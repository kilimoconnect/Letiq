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
