#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createJournalStore } from "./fixtures/journal-store.mjs";

const backend = process.argv[2] ?? "native";
const target = process.argv[3] ?? backend;
const packageRoot = process.argv[4];
const format = process.argv[5] ?? "esm";
const sdk = packageRoot
  ? format === "cjs" ? createRequire(import.meta.url)(resolve(packageRoot, "node.cjs")) : await import(pathToFileURL(resolve(packageRoot, "node.js")))
  : await import("../node.js");
const wasm = [backend, target].includes("wasm") ? await readFile(packageRoot ? resolve(packageRoot, "fx-core.wasm") : new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = packageRoot ? undefined : new URL("../../zig-out/lib/libfx.node", import.meta.url);
// Leave room for the SDK request envelope within its existing 8 MiB bound.
const prompt = "x".repeat(5 * 1024 * 1024 - 4) + "\u{1f9ea}";
assert.equal(Buffer.byteLength(prompt), 5 * 1024 * 1024);
const watchdog = setTimeout(() => { console.error("large input recovery timed out"); process.exit(1); }, 30_000);
const store = createJournalStore();
let agent, requests = 0, loseAck = true;
const model = "fixture/large-input";
const options = (backend, journal) => ({
  backend, wasm, nativeAddon, model, apiKey: "fixture-key", journal,
  async fetch(_url, init) {
    if (init.method === "GET") return Response.json({ data: [{ id: model, type: "language", tags: ["tool-use"], context_window: 16_000_000, max_tokens: 64_000 }] });
    requests++;
    assert.ok(JSON.stringify(JSON.parse(Buffer.from(init.body).toString()).prompt).includes(prompt));
    return new Response('data: {"type":"text-delta","delta":"LARGE_INPUT_SAVED"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop"}}\n\ndata: [DONE]\n\n', { headers: { "content-type": "text/event-stream" } });
  },
  async onEntry(entry) {
    await store.options().onEntry(entry);
    if (entry.kind === "model_step") {
      const body = JSON.parse(Buffer.from(entry.bytes).toString());
      assert.ok(entry.bytes.length < 64 * 1024, "provider context rewrote the original input");
      assert.equal(body.executionContext.v, 2);
      assert.equal(Object.hasOwn(body.executionContext.recovery, "user"), false);
      if (loseAck && body.phase === "request") {
        loseAck = false;
        throw new Error("Lost request acknowledgement");
      }
    }
  },
});
const consume = async turn => {
  const drained = (async () => { for await (const _ of turn) {} })();
  return (await Promise.all([turn.result, drained]))[0];
};
try {
  agent = await sdk.createFxAgent(options(backend, []));
  await assert.rejects(consume(agent.prompt(prompt, { requestId: "large-input" })), error => error.name === "PersistenceUncertain" && error.cause?.message === "Lost request acknowledgement");
  assert.equal(requests, 0);
  await agent.close(); agent = null;
  agent = await sdk.createFxAgent(options(target, store.read()));
  assert.equal((await consume(agent.resume())).ok, true);
  assert.equal(requests, 1);
  const checkpoint = await agent.checkpoint();
  await agent.close(); agent = null;
  agent = await sdk.createFxAgent(options(backend, [checkpoint]));
  assert.equal((await consume(agent.prompt(prompt, { requestId: "large-input" }))).ok, true);
  assert.equal(requests, 1);
  console.log(`Large input recovery passed: ${backend} -> ${target}, ${format}, checkpoint=${checkpoint.bytes.length}`);
} finally { await agent?.close(); store.close(); clearTimeout(watchdog); }
