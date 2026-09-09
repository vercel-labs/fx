#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const home = await mkdtemp(join(tmpdir(), "fx-native-tool-frame-"));
const rich = { type: "libfx.tool-result", text: '"'.repeat(3 * 1024 * 1024), images: [] };
const content = JSON.stringify({ text: rich.text, images: rich.images });
const encoded = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content, isError: false, contentType: "rich", executionOutcome: "completed" } });
assert.ok(Buffer.byteLength(content) < 8 * 1024 * 1024);
assert.ok(Buffer.byteLength(encoded) + 1 > 8 * 1024 * 1024);
const limitError = "Host tool result exceeded the response frame limit";
let requests = 0;
let executions = 0;
let exits = 0;
const responses = [];
let agent;
const timer = setTimeout(() => assert.fail("native tool frame limit timed out"), 10_000);
const sse = (...events) => new Response(
  [...events.map((event) => `data: ${JSON.stringify(event)}\n\n`), "data: [DONE]\n\n"].join(""),
  { headers: { "content-type": "text/event-stream" } },
);

try {
  agent = await createFxAgent({
    backend: "native",
    nativeAddon: addon,
    home,
    workspaceRoot: home,
    apiKey: "native-tool-frame-key",
    model: "native/test-model",
    onEvent(event) {
      if (event.type === "runtime.exit") exits += 1;
      if (event.type === "acp.send" && event.message.result?.content !== undefined) {
        responses.push(event.message.result);
      }
    },
    tools: [{
      name: "escaped_result",
      description: "Return escaped text",
      inputSchema: { type: "object", properties: {} },
      execute() { executions += 1; return rich; },
    }],
    fetch(_url, init) {
      if (init.method === "GET") return Response.json({ object: "list", data: [] });
      requests += 1;
      if (requests === 1) return sse(
        { type: "tool-call", toolCallId: "frame1", toolName: "escaped_result", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      );
      assert.fail("unacknowledged oversized result allowed another provider request");
    },
  });
  const first = agent.prompt("get escaped text");
  const events = [];
  await assert.rejects(async () => { for await (const event of first) events.push(event); }, /SuspensionCheckpointUnavailable/);
  await assert.rejects(first.result, /SuspensionCheckpointUnavailable/);
  assert.equal(events.filter((event) => event.type === "tool_end" && event.isError).length, 1);
  assert.deepEqual(responses, [{ content: limitError, isError: true, executionOutcome: "uncertain" }]);
  assert.deepEqual(await agent.status(), { state: "blocked", canResume: false });
  await assert.rejects(agent.prompt("continue without replaying the tool").result, /uncertain/i);
  assert.throws(() => agent.resume(), /journal.*onEntry/);
  await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
  assert.equal(requests, 1);
  assert.equal(executions, 1);
  assert.equal(responses.length, 1);
  assert.equal(exits, 0);
  console.log("native tool frame limit passed: uncertainty retained, missing-sink owner blocked, no further model request or replay");
} finally {
  clearTimeout(timer);
  await agent?.close().catch(() => {});
  await rm(home, { recursive: true, force: true });
}
