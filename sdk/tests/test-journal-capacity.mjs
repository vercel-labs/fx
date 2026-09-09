#!/usr/bin/env node
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createFxAgent, createProjection } from "../node.js";

const backend = process.argv[2] ?? "native";
assert.ok(["native", "wasm"].includes(backend));
let entries = [];
let modelCalls = 0;
let summaries = 0;
const textBytes = 1024 * 1024;
const encoder = new TextEncoder();
const headers = { "content-type": "text/event-stream" };
const finish = 'data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n';

function response() {
  let chunk = 0;
  return new Response(new ReadableStream({
    pull(controller) {
      if (chunk++ < 16) {
        const event = { type: "text-delta", delta: "x".repeat(textBytes / 16) };
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
      } else {
        controller.enqueue(encoder.encode(finish));
        controller.close();
      }
    },
  }), { headers });
}

const options = {
  backend,
  ...(backend === "native"
    ? { nativeAddon: fileURLToPath(new URL("../../zig-out/lib/libfx.node", import.meta.url)) }
    : { wasm: new URL("../../zig-out/bin/fx-core.wasm", import.meta.url) }),
  apiKey: "test-key-not-a-secret",
  model: "test/capacity",
  tools: [{
    name: "unused",
    description: "Capacity fixture sentinel",
    inputSchema: { type: "object", properties: {} },
    execute() { throw new Error("No tools should execute"); },
  }],
  fetch: async (_input, init) => {
    if (init?.method === "GET") {
      return Response.json({ data: [{
        id: "test/capacity", type: "language", tags: ["tool-use"],
        context_window: 128000, max_tokens: 8192,
      }] });
    }
    modelCalls++;
    const body = JSON.parse(new TextDecoder().decode(init.body));
    // Keep provider history below the bridge limit while the journal grows.
    if (body.tools.length === 0) {
      summaries++;
      const event = {
        type: "text-delta",
        delta: "Earlier fixture responses were completed. Continue the requested task.",
      };
      return new Response(`data: ${JSON.stringify(event)}\n\n${finish}`, { headers });
    }
    return response();
  },
  onEntry(entry) { entries.push({ ...entry, bytes: entry.bytes.slice() }); },
};

async function settle(turn) {
  let bytes = 0;
  const result = turn.result.then(value => ({ value }), error => ({ error }));
  const events = (async () => {
    for await (const event of turn) {
      if (event.type === "text_delta") bytes += event.delta.length;
    }
  })().catch(error => error);
  const outcome = await result;
  const eventError = await events;
  return { ...outcome, bytes, eventError };
}

let agent = await createFxAgent({ ...options, journal: [] });
let completed = 0;
let refused = false;
let checkpoint;
try {
  for (let index = 0; index < 40; index++) {
    const beforeCalls = modelCalls;
    const beforeEntries = entries.length;
    const outcome = await settle(agent.prompt("Return the capacity fixture.", {
      requestId: `capacity-${index}`,
    }));
    if (outcome.error) {
      assert.equal(outcome.error.code, "JournalCapacityExceeded", JSON.stringify({
        error: String(outcome.error), completed, modelCalls, summaries,
      }));
      assert.equal(modelCalls, beforeCalls, "capacity refusal must precede model I/O");
      assert.equal(entries.length, beforeEntries, "capacity refusal must precede turn admission");
      refused = true;
      break;
    }
    assert.equal(outcome.eventError, undefined);
    assert.equal(outcome.value.ok, true);
    assert.equal(outcome.bytes, textBytes);
    completed++;
  }
  assert.ok(refused && completed > 0, "fixture must reach the real capacity boundary");
  assert.ok(summaries > 0, "fixture must exercise automatic context compaction");
  assert.equal((await agent.status()).idle, true);
  checkpoint = await agent.checkpoint();
  assert.equal(checkpoint.kind, "checkpoint");
  assert.equal(createProjection([checkpoint]).requests().size, completed);
} finally {
  await agent.close();
}

entries = [checkpoint];
agent = await createFxAgent({ ...options, journal: entries });
try {
  const beforeCalls = modelCalls;
  const replay = await settle(agent.prompt("Return the capacity fixture.", {
    requestId: "capacity-0",
  }));
  assert.equal(replay.eventError, undefined);
  assert.equal(replay.error, undefined);
  assert.equal(replay.value.ok, true);
  assert.equal(replay.bytes, textBytes);
  assert.equal(modelCalls, beforeCalls);
  assert.equal(entries.length, 1);
  console.log(JSON.stringify({
    backend, completed, modelCalls, summaries,
    checkpointBytes: checkpoint.bytes.length,
    replayBytes: replay.bytes,
    capacityRefusedBeforeIo: true,
  }));
} finally {
  await agent.close();
}
