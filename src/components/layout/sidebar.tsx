"use client";

import Link, { useLinkStatus } from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";
import { Lock, Loader2 } from "lucide-react";
import { NAV, canSee } from "./nav-config";
import { cn } from "@/lib/utils";

/** Shows a spinner on the clicked link while its route is loading. */
function NavPending() {
  const { pending } = useLinkStatus();
  return pending ? (
    <Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-sidebar-muted" />
  ) : null;
}

export function SidebarNav({
  isOwner,
  permissions,
  collapsed,
  onNavigate,
}: {
  isOwner: boolean;
  permissions: string[];
  collapsed: boolean;
  onNavigate?: () => void;
}) {
  const pathname = usePathname();
  const perms = new Set(permissions);

  const isActive = (href: string) =>
    pathname === href || pathname.startsWith(`${href}/`);

  return (
    <nav className="flex flex-1 flex-col gap-0.5 overflow-y-auto px-2 py-3">
      {NAV.map((entry) => {
        const Icon = entry.icon;

        // Disabled future modules
        if (!entry.enabled) {
          return (
            <div
              key={entry.label}
              title="Available in a later phase"
              className={cn(
                "flex cursor-not-allowed items-center gap-3 rounded-md px-3 py-2 text-sm text-sidebar-muted/60",
                collapsed && "justify-center px-0",
              )}
            >
              <Icon className="h-[18px] w-[18px] shrink-0" />
              {!collapsed && (
                <>
                  <span className="flex-1 truncate">{entry.label}</span>
                  <Lock className="h-3 w-3" />
                </>
              )}
            </div>
          );
        }

        if (!canSee(entry, isOwner, perms)) return null;

        // Group with children
        if (entry.items) {
          const visibleItems = entry.items.filter((it) => canSee(it, isOwner, perms));
          if (visibleItems.length === 0) return null;
          const groupActive = visibleItems.some((it) => isActive(it.href));
          return (
            <div key={entry.label} className="mt-1">
              <div
                className={cn(
                  "flex items-center gap-3 rounded-md px-3 py-1.5 text-[11px] font-semibold uppercase tracking-wide text-sidebar-muted",
                  collapsed && "justify-center px-0",
                )}
              >
                <Icon className="h-[18px] w-[18px] shrink-0" />
                {!collapsed && <span className="flex-1 truncate">{entry.label}</span>}
              </div>
              {!collapsed &&
                visibleItems.map((it) => (
                  <Link
                    key={it.href}
                    href={it.href}
                    onClick={onNavigate}
                    className={cn(
                      "ml-3 flex items-center gap-3 rounded-md px-3 py-1.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-active",
                      isActive(it.href) && "bg-sidebar-active text-white",
                    )}
                  >
                    <span className="flex-1 truncate">{it.label}</span>
                    <NavPending />
                  </Link>
                ))}
              {collapsed && groupActive && (
                <div className="mx-auto my-0.5 h-1 w-1 rounded-full bg-sidebar-accent" />
              )}
            </div>
          );
        }

        // Leaf link
        const href = entry.href!;
        return (
          <Link
            key={href}
            href={href}
            onClick={onNavigate}
            className={cn(
              "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium text-sidebar-foreground transition-colors hover:bg-sidebar-active",
              isActive(href) && "bg-sidebar-active text-white",
              collapsed && "justify-center px-0",
            )}
          >
            <Icon className="h-[18px] w-[18px] shrink-0" />
            {!collapsed && <span className="flex-1 truncate">{entry.label}</span>}
            {!collapsed && <NavPending />}
          </Link>
        );
      })}
    </nav>
  );
}

export function SidebarBrand({ collapsed }: { collapsed: boolean }) {
  return (
    <div
      className={cn(
        "flex h-14 items-center gap-2.5 border-b border-sidebar-border px-4",
        collapsed && "justify-center px-0",
      )}
    >
      <div className="flex h-8 w-8 shrink-0 items-center justify-center overflow-hidden rounded-md">
        <Image
          src="/icon.png"
          alt="Letiq Limited"
          width={1024}
          height={1024}
          className="h-full w-full object-contain"
        />
      </div>
      {!collapsed && (
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold text-white">Letiq ERP</p>
          <p className="truncate text-[11px] text-sidebar-muted">Letiq Limited</p>
        </div>
      )}
    </div>
  );
}
