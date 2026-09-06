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
const encoded = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { content, isError: false, contentType: "rich" } });
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
      assert.ok(requests <= 3);
      const payload = JSON.parse(Buffer.from(init.body).toString("utf8"));
      const results = payload.prompt.flatMap((message) => message.content ?? [])
        .filter((part) => part.type === "tool-result" && part.toolCallId === "frame1");
      assert.equal(results.length, 1);
      assert.deepEqual(results[0].output, { type: "error-text", value: limitError });
      return sse(
        { type: "text-delta", delta: requests === 2 ? "handled error" : "still usable" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      );
    },
  });
  const first = agent.prompt("get escaped text");
  const events = [];
  for await (const event of first) events.push(event);
  assert.equal((await first.result).stopReason, "end_turn");
  assert.equal(events.filter((event) => event.type === "tool_end" && event.isError).length, 1);
  assert.equal(events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), "handled error");
  assert.deepEqual(responses, [{ content: limitError, isError: true }]);

  const followup = agent.prompt("continue without replaying the tool");
  let text = "";
  for await (const event of followup) if (event.type === "text_delta") text += event.delta;
  assert.equal((await followup.result).stopReason, "end_turn");
  assert.equal(text, "still usable");
  assert.equal(requests, 3);
  assert.equal(executions, 1);
  assert.equal(responses.length, 1);
  assert.equal(exits, 0);
  console.log("native tool frame limit passed: one tool error, model continuation, reusable agent, no replay");
} finally {
  clearTimeout(timer);
  await agent?.close().catch(() => {});
  await rm(home, { recursive: true, force: true });
}
