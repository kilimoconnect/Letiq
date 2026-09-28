import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { requireActiveUser } from "@/lib/auth/guards";
import { createAdminClient } from "@/lib/supabase/admin";
import { getPrimaryCompanyId } from "@/lib/admin/queries";
import { formatMoney, formatQuantity, formatDate } from "@/lib/format";
import { PrintButton } from "@/components/print/print-button";

export const metadata: Metadata = { title: "Invoice" };
type Params = Promise<{ id: string }>;

export default async function InvoicePrintPage(props: { params: Params }) {
  const user = await requireActiveUser();
  const { id } = await props.params;
  const admin = createAdminClient();
  const companyId = await getPrimaryCompanyId(user.defaultCompanyId);

  const { data: sale } = await admin.from("sales")
    .select("*, customer:customers(code,name,phone,address,tin,vat_number), branch:branches(name,code,address,phone,email)")
    .eq("id", id).maybeSingle();
  if (!sale || sale.company_id !== companyId || sale.document_status === "draft") notFound();
  if (!user.isOwner && !user.branchIds.includes(sale.branch_id)) notFound();

  const { data: company } = await admin.from("companies")
    .select("name, legal_name, address, phone, email").eq("id", companyId).single();
  const { data: lines } = await admin.from("sale_lines").select("*").eq("sale_id", id).order("line_no");
  const { data: payments } = await admin.from("sale_payments").select("amount, account:payment_accounts(name)").eq("sale_id", id);

  const s = sale as Record<string, unknown> as {
    document_number: string; document_date: string; due_date: string | null;
    subtotal: number; discount_total: number; net_total: number; tax_total: number; grand_total: number;
    amount_paid: number; outstanding: number;
    customer: { name: string; phone: string | null; address: string | null; tin: string | null; vat_number: string | null } | null;
    branch: { name: string; code: string; address: string | null; phone: string | null } | null;
  };
  const ll = (lines ?? []) as unknown as Array<{ id: string; description: string; quantity: number; unit_price: number; discount: number; tax_name: string | null; tax_rate: number; line_total: number }>;

  return (
    <div className="mx-auto max-w-3xl bg-white p-8 text-stone-900">
      <style>{`@media print { .no-print { display: none !important; } body { background: #fff; } } @page { margin: 14mm; }`}</style>

      <div className="mb-6 flex items-start justify-between">
        <div>
          <h1 className="text-xl font-bold">{company?.name}</h1>
          {company?.legal_name && company.legal_name !== company.name && <p className="text-sm text-stone-600">{company.legal_name}</p>}
          <p className="text-sm text-stone-600">{s.branch?.name}{s.branch?.address ? ` · ${s.branch.address}` : ""}</p>
          <p className="text-sm text-stone-600">{[company?.phone, company?.email].filter(Boolean).join(" · ")}</p>
        </div>
        <div className="text-right">
          <h2 className="text-lg font-bold">TAX INVOICE</h2>
          <p className="font-mono text-sm">{s.document_number}</p>
          <p className="text-sm text-stone-600">Date: {formatDate(s.document_date)}</p>
          {s.due_date && <p className="text-sm text-stone-600">Due: {formatDate(s.due_date)}</p>}
        </div>
      </div>

      <div className="mb-6 rounded border border-stone-200 p-3 text-sm">
        <p className="font-semibold">Bill to</p>
        <p>{s.customer?.name}</p>
        {s.customer?.address && <p className="text-stone-600">{s.customer.address}</p>}
        {s.customer?.phone && <p className="text-stone-600">{s.customer.phone}</p>}
        {s.customer?.tin && <p className="text-stone-600">TIN: {s.customer.tin}{s.customer.vat_number ? ` · VRN: ${s.customer.vat_number}` : ""}</p>}
      </div>

      <table className="mb-4 w-full text-sm">
        <thead>
          <tr className="border-b-2 border-stone-300 text-left">
            <th className="py-1.5">Description</th>
            <th className="py-1.5 text-right">Qty</th>
            <th className="py-1.5 text-right">Price</th>
            <th className="py-1.5 text-right">Disc</th>
            <th className="py-1.5 text-right">Amount</th>
          </tr>
        </thead>
        <tbody>
          {ll.map((l) => (
            <tr key={l.id} className="border-b border-stone-100">
              <td className="py-1.5">{l.description}{l.tax_name ? ` (${l.tax_name})` : ""}</td>
              <td className="py-1.5 text-right tabular-nums">{formatQuantity(l.quantity)}</td>
              <td className="py-1.5 text-right tabular-nums">{formatMoney(l.unit_price)}</td>
              <td className="py-1.5 text-right tabular-nums">{formatMoney(l.discount)}</td>
              <td className="py-1.5 text-right tabular-nums">{formatMoney(l.line_total)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="ml-auto w-64 space-y-1 text-sm">
        <Row label="Subtotal" value={formatMoney(s.subtotal)} />
        <Row label="Discount" value={formatMoney(s.discount_total)} />
        <Row label="Net" value={formatMoney(s.net_total)} />
        <Row label="Tax (VAT)" value={formatMoney(s.tax_total)} />
        <div className="flex justify-between border-t border-stone-300 pt-1 font-bold"><span>Total</span><span className="tabular-nums">{formatMoney(s.grand_total)}</span></div>
        <Row label="Paid" value={formatMoney(s.amount_paid)} />
        <div className="flex justify-between font-semibold"><span>Balance due</span><span className="tabular-nums">{formatMoney(s.outstanding)}</span></div>
      </div>

      {(payments ?? []).length > 0 && (
        <p className="mt-4 text-xs text-stone-600">
          Payment: {(payments ?? []).map((p) => { const pp = p as unknown as { account: { name: string } | null; amount: number }; return `${pp.account?.name} ${formatMoney(pp.amount)}`; }).join(", ")}
        </p>
      )}

      <p className="mt-8 text-center text-xs text-stone-400">Thank you for your business.</p>

      <div className="no-print mt-6 flex justify-center"><PrintButton /></div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return <div className="flex justify-between"><span className="text-stone-600">{label}</span><span className="tabular-nums">{value}</span></div>;
}
