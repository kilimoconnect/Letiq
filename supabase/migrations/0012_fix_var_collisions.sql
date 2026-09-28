-- =============================================================================
-- Letiq ERP - Migration 0012: fix remaining variable/column name collisions
-- =============================================================================
-- recalc_sale (outstanding) and post_sales_return (net_total/tax_total/total/
-- cogs_restored) declared locals with the same names as the columns they
-- update, making the UPDATEs ambiguous. Renamed the locals to v_*.

set check_function_bodies = off;

create or replace function public.recalc_sale(p_sale uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  s public.sales; init_paid numeric(18,2); alloc numeric(18,2);
  ret_total numeric(18,2); ret_recv numeric(18,2); paid numeric(18,2);
  v_out numeric(18,2); v_status text;
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
  v_out := round(s.grand_total - paid - ret_recv, 2);
  if v_out < 0 then v_out := 0; end if;

  if ret_total >= s.grand_total and s.grand_total > 0 then v_status := 'refunded';
  elsif ret_total > 0 then v_status := 'partially_refunded';
  elsif paid <= 0 then v_status := 'unpaid';
  elsif paid < s.grand_total then v_status := 'partially_paid';
  else v_status := 'paid';
  end if;

  update public.sales set amount_paid = paid, outstanding = v_out, payment_status = v_status
    where id = p_sale;
end; $$;

create or replace function public.post_sales_return(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.sales_returns; ln record; docnum text;
  v_net numeric(18,2):=0; v_tax numeric(18,2):=0; v_total numeric(18,2):=0;
  v_cogs numeric(18,2):=0; refund numeric(18,2); recv_reduction numeric(18,2);
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
    select coalesce(sum(prl.quantity),0) into prior
      from public.sales_return_lines prl
      join public.sales_returns pr on pr.id = prl.return_id
      where prl.sale_line_id = ln.sale_line_id and pr.document_status='posted';
    if ln.quantity + prior > ln.sold_qty + 0.0001 then
      raise exception 'Return exceeds sold quantity for a line' using errcode='P0001';
    end if;

    v_net := v_net + ln.net_amount;
    v_tax := v_tax + ln.tax_amount;
    v_total := v_total + ln.line_total;

    if ln.track_inventory then
      if ln.condition = 'saleable' then
        perform public.record_stock_movement(r.company_id, r.branch_id, ln.product_id,
          'sales_return','sales_return', r.id, docnum, ln.quantity, 0, ln.unit_cost, p_user);
        v_cogs := v_cogs + round(ln.quantity * ln.unit_cost, 2);
        update public.sales_return_lines set cogs_reversal = round(ln.quantity * ln.unit_cost,2) where id=ln.id;
      else
        update public.sales_return_lines set cogs_reversal = 0 where id=ln.id;
      end if;
    end if;
  end loop;

  select coalesce(sum(amount),0) into refund from public.sales_return_refunds where return_id=p_id;
  if refund > v_total + 0.001 then raise exception 'Refund exceeds return value' using errcode='P0001'; end if;
  recv_reduction := round(v_total - refund, 2);
  if recv_reduction < 0 then recv_reduction := 0; end if;

  if v_net > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'4900'),'debit',v_net,'credit',0,'memo','Sales returns');
  end if;
  if v_tax > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'2120'),'debit',v_tax,'credit',0,'memo','Output VAT reversal');
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
  if v_cogs > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1150'),'debit',v_cogs,'credit',0,'memo','Inventory restored');
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5100'),'debit',0,'credit',v_cogs,'memo','COGS reversed');
  end if;
  perform public.create_journal(r.company_id, r.branch_id, r.document_date, 'sales_return', r.id, docnum,
    'Sales return '||docnum, p_user, jlines);

  update public.sales_returns set document_status='posted', document_number=docnum,
    net_total=v_net, tax_total=v_tax, total=v_total, refund_amount=refund,
    receivable_reduction=recv_reduction, cogs_restored=v_cogs, posted_by=p_user, posted_at=now()
    where id=p_id;

  perform public.recalc_sale(r.sale_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (r.company_id, 'sales_return', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

revoke all on function public.recalc_sale(uuid) from public, anon, authenticated;
grant execute on function public.recalc_sale(uuid) to service_role;
revoke all on function public.post_sales_return(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.post_sales_return(uuid,uuid,text) to service_role;
