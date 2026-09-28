-- =============================================================================
-- Letiq ERP - Migration 0008: Phase 2 transactional tables
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Idempotency + status history
-- ---------------------------------------------------------------------------
create table if not exists public.idempotency_keys (
  key        text primary key,
  operation  text not null,
  result_id  uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.transaction_status_history (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies(id) on delete restrict,
  source_type text not null,
  source_id   uuid not null,
  from_status text,
  to_status   text not null,
  reason      text,
  changed_by  uuid references auth.users(id) on delete set null,
  changed_at  timestamptz not null default now()
);
create index if not exists tsh_source_idx on public.transaction_status_history(source_type, source_id);

-- ---------------------------------------------------------------------------
-- SALES
-- ---------------------------------------------------------------------------
create table if not exists public.sales (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete restrict,
  branch_id        uuid not null references public.branches(id) on delete restrict,
  document_status  text not null default 'draft' check (document_status in ('draft','posted','voided')),
  payment_status   text not null default 'unpaid'
                     check (payment_status in ('unpaid','partially_paid','paid','refunded','partially_refunded')),
  document_number  text,
  document_date    date not null default current_date,
  due_date         date,
  customer_id      uuid not null references public.customers(id) on delete restrict,
  customer_reference text,
  salesperson_id   uuid references public.user_profiles(id) on delete set null,
  notes            text,
  is_credit        boolean not null default false,
  subtotal         numeric(18,2) not null default 0,
  discount_total   numeric(18,2) not null default 0,
  net_total        numeric(18,2) not null default 0,
  tax_total        numeric(18,2) not null default 0,
  grand_total      numeric(18,2) not null default 0,
  amount_paid      numeric(18,2) not null default 0,
  outstanding      numeric(18,2) not null default 0,
  cogs_total       numeric(18,2) not null default 0,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_by       uuid references auth.users(id) on delete set null,
  updated_at       timestamptz not null default now(),
  posted_by        uuid references auth.users(id) on delete set null,
  posted_at        timestamptz,
  voided_by        uuid references auth.users(id) on delete set null,
  voided_at        timestamptz,
  void_reason      text
);
create unique index if not exists sales_docnum_unique
  on public.sales(company_id, document_number) where document_number is not null;
create index if not exists sales_company_branch_idx on public.sales(company_id, branch_id, document_date);
create index if not exists sales_customer_idx on public.sales(customer_id);
create index if not exists sales_status_idx on public.sales(document_status, payment_status);

create table if not exists public.sale_lines (
  id            uuid primary key default gen_random_uuid(),
  sale_id       uuid not null references public.sales(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete restrict,
  description   text,
  quantity      numeric(18,4) not null check (quantity > 0),
  unit_price    numeric(18,2) not null check (unit_price >= 0),
  original_price numeric(18,2) not null default 0,
  discount      numeric(18,2) not null default 0 check (discount >= 0),
  tax_code_id   uuid references public.tax_codes(id) on delete set null,
  tax_rate      numeric(9,4) not null default 0,
  tax_type      text,
  tax_name      text,
  tax_inclusive boolean not null default false,
  net_amount    numeric(18,2) not null default 0,
  tax_amount    numeric(18,2) not null default 0,
  line_total    numeric(18,2) not null default 0,
  unit_cost     numeric(18,4) not null default 0,
  cogs          numeric(18,2) not null default 0,
  track_inventory boolean not null default true,
  line_no       integer not null default 0
);
create index if not exists sale_lines_sale_idx on public.sale_lines(sale_id);
create index if not exists sale_lines_product_idx on public.sale_lines(product_id);

create table if not exists public.sale_payments (
  id                 uuid primary key default gen_random_uuid(),
  sale_id            uuid not null references public.sales(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount             numeric(18,2) not null check (amount > 0),
  reference          text,
  payment_date       date not null default current_date,
  created_at         timestamptz not null default now()
);
create index if not exists sale_payments_sale_idx on public.sale_payments(sale_id);

-- ---------------------------------------------------------------------------
-- CUSTOMER RECEIPTS
-- ---------------------------------------------------------------------------
create table if not exists public.customer_receipts (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies(id) on delete restrict,
  branch_id          uuid not null references public.branches(id) on delete restrict,
  document_status    text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number    text,
  document_date      date not null default current_date,
  customer_id        uuid not null references public.customers(id) on delete restrict,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount             numeric(18,2) not null check (amount > 0),
  reference          text,
  notes              text,
  created_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  posted_by          uuid references auth.users(id) on delete set null,
  posted_at          timestamptz,
  voided_by          uuid references auth.users(id) on delete set null,
  voided_at          timestamptz,
  void_reason        text
);
create unique index if not exists receipts_docnum_unique
  on public.customer_receipts(company_id, document_number) where document_number is not null;
create index if not exists receipts_customer_idx on public.customer_receipts(customer_id);

create table if not exists public.customer_receipt_allocations (
  id         uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.customer_receipts(id) on delete cascade,
  sale_id    uuid not null references public.sales(id) on delete restrict,
  amount     numeric(18,2) not null check (amount > 0)
);
create index if not exists receipt_alloc_receipt_idx on public.customer_receipt_allocations(receipt_id);
create index if not exists receipt_alloc_sale_idx on public.customer_receipt_allocations(sale_id);

-- ---------------------------------------------------------------------------
-- SALES RETURNS
-- ---------------------------------------------------------------------------
create table if not exists public.sales_returns (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete restrict,
  branch_id           uuid not null references public.branches(id) on delete restrict,
  sale_id             uuid not null references public.sales(id) on delete restrict,
  document_status     text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number     text,
  document_date       date not null default current_date,
  customer_id         uuid not null references public.customers(id) on delete restrict,
  reason              text not null,
  notes               text,
  refund_method       text not null default 'receivable' check (refund_method in ('payment_account','receivable','mixed')),
  net_total           numeric(18,2) not null default 0,
  tax_total           numeric(18,2) not null default 0,
  total               numeric(18,2) not null default 0,
  refund_amount       numeric(18,2) not null default 0,
  receivable_reduction numeric(18,2) not null default 0,
  cogs_restored       numeric(18,2) not null default 0,
  created_by          uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null,
  updated_at          timestamptz not null default now(),
  posted_by           uuid references auth.users(id) on delete set null,
  posted_at           timestamptz,
  voided_by           uuid references auth.users(id) on delete set null,
  voided_at           timestamptz,
  void_reason         text
);
create unique index if not exists returns_docnum_unique
  on public.sales_returns(company_id, document_number) where document_number is not null;
create index if not exists returns_sale_idx on public.sales_returns(sale_id);

create table if not exists public.sales_return_lines (
  id           uuid primary key default gen_random_uuid(),
  return_id    uuid not null references public.sales_returns(id) on delete cascade,
  sale_line_id uuid not null references public.sale_lines(id) on delete restrict,
  product_id   uuid not null references public.products(id) on delete restrict,
  quantity     numeric(18,4) not null check (quantity > 0),
  unit_price   numeric(18,2) not null default 0,
  tax_rate     numeric(9,4) not null default 0,
  net_amount   numeric(18,2) not null default 0,
  tax_amount   numeric(18,2) not null default 0,
  line_total   numeric(18,2) not null default 0,
  unit_cost    numeric(18,4) not null default 0,
  cogs_reversal numeric(18,2) not null default 0,
  condition    text not null default 'saleable' check (condition in ('saleable','damaged')),
  track_inventory boolean not null default true,
  line_no      integer not null default 0
);
create index if not exists return_lines_return_idx on public.sales_return_lines(return_id);

create table if not exists public.sales_return_refunds (
  id                 uuid primary key default gen_random_uuid(),
  return_id          uuid not null references public.sales_returns(id) on delete cascade,
  payment_account_id uuid not null references public.payment_accounts(id) on delete restrict,
  amount             numeric(18,2) not null check (amount > 0),
  reference          text,
  refund_date        date not null default current_date
);

-- ---------------------------------------------------------------------------
-- INVENTORY OPENINGS
-- ---------------------------------------------------------------------------
create table if not exists public.inventory_openings (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete restrict,
  branch_id       uuid not null references public.branches(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  opening_date    date not null default current_date,
  reference       text,
  description     text,
  total_cost      numeric(18,2) not null default 0,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id) on delete set null,
  updated_at      timestamptz not null default now(),
  posted_by       uuid references auth.users(id) on delete set null,
  posted_at       timestamptz,
  voided_by       uuid references auth.users(id) on delete set null,
  voided_at       timestamptz,
  void_reason     text
);
create unique index if not exists openings_docnum_unique
  on public.inventory_openings(company_id, document_number) where document_number is not null;

create table if not exists public.inventory_opening_lines (
  id         uuid primary key default gen_random_uuid(),
  opening_id uuid not null references public.inventory_openings(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity   numeric(18,4) not null check (quantity > 0),
  unit_cost  numeric(18,4) not null check (unit_cost >= 0),
  total_cost numeric(18,2) not null default 0,
  line_no    integer not null default 0
);
create index if not exists opening_lines_opening_idx on public.inventory_opening_lines(opening_id);

-- ---------------------------------------------------------------------------
-- STOCK ADJUSTMENTS
-- ---------------------------------------------------------------------------
create table if not exists public.stock_adjustments (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id) on delete restrict,
  branch_id       uuid not null references public.branches(id) on delete restrict,
  document_status text not null default 'draft' check (document_status in ('draft','posted','voided')),
  document_number text,
  adjustment_date date not null default current_date,
  direction       text not null check (direction in ('increase','decrease')),
  reason          text not null,
  description     text,
  reference       text,
  total_value     numeric(18,2) not null default 0,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id) on delete set null,
  updated_at      timestamptz not null default now(),
  posted_by       uuid references auth.users(id) on delete set null,
  posted_at       timestamptz,
  voided_by       uuid references auth.users(id) on delete set null,
  voided_at       timestamptz,
  void_reason     text
);
create unique index if not exists adjustments_docnum_unique
  on public.stock_adjustments(company_id, document_number) where document_number is not null;

create table if not exists public.stock_adjustment_lines (
  id            uuid primary key default gen_random_uuid(),
  adjustment_id uuid not null references public.stock_adjustments(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete restrict,
  quantity      numeric(18,4) not null check (quantity > 0),
  unit_cost     numeric(18,4) not null default 0,
  total_value   numeric(18,2) not null default 0,
  line_no       integer not null default 0
);
create index if not exists adjustment_lines_adj_idx on public.stock_adjustment_lines(adjustment_id);

-- ---------------------------------------------------------------------------
-- STOCK TRANSFERS
-- ---------------------------------------------------------------------------
create table if not exists public.stock_transfers (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id) on delete restrict,
  source_branch_id    uuid not null references public.branches(id) on delete restrict,
  destination_branch_id uuid not null references public.branches(id) on delete restrict,
  status              text not null default 'draft'
                        check (status in ('draft','dispatched','partially_received','received','voided')),
  document_number     text,
  transfer_date       date not null default current_date,
  expected_date       date,
  reference           text,
  notes               text,
  created_by          uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null,
  updated_at          timestamptz not null default now(),
  dispatched_by       uuid references auth.users(id) on delete set null,
  dispatched_at       timestamptz,
  voided_by           uuid references auth.users(id) on delete set null,
  voided_at           timestamptz,
  void_reason         text,
  check (source_branch_id <> destination_branch_id)
);
create unique index if not exists transfers_docnum_unique
  on public.stock_transfers(company_id, document_number) where document_number is not null;

create table if not exists public.stock_transfer_lines (
  id            uuid primary key default gen_random_uuid(),
  transfer_id   uuid not null references public.stock_transfers(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete restrict,
  qty_requested numeric(18,4) not null check (qty_requested > 0),
  qty_dispatched numeric(18,4) not null default 0 check (qty_dispatched >= 0),
  qty_received  numeric(18,4) not null default 0 check (qty_received >= 0),
  unit_cost     numeric(18,4) not null default 0,
  line_no       integer not null default 0
);
create index if not exists transfer_lines_transfer_idx on public.stock_transfer_lines(transfer_id);

-- ---------------------------------------------------------------------------
-- updated_at triggers for editable draft headers
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['sales','sales_returns','inventory_openings','stock_adjustments','stock_transfers'] loop
    execute format('drop trigger if exists trg_%1$s_updated on public.%1$s', t);
    execute format('create trigger trg_%1$s_updated before update on public.%1$s
                    for each row execute function public.set_updated_at()', t);
  end loop;
end $$;
