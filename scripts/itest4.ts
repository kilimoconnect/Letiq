/**
 * Phase 4 accounting integration test (BEGIN..ROLLBACK).
 * Manual journals (balance, control-account, header rejection, void reversal),
 * trial-balance equality, and customer opening balance → AR.
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
async function expectFail(db: Client, sql: string, p: unknown[]) {
  await db.query("savepoint sp");
  try { await db.query(sql, p); await db.query("release savepoint sp"); return false; }
  catch { await db.query("rollback to savepoint sp"); return true; }
}
async function acc(db: Client, co: string, code: string) {
  return one<string>(db, "select id from chart_of_accounts where company_id=$1 and code=$2", [co, code]);
}
async function mkJournal(db: Client, co: string, owner: string, lines: [string, number, number][]) {
  const d = await one<string>(db, `insert into manual_journal_drafts(company_id, journal_date, description, created_by) values ($1,current_date,'test',$2) returning id`, [co, owner]);
  let i = 0;
  for (const [accId, dr, cr] of lines) {
    i++;
    await db.query(`insert into manual_journal_draft_lines(draft_id, account_id, debit, credit, line_no) values ($1,$2,$3,$4,$5)`, [d, accId, dr, cr, i]);
  }
  return d;
}

async function main() {
  const db = createDbClient();
  await db.connect();
  await db.query("begin");
  try {
    const co = await one<string>(db, "select id from companies where code='LETIQ'");
    const owner = await one<string>(db, "select id from user_profiles where is_primary_owner");
    const br = await one<string>(db, "select id from branches where company_id=$1 and code='HQ'", [co]);
    const cust = await one<string>(db, "select id from customers where company_id=$1 and code='WALK-IN'", [co]);
    const a6100 = await acc(db, co, "6100");
    const a3200 = await acc(db, co, "3200");
    const a1140 = await acc(db, co, "1140");
    const a1000 = await acc(db, co, "1000"); // header (Assets)

    // 1) Balanced manual journal posts
    const j1 = await mkJournal(db, co, owner, [[a6100, 1000, 0], [a3200, 0, 1000]]);
    await db.query(`select post_manual_journal($1,$2,null,false)`, [j1, owner]);
    check("balanced manual journal posts", (await one<string>(db, "select document_status from manual_journal_drafts where id=$1", [j1])) === "posted");
    check("manual journal got a number", (await one<string>(db, "select document_number from manual_journal_drafts where id=$1", [j1])) !== null);

    // 2) Unbalanced rejected
    const j2 = await mkJournal(db, co, owner, [[a6100, 1000, 0], [a3200, 0, 500]]);
    check("unbalanced manual journal rejected", await expectFail(db, `select post_manual_journal($1,$2,null,false)`, [j2, owner]));

    // 3) Control account rejected without permission, allowed with
    const j3 = await mkJournal(db, co, owner, [[a1140, 500, 0], [a3200, 0, 500]]);
    check("control-account manual posting rejected (no allow)", await expectFail(db, `select post_manual_journal($1,$2,null,false)`, [j3, owner]));
    await db.query(`select post_manual_journal($1,$2,null,true)`, [j3, owner]);
    check("control-account posting allowed with override", (await one<string>(db, "select document_status from manual_journal_drafts where id=$1", [j3])) === "posted");

    // 4) Header account rejected
    const j4 = await mkJournal(db, co, owner, [[a1000, 100, 0], [a3200, 0, 100]]);
    check("header-account posting rejected", await expectFail(db, `select post_manual_journal($1,$2,null,true)`, [j4, owner]));

    // 5) Void reversal nets the account to zero
    const before6100 = Number(await one(db, "select report_account_balance($1,$2,current_date)", [co, a6100]));
    await db.query(`select void_manual_journal($1,$2,'test void')`, [j1, owner]);
    const after6100 = Number(await one(db, "select report_account_balance($1,$2,current_date)", [co, a6100]));
    check("void reversal nets expense account back", before6100 === 1000 && after6100 === 0);

    // 6) Trial balance balances (sum of closing net across all accounts = 0)
    const tbNet = Number(await one(db, "select coalesce(sum(closing_net),0) from report_trial_balance($1, '1900-01-01'::date, current_date)", [co]));
    check("trial balance balances (sum closing net = 0)", Math.abs(tbNet) < 0.005, `net=${tbNet}`);

    // 7) Customer opening balance increases AR
    const arBefore = Number(await one(db, "select report_account_balance($1,$2,current_date)", [co, a1140]));
    const cob = await one<string>(db, `insert into customer_opening_balances(company_id, branch_id, customer_id, invoice_date, due_date, amount, created_by) values ($1,$2,$3,current_date,current_date+30,5000,$4) returning id`, [co, br, cust, owner]);
    await db.query(`select post_customer_opening($1,$2,null)`, [cob, owner]);
    const arAfter = Number(await one(db, "select report_account_balance($1,$2,current_date)", [co, a1140]));
    check("customer opening increases AR by 5000", arAfter - arBefore === 5000);
    check("customer opening outstanding set", Number(await one(db, "select outstanding from customer_opening_balances where id=$1", [cob])) === 5000);

    // 8) TB still balances after openings
    const tbNet2 = Number(await one(db, "select coalesce(sum(closing_net),0) from report_trial_balance($1, '1900-01-01'::date, current_date)", [co]));
    check("trial balance still balances after openings", Math.abs(tbNet2) < 0.005, `net=${tbNet2}`);

    console.log(`\n${passed} Phase 4 accounting checks passed. Rolling back.`);
  } finally {
    await db.query("rollback");
    await db.end();
  }
}
main().catch((e) => { console.error("\nPhase 4 integration test error:\n", e); process.exit(1); });
