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
