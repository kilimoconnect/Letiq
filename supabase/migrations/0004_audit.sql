-- =============================================================================
-- Letiq ERP - Migration 0004: Immutable audit log
-- =============================================================================

create table if not exists public.audit_logs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete set null,
  company_id    uuid references public.companies(id) on delete set null,
  branch_id     uuid references public.branches(id) on delete set null,
  action        text not null,
  resource_type text not null,
  resource_id   text,
  old_values    jsonb,
  new_values    jsonb,
  reason        text,
  ip_address    text,
  user_agent    text,
  created_at    timestamptz not null default now()
);

create index if not exists audit_logs_created_idx  on public.audit_logs(created_at desc);
create index if not exists audit_logs_user_idx     on public.audit_logs(user_id);
create index if not exists audit_logs_company_idx  on public.audit_logs(company_id);
create index if not exists audit_logs_resource_idx on public.audit_logs(resource_type, resource_id);

-- Hard immutability: block UPDATE/DELETE for everyone, including the service
-- role (which bypasses RLS). Records can only ever be inserted.
create or replace function public.audit_logs_block_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Audit log records are immutable and cannot be % ', TG_OP
    using errcode = '0A000';
  return null;
end;
$$;

drop trigger if exists trg_audit_logs_no_update on public.audit_logs;
create trigger trg_audit_logs_no_update
  before update on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();

drop trigger if exists trg_audit_logs_no_delete on public.audit_logs;
create trigger trg_audit_logs_no_delete
  before delete on public.audit_logs
  for each row execute function public.audit_logs_block_mutation();
