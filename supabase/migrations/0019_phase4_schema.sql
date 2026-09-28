-- =============================================================================
-- Letiq ERP - Migration 0019: Phase 4 accounting schema
-- =============================================================================

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- Chart of accounts: cash-flow classification + control-account flag.
-- ---------------------------------------------------------------------------
alter table public.chart_of_accounts add column if not exists cashflow_class text
  not null default 'unclassified'
  check (cashflow_class in ('operating','investing','financing','excluded_transfer','unclassified'));
alter table public.chart_of_accounts add column if not exists is_control boolean not null default false;

-- Mark control accounts (owned by subledgers) and default cash-flow classes.
do $$
declare c record;
begin
  for c in select id from public.companies loop
    update public.chart_of_accounts set is_control = true
      where company_id=c.id and code in ('1110','1120','1121','1122','1130','1131','1132','1140','1150','1160','2110','2120');
    -- Cash/bank/mobile accounts drive the cash-flow statement; their class is
    -- taken from the contra side, so leave them 'operating' as a safe default.
    update public.chart_of_accounts set cashflow_class='operating'
      where company_id=c.id and account_type in ('revenue','cost_of_sales','expense');
    update public.chart_of_accounts set cashflow_class='excluded_transfer'
      where company_id=c.id and code in ('3200'); -- opening balance equity
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Journal lines: optional subledger references (for GL filters & manual JEs).
-- ---------------------------------------------------------------------------
alter table public.journal_lines add column if not exists branch_id uuid references public.branches(id) on delete set null;
alter table public.journal_lines add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter table public.journal_lines add column if not exists supplier_id uuid references public.suppliers(id) on delete set null;

-- Reporting indexes.
create index if not exists journal_entries_company_date_idx on public.journal_entries(company_id, entry_date);
create index if not exists journal_entries_branch_date_idx on public.journal_entries(branch_id, entry_date);
create index if not exists journal_lines_account_journal_idx on public.journal_lines(account_id, journal_id);
create index if not exists journal_lines_customer_idx on public.journal_lines(customer_id);
create index if not exists journal_lines_supplier_idx on public.journal_lines(supplier_id);

-- ---------------------------------------------------------------------------
-- Extend create_journal to accept optional branch/customer/supplier per line.
-- Backward compatible: existing callers omit these keys.
-- ---------------------------------------------------------------------------
create or replace function public.create_journal(
  p_company uuid, p_branch uuid, p_date date,
  p_source_type text, p_source_id uuid, p_source_number text, p_memo text,
  p_user uuid, p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  j_id uuid; total_debit numeric(18,2) := 0; total_credit numeric(18,2) := 0; ln jsonb; i int := 0;
begin
  for ln in select * from jsonb_array_elements(p_lines) loop
    total_debit := total_debit + coalesce((ln->>'debit')::numeric, 0);
    total_credit := total_credit + coalesce((ln->>'credit')::numeric, 0);
  end loop;
  if round(total_debit,2) <> round(total_credit,2) then
    raise exception 'Journal is not balanced (debit % <> credit %)', total_debit, total_credit using errcode='P0001';
  end if;
  if round(total_debit,2) = 0 then return null; end if;

  insert into public.journal_entries(company_id, branch_id, entry_date, source_type, source_id, source_number, memo, posted_by)
    values (p_company, p_branch, p_date, p_source_type, p_source_id, p_source_number, p_memo, p_user)
    returning id into j_id;

  for ln in select * from jsonb_array_elements(p_lines) loop
    if coalesce((ln->>'debit')::numeric,0)=0 and coalesce((ln->>'credit')::numeric,0)=0 then continue; end if;
    i := i + 1;
    insert into public.journal_lines(journal_id, account_id, debit, credit, memo, line_no, branch_id, customer_id, supplier_id)
      values (j_id, (ln->>'account_id')::uuid,
        round(coalesce((ln->>'debit')::numeric,0),2), round(coalesce((ln->>'credit')::numeric,0),2),
        ln->>'memo', i,
        nullif(ln->>'branch_id','')::uuid, nullif(ln->>'customer_id','')::uuid, nullif(ln->>'supplier_id','')::uuid);
  end loop;
  return j_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Manual journals
-- ---------------------------------------------------------------------------
create table if not exists public.manual_journal_drafts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid references public.branches(id) on delete set null,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  journal_date date not null default current_date,
  reference text,
  description text,
  notes text,
  reversal_date date,
  total_debit numeric(18,2) not null default 0,
  total_credit numeric(18,2) not null default 0,
  is_control_adjustment boolean not null default false,
  journal_id uuid references public.journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  void_reason text
);
create unique index if not exists mjd_docnum_unique on public.manual_journal_drafts(company_id, document_number) where document_number is not null;

create table if not exists public.manual_journal_draft_lines (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null references public.manual_journal_drafts(id) on delete cascade,
  account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  branch_id uuid references public.branches(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  description text,
  line_no integer not null default 0,
  check (debit = 0 or credit = 0),
  check (debit > 0 or credit > 0)
);
create index if not exists mjdl_draft_idx on public.manual_journal_draft_lines(draft_id);

-- ---------------------------------------------------------------------------
-- General / customer / supplier opening balances
-- ---------------------------------------------------------------------------
create table if not exists public.accounting_opening_balances (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  opening_date date not null default current_date,
  reference text,
  description text,
  total_debit numeric(18,2) not null default 0,
  total_credit numeric(18,2) not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  void_reason text
);
create table if not exists public.accounting_opening_balance_lines (
  id uuid primary key default gen_random_uuid(),
  opening_id uuid not null references public.accounting_opening_balances(id) on delete cascade,
  account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  branch_id uuid references public.branches(id) on delete set null,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  description text,
  line_no integer not null default 0,
  check (debit = 0 or credit = 0),
  check (debit > 0 or credit > 0)
);
create index if not exists aobl_opening_idx on public.accounting_opening_balance_lines(opening_id);

create table if not exists public.customer_opening_balances (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  reference text,
  invoice_date date not null default current_date,
  due_date date,
  amount numeric(18,2) not null check (amount > 0),
  outstanding numeric(18,2) not null default 0,
  journal_id uuid references public.journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  void_reason text
);
create table if not exists public.supplier_opening_balances (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  reference text,
  document_date date not null default current_date,
  due_date date,
  amount numeric(18,2) not null check (amount > 0),
  outstanding numeric(18,2) not null default 0,
  journal_id uuid references public.journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  posted_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz,
  voided_by uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  void_reason text
);

-- ---------------------------------------------------------------------------
-- Bank / mobile-money reconciliation
-- ---------------------------------------------------------------------------
create table if not exists public.bank_reconciliations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  statement_start date not null,
  statement_end date not null,
  statement_opening numeric(18,2) not null default 0,
  statement_closing numeric(18,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','in_progress','reconciled','finalized','reopened')),
  notes text,
  prepared_by uuid references auth.users(id) on delete set null,
  finalized_by uuid references auth.users(id) on delete set null,
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (statement_end >= statement_start)
);
create index if not exists bank_recs_account_idx on public.bank_reconciliations(payment_account_id, statement_end);

create table if not exists public.bank_statement_lines (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null references public.bank_reconciliations(id) on delete cascade,
  txn_date date not null,
  value_date date,
  description text,
  reference text,
  money_in numeric(18,2) not null default 0 check (money_in >= 0),
  money_out numeric(18,2) not null default 0 check (money_out >= 0),
  statement_balance numeric(18,2),
  fingerprint text not null,
  matched_amount numeric(18,2) not null default 0,
  status text not null default 'unmatched' check (status in ('unmatched','partial','matched','adjusted')),
  created_at timestamptz not null default now(),
  unique (reconciliation_id, fingerprint)
);
create index if not exists bank_lines_rec_idx on public.bank_statement_lines(reconciliation_id);

create table if not exists public.bank_reconciliation_matches (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null references public.bank_reconciliations(id) on delete cascade,
  statement_line_id uuid references public.bank_statement_lines(id) on delete cascade,
  journal_line_id uuid references public.journal_lines(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists bank_matches_rec_idx on public.bank_reconciliation_matches(reconciliation_id);
create unique index if not exists bank_matches_jl_unique on public.bank_reconciliation_matches(journal_line_id) where journal_line_id is not null;

create table if not exists public.bank_reconciliation_adjustments (
  id uuid primary key default gen_random_uuid(),
  reconciliation_id uuid not null references public.bank_reconciliations(id) on delete cascade,
  statement_line_id uuid references public.bank_statement_lines(id) on delete set null,
  account_id uuid not null references public.chart_of_accounts(id) on delete restrict,
  direction text not null check (direction in ('in','out')),
  amount numeric(18,2) not null check (amount > 0),
  description text not null,
  reference text,
  journal_id uuid references public.journal_entries(id) on delete set null,
  document_status text not null default 'posted' check (document_status in ('posted','voided')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  voided_by uuid references auth.users(id) on delete set null,
  void_reason text
);
create index if not exists bank_adj_rec_idx on public.bank_reconciliation_adjustments(reconciliation_id);

-- ---------------------------------------------------------------------------
-- Period close checks + events
-- ---------------------------------------------------------------------------
create table if not exists public.accounting_period_close_checks (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.accounting_periods(id) on delete cascade,
  check_key text not null,
  severity text not null check (severity in ('blocking','warning','passed')),
  detail text,
  item_count integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists apcc_period_idx on public.accounting_period_close_checks(period_id);

create table if not exists public.accounting_period_events (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.accounting_periods(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete restrict,
  event text not null check (event in ('close','reopen','lock','unlock')),
  from_status text,
  to_status text,
  reason text,
  acknowledgements jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ape_period_idx on public.accounting_period_events(period_id);

-- updated_at triggers for editable drafts
do $$
declare t text;
begin
  foreach t in array array['manual_journal_drafts','accounting_opening_balances','bank_reconciliations'] loop
    execute format('drop trigger if exists trg_%1$s_updated on public.%1$s', t);
    execute format('create trigger trg_%1$s_updated before update on public.%1$s for each row execute function public.set_updated_at()', t);
  end loop;
end $$;
