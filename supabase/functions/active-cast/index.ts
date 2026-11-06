// Owner facade. Database RPCs validate auth.uid and preserve RLS/owner boundaries.
const base = Deno.env.get("SUPABASE_URL") ?? "";
const key = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const origins = new Set((Deno.env.get("CAST_OWNER_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean));
Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  const headers: Record<string,string> = { "Content-Type": "application/json", "Cache-Control": "no-store", Vary: "Origin" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (origin && origins.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  if (origin && !origins.has(origin)) return reply({ error: "origin_not_allowed" }, 403);
  if (request.method === "OPTIONS") {
    headers["Access-Control-Allow-Headers"] = "Authorization, apikey, Content-Type, x-client-info";
    headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return reply({ error: "authentication_required" }, 401);
  if (!base || !key) return reply({ error: "service_not_configured" }, 503);
  try {
    // Auth validates the user token; never accept a decoded but unverified JWT.
    const user = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: authorization }, signal: AbortSignal.timeout(10000) });
    if (!user.ok) return reply({ error: "authentication_required" }, 401);
    const reader = request.body?.getReader();
    if (!reader) return reply({ error: "invalid_input" }, 400);
    let size = 0;
    const chunks: Uint8Array[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 131072) { await reader.cancel(); return reply({ error: "request_too_large" }, 413); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || typeof body.action !== "string") return reply({ error: "invalid_input" }, 400);
    const upstream = await fetch(`${base}/rest/v1/rpc/cast_control`, {
      method: "POST", headers: { apikey: key, Authorization: authorization, "Content-Type": "application/json" },
      body: JSON.stringify({ p_action: body.action, p_input: body.input ?? {} }), signal: AbortSignal.timeout(10000),
    });
    const result = await upstream.json();
    if (!upstream.ok) {
      const allowed = new Set(["idempotency_conflict", "preset_revision_conflict", "cast_unavailable", "incident_unavailable", "core_identity_immutable", "explicit_consent_required", "location_sharing_not_authorized", "record_location_not_authorized", "consent_exceeds_preset", "invalid_favorites", "custom_name_length", "start_rate_limit", "grant_limit", "cast_stopped"]);
      const code = allowed.has(result?.message) ? result.message : "invalid_request";
      return reply({ error: code }, code.includes("conflict") ? 409 : code.includes("rate_limit") ? 429 : 400);
    }
    return reply(result, result?.error === "revision_conflict" ? 409 : 200);
  } catch { return reply({ error: "request_failed_retry_same_id" }, 503); }
});
export {};
