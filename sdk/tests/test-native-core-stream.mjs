#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const events = [];
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
    if (requestCount === 1) {
      firstResponse = response;
      response.on("close", () => {
        events.push("first-connection-close");
        firstConnectionClosedResolve();
      });
      response.write('data: {"type":"text-delta","delta":"native one"}\n\n');
      response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}\n\n');
      events.push("first-finish-sent");
      return;
    }
    assert.equal(requestCount, 2, "only two Gateway requests are expected");
    response.write('data: {"type":"text-delta","delta":"native two"}\n\n');
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"}}}\n\n');
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
  let firstAbortResolve;
  const firstAbort = new Promise((resolveAbort) => { firstAbortResolve = resolveAbort; });
  agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    fetch(input, init) {
      fetchCalls += 1;
      if (fetchCalls === 1) {
        init.signal.addEventListener("abort", () => {
          events.push("first-abort");
          firstAbortResolve();
        }, { once: true });
      } else if (fetchCalls === 2) {
        events.push("second-fetch");
      }
      return fetch(input, init);
    },
    env: {
      AI_GATEWAY_API_KEY: "native-core-stream-key",
      FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${port}/chat`,
      FX_MODEL: "native/test-model",
    },
  });
  const session = await agent.createSession();
  const firstTurn = session.prompt("first native prompt");
  let firstText = "";
  for await (const update of firstTurn) {
    if (update.sessionUpdate === "agent_message_chunk" && !update.content.text.startsWith("[context]")) {
      firstText += update.content.text;
    }
  }
  assert.equal(firstText.trimEnd(), "native one");
  assert.equal((await firstTurn.result).stopReason, "end_turn");
  events.push("first-turn-complete");
  assert.equal(firstResponse.writableEnded, false, "prompt one must finish before [DONE] or EOF");

  const secondTurn = session.prompt("second native prompt");
  await Promise.race([
    Promise.any([firstAbort, firstConnectionClosed]),
    timeout("first response abort or connection close"),
  ]);
  let secondText = "";
  for await (const update of secondTurn) {
    if (update.sessionUpdate === "agent_message_chunk" && !update.content.text.startsWith("[context]")) {
      secondText += update.content.text;
    }
  }
  assert.equal(secondText.trimEnd(), "native two");
  assert.equal((await secondTurn.result).stopReason, "end_turn");
  assert.equal(fetchCalls, 2, "both prompts must use the Node-owned fetch option");
  const releaseEvents = [events.indexOf("first-abort"), events.indexOf("first-connection-close")]
    .filter((index) => index >= 0);
  assert.ok(releaseEvents.length > 0, "the first response must be aborted or closed");
  assert.ok(events.indexOf("second-fetch") > Math.min(...releaseEvents), "request two must start after response one releases the pump slot");
  await session.close();
  assert.equal(await agent.close(), 0);
  agent = null;
  console.log("native core stream passed: split terminal tail, matching abort, prompt reuse, and graceful close");
} finally {
  agent?.abort();
  firstResponse?.destroy();
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
