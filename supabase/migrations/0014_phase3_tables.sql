-- =============================================================================
-- Letiq ERP - Migration 0014: Phase 3 transactional tables
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PURCHASES
-- ---------------------------------------------------------------------------
create table if not exists public.purchases (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies(id) on delete restrict,
  branch_id              uuid not null references public.branches(id) on delete restrict,
  document_status        text not null default 'draft' check (document_status in ('draft','posted','voided')),
  payment_status         text not null default 'unpaid'
                          check (payment_status in ('unpaid','partially_paid','paid','partially_refunded','refunded')),
  document_number        text,
  document_date          date not null default current_date,
  supplier_invoice_date  date,
  supplier_invoice_number text,
  supplier_invoice_norm  text,
  internal_reference     text,
  due_date               date,
  supplier_id            uuid not null references public.suppliers(id) on delete restrict,
  notes                  text,
  is_credit              boolean not null default false,
  subtotal               numeric(18,2) not null default 0,
  discount_total         numeric(18,2) not null default 0,
  net_total              numeric(18,2) not null default 0,
  tax_total              numeric(18,2) not null default 0,
  recoverable_tax        numeric(18,2) not null default 0,
  nonrecoverable_tax     numeric(18,2) not null default 0,
  grand_total            numeric(18,2) not null default 0,
  inventory_value        numeric(18,2) not null default 0,
  amount_paid            numeric(18,2) not null default 0,
  outstanding            numeric(18,2) not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists purchases_docnum_unique on public.purchases(company_id, document_number) where document_number is not null;
create unique index if not exists purchases_supplier_invoice_unique
  on public.purchases(company_id, supplier_id, supplier_invoice_norm)
  where document_status = 'posted' and supplier_invoice_norm is not null and supplier_invoice_norm <> '';
create index if not exists purchases_supplier_idx on public.purchases(supplier_id);
create index if not exists purchases_company_idx on public.purchases(company_id, document_date);

create table if not exists public.purchase_lines (
  id            uuid primary key default gen_random_uuid(),
  purchase_id   uuid not null references public.purchases(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete restrict,
  description   text,
  quantity      numeric(18,4) not null check (quantity > 0),
  unit_cost     numeric(18,2) not null check (unit_cost >= 0),
  discount      numeric(18,2) not null default 0 check (discount >= 0),
  tax_code_id   uuid references public.tax_codes(id) on delete set null,
  tax_rate      numeric(9,4) not null default 0,
  tax_type      text,
  tax_name      text,
  tax_inclusive boolean not null default false,
  is_recoverable boolean not null default true,
  net_amount    numeric(18,2) not null default 0,
  tax_amount    numeric(18,2) not null default 0,
  recoverable_tax numeric(18,2) not null default 0,
  nonrecoverable_tax numeric(18,2) not null default 0,
  gross_amount  numeric(18,2) not null default 0,
  inventory_unit_cost numeric(18,4) not null default 0,
  inventory_value numeric(18,2) not null default 0,
  track_inventory boolean not null default true,
  line_no       integer not null default 0
);
create index if not exists purchase_lines_purchase_idx on public.purchase_lines(purchase_id);

create table if not exists public.purchase_payments (
  id uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  reference text,
  payment_date date not null default current_date,
  created_at timestamptz not null default now()
);
create index if not exists purchase_payments_purchase_idx on public.purchase_payments(purchase_id);

-- ---------------------------------------------------------------------------
-- EXPENSES
-- ---------------------------------------------------------------------------
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id  uuid not null references public.branches(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  payment_status  text not null default 'unpaid' check (payment_status in ('unpaid','partially_paid','paid')),
  document_number text,
  document_date   date not null default current_date,
  expense_category_id uuid not null references public.expense_categories(id) on delete restrict,
  supplier_id uuid references public.suppliers(id) on delete restrict,
  reference   text,
  description text,
  tax_code_id uuid references public.tax_codes(id) on delete set null,
  tax_rate    numeric(9,4) not null default 0,
  tax_name    text,
  tax_inclusive boolean not null default false,
  is_recoverable boolean not null default true,
  net_total   numeric(18,2) not null default 0,
  tax_total   numeric(18,2) not null default 0,
  recoverable_tax numeric(18,2) not null default 0,
  nonrecoverable_tax numeric(18,2) not null default 0,
  grand_total numeric(18,2) not null default 0,
  amount_paid numeric(18,2) not null default 0,
  outstanding numeric(18,2) not null default 0,
  due_date    date,
  is_credit   boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists expenses_docnum_unique on public.expenses(company_id, document_number) where document_number is not null;
create index if not exists expenses_company_idx on public.expenses(company_id, document_date);

create table if not exists public.expense_payments (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  reference text,
  payment_date date not null default current_date,
  created_at timestamptz not null default now()
);
create index if not exists expense_payments_expense_idx on public.expense_payments(expense_id);

-- ---------------------------------------------------------------------------
-- SUPPLIER PAYABLES (one row per unpaid purchase OR expense)
-- ---------------------------------------------------------------------------
create table if not exists public.supplier_payables (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id  uuid not null references public.branches(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  source_type text not null check (source_type in ('purchase','expense')),
  purchase_id uuid references public.purchases(id) on delete cascade,
  expense_id  uuid references public.expenses(id) on delete cascade,
  original_amount numeric(18,2) not null default 0,
  outstanding numeric(18,2) not null default 0,
  status text not null default 'open' check (status in ('open','partial','settled','voided')),
  created_at timestamptz not null default now(),
  check ( (purchase_id is not null)::int + (expense_id is not null)::int = 1 ),
  check ( (source_type='purchase' and purchase_id is not null) or (source_type='expense' and expense_id is not null) )
);
create unique index if not exists payable_purchase_unique on public.supplier_payables(purchase_id) where purchase_id is not null;
create unique index if not exists payable_expense_unique on public.supplier_payables(expense_id) where expense_id is not null;
create index if not exists payables_supplier_idx on public.supplier_payables(supplier_id, status);

-- ---------------------------------------------------------------------------
-- SUPPLIER PAYMENTS
-- ---------------------------------------------------------------------------
create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id  uuid not null references public.branches(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  document_date date not null default current_date,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  amount numeric(18,2) not null default 0,
  reference text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists supplier_payments_docnum_unique on public.supplier_payments(company_id, document_number) where document_number is not null;

create table if not exists public.supplier_payment_funding (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.supplier_payments(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  reference text
);
create index if not exists spf_payment_idx on public.supplier_payment_funding(payment_id);

create table if not exists public.supplier_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.supplier_payments(id) on delete cascade,
  payable_id uuid not null references public.supplier_payables(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0)
);
create index if not exists spa_payment_idx on public.supplier_payment_allocations(payment_id);
create index if not exists spa_payable_idx on public.supplier_payment_allocations(payable_id);

-- ---------------------------------------------------------------------------
-- PURCHASE RETURNS
-- ---------------------------------------------------------------------------
create table if not exists public.purchase_returns (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id  uuid not null references public.branches(id) on delete restrict,
  purchase_id uuid not null references public.purchases(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  document_date date not null default current_date,
  reason text not null,
  notes text,
  settlement_method text not null default 'reduce_payable'
    check (settlement_method in ('reduce_payable','supplier_credit','refund','mixed')),
  net_total numeric(18,2) not null default 0,
  tax_total numeric(18,2) not null default 0,
  total     numeric(18,2) not null default 0,
  inventory_cost_removed numeric(18,2) not null default 0,
  refund_amount numeric(18,2) not null default 0,
  payable_reduction numeric(18,2) not null default 0,
  credit_amount numeric(18,2) not null default 0,
  price_variance numeric(18,2) not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists purchase_returns_docnum_unique on public.purchase_returns(company_id, document_number) where document_number is not null;
create index if not exists purchase_returns_purchase_idx on public.purchase_returns(purchase_id);

create table if not exists public.purchase_return_lines (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.purchase_returns(id) on delete cascade,
  purchase_line_id uuid not null references public.purchase_lines(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,4) not null check (quantity > 0),
  unit_price numeric(18,2) not null default 0,
  tax_rate numeric(9,4) not null default 0,
  is_recoverable boolean not null default true,
  net_amount numeric(18,2) not null default 0,
  tax_amount numeric(18,2) not null default 0,
  line_total numeric(18,2) not null default 0,
  inventory_cost numeric(18,2) not null default 0,
  track_inventory boolean not null default true,
  line_no integer not null default 0
);
create index if not exists purchase_return_lines_return_idx on public.purchase_return_lines(return_id);

create table if not exists public.purchase_return_settlements (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.purchase_returns(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  reference text
);

create table if not exists public.supplier_credits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  source_return_id uuid references public.purchase_returns(id) on delete set null,
  amount numeric(18,2) not null check (amount > 0),
  remaining numeric(18,2) not null default 0,
  status text not null default 'open' check (status in ('open','used','voided')),
  created_at timestamptz not null default now()
);
create index if not exists supplier_credits_supplier_idx on public.supplier_credits(supplier_id, status);

-- ---------------------------------------------------------------------------
-- OTHER INCOME
-- ---------------------------------------------------------------------------
create table if not exists public.other_income_transactions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  branch_id  uuid not null references public.branches(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  document_date date not null default current_date,
  income_type_id uuid not null references public.other_income_types(id) on delete restrict,
  received_from text,
  description text,
  tax_code_id uuid references public.tax_codes(id) on delete set null,
  tax_rate numeric(9,4) not null default 0,
  tax_name text,
  tax_inclusive boolean not null default false,
  net_total numeric(18,2) not null default 0,
  tax_total numeric(18,2) not null default 0,
  grand_total numeric(18,2) not null default 0,
  reference text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists other_income_docnum_unique on public.other_income_transactions(company_id, document_number) where document_number is not null;

create table if not exists public.other_income_receipts (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.other_income_transactions(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  reference text
);
create index if not exists other_income_receipts_txn_idx on public.other_income_receipts(transaction_id);

-- ---------------------------------------------------------------------------
-- CASH TRANSFERS
-- ---------------------------------------------------------------------------
create table if not exists public.cash_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  transfer_date date not null default current_date,
  source_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  destination_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  source_branch_id uuid references public.branches(id) on delete restrict,
  destination_branch_id uuid references public.branches(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  fee numeric(18,2) not null default 0 check (fee >= 0),
  fee_account_id uuid references public.chart_of_accounts(id) on delete set null,
  reference text,
  description text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text,
  check (source_account_id <> destination_account_id)
);
create unique index if not exists cash_transfers_docnum_unique on public.cash_transfers(company_id, document_number) where document_number is not null;

-- ---------------------------------------------------------------------------
-- FINANCIAL OPENING BALANCES
-- ---------------------------------------------------------------------------
create table if not exists public.financial_opening_balances (
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
  posted_by  uuid references auth.users(id) on delete set null,
  posted_at  timestamptz,
  voided_by  uuid references auth.users(id) on delete set null,
  voided_at  timestamptz,
  void_reason text
);
create unique index if not exists fob_docnum_unique on public.financial_opening_balances(company_id, document_number) where document_number is not null;

create table if not exists public.financial_opening_balance_lines (
  id uuid primary key default gen_random_uuid(),
  opening_id uuid not null references public.financial_opening_balances(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  side text not null check (side in ('debit','credit')),
  amount numeric(18,2) not null check (amount > 0),
  reference text,
  line_no integer not null default 0
);
create index if not exists fob_lines_opening_idx on public.financial_opening_balance_lines(opening_id);

-- updated_at triggers for editable drafts
do $$
declare t text;
begin
  foreach t in array array['purchases','expenses','supplier_payments','purchase_returns',
    'other_income_transactions','cash_transfers','financial_opening_balances'] loop
    execute format('drop trigger if exists trg_%1$s_updated on public.%1$s', t);
    execute format('create trigger trg_%1$s_updated before update on public.%1$s
                    for each row execute function public.set_updated_at()', t);
  end loop;
end $$;
