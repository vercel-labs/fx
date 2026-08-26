// Local harness for worker/worker.js — mirrors production routing:
//   /v1/*, /v3/*  -> passed to the worker (gateway proxy)
//   everything    -> served statically from ../ (the site root)
// GATEWAY_KEY from worker/.dev.vars or the environment. Test stand-in for
// `wrangler dev` (same handler, minus Cloudflare bindings).
import http from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, extname, normalize, join } from "node:path";
import worker from "../worker/worker.js";

function loadEnv() {
  const env = { ...process.env };
  const devVars = fileURLToPath(new URL("../worker/.dev.vars", import.meta.url));
  if (existsSync(devVars)) {
    for (const line of readFileSync(devVars, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
      if (m && !(m[1] in env)) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
  return env;
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".sh": "text/x-shellscript",
  ".webp": "image/webp",
  ".json": "application/json",
  ".txt": "text/plain; charset=utf-8",
};

const env = loadEnv();
const port = Number(env.PORT || 8788);
const siteRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));

async function serveStatic(pathname) {
  let p = pathname === "/" ? "/index.html" : pathname;
  if (p.includes("..")) return new Response("forbidden", { status: 403 });
  const file = normalize(join(siteRoot, p));
  if (!file.startsWith(siteRoot)) return new Response("forbidden", { status: 403 });
  try {
    const data = await readFile(file);
    return new Response(data, {
      headers: { "Content-Type": MIME[extname(file)] || "application/octet-stream", "Cache-Control": "no-cache" },
    });
  } catch {
    return new Response("not found", { status: 404 });
  }
}

const server = http.createServer(async (req, res) => {
  const pathname = new URL(req.url, `http://127.0.0.1:${port}`).pathname;
  const isGateway = pathname.startsWith("/v1") || pathname.startsWith("/v3");

  let resp;
  if (isGateway) {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const r = new Request(`http://127.0.0.1:${port}${req.url}`, {
      method: req.method,
      headers: req.headers,
      body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
      duplex: body ? "half" : undefined,
    });
    resp = await worker.fetch(r, env);
  } else {
    resp = await serveStatic(pathname);
  }
  res.writeHead(resp.status, Object.fromEntries(resp.headers));
  res.end(Buffer.from(await resp.arrayBuffer()));
});

server.listen(port, () => {
  console.log(`oh-my-fx local stack on :${port}  (assets: ../, proxy → ${env.UPSTREAM_BASE || "https://ai-gateway.vercel.sh"})`);
});
