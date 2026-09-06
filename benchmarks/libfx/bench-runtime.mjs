#!/usr/bin/env node
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../sdk/node.js";
import { sampleStats as stats } from "./workload.mjs";

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const backend = value("--backend", "native");
const warmSamples = Number(value("--warm-samples", "100"));
const streamSamples = Number(value("--stream-samples", "30"));
if (!new Set(["native", "wasm"]).has(backend) ||
  !Number.isInteger(warmSamples) || warmSamples < 1 || warmSamples > 1000 ||
  !Number.isInteger(streamSamples) || streamSamples < 1 || streamSamples > 100) {
  throw new Error("usage: bench-runtime.mjs --backend native|wasm --warm-samples 1..1000 --stream-samples 1..100");
}

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const server = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "runtime/model", type: "language" }] }));
      return;
    }
    const url = new URL(request.url, "http://localhost");
    const chunks = Number(url.searchParams.get("chunks") ?? 1);
    const bytes = Number(url.searchParams.get("bytes") ?? 5);
    const delta = url.pathname === "/warm" ? "hello" : "x".repeat(bytes);
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (let index = 0; index < chunks; index += 1) {
      response.write(`data: ${JSON.stringify({ type: "text-delta", id: String(index), delta })}\n\n`);
    }
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const origin = `http://127.0.0.1:${server.address().port}`;
const nativeFetch = globalThis.fetch.bind(globalThis);
let active = null;
let nonPromptFetches = 0;

function bodyBytes(body) {
  if (typeof body === "string") return new TextEncoder().encode(body).length;
  if (body instanceof ArrayBuffer) return body.byteLength;
  if (ArrayBuffer.isView(body)) return body.byteLength;
  return 0;
}

const tracedFetch = async (input, init = {}) => {
  if ((init.method ?? "GET") === "GET") {
    nonPromptFetches += 1;
    return nativeFetch(`${origin}/models`, init);
  }
  const sample = active;
  if (sample) {
    sample.fetch_at = performance.now();
    sample.request_bytes = bodyBytes(init.body);
  }
  const response = await nativeFetch(input, init);
  if (sample) sample.headers_at = performance.now();
  if (!response.body) return response;
  const reader = response.body.getReader();
  const body = new ReadableStream({
    async pull(controller) {
      const result = await reader.read();
      if (result.done) return controller.close();
      if (sample) sample.first_body_at ??= performance.now();
      controller.enqueue(result.value);
    },
    cancel(reason) { return reader.cancel(reason); },
  });
  return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers });
};

const agentOptions = (gatewayChatUrl) => ({
  backend,
  nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
  wasm: resolve(root, "zig-out/bin/fx-core.wasm"),
  fetch: tracedFetch,
  apiKey: "runtime-benchmark-key",
  gatewayChatUrl,
  model: "runtime/model",
  instructions: "Reply with hello.",
});

function summarize(rows) {
  return Object.fromEntries(Object.entries({
    prompt_to_fetch_ms: rows.map((row) => row.fetch_at - row.prompt_at),
    first_body_to_first_text_ms: rows.map((row) => row.first_text_at - row.first_body_at),
    prompt_to_first_text_ms: rows.map((row) => row.first_text_at - row.prompt_at),
    prompt_to_completion_ms: rows.map((row) => row.completed_at - row.prompt_at),
    request_bytes: rows.map((row) => row.request_bytes),
  }).map(([name, samples]) => [name, stats(samples)]));
}

async function runWarmPrompt(agent, index) {
  const row = {
    index,
    prompt_at: performance.now(),
    fetch_at: null,
    headers_at: null,
    first_body_at: null,
    first_text_at: null,
    completed_at: null,
    request_bytes: null,
    text: "",
  };
  active = row;
  try {
    const turn = agent.prompt(`hello ${index}`);
    for await (const event of turn) {
      if (event.type !== "text_delta") continue;
      row.first_text_at ??= performance.now();
      row.text += event.delta;
    }
    const result = await turn.result;
    row.completed_at = performance.now();
    if (row.text !== "hello" || result.stopReason !== "end_turn") throw new Error("unexpected warm prompt result");
    return row;
  } finally {
    active = null;
  }
}

async function runStreamCase(chunks, bytes) {
  const rows = [];
  for (let sample = -1; sample < streamSamples; sample += 1) {
    const agent = await createFxAgent(agentOptions(`${origin}/stream?chunks=${chunks}&bytes=${bytes}`));
    try {
      const promptAt = performance.now();
      const turn = agent.prompt("stream");
      let firstTextAt = null;
      let eventCount = 0;
      let outputBytes = 0;
      for await (const event of turn) {
        if (event.type !== "text_delta") continue;
        firstTextAt ??= performance.now();
        eventCount += 1;
        outputBytes += event.delta.length;
      }
      const result = await turn.result;
      const completedAt = performance.now();
      if (result.stopReason !== "end_turn" || eventCount !== chunks || outputBytes !== chunks * bytes) {
        throw new Error(`unexpected stream result: ${eventCount} events and ${outputBytes} bytes`);
      }
      if (sample >= 0) rows.push({ first_text_ms: firstTextAt - promptAt, completion_ms: completedAt - promptAt });
    } finally {
      await agent.close();
    }
  }
  return {
    chunks,
    bytes,
    total_bytes: chunks * bytes,
    samples: streamSamples,
    rows,
    first_text_ms: stats(rows.map((row) => row.first_text_ms)),
    completion_ms: stats(rows.map((row) => row.completion_ms)),
  };
}

let warmAgent;
try {
  warmAgent = await createFxAgent(agentOptions(`${origin}/warm`));
  const firstPrompt = await runWarmPrompt(warmAgent, -4);
  for (let index = -3; index < 0; index += 1) await runWarmPrompt(warmAgent, index);
  const warmRows = [];
  for (let index = 0; index < warmSamples; index += 1) warmRows.push(await runWarmPrompt(warmAgent, index));
  await warmAgent.close();
  warmAgent = null;

  process.stdout.write(`${JSON.stringify({
    format_version: 1,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    backend,
    warmups: 3,
    first_prompt: {
      text: firstPrompt.text,
      prompt_to_fetch_ms: firstPrompt.fetch_at - firstPrompt.prompt_at,
      first_body_to_first_text_ms: firstPrompt.first_text_at - firstPrompt.first_body_at,
      prompt_to_first_text_ms: firstPrompt.first_text_at - firstPrompt.prompt_at,
      prompt_to_completion_ms: firstPrompt.completed_at - firstPrompt.prompt_at,
      request_bytes: firstPrompt.request_bytes,
    },
    warm: summarize(warmRows),
    warm_samples: warmRows,
    streams: [
      await runStreamCase(1, 1),
      await runStreamCase(1000, 1),
      await runStreamCase(16, 65_536),
    ],
    non_prompt_fetches: nonPromptFetches,
  }, null, 2)}\n`);
} finally {
  await warmAgent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
