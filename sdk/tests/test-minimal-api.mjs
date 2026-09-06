#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
let requestedAuthorization;
let requestedModel;
const server = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "minimal/model", type: "language" }] }));
      return;
    }
    requestedAuthorization = request.headers.authorization;
    requestedModel = request.headers["ai-language-model-id"];
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end([
      'data: {"type":"reasoning-delta","delta":"think"}',
      'data: {"type":"text-delta","delta":"hello"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}',
      "data: [DONE]",
      "",
    ].join("\n\n"));
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

let agent;
try {
  agent = await createFxAgent({
    backend: "native",
    nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
    fetch,
    apiKey: "minimal-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "minimal/model",
  });
  assert.deepEqual(Object.keys(agent).sort(), ["checkpoint", "close", "prompt"]);
  const turn = agent.prompt("hello");
  let text = "";
  let reasoning = "";
  for await (const event of turn) {
    if (event.type === "text_delta") text += event.delta;
    if (event.type === "reasoning_delta") reasoning += event.delta;
  }
  assert.equal(text, "hello");
  assert.equal(reasoning, "think");
  assert.deepEqual(await turn.result, {
    stopReason: "end_turn",
    usage: { inputTokens: 1, outputTokens: 1 },
  });
  assert.equal(requestedAuthorization, "Bearer minimal-key");
  assert.equal(requestedModel, "minimal/model");
  const checkpoint = await agent.checkpoint();
  assert.ok(checkpoint instanceof Uint8Array);
  assert.equal(await agent.close(), undefined);
  assert.equal(await agent.close(), undefined);
  console.log("minimal libfx API passed");
} finally {
  await agent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
