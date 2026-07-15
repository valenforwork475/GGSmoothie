import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "server configuration missing" }, 500);

  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "authentication required" }, 401);
  const token = authHeader.slice(7);
  const authClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await authClient.auth.getUser(token);
  if (userError || !userData.user) return json({ error: "invalid session" }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: caller, error: callerError } = await admin
    .from("staff").select("uid,display_name,role,active,email")
    .eq("uid", userData.user.id).maybeSingle();
  if (callerError || !caller || !caller.active || !["manager", "owner"].includes(caller.role)) {
    return json({ error: "manager or owner access required" }, 403);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const action = String(body.action || "");

  if (action === "create") {
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    const displayName = String(body.display_name || "").trim();
    const role = String(body.role || "cashier");
    if (!/^\S+@\S+\.\S+$/.test(email)) return json({ error: "valid email required" }, 400);
    if (password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
    if (displayName.length < 2 || displayName.length > 80) return json({ error: "display name is required" }, 400);
    if (!["cashier", "manager", "owner"].includes(role)) return json({ error: "invalid role" }, 400);
    if (role === "owner" && caller.role !== "owner") return json({ error: "only an owner may create another owner" }, 403);

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { display_name: displayName },
    });
    if (createError || !created.user) return json({ error: createError?.message || "user creation failed" }, 400);

    const { error: staffError } = await admin.from("staff").insert({
      uid: created.user.id, email, display_name: displayName, role, active: true,
    });
    if (staffError) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: staffError.message }, 400);
    }
    await admin.from("audit_log").insert({
      actor_uid: caller.uid, action: "staff.create", entity_type: "staff", entity_id: created.user.id,
      detail: { email, display_name: displayName, role },
    });
    return json({ success: true, uid: created.user.id });
  }

  if (action === "update") {
    const uid = String(body.uid || "");
    const role = String(body.role || "");
    const active = body.active === true;
    const displayName = String(body.display_name || "").trim();
    if (!uid || !["cashier", "manager", "owner"].includes(role) || displayName.length < 2) {
      return json({ error: "invalid staff update" }, 400);
    }
    if (uid === caller.uid && !active) return json({ error: "you cannot deactivate your own account" }, 400);
    const { data: target } = await admin.from("staff").select("role").eq("uid", uid).maybeSingle();
    if (!target) return json({ error: "staff account not found" }, 404);
    if ((target.role === "owner" || role === "owner") && caller.role !== "owner") {
      return json({ error: "only an owner may change owner accounts" }, 403);
    }
    const { error } = await admin.from("staff").update({ role, active, display_name: displayName }).eq("uid", uid);
    if (error) return json({ error: error.message }, 400);
    await admin.from("audit_log").insert({
      actor_uid: caller.uid, action: "staff.update", entity_type: "staff", entity_id: uid,
      detail: { display_name: displayName, role, active },
    });
    return json({ success: true });
  }

  if (action === "reset_password") {
    const uid = String(body.uid || "");
    const password = String(body.password || "");
    if (!uid || password.length < 8) return json({ error: "password must be at least 8 characters" }, 400);
    const { data: target } = await admin.from("staff").select("role").eq("uid", uid).maybeSingle();
    if (!target) return json({ error: "staff account not found" }, 404);
    if (target.role === "owner" && caller.role !== "owner") return json({ error: "only an owner may reset an owner password" }, 403);
    const { error } = await admin.auth.admin.updateUserById(uid, { password });
    if (error) return json({ error: error.message }, 400);
    await admin.from("audit_log").insert({
      actor_uid: caller.uid, action: "staff.reset_password", entity_type: "staff", entity_id: uid, detail: {},
    });
    return json({ success: true });
  }

  return json({ error: "unknown action" }, 400);
});