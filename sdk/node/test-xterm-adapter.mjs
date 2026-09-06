#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { encodeXtermKeyEvent, fxSdkApiVersion, xtermAdapter } from "../node.js";

const superBackspace = "\x1b[127;9u";

assert.equal(fxSdkApiVersion, 2);
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "Enter", shiftKey: true }), "\x1b[13;2u");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowLeft", metaKey: true }), "\x1b[1;9D");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowRight", metaKey: true }), "\x1b[1;9C");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowUp", metaKey: true }), "\x1b[1;9A");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowDown", metaKey: true }), "\x1b[1;9B");

assert.equal(
  encodeXtermKeyEvent({ type: "keydown", key: "Backspace", metaKey: true }),
  superBackspace,
);
assert.equal(
  encodeXtermKeyEvent({ type: "keydown", key: "Backspace", metaKey: true, shiftKey: true }),
  "\x1b[127;10u",
);
for (const event of [
  { type: "keyup", key: "Backspace", metaKey: true },
  { type: "keydown", key: "Backspace", metaKey: false },
  { type: "keydown", key: "Backspace", altKey: true },
  { type: "keydown", key: "Enter", shiftKey: false },
  { type: "keydown", key: "ArrowLeft", metaKey: false },
]) {
  assert.equal(encodeXtermKeyEvent(event), null);
}

let handler;
let sent = "";
const term = {
  cols: 80,
  rows: 24,
  write() {},
  onData() { return { dispose() {} }; },
  onResize() { return { dispose() {} }; },
  attachCustomKeyEventHandler(callback) {
    handler = callback;
  },
};
const host = xtermAdapter(term);
host.onKeyData((data) => { sent += data; });

assert.equal(handler({ type: "keydown", key: "Backspace", metaKey: true }), false);
assert.equal(sent, superBackspace);
assert.equal(handler({ type: "keydown", key: "Enter", shiftKey: true }), false);
assert.equal(handler({ type: "keydown", key: "ArrowLeft", metaKey: true }), false);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D`);
assert.equal(handler({ type: "keydown", key: "Backspace", altKey: true }), true);

console.log("xterm adapter passed: modified Enter, Backspace, and arrows preserve modifiers");
