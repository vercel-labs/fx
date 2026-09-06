#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const events = [];
const unicodeText = "\u{1f600}界".repeat(200_000);
let requestCount = 0;
let firstResponse;
let firstConnectionClosedResolve;
const firstConnectionClosed = new Promise((resolveClosed) => { firstConnectionClosedResolve = resolveClosed; });
const server = createServer((request, response) => {
  if (request.method !== "POST") {
    response.writeHead(404).end();
    return;
  }
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    requestCount += 1;
    const payload = JSON.parse(body);
    assert.ok(payload);
    assert.ok(payload.tools == null || payload.tools.length === 0, "N-API core must not advertise native tools");
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (requestCount >= 4) {
      response.end('data: {"type":"text-delta","delta":"x"}\n\n'.repeat(1000) +
        'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
      return;
    }
    if (requestCount === 1) {
      firstResponse = response;
      response.on("close", () => {
        events.push("first-connection-close");
        firstConnectionClosedResolve();
      });
      response.write('data: {"type":"text-delta","delta":"native one"}\n\n');
      response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n');
      events.push("first-finish-sent");
      return;
    }
    if (requestCount === 3) {
      response.end(`data: ${JSON.stringify({ type: "text-delta", delta: unicodeText })}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n`);
      return;
    }
    assert.equal(requestCount, 2, "unexpected Gateway request");
    response.write('data: {"type":"text-delta","delta":"native two"}\n\n');
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
  timer.unref();
});
let agent;
try {
  let fetchCalls = 0;
  let catalogCalls = 0;
  let firstAbortResolve;
  const firstAbort = new Promise((resolveAbort) => { firstAbortResolve = resolveAbort; });
  agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    async fetch(input, init) {
      if (init.method === "GET") {
        catalogCalls += 1;
        return Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] });
      }
      assert.equal(init.method, "POST");
      fetchCalls += 1;
      const first = fetchCalls === 1;
      if (first) {
        init.signal.addEventListener("abort", () => {
          events.push("first-abort");
          firstAbortResolve();
        }, { once: true });
      } else if (fetchCalls === 2) {
        events.push("second-fetch");
      }
      const response = await fetch(input, init);
      if (!first) return response;
      const reader = response.body.getReader();
      return new Response(new ReadableStream({
        async pull(controller) {
          try {
            const chunk = await reader.read();
            if (chunk.done) controller.close();
            else controller.enqueue(chunk.value);
          } catch (error) {
            // Cleanup can settle after the next prompt has already become ready.
            await new Promise((resolveWait) => setTimeout(resolveWait, 25));
            controller.error(error);
          }
        },
        cancel(reason) { return reader.cancel(reason); },
      }), { status: response.status, headers: response.headers });
    },
    apiKey: "native-core-stream-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "native/test-model",
  });
  const firstTurn = agent.prompt("first native prompt");
  let firstText = "";
  for await (const update of firstTurn) {
    if (update.type === "text_delta") {
      firstText += update.delta;
    }
  }
  assert.equal(firstText.trimEnd(), "native one");
  assert.equal((await firstTurn.result).stopReason, "end_turn");
  events.push("first-turn-complete");
  assert.equal(firstResponse.writableEnded, false, "prompt one must finish before [DONE] or EOF");

  const secondTurn = agent.prompt("second native prompt");
  await Promise.race([
    Promise.any([firstAbort, firstConnectionClosed]),
    timeout("first response abort or connection close"),
  ]);
  let secondText = "";
  await Promise.race([
    (async () => {
      for await (const update of secondTurn) {
        if (update.type === "text_delta") secondText += update.delta;
      }
    })(),
    timeout("second prompt after delayed first pump cleanup"),
  ]);
  assert.equal(secondText.trimEnd(), "native two");
  assert.equal((await secondTurn.result).stopReason, "end_turn");
  assert.equal(fetchCalls, 2, "both prompts must use the Node-owned fetch option");
  const releaseEvents = [events.indexOf("first-abort"), events.indexOf("first-connection-close")]
    .filter((index) => index >= 0);
  assert.ok(releaseEvents.length > 0, "the first response must be aborted or closed");
  assert.ok(events.indexOf("second-fetch") > Math.min(...releaseEvents), "request two must start after response one releases the pump slot");
  const unicodeTurn = agent.prompt("large Unicode response");
  let unicodeOutput = "";
  for await (const update of unicodeTurn) if (update.type === "text_delta") unicodeOutput += update.delta;
  assert.equal((await unicodeTurn.result).stopReason, "end_turn");
  assert.ok(unicodeOutput === unicodeText, "native drain boundaries must preserve every UTF-8 character");
  for (let batch = 0; batch < 20; batch++) {
    const burst = agent.prompt(`stream burst ${batch}`);
    let deltas = 0;
    await Promise.race([
      (async () => {
        for await (const event of burst) if (event.type === "text_delta") {
          assert.equal(event.delta, "x");
          deltas++;
        }
        assert.equal((await burst.result).stopReason, "end_turn");
      })(),
      timeout("stream burst readiness"),
    ]);
    assert.equal(deltas, 1000);
  }
  assert.equal(requestCount, 23);
  assert.equal(catalogCalls, 1, "the agent must reuse model metadata across prompts");
  assert.equal(await agent.close(), undefined);
  agent = null;
  console.log("native core stream passed: split terminal tail, matching abort, prompt reuse, and graceful close");
} finally {
  await agent?.close().catch(() => {});
  firstResponse?.destroy();
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
