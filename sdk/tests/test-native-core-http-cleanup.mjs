#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { setImmediate as nextLoop } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../node.js";

const apiKey = "http-cleanup-fixture-key";
const modelId = "native/http-cleanup-model";
const catalogUrl = "https://ai-gateway.vercel.sh/coding-agent/v1/models";
const addon = resolve(process.argv[2] || fileURLToPath(new URL("../../zig-out/lib/libfx.node", import.meta.url)));
const native = createRequire(import.meta.url)(addon);
assert.equal(typeof native.coreFetchDisposition, "function", "rebuild libfx.node with coreFetchDisposition before running this suite");
const eofDelayMs = 30;
const cleanupBoundMs = 500; // 100 ms policy budget plus scheduling allowance.
const realFetch = globalThis.fetch; // All agents share Node's default TCP pool.
const sse = (value) => `data: ${typeof value === "string" ? value : JSON.stringify(value)}\n\n`;
const textFrame = (delta) => sse({ type: "text-delta", delta });
const finishFrame = (reason) => sse({ type: "finish", finishReason: { unified: reason, raw: reason } });
const successFrames = textFrame("OK") + finishFrame("stop") + sse("[DONE]");
function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  void promise.catch(() => {});
  return { promise, resolve, reject };
}
const serverFailure = deferred();
async function bounded(promise, label, ms = 2000) {
  let timer;
  try {
    return await Promise.race([promise, serverFailure.promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label}: exceeded ${ms} ms`)), ms); })]);
  } finally { clearTimeout(timer); }
}
const requests = [], results = [], catalogCounts = [];
const agents = new Set(), socketIds = new WeakMap();
let clientPosts = 0, serverPosts = 0, nextSocketId = 0, currentCase;
function plan(mode, input = currentCase) {
  const record = { id: requests.length + 1, mode, input, text: "", aborts: 0,
    posted: deferred(), firstText: deferred(), aborted: deferred(), closed: deferred() };
  requests.push(record);
  return record;
}
const check = (record, expectation) => `request ${record.id} (${record.mode}): ${expectation}`;
function endAfterDelay(record, tail = "") {
  assert.ok(record.response, check(record, "server must have accepted the POST"));
  assert.equal(record.response.writableEnded, false, check(record, "HTTP EOF must still be withheld"));
  record.endTimer = setTimeout(() => { record.endAt = performance.now(); record.response.end(tail); }, eofDelayMs);
}
const server = createServer((request, response) => {
  void serve(request, response).catch((error) => { serverFailure.reject(error); response.destroy(); });
});
server.on("connection", (socket) => { socketIds.set(socket, ++nextSocketId); });
async function serve(request, response) {
  assert.equal(request.method, "POST");
  assert.equal(request.url, "/chat");
  const record = requests[serverPosts++];
  assert.ok(record, "unexpected HTTP POST");
  record.socketId = socketIds.get(request.socket);
  record.response = response;
  response.once("close", () => { clearTimeout(record.endTimer); record.closed.resolve(); });
  let body = "";
  for await (const chunk of request) body += chunk.toString("utf8");
  assert.ok(!body.includes(apiKey), check(record, "credentials must not appear in model payloads"));
  const payload = JSON.parse(body);
  if (record.mode === "tool-step") assert.ok(payload.tools?.some((tool) => tool.name === "lookup"), "lookup must be advertised");
  else if (record.mode === "tool-result") assert.ok(body.includes("value:alpha"), "the second POST must include the tool result");
  else assert.ok(payload.tools == null || payload.tools.length === 0, "no native tools must be advertised");
  record.frames = record.mode === "active" ? textFrame("PARTIAL") : record.mode === "tool-step"
    ? sse({ type: "tool-call", toolCallId: "cleanup_lookup", toolName: "lookup", input: { key: "alpha" } }) + finishFrame("tool-calls") + sse("[DONE]")
    : successFrames;
  response.writeHead(200, { "content-type": "text/event-stream" });
  record.wireAt = performance.now();
  response.write(record.frames);
  record.posted.resolve();
}
await new Promise((done, fail) => { server.once("error", fail); server.listen(0, "127.0.0.1", done); });
const gatewayChatUrl = `http://127.0.0.1:${server.address().port}/chat`;
async function newTurn(record, extra = {}) {
  const agentIndex = catalogCounts.push(0) - 1;
  const agent = await bounded(createFxEngine({
    backend: "native", nativeAddon: addon, apiKey, model: modelId, gatewayChatUrl,
    fetch(input, init) {
      if (init.method === "GET") {
        assert.equal(String(input), catalogUrl, "only the injected catalog GET is allowed");
        assert.equal(++catalogCounts[agentIndex], 1, "each fresh agent may resolve its catalog once");
        return Promise.resolve(Response.json({ object: "list", data: [{ id: modelId, type: "language", tags: ["tool-use"] }] }));
      }
      assert.equal(String(input), gatewayChatUrl, "no external network request is allowed");
      assert.equal(init.method, "POST");
      const posted = requests[clientPosts++];
      assert.ok(posted, "unexpected client POST");
      posted.signal = init.signal;
      assert.equal(init.signal.aborted, false, check(posted, "POST must start with a live signal"));
      init.signal.addEventListener("abort", () => {
        posted.aborts++; posted.abortAt = performance.now(); posted.aborted.resolve();
      }, { once: true });
      return realFetch(input, init); // Preserve the real Response and default dispatcher.
    },
    ...extra,
  }), "fresh native agent initialization");
  agents.add(agent);
  const turn = agent.prompt(record.input);
  const reading = (async () => {
    for await (const update of turn) {
      if (update.type !== "text_delta") continue;
      record.text += update.delta;
      if (record.firstTextAt !== undefined) continue;
      record.firstTextAt = performance.now();
      assert.equal(record.response?.writableEnded, false, check(record, "first text must arrive before HTTP EOF"));
      record.firstText.resolve();
    }
  })();
  void reading.catch((error) => record.firstText.reject(error));
  return { agent, turn, reading };
}
async function completedTurn(turn, record, reading) {
  record.result = await bounded(turn.result, check(record, "model result before HTTP EOF"));
  record.resultAt = performance.now();
  await bounded(reading, check(record, "event iterator before HTTP EOF"));
  assert.equal(record.result.stopReason, "end_turn", check(record, "model must succeed"));
  assert.equal(record.text, "OK", check(record, "exact streamed model text"));
  assert.equal(record.response.writableEnded, false, check(record, "completion must not depend on HTTP EOF"));
  assert.equal(record.aborts, 0, check(record, "no premature successful signal abort"));
}
async function closedAgent(agent, closing = agent.close()) {
  assert.equal(await bounded(closing, "native agent.close cleanup", cleanupBoundMs), undefined);
  agents.delete(agent);
  await nextLoop(); // Let the shared fetch pool take its ordinary idle/reuse turn.
}
async function drainedAgent(agent, record) {
  const started = performance.now(), closing = agent.close();
  endAfterDelay(record);
  await closedAgent(agent, closing);
  await bounded(record.closed.promise, check(record, "successful drain must reach HTTP EOF"), cleanupBoundMs);
  assert.equal(record.aborts, 0, check(record, "successful close must never abort its fetch signal"));
  assert.equal(record.signal.aborted, false);
  assert.equal(record.response.writableEnded, true);
  return performance.now() - started;
}
function passed(name, details) {
  results.push({ name, ...details });
  console.log(`PASS ${name}: ${JSON.stringify(details)}`);
}
try {
  currentCase = "coherent disposition across native completion between legacy reads";
  {
    const record = plan("split-read"), wire = Buffer.from(successFrames), held = [];
    const textBytes = Buffer.byteLength(textFrame("OK")), sleeper = new Int32Array(new SharedArrayBuffer(4));
    let pushedBytes = 0, released = false, handle;
    const stats = record.interleaving = { dispositionReads: 0, consumedReads: 0, activeReads: 0, forcedSplitReads: 0, destroyed: 0 };
    const pendingFinish = (fetchHandle) => fetchHandle === handle && !released && pushedBytes === wire.length;
    function releaseFinish(core, fetchHandle) {
      assert.equal(fetchHandle, handle, "completion must target the exact POST handle");
      assert.equal(native.pushCoreFetchResponse(core, fetchHandle, Buffer.concat(held)), 1);
      released = true;
      held.length = 0;
      // JS cannot deliver EOF here. Wait only for the native worker to retire.
      const deadline = performance.now() + cleanupBoundMs;
      while (native.coreFetchActive(core, fetchHandle)) {
        assert.ok(performance.now() < deadline, "native retirement must finish within the bounded getter wait");
        Atomics.wait(sleeper, 0, 0, 1);
      }
      assert.equal(native.coreFetchDisposition(core, fetchHandle), 2, "normal retirement must retain consumed disposition");
    }
    const wrapped = Object.assign(Object.create(native), {
      takeCoreFetch(core) {
        const fetch = native.takeCoreFetch(core);
        if (fetch) {
          const request = JSON.parse(fetch.request.toString("utf8"));
          if (request.method === "POST") {
            assert.equal(request.url, gatewayChatUrl);
            assert.ok(Number.isInteger(request.handle) && request.handle > 0, "target a positive exact POST handle");
            handle = request.handle;
          }
        }
        return fetch;
      },
      pushCoreFetchResponse(core, fetchHandle, bytes) {
        if (fetchHandle !== handle) return native.pushCoreFetchResponse(core, fetchHandle, bytes);
        assert.equal(native.coreFetchDisposition(core, fetchHandle), 1, "withheld finish must keep the POST active");
        assert.deepEqual(bytes, wire.subarray(pushedBytes, pushedBytes + bytes.length), "only real loopback bytes may be forwarded");
        const prefix = Math.min(bytes.length, Math.max(0, textBytes - pushedBytes));
        if (prefix) assert.equal(native.pushCoreFetchResponse(core, fetchHandle, bytes.subarray(0, prefix)), 1);
        if (prefix < bytes.length) held.push(Buffer.from(bytes.subarray(prefix)));
        pushedBytes += bytes.length;
        return 1;
      },
      coreFetchConsumed(core, fetchHandle) {
        stats.consumedReads++;
        const prior = native.coreFetchDisposition(core, fetchHandle) === 2;
        // Hold finish until the old getter reads false after text was pushed,
        // then retire before returning false to its separate active read.
        if (!prior && pendingFinish(fetchHandle)) { stats.forcedSplitReads++; releaseFinish(core, fetchHandle); }
        return prior;
      },
      coreFetchActive(core, fetchHandle) {
        stats.activeReads++;
        return native.coreFetchActive(core, fetchHandle);
      },
      coreFetchDisposition(core, fetchHandle) {
        if (fetchHandle === handle) stats.dispositionReads++;
        if (pendingFinish(fetchHandle)) releaseFinish(core, fetchHandle);
        return native.coreFetchDisposition(core, fetchHandle);
      },
      destroyCore(core) { stats.destroyed++; return native.destroyCore(core); },
    });
    const { agent, turn, reading } = await newTurn(record, { nativeAddon: wrapped });
    await completedTurn(turn, record, reading);
    assert.equal(released, true, "the real finish frames must cross the native completion gate");
    assert.equal(pushedBytes, wire.length);
    await drainedAgent(agent, record);
    assert.ok(stats.dispositionReads > 0, "the SDK must observe the POST's coherent disposition");
    assert.equal(stats.consumedReads, 0, "the new path, including close, must never call the obsolete getter");
    assert.equal(stats.activeReads, 0, "the new path must not split a coherent observation");
    assert.equal(stats.forcedSplitReads, 0, "only the old implementation enters the interleaving trap");
    assert.equal(stats.destroyed, 1, "close must release the wrapped native core exactly once");
    passed("coherent disposition interleaving", { posts: 1, ...stats, signalAborts: record.aborts });
  }
  currentCase = "30 fresh agents, delayed EOF, shared TCP pool";
  let sharedSocketId, maxCloseMs = 0;
  for (let index = 0; index < 30; index++) {
    const record = plan("success", `cleanup success ${index + 1}`);
    const { agent, turn, reading } = await newTurn(record);
    await bounded(record.firstText.promise, check(record, "first streamed text before EOF"));
    await completedTurn(turn, record, reading);
    maxCloseMs = Math.max(maxCloseMs, await drainedAgent(agent, record));
    sharedSocketId ??= record.socketId;
    assert.equal(record.socketId, sharedSocketId, check(record, "all 30 fresh agents must reuse the same request.socket"));
  }
  passed("delayed EOF socket reuse", { requests: 30, socketId: sharedSocketId, signalAborts: 0, maxCloseMs });
  for (const operation of ["turn.cancel", "agent.close"]) {
    currentCase = `${operation} while a live POST is unfinished`;
    const record = plan("active"), { agent, turn, reading } = await newTurn(record);
    await bounded(record.firstText.promise, check(record, "unfinished response text"));
    const cancelAt = performance.now();
    let closing;
    if (operation === "turn.cancel") turn.cancel();
    else closing = agent.close();
    assert.equal(record.signal.aborted, true, check(record, `${operation} must synchronously abort the client signal`));
    assert.equal(record.aborts, 1, check(record, "exactly one abort event"));
    record.result = await bounded(turn.result, "cancelled turn result", cleanupBoundMs);
    await bounded(reading, "cancelled event iterator", cleanupBoundMs);
    assert.equal(record.result.stopReason, "cancelled");
    assert.equal(record.text, "PARTIAL");
    await closedAgent(agent, closing);
    await bounded(record.closed.promise, "server must observe cancellation", cleanupBoundMs);
    assert.equal(record.response.writableEnded, false, "cancellation must not wait for server EOF");
    passed(operation, { signalAborts: record.aborts, abortMs: record.abortAt - cancelAt });
  }
  currentCase = "successful model, HTTP tail never reaches EOF";
  {
    const record = plan("stalled-tail"), { agent, turn, reading } = await newTurn(record);
    await completedTurn(turn, record, reading);
    const closeAt = performance.now();
    await closedAgent(agent);
    assert.equal(record.aborts, 1, "the 100 ms cleanup timer must abort a never-ending tail");
    assert.ok(record.abortAt - record.resultAt >= 50, "successful consumption must drain, not abort immediately");
    assert.equal(record.response.writableEnded, false);
    await bounded(record.closed.promise, "timer abort must close the server response", cleanupBoundMs);
    passed("never-EOF cleanup", { signalAborts: record.aborts, closeMs: performance.now() - closeAt, abortAfterResultMs: record.abortAt - record.resultAt });
  }
  currentCase = "consumed HTTP tail exceeds 64 KiB";
  {
    const record = plan("capped-tail"), { agent, turn, reading } = await newTurn(record);
    await completedTurn(turn, record, reading);
    const tail = `: ${"x".repeat(96 * 1024)}\n\n`;
    record.tailBytes = Buffer.byteLength(tail);
    record.tailAt = performance.now();
    record.response.write(tail);
    endAfterDelay(record); // Offer EOF before 100 ms so a timer-only fix cannot pass.
    const closing = agent.close();
    await bounded(record.aborted.promise, ">64 KiB tail must abort before the offered 30 ms EOF", cleanupBoundMs);
    assert.equal(record.response.writableEnded, false, "byte-limit abort must precede HTTP EOF");
    assert.equal(record.aborts, 1);
    await closedAgent(agent, closing);
    await bounded(record.closed.promise, "byte-limit abort must close the server response", cleanupBoundMs);
    passed("tail byte cap", { tailBytes: record.tailBytes, signalAborts: record.aborts, abortMs: record.abortAt - record.tailAt });
  }
  currentCase = "tool-step completion drains before the next POST";
  {
    const first = plan("tool-step"), second = plan("tool-result"), toolStarted = deferred();
    let toolCalls = 0;
    const { agent, turn, reading } = await newTurn(second, { tools: [{
      name: "lookup", description: "Look up a fixture value.",
      inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"], additionalProperties: false },
      execute(input, { signal }) {
        assert.equal(signal.aborted, false);
        assert.deepEqual(input, { key: "alpha" });
        toolCalls++; toolStarted.resolve();
        return "value:alpha";
      },
    }] });
    await bounded(toolStarted.promise, "host tool after finish(tool-calls)");
    assert.equal(first.aborts, 0, "tool completion is successful consumption, not cancellation");
    endAfterDelay(first, textFrame("STALE-FIRST-RESPONSE"));
    await bounded(second.posted.promise, "next POST after successful tool-step cleanup");
    assert.ok(first.endAt <= second.wireAt, "next POST must not overtake the first body's EOF");
    await completedTurn(turn, second, reading);
    await drainedAgent(agent, second);
    assert.equal(toolCalls, 1);
    assert.equal(first.aborts, 0);
    assert.equal(second.text, "OK", "late first-response text must not reach the next model step");
    passed("tool-step cleanup isolation", { posts: 2, toolCalls, signalAborts: 0 });
  }
  currentCase = "older addon without disposition keeps conservative abort";
  {
    const record = plan("legacy-addon");
    let activeReads = 0;
    const wrapped = Object.assign(Object.create(native), {
      coreFetchDisposition: undefined,
      coreFetchConsumed() { throw new Error("an older addon must not compose a split observation"); },
      coreFetchActive(core, handle) { activeReads++; return native.coreFetchActive(core, handle); },
    });
    const { agent, turn, reading } = await newTurn(record, { nativeAddon: wrapped });
    record.result = await bounded(turn.result, "legacy addon successful model result");
    await bounded(reading, "legacy addon event iterator");
    await bounded(record.aborted.promise, "legacy addon conservative fetch abort");
    assert.equal(record.result.stopReason, "end_turn");
    assert.equal(record.text, "OK");
    assert.ok(activeReads > 0, "missing disposition must use the existing active-only query");
    assert.equal(record.aborts, 1, "without authoritative consumption the old addon must abort, not infer success");
    assert.equal(record.response.writableEnded, false);
    await closedAgent(agent);
    await bounded(record.closed.promise, "legacy addon response release", cleanupBoundMs);
    passed("legacy addon fallback", { posts: 1, activeReads, signalAborts: record.aborts });
  }
  assert.equal(catalogCounts.length, 37, "every scenario must use a fresh agent");
  assert.deepEqual(catalogCounts, Array(37).fill(1), "ordinary model discovery must stay local and resolve once per agent");
  assert.equal(clientPosts, 38);
  assert.equal(serverPosts, clientPosts);
  console.log(`native core real HTTP cleanup passed: ${results.length} cases, ${serverPosts} POSTs, ${catalogCounts.length} fake catalog GETs, fake credentials only`);
} catch (error) {
  console.error("FIRST HTTP CLEANUP FAILURE", JSON.stringify({ case: currentCase, expectation: error.message, passed: results, clientPosts, serverPosts, catalogCounts,
    requests: requests.map(({ signal, response, posted, firstText, aborted, closed, endTimer, ...record }) => ({
      ...record, signalAborted: signal?.aborted, httpEnded: response?.writableEnded,
    })),
  }));
  throw error;
} finally {
  for (const record of requests) clearTimeout(record.endTimer);
  server.closeAllConnections(); // Release real bodies first so failed reads cannot hang teardown.
  for (const agent of agents) await bounded(agent.close().catch(() => {}), "failure teardown", cleanupBoundMs).catch(() => {});
  await new Promise((done) => server.close(done));
}
