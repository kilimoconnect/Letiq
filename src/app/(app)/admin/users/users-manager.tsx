"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { MoreHorizontal, Pencil, Plus, Power, KeyRound, Search, ShieldCheck } from "lucide-react";
import {
  createUser,
  updateUser,
  setUserActive,
  sendPasswordReset,
} from "@/lib/admin/users-actions";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { cn } from "@/lib/utils";

export interface UserRow {
  id: string;
  email: string;
  fullName: string | null;
  phone: string | null;
  isActive: boolean;
  isPrimaryOwner: boolean;
  roleId: string | null;
  roleName: string;
  defaultBranchId: string | null;
  companyIds: string[];
  branchIds: string[];
}
export interface RefRow { id: string; name: string; code: string }
export interface CompanyRow { id: string; code: string; name: string }
export interface BranchRow { id: string; code: string; name: string; company_id: string }

export function UsersManager({
  currentUserId,
  users,
  roles,
  companies,
  branches,
}: {
  currentUserId: string;
  users: UserRow[];
  roles: RefRow[];
  companies: CompanyRow[];
  branches: BranchRow[];
}) {
  const router = useRouter();
  const [search, setSearch] = React.useState("");
  const [formUser, setFormUser] = React.useState<UserRow | null>(null);
  const [creating, setCreating] = React.useState(false);
  const [toggleUser, setToggleUser] = React.useState<UserRow | null>(null);

  const assignableRoles = roles.filter((r) => r.code !== "OWNER");

  const filtered = users.filter((u) => {
    const t = search.trim().toLowerCase();
    if (!t) return true;
    return (
      u.email.toLowerCase().includes(t) ||
      (u.fullName ?? "").toLowerCase().includes(t) ||
      u.roleName.toLowerCase().includes(t)
    );
  });

  async function onToggle(reason: string) {
    if (!toggleUser) return;
    const res = await setUserActive(toggleUser.id, !toggleUser.isActive, reason);
    if (!res.ok) return res.error ?? "Could not update.";
    toast.success(toggleUser.isActive ? "User deactivated." : "User activated.");
    router.refresh();
  }

  async function onReset(u: UserRow) {
    const res = await sendPasswordReset(u.id);
    if (res.ok) toast.success(`Password reset email sent to ${u.email}.`);
    else toast.error(res.error ?? "Could not send reset.");
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative flex-1 sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search users..."
            className="pl-8"
          />
        </div>
        <Button onClick={() => setCreating(true)}>
          <Plus className="h-4 w-4" /> New User
        </Button>
      </div>

      <div className="rounded-lg border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>User</TableHead>
              <TableHead>Role</TableHead>
              <TableHead>Branches</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="w-10 text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filtered.length === 0 ? (
              <TableRow>
                <TableCell colSpan={5} className="py-0">
                  <EmptyState className="border-0 bg-transparent" title="No users found" />
                </TableCell>
              </TableRow>
            ) : (
              filtered.map((u) => (
                <TableRow key={u.id}>
                  <TableCell>
                    <div className="flex items-center gap-1.5">
                      <span className="font-medium">{u.fullName || "—"}</span>
                      {u.isPrimaryOwner && (
                        <Badge variant="default" className="gap-1">
                          <ShieldCheck className="h-3 w-3" /> Owner
                        </Badge>
                      )}
                    </div>
                    <div className="text-xs text-muted-foreground">{u.email}</div>
                  </TableCell>
                  <TableCell>{u.roleName}</TableCell>
                  <TableCell className="text-sm text-muted-foreground">
                    {u.branchIds.length} assigned
                  </TableCell>
                  <TableCell><StatusBadge active={u.isActive} /></TableCell>
                  <TableCell className="text-right">
                    <DropdownMenu>
                      <DropdownMenuTrigger className="inline-flex h-8 w-8 items-center justify-center rounded-md hover:bg-muted">
                        <MoreHorizontal className="h-4 w-4" />
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onClick={() => setFormUser(u)}>
                          <Pencil className="h-4 w-4" /> Edit
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => onReset(u)}>
                          <KeyRound className="h-4 w-4" /> Send password reset
                        </DropdownMenuItem>
                        {!u.isPrimaryOwner && u.id !== currentUserId && (
                          <DropdownMenuItem
                            variant={u.isActive ? "destructive" : "default"}
                            onClick={() => setToggleUser(u)}
                          >
                            <Power className="h-4 w-4" />
                            {u.isActive ? "Deactivate" : "Activate"}
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

      {/* Create */}
      <Dialog open={creating} onOpenChange={setCreating}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>New user</DialogTitle>
            <DialogDescription>
              Create an account and assign a role, companies and branches.
            </DialogDescription>
          </DialogHeader>
          <UserForm
            mode="create"
            roles={assignableRoles}
            companies={companies}
            branches={branches}
            onCancel={() => setCreating(false)}
            onSaved={() => { setCreating(false); router.refresh(); }}
          />
        </DialogContent>
      </Dialog>

      {/* Edit */}
      <Dialog open={!!formUser} onOpenChange={(o) => !o && setFormUser(null)}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>Edit user</DialogTitle>
            <DialogDescription>{formUser?.email}</DialogDescription>
          </DialogHeader>
          {formUser && (
            <UserForm
              mode="edit"
              user={formUser}
              roles={assignableRoles}
              companies={companies}
              branches={branches}
              onCancel={() => setFormUser(null)}
              onSaved={() => { setFormUser(null); router.refresh(); }}
            />
          )}
        </DialogContent>
      </Dialog>

      <ConfirmDialog
        open={!!toggleUser}
        onOpenChange={(o) => !o && setToggleUser(null)}
        title={toggleUser?.isActive ? "Deactivate user?" : "Activate user?"}
        description={
          toggleUser?.isActive
            ? "The user will immediately lose the ability to sign in or perform actions."
            : "The user will be able to sign in again."
        }
        confirmLabel={toggleUser?.isActive ? "Deactivate" : "Activate"}
        destructive={Boolean(toggleUser?.isActive)}
        requireReason={Boolean(toggleUser?.isActive)}
        onConfirm={onToggle}
      />
    </div>
  );
}

function UserForm({
  mode,
  user,
  roles,
  companies,
  branches,
  onCancel,
  onSaved,
}: {
  mode: "create" | "edit";
  user?: UserRow;
  roles: RefRow[];
  companies: CompanyRow[];
  branches: BranchRow[];
  onCancel: () => void;
  onSaved: () => void;
}) {
  const isOwner = user?.isPrimaryOwner ?? false;
  const [email, setEmail] = React.useState(user?.email ?? "");
  const [password, setPassword] = React.useState("");
  const [fullName, setFullName] = React.useState(user?.fullName ?? "");
  const [phone, setPhone] = React.useState(user?.phone ?? "");
  const [roleId, setRoleId] = React.useState(user?.roleId ?? "");
  const [companyIds, setCompanyIds] = React.useState<Set<string>>(
    () => new Set(user?.companyIds ?? companies.map((c) => c.id)),
  );
  const [branchIds, setBranchIds] = React.useState<Set<string>>(
    () => new Set(user?.branchIds ?? []),
  );
  const [defaultBranchId, setDefaultBranchId] = React.useState(user?.defaultBranchId ?? "");
  const [isActive, setIsActive] = React.useState(user?.isActive ?? true);
  const [pending, setPending] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const visibleBranches = branches.filter((b) => companyIds.has(b.company_id));
  const selectedBranchList = visibleBranches.filter((b) => branchIds.has(b.id));

  function toggleSet(set: Set<string>, id: string, setter: (s: Set<string>) => void) {
    const next = new Set(set);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setter(next);
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setPending(true);
    setError(null);
    const payload = {
      fullName,
      phone,
      roleId,
      companyIds: Array.from(companyIds),
      branchIds: Array.from(branchIds).filter((id) => visibleBranches.some((b) => b.id === id)),
      defaultBranchId: defaultBranchId || null,
      isActive,
    };
    const res =
      mode === "create"
        ? await createUser({ email, password, ...payload })
        : await updateUser(user!.id, payload);
    if (res.ok) {
      toast.success(mode === "create" ? "User created." : "User updated.");
      onSaved();
    } else {
      setError(res.error ?? "Could not save.");
      setPending(false);
    }
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="u-email">Email *</Label>
          <Input
            id="u-email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={mode === "edit"}
            required
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="u-name">Full Name *</Label>
          <Input id="u-name" value={fullName} onChange={(e) => setFullName(e.target.value)} required />
        </div>
        {mode === "create" && (
          <div className="space-y-1.5">
            <Label htmlFor="u-pass">Initial Password *</Label>
            <Input
              id="u-pass"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              minLength={8}
              required
              autoComplete="new-password"
            />
            <p className="text-xs text-muted-foreground">
              At least 8 characters. Share it securely; the user can change it later.
            </p>
          </div>
        )}
        <div className="space-y-1.5">
          <Label htmlFor="u-phone">Phone</Label>
          <Input id="u-phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label>Role *</Label>
          {isOwner ? (
            <Input value={user?.roleName ?? "Owner"} disabled />
          ) : (
            <Select value={roleId} onValueChange={setRoleId}>
              <SelectTrigger><SelectValue placeholder="Select role" /></SelectTrigger>
              <SelectContent>
                {roles.map((r) => (
                  <SelectItem key={r.id} value={r.id}>{r.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
      </div>

      <div className="space-y-2">
        <Label>Companies *</Label>
        <div className="flex flex-wrap gap-2">
          {companies.map((c) => (
            <label
              key={c.id}
              className={cn(
                "flex cursor-pointer items-center gap-2 rounded-md border border-border px-2.5 py-1.5 text-sm hover:bg-muted",
                companyIds.has(c.id) && "border-primary/40 bg-accent",
              )}
            >
              <Checkbox
                checked={companyIds.has(c.id)}
                onCheckedChange={() => toggleSet(companyIds, c.id, setCompanyIds)}
              />
              {c.code} — {c.name}
            </label>
          ))}
        </div>
      </div>

      <div className="space-y-2">
        <Label>Branches</Label>
        {visibleBranches.length === 0 ? (
          <p className="text-sm text-muted-foreground">Select a company to see its branches.</p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {visibleBranches.map((b) => (
              <label
                key={b.id}
                className={cn(
                  "flex cursor-pointer items-center gap-2 rounded-md border border-border px-2.5 py-1.5 text-sm hover:bg-muted",
                  branchIds.has(b.id) && "border-primary/40 bg-accent",
                )}
              >
                <Checkbox
                  checked={branchIds.has(b.id)}
                  onCheckedChange={() => toggleSet(branchIds, b.id, setBranchIds)}
                />
                {b.code} — {b.name}
              </label>
            ))}
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label>Default Branch</Label>
          <Select
            value={defaultBranchId || undefined}
            onValueChange={setDefaultBranchId}
            disabled={selectedBranchList.length === 0}
          >
            <SelectTrigger><SelectValue placeholder="Select default branch" /></SelectTrigger>
            <SelectContent>
              {selectedBranchList.map((b) => (
                <SelectItem key={b.id} value={b.id}>{b.code} — {b.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex items-center justify-between rounded-md border border-border px-3 py-2">
          <div>
            <Label>Active</Label>
            <p className="text-xs text-muted-foreground">Inactive users cannot sign in.</p>
          </div>
          <Switch checked={isActive} onCheckedChange={setIsActive} disabled={isOwner} />
        </div>
      </div>

      {error && (
        <p className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{error}</p>
      )}

      <div className="flex justify-end gap-2 pt-2">
        <Button type="button" variant="outline" onClick={onCancel} disabled={pending}>Cancel</Button>
        <Button type="submit" disabled={pending}>
          {pending ? "Saving..." : mode === "create" ? "Create user" : "Save changes"}
        </Button>
      </div>
    </form>
  );
}
