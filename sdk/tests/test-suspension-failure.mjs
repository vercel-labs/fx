#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createJournalStore } from "./fixtures/journal-store.mjs";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] || "native";
const wasm = backend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined;
const nativeAddon = new URL("../../zig-out/lib/libfx.node", import.meta.url);
const watchdog = setTimeout(() => { console.error("suspension failure integration timed out"); process.exit(1); }, 20_000);
try {
  for (const failure of ["before_write", "lost_ack", "accepted_void"]) {
    const store = createJournalStore();
    let agent;
    let requests = 0;
    let effects = 0;
    let suspension;
    try {
      agent = await createFxAgent({
        ...store.options(),
        backend, wasm, nativeAddon, apiKey: "fixture-key", model: "suspension/model",
        async fetch(_url, init) {
          if (init.method === "GET") return Response.json({ object: "list", data: [] });
          requests++;
          return new Response([
            { type: "tool-call", toolCallId: "effect", toolName: "effect", input: {} },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
          ].map(event => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
        },
        tools: [{ name: "effect", description: "fixture effect", inputSchema: { type: "object", properties: {} },
          execute(_input, { signal }) {
            effects++;
            // Do not await suspension from an active tool: it must settle first.
            suspension = agent.suspend();
            void suspension.catch(() => {});
            assert.equal(signal.aborted, false);
            return "settled-effect";
          },
        }],
        async onEntry(entry) {
          if (entry.kind === "tool_result" && failure === "before_write") throw new Error("fixture write failed");
          await store.options().onEntry(entry);
          if (entry.kind === "tool_result" && failure === "lost_ack") throw new Error("fixture ack lost");
          // onEntry resolves void after durable storage; no return marker is required.
        },
      });
      const turn = agent.prompt("execute effect", { requestId: "suspension-failure" });
      try { for await (const _ of turn) {} } catch {}
      if (failure === "accepted_void") {
        await assert.rejects(turn.result, { name: "PendingTurnError" });
        assert.equal((await suspension).pendingTurn.awaiting, "model");
        assert.equal((await agent.status()).idle, false);
      } else {
        await assert.rejects(turn.result, { name: "PersistenceUncertain" });
        await assert.rejects(suspension, { name: "PersistenceUncertain" });
        await assert.rejects(agent.status(), { name: "PersistenceUncertain" });
        await assert.rejects(agent.checkpoint(), { name: "PersistenceUncertain" });
        assert.throws(() => agent.resume(), { name: "PersistenceUncertain" });
        assert.throws(() => agent.prompt("retry", { requestId: "retry" }), { name: "PersistenceUncertain" });
        await assert.rejects(agent.abandon(), { name: "PersistenceUncertain" });
      }
      assert.equal(requests, 1, "suspension or failed durability ack allowed another provider request");
      assert.equal(effects, 1);
      assert.equal(store.read().at(-1).kind, failure === "before_write" ? "model_step" : "tool_result");
      await agent.close(); agent = null;
    } finally { await agent?.close().catch(() => {}); store.close(); }
  }
  console.log(`${backend} suspension failure integration passed: failed writes fence recovery; durable void acknowledgement permits suspension`);
} finally {
  clearTimeout(watchdog);
}
