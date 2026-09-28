# Letiq ERP

ERP and accounting system for **Letiq Limited**.

This repository implements **Phase 1 — System Foundation** (auth, RBAC, master data),
**Phase 2 — Sales, Customer Payments, Inventory & Kardex**, and **Phase 3 — Purchases,
Supplier Payments, Purchase Returns, Expenses, Other Income, Cash Transfers and
Payment-Account Ledgers**. Full financial statements, bank reconciliation, manual journals,
budgets, payroll and multi-currency are intentionally **deferred to Phase 4**.

- Base currency: **TZS** · Timezone: **Africa/Dar_es_Salaam** · Dates: **DD/MM/YYYY**
- Multi-company ready (starts with one company: `LETIQ`).

## Tech stack

- Next.js 16 (App Router) + React 19, TypeScript (strict)
- Tailwind CSS v4, hand-built shadcn-style UI on Radix primitives
- Supabase (PostgreSQL + Auth), Row Level Security
- React Hook Form–style forms with server-side Zod/validation
- Postgres migrations & seeds run with `pg` + `tsx`

> **Windows note:** this machine's native `@next/swc` binary is zeroed by antivirus
> ("not a valid Win32 application"). The `dev` and `build` scripts use `--webpack`,
> which runs fine on the WASM SWC fallback. On a clean machine you can remove
> `--webpack`. See `.claude` memory `flutter-sdk-corruption` for the repair steps.

---

## 1. Local setup

```bash
npm install
cp .env.example .env.local   # then fill in the values (see below)
```

### Environment variables

| Variable | Where | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | browser + server | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | browser + server | Anon/publishable key |
| `SUPABASE_SERVICE_ROLE_KEY` | **server only** | Full-access key; never sent to the browser |
| `DATABASE_URL` | scripts only | Direct Postgres connection for migrations/seed |
| `OWNER_EMAIL` | scripts | Email that becomes the protected Owner |
| `OWNER_INITIAL_PASSWORD` | scripts (optional) | Password used only if the Owner auth user must be created |
| `NEXT_PUBLIC_APP_NAME` / `NEXT_PUBLIC_COMPANY_NAME` | app | Display strings |

`.env.local` is git-ignored. Only `.env.example` (no secrets) is committed.

## 2. Supabase setup

1. Create / open the Supabase project.
2. Get the keys from **Project Settings → API** (`anon` and `service_role`).
3. Get `DATABASE_URL` from **Project Settings → Database → Connection string (URI)**
   (URL-encode special characters in the password).
4. Paste all four into `.env.local`.

## 3. Migrations

Migrations live in `supabase/migrations/*.sql` and are applied in order. They are
idempotent and tracked in a `schema_migrations` table.

```bash
npm run db:migrate
```

| File | Contents |
| --- | --- |
| `0001_foundation.sql` | Extensions, `updated_at` trigger, cross-company & COA triggers, auth helper functions |
| `0002_identity_rbac.sql` | `companies`, `branches`, `roles`, `permissions`, `role_permissions`, `user_profiles`, access tables |
| `0003_master_data.sql` | Units, categories, brands, chart of accounts, tax codes, payment accounts, products, customers, suppliers, expense/income types, document sequences, accounting periods |
| `0004_audit.sql` | Immutable `audit_logs` (update/delete blocked by triggers) |
| `0005_rls.sql` | Row Level Security policies for every table |

## 4. Seed

Idempotent — safe to run repeatedly.

```bash
npm run db:seed
```

Seeds: all permissions & the 6 default roles; company `LETIQ`; branch `HQ` (head office);
units (Piece, Litre, Kilogram, Bag, Carton); a hierarchical chart of accounts; tax codes
(VAT 18%, Zero, Exempt); payment accounts (Cash, NMB, CRDB, MIX, M-Pesa); the protected
`WALK-IN` customer; document-number sequences; and the current-year accounting period.

## 5. Owner bootstrap

```bash
npm run bootstrap:owner
```

Finds (or creates, using `OWNER_INITIAL_PASSWORD`) the auth user for `OWNER_EMAIL`, then
gives them the protected **Owner** role, company/branch access and `is_primary_owner`.
Run **after** migrate + seed. The primary Owner cannot be deleted, deactivated or downgraded.

Full first-time sequence:

```bash
npm run db:migrate
npm run db:seed
npm run bootstrap:owner
```

## 6. Run

```bash
npm run dev            # http://localhost:3000
# or
npm run build && npm run start
```

Sign in at `/sign-in` with the Owner email and password.

## 7. User invitation process

There is **no public sign-up**. The Owner creates users under **Admin → Users**:
set email, name, initial password, role (the Owner role cannot be assigned here),
companies, branches and default branch. Users can change their own password under
**My Account**, and the Owner can trigger a password-reset email. Inactive users
cannot sign in.

## 8. Permission model

- **Roles** (`roles`) ↔ **permissions** (`permissions`, `resource.action`) via
  `role_permissions`. Each user has one role (`user_profiles.role_id`) plus explicit
  company access (`user_company_access`) and branch access (`user_branch_access`).
- Resources are scaffolded for every planned module; Phase 1 enforces Admin, Users,
  Roles and Audit-log permissions (Owner-only). Future Owner-only permissions
  `transactions.delete_draft` and `transactions.void` are seeded. There is **no**
  "delete posted transaction" permission.
- Server helpers in `src/lib/auth/guards.ts`: `requireUser`, `requireActiveUser`,
  `requireOwnerPage`, `requirePermissionPage` (redirecting page guards) and
  `assertActiveUser`, `assertOwner`, `assertCompanyAccess`, `assertBranchAccess`,
  `assertPermission` (throwing guards for server actions).

## 9. Row Level Security

RLS is enabled and **forced** on every table:

- Company-scoped tables: readable when the user has access to the row's company
  (`has_company_access`, Owner sees all); insert/update/delete **Owner-only**.
- `roles`/`permissions`/`role_permissions`: readable by any authenticated user; writes Owner-only.
- `user_profiles` and access tables: a user reads their own rows; Owner reads/writes all.
- `audit_logs`: Owner-only read; no write policy (only the service role inserts) and
  update/delete are blocked by triggers even for the service role.

Server actions re-verify identity and Owner authorization in code, and use the
trusted server identity for `created_by`/`updated_by` and `company_id` — browser-supplied
role/company/branch ids are never trusted.

## 10. Test & build commands

```bash
npm run typecheck        # tsc --noEmit
npm run test             # pure calculation unit tests (tax, weighted-average)
npm run test:integration # end-to-end posting test against the DB (BEGIN..ROLLBACK, no data kept)
npm run build            # production build (webpack on this machine)
npm run lint
```

---

# Phase 2 — Sales, Customer Payments, Inventory & Kardex

## Setup
Phase 2 adds migrations `0006`–`0012`. On an existing Phase 1 database:

```bash
npm run db:migrate   # applies 0006-0012 (idempotent)
npm run db:seed      # registers the new Phase 2 permissions & role grants
```

The seed adds fine-grained permissions (`sales.view_cost`, `sales.override_price`,
`sales.sell_below_cost`, `sales.receive_payment`, `sales.create_return`,
`inventory.view_cost`, `inventory.view_kardex`, `inventory.opening_balance`,
`inventory.adjustment_create/adjustment_post`, `inventory.transfer_create/dispatch/receive`)
and maps them to the default roles. `transactions.delete_draft` and `transactions.void`
remain Owner-only.

## Atomic posting (RPC functions)
Every posting operation runs inside **one PostgreSQL function** (a single transaction):
it locks stock and sequence rows, recalculates all totals on the server, writes stock,
kardex, journal, payment and status records together, and is guarded by an idempotency
key. Functions are `SECURITY DEFINER` with a fixed `search_path`, and `EXECUTE` is granted
only to `service_role` (called by trusted server actions after the user, permission and
branch access have been verified). Functions: `post_inventory_opening`, `post_stock_adjustment`,
`post_sale`, `post_customer_receipt`, `post_sales_return`, `dispatch_stock_transfer`,
`receive_stock_transfer`, and matching `void_*`, plus helpers `record_stock_movement`
(weighted-average costing), `next_document_number`, `create_journal`, `recalc_sale`.

## Inventory costing
**Weighted-average by (company, branch, product).** Incoming stock:
`new avg = (old value + qty×cost) / (old qty + qty)`. Outgoing uses the average *before*
the movement and stores that cost on the movement (COGS). The immutable `stock_movements`
ledger is the source of truth; `stock_balances` is a reconciling projection. Negative stock
is blocked; a sale cannot post without sufficient stock; non-`track_inventory` products
create no stock or COGS entries.

## Accounting entries
- **Sale:** Dr Cash/Bank/MoMo (received) + Dr A/R (unpaid); Cr Sales Revenue (net); Cr Output
  VAT (tax). Tracked lines also Dr COGS / Cr Inventory. Debits always equal credits.
- **Customer receipt:** Dr payment account; Cr A/R.
- **Sales return:** Dr Sales Returns (net) + Dr Output VAT reversal; Cr payment account / A/R.
  Saleable returns also Dr Inventory / Cr COGS at the original captured cost.
- **Opening balance:** Dr Inventory; Cr Opening Balance Equity.
- **Adjustment +:** Dr Inventory / Cr Inventory Adjustment Gain. **Adjustment −:** Dr Inventory
  Shrinkage / Cr Inventory. **Transfers** create no GL journal (ownership unchanged).

## Workflows
- **Opening stock:** Owner creates a draft, posts it → stock-in movements + balanced journal.
- **Sales:** create a draft (no stock/GL effect) → Post allocates the invoice number and does
  everything atomically. Payment status (unpaid / partial / paid / refunded) is server-computed.
- **Customer payments:** pick a customer, allocate the receipt across their outstanding invoices
  (allocations must equal the amount — no overpayment), Post settles the invoices.
- **Sales returns:** reference a posted sale; quantities capped at sold − prior returns; original
  price/tax/cost come from the sale line; saleable stock is restored at original cost.
- **Adjustments:** increase (needs cost) / decrease (uses current average); reason mandatory.
- **Transfers:** draft → dispatch (stock out of source, into transit) → receive (partial allowed).

## Voiding rules
Only the Owner can void posted documents. Voids require a reason, reverse stock and accounting,
keep the original visible, and never reuse a number. A sale cannot be voided while it has posted
receipts or returns — reverse those first. Posted documents and ledgers are never hard-deleted.

## Routes added
`/sales/new`, `/sales/history`, `/sales/[id]`, `/sales/[id]/return`, `/sales/customer-payments`,
`/sales/customer-payments/new`, `/inventory`, `/inventory/kardex`, `/inventory/opening-balances`,
`/inventory/adjustments`, `/inventory/transfers`, `/inventory/transfers/[id]`, plus printable
`/invoice/[id]` and `/receipt/[id]`.

## Tables added
`stock_balances`, `stock_movements`, `journal_entries`, `journal_lines`, `inventory_openings(+lines)`,
`stock_adjustments(+lines)`, `stock_transfers(+lines)`, `sales(+lines)`, `sale_payments`,
`customer_receipts(+allocations)`, `sales_returns(+lines,+refunds)`, `transaction_status_history`,
`idempotency_keys`. RLS is enabled and forced on all of them: reads are company-scoped, and there
are no client write policies (all mutations flow through service-role server actions).

## Testing
`npm run test` (calculation units) and `npm run test:integration` (posts an opening, sale, receipt
and return through the real RPCs and asserts stock, weighted-average cost, balanced journals,
duplicate-post and insufficient-stock rejection — all inside a transaction that rolls back).

---

# Phase 3 — Purchases, Expenses, Other Income & Cash

## Setup
Adds migrations `0013`–`0018`. On an existing Phase 2 database:

```bash
npm run db:migrate                 # applies 0013-0018 (idempotent)
npm run db:seed                    # registers Phase 3 permissions & role grants
npm run test:phase3                # posting integration test (rolls back)
```

`0013` also gives each seeded payment account its **own** ledger account (NMB/CRDB were
sharing "Bank"), so per-account balances and ledgers derive cleanly from journal lines.

## Account mapping requirements
Posting is blocked if a required account is missing. Phase 3 adds protected accounts
**1170 Supplier Credits**, **5200 Purchase Returns**, **5300 Purchase Price Variance**
(seeded idempotently), and uses existing **1150 Inventory**, **1160 Input VAT**,
**2110 Accounts Payable**, **6100 Operating Expenses**, **6200 Bank/Mobile Charges**,
**4200 Other Income**, **2120 Output VAT**, **3200 Opening Balance Equity**. Expense
categories and other-income types should map to a ledger account (they fall back to 6100 / 4200).

## Purchase accounting
For tracked products: **Dr Inventory** (net + non-recoverable tax) + **Dr Input VAT**
(recoverable only); **Cr** payment accounts (paid) + **Cr Accounts Payable** (unpaid).
Recoverable VAT is **excluded** from inventory cost; weighted-average cost updates with the
inventory value only. Non-inventory lines debit Operating Expenses. Duplicate supplier invoice
numbers (normalized) are rejected at posting.

## Purchase-return costing
Inventory is removed at the **current** weighted-average carrying cost. The supplier credit
uses the **original** purchase price/tax snapshot. Any difference posts to **Purchase Price
Variance** so the average cost is never distorted. Settlement: reduce payable / supplier credit
/ immediate refund / mixed.

## Supplier-payment allocation
A payment funds from one or more payment accounts and allocates across the supplier's open
**supplier_payables** (from purchases and expenses). Funding must equal allocations — no
supplier advance in Phase 3. Each allocation is capped at the payable's outstanding. Accounting:
**Dr Accounts Payable / Cr** funding accounts. Payment statuses recalc automatically.

## Expense accounting
**Dr** expense account (net + non-recoverable tax) + **Dr Input VAT** (recoverable);
**Cr** payments + **Cr Accounts Payable** (unpaid). Supports paid / partial / credit.

## Other-income accounting
Fully received when posted: **Dr** payment accounts / **Cr** Other Income (net) + **Cr Output
VAT** (if taxable). Never touches inventory or sales.

## Cash-transfer accounting
**Dr** destination (amount) + **Dr** Bank/Mobile Charges (fee); **Cr** source (amount + fee).
The source must have sufficient funds (respecting any Owner-configured overdraft). Transfers are
not income/expense (only the fee is an expense) and are not double-counted in company totals.

## Opening-balance workflow
Owner-only. Each line: a payment account + debit/credit + amount. Posted as a balanced journal
against **Opening Balance Equity**; appears in the account ledger. Not stored as an editable
field on the account.

## Payment-account balances & ledger
Balances are **derived** from posted journal lines (`payment_account_balance()`), never stored
editable. The ledger (`/cash-and-banks/accounts/[id]`) is an immutable running-balance view of
every posted journal line hitting that account. Available balance adds an approved overdraft.

## Overdraft settings
Owner-only (audited). Cash/mobile accounts default to no negative balance; a bank account may go
negative only within a configured overdraft limit and date window. Transfers and supplier
payments enforce the limit.

## Permissions
`purchases.{view,create,edit_draft,post,view_cost,record_payment,create_return,export}`,
`expenses.{view,create,edit_draft,post,export}`, `other_income.{...}`,
`cash_accounts.{view,view_balance,view_ledger,opening_balance}`,
`cash_transfers.{view,create,edit_draft,post,export}`. `transactions.delete_draft` and
`transactions.void` remain **Owner-only**.

## Voiding & dependencies
Only the Owner voids posted documents (reason required; reversing journal + inventory).
A purchase cannot be voided while it has posted supplier payments or purchase returns (reverse
those first) or if removing its stock would go negative. A cash transfer void is blocked if the
destination lacks the funds to give back.

---

# Phase 4 — Core Accounting, Financial Reports & Controls

## Accounting architecture
Every posted operational transaction (sale, purchase, expense, income, transfer, receipt,
return) writes a **balanced journal entry** via the Phase 2/3 posting RPCs. Phase 4 adds the
reporting and control layer on top: **all financial statements are generated from posted
`journal_lines`**, never recomputed from the operational tables. Subledgers (customers,
suppliers, stock, payment accounts) provide detail and are reconciled to the GL on the
Reconciliation Controls page. Reversal journals are ordinary journals and are included by
date — reports follow journal movements, not source-document status.

## Setup
Adds migrations `0019`–`0022`. On an existing Phase 3 database:
```bash
npm run db:migrate      # 0019 schema, 0020 report fns, 0021 posting RPCs, 0022 RLS
npm run db:seed         # Phase 4 permissions + role grants
npm run test:phase4     # accounting integration test (rolls back)
```
`0019` adds a `cashflow_class` and `is_control` flag to the chart of accounts and marks the
control accounts (Cash/Bank/Mobile/AR/AP/Inventory/VAT).

## Journal rules
Debits must equal credits; a line is debit **or** credit, never both; no zero lines; ≥2 lines;
accounts must be active, non-header, same company; the date must be in an open period; posted
journals are immutable (DB triggers); one active original journal per source
(`unique(source_type, source_id)`); reversals link by a `*_void` source type.

## Manual journals
`/accounting/journals/new`. Accountant creates a draft; a poster (permission
`accounting.post_manual_journal`) posts it. **Direct posting to control accounts is blocked**
unless the user holds `accounting.post_control_account_adjustment` (Owner) — those post as an
audited control adjustment. Only the Owner deletes drafts or voids posted journals (void =
reversing journal). Manual journals never change inventory quantities.

## Reports (from posted journals)
- **General Ledger** `report_gl_lines` + opening from `report_account_balance`, running balance.
- **Trial Balance** `report_trial_balance` — closing debits must equal credits (flagged if not).
- **Profit & Loss** — period movements on revenue/cost-of-sales/expense accounts; net sales =
  4100 − 4900; gross profit = net sales − COGS; bank charges (6200) shown under finance.
- **Balance Sheet** — as-of closing balances; equity includes **current-period earnings** = the
  net of all P&L accounts (no year-end close journal in Phase 4, so earnings accrue live);
  flags an exception if Assets ≠ Liabilities + Equity.
- **Cash Flow** `report_cash_flow` — net movement on cash/bank/mobile accounts bucketed by
  source; transfers/openings excluded from operating; manual/opening cash movements land in an
  Unclassified exception; closing reconciles to payment-account balances.
- **VAT** — from posted transaction tax snapshots (sales/returns/income = output;
  purchases/returns/expenses recoverable = input), reconciled to control accounts 2120/1160.
- **Receivables / Payables ageing** — as-of outstanding (payments after the as-of date are
  excluded), bucketed Not-due/1-30/31-60/61-90/90+, reconciled to AR (1140) / AP (2110).
- **Customer / Supplier statements** — opening balance + dated movements + running balance.
- **Inventory Valuation** — current from `stock_balances`; historical reconstructed from the
  immutable `stock_movements` running snapshots; reconciled to Inventory (1150).

## Bank reconciliation
`/cash-and-banks/reconciliation`. Create a statement period + opening/closing, import lines
(CSV paste; duplicate rows rejected by fingerprint), match statement lines to posted ERP
journal lines (one-to-one/partial; overmatch blocked; an ERP line can't be matched twice), or
create an **adjustment** (posts a balanced journal, e.g. bank charges). Finalize requires all
lines resolved and statement lines to equal closing − opening. Only the Owner reopens
(reason + audit). No live bank integration.

## Opening balances
`/accounting/opening-balances` (Owner). General GL openings (no direct control-account
posting), plus customer and supplier opening documents (Dr AR / Cr OBE and Dr OBE / Cr AP)
that appear in the ageing reports. Payment-account and inventory openings remain in their
Phase 2/3 workflows.

## Period closing
`/accounting/period-close`. Statuses Open → Closed → Locked. Closing runs an automated
checklist (unposted drafts, negative stock, subledger vs GL differences = **blocking**;
open transfers/reconciliations = **warning**). The Owner cannot close with blocking issues;
warnings need a written explanation (stored in the audit trail). Only the Owner reopens or
unlocks (reason + audit). Posting into a closed/locked period is blocked at the DB layer by
`assert_period_open` inside every posting RPC.

## Permissions
`accounting.*` (view, view_journals, create/post_manual_journal, post_control_account_adjustment,
view_general_ledger, view_trial_balance, view_control_accounts, manage_opening_balances, export),
`reports.view_*` per statement, `reconciliation.*`, `periods.*`. Accountant gets reports +
manual-journal drafts + reconciliation by default but **not** manual-journal posting or
control adjustments unless the Owner grants them. Only the Owner reopens/unlocks periods,
voids posted journals, or deletes drafts.

## Audit controls
Manual-journal create/post/void, control-account adjustments, opening-balance posting,
reconciliation create/import/match/adjust/finalize/reopen, and period close/reopen/lock/unlock
are all written to `audit_logs`.

## Phase 4 testing
`npm run test:phase4` posts balanced/unbalanced/control/header manual journals, a void reversal,
and a customer opening through the real RPCs, and asserts trial-balance equality — inside a
transaction that rolls back.

## Out of scope (deferred)
Payroll, budgeting/forecasting, fixed-asset depreciation, multi-currency & FX, landed cost,
purchase orders, separate GRNs, live bank feeds, TRA/EFD filing, intercompany elimination /
statutory consolidation, manufacturing, loan schedules.

## Phase 3 testing
`npm run test:phase3` posts purchases (weighted-avg + recoverable-VAT split), supplier payments,
purchase returns (price variance), expenses, other income and cash transfers through the real
RPCs, asserting balances, funds checks and balanced journals — inside a transaction that rolls back.

## Deferred to Phase 4
Profit & Loss, Balance Sheet, Trial Balance, General Ledger report, VAT return, bank
reconciliation, manual journals, budgets, payroll, multi-currency, landed-cost allocation,
purchase orders and separate goods-received notes.

## Phase 1 scope

**Included:** sign-in, dashboard (real setup stats), admin master data (company, branches,
products, categories, brands, units, tax codes, payment accounts, other-income types,
expense categories, customers, suppliers, chart of accounts, roles & permissions, users,
document numbering, accounting periods, audit log), unauthorized page, account/profile.

**Deferred to later phases:** Purchases, Expenses, Other Income, Cash Transfers, and full
financial reports. These appear as locked items in the sidebar and have no transaction pages.
(Sales, Customer Payments, Inventory and Kardex are delivered in Phase 2 — see below.)

## Project structure

```
src/
  app/
    (auth)/sign-in/           # sign-in page + action
    (app)/                    # protected shell (sidebar/header/branch selector)
      dashboard/              # setup dashboard
      admin/                  # Owner-only admin
        [resource]/           # generic master-data CRUD (14 entities)
        company/ users/ roles/ audit-log/   # bespoke admin pages
      account/                # profile & password
    unauthorized/             # access-denied page
  components/{ui,layout,admin} # design system + shell + CRUD engine
  lib/
    supabase/                 # browser / server / admin clients + middleware
    auth/                     # session, guards, permissions catalog, actions
    admin/                    # resource registry, queries, server actions
    audit.ts format.ts utils.ts
scripts/                      # migrate / seed / bootstrap-owner
supabase/migrations/          # SQL migrations
```
