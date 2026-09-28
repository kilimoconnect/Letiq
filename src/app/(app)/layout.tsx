import { cookies } from "next/headers";
import { requireActiveUser } from "@/lib/auth/guards";
import { createAdminClient } from "@/lib/supabase/admin";
import { ACTIVE_BRANCH_COOKIE } from "@/lib/auth/constants";
import { AppShell } from "@/components/layout/app-shell";
import type { BranchOption } from "@/components/layout/branch-selector";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireActiveUser();
  const admin = createAdminClient();

  const companyId = user.defaultCompanyId ?? user.companyIds[0] ?? null;
  let companyName =
    process.env.NEXT_PUBLIC_COMPANY_NAME ?? "Letiq Limited";
  let branches: BranchOption[] = [];

  if (companyId) {
    const { data: company } = await admin
      .from("companies")
      .select("name")
      .eq("id", companyId)
      .maybeSingle();
    if (company?.name) companyName = company.name;

    const { data: allBranches } = await admin
      .from("branches")
      .select("id, name, code")
      .eq("company_id", companyId)
      .eq("is_active", true)
      .order("code");

    const rows = (allBranches ?? []) as BranchOption[];
    branches = user.isOwner
      ? rows
      : rows.filter((b) => user.branchIds.includes(b.id));
  }

  const accessible = new Set(branches.map((b) => b.id));
  const store = await cookies();
  const cookieBranch = store.get(ACTIVE_BRANCH_COOKIE)?.value;
  const activeBranchId =
    cookieBranch && accessible.has(cookieBranch)
      ? cookieBranch
      : user.defaultBranchId && accessible.has(user.defaultBranchId)
        ? user.defaultBranchId
        : (branches[0]?.id ?? null);

  return (
    <AppShell
      user={{
        fullName: user.fullName,
        email: user.email,
        roleName: user.role?.name ?? "No role",
        isOwner: user.isOwner,
      }}
      permissions={Array.from(user.permissions)}
      companyName={companyName}
      branches={branches}
      activeBranchId={activeBranchId}
    >
      {children}
    </AppShell>
  );
}
