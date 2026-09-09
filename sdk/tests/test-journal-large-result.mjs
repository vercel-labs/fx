#!/usr/bin/env node
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const directory = resolve(process.argv[2]);
const format = process.argv[3] ?? "esm";
const sdk = format === "cjs"
  ? createRequire(import.meta.url)(resolve(directory, "node.cjs"))
  : await import(pathToFileURL(resolve(directory, "node.js")).href);
const signature = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");
const image = Buffer.alloc(3 * 1024 * 1024);
signature.copy(image);
const data = image.toString("base64");
const sse = (events) => new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
  headers: { "content-type": "text/event-stream" },
});

for (const backend of ["native", "wasm"]) {
  let requests = 0;
  let effects = 0;
  let restoredRequestHadImage = false;
  const entries = [];
  const options = {
    backend, model: "journal/large-result", apiKey: "fixture-key", journal: [],
    onEntry(entry) { entries.push({ ...entry, bytes: Uint8Array.from(entry.bytes) }); },
    fetch(_url, init) {
      if (init.method === "GET") return Promise.resolve(Response.json({ data: [{ id: "journal/large-result", type: "language", tags: ["tool-use", "vision", "file-input"] }] }));
      requests++;
      if (requests > 1) {
        const body = JSON.parse(Buffer.from(init.body).toString("utf8"));
        const received = body.prompt.flatMap((message) => message.content ?? [])
          .filter((part) => part.type === "tool-result")
          .flatMap((part) => part.output.value ?? [])
          .filter((part) => part.type === "image-data");
        assert.deepEqual(received, [{ type: "image-data", data, mediaType: "image/png" }]);
        if (requests === 3) restoredRequestHadImage = true;
      }
      return Promise.resolve(sse(requests === 1 ? [
        { type: "tool-call", toolCallId: "original-large-call", toolName: "screenshot", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ] : [
        { type: "text-delta", delta: "Stored screenshot." },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ]));
    },
    tools: [{
      name: "screenshot", description: "A bounded image fixture", inputSchema: { type: "object", properties: {} }, replay: "safe",
      execute() {
        effects++;
        return { type: "libfx.tool-result", text: "receipt:screenshot", images: [{ type: "image", mimeType: "image/png", data }] };
      },
    }],
  };
  const consume = async (turn) => {
    const drained = (async () => { for await (const _event of turn) {} })();
    const [result] = await Promise.all([turn.result, drained]);
    assert.equal(result.ok, true);
  };
  let agent;
  try {
    agent = await sdk.createFxAgent(options);
    await consume(agent.prompt("Take the screenshot.", { requestId: "large-request" }));
    assert.equal(requests, 2);
    assert.equal(effects, 1);
    assert.ok(entries.some((entry) => entry.kind === "tool_result" && entry.bytes.length > 4 * 1024 * 1024));
    const checkpoint = await agent.checkpoint();
    assert.ok(checkpoint.bytes.length > 8 * 1024 * 1024, "checkpoint must exercise chunked restore");
    assert.equal(entries.at(-1).hash, checkpoint.hash, "checkpoint return precedes durability");
    await agent.close();
    agent = await sdk.createFxAgent({ ...options, journal: [checkpoint] });
    await consume(agent.prompt("Take the screenshot.", { requestId: "large-request" }));
    assert.equal(requests, 2, "completed retry called the model");
    assert.equal(effects, 1, "completed retry repeated the effect");
    await consume(agent.prompt("Describe the saved image.", { requestId: "next-request" }));
    assert.equal(requests, 3);
    assert.equal(effects, 1);
    assert.equal(restoredRequestHadImage, true, "restored model history lost the image");
    console.log(JSON.stringify({ format, backend, requests, effects, checkpointBytes: checkpoint.bytes.length }));
  } finally {
    await agent?.close();
  }
}
