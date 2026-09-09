#!/usr/bin/env node
// Bridge unit tests: the real JavaScript SDK with a controlled ACP transport.
// These do not load Zig or prove native/Wasm execution or crash recovery.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import {
  createFxAgent, JournalConflict, PersistenceUncertain, RequestConflict, PendingTurnError,
} from "../fx-sdk.js";

const digest = (value) => createHash("sha256").update(value).digest("hex");
function envelope(seq, kind, fields) {
  const bytes = Buffer.from(JSON.stringify({ v: 1, kind, ...fields }));
  const hash = createHash("sha256").update(`${seq}\n${kind}\n`).update(bytes).digest("hex");
  return { seq, kind, bytes, hash };
}
const inputJson = JSON.stringify({ text: "hello", images: [] });
const start = envelope(1, "turn_start", {
  namespace: "s", turnId: "t", userMessageId: "u", requestId: "r",
  inputHash: digest(inputJson), inputJson, model: "test/model", runtimeTurnId: "1",
});
const step = envelope(2, "model_step", {
  turnId: "t", messageId: "m", generationId: "g", final: true,
  completion: { content: "hello" }, calls: [],
});
const success = { ok: true, stopReason: "stop" };
const end = envelope(3, "turn_end", { turnId: "t", result: success });
const wire = (entry) => ({ ...entry, bytes: Buffer.from(entry.bytes).toString("base64") });
const nextTask = () => new Promise(setImmediate);
function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function collect(turn) {
  const events = [];
  for await (const event of turn) events.push(event);
  return events;
}
function fixture({ version = 1, failRestoreAppend = false } = {}) {
  let handler;
  let options;
  let ended = false;
  let id = 1000;
  let status = { idle: true, lastSeq: 0, pendingTurn: null };
  const exited = deferred();
  const controls = new Map();
  const requests = [];
  const respond = (request, result, error) => handler({ id: request.id, ...(error ? { error } : { result }) });
  const runtime = {
    exited: exited.promise,
    setLineHandler(value) { handler = value; },
    write(line) {
      const request = JSON.parse(line);
      if (!request.method) {
        controls.get(request.id)?.resolve(request.result);
        controls.delete(request.id);
        return;
      }
      requests.push(request);
      if (request.method === "initialize") queueMicrotask(() => respond(request, { _meta: { libfxJournalVersion: version } }));
      if (request.method === "libfx/new") queueMicrotask(() => respond(request, { sessionId: "s" }));
      if (["libfx/journal/restore", "libfx/journal/restore_begin", "libfx/journal/restore_append", "libfx/journal/restore_finish"].includes(request.method)) {
        queueMicrotask(() => respond(request, {}, failRestoreAppend && request.method === "libfx/journal/restore_append" ? { message: "JournalConflict: transfer rejected" } : undefined));
      }
      if (request.method === "libfx/status") queueMicrotask(() => respond(request, status));
      if (request.method === "libfx/suspend") queueMicrotask(() => respond(request, {}));
    },
    closeStdin() { ended = true; exited.resolve(0); },
    abortHostEffects() {},
    abort(error) { this.error = error; ended = true; exited.resolve(1); },
  };
  return {
    requests, respond,
    setStatus(value) { status = value; },
    get options() { return options; },
    get ended() { return ended; },
    factory: async (value) => { options = value; return runtime; },
    update: (update) => handler({ method: "session/update", params: { sessionId: "s", update } }, Buffer.byteLength(JSON.stringify(update))),
    append(entry) {
      const acknowledgement = deferred();
      controls.set(++id, acknowledgement);
      handler({ id, method: "libfx/journal_append", params: { sessionId: "s", entry: wire(entry) } });
      return acknowledgement.promise;
    },
    finish(result = success, extra = {}) {
      respond(requests.find((request) => request.method === "session/prompt"), { journalResult: result, ...extra });
    },
  };
}

await test("journal options reject partial and legacy persistence before runtime loading", async () => {
  for (const invalid of [
    { checkpoint: new Uint8Array() }, { onCheckpoint() {} }, { journal: [] },
    { onEntry() {} }, { journal: null, onEntry() {} }, { journal: [], onEntry: 0 },
    { journal: [], onEntry() {}, checkpoint: new Uint8Array() },
  ]) {
    let loaded = false;
    await assert.rejects(createFxAgent({ apiKey: "test", runtimeFactory() { loaded = true; }, ...invalid }), TypeError);
    assert.equal(loaded, false);
  }
});

await test("journal negotiation rejects an incompatible core before creating a session", async () => {
  const f = fixture({ version: 0 });
  await assert.rejects(createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() {} }), /version 1/);
  assert.equal(f.requests.some((request) => request.method === "libfx/new"), false);
});

await test("durability gates projection adoption and live retries share one execution", async () => {
  const f = fixture();
  const gate = deferred();
  let agent;
  let callbackStatus;
  agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [],
    async onEntry(entry) {
      if (entry.kind === "turn_start") {
        callbackStatus = await agent.status();
        await gate.promise;
        entry.bytes.fill(0);
      }
    },
  });
  const turn = agent.prompt("hello", { requestId: "r" });
  const drain = collect(turn);
  const acknowledgement = f.append(start);
  await nextTask();
  assert.deepEqual(callbackStatus, { idle: true, lastSeq: 0, pendingTurn: null });
  let acknowledged = false;
  void acknowledgement.then(() => { acknowledged = true; });
  await nextTask();
  assert.equal(acknowledged, false);
  gate.resolve();
  assert.deepEqual(await acknowledgement, { durable: true });
  assert.equal((await agent.status()).lastSeq, 1);
  await f.update({ sessionUpdate: "libfx/journal_generation", key: { turnId: "t", messageId: "m", generationId: "g" } });
  await f.update({ sessionUpdate: "agent_message_chunk", content: { text: "hel" } });
  const retry = agent.prompt("hello", { requestId: "r" });
  const retryDrain = collect(retry);
  assert.throws(() => agent.prompt("changed", { requestId: "r" }), RequestConflict);
  await f.update({ sessionUpdate: "agent_message_chunk", content: { text: "lo" } });
  await f.append(step);
  await f.append(end);
  f.finish();
  assert.deepEqual(await turn.result, success);
  const events = await drain;
  const attached = await retryDrain;
  await retry.result;
  assert.deepEqual(events.map((event) => event.type), ["turn_start", "text_delta", "text_delta", "turn_end"]);
  assert.deepEqual(attached.map((event) => event.type), ["text_delta", "turn_end"]);
  assert.deepEqual(events[1].key, { turnId: "t", messageId: "m", generationId: "g" });
  assert.equal(events[1].ordinal, 1);
  assert.equal(attached[0].ordinal, 2);
  assert.equal(f.requests.filter((request) => request.method === "session/prompt").length, 1);
  await agent.close();
  assert.equal(f.ended, true);
});

await test("persistence uncertainty preserves its cause and fences later operations", async () => {
  const f = fixture();
  const cause = new Error("disk uncertain");
  const agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() { throw cause; },
  });
  const turn = agent.prompt("hello", { requestId: "r" });
  const stream = collect(turn);
  void stream.catch(() => {});
  assert.deepEqual(await f.append(start), { durable: false });
  f.respond(f.requests.find((request) => request.method === "session/prompt"), null, { message: "Unrelated core error" });
  await assert.rejects(turn.result, (error) => error instanceof PersistenceUncertain && error.cause === cause);
  await assert.rejects(stream, PersistenceUncertain);
  assert.throws(() => agent.prompt("hello", { requestId: "r" }), PersistenceUncertain);
  await agent.close();
});

await test("restore replays validated entries without invoking persistence or prompting", async () => {
  const f = fixture();
  let callbacks = 0;
  const agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [start, step, end], onEntry() { callbacks++; },
  });
  assert.equal(callbacks, 0);
  assert.equal(f.requests.filter((request) => request.method === "libfx/journal/restore").length, 3);
  assert.equal(f.requests.filter((request) => request.method === "session/prompt").length, 0);
  await agent.close();
});

await test("suspension resolves status while its unfinished turn rejects PendingTurnError", async () => {
  const f = fixture();
  const agent = await createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() {} });
  const turn = agent.prompt("hello", { requestId: "r" });
  void turn.result.catch(() => {});
  await f.append(start);
  const pending = {
    idle: false, lastSeq: 1,
    pendingTurn: { turnId: "t", requestId: "r", lastSeq: 1, awaiting: "model" },
  };
  const suspension = agent.suspend();
  await nextTask();
  f.setStatus(pending);
  f.respond(f.requests.find((request) => request.method === "session/prompt"), { stopReason: "suspended", journalStatus: pending });
  await assert.rejects(turn.result, (error) => error instanceof PendingTurnError && error.pendingTurn.turnId === "t");
  assert.deepEqual(await suspension, pending);
  assert.equal(f.requests.some((request) => request.method === "libfx/abandon"), false);
  await agent.close();
});

await test("cancelled entered executors retain cleanup ownership until their promises settle", async () => {
  const f = fixture();
  const entered = deferred();
  const release = deferred();
  const agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() {},
    tools: [{
      name: "lookup", description: "lookup", inputSchema: { type: "object" }, replay: "safe",
      async execute(input, context) {
        assert.deepEqual(input, { key: "one" });
        assert.equal(context.callId, "c1");
        assert.equal(context.requestId, "r");
        assert.equal(context.recovering, false);
        entered.resolve(context);
        await release.promise;
        return { content: "settled" };
      },
    }],
  });
  const turn = agent.prompt("hello", { requestId: "r" });
  await f.append(start);
  await f.append(envelope(2, "model_step", {
    turnId: "t", messageId: "m", generationId: "g", final: false, completion: { content: "select" },
    calls: [{ callId: "c1", providerId: "p1", name: "lookup", argumentsJson: '{"key":"one"}', replay: "safe" }],
  }));
  const execution = f.options.hostToolExecutor("lookup", { key: "one" }, "s", {
    turnId: "t", callId: "c1", requestId: "r", recovering: false,
  });
  const context = await entered.promise;
  turn.cancel();
  assert.equal(context.signal.aborted, true);
  const result = {
    ok: false, reason: "interrupted", retryable: false, message: "outcome unknown",
    pendingTool: { callId: "c1", name: "lookup", input: { key: "one" } },
  };
  await f.append(envelope(3, "turn_end", { turnId: "t", result }));
  f.finish(result);
  let settled = false;
  void turn.result.then(() => { settled = true; });
  const close = agent.close();
  await nextTask();
  assert.equal(settled, false);
  assert.equal(f.ended, false);
  release.resolve();
  assert.equal((await execution).executionOutcome, "uncertain");
  assert.deepEqual(await turn.result, result);
  await close;
  assert.equal(f.ended, true);
});

await test("bounded output resumes when its consumer advances", async () => {
  const f = fixture();
  const agent = await createFxAgent({ apiKey: "test", runtimeFactory: f.factory });
  const turn = agent.prompt("hello");
  const chunk = { sessionUpdate: "agent_message_chunk", content: { text: "x".repeat(4096) } };
  let pressured;
  for (let index = 0; index < 270; index++) {
    const pending = f.update(chunk);
    if (pending) { pressured = pending; break; }
  }
  assert.ok(pressured, "bounded output must apply backpressure");
  let released = false;
  void pressured.then(() => { released = true; });
  await nextTask();
  assert.equal(released, false);
  const iterator = turn[Symbol.asyncIterator]();
  await iterator.next();
  await pressured;
  assert.equal(released, true);
  await iterator.return();
  f.respond(f.requests.find((request) => request.method === "session/prompt"), { stopReason: "cancelled" });
  await turn.result;
  await agent.close();
});

await test("a core result without a durable turn end is rejected", async () => {
  const f = fixture();
  const agent = await createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() {} });
  const turn = agent.prompt("hello", { requestId: "r" });
  f.finish();
  await assert.rejects(turn.result, JournalConflict);
  await agent.close();
});

await test("completed retry events come from core replay without new persistence callbacks", async () => {
  const f = fixture();
  let callbacks = 0;
  const agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [start, step, end], onEntry() { callbacks++; },
  });
  const turn = agent.prompt("hello", { requestId: "r" });
  const drain = collect(turn);
  for (const event of [
    { type: "turn_start", turnId: "t", messageId: "u" },
    { type: "text_delta", delta: "hello", key: { turnId: "t", messageId: "m", generationId: "g" }, ordinal: 1 },
    { type: "turn_end", turnId: "t", result: success },
  ]) await f.update({ sessionUpdate: "libfx/journal_event", event });
  f.finish(success, { journalReplay: true, requestId: "r" });
  await turn.result;
  assert.equal((await drain).length, 3);
  assert.equal(callbacks, 0);
  await agent.close();
});

await test("an already-aborted journal prompt rejects without admitting a request", async () => {
  const f = fixture();
  const agent = await createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [], onEntry() {} });
  const turn = agent.prompt("hello", { requestId: "r", signal: AbortSignal.abort() });
  await assert.rejects(turn.result, { name: "AbortError" });
  assert.equal(f.requests.some((request) => request.method === "session/prompt"), false);
  await agent.close();
});

await test("checkpoint returns its exact acknowledged journal entry", async () => {
  const f = fixture();
  const gate = deferred();
  const checkpoint = envelope(1, "checkpoint", { lastIncludedSeq: 0, records: [] });
  const agent = await createFxAgent({
    apiKey: "test", runtimeFactory: f.factory, journal: [],
    async onEntry() { await gate.promise; },
  });
  const pending = agent.checkpoint();
  let settled = false;
  void pending.then(() => { settled = true; });
  const acknowledgement = f.append(checkpoint);
  await nextTask();
  assert.equal(settled, false);
  gate.resolve();
  assert.deepEqual(await acknowledgement, { durable: true });
  f.respond(f.requests.find((request) => request.method === "libfx/checkpoint"), { entry: wire(checkpoint) });
  const result = await pending;
  assert.equal(result.kind, "checkpoint");
  assert.equal(result.seq, checkpoint.seq);
  assert.equal(result.hash, checkpoint.hash);
  assert.ok(result.bytes instanceof Uint8Array);
  assert.deepEqual(Buffer.from(result.bytes), checkpoint.bytes);
  await agent.close();
});


function paddedCheckpoint(byteLength) {
  const prefix = JSON.stringify({ v: 1, kind: "checkpoint", lastIncludedSeq: 0, records: [] });
  const bytes = Buffer.from(prefix + " ".repeat(byteLength - Buffer.byteLength(prefix)));
  const hash = createHash("sha256").update("1\ncheckpoint\n").update(bytes).digest("hex");
  return { seq: 1, kind: "checkpoint", bytes, hash };
}

await test("restore transfer keeps small entries direct and streams the 32 MiB boundary", async () => {
  for (const byteLength of [128, 32 * 1024 * 1024]) {
    const entry = paddedCheckpoint(byteLength);
    const f = fixture();
    f.setStatus({ idle: true, lastSeq: 1 });
    const agent = await createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [entry], onEntry() { assert.fail("restore wrote host storage"); } });
    try {
      assert.deepEqual(await agent.status(), { idle: true, lastSeq: 1 });
      const restored = f.requests.filter(request => request.method.startsWith("libfx/journal/restore"));
      for (const request of restored) assert.ok(Buffer.byteLength(JSON.stringify(request)) + 1 < 8 * 1024 * 1024, "restore exceeded unchanged ACP input frame bound");
      if (byteLength <= 4 * 1024 * 1024) {
        assert.deepEqual(restored.map(request => request.method), ["libfx/journal/restore"]);
        assert.deepEqual(restored[0].params.entry, wire(entry));
      } else {
        assert.equal(restored[0].method, "libfx/journal/restore_begin");
        assert.deepEqual(restored[0].params, { sessionId: "s", entry: { seq: 1, kind: "checkpoint", hash: entry.hash }, byteLength });
        assert.equal(restored.at(-1).method, "libfx/journal/restore_finish");
        const received = Buffer.alloc(byteLength);
        let offset = 0;
        for (const request of restored.slice(1, -1)) {
          assert.equal(request.method, "libfx/journal/restore_append");
          assert.equal(request.params.sessionId, "s");
          assert.equal(request.params.offset, offset);
          const chunk = Buffer.from(request.params.bytes, "base64");
          assert.ok(chunk.length > 0 && chunk.length <= 64 * 1024);
          chunk.copy(received, offset);
          offset += chunk.length;
        }
        assert.equal(offset, byteLength);
        assert.deepEqual(received, entry.bytes);
      }
      assert.equal(f.requests.some(request => request.method === "session/prompt"), false);
    } finally { await agent.close(); }
  }
});

await test("restore transfer failure closes the incomplete owner without finish or authority use", async () => {
  const f = fixture({ failRestoreAppend: true });
  const entry = paddedCheckpoint(4 * 1024 * 1024 + 1);
  await assert.rejects(createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [entry], onEntry() { assert.fail("restore wrote host storage"); } }), JournalConflict);
  assert.equal(f.ended, true);
  assert.deepEqual(f.requests.filter(request => request.method.startsWith("libfx/journal/restore")).map(request => request.method), ["libfx/journal/restore_begin", "libfx/journal/restore_append"]);
  assert.equal(f.requests.some(request => ["session/prompt", "libfx/status", "libfx/abandon", "libfx/resume", "libfx/checkpoint"].includes(request.method)), false);
});

await test("restore transfer rejects entries above 32 MiB before beginning a transfer", async () => {
  const f = fixture();
  const entry = { seq: 1, kind: "checkpoint", bytes: new Uint8Array(32 * 1024 * 1024 + 1), hash: "0".repeat(64) };
  await assert.rejects(createFxAgent({ apiKey: "test", runtimeFactory: f.factory, journal: [entry], onEntry() {} }), /32 MiB/);
  assert.equal(f.ended, true);
  assert.equal(f.requests.some(request => request.method.startsWith("libfx/journal/restore")), false);
});
