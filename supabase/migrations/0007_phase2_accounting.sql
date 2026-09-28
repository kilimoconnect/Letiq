-- =============================================================================
-- Letiq ERP - Migration 0007: Phase 2 accounting (journals) + extra accounts
-- =============================================================================

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- JOURNAL ENTRIES / LINES
-- ---------------------------------------------------------------------------
create table if not exists public.journal_entries (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete restrict,
  branch_id     uuid references public.branches(id) on delete restrict,
  entry_date    date not null,
  source_type   text not null,
  source_id     uuid,
  source_number text,
  memo          text,
  posted_by     uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  -- One journal per source document; prevents duplicate accounting.
  unique (source_type, source_id)
);
create index if not exists journal_entries_company_idx on public.journal_entries(company_id, entry_date);
create index if not exists journal_entries_source_idx on public.journal_entries(source_type, source_id);

create table if not exists public.journal_lines (
  id          uuid primary key default gen_random_uuid(),
  journal_id  uuid not null references public.journal_entries(id) on delete cascade,
  account_id  uuid not null references public.chart_of_accounts(id) on delete restrict,
  debit       numeric(18,2) not null default 0 check (debit >= 0),
  credit      numeric(18,2) not null default 0 check (credit >= 0),
  memo        text,
  line_no     integer not null default 0,
  check (debit = 0 or credit = 0)
);
create index if not exists journal_lines_journal_idx on public.journal_lines(journal_id);
create index if not exists journal_lines_account_idx on public.journal_lines(account_id);

-- Immutability for journals (insert-only from posting functions).
drop trigger if exists trg_journal_entries_no_mut on public.journal_entries;
create trigger trg_journal_entries_no_mut before update or delete on public.journal_entries
  for each row execute function public.block_mutation();
drop trigger if exists trg_journal_lines_no_mut on public.journal_lines;
create trigger trg_journal_lines_no_mut before update or delete on public.journal_lines
  for each row execute function public.block_mutation();

-- ---------------------------------------------------------------------------
-- Resolve an active posting account by code within a company.
-- ---------------------------------------------------------------------------
create or replace function public.account_id_by_code(p_company uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare acc uuid;
begin
  select id into acc from public.chart_of_accounts
    where company_id = p_company and code = p_code and is_active;
  if acc is null then
    raise exception 'Account % is not configured for this company', p_code
      using errcode = 'P0001';
  end if;
  return acc;
end; $$;

-- ---------------------------------------------------------------------------
-- Create a balanced journal from a jsonb array of lines:
--   [{ "account_id": uuid, "debit": num, "credit": num, "memo": text }]
-- Validates debits = credits (> 0). Unique(source_type, source_id) guards dups.
-- ---------------------------------------------------------------------------
create or replace function public.create_journal(
  p_company uuid, p_branch uuid, p_date date,
  p_source_type text, p_source_id uuid, p_source_number text, p_memo text,
  p_user uuid, p_lines jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  j_id uuid;
  total_debit numeric(18,2) := 0;
  total_credit numeric(18,2) := 0;
  ln jsonb;
  i int := 0;
begin
  for ln in select * from jsonb_array_elements(p_lines) loop
    total_debit := total_debit + coalesce((ln->>'debit')::numeric, 0);
    total_credit := total_credit + coalesce((ln->>'credit')::numeric, 0);
  end loop;

  if round(total_debit,2) <> round(total_credit,2) then
    raise exception 'Journal is not balanced (debit % <> credit %)', total_debit, total_credit
      using errcode = 'P0001';
  end if;
  if round(total_debit,2) = 0 then
    return null; -- nothing to post (e.g. fully non-inventory, zero effect)
  end if;

  insert into public.journal_entries(company_id, branch_id, entry_date, source_type, source_id, source_number, memo, posted_by)
    values (p_company, p_branch, p_date, p_source_type, p_source_id, p_source_number, p_memo, p_user)
    returning id into j_id;

  for ln in select * from jsonb_array_elements(p_lines) loop
    if coalesce((ln->>'debit')::numeric,0) = 0 and coalesce((ln->>'credit')::numeric,0) = 0 then
      continue;
    end if;
    i := i + 1;
    insert into public.journal_lines(journal_id, account_id, debit, credit, memo, line_no)
      values (j_id, (ln->>'account_id')::uuid,
              round(coalesce((ln->>'debit')::numeric,0),2),
              round(coalesce((ln->>'credit')::numeric,0),2),
              ln->>'memo', i);
  end loop;

  return j_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Seed additional protected system accounts for every company (idempotent).
-- ---------------------------------------------------------------------------
do $$
declare
  c record;
  eq_parent uuid; rev_parent uuid; exp_parent uuid;
begin
  for c in select id from public.companies loop
    select id into eq_parent from public.chart_of_accounts where company_id=c.id and code='3000';
    select id into rev_parent from public.chart_of_accounts where company_id=c.id and code='4000';
    select id into exp_parent from public.chart_of_accounts where company_id=c.id and code='6000';

    insert into public.chart_of_accounts(company_id, code, name, account_type, parent_id, normal_balance, allow_posting, is_system, is_active)
      values
        (c.id, '3200', 'Opening Balance Equity', 'equity', eq_parent, 'credit', true, true, true),
        (c.id, '4300', 'Inventory Adjustment Gain', 'revenue', rev_parent, 'credit', true, true, true),
        (c.id, '4900', 'Sales Returns', 'revenue', rev_parent, 'debit', true, true, true),
        (c.id, '6300', 'Inventory Shrinkage / Loss', 'expense', exp_parent, 'debit', true, true, true)
    on conflict (company_id, code) do nothing;
  end loop;
end $$;

-- Opening-balance document sequence for every company (idempotent).
do $$
declare c record;
begin
  for c in select id from public.companies loop
    if not exists (select 1 from public.document_sequences
                     where company_id=c.id and document_type='inventory_opening' and branch_id is null) then
      insert into public.document_sequences(company_id, document_type, prefix, current_number, number_length, reset_frequency)
        values (c.id, 'inventory_opening', 'OPB', 0, 5, 'never');
    end if;
  end loop;
end $$;
