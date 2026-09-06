#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const packageRoot = resolve(process.argv[2]);
const backend = process.argv[3] || "native";
const platform = `${process.platform}-${process.arch}`;
const { createFxAgent } = await import(pathToFileURL(resolve(packageRoot, "node.js")));
const { createMcpAdapter } = await import(pathToFileURL(resolve(packageRoot, "mcp.js")));
const { createSkillsAdapter } = await import(pathToFileURL(resolve(packageRoot, "skills.js")));
assert.equal(typeof createMcpAdapter, "function");
assert.equal(typeof createSkillsAdapter, "function");

let requestedAuthorization;
let requestedModel;
const server = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[]}');
      return;
    }
    requestedAuthorization = request.headers.authorization;
    requestedModel = request.headers["ai-language-model-id"];
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"text-delta","delta":"packed"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

const agent = await createFxAgent({
  backend,
  nativeAddon: resolve(packageRoot, `libfx.${platform}.node`),
  wasm: resolve(packageRoot, "fx-core.wasm"),
  fetch,
  apiKey: "packed-key",
  gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  model: "packed/model",
});
try {
  assert.deepEqual(Object.keys(agent).sort(), ["checkpoint", "close", "prompt"]);
  const turn = agent.prompt("hello");
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  assert.equal(text, "packed");
  assert.deepEqual(await turn.result, { stopReason: "end_turn", usage: { inputTokens: 1, outputTokens: 1 } });
  assert.equal(requestedAuthorization, "Bearer packed-key");
  assert.equal(requestedModel, "packed/model");
  assert.ok((await agent.checkpoint()).length > 48);
  await agent.close();
  console.log(`${backend} packed libfx example passed`);
} finally {
  await agent.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
