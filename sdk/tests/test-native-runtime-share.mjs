#!/usr/bin/env node
// TEST-11, SEC-1: 64 or more native runtimes for one agent don't keep another
// agent's turn off the native backend. While the process's runtimes are
// contended no agent holds more than its share (src/napi_runtime_shares.zig):
// the busy agent's extra turns run on WebAssembly, and without JSPI they fail
// with LIBFX_NATIVE_LIMIT naming the limit, while the other agent's turn runs
// natively. Engines that fail to start or close early give their runtimes
// back.
//
//   node sdk/tests/test-native-runtime-share.mjs
//
// With JSPI and zig-out/bin/fx-core.wasm, as under Bun or with
// --experimental-wasm-jspi, it also checks the WebAssembly overflow.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const nativeAddon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")).catch(() => null);
const runtimes = 64;
const model = "sdk/share-model";
const modelCatalog = [{ id: model, type: "language", tags: ["tool-use"] }];

const sse = (text) => new Response(
  [
    `data: ${JSON.stringify({ type: "text-delta", delta: text })}\n\n`,
    `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" } })}\n\n`,
    "data: [DONE]\n\n",
  ].join(""),
  { headers: { "content-type": "text/event-stream" } },
);

// A tenant: an agent whose model answers every request at once, or, while
// `held`, only once released, so each of its turns keeps its engine.
function tenant(name, { held = false } = {}) {
  const requests = [];
  const waiting = [];
  const events = [];
  const agent = createFxAgent({
    name,
    durability: memory(),
    backend: "native",
    nativeAddon,
    ...(wasm ? { wasm } : {}),
    apiKey: `${name}-key`,
    model,
    modelCatalog,
    fetch: async (_url, init = {}) => {
      requests.push(init.method ?? "POST");
      if (held) await new Promise((resolve) => waiting.push(resolve));
      return sse(`${name} answered`);
    },
    onEvent: (event) => { if (event.type === "runtime.fallback") events.push(event); },
  });
  return {
    agent,
    requests,
    fallbacks: events,
    release() { for (const resolve of waiting.splice(0)) resolve(); },
  };
}

async function until(predicate, label, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

const prompts = (agent, count) => Array.from({ length: count }, (_, index) => agent.session().prompt(`hold ${index}`));

// Engines that fail to start, and engines closed before their first turn,
// give their runtimes back: an agent alone still gets all but one.
{
  const bad = { backend: "native", nativeAddon, apiKey: "bad-key", model, modelCatalog, checkpoint: new Uint8Array([1, 2, 3]) };
  for (let index = 0; index < runtimes + 4; index += 1) {
    await assert.rejects(createFxEngine(bad), (error) => error.message.includes("Invalid or non-fresh libfx checkpoint"));
  }
  const engines = [];
  const fallbacks = [];
  for (let index = 0; index < runtimes - 1; index += 1) {
    engines.push(await createFxEngine({
      backend: "native",
      nativeAddon,
      apiKey: "engine-key",
      model,
      modelCatalog,
      onEvent: (event) => { if (event.type === "runtime.fallback") fallbacks.push(event); },
    }));
  }
  assert.deepEqual(fallbacks, [], "engines outside an agent, as one agent alone, run 63 natively");
  await Promise.all(engines.map((engine) => engine.close()));
}

// Without JSPI an agent's turn beyond its share fails, naming the native
// limit, and another agent's turn still runs natively.
{
  const savedSuspending = WebAssembly.Suspending;
  const savedPromising = WebAssembly.promising;
  Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: undefined });
  Object.defineProperty(WebAssembly, "promising", { configurable: true, value: undefined });
  try {
    assert.equal(supportsJspi(), false);
    const acme = tenant("acme", { held: true });
    const evil = tenant("evilcorp");
    const ends = prompts(acme.agent, runtimes).map((turn) => turn.result);
    const settled = [];
    for (const result of ends) void result.then((value) => settled.push(value));
    await until(() => acme.requests.length + settled.length >= runtimes, "acme's 64 turns holding or ended");

    const during = await evil.agent.session().prompt("hello").result;
    assert.equal(during.stopReason, "end_turn", `evilcorp's turn runs while acme holds its share: ${JSON.stringify(during)}`);
    assert.equal(evil.requests.length, 1);

    assert.equal(acme.requests.length, runtimes - 1, "63 of acme's turns hold native runtimes");
    assert.equal(settled.length, 1);
    const [refused] = settled;
    assert.equal(refused.stopReason, "error", "acme's 64th turn ends with an error");
    assert.equal(refused.error.code, "LIBFX_NATIVE_LIMIT");
    assert.match(refused.error.message, /share of the 64 native runtimes/);
    assert.match(refused.error.message, /--experimental-wasm-jspi/);

    acme.release();
    const results = await Promise.all(ends);
    assert.equal(results.filter((result) => result.stopReason === "end_turn").length, runtimes - 1);
    await Promise.all([acme.agent.close(), evil.agent.close()]);
  } finally {
    Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: savedSuspending });
    Object.defineProperty(WebAssembly, "promising", { configurable: true, value: savedPromising });
  }
}

// With JSPI an agent's turns beyond its share run on WebAssembly, with a
// diagnostic, and another agent's turn runs natively.
if (supportsJspi() && wasm) {
  const acme = tenant("acme-wasm", { held: true });
  const evil = tenant("evilcorp-wasm");
  const held = prompts(acme.agent, runtimes + 2);
  const settled = [];
  for (const turn of held) void turn.result.then((value) => settled.push(value));
  await until(() => acme.requests.length + settled.length >= runtimes + 2, "acme's 66 turns holding or ended");
  const during = await evil.agent.session().prompt("hello").result;
  assert.equal(during.stopReason, "end_turn", `evilcorp's turn runs while acme holds its share: ${JSON.stringify(during)}`);
  assert.deepEqual(evil.fallbacks, [], "evilcorp's turn ran natively");
  assert.deepEqual(settled, [], "every one of acme's turns runs");
  assert.equal(acme.fallbacks.length, 3, "acme's 3 turns beyond its 63 run on WebAssembly");
  for (const event of acme.fallbacks) {
    assert.equal(event.backend, "wasm");
    assert.equal(event.code, "LIBFX_NATIVE_LIMIT");
    assert.match(event.message, /share of the 64 native runtimes/);
  }
  acme.release();
  const results = await Promise.all(held.map((turn) => turn.result));
  assert.ok(results.every((result) => result.stopReason === "end_turn"), JSON.stringify(results.filter((result) => result.stopReason !== "end_turn")));
  await Promise.all([acme.agent.close(), evil.agent.close()]);
  console.log("native runtime shares passed, with the WebAssembly overflow");
} else {
  console.log("native runtime shares passed; the WebAssembly overflow needs JSPI and zig-out/bin/fx-core.wasm");
}
