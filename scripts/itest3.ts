/**
 * Phase 3 integration test against the live DB, inside a BEGIN..ROLLBACK.
 * Validates purchase (weighted-average + recoverable VAT split), supplier
 * payment, purchase return (price variance), expense, other income, cash
 * transfer (funds + charge) and financial opening balances through the RPCs.
 */
import { createDbClient } from "./db";
import type { Client } from "pg";

let passed = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { console.error(`  FAIL ${name} ${detail}`); process.exitCode = 1; }
}
async function one<T = number>(db: Client, sql: string, p: unknown[] = []): Promise<T> {
  const { rows } = await db.query(sql, p);
  return rows[0] ? (Object.values(rows[0])[0] as T) : (null as unknown as T);
}
async function balanced(db: Client, st: string, id: string) {
  const { rows } = await db.query(
    `select coalesce(sum(l.debit),0) d, coalesce(sum(l.credit),0) c from journal_entries j
     join journal_lines l on l.journal_id=j.id where j.source_type=$1 and j.source_id=$2`, [st, id]);
  return rows[0] && Number(rows[0].d) === Number(rows[0].c) && Number(rows[0].d) > 0;
}
async function expectFail(db: Client, sql: string, p: unknown[]) {
  await db.query("savepoint sp");
  try { await db.query(sql, p); await db.query("release savepoint sp"); return false; }
  catch { await db.query("rollback to savepoint sp"); return true; }
}

async function main() {
  const db = createDbClient();
  await db.connect();
  await db.query("begin");
  try {
    const co = await one<string>(db, "select id from companies where code='LETIQ'");
    const br = await one<string>(db, "select id from branches where company_id=$1 and code='HQ'", [co]);
    const owner = await one<string>(db, "select id from user_profiles where is_primary_owner");
    const cash = await one<string>(db, "select id from payment_accounts where company_id=$1 and code='CASH'", [co]);
    const nmb = await one<string>(db, "select id from payment_accounts where company_id=$1 and code='NMB'", [co]);
    const mpesa = await one<string>(db, "select id from payment_accounts where company_id=$1 and code='MPESA'", [co]);
    const vat = await one<string>(db, "select id from tax_codes where company_id=$1 and code='VAT18'", [co]);
    const supplier = await one<string>(db, `insert into suppliers(company_id, code, name, created_by) values ($1,'ITS-'||substr(md5(random()::text),1,5),'Test Supplier',$2) returning id`, [co, owner]);
    const product = await one<string>(db, `insert into products(company_id, sku, name, selling_price, track_inventory, created_by) values ($1,'IP3-'||substr(md5(random()::text),1,5),'Test Item',1500,true,$2) returning id`, [co, owner]);
    const expCat = await one<string>(db, `insert into expense_categories(company_id, code, name, expense_account_id, created_by) values ($1,'IEC-'||substr(md5(random()::text),1,4),'Rent',(select id from chart_of_accounts where company_id=$1 and code='6100'),$2) returning id`, [co, owner]);
    const incType = await one<string>(db, `insert into other_income_types(company_id, code, name, income_account_id, created_by) values ($1,'IIT-'||substr(md5(random()::text),1,4),'Commission',(select id from chart_of_accounts where company_id=$1 and code='4200'),$2) returning id`, [co, owner]);

    // 1) Financial opening: fund NMB with 3,000,000
    const fob = await one<string>(db, `insert into financial_opening_balances(company_id, opening_date, created_by) values ($1,current_date,$2) returning id`, [co, owner]);
    await db.query(`insert into financial_opening_balance_lines(opening_id, payment_account_id, side, amount, line_no) values ($1,$2,'debit',3000000,1)`, [fob, nmb]);
    await db.query(`select post_financial_opening($1,$2,null)`, [fob, owner]);
    check("financial opening funds NMB to 3,000,000", Number(await one(db, "select payment_account_balance($1)", [nmb])) === 3000000);

    // 2) Cash purchase 10 @ 1000 net + 18% recoverable VAT, paid cash 11800
    const pur = await one<string>(db, `insert into purchases(company_id, branch_id, supplier_id, document_date, supplier_invoice_number, created_by) values ($1,$2,$3,current_date,'INV-100',$4) returning id`, [co, br, supplier, owner]);
    await db.query(`insert into purchase_lines(purchase_id, product_id, quantity, unit_cost, tax_code_id, tax_rate, tax_inclusive, is_recoverable, track_inventory, line_no) values ($1,$2,10,1000,$3,18,false,true,true,1)`, [pur, product, vat]);
    await db.query(`insert into purchase_payments(purchase_id, payment_account_id, amount) values ($1,$2,11800)`, [pur, cash]);
    await db.query(`select post_purchase($1,$2,null)`, [pur, owner]);
    check("purchase adds 10 to stock", Number(await one(db, "select quantity from stock_balances where product_id=$1", [product])) === 10);
    check("avg cost excludes recoverable VAT (=1000)", Number(await one(db, "select avg_unit_cost from stock_balances where product_id=$1", [product])) === 1000);
    check("purchase inventory value = 10000", Number(await one(db, "select inventory_value from purchases where id=$1", [pur])) === 10000);
    check("purchase recoverable tax = 1800", Number(await one(db, "select recoverable_tax from purchases where id=$1", [pur])) === 1800);
    check("purchase paid in full", (await one<string>(db, "select payment_status from purchases where id=$1", [pur])) === "paid");
    check("purchase journal balances", await balanced(db, "purchase", pur));

    // 3) Weighted average: second purchase 10 @ 1200 net -> avg 1100
    const pur2 = await one<string>(db, `insert into purchases(company_id, branch_id, supplier_id, document_date, supplier_invoice_number, created_by) values ($1,$2,$3,current_date,'INV-101',$4) returning id`, [co, br, supplier, owner]);
    await db.query(`insert into purchase_lines(purchase_id, product_id, quantity, unit_cost, tax_rate, is_recoverable, track_inventory, line_no) values ($1,$2,10,1200,0,true,true,1)`, [pur2, product]);
    await db.query(`select post_purchase($1,$2,null)`, [pur2, owner]);
    check("weighted-average cost now 1100", Number(await one(db, "select avg_unit_cost from stock_balances where product_id=$1", [product])) === 1100);

    // 4) Duplicate supplier invoice rejected
    const dupPur = await one<string>(db, `insert into purchases(company_id, branch_id, supplier_id, document_date, supplier_invoice_number, created_by) values ($1,$2,$3,current_date,'inv 100',$4) returning id`, [co, br, supplier, owner]);
    await db.query(`insert into purchase_lines(purchase_id, product_id, quantity, unit_cost, tax_rate, is_recoverable, track_inventory, line_no) values ($1,$2,1,1000,0,true,true,1)`, [dupPur, product]);
    check("duplicate supplier invoice rejected (normalized)", await expectFail(db, `select post_purchase($1,$2,null)`, [dupPur, owner]));

    // 5) Credit purchase -> payable, then supplier payment settles it
    const credit = await one<string>(db, `insert into purchases(company_id, branch_id, supplier_id, document_date, supplier_invoice_number, due_date, is_credit, created_by) values ($1,$2,$3,current_date,'INV-200',current_date+30,true,$4) returning id`, [co, br, supplier, owner]);
    await db.query(`insert into purchase_lines(purchase_id, product_id, quantity, unit_cost, tax_rate, is_recoverable, track_inventory, line_no) values ($1,$2,5,1000,0,true,true,1)`, [credit, product]);
    await db.query(`select post_purchase($1,$2,null)`, [credit, owner]);
    const payable = await one<string>(db, "select id from supplier_payables where purchase_id=$1", [credit]);
    check("credit purchase creates payable 5000", Number(await one(db, "select outstanding from supplier_payables where id=$1", [payable])) === 5000);

    const spay = await one<string>(db, `insert into supplier_payments(company_id, branch_id, supplier_id, document_date, created_by) values ($1,$2,$3,current_date,$4) returning id`, [co, br, supplier, owner]);
    await db.query(`insert into supplier_payment_funding(payment_id, payment_account_id, amount) values ($1,$2,5000)`, [spay, nmb]);
    await db.query(`insert into supplier_payment_allocations(payment_id, payable_id, amount) values ($1,$2,5000)`, [spay, payable]);
    await db.query(`select post_supplier_payment($1,$2,null)`, [spay, owner]);
    check("supplier payment settles payable", Number(await one(db, "select outstanding from supplier_payables where id=$1", [payable])) === 0);
    check("credit purchase now paid", (await one<string>(db, "select payment_status from purchases where id=$1", [credit])) === "paid");
    check("supplier payment journal balances", await balanced(db, "supplier_payment", spay));

    // 6) Purchase return (1 unit of pur, reduce payable) — but pur is paid, so use credit? credit is paid too.
    //    Return 1 unit from pur2 (unpaid? pur2 is cash? pur2 had no payment -> unpaid, payable exists)
    const pur2line = await one<string>(db, "select id from purchase_lines where purchase_id=$1", [pur2]);
    const pret = await one<string>(db, `insert into purchase_returns(company_id, branch_id, purchase_id, supplier_id, reason, settlement_method, created_by) values ($1,$2,$3,$4,'Damaged','reduce_payable',$5) returning id`, [co, br, pur2, supplier, owner]);
    await db.query(`insert into purchase_return_lines(return_id, purchase_line_id, product_id, quantity, unit_price, tax_rate, is_recoverable, net_amount, tax_amount, line_total, track_inventory, line_no) values ($1,$2,$3,1,1200,0,true,1200,0,1200,true,1)`, [pret, pur2line, product]);
    const qtyBefore = Number(await one(db, "select quantity from stock_balances where product_id=$1", [product]));
    await db.query(`select post_purchase_return($1,$2,null)`, [pret, owner]);
    const qtyAfter = Number(await one(db, "select quantity from stock_balances where product_id=$1", [product]));
    check("purchase return reduces stock by 1", qtyBefore - qtyAfter === 1);
    // avg after 10@1000+10@1200+5@1000 = 1080; credit basis 1200 => PPV 120
    check("purchase return PPV recorded (1200 - 1080 avg = 120)", Number(await one(db, "select price_variance from purchase_returns where id=$1", [pret])) === 120);
    check("purchase return journal balances", await balanced(db, "purchase_return", pret));

    // 7) Expense (recoverable VAT) paid from NMB
    const exp = await one<string>(db, `insert into expenses(company_id, branch_id, expense_category_id, document_date, tax_rate, net_total, tax_total, grand_total, is_recoverable, created_by) values ($1,$2,$3,current_date,18,100000,18000,118000,true,$4) returning id`, [co, br, expCat, owner]);
    await db.query(`insert into expense_payments(expense_id, payment_account_id, amount) values ($1,$2,118000)`, [exp, nmb]);
    await db.query(`select post_expense($1,$2,null)`, [exp, owner]);
    check("expense posts & is paid", (await one<string>(db, "select payment_status from expenses where id=$1", [exp])) === "paid");
    check("expense journal balances", await balanced(db, "expense", exp));

    // 8) Other income taxable, received to cash
    const cashBefore = Number(await one(db, "select payment_account_balance($1)", [cash]));
    const oi = await one<string>(db, `insert into other_income_transactions(company_id, branch_id, income_type_id, document_date, tax_rate, net_total, tax_total, grand_total, created_by) values ($1,$2,$3,current_date,18,50000,9000,59000,$4) returning id`, [co, br, incType, owner]);
    await db.query(`insert into other_income_receipts(transaction_id, payment_account_id, amount) values ($1,$2,59000)`, [oi, cash]);
    await db.query(`select post_other_income($1,$2,null)`, [oi, owner]);
    check("other income posts", (await one<string>(db, "select document_status from other_income_transactions where id=$1", [oi])) === "posted");
    check("other income journal balances", await balanced(db, "other_income", oi));
    check("other income increased cash by 59000", Number(await one(db, "select payment_account_balance($1)", [cash])) - cashBefore === 59000);

    // 9) Cash transfer NMB -> M-Pesa 2,000,000 fee 5,000
    const nmbBefore = Number(await one(db, "select payment_account_balance($1)", [nmb]));
    const ct = await one<string>(db, `insert into cash_transfers(company_id, transfer_date, source_account_id, destination_account_id, source_branch_id, amount, fee, created_by) values ($1,current_date,$2,$3,$4,2000000,5000,$5) returning id`, [co, nmb, mpesa, br, owner]);
    await db.query(`select post_cash_transfer($1,$2,null)`, [ct, owner]);
    check("transfer: NMB decreases by 2,005,000", nmbBefore - Number(await one(db, "select payment_account_balance($1)", [nmb])) === 2005000);
    check("transfer: M-Pesa increases by 2,000,000", Number(await one(db, "select payment_account_balance($1)", [mpesa])) === 2000000);
    check("transfer journal balances", await balanced(db, "cash_transfer", ct));

    // 10) Insufficient funds rejected (transfer 9,999,999 from M-Pesa which has 2,000,000)
    const bad = await one<string>(db, `insert into cash_transfers(company_id, transfer_date, source_account_id, destination_account_id, source_branch_id, amount, created_by) values ($1,current_date,$2,$3,$4,9999999,$5) returning id`, [co, mpesa, nmb, br, owner]);
    check("insufficient funds transfer rejected", await expectFail(db, `select post_cash_transfer($1,$2,null)`, [bad, owner]));

    // 11) Same-account transfer rejected
    const same = await one<string>(db, `insert into cash_transfers(company_id, transfer_date, source_account_id, destination_account_id, source_branch_id, amount, created_by) values ($1,current_date,$2,$2,$3,1000,$4) returning id`, [co, nmb, br, owner]).catch(() => null);
    check("same-account transfer blocked by constraint", same === null);

    console.log(`\n${passed} Phase 3 integration checks passed. Rolling back.`);
  } finally {
    await db.query("rollback");
    await db.end();
  }
}
main().catch((e) => { console.error("\nPhase 3 integration test error:\n", e); process.exit(1); });
