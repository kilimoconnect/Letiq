"use client";

import * as React from "react";
import { Menu, PanelLeftClose, PanelLeftOpen, X } from "lucide-react";
import { SidebarBrand, SidebarNav } from "./sidebar";
import { Breadcrumbs } from "./breadcrumbs";
import { BranchSelector, type BranchOption } from "./branch-selector";
import { UserMenu } from "./user-menu";
import { cn } from "@/lib/utils";

export interface ShellUser {
  fullName: string | null;
  email: string;
  roleName: string;
  isOwner: boolean;
}

export function AppShell({
  user,
  permissions,
  companyName,
  branches,
  activeBranchId,
  children,
}: {
  user: ShellUser;
  permissions: string[];
  companyName: string;
  branches: BranchOption[];
  activeBranchId: string | null;
  children: React.ReactNode;
}) {
  const [collapsed, setCollapsed] = React.useState(false);
  const [mobileOpen, setMobileOpen] = React.useState(false);

  React.useEffect(() => {
    try {
      setCollapsed(localStorage.getItem("letiq_sidebar_collapsed") === "1");
    } catch {
      /* ignore */
    }
  }, []);

  function toggleCollapsed() {
    setCollapsed((c) => {
      const next = !c;
      try {
        localStorage.setItem("letiq_sidebar_collapsed", next ? "1" : "0");
      } catch {
        /* ignore */
      }
      return next;
    });
  }

  return (
    <div className="flex min-h-screen bg-background">
      {/* Desktop sidebar */}
      <aside
        className={cn(
          "sticky top-0 hidden h-screen shrink-0 flex-col bg-sidebar lg:flex transition-[width] duration-200",
          collapsed ? "w-16" : "w-60",
        )}
      >
        <SidebarBrand collapsed={collapsed} />
        <SidebarNav isOwner={user.isOwner} permissions={permissions} collapsed={collapsed} />
      </aside>

      {/* Mobile drawer */}
      {mobileOpen && (
        <div className="fixed inset-0 z-50 lg:hidden">
          <div
            className="absolute inset-0 bg-slate-900/50"
            onClick={() => setMobileOpen(false)}
          />
          <aside className="absolute left-0 top-0 flex h-full w-64 flex-col bg-sidebar shadow-xl">
            <div className="flex items-center justify-between">
              <SidebarBrand collapsed={false} />
              <button
                onClick={() => setMobileOpen(false)}
                className="mr-3 text-sidebar-muted hover:text-white"
                aria-label="Close menu"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <SidebarNav
              isOwner={user.isOwner}
              permissions={permissions}
              collapsed={false}
              onNavigate={() => setMobileOpen(false)}
            />
          </aside>
        </div>
      )}

      {/* Main column */}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 flex h-14 items-center gap-3 border-b border-border bg-card px-4">
          <button
            onClick={() => setMobileOpen(true)}
            className="rounded-md p-1.5 text-muted-foreground hover:bg-muted lg:hidden"
            aria-label="Open menu"
          >
            <Menu className="h-5 w-5" />
          </button>
          <button
            onClick={toggleCollapsed}
            className="hidden rounded-md p-1.5 text-muted-foreground hover:bg-muted lg:inline-flex"
            aria-label="Toggle sidebar"
          >
            {collapsed ? (
              <PanelLeftOpen className="h-5 w-5" />
            ) : (
              <PanelLeftClose className="h-5 w-5" />
            )}
          </button>

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold text-foreground">
              {companyName}
            </p>
          </div>

          <div className="hidden items-center gap-2 sm:flex">
            <span className="text-xs text-muted-foreground">Branch</span>
            <BranchSelector branches={branches} activeBranchId={activeBranchId} />
          </div>

          <UserMenu
            fullName={user.fullName}
            email={user.email}
            roleName={user.roleName}
          />
        </header>

        <div className="border-b border-border bg-card/60 px-4 py-2 sm:hidden">
          <BranchSelector branches={branches} activeBranchId={activeBranchId} />
        </div>

        <div className="px-4 pt-4">
          <Breadcrumbs />
        </div>

        <main className="flex-1 px-4 pb-10 pt-4">{children}</main>
      </div>
    </div>
  );
}
