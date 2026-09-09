#!/usr/bin/env node
// Real ACP/core and persisted journal entries; only provider and external tool are fixtures.
import { strict as assert } from "node:assert";
import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createFxAgent } from "../node.js";
import { createJournalStore } from "./fixtures/journal-store.mjs";

const backend = process.argv[2] || "native";
const targetBackend = process.argv[3] || (backend === "native" ? "wasm" : "native");
const mode = process.argv[4] || "throw";
const knownFailure = mode === "returned_failure" || mode === "returned_plain_failure";
const wasm = backend === "wasm" || targetBackend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = new URL("../../zig-out/lib/libfx.node", import.meta.url);
const directory = await mkdtemp(join(tmpdir(), "libfx-tool-uncertainty-"));
const watchdog = setTimeout(() => { console.error("host tool uncertainty test timed out"); process.exit(1); }, 20_000);
let agent;
let target;
let suspension;
let toolCalls = 0;
let providerRequests = 0;
let externalEffects = 0;
const stores = [];
const storeFor = (journal = []) => { const store = createJournalStore(journal); stores.push(store); return store; };
const sourceStore = storeFor();
const options = (backend, store) => ({
  backend, wasm, nativeAddon, apiKey: "fixture-key", model: "suspension/model",
  ...(mode === "no_sink" ? {} : store.options()),
  async fetch(_url, init) {
    if (init.method === "GET") return Response.json({ object: "list", data: [] });
    providerRequests++;
    const body = new TextDecoder().decode(init.body);
    if (providerRequests > 1) {
      assert.ok(knownFailure, "uncertain effect allowed another model request");
      assert.ok(body.includes("known terminal failure"));
    }
    const events = providerRequests === 1 ? [
      { type: "tool-call", toolCallId: "effect-1", toolName: "effect", input: {} },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ] : [
      { type: "text-delta", delta: "finished" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ];
    return new Response(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  },
  tools: [{ name: "effect", description: "fixture effect", inputSchema: { type: "object", properties: {} },
    async execute(_input, { signal }) {
      toolCalls++;
      externalEffects++;
      await writeFile(join(directory, "external-effect"), String(externalEffects), { flush: true });
      // Suspension must wait for this callback; do not await it from the tool.
      if (mode !== "throw_without_suspend") {
        suspension = agent.suspend();
        void suspension.catch(() => {});
      }
      assert.equal(signal.aborted, false);
      if (mode === "returned_plain_failure") return { content: "known terminal failure", isError: true };
      if (knownFailure) return { type: "libfx.tool-result", text: "known terminal failure", images: [], isError: true };
      if (mode === "invalid_result") return { type: "libfx.tool-result", text: "lost result", images: null };
      if (mode === "invalid_image") return { type: "libfx.tool-result", text: "lost result", images: [{ type: "image", data: "invalid-base64", mimeType: "image/png" }] };
      if (mode === "throw_getter") throw { get toolResult() { throw new Error("diagnostic getter failed"); } };
      if (mode === "oversized_result") return "x".repeat(9 * 1024 * 1024);
      const error = new Error("remote effect committed but acknowledgement was lost");
      if (mode === "throw_rich") error.toolResult = { type: "libfx.tool-result", text: "unacknowledged effect", images: [], isError: true };
      throw error;
    },
  }],

});
async function finish(turn) {
  const events = [];
  try { for await (const event of turn) events.push(event); } catch {}
  return { events, result: await turn.result.catch(error => ({ error })) };
}
async function assertBlocked(owner) {
  assert.equal((await owner.status()).pendingTurn.awaiting.tool.name, "effect");
  await assert.rejects(owner.prompt("repeat the effect", { requestId: "changed-request" }).result, /resume|abandon|RecoveryRequired|PendingTurn/i);
  const resumed = await finish(owner.resume());
  assert.equal(resumed.result.error?.name, "RecoveryRequired");
  assert.equal(providerRequests, 1, "resume sent another provider request");
  assert.equal(toolCalls, 1, "resume replayed the tool");
  assert.equal(externalEffects, 1);
}
try {
  agent = await createFxAgent(options(backend, sourceStore));
  const turn = await finish(agent.prompt("perform the external effect", { requestId: "uncertain-effect" }));
  if (mode === "no_sink") {
    await assert.rejects(suspension, /journal.*onEntry/);
    assert.match(turn.result.error?.message ?? "", /SuspensionCheckpointUnavailable/);
    assert.deepEqual(await agent.status(), { state: "blocked", canResume: false });
    await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
    await assert.rejects(agent.prompt("retry").result, /uncertain/i);
    assert.throws(() => agent.resume(), /journal.*onEntry/);
    assert.equal(providerRequests, 1);
    assert.equal(externalEffects, 1);
    assert.equal(toolCalls, 1);
    await agent.close(); agent = null;
  } else {
    if (suspension) {
      if (knownFailure) assert.equal((await suspension).pendingTurn.awaiting, "model");
      else await assert.rejects(suspension, { name: "RecoveryRequired" });
    }
    assert.equal(turn.result.error?.name, knownFailure ? "PendingTurnError" : "RecoveryRequired");
    assert.equal(providerRequests, 1);
    const journal = sourceStore.read();
    assert.equal(journal.at(-1).kind, knownFailure ? "tool_result" : "model_step");
    if (knownFailure) {
      assert.equal((await agent.status()).pendingTurn.awaiting, "model");
      assert.ok(turn.events.some(event => event.type === "tool_end" && event.isError === true));
    } else await assertBlocked(agent);
    await agent.close(); agent = null;
    target = await createFxAgent(options(targetBackend, storeFor(journal)));
    if (knownFailure) {
      assert.equal((await target.status()).pendingTurn.awaiting, "model");
      const resumed = await finish(target.resume());
      assert.equal(resumed.result.stopReason, "stop");
      assert.equal(providerRequests, 2);
      assert.equal(toolCalls, 1);
    } else await assertBlocked(target);
    await target.close(); target = null;
  }
  assert.equal(await readFile(join(directory, "external-effect"), "utf8"), "1");
  console.log(`host tool uncertainty passed: ${backend} -> ${targetBackend}, ${mode}; effects=1, providerRequests=${providerRequests}`);
} finally {
  await agent?.close().catch(() => {});
  await target?.close().catch(() => {});
  for (const store of stores) store.close();
  await rm(directory, { recursive: true, force: true });
  clearTimeout(watchdog);
}
