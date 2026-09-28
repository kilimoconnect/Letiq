import type { Metadata } from "next";
import Link from "next/link";
import {
  Building,
  Building2,
  Package,
  Tags,
  Bookmark,
  Ruler,
  Percent,
  Wallet,
  Coins,
  Receipt,
  Users2,
  Truck,
  BookText,
  ShieldCheck,
  UserCog,
  Hash,
  CalendarRange,
  ScrollText,
  type LucideIcon,
} from "lucide-react";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";

export const metadata: Metadata = { title: "Admin" };

interface Section {
  label: string;
  href: string;
  description: string;
  icon: LucideIcon;
}

interface Group {
  title: string;
  items: Section[];
}

const GROUPS: Group[] = [
  {
    title: "Organisation",
    items: [
      { label: "Company", href: "/admin/company", description: "Company profile & defaults", icon: Building2 },
      { label: "Branches", href: "/admin/branches", description: "Locations and head office", icon: Building },
      { label: "Accounting Periods", href: "/admin/accounting-periods", description: "Financial years & status", icon: CalendarRange },
      { label: "Document Numbering", href: "/admin/document-numbering", description: "Transaction number sequences", icon: Hash },
    ],
  },
  {
    title: "Catalogue",
    items: [
      { label: "Products", href: "/admin/products", description: "Goods and items", icon: Package },
      { label: "Product Categories", href: "/admin/product-categories", description: "Product grouping", icon: Tags },
      { label: "Brands", href: "/admin/brands", description: "Product brands", icon: Bookmark },
      { label: "Units of Measurement", href: "/admin/units", description: "Piece, litre, kg, carton…", icon: Ruler },
    ],
  },
  {
    title: "Finance",
    items: [
      { label: "Tax Codes", href: "/admin/tax-codes", description: "VAT & tax configuration", icon: Percent },
      { label: "Payment Accounts", href: "/admin/payment-accounts", description: "Cash, bank & mobile money", icon: Wallet },
      { label: "Chart of Accounts", href: "/admin/chart-of-accounts", description: "General-ledger accounts", icon: BookText },
      { label: "Other Income Types", href: "/admin/other-income-types", description: "Income categories", icon: Coins },
      { label: "Expense Categories", href: "/admin/expense-categories", description: "Expense categories", icon: Receipt },
    ],
  },
  {
    title: "Relationships",
    items: [
      { label: "Customers", href: "/admin/customers", description: "People you sell to", icon: Users2 },
      { label: "Suppliers", href: "/admin/suppliers", description: "Vendors you buy from", icon: Truck },
    ],
  },
  {
    title: "Security & Governance",
    items: [
      { label: "Users", href: "/admin/users", description: "Accounts, roles & access", icon: UserCog },
      { label: "Roles & Permissions", href: "/admin/roles", description: "Roles and their permissions", icon: ShieldCheck },
      { label: "Audit Log", href: "/admin/audit-log", description: "Immutable activity trail", icon: ScrollText },
    ],
  },
];

export default function AdminPage() {
  return (
    <div>
      <PageHeader
        title="Administration"
        description="Configure master data, security and system settings for Letiq ERP."
      />
      <div className="space-y-8">
        {GROUPS.map((group) => (
          <section key={group.title}>
            <h2 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              {group.title}
            </h2>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {group.items.map((item) => {
                const Icon = item.icon;
                return (
                  <Link key={item.href} href={item.href}>
                    <Card className="flex items-start gap-3 p-4 transition-colors hover:border-primary/40 hover:bg-accent/40">
                      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-primary/10 text-primary">
                        <Icon className="h-[18px] w-[18px]" />
                      </div>
                      <div className="min-w-0">
                        <p className="text-sm font-medium text-foreground">{item.label}</p>
                        <p className="text-xs text-muted-foreground">{item.description}</p>
                      </div>
                    </Card>
                  </Link>
                );
              })}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
