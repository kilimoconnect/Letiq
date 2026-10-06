"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Plus, Trash2 } from "lucide-react";
import { savePurchaseDraft, postPurchase, type PurchaseDraftInput } from "@/lib/purchases/actions";
import { calcLine, calcTotals, round2 } from "@/lib/sales/calc";
import { formatMoney } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent } from "@/components/ui/card";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import { ProductPicker } from "@/components/common/product-picker";

export interface ProductOpt {
  id: string; sku: string; barcode: string | null; name: string; tax_code_id: string | null;
  category: string | null; brand: string | null;
}
export interface TaxOpt { id: string; name: string; rate: number; is_inclusive: boolean }
export interface AccountOpt { id: string; name: string }
export interface SupplierOpt { id: string; code: string; name: string }

interface Line { key: string; product_id: string; quantity: string; unit_cost: string; discount: string; tax_code_id: string }
interface Payment { key: string; payment_account_id: string; amount: string }
const NONE = "__none__";
const nl = (): Line => ({ key: Math.random().toString(36).slice(2), product_id: "", quantity: "1", unit_cost: "", discount: "0", tax_code_id: NONE });

export function PurchaseForm({
  branchId, products, taxCodes, accounts, suppliers,
}: {
  branchId: string; products: ProductOpt[]; taxCodes: TaxOpt[]; accounts: AccountOpt[]; suppliers: SupplierOpt[];
}) {
  const router = useRouter();
  const [supplierId, setSupplierId] = React.useState("");
  const [date, setDate] = React.useState(new Date().toISOString().slice(0, 10));
  const [invDate, setInvDate] = React.useState("");
  const [invNo, setInvNo] = React.useState("");
  const [reference, setReference] = React.useState("");
  const [dueDate, setDueDate] = React.useState("");
  const [lines, setLines] = React.useState<Line[]>([nl()]);
  const [payments, setPayments] = React.useState<Payment[]>([]);
  const [pending, setPending] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const taxMap = new Map(taxCodes.map((t) => [t.id, t]));
  const prodMap = new Map(products.map((p) => [p.id, p]));
  const setLine = (k: string, patch: Partial<Line>) => setLines(lines.map((l) => l.key === k ? { ...l, ...patch } : l));

  const computed = lines.map((l) => {
    const tc = l.tax_code_id !== NONE ? taxMap.get(l.tax_code_id) : null;
    return calcLine({ quantity: Number(l.quantity || 0), unitPrice: Number(l.unit_cost || 0), discount: Number(l.discount || 0), taxRate: tc ? tc.rate : 0, taxInclusive: tc ? tc.is_inclusive : false });
  });
  const totals = calcTotals(lines.map((l) => {
    const tc = l.tax_code_id !== NONE ? taxMap.get(l.tax_code_id) : null;
    return { quantity: Number(l.quantity || 0), unitPrice: Number(l.unit_cost || 0), discount: Number(l.discount || 0), taxRate: tc ? tc.rate : 0, taxInclusive: tc ? tc.is_inclusive : false };
  }));
  const paid = round2(payments.reduce((s, p) => s + Number(p.amount || 0), 0));
  const outstanding = round2(totals.grand - paid);

  async function submit(post: boolean) {
    setError(null);
    if (!supplierId) { setError("Select a supplier."); return; }
    const valid = lines.filter((l) => l.product_id && Number(l.quantity) > 0);
    if (valid.length === 0) { setError("Add at least one product line."); return; }
    if (post && outstanding > 0 && !dueDate) { setError("A due date is required when there is an outstanding balance."); return; }
    const input: PurchaseDraftInput = {
      branchId, supplierId, documentDate: date, supplierInvoiceDate: invDate || null, supplierInvoiceNumber: invNo,
      internalReference: reference, dueDate: dueDate || null,
      lines: valid.map((l) => ({ product_id: l.product_id, quantity: Number(l.quantity), unit_cost: Number(l.unit_cost || 0), discount: Number(l.discount || 0), tax_code_id: l.tax_code_id === NONE ? null : l.tax_code_id })),
      payments: payments.filter((p) => p.payment_account_id && Number(p.amount) > 0).map((p) => ({ payment_account_id: p.payment_account_id, amount: Number(p.amount) })),
    };
    setPending(true);
    const res = await savePurchaseDraft(input);
    if (!res.ok || !res.id) { setError(res.error ?? "Failed."); setPending(false); return; }
    if (post) {
      const pr = await postPurchase(res.id);
      if (!pr.ok) { setError(pr.error ?? "Draft saved but posting failed."); setPending(false); return; }
      toast.success("Purchase posted.");
    } else toast.success("Draft saved.");
    router.push(`/purchases/${res.id}`);
  }

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-[1fr_320px]">
      <div className="space-y-4">
        <Card><CardContent className="grid grid-cols-1 gap-4 p-5 sm:grid-cols-2">
          <div className="space-y-1.5"><Label>Supplier *</Label>
            <Select value={supplierId} onValueChange={setSupplierId}>
              <SelectTrigger><SelectValue placeholder="Select supplier" /></SelectTrigger>
              <SelectContent>{suppliers.map((s) => <SelectItem key={s.id} value={s.id}>{s.code} — {s.name}</SelectItem>)}</SelectContent>
            </Select></div>
          <div className="space-y-1.5"><Label>Purchase date</Label><Input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Supplier invoice no.</Label><Input value={invNo} onChange={(e) => setInvNo(e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Supplier invoice date</Label><Input type="date" value={invDate} onChange={(e) => setInvDate(e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Internal reference</Label><Input value={reference} onChange={(e) => setReference(e.target.value)} /></div>
          <div className="space-y-1.5"><Label>Due date {outstanding > 0 && <span className="text-destructive">*</span>}</Label><Input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} /></div>
        </CardContent></Card>

        <Card><CardContent className="p-3">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 text-xs uppercase text-muted-foreground">
                <tr><th className="px-2 py-2 text-left">Product</th><th className="px-2 py-2 text-right">Qty</th><th className="px-2 py-2 text-right">Cost</th><th className="px-2 py-2 text-right">Disc</th><th className="px-2 py-2 text-left">Tax</th><th className="px-2 py-2 text-right">Total</th><th /></tr>
              </thead>
              <tbody>
                {lines.map((l, i) => (
                  <tr key={l.key} className="border-t border-border align-top">
                    <td className="px-1 py-1 min-w-[280px]">
                      <ProductPicker products={products} value={l.product_id}
                        onChange={(v) => { const p = prodMap.get(v); setLine(l.key, { product_id: v, tax_code_id: p?.tax_code_id ?? NONE }); }} />
                    </td>
                    <td className="px-1 py-1"><Input className="h-8 w-20 text-right tabular-nums" type="number" min="0" step="0.0001" value={l.quantity} onChange={(e) => setLine(l.key, { quantity: e.target.value })} /></td>
                    <td className="px-1 py-1"><Input className="h-8 w-24 text-right tabular-nums" type="number" min="0" step="0.01" value={l.unit_cost} onChange={(e) => setLine(l.key, { unit_cost: e.target.value })} /></td>
                    <td className="px-1 py-1"><Input className="h-8 w-20 text-right tabular-nums" type="number" min="0" step="0.01" value={l.discount} onChange={(e) => setLine(l.key, { discount: e.target.value })} /></td>
                    <td className="px-1 py-1 min-w-[120px]">
                      <Select value={l.tax_code_id} onValueChange={(v) => setLine(l.key, { tax_code_id: v })}>
                        <SelectTrigger className="h-8"><SelectValue /></SelectTrigger>
                        <SelectContent><SelectItem value={NONE}>No tax</SelectItem>{taxCodes.map((t) => <SelectItem key={t.id} value={t.id}>{t.name} ({t.rate}%)</SelectItem>)}</SelectContent>
                      </Select>
                    </td>
                    <td className="px-2 py-1 text-right tabular-nums">{formatMoney(computed[i].lineTotal)}</td>
                    <td className="px-1 py-1 text-center"><button type="button" onClick={() => setLines(lines.filter((x) => x.key !== l.key))} className="text-muted-foreground hover:text-destructive"><Trash2 className="h-4 w-4" /></button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Button type="button" variant="outline" size="sm" className="mt-2" onClick={() => setLines([...lines, nl()])}><Plus className="h-4 w-4" /> Add line</Button>
        </CardContent></Card>

        <Card><CardContent className="p-5">
          <div className="mb-2 flex items-center justify-between">
            <Label>Payments</Label>
            <Button type="button" variant="outline" size="sm" onClick={() => setPayments([...payments, { key: Math.random().toString(36).slice(2), payment_account_id: "", amount: "" }])}><Plus className="h-4 w-4" /> Add payment</Button>
          </div>
          {payments.length === 0 && <p className="text-sm text-muted-foreground">No payments — this will be a credit purchase.</p>}
          <div className="space-y-2">
            {payments.map((p) => (
              <div key={p.key} className="flex items-center gap-2">
                <Select value={p.payment_account_id} onValueChange={(v) => setPayments(payments.map((x) => x.key === p.key ? { ...x, payment_account_id: v } : x))}>
                  <SelectTrigger className="h-8 flex-1"><SelectValue placeholder="Account" /></SelectTrigger>
                  <SelectContent>{accounts.map((a) => <SelectItem key={a.id} value={a.id}>{a.name}</SelectItem>)}</SelectContent>
                </Select>
                <Input className="h-8 w-32 text-right tabular-nums" type="number" min="0" step="0.01" placeholder="Amount" value={p.amount} onChange={(e) => setPayments(payments.map((x) => x.key === p.key ? { ...x, amount: e.target.value } : x))} />
                <button type="button" onClick={() => setPayments(payments.filter((x) => x.key !== p.key))} className="text-muted-foreground hover:text-destructive"><Trash2 className="h-4 w-4" /></button>
              </div>
            ))}
          </div>
        </CardContent></Card>
      </div>

      <div>
        <Card className="sticky top-20"><CardContent className="space-y-2 p-5 text-sm">
          <Row label="Subtotal" value={formatMoney(totals.subtotal)} />
          <Row label="Discount" value={formatMoney(totals.discount)} />
          <Row label="Net" value={formatMoney(totals.net)} />
          <Row label="Tax" value={formatMoney(totals.tax)} />
          <div className="my-1 border-t border-border" />
          <Row label="Grand total" value={formatMoney(totals.grand)} bold />
          <Row label="Paid" value={formatMoney(paid)} />
          <Row label="Outstanding" value={formatMoney(outstanding)} bold />
          {error && <p className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{error}</p>}
          <div className="flex flex-col gap-2 pt-2">
            <Button onClick={() => submit(true)} disabled={pending}>{pending ? "Working..." : "Post purchase"}</Button>
            <Button variant="outline" onClick={() => submit(false)} disabled={pending}>Save draft</Button>
          </div>
        </CardContent></Card>
      </div>
    </div>
  );
}

function Row({ label, value, bold }: { label: string; value: string; bold?: boolean }) {
  return <div className="flex items-center justify-between"><span className={bold ? "font-medium" : "text-muted-foreground"}>{label}</span><span className={`tabular-nums ${bold ? "font-semibold" : ""}`}>{value}</span></div>;
}
