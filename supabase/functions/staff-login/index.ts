import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
});
const codePattern = /^[A-Z0-9][A-Z0-9_-]{2,19}$/;
const internalEmail = (code: string) => `pos+${code.toLowerCase()}@gg-smoothie.vercel.app`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "server configuration missing" }, 500);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "invalid request" }, 400); }
  const rawIdentifier = String(body.identifier || "").trim();
  const password = String(body.password || "");
  const surface = body.surface === "backoffice" ? "backoffice" : "pos";
  const code = rawIdentifier.toUpperCase();
  const isCode = codePattern.test(code);
  const loginEmail = isCode ? internalEmail(code) : rawIdentifier.toLowerCase();
  const eventIdentifier = isCode ? code : loginEmail;
  if ((!isCode && !/^\S+@\S+\.\S+$/.test(loginEmail)) || !password) {
    return json({ error: "รหัสพนักงาน อีเมล หรือรหัสผ่านไม่ถูกต้อง" }, 400);
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const since = new Date(Date.now() - 15 * 60_000).toISOString();
  const { data: recent } = await admin.from("staff_login_events")
    .select("success").eq("identifier", eventIdentifier).gte("created_at", since)
    .order("created_at", { ascending: false }).limit(10);
  let consecutiveFailures = 0;
  for (const event of recent || []) { if (event.success) break; consecutiveFailures++; }
  if (consecutiveFailures >= 5) return json({ error: "บัญชีถูกพักการเข้าสู่ระบบ 15 นาที กรุณาติดต่อผู้ดูแล" }, 429);

  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: signedIn, error: signInError } = await auth.auth.signInWithPassword({ email: loginEmail, password });
  const userAgent = (req.headers.get("user-agent") || "").slice(0, 300) || null;
  if (signInError || !signedIn.session || !signedIn.user) {
    await admin.from("staff_login_events").insert({ identifier: eventIdentifier, surface, success: false, user_agent: userAgent });
    return json({ error: "รหัสพนักงาน อีเมล หรือรหัสผ่านไม่ถูกต้อง" }, 401);
  }

  const { data: staff } = await admin.from("staff")
    .select("uid,display_name,role,active,staff_code,email").eq("uid", signedIn.user.id).maybeSingle();
  const surfaceAllowed = surface === "pos" || ["manager", "owner"].includes(staff?.role || "");
  if (!staff?.active || !surfaceAllowed) {
    await admin.from("staff_login_events").insert({ uid: signedIn.user.id, identifier: eventIdentifier, surface, success: false, user_agent: userAgent });
    return json({ error: surface === "backoffice" ? "บัญชีนี้ไม่มีสิทธิ์เข้า Back Office" : "บัญชีถูกระงับ" }, 403);
  }

  await admin.from("staff_login_events").insert({ uid: signedIn.user.id, identifier: eventIdentifier, surface, success: true, user_agent: userAgent });
  return json({
    access_token: signedIn.session.access_token,
    expires_at: signedIn.session.expires_at,
    user: { id: signedIn.user.id },
    staff,
  });
});
