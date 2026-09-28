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
