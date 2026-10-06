import type { Metadata } from "next";
import { requirePermissionPage } from "@/lib/auth/guards";
import { getActiveContext, can } from "@/lib/context";
import { createAdminClient } from "@/lib/supabase/admin";
import { flattenProducts } from "@/lib/products";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { SaleForm } from "./sale-form";

export const metadata: Metadata = { title: "Create Sale" };

export default async function NewSalePage() {
  await requirePermissionPage("sales.create");
  const ctx = await getActiveContext();
  const admin = createAdminClient();

  if (!ctx.branchId) {
    return (
      <div>
        <PageHeader title="Create Sale" />
        <EmptyState title="No active branch" description="You need an assigned branch to create sales." />
      </div>
    );
  }

  const [{ data: products }, { data: taxCodes }, { data: accounts }, { data: customers }, { data: bals }] = await Promise.all([
    admin.from("products").select("id, sku, barcode, name, selling_price, tax_code_id, track_inventory, category:product_categories(name), brand:brands(name)").eq("company_id", ctx.companyId).eq("is_active", true).order("name"),
    admin.from("tax_codes").select("id, name, rate, is_inclusive").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
    admin.from("payment_accounts").select("id, code, name, branch_id").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
    admin.from("customers").select("id, code, name, is_protected").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
    admin.from("stock_balances").select("product_id, quantity").eq("company_id", ctx.companyId).eq("branch_id", ctx.branchId),
  ]);

  const stock: Record<string, number> = {};
  for (const b of bals ?? []) stock[b.product_id] = Number(b.quantity);
  const branchAccounts = (accounts ?? []).filter((a) => !a.branch_id || a.branch_id === ctx.branchId);
  const walkIn = (customers ?? []).find((c) => c.is_protected);

  return (
    <div>
      <PageHeader title="Create Sale" description="Fast sales entry. Totals and stock are validated on the server at posting." />
      <SaleForm
        branchId={ctx.branchId}
        products={flattenProducts(products)}
        taxCodes={(taxCodes ?? []).map((t) => ({ ...t, rate: Number(t.rate) })) as never}
        accounts={branchAccounts as never}
        customers={(customers ?? []) as never}
        stock={stock}
        canViewCost={can(ctx.user, "sales.view_cost")}
        walkInId={walkIn?.id ?? null}
      />
    </div>
  );
}
