-- =============================================================================
-- Letiq ERP - Migration 0020: Phase 4 reporting functions (journal-driven)
-- =============================================================================
-- All financial reports are built on these. net = debit - credit; a report
-- presents net>0 as a debit balance and net<0 as a credit balance. Reversal
-- journals are ordinary journals, so they are included by date automatically.

set check_function_bodies = off;

-- Trial balance / P&L / Balance Sheet source. One row per account.
create or replace function public.report_trial_balance(
  p_company uuid, p_start date, p_end date
)
returns table(
  account_id uuid, code text, name text, account_type text, normal_balance text,
  parent_id uuid, allow_posting boolean, cashflow_class text,
  opening_net numeric, period_debit numeric, period_credit numeric, closing_net numeric
)
language sql stable security definer set search_path = public as $$
  select a.id, a.code, a.name, a.account_type, a.normal_balance, a.parent_id, a.allow_posting, a.cashflow_class,
    coalesce(sum(case when je.entry_date < p_start then jl.debit - jl.credit else 0 end), 0),
    coalesce(sum(case when je.entry_date between p_start and p_end then jl.debit else 0 end), 0),
    coalesce(sum(case when je.entry_date between p_start and p_end then jl.credit else 0 end), 0),
    coalesce(sum(case when je.entry_date <= p_end then jl.debit - jl.credit else 0 end), 0)
  from public.chart_of_accounts a
  left join public.journal_lines jl on jl.account_id = a.id
  left join public.journal_entries je on je.id = jl.journal_id
  where a.company_id = p_company
  group by a.id, a.code, a.name, a.account_type, a.normal_balance, a.parent_id, a.allow_posting, a.cashflow_class
  order by a.code;
$$;

-- Balance of a single account as of a date (net debit - credit).
create or replace function public.report_account_balance(
  p_company uuid, p_account uuid, p_asof date
)
returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(jl.debit - jl.credit), 0)
  from public.journal_lines jl
  join public.journal_entries je on je.id = jl.journal_id
  where je.company_id = p_company and jl.account_id = p_account and je.entry_date <= p_asof;
$$;

-- General-ledger lines for one account within a range (running balance in app).
create or replace function public.report_gl_lines(
  p_company uuid, p_account uuid, p_start date, p_end date
)
returns table(
  journal_id uuid, entry_date date, created_at timestamptz, source_type text,
  source_id uuid, source_number text, memo text, branch_id uuid, debit numeric, credit numeric
)
language sql stable security definer set search_path = public as $$
  select jl.journal_id, je.entry_date, je.created_at, je.source_type, je.source_id, je.source_number,
    coalesce(jl.memo, je.memo), coalesce(jl.branch_id, je.branch_id), jl.debit, jl.credit
  from public.journal_lines jl
  join public.journal_entries je on je.id = jl.journal_id
  where je.company_id = p_company and jl.account_id = p_account
    and je.entry_date between p_start and p_end
  order by je.entry_date, je.created_at;
$$;

-- Cash-flow buckets: net movement on cash/bank/mobile accounts, grouped by the
-- source_type of each journal (transfers/openings excluded from company totals).
create or replace function public.report_cash_flow(
  p_company uuid, p_start date, p_end date
)
returns table(source_type text, opening numeric, movement numeric)
language sql stable security definer set search_path = public as $$
  with cash_accounts as (
    select id from public.chart_of_accounts
    where company_id = p_company and code in ('1110','1120','1121','1122','1130','1131','1132')
  )
  select je.source_type,
    coalesce(sum(case when je.entry_date < p_start then jl.debit - jl.credit else 0 end),0) as opening,
    coalesce(sum(case when je.entry_date between p_start and p_end then jl.debit - jl.credit else 0 end),0) as movement
  from public.journal_lines jl
  join public.journal_entries je on je.id = jl.journal_id
  where je.company_id = p_company and jl.account_id in (select id from cash_accounts)
  group by je.source_type;
$$;

revoke all on function public.report_trial_balance(uuid,date,date) from public, anon, authenticated;
revoke all on function public.report_account_balance(uuid,uuid,date) from public, anon, authenticated;
revoke all on function public.report_gl_lines(uuid,uuid,date,date) from public, anon, authenticated;
revoke all on function public.report_cash_flow(uuid,date,date) from public, anon, authenticated;
grant execute on function public.report_trial_balance(uuid,date,date) to service_role;
grant execute on function public.report_account_balance(uuid,uuid,date) to service_role;
grant execute on function public.report_gl_lines(uuid,uuid,date,date) to service_role;
grant execute on function public.report_cash_flow(uuid,date,date) to service_role;
