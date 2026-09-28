import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { requireActiveUser } from "@/lib/auth/guards";
import { createAdminClient } from "@/lib/supabase/admin";
import { getPrimaryCompanyId } from "@/lib/admin/queries";
import { formatMoney, formatDate } from "@/lib/format";
import { PrintButton } from "@/components/print/print-button";

export const metadata: Metadata = { title: "Receipt" };
type Params = Promise<{ id: string }>;

export default async function ReceiptPrintPage(props: { params: Params }) {
  const user = await requireActiveUser();
  const { id } = await props.params;
  const admin = createAdminClient();
  const companyId = await getPrimaryCompanyId(user.defaultCompanyId);

  const { data: rec } = await admin.from("customer_receipts")
    .select("*, customer:customers(id, name), branch:branches(name, code), account:payment_accounts(name)")
    .eq("id", id).maybeSingle();
  if (!rec || rec.company_id !== companyId || rec.document_status !== "posted") notFound();

  const { data: company } = await admin.from("companies").select("name, phone, email").eq("id", companyId).single();
  const { data: allocs } = await admin.from("customer_receipt_allocations")
    .select("amount, sale:sales(document_number)").eq("receipt_id", id);

  const r = rec as Record<string, unknown> as {
    document_number: string; document_date: string; amount: number; reference: string | null;
    customer: { id: string; name: string } | null; branch: { name: string } | null; account: { name: string } | null;
  };

  const { data: bal } = await admin.from("sales")
    .select("outstanding").eq("company_id", companyId).eq("customer_id", r.customer?.id ?? "").eq("document_status", "posted");
  const remaining = (bal ?? []).reduce((s, x) => s + Number(x.outstanding), 0);

  return (
    <div className="mx-auto max-w-md bg-white p-8 text-stone-900">
      <style>{`@media print { .no-print { display: none !important; } } @page { margin: 14mm; }`}</style>
      <div className="mb-4 text-center">
        <h1 className="text-lg font-bold">{company?.name}</h1>
        <p className="text-sm text-stone-600">{r.branch?.name}</p>
        <p className="text-xs text-stone-500">{[company?.phone, company?.email].filter(Boolean).join(" · ")}</p>
      </div>
      <h2 className="mb-3 text-center text-base font-bold">PAYMENT RECEIPT</h2>

      <div className="space-y-1 text-sm">
        <div className="flex justify-between"><span className="text-stone-600">Receipt no.</span><span className="font-mono">{r.document_number}</span></div>
        <div className="flex justify-between"><span className="text-stone-600">Date</span><span>{formatDate(r.document_date)}</span></div>
        <div className="flex justify-between"><span className="text-stone-600">Customer</span><span>{r.customer?.name}</span></div>
        <div className="flex justify-between"><span className="text-stone-600">Method</span><span>{r.account?.name}</span></div>
        {r.reference && <div className="flex justify-between"><span className="text-stone-600">Reference</span><span>{r.reference}</span></div>}
      </div>

      <div className="my-3 border-y border-stone-200 py-2 text-sm">
        <p className="mb-1 font-semibold">Applied to</p>
        {(allocs ?? []).map((a, i) => (
          <div key={i} className="flex justify-between">
            <span className="text-stone-600">{(a as unknown as { sale: { document_number: string } | null }).sale?.document_number}</span>
            <span className="tabular-nums">{formatMoney((a as unknown as { amount: number }).amount)}</span>
          </div>
        ))}
      </div>

      <div className="flex justify-between text-base font-bold"><span>Amount received</span><span className="tabular-nums">{formatMoney(r.amount)}</span></div>
      <div className="mt-1 flex justify-between text-sm"><span className="text-stone-600">Remaining balance</span><span className="tabular-nums">{formatMoney(remaining)}</span></div>

      <p className="mt-6 text-center text-xs text-stone-500">Received by {user.fullName ?? user.email}</p>
      <div className="no-print mt-6 flex justify-center"><PrintButton /></div>
    </div>
  );
}
