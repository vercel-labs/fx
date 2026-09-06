#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasmPath = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const encoded = new TextEncoder();
let modelRequests = 0;
let toolCalls = 0;
const sdkEvents = [];

const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "host/tool-model", type: "language", tags: ["tool-use"] }] }));
      return;
    }
    modelRequests += 1;
    const payload = JSON.parse(body);
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (modelRequests === 1) {
      const lookup = payload.tools?.find((tool) => tool.name === "lookup");
      assert.ok(lookup, `host tool was not advertised to the model: ${JSON.stringify(payload.tools)}`);
      assert.equal(lookup.inputSchema.properties.key.type, "string");
      response.end([
        'data: {"type":"tool-call","toolCallId":"call_1","toolName":"lookup","input":{"key":"alpha"}}',
        'data: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}',
        "data: [DONE]",
        "",
      ].join("\n\n"));
      return;
    }
    assert.equal(modelRequests, 2);
    assert.ok(body.includes("value:alpha"), `host tool result did not reach the next model step: ${body}`);
    response.end([
      'data: {"type":"text-delta","delta":"done"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":2},"outputTokens":{"total":1}}}',
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
    backend,
    nativeAddon: addon,
    ...(backend === "wasm" ? { wasm: await readFile(wasmPath) } : {}),
    fetch,
    onEvent(event) { sdkEvents.push(event); },
    apiKey: "host-tool-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "host/tool-model",
    tools: [{
      name: "lookup",
      description: "Look up a value by key.",
      inputSchema: {
        type: "object",
        properties: { key: { type: "string" } },
        required: ["key"],
        additionalProperties: false,
      },
      async execute(input, { signal }) {
        assert.equal(signal.aborted, false);
        toolCalls += 1;
        return `value:${input.key}`;
      },
    }],
  });
  const initialize = sdkEvents.find((event) => event.type === "acp.send" && event.message?.method === "initialize");
  assert.equal(initialize?.message.params.clientCapabilities.libfx.tools[0].name, "lookup");
  const turn = agent.prompt("use lookup");
  let text = "";
  for await (const update of turn) {
    if (update.type === "text_delta") text += update.delta;
  }
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(text.trim(), "done");
  assert.equal(toolCalls, 1);
  assert.equal(modelRequests, 2);
  assert.equal(await agent.close(), undefined);
  agent = null;
  console.log(`${backend} host tool integration passed`);
} finally {
  await agent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
