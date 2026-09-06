#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { createMcpAdapter } from "../mcp.js";

const imageError = process.argv[4] === "images-error";
const imageOnly = process.argv[4] === "image-only";
const imageMode = imageError || imageOnly || process.argv[4] === "images";
const imageData = Buffer.concat([Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64"), Buffer.alloc(80 * 1024)]).toString("base64");
let toolCalls = 0;
const transport = process.argv[2] || "stdio";
const backend = process.argv[3] || (transport === "stdio" ? "native" : "wasm");
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const toolDescription = "MCP tool usage and parameter guidance. ".repeat(64);
let mcpClosed = false;

function rpcClient(send, close) {
  let nextId = 1;
  const pending = new Map();
  const receive = (message) => {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message));
    else waiter.resolve(message.result);
  };
  const request = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const id = nextId++;
    pending.set(id, { resolve: resolveRequest, reject });
    send({ jsonrpc: "2.0", id, method, params }, receive).catch((error) => {
      pending.delete(id);
      reject(error);
    });
  });
  return {
    initialize: () => request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "libfx-test", version: "1" } }),
    listTools: (params) => request("tools/list", params),
    callTool: (params, resultSchema, options) => {
      assert.equal(resultSchema, undefined);
      assert.ok(options?.signal instanceof AbortSignal);
      toolCalls += 1;
      return request("tools/call", params);
    },
    readResource: (params) => request("resources/read", params),
    getPrompt: (params) => request("prompts/get", params),
    async close() { await close(); mcpClosed = true; },
    receive,
  };
}

let mcpServer;
let mcpClient;
if (transport === "stdio") {
  const child = spawn(process.execPath, [resolve(scriptDir, "fixtures/mcp-stdio-server.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
  let client;
  client = rpcClient(async (message) => { child.stdin.write(`${JSON.stringify(message)}\n`); }, async () => {
    child.stdin.end();
    await new Promise((resolveExit) => child.once("exit", resolveExit));
  });
  createInterface({ input: child.stdout }).on("line", (line) => client.receive(JSON.parse(line)));
  mcpClient = client;
} else {
  const dispatch = ({ id, method, params }) => {
    if (method === "initialize") return { jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {}, resources: {}, prompts: {} }, serverInfo: { name: "http-fixture", version: "1" } } };
    if (method === "tools/list" && params.cursor === undefined) return { jsonrpc: "2.0", id, result: { tools: [], nextCursor: "tools-page" } };
    if (method === "tools/list") return { jsonrpc: "2.0", id, result: { tools: [{ name: "echo", description: toolDescription, inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } }] } };
    if (method === "tools/call") return { jsonrpc: "2.0", id, result: imageMode ? { isError: imageError, content: [{ type: "image", mimeType: "image/png", data: imageData }], structuredContent: imageOnly ? undefined : { label: "screenshot" } } : { content: [{ type: "text", text: `mcp:${params.arguments.value}` }] } };
    if (method === "resources/read") return { jsonrpc: "2.0", id, result: { contents: [{ uri: params.uri, text: "resource context" }] } };
    if (method === "prompts/get") return { jsonrpc: "2.0", id, result: { messages: [{ role: "user", content: { type: "text", text: "prompt context" } }] } };
    return { jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } };
  };
  mcpServer = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(dispatch(JSON.parse(Buffer.concat(chunks).toString("utf8")))));
  });
  await new Promise((resolveListen) => mcpServer.listen(0, "127.0.0.1", resolveListen));
  const endpoint = `http://127.0.0.1:${mcpServer.address().port}/mcp`;
  mcpClient = rpcClient(async (message, receive) => {
    const response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(message) });
    receive(await response.json());
  }, async () => {
    mcpServer.closeAllConnections();
    await new Promise((resolveClose) => mcpServer.close(resolveClose));
  });
}

await mcpClient.initialize();
const adapter = await createMcpAdapter(mcpClient, {
  prefix: "mcp_",
  resources: ["memory://fixture"],
  prompts: ["fixture"],
});
assert.ok(adapter.instructions.includes("resource context"));
assert.ok(adapter.instructions.includes("prompt context"));

let gatewayRequests = 0;
const gateway = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "mcp/model", type: "language", tags: imageMode ? ["tool-use", "vision", "file-input"] : ["tool-use"] }] }));
      return;
    }
    gatewayRequests += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (gatewayRequests === 1) {
      assert.ok(body.includes("resource context") && body.includes("prompt context"));
      assert.ok(JSON.parse(body).tools.some((tool) => tool.name === "mcp_echo"));
      if (transport === "http") assert.equal(JSON.parse(body).tools.find((tool) => tool.name === "mcp_echo").description, toolDescription);
      response.end('data: {"type":"tool-call","toolCallId":"mcp_1","toolName":"mcp_echo","input":{"value":"hello"}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n');
      return;
    }
    if (imageMode) {
      const parts = JSON.parse(body).prompt.flatMap((message) => message.content ?? []);
      const result = parts.find((part) => part.type === "tool-result" && part.toolCallId === "mcp_1");
      assert.equal(result?.output.type, "content", JSON.stringify(result?.output));
      assert.deepEqual(result.output.value.find((part) => part.type === "image-data"), { type: "image-data", data: imageData, mediaType: "image/png" });
      if (imageOnly) assert.ok(result.output.value.every((part) => part.type === "image-data"));
      else assert.ok(result.output.value.some((part) => part.type === "text" && part.text.includes("screenshot")));
      if (imageError) assert.ok(result.output.value.some((part) => part.type === "text" && part.text.includes("Tool error")));
    } else assert.ok(body.includes("mcp:hello"));
    response.end('data: {"type":"text-delta","delta":"done"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => gateway.listen(0, "127.0.0.1", resolveListen));

let agent;
try {
  const options = {
    backend,
    nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
    ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
    tools: adapter.tools,
    instructions: adapter.instructions,
    fetch: (input, init) => fetch((init?.method ?? "GET") === "GET" ? `http://127.0.0.1:${gateway.address().port}/models` : input, init),
    apiKey: "mcp-key",
    gatewayChatUrl: `http://127.0.0.1:${gateway.address().port}/chat`,
    model: "mcp/model",
  };
  agent = await createFxAgent(options);
  const turn = agent.prompt("use MCP");
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  assert.equal(text, "done");
  assert.equal((await turn.result).stopReason, "end_turn");
  if (imageMode) {
    const checkpoint = await agent.checkpoint();
    await agent.close();
    agent = await createFxAgent({ ...options, checkpoint });
    const resumed = agent.prompt("Describe that screenshot again");
    for await (const event of resumed) {}
    assert.equal((await resumed.result).stopReason, "end_turn");
    assert.equal(gatewayRequests, 3);
  }
  assert.equal(toolCalls, 1, "result transfer or restore must never repeat the MCP effect");
  await agent.close();
  agent = null;
  await adapter.close();
  assert.equal(mcpClosed, true);
  console.log(`${transport}/${backend} MCP adapter integration passed`);
} finally {
  await agent?.close().catch(() => {});
  await adapter.close().catch(() => {});
  gateway.closeAllConnections();
  await new Promise((resolveClose) => gateway.close(resolveClose));
}
