-- =============================================================================
-- Letiq ERP - Migration 0022: Phase 4 Row Level Security
-- =============================================================================
-- Company-scoped reads; no client write policies (all mutations via service-
-- role server actions that verify user/permission). Posted journals remain
-- immutable via the Phase 2 triggers.

do $$
declare t text;
begin
  foreach t in array array[
    'manual_journal_drafts','accounting_opening_balances','customer_opening_balances',
    'supplier_opening_balances','bank_reconciliations','accounting_period_events'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('drop policy if exists %I on public.%I', t||'_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.has_company_access(company_id))', t||'_select', t);
  end loop;
end $$;

create or replace function public._rls_child_policy(child text, parent text, fk text)
returns void language plpgsql as $$
begin
  execute format('alter table public.%I enable row level security', child);
  execute format('alter table public.%I force row level security', child);
  execute format('drop policy if exists %I on public.%I', child||'_select', child);
  execute format($f$create policy %I on public.%I for select to authenticated
    using (exists (select 1 from public.%I p where p.id = public.%I.%I and public.has_company_access(p.company_id)))$f$,
    child||'_select', child, parent, child, fk);
end $$;

select public._rls_child_policy('manual_journal_draft_lines','manual_journal_drafts','draft_id');
select public._rls_child_policy('accounting_opening_balance_lines','accounting_opening_balances','opening_id');
select public._rls_child_policy('bank_statement_lines','bank_reconciliations','reconciliation_id');
select public._rls_child_policy('bank_reconciliation_matches','bank_reconciliations','reconciliation_id');
select public._rls_child_policy('bank_reconciliation_adjustments','bank_reconciliations','reconciliation_id');

-- period close checks: visible when the period's company is accessible
alter table public.accounting_period_close_checks enable row level security;
alter table public.accounting_period_close_checks force row level security;
drop policy if exists apcc_select on public.accounting_period_close_checks;
create policy apcc_select on public.accounting_period_close_checks for select to authenticated
  using (exists (select 1 from public.accounting_periods ap where ap.id = accounting_period_close_checks.period_id and public.has_company_access(ap.company_id)));

drop function if exists public._rls_child_policy(text, text, text);
