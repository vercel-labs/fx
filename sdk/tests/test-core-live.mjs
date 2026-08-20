#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);
const apiKey = process.env.AI_GATEWAY_API_KEY || process.env.FX_API_KEY;

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-core-live.mjs");
  process.exit(2);
}
if (!apiKey) {
  console.error("Set AI_GATEWAY_API_KEY or FX_API_KEY to run the live gateway smoke test");
  process.exit(2);
}

const nonce = `FXWASMLIVE${randomUUID().replaceAll("-", "").slice(0, 16).toUpperCase()}`;
const startedAt = performance.now();
let fetchCalls = 0;
let responseStatus = null;
let firstResponseBodyChunkAt = null;
let responseBodyChunks = 0;
let requestedSessionId = null;
let requestedSessionAffinity = null;
const responsePreviewChunks = [];
let responsePreviewBytes = 0;

const tracedFetch = async (url, init) => {
  if (init.method === "GET" && String(url).endsWith("/v1/models")) return fetch(url, init);
  fetchCalls++;
  const headers = new Headers(init.headers);
  requestedSessionId = headers.get("x-session-id");
  requestedSessionAffinity = headers.get("x-session-affinity");
  const response = await fetch(url, init);
  responseStatus = response.status;
  if (!response.body) return response;

  const reader = response.body.getReader();
  const body = new ReadableStream({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        controller.close();
        return;
      }
      if (firstResponseBodyChunkAt === null) firstResponseBodyChunkAt = performance.now();
      responseBodyChunks++;
      if (responsePreviewBytes < 4096) {
        const preview = value.subarray(0, 4096 - responsePreviewBytes);
        responsePreviewChunks.push(preview.slice());
        responsePreviewBytes += preview.length;
      }
      controller.enqueue(value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
};

const agent = await Promise.race([
  createFxAgent({ backend: "wasm", wasm: await readFile(wasmPath), fetch: tracedFetch, env: { AI_GATEWAY_API_KEY: apiKey } }),
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for fx-core initialize")), 5000)),
]);

try {
  const session = await agent.createSession();
  const prompt = [
    `Begin your response with the exact token ${nonce}.`,
    "Then write four short, distinct sentences explaining why incremental token streaming improves an interactive coding assistant.",
    "Do not use tools or Markdown.",
  ].join(" ");
  const turn = session.prompt(prompt);
  const chunks = [];
  let firstAcpChunkAt = null;
  const timeout = setTimeout(() => turn.cancel(), 45000);
  try {
    for await (const update of turn) {
      if (update.sessionUpdate !== "agent_message_chunk") continue;
      const text = update.content?.text;
      if (!text || text.startsWith("[context]")) continue;
      if (firstAcpChunkAt === null) firstAcpChunkAt = performance.now();
      chunks.push(text);
    }
  } finally {
    clearTimeout(timeout);
  }
  const stopReason = await turn.stopReason;
  const text = chunks.join("").trim();

  if (responseStatus !== 200) throw new Error(`live gateway returned HTTP ${responseStatus}`);
  if (fetchCalls !== 1) throw new Error(`expected one live gateway fetch, got ${fetchCalls}`);
  if (requestedSessionId !== session.id) throw new Error(`live gateway request used unexpected session id: ${requestedSessionId}`);
  if (requestedSessionAffinity !== session.id) throw new Error(`live gateway request used unexpected session affinity: ${requestedSessionAffinity}`);
  if (!text.includes(nonce)) {
    const responsePreview = new TextDecoder().decode(Buffer.concat(responsePreviewChunks.map((chunk) => Buffer.from(chunk))));
    throw new Error(`live model response did not include the per-run nonce; ACP text=${JSON.stringify(text.slice(0, 500))}; SSE preview=${JSON.stringify(responsePreview.slice(0, 1000))}`);
  }
  if (chunks.filter((chunk) => chunk.trim().length > 0).length < 2) {
    throw new Error(`live response was not delivered incrementally: ${chunks.length} ACP chunks`);
  }
  if (stopReason !== "end_turn") throw new Error(`unexpected stop reason: ${stopReason}`);

  const elapsedMs = Math.round(performance.now() - startedAt);
  const firstBodyMs = firstResponseBodyChunkAt === null ? "n/a" : Math.round(firstResponseBodyChunkAt - startedAt);
  const firstAcpMs = firstAcpChunkAt === null ? "n/a" : Math.round(firstAcpChunkAt - startedAt);
  console.log(`live core SDK ACP stream passed (${session.id})`);
  console.log(`gateway HTTP ${responseStatus}; body chunks=${responseBodyChunks}; ACP text chunks=${chunks.length}`);
  console.log(`first body chunk=${firstBodyMs}ms; first ACP chunk=${firstAcpMs}ms; total=${elapsedMs}ms`);
  console.log(`model echoed nonce ${nonce}; response bytes=${new TextEncoder().encode(text).length}`);
} finally {
  agent.abort();
}
