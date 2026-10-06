"use client";

import * as React from "react";
import { ChevronDown, Search } from "lucide-react";
import { cn } from "@/lib/utils";
import { Input } from "@/components/ui/input";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

export interface PickerProduct {
  id: string;
  sku: string;
  name: string;
  barcode?: string | null;
  category?: string | null;
  brand?: string | null;
  track_inventory?: boolean;
}

const MAX_RESULTS = 200;

function details(p: PickerProduct) {
  return [p.sku, p.category, p.brand].filter(Boolean).join(" · ");
}

/**
 * Product selector that opens a wide search window listing SKU, name,
 * category and brand. When `available` is given (sales), stock is shown and
 * tracked products with no stock cannot be picked.
 */
export function ProductPicker({
  products,
  value,
  onChange,
  available,
  placeholder = "Search product",
  className,
}: {
  products: PickerProduct[];
  value: string;
  onChange: (id: string) => void;
  available?: Record<string, number>;
  placeholder?: string;
  className?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const [active, setActive] = React.useState(0);
  const listRef = React.useRef<HTMLTableSectionElement>(null);

  const selected = products.find((p) => p.id === value);
  const showStock = available !== undefined;
  const isBlocked = (p: PickerProduct) =>
    showStock && p.track_inventory !== false && (available?.[p.id] ?? 0) <= 0;

  const results = React.useMemo(() => {
    const tokens = q.toLowerCase().split(/\s+/).filter(Boolean);
    const matched = tokens.length === 0
      ? products
      : products.filter((p) => {
          const hay = [p.sku, p.name, p.barcode, p.category, p.brand].filter(Boolean).join(" ").toLowerCase();
          return tokens.every((t) => hay.includes(t));
        });
    return matched.slice(0, MAX_RESULTS);
  }, [products, q]);

  React.useEffect(() => {
    listRef.current?.querySelector(`[data-index="${active}"]`)?.scrollIntoView({ block: "nearest" });
  }, [active]);

  function choose(p: PickerProduct) {
    if (isBlocked(p)) return;
    onChange(p.id);
    setOpen(false);
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown") { e.preventDefault(); setActive((i) => Math.min(i + 1, results.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
    else if (e.key === "Enter") { e.preventDefault(); const p = results[active]; if (p) choose(p); }
  }

  return (
    <>
      <button
        type="button"
        onClick={() => { setQ(""); setActive(0); setOpen(true); }}
        className={cn(
          "flex min-h-8 w-full items-center justify-between gap-2 rounded-md border border-input bg-card px-2.5 py-1 text-left text-sm shadow-sm transition-colors hover:bg-muted/40 focus:outline-none focus:ring-2 focus:ring-ring",
          className,
        )}
      >
        {selected ? (
          <span className="min-w-0">
            <span className="block truncate font-medium">{selected.name}</span>
            <span className="block truncate text-xs text-muted-foreground">{details(selected)}</span>
          </span>
        ) : (
          <span className="flex items-center gap-1.5 text-muted-foreground"><Search className="h-3.5 w-3.5" />{placeholder}</span>
        )}
        <ChevronDown className="h-4 w-4 shrink-0 opacity-50" />
      </button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="flex max-h-[85vh] max-w-4xl flex-col gap-3 overflow-hidden">
          <DialogHeader>
            <DialogTitle>Select product</DialogTitle>
            <DialogDescription>Search by name, SKU, barcode, category or brand.</DialogDescription>
          </DialogHeader>
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input autoFocus value={q} onChange={(e) => { setQ(e.target.value); setActive(0); }} onKeyDown={onKeyDown}
              placeholder="Type to search..." className="pl-8" />
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto rounded-md border border-border">
            <table className="w-full text-sm">
              <thead className="sticky top-0 bg-muted text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="px-3 py-2 text-left">SKU</th>
                  <th className="px-3 py-2 text-left">Product</th>
                  <th className="px-3 py-2 text-left">Category</th>
                  <th className="px-3 py-2 text-left">Brand</th>
                  {showStock && <th className="px-3 py-2 text-right">Available</th>}
                </tr>
              </thead>
              <tbody ref={listRef}>
                {results.map((p, i) => {
                  const blocked = isBlocked(p);
                  return (
                    <tr
                      key={p.id}
                      data-index={i}
                      onClick={() => choose(p)}
                      onMouseEnter={() => setActive(i)}
                      className={cn(
                        "border-t border-border",
                        blocked ? "cursor-not-allowed opacity-50" : "cursor-pointer",
                        i === active && !blocked && "bg-accent",
                        p.id === value && "font-medium",
                      )}
                    >
                      <td className="px-3 py-2 font-mono text-xs">{p.sku}</td>
                      <td className="px-3 py-2">{p.name}</td>
                      <td className="px-3 py-2 text-muted-foreground">{p.category ?? "—"}</td>
                      <td className="px-3 py-2 text-muted-foreground">{p.brand ?? "—"}</td>
                      {showStock && (
                        <td className="px-3 py-2 text-right tabular-nums">
                          {p.track_inventory === false
                            ? <span className="text-xs text-muted-foreground">Not tracked</span>
                            : blocked
                              ? <span className="text-xs font-medium text-destructive">Out of stock</span>
                              : available?.[p.id]}
                        </td>
                      )}
                    </tr>
                  );
                })}
                {results.length === 0 && (
                  <tr><td colSpan={showStock ? 5 : 4} className="px-3 py-8 text-center text-muted-foreground">No products match.</td></tr>
                )}
              </tbody>
            </table>
          </div>
          {results.length === MAX_RESULTS && (
            <p className="text-xs text-muted-foreground">Showing the first {MAX_RESULTS} matches — type more to narrow down.</p>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
