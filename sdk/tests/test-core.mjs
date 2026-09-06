#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
let fetchCalls = 0;
let requestedSessionId;
let requestedAuthorization;
let requestedModel;
const mockFetch = async (url, init) => {
  if (init.method === "GET") {
    return Response.json({ object: "list", data: [{ id: "sdk/core-model", type: "language" }] });
  }
  fetchCalls += 1;
  const headers = new Headers(init.headers);
  requestedSessionId = headers.get("x-session-id");
  requestedAuthorization = headers.get("authorization");
  requestedModel = headers.get("ai-language-model-id");
  const payload = JSON.parse(new TextDecoder().decode(init.body));
  assert.ok(Array.isArray(payload.prompt) || Array.isArray(payload.messages));
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"hello"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":" world"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const agent = await createFxAgent({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  fetch: mockFetch,
  apiKey: "sdk-test-key",
  model: "sdk/core-model",
});
assert.deepEqual(Object.keys(agent).sort(), ["checkpoint", "close", "prompt"]);

const turn = agent.prompt([
  { type: "text", text: "say hello" },
  { type: "resource", resource: { uri: "memory://context", text: "embedded context" } },
]);
const chunks = [];
for await (const event of turn) {
  if (event.type === "text_delta") chunks.push(event.delta);
}
assert.equal(chunks.join(""), "hello world");
assert.deepEqual(await turn.result, {
  stopReason: "end_turn",
  usage: { inputTokens: 3, outputTokens: 2 },
});
assert.equal(fetchCalls, 1);
assert.ok(requestedSessionId);
assert.equal(requestedAuthorization, "Bearer sdk-test-key");
assert.equal(requestedModel, "sdk/core-model");
assert.ok((await agent.checkpoint()).length > 48);
assert.equal(await agent.close(), undefined);
console.log("core SDK passed: minimal prompt, stream, usage, checkpoint, and close");
