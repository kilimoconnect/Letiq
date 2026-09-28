-- ============================================================================
-- Letiq ERP - Migration 0023: explicit Data API grants
-- ----------------------------------------------------------------------------
-- Newer Supabase projects no longer grant table/sequence/function privileges
-- to anon/authenticated/service_role for objects created via SQL. Without
-- these, even the service-role client gets "permission denied". Restore the
-- classic Supabase grants (RLS still governs anon/authenticated rows), then
-- re-apply the service-role-only restrictions on posting/internal functions.
-- Idempotent.
-- ============================================================================

grant usage on schema public to anon, authenticated, service_role;

grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;
grant execute on all functions in schema public to anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant usage, select on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;

-- Internal migration bookkeeping has no RLS: keep it off the Data API.
revoke all on table public.schema_migrations from anon, authenticated;

-- Re-apply service-role-only function restrictions (from 0009-0021).
do $$
declare fn text;
begin
  foreach fn in array array[
    -- 0009
    'next_document_number(uuid,uuid,text)',
    'record_stock_movement(uuid,uuid,uuid,text,text,uuid,text,numeric,numeric,numeric,uuid)',
    'adjust_in_transit(uuid,uuid,uuid,numeric)',
    'assert_period_open(uuid,date)',
    'resolve_payment_ledger(uuid,uuid)',
    'recalc_sale(uuid)',
    'claim_idempotency(text,text,uuid)',
    'account_id_by_code(uuid,text)',
    'create_journal(uuid,uuid,date,text,uuid,text,text,uuid,jsonb)',
    'post_inventory_opening(uuid,uuid,text)','void_inventory_opening(uuid,uuid,text)',
    'post_stock_adjustment(uuid,uuid,text)','void_stock_adjustment(uuid,uuid,text)',
    'post_sale(uuid,uuid,text)','void_sale(uuid,uuid,text)',
    'post_customer_receipt(uuid,uuid,text)','void_customer_receipt(uuid,uuid,text)',
    'post_sales_return(uuid,uuid,text)','void_sales_return(uuid,uuid,text)',
    'dispatch_stock_transfer(uuid,uuid,text)','receive_stock_transfer(uuid,uuid,jsonb,text)',
    'void_stock_transfer(uuid,uuid,text)',
    -- 0013
    'payment_account_balance(uuid)','overdraft_limit_on(uuid,date)',
    'assert_sufficient_funds(uuid,numeric,date)',
    -- 0016
    'norm_invoice(text)',
    'recalc_purchase(uuid)','recalc_expense(uuid)',
    'post_purchase(uuid,uuid,text)','void_purchase(uuid,uuid,text)',
    'post_expense(uuid,uuid,text)','void_expense(uuid,uuid,text)',
    'post_supplier_payment(uuid,uuid,text)','void_supplier_payment(uuid,uuid,text)',
    'post_other_income(uuid,uuid,text)','void_other_income(uuid,uuid,text)',
    'post_cash_transfer(uuid,uuid,text)','void_cash_transfer(uuid,uuid,text)',
    'post_financial_opening(uuid,uuid,text)','void_financial_opening(uuid,uuid,text)',
    'post_purchase_return(uuid,uuid,text)','void_purchase_return(uuid,uuid,text)',
    -- 0020
    'report_trial_balance(uuid,date,date)','report_account_balance(uuid,uuid,date)',
    'report_gl_lines(uuid,uuid,date,date)','report_cash_flow(uuid,date,date)',
    -- 0021
    'post_manual_journal(uuid,uuid,text,boolean)','void_manual_journal(uuid,uuid,text)',
    'post_accounting_opening(uuid,uuid,text)','void_accounting_opening(uuid,uuid,text)',
    'post_customer_opening(uuid,uuid,text)','post_supplier_opening(uuid,uuid,text)',
    'post_bank_adjustment(uuid,uuid,uuid,text,numeric,text,text,uuid)','void_bank_adjustment(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', fn);
    execute format('grant execute on function public.%s to service_role', fn);
  end loop;
end $$;
