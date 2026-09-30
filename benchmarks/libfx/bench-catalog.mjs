#!/usr/bin/env node
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, listModels } from "../../sdk/node.js";
import { sampleStats } from "./workload.mjs";
import { createCatalogReader } from "../../sdk/model-catalog.js";

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  if (!args[index + 1] || args[index + 1].startsWith("--")) throw new Error(`missing value for ${name}`);
  return args[index + 1];
};
const backend = value("--backend", "native");
const samples = Number(value("--samples", "50"));
const sizes = value("--sizes", "200,10000").split(",").map(Number);
const enforce = args.includes("--check");
const warmups = 3;
if (!["native", "wasm"].includes(backend) || !Number.isInteger(samples) || samples < 1 || samples > 1000 ||
    !sizes.length || sizes.some(size => !Number.isInteger(size) || size < 3 || size > 10000)) {
  throw new Error("usage: bench-catalog.mjs --backend native|wasm --samples 1..1000 --sizes 3..10000[,size] [--check]");
}
const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const originalFetch = globalThis.fetch;
const failures = [];
const cohorts = [];
let active = null;
let fixture = null;
let catalogRequests = 0;
let generationRequests = 0;
let refreshGate = null;

globalThis.fetch = async (input, init = {}) => {
  const url = new URL(typeof input === "string" ? input : input.url);
  const headers = new Headers(init.headers);
  if (url.origin !== "https://ai-gateway.vercel.sh") throw new Error("benchmark attempted an unexpected origin");
  if ((init.method ?? "GET") === "GET" && url.pathname === "/coding-agent/v1/models") {
    catalogRequests++;
    if (refreshGate) await refreshGate.promise;
    return new Response(fixture.body, { headers: { "content-type": "application/json" } });
  }
  if (init.method !== "POST" || url.pathname !== "/v4/ai/language-model") throw new Error("unexpected benchmark request");
  generationRequests++;
  assert.equal(headers.get("ai-language-model-id"), active.model);
  const payload = JSON.parse(typeof init.body === "string" ? init.body : decoder.decode(init.body));
  assert.equal(payload.maxOutputTokens, active.outputLimit, "generation did not use the selected model's output limit");
  active.generation_at = performance.now();
  return new Response(encoder.encode(
    'data: {"type":"text-delta","delta":"ok"}\n\n' +
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n' +
    'data: [DONE]\n\n'
  ), { headers: { "content-type": "text/event-stream" } });
};

function onEvent(event) {
  if (!active) return;
  if (event.type === "acp.send") {
    const metadata = event.message.method === "initialize"
      ? event.message.params.clientCapabilities?.libfx?.initialModelMetadata
      : event.message.params.modelMetadata;
    if (metadata) active.catalog_observed_bytes = Math.max(active.catalog_observed_bytes, encoder.encode(JSON.stringify(metadata)).length);
  }
  if (event.type === "transport.start") active.transport_method = event.method;
  if (event.type === "transport.activity" && active.transport_method === "GET") {
    active.catalog_observed_bytes = Math.max(active.catalog_observed_bytes, event.totalBytes);
  }
}

function agentOptions(model, apiKey) {
  return { backend, nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
    ...(backend === "wasm" ? { wasm: resolve(root, "zig-out/bin/fx-core.wasm") } : {}),
    apiKey, model, instructions: "Reply with ok.", onEvent };
}

async function runPrompt(agent, row) {
  active = row;
  row.prompt_at = performance.now();
  let text = "";
  try {
    const turn = agent.prompt("say ok");
    for await (const event of turn) {
      if (event.type !== "text_delta") continue;
      row.first_text_at ??= performance.now();
      text += event.delta;
    }
    assert.equal(text, "ok");
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.ok(row.first_text_at !== undefined && row.generation_at !== undefined);
    row.prompt_to_first_text_ms = row.first_text_at - row.prompt_at;
    row.prompt_to_generation_ms = row.generation_at - row.prompt_at;
    return row;
  } finally { active = null; }
}

function summarize(rows) {
  return {
    prompt_to_first_text_ms: sampleStats(rows.map(row => row.prompt_to_first_text_ms)),
    prompt_to_generation_ms: sampleStats(rows.map(row => row.prompt_to_generation_ms)),
    ...(rows[0].create_to_first_text_ms === undefined ? {} : {
      create_to_first_text_ms: sampleStats(rows.map(row => row.create_to_first_text_ms)),
      creation_ms: sampleStats(rows.map(row => row.creation_ms)),
    }),
    catalog_observed_bytes: sampleStats(rows.map(row => row.catalog_observed_bytes)),
  };
}

try {
  for (const size of sizes) {
    const data = Array.from({ length: size }, (_, index) => ({
      id: `catalog/model-${String(index).padStart(5, "0")}`, type: "language",
      released: index, context_window: 128000, max_tokens: 1024 + index,
      tags: index % 2 ? ["tool-use", "reasoning", "vision"] : ["tool-use", "reasoning"],
      reasoning_options: [{ type: "effort", values: ["low", "high"] }],
      pricing: { input: "0.000001", output: "0.000003" },
    }));
    fixture = { size, body: JSON.stringify({ object: "list", data }) };
    const apiKey = `catalog-benchmark-${size}`;
    const beforeCatalog = catalogRequests;
    const beforeGeneration = generationRequests;
    const discoveryAt = performance.now();
    const models = await listModels({ apiKey });
    const discoveryMs = performance.now() - discoveryAt;
    assert.equal(models.length, size, "discovery omitted models");
    assert.equal(models[0], data[0].id);
    assert.equal(models[Math.floor(size / 2)], data[Math.floor(size / 2)].id);
    assert.equal(models.at(-1), data.at(-1).id);

    const fresh = [];
    const selected = [0, Math.floor(size / 2), size - 1];
    for (let index = -warmups; index < samples; index++) {
      const modelIndex = selected[(index + warmups) % selected.length];
      const model = data[modelIndex];
      const row = { index, model: model.id, outputLimit: model.max_tokens, catalog_observed_bytes: 0 };
      const start = performance.now();
      active = row;
      const agent = await createFxAgent(agentOptions(model.id, apiKey));
      active = null;
      row.creation_ms = performance.now() - start;
      try {
        await runPrompt(agent, row);
        row.create_to_first_text_ms = row.first_text_at - start;
        if (index >= 0) fresh.push(row);
      } finally { await agent.close(); }
    }

    const reused = [];
    const agent = await createFxAgent(agentOptions(data[0].id, apiKey));
    try {
      for (let index = -warmups; index < samples; index++) {
        const row = { index, model: data[0].id, outputLimit: data[0].max_tokens, catalog_observed_bytes: 0 };
        await runPrompt(agent, row);
        if (index >= 0) reused.push(row);
      }
    } finally { await agent.close(); }

    const reads = catalogRequests - beforeCatalog;
    const posts = generationRequests - beforeGeneration;
    if (reads !== 1) failures.push(`${size} models: discovery and fresh Agents made ${reads} catalog requests; expected one`);
    if (posts !== 2 * (samples + warmups)) failures.push(`${size} models: unexpected generation request count ${posts}`);
    const observed = Math.max(...fresh.map(row => row.catalog_observed_bytes));
    if (observed > 4096) failures.push(`${size} models: Agent received at least ${observed} catalog bytes; expected selected metadata within 4096 bytes`);
    cohorts.push({ catalog_entries: size, catalog_bytes: encoder.encode(fixture.body).length,
      discovered_models: models.length, discovery_ms: discoveryMs, catalog_requests: reads, generation_requests: posts,
      fresh: { ...summarize(fresh), samples: fresh },
      reused: { ...summarize(reused), samples: reused } });
    globalThis.gc?.();
  }

  if (samples >= 30 && cohorts.length > 1) {
    const smallest = cohorts.reduce((a, b) => a.catalog_entries < b.catalog_entries ? a : b);
    const largest = cohorts.reduce((a, b) => a.catalog_entries > b.catalog_entries ? a : b);
    if (largest.fresh.create_to_first_text_ms.p95 > smallest.fresh.create_to_first_text_ms.p95 + 5) {
      failures.push("warm create-to-first-text p95 grew by more than 5ms with catalog size");
    }
  }
  const staleKey = "catalog-benchmark-stale";
  const seeded = createCatalogReader(globalThis.fetch, { shared: true, now: () => performance.now() - 10 * 60 * 1000 });
  await seeded.models("https://ai-gateway.vercel.sh/coding-agent/v1/models", {
    method: "GET", headers: { authorization: "Bearer " + staleKey },
  });
  seeded.release();
  let releaseRefresh;
  refreshGate = { promise: new Promise(resolve => { releaseRefresh = resolve; }) };
  const backgroundTasks = [];
  const staleModel = JSON.parse(fixture.body).data.at(-1);
  const staleRow = { model: staleModel.id, outputLimit: staleModel.max_tokens, catalog_observed_bytes: 0 };
  const staleAgent = await createFxAgent({ ...agentOptions(staleModel.id, staleKey),
    onBackgroundTask: task => backgroundTasks.push(task) });
  try {
    await runPrompt(staleAgent, staleRow);
    assert.equal(backgroundTasks.length, 1, "stale lookup did not schedule one refresh after first text");
    await staleAgent.close();
  } finally {
    releaseRefresh();
    await Promise.all(backgroundTasks);
    await staleAgent.close();
    refreshGate = null;
  }
  const beforeKnown = catalogRequests;
  const known = await createFxAgent(agentOptions("google/gemini-2.5-flash", "catalog-benchmark-known"));
  try {
    await runPrompt(known, { model: "google/gemini-2.5-flash", outputLimit: undefined, catalog_observed_bytes: 0 });
  } finally { await known.close(); }
  if (catalogRequests !== beforeKnown) failures.push("known text model fetched a catalog without needing discovery");

  process.stdout.write(JSON.stringify({
    format_version: 1, runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version, backend, samples, warmups,
    timing_scope: "synthetic immediate transport; library latency, not deployed or live-model TTFT",
    transfer_scope: "largest selected metadata envelope or observed catalog transport body; HTTP activity can throttle and is a lower bound",
    stale_refresh_did_not_block_first_text: true,
    cohorts, failures,
  }, null, 2) + "\n");
  if (enforce && failures.length) {
    for (const failure of failures) process.stderr.write(`catalog benchmark failed: ${failure}\n`);
    process.exitCode = 1;
  }
} finally { globalThis.fetch = originalFetch; }
