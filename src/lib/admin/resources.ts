/**
 * Declarative registry for the generic Admin master-data CRUD engine.
 * Pure serializable data (no functions) so it is shared by server pages,
 * server actions and client components. Server actions look tables up by
 * `key` here - the browser never supplies a table name.
 */

export type FieldType =
  | "text"
  | "textarea"
  | "number"
  | "money"
  | "quantity"
  | "switch"
  | "select"
  | "date";

export interface FieldDef {
  name: string;
  label: string;
  type: FieldType;
  required?: boolean;
  placeholder?: string;
  help?: string;
  min?: number;
  max?: number;
  colSpan?: 1 | 2;
  /** Static enum options. */
  options?: { value: string; label: string }[];
  /** Dynamic option source key, resolved to active records at page load. */
  optionsKey?: OptionSourceKey;
  /** Optional selects store null when empty. */
  nullable?: boolean;
  defaultValue?: string | number | boolean;
}

export type ColumnType =
  | "text"
  | "code"
  | "money"
  | "number"
  | "boolean"
  | "date"
  | "ref";

export interface ColumnDef {
  key: string;
  label: string;
  type?: ColumnType;
  /** For type "ref": the option source used to resolve the id to a label. */
  refKey?: OptionSourceKey;
  align?: "left" | "right";
}

export type OptionSourceKey =
  | "accounts"
  | "postingAccounts"
  | "taxCodes"
  | "categories"
  | "brands"
  | "units"
  | "branches";

export interface OptionSource {
  table: string;
  /** Column used as the display label. */
  labelColumn: string;
  /** Optionally restrict (e.g. only accounts that allow posting). */
  where?: Record<string, string | boolean>;
}

export const OPTION_SOURCES: Record<OptionSourceKey, OptionSource> = {
  accounts: { table: "chart_of_accounts", labelColumn: "name" },
  postingAccounts: {
    table: "chart_of_accounts",
    labelColumn: "name",
    where: { allow_posting: true },
  },
  taxCodes: { table: "tax_codes", labelColumn: "name" },
  categories: { table: "product_categories", labelColumn: "name" },
  brands: { table: "brands", labelColumn: "name" },
  units: { table: "units", labelColumn: "name" },
  branches: { table: "branches", labelColumn: "name" },
};

export interface ResourceConfig {
  key: string;
  table: string;
  title: string;
  singular: string;
  description: string;
  auditType: string;
  /** Field used for duplicate messaging. */
  codeField: string;
  searchColumns: string[];
  columns: ColumnDef[];
  fields: FieldDef[];
  /** Larger records use a dedicated full-width form instead of a modal. */
  layout?: "modal" | "form";
}

const ENUM = {
  taxType: [
    { value: "standard", label: "Standard" },
    { value: "zero_rated", label: "Zero-rated" },
    { value: "exempt", label: "Exempt" },
    { value: "out_of_scope", label: "Out of scope" },
  ],
  appliesTo: [
    { value: "both", label: "Sales & Purchases" },
    { value: "sales", label: "Sales" },
    { value: "purchases", label: "Purchases" },
  ],
  paymentType: [
    { value: "cash", label: "Cash" },
    { value: "bank", label: "Bank" },
    { value: "mobile_money", label: "Mobile Money" },
    { value: "clearing", label: "Clearing Account" },
  ],
  accountType: [
    { value: "asset", label: "Asset" },
    { value: "liability", label: "Liability" },
    { value: "equity", label: "Equity" },
    { value: "revenue", label: "Revenue" },
    { value: "cost_of_sales", label: "Cost of Sales" },
    { value: "expense", label: "Expense" },
  ],
  normalBalance: [
    { value: "debit", label: "Debit" },
    { value: "credit", label: "Credit" },
  ],
  periodStatus: [
    { value: "open", label: "Open" },
    { value: "closed", label: "Closed" },
    { value: "locked", label: "Locked" },
  ],
  resetFrequency: [
    { value: "never", label: "Never" },
    { value: "yearly", label: "Yearly" },
    { value: "monthly", label: "Monthly" },
    { value: "daily", label: "Daily" },
  ],
  documentType: [
    { value: "sales_invoice", label: "Sales Invoice" },
    { value: "sales_receipt", label: "Sales Receipt" },
    { value: "sales_return", label: "Sales Return" },
    { value: "purchase", label: "Purchase" },
    { value: "purchase_return", label: "Purchase Return" },
    { value: "expense", label: "Expense" },
    { value: "other_income", label: "Other Income" },
    { value: "cash_transfer", label: "Cash Transfer" },
    { value: "stock_transfer", label: "Stock Transfer" },
    { value: "stock_adjustment", label: "Stock Adjustment" },
    { value: "journal_entry", label: "Journal Entry" },
  ],
};

const CODE_NAME_DESC = (singular: string): FieldDef[] => [
  { name: "code", label: "Code", type: "text", required: true, colSpan: 1, placeholder: `${singular} code` },
  { name: "name", label: "Name", type: "text", required: true, colSpan: 1 },
  { name: "description", label: "Description", type: "textarea", colSpan: 2 },
];

export const RESOURCES: Record<string, ResourceConfig> = {
  branches: {
    key: "branches",
    table: "branches",
    title: "Branches",
    singular: "Branch",
    description: "Physical locations for the company.",
    auditType: "branch",
    codeField: "code",
    searchColumns: ["code", "name", "email"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "phone", label: "Phone" },
      { key: "is_head_office", label: "Head Office", type: "boolean" },
    ],
    fields: [
      { name: "code", label: "Branch Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Branch Name", type: "text", required: true, colSpan: 1 },
      { name: "phone", label: "Phone", type: "text", colSpan: 1 },
      { name: "email", label: "Email", type: "text", colSpan: 1 },
      { name: "address", label: "Physical Address", type: "textarea", colSpan: 2 },
      { name: "is_head_office", label: "Head office", type: "switch", colSpan: 2, help: "Only one branch per company can be the head office." },
    ],
  },

  units: {
    key: "units",
    table: "units",
    title: "Units of Measurement",
    singular: "Unit",
    description: "Measurement units used by products.",
    auditType: "unit",
    codeField: "code",
    searchColumns: ["code", "name", "symbol"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "symbol", label: "Symbol" },
      { key: "allow_decimal", label: "Decimals", type: "boolean" },
    ],
    fields: [
      { name: "code", label: "Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Unit Name", type: "text", required: true, colSpan: 1 },
      { name: "symbol", label: "Symbol", type: "text", colSpan: 1 },
      { name: "allow_decimal", label: "Allow decimal quantities", type: "switch", colSpan: 2, defaultValue: true },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  "product-categories": {
    key: "product-categories",
    table: "product_categories",
    title: "Product Categories",
    singular: "Category",
    description: "Grouping for products.",
    auditType: "product_category",
    codeField: "code",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
    ],
    fields: CODE_NAME_DESC("Category"),
  },

  brands: {
    key: "brands",
    table: "brands",
    title: "Brands",
    singular: "Brand",
    description: "Product brands.",
    auditType: "brand",
    codeField: "code",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
    ],
    fields: CODE_NAME_DESC("Brand"),
  },

  "tax-codes": {
    key: "tax-codes",
    table: "tax_codes",
    title: "Tax Codes",
    singular: "Tax Code",
    description: "VAT and other tax configuration.",
    auditType: "tax_code",
    codeField: "code",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "tax_type", label: "Type" },
      { key: "rate", label: "Rate %", type: "number", align: "right" },
      { key: "applies_to", label: "Applies To" },
    ],
    fields: [
      { name: "code", label: "Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Name", type: "text", required: true, colSpan: 1 },
      { name: "tax_type", label: "Tax Type", type: "select", required: true, options: ENUM.taxType, colSpan: 1 },
      { name: "rate", label: "Tax Rate (%)", type: "number", required: true, min: 0, max: 100, colSpan: 1, defaultValue: 0 },
      { name: "applies_to", label: "Applies To", type: "select", required: true, options: ENUM.appliesTo, colSpan: 1 },
      { name: "is_inclusive", label: "Tax inclusive", type: "switch", colSpan: 1 },
      { name: "input_account_id", label: "Input-tax Account", type: "select", optionsKey: "accounts", nullable: true, colSpan: 1 },
      { name: "output_account_id", label: "Output-tax Account", type: "select", optionsKey: "accounts", nullable: true, colSpan: 1 },
      { name: "effective_start", label: "Effective Start", type: "date", required: true, colSpan: 1 },
      { name: "effective_end", label: "Effective End", type: "date", nullable: true, colSpan: 1 },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  "payment-accounts": {
    key: "payment-accounts",
    table: "payment_accounts",
    title: "Payment Accounts",
    singular: "Payment Account",
    description: "Cash, bank and mobile-money accounts.",
    auditType: "payment_account",
    codeField: "code",
    searchColumns: ["code", "name", "provider", "account_number"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "account_type", label: "Type" },
      { key: "provider", label: "Provider" },
    ],
    fields: [
      { name: "code", label: "Account Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Account Name", type: "text", required: true, colSpan: 1 },
      { name: "account_type", label: "Account Type", type: "select", required: true, options: ENUM.paymentType, colSpan: 1 },
      { name: "provider", label: "Institution / Provider", type: "text", colSpan: 1 },
      { name: "account_number", label: "Account Number", type: "text", nullable: true, colSpan: 1 },
      { name: "branch_id", label: "Branch", type: "select", optionsKey: "branches", nullable: true, colSpan: 1 },
      { name: "ledger_account_id", label: "Linked Ledger Account", type: "select", optionsKey: "postingAccounts", nullable: true, colSpan: 2 },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  products: {
    key: "products",
    table: "products",
    title: "Products",
    singular: "Product",
    description: "Goods and items catalogue.",
    auditType: "product",
    codeField: "sku",
    layout: "form",
    searchColumns: ["sku", "barcode", "name"],
    columns: [
      { key: "sku", label: "SKU", type: "code" },
      { key: "name", label: "Name" },
      { key: "category_id", label: "Category", type: "ref", refKey: "categories" },
      { key: "brand_id", label: "Brand", type: "ref", refKey: "brands" },
      { key: "selling_price", label: "Selling Price", type: "money", align: "right" },
      { key: "track_inventory", label: "Tracked", type: "boolean" },
    ],
    fields: [
      { name: "sku", label: "SKU / Product Code", type: "text", required: true, colSpan: 1 },
      { name: "barcode", label: "Barcode", type: "text", nullable: true, colSpan: 1 },
      { name: "name", label: "Product Name", type: "text", required: true, colSpan: 2 },
      { name: "category_id", label: "Category", type: "select", optionsKey: "categories", nullable: true, colSpan: 1 },
      { name: "brand_id", label: "Brand", type: "select", optionsKey: "brands", nullable: true, colSpan: 1 },
      { name: "base_unit_id", label: "Base Unit", type: "select", optionsKey: "units", nullable: true, colSpan: 1 },
      { name: "tax_code_id", label: "Tax Code", type: "select", optionsKey: "taxCodes", nullable: true, colSpan: 1 },
      { name: "purchase_price", label: "Default Purchase Price", type: "money", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "selling_price", label: "Default Selling Price", type: "money", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "reorder_level", label: "Reorder Level", type: "quantity", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "track_inventory", label: "Track inventory", type: "switch", colSpan: 1, defaultValue: true },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  customers: {
    key: "customers",
    table: "customers",
    title: "Customers",
    singular: "Customer",
    description: "People and organisations you sell to.",
    auditType: "customer",
    codeField: "code",
    searchColumns: ["code", "name", "phone", "email", "tin"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "phone", label: "Phone" },
      { key: "credit_allowed", label: "Credit", type: "boolean" },
      { key: "credit_limit", label: "Credit Limit", type: "money", align: "right" },
    ],
    fields: [
      { name: "code", label: "Customer Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Customer Name", type: "text", required: true, colSpan: 1 },
      { name: "customer_type", label: "Customer Type", type: "text", nullable: true, colSpan: 1 },
      { name: "phone", label: "Phone", type: "text", colSpan: 1 },
      { name: "email", label: "Email", type: "text", colSpan: 1 },
      { name: "tin", label: "TIN", type: "text", nullable: true, colSpan: 1 },
      { name: "vat_number", label: "VAT Registration No.", type: "text", nullable: true, colSpan: 1 },
      { name: "credit_allowed", label: "Credit allowed", type: "switch", colSpan: 1 },
      { name: "credit_limit", label: "Credit Limit", type: "money", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "address", label: "Address", type: "textarea", colSpan: 2 },
    ],
  },

  suppliers: {
    key: "suppliers",
    table: "suppliers",
    title: "Suppliers",
    singular: "Supplier",
    description: "Vendors you purchase from.",
    auditType: "supplier",
    codeField: "code",
    searchColumns: ["code", "name", "phone", "email", "tin"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "contact_person", label: "Contact" },
      { key: "phone", label: "Phone" },
      { key: "payment_terms_days", label: "Terms (days)", type: "number", align: "right" },
    ],
    fields: [
      { name: "code", label: "Supplier Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Supplier Name", type: "text", required: true, colSpan: 1 },
      { name: "contact_person", label: "Contact Person", type: "text", nullable: true, colSpan: 1 },
      { name: "phone", label: "Phone", type: "text", colSpan: 1 },
      { name: "email", label: "Email", type: "text", colSpan: 1 },
      { name: "tin", label: "TIN", type: "text", nullable: true, colSpan: 1 },
      { name: "vat_number", label: "VAT Registration No.", type: "text", nullable: true, colSpan: 1 },
      { name: "payment_terms_days", label: "Payment Terms (days)", type: "number", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "address", label: "Address", type: "textarea", colSpan: 2 },
    ],
  },

  "expense-categories": {
    key: "expense-categories",
    table: "expense_categories",
    title: "Expense Categories",
    singular: "Expense Category",
    description: "Categories used by expense transactions.",
    auditType: "expense_category",
    codeField: "code",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "expense_account_id", label: "Expense Account", type: "ref", refKey: "accounts" },
    ],
    fields: [
      { name: "code", label: "Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Name", type: "text", required: true, colSpan: 1 },
      { name: "expense_account_id", label: "Default Expense Account", type: "select", optionsKey: "postingAccounts", nullable: true, colSpan: 1 },
      { name: "default_tax_code_id", label: "Default Tax Code", type: "select", optionsKey: "taxCodes", nullable: true, colSpan: 1 },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  "other-income-types": {
    key: "other-income-types",
    table: "other_income_types",
    title: "Other Income Types",
    singular: "Income Type",
    description: "Categories used by other-income transactions.",
    auditType: "other_income_type",
    codeField: "code",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "income_account_id", label: "Income Account", type: "ref", refKey: "accounts" },
    ],
    fields: [
      { name: "code", label: "Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Name", type: "text", required: true, colSpan: 1 },
      { name: "income_account_id", label: "Default Income Account", type: "select", optionsKey: "postingAccounts", nullable: true, colSpan: 1 },
      { name: "default_tax_code_id", label: "Default Tax Code", type: "select", optionsKey: "taxCodes", nullable: true, colSpan: 1 },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  "chart-of-accounts": {
    key: "chart-of-accounts",
    table: "chart_of_accounts",
    title: "Chart of Accounts",
    singular: "Account",
    description: "Hierarchical general-ledger accounts.",
    auditType: "chart_of_account",
    codeField: "code",
    layout: "form",
    searchColumns: ["code", "name"],
    columns: [
      { key: "code", label: "Code", type: "code" },
      { key: "name", label: "Name" },
      { key: "account_type", label: "Type" },
      { key: "normal_balance", label: "Normal Balance" },
      { key: "allow_posting", label: "Posting", type: "boolean" },
    ],
    fields: [
      { name: "code", label: "Account Code", type: "text", required: true, colSpan: 1 },
      { name: "name", label: "Account Name", type: "text", required: true, colSpan: 1 },
      { name: "account_type", label: "Account Type", type: "select", required: true, options: ENUM.accountType, colSpan: 1 },
      { name: "normal_balance", label: "Normal Balance", type: "select", required: true, options: ENUM.normalBalance, colSpan: 1 },
      { name: "parent_id", label: "Parent Account", type: "select", optionsKey: "accounts", nullable: true, colSpan: 1 },
      { name: "allow_posting", label: "Allow direct posting", type: "switch", colSpan: 1, defaultValue: true, help: "Automatically disabled for accounts that have children." },
      { name: "description", label: "Description", type: "textarea", colSpan: 2 },
    ],
  },

  "document-numbering": {
    key: "document-numbering",
    table: "document_sequences",
    title: "Document Numbering",
    singular: "Sequence",
    description: "Number sequences for transaction documents.",
    auditType: "document_sequence",
    codeField: "document_type",
    searchColumns: ["document_type", "prefix"],
    columns: [
      { key: "document_type", label: "Document Type" },
      { key: "prefix", label: "Prefix", type: "code" },
      { key: "current_number", label: "Current No.", type: "number", align: "right" },
      { key: "number_length", label: "Length", type: "number", align: "right" },
      { key: "reset_frequency", label: "Reset" },
      { key: "branch_id", label: "Branch", type: "ref", refKey: "branches" },
    ],
    fields: [
      { name: "document_type", label: "Document Type", type: "select", required: true, options: ENUM.documentType, colSpan: 1 },
      { name: "branch_id", label: "Branch (optional)", type: "select", optionsKey: "branches", nullable: true, colSpan: 1 },
      { name: "prefix", label: "Prefix", type: "text", colSpan: 1 },
      { name: "number_length", label: "Number Length", type: "number", min: 1, max: 12, colSpan: 1, defaultValue: 5 },
      { name: "current_number", label: "Current Number", type: "number", min: 0, colSpan: 1, defaultValue: 0 },
      { name: "reset_frequency", label: "Reset Frequency", type: "select", required: true, options: ENUM.resetFrequency, colSpan: 1, defaultValue: "never" },
    ],
  },

  "accounting-periods": {
    key: "accounting-periods",
    table: "accounting_periods",
    title: "Accounting Periods",
    singular: "Period",
    description: "Financial-year periods and their status.",
    auditType: "accounting_period",
    codeField: "name",
    searchColumns: ["name", "financial_year"],
    columns: [
      { key: "name", label: "Period", type: "code" },
      { key: "financial_year", label: "Financial Year" },
      { key: "start_date", label: "Start", type: "date" },
      { key: "end_date", label: "End", type: "date" },
      { key: "status", label: "Status" },
    ],
    fields: [
      { name: "financial_year", label: "Financial Year", type: "text", required: true, colSpan: 1, placeholder: "e.g. 2026" },
      { name: "name", label: "Period Name", type: "text", required: true, colSpan: 1, placeholder: "e.g. FY 2026" },
      { name: "start_date", label: "Start Date", type: "date", required: true, colSpan: 1 },
      { name: "end_date", label: "End Date", type: "date", required: true, colSpan: 1 },
      { name: "status", label: "Status", type: "select", required: true, options: ENUM.periodStatus, colSpan: 1, defaultValue: "open" },
    ],
  },
};

export function getResource(key: string): ResourceConfig | undefined {
  return RESOURCES[key];
}

/** Resources that do NOT have an is_active column (status handled differently). */
export const NO_ACTIVE_TOGGLE = new Set<string>(["accounting-periods"]);

/**
 * Master-data resources whose code/SKU is auto-generated on create (prefix +
 * zero-padded sequence per company, e.g. "PRD-0001"). The user may still type
 * their own code; leaving it blank auto-generates one. The code is read-only
 * after creation. Document Numbering (an enum) and Accounting Periods (a named
 * period) are intentionally excluded.
 */
export const AUTO_CODE_PREFIXES: Record<string, string> = {
  branches: "BR",
  units: "UOM",
  "product-categories": "CAT",
  brands: "BRD",
  "tax-codes": "TAX",
  "payment-accounts": "PA",
  products: "PRD",
  customers: "CUST",
  suppliers: "SUP",
  "expense-categories": "EXC",
  "other-income-types": "OIT",
  "chart-of-accounts": "ACC",
};

export function autoCodePrefix(key: string): string | undefined {
  return AUTO_CODE_PREFIXES[key];
}
