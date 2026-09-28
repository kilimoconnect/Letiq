-- =============================================================================
-- Letiq ERP - Migration 0010: Phase 2 Row Level Security
-- =============================================================================
-- Reads are scoped to companies the user can access (Owner = all). No client
-- write policies exist: every mutation goes through service-role server actions
-- that have already verified the user, permission and branch access. Posted
-- ledgers (stock_movements, journal_*) are additionally immutable via triggers.
-- Branch-level restriction is enforced in the server-action layer.

-- Parent tables with a company_id: SELECT by company access.
do $$
declare t text;
begin
  foreach t in array array[
    'stock_balances','stock_movements','sales','customer_receipts','sales_returns',
    'inventory_openings','stock_adjustments','stock_transfers','journal_entries',
    'transaction_status_history'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using (public.has_company_access(company_id))', t||'_select', t);
  end loop;
end $$;

-- Child tables: SELECT when the parent is visible.
create or replace function public._rls_child_policy(child text, parent text, fk text)
returns void language plpgsql as $$
begin
  execute format('alter table public.%I enable row level security', child);
  execute format('alter table public.%I force row level security', child);
  execute format('drop policy if exists %I on public.%I', child||'_select', child);
  execute format($f$create policy %I on public.%I for select to authenticated
    using (exists (select 1 from public.%I p
      where p.id = public.%I.%I and public.has_company_access(p.company_id)))$f$,
    child||'_select', child, parent, child, fk);
end $$;

select public._rls_child_policy('sale_lines','sales','sale_id');
select public._rls_child_policy('sale_payments','sales','sale_id');
select public._rls_child_policy('customer_receipt_allocations','customer_receipts','receipt_id');
select public._rls_child_policy('sales_return_lines','sales_returns','return_id');
select public._rls_child_policy('sales_return_refunds','sales_returns','return_id');
select public._rls_child_policy('inventory_opening_lines','inventory_openings','opening_id');
select public._rls_child_policy('stock_adjustment_lines','stock_adjustments','adjustment_id');
select public._rls_child_policy('stock_transfer_lines','stock_transfers','transfer_id');

-- journal_lines: visible when the journal is visible.
alter table public.journal_lines enable row level security;
alter table public.journal_lines force row level security;
drop policy if exists journal_lines_select on public.journal_lines;
create policy journal_lines_select on public.journal_lines for select to authenticated
  using (exists (select 1 from public.journal_entries j
    where j.id = journal_lines.journal_id and public.has_company_access(j.company_id)));

-- idempotency_keys: internal only, no client access (service role bypasses RLS).
alter table public.idempotency_keys enable row level security;
alter table public.idempotency_keys force row level security;

drop function if exists public._rls_child_policy(text, text, text);
