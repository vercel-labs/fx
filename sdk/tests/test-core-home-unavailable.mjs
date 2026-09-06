#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/tests/test-core-home-unavailable.mjs");
  process.exit(2);
}

const encoded = new TextEncoder();
const catalogModels = [
  { id: "sdk/catalog-alpha", type: "language", released: 2, tags: ["tool-use"] },
];
let fetchCalls = 0;
let workspaceExecs = 0;
const mockFetch = async (url, init) => {
  if (init.method === "GET" && String(url).endsWith("/v1/models")) {
    return Response.json({ object: "list", data: catalogModels });
  }
  fetchCalls++;
  if (init.method !== "POST") throw new Error(`unexpected method ${init.method}`);
  const requestBody = JSON.parse(new TextDecoder().decode(init.body));
  if (!Array.isArray(requestBody.prompt) && !Array.isArray(requestBody.messages)) {
    throw new Error("gateway request did not contain prompt messages");
  }
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"hello"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":" world"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const timeout = (label, ms = 8000) => {
  let timer;
  const promise = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
  });
  return { promise, cancel() { clearTimeout(timer); } };
};

const initializeTimeout = timeout("fx-core initialize");
const agent = await Promise.race([
  createFxAgent({
    backend: "wasm",
    wasm: await readFile(wasmPath),
    fetch: mockFetch,
    apiKey: "sdk-test-key",
    workspace: {
      info: {
        version: 1,
        root: "/repo",
        cwd: "/repo",
        home: "/repo",
        gitAvailable: false,
        ephemeral: true,
      },
      permission: "allow-sandboxed",
      async exec() {
        workspaceExecs += 1;
        throw new Error("workspace.exec should not run during a text-only prompt");
      },
    },
  }),
  initializeTimeout.promise,
]).finally(() => initializeTimeout.cancel());

const turn = agent.prompt("say hello");
const chunks = [];
const notices = [];
for await (const update of turn) {
  if (update.type === "text_delta") chunks.push(update.delta);
}
const resultTimeout = timeout("prompt result");
const result = await Promise.race([turn.result, resultTimeout.promise]).finally(() => resultTimeout.cancel());
const streamedText = chunks.join("").trimEnd();
if (notices.some((notice) => notice.includes("home unavailable"))) {
  throw new Error(`home unavailable notice replaced the turn: ${JSON.stringify(notices)}`);
}
if (streamedText !== "hello world") throw new Error(`unexpected streamed text: ${JSON.stringify(chunks)}`);
if (result.stopReason !== "end_turn") throw new Error(`unexpected stop reason: ${result.stopReason}`);
if (fetchCalls !== 1) throw new Error(`expected one gateway fetch, got ${fetchCalls}`);
if (workspaceExecs !== 0) throw new Error(`workspace.exec ran ${workspaceExecs} time(s)`);

await agent.close();
console.log("core SDK HOME=/repo unavailable filesystem passed: prompt reached the model");
