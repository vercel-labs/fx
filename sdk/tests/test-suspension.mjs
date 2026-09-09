#!/usr/bin/env node
// Real libfx ACP/core; only provider transport and customer effects are fixtures.
import { strict as assert } from "node:assert";
const watchdog = setTimeout(() => { console.error("suspension integration timed out"); process.exit(1); }, 20_000);
import { readFile } from "node:fs/promises";
import { createJournalStore } from "./fixtures/journal-store.mjs";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] || "native";
const targetBackend = process.argv[3] || backend;
const wasm = backend === "wasm" || targetBackend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = new URL("../../zig-out/lib/libfx.node", import.meta.url);
const stores = [];
const storeFor = (journal = []) => { const store = createJournalStore(journal); stores.push(store); return store; };
const sourceStore = storeFor();
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const entered = deferred();
const release = deferred();
const checkpointEntered = deferred();
const checkpointRelease = deferred();
let calls = 0;
let requests = 0;
let savingPause = false;
let stderr = "";
const options = (backend, store) => ({
  ...store.options(),
  backend, wasm, nativeAddon, model: "suspension/model", apiKey: "fixture-key",
  onEvent(event) {
    if (process.env.FX_SUSPENSION_TEST_TRACE && event.type.startsWith("acp.")) console.error(event.type, event.message.method ?? "response", event.message.id, event.message.error ?? "");
  },
  stderr(chunk) { stderr += new TextDecoder().decode(chunk); },
  async fetch(_url, init) {
    if (init.method === "GET") return Response.json({ object: "list", data: [] });
    requests++;
    const body = new TextDecoder().decode(init.body);
    const events = requests === 1 ? [
      { type: "tool-call", toolCallId: "effect-1", toolName: "effect", input: {} },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ] : [
      { type: "text-delta", delta: "finished" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ];
    if (requests > 1) assert.ok(body.includes("committed-effect"), "resume omitted settled tool result");
    return new Response(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  },
  tools: [{ name: "effect", description: "Fixture effect", inputSchema: { type: "object", properties: {} },
    async execute(_input, { signal }) {
      calls++;
      entered.resolve();
      await release.promise;
      assert.equal(signal.aborted, false, "suspend cancelled an active effect");
      savingPause = true;
      return "committed-effect";
    },
  }],
  async onEntry(entry) {
    await store.options().onEntry(entry);
    if (store === sourceStore && savingPause && entry.kind === "tool_result") {
      checkpointEntered.resolve();
      await checkpointRelease.promise;
    }
  },
});
let agent;
let restored;
try {
  agent = await createFxAgent(options(backend, sourceStore));
  assert.deepEqual(await agent.status(), { idle: true, lastSeq: 0 });
  const turn = agent.prompt("run effect and then finish", { requestId: "suspended-request" });
  const observed = Promise.allSettled([
    turn.result, (async () => { for await (const _ of turn) {} })(),
  ]);
  await entered.promise;
  let settled = false;
  const suspended = agent.suspend().then(result => { settled = true; return result; });
  assert.equal((await agent.status()).idle, false);
  assert.equal(settled, false);
  release.resolve();
  await checkpointEntered.promise;
  assert.equal(settled, false, "pause resolved before durable acknowledgement");
  assert.equal(requests, 1);
  checkpointRelease.resolve();
  const paused = await suspended;
  assert.equal(paused.idle, false);
  assert.equal(paused.pendingTurn.awaiting, "model");
  const outcomes = await observed;
  assert.equal(outcomes[0].status, "rejected");
  assert.equal(outcomes[0].reason.name, "PendingTurnError");
  assert.equal(outcomes[1].status, "rejected");
  const pendingJournal = sourceStore.read();
  assert.equal(pendingJournal.at(-1).kind, "tool_result");
  await assert.rejects(agent.prompt("replace pending work", { requestId: "another-request" }).result, /resume|abandon|PendingTurn/);
  await assert.rejects(agent.checkpoint(), /InvalidJournalTransition|pending/i);
  await agent.close(); agent = null;

  const resumedStore = storeFor(pendingJournal);
  restored = await createFxAgent(options(targetBackend, resumedStore));
  assert.deepEqual(await restored.status(), paused);
  const resumed = restored.resume();
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "stop");
  assert.equal(requests, 2);
  assert.equal(calls, 1, "resume replayed settled effect");
  assert.equal((await restored.status()).idle, true);
  const checkpoint = await restored.checkpoint();
  assert.deepEqual(checkpoint, resumedStore.read().at(-1));
  await restored.close(); restored = null;

  // Fork the saved durable prefix into its own fixture store before abandoning.
  const abandonedStore = storeFor(pendingJournal);
  restored = await createFxAgent(options(targetBackend, abandonedStore));
  await restored.abandon();
  assert.equal((await restored.status()).idle, true);
  assert.equal(abandonedStore.read().at(-1).kind, "turn_end");
  await assert.rejects(restored.resume().result, /pending|paused|InvalidJournalTransition/i);
  await restored.close(); restored = null;

  // Reopen the real selected-decision prefix without its effect acknowledgement.
  // The original blocked tool must not execute, even though its effect happened.
  const resultIndex = pendingJournal.findIndex(entry => entry.kind === "tool_result");
  assert.ok(resultIndex > 0);
  const uncertainStore = storeFor(pendingJournal.slice(0, resultIndex));
  restored = await createFxAgent(options(targetBackend, uncertainStore));
  assert.equal((await restored.status()).pendingTurn.awaiting.tool.name, "effect");
  const unsafe = restored.resume();
  const unsafeResults = await Promise.allSettled([
    unsafe.result, (async () => { for await (const _ of unsafe) {} })(),
  ]);
  assert.equal(unsafeResults[0].status, "rejected");
  assert.equal(unsafeResults[0].reason.name, "RecoveryRequired");
  assert.equal(requests, 2, "uncertain resume sent a provider request");
  assert.equal(calls, 1, "uncertain resume replayed a tool");
  await restored.close(); restored = null;
  assert.equal(stderr, "");
  console.log(`suspension integration passed: ${backend} -> ${targetBackend}; durable ack, no cancellation/replay, explicit resume/abandon`);
} finally {
  release.resolve(); checkpointRelease.resolve();
  await agent?.close().catch(() => {});
  await restored?.close().catch(() => {});
  for (const store of stores) store.close();
  clearTimeout(watchdog);
}
