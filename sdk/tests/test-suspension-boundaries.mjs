#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createJournalStore } from "./fixtures/journal-store.mjs";
import { createFxAgent } from "../node.js";
const backend = process.argv[2] || "native";
const wasm = backend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = new URL("../../zig-out/lib/libfx.node", import.meta.url);
const watchdog = setTimeout(() => { console.error("suspension boundary integration timed out"); process.exit(1); }, 20_000);
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
try {
  for (const boundary of ["before_model", "model_active", "unavailable"]) {
    const entered = deferred();
    const release = deferred();
    let requests = 0;
    let aborted = false;
    const store = createJournalStore();
    let agent;
    try {
      agent = await createFxAgent({
        backend, wasm, nativeAddon, apiKey: "fixture-key", model: "suspension/model",
        async fetch(_url, init) {
          if (init.method === "GET") return Response.json({ object: "list", data: [] });
          requests++;
          init.signal.addEventListener("abort", () => { aborted = true; });
          entered.resolve();
          await release.promise;
          return new Response('data: {"type":"text-delta","delta":"finished"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', { headers: { "content-type": "text/event-stream" } });
        },
        ...(boundary === "unavailable" ? {} : store.options()),
      });
      if (boundary === "unavailable") await assert.rejects(agent.suspend(), /journal.*onEntry/);
      else assert.equal(await agent.suspend(), null);
      const turn = agent.prompt("finish with text", { requestId: "boundary-request" });
      const observed = Promise.allSettled([turn.result, (async () => { for await (const _ of turn) {} })()]);
      // Native reader and worker are concurrent: only the WASM pre-start boundary
      // is deterministic. Native exercises the provider-active path here too.
      if (boundary !== "before_model" || backend !== "wasm") await entered.promise;
      if (boundary === "unavailable") {
        await assert.rejects(agent.suspend(), /journal.*onEntry/);
        assert.equal((await agent.status()).state, "running");
        release.resolve();
        assert.equal((await turn.result).stopReason, "end_turn");
      } else {
        const suspended = agent.suspend();
        const preStart = boundary === "before_model" && backend === "wasm";
        const beforeAcknowledgement = await agent.status();
        assert.equal(beforeAcknowledgement.idle, preStart);
        if (preStart) assert.equal(beforeAcknowledgement.lastSeq, 0, "unacknowledged admission was presented as durable");
        assert.equal(aborted, false, "suspension aborted the active provider");
        release.resolve();
        const status = await suspended;
        assert.equal(status.idle, !preStart);
        if (preStart) {
          await assert.rejects(turn.result, { name: "PendingTurnError" });
          assert.equal(status.pendingTurn.awaiting, "model");
        } else assert.equal((await turn.result).stopReason, "stop");
        assert.equal(requests, preStart ? 0 : 1);
        // Normal transport cleanup may abort its signal after EOF. Assert the
        // meaningful boundary while work was outstanding in the other tests.
      }
      const outcomes = await observed;
      const expectedStatus = boundary === "before_model" && backend === "wasm" ? "rejected" : "fulfilled";
      assert.deepEqual(outcomes.map(result => result.status), [expectedStatus, expectedStatus]);
      await agent.close(); agent = null;
    } finally { release.resolve(); await agent?.close().catch(() => {}); store.close(); }
  }
  console.log(`${backend} suspension boundary integration passed: pre-start, final response, missing sink`);
} finally {
  clearTimeout(watchdog);
}
