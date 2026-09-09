#!/usr/bin/env node
// Real ACP/core. Cancellation after executor entry must fence the owner even
// without storage, and a late executor settlement must not restore authority.
import { strict as assert } from "node:assert";
import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFxAgent } from "../node.js";
import { createJournalStore } from "./fixtures/journal-store.mjs";
const backend = process.argv[2] || "native";
const sink = process.argv[3] === "sink";
const beforeEntry = process.argv[4] === "before";
const lateReject = process.argv[5] === "reject";
const directory = await mkdtemp(join(tmpdir(), "libfx-cancel-owner-"));
const store = createJournalStore();
const watchdog = setTimeout(() => { console.error("cancel owner test timed out"); process.exit(1); }, 20_000);
const controller = new AbortController();
let entered;
const enteredPromise = new Promise(resolve => { entered = resolve; });
let settle;
let requests = 0;
let calls = 0;
let aborted = false;
let agent;
try {
  agent = await createFxAgent({
    backend,
    wasm: backend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined,
    nativeAddon: new URL("../../zig-out/lib/libfx.node", import.meta.url),
    apiKey: "fixture-key", model: "suspension/model",
    onEvent(event) {
      const message = event.message;
      const aboutToCall = backend === "native" ? message?.method === "libfx/tool_call"
        : message?.method === "session/update" && message.params?.update?.sessionUpdate === "tool_call";
      if (beforeEntry && event.type === "acp.receive" && aboutToCall) { controller.abort(); entered(); }
    },
    async fetch(_url, init) {
      if (init.method === "GET") return Response.json({ object: "list", data: [] });
      requests++;
      const events = requests === 1 ? [
        { type: "tool-call", toolCallId: "effect", toolName: "effect", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ] : [
        { type: "text-delta", delta: "safe followup" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ];
      return new Response(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
    },
    tools: [{ name: "effect", description: "external effect fixture", inputSchema: { type: "object", properties: {} },
      async execute(_input, { signal }) {
        calls++;
        await writeFile(join(directory, "effect"), String(calls), { flush: true });
        const pending = new Promise((resolve, reject) => {
          settle = () => lateReject ? reject(new Error("late lost ack")) : resolve("late completion");
          signal.addEventListener("abort", () => { aborted = true; }, { once: true });
        });
        entered();
        return pending;
      },
    }],
    ...(sink ? store.options() : {}),
  });
  const turn = agent.prompt("apply external effect", { signal: controller.signal, requestId: "cancelled-request" });
  const drain = (async () => { try { for await (const _ of turn) {} } catch {} })();
  await enteredPromise;
  controller.abort();
  if (beforeEntry) {
    const result = await turn.result;
    if (sink) assert.equal(result.ok, false);
    else assert.equal(result.stopReason, "cancelled");
    assert.equal(calls, 0);
    const status = await agent.status();
    if (sink) assert.equal(status.idle, true);
    else assert.deepEqual(status, { state: "idle", canResume: false });
    const next = agent.prompt("safe followup", { requestId: "safe-followup" });
    for await (const _ of next) {}
    assert.equal((await next.result).stopReason, sink ? "stop" : "end_turn");
    assert.equal(requests, 2);
  } else {
    let resultSettled = false;
    void turn.result.then(() => { resultSettled = true; }, () => { resultSettled = true; });
    await new Promise(resolve => setTimeout(resolve, 25));
    assert.equal(resultSettled, false, "turn settled before the executor released resources");
    settle();
    await assert.rejects(turn.result, sink ? /RecoveryRequired/ : /HostToolOutcomeUncertain|host.*uncertain/i);
    assert.equal(aborted, true);
    assert.equal(calls, 1);
    assert.equal(await readFile(join(directory, "effect"), "utf8"), "1");
    for (let attempt = 0; attempt < 2; attempt++) {
      if (sink) {
        assert.equal((await agent.status()).pendingTurn.awaiting.tool.name, "effect");
        await assert.rejects(agent.resume().result, /RecoveryRequired/);
        await assert.rejects(agent.checkpoint(), /RecoveryRequired/);
      } else {
        assert.deepEqual(await agent.status(), { state: "blocked", canResume: false });
        assert.throws(() => agent.resume(), /journal.*onEntry/);
        await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
        await assert.rejects(agent.abandon(), /journal.*onEntry/);
      }
      await assert.rejects(agent.prompt("retry", { requestId: "retry" }).result, sink ? /RecoveryRequired/ : /uncertain/i);
      if (attempt === 0) { settle(); await new Promise(resolve => setTimeout(resolve, 25)); }
    }
    if (sink) {
      await agent.abandon();
      assert.equal((await agent.status()).idle, true);
      await assert.rejects(agent.prompt("after abandonment", { requestId: "after-abandon" }).result, /RecoveryRequired/);
    }
    assert.equal(requests, 1, "cancelled effect owner sent another model request");
    assert.equal(calls, 1, "cancelled effect was repeated");
  }
  await drain;
  await agent.close(); agent = null;
  console.log(`cancel owner passed: ${backend}, sink=${sink}, beforeEntry=${beforeEntry}, lateReject=${lateReject}, requests=${requests}, effects=${calls}`);
} finally {
  settle?.();
  await agent?.close().catch(() => {});
  store.close();
  await rm(directory, { recursive: true, force: true });
  clearTimeout(watchdog);
}
