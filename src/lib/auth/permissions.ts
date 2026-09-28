/**
 * Permission catalog and role matrix.
 *
 * Pure data (no server-only imports) so it can be consumed by both the app and
 * the seed script. Permissions follow `resource.action`. Most resources are
 * forward-looking scaffolding for modules that arrive in later phases; Phase 1
 * only actively enforces the Admin / Users / Roles / Audit-log permissions,
 * which belong to the Owner.
 */

export const RESOURCES = [
  "dashboard",
  "sales",
  "purchases",
  "other_income",
  "expenses",
  "cash_transfers",
  "inventory",
  "kardex",
  "reports",
  "admin",
  "users",
  "roles",
  "audit_log",
  "transactions",
  "cash_accounts",
  "accounting",
  "reconciliation",
  "periods",
] as const;
export type Resource = (typeof RESOURCES)[number];

export const ACTIONS = [
  "view",
  "create",
  "edit_draft",
  "post",
  "approve",
  "export",
  "void",
  "delete_draft",
  "manage",
  // Phase 2 fine-grained actions
  "view_cost",
  "override_price",
  "sell_below_cost",
  "receive_payment",
  "create_return",
  "view_kardex",
  "opening_balance",
  "adjustment_create",
  "adjustment_post",
  "transfer_create",
  "transfer_dispatch",
  "transfer_receive",
  // Phase 3 fine-grained actions
  "record_payment",
  "view_balance",
  "view_ledger",
  // Phase 4 accounting actions
  "view_journals",
  "create_manual_journal",
  "post_manual_journal",
  "post_control_account_adjustment",
  "view_general_ledger",
  "view_trial_balance",
  "view_control_accounts",
  "manage_opening_balances",
  // Phase 4 report actions
  "view_profit_loss",
  "view_balance_sheet",
  "view_cash_flow",
  "view_vat",
  "view_receivables",
  "view_payables",
  "view_inventory_valuation",
  // Phase 4 reconciliation actions
  "import_statement",
  "match",
  "finalize",
  "reopen",
  // Phase 4 period actions
  "close",
  "lock",
  "unlock",
] as const;
export type Action = (typeof ACTIONS)[number];

export type PermissionCode = `${Resource}.${Action}`;

export interface PermissionDef {
  resource: Resource;
  action: Action;
  code: PermissionCode;
  description: string;
}

function p(resource: Resource, actions: Action[]): PermissionDef[] {
  return actions.map((action) => ({
    resource,
    action,
    code: `${resource}.${action}` as PermissionCode,
    description: `${action.replace(/_/g, " ")} ${resource.replace(/_/g, " ")}`,
  }));
}

const TXN_ACTIONS: Action[] = [
  "view",
  "create",
  "edit_draft",
  "post",
  "approve",
  "export",
  "void",
  "delete_draft",
];

/** The full set of permissions seeded into the database. */
export const PERMISSION_DEFS: PermissionDef[] = [
  ...p("dashboard", ["view"]),
  ...p("sales", [
    ...TXN_ACTIONS,
    "view_cost", "override_price", "sell_below_cost", "receive_payment", "create_return",
  ]),
  ...p("purchases", [...TXN_ACTIONS, "view_cost", "record_payment", "create_return"]),
  ...p("other_income", TXN_ACTIONS),
  ...p("expenses", TXN_ACTIONS),
  ...p("cash_transfers", TXN_ACTIONS),
  ...p("cash_accounts", ["view", "view_balance", "view_ledger", "opening_balance"]),
  ...p("inventory", [
    "view", "create", "edit_draft", "post", "export", "manage",
    "view_cost", "view_kardex", "opening_balance",
    "adjustment_create", "adjustment_post",
    "transfer_create", "transfer_dispatch", "transfer_receive",
  ]),
  ...p("kardex", ["view", "export"]),
  ...p("reports", [
    "view", "export",
    "view_profit_loss", "view_balance_sheet", "view_cash_flow", "view_vat",
    "view_receivables", "view_payables", "view_inventory_valuation",
  ]),
  ...p("accounting", [
    "view", "view_journals", "create_manual_journal", "post_manual_journal",
    "post_control_account_adjustment", "view_general_ledger", "view_trial_balance",
    "view_control_accounts", "manage_opening_balances", "export",
  ]),
  ...p("reconciliation", ["view", "create", "import_statement", "match", "finalize", "reopen"]),
  ...p("periods", ["view", "close", "reopen", "lock", "unlock"]),
  ...p("admin", ["view", "manage"]),
  ...p("users", ["view", "manage"]),
  ...p("roles", ["view", "manage"]),
  ...p("audit_log", ["view", "export"]),
  // Owner-only guarded actions. No "delete posted" permission exists.
  ...p("transactions", ["delete_draft", "void"]),
];

export const OWNER_ROLE = "OWNER";

export interface RoleDef {
  code: string;
  name: string;
  description: string;
  isSystem: boolean;
  isProtected: boolean;
  /** "*" grants every permission; otherwise an explicit list of codes. */
  permissions: "*" | PermissionCode[];
}

export const ROLE_DEFS: RoleDef[] = [
  {
    code: OWNER_ROLE,
    name: "Owner",
    description: "Full system access. Protected system role.",
    isSystem: true,
    isProtected: true,
    permissions: "*",
  },
  {
    code: "DIRECTOR",
    name: "Director",
    description: "Operational direction across modules.",
    isSystem: true,
    isProtected: false,
    permissions: [
      "dashboard.view",
      "sales.view", "sales.create", "sales.edit_draft", "sales.post", "sales.approve", "sales.export", "sales.void",
      "sales.view_cost", "sales.override_price", "sales.receive_payment", "sales.create_return",
      "purchases.view", "purchases.create", "purchases.edit_draft", "purchases.post", "purchases.approve", "purchases.export", "purchases.void",
      "purchases.view_cost", "purchases.record_payment", "purchases.create_return",
      "other_income.view", "other_income.create", "other_income.edit_draft", "other_income.post", "other_income.approve", "other_income.export",
      "expenses.view", "expenses.create", "expenses.edit_draft", "expenses.post", "expenses.approve", "expenses.export",
      "cash_transfers.view", "cash_transfers.create", "cash_transfers.edit_draft", "cash_transfers.post", "cash_transfers.approve", "cash_transfers.export",
      "cash_accounts.view", "cash_accounts.view_balance", "cash_accounts.view_ledger",
      "inventory.view", "inventory.create", "inventory.edit_draft", "inventory.post", "inventory.manage", "inventory.export",
      "inventory.view_cost", "inventory.view_kardex",
      "inventory.adjustment_create", "inventory.adjustment_post",
      "inventory.transfer_create", "inventory.transfer_dispatch", "inventory.transfer_receive",
      "kardex.view", "kardex.export",
      "reports.view", "reports.export",
      "reports.view_profit_loss", "reports.view_receivables", "reports.view_payables", "reports.view_inventory_valuation",
      "periods.view",
    ],
  },
  {
    code: "ACCOUNTANT",
    name: "Accountant",
    description: "Records and posts financial transactions.",
    isSystem: true,
    isProtected: false,
    permissions: [
      "dashboard.view",
      "sales.view", "sales.create", "sales.edit_draft", "sales.post", "sales.export",
      "sales.view_cost", "sales.receive_payment",
      "purchases.view", "purchases.create", "purchases.edit_draft", "purchases.post", "purchases.export",
      "purchases.view_cost", "purchases.record_payment", "purchases.create_return",
      "other_income.view", "other_income.create", "other_income.edit_draft", "other_income.post",
      "expenses.view", "expenses.create", "expenses.edit_draft", "expenses.post",
      "cash_transfers.view", "cash_transfers.create", "cash_transfers.edit_draft", "cash_transfers.post",
      "cash_accounts.view", "cash_accounts.view_balance", "cash_accounts.view_ledger",
      "inventory.view", "inventory.view_cost", "inventory.view_kardex",
      "kardex.view", "kardex.export",
      "reports.view", "reports.export",
      "reports.view_profit_loss", "reports.view_balance_sheet", "reports.view_cash_flow",
      "reports.view_vat", "reports.view_receivables", "reports.view_payables", "reports.view_inventory_valuation",
      "accounting.view", "accounting.view_journals", "accounting.create_manual_journal",
      "accounting.view_general_ledger", "accounting.view_trial_balance", "accounting.view_control_accounts", "accounting.export",
      "reconciliation.view", "reconciliation.create", "reconciliation.import_statement", "reconciliation.match", "reconciliation.finalize",
      "periods.view",
    ],
  },
  {
    code: "CASHIER",
    name: "Sales / Cashier",
    description: "Point-of-sale and receipts.",
    isSystem: true,
    isProtected: false,
    permissions: [
      "dashboard.view",
      "sales.view", "sales.create", "sales.edit_draft", "sales.post", "sales.receive_payment",
      "inventory.view", "inventory.view_kardex", "kardex.view",
    ],
  },
  {
    code: "STOREKEEPER",
    name: "Storekeeper",
    description: "Stock movements and inventory.",
    isSystem: true,
    isProtected: false,
    permissions: [
      "dashboard.view",
      "inventory.view", "inventory.create", "inventory.edit_draft", "inventory.post", "inventory.manage",
      "inventory.view_kardex", "inventory.adjustment_create",
      "inventory.transfer_create", "inventory.transfer_dispatch", "inventory.transfer_receive",
      "kardex.view", "kardex.export",
      "purchases.view", "purchases.create", "purchases.edit_draft", "purchases.post",
    ],
  },
  {
    code: "AUDITOR",
    name: "Viewer / Auditor",
    description: "Read-only access to operational data and reports.",
    isSystem: true,
    isProtected: false,
    permissions: [
      "dashboard.view",
      "sales.view", "sales.export",
      "purchases.view", "purchases.export",
      "other_income.view", "expenses.view",
      "cash_transfers.view",
      "cash_accounts.view", "cash_accounts.view_ledger",
      "inventory.view", "inventory.view_kardex", "kardex.view", "kardex.export",
      "reports.view", "reports.export",
      "reports.view_profit_loss", "reports.view_balance_sheet", "reports.view_cash_flow",
      "reports.view_vat", "reports.view_receivables", "reports.view_payables", "reports.view_inventory_valuation",
      "accounting.view", "accounting.view_journals", "accounting.view_general_ledger",
      "accounting.view_trial_balance", "accounting.view_control_accounts", "accounting.export",
      "reconciliation.view", "periods.view",
    ],
  },
];
