#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
let modelRequests = 0;
let requestBodies = [];
const server = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[]}');
      return;
    }
    modelRequests += 1;
    requestBodies.push(body);
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (modelRequests > 1) {
      response.end('data: {"type":"text-delta","delta":"recovered"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
      return;
    }
    response.end('data: {"type":"tool-call","toolCallId":"cancel_1","toolName":"wait","input":{}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

async function withTimeout(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), 5000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function exerciseCancellation(settlement, closeBeforeSettle) {
  modelRequests = 0;
  requestBodies = [];
  let toolStartedResolve;
  const toolStarted = new Promise((resolveStarted) => { toolStartedResolve = resolveStarted; });
  let settleTool;
  let toolCalls = 0;
  let toolSignalAborted = false;
  const events = [];
  const unhandledRejections = [];
  const recordUnhandled = (error) => unhandledRejections.push(error);
  process.on("unhandledRejection", recordUnhandled);
  const controller = new AbortController();
  let agent;
  try {
    agent = await createFxAgent({
      backend,
      nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
      ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
      fetch(input, init) {
        const url = init.method === "GET" ? `http://127.0.0.1:${server.address().port}/models` : input;
        assert.equal(new URL(url).origin, `http://127.0.0.1:${server.address().port}`);
        return fetch(url, init);
      },
      traceWasi: process.env.LIBFX_TRACE_WASM === "1",
      onEvent(event) {
        events.push(event);
        const message = event.message;
        const beforeTool = backend === "native"
          ? message?.method === "libfx/tool_call"
          : message?.method === "session/update" && message.params?.update?.sessionUpdate === "tool_call";
        if (settlement === "before-start" && event.type === "acp.receive" && beforeTool) {
          controller.abort();
          toolStartedResolve();
        }
      },
      tools: [{
        name: "wait",
        description: "Wait until cancelled",
        inputSchema: { type: "object", properties: {} },
        execute(_input, { signal }) {
          toolCalls += 1;
          return new Promise((resolveTool, rejectTool) => {
            settleTool = () => settlement === "reject"
              ? rejectTool(new Error("late tool failure"))
              : resolveTool("late tool result");
            signal.addEventListener("abort", () => {
              toolSignalAborted = true;
              if (settlement === "cooperative") rejectTool(new DOMException("aborted", "AbortError"));
            }, { once: true });
            toolStartedResolve();
          });
        },
      }],
      apiKey: "cancel-key",
      gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
      model: "cancel/model",
    });
    const turn = agent.prompt("wait", { signal: controller.signal });
    const drain = (async () => { for await (const _event of turn) {} })();
    await withTimeout(toolStarted, "tool start");
    controller.abort();
    const poisoned = settlement !== "before-start";
    let turnSettled = false;
    const observed = Promise.allSettled([turn.result, drain]).then((results) => {
      turnSettled = true;
      return results;
    });
    let closeSettled = false;
    const closing = closeBeforeSettle ? agent.close().then(() => { closeSettled = true; }) : null;
    if (settlement === "resolve" || settlement === "reject") {
      await new Promise((resolveWait) => setTimeout(resolveWait, 25));
      assert.equal(turnSettled, false, "turn settled before its executor released resources");
      assert.equal(closeSettled, false, "close settled before its executor released resources");
      settleTool();
    }
    const [result, stream] = await withTimeout(observed, "cancelled turn and event stream");
    if (closing) await withTimeout(closing, "close after tool settlement");
    if (poisoned) {
      assert.equal(result.status, "rejected");
      assert.match(result.reason.message, /HostToolOutcomeUncertain/);
      assert.equal(stream.status, "rejected");
    } else {
      assert.equal(result.status, "fulfilled");
      assert.equal(result.value.stopReason, "cancelled");
      assert.equal(stream.status, "fulfilled");
    }
    assert.equal(toolCalls, settlement === "before-start" ? 0 : 1);
    assert.equal(toolSignalAborted, settlement !== "before-start");
    assert.equal(modelRequests, 1);

    if (poisoned && !closing) {
      assert.deepEqual(await agent.status(), { state: "blocked", canResume: false });
      await assert.rejects(agent.prompt("continue after cancellation").result, /uncertain/i);
      assert.throws(() => agent.resume(), /journal.*onEntry/);
      await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
      assert.equal(modelRequests, 1);
    } else if (!poisoned) {
      const followup = agent.prompt("continue after cancellation");
      let text = "";
      await withTimeout((async () => {
        for await (const event of followup) if (event.type === "text_delta") text += event.delta;
        assert.equal((await followup.result).stopReason, "end_turn");
      })(), "follow-up prompt");
      assert.equal(text, "recovered");
      assert.equal(modelRequests, 2);
    }
    assert.ok(requestBodies.every((body) => !body.includes("late tool result") && !body.includes("late tool failure")));

    const eventsBeforeSettle = events.length;
    if (!closing) await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
    const sendsBeforeSettle = events.filter((event) => event.type === "acp.send").length;
    settleTool?.();
    await new Promise((resolveWait) => setTimeout(resolveWait, 25));
    assert.deepEqual(unhandledRejections, []);
    assert.equal(events.filter((event) => event.type === "acp.send").length, sendsBeforeSettle);
    if (closeBeforeSettle) assert.equal(events.length, eventsBeforeSettle);
    else await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
    await withTimeout(agent.close(), "close");
    console.log(`${backend} host tool cancellation passed: ${settlement}, closeBeforeSettle=${closeBeforeSettle}`);
  } finally {
    settleTool?.();
    await withTimeout(agent?.close().catch(() => {}), "cleanup");
    process.off("unhandledRejection", recordUnhandled);
  }
}

try {
  await exerciseCancellation("cooperative", false);
  await exerciseCancellation("before-start", false);
  for (const settlement of ["resolve", "reject"]) {
    await exerciseCancellation(settlement, false);
    await exerciseCancellation(settlement, true);
  }
} finally {
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
