#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";
import { retryAfterSeconds } from "../fetch-cleanup.js";

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
  const chunks = [
    encoded.encode('data: {"type":"text-delta","delta":"recovered once"}\n\n'),
    encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'),
    encoded.encode("data: [DONE]\n\n"),
  ];
  let chunkIndex = 0;
  return new Response(new ReadableStream({
    async pull(controller) {
      if (chunkIndex > 0) await new Promise((resolveWait) => setTimeout(resolveWait, 300));
      controller.enqueue(chunks[chunkIndex++]);
      if (chunkIndex === chunks.length) controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const agent = await createFxEngine({
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
  const activity = events.filter((event) => event.type === "transport.activity" && event.attempt === 3);
  assert.ok(activity.length >= 2, "streaming model response chunks must produce periodic liveness events");
  assert.ok(activity.every((event) => event.chunkBytes > 0));
  assert.ok(activity.at(-1).totalBytes > activity[0].totalBytes, "liveness byte counts must be cumulative per attempt");
  console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent transport retry passed`);
} finally {
  await agent.close();
}

const cancelEvents = [];
let cancelFetchCalls = 0;
let fetchStartedResolve;
const fetchStarted = new Promise((resolveStarted) => { fetchStartedResolve = resolveStarted; });
const cancelledAgent = await createFxEngine({
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
const retryBoundaryAgent = await createFxEngine({
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

const unavailable = (seconds) => new Response(JSON.stringify({ error: { message: "provider temporarily unavailable" } }), {
  status: 503,
  headers: { "content-type": "application/json", "retry-after": String(seconds) },
});
const finalAnswer = (text) => new Response(new ReadableStream({
  start(controller) {
    controller.enqueue(encoded.encode(`data: {"type":"text-delta","delta":"${text}"}\n\n`));
    controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
    controller.enqueue(encoded.encode("data: [DONE]\n\n"));
    controller.close();
  },
}), { status: 200, headers: { "content-type": "text/event-stream" } });

// Both hosts read Retry-After as native fx does: digits only, capped at int32.
for (const [value, seconds] of [
  [null, -1], ["", -1], [" 5 ", 5], ["0", 0], ["-5", -1], ["+5", -1], ["5.0", -1],
  ["Wed, 21 Oct 2026 07:28:00 GMT", -1], ["99999999999", 0x7fffffff],
]) {
  const headers = new Headers(value === null ? {} : { "retry-after": value });
  assert.equal(retryAfterSeconds(headers), seconds, `Retry-After ${JSON.stringify(value)}`);
}

// Both hosts pass a 503's Retry-After to fx, which waits that long rather
// than its own one-second first step.
const postedAt = [];
const retryAfterAgent = await createFxEngine({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  fetch: async (_url, init) => {
    if (init.method === "GET") return catalogResponse();
    postedAt.push(performance.now());
    return postedAt.length === 1 ? unavailable(3) : finalAnswer("waited as asked");
  },
  apiKey: "transport-retry-after-key",
  model: "transport-retry/model",
});
try {
  const turn = retryAfterAgent.prompt("wait as the gateway asks");
  let output = "";
  for await (const event of turn) if (event.type === "text_delta") output += event.delta;
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(output, "waited as asked");
  assert.equal(postedAt.length, 2);
  const gap = postedAt[1] - postedAt[0];
  assert.ok(gap >= 2_900, `the resend must wait the 3 s Retry-After asked for, waited ${Math.round(gap)} ms`);
} finally {
  await retryAfterAgent.close();
}
console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent honored Retry-After`);

// Cancel during a retry wait ends the turn at once and sends nothing more,
// however long the wait was.
let waitPosts = 0;
let firstFailure;
const failedOnce = new Promise((resolveFailed) => { firstFailure = resolveFailed; });
const waitCancelAgent = await createFxEngine({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  fetch: async (_url, init) => {
    if (init.method === "GET") return catalogResponse();
    waitPosts += 1;
    firstFailure();
    return unavailable(8);
  },
  apiKey: "transport-wait-cancel-key",
  model: "transport-retry/model",
});
try {
  const turn = waitCancelAgent.prompt("cancel while waiting to retry");
  await failedOnce;
  await new Promise((resolveWait) => setTimeout(resolveWait, 300));
  const cancelledAt = performance.now();
  turn.cancel();
  assert.equal((await turn.result).stopReason, "cancelled");
  const settled = performance.now() - cancelledAt;
  assert.ok(settled < 1_000, `cancel during an 8 s wait must end the turn at once, took ${Math.round(settled)} ms`);
  assert.equal(waitPosts, 1, "a cancelled wait must not resend");
} finally {
  await waitCancelAgent.close();
}
console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent cancel during a retry wait ended the turn at once`);
