-- =============================================================================
-- Letiq ERP - Migration 0009: Phase 2 atomic posting functions (RPCs)
-- =============================================================================
-- Each posting operation runs inside a single function call (one transaction),
-- locks required rows, recalculates totals on the server, and writes stock,
-- kardex, journal, payment and status records together. SECURITY DEFINER with a
-- fixed search_path; EXECUTE granted only to service_role (the trusted server
-- layer that has already verified the user, permission and branch access).

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.assert_period_open(p_company uuid, p_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from public.accounting_periods
    where company_id = p_company and p_date between start_date and end_date
      and status in ('closed','locked')
  ) then
    raise exception 'The accounting period for % is closed or locked', p_date
      using errcode = 'P0001';
  end if;
end; $$;

create or replace function public.resolve_payment_ledger(p_company uuid, p_pa uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare pa public.payment_accounts; acc uuid;
begin
  select * into pa from public.payment_accounts where id = p_pa and company_id = p_company and is_active;
  if not found then raise exception 'Payment account is not valid for this company' using errcode='P0001'; end if;
  if pa.ledger_account_id is not null then return pa.ledger_account_id; end if;
  acc := public.account_id_by_code(p_company,
           case pa.account_type when 'cash' then '1110' when 'bank' then '1120'
                when 'mobile_money' then '1130' else '1130' end);
  return acc;
end; $$;

-- Recompute a sale's amount paid / outstanding / payment status from valid
-- payments, posted receipt allocations and posted returns. Server-authoritative.
create or replace function public.recalc_sale(p_sale uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  s public.sales; init_paid numeric(18,2); alloc numeric(18,2);
  ret_total numeric(18,2); ret_recv numeric(18,2); paid numeric(18,2);
  outstanding numeric(18,2); status text;
begin
  select * into s from public.sales where id = p_sale;
  select coalesce(sum(amount),0) into init_paid from public.sale_payments where sale_id = p_sale;
  select coalesce(sum(a.amount),0) into alloc
    from public.customer_receipt_allocations a
    join public.customer_receipts r on r.id = a.receipt_id
    where a.sale_id = p_sale and r.document_status = 'posted';
  select coalesce(sum(total),0), coalesce(sum(receivable_reduction),0)
    into ret_total, ret_recv
    from public.sales_returns where sale_id = p_sale and document_status = 'posted';

  paid := round(init_paid + alloc, 2);
  outstanding := round(s.grand_total - paid - ret_recv, 2);
  if outstanding < 0 then outstanding := 0; end if;

  if ret_total >= s.grand_total and s.grand_total > 0 then
    status := 'refunded';
  elsif ret_total > 0 then
    status := 'partially_refunded';
  elsif paid <= 0 then
    status := 'unpaid';
  elsif paid < s.grand_total then
    status := 'partially_paid';
  else
    status := 'paid';
  end if;

  update public.sales set amount_paid = paid, outstanding = outstanding, payment_status = status
    where id = p_sale;
end; $$;

create or replace function public.claim_idempotency(p_key text, p_op text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_key is null then return true; end if;
  begin
    insert into public.idempotency_keys(key, operation, result_id) values (p_key, p_op, p_id);
    return true;
  exception when unique_violation then
    return false; -- already processed
  end;
end; $$;

-- ---------------------------------------------------------------------------
-- INVENTORY OPENING
-- ---------------------------------------------------------------------------
create or replace function public.post_inventory_opening(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.inventory_openings; ln record; docnum text; total numeric(18,2):=0;
  jlines jsonb := '[]'::jsonb;
begin
  select * into o from public.inventory_openings where id = p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if o.document_status <> 'draft' then raise exception 'Opening already %', o.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_inventory_opening', p_id) then return p_id; end if;
  perform public.assert_period_open(o.company_id, o.opening_date);

  if not exists (select 1 from public.inventory_opening_lines where opening_id = p_id) then
    raise exception 'Opening has no lines' using errcode='P0001';
  end if;

  docnum := public.next_document_number(o.company_id, o.branch_id, 'inventory_opening');

  for ln in select * from public.inventory_opening_lines where opening_id = p_id order by line_no loop
    perform public.record_stock_movement(o.company_id, o.branch_id, ln.product_id,
      'opening', 'inventory_opening', o.id, docnum, ln.quantity, 0, ln.unit_cost, p_user);
    total := total + round(ln.quantity * ln.unit_cost, 2);
    update public.inventory_opening_lines set total_cost = round(ln.quantity * ln.unit_cost,2) where id = ln.id;
  end loop;

  jlines := jsonb_build_array(
    jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'1150'), 'debit', total, 'credit', 0, 'memo','Opening inventory'),
    jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'3200'), 'debit', 0, 'credit', total, 'memo','Opening balance equity')
  );
  perform public.create_journal(o.company_id, o.branch_id, o.opening_date, 'inventory_opening', o.id, docnum, 'Inventory opening '||docnum, p_user, jlines);

  update public.inventory_openings set document_status='posted', document_number=docnum,
    total_cost=total, posted_by=p_user, posted_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (o.company_id, 'inventory_opening', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_inventory_opening(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.inventory_openings; ln record;
begin
  select * into o from public.inventory_openings where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if o.document_status <> 'posted' then raise exception 'Only posted openings can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'') = '' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(o.company_id, o.opening_date);

  for ln in select * from public.inventory_opening_lines where opening_id=p_id loop
    perform public.record_stock_movement(o.company_id, o.branch_id, ln.product_id,
      'adjustment_void', 'inventory_opening_void', o.id, o.document_number, 0, ln.quantity, 0, p_user);
  end loop;

  perform public.create_journal(o.company_id, o.branch_id, current_date, 'inventory_opening_void', o.id, o.document_number,
    'Void opening '||o.document_number, p_user, jsonb_build_array(
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'3200'),'debit',o.total_cost,'credit',0),
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'1150'),'debit',0,'credit',o.total_cost)
    ));

  update public.inventory_openings set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (o.company_id, 'inventory_opening', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- STOCK ADJUSTMENT
-- ---------------------------------------------------------------------------
create or replace function public.post_stock_adjustment(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare a public.stock_adjustments; ln record; docnum text; total numeric(18,2):=0; v numeric(18,2);
begin
  select * into a from public.stock_adjustments where id=p_id for update;
  if not found then raise exception 'Adjustment not found' using errcode='P0001'; end if;
  if a.document_status <> 'draft' then raise exception 'Adjustment already %', a.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_stock_adjustment', p_id) then return p_id; end if;
  perform public.assert_period_open(a.company_id, a.adjustment_date);
  if not exists (select 1 from public.stock_adjustment_lines where adjustment_id=p_id) then
    raise exception 'Adjustment has no lines' using errcode='P0001';
  end if;

  docnum := public.next_document_number(a.company_id, a.branch_id, 'stock_adjustment');

  for ln in select * from public.stock_adjustment_lines where adjustment_id=p_id order by line_no loop
    if a.direction = 'increase' then
      perform public.record_stock_movement(a.company_id, a.branch_id, ln.product_id,
        'adjustment_increase','stock_adjustment', a.id, docnum, ln.quantity, 0, ln.unit_cost, p_user);
      v := round(ln.quantity * ln.unit_cost, 2);
    else
      v := public.record_stock_movement(a.company_id, a.branch_id, ln.product_id,
        'adjustment_decrease','stock_adjustment', a.id, docnum, 0, ln.quantity, 0, p_user);
    end if;
    total := total + v;
    update public.stock_adjustment_lines set total_value = v where id = ln.id;
  end loop;

  if a.direction = 'increase' then
    perform public.create_journal(a.company_id, a.branch_id, a.adjustment_date, 'stock_adjustment', a.id, docnum,
      'Stock adjustment '||docnum, p_user, jsonb_build_array(
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'1150'),'debit',total,'credit',0),
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'4300'),'debit',0,'credit',total)));
  else
    perform public.create_journal(a.company_id, a.branch_id, a.adjustment_date, 'stock_adjustment', a.id, docnum,
      'Stock adjustment '||docnum, p_user, jsonb_build_array(
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'6300'),'debit',total,'credit',0),
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'1150'),'debit',0,'credit',total)));
  end if;

  update public.stock_adjustments set document_status='posted', document_number=docnum, total_value=total,
    posted_by=p_user, posted_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (a.company_id, 'stock_adjustment', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_stock_adjustment(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare a public.stock_adjustments; ln record;
begin
  select * into a from public.stock_adjustments where id=p_id for update;
  if not found then raise exception 'Adjustment not found' using errcode='P0001'; end if;
  if a.document_status <> 'posted' then raise exception 'Only posted adjustments can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(a.company_id, a.adjustment_date);

  for ln in select * from public.stock_adjustment_lines where adjustment_id=p_id loop
    if a.direction='increase' then
      perform public.record_stock_movement(a.company_id, a.branch_id, ln.product_id,
        'adjustment_void','stock_adjustment_void', a.id, a.document_number, 0, ln.quantity, 0, p_user);
    else
      perform public.record_stock_movement(a.company_id, a.branch_id, ln.product_id,
        'adjustment_void','stock_adjustment_void', a.id, a.document_number, ln.quantity, 0, ln.unit_cost, p_user);
    end if;
  end loop;

  if a.direction='increase' then
    perform public.create_journal(a.company_id, a.branch_id, current_date, 'stock_adjustment_void', a.id, a.document_number,
      'Void adjustment '||a.document_number, p_user, jsonb_build_array(
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'4300'),'debit',a.total_value,'credit',0),
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'1150'),'debit',0,'credit',a.total_value)));
  else
    perform public.create_journal(a.company_id, a.branch_id, current_date, 'stock_adjustment_void', a.id, a.document_number,
      'Void adjustment '||a.document_number, p_user, jsonb_build_array(
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'1150'),'debit',a.total_value,'credit',0),
        jsonb_build_object('account_id', public.account_id_by_code(a.company_id,'6300'),'debit',0,'credit',a.total_value)));
  end if;

  update public.stock_adjustments set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (a.company_id, 'stock_adjustment', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- SALE
-- ---------------------------------------------------------------------------
create or replace function public.post_sale(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  s public.sales; ln record; pay record; docnum text;
  subtotal numeric(18,2):=0; disc_total numeric(18,2):=0; net_total numeric(18,2):=0;
  tax_total numeric(18,2):=0; grand numeric(18,2):=0; cogs_total numeric(18,2):=0;
  base numeric(18,2); net numeric(18,2); tax numeric(18,2); ltotal numeric(18,2);
  paid numeric(18,2); outstanding numeric(18,2); linecogs numeric(18,2);
  jlines jsonb := '[]'::jsonb;
begin
  select * into s from public.sales where id=p_id for update;
  if not found then raise exception 'Sale not found' using errcode='P0001'; end if;
  if s.document_status <> 'draft' then raise exception 'Sale already %', s.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_sale', p_id) then return p_id; end if;
  perform public.assert_period_open(s.company_id, s.document_date);
  if not exists (select 1 from public.sale_lines where sale_id=p_id) then
    raise exception 'Sale has no lines' using errcode='P0001';
  end if;

  docnum := public.next_document_number(s.company_id, s.branch_id, 'sales_invoice');

  -- Recalculate line and header totals (server-authoritative).
  for ln in select * from public.sale_lines where sale_id=p_id order by line_no loop
    base := round(ln.quantity * ln.unit_price - ln.discount, 2);
    if base < 0 then raise exception 'Line discount exceeds line value' using errcode='P0001'; end if;
    if ln.tax_inclusive and ln.tax_rate > 0 then
      net := round(base / (1 + ln.tax_rate/100.0), 2);
      tax := round(base - net, 2);
      ltotal := base;
    else
      net := base;
      tax := round(base * ln.tax_rate/100.0, 2);
      ltotal := round(net + tax, 2);
    end if;
    subtotal := subtotal + round(ln.quantity * ln.unit_price, 2);
    disc_total := disc_total + ln.discount;
    net_total := net_total + net;
    tax_total := tax_total + tax;
    grand := grand + ltotal;

    linecogs := 0;
    if ln.track_inventory then
      linecogs := public.record_stock_movement(s.company_id, s.branch_id, ln.product_id,
        'sale','sale', s.id, docnum, 0, ln.quantity, 0, p_user);
      cogs_total := cogs_total + linecogs;
    end if;
    update public.sale_lines set net_amount=net, tax_amount=tax, line_total=ltotal,
      unit_cost = case when ln.quantity>0 then round(linecogs/ln.quantity,4) else 0 end, cogs=linecogs
      where id=ln.id;
  end loop;

  -- Validate payments do not exceed total.
  select coalesce(sum(amount),0) into paid from public.sale_payments where sale_id=p_id;
  if paid > grand + 0.001 then raise exception 'Payments exceed the sale total' using errcode='P0001'; end if;
  outstanding := round(grand - paid, 2);
  if outstanding > 0 and s.customer_id is null then
    raise exception 'A credit balance requires a customer' using errcode='P0001';
  end if;

  -- Journal: debit payment ledgers + AR; credit revenue + VAT; COGS/inventory.
  for pay in
    select public.resolve_payment_ledger(s.company_id, payment_account_id) as acc, sum(amount) as amt
    from public.sale_payments where sale_id=p_id group by 1
  loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc, 'debit', pay.amt, 'credit', 0, 'memo','Payment received');
  end loop;
  if outstanding > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1140'),'debit',outstanding,'credit',0,'memo','Accounts receivable');
  end if;
  if net_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'4100'),'debit',0,'credit',net_total,'memo','Sales revenue');
  end if;
  if tax_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'2120'),'debit',0,'credit',tax_total,'memo','Output VAT');
  end if;
  if cogs_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'5100'),'debit',cogs_total,'credit',0,'memo','Cost of goods sold');
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1150'),'debit',0,'credit',cogs_total,'memo','Inventory');
  end if;

  perform public.create_journal(s.company_id, s.branch_id, s.document_date, 'sale', s.id, docnum,
    'Sale '||docnum, p_user, jlines);

  update public.sales set document_status='posted', document_number=docnum,
    subtotal=subtotal, discount_total=disc_total, net_total=net_total, tax_total=tax_total,
    grand_total=grand, cogs_total=cogs_total, posted_by=p_user, posted_at=now() where id=p_id;

  perform public.recalc_sale(p_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (s.company_id, 'sale', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_sale(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare s public.sales; ln record; jlines jsonb := '[]'::jsonb; pay record;
begin
  select * into s from public.sales where id=p_id for update;
  if not found then raise exception 'Sale not found' using errcode='P0001'; end if;
  if s.document_status <> 'posted' then raise exception 'Only posted sales can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(s.company_id, s.document_date);

  -- Block when dependent posted records exist.
  if exists (select 1 from public.customer_receipt_allocations a
             join public.customer_receipts r on r.id=a.receipt_id
             where a.sale_id=p_id and r.document_status='posted') then
    raise exception 'Void the customer receipts on this sale first' using errcode='P0001';
  end if;
  if exists (select 1 from public.sales_returns where sale_id=p_id and document_status='posted') then
    raise exception 'Void the sales returns on this sale first' using errcode='P0001';
  end if;

  -- Reverse inventory (put stock back at captured cost).
  for ln in select * from public.sale_lines where sale_id=p_id loop
    if ln.track_inventory and ln.quantity>0 then
      perform public.record_stock_movement(s.company_id, s.branch_id, ln.product_id,
        'sale_void','sale_void', s.id, s.document_number, ln.quantity, 0, ln.unit_cost, p_user);
    end if;
  end loop;

  -- Reverse the sales journal.
  for pay in
    select public.resolve_payment_ledger(s.company_id, payment_account_id) as acc, sum(amount) as amt
    from public.sale_payments where sale_id=p_id group by 1
  loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc, 'debit', 0, 'credit', pay.amt);
  end loop;
  if s.outstanding > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1140'),'debit',0,'credit',s.outstanding);
  end if;
  if s.net_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'4100'),'debit',s.net_total,'credit',0);
  end if;
  if s.tax_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'2120'),'debit',s.tax_total,'credit',0);
  end if;
  if s.cogs_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1150'),'debit',s.cogs_total,'credit',0);
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'5100'),'debit',0,'credit',s.cogs_total);
  end if;
  perform public.create_journal(s.company_id, s.branch_id, current_date, 'sale_void', s.id, s.document_number,
    'Void sale '||s.document_number, p_user, jlines);

  update public.sales set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (s.company_id, 'sale', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- CUSTOMER RECEIPT
-- ---------------------------------------------------------------------------
create or replace function public.post_customer_receipt(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.customer_receipts; alloc_total numeric(18,2); docnum text; a record; s public.sales;
begin
  select * into r from public.customer_receipts where id=p_id for update;
  if not found then raise exception 'Receipt not found' using errcode='P0001'; end if;
  if r.document_status <> 'draft' then raise exception 'Receipt already %', r.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_customer_receipt', p_id) then return p_id; end if;
  perform public.assert_period_open(r.company_id, r.document_date);

  select coalesce(sum(amount),0) into alloc_total from public.customer_receipt_allocations where receipt_id=p_id;
  if round(alloc_total,2) <> round(r.amount,2) then
    raise exception 'Allocations (%.2f) must equal the receipt amount (%.2f)', alloc_total, r.amount using errcode='P0001';
  end if;

  -- Validate each allocation against invoice outstanding (lock the sales).
  for a in select * from public.customer_receipt_allocations where receipt_id=p_id loop
    select * into s from public.sales where id=a.sale_id for update;
    if not found or s.document_status <> 'posted' then raise exception 'Invalid invoice in allocation' using errcode='P0001'; end if;
    if s.customer_id <> r.customer_id then raise exception 'Invoice belongs to a different customer' using errcode='P0001'; end if;
    if a.amount > s.outstanding + 0.001 then raise exception 'Allocation exceeds invoice outstanding' using errcode='P0001'; end if;
  end loop;

  docnum := public.next_document_number(r.company_id, r.branch_id, 'sales_receipt');

  perform public.create_journal(r.company_id, r.branch_id, r.document_date, 'customer_receipt', r.id, docnum,
    'Customer receipt '||docnum, p_user, jsonb_build_array(
      jsonb_build_object('account_id', public.resolve_payment_ledger(r.company_id, r.payment_account_id),'debit',r.amount,'credit',0),
      jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1140'),'debit',0,'credit',r.amount)));

  update public.customer_receipts set document_status='posted', document_number=docnum, posted_by=p_user, posted_at=now() where id=p_id;

  -- Recompute affected invoices.
  for a in select distinct sale_id from public.customer_receipt_allocations where receipt_id=p_id loop
    perform public.recalc_sale(a.sale_id);
  end loop;

  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (r.company_id, 'customer_receipt', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_customer_receipt(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.customer_receipts; a record;
begin
  select * into r from public.customer_receipts where id=p_id for update;
  if not found then raise exception 'Receipt not found' using errcode='P0001'; end if;
  if r.document_status <> 'posted' then raise exception 'Only posted receipts can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(r.company_id, r.document_date);

  perform public.create_journal(r.company_id, r.branch_id, current_date, 'customer_receipt_void', r.id, r.document_number,
    'Void receipt '||r.document_number, p_user, jsonb_build_array(
      jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1140'),'debit',r.amount,'credit',0),
      jsonb_build_object('account_id', public.resolve_payment_ledger(r.company_id, r.payment_account_id),'debit',0,'credit',r.amount)));

  update public.customer_receipts set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  for a in select distinct sale_id from public.customer_receipt_allocations where receipt_id=p_id loop
    perform public.recalc_sale(a.sale_id);
  end loop;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (r.company_id, 'customer_receipt', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- SALES RETURN
-- ---------------------------------------------------------------------------
create or replace function public.post_sales_return(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.sales_returns; ln record; docnum text;
  net_total numeric(18,2):=0; tax_total numeric(18,2):=0; total numeric(18,2):=0;
  cogs_restored numeric(18,2):=0; refund numeric(18,2); recv_reduction numeric(18,2);
  prior numeric(18,4); jlines jsonb := '[]'::jsonb; rf record;
begin
  select * into r from public.sales_returns where id=p_id for update;
  if not found then raise exception 'Return not found' using errcode='P0001'; end if;
  if r.document_status <> 'draft' then raise exception 'Return already %', r.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_sales_return', p_id) then return p_id; end if;
  if coalesce(r.reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(r.company_id, r.document_date);

  docnum := public.next_document_number(r.company_id, r.branch_id, 'sales_return');

  for ln in select rl.*, sl.quantity as sold_qty from public.sales_return_lines rl
            join public.sale_lines sl on sl.id = rl.sale_line_id
            where rl.return_id=p_id order by rl.line_no loop
    -- Cannot return more than sold minus prior valid returns.
    select coalesce(sum(prl.quantity),0) into prior
      from public.sales_return_lines prl
      join public.sales_returns pr on pr.id = prl.return_id
      where prl.sale_line_id = ln.sale_line_id and pr.document_status='posted';
    if ln.quantity + prior > ln.sold_qty + 0.0001 then
      raise exception 'Return exceeds sold quantity for a line' using errcode='P0001';
    end if;

    net_total := net_total + ln.net_amount;
    tax_total := tax_total + ln.tax_amount;
    total := total + ln.line_total;

    if ln.track_inventory then
      if ln.condition = 'saleable' then
        perform public.record_stock_movement(r.company_id, r.branch_id, ln.product_id,
          'sales_return','sales_return', r.id, docnum, ln.quantity, 0, ln.unit_cost, p_user);
        cogs_restored := cogs_restored + round(ln.quantity * ln.unit_cost, 2);
        update public.sales_return_lines set cogs_reversal = round(ln.quantity * ln.unit_cost,2) where id=ln.id;
      else
        update public.sales_return_lines set cogs_reversal = 0 where id=ln.id;
      end if;
    end if;
  end loop;

  select coalesce(sum(amount),0) into refund from public.sales_return_refunds where return_id=p_id;
  if refund > total + 0.001 then raise exception 'Refund exceeds return value' using errcode='P0001'; end if;
  recv_reduction := round(total - refund, 2);
  if recv_reduction < 0 then recv_reduction := 0; end if;

  -- Journal: reverse revenue & VAT; refund cash or reduce AR; restore inventory/COGS.
  if net_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'4900'),'debit',net_total,'credit',0,'memo','Sales returns');
  end if;
  if tax_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'2120'),'debit',tax_total,'credit',0,'memo','Output VAT reversal');
  end if;
  for rf in
    select public.resolve_payment_ledger(r.company_id, payment_account_id) as acc, sum(amount) as amt
    from public.sales_return_refunds where return_id=p_id group by 1
  loop
    jlines := jlines || jsonb_build_object('account_id', rf.acc, 'debit', 0, 'credit', rf.amt, 'memo','Refund');
  end loop;
  if recv_reduction > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1140'),'debit',0,'credit',recv_reduction,'memo','Reduce receivable');
  end if;
  if cogs_restored > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1150'),'debit',cogs_restored,'credit',0,'memo','Inventory restored');
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5100'),'debit',0,'credit',cogs_restored,'memo','COGS reversed');
  end if;
  perform public.create_journal(r.company_id, r.branch_id, r.document_date, 'sales_return', r.id, docnum,
    'Sales return '||docnum, p_user, jlines);

  update public.sales_returns set document_status='posted', document_number=docnum,
    net_total=net_total, tax_total=tax_total, total=total, refund_amount=refund,
    receivable_reduction=recv_reduction, cogs_restored=cogs_restored, posted_by=p_user, posted_at=now()
    where id=p_id;

  perform public.recalc_sale(r.sale_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (r.company_id, 'sales_return', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_sales_return(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.sales_returns; ln record; jlines jsonb := '[]'::jsonb; rf record;
begin
  select * into r from public.sales_returns where id=p_id for update;
  if not found then raise exception 'Return not found' using errcode='P0001'; end if;
  if r.document_status <> 'posted' then raise exception 'Only posted returns can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(r.company_id, r.document_date);

  for ln in select * from public.sales_return_lines where return_id=p_id loop
    if ln.track_inventory and ln.condition='saleable' and ln.quantity>0 then
      perform public.record_stock_movement(r.company_id, r.branch_id, ln.product_id,
        'sales_return_void','sales_return_void', r.id, r.document_number, 0, ln.quantity, 0, p_user);
    end if;
  end loop;

  if r.net_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'4900'),'debit',0,'credit',r.net_total);
  end if;
  if r.tax_total > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'2120'),'debit',0,'credit',r.tax_total);
  end if;
  for rf in select public.resolve_payment_ledger(r.company_id, payment_account_id) as acc, sum(amount) as amt
            from public.sales_return_refunds where return_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', rf.acc, 'debit', rf.amt, 'credit', 0);
  end loop;
  if r.receivable_reduction > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1140'),'debit',r.receivable_reduction,'credit',0);
  end if;
  if r.cogs_restored > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5100'),'debit',r.cogs_restored,'credit',0);
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1150'),'debit',0,'credit',r.cogs_restored);
  end if;
  perform public.create_journal(r.company_id, r.branch_id, current_date, 'sales_return_void', r.id, r.document_number,
    'Void return '||r.document_number, p_user, jlines);

  update public.sales_returns set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  perform public.recalc_sale(r.sale_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (r.company_id, 'sales_return', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- STOCK TRANSFERS
-- ---------------------------------------------------------------------------
create or replace function public.dispatch_stock_transfer(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t public.stock_transfers; ln record; docnum text; cost numeric(18,2);
begin
  select * into t from public.stock_transfers where id=p_id for update;
  if not found then raise exception 'Transfer not found' using errcode='P0001'; end if;
  if t.status <> 'draft' then raise exception 'Transfer already %', t.status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'dispatch_stock_transfer', p_id) then return p_id; end if;
  perform public.assert_period_open(t.company_id, t.transfer_date);
  if not exists (select 1 from public.stock_transfer_lines where transfer_id=p_id) then
    raise exception 'Transfer has no lines' using errcode='P0001';
  end if;

  docnum := public.next_document_number(t.company_id, t.source_branch_id, 'stock_transfer');

  for ln in select * from public.stock_transfer_lines where transfer_id=p_id order by line_no loop
    cost := public.record_stock_movement(t.company_id, t.source_branch_id, ln.product_id,
      'transfer_out','stock_transfer', t.id, docnum, 0, ln.qty_requested, 0, p_user);
    perform public.adjust_in_transit(t.company_id, t.destination_branch_id, ln.product_id, ln.qty_requested);
    update public.stock_transfer_lines set qty_dispatched = ln.qty_requested,
      unit_cost = case when ln.qty_requested>0 then round(cost/ln.qty_requested,4) else 0 end
      where id=ln.id;
  end loop;

  update public.stock_transfers set status='dispatched', document_number=docnum,
    dispatched_by=p_user, dispatched_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (t.company_id, 'stock_transfer', p_id, 'draft', 'dispatched', p_user);
  return p_id;
end; $$;

create or replace function public.receive_stock_transfer(p_id uuid, p_user uuid, p_lines jsonb, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t public.stock_transfers; item jsonb; ln public.stock_transfer_lines;
  qty numeric(18,4); all_done boolean; any_recv boolean := false; new_status text;
begin
  select * into t from public.stock_transfers where id=p_id for update;
  if not found then raise exception 'Transfer not found' using errcode='P0001'; end if;
  if t.status not in ('dispatched','partially_received') then
    raise exception 'Transfer is not in a receivable state' using errcode='P0001';
  end if;
  if p_idem is not null and not public.claim_idempotency(p_idem, 'receive_stock_transfer', p_id) then return p_id; end if;

  for item in select * from jsonb_array_elements(p_lines) loop
    select * into ln from public.stock_transfer_lines where id=(item->>'line_id')::uuid and transfer_id=p_id for update;
    if not found then raise exception 'Invalid transfer line' using errcode='P0001'; end if;
    qty := (item->>'qty')::numeric;
    if qty <= 0 then continue; end if;
    if ln.qty_received + qty > ln.qty_dispatched + 0.0001 then
      raise exception 'Cannot receive more than dispatched' using errcode='P0001';
    end if;
    perform public.record_stock_movement(t.company_id, t.destination_branch_id, ln.product_id,
      'transfer_in','stock_transfer', t.id, t.document_number, qty, 0, ln.unit_cost, p_user);
    perform public.adjust_in_transit(t.company_id, t.destination_branch_id, ln.product_id, -qty);
    update public.stock_transfer_lines set qty_received = ln.qty_received + qty where id=ln.id;
    any_recv := true;
  end loop;

  select bool_and(qty_received >= qty_dispatched) into all_done
    from public.stock_transfer_lines where transfer_id=p_id;
  new_status := case when all_done then 'received' else 'partially_received' end;
  update public.stock_transfers set status=new_status where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (t.company_id, 'stock_transfer', p_id, t.status, new_status, p_user);
  return p_id;
end; $$;

create or replace function public.void_stock_transfer(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare t public.stock_transfers; ln record;
begin
  select * into t from public.stock_transfers where id=p_id for update;
  if not found then raise exception 'Transfer not found' using errcode='P0001'; end if;
  if t.status = 'voided' then raise exception 'Transfer already voided' using errcode='P0001'; end if;
  if t.status = 'draft' then raise exception 'Delete the draft instead of voiding' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(t.company_id, t.transfer_date);

  for ln in select * from public.stock_transfer_lines where transfer_id=p_id loop
    -- Return received stock out of destination.
    if ln.qty_received > 0 then
      perform public.record_stock_movement(t.company_id, t.destination_branch_id, ln.product_id,
        'transfer_void','stock_transfer_void', t.id, t.document_number, 0, ln.qty_received, 0, p_user);
    end if;
    -- Return dispatched stock back to source.
    if ln.qty_dispatched > 0 then
      perform public.record_stock_movement(t.company_id, t.source_branch_id, ln.product_id,
        'transfer_void','stock_transfer_void', t.id, t.document_number, ln.qty_dispatched, 0, ln.unit_cost, p_user);
    end if;
    -- Clear any remaining in-transit.
    perform public.adjust_in_transit(t.company_id, t.destination_branch_id, ln.product_id, -(ln.qty_dispatched - ln.qty_received));
  end loop;

  update public.stock_transfers set status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (t.company_id, 'stock_transfer', p_id, t.status, 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Lock down execution: only the trusted server (service_role) may call these.
-- ---------------------------------------------------------------------------
do $$
declare fn text;
begin
  foreach fn in array array[
    'next_document_number(uuid,uuid,text)',
    'record_stock_movement(uuid,uuid,uuid,text,text,uuid,text,numeric,numeric,numeric,uuid)',
    'adjust_in_transit(uuid,uuid,uuid,numeric)',
    'assert_period_open(uuid,date)',
    'resolve_payment_ledger(uuid,uuid)',
    'recalc_sale(uuid)',
    'claim_idempotency(text,text,uuid)',
    'account_id_by_code(uuid,text)',
    'create_journal(uuid,uuid,date,text,uuid,text,text,uuid,jsonb)',
    'post_inventory_opening(uuid,uuid,text)','void_inventory_opening(uuid,uuid,text)',
    'post_stock_adjustment(uuid,uuid,text)','void_stock_adjustment(uuid,uuid,text)',
    'post_sale(uuid,uuid,text)','void_sale(uuid,uuid,text)',
    'post_customer_receipt(uuid,uuid,text)','void_customer_receipt(uuid,uuid,text)',
    'post_sales_return(uuid,uuid,text)','void_sales_return(uuid,uuid,text)',
    'dispatch_stock_transfer(uuid,uuid,text)','receive_stock_transfer(uuid,uuid,jsonb,text)',
    'void_stock_transfer(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public', fn);
    execute format('revoke all on function public.%s from anon', fn);
    execute format('revoke all on function public.%s from authenticated', fn);
    execute format('grant execute on function public.%s to service_role', fn);
  end loop;
end $$;
