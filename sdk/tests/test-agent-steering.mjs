#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";
import { createFxEngine as createCoreEngine, turnEndInputs } from "../fx-sdk.js";
import { testHooks } from "./hooks-fixture.mjs";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-steering.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = backend === "wasm"
  ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"))
  : undefined;
let modelRequests = 0;

const finish = (response, text) => {
  response.end([
    `data: ${JSON.stringify({ type: "text-delta", delta: text })}`,
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":2},"outputTokens":{"total":1}}}',
    "data: [DONE]",
    "",
  ].join("\n\n"));
};

const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "steering/model", type: "language" }] }));
      return;
    }

    modelRequests += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (modelRequests === 1) {
      response.write('data: {"type":"text-delta","delta":"before"}\n\n');
      setTimeout(() => {
        response.end([
          'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}',
          "data: [DONE]",
          "",
        ].join("\n\n"));
      }, 300);
      return;
    }
    if (modelRequests === 2) {
      assert.ok(body.includes("<user_steering>"), "next model step omitted the steering boundary");
      assert.ok(body.includes("focus on") && body.includes("tests"), "next model step omitted steering text");
      assert.ok(body.includes("before"), "next model step omitted in-flight assistant work");
      finish(response, "after");
      return;
    }
    if (modelRequests === 3) {
      assert.ok(body.includes("focus on") && body.includes("tests"), "checkpoint omitted applied steering");
      assert.ok(body.includes("after"), "checkpoint omitted the completed steered response");
      finish(response, "restored");
      return;
    }
    if (modelRequests === 4) {
      response.write('data: {"type":"text-delta","delta":"cancel-start"}\n\n');
      return;
    }
    assert.equal(modelRequests, 5, "unexpected extra model request");
    assert.ok(!body.includes("drop this steering"), "cancelled steering leaked into the next prompt");
    finish(response, "clean");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const options = (checkpoint) => ({
  ...(testHooks ? { hooks: testHooks } : {}),
  backend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  ...(checkpoint ? { checkpoint } : {}),
  fetch,
  apiKey: "steering-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "steering/model",
});

let agent;
try {
  agent = await createFxEngine(options());
  const turn = agent.prompt("start work");
  const events = [];
  let steered = null;
  for await (const event of turn) {
    events.push(event);
    if (!steered && event.type === "text_delta" && event.delta === "before") {
      steered = await turn.steer([
        { type: "text", text: "focus on" },
        { type: "text", text: "tests" },
      ]);
    }
  }
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.deepEqual(
    events.filter((event) => event.type === "text_delta" || event.type === "user_message"),
    [
      { type: "text_delta", delta: "before" },
      // The steer shows where it joined the turn, with its id.
      { type: "user_message", text: "focus on\ntests", id: steered.id },
      { type: "text_delta", delta: "after" },
    ],
  );
  await assert.rejects(turn.steer("too late"), /no prompt is running/);

  const checkpoint = await agent.checkpoint();
  await agent.close();
  agent = await createFxEngine(options(checkpoint));
  const restored = agent.prompt("continue saved work");
  let restoredText = "";
  for await (const event of restored) if (event.type === "text_delta") restoredText += event.delta;
  assert.equal((await restored.result).stopReason, "end_turn");
  assert.equal(restoredText, "restored");

  const cancelled = agent.prompt("cancel this work");
  let cancellationSent = false;
  for await (const event of cancelled) {
    if (!cancellationSent && event.type === "text_delta" && event.delta === "cancel-start") {
      cancellationSent = true;
      await cancelled.steer("drop this steering");
      cancelled.cancel();
    }
  }
  assert.equal((await cancelled.result).stopReason, "cancelled");

  const clean = agent.prompt("start cleanly");
  let cleanText = "";
  for await (const event of clean) if (event.type === "text_delta") cleanText += event.delta;
  assert.equal((await clean.result).stopReason, "end_turn");
  assert.equal(cleanText, "clean");
  assert.equal(modelRequests, 5);
  console.log(`${backend} mid-turn steering integration passed`);
} finally {
  await agent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}

// The read of stored inputs before a turn ends, on WebAssembly: the
// `fx_take_inputs` import awaits the runtime's `takeInputs`. A cancel ends the
// wait on a running turn's read. A turn that is no longer current can take no
// steer, so it reads nothing and never waits, whatever the read would do.
if (backend === "wasm") {
  let handler;
  let exit;
  let promptId = null;
  let takeInputs;
  let reads = 0;
  const runtime = {
    exited: new Promise((resolveExit) => { exit = resolveExit; }),
    setLineHandler(value) { handler = value; },
    write(data) {
      const message = JSON.parse(data);
      const deliver = (value) => queueMicrotask(() => handler(value));
      if (message.method === "initialize") deliver({ id: message.id, result: {} });
      if (message.method === "libfx/new") deliver({ id: message.id, result: { sessionId: "session" } });
      // The core answers the prompt when the test says.
      if (message.method === "session/prompt") promptId = message.id;
    },
    abortHostEffects() {},
    closeStdin() { exit(0); },
  };
  const engine = await createCoreEngine({
    apiKey: "steering-key",
    runtimeFactory: (runtimeOptions) => {
      takeInputs = runtimeOptions.takeInputs;
      return runtime;
    },
    // A read of the store that never answers.
    [turnEndInputs]: () => {
      reads += 1;
      return new Promise(() => {});
    },
  });
  const settles = (promise) => Promise.race([
    promise.then(() => "settled", () => "settled"),
    new Promise((resolveWait) => setTimeout(() => resolveWait("waiting"), 100)),
  ]);
  let answered = false;
  const answer = () => {
    if (answered || promptId === null) return;
    answered = true;
    handler({ id: promptId, result: { stopReason: "cancelled" } });
  };
  try {
    assert.equal(await settles(takeInputs()), "settled", "with no turn running, the read waits");
    assert.equal(reads, 0, "with no turn running, the store was read");
    const turn = engine.prompt("read before the end");
    while (promptId === null) await new Promise((resolveWait) => setTimeout(resolveWait, 5));
    const running = takeInputs();
    assert.equal(await settles(running), "waiting", "the running turn's read did not wait on the store");
    assert.equal(reads, 1);
    turn.cancel();
    assert.equal(await settles(running), "settled", "the cancel did not end the running turn's read");
    // Cancelled, and the core has not answered its prompt yet.
    assert.equal(await settles(takeInputs()), "settled", "a cancelled turn's read waits on the store");
    assert.equal(reads, 1, "a cancelled turn read the store");
    answer();
    assert.equal((await turn.result).stopReason, "cancelled");
    assert.equal(await settles(takeInputs()), "settled", "after the turn, the read waits");
    assert.equal(reads, 1, "after the turn, the store was read");
  } finally {
    answer();
    await engine.close().catch(() => {});
  }
  console.log("wasm turn-end read waits only for a running turn");
}
