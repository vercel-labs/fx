#!/usr/bin/env node
import assert from "node:assert/strict";
import { CoreOutput } from "../core-output.js";
import { createFxAgent } from "../fx-sdk.js";

const encoder = new TextEncoder();
const message = { text: "¢€\u{1f600}界\nsecond line", escaped: '"\\' };
const wire = encoder.encode(JSON.stringify(message) + "\n");
for (let split = 1; split < wire.length; split++) {
  const messages = [];
  const output = new CoreOutput((value) => { messages.push(value); });
  output.write(wire.subarray(0, split));
  assert.equal(messages.length, 0);
  output.write(wire.subarray(split));
  output.finish();
  assert.deepEqual(messages, [message]);
}

const a = [], b = [];
const first = new CoreOutput((value) => { a.push(value); });
const second = new CoreOutput((value) => { b.push(value); });
for (const byte of wire) {
  first.write(Uint8Array.of(byte));
  second.write(Uint8Array.of(byte));
}
assert.deepEqual(a, [message]);
assert.deepEqual(b, [message]);

let release;
const received = [];
const gated = new CoreOutput((value) => {
  received.push(value.id);
  if (value.id === 1) return new Promise((resolve) => { release = resolve; });
});
const pending = gated.write(encoder.encode('{"id":1}\n{"id":2}\n'));
assert.deepEqual(received, [1]);
release();
await pending;
assert.deepEqual(received, [1, 2]);

for (const invalid of [Uint8Array.of(0xff, 10), encoder.encode("not json\n")]) {
  const output = new CoreOutput(() => assert.fail("invalid output was published"));
  assert.throws(() => output.write(invalid));
}
const truncated = new CoreOutput(() => assert.fail("partial output was published"));
truncated.write(encoder.encode('{"id":1}'));
assert.throws(() => truncated.finish(), /within a message/);
truncated.close();
assert.throws(() => truncated.write(wire), /closed/);

const limited = new CoreOutput(() => assert.fail("oversized output was published"));
const fragment = new Uint8Array(1024 * 1024).fill(32);
for (let index = 0; index < 64; index++) limited.write(fragment);
assert.throws(() => limited.write(Uint8Array.of(10)), /exceeds 64 MiB/);
limited.close();

const exactMessages = [];
const exact = new CoreOutput((value) => { exactMessages.push(value); });
exact.write(encoder.encode("{}"));
for (let index = 0; index < 63; index++) exact.write(fragment);
exact.write(fragment.subarray(0, fragment.length - 3));
exact.write(Uint8Array.of(10));
exact.finish();
assert.deepEqual(exactMessages, [{}]);

const failure = new Error("consumer failed");
const rejected = new CoreOutput(() => Promise.reject(failure));
await assert.rejects(rejected.write(wire), (error) => error === failure);

for (const cancelAt of ["permission.request", "permission.resolve"]) {
  let handler, exit, promptId, turn;
  let permissionCalls = 0;
  const approvals = [];
  const runtime = {
    exited: new Promise((resolve) => { exit = resolve; }),
    setLineHandler(value) { handler = value; },
    write(data) {
      const message = JSON.parse(data);
      const deliver = (value) => queueMicrotask(() => handler(value));
      if (message.method === "initialize") deliver({ id: message.id, result: {} });
      if (message.method === "libfx/new") deliver({ id: message.id, result: { sessionId: "session" } });
      if (message.method === "session/prompt") {
        promptId = message.id;
        deliver({ id: 100, method: "session/request_permission", params: { sessionId: "session", options: [] } });
      }
      if (message.method === "session/cancel") deliver({ id: promptId, result: { stopReason: "cancelled" } });
      if (message.id === 100) approvals.push(message);
    },
    abortHostEffects() {},
    closeStdin() { exit(0); },
  };
  const agent = await createFxAgent({
    apiKey: "callback-fixture", runtimeFactory: () => runtime,
    onEvent(event) { if (event.type === cancelAt) turn.cancel(); },
    onPermission() { permissionCalls++; return "allow-once"; },
  });
  turn = agent.prompt("permission callback");
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(permissionCalls, cancelAt === "permission.request" ? 0 : 1);
  assert.deepEqual(approvals, [], "approval escaped after callback cancellation");
  await agent.close();
}
console.log("core output framing passed: fragmented UTF-8, isolation, ordering, invalid and bounded records");
