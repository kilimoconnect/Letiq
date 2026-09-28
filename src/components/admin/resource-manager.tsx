"use client";

import * as React from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { toast } from "sonner";
import {
  Plus,
  Search,
  MoreHorizontal,
  Pencil,
  Eye,
  Power,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import {
  NO_ACTIVE_TOGGLE,
  type ColumnDef,
  type ResourceConfig,
} from "@/lib/admin/resources";
import type { OptionMap } from "@/lib/admin/queries";
import { setResourceActive } from "@/lib/admin/actions";
import { formatDate, formatMoney, formatQuantity } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { ResourceForm } from "./resource-form";
import { cn } from "@/lib/utils";

type Row = Record<string, unknown>;

export function ResourceManager({
  config,
  rows,
  total,
  page,
  pageSize,
  options,
  query,
}: {
  config: ResourceConfig;
  rows: Row[];
  total: number;
  page: number;
  pageSize: number;
  options: OptionMap;
  query: { q: string; status: "active" | "inactive" | "all" };
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [isPending, startTransition] = React.useTransition();

  const [formOpen, setFormOpen] = React.useState(false);
  const [editingRow, setEditingRow] = React.useState<Row | null>(null);
  const [viewingRow, setViewingRow] = React.useState<Row | null>(null);
  const [toggleRow, setToggleRow] = React.useState<Row | null>(null);
  const [searchText, setSearchText] = React.useState(query.q);

  const hasActive = !NO_ACTIVE_TOGGLE.has(config.key);
  const totalPages = Math.max(1, Math.ceil(total / pageSize));

  function navigate(next: Record<string, string | number | undefined>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [k, v] of Object.entries(next)) {
      if (v === undefined || v === "" || v === "all") params.delete(k);
      else params.set(k, String(v));
    }
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  function refLabel(col: ColumnDef, value: unknown): string {
    if (!value) return "—";
    const list = col.refKey ? options[col.refKey] : undefined;
    const found = list?.find((o) => o.value === value);
    return found?.label ?? "—";
  }

  function renderCell(col: ColumnDef, row: Row) {
    const v = row[col.key];
    switch (col.type) {
      case "money":
        return <span className="tabular-nums">{formatMoney(v as number)}</span>;
      case "number":
        return <span className="tabular-nums">{v == null ? "—" : String(v)}</span>;
      case "date":
        return formatDate(v as string);
      case "boolean":
        return v ? <Badge variant="secondary">Yes</Badge> : <span className="text-muted-foreground">No</span>;
      case "code":
        return <span className="font-mono text-xs font-medium">{(v as string) ?? "—"}</span>;
      case "ref":
        return refLabel(col, v);
      default:
        return v == null || v === "" ? <span className="text-muted-foreground">—</span> : String(v);
    }
  }

  function openCreate() {
    setEditingRow(null);
    setFormOpen(true);
  }
  function openEdit(row: Row) {
    setEditingRow(row);
    setFormOpen(true);
  }

  async function onToggleConfirm(reason: string) {
    if (!toggleRow) return;
    const nextActive = !(toggleRow.is_active as boolean);
    const res = await setResourceActive(config.key, toggleRow.id as string, nextActive, reason);
    if (!res.ok) return res.error ?? "Could not update.";
    toast.success(nextActive ? `${config.singular} activated.` : `${config.singular} deactivated.`);
    router.refresh();
  }

  const colCount = config.columns.length + (hasActive ? 1 : 0) + 1;

  return (
    <div className="space-y-4">
      {/* Toolbar */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            navigate({ q: searchText, page: 1 });
          }}
          className="relative flex-1 sm:max-w-xs"
        >
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={searchText}
            onChange={(e) => setSearchText(e.target.value)}
            placeholder={`Search ${config.title.toLowerCase()}...`}
            className="pl-8"
          />
        </form>

        <div className="flex items-center gap-2">
          {hasActive && (
            <Select
              value={query.status}
              onValueChange={(v) => navigate({ status: v, page: 1 })}
            >
              <SelectTrigger className="h-9 w-[130px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="active">Active</SelectItem>
                <SelectItem value="inactive">Inactive</SelectItem>
                <SelectItem value="all">All</SelectItem>
              </SelectContent>
            </Select>
          )}
          <Button onClick={openCreate}>
            <Plus className="h-4 w-4" />
            New {config.singular}
          </Button>
        </div>
      </div>

      {/* Table */}
      <div className={cn("rounded-lg border border-border bg-card", isPending && "opacity-60")}>
        <Table>
          <TableHeader>
            <TableRow>
              {config.columns.map((c) => (
                <TableHead key={c.key} className={c.align === "right" ? "text-right" : ""}>
                  {c.label}
                </TableHead>
              ))}
              {hasActive && <TableHead>Status</TableHead>}
              <TableHead className="w-10 text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={colCount} className="py-0">
                  <EmptyState
                    className="border-0 bg-transparent"
                    title={`No ${config.title.toLowerCase()} found`}
                    description={
                      query.q
                        ? "Try a different search term."
                        : `Create your first ${config.singular.toLowerCase()} to get started.`
                    }
                  />
                </TableCell>
              </TableRow>
            ) : (
              rows.map((row) => (
                <TableRow key={row.id as string}>
                  {config.columns.map((c) => (
                    <TableCell key={c.key} className={c.align === "right" ? "text-right" : ""}>
                      {renderCell(c, row)}
                    </TableCell>
                  ))}
                  {hasActive && (
                    <TableCell>
                      <StatusBadge active={Boolean(row.is_active)} />
                    </TableCell>
                  )}
                  <TableCell className="text-right">
                    <DropdownMenu>
                      <DropdownMenuTrigger className="inline-flex h-8 w-8 items-center justify-center rounded-md hover:bg-muted">
                        <MoreHorizontal className="h-4 w-4" />
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onClick={() => setViewingRow(row)}>
                          <Eye className="h-4 w-4" /> View details
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => openEdit(row)}>
                          <Pencil className="h-4 w-4" /> Edit
                        </DropdownMenuItem>
                        {hasActive && (
                          <DropdownMenuItem
                            variant={row.is_active ? "destructive" : "default"}
                            onClick={() => setToggleRow(row)}
                          >
                            <Power className="h-4 w-4" />
                            {row.is_active ? "Deactivate" : "Activate"}
                          </DropdownMenuItem>
                        )}
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Pagination */}
      {total > pageSize && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>
            {(page - 1) * pageSize + 1}–{Math.min(page * pageSize, total)} of {total}
          </span>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={page <= 1}
              onClick={() => navigate({ page: page - 1 })}
            >
              <ChevronLeft className="h-4 w-4" /> Prev
            </Button>
            <span>
              Page {page} of {totalPages}
            </span>
            <Button
              variant="outline"
              size="sm"
              disabled={page >= totalPages}
              onClick={() => navigate({ page: page + 1 })}
            >
              Next <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      )}

      {/* Create / Edit dialog */}
      <Dialog open={formOpen} onOpenChange={setFormOpen}>
        <DialogContent className={config.layout === "form" ? "max-w-2xl" : "max-w-lg"}>
          <DialogHeader>
            <DialogTitle>
              {editingRow ? `Edit ${config.singular}` : `New ${config.singular}`}
            </DialogTitle>
            <DialogDescription>{config.description}</DialogDescription>
          </DialogHeader>
          <ResourceForm
            config={config}
            options={options}
            row={editingRow}
            onCancel={() => setFormOpen(false)}
            onSaved={() => {
              setFormOpen(false);
              router.refresh();
            }}
          />
        </DialogContent>
      </Dialog>

      {/* View details dialog */}
      <Dialog open={!!viewingRow} onOpenChange={(o) => !o && setViewingRow(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{config.singular} details</DialogTitle>
          </DialogHeader>
          {viewingRow && (
            <dl className="grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
              {config.fields.map((f) => {
                const raw = viewingRow[f.name];
                let display: React.ReactNode;
                if (f.type === "switch") display = raw ? "Yes" : "No";
                else if (f.type === "money") display = formatMoney(raw as number);
                else if (f.type === "quantity") display = formatQuantity(raw as number);
                else if (f.type === "date") display = raw ? formatDate(raw as string) : "—";
                else if (f.type === "select" && f.optionsKey) {
                  const list = options[f.optionsKey];
                  display = list?.find((o) => o.value === raw)?.label ?? "—";
                } else if (f.type === "select" && f.options) {
                  display = f.options.find((o) => o.value === raw)?.label ?? "—";
                } else display = raw == null || raw === "" ? "—" : String(raw);
                return (
                  <div key={f.name} className={f.colSpan === 2 ? "sm:col-span-2" : ""}>
                    <dt className="text-xs uppercase tracking-wide text-muted-foreground">
                      {f.label}
                    </dt>
                    <dd className="text-sm">{display}</dd>
                  </div>
                );
              })}
            </dl>
          )}
        </DialogContent>
      </Dialog>

      {/* Activate / Deactivate confirm */}
      <ConfirmDialog
        open={!!toggleRow}
        onOpenChange={(o) => !o && setToggleRow(null)}
        title={
          toggleRow?.is_active
            ? `Deactivate ${config.singular.toLowerCase()}?`
            : `Activate ${config.singular.toLowerCase()}?`
        }
        description={
          toggleRow?.is_active
            ? "Deactivated records stay in history but are hidden from new activity and selection lists."
            : "This record will become available for selection again."
        }
        confirmLabel={toggleRow?.is_active ? "Deactivate" : "Activate"}
        destructive={Boolean(toggleRow?.is_active)}
        requireReason={Boolean(toggleRow?.is_active)}
        onConfirm={onToggleConfirm}
      />
    </div>
  );
}
