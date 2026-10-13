#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

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
  let steered = false;
  for await (const event of turn) {
    events.push(event);
    if (!steered && event.type === "text_delta" && event.delta === "before") {
      steered = true;
      await turn.steer([
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
      { type: "user_message", text: "focus on\ntests" },
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
