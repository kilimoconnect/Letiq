-- =============================================================================
-- Letiq ERP - Migration 0017: Phase 3 Row Level Security
-- =============================================================================
-- Company-scoped reads; no client write policies (all mutations go through
-- service-role server actions that verify user/permission/branch access).

do $$
declare t text;
begin
  foreach t in array array[
    'purchases','expenses','supplier_payables','supplier_payments','purchase_returns',
    'supplier_credits','other_income_transactions','cash_transfers','financial_opening_balances'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using (public.has_company_access(company_id))', t||'_select', t);
  end loop;
end $$;

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

select public._rls_child_policy('purchase_lines','purchases','purchase_id');
select public._rls_child_policy('purchase_payments','purchases','purchase_id');
select public._rls_child_policy('expense_payments','expenses','expense_id');
select public._rls_child_policy('supplier_payment_funding','supplier_payments','payment_id');
select public._rls_child_policy('supplier_payment_allocations','supplier_payments','payment_id');
select public._rls_child_policy('purchase_return_lines','purchase_returns','return_id');
select public._rls_child_policy('purchase_return_settlements','purchase_returns','return_id');
select public._rls_child_policy('other_income_receipts','other_income_transactions','transaction_id');
select public._rls_child_policy('financial_opening_balance_lines','financial_opening_balances','opening_id');

drop function if exists public._rls_child_policy(text, text, text);
