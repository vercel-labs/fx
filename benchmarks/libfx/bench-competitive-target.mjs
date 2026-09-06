#!/usr/bin/env node
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const target = value("--target", null);
const gatewayOrigin = value("--gateway-origin", null);
const piRoot = value("--pi-root", null);
const samples = Number(value("--samples", "100"));
const warmups = Number(value("--warmups", "3"));
if (!new Set(["libfx", "pi"]).has(target) || !gatewayOrigin) throw new Error("target and gateway origin are required");
if (target === "pi" && !piRoot) throw new Error("Pi npm prefix is required");
if (!Number.isInteger(samples) || samples < 1 || samples > 1000 || !Number.isInteger(warmups) || warmups < 0 || warmups > 100) {
  throw new Error("samples must be 1..1000 and warmups must be 0..100");
}

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const encoder = new TextEncoder();
const nativeFetch = globalThis.fetch.bind(globalThis);
const rows = [];
let active = null;
let requestCount = 0;
let catalogRequests = 0;
let cleanup = async () => {};
let runTurn;

function bodyBytes(body) {
  if (typeof body === "string") return encoder.encode(body).length;
  if (body instanceof ArrayBuffer) return body.byteLength;
  if (ArrayBuffer.isView(body)) return body.byteLength;
  return 0;
}

globalThis.fetch = async (input, init = {}) => {
  const isPrompt = String(init.method ?? input?.method ?? "GET").toUpperCase() === "POST";
  if (target === "libfx" && !isPrompt) {
    if ((init.method ?? "GET") !== "GET" || String(input) !== "https://ai-gateway.vercel.sh/coding-agent/v1/models") {
      throw new Error("unexpected non-prompt libfx benchmark request");
    }
    catalogRequests += 1;
    return Response.json({ object: "list", data: [{ id: "fake/model", type: "language", context_window: 1_000_000, max_tokens: 4096 }] });
  }
  if (isPrompt) {
    requestCount += 1;
    if (active) {
      active.fetch_at = performance.now();
      active.request_bytes = bodyBytes(init.body);
    }
  }
  const response = await nativeFetch(input, init);
  const sample = active;
  if (sample && isPrompt) {
    sample.headers_at = performance.now();
    sample.request_id = response.headers.get("x-fake-request-id");
  }
  if (!sample || !isPrompt || !response.body) return response;
  const reader = response.body.getReader();
  const body = new ReadableStream({
    async pull(controller) {
      const result = await reader.read();
      if (result.done) return controller.close();
      sample.first_body_at ??= performance.now();
      controller.enqueue(result.value);
    },
    cancel(reason) { return reader.cancel(reason); },
  });
  return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
};

const importAt = performance.now();
let importedAt;
let initializedAt;
if (target === "libfx") {
  const { createFxAgent } = await import(pathToFileURL(resolve(root, "sdk/node.js")));
  importedAt = performance.now();
  const agent = await createFxAgent({
    backend: "native",
    nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
    fetch: globalThis.fetch,
    apiKey: "competitive-benchmark-key",
    gatewayChatUrl: `${gatewayOrigin}/fx`,
    model: "fake/model",
    instructions: "Return the synthetic response exactly.",
  });
  initializedAt = performance.now();
  runTurn = async (row) => {
    active = row;
    const turn = agent.prompt(`synthetic ${row.index}`);
    for await (const event of turn) {
      if (event.type !== "text_delta") continue;
      row.first_text_at ??= performance.now();
      row.output += event.delta;
      row.event_count += 1;
    }
    const result = await turn.result;
    row.completed_at = performance.now();
    active = null;
    if (result.stopReason !== "end_turn") throw new Error(`unexpected libfx stop reason: ${result.stopReason}`);
  };
  cleanup = () => agent.close();
} else {
  process.env.OPENAI_API_KEY = "competitive-benchmark-key";
  const entry = pathToFileURL(resolve(piRoot, "node_modules/@earendil-works/pi-coding-agent/dist/index.js")).href;
  const { createAgentSession, DefaultResourceLoader, SessionManager } = await import(entry);
  importedAt = performance.now();
  const loader = new DefaultResourceLoader({
    cwd: root,
    agentDir: resolve(piRoot, "benchmark-agent"),
    systemPrompt: "Return the synthetic response exactly.",
    appendSystemPrompt: [],
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
  });
  await loader.reload();
  const model = {
    id: "fake/model",
    name: "Fake Model",
    api: "openai-completions",
    provider: "openai",
    baseUrl: `${gatewayOrigin}/v1`,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1_000_000,
    maxTokens: 4096,
  };
  const { session } = await createAgentSession({ model, resourceLoader: loader, noTools: "all", sessionManager: SessionManager.inMemory() });
  initializedAt = performance.now();
  let current = null;
  const unsubscribe = session.subscribe((event) => {
    if (!current || event.type !== "message_update" || event.assistantMessageEvent.type !== "text_delta") return;
    current.first_text_at ??= performance.now();
    current.output += event.assistantMessageEvent.delta;
    current.event_count += 1;
  });
  runTurn = async (row) => {
    active = row;
    current = row;
    await session.prompt(`synthetic ${row.index}`);
    row.completed_at = performance.now();
    current = null;
    active = null;
  };
  cleanup = async () => {
    unsubscribe();
    session.dispose();
  };
}

try {
  for (let index = -warmups; index < samples; index += 1) {
    const row = {
      index,
      prompt_at: performance.now(),
      fetch_at: null,
      headers_at: null,
      first_body_at: null,
      first_text_at: null,
      completed_at: null,
      request_bytes: null,
      request_id: null,
      output: "",
      event_count: 0,
    };
    const requestsBefore = requestCount;
    await runTurn(row);
    if (requestCount - requestsBefore !== 1) throw new Error(`${target} sample ${index} did not make exactly one inference request`);
    if (row.output !== "xxxxx" || row.event_count !== 1 || !row.request_id) {
      throw new Error(`${target} sample ${index} produced an invalid response`);
    }
    if (index >= 0) rows.push(row);
  }
  if (target === "libfx" && catalogRequests !== 1) throw new Error("libfx must reuse model metadata across benchmark prompts");
} finally {
  active = null;
  await cleanup();
  globalThis.fetch = nativeFetch;
}

process.stdout.write(`${JSON.stringify({
  format_version: 1,
  target,
  runtime: process.versions.bun ? "bun" : "node",
  runtime_version: process.versions.bun ?? process.version,
  warmups,
  samples,
  request_count: requestCount,
  catalog_fetches: catalogRequests,
  import_ms: importedAt - importAt,
  initialize_ms: initializedAt - importedAt,
  rows: rows.map((row) => ({
    prompt_to_first_text_ms: row.first_text_at - row.prompt_at,
    prompt_to_completion_ms: row.completed_at - row.prompt_at,
    prompt_to_fetch_ms: row.fetch_at - row.prompt_at,
    fetch_to_headers_ms: row.headers_at - row.fetch_at,
    first_body_to_first_text_ms: row.first_text_at - row.first_body_at,
    request_bytes: row.request_bytes,
    request_id: row.request_id,
  })),
}, null, 2)}\n`);
