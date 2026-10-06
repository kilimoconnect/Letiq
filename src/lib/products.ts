type Named = { name: string } | { name: string }[] | null | undefined;

function nameOf(rel: Named): string | null {
  if (!rel) return null;
  return Array.isArray(rel) ? (rel[0]?.name ?? null) : rel.name;
}

/**
 * Flattens product rows selected with `category:product_categories(name)` and
 * `brand:brands(name)` into plain `category` / `brand` strings for the
 * ProductPicker.
 */
export function flattenProducts<T extends { category?: Named; brand?: Named }>(
  rows: T[] | null | undefined,
): (Omit<T, "category" | "brand"> & { category: string | null; brand: string | null })[] {
  return (rows ?? []).map((r) => ({ ...r, category: nameOf(r.category), brand: nameOf(r.brand) }));
}
