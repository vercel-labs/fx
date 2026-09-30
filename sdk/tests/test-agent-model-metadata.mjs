#!/usr/bin/env node
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, listModels } from "../node.js";
import { createFxAgent as createHostAgent } from "../fx-sdk.js";
import { createCatalogReader } from "../model-catalog.js";

const backend = process.argv[2] ?? "native";
const root = fileURLToPath(new URL("../..", import.meta.url));
const originalFetch = globalThis.fetch;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
let catalogReads = 0;
let expectedModel;
let expectedLimit;
let data = [];
let lastPayload;
let defaultModel;
const options = { backend, nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: resolve(root, "zig-out/bin/fx-core.wasm") } : {}),
  apiKey: "selected-metadata-fixture" };

const fixtureFetch = async (input, init = {}) => {
  assert.equal(new URL(String(input)).origin, "https://ai-gateway.vercel.sh");
  if (init.method === "GET") {
    catalogReads++;
    return Response.json({ object: "list", data });
  }
  assert.equal(init.method, "POST");
  assert.equal(new Headers(init.headers).get("ai-language-model-id"), expectedModel);
  lastPayload = JSON.parse(typeof init.body === "string" ? init.body : decoder.decode(init.body));
  assert.equal(lastPayload.maxOutputTokens, expectedLimit, "selected metadata was not applied");
  assert.doesNotMatch(JSON.stringify(lastPayload.prompt), /METADATA_ONLY_SENTINEL/);
  return new Response(encoder.encode(
    'data: {"type":"text-delta","delta":"ok"}\n\n' +
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n'
  ), { headers: { "content-type": "text/event-stream" } });
};
globalThis.fetch = fixtureFetch;

async function prompt(agent) {
  const turn = agent.prompt("say ok");
  let output = "";
  for await (const event of turn) if (event.type === "text_delta") output += event.delta;
  assert.equal(output, "ok");
  assert.equal((await turn.result).stopReason, "end_turn");
}

try {
  const probe = await createFxAgent({ ...options, onEvent(event) {
    if (event.type === "runtime.ready") defaultModel = event.model;
  } });
  await probe.close();
  assert.equal(typeof defaultModel, "string", "backend did not report its compiled default");
  assert.equal(catalogReads, 0, "creation must not eagerly discover models");

  data = Array.from({ length: 200 }, (_, index) => ({
    id: "catalog/model-" + String(index).padStart(3, "0"), type: "language",
    context_window: 128000, max_tokens: 1024 + index,
    tags: ["tool-use", "reasoning"], reasoning_options: [{ type: "effort", values: ["low", "high"] }],
    fast_options: [{ type: "toggle" }], description: "METADATA_ONLY_SENTINEL",
  }));
  data.push({ ...data[0], id: defaultModel, max_tokens: 4096 });
  const ids = await listModels({ apiKey: options.apiKey });
  assert.equal(ids.length, 201);
  assert.ok(ids.includes("catalog/model-199"));
  assert.ok(ids.includes(defaultModel));

  for (const selected of [data[0], data[100], data[199], data[200]]) {
    expectedModel = selected.id; expectedLimit = selected.max_tokens;
    const agent = await createFxAgent({ ...options,
      ...(selected.id === defaultModel ? {} : { model: selected.id }) });
    try {
      await prompt(agent);
      await prompt(agent);
      const checkpoint = await agent.checkpoint();
      const restored = await createFxAgent({ ...options, model: selected.id, checkpoint });
      try { await prompt(restored); } finally { await restored.close(); }
    } finally { await agent.close(); }
  }

  expectedModel = defaultModel; expectedLimit = 4096;
  const controlled = await createFxAgent({ ...options, effort: "high", fast: true });
  try {
    await prompt(controlled);
    assert.equal(lastPayload.reasoning, "high");
    assert.equal(lastPayload.providerOptions.gateway.speed, "fast");
  } finally { await controlled.close(); }

  expectedModel = "catalog/not-listed"; expectedLimit = undefined;
  const missing = await createFxAgent({ ...options, model: expectedModel });
  try { await prompt(missing); } finally { await missing.close(); }
  assert.equal(catalogReads, 1, "selection, default, controls and restoration must reuse complete discovery");
} finally { globalThis.fetch = originalFetch; }
{
  const tasks = [];
  const apiKey = "initialization-refresh-fixture";
  expectedModel = "catalog/refresh-controls";
  expectedLimit = 2048;
  data = [{ id: expectedModel, type: "language", context_window: 128000, max_tokens: 1024, tags: ["tool-use"] }];
  globalThis.fetch = fixtureFetch;
  try {
    const before = catalogReads;
    const seeded = createCatalogReader(globalThis.fetch, { shared: true, now: () => performance.now() - 6 * 60 * 1000 });
    await seeded.models("https://ai-gateway.vercel.sh/coding-agent/v1/models", {
      method: "GET", headers: { authorization: "Bearer " + apiKey },
    });
    seeded.release();
    data = [{ ...data[0], max_tokens: 2048, tags: ["tool-use", "reasoning"],
      reasoning_options: [{ type: "effort", values: ["high"] }] }];
    await assert.rejects(createFxAgent({ ...options, apiKey, model: expectedModel, effort: "high",
      onBackgroundTask: task => tasks.push(task) }), /reasoning/i);
    assert.equal(tasks.length, 1, "a stale capability rejection must schedule refresh without waiting for first text");
    await Promise.all(tasks);
    const recovered = await createFxAgent({ ...options, apiKey, model: expectedModel, effort: "high" });
    try { await prompt(recovered); } finally { await recovered.close(); }
    assert.equal(catalogReads - before, 2, "recovery must reuse the one refreshed snapshot");
  } finally { globalThis.fetch = originalFetch; }
}
{
  let handler, finish;
  let writes = 0;
  const runtime = {
    exited: new Promise(resolve => { finish = resolve; }),
    setLineHandler(value) { handler = value; },
    abortHostEffects() {}, closeStdin() { finish(0); },
    write(line) {
      const message = JSON.parse(line);
      if (message.method === "session/prompt") {
        writes++;
        if (writes === 1) throw new Error("injected write failure");
        assert.equal(message.params.modelMetadata?.model, "delivery/model", "failed write marked metadata delivered");
        queueMicrotask(() => {
          handler({ method: "session/update", params: { sessionId: "delivery", update: {
            sessionUpdate: "agent_message_chunk", content: { type: "text", text: "ok" },
          } } }, 128);
          handler({ id: message.id, result: { stopReason: "end_turn" } }, 128);
        });
      } else {
        queueMicrotask(() => handler({ id: message.id, result: message.method === "libfx/new" ? { sessionId: "delivery" } : {} }, 128));
      }
    },
  };
  const fetch = async () => Response.json({ data: [{ id: "delivery/model", type: "language", context_window: 128000 }] });
  const agent = await createHostAgent({ apiKey: "delivery-fixture", model: "delivery/model",
    cacheModels: true, fetch, runtimeFactory: async () => runtime });
  try {
    await listModels({ apiKey: "delivery-fixture", cacheModels: true, fetch });
    await assert.rejects(prompt(agent), /injected write failure/);
    await prompt(agent);
    assert.equal(writes, 2);
  } finally { await agent.close(); }
}

console.log(backend + " selected model metadata passed");
