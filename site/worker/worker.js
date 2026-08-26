// oh-my-fx — one Cloudflare Worker serving both the site and the gateway
// proxy (Workers Static Assets). One product, one URL, one deploy.
//
// Routing:
//   /v1/*, /v3/*  -> proxied to UPSTREAM_BASE with GATEWAY_KEY injected
//   everything    -> static assets from the "site" directory (env.ASSETS)
//                    or, locally, from the sibling ../site in the harness
//
// The Vercel AI Gateway key lives ONLY in the GATEWAY_KEY secret. The browser
// never sees it: the fx wasm in the page is pointed at this worker's origin,
// and every gateway call is forwarded with the key injected server-side.
//
// Bindings (wrangler):
//   GATEWAY_KEY    (secret)  the Vercel AI Gateway API key
//   SITE_ORIGIN    (var)     allowed site origin, comma separated, or "*"
//   UPSTREAM_BASE  (var)     default https://ai-gateway.vercel.sh
//   RATE_LIMIT     (var)     requests per IP per minute (default 20)

const DEFAULT_UPSTREAM = "https://ai-gateway.vercel.sh";

const CORS_HEADERS =
  "authorization, content-type, ai-gateway-auth-method, ai-gateway-protocol-version, ai-model-id, ai-language-model-id, ai-language-model-specification-version, ai-language-model-streaming, ai-reporting-tags, ai-reporting-user, http-referer, x-title, x-ai-gateway-api-key, x-api-key, x-session-id, x-session-affinity";

function isGatewayPath(pathname) {
  return pathname.startsWith("/v1") || pathname.startsWith("/v3");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (!isGatewayPath(url.pathname)) {
      return env.ASSETS ? env.ASSETS.fetch(request) : new Response("not found", { status: 404 });
    }

    const origin = request.headers.get("Origin");
    const siteOrigin = (env.SITE_ORIGIN || "*").split(",").map((s) => s.trim());
    const cors = (res) => {
      const h = new Headers(res.headers);
      if (siteOrigin.includes("*")) h.set("Access-Control-Allow-Origin", "*");
      else if (origin && siteOrigin.includes(origin)) {
        h.set("Access-Control-Allow-Origin", origin);
        h.set("Vary", "Origin");
      }
      h.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      h.set("Access-Control-Allow-Headers", CORS_HEADERS);
      h.set("Access-Control-Max-Age", "600");
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers: h });
    };

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    const key = env.GATEWAY_KEY;
    if (!key) return cors(Response.json({ error: "server_misconfigured" }, { status: 500 }));

    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const limit = Number(env.RATE_LIMIT || 20);
    const now = Date.now();
    const bucket = (globalThis.__fxRate ||= new Map()).get(ip) || [];
    const fresh = bucket.filter((t) => now - t < 60_000);
    if (fresh.length >= limit) {
      return cors(Response.json({ error: "rate_limited" }, { status: 429 }));
    }
    fresh.push(now);
    globalThis.__fxRate.set(ip, fresh);

    const base = (env.UPSTREAM_BASE || DEFAULT_UPSTREAM).replace(/\/+$/, "");
    const target = base + url.pathname + url.search;

    const headers = new Headers(request.headers);
    headers.delete("authorization");
    headers.delete("host");
    headers.set("authorization", `Bearer ${key}`);

    try {
      const init = { method: request.method, headers, redirect: "manual" };
      if (!["GET", "HEAD"].includes(request.method)) {
        init.body = request.body;
        init.duplex = "half";
      }
      const upstream = await fetch(target, init);
      return cors(upstream);
    } catch (err) {
      return cors(Response.json({ error: "upstream_error", message: String(err?.message || err) }, { status: 502 }));
    }
  },
};
