#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createProjection, readCheckpoint } from "../transcript.js";
import {
  decodeEntry, hashBytes, JournalConflict, parseJournalJson, PendingTurnError,
  PersistenceUncertain, RecoveryRequired, RequestConflict,
} from "../journal-codec.js";

const encoder = new TextEncoder();
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
function envelope(seq, kind, source) {
  const bytes = source instanceof Uint8Array ? source : encoder.encode(typeof source === "string" ? source : JSON.stringify(source));
  const hash = createHash("sha256").update(`${seq}\n${kind}\n`).update(bytes).digest("hex");
  return { seq, kind, bytes, hash };
}
function entry(seq, kind, fields) {
  return envelope(seq, kind, { v: 1, kind, ...fields });
}
function start(seq = 1, text = "hello", turnId = "turn-1", requestId = "request-1") {
  const inputJson = JSON.stringify({ text, images: [] });
  return entry(seq, "turn_start", {
    namespace: "session-1", turnId, userMessageId: `${turnId}:user`, requestId,
    inputHash: digest(encoder.encode(inputJson)), inputJson, model: "test/model", runtimeTurnId: "1",
  });
}
const call = (callId, replay = "blocked") => ({ callId, providerId: `provider-${callId}`, name: "lookup", argumentsJson: JSON.stringify({ key: callId }), replay });
const step = (seq, calls = [], options = {}) => entry(seq, "model_step", {
  turnId: "turn-1", messageId: `message-${seq}`, generationId: `generation-${seq}`,
  final: calls.length === 0, completion: { content: "Saved reply", usage: { input_tokens: 3, output_tokens: 2, reasoning_tokens: null } }, calls,
  ...options,
});
const result = (seq, callId, isError = false) => entry(seq, "tool_result", { turnId: "turn-1", callId, content: isError ? "ordinary failure" : "stored value", isError });
const end = (seq, value = { ok: true, stopReason: "stop" }) => entry(seq, "turn_end", { turnId: "turn-1", result: value });
const checkpoint = (seq, entries) => entry(seq, "checkpoint", { lastIncludedSeq: seq - 1, records: entries.map((item) => decodeEntry(item).body) });
const rejected = (fn) => assert.throws(fn, JournalConflict);

for (const [recorded, expected] of [
  [{ input_tokens: 3, output_tokens: 2, reasoning_tokens: null }, { inputTokens: 3, outputTokens: 2 }],
  [{ input_tokens: null, output_tokens: null }, {}],
]) {
  const entries = [start(), step(2), end(3, { ok: true, stopReason: "stop", usage: recorded })];
  const projection = createProjection(entries);
  assert.deepEqual(projection.requests().get("request-1").result, { ok: true, stopReason: "stop", usage: expected });
  assert.deepEqual(createProjection([checkpoint(4, entries)]).requests(), projection.requests());
  assert.deepEqual(decodeEntry(entries[2]).body.result.usage, recorded);
}

{
  const stopped = { ok: true, stopReason: "tool_limit" };
  const prefix = [start(), step(2, [call("first"), call("second")])];
  rejected(() => createProjection([start(), end(2, stopped)]));
  rejected(() => createProjection([...prefix, end(3, stopped)]));
  rejected(() => createProjection([...prefix, result(3, "first"), end(4, stopped)]));
  const entries = [...prefix, result(3, "first", true), result(4, "second"), end(5, stopped)];
  const projection = createProjection(entries);
  assert.equal(projection.transcript().messages[1].status, "complete");
  assert.deepEqual(readCheckpoint(checkpoint(6, entries).bytes), projection.transcript());
  const request = entry(5, "model_step", { phase: "request", turnId: "turn-1", messageId: "next", generationId: "next-generation", supersedesGenerationId: null, executionContext: {} });
  rejected(() => createProjection([...entries.slice(0, 4), request, end(6, stopped)]));
}

{
  const entries = [start(), step(2, [call("first")]), result(3, "first")];
  const p = createProjection(entries);
  const compact = (seq, count) => entry(seq, "model_step", {
    phase: "context", turnId: "turn-1", afterTurnCount: 1, afterStepCount: 1,
    summary: { kind: "compacted_summary", summary: "Saved first result", removed_turn_count: 0, compaction_count: 1 },
    retainedFrom: { turns: 0, tool_steps: 1, steering: 0 },
    activeThrough: { tool_steps: count, steering: 0 },
  });
  const before = p.transcript();
  entries.push(compact(4, 1));
  assert.deepEqual(p.apply(entries.at(-1)).delta, { messages: [] });
  assert.deepEqual(p.transcript(), before);
  rejected(() => p.preview(compact(5, 0)));
  rejected(() => p.preview(compact(5, 2)));
  for (const next of [step(5), end(6)]) { entries.push(next); p.apply(next); }
  assert.deepEqual(createProjection([checkpoint(7, entries)]).transcript(), p.transcript());
  assert.equal(p.transcript().messages[1].parts.filter(part => part.type === "tool_result").length, 1);
}

{
  const feedback = entry(3, "tool_result", {
    ...decodeEntry(result(3, "first")).body,
    persisted: { permission_feedback: ["Keep the existing file", "Run the second command"] },
  });
  const entries = [start(), step(2, [call("first"), call("second")]), feedback];
  const p = createProjection(entries);
  assert.deepEqual(p.transcript().messages.slice(2).map(message => [message.id, message.role, message.parts[0].text]), [
    ["first:feedback:1", "user", "Keep the existing file"],
    ["first:feedback:2", "user", "Run the second command"],
  ]);
  assert.deepEqual(p.apply(feedback).delta, { messages: [] });
  for (const next of [result(4, "second"), step(5), end(6)]) { p.apply(next); entries.push(next); }
  assert.deepEqual(createProjection([checkpoint(7, entries)]).transcript(), p.transcript());
  const invalid = entry(3, "tool_result", { ...decodeEntry(feedback).body, persisted: { permission_feedback: [42] } });
  rejected(() => createProjection(entries.slice(0, 2)).apply(invalid));
}

{
  const p = createProjection([start(), step(2)]);
  const guidance = entry(3, "model_step", {
    phase: "context", change: "steering", turnId: "turn-1", afterTurnCount: 1, afterStepCount: 1,
    prefix: null, retiredDraft: null, guidance: [{ id: "turn-1:steering:1", text: "New requirement" }],
  });
  const before = p.transcript();
  const candidate = p.preview(guidance);
  assert.deepEqual(p.transcript(), before);
  assert.deepEqual(candidate.completedDrafts, []);
  assert.equal(candidate.delta.messages[0].id, "turn-1:steering:1");
  p.apply(guidance);
  assert.deepEqual(p.apply(guidance).delta, { messages: [] });
  rejected(() => p.preview(end(4)));
  const reservation = entry(4, "model_step", {
    phase: "request", turnId: "turn-1", messageId: "next", generationId: "generation-next", executionContext: {},
  });
  p.apply(reservation);
  const more = entry(5, "model_step", {
    phase: "context", change: "steering", turnId: "turn-1", afterTurnCount: 1, afterStepCount: 1,
    prefix: { id: "turn-1:steering:2:assistant", text: "Interrupted thought" },
    retiredDraft: { turnId: "turn-1", messageId: "next", generationId: "generation-next" },
    guidance: [{ id: "turn-1:steering:2", text: "Keep going" }],
  });
  assert.deepEqual(p.apply(more).completedDrafts, [{ turnId: "turn-1", messageId: "next", generationId: "generation-next" }]);
  assert.deepEqual(p.transcript().messages.map(message => message.role), ["user", "assistant", "user", "assistant", "user"]);
  assert.equal(p.transcript().messages[1].status, "complete");
  const badId = entry(6, "model_step", { ...decodeEntry(more).body, guidance: [{ id: "turn-1:steering:2", text: "Duplicate" }] });
  rejected(() => p.preview(badId));
  const badBoundary = entry(6, "model_step", { ...decodeEntry(more).body, afterStepCount: 0 });
  rejected(() => p.preview(badBoundary));
}

{
  const providerCall = { ...call("provider"), provenance: "provider_executed", provider_result: '{"content":"stored"}' };
  const providerStep = step(2, [providerCall], { final: false, completion: { content: "Provider answer", finish_reason: "stop" } });
  const p = createProjection([start(), providerStep]);
  rejected(() => p.preview(end(3)));
  p.apply(result(3, "provider"));
  const completed = p.preview(end(4)).projection.transcript();
  assert.equal(completed.messages.length, 2);
  assert.equal(completed.messages[1].parts.filter((part) => part.type === "text").length, 1);
  p.apply(entry(4, "model_step", {
    phase: "request", turnId: "turn-1", messageId: "next-message", generationId: "next-generation", executionContext: {},
  }));
  rejected(() => p.preview(end(5)));
}

{
  const entries = [start(), step(2), end(3)];
  const context = entry(4, "model_step", {
    phase: "context", turnId: null, afterTurnCount: 1,
    summary: { kind: "compacted_summary", summary: "Saved context summary", removed_turn_count: 1, compaction_count: 1 },
    retainedFrom: { turns: 1, tool_steps: 0, steering: 0 },
  });
  const p = createProjection(entries);
  const before = p.transcript();
  const preview = p.preview(context);
  assert.deepEqual(preview.delta, { messages: [] });
  assert.deepEqual(preview.completedDrafts, []);
  assert.deepEqual(p.transcript(), before);
  assert.deepEqual(p.apply(context), { delta: { messages: [] }, completedDrafts: [] });
  assert.deepEqual(p.transcript(), before);
  assert.deepEqual(readCheckpoint(checkpoint(5, [...entries, context]).bytes), before);
  rejected(() => createProjection([...entries, entry(4, "model_step", { ...decodeEntry(context).body, afterTurnCount: 2 })]));
  rejected(() => createProjection([...entries, entry(4, "model_step", { ...decodeEntry(context).body, retainedFrom: { turns: -1, tool_steps: 0, steering: 0 } })]));
  rejected(() => createProjection([...entries, entry(4, "model_step", { ...decodeEntry(context).body, summary: { kind: "compacted_summary" } })]));
  const pending = createProjection([start(), step(2, [call("pending")])]);
  rejected(() => pending.preview(entry(3, "model_step", { ...decodeEntry(context).body, turnId: "turn-1" })));
}

// Request reservations acknowledge budget/authority without inventing a saved
// response. Retrying retires only its prior generation, including on replay.
{
  const reservation = (seq, generationId, supersedesGenerationId = null) => entry(seq, "model_step", {
    phase: "request", turnId: "turn-1", messageId: "reserved-message", generationId,
    supersedesGenerationId, executionContext: { recovery: { outstanding_reservation: true } },
  });
  const p = createProjection([start()]);
  const first = reservation(2, "attempt-one");
  const before = p.transcript();
  assert.deepEqual(p.apply(first), { delta: { messages: [] }, completedDrafts: [] });
  assert.deepEqual(p.transcript(), before);
  rejected(() => p.preview(reservation(3, "attempt-two", "unrelated")));
  const retry = reservation(3, "attempt-two", "attempt-one");
  const retired = [{ turnId: "turn-1", messageId: "reserved-message", generationId: "attempt-one" }];
  assert.deepEqual(p.apply(retry).completedDrafts, retired);
  assert.deepEqual(p.apply(retry).completedDrafts, retired);
  rejected(() => p.preview(step(4, [], { messageId: "reserved-message", generationId: "attempt-one" })));
  const complete = step(4, [], { messageId: "reserved-message", generationId: "attempt-two" });
  assert.deepEqual(p.apply(complete).completedDrafts, [{ turnId: "turn-1", messageId: "reserved-message", generationId: "attempt-two" }]);
  assert.equal(p.transcript().messages.length, 2);
  p.apply(end(5));
  assert.deepEqual(readCheckpoint(checkpoint(6, [start(), first, retry, complete, end(5)]).bytes), p.transcript());
}

// Invalid arguments remain exact inspectable evidence; nested JSON still has
// the same bounds as a top-level journal body.
{
  const malformed = { ...call("bad"), argumentsJson: "{broken" };
  const p = createProjection([start(), step(2, [malformed])]);
  assert.equal(p.transcript().messages[1].parts.find((part) => part.type === "tool_call").input, "{broken");
  const deep = { ...call("deep"), argumentsJson: "[".repeat(65) + "0" + "]".repeat(65) };
  rejected(() => createProjection([start(), step(2, [deep])]));
}

// Independent SHA-256 references cover the padding boundary and multiblock input.
for (const text of ["", "abc", "雪 😀", "x".repeat(55), "x".repeat(56), "x".repeat(64), "x".repeat(65), "a".repeat(100000)]) {
  const bytes = encoder.encode(text);
  assert.equal(hashBytes(bytes), digest(bytes));
}
assert.equal(hashBytes(encoder.encode("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

// Frozen wire vectors are also asserted in execution_journal_codec.zig.
for (const [seq, kind, bytes, hash] of [
  [1, "turn_start", '{"v":1,"kind":"turn_start"}', "20509104dca7f4ebf2c58e4cf3e125241a4e31e7f833a499db9a1ee9797df7c4"],
  [Number.MAX_SAFE_INTEGER, "turn_end", ' { "kind":"turn_end", "v":1, "text":"done\\n" }\n', "a5f0c334c827b27d1bedc8f737d5b4c4c00d0074629eb169a80888e5c67f5080"],
]) {
  const decoded = decodeEntry({ seq, kind, bytes: encoder.encode(bytes), hash });
  assert.equal(decoded.hash, hash);
  assert.equal(decoded.body.kind, kind);
}

const original = start();
const decoded = decodeEntry(original);
original.bytes.fill(0);
assert.equal(decoded.body.turnId, "turn-1");
assert.equal(decoded.bytes[0], 123);
assert.notEqual(decoded.bytes, original.bytes);
assert(Object.isFrozen(decoded.body));

for (const invalid of [0, -1, 1.1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, "1"]) rejected(() => decodeEntry({ ...start(), seq: invalid }));
for (const hash of ["", "0".repeat(64), "g".repeat(64), start().hash.toUpperCase()]) rejected(() => decodeEntry({ ...start(), hash }));
rejected(() => decodeEntry({ ...start(), seq: 2 }));
rejected(() => decodeEntry({ ...start(), kind: "unknown" }));
rejected(() => decodeEntry({ ...start(), bytes: [123, 125] }));
rejected(() => decodeEntry({ ...start(), bytes: new Uint8Array(32 * 1024 * 1024 + 1) }));
const maximum = new Uint8Array(32 * 1024 * 1024).fill(32);
maximum.set(encoder.encode('{"v":1,"kind":"turn_start"}'));
assert.equal(decodeEntry(envelope(1, "turn_start", maximum)).bytes.length, maximum.length);
for (const bytes of [Uint8Array.of(0xff), Uint8Array.of(0xc0, 0xaf), Uint8Array.of(0xed, 0xa0, 0x80)]) rejected(() => decodeEntry(envelope(1, "turn_start", bytes)));
for (const text of [
  "null", "[]", "{", '{"v":1,"kind":"turn_start",}',
  '{"v":1,"v":1,"kind":"turn_start"}', '{"v":1,"kind":"turn_start","v":{}}',
  '{"v":1,"kind":"turn_start","x":[],"x":null}',
  '{"v":1,"kind":"turn_start","x":{"a":1},"x":{}}',
  '{"v":1,"kind":"turn_start","nested":{"x":1,"x":2}}',
  '{"v":1,"kind":"turn_start","text":"\\ud800"}',
  '{"v":1,"kind":"turn_start","text":"\\udc00"}',
  '{"v":1,"kind":"turn_start"}{}', '\ufeff{"v":1,"kind":"turn_start"}',
]) rejected(() => decodeEntry(envelope(1, "turn_start", text)));
for (const v of ["0", "2", "1.0", "1e0", '"1"', "true", "null"]) rejected(() => decodeEntry(envelope(1, "turn_start", `{"v":${v},"kind":"turn_start"}`)));
rejected(() => decodeEntry(envelope(1, "turn_start", '{"v":1,"kind":"tool_result"}')));
rejected(() => decodeEntry(envelope(1, "turn_start", '{"v":1,"kind":"turn_start","nested":' + "[".repeat(65) + "0" + "]".repeat(65) + "}")));
assert.deepEqual(parseJournalJson('{"v":1.5,"n":1e2,"quote":"a\\\"b","unicode":"\\ud83d\\ude00"}'), { v: 1.5, n: 100, quote: 'a"b', unicode: "😀" });
assert.equal(Object.hasOwn(parseJournalJson('{"__proto__":{"polluted":true}}'), "__proto__"), true);
assert.equal({}.polluted, undefined);

for (const text of ["hello", "雪と😀\nquotes: \"\\"]) {
  const entries = [start(1, text), step(2), end(3)];
  const projection = createProjection(entries);
  const transcript = projection.transcript();
  assert.equal(transcript.model, "test/model");
  assert.deepEqual(transcript.usage, { input_tokens: 3, output_tokens: 2 });
  assert.deepEqual(transcript.messages.map((message) => [message.id, message.role, message.status]), [
    ["turn-1:user", "user", "complete"], ["message-2", "assistant", "complete"],
  ]);
  assert.equal(transcript.messages[0].parts[0].text, text);
  assert.equal(transcript.messages[1].parts[0].text, "Saved reply");
  assert.deepEqual(projection.requests().get("request-1"), { inputHash: decodeEntry(entries[0]).body.inputHash, turnId: "turn-1", complete: true, result: decodeEntry(entries[2]).body.result });
  assert.ok(Object.isFrozen(projection.requests().get("request-1").result));
  const pruned = checkpoint(4, entries);
  assert.deepEqual(readCheckpoint(pruned.bytes), transcript);
  assert.deepEqual(createProjection([pruned]).transcript(), transcript);
  assert.deepEqual(createProjection([pruned]).requests(), projection.requests());
  assert.deepEqual(projection.apply(pruned).delta, { messages: [] });
  const second = start(5, "next", "turn-2", "request-2");
  projection.apply(second);
  const restored = createProjection([pruned, second]);
  assert.deepEqual(restored.transcript(), projection.transcript());
  assert.deepEqual(restored.requests(), projection.requests());
}

// Images retain their durable references; projection never opens the referenced assets.
const imageInput = {
  text: "Inspect 雪.png", work_id: "work-metadata",
  images: [
    { id: 9, path: "/unopened/雪.png", media_type: "image/png", snapshot_path: "images/saved.png", snapshot_sha256: "a".repeat(64) },
    { id: 10, path: { encoding: "base64", data: "/wA=" }, media_type: "image/jpeg" },
  ],
};
const withInput = (input) => {
  const inputJson = JSON.stringify(input);
  return entry(1, "turn_start", { ...decodeEntry(start()).body, inputJson, inputHash: digest(encoder.encode(inputJson)) });
};
const imageStart = withInput(imageInput);
const imageProjection = createProjection([imageStart, step(2), end(3)]);
assert.deepEqual(imageProjection.transcript().messages[0].parts, [
  { type: "text", text: "Inspect 雪.png" },
  { type: "image", id: 9, path: "/unopened/雪.png", mimeType: "image/png", snapshotPath: "images/saved.png", snapshotSha256: "a".repeat(64) },
  { type: "image", id: 10, path: { encoding: "base64", data: "/wA=" }, mimeType: "image/jpeg" },
]);
const imageCheckpoint = checkpoint(4, [imageStart, step(2), end(3)]);
assert.deepEqual(createProjection([imageCheckpoint]).transcript(), imageProjection.transcript());
assert.deepEqual(readCheckpoint(imageCheckpoint.bytes), imageProjection.transcript());
assert.equal(decodeEntry(imageCheckpoint).body.records[0].inputJson, JSON.stringify(imageInput));
assert.throws(() => { imageProjection.transcript().messages[0].parts[2].path.data = "changed"; }, TypeError);
assert.equal(createProjection([withInput({ text: { encoding: "base64", data: "/wA=" }, images: [] })]).transcript().messages[0].parts[0].text, "\ufffd\0");
for (const text of [
  { encoding: "base64", data: "/wA" }, { encoding: "base64", data: "***=" },
  { encoding: "base64", data: "aGk=" }, { data: "/wA=", encoding: "base64" },
  { encoding: "base64", data: "/wA=", extra: true },
]) rejected(() => createProjection([withInput({ text, images: [] })]));
rejected(() => createProjection([withInput({ text: "", images: [{ id: 1, path: "a", media_type: "image/png", snapshot_path: "saved" }] })]));

// A preview and all later candidate changes leave every prior snapshot intact.
const projection = createProjection([start()]);
const before = projection.transcript();
const requestsBefore = projection.requests();
const decision = step(2, [call("one", "safe"), call("two"), call("three")]);
const candidate = projection.preview(decision);
assert.deepEqual(candidate.completedDrafts, [{ turnId: "turn-1", messageId: "message-2", generationId: "generation-2" }]);
assert.equal(candidate.delta.messages.length, 1);
assert.equal(candidate.delta.messages[0].status, "running");
assert.deepEqual(projection.transcript(), before);
const selected = candidate.projection.transcript();
const firstResult = result(3, "one", true);
const resultChange = candidate.projection.apply(firstResult);
assert.equal(resultChange.delta.messages.length, 1);
assert.deepEqual(resultChange.completedDrafts, []);
assert.deepEqual(resultChange.delta.messages[0].parts.filter((part) => part.type === "tool_call").map((part) => part.status), ["complete", "pending", "pending"]);
assert.equal(resultChange.delta.messages[0].parts.at(-1).isError, true);
assert.equal(selected.messages[1].parts[1].status, "pending");
assert.deepEqual(projection.transcript(), before);
rejected(() => candidate.projection.preview(result(4, "three")));
rejected(() => candidate.projection.preview(step(4)));
rejected(() => candidate.projection.preview(end(4)));

const interrupted = end(4, {
  ok: false, reason: "interrupted", retryable: false, message: "Turn abandoned",
  pendingTool: { callId: "two", name: "lookup", input: { key: "two" } },
});
const closed = candidate.projection.apply(interrupted);
assert.equal(closed.delta.messages[0].status, "interrupted");
assert.deepEqual(closed.delta.messages[0].parts.filter((part) => part.type === "tool_call").map((part) => part.status), ["complete", "unknown", "skipped"]);
assert.equal(candidate.projection.requests().get("request-1").complete, true);
assert.equal(requestsBefore.get("request-1").complete, false);
requestsBefore.clear();
assert.equal(projection.requests().size, 1);
assert.throws(() => { before.messages.push({}); }, TypeError);
assert.throws(() => { selected.messages[1].parts[1].input.key = "altered"; }, TypeError);
assert.deepEqual(candidate.projection.preview(decision).delta, { messages: [] });
assert.deepEqual(candidate.projection.preview(decision).completedDrafts, candidate.completedDrafts);
assert.deepEqual(candidate.projection.apply(decision).completedDrafts, candidate.completedDrafts);
assert.deepEqual(candidate.projection.transcript(), createProjection([start(), decision, firstResult, interrupted]).transcript());
assert.deepEqual(candidate.projection.apply(firstResult), { delta: { messages: [] }, completedDrafts: [] });

// Failures are rejected before adoption, including a partially validated tool batch.
const stable = candidate.projection.transcript();
for (const bad of [
  step(2, [call("different")]), start(6), step(5),
  checkpoint(5, [start(), step(2), end(3)]),
  checkpoint(5, []),
]) {
  rejected(() => candidate.projection.preview(bad));
  assert.deepEqual(candidate.projection.transcript(), stable);
}
assert.throws(() => createProjection([start(), start(2, "other", "turn-2", "request-2")]), PendingTurnError);
assert.throws(() => createProjection([start(), step(2), end(3), start(4, "changed", "turn-2")]), RequestConflict);
const invalidBatch = createProjection([start()]);
rejected(() => invalidBatch.apply(step(2, [call("one"), call("one")])));
assert.equal(invalidBatch.transcript().messages.length, 1);
invalidBatch.apply(step(2, [call("one")]));
rejected(() => createProjection([start(), step(2, [], { messageId: "turn-1:user" })]));
rejected(() => createProjection([start(), step(2, [call("one")]), end(3, { ok: false, reason: "interrupted", retryable: false, message: "", pendingTool: { callId: "other", name: "lookup", input: { key: "one" } } })]));
rejected(() => createProjection([entry(1, "turn_start", { ...decodeEntry(start()).body, inputHash: "0".repeat(64) })]));
rejected(() => createProjection([start(), step(2, [], { completion: { content: ["two", "messages"] } })]));

const history = [start(), step(2), end(3)];
const firstCheckpoint = checkpoint(4, history);
const repeatedCheckpoint = checkpoint(5, history);
assert.deepEqual(createProjection([firstCheckpoint, repeatedCheckpoint]).transcript(), createProjection(history).transcript());
for (const invalid of [
  entry(4, "checkpoint", { lastIncludedSeq: 2, records: history.map((item) => decodeEntry(item).body) }),
  entry(3, "checkpoint", { lastIncludedSeq: 2, records: history.map((item) => decodeEntry(item).body) }),
  entry(5, "checkpoint", { lastIncludedSeq: 4, records: [decodeEntry(firstCheckpoint).body] }),
  checkpoint(2, [start()]),
]) rejected(() => createProjection([invalid]));
rejected(() => readCheckpoint(step(2).bytes));
rejected(() => readCheckpoint(encoder.encode('{"v":1,"kind":"checkpoint","lastIncludedSeq":1,"records":[{"v":1.0,"kind":"turn_end"}]}')));
assert.deepEqual(readCheckpoint(checkpoint(1, []).bytes), { model: "", usage: {}, messages: [] });

// Turn totals replace that turn's step totals, without double counting other turns.
const totals = createProjection([start(), step(2, [call("one")]), result(3, "one"), step(4), end(5, { ok: true, stopReason: "stop", usage: { input_tokens: 6, output_tokens: 4 } })]);
assert.deepEqual(totals.transcript().usage, { input_tokens: 6, output_tokens: 4 });
for (const ErrorType of [JournalConflict, PersistenceUncertain, PendingTurnError, RequestConflict, RecoveryRequired]) {
  const cause = new Error("cause");
  const error = new ErrorType("test", { cause });
  assert.equal(error.name, ErrorType.name);
  assert.equal(error.code, ErrorType.name);
  assert.equal(error.cause, cause);
}

// Captured through the a97bf8d SDK and the built native addon, using an isolated
// home, deterministic provider responses, and a fixture-only lookup tool. These
// are exact encoder bytes; tests below do not initialize a runtime.
const legacyComplete = Buffer.from(
  "RlhDUAIAAAB8BAAAU9Qz5XWLI/m6iS1b4MzkypQ4mU8KCNrBmUKIDtXFwm17Imhpc3RvcnkiOlt7ImtpbmQiOiJhc3Npc3RhbnQi" +
  "LCJ1c2VyIjp7InRleHQiOiJJbnNwZWN0IHNhdmVkIGNvbnRleHQiLCJpbWFnZXMiOltdfSwiYXNzaXN0YW50IjoiU2F2ZWQgYW5z" +
  "d2VyIPCfmIAiLCJwcm92aWRlcl9yZXBsYXkiOm51bGwsImV4ZWN1dGlvbiI6eyJzY2hlbWFfdmVyc2lvbiI6OSwidG9vbF9zdGVw" +
  "cyI6W3siYXNzaXN0YW50IjoiQ2hlY2tpbmcg6ZuqIiwicHJvdmlkZXJfcmVwbGF5IjpudWxsLCJ0b29sX2NhbGxzIjpbeyJpZCI6" +
  "ImxlZ2FjeS1jYWxsIiwibmFtZSI6Imxvb2t1cCIsImFyZ3VtZW50c19qc29uIjoie1wia2V5XCI6XCLpm6pcIn0iLCJwcm92aWRl" +
  "cl9yZXN1bHQiOm51bGx9XSwidG9vbF9yZXN1bHRzIjpbeyJ0b29sX2NhbGxfaWQiOiJsZWdhY3ktY2FsbCIsInRvb2xfbmFtZSI6" +
  "Imxvb2t1cCIsInN0YXR1cyI6InN1Y2Nlc3MiLCJvdXRwdXQiOiJTdG9yZWQgcmVzdWx0IOmbqiIsIm91dHB1dF9oYW5kbGUiOm51" +
  "bGwsInByZXZpZXciOm51bGwsIm91dHB1dF9ieXRlcyI6MTcsInN0b3JlZF9vdXRwdXRfYnl0ZXMiOjE3LCJ0cnVuY2F0ZWQiOmZh" +
  "bHNlLCJwcm92aWRlcl9uYXRpdmUiOmZhbHNlLCJjcmVhdGVkX2F0X21zIjoxNzg4NzkzMzgyMjg0LCJwZXJtaXNzaW9uX2ZlZWRi" +
  "YWNrIjpbXSwiY29tbWl0dGVkX2ZpbGVfcHJlc2VudGF0aW9uIjpudWxsLCJjb21tYW5kX291dHB1dF9yZXBsYXkiOm51bGwsImNv" +
  "bW1hbmRfcHJvY2Vzc19wcmVzZW50YXRpb24iOm51bGwsInRlcm1pbmFsX2FjdGlvbl9wcmVzZW50YXRpb24iOm51bGx9XX1dLCJm" +
  "aWxlcyI6W10sInN0ZWVyaW5nIjpbXSwidHVybl9zdW1tYXJ5Ijp7InN0YXJ0ZWRfYXRfbXMiOjE3ODg3OTMzODIyNjYsImNvbXBs" +
  "ZXRlZF9hdF9tcyI6MTc4ODc5MzM4MjI4NCwidGhpbmtpbmdfZHVyYXRpb25fbXMiOjAsInR1cm5fZHVyYXRpb25fbXMiOjE4LCJ0" +
  "b2tlbl9wcm9ncmVzcyI6eyJpbnB1dF90b2tlbnMiOjYsIm91dHB1dF90b2tlbnMiOjYsImlucHV0X2V4YWN0IjpmYWxzZSwib3V0" +
  "cHV0X2V4YWN0IjpmYWxzZX19fX1dLCJ1c2FnZSI6eyJpbnB1dF90b2tlbnMiOjcsIm91dHB1dF90b2tlbnMiOjMsImNhY2hlX3Jl" +
  "YWRfdG9rZW5zIjpudWxsLCJjYWNoZV93cml0ZV90b2tlbnMiOm51bGwsInJlYXNvbmluZ190b2tlbnMiOm51bGx9fQ==",
  "base64",
);
const legacyPaused = Buffer.from(
  "RlhDUAIAAAA1BQAAdE7hCI8xb7FhE+LxKdgTzkkewuPzbvlXf62q7jblkQR7Imhpc3RvcnkiOltdLCJ1c2FnZSI6eyJpbnB1dF90" +
  "b2tlbnMiOm51bGwsIm91dHB1dF90b2tlbnMiOm51bGwsImNhY2hlX3JlYWRfdG9rZW5zIjpudWxsLCJjYWNoZV93cml0ZV90b2tl" +
  "bnMiOm51bGwsInJlYXNvbmluZ190b2tlbnMiOm51bGx9LCJyZWNvdmVyeV9jaGVja3BvaW50Ijp7InZlcnNpb24iOjIsInR1cm5f" +
  "aWQiOjEsInVzZXIiOnsidGV4dCI6IlBlbmRpbmcgcmVxdWVzdCIsImltYWdlcyI6W119LCJhc3Npc3RhbnRfc291cmNlIjoiIiwi" +
  "ZXhlY3V0aW9uIjp7InNjaGVtYV92ZXJzaW9uIjo5LCJ0b29sX3N0ZXBzIjpbeyJhc3Npc3RhbnQiOiJTYXZlZCBwYXJ0aWFsIOmb" +
  "qiIsInByb3ZpZGVyX3JlcGxheSI6bnVsbCwidG9vbF9jYWxscyI6W3siaWQiOiJwZW5kaW5nLWNhbGwiLCJuYW1lIjoibG9va3Vw" +
  "IiwiYXJndW1lbnRzX2pzb24iOiJ7XCJrZXlcIjpcInNhdmVkXCJ9IiwicHJvdmlkZXJfcmVzdWx0IjpudWxsfV0sInRvb2xfcmVz" +
  "dWx0cyI6W3sidG9vbF9jYWxsX2lkIjoicGVuZGluZy1jYWxsIiwidG9vbF9uYW1lIjoibG9va3VwIiwic3RhdHVzIjoic3VjY2Vz" +
  "cyIsIm91dHB1dCI6IlNhdmVkIHJlc3VsdCIsIm91dHB1dF9oYW5kbGUiOm51bGwsInByZXZpZXciOm51bGwsIm91dHB1dF9ieXRl" +
  "cyI6MTIsInN0b3JlZF9vdXRwdXRfYnl0ZXMiOjEyLCJ0cnVuY2F0ZWQiOmZhbHNlLCJwcm92aWRlcl9uYXRpdmUiOmZhbHNlLCJj" +
  "cmVhdGVkX2F0X21zIjoxNzg4NzkzNDM1MTM2LCJwZXJtaXNzaW9uX2ZlZWRiYWNrIjpbXSwiY29tbWl0dGVkX2ZpbGVfcHJlc2Vu" +
  "dGF0aW9uIjpudWxsLCJjb21tYW5kX291dHB1dF9yZXBsYXkiOm51bGwsImNvbW1hbmRfcHJvY2Vzc19wcmVzZW50YXRpb24iOm51" +
  "bGwsInRlcm1pbmFsX2FjdGlvbl9wcmVzZW50YXRpb24iOm51bGx9XX1dLCJmaWxlcyI6W10sInN0ZWVyaW5nIjpbXSwidHVybl9z" +
  "dW1tYXJ5IjpudWxsfSwiY2F1c2UiOiJzdXNwZW5kZWQiLCJhY3Rpb24iOiJwYXVzZWQiLCJ0b29sX3N0YXRlIjoiY29uZmlybWVk" +
  "IiwiYXV0aG9yaXR5Ijp7InByb3ZpZGVyIjoiZ2F0ZXdheSIsIm1vZGVsIjoibGVnYWN5L21vZGVsIiwiY3JlZGVudGlhbF9zb3Vy" +
  "Y2UiOiJhaV9nYXRld2F5X2FwaV9rZXkiLCJjcmVkZW50aWFsX2lkZW50aXR5IjoiMzg0NDI4MmMyMTQ1YWU5ODU2ZDJiMTAxMWJl" +
  "NmFjNzJjNGViM2I0NmExM2JiMmMyYmZkZmM4MTc0N2NlNGU5NCJ9LCJyZXF1ZXN0ZWRfZmFzdF9tb2RlIjpmYWxzZSwiZmFzdF9t" +
  "b2RlIjpmYWxzZSwibWF4X3Byb3ZpZGVyX2F0dGVtcHRzIjoxMCwiY29uc3VtZWRfcHJvdmlkZXJfYXR0ZW1wdHMiOjAsIm91dHN0" +
  "YW5kaW5nX3Jlc2VydmF0aW9uIjpmYWxzZX19",
  "base64",
);

const completeBytesBefore = Uint8Array.from(legacyComplete);
const legacyTranscript = readCheckpoint(legacyComplete);
assert.equal(legacyTranscript.legacy, true);
assert.equal(legacyTranscript.readOnly, true);
assert.equal(legacyTranscript.pendingEvidence, null);
assert.equal(legacyTranscript.model, "", "history-only checkpoints did not record a model");
assert.deepEqual(legacyTranscript.usage, { input_tokens: 7, output_tokens: 3 });
assert.deepEqual(legacyTranscript.messages.map((message) => message.parts.filter((part) => part.type === "text").map((part) => part.text)), [
  ["Inspect saved context"], ["Checking 雪"], ["Saved answer 😀"],
]);
assert.deepEqual(legacyTranscript.messages[1].parts.slice(1), [
  { type: "tool_call", callId: "legacy-call", name: "lookup", input: { key: "雪" }, status: "complete" },
  { type: "tool_result", callId: "legacy-call", content: "Stored result 雪", isError: false },
]);
assert(legacyTranscript.messages.every((message) => message.id.startsWith("legacy:") && message.turnId.startsWith("legacy:")));
assert.equal(Object.hasOwn(legacyTranscript, "requests"), false);
assert.deepEqual(Uint8Array.from(legacyComplete), completeBytesBefore);

const pausedTranscript = readCheckpoint(legacyPaused);
assert.equal(pausedTranscript.model, "legacy/model");
assert.equal(pausedTranscript.messages.at(-1).status, "interrupted");
assert.equal(pausedTranscript.pendingEvidence.turn_id, 1);
assert.equal(pausedTranscript.pendingEvidence.tool_state, "confirmed");
assert.equal(pausedTranscript.messages[1].parts.find((part) => part.type === "tool_call").status, "complete");
assert.deepEqual(pausedTranscript.pendingEvidence, JSON.parse(legacyPaused.subarray(44)).recovery_checkpoint);
assert.throws(() => { pausedTranscript.pendingEvidence.execution.tool_steps[0].tool_results[0].output = "changed"; }, TypeError);
assert.throws(() => { pausedTranscript.messages[0].parts.push({ type: "text", text: "changed" }); }, TypeError);

function legacyPayload(bytes) { return JSON.parse(Buffer.from(bytes).subarray(44)); }
function legacyFrame(payload, version = 2) {
  const bytes = Buffer.from(typeof payload === "string" ? payload : JSON.stringify(payload));
  const header = Buffer.alloc(44);
  header.write("FXCP"); header.writeUInt16LE(version, 4); header.writeUInt32LE(bytes.length, 8);
  createHash("sha256").update(bytes).digest().copy(header, 12);
  return Buffer.concat([header, bytes]);
}
const versionOne = Buffer.from(legacyComplete);
versionOne.writeUInt16LE(1, 4);
assert.deepEqual(readCheckpoint(versionOne), legacyTranscript);
const offsetBuffer = Buffer.concat([Buffer.from("offset"), legacyComplete, Buffer.from("tail")]);
assert.deepEqual(readCheckpoint(offsetBuffer.subarray(6, -4)), legacyTranscript);
for (const length of [0, 1, 4, 12, 43, 44, legacyComplete.length - 1]) rejected(() => readCheckpoint(legacyComplete.subarray(0, length)));
for (const offset of [0, 4, 6, 8, 12, 43, 44, legacyComplete.length - 1]) {
  const corrupt = Buffer.from(legacyComplete);
  corrupt[offset] ^= 0x80;
  rejected(() => readCheckpoint(corrupt));
}
rejected(() => readCheckpoint(Buffer.concat([legacyComplete, Buffer.from([0])])));
const oversizedLegacy = Buffer.alloc(4 * 1024 * 1024 + 1);
oversizedLegacy.write("FXCP");
rejected(() => readCheckpoint(oversizedLegacy));
rejected(() => readCheckpoint(legacyFrame(legacyPayload(legacyPaused), 1)));
rejected(() => readCheckpoint(legacyFrame({ history: [], usage: {}, recovery_checkpoint: null })));
rejected(() => readCheckpoint(legacyFrame('{"history":[],"history":[],"usage":{}}')));
rejected(() => readCheckpoint(legacyFrame({ history: Array(1025).fill({ kind: "compacted_summary", summary: "", removed_turn_count: 0, compaction_count: 0 }), usage: {} })));

for (const alter of [
  (body) => { body.history[0].kind = "future_kind"; },
  (body) => { body.history[0].execution.schema_version = 10; },
  (body) => { body.history[0].execution = null; },
  (body) => { body.history[0].assistant = null; },
  (body) => { body.history[0].execution.tool_steps[0].tool_calls[0].name = 12; },
  (body) => { body.history[0].execution.tool_steps[0].tool_results[0].status = "pending"; },
  (body) => { body.history[0].execution.tool_steps[0].tool_results[0].output = null; },
]) {
  const body = legacyPayload(legacyComplete); alter(body);
  rejected(() => readCheckpoint(legacyFrame(body)));
}
for (const alter of [
  (pending) => { pending.version = 3; },
  (pending) => { pending.turn_id = 0; },
  (pending) => { pending.consumed_provider_attempts = 11; },
  (pending) => { pending.consumed_provider_attempts = 10; pending.outstanding_reservation = true; },
  (pending) => { pending.tool_state = "safe"; },
  (pending) => { pending.cause = "future_cause"; },
  (pending) => { pending.action = "resume"; },
  (pending) => { pending.authority.provider = "unknown"; },
  (pending) => { pending.authority.credential_source = "chatgpt_subscription"; },
]) {
  const body = legacyPayload(legacyPaused); alter(body.recovery_checkpoint);
  rejected(() => readCheckpoint(legacyFrame(body)));
}

const richLegacy = legacyPayload(legacyComplete);
richLegacy.history[0].user.images = imageInput.images;
const richTranscript = readCheckpoint(legacyFrame(richLegacy));
assert.deepEqual(richTranscript.messages[0].parts.slice(1), imageProjection.transcript().messages[0].parts.slice(1));
const uncertainLegacy = legacyPayload(legacyPaused);
uncertainLegacy.recovery_checkpoint.tool_state = "uncertain";
uncertainLegacy.recovery_checkpoint.execution.tool_steps[0].tool_results = [];
uncertainLegacy.recovery_checkpoint.execution.tool_steps[0].tool_calls.push({ id: "later-call", name: "lookup", arguments_json: '{"key":"later"}', provider_result: null });
assert.deepEqual(readCheckpoint(legacyFrame(uncertainLegacy)).messages[1].parts.filter((part) => part.type === "tool_call").map((part) => part.status), ["unknown", "unknown"], "legacy records cannot establish sequential journal execution or skipped calls");
const opaquePresentation = legacyPayload(legacyPaused);
opaquePresentation.recovery_checkpoint.execution.tool_steps[0].tool_results[0].command_output_replay = { stored_metadata: "read-only evidence" };
assert.deepEqual(readCheckpoint(legacyFrame(opaquePresentation)).pendingEvidence.execution.tool_steps[0].tool_results[0].command_output_replay, { stored_metadata: "read-only evidence" }, "hidden presentation metadata is preserved without claiming native admission validation");
for (let schemaVersion = 1; schemaVersion <= 9; schemaVersion++) {
  const body = legacyPayload(legacyComplete);
  body.history[0].execution = { schema_version: schemaVersion, tool_steps: [], files: [] };
  if (schemaVersion >= 5) body.history[0].execution.turn_summary = null;
  if (schemaVersion >= 6) body.history[0].execution.steering = [];
  assert.equal(readCheckpoint(legacyFrame(body)).messages.at(-1).parts[0].text, "Saved answer 😀");
}
const oldPending = legacyPayload(legacyPaused);
oldPending.recovery_checkpoint.version = 1;
oldPending.recovery_checkpoint.route_model = oldPending.recovery_checkpoint.authority.model;
delete oldPending.recovery_checkpoint.authority;
assert.equal(readCheckpoint(legacyFrame(oldPending)).model, "legacy/model");
for (let routeVersion = 2; routeVersion <= 4; routeVersion++) {
  const body = structuredClone(oldPending);
  const pending = body.recovery_checkpoint;
  pending.version = routeVersion;
  pending.delivery = "possibly_sent";
  pending.route_identity = { connection_id: "vercel", adapter_kind: "vercel_ai_gateway", permission_review_model_id: "review" };
  if (routeVersion >= 3) Object.assign(pending.route_identity, { vision_model_id: "vision", subagent_model_id: "child" });
  if (routeVersion === 4) Object.assign(pending.route_identity, { version: 1, endpoint: "https://unused.invalid", protocol: "vercel_ai_gateway", credential_ref: "unused" });
  const transcript = readCheckpoint(legacyFrame(body));
  assert.equal(transcript.readOnly, true);
  assert.deepEqual(transcript.pendingEvidence.route_identity, pending.route_identity);
}

const historicalKinds = { history: [
  { kind: "compacted_summary", summary: "Older saved summary", removed_turn_count: 3, compaction_count: 1 },
  { kind: "interrupted", user: { text: "cancelled", images: [] }, assistant: "partial", tool_call: { id: "old-call", name: "lookup", arguments_json: "malformed historical input", provider_result: null }, completed_tool_names: [], terminal_reason: "failed" },
  { kind: "background_command", user: { text: "old job", images: [] }, log_path: "old.log", expect_url: false, url: null, background_record_id: null },
], usage: {} };
const historicalTranscript = readCheckpoint(legacyFrame(historicalKinds));
assert.equal(historicalTranscript.messages[0].parts[0].text, "Older saved summary");
assert.equal(historicalTranscript.messages[2].status, "error");
assert.equal(historicalTranscript.messages[2].parts[1].input, "malformed historical input");
assert.equal(historicalTranscript.messages.at(-1).parts[0].text, "[Historical command record: fx no longer owns or controls this process; former log=old.log]");

const savedFetch = globalThis.fetch;
const savedInstantiate = WebAssembly.instantiate;
try {
  globalThis.fetch = () => assert.fail("read-only inspection started a network request");
  WebAssembly.instantiate = () => assert.fail("read-only inspection initialized WebAssembly");
  assert.deepEqual(readCheckpoint(legacyComplete), legacyTranscript);
  assert.deepEqual(readCheckpoint(legacyPaused), pausedTranscript);
} finally {
  globalThis.fetch = savedFetch;
  WebAssembly.instantiate = savedInstantiate;
}
assert.deepEqual(Uint8Array.from(legacyComplete), completeBytesBefore);

console.log("Journal codec and transcript projection tests passed");
