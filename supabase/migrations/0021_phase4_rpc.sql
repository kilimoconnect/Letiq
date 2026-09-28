-- =============================================================================
-- Letiq ERP - Migration 0021: Phase 4 posting functions
-- =============================================================================

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- MANUAL JOURNAL
-- ---------------------------------------------------------------------------
create or replace function public.post_manual_journal(
  p_id uuid, p_user uuid, p_idem text, p_allow_control boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.manual_journal_drafts; ln record; docnum text; jlines jsonb := '[]'::jsonb;
  n int := 0; td numeric(18,2) := 0; tc numeric(18,2) := 0; used_control boolean := false;
begin
  select * into d from public.manual_journal_drafts where id = p_id for update;
  if not found then raise exception 'Journal not found' using errcode='P0001'; end if;
  if d.document_status <> 'draft' then raise exception 'Journal already %', d.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_manual_journal', p_id) then return p_id; end if;
  perform public.assert_period_open(d.company_id, d.journal_date);

  for ln in
    select mjl.*, a.allow_posting, a.is_control, a.is_active, a.company_id as acc_company, a.code
    from public.manual_journal_draft_lines mjl
    join public.chart_of_accounts a on a.id = mjl.account_id
    where mjl.draft_id = p_id order by mjl.line_no
  loop
    if ln.acc_company <> d.company_id then raise exception 'Account belongs to another company' using errcode='P0001'; end if;
    if not ln.is_active then raise exception 'Account % is inactive', ln.code using errcode='P0001'; end if;
    if not ln.allow_posting then raise exception 'Cannot post to header account %', ln.code using errcode='P0001'; end if;
    if ln.is_control then
      if not p_allow_control then
        raise exception 'Direct posting to control account % is not allowed; use the operational module or a control adjustment', ln.code using errcode='P0001';
      end if;
      used_control := true;
    end if;
    n := n + 1; td := td + ln.debit; tc := tc + ln.credit;
    jlines := jlines || jsonb_build_object('account_id', ln.account_id, 'debit', ln.debit, 'credit', ln.credit,
      'memo', ln.description, 'branch_id', ln.branch_id, 'customer_id', ln.customer_id, 'supplier_id', ln.supplier_id);
  end loop;

  if n < 2 then raise exception 'A journal needs at least two lines' using errcode='P0001'; end if;
  if round(td,2) <> round(tc,2) then raise exception 'Journal is not balanced' using errcode='P0001'; end if;

  docnum := public.next_document_number(d.company_id, d.branch_id, 'journal_entry');
  declare j_id uuid;
  begin
    j_id := public.create_journal(d.company_id, d.branch_id, d.journal_date, 'manual_journal', d.id, docnum, coalesce(d.description, 'Manual journal'), p_user, jlines);
    update public.manual_journal_drafts set document_status='posted', document_number=docnum, journal_id=j_id,
      total_debit=round(td,2), total_credit=round(tc,2), is_control_adjustment=used_control, posted_by=p_user, posted_at=now()
      where id=p_id;
  end;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, changed_by)
    values (d.company_id, 'manual_journal', p_id, 'draft', 'posted', p_user);
  return p_id;
end; $$;

create or replace function public.void_manual_journal(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.manual_journal_drafts; ln record; jlines jsonb := '[]'::jsonb;
begin
  select * into d from public.manual_journal_drafts where id = p_id for update;
  if not found then raise exception 'Journal not found' using errcode='P0001'; end if;
  if d.document_status <> 'posted' then raise exception 'Only posted journals can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(d.company_id, coalesce(d.reversal_date, current_date));

  for ln in select * from public.journal_lines where journal_id = d.journal_id loop
    jlines := jlines || jsonb_build_object('account_id', ln.account_id, 'debit', ln.credit, 'credit', ln.debit,
      'memo', 'Reversal', 'branch_id', ln.branch_id, 'customer_id', ln.customer_id, 'supplier_id', ln.supplier_id);
  end loop;
  perform public.create_journal(d.company_id, d.branch_id, coalesce(d.reversal_date, current_date),
    'manual_journal_void', d.id, d.document_number, 'Void journal '||d.document_number, p_user, jlines);

  update public.manual_journal_drafts set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  insert into public.transaction_status_history(company_id, source_type, source_id, from_status, to_status, reason, changed_by)
    values (d.company_id, 'manual_journal', p_id, 'posted', 'voided', p_reason, p_user);
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- GENERAL ACCOUNTING OPENING (no direct control-account postings)
-- ---------------------------------------------------------------------------
create or replace function public.post_accounting_opening(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.accounting_opening_balances; ln record; docnum text; jlines jsonb := '[]'::jsonb;
  n int := 0; td numeric(18,2) := 0; tc numeric(18,2) := 0;
begin
  select * into o from public.accounting_opening_balances where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if o.document_status <> 'draft' then raise exception 'Opening already %', o.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_accounting_opening', p_id) then return p_id; end if;
  perform public.assert_period_open(o.company_id, o.opening_date);

  for ln in select l.*, a.allow_posting, a.is_control, a.is_active, a.company_id as acc_company, a.code
            from public.accounting_opening_balance_lines l join public.chart_of_accounts a on a.id=l.account_id
            where l.opening_id=p_id order by l.line_no loop
    if ln.acc_company <> o.company_id then raise exception 'Account belongs to another company' using errcode='P0001'; end if;
    if not ln.is_active then raise exception 'Account % is inactive', ln.code using errcode='P0001'; end if;
    if not ln.allow_posting then raise exception 'Cannot post to header account %', ln.code using errcode='P0001'; end if;
    if ln.is_control then raise exception 'General openings cannot post directly to control account % — use the subledger opening workflow', ln.code using errcode='P0001'; end if;
    n := n+1; td := td + ln.debit; tc := tc + ln.credit;
    jlines := jlines || jsonb_build_object('account_id', ln.account_id, 'debit', ln.debit, 'credit', ln.credit, 'memo', ln.description, 'branch_id', ln.branch_id);
  end loop;
  if n < 2 then raise exception 'An opening needs at least two lines' using errcode='P0001'; end if;
  if round(td,2) <> round(tc,2) then raise exception 'Opening is not balanced' using errcode='P0001'; end if;

  docnum := public.next_document_number(o.company_id, null, 'journal_entry');
  perform public.create_journal(o.company_id, null, o.opening_date, 'accounting_opening', o.id, docnum, 'General opening balance', p_user, jlines);
  update public.accounting_opening_balances set document_status='posted', document_number=docnum, total_debit=round(td,2), total_credit=round(tc,2), posted_by=p_user, posted_at=now() where id=p_id;
  return p_id;
end; $$;

create or replace function public.void_accounting_opening(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.accounting_opening_balances; ln record; jlines jsonb := '[]'::jsonb; jid uuid;
begin
  select * into o from public.accounting_opening_balances where id=p_id for update;
  if not found or o.document_status <> 'posted' then raise exception 'Only posted openings can be voided' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  perform public.assert_period_open(o.company_id, current_date);
  select id into jid from public.journal_entries where source_type='accounting_opening' and source_id=p_id;
  for ln in select * from public.journal_lines where journal_id=jid loop
    jlines := jlines || jsonb_build_object('account_id', ln.account_id, 'debit', ln.credit, 'credit', ln.debit, 'branch_id', ln.branch_id);
  end loop;
  perform public.create_journal(o.company_id, null, current_date, 'accounting_opening_void', o.id, o.document_number, 'Void opening', p_user, jlines);
  update public.accounting_opening_balances set document_status='voided', voided_by=p_user, voided_at=now(), void_reason=p_reason where id=p_id;
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- CUSTOMER / SUPPLIER OPENING BALANCES
-- ---------------------------------------------------------------------------
create or replace function public.post_customer_opening(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.customer_opening_balances; docnum text; jid uuid;
begin
  select * into o from public.customer_opening_balances where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if o.document_status <> 'draft' then raise exception 'Already %', o.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_customer_opening', p_id) then return p_id; end if;
  perform public.assert_period_open(o.company_id, o.invoice_date);
  docnum := public.next_document_number(o.company_id, null, 'journal_entry');
  jid := public.create_journal(o.company_id, o.branch_id, o.invoice_date, 'customer_opening', o.id, docnum,
    'Customer opening balance', p_user, jsonb_build_array(
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'1140'), 'debit', o.amount, 'credit', 0, 'customer_id', o.customer_id),
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'3200'), 'debit', 0, 'credit', o.amount)));
  update public.customer_opening_balances set document_status='posted', document_number=docnum, outstanding=o.amount, journal_id=jid, posted_by=p_user, posted_at=now() where id=p_id;
  return p_id;
end; $$;

create or replace function public.post_supplier_opening(p_id uuid, p_user uuid, p_idem text)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.supplier_opening_balances; docnum text; jid uuid;
begin
  select * into o from public.supplier_opening_balances where id=p_id for update;
  if not found then raise exception 'Opening not found' using errcode='P0001'; end if;
  if o.document_status <> 'draft' then raise exception 'Already %', o.document_status using errcode='P0001'; end if;
  if not public.claim_idempotency(p_idem, 'post_supplier_opening', p_id) then return p_id; end if;
  perform public.assert_period_open(o.company_id, o.document_date);
  docnum := public.next_document_number(o.company_id, null, 'journal_entry');
  jid := public.create_journal(o.company_id, o.branch_id, o.document_date, 'supplier_opening', o.id, docnum,
    'Supplier opening balance', p_user, jsonb_build_array(
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'3200'), 'debit', o.amount, 'credit', 0),
      jsonb_build_object('account_id', public.account_id_by_code(o.company_id,'2110'), 'debit', 0, 'credit', o.amount, 'supplier_id', o.supplier_id)));
  update public.supplier_opening_balances set document_status='posted', document_number=docnum, outstanding=o.amount, journal_id=jid, posted_by=p_user, posted_at=now() where id=p_id;
  return p_id;
end; $$;

-- ---------------------------------------------------------------------------
-- BANK RECONCILIATION ADJUSTMENT (posts a journal)
-- ---------------------------------------------------------------------------
create or replace function public.post_bank_adjustment(
  p_rec uuid, p_line uuid, p_account uuid, p_direction text, p_amount numeric,
  p_description text, p_reference text, p_user uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare rec public.bank_reconciliations; pa_ledger uuid; docnum text; jid uuid; adj_id uuid; jlines jsonb;
begin
  select * into rec from public.bank_reconciliations where id=p_rec for update;
  if not found then raise exception 'Reconciliation not found' using errcode='P0001'; end if;
  if rec.status = 'finalized' then raise exception 'Reconciliation is finalized' using errcode='P0001'; end if;
  if coalesce(p_description,'')='' then raise exception 'A description is required' using errcode='P0001'; end if;
  if not (p_amount > 0) then raise exception 'Amount must be greater than zero' using errcode='P0001'; end if;
  perform public.assert_period_open(rec.company_id, rec.statement_end);

  pa_ledger := public.resolve_payment_ledger(rec.company_id, rec.payment_account_id);
  docnum := public.next_document_number(rec.company_id, null, 'journal_entry');
  if p_direction = 'in' then
    jlines := jsonb_build_array(
      jsonb_build_object('account_id', pa_ledger, 'debit', p_amount, 'credit', 0),
      jsonb_build_object('account_id', p_account, 'debit', 0, 'credit', p_amount));
  else
    jlines := jsonb_build_array(
      jsonb_build_object('account_id', p_account, 'debit', p_amount, 'credit', 0),
      jsonb_build_object('account_id', pa_ledger, 'debit', 0, 'credit', p_amount));
  end if;
  jid := public.create_journal(rec.company_id, null, rec.statement_end, 'bank_adjustment', gen_random_uuid(), docnum, coalesce(p_description,'Bank adjustment'), p_user, jlines);

  insert into public.bank_reconciliation_adjustments(reconciliation_id, statement_line_id, account_id, direction, amount, description, reference, journal_id, created_by)
    values (p_rec, p_line, p_account, p_direction, p_amount, p_description, p_reference, jid, p_user)
    returning id into adj_id;
  if p_line is not null then
    update public.bank_statement_lines set status='adjusted', matched_amount = greatest(money_in, money_out) where id=p_line;
  end if;
  update public.bank_reconciliations set status='in_progress' where id=p_rec and status='draft';
  return adj_id;
end; $$;

create or replace function public.void_bank_adjustment(p_id uuid, p_user uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare adj public.bank_reconciliation_adjustments; rec public.bank_reconciliations; ln record; jlines jsonb := '[]'::jsonb;
begin
  select * into adj from public.bank_reconciliation_adjustments where id=p_id for update;
  if not found or adj.document_status <> 'posted' then raise exception 'Adjustment not found' using errcode='P0001'; end if;
  if coalesce(p_reason,'')='' then raise exception 'A reason is required' using errcode='P0001'; end if;
  select * into rec from public.bank_reconciliations where id=adj.reconciliation_id;
  if rec.status='finalized' then raise exception 'Reconciliation is finalized' using errcode='P0001'; end if;
  perform public.assert_period_open(rec.company_id, current_date);
  for ln in select * from public.journal_lines where journal_id=adj.journal_id loop
    jlines := jlines || jsonb_build_object('account_id', ln.account_id, 'debit', ln.credit, 'credit', ln.debit);
  end loop;
  perform public.create_journal(rec.company_id, null, current_date, 'bank_adjustment_void', p_id, null, 'Void bank adjustment', p_user, jlines);
  update public.bank_reconciliation_adjustments set document_status='voided', voided_by=p_user, void_reason=p_reason where id=p_id;
  return p_id;
end; $$;

-- grants
do $$
declare fn text;
begin
  foreach fn in array array[
    'post_manual_journal(uuid,uuid,text,boolean)','void_manual_journal(uuid,uuid,text)',
    'post_accounting_opening(uuid,uuid,text)','void_accounting_opening(uuid,uuid,text)',
    'post_customer_opening(uuid,uuid,text)','post_supplier_opening(uuid,uuid,text)',
    'post_bank_adjustment(uuid,uuid,uuid,text,numeric,text,text,uuid)','void_bank_adjustment(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public', fn);
    execute format('revoke all on function public.%s from anon', fn);
    execute format('revoke all on function public.%s from authenticated', fn);
    execute format('grant execute on function public.%s to service_role', fn);
  end loop;
end $$;
