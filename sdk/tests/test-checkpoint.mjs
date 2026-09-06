#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const sourceBackend = process.argv[2] || "native";
const targetBackend = process.argv[3] || "wasm";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
let modelRequests = 0;

const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "checkpoint/model", type: "language" }] }));
      return;
    }
    modelRequests += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (modelRequests === 1) {
      response.end([
        'data: {"type":"text-delta","delta":"remembered value"}',
        'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":2},"outputTokens":{"total":2}}}',
        "data: [DONE]",
        "",
      ].join("\n\n"));
      return;
    }
    assert.ok(body.includes("store this context"), "restored request omitted the prior user turn");
    assert.ok(body.includes("remembered value"), "restored request omitted the prior assistant turn");
    response.end([
      'data: {"type":"text-delta","delta":"restored"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":4},"outputTokens":{"total":1}}}',
      "data: [DONE]",
      "",
    ].join("\n\n"));
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const options = (backend, checkpoint) => ({
  backend,
  nativeAddon: addon,
  ...(backend === "wasm" ? { wasm } : {}),
  ...(checkpoint ? { checkpoint } : {}),
  fetch,
  apiKey: "checkpoint-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "checkpoint/model",
});

let source;
let target;
try {
  source = await createFxAgent(options(sourceBackend));
  const first = source.prompt("store this context");
  for await (const _ of first) {}
  assert.equal((await first.result).stopReason, "end_turn");
  const checkpoint = await source.checkpoint();
  assert.ok(checkpoint instanceof Uint8Array && checkpoint.length > 48);
  assert.equal(await source.close(), undefined);
  source = null;

  target = await createFxAgent(options(targetBackend, checkpoint));
  const second = target.prompt("continue");
  let text = "";
  for await (const update of second) {
    if (update.type === "text_delta") text += update.delta;
  }
  assert.equal(text.trim(), "restored");
  assert.equal((await second.result).stopReason, "end_turn");
  assert.equal(await target.close(), undefined);
  target = null;
  assert.equal(modelRequests, 2);
  console.log(`checkpoint integration passed: ${sourceBackend} -> ${targetBackend}`);
} finally {
  await source?.close().catch(() => {});
  await target?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
