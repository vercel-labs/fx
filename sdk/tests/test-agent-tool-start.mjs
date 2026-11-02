#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-tool-start.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
const catalog = {
  object: "list",
  data: [{ id: "sdk/tool-model", type: "language", tags: ["tool-use"] }],
};

const sse = (...events) => new Response(
  [...events.map((event) => `data: ${JSON.stringify(event)}\n\n`), "data: [DONE]\n\n"].join(""),
  { headers: { "content-type": "text/event-stream" } },
);

function mockGateway(calls) {
  const state = { chatBodies: [] };
  const fetch = async (url, init = {}) => {
    if (String(init.method ?? "GET").toUpperCase() === "GET") return Response.json(catalog);
    state.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    const call = calls[state.chatBodies.length - 1];
    if (!call) throw new Error(`unexpected gateway request ${state.chatBodies.length}`);
    return sse(...call);
  };
  return { state, fetch };
}

const toolCallFinish = (id, name, input) => [
  { type: "tool-call", toolCallId: id, toolName: name, input },
  { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
];
const textFinish = (delta) => [
  { type: "text-delta", delta },
  { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
];

const baseOptions = {
  backend,
  apiKey: "sdk-tool-start-key",
  model: "sdk/tool-model",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
};

async function collectTurn(agent, input) {
  const events = [];
  const turn = agent.prompt(input);
  for await (const event of turn) events.push(event);
  return { events, result: await turn.result };
}

// tool_start carries the host tool's input object, in order, before tool_end.
{
  const executions = [];
  const gateway = mockGateway([
    toolCallFinish("call-1", "run_command", { command: "ls -la" }),
    textFinish("done"),
  ]);
  const agent = await createFxEngine({
    ...baseOptions,
    fetch: gateway.fetch,
    tools: [{
      name: "run_command",
      description: "Run a shell command",
      inputSchema: { type: "object", properties: { command: { type: "string" } } },
      execute(input) {
        executions.push(input);
        return "ok";
      },
    }],
  });
  const { events, result } = await collectTurn(agent, "list files");
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(executions, [{ command: "ls -la" }]);

  const starts = events.filter((event) => event.type === "tool_start");
  const ends = events.filter((event) => event.type === "tool_end");
  assert.equal(starts.length, 1);
  assert.equal(ends.length, 1);
  assert.ok(events.indexOf(starts[0]) < events.indexOf(ends[0]), "tool_start precedes tool_end");
  assert.deepEqual(starts[0], {
    type: "tool_start",
    id: "call-1",
    name: "run_command",
    input: { command: "ls -la" },
  });
  assert.equal(starts[0].inputTruncated, undefined);
  assert.equal("inputPreview" in starts[0], false);
  await agent.close();
}

// Two tool calls in one turn keep their own inputs.
{
  const gateway = mockGateway([
    [
      { type: "tool-call", toolCallId: "call-a", toolName: "first", input: { value: 1 } },
      { type: "tool-call", toolCallId: "call-b", toolName: "second", input: { value: 2 } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ],
    textFinish("done"),
  ]);
  const agent = await createFxEngine({
    ...baseOptions,
    fetch: gateway.fetch,
    tools: [
      { name: "first", description: "First", inputSchema: { type: "object" }, execute: () => "a" },
      { name: "second", description: "Second", inputSchema: { type: "object" }, execute: () => "b" },
    ],
  });
  const { events, result } = await collectTurn(agent, "run both");
  assert.equal(result.stopReason, "end_turn");
  const starts = events.filter((event) => event.type === "tool_start");
  assert.deepEqual(
    starts.map((event) => [event.id, event.input]),
    [["call-a", { value: 1 }], ["call-b", { value: 2 }]],
  );
  await agent.close();
}

// An oversized input is truncated with a marker while the tool itself still
// receives the complete arguments.
{
  const huge = "x".repeat(128 * 1024);
  const executions = [];
  const gateway = mockGateway([
    toolCallFinish("call-big", "upload_blob", { path: "/tmp/big.txt", content: huge }),
    textFinish("done"),
  ]);
  const agent = await createFxEngine({
    ...baseOptions,
    fetch: gateway.fetch,
    tools: [{
      name: "upload_blob",
      description: "Upload a blob",
      inputSchema: { type: "object" },
      execute(input) {
        executions.push(input);
        return "written";
      },
    }],
  });
  const { events, result } = await collectTurn(agent, "write a big file");
  assert.equal(result.stopReason, "end_turn");
  assert.equal(executions.length, 1);
  assert.equal(executions[0].content.length, huge.length, "execute() receives the full input");

  const start = events.find((event) => event.type === "tool_start");
  assert.equal("input" in start, false);
  assert.equal(start.inputTruncated, true);
  assert.equal(typeof start.inputPreview, "string");
  const full = JSON.stringify({ path: "/tmp/big.txt", content: huge });
  assert.ok(encoded.encode(start.inputPreview).length <= 64 * 1024);
  assert.ok(full.startsWith(start.inputPreview), "preview is a prefix of the full input JSON");
  await agent.close();
}

// Boundary: an input whose JSON is exactly the cap arrives whole; one byte
// over is truncated. Non-ASCII previews stay valid UTF-8 within the byte cap.
{
  const exactFit = { v: "x".repeat(64 * 1024 - JSON.stringify({ v: "" }).length) };
  assert.equal(encoded.encode(JSON.stringify(exactFit)).length, 64 * 1024);
  const overByOne = { v: exactFit.v + "x" };
  const nonAscii = { v: "😀".repeat(40 * 1024) };
  const gateway = mockGateway([
    toolCallFinish("call-exact", "probe", exactFit),
    textFinish("one"),
    toolCallFinish("call-over", "probe", overByOne),
    textFinish("two"),
    toolCallFinish("call-utf8", "probe", nonAscii),
    textFinish("three"),
  ]);
  const agent = await createFxEngine({
    ...baseOptions,
    fetch: gateway.fetch,
    tools: [{ name: "probe", description: "Probe inputs", inputSchema: { type: "object" }, execute: () => "ok" }],
  });

  const first = await collectTurn(agent, "exact fit");
  const startExact = first.events.find((event) => event.type === "tool_start");
  assert.deepEqual(startExact.input, exactFit);
  assert.equal(startExact.inputTruncated, undefined);

  const second = await collectTurn(agent, "one over");
  const startOver = second.events.find((event) => event.type === "tool_start");
  assert.equal(startOver.inputTruncated, true);
  assert.equal(encoded.encode(startOver.inputPreview).length, 64 * 1024);

  const third = await collectTurn(agent, "non-ascii");
  const startUtf8 = third.events.find((event) => event.type === "tool_start");
  assert.equal(startUtf8.inputTruncated, true);
  assert.ok(encoded.encode(startUtf8.inputPreview).length <= 64 * 1024);
  const lastCode = startUtf8.inputPreview.charCodeAt(startUtf8.inputPreview.length - 1);
  assert.ok(!(lastCode >= 0xd800 && lastCode <= 0xdbff), "preview never ends with a lone surrogate");
  await agent.close();
}

console.log(`${backend} agent tool_start input passed`);
