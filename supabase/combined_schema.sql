-- Letiq ERP - combined schema (migrations 0001-0005).
-- Paste into Supabase SQL Editor and Run. Idempotent/safe to re-run.

-- ============================================================
-- migrations/0001_foundation.sql
-- ============================================================
-- =============================================================================
-- Letiq ERP - Migration 0001: Foundation (extensions, helpers, triggers)
-- =============================================================================
-- Idempotent. Safe to run more than once.

create extension if not exists pgcrypto;      -- gen_random_uuid()
create extension if not exists "uuid-ossp";
create extension if not exists btree_gist;    -- exclusion constraints on (uuid, daterange)

-- ---------------------------------------------------------------------------
-- Generic updated_at trigger
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Generic cross-company integrity trigger.
-- Attach with pairs of args: (column_name, referenced_table[, column_name, table]...)
-- Ensures each referenced row belongs to the same company_id as NEW.
-- ---------------------------------------------------------------------------
create or replace function public.check_company_consistency()
returns trigger
language plpgsql
as $$
declare
  i int := 0;
  col text;
  tbl text;
  ref_id uuid;
  ref_company uuid;
begin
  while i < TG_NARGS loop
    col := TG_ARGV[i];
    tbl := TG_ARGV[i + 1];
    ref_id := (to_jsonb(NEW) ->> col)::uuid;
    if ref_id is not null then
      execute format('select company_id from public.%I where id = $1', tbl)
        into ref_company using ref_id;
      if ref_company is null or ref_company <> NEW.company_id then
        raise exception
          'Cross-company reference on %.% -> % (id %) does not match company %',
          TG_TABLE_NAME, col, tbl, ref_id, NEW.company_id
          using errcode = '23514';
      end if;
    end if;
    i := i + 2;
  end loop;
  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- Chart of accounts: validate parent (same company, no cycles) and enforce
-- that any account which becomes a parent stops allowing direct posting.
-- ---------------------------------------------------------------------------
create or replace function public.coa_validate_parent()
returns trigger
language plpgsql
as $$
declare
  cur uuid;
  parent_company uuid;
  guard int := 0;
begin
  if NEW.parent_id is not null then
    if NEW.parent_id = NEW.id then
      raise exception 'An account cannot be its own parent' using errcode = '23514';
    end if;
    select company_id into parent_company
      from public.chart_of_accounts where id = NEW.parent_id;
    if parent_company is null or parent_company <> NEW.company_id then
      raise exception 'Parent account must belong to the same company'
        using errcode = '23514';
    end if;
    -- Walk up the ancestor chain looking for NEW.id (cycle detection).
    cur := NEW.parent_id;
    while cur is not null loop
      guard := guard + 1;
      if guard > 1000 then
        raise exception 'Account hierarchy too deep or cyclic' using errcode = '23514';
      end if;
      if cur = NEW.id then
        raise exception 'Account hierarchy would create a cycle' using errcode = '23514';
      end if;
      select parent_id into cur from public.chart_of_accounts where id = cur;
    end loop;
  end if;
  return NEW;
end;
$$;

create or replace function public.coa_demote_parent()
returns trigger
language plpgsql
as $$
begin
  if NEW.parent_id is not null then
    update public.chart_of_accounts
      set allow_posting = false
      where id = NEW.parent_id and allow_posting = true;
  end if;
  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- Authorization helper functions.
-- SECURITY DEFINER so they can read app tables from inside RLS policies
-- without triggering the same table's RLS (avoids infinite recursion).
-- ---------------------------------------------------------------------------

-- Is the current auth user the (an) Owner? Owner = active profile w/ OWNER role.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_profiles up
    join public.roles r on r.id = up.role_id
    where up.id = auth.uid()
      and up.is_active
      and r.code = 'OWNER'
  );
$$;

-- Does the current auth user have an active profile?
create or replace function public.is_active_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_profiles up
    where up.id = auth.uid() and up.is_active
  );
$$;

-- Does the current user have access to a company (Owner => all)?
create or replace function public.has_company_access(target_company uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_owner()
    or exists (
      select 1 from public.user_company_access uca
      where uca.user_id = auth.uid()
        and uca.company_id = target_company
    );
$$;

-- Does the current user have access to a branch (Owner => all)?
create or replace function public.has_branch_access(target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_owner()
    or exists (
      select 1 from public.user_branch_access uba
      where uba.user_id = auth.uid()
        and uba.branch_id = target_branch
    );
$$;


-- ============================================================
-- migrations/0002_identity_rbac.sql
-- ============================================================
-- =============================================================================
-- Letiq ERP - Migration 0002: Companies, Branches, Identity & RBAC
-- =============================================================================

-- ---------------------------------------------------------------------------
-- ROLES
-- ---------------------------------------------------------------------------
create table if not exists public.roles (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  description  text,
  is_system    boolean not null default false,   -- shipped with the app
  is_protected boolean not null default false,   -- cannot be edited/deleted (Owner)
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now(),
  updated_by   uuid references auth.users(id) on delete set null
);

-- ---------------------------------------------------------------------------
-- PERMISSIONS (resource + action)
-- ---------------------------------------------------------------------------
create table if not exists public.permissions (
  id          uuid primary key default gen_random_uuid(),
  resource    text not null,
  action      text not null,
  code        text not null unique,             -- e.g. "admin.manage"
  description text,
  created_at  timestamptz not null default now(),
  unique (resource, action)
);

create table if not exists public.role_permissions (
  role_id       uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (role_id, permission_id)
);

-- ---------------------------------------------------------------------------
-- COMPANIES
-- ---------------------------------------------------------------------------
create table if not exists public.companies (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  name          text not null,
  legal_name    text,
  base_currency text not null default 'TZS',
  timezone      text not null default 'Africa/Dar_es_Salaam',
  date_format   text not null default 'DD/MM/YYYY',
  phone         text,
  email         text,
  address       text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id) on delete set null,
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id) on delete set null
);

-- ---------------------------------------------------------------------------
-- BRANCHES
-- ---------------------------------------------------------------------------
create table if not exists public.branches (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete restrict,
  code           text not null,
  name           text not null,
  address        text,
  phone          text,
  email          text,
  is_head_office boolean not null default false,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);
-- Only one head office per company
create unique index if not exists branches_one_head_office_per_company
  on public.branches (company_id)
  where is_head_office;

-- ---------------------------------------------------------------------------
-- USER PROFILES  (1:1 with auth.users)
-- ---------------------------------------------------------------------------
create table if not exists public.user_profiles (
  id                uuid primary key references auth.users(id) on delete cascade,
  email             text not null unique,
  full_name         text,
  phone             text,
  role_id           uuid references public.roles(id) on delete restrict,
  default_company_id uuid references public.companies(id) on delete set null,
  default_branch_id uuid references public.branches(id) on delete set null,
  is_active         boolean not null default true,
  is_primary_owner  boolean not null default false,  -- protected bootstrap owner
  last_sign_in_at   timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,
  updated_at        timestamptz not null default now(),
  updated_by        uuid references auth.users(id) on delete set null
);
-- Guarantee at most one primary owner across the system.
create unique index if not exists user_profiles_single_primary_owner
  on public.user_profiles ((is_primary_owner))
  where is_primary_owner;

-- ---------------------------------------------------------------------------
-- USER <-> COMPANY / BRANCH ACCESS
-- ---------------------------------------------------------------------------
create table if not exists public.user_company_access (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.user_profiles(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  unique (user_id, company_id)
);

create table if not exists public.user_branch_access (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.user_profiles(id) on delete cascade,
  branch_id  uuid not null references public.branches(id) on delete cascade,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  unique (user_id, branch_id)
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index if not exists branches_company_idx        on public.branches(company_id);
create index if not exists user_profiles_role_idx       on public.user_profiles(role_id);
create index if not exists uca_user_idx                 on public.user_company_access(user_id);
create index if not exists uca_company_idx              on public.user_company_access(company_id);
create index if not exists uba_user_idx                 on public.user_branch_access(user_id);
create index if not exists uba_branch_idx               on public.user_branch_access(branch_id);
create index if not exists role_permissions_perm_idx    on public.role_permissions(permission_id);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------
drop trigger if exists trg_roles_updated on public.roles;
create trigger trg_roles_updated before update on public.roles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_companies_updated on public.companies;
create trigger trg_companies_updated before update on public.companies
  for each row execute function public.set_updated_at();

drop trigger if exists trg_branches_updated on public.branches;
create trigger trg_branches_updated before update on public.branches
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_profiles_updated on public.user_profiles;
create trigger trg_user_profiles_updated before update on public.user_profiles
  for each row execute function public.set_updated_at();


-- ============================================================
-- migrations/0003_master_data.sql
-- ============================================================
-- =============================================================================
-- Letiq ERP - Migration 0003: Master data
-- =============================================================================

-- ---------------------------------------------------------------------------
-- UNITS OF MEASUREMENT
-- ---------------------------------------------------------------------------
create table if not exists public.units (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete restrict,
  code          text not null,
  name          text not null,
  symbol        text,
  allow_decimal boolean not null default true,
  description   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id) on delete set null,
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

-- ---------------------------------------------------------------------------
-- PRODUCT CATEGORIES
-- ---------------------------------------------------------------------------
create table if not exists public.product_categories (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete restrict,
  code        text not null,
  name        text not null,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

-- ---------------------------------------------------------------------------
-- BRANDS
-- ---------------------------------------------------------------------------
create table if not exists public.brands (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete restrict,
  code        text not null,
  name        text not null,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

-- ---------------------------------------------------------------------------
-- CHART OF ACCOUNTS (hierarchical)
-- ---------------------------------------------------------------------------
create table if not exists public.chart_of_accounts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete restrict,
  code           text not null,
  name           text not null,
  account_type   text not null check (account_type in
                   ('asset','liability','equity','revenue','cost_of_sales','expense')),
  parent_id      uuid references public.chart_of_accounts(id) on delete restrict,
  normal_balance text not null check (normal_balance in ('debit','credit')),
  allow_posting  boolean not null default true,
  is_system      boolean not null default false,
  is_active      boolean not null default true,
  description    text,
  created_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);
create index if not exists coa_company_idx on public.chart_of_accounts(company_id);
create index if not exists coa_parent_idx  on public.chart_of_accounts(parent_id);

drop trigger if exists trg_coa_validate on public.chart_of_accounts;
create trigger trg_coa_validate before insert or update on public.chart_of_accounts
  for each row execute function public.coa_validate_parent();

drop trigger if exists trg_coa_demote on public.chart_of_accounts;
create trigger trg_coa_demote after insert or update on public.chart_of_accounts
  for each row execute function public.coa_demote_parent();

-- ---------------------------------------------------------------------------
-- TAX CODES
-- ---------------------------------------------------------------------------
create table if not exists public.tax_codes (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete restrict,
  code              text not null,
  name              text not null,
  tax_type          text not null check (tax_type in
                      ('standard','zero_rated','exempt','out_of_scope')),
  rate              numeric(9,4) not null default 0 check (rate >= 0 and rate <= 100),
  applies_to        text not null default 'both' check (applies_to in ('sales','purchases','both')),
  is_inclusive      boolean not null default false,
  input_account_id  uuid references public.chart_of_accounts(id) on delete set null,
  output_account_id uuid references public.chart_of_accounts(id) on delete set null,
  effective_start   date not null default current_date,
  effective_end     date,
  is_active         boolean not null default true,
  description       text,
  created_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,
  updated_at        timestamptz not null default now(),
  updated_by        uuid references auth.users(id) on delete set null,
  unique (company_id, code),
  check (effective_end is null or effective_end >= effective_start)
);
-- Prevent overlapping effective date ranges for the same tax code.
alter table public.tax_codes drop constraint if exists tax_codes_no_overlap;
alter table public.tax_codes add constraint tax_codes_no_overlap
  exclude using gist (
    company_id with =,
    code with =,
    daterange(effective_start, coalesce(effective_end, 'infinity'::date), '[]') with &&
  );

drop trigger if exists trg_tax_codes_company on public.tax_codes;
create trigger trg_tax_codes_company before insert or update on public.tax_codes
  for each row execute function public.check_company_consistency(
    'input_account_id', 'chart_of_accounts',
    'output_account_id', 'chart_of_accounts');

-- ---------------------------------------------------------------------------
-- PAYMENT ACCOUNTS  (no editable balance - balances are derived later)
-- ---------------------------------------------------------------------------
create table if not exists public.payment_accounts (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id) on delete restrict,
  branch_id         uuid references public.branches(id) on delete restrict,
  code              text not null,
  name              text not null,
  account_type      text not null check (account_type in
                      ('cash','bank','mobile_money','clearing')),
  provider          text,
  account_number    text,
  ledger_account_id uuid references public.chart_of_accounts(id) on delete set null,
  is_active         boolean not null default true,
  description       text,
  created_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,
  updated_at        timestamptz not null default now(),
  updated_by        uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

drop trigger if exists trg_payment_accounts_company on public.payment_accounts;
create trigger trg_payment_accounts_company before insert or update on public.payment_accounts
  for each row execute function public.check_company_consistency(
    'branch_id', 'branches',
    'ledger_account_id', 'chart_of_accounts');

-- ---------------------------------------------------------------------------
-- PRODUCTS  (no stock quantity - inventory arrives in a later phase)
-- ---------------------------------------------------------------------------
create table if not exists public.products (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete restrict,
  sku             text not null,
  barcode         text,
  name            text not null,
  description     text,
  category_id     uuid references public.product_categories(id) on delete restrict,
  brand_id        uuid references public.brands(id) on delete restrict,
  base_unit_id    uuid references public.units(id) on delete restrict,
  purchase_price  numeric(18,2) not null default 0 check (purchase_price >= 0),
  selling_price   numeric(18,2) not null default 0 check (selling_price >= 0),
  tax_code_id     uuid references public.tax_codes(id) on delete set null,
  reorder_level   numeric(18,4) not null default 0 check (reorder_level >= 0),
  track_inventory boolean not null default true,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  updated_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id) on delete set null,
  unique (company_id, sku)
);
create index if not exists products_company_idx  on public.products(company_id);
create index if not exists products_category_idx on public.products(category_id);
create index if not exists products_brand_idx    on public.products(brand_id);

drop trigger if exists trg_products_company on public.products;
create trigger trg_products_company before insert or update on public.products
  for each row execute function public.check_company_consistency(
    'category_id', 'product_categories',
    'brand_id', 'brands',
    'base_unit_id', 'units',
    'tax_code_id', 'tax_codes');

-- ---------------------------------------------------------------------------
-- CUSTOMERS
-- ---------------------------------------------------------------------------
create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id) on delete restrict,
  code          text not null,
  name          text not null,
  customer_type text,
  phone         text,
  email         text,
  tin           text,
  vat_number    text,
  address       text,
  credit_allowed boolean not null default false,
  credit_limit  numeric(18,2) not null default 0 check (credit_limit >= 0),
  is_active     boolean not null default true,
  is_protected  boolean not null default false,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id) on delete set null,
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

-- ---------------------------------------------------------------------------
-- SUPPLIERS
-- ---------------------------------------------------------------------------
create table if not exists public.suppliers (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete restrict,
  code               text not null,
  name               text not null,
  contact_person     text,
  phone              text,
  email              text,
  tin                text,
  vat_number         text,
  address            text,
  payment_terms_days integer not null default 0 check (payment_terms_days >= 0),
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  created_by         uuid references auth.users(id) on delete set null,
  updated_at         timestamptz not null default now(),
  updated_by         uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

-- ---------------------------------------------------------------------------
-- EXPENSE CATEGORIES
-- ---------------------------------------------------------------------------
create table if not exists public.expense_categories (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete restrict,
  code                text not null,
  name                text not null,
  description         text,
  expense_account_id  uuid references public.chart_of_accounts(id) on delete set null,
  default_tax_code_id uuid references public.tax_codes(id) on delete set null,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id) on delete set null,
  updated_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

drop trigger if exists trg_expense_categories_company on public.expense_categories;
create trigger trg_expense_categories_company before insert or update on public.expense_categories
  for each row execute function public.check_company_consistency(
    'expense_account_id', 'chart_of_accounts',
    'default_tax_code_id', 'tax_codes');

-- ---------------------------------------------------------------------------
-- OTHER INCOME TYPES
-- ---------------------------------------------------------------------------
create table if not exists public.other_income_types (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete restrict,
  code                text not null,
  name                text not null,
  description         text,
  income_account_id   uuid references public.chart_of_accounts(id) on delete set null,
  default_tax_code_id uuid references public.tax_codes(id) on delete set null,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id) on delete set null,
  updated_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null,
  unique (company_id, code)
);

drop trigger if exists trg_other_income_company on public.other_income_types;
create trigger trg_other_income_company before insert or update on public.other_income_types
  for each row execute function public.check_company_consistency(
    'income_account_id', 'chart_of_accounts',
    'default_tax_code_id', 'tax_codes');

-- ---------------------------------------------------------------------------
-- DOCUMENT SEQUENCES  (configuration only; no numbers generated yet)
-- ---------------------------------------------------------------------------
create table if not exists public.document_sequences (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete restrict,
  branch_id       uuid references public.branches(id) on delete restrict,
  document_type   text not null,
  prefix          text not null default '',
  current_number  bigint not null default 0 check (current_number >= 0),
  number_length   integer not null default 5 check (number_length between 1 and 12),
  reset_frequency text not null default 'never'
                  check (reset_frequency in ('never','yearly','monthly','daily')),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  updated_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id) on delete set null
);
create unique index if not exists document_sequences_unique
  on public.document_sequences (
    company_id,
    document_type,
    coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

drop trigger if exists trg_document_sequences_company on public.document_sequences;
create trigger trg_document_sequences_company before insert or update on public.document_sequences
  for each row execute function public.check_company_consistency('branch_id', 'branches');

-- ---------------------------------------------------------------------------
-- ACCOUNTING PERIODS
-- ---------------------------------------------------------------------------
create table if not exists public.accounting_periods (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete restrict,
  financial_year text not null,
  name           text not null,
  start_date     date not null,
  end_date       date not null,
  status         text not null default 'open' check (status in ('open','closed','locked')),
  closed_by      uuid references auth.users(id) on delete set null,
  closed_at      timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id) on delete set null,
  check (end_date >= start_date)
);
-- No overlapping periods within a company.
alter table public.accounting_periods drop constraint if exists accounting_periods_no_overlap;
alter table public.accounting_periods add constraint accounting_periods_no_overlap
  exclude using gist (
    company_id with =,
    daterange(start_date, end_date, '[]') with &&
  );

-- ---------------------------------------------------------------------------
-- updated_at triggers for all master tables
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'units','product_categories','brands','chart_of_accounts','tax_codes',
    'payment_accounts','products','customers','suppliers','expense_categories',
    'other_income_types','document_sequences','accounting_periods'
  ] loop
    execute format('drop trigger if exists trg_%1$s_updated on public.%1$s', t);
    execute format(
      'create trigger trg_%1$s_updated before update on public.%1$s
         for each row execute function public.set_updated_at()', t);
  end loop;
end $$;


-- ============================================================
-- migrations/0004_audit.sql
-- ============================================================
-- =============================================================================
-- Letiq ERP - Migration 0004: Immutable audit log
-- =============================================================================

create table if not exists public.audit_logs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete set null,
  company_id    uuid references public.companies(id) on delete set null,
  branch_id     uuid references public.branches(id) on delete set null,
  action        text not null,
  resource_type text not null,
  resource_id   text,
  old_values    jsonb,
  new_values    jsonb,
  reason        text,
  ip_address    text,
  user_agent    text,
  created_at    timestamptz not null default now()
);

create index if not exists audit_logs_created_idx  on public.audit_logs(created_at desc);
create index if not exists audit_logs_user_idx     on public.audit_logs(user_id);
create index if not exists audit_logs_company_idx  on public.audit_logs(company_id);
create index if not exists audit_logs_resource_idx on public.audit_logs(resource_type, resource_id);

-- Hard immutability: block UPDATE/DELETE for everyone, including the service
-- role (which bypasses RLS). Records can only ever be inserted.
create or replace function public.audit_logs_block_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Audit log records are immutable and cannot be % ', TG_OP
    using errcode = '0A000';
  return null;
end;
$$;

drop trigger if exists trg_audit_logs_no_update on public.audit_logs;
create trigger trg_audit_logs_no_update
  before update on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();

drop trigger if exists trg_audit_logs_no_delete on public.audit_logs;
create trigger trg_audit_logs_no_delete
  before delete on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();


-- ============================================================
-- migrations/0005_rls.sql
-- ============================================================
-- =============================================================================
-- Letiq ERP - Migration 0005: Row Level Security
-- =============================================================================
-- Model:
--   * Reads  : a user may read rows for companies they are assigned to
--              (Owner is assigned to everything via has_company_access()).
--   * Writes : master-data mutations are Owner-only at the DB level.
--   * Server actions additionally assert authorization in code; RLS is the
--     backstop so a direct authed API call cannot bypass permissions.
--   * The service-role client bypasses RLS and is only used from trusted
--     server code after the caller has been authorized.
-- =============================================================================

-- Company-scoped tables: SELECT by company access, writes Owner-only.
do $$
declare t text;
begin
  foreach t in array array[
    'branches','units','product_categories','brands','chart_of_accounts',
    'tax_codes','payment_accounts','products','customers','suppliers',
    'expense_categories','other_income_types','document_sequences',
    'accounting_periods'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);

    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (public.has_company_access(company_id))',
      t || '_select', t);

    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (public.is_owner())',
      t || '_insert', t);

    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (public.is_owner()) with check (public.is_owner())',
      t || '_update', t);

    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (public.is_owner())',
      t || '_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- companies (access keyed by id, not company_id)
-- ---------------------------------------------------------------------------
alter table public.companies enable row level security;
alter table public.companies force row level security;
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies for select to authenticated
  using (public.has_company_access(id));
drop policy if exists companies_write on public.companies;
create policy companies_write on public.companies for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- ---------------------------------------------------------------------------
-- roles / permissions / role_permissions: readable by any authed user,
-- writable only by Owner.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['roles','permissions','role_permissions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (public.is_owner()) with check (public.is_owner())',
      t || '_write', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- user_profiles: a user can read their own row; Owner can read/write all.
-- ---------------------------------------------------------------------------
alter table public.user_profiles enable row level security;
alter table public.user_profiles force row level security;
drop policy if exists user_profiles_select on public.user_profiles;
create policy user_profiles_select on public.user_profiles for select to authenticated
  using (id = auth.uid() or public.is_owner());
drop policy if exists user_profiles_write on public.user_profiles;
create policy user_profiles_write on public.user_profiles for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- ---------------------------------------------------------------------------
-- user_company_access / user_branch_access: user reads own; Owner all/writes.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['user_company_access','user_branch_access'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (user_id = auth.uid() or public.is_owner())',
      t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (public.is_owner()) with check (public.is_owner())',
      t || '_write', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- audit_logs: Owner-only read. No insert/update/delete policies => the app
-- (authenticated) role can never write; the service role inserts, and the
-- immutability triggers block any update/delete even for the service role.
-- ---------------------------------------------------------------------------
alter table public.audit_logs enable row level security;
alter table public.audit_logs force row level security;
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (public.is_owner());


