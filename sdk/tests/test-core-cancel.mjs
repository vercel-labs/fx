#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { strict as assert } from "node:assert";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-core-cancel.mjs");
  process.exit(2);
}

let fetchStartedResolve;
const fetchStarted = new Promise((resolve) => { fetchStartedResolve = resolve; });
let fetchAborted = false;
const stalledFetch = async (_url, init) => {
  let controller;
  const body = new ReadableStream({ start(value) { controller = value; } });
  init.signal.addEventListener("abort", () => {
    fetchAborted = true;
    controller.error(new DOMException("The operation was aborted", "AbortError"));
  }, { once: true });
  fetchStartedResolve();
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
};

const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
});

const agent = await Promise.race([
  createFxAgent({
  backend: "wasm",
    wasm: await readFile(wasmPath),
    fetch: stalledFetch,
    apiKey: "sdk-test-key",
  }),
  timeout("fx-core initialize"),
]);

const controller = new AbortController();
const turn = agent.prompt("wait forever", { signal: controller.signal });
await Promise.race([fetchStarted, timeout("stalled gateway fetch")]);
controller.abort();
const result = await Promise.race([turn.result, timeout("cancelled prompt")]);
if (result.stopReason !== "cancelled") throw new Error(`unexpected stop reason: ${result.stopReason}`);
if (!fetchAborted) throw new Error("AbortSignal did not abort the stalled fetch");

await agent.close();
console.log("core SDK stalled-fetch cancellation passed: AbortSignal stopped fetch and turn.result returned cancelled");

async function within(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), 2000); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

for (const stage of ["headers", "body", "late-body", "close"]) {
  let started;
  const catalogStarted = new Promise((resolveStarted) => { started = resolveStarted; });
  let release;
  let finishLateBody;
  let signal;
  let requests = 0;
  let lateBodyCancelled = false;
  let followingUp = false;
  const model = `sdk/catalog-cancel-${stage}`;
  const catalog = () => Response.json({ object: "list", data: [{ id: model, type: "language", tags: ["tool-use"] }] });
  const catalogAgent = await createFxAgent({
    backend: "wasm",
    wasm: await readFile(wasmPath),
    apiKey: "sdk-test-key",
    model,
    async fetch(_url, init) {
      requests += 1;
      if (followingUp) {
        if (init.method === "GET") return catalog();
        return new Response('data: {"type":"text-delta","delta":"recovered"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', { headers: { "content-type": "text/event-stream" } });
      }
      assert.equal(init.method, "GET");
      signal = init.signal;
      if (stage.endsWith("body")) {
        return new Response(new ReadableStream({
          start(body) {
            release = () => { try { body.close(); } catch {} };
            if (stage === "body") signal?.addEventListener("abort", () => body.error(new DOMException("Aborted", "AbortError")), { once: true });
          },
          pull() { started(); },
        }, { highWaterMark: 0 }));
      }
      // A host may settle after cancellation even when it receives the signal.
      return new Promise((resolveFetch) => {
        const response = new Response(new ReadableStream({
          start(body) { finishLateBody = () => { try { body.close(); } catch {} }; },
          cancel() { lateBodyCancelled = true; },
        }));
        release = () => resolveFetch(response);
        started();
      });
    },
  });
  const catalogTurn = catalogAgent.prompt("cancel the pending catalog lookup");
  try {
    await within(catalogStarted, `${stage} catalog start`);
    if (stage === "close") await within(catalogAgent.close(), "close during catalog lookup");
    else catalogTurn.cancel();
    assert.equal((await within(catalogTurn.result, `${stage} catalog cancellation`)).stopReason, "cancelled");
    assert.equal(signal?.aborted, true, "catalog fetch must receive the runtime AbortSignal");
    assert.equal(requests, 1, "cancellation must not retry the catalog fetch");
    release();
    await new Promise((resolveTask) => setTimeout(resolveTask, 0));
    if (!stage.endsWith("body")) assert.equal(lateBodyCancelled, true, "discard a response arriving after cancellation");
    if (stage !== "close") {
      followingUp = true;
      const followup = catalogAgent.prompt("continue after cancellation");
      let text = "";
      for await (const event of followup) if (event.type === "text_delta") text += event.delta;
      assert.equal((await followup.result).stopReason, "end_turn");
      assert.equal(text, "recovered");
    }
  } finally {
    release?.();
    finishLateBody?.();
    await catalogAgent.close();
  }
}
console.log("core SDK catalog cancellation passed: pending headers/body, late response, close, and follow-up");
