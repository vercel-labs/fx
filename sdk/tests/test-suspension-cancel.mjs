#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createJournalStore } from "./fixtures/journal-store.mjs";
import { createFxAgent } from "../node.js";
const backend = process.argv[2] || "native";
const store = createJournalStore();
const watchdog = setTimeout(() => { console.error("suspension cancellation integration timed out"); process.exit(1); }, 20_000);
let entered;
const toolEntered = new Promise(resolve => { entered = resolve; });
let calls = 0;
let agent;
try {
  agent = await createFxAgent({
    ...store.options(),
    backend,
    wasm: backend === "wasm" ? await readFile(new URL("../../zig-out/bin/fx-core.wasm", import.meta.url)) : undefined,
    nativeAddon: new URL("../../zig-out/lib/libfx.node", import.meta.url),
    apiKey: "fixture-key", model: "suspension/model",
    async fetch(_url, init) {
      if (init.method === "GET") return Response.json({ object: "list", data: [] });
      return new Response('data: {"type":"tool-call","toolCallId":"effect","toolName":"effect","input":{}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n', { headers: { "content-type": "text/event-stream" } });
    },
    tools: [{ name: "effect", description: "fixture effect", inputSchema: { type: "object", properties: {} },
      execute(_input, { signal }) {
        calls++;
        entered();
        return new Promise(resolve => signal.addEventListener("abort", () => resolve("cancelled-effect"), { once: true }));
      },
    }],

  });
  const turn = agent.prompt("execute effect", { requestId: "cancelled-request" });
  const drain = (async () => { try { for await (const _ of turn) {} } catch {} })();
  await toolEntered;
  turn.cancel();
  await drain;
  await assert.rejects(turn.result, /RecoveryRequired/);
  assert.equal(calls, 1);
  assert.equal((await agent.status()).pendingTurn.awaiting.tool.name, "effect");
  // Even a durable sink cannot clear the independent cancellation owner fence.
  await assert.rejects(agent.checkpoint(), /RecoveryRequired/i);
  await assert.rejects(agent.resume().result, /RecoveryRequired/i);
  await assert.rejects(agent.prompt("retry", { requestId: "retry" }).result, /RecoveryRequired/i);
  assert.equal(calls, 1, "cancelled uncertain tool was replayed");
  await agent.abandon();
  assert.equal((await agent.status()).idle, true);
  assert.equal(store.read().at(-1).kind, "turn_end");
  await assert.rejects(agent.prompt("retry after abandonment", { requestId: "after-abandon" }).result, /RecoveryRequired/);
  await agent.close(); agent = null;
  console.log(`${backend} suspension cancellation integration passed: core retains uncertain effects and blocks replay`);
} finally {
  await agent?.close().catch(() => {});
  store.close();
  clearTimeout(watchdog);
}
