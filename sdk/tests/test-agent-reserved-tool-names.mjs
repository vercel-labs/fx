#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-reserved-tool-names.mjs [native|wasm]");
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

// The two most natural names an embedder picks for file tools are the kernel's
// builtin file-mutation names. Host tools must still execute under them.
const calls = [];
const writeResult = { type: "libfx.tool-result", text: "wrote it", images: [] };
const editResult = { type: "libfx.tool-result", text: "edited it", images: [] };

const tools = [
  {
    name: "write_file",
    description: "Write text to a file",
    inputSchema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } }, required: ["path", "content"] },
    execute(input) { calls.push({ tool: "write_file", input }); return writeResult; },
  },
  {
    name: "edit_file",
    description: "Replace text in a file",
    inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
    execute(input) { calls.push({ tool: "edit_file", input }); return editResult; },
  },
];

const gateway = {
  chatBodies: [],
  fetch: async (url, init = {}) => {
    if (String(init.method ?? "GET").toUpperCase() === "GET") return Response.json(catalog);
    gateway.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    if (gateway.chatBodies.length === 1) {
      return sse(
        { type: "tool-call", toolCallId: "call-w", toolName: "write_file", input: { path: "/tmp/n.txt", content: "hi" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      );
    }
    if (gateway.chatBodies.length === 2) {
      return sse(
        { type: "tool-call", toolCallId: "call-e", toolName: "edit_file", input: { path: "/tmp/n.txt" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      );
    }
    return sse({ type: "text-delta", delta: "done" }, { type: "finish", finishReason: { unified: "stop", raw: "stop" } });
  },
};

const agent = await createFxEngine({
  backend,
  apiKey: "sdk-reserved-names-key",
  model: "sdk/tool-model",
  fetch: gateway.fetch,
  tools,
  // File mutations need a permission decision; answer allow for the test.
  onPermission: () => "allow-once",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
});

const events = [];
const turn = agent.prompt("write then edit");
for await (const event of turn) events.push(event);
const result = await turn.result;
assert.equal(result.stopReason, "end_turn");

// Both host tools executed through the host executor; no call-time failure.
assert.deepEqual(calls.map((c) => c.tool), ["write_file", "edit_file"]);
assert.equal(calls[0].input.path, "/tmp/n.txt");
assert.equal(calls[0].input.content, "hi");

// Their results reached the model on the next step (not a tool error).
const second = gateway.chatBodies[1];
const toolResult = second.prompt
  .filter((m) => m.role === "tool" || (Array.isArray(m.content) && m.content.some((p) => p.type === "tool-result")))
  .flatMap((m) => (Array.isArray(m.content) ? m.content : []))
  .filter((p) => p.type === "tool-result")
  .map((p) => p.output?.value ?? p.output);
assert.ok(toolResult.length > 0, "tool results reached the model");
const resultText = JSON.stringify(toolResult);
assert.match(resultText, /wrote it/, "write_file result reached the model");

// The events carry the reserved names and the inputs.
const starts = events.filter((e) => e.type === "tool_start");
assert.deepEqual(starts.map((e) => e.name), ["write_file", "edit_file"]);
assert.deepEqual(starts[0].input, { path: "/tmp/n.txt", content: "hi" });
const ends = events.filter((e) => e.type === "tool_end");
assert.equal(ends.length, 2);
assert.ok(ends.every((e) => !e.isError), "no tool_end is an error");
assert.match(ends[0].content, /wrote it/);
assert.match(ends[1].content, /edited it/);

await agent.close();
console.log(`${backend} agent reserved-name host tools passed`);
