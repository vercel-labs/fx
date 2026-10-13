#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-provider-tools.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = backend === "wasm"
  ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"))
  : undefined;
let modelRequests = 0;
let providerName;

const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "provider-tools/model", type: "language", tags: ["tool-use"] }] }));
      return;
    }

    modelRequests += 1;
    const payload = JSON.parse(body);
    const providerTool = payload.tools?.find((tool) => tool.type === "provider");
    assert.ok(providerTool, `provider tool was not advertised: ${JSON.stringify(payload.tools)}`);
    assert.match(providerTool.id, /^gateway\.(exa|perplexity|parallel)_search$/);
    providerName = providerTool.name;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (modelRequests === 1) {
      response.end([
        `data: ${JSON.stringify({ type: "tool-input-start", id: "search-1", toolName: providerName })}`,
        `data: ${JSON.stringify({ type: "tool-call", toolCallId: "search-1", toolName: providerName, input: { query: "libfx provider search" }, providerExecuted: true })}`,
        `data: ${JSON.stringify({ type: "tool-result", toolCallId: "search-1", result: { results: [{ title: "Source", url: "https://example.com", snippet: "sourced-result" }] } })}`,
        'data: {"type":"text-delta","delta":"searched"}',
        'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":2},"outputTokens":{"total":1}}}',
        "data: [DONE]",
        "",
      ].join("\n\n"));
      return;
    }

    assert.equal(modelRequests, 2, "unexpected extra model request");
    assert.ok(body.includes("sourced-result"), "checkpoint omitted the provider-executed result");
    response.end([
      'data: {"type":"text-delta","delta":"restored"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":1}}}',
      "data: [DONE]",
      "",
    ].join("\n\n"));
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const options = (checkpoint) => ({
  backend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  ...(checkpoint ? { checkpoint } : {}),
  fetch,
  apiKey: "provider-tools-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "provider-tools/model",
  tools: [{ name: "web_search", providerExecuted: true }],
});

let agent;
try {
  agent = await createFxEngine(options());
  const turn = agent.prompt("search the web");
  const events = [];
  for await (const event of turn) events.push(event);
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(events.find((event) => event.type === "tool_start")?.name, "web_search");
  const ended = events.find((event) => event.type === "tool_end");
  assert.equal(ended?.name, "web_search");
  assert.equal(ended?.isError, false);
  assert.ok(ended?.content?.includes("sourced-result"), `unexpected tool_end payload: ${JSON.stringify(ended)}`);
  assert.equal(events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), "searched");

  const checkpoint = await agent.checkpoint();
  await agent.close();
  agent = await createFxEngine(options(checkpoint));
  const restored = agent.prompt("use the saved search");
  let restoredText = "";
  for await (const event of restored) if (event.type === "text_delta") restoredText += event.delta;
  assert.equal((await restored.result).stopReason, "end_turn");
  assert.equal(restoredText, "restored");
  assert.equal(modelRequests, 2);
  console.log(`${backend} provider-executed tool integration passed`);
} finally {
  await agent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
