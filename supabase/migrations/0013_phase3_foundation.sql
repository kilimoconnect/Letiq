-- =============================================================================
-- Letiq ERP - Migration 0013: Phase 3 foundation
--   - recoverable-VAT flag on tax codes
--   - payment-account overdraft settings
--   - a dedicated ledger account per payment account (so per-account balances
--     and ledgers derive cleanly from posted journal lines)
--   - Purchase Returns / Purchase Price Variance / Supplier Credits accounts
--   - supplier-payment & financial-opening document sequences
--   - payment-account balance + funds helpers
-- =============================================================================

set check_function_bodies = off;

-- Recoverable input VAT flag (default true = standard recoverable VAT).
alter table public.tax_codes add column if not exists is_recoverable boolean not null default true;

-- Overdraft settings on payment accounts (Owner-configured; audited in app).
alter table public.payment_accounts add column if not exists allow_negative boolean not null default false;
alter table public.payment_accounts add column if not exists overdraft_limit numeric(18,2) not null default 0;
alter table public.payment_accounts add column if not exists overdraft_start date;
alter table public.payment_accounts add column if not exists overdraft_end date;
alter table public.payment_accounts drop constraint if exists payment_accounts_overdraft_nonneg;
alter table public.payment_accounts add constraint payment_accounts_overdraft_nonneg check (overdraft_limit >= 0);

-- ---------------------------------------------------------------------------
-- Extra protected accounts + per-account ledgers, per company (idempotent).
-- ---------------------------------------------------------------------------
do $$
declare
  c record; cur_assets uuid; cos uuid; bank uuid; momo uuid;
  a_nmb uuid; a_crdb uuid; a_mpesa uuid; a_mix uuid;
begin
  for c in select id from public.companies loop
    select id into cur_assets from public.chart_of_accounts where company_id=c.id and code='1100';
    select id into cos from public.chart_of_accounts where company_id=c.id and code='5000';
    select id into bank from public.chart_of_accounts where company_id=c.id and code='1120';
    select id into momo from public.chart_of_accounts where company_id=c.id and code='1130';

    insert into public.chart_of_accounts(company_id, code, name, account_type, parent_id, normal_balance, allow_posting, is_system, is_active) values
      (c.id, '1170', 'Supplier Credits', 'asset', cur_assets, 'debit', true, true, true),
      (c.id, '5200', 'Purchase Returns', 'cost_of_sales', cos, 'credit', true, true, true),
      (c.id, '5300', 'Purchase Price Variance', 'cost_of_sales', cos, 'debit', true, true, true),
      (c.id, '1121', 'NMB Bank', 'asset', bank, 'debit', true, true, true),
      (c.id, '1122', 'CRDB Bank', 'asset', bank, 'debit', true, true, true),
      (c.id, '1131', 'M-Pesa', 'asset', momo, 'debit', true, true, true),
      (c.id, '1132', 'MIX', 'asset', momo, 'debit', true, true, true)
    on conflict (company_id, code) do nothing;

    -- Repoint the seeded payment accounts to their own ledger accounts so each
    -- has an isolated balance and ledger.
    select id into a_nmb from public.chart_of_accounts where company_id=c.id and code='1121';
    select id into a_crdb from public.chart_of_accounts where company_id=c.id and code='1122';
    select id into a_mpesa from public.chart_of_accounts where company_id=c.id and code='1131';
    select id into a_mix from public.chart_of_accounts where company_id=c.id and code='1132';

    update public.payment_accounts set ledger_account_id = a_nmb where company_id=c.id and code='NMB';
    update public.payment_accounts set ledger_account_id = a_crdb where company_id=c.id and code='CRDB';
    update public.payment_accounts set ledger_account_id = a_mpesa where company_id=c.id and code='MPESA';
    update public.payment_accounts set ledger_account_id = a_mix where company_id=c.id and code='MIX';

    -- Document sequences new in Phase 3.
    if not exists (select 1 from public.document_sequences where company_id=c.id and document_type='supplier_payment' and branch_id is null) then
      insert into public.document_sequences(company_id, document_type, prefix, current_number, number_length, reset_frequency)
        values (c.id, 'supplier_payment', 'SPY', 0, 5, 'never');
    end if;
    if not exists (select 1 from public.document_sequences where company_id=c.id and document_type='financial_opening_balance' and branch_id is null) then
      insert into public.document_sequences(company_id, document_type, prefix, current_number, number_length, reset_frequency)
        values (c.id, 'financial_opening_balance', 'FOB', 0, 5, 'never');
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Payment-account balance = sum(debit - credit) over its ledger account's
-- posted journal lines (asset normal debit => positive = funds available).
-- ---------------------------------------------------------------------------
create or replace function public.payment_account_balance(p_pa uuid)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare acc uuid; bal numeric(18,2);
begin
  select ledger_account_id into acc from public.payment_accounts where id = p_pa;
  if acc is null then return 0; end if;
  select coalesce(sum(l.debit - l.credit), 0) into bal
    from public.journal_lines l where l.account_id = acc;
  return coalesce(bal, 0);
end; $$;

-- Effective overdraft limit for an account on a date (0 unless configured).
create or replace function public.overdraft_limit_on(p_pa uuid, p_date date)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare pa public.payment_accounts;
begin
  select * into pa from public.payment_accounts where id = p_pa;
  if pa.allow_negative
     and (pa.overdraft_start is null or p_date >= pa.overdraft_start)
     and (pa.overdraft_end is null or p_date <= pa.overdraft_end)
  then return pa.overdraft_limit; else return 0; end if;
end; $$;

-- Raise if an outflow would push an account below its allowed (overdraft) floor.
create or replace function public.assert_sufficient_funds(p_pa uuid, p_outflow numeric, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
declare bal numeric(18,2); lim numeric(18,2);
begin
  if coalesce(p_outflow,0) <= 0 then return; end if;
  bal := public.payment_account_balance(p_pa);
  lim := public.overdraft_limit_on(p_pa, p_date);
  if (bal - p_outflow) < -lim - 0.001 then
    raise exception 'Insufficient funds in the payment account (balance %, needed %, overdraft %)', bal, p_outflow, lim
      using errcode = 'P0001';
  end if;
end; $$;

revoke all on function public.payment_account_balance(uuid) from public, anon, authenticated;
grant execute on function public.payment_account_balance(uuid) to service_role;
revoke all on function public.overdraft_limit_on(uuid,date) from public, anon, authenticated;
grant execute on function public.overdraft_limit_on(uuid,date) to service_role;
revoke all on function public.assert_sufficient_funds(uuid,numeric,date) from public, anon, authenticated;
grant execute on function public.assert_sufficient_funds(uuid,numeric,date) to service_role;
