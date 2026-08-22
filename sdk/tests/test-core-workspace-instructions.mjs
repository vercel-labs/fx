#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/tests/test-core-workspace-instructions.mjs");
  process.exit(2);
}

const encoded = new TextEncoder();
const catalogModels = [
  { id: "sdk/catalog-alpha", type: "language", released: 2, tags: ["tool-use"] },
];
let fetchCalls = 0;
let workspaceExecs = 0;
let checkedInstructions = false;
const mockFetch = async (url, init) => {
  if (init.method === "GET" && String(url).endsWith("/v1/models")) {
    return Response.json({ object: "list", data: catalogModels });
  }
  fetchCalls++;
  if (init.method !== "POST") throw new Error(`unexpected method ${init.method}`);
  const requestBody = JSON.parse(new TextDecoder().decode(init.body));
  const messages = requestBody.prompt || requestBody.messages;
  if (!Array.isArray(messages)) throw new Error("gateway request did not contain prompt messages");
  const prompt = JSON.stringify(messages);
  const globalIndex = prompt.indexOf("CORE-GLOBAL-INSTRUCTION");
  const projectIndex = prompt.indexOf("CORE-PROJECT-INSTRUCTION");
  if (globalIndex < 0 || projectIndex < 0 || globalIndex >= projectIndex) {
    throw new Error(`workspace instructions were absent or out of precedence order: ${prompt}`);
  }
  for (const source of ["/home/visitor/.fx/AGENTS.md", "/workspace/AGENTS.md"]) {
    if (!prompt.includes(source)) throw new Error(`workspace instruction provenance omitted ${source}`);
  }
  checkedInstructions = true;
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"instructions loaded"}\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n"));
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
    env: { AI_GATEWAY_API_KEY: "sdk-test-key" },
    workspace: {
      info: {
        version: 1,
        root: "/workspace",
        cwd: "/workspace",
        home: "/home/visitor",
        gitAvailable: false,
        ephemeral: true,
      },
      permission: "allow-sandboxed",
      instructions: {
        version: 1,
        global: "CORE-GLOBAL-INSTRUCTION",
        project: "CORE-PROJECT-INSTRUCTION",
      },
      async exec() {
        workspaceExecs += 1;
        throw new Error("workspace.exec should not run during a text-only prompt");
      },
    },
  }),
  initializeTimeout.promise,
]).finally(() => initializeTimeout.cancel());

const session = await agent.createSession();
const turn = session.prompt("confirm workspace instructions");
const chunks = [];
for await (const update of turn) {
  if (update.sessionUpdate !== "agent_message_chunk") continue;
  if (!update.content.text.startsWith("[context]")) chunks.push(update.content.text);
}
const resultTimeout = timeout("prompt result");
const result = await Promise.race([turn.result, resultTimeout.promise]).finally(() => resultTimeout.cancel());
if (chunks.join("").trimEnd() !== "instructions loaded") {
  throw new Error(`unexpected streamed text: ${JSON.stringify(chunks)}`);
}
if (result.stopReason !== "end_turn") throw new Error(`unexpected stop reason: ${result.stopReason}`);
if (!checkedInstructions) throw new Error("workspace instructions were not checked");
if (fetchCalls !== 1) throw new Error(`expected one gateway fetch, got ${fetchCalls}`);
if (workspaceExecs !== 0) throw new Error(`workspace.exec ran ${workspaceExecs} time(s)`);

await agent.close();
console.log("core SDK workspace instructions passed: global and project rules reached the model with provenance and precedence");
