import type { Metadata } from "next";
import { requirePermissionPage } from "@/lib/auth/guards";
import { getActiveContext } from "@/lib/context";
import { createAdminClient } from "@/lib/supabase/admin";
import { flattenProducts } from "@/lib/products";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { PurchaseForm } from "./purchase-form";

export const metadata: Metadata = { title: "Create Purchase" };

export default async function NewPurchasePage() {
  await requirePermissionPage("purchases.create");
  const ctx = await getActiveContext();
  const admin = createAdminClient();
  if (!ctx.branchId) return <div><PageHeader title="Create Purchase" /><EmptyState title="No active branch" /></div>;

  const [{ data: products }, { data: taxCodes }, { data: accounts }, { data: suppliers }] = await Promise.all([
    admin.from("products").select("id, sku, barcode, name, tax_code_id, category:product_categories(name), brand:brands(name)").eq("company_id", ctx.companyId).eq("is_active", true).order("name"),
    admin.from("tax_codes").select("id, name, rate, is_inclusive").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
    admin.from("payment_accounts").select("id, name, branch_id").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
    admin.from("suppliers").select("id, code, name").eq("company_id", ctx.companyId).eq("is_active", true).order("code"),
  ]);
  const branchAccounts = (accounts ?? []).filter((a) => !a.branch_id || a.branch_id === ctx.branchId);

  return (
    <div>
      <PageHeader title="Create Purchase" description="Record received goods and the supplier invoice. Save as draft if goods are not yet received." />
      <PurchaseForm branchId={ctx.branchId}
        products={flattenProducts(products)}
        taxCodes={(taxCodes ?? []).map((t) => ({ ...t, rate: Number(t.rate) })) as never}
        accounts={branchAccounts as never} suppliers={(suppliers ?? []) as never} />
    </div>
  );
}
