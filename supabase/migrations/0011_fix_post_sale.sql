-- =============================================================================
-- Letiq ERP - Migration 0011: fix post_sale variable/column name collision
-- =============================================================================
-- The previous post_sale used local variables named identically to sales
-- columns (subtotal, net_total, tax_total, cogs_total), which made the final
-- UPDATE ambiguous. Renamed the locals to v_* and re-created the function.

set check_function_bodies = off;

create or replace function public.post_sale(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  s public.sales; ln record; pay record; docnum text;
  v_subtotal numeric(18,2):=0; v_disc numeric(18,2):=0; v_net numeric(18,2):=0;
  v_tax numeric(18,2):=0; v_grand numeric(18,2):=0; v_cogs numeric(18,2):=0;
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
    v_subtotal := v_subtotal + round(ln.quantity * ln.unit_price, 2);
    v_disc := v_disc + ln.discount;
    v_net := v_net + net;
    v_tax := v_tax + tax;
    v_grand := v_grand + ltotal;

    linecogs := 0;
    if ln.track_inventory then
      linecogs := public.record_stock_movement(s.company_id, s.branch_id, ln.product_id,
        'sale','sale', s.id, docnum, 0, ln.quantity, 0, p_user);
      v_cogs := v_cogs + linecogs;
    end if;
    update public.sale_lines set net_amount=net, tax_amount=tax, line_total=ltotal,
      unit_cost = case when ln.quantity>0 then round(linecogs/ln.quantity,4) else 0 end, cogs=linecogs
      where id=ln.id;
  end loop;

  select coalesce(sum(amount),0) into paid from public.sale_payments where sale_id=p_id;
  if paid > v_grand + 0.001 then raise exception 'Payments exceed the sale total' using errcode='P0001'; end if;
  outstanding := round(v_grand - paid, 2);
  if outstanding > 0 and s.customer_id is null then
    raise exception 'A credit balance requires a customer' using errcode='P0001';
  end if;

  for pay in
    select public.resolve_payment_ledger(s.company_id, payment_account_id) as acc, sum(amount) as amt
    from public.sale_payments where sale_id=p_id group by 1
  loop
    jlines := jlines || jsonb_build_object('account_id', pay.acc, 'debit', pay.amt, 'credit', 0, 'memo','Payment received');
  end loop;
  if outstanding > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1140'),'debit',outstanding,'credit',0,'memo','Accounts receivable');
  end if;
  if v_net > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'4100'),'debit',0,'credit',v_net,'memo','Sales revenue');
  end if;
  if v_tax > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'2120'),'debit',0,'credit',v_tax,'memo','Output VAT');
  end if;
  if v_cogs > 0 then
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'5100'),'debit',v_cogs,'credit',0,'memo','Cost of goods sold');
    jlines := jlines || jsonb_build_object('account_id', public.account_id_by_code(s.company_id,'1150'),'debit',0,'credit',v_cogs,'memo','Inventory');
  end if;

  perform public.create_journal(s.company_id, s.branch_id, s.document_date, 'sale', s.id, docnum,
    'Sale '||docnum, p_user, jlines);

  update public.sales set document_status='posted', document_number=docnum,
    subtotal=v_subtotal, discount_total=v_disc, net_total=v_net, tax_total=v_tax,
    grand_total=v_grand, cogs_total=v_cogs, posted_by=p_user, posted_at=now() where id=p_id;

  perform public.recalc_sale(p_id);
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (s.company_id, 'sale', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

revoke all on function public.post_sale(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.post_sale(uuid,uuid,text) to service_role;
