#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../node.js";

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
// The core's request budget, `default_max_request_bytes` in
// src/core/agent/runtime/request_image_budget.zig.
const requestBudget = 30 * 1024 * 1024;
let requests = 0;
let toolCalls = 0;
let largestBody = 0;
const imagesSent = [];
let agent;
const timer = setTimeout(() => assert.fail("native image framing timed out"), 60_000);
const sse = (...events) => new Response(
  [...events.map((event) => `data: ${JSON.stringify(event)}\n\n`), "data: [DONE]\n\n"].join(""),
  { headers: { "content-type": "text/event-stream" } },
);

try {
  agent = await createFxEngine({
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
      largestBody = Math.max(largestBody, init.body.length);
      imagesSent.push(JSON.parse(Buffer.from(init.body).toString("utf8")).prompt
        .filter((message) => message.role === "user" && Array.isArray(message.content))
        .flatMap((message) => message.content)
        .filter((part) => part.type === "file").length);
      // Each prompt calls the tool once, then answers with its images.
      if (requests % 2 === 1) return sse(
        { type: "tool-call", toolCallId: `images${requests}`, toolName: "screenshots", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      );
      if (requests > 2) return sse({ type: "finish", finishReason: { unified: "stop", raw: "stop" } });
      assert.ok(init.body.length < 8 * 1024 * 1024);
      assert.ok(Buffer.from(init.body).toString("base64").length > 8 * 1024 * 1024);
      const payload = JSON.parse(Buffer.from(init.body).toString("utf8"));
      const resultValues = payload.prompt.flatMap((message) => message.content ?? [])
        .filter((part) => part.type === "tool-result")
        .flatMap((part) => part.output.value ?? []);
      assert.ok(resultValues.length > 0);
      assert.ok(resultValues.every((part) => part.type === "text"));
      const received = payload.prompt
        .filter((message) => message.role === "user" && Array.isArray(message.content))
        .flatMap((message) => message.content)
        .filter((part) => part.type === "file");
      assert.deepEqual(received, images.map(() => ({ type: "file", mediaType: "image/png", data: { type: "data", data } })));
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

  // History keeps every image: 7 MiB of them each turn. Once a request would
  // pass the core's budget, the core leaves the oldest images out, and the
  // native transport carries each request it trims that way.
  for (const _ of [2, 3, 4, 5]) assert.equal((await agent.prompt("take screenshots").result).stopReason, "end_turn");
  assert.equal((await agent.prompt("x".repeat(4 * 1024 * 1024)).result).stopReason, "end_turn");
  assert.equal(requests, 12);
  assert.ok(largestBody <= requestBudget, `every request fits the core's budget: ${largestBody} bytes`);
  assert.equal(imagesSent[7], 8, "the fourth turn's answer carries all eight images");
  assert.ok(imagesSent[9] < 10 && imagesSent[11] < 12, `later requests leave the oldest images out: ${imagesSent}`);

  // Text is never left out of a request. The native transport limit, 32 MiB,
  // carries one over the core's budget, and one whose text alone is over the
  // limit fails before it reaches host fetch.
  let textRequests = 0;
  let largestTextBody = 0;
  const textOnly = await createFxEngine({
    backend: "native",
    nativeAddon: addon,
    home,
    workspaceRoot: home,
    apiKey: "native-image-framing-key",
    model: "native/image-model",
    fetch(_url, init) {
      if (init.method === "GET") {
        return Response.json({ object: "list", data: [{ id: "native/image-model", type: "language", tags: ["tool-use", "vision", "file-input"] }] });
      }
      textRequests += 1;
      largestTextBody = Math.max(largestTextBody, init.body.length);
      return sse(
        { type: "text-delta", delta: "ok" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      );
    },
  });
  try {
    const text = "x".repeat(7.75 * 1024 * 1024);
    for (const _ of [1, 2, 3, 4]) assert.equal((await textOnly.prompt(text).result).stopReason, "end_turn");
    assert.equal(textRequests, 4);
    assert.ok(largestTextBody > requestBudget + 1024 * 1024, `a request over the core's budget still reaches fetch: ${largestTextBody} bytes`);
    await assert.rejects(textOnly.prompt(text).result, /HostStreamBackpressure/);
    assert.equal(textRequests, 4, "a request over the transport limit must not reach host fetch");
  } finally {
    await textOnly.close();
  }
  console.log("native image framing passed: accepted images survive base64 framing; requests past the budget leave the oldest images out");
} finally {
  clearTimeout(timer);
  await agent?.close();
  await rm(home, { recursive: true, force: true });
}
