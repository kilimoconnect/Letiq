import { config } from "dotenv";
import { createClient } from "@supabase/supabase-js";
import { randomBytes } from "node:crypto";
import { createDbClient } from "./db";

config({ path: ".env.local" });
config();

const COMPANY_CODE = "LETIQ";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function findAuthUserByEmail(
  admin: any,
  email: string,
): Promise<{ id: string; email?: string } | null> {
  const target = email.toLowerCase();
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const found = data.users.find(
      (u: { email?: string }) => u.email?.toLowerCase() === target,
    );
    if (found) return found;
    if (data.users.length < 200) break;
  }
  return null;
}

async function main() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const ownerEmail = process.env.OWNER_EMAIL;
  if (!url || !serviceKey) throw new Error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.");
  if (!ownerEmail) throw new Error("OWNER_EMAIL is required.");

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  console.log(`Looking up auth user for ${ownerEmail}...`);
  let authUser = await findAuthUserByEmail(admin, ownerEmail);

  let generatedPassword: string | null = null;
  if (!authUser) {
    const password = process.env.OWNER_INITIAL_PASSWORD || randomBytes(12).toString("base64url");
    generatedPassword = process.env.OWNER_INITIAL_PASSWORD ? null : password;
    console.log("  Not found - creating the Owner auth user...");
    const { data, error } = await admin.auth.admin.createUser({
      email: ownerEmail,
      password,
      email_confirm: true,
    });
    if (error) throw error;
    authUser = data.user;
  } else {
    console.log("  Found existing auth user.");
    // If an initial password is provided, (re)set it so the Owner can sign in.
    if (process.env.OWNER_INITIAL_PASSWORD) {
      const { error } = await admin.auth.admin.updateUserById(authUser.id, {
        password: process.env.OWNER_INITIAL_PASSWORD,
        email_confirm: true,
      });
      if (error) throw error;
      console.log("  Owner password updated from OWNER_INITIAL_PASSWORD.");
    }
  }

  const ownerId = authUser!.id;

  const db = createDbClient();
  await db.connect();
  try {
    await db.query("begin");

    const company = await db.query<{ id: string }>(
      "select id from companies where code = $1",
      [COMPANY_CODE],
    );
    if (!company.rowCount) throw new Error("Company not seeded. Run `npm run db:seed` first.");
    const companyId = company.rows[0].id;

    const branch = await db.query<{ id: string }>(
      "select id from branches where company_id = $1 and code = 'HQ'",
      [companyId],
    );
    const branchId = branch.rows[0]?.id ?? null;

    const role = await db.query<{ id: string }>(
      "select id from roles where code = 'OWNER'",
    );
    if (!role.rowCount) throw new Error("OWNER role not seeded. Run `npm run db:seed` first.");
    const ownerRoleId = role.rows[0].id;

    await db.query(
      `insert into user_profiles
         (id, email, full_name, role_id, default_company_id, default_branch_id,
          is_active, is_primary_owner, created_by, updated_by)
       values ($1::uuid,$2::text,'Owner',$3::uuid,$4::uuid,$5::uuid,true,true,$1::uuid,$1::uuid)
       on conflict (id) do update
         set role_id = excluded.role_id, is_active = true, is_primary_owner = true,
             default_company_id = excluded.default_company_id,
             default_branch_id = excluded.default_branch_id, updated_by = excluded.id`,
      [ownerId, ownerEmail, ownerRoleId, companyId, branchId],
    );

    await db.query(
      `insert into user_company_access (user_id, company_id, created_by)
       values ($1::uuid,$2::uuid,$1::uuid) on conflict (user_id, company_id) do nothing`,
      [ownerId, companyId],
    );
    if (branchId) {
      await db.query(
        `insert into user_branch_access (user_id, branch_id, is_default, created_by)
         values ($1::uuid,$2::uuid,true,$1::uuid) on conflict (user_id, branch_id) do nothing`,
        [ownerId, branchId],
      );
    }

    await db.query(
      `insert into audit_logs (user_id, company_id, branch_id, action, resource_type, resource_id, new_values)
       values ($1::uuid,$2::uuid,$3::uuid,'owner.bootstrap','user_profiles',$1::text, jsonb_build_object('email',$4::text))`,
      [ownerId, companyId, branchId, ownerEmail],
    );

    await db.query("commit");
  } catch (err) {
    await db.query("rollback");
    throw err;
  } finally {
    await db.end();
  }

  console.log("\nOwner bootstrap complete.");
  console.log(`  Owner email : ${ownerEmail}`);
  if (generatedPassword) {
    console.log(`  Temp password (change after first sign-in): ${generatedPassword}`);
  } else {
    console.log("  Use the existing password / send a password reset from Supabase.");
  }
}

main().catch((err) => {
  console.error("\nOwner bootstrap failed:\n", err);
  process.exit(1);
});
