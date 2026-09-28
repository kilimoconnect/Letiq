import { createDbClient } from "./db";
import { PERMISSION_DEFS, ROLE_DEFS } from "../src/lib/auth/permissions";
import type { Client } from "pg";

const COMPANY_CODE = "LETIQ";
const COMPANY_NAME = "Letiq Limited";

interface CoaSeed {
  code: string;
  name: string;
  type: "asset" | "liability" | "equity" | "revenue" | "cost_of_sales" | "expense";
  parent?: string;
  posting: boolean;
}

const normalBalance: Record<CoaSeed["type"], "debit" | "credit"> = {
  asset: "debit",
  expense: "debit",
  cost_of_sales: "debit",
  liability: "credit",
  equity: "credit",
  revenue: "credit",
};

const COA: CoaSeed[] = [
  { code: "1000", name: "Assets", type: "asset", posting: false },
  { code: "1100", name: "Current Assets", type: "asset", parent: "1000", posting: false },
  { code: "1110", name: "Cash", type: "asset", parent: "1100", posting: true },
  { code: "1120", name: "Bank", type: "asset", parent: "1100", posting: true },
  { code: "1130", name: "Mobile Money", type: "asset", parent: "1100", posting: true },
  { code: "1140", name: "Accounts Receivable", type: "asset", parent: "1100", posting: true },
  { code: "1150", name: "Inventory", type: "asset", parent: "1100", posting: true },
  { code: "1160", name: "Input VAT", type: "asset", parent: "1100", posting: true },
  { code: "2000", name: "Liabilities", type: "liability", posting: false },
  { code: "2100", name: "Current Liabilities", type: "liability", parent: "2000", posting: false },
  { code: "2110", name: "Accounts Payable", type: "liability", parent: "2100", posting: true },
  { code: "2120", name: "Output VAT", type: "liability", parent: "2100", posting: true },
  { code: "3000", name: "Equity", type: "equity", posting: false },
  { code: "3100", name: "Owner's Equity", type: "equity", parent: "3000", posting: true },
  { code: "4000", name: "Revenue", type: "revenue", posting: false },
  { code: "4100", name: "Sales Revenue", type: "revenue", parent: "4000", posting: true },
  { code: "4200", name: "Other Income", type: "revenue", parent: "4000", posting: true },
  { code: "5000", name: "Cost of Sales", type: "cost_of_sales", posting: false },
  { code: "5100", name: "Cost of Goods Sold", type: "cost_of_sales", parent: "5000", posting: true },
  { code: "6000", name: "Expenses", type: "expense", posting: false },
  { code: "6100", name: "Operating Expenses", type: "expense", parent: "6000", posting: true },
  { code: "6200", name: "Bank and Mobile Money Charges", type: "expense", parent: "6000", posting: true },
];

const UNITS = [
  { code: "PCS", name: "Piece", symbol: "pc", allow_decimal: false },
  { code: "LTR", name: "Litre", symbol: "L", allow_decimal: true },
  { code: "KG", name: "Kilogram", symbol: "kg", allow_decimal: true },
  { code: "BAG", name: "Bag", symbol: "bag", allow_decimal: false },
  { code: "CTN", name: "Carton", symbol: "ctn", allow_decimal: false },
];

const PAYMENT_ACCOUNTS = [
  { code: "CASH", name: "Cash", type: "cash", provider: null, ledger: "1110" },
  { code: "NMB", name: "NMB Bank", type: "bank", provider: "NMB Bank", ledger: "1120" },
  { code: "CRDB", name: "CRDB Bank", type: "bank", provider: "CRDB Bank", ledger: "1120" },
  { code: "MIX", name: "MIX", type: "clearing", provider: "MIX", ledger: "1130" },
  { code: "MPESA", name: "M-Pesa", type: "mobile_money", provider: "Vodacom M-Pesa", ledger: "1130" },
];

const TAX_CODES = [
  { code: "VAT18", name: "VAT 18%", tax_type: "standard", rate: 18, applies_to: "both", input: "1160", output: "2120" },
  { code: "ZERO", name: "Zero Rated", tax_type: "zero_rated", rate: 0, applies_to: "both", input: null, output: null },
  { code: "EXEMPT", name: "Exempt", tax_type: "exempt", rate: 0, applies_to: "both", input: null, output: null },
];

const DOC_TYPES = [
  { type: "sales_invoice", prefix: "INV" },
  { type: "sales_receipt", prefix: "RCP" },
  { type: "sales_return", prefix: "SRN" },
  { type: "purchase", prefix: "PUR" },
  { type: "purchase_return", prefix: "PRN" },
  { type: "expense", prefix: "EXP" },
  { type: "other_income", prefix: "OIN" },
  { type: "cash_transfer", prefix: "CTR" },
  { type: "stock_transfer", prefix: "STR" },
  { type: "stock_adjustment", prefix: "ADJ" },
  { type: "journal_entry", prefix: "JRN" },
];

async function seedPermissionsAndRoles(db: Client) {
  const permId = new Map<string, string>();
  for (const p of PERMISSION_DEFS) {
    const { rows } = await db.query<{ id: string }>(
      `insert into permissions (resource, action, code, description)
       values ($1,$2,$3,$4)
       on conflict (code) do update set description = excluded.description
       returning id`,
      [p.resource, p.action, p.code, p.description],
    );
    permId.set(p.code, rows[0].id);
  }

  for (const r of ROLE_DEFS) {
    const { rows } = await db.query<{ id: string }>(
      `insert into roles (code, name, description, is_system, is_protected, is_active)
       values ($1,$2,$3,$4,$5,true)
       on conflict (code) do update
         set name = excluded.name, description = excluded.description,
             is_system = excluded.is_system, is_protected = excluded.is_protected
       returning id`,
      [r.code, r.name, r.description, r.isSystem, r.isProtected],
    );
    const roleId = rows[0].id;
    const codes = r.permissions === "*" ? PERMISSION_DEFS.map((p) => p.code) : r.permissions;
    for (const code of codes) {
      const pid = permId.get(code);
      if (!pid) continue;
      await db.query(
        `insert into role_permissions (role_id, permission_id)
         values ($1,$2) on conflict do nothing`,
        [roleId, pid],
      );
    }
  }
  console.log(`  roles=${ROLE_DEFS.length} permissions=${PERMISSION_DEFS.length}`);
}

async function main() {
  const db = createDbClient();
  await db.connect();
  try {
    await db.query("begin");

    console.log("Seeding permissions & roles...");
    await seedPermissionsAndRoles(db);

    console.log("Seeding company & branch...");
    const company = await db.query<{ id: string }>(
      `insert into companies (code, name, legal_name, base_currency, timezone, date_format)
       values ($1,$2,$2,'TZS','Africa/Dar_es_Salaam','DD/MM/YYYY')
       on conflict (code) do update set name = excluded.name, legal_name = excluded.legal_name
       returning id`,
      [COMPANY_CODE, COMPANY_NAME],
    );
    const companyId = company.rows[0].id;

    await db.query(
      `insert into branches (company_id, code, name, is_head_office, is_active)
       values ($1,'HQ','Head Office', true, true)
       on conflict (company_id, code) do update set name = excluded.name`,
      [companyId],
    );

    console.log("Seeding units...");
    for (const u of UNITS) {
      await db.query(
        `insert into units (company_id, code, name, symbol, allow_decimal)
         values ($1,$2,$3,$4,$5)
         on conflict (company_id, code) do nothing`,
        [companyId, u.code, u.name, u.symbol, u.allow_decimal],
      );
    }

    console.log("Seeding chart of accounts...");
    const coaId = new Map<string, string>();
    for (const a of COA) {
      const parentId = a.parent ? coaId.get(a.parent) ?? null : null;
      const { rows } = await db.query<{ id: string }>(
        `insert into chart_of_accounts
           (company_id, code, name, account_type, parent_id, normal_balance, allow_posting, is_system, is_active)
         values ($1,$2,$3,$4,$5,$6,$7,true,true)
         on conflict (company_id, code) do update
           set name = excluded.name, account_type = excluded.account_type,
               normal_balance = excluded.normal_balance, parent_id = excluded.parent_id
         returning id`,
        [companyId, a.code, a.name, a.type, parentId, normalBalance[a.type], a.posting],
      );
      coaId.set(a.code, rows[0].id);
    }

    console.log("Seeding tax codes...");
    for (const t of TAX_CODES) {
      const exists = await db.query(
        `select 1 from tax_codes where company_id=$1 and code=$2`,
        [companyId, t.code],
      );
      if (exists.rowCount) continue;
      await db.query(
        `insert into tax_codes
           (company_id, code, name, tax_type, rate, applies_to, is_inclusive,
            input_account_id, output_account_id)
         values ($1,$2,$3,$4,$5,$6,false,$7,$8)`,
        [
          companyId, t.code, t.name, t.tax_type, t.rate, t.applies_to,
          t.input ? coaId.get(t.input) : null,
          t.output ? coaId.get(t.output) : null,
        ],
      );
    }

    console.log("Seeding payment accounts...");
    for (const pa of PAYMENT_ACCOUNTS) {
      await db.query(
        `insert into payment_accounts
           (company_id, code, name, account_type, provider, ledger_account_id)
         values ($1,$2,$3,$4,$5,$6)
         on conflict (company_id, code) do nothing`,
        [companyId, pa.code, pa.name, pa.type, pa.provider, coaId.get(pa.ledger) ?? null],
      );
    }

    console.log("Seeding walk-in customer...");
    await db.query(
      `insert into customers (company_id, code, name, customer_type, is_protected)
       values ($1,'WALK-IN','Walk-in Customer','individual', true)
       on conflict (company_id, code) do update set is_protected = true`,
      [companyId],
    );

    console.log("Seeding document sequences...");
    for (const d of DOC_TYPES) {
      const exists = await db.query(
        `select 1 from document_sequences
         where company_id=$1 and document_type=$2 and branch_id is null`,
        [companyId, d.type],
      );
      if (exists.rowCount) continue;
      await db.query(
        `insert into document_sequences
           (company_id, document_type, prefix, current_number, number_length, reset_frequency)
         values ($1,$2,$3,0,5,'yearly')`,
        [companyId, d.type, d.prefix],
      );
    }

    console.log("Seeding current accounting period...");
    const year = new Date().getFullYear();
    const periodExists = await db.query(
      `select 1 from accounting_periods where company_id=$1 and name=$2`,
      [companyId, `FY ${year}`],
    );
    if (!periodExists.rowCount) {
      await db.query(
        `insert into accounting_periods
           (company_id, financial_year, name, start_date, end_date, status)
         values ($1,$2,$3, make_date($4,1,1), make_date($4,12,31), 'open')`,
        [companyId, String(year), `FY ${year}`, year],
      );
    }

    await db.query("commit");
    console.log("\nSeed complete.");
  } catch (err) {
    await db.query("rollback");
    throw err;
  } finally {
    await db.end();
  }
}

main().catch((err) => {
  console.error("\nSeed failed:\n", err);
  process.exit(1);
});
