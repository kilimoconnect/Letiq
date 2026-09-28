import type { Metadata } from "next";
import Link from "next/link";
import {
  TrendingUp, CalendarDays, HandCoins, Wallet, Boxes, AlertTriangle, Truck, Receipt,
} from "lucide-react";
import { requireActiveUser } from "@/lib/auth/guards";
import { createAdminClient } from "@/lib/supabase/admin";
import { getActiveContext, can } from "@/lib/context";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardContent } from "@/components/ui/card";
import { PayStatusBadge } from "@/components/common/doc-status-badge";
import { formatMoney, formatDate } from "@/lib/format";
import { profitAndLoss } from "@/lib/reports/queries";
import { receivablesAgeing, payablesAgeing, vatReport } from "@/lib/reports/subledger";

export const metadata: Metadata = { title: "Dashboard" };

function todayInTz(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Dar_es_Salaam", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

export default async function DashboardPage() {
  const user = await requireActiveUser();
  await getActiveContext();
  const admin = createAdminClient();
  const companyId = user.defaultCompanyId ?? user.companyIds[0];
  const showSalesCost = can(user, "sales.view_cost");
  const showInvCost = can(user, "inventory.view_cost");

  const today = todayInTz();
  const monthStart = today.slice(0, 8) + "01";

  const { data: company } = await admin.from("companies").select("name").eq("id", companyId).maybeSingle();

  const [{ data: postedSales }, { data: receiptsToday }, { data: balances }] = await Promise.all([
    admin.from("sales")
      .select("id, document_number, document_date, grand_total, net_total, cogs_total, outstanding, amount_paid, payment_status, created_at, customer:customers(name), branch:branches(code)")
      .eq("company_id", companyId).eq("document_status", "posted").order("created_at", { ascending: false }),
    admin.from("customer_receipts")
      .select("amount").eq("company_id", companyId).eq("document_status", "posted").eq("document_date", today),
    admin.from("stock_balances")
      .select("quantity, stock_value, qty_in_transit, product:products(reorder_level)").eq("company_id", companyId),
  ]);

  type Sale = { id: string; document_number: string | null; document_date: string; grand_total: number; net_total: number; cogs_total: number; outstanding: number; amount_paid: number; payment_status: string; created_at: string; customer: { name: string } | null; branch: { code: string } | null };
  const sales = (postedSales ?? []) as unknown as Sale[];

  const salesToday = sales.filter((s) => s.document_date === today).reduce((a, s) => a + Number(s.grand_total), 0);
  const salesMonth = sales.filter((s) => s.document_date >= monthStart).reduce((a, s) => a + Number(s.grand_total), 0);
  const cogsMonth = sales.filter((s) => s.document_date >= monthStart).reduce((a, s) => a + Number(s.cogs_total), 0);
  const gpMonth = sales.filter((s) => s.document_date >= monthStart).reduce((a, s) => a + (Number(s.net_total) - Number(s.cogs_total)), 0);
  const outstanding = sales.reduce((a, s) => a + Number(s.outstanding), 0);
  const receivedToday =
    sales.filter((s) => s.document_date === today).reduce((a, s) => a + Number(s.amount_paid), 0) +
    (receiptsToday ?? []).reduce((a, r) => a + Number(r.amount), 0);

  const bals = (balances ?? []) as unknown as Array<{ quantity: number; stock_value: number; qty_in_transit: number; product: { reorder_level: number } | null }>;
  const stockValue = bals.reduce((a, b) => a + Number(b.stock_value), 0);
  const inTransit = bals.reduce((a, b) => a + Number(b.qty_in_transit), 0);
  const lowStock = bals.filter((b) => Number(b.quantity) <= Number(b.product?.reorder_level ?? 0)).length;

  const stats: { label: string; value: string; icon: typeof TrendingUp; hidden?: boolean }[] = [
    { label: "Sales today", value: formatMoney(salesToday), icon: TrendingUp },
    { label: "Sales this month", value: formatMoney(salesMonth), icon: CalendarDays },
    { label: "Received today", value: formatMoney(receivedToday), icon: HandCoins },
    { label: "Outstanding receivables", value: formatMoney(outstanding), icon: Wallet },
    { label: "COGS (month)", value: formatMoney(cogsMonth), icon: Receipt, hidden: !showSalesCost },
    { label: "Gross profit (month)", value: formatMoney(gpMonth), icon: TrendingUp, hidden: !showSalesCost },
    { label: "Stock value", value: formatMoney(stockValue), icon: Boxes, hidden: !showInvCost },
    { label: "Low-stock items", value: String(lowStock), icon: AlertTriangle },
    { label: "Stock in transit", value: String(inTransit), icon: Truck },
  ].filter((s) => !s.hidden);

  const recent = sales.slice(0, 6);

  // ---- Phase 3 metrics ----
  const showBal = can(user, "cash_accounts.view_balance");
  const [{ data: purchases }, { data: expensesData }, { data: incomeData }, { data: supPaysToday }, { data: payables }, { data: accounts }] =
    await Promise.all([
      admin.from("purchases").select("document_date, grand_total").eq("company_id", companyId).eq("document_status", "posted"),
      admin.from("expenses").select("document_date, grand_total").eq("company_id", companyId).eq("document_status", "posted"),
      admin.from("other_income_transactions").select("document_date, grand_total").eq("company_id", companyId).eq("document_status", "posted"),
      admin.from("supplier_payments").select("amount").eq("company_id", companyId).eq("document_status", "posted").eq("document_date", today),
      admin.from("supplier_payables").select("outstanding").eq("company_id", companyId).in("status", ["open", "partial"]),
      admin.from("payment_accounts").select("id").eq("company_id", companyId).eq("is_active", true),
    ]);
  const sum = (rows: { grand_total?: number; amount?: number; outstanding?: number }[] | null, field: "grand_total" | "amount" | "outstanding", filter?: (r: { document_date?: string }) => boolean) =>
    (rows ?? []).filter((r) => !filter || filter(r as { document_date?: string })).reduce((a, r) => a + Number((r as Record<string, number>)[field] ?? 0), 0);
  const purToday = sum(purchases as never, "grand_total", (r) => r.document_date === today);
  const purMonth = sum(purchases as never, "grand_total", (r) => (r.document_date ?? "") >= monthStart);
  const expToday = sum(expensesData as never, "grand_total", (r) => r.document_date === today);
  const expMonth = sum(expensesData as never, "grand_total", (r) => (r.document_date ?? "") >= monthStart);
  const incToday = sum(incomeData as never, "grand_total", (r) => r.document_date === today);
  const incMonth = sum(incomeData as never, "grand_total", (r) => (r.document_date ?? "") >= monthStart);
  const supPayToday = (supPaysToday ?? []).reduce((a, r) => a + Number(r.amount), 0);
  const outstandingAP = (payables ?? []).reduce((a, r) => a + Number(r.outstanding), 0);
  let cashTotal = 0;
  if (showBal) {
    const balances = await Promise.all((accounts ?? []).map(async (a) => Number((await admin.rpc("payment_account_balance", { p_pa: a.id })).data ?? 0)));
    cashTotal = balances.reduce((s, b) => s + b, 0);
  }
  const p3: { label: string; value: string; hidden?: boolean }[] = [
    { label: "Purchases today", value: formatMoney(purToday) },
    { label: "Purchases this month", value: formatMoney(purMonth) },
    { label: "Supplier paid today", value: formatMoney(supPayToday) },
    { label: "Outstanding payables", value: formatMoney(outstandingAP) },
    { label: "Expenses this month", value: formatMoney(expMonth) },
    { label: "Other income month", value: formatMoney(incMonth) },
    { label: "Cash & bank total", value: formatMoney(cashTotal), hidden: !showBal },
  ].filter((s) => !s.hidden);
  void expToday; void incToday; void purToday;

  // ---- Phase 4 financial section (permission-gated) ----
  const showFin = can(user, "reports.view_profit_loss");
  let fin: { label: string; value: string }[] = [];
  if (showFin) {
    const [pl, ar, ap, vat] = await Promise.all([
      profitAndLoss(companyId, monthStart, today),
      receivablesAgeing(companyId, today),
      payablesAgeing(companyId, today),
      vatReport(companyId, monthStart, today),
    ]);
    const overdueAr = ar.buckets.d1_30 + ar.buckets.d31_60 + ar.buckets.d61_90 + ar.buckets.d90;
    const overdueAp = ap.buckets.d1_30 + ap.buckets.d31_60 + ap.buckets.d61_90 + ap.buckets.d90;
    fin = [
      { label: "Revenue (month)", value: formatMoney(pl.netSales) },
      { label: "Gross profit", value: formatMoney(pl.grossProfit) },
      { label: "Net profit (month)", value: formatMoney(pl.netProfit) },
      { label: "Accounts receivable", value: formatMoney(ar.total) },
      { label: "Overdue receivables", value: formatMoney(overdueAr) },
      { label: "Accounts payable", value: formatMoney(ap.total) },
      { label: "Overdue payables", value: formatMoney(overdueAp) },
      { label: "VAT payable / (refund)", value: formatMoney(vat.netVat) },
    ];
  }

  return (
    <div>
      <PageHeader title={`Welcome${user.fullName ? `, ${user.fullName.split(" ")[0]}` : ""}`} description={`${company?.name ?? "Letiq ERP"} · Today ${formatDate(today)}`} />

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        {stats.map((s) => {
          const Icon = s.icon;
          return (
            <Card key={s.label} className="p-4">
              <div className="mb-2 flex h-8 w-8 items-center justify-center rounded-md bg-primary/10 text-primary"><Icon className="h-[18px] w-[18px]" /></div>
              <p className="text-lg font-semibold tabular-nums">{s.value}</p>
              <p className="text-xs text-muted-foreground">{s.label}</p>
            </Card>
          );
        })}
      </div>

      {p3.length > 0 && (
        <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-7">
          {p3.map((s) => (
            <Card key={s.label} className="p-4">
              <p className="text-base font-semibold tabular-nums">{s.value}</p>
              <p className="text-xs text-muted-foreground">{s.label}</p>
            </Card>
          ))}
        </div>
      )}

      {fin.length > 0 && (
        <div className="mt-4">
          <h2 className="mb-2 text-sm font-semibold">Financial summary</h2>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {fin.map((s) => (
              <Card key={s.label} className="p-4">
                <p className="text-base font-semibold tabular-nums">{s.value}</p>
                <p className="text-xs text-muted-foreground">{s.label}</p>
              </Card>
            ))}
          </div>
        </div>
      )}

      <Card className="mt-6">
        <CardContent className="p-5">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-sm font-semibold">Recent posted sales</h2>
            <Link href="/sales/history" className="text-sm text-primary hover:underline">View all</Link>
          </div>
          {recent.length === 0 ? (
            <p className="text-sm text-muted-foreground">No posted sales yet. Create your first sale.</p>
          ) : (
            <div className="divide-y divide-border">
              {recent.map((s) => (
                <Link key={s.id} href={`/sales/${s.id}`} className="flex items-center justify-between gap-3 py-2 text-sm hover:bg-muted/40">
                  <div className="min-w-0">
                    <span className="font-mono text-xs">{s.document_number}</span>
                    <span className="ml-2 text-muted-foreground">{s.customer?.name} · {s.branch?.code} · {formatDate(s.document_date)}</span>
                  </div>
                  <div className="flex items-center gap-3">
                    <PayStatusBadge status={s.payment_status} />
                    <span className="tabular-nums font-medium">{formatMoney(s.grand_total)}</span>
                  </div>
                </Link>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
