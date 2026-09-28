-- =============================================================================
-- Letiq ERP - Migration 0015: Phase 3 atomic posting functions
-- =============================================================================
-- One transaction per posting op: locks rows, recalculates on the server,
-- writes document + payments + payable + stock/kardex + balanced journal +
-- status history together. SECURITY DEFINER, service_role-only.

set check_function_bodies = off;

-- Normalize a supplier invoice number for duplicate detection.
create or replace function public.norm_invoice(p text)
returns text language sql immutable as $$
  select nullif(lower(regexp_replace(coalesce(p,''), '[^a-zA-Z0-9]', '', 'g')), '');
$$;

-- ---------------------------------------------------------------------------
-- recalc_purchase / recalc_expense: derive outstanding + payment status +
-- keep the supplier_payables row in sync. Server-authoritative.
-- ---------------------------------------------------------------------------
create or replace function public.recalc_purchase(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.purchases; init_paid numeric(18,2); alloc numeric(18,2);
  ret_total numeric(18,2); ret_payable numeric(18,2); paid numeric(18,2);
  v_out numeric(18,2); v_status text;
begin
  select * into v from public.purchases where id=p_id;
  select coalesce(sum(amount),0) into init_paid from public.purchase_payments where purchase_id=p_id;
  select coalesce(sum(a.amount),0) into alloc
    from public.supplier_payment_allocations a
    join public.supplier_payments sp on sp.id=a.payment_id
    join public.supplier_payables pb on pb.id=a.payable_id
    where pb.purchase_id=p_id and sp.document_status='posted';
  select coalesce(sum(total),0), coalesce(sum(payable_reduction),0) into ret_total, ret_payable
    from public.purchase_returns where purchase_id=p_id and document_status='posted';

  paid := round(init_paid + alloc, 2);
  v_out := round(v.grand_total - paid - ret_payable, 2);
  if v_out < 0 then v_out := 0; end if;

  if ret_total >= v.grand_total and v.grand_total > 0 then v_status := 'refunded';
  elsif ret_total > 0 then v_status := 'partially_refunded';
  elsif paid <= 0 then v_status := 'unpaid';
  elsif paid < v.grand_total then v_status := 'partially_paid';
  else v_status := 'paid';
  end if;

  update public.purchases set amount_paid=paid, outstanding=v_out, payment_status=v_status where id=p_id;
  update public.supplier_payables set outstanding=v_out,
    status = case when v_out<=0 then 'settled' when paid>0 or ret_payable>0 then 'partial' else 'open' end
    where purchase_id=p_id;
end; $$;

create or replace function public.recalc_expense(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.expenses; init_paid numeric(18,2); alloc numeric(18,2); paid numeric(18,2);
  v_out numeric(18,2); v_status text;
begin
  select * into v from public.expenses where id=p_id;
  select coalesce(sum(amount),0) into init_paid from public.expense_payments where expense_id=p_id;
  select coalesce(sum(a.amount),0) into alloc
    from public.supplier_payment_allocations a
    join public.supplier_payments sp on sp.id=a.payment_id
    join public.supplier_payables pb on pb.id=a.payable_id
    where pb.expense_id=p_id and sp.document_status='posted';
  paid := round(init_paid + alloc, 2);
  v_out := round(v.grand_total - paid, 2);
  if v_out < 0 then v_out := 0; end if;
  if paid <= 0 then v_status := 'unpaid';
  elsif paid < v.grand_total then v_status := 'partially_paid';
  else v_status := 'paid'; end if;

  update public.expenses set amount_paid=paid, outstanding=v_out, payment_status=v_status where id=p_id;
  update public.supplier_payables set outstanding=v_out,
    status = case when v_out<=0 then 'settled' when paid>0 then 'partial' else 'open' end
    where expense_id=p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- POST PURCHASE
-- ---------------------------------------------------------------------------
create or replace function public.post_purchase(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v public.purchases; ln record; pay record; docnum text; norm text;
  base numeric(18,2); net numeric(18,2); tax numeric(18,2); rec numeric(18,2); nonrec numeric(18,2);
  inv_unit numeric(18,4); inv_val numeric(18,2);
  v_sub numeric(18,2):=0; v_disc numeric(18,2):=0; v_net numeric(18,2):=0; v_tax numeric(18,2):=0;
  v_rec numeric(18,2):=0; v_nonrec numeric(18,2):=0; v_grand numeric(18,2):=0; v_inv numeric(18,2):=0;
  v_expense numeric(18,2):=0; paid numeric(18,2); outstanding numeric(18,2); jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.purchases where id=p_id for update;
  if not found then raise exception 'Purchase not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Purchase already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_purchase', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  if not exists (select 1 from public.purchase_lines where purchase_id=p_id) then
    raise exception 'Purchase has no lines' using errcode='P0001';
  end if;

  norm := public.norm_invoice(v.supplier_invoice_number);
  if norm is not null and exists (
    select 1 from public.purchases x where x.company_id=v.company_id and x.supplier_id=v.supplier_id
      and x.supplier_invoice_norm = norm and x.document_status='posted' and x.id <> p_id
  ) then
    raise exception 'A posted purchase with this supplier invoice number already exists' using errcode='P0001';
  end if;

  docnum := public.next_document_number(v.company_id, v.branch_id, 'purchase');

  for ln in select * from public.purchase_lines where purchase_id=p_id order by line_no loop
    base := round(ln.quantity * ln.unit_cost - ln.discount, 2);
    if base < 0 then raise exception 'Line discount exceeds line value' using errcode='P0001'; end if;
    if ln.tax_inclusive and ln.tax_rate > 0 then
      net := round(base / (1 + ln.tax_rate/100.0), 2); tax := round(base - net, 2);
    else
      net := base; tax := round(base * ln.tax_rate/100.0, 2);
    end if;
    rec := case when ln.is_recoverable then tax else 0 end;
    nonrec := tax - rec;

    v_sub := v_sub + round(ln.quantity*ln.unit_cost,2); v_disc := v_disc + ln.discount;
    v_net := v_net + net; v_tax := v_tax + tax; v_rec := v_rec + rec; v_nonrec := v_nonrec + nonrec;
    v_grand := v_grand + round(net + tax, 2);

    if ln.track_inventory then
      inv_val := round(net + nonrec, 2);
      inv_unit := case when ln.quantity>0 then round(inv_val/ln.quantity,4) else 0 end;
      perform public.record_stock_movement(v.company_id, v.branch_id, ln.product_id,
        'purchase','purchase', v.id, docnum, ln.quantity, 0, inv_unit, p_user);
      v_inv := v_inv + inv_val;
    else
      inv_val := 0; inv_unit := 0;
      v_expense := v_expense + round(net + nonrec, 2);
    end if;

    update public.purchase_lines set net_amount=net, tax_amount=tax, recoverable_tax=rec,
      nonrecoverable_tax=nonrec, gross_amount=round(net+tax,2), inventory_unit_cost=inv_unit,
      inventory_value=inv_val where id=ln.id;
  end loop;

  select coalesce(sum(amount),0) into paid from public.purchase_payments where purchase_id=p_id;
  if paid > v_grand + 0.001 then raise exception 'Payments exceed the purchase total' using errcode='P0001'; end if;
  outstanding := round(v_grand - paid, 2);

  -- Journal
  if v_inv > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1150'),'debit',v_inv,'credit',0,'memo','Inventory'); end if;
  if v_expense > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'6100'),'debit',v_expense,'credit',0,'memo','Purchases (non-stock)'); end if;
  if v_rec > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1160'),'debit',v_rec,'credit',0,'memo','Input VAT'); end if;
  for pay in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
             from public.purchase_payments where purchase_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc,'debit',0,'credit',pay.amt,'memo','Payment');
  end loop;
  if outstanding > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',0,'credit',outstanding,'memo','Accounts payable'); end if;
  perform public.create_journal(v.company_id, v.branch_id, v.document_date, 'purchase', v.id, docnum, 'Purchase '||docnum, p_user, jlines);

  update public.purchases set document_status='posted', document_number=docnum, supplier_invoice_norm=norm,
    subtotal=v_sub, discount_total=v_disc, net_total=v_net, tax_total=v_tax, recoverable_tax=v_rec,
    nonrecoverable_tax=v_nonrec, grand_total=v_grand, inventory_value=v_inv, posted_by=p_user, posted_at=now()
    where id=p_id;

  if outstanding > 0 then
    insert into public.supplier_payables(company_id, branch_id, supplier_id, source_type, purchase_id, original_amount, outstanding, status)
      values (v.company_id, v.branch_id, v.supplier_id, 'purchase', v.id, outstanding, outstanding, 'open');
  end if;

  perform public.recalc_purchase(p_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'purchase', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_purchase(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.purchases; ln record; pay record; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.purchases where id=p_id for update;
  if not found then raise exception 'Purchase not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted purchases can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  if exists (select 1 from public.supplier_payment_allocations a join public.supplier_payments sp on sp.id=a.payment_id
             join public.supplier_payables pb on pb.id=a.payable_id
             where pb.purchase_id=p_id and sp.document_status='posted') then
    raise exception 'Void the supplier payments on this purchase first' using errcode='P0001';
  end if;
  if exists (select 1 from public.purchase_returns where purchase_id=p_id and document_status='posted') then
    raise exception 'Void the purchase returns on this purchase first' using errcode='P0001';
  end if;

  for ln in select * from public.purchase_lines where purchase_id=p_id loop
    if ln.track_inventory and ln.quantity>0 then
      perform public.record_stock_movement(v.company_id, v.branch_id, ln.product_id,
        'purchase_return','purchase_void', v.id, v.document_number, 0, ln.quantity, 0, p_user);
    end if;
  end loop;

  if v.inventory_value > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1150'),'debit',0,'credit',v.inventory_value); end if;
  if (v.net_total + v.nonrecoverable_tax - v.inventory_value) > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'6100'),'debit',0,'credit',round(v.net_total+v.nonrecoverable_tax - v.inventory_value,2));
  end if;
  if v.recoverable_tax > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1160'),'debit',0,'credit',v.recoverable_tax); end if;
  for pay in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
             from public.purchase_payments where purchase_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc,'debit',pay.amt,'credit',0);
  end loop;
  if v.outstanding > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',v.outstanding,'credit',0); end if;
  perform public.create_journal(v.company_id, v.branch_id, current_date, 'purchase_void', v.id, v.document_number, 'Void purchase '||v.document_number, p_user, jlines);

  update public.supplier_payables set outstanding=0, status='voided' where purchase_id=p_id;
  update public.purchases set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'purchase', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- POST EXPENSE
-- ---------------------------------------------------------------------------
create or replace function public.post_expense(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.expenses; cat public.expense_categories; pay record; docnum text;
  net numeric(18,2); tax numeric(18,2); rec numeric(18,2); nonrec numeric(18,2);
  paid numeric(18,2); outstanding numeric(18,2); exp_acc uuid; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.expenses where id=p_id for update;
  if not found then raise exception 'Expense not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Expense already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_expense', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  if v.grand_total <= 0 then raise exception 'Expense amount must be greater than zero' using errcode='P0001'; end if;

  select * into cat from public.expense_categories where id=v.expense_category_id;
  exp_acc := coalesce(cat.expense_account_id, public.account_id_by_code(v.company_id,'6100'));

  net := v.net_total; tax := v.tax_total;
  rec := case when v.is_recoverable then tax else 0 end; nonrec := tax - rec;

  select coalesce(sum(amount),0) into paid from public.expense_payments where expense_id=p_id;
  if paid > v.grand_total + 0.001 then raise exception 'Payments exceed the expense total' using errcode='P0001'; end if;
  outstanding := round(v.grand_total - paid, 2);
  if outstanding > 0 and v.supplier_id is null then raise exception 'A credit expense requires a supplier' using errcode='P0001'; end if;

  docnum := public.next_document_number(v.company_id, v.branch_id, 'expense');

  jlines := jlines || jsonb_build_object('account_id', exp_acc,'debit',round(net+nonrec,2),'credit',0,'memo','Expense');
  if rec > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1160'),'debit',rec,'credit',0,'memo','Input VAT'); end if;
  for pay in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
             from public.expense_payments where expense_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc,'debit',0,'credit',pay.amt,'memo','Payment');
  end loop;
  if outstanding > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',0,'credit',outstanding,'memo','Accounts payable'); end if;
  perform public.create_journal(v.company_id, v.branch_id, v.document_date, 'expense', v.id, docnum, 'Expense '||docnum, p_user, jlines);

  update public.expenses set document_status='posted', document_number=docnum,
    recoverable_tax=rec, nonrecoverable_tax=nonrec, posted_by=p_user, posted_at=now() where id=p_id;

  if outstanding > 0 then
    insert into public.supplier_payables(company_id, branch_id, supplier_id, source_type, expense_id, original_amount, outstanding, status)
      values (v.company_id, v.branch_id, v.supplier_id, 'expense', v.id, outstanding, outstanding, 'open');
  end if;

  perform public.recalc_expense(p_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'expense', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_expense(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.expenses; cat public.expense_categories; pay record; exp_acc uuid;
  net numeric(18,2); rec numeric(18,2); nonrec numeric(18,2); jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.expenses where id=p_id for update;
  if not found then raise exception 'Expense not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted expenses can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  if exists (select 1 from public.supplier_payment_allocations a join public.supplier_payments sp on sp.id=a.payment_id
             join public.supplier_payables pb on pb.id=a.payable_id
             where pb.expense_id=p_id and sp.document_status='posted') then
    raise exception 'Void the supplier payments on this expense first' using errcode='P0001';
  end if;

  select * into cat from public.expense_categories where id=v.expense_category_id;
  exp_acc := coalesce(cat.expense_account_id, public.account_id_by_code(v.company_id,'6100'));
  net := v.net_total; rec := v.recoverable_tax; nonrec := v.nonrecoverable_tax;

  jlines := jlines || jsonb_build_object('account_id', exp_acc,'debit',0,'credit',round(net+nonrec,2));
  if rec > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'1160'),'debit',0,'credit',rec); end if;
  for pay in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
             from public.expense_payments where expense_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc,'debit',pay.amt,'credit',0);
  end loop;
  if v.outstanding > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',v.outstanding,'credit',0); end if;
  perform public.create_journal(v.company_id, v.branch_id, current_date, 'expense_void', v.id, v.document_number, 'Void expense '||v.document_number, p_user, jlines);

  update public.supplier_payables set outstanding=0, status='voided' where expense_id=p_id;
  update public.expenses set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'expense', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- SUPPLIER PAYMENT
-- ---------------------------------------------------------------------------
create or replace function public.post_supplier_payment(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.supplier_payments; fund_total numeric(18,2); alloc_total numeric(18,2);
  docnum text; f record; a record; pb public.supplier_payables; jlines jsonb := '[]'::jsonb; v_total numeric(18,2);
begin
  select * into v from public.supplier_payments where id=p_id for update;
  if not found then raise exception 'Payment not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Payment already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_supplier_payment', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.document_date);

  select coalesce(sum(amount),0) into fund_total from public.supplier_payment_funding where payment_id=p_id;
  select coalesce(sum(amount),0) into alloc_total from public.supplier_payment_allocations where payment_id=p_id;
  if fund_total <= 0 then raise exception 'Payment amount must be greater than zero' using errcode='P0001'; end if;
  if round(fund_total,2) <> round(alloc_total,2) then raise exception 'Funding (%.2f) must equal allocations (%.2f)', fund_total, alloc_total using errcode='P0001'; end if;

  -- Validate & lock payables, check for overpayment.
  for a in select * from public.supplier_payment_allocations where payment_id=p_id loop
    select * into pb from public.supplier_payables where id=a.payable_id for update;
    if not found or pb.company_id <> v.company_id or pb.supplier_id <> v.supplier_id then
      raise exception 'Invalid payable in allocation' using errcode='P0001'; end if;
    if a.amount > pb.outstanding + 0.001 then raise exception 'Allocation exceeds outstanding balance' using errcode='P0001'; end if;
  end loop;

  -- Check funds for each funding account.
  for f in select payment_account_id as pa, sum(amount) as amt from public.supplier_payment_funding where payment_id=p_id group by 1 loop
    perform public.assert_sufficient_funds(f.pa, f.amt, v.document_date);
  end loop;

  docnum := public.next_document_number(v.company_id, v.branch_id, 'supplier_payment');
  v_total := round(fund_total,2);

  jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',v_total,'credit',0,'memo','Accounts payable');
  for f in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.supplier_payment_funding where payment_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', f.acc,'debit',0,'credit',f.amt,'memo','Payment');
  end loop;
  perform public.create_journal(v.company_id, v.branch_id, v.document_date, 'supplier_payment', v.id, docnum, 'Supplier payment '||docnum, p_user, jlines);

  update public.supplier_payments set document_status='posted', document_number=docnum, amount=v_total, posted_by=p_user, posted_at=now() where id=p_id;

  -- Recalculate the affected source documents (this updates the payables).
  for a in select distinct pb2.purchase_id, pb2.expense_id from public.supplier_payment_allocations al
           join public.supplier_payables pb2 on pb2.id=al.payable_id where al.payment_id=p_id loop
    if a.purchase_id is not null then perform public.recalc_purchase(a.purchase_id);
    elsif a.expense_id is not null then perform public.recalc_expense(a.expense_id); end if;
  end loop;

  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'supplier_payment', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_supplier_payment(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.supplier_payments; f record; a record; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.supplier_payments where id=p_id for update;
  if not found then raise exception 'Payment not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted payments can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.document_date);

  for f in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.supplier_payment_funding where payment_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', f.acc,'debit',f.amt,'credit',0);
  end loop;
  jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2110'),'debit',0,'credit',v.amount);
  perform public.create_journal(v.company_id, v.branch_id, current_date, 'supplier_payment_void', v.id, v.document_number, 'Void payment '||v.document_number, p_user, jlines);

  update public.supplier_payments set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;

  for a in select distinct pb.purchase_id, pb.expense_id from public.supplier_payment_allocations al
           join public.supplier_payables pb on pb.id=al.payable_id where al.payment_id=p_id loop
    if a.purchase_id is not null then perform public.recalc_purchase(a.purchase_id);
    elsif a.expense_id is not null then perform public.recalc_expense(a.expense_id); end if;
  end loop;

  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'supplier_payment', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- OTHER INCOME
-- ---------------------------------------------------------------------------
create or replace function public.post_other_income(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.other_income_transactions; it public.other_income_types; recv numeric(18,2);
  docnum text; r record; inc_acc uuid; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.other_income_transactions where id=p_id for update;
  if not found then raise exception 'Other income not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_other_income', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  if v.grand_total <= 0 then raise exception 'Amount must be greater than zero' using errcode='P0001'; end if;

  select coalesce(sum(amount),0) into recv from public.other_income_receipts where transaction_id=p_id;
  if round(recv,2) <> round(v.grand_total,2) then raise exception 'Receipts (%.2f) must equal the gross amount (%.2f)', recv, v.grand_total using errcode='P0001'; end if;

  select * into it from public.other_income_types where id=v.income_type_id;
  inc_acc := coalesce(it.income_account_id, public.account_id_by_code(v.company_id,'4200'));
  docnum := public.next_document_number(v.company_id, v.branch_id, 'other_income');

  for r in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.other_income_receipts where transaction_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', r.acc,'debit',r.amt,'credit',0,'memo','Received');
  end loop;
  jlines := jlines || jsonb_build_object('account_id', inc_acc,'debit',0,'credit',v.net_total,'memo','Other income');
  if v.tax_total > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2120'),'debit',0,'credit',v.tax_total,'memo','Output VAT'); end if;
  perform public.create_journal(v.company_id, v.branch_id, v.document_date, 'other_income', v.id, docnum, 'Other income '||docnum, p_user, jlines);

  update public.other_income_transactions set document_status='posted', document_number=docnum, posted_by=p_user, posted_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'other_income', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_other_income(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.other_income_transactions; it public.other_income_types; r record; inc_acc uuid; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.other_income_transactions where id=p_id for update;
  if not found then raise exception 'Not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.document_date);
  select * into it from public.other_income_types where id=v.income_type_id;
  inc_acc := coalesce(it.income_account_id, public.account_id_by_code(v.company_id,'4200'));

  for r in select public.resolve_payment_ledger(v.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.other_income_receipts where transaction_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', r.acc,'debit',0,'credit',r.amt);
  end loop;
  jlines := jlines || jsonb_build_object('account_id', inc_acc,'debit',v.net_total,'credit',0);
  if v.tax_total > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(v.company_id,'2120'),'debit',v.tax_total,'credit',0); end if;
  perform public.create_journal(v.company_id, v.branch_id, current_date, 'other_income_void', v.id, v.document_number, 'Void income '||v.document_number, p_user, jlines);

  update public.other_income_transactions set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'other_income', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- CASH TRANSFER
-- ---------------------------------------------------------------------------
create or replace function public.post_cash_transfer(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.cash_transfers; docnum text; src_acc uuid; dst_acc uuid; fee_acc uuid; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.cash_transfers where id=p_id for update;
  if not found then raise exception 'Transfer not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_cash_transfer', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.transfer_date);
  if v.source_account_id = v.destination_account_id then raise exception 'Source and destination must differ' using errcode='P0001'; end if;

  perform public.assert_sufficient_funds(v.source_account_id, round(v.amount + v.fee, 2), v.transfer_date);

  src_acc := public.resolve_payment_ledger(v.company_id, v.source_account_id);
  dst_acc := public.resolve_payment_ledger(v.company_id, v.destination_account_id);
  fee_acc := coalesce(v.fee_account_id, public.account_id_by_code(v.company_id,'6200'));
  docnum := public.next_document_number(v.company_id, v.source_branch_id, 'cash_transfer');

  jlines := jlines || jsonb_build_object('account_id', dst_acc,'debit',v.amount,'credit',0,'memo','Transfer in');
  if v.fee > 0 then jlines := jlines || jsonb_build_object('account_id', fee_acc,'debit',v.fee,'credit',0,'memo','Transfer charge'); end if;
  jlines := jlines || jsonb_build_object('account_id', src_acc,'debit',0,'credit',round(v.amount+v.fee,2),'memo','Transfer out');
  perform public.create_journal(v.company_id, v.source_branch_id, v.transfer_date, 'cash_transfer', v.id, docnum, 'Cash transfer '||docnum, p_user, jlines);

  update public.cash_transfers set document_status='posted', document_number=docnum, posted_by=p_user, posted_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'cash_transfer', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_cash_transfer(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.cash_transfers; src_acc uuid; dst_acc uuid; fee_acc uuid; jlines jsonb := '[]'::jsonb;
begin
  select * into v from public.cash_transfers where id=p_id for update;
  if not found then raise exception 'Transfer not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.transfer_date);
  -- Voiding takes the amount back out of the destination.
  perform public.assert_sufficient_funds(v.destination_account_id, v.amount, current_date);

  src_acc := public.resolve_payment_ledger(v.company_id, v.source_account_id);
  dst_acc := public.resolve_payment_ledger(v.company_id, v.destination_account_id);
  fee_acc := coalesce(v.fee_account_id, public.account_id_by_code(v.company_id,'6200'));

  jlines := jlines || jsonb_build_object('account_id', src_acc,'debit',round(v.amount+v.fee,2),'credit',0);
  jlines := jlines || jsonb_build_object('account_id', dst_acc,'debit',0,'credit',v.amount);
  if v.fee > 0 then jlines := jlines || jsonb_build_object('account_id', fee_acc,'debit',0,'credit',v.fee); end if;
  perform public.create_journal(v.company_id, v.source_branch_id, current_date, 'cash_transfer_void', v.id, v.document_number, 'Void transfer '||v.document_number, p_user, jlines);

  update public.cash_transfers set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'cash_transfer', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- FINANCIAL OPENING BALANCE
-- ---------------------------------------------------------------------------
create or replace function public.post_financial_opening(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.financial_opening_balances; ln record; docnum text; obe uuid;
  td numeric(18,2):=0; tc numeric(18,2):=0; acc uuid;
begin
  select * into v from public.financial_opening_balances where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if v.document_status <> 'draft' then raise exception 'Already %', v.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_financial_opening', p_id) then return p_id; end if;
  perform public.assert_period_open(v.company_id, v.opening_date);
  if not exists (select 1 from public.financial_opening_balance_lines where opening_id=p_id) then
    raise exception 'Opening has no lines' using errcode='P0001'; end if;

  obe := public.account_id_by_code(v.company_id,'3200');
  docnum := public.next_document_number(v.company_id, null, 'financial_opening_balance');

  for ln in select * from public.financial_opening_balance_lines where opening_id=p_id order by line_no loop
    acc := public.resolve_payment_ledger(v.company_id, ln.payment_account_id);
    if ln.side = 'debit' then
      perform public.create_journal(v.company_id, null, v.opening_date, 'financial_opening_line', ln.id, docnum, 'Opening balance', p_user,
        jsonb_build_array(
          jsonb_build_object('account_id', acc,'debit',ln.amount,'credit',0),
          jsonb_build_object('account_id', obe,'debit',0,'credit',ln.amount)));
      td := td + ln.amount;
    else
      perform public.create_journal(v.company_id, null, v.opening_date, 'financial_opening_line', ln.id, docnum, 'Opening balance', p_user,
        jsonb_build_array(
          jsonb_build_object('account_id', obe,'debit',ln.amount,'credit',0),
          jsonb_build_object('account_id', acc,'debit',0,'credit',ln.amount)));
      tc := tc + ln.amount;
    end if;
  end loop;

  update public.financial_opening_balances set document_status='posted', document_number=docnum,
    total_debit=td, total_credit=tc, posted_by=p_user, posted_at=now() where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (v.company_id, 'financial_opening', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_financial_opening(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v public.financial_opening_balances; ln record; obe uuid; acc uuid;
begin
  select * into v from public.financial_opening_balances where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if v.document_status <> 'posted' then raise exception 'Only posted can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(v.company_id, v.opening_date);
  obe := public.account_id_by_code(v.company_id,'3200');

  for ln in select * from public.financial_opening_balance_lines where opening_id=p_id loop
    acc := public.resolve_payment_ledger(v.company_id, ln.payment_account_id);
    if ln.side = 'debit' then
      perform public.create_journal(v.company_id, null, current_date, 'financial_opening_line_void', ln.id, v.document_number, 'Void opening', p_user,
        jsonb_build_array(jsonb_build_object('account_id', acc,'debit',0,'credit',ln.amount),
                          jsonb_build_object('account_id', obe,'debit',ln.amount,'credit',0)));
    else
      perform public.create_journal(v.company_id, null, current_date, 'financial_opening_line_void', ln.id, v.document_number, 'Void opening', p_user,
        jsonb_build_array(jsonb_build_object('account_id', obe,'debit',0,'credit',ln.amount),
                          jsonb_build_object('account_id', acc,'debit',ln.amount,'credit',0)));
    end if;
  end loop;

  update public.financial_opening_balances set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (v.company_id, 'financial_opening', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;
