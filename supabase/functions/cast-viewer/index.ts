// Bearer links use a POST body, never a URL/query string. No request logging.
const origins = new Set((Deno.env.get("CAST_VIEWER_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean));
const base = Deno.env.get("SUPABASE_URL") ?? "";
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  const headers: Record<string, string> = {
    "Content-Type": "application/json", "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "Vary": "Origin",
  };
  if (origin && origins.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  const reply = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers });
  if (origin && !origins.has(origin)) return reply({ error: "origin_not_allowed" }, 403);
  if (new URL(request.url).search) return reply({ error: "query_parameters_not_allowed" }, 400);
  if (request.method === "OPTIONS") {
    headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    headers["Access-Control-Allow-Headers"] = "Content-Type";
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
  if (!base || !key) return reply({ error: "service_not_configured" }, 503);
  try {
    if (!request.headers.get("content-type")?.startsWith("application/json")) return reply({ error: "json_required" }, 415);
    // Check streamed length too: Content-Length is optional and untrusted.
    const reader = request.body?.getReader();
    if (!reader) return reply({ error: "invalid_input" }, 400);
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) { await reader.cancel(); return reply({ error: "request_too_large" }, 413); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || typeof body !== "object" || typeof body.token !== "string" || !/^[a-f0-9]{64}$/.test(body.token) || !["heartbeat", "location", "message"].includes(body.action)) return reply({ error: "invalid_input" }, 400);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.token));
    const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
    const upstream = await fetch(`${base}/rest/v1/rpc/cast_viewer`, {
      method: "POST", headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_token_hash: hash, p_action: body.action, p_input: body.input ?? {} }),
      signal: AbortSignal.timeout(10000),
    });
    if (!upstream.ok) {
      const error = await upstream.json();
      const code = error?.message;
      if (["access_denied", "scope_denied"].includes(code)) return reply({ error: "access_denied" }, 403);
      if (code === "message_rate_limit") return reply({ error: code }, 429);
      if (code === "idempotency_conflict") return reply({ error: code }, 409);
      return reply({ error: "invalid_request" }, 400);
    }
    return reply(await upstream.json());
  } catch (error) {
    return reply({ error: error instanceof SyntaxError ? "invalid_json" : "request_failed_retry_same_id" }, error instanceof SyntaxError ? 400 : 503);
  }
});
export {};
