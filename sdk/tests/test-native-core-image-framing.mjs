#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const home = await mkdtemp(join(tmpdir(), "fx-native-image-framing-"));
const signature = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");
const image = Buffer.alloc(3.5 * 1024 * 1024 * 3 / 4);
signature.copy(image);
const data = image.toString("base64");
const images = [1, 2].map(() => ({ type: "image", mimeType: "image/png", data }));
const result = { type: "libfx.tool-result", text: "two screenshots", images };
assert.equal(Buffer.byteLength(JSON.stringify({ text: result.text, images })), 7_340_169);
let requests = 0;
let toolCalls = 0;
let agent;
const timer = setTimeout(() => assert.fail("native image framing timed out"), 10_000);
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
    apiKey: "native-image-framing-key",
    model: "native/image-model",
    tools: [{
      name: "screenshots",
      description: "Take two screenshots",
      inputSchema: { type: "object", properties: {} },
      execute() {
        toolCalls += 1;
        return result;
      },
    }],
    fetch(_url, init) {
      if (init.method === "GET") {
        return Response.json({ object: "list", data: [{ id: "native/image-model", type: "language", tags: ["tool-use", "vision", "file-input"] }] });
      }
      requests += 1;
      if (requests === 1) return sse(
        { type: "tool-call", toolCallId: "images1", toolName: "screenshots", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      );
      assert.equal(requests, 2);
      assert.ok(init.body.length < 8 * 1024 * 1024);
      assert.ok(Buffer.from(init.body).toString("base64").length > 8 * 1024 * 1024);
      const payload = JSON.parse(Buffer.from(init.body).toString("utf8"));
      const received = payload.prompt.flatMap((message) => message.content ?? [])
        .filter((part) => part.type === "tool-result")
        .flatMap((part) => part.output.value ?? [])
        .filter((part) => part.type === "image-data");
      assert.deepEqual(received, images.map(() => ({ type: "image-data", data, mediaType: "image/png" })));
      return sse(
        { type: "text-delta", delta: "received images" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      );
    },
  });
  const turn = agent.prompt("take screenshots");
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(toolCalls, 1);
  assert.equal(requests, 2);

  // The retained images plus this prompt exceed the unchanged raw request budget.
  await assert.rejects(agent.prompt("x".repeat(2 * 1024 * 1024)).result, /HostStreamBackpressure/);
  assert.equal(requests, 2, "an oversized raw request must not reach host fetch");
  console.log("native image framing passed: accepted images survive base64 framing; oversized raw requests stay bounded");
} finally {
  clearTimeout(timer);
  await agent?.close();
  await rm(home, { recursive: true, force: true });
}
