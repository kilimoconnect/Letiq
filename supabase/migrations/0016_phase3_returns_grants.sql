-- =============================================================================
-- Letiq ERP - Migration 0016: Purchase returns + Phase 3 grants
-- =============================================================================

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- POST PURCHASE RETURN
--   Inventory removed at current weighted-average (carrying) cost.
--   Supplier credit basis uses the original purchase price/tax snapshot.
--   The difference posts to Purchase Price Variance so avg cost is never
--   distorted by simply subtracting the original cost.
-- ---------------------------------------------------------------------------
create or replace function public.post_purchase_return(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.purchase_returns; ln record; docnum text; prior numeric(18,4);
  v_net numeric(18,2):=0; v_tax numeric(18,2):=0; v_total numeric(18,2):=0;
  v_recvat numeric(18,2):=0; v_cc numeric(18,2):=0; cost numeric(18,2);
  refund numeric(18,2); remaining numeric(18,2); payable_reduction numeric(18,2):=0;
  credit_amount numeric(18,2):=0; settlement_gross numeric(18,2); ppv numeric(18,2);
  jlines jsonb := '[]'::jsonb; s record;
begin
  select * into r from public.purchase_returns where id=p_id for update;
  if not found then raise exception 'Return not found' using errcode='P0001'; end if;
  if r.document_status <> 'draft' then raise exception 'Return already %', r.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_purchase_return', p_id) then return p_id; end if;
  if coalesce(r.reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(r.company_id, r.document_date);

  docnum := public.next_document_number(r.company_id, r.branch_id, 'purchase_return');

  for ln in select rl.*, pl.quantity as bought_qty from public.purchase_return_lines rl
            join public.purchase_lines pl on pl.id=rl.purchase_line_id
            where rl.return_id=p_id order by rl.line_no loop
    select coalesce(sum(prl.quantity),0) into prior
      from public.purchase_return_lines prl join public.purchase_returns pr on pr.id=prl.return_id
      where prl.purchase_line_id=ln.purchase_line_id and pr.document_status='posted';
    if ln.quantity + prior > ln.bought_qty + 0.0001 then
      raise exception 'Return exceeds purchased quantity for a line' using errcode='P0001';
    end if;

    v_net := v_net + ln.net_amount; v_tax := v_tax + ln.tax_amount; v_total := v_total + ln.line_total;
    if ln.is_recoverable then v_recvat := v_recvat + ln.tax_amount; end if;

    if ln.track_inventory then
      cost := public.record_stock_movement(r.company_id, r.branch_id, ln.product_id,
        'purchase_return','purchase_return', r.id, docnum, 0, ln.quantity, 0, p_user);
      v_cc := v_cc + cost;
      update public.purchase_return_lines set inventory_cost = cost where id=ln.id;
    end if;
  end loop;

  settlement_gross := round(v_total, 2);
  select coalesce(sum(amount),0) into refund from public.purchase_return_settlements where return_id=p_id;
  if refund > settlement_gross + 0.001 then raise exception 'Refund exceeds the return value' using errcode='P0001'; end if;
  remaining := round(settlement_gross - refund, 2);
  if r.settlement_method = 'supplier_credit' then credit_amount := remaining;
  else payable_reduction := remaining; end if;
  ppv := round(settlement_gross - v_recvat - v_cc, 2);

  -- Journal
  if payable_reduction > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'2110'),'debit',payable_reduction,'credit',0,'memo','Reduce payable'); end if;
  if credit_amount > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1170'),'debit',credit_amount,'credit',0,'memo','Supplier credit'); end if;
  for s in select public.resolve_payment_ledger(r.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.purchase_return_settlements where return_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', s.acc,'debit',s.amt,'credit',0,'memo','Refund received');
  end loop;
  if v_recvat > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1160'),'debit',0,'credit',v_recvat,'memo','Input VAT reversal'); end if;
  if v_cc > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1150'),'debit',0,'credit',v_cc,'memo','Inventory'); end if;
  if ppv > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5300'),'debit',0,'credit',ppv,'memo','Purchase price variance');
  elsif ppv < 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5300'),'debit',-ppv,'credit',0,'memo','Purchase price variance'); end if;
  perform public.create_journal(r.company_id, r.branch_id, r.document_date, 'purchase_return', r.id, docnum, 'Purchase return '||docnum, p_user, jlines);

  update public.purchase_returns set document_status='posted', document_number=docnum,
    net_total=v_net, tax_total=v_tax, total=v_total, inventory_cost_removed=v_cc,
    refund_amount=refund, payable_reduction=payable_reduction, credit_amount=credit_amount,
    price_variance=ppv, posted_by=p_user, posted_at=now() where id=p_id;

  if credit_amount > 0 then
    insert into public.supplier_credits(company_id, supplier_id, source_return_id, amount, remaining, status)
      values (r.company_id, r.supplier_id, r.id, credit_amount, credit_amount, 'open');
  end if;

  perform public.recalc_purchase(r.purchase_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (r.company_id, 'purchase_return', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_purchase_return(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.purchase_returns; ln record; jlines jsonb := '[]'::jsonb; s record; ppv numeric(18,2);
begin
  select * into r from public.purchase_returns where id=p_id for update;
  if not found then raise exception 'Return not found' using errcode='P0001'; end if;
  if r.document_status <> 'posted' then raise exception 'Only posted returns can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(r.company_id, r.document_date);
  if exists (select 1 from public.supplier_credits where source_return_id=p_id and status='used') then
    raise exception 'A supplier credit from this return has been used; reverse it first' using errcode='P0001';
  end if;

  -- Restore stock at the cost that was removed.
  for ln in select * from public.purchase_return_lines where return_id=p_id loop
    if ln.track_inventory and ln.quantity>0 then
      perform public.record_stock_movement(r.company_id, r.branch_id, ln.product_id,
        'purchase','purchase_return_void', r.id, r.document_number, ln.quantity, 0,
        case when ln.quantity>0 then round(ln.inventory_cost/ln.quantity,4) else 0 end, p_user);
    end if;
  end loop;

  ppv := r.price_variance;
  if r.payable_reduction > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'2110'),'debit',0,'credit',r.payable_reduction); end if;
  if r.credit_amount > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1170'),'debit',0,'credit',r.credit_amount); end if;
  for s in select public.resolve_payment_ledger(r.company_id, payment_account_id) as acc, sum(amount) as amt
           from public.purchase_return_settlements where return_id=p_id group by 1 loop
    jlines := jlines || jsonb_build_object('account_id', s.acc,'debit',0,'credit',s.amt);
  end loop;
  if r.tax_total > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1160'),'debit',(select coalesce(sum(tax_amount),0) from public.purchase_return_lines where return_id=p_id and is_recoverable),'credit',0); end if;
  if r.inventory_cost_removed > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'1150'),'debit',r.inventory_cost_removed,'credit',0); end if;
  if ppv > 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5300'),'debit',ppv,'credit',0);
  elsif ppv < 0 then jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(r.company_id,'5300'),'debit',0,'credit',-ppv); end if;
  perform public.create_journal(r.company_id, r.branch_id, current_date, 'purchase_return_void', r.id, r.document_number, 'Void return '||r.document_number, p_user, jlines);

  update public.supplier_credits set status='voided', remaining=0 where source_return_id=p_id;
  update public.purchase_returns set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  perform public.recalc_purchase(r.purchase_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (r.company_id, 'purchase_return', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Lock down execution: service_role only.
-- ---------------------------------------------------------------------------
do $$
declare fn text;
begin
  foreach fn in array array[
    'norm_invoice(text)',
    'recalc_purchase(uuid)','recalc_expense(uuid)',
    'post_purchase(uuid,uuid,text)','void_purchase(uuid,uuid,text)',
    'post_expense(uuid,uuid,text)','void_expense(uuid,uuid,text)',
    'post_supplier_payment(uuid,uuid,text)','void_supplier_payment(uuid,uuid,text)',
    'post_other_income(uuid,uuid,text)','void_other_income(uuid,uuid,text)',
    'post_cash_transfer(uuid,uuid,text)','void_cash_transfer(uuid,uuid,text)',
    'post_financial_opening(uuid,uuid,text)','void_financial_opening(uuid,uuid,text)',
    'post_purchase_return(uuid,uuid,text)','void_purchase_return(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public', fn);
    execute format('revoke all on function public.%s from anon', fn);
    execute format('revoke all on function public.%s from authenticated', fn);
    execute format('grant execute on function public.%s to service_role', fn);
  end loop;
end $$;
