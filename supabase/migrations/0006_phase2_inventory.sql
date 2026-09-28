-- =============================================================================
-- Letiq ERP - Migration 0006: Phase 2 inventory ledger & costing
-- =============================================================================
-- Weighted-average cost per (company, branch, product). The stock_movements
-- ledger is the immutable source of truth; stock_balances is a maintained
-- projection that reconciles to it.

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- STOCK BALANCES (projection)
-- ---------------------------------------------------------------------------
create table if not exists public.stock_balances (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references public.companies(id) on delete restrict,
  branch_id        uuid not null references public.branches(id) on delete restrict,
  product_id       uuid not null references public.products(id) on delete restrict,
  quantity         numeric(18,4) not null default 0,
  avg_unit_cost    numeric(18,4) not null default 0,
  stock_value      numeric(18,2) not null default 0,
  qty_in_transit   numeric(18,4) not null default 0,
  last_movement_at timestamptz,
  updated_at       timestamptz not null default now(),
  unique (company_id, branch_id, product_id),
  check (quantity >= 0),
  check (qty_in_transit >= 0)
);
create index if not exists stock_balances_company_branch_idx
  on public.stock_balances(company_id, branch_id);
create index if not exists stock_balances_product_idx on public.stock_balances(product_id);

-- ---------------------------------------------------------------------------
-- STOCK MOVEMENTS (immutable ledger)
-- ---------------------------------------------------------------------------
create table if not exists public.stock_movements (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id) on delete restrict,
  branch_id      uuid not null references public.branches(id) on delete restrict,
  product_id     uuid not null references public.products(id) on delete restrict,
  movement_type  text not null check (movement_type in (
                   'opening','sale','sale_void','sales_return','sales_return_void',
                   'adjustment_increase','adjustment_decrease','adjustment_void',
                   'transfer_out','transfer_in','transfer_void',
                   'purchase','purchase_return')),
  source_type    text not null,
  source_id      uuid,
  source_number  text,
  qty_in         numeric(18,4) not null default 0 check (qty_in >= 0),
  qty_out        numeric(18,4) not null default 0 check (qty_out >= 0),
  unit_cost      numeric(18,4) not null default 0,
  movement_value numeric(18,2) not null default 0,
  balance_qty    numeric(18,4) not null,
  avg_cost_after numeric(18,4) not null,
  balance_value  numeric(18,2) not null,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists stock_movements_scope_idx
  on public.stock_movements(company_id, branch_id, product_id, created_at);
create index if not exists stock_movements_source_idx
  on public.stock_movements(source_type, source_id);
create index if not exists stock_movements_type_idx on public.stock_movements(movement_type);

-- Immutability: movements can only be inserted.
create or replace function public.block_mutation()
returns trigger language plpgsql as $$
begin
  raise exception '% records are immutable', TG_TABLE_NAME using errcode = '0A000';
  return null;
end; $$;

drop trigger if exists trg_stock_movements_no_update on public.stock_movements;
create trigger trg_stock_movements_no_update before update or delete on public.stock_movements
  for each row execute function public.block_mutation();

-- ---------------------------------------------------------------------------
-- Atomic document-number generator (locks the sequence row).
-- ---------------------------------------------------------------------------
create or replace function public.next_document_number(
  p_company uuid, p_branch uuid, p_doc_type text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  seq public.document_sequences;
  n bigint;
begin
  select * into seq from public.document_sequences
    where company_id = p_company
      and document_type = p_doc_type
      and (branch_id = p_branch or branch_id is null)
      and is_active
    order by branch_id nulls last
    limit 1
    for update;
  if not found then
    raise exception 'No active document sequence for % in this company', p_doc_type
      using errcode = 'P0001';
  end if;
  n := seq.current_number + 1;
  update public.document_sequences set current_number = n, updated_at = now()
    where id = seq.id;
  return seq.prefix || lpad(n::text, seq.number_length, '0');
end; $$;

-- ---------------------------------------------------------------------------
-- Record one stock movement and update the weighted-average balance.
-- Locks the balance row. Returns the movement value (for outgoing = COGS).
-- Raises on negative stock.
-- ---------------------------------------------------------------------------
create or replace function public.record_stock_movement(
  p_company uuid, p_branch uuid, p_product uuid,
  p_movement_type text, p_source_type text, p_source_id uuid, p_source_number text,
  p_qty_in numeric, p_qty_out numeric, p_in_unit_cost numeric, p_user uuid
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  bal public.stock_balances;
  new_qty numeric(18,4);
  new_value numeric(18,2);
  new_avg numeric(18,4);
  move_cost numeric(18,4);
  move_value numeric(18,2);
begin
  select * into bal from public.stock_balances
    where company_id = p_company and branch_id = p_branch and product_id = p_product
    for update;
  if not found then
    insert into public.stock_balances(company_id, branch_id, product_id)
      values (p_company, p_branch, p_product)
      returning * into bal;
  end if;

  if coalesce(p_qty_in,0) > 0 then
    move_cost := coalesce(p_in_unit_cost, 0);
    move_value := round(p_qty_in * move_cost, 2);
    new_qty := bal.quantity + p_qty_in;
    new_value := bal.stock_value + move_value;
    if new_qty > 0 then new_avg := round(new_value / new_qty, 4); else new_avg := bal.avg_unit_cost; end if;
  elsif coalesce(p_qty_out,0) > 0 then
    if bal.quantity - p_qty_out < 0 then
      raise exception 'Insufficient stock (available %, requested %)', bal.quantity, p_qty_out
        using errcode = 'P0001';
    end if;
    move_cost := bal.avg_unit_cost;
    move_value := round(p_qty_out * move_cost, 2);
    new_qty := bal.quantity - p_qty_out;
    new_value := bal.stock_value - move_value;
    new_avg := bal.avg_unit_cost;
    if new_qty = 0 then new_value := 0; end if;
  else
    return 0;
  end if;

  insert into public.stock_movements(
    company_id, branch_id, product_id, movement_type, source_type, source_id, source_number,
    qty_in, qty_out, unit_cost, movement_value, balance_qty, avg_cost_after, balance_value, created_by)
  values (
    p_company, p_branch, p_product, p_movement_type, p_source_type, p_source_id, p_source_number,
    coalesce(p_qty_in,0), coalesce(p_qty_out,0), move_cost, move_value, new_qty, new_avg, new_value, p_user);

  update public.stock_balances
    set quantity = new_qty, avg_unit_cost = new_avg, stock_value = new_value,
        last_movement_at = now(), updated_at = now()
    where id = bal.id;

  return move_value;
end; $$;

-- Adjust in-transit quantity (transfers). Never below zero.
create or replace function public.adjust_in_transit(
  p_company uuid, p_branch uuid, p_product uuid, p_delta numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.stock_balances(company_id, branch_id, product_id, qty_in_transit)
    values (p_company, p_branch, p_product, greatest(p_delta, 0))
  on conflict (company_id, branch_id, product_id) do update
    set qty_in_transit = greatest(public.stock_balances.qty_in_transit + p_delta, 0),
        updated_at = now();
end; $$;
