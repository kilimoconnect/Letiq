/**
 * Phase 2 integration test against the live database. Everything runs inside a
 * single transaction that is ROLLED BACK at the end, so no data persists.
 * Exercises opening -> sale -> receipt -> return posting through the real RPCs
 * and asserts stock, weighted-average cost and balanced journals.
 */
import { createDbClient } from "./db";
import type { Client } from "pg";

let passed = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { console.error(`  FAIL ${name} ${detail}`); process.exitCode = 1; }
}

async function scalar<T = number>(db: Client, sql: string, params: unknown[]): Promise<T> {
  const { rows } = await db.query(sql, params);
  return rows[0] ? (Object.values(rows[0])[0] as T) : (null as unknown as T);
}
async function expectFail(db: Client, sql: string, params: unknown[]): Promise<boolean> {
  await db.query("savepoint sp");
  try { await db.query(sql, params); await db.query("release savepoint sp"); return false; }
  catch { await db.query("rollback to savepoint sp"); return true; }
}
async function journalBalanced(db: Client, sourceType: string, sourceId: string): Promise<boolean> {
  const { rows } = await db.query(
    `select coalesce(sum(l.debit),0) d, coalesce(sum(l.credit),0) c
     from journal_entries j join journal_lines l on l.journal_id=j.id
     where j.source_type=$1 and j.source_id=$2`, [sourceType, sourceId]);
  return rows[0] && Number(rows[0].d) === Number(rows[0].c) && Number(rows[0].d) > 0;
}

async function main() {
  const db = createDbClient();
  await db.connect();
  await db.query("begin");
  try {
    const company = await scalar<string>(db, "select id from companies where code='LETIQ'", []);
    const branch = await scalar<string>(db, "select id from branches where company_id=$1 and code='HQ'", [company]);
    const owner = await scalar<string>(db, "select id from user_profiles where is_primary_owner", []);
    const cash = await scalar<string>(db, "select id from payment_accounts where company_id=$1 and code='CASH'", [company]);
    const walkin = await scalar<string>(db, "select id from customers where company_id=$1 and code='WALK-IN'", [company]);

    // Test product
    const product = await scalar<string>(db,
      `insert into products(company_id, sku, name, selling_price, track_inventory, created_by)
       values ($1, 'ITEST-'||substr(md5(random()::text),1,6), 'Integration Test Item', 1500, true, $2) returning id`,
      [company, owner]);

    // 1) Opening balance: 10 @ 1000
    const opening = await scalar<string>(db,
      `insert into inventory_openings(company_id, branch_id, opening_date, created_by) values ($1,$2,current_date,$3) returning id`,
      [company, branch, owner]);
    await db.query(`insert into inventory_opening_lines(opening_id, product_id, quantity, unit_cost, line_no) values ($1,$2,10,1000,1)`, [opening, product]);
    await db.query(`select post_inventory_opening($1,$2,null)`, [opening, owner]);

    const qty1 = await scalar<number>(db, "select quantity from stock_balances where company_id=$1 and branch_id=$2 and product_id=$3", [company, branch, product]);
    const avg1 = await scalar<number>(db, "select avg_unit_cost from stock_balances where product_id=$1", [product]);
    check("opening sets qty 10", Number(qty1) === 10, `got ${qty1}`);
    check("opening sets avg cost 1000", Number(avg1) === 1000, `got ${avg1}`);
    check("opening journal balances", await journalBalanced(db, "inventory_opening", opening));

    // 2) Cash sale: 4 @ 1500, paid cash 6000
    const sale = await scalar<string>(db,
      `insert into sales(company_id, branch_id, document_date, customer_id, created_by, grand_total)
       values ($1,$2,current_date,$3,$4,6000) returning id`, [company, branch, walkin, owner]);
    await db.query(`insert into sale_lines(sale_id, product_id, quantity, unit_price, net_amount, tax_amount, line_total, track_inventory, line_no)
                    values ($1,$2,4,1500,6000,0,6000,true,1)`, [sale, product]);
    await db.query(`insert into sale_payments(sale_id, payment_account_id, amount) values ($1,$2,6000)`, [sale, cash]);
    await db.query(`select post_sale($1,$2,null)`, [sale, owner]);

    const qty2 = await scalar<number>(db, "select quantity from stock_balances where product_id=$1", [product]);
    const cogs = await scalar<number>(db, "select cogs_total from sales where id=$1", [sale]);
    const payStatus = await scalar<string>(db, "select payment_status from sales where id=$1", [sale]);
    const outstanding = await scalar<number>(db, "select outstanding from sales where id=$1", [sale]);
    const docnum = await scalar<string>(db, "select document_number from sales where id=$1", [sale]);
    check("sale reduces stock to 6", Number(qty2) === 6, `got ${qty2}`);
    check("sale COGS = 4000 (4 * avg 1000)", Number(cogs) === 4000, `got ${cogs}`);
    check("sale payment status = paid", payStatus === "paid", `got ${payStatus}`);
    check("sale outstanding = 0", Number(outstanding) === 0, `got ${outstanding}`);
    check("sale got a document number", !!docnum, `got ${docnum}`);
    check("sale journal balances", await journalBalanced(db, "sale", sale));
    check("kardex movement recorded for sale", (await scalar<number>(db, "select count(*)::int from stock_movements where source_id=$1 and movement_type='sale'", [sale])) === 1);

    // 3) Duplicate post prevented
    check("duplicate post is rejected", await expectFail(db, `select post_sale($1,$2,null)`, [sale, owner]));

    // 4) Insufficient stock rejected
    const bigSale = await scalar<string>(db,
      `insert into sales(company_id, branch_id, document_date, customer_id, created_by, grand_total)
       values ($1,$2,current_date,$3,$4,150000) returning id`, [company, branch, walkin, owner]);
    await db.query(`insert into sale_lines(sale_id, product_id, quantity, unit_price, net_amount, tax_amount, line_total, track_inventory, line_no)
                    values ($1,$2,100,1500,150000,0,150000,true,1)`, [bigSale, product]);
    check("insufficient stock is rejected", await expectFail(db, `select post_sale($1,$2,null)`, [bigSale, owner]));

    // 5) Credit sale + customer receipt settles it
    const credit = await scalar<string>(db,
      `insert into sales(company_id, branch_id, document_date, customer_id, created_by, grand_total, due_date, is_credit)
       values ($1,$2,current_date,$3,$4,3000,current_date+30,true) returning id`, [company, branch, walkin, owner]);
    await db.query(`insert into sale_lines(sale_id, product_id, quantity, unit_price, net_amount, tax_amount, line_total, track_inventory, line_no)
                    values ($1,$2,2,1500,3000,0,3000,true,1)`, [credit, product]);
    await db.query(`select post_sale($1,$2,null)`, [credit, owner]);
    const creditOut = await scalar<number>(db, "select outstanding from sales where id=$1", [credit]);
    check("credit sale outstanding = 3000", Number(creditOut) === 3000, `got ${creditOut}`);

    const receipt = await scalar<string>(db,
      `insert into customer_receipts(company_id, branch_id, customer_id, payment_account_id, amount, created_by)
       values ($1,$2,$3,$4,3000,$5) returning id`, [company, branch, walkin, cash, owner]);
    await db.query(`insert into customer_receipt_allocations(receipt_id, sale_id, amount) values ($1,$2,3000)`, [receipt, credit]);
    await db.query(`select post_customer_receipt($1,$2,null)`, [receipt, owner]);
    const creditOut2 = await scalar<number>(db, "select outstanding from sales where id=$1", [credit]);
    const creditPay = await scalar<string>(db, "select payment_status from sales where id=$1", [credit]);
    check("receipt settles invoice to 0", Number(creditOut2) === 0, `got ${creditOut2}`);
    check("invoice now paid", creditPay === "paid", `got ${creditPay}`);
    check("receipt journal balances", await journalBalanced(db, "customer_receipt", receipt));

    // 6) Sales return (1 saleable unit from the cash sale)
    const saleLine = await scalar<string>(db, "select id from sale_lines where sale_id=$1", [sale]);
    const ret = await scalar<string>(db,
      `insert into sales_returns(company_id, branch_id, sale_id, customer_id, reason, created_by)
       values ($1,$2,$3,$4,'Damaged on delivery',$5) returning id`, [company, branch, sale, walkin, owner]);
    await db.query(`insert into sales_return_lines(return_id, sale_line_id, product_id, quantity, unit_price, net_amount, tax_amount, line_total, unit_cost, condition, track_inventory, line_no)
                    values ($1,$2,$3,1,1500,1500,0,1500,1000,'saleable',true,1)`, [ret, saleLine, product]);
    await db.query(`select post_sales_return($1,$2,null)`, [ret, owner]);
    // 10 opening - 4 cash sale - 2 credit sale + 1 saleable return = 5
    const qty3 = await scalar<number>(db, "select quantity from stock_balances where product_id=$1", [product]);
    check("saleable return restores stock (10-4-2+1=5)", Number(qty3) === 5, `got ${qty3}`);
    check("return journal balances", await journalBalanced(db, "sales_return", ret));

    // 7) Excess return rejected (sold 4, already returned 1, try 5)
    const ret2 = await scalar<string>(db,
      `insert into sales_returns(company_id, branch_id, sale_id, customer_id, reason, created_by)
       values ($1,$2,$3,$4,'test',$5) returning id`, [company, branch, sale, walkin, owner]);
    await db.query(`insert into sales_return_lines(return_id, sale_line_id, product_id, quantity, unit_price, net_amount, tax_amount, line_total, unit_cost, condition, track_inventory, line_no)
                    values ($1,$2,$3,5,1500,7500,0,7500,1000,'saleable',true,1)`, [ret2, saleLine, product]);
    check("excess return is rejected", await expectFail(db, `select post_sales_return($1,$2,null)`, [ret2, owner]));

    console.log(`\n${passed} integration checks passed. Rolling back (no data persisted).`);
  } finally {
    await db.query("rollback");
    await db.end();
  }
}
main().catch((e) => { console.error("\nIntegration test error:\n", e); process.exit(1); });
