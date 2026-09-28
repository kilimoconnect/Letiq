"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { importStatementLines, matchStatementLine, addReconciliationAdjustment, finalizeReconciliation, reopenReconciliation } from "@/lib/reconciliation/actions";
import { formatMoney, formatDate } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";

export interface StmtLine { id: string; txn_date: string; description: string | null; reference: string | null; money_in: number; money_out: number; matched_amount: number; status: string }
export interface ErpEntry { journal_line_id: string; entry_date: string; source_number: string | null; amount: number; memo: string | null }
export interface AccOpt { id: string; code: string; name: string }

export function RecWorkspace({
  recId, status, finalized, statementNet, declaredNet, canFinalize, isOwner,
  lines, erpEntries, adjustmentAccounts,
}: {
  recId: string; status: string; finalized: boolean; statementNet: number; declaredNet: number;
  canFinalize: boolean; isOwner: boolean; lines: StmtLine[]; erpEntries: ErpEntry[]; adjustmentAccounts: AccOpt[];
}) {
  const router = useRouter();
  const [csv, setCsv] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [matchFor, setMatchFor] = React.useState<StmtLine | null>(null);
  const [adjFor, setAdjFor] = React.useState<StmtLine | null>(null);
  const [reopen, setReopen] = React.useState(false);

  async function doImport() {
    const rows = csv.split(/\r?\n/).map((r) => r.trim()).filter(Boolean).map((r) => {
      const [txn_date, description, reference, money_in, money_out] = r.split(",");
      return { txn_date: (txn_date || "").trim(), description, reference, money_in: Number(money_in || 0), money_out: Number(money_out || 0) };
    });
    if (rows.length === 0) { toast.error("Paste CSV rows first."); return; }
    setBusy(true);
    const res = await importStatementLines(recId, rows);
    setBusy(false);
    if (res.ok) { toast.success(`Imported ${res.imported}, skipped ${res.duplicates} duplicate(s).`); setCsv(""); router.refresh(); }
    else toast.error(res.error ?? "Failed.");
  }

  const unresolved = lines.filter((l) => l.status !== "matched" && l.status !== "adjusted").length;
  const diff = Math.round((statementNet - declaredNet) * 100) / 100;

  return (
    <div className="space-y-4">
      <Card><CardContent className="flex flex-wrap items-center gap-6 p-4 text-sm">
        <div><span className="text-muted-foreground">Statement lines net</span> <span className="tabular-nums font-medium">{formatMoney(statementNet)}</span></div>
        <div><span className="text-muted-foreground">Closing − opening</span> <span className="tabular-nums font-medium">{formatMoney(declaredNet)}</span></div>
        <div><span className="text-muted-foreground">Difference</span> <span className={`tabular-nums font-semibold ${Math.abs(diff) < 0.05 ? "text-success" : "text-destructive"}`}>{formatMoney(diff)}</span></div>
        <div><span className="text-muted-foreground">Unresolved</span> {unresolved}</div>
        <div className="ml-auto flex gap-2">
          {!finalized && canFinalize && <Button size="sm" onClick={async () => { setBusy(true); const r = await finalizeReconciliation(recId); setBusy(false); if (r.ok) { toast.success("Finalized."); router.refresh(); } else toast.error(r.error ?? "Failed."); }} disabled={busy}>Finalize</Button>}
          {finalized && isOwner && <Button size="sm" variant="outline" onClick={() => setReopen(true)}>Reopen</Button>}
        </div>
      </CardContent></Card>

      {!finalized && (
        <Card><CardContent className="space-y-2 p-4">
          <Label>Import statement (CSV: date,description,reference,money_in,money_out)</Label>
          <Textarea value={csv} onChange={(e) => setCsv(e.target.value)} rows={4} placeholder={"2026-09-01,Deposit,REF01,500000,0\n2026-09-02,Bank charge,,0,5000"} className="font-mono text-xs" />
          <Button size="sm" onClick={doImport} disabled={busy}>Import lines</Button>
        </CardContent></Card>
      )}

      <div className="rounded-lg border border-border bg-card">
        <Table>
          <TableHeader><TableRow><TableHead>Date</TableHead><TableHead>Description</TableHead><TableHead className="text-right">In</TableHead><TableHead className="text-right">Out</TableHead><TableHead>Status</TableHead><TableHead className="text-right">Action</TableHead></TableRow></TableHeader>
          <TableBody>
            {lines.map((l) => (
              <TableRow key={l.id}>
                <TableCell className="text-sm">{formatDate(l.txn_date)}</TableCell>
                <TableCell className="text-sm">{l.description ?? "—"}{l.reference ? ` · ${l.reference}` : ""}</TableCell>
                <TableCell className="text-right tabular-nums">{l.money_in ? formatMoney(l.money_in) : ""}</TableCell>
                <TableCell className="text-right tabular-nums">{l.money_out ? formatMoney(l.money_out) : ""}</TableCell>
                <TableCell><Badge variant={l.status === "matched" || l.status === "adjusted" ? "success" : l.status === "partial" ? "warning" : "muted"}>{l.status}</Badge></TableCell>
                <TableCell className="text-right">
                  {!finalized && l.status !== "matched" && l.status !== "adjusted" && (
                    <div className="flex justify-end gap-2">
                      <button className="text-xs text-primary hover:underline" onClick={() => setMatchFor(l)}>Match</button>
                      <button className="text-xs text-primary hover:underline" onClick={() => setAdjFor(l)}>Adjust</button>
                    </div>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {matchFor && <MatchDialog line={matchFor} erpEntries={erpEntries} recId={recId} onClose={() => setMatchFor(null)} onDone={() => { setMatchFor(null); router.refresh(); }} />}
      {adjFor && <AdjustDialog line={adjFor} accounts={adjustmentAccounts} recId={recId} onClose={() => setAdjFor(null)} onDone={() => { setAdjFor(null); router.refresh(); }} />}

      <ConfirmDialog open={reopen} onOpenChange={setReopen} title="Reopen reconciliation?" description="Only the Owner can reopen. Recorded in the audit trail." confirmLabel="Reopen" destructive requireReason
        onConfirm={async (reason) => { const r = await reopenReconciliation(recId, reason); if (!r.ok) return r.error ?? "Failed."; toast.success("Reopened."); router.refresh(); }} />
    </div>
  );
}

function MatchDialog({ line, erpEntries, recId, onClose, onDone }: { line: StmtLine; erpEntries: ErpEntry[]; recId: string; onClose: () => void; onDone: () => void }) {
  const [entry, setEntry] = React.useState("");
  const remaining = Math.round((line.money_in + line.money_out - line.matched_amount) * 100) / 100;
  const [amount, setAmount] = React.useState(String(remaining));
  const [busy, setBusy] = React.useState(false);
  return (
    <ConfirmDialogShell title="Match to an ERP entry" onClose={onClose}>
      <div className="space-y-3">
        <p className="text-sm text-muted-foreground">Statement line: {formatMoney(line.money_in + line.money_out)} · remaining {formatMoney(remaining)}</p>
        <div className="space-y-1.5"><Label>ERP entry</Label>
          <Select value={entry} onValueChange={setEntry}><SelectTrigger><SelectValue placeholder="Select posted entry" /></SelectTrigger>
            <SelectContent>{erpEntries.map((e) => <SelectItem key={e.journal_line_id} value={e.journal_line_id}>{formatDate(e.entry_date)} · {e.source_number ?? ""} · {formatMoney(e.amount)}</SelectItem>)}</SelectContent></Select></div>
        <div className="space-y-1.5"><Label>Amount</Label><Input type="number" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button disabled={busy || !entry} onClick={async () => { setBusy(true); const r = await matchStatementLine(recId, line.id, entry, Number(amount)); setBusy(false); if (r.ok) { toast.success("Matched."); onDone(); } else toast.error(r.error ?? "Failed."); }}>Match</Button>
        </div>
      </div>
    </ConfirmDialogShell>
  );
}

function AdjustDialog({ line, accounts, recId, onClose, onDone }: { line: StmtLine; accounts: AccOpt[]; recId: string; onClose: () => void; onDone: () => void }) {
  const direction = line.money_in > 0 ? "in" : "out";
  const [account, setAccount] = React.useState("");
  const [amount, setAmount] = React.useState(String(line.money_in || line.money_out));
  const [desc, setDesc] = React.useState(line.description ?? "");
  const [busy, setBusy] = React.useState(false);
  return (
    <ConfirmDialogShell title="Create an adjustment (posts a journal)" onClose={onClose}>
      <div className="space-y-3">
        <p className="text-sm text-muted-foreground">A {direction === "in" ? "money-in" : "money-out"} statement item not yet in the ERP. This posts a balanced journal.</p>
        <div className="space-y-1.5"><Label>Ledger account</Label>
          <Select value={account} onValueChange={setAccount}><SelectTrigger><SelectValue placeholder="Select account" /></SelectTrigger>
            <SelectContent>{accounts.map((a) => <SelectItem key={a.id} value={a.id}>{a.code} — {a.name}</SelectItem>)}</SelectContent></Select></div>
        <div className="space-y-1.5"><Label>Amount</Label><Input type="number" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
        <div className="space-y-1.5"><Label>Description</Label><Input value={desc} onChange={(e) => setDesc(e.target.value)} /></div>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button disabled={busy || !account || !desc} onClick={async () => { setBusy(true); const r = await addReconciliationAdjustment({ recId, statementLineId: line.id, accountId: account, direction, amount: Number(amount), description: desc }); setBusy(false); if (r.ok) { toast.success("Adjustment posted."); onDone(); } else toast.error(r.error ?? "Failed."); }}>Post adjustment</Button>
        </div>
      </div>
    </ConfirmDialogShell>
  );
}

function ConfirmDialogShell({ title, children, onClose }: { title: string; children: React.ReactNode; onClose: () => void }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-stone-900/50 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-lg border border-border bg-card p-6 shadow-lg" onClick={(e) => e.stopPropagation()}>
        <h3 className="mb-3 text-lg font-semibold">{title}</h3>
        {children}
      </div>
    </div>
  );
}
