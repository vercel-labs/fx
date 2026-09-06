#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-transport-retry.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const encoded = new TextEncoder();
const events = [];
let fetchCalls = 0;
const catalogResponse = () => Response.json({ object: "list", data: [{ id: "transport-retry/model", type: "language" }] });
const fetchOnceThenSucceed = async (_url, init) => {
  if (init.method === "GET") return catalogResponse();
  assert.equal(init.method, "POST");
  fetchCalls += 1;
  if (fetchCalls === 1) throw new TypeError("injected host transport failure");
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"recovered once"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const agent = await createFxAgent({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  fetch: fetchOnceThenSucceed,
  apiKey: "transport-retry-key",
  model: "transport-retry/model",
  onEvent(event) { events.push(event); },
});

try {
  const turn = agent.prompt("recover one transport failure");
  let output = "";
  for await (const event of turn) if (event.type === "text_delta") output += event.delta;
  assert.equal(output, "recovered once", "the successful retry must publish output exactly once");
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(fetchCalls, 2, "libfx must make exactly one bounded retry");
  assert.deepEqual(
    events.filter((event) => event.type === "transport.start").map((event) => [event.method, event.attempt]),
    [["GET", 1], ["POST", 2], ["POST", 3]],
  );
  assert.deepEqual(
    events.filter((event) => event.type === "transport.error").map((event) => [event.attempt, event.error]),
    [[2, "TypeError"]],
  );
  assert.deepEqual(
    events.filter((event) => event.type === "transport.retry").map((event) => [event.attempt, event.nextAttempt]),
    [[2, 3]],
  );
  assert.deepEqual(
    events.filter((event) => event.type === "transport.response").map((event) => [event.attempt, event.status]),
    [[1, 200], [3, 200]],
  );
  console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent transport retry passed`);
} finally {
  await agent.close();
}

const cancelEvents = [];
let cancelFetchCalls = 0;
let fetchStartedResolve;
const fetchStarted = new Promise((resolveStarted) => { fetchStartedResolve = resolveStarted; });
const cancelledAgent = await createFxAgent({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  fetch: async (_url, init) => {
    if (init.method === "GET") return catalogResponse();
    assert.equal(init.method, "POST");
    cancelFetchCalls += 1;
    fetchStartedResolve();
    return new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
    });
  },
  apiKey: "transport-cancel-key",
  model: "transport-retry/model",
  onEvent(event) { cancelEvents.push(event); },
});

try {
  const turn = cancelledAgent.prompt("cancel without retrying");
  await fetchStarted;
  turn.cancel();
  assert.equal((await turn.result).stopReason, "cancelled");
  await new Promise((resolveWait) => setTimeout(resolveWait, 350));
  assert.equal(cancelFetchCalls, 1, "cancellation must not start a retry");
  assert.deepEqual(
    cancelEvents.filter((event) => event.type === "transport.start").map((event) => [event.method, event.attempt]),
    [["GET", 1], ["POST", 2]],
  );
} finally {
  await cancelledAgent.close();
}

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent cancellation stopped transport retry`);

const retryBoundaryEvents = [];
const retryBoundaryController = new AbortController();
let retryBoundaryFetchCalls = 0;
const retryBoundaryAgent = await createFxAgent({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  fetch(_url, init) {
    if (init.method === "GET") return catalogResponse();
    assert.equal(init.method, "POST");
    retryBoundaryFetchCalls += 1;
    throw new TypeError("injected retry-boundary transport failure");
  },
  apiKey: "transport-retry-boundary-key",
  model: "transport-retry/model",
  onEvent(event) {
    retryBoundaryEvents.push(event);
    if (event.type === "transport.retry") retryBoundaryController.abort();
  },
});

try {
  const turn = retryBoundaryAgent.prompt("cancel from the retry event", {
    signal: retryBoundaryController.signal,
  });
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(retryBoundaryFetchCalls, 1, "cancellation from transport.retry must prevent the second fetch");
  assert.deepEqual(
    retryBoundaryEvents.filter((event) => event.type === "transport.start").map((event) => [event.method, event.attempt]),
    [["GET", 1], ["POST", 2]],
  );
} finally {
  await retryBoundaryAgent.close();
}

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent retry-event cancellation stopped transport retry`);
