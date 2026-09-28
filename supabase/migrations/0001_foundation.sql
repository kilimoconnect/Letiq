-- =============================================================================
-- Letiq ERP - Migration 0001: Foundation (extensions, helpers, triggers)
-- =============================================================================
-- Idempotent. Safe to run more than once.

-- Helper functions below reference tables created in later migrations; allow
-- creating them before those tables exist.
set check_function_bodies = off;

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
