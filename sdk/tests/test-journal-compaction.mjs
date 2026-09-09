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
const load = name => packageRoot
  ? format === "cjs" ? createRequire(import.meta.url)(resolve(packageRoot, `${name}.cjs`)) : import(pathToFileURL(resolve(packageRoot, `${name}.js`)))
  : import(new URL(`../${name}.js`, import.meta.url));
const { createFxAgent } = await load("node");
const { createProjection } = await load("transcript");
const wasm = [backend, target].includes("wasm") ? await readFile(packageRoot ? resolve(packageRoot, "fx-core.wasm") : new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = packageRoot ? undefined : new URL("../../zig-out/lib/libfx.node", import.meta.url);
const watchdog = setTimeout(() => { console.error("journal compaction timed out"); process.exit(1); }, 30_000);
const store = createJournalStore();
const model = "fixture/compaction";
let requests = 0, summaries = 0, effects = 0, loseAck = true;
let agent, restored;
const options = (selected, journal) => ({
  backend: selected, nativeAddon, wasm, model, apiKey: "fixture-key", journal,
  tools: [{ name: "read", description: "Read fixture data", inputSchema: { type: "object", properties: {} },
    execute() { effects++; return "COMPACTION_SAVED_RESULT"; } }],
  async fetch(_url, init) {
    if (init.method === "GET") return Response.json({ object: "list", data: [
      { id: model, type: "language", tags: ["tool-use", "reasoning"], context_window: 128_000, max_tokens: 8192 },
    ] });
    const body = JSON.parse(new TextDecoder().decode(init.body));
    let events;
    if (body.tools.length === 0) {
      summaries++;
      events = [{ type: "text-delta", delta: "Preserve COMPACTION_SAVED_RESULT and continue without repeating completed reads." }];
    } else {
      requests++;
      if (requests <= 5) events = [
        { type: "reasoning-start", id: `reasoning-${requests}` },
        { type: "reasoning-end", id: `reasoning-${requests}`, providerMetadata: { openai: { reasoningEncryptedContent: `SAVED_REASONING_${requests}` + "a".repeat(80_000) } } },
        { type: "tool-call", toolCallId: `read-${requests}`, toolName: "read", input: {} },
      ];
      else {
        const prompt = JSON.stringify(body.prompt);
        assert.ok(prompt.includes("context_handoff"));
        assert.ok(prompt.includes("SAVED_REASONING_5"));
        assert.ok(!prompt.includes("SAVED_REASONING_1"));
        events = [{ type: "text-delta", delta: "COMPACTION_RECOVERED" }];
      }
    }
    events.push({ type: "finish", finishReason: { unified: events.some(event => event.type === "tool-call") ? "tool-calls" : "stop" } });
    return new Response(events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  },
  async onEntry(entry) {
    await store.options().onEntry(entry);
    if (loseAck && entry.kind === "model_step" && JSON.parse(new TextDecoder().decode(entry.bytes)).activeThrough) {
      loseAck = false;
      throw new Error("Lost compaction acknowledgement");
    }
  },
});

try {
  agent = await createFxAgent(options(backend, []));
  await assert.rejects(agent.prompt("Read the fixture five times, then finish.", { requestId: "compaction-request" }).result,
    error => error.name === "PersistenceUncertain" && error.cause?.message === "Lost compaction acknowledgement");
  assert.equal(effects, 5); assert.equal(requests, 5); assert.equal(summaries, 1);
  assert.equal(JSON.parse(new TextDecoder().decode(store.read().at(-1).bytes)).phase, "context");
  await agent.close(); agent = null;
  restored = await createFxAgent(options(target, store.read()));
  const result = await restored.resume().result;
  assert.equal(result.ok, true);
  assert.equal(effects, 5); assert.equal(requests, 6); assert.equal(summaries, 1);
  const transcript = createProjection(store.read()).transcript();
  assert.equal(transcript.messages.flatMap(message => message.parts).filter(part => part.type === "tool_result").length, 5);
  assert.ok(JSON.stringify(transcript).includes("COMPACTION_RECOVERED"));
  console.log(`Journal compaction recovery passed: ${backend} -> ${target}, ${format}`);
} finally {
  await agent?.close(); await restored?.close(); store.close(); clearTimeout(watchdog);
}
