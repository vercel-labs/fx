#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { encodeXtermKeyEvent, fxSdkApiVersion, xtermAdapter } from "../node.js";

const superBackspace = "\x1b[127;9u";

assert.equal(fxSdkApiVersion, 1);
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "Enter", shiftKey: true }), "\x1b[13;2u");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowLeft", metaKey: true }), "\x1b[1;9D");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowRight", metaKey: true }), "\x1b[1;9C");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowUp", metaKey: true }), "\x1b[1;9A");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "ArrowDown", metaKey: true }), "\x1b[1;9B");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "a", metaKey: true }), "\x1b[97;9u");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "c", metaKey: true }), "\x1b[99;9u");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "x", metaKey: true }), "\x1b[120;9u");
assert.equal(encodeXtermKeyEvent({ type: "keydown", key: "z", metaKey: true }), "\x1b[122;9u");
assert.equal(
  encodeXtermKeyEvent({ type: "keydown", key: "Z", metaKey: true, shiftKey: true }),
  "\x1b[122;10u",
);

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
let selected = false;
const listeners = new Map();
const screen = {
  getBoundingClientRect() {
    return { left: 0, top: 0, right: 800, bottom: 240, width: 800, height: 240 };
  },
};
const element = {
  querySelector(selector) { return selector === ".xterm-screen" ? screen : null; },
  addEventListener(type, callback) { listeners.set(type, callback); },
  removeEventListener(type, callback) { if (listeners.get(type) === callback) listeners.delete(type); },
};
const term = {
  cols: 80,
  rows: 24,
  element,
  modes: { mouseTrackingMode: "none" },
  write() {},
  onData() { return { dispose() {} }; },
  onResize() { return { dispose() {} }; },
  hasSelection() { return selected; },
  attachCustomKeyEventHandler(callback) {
    handler = callback;
  },
};
const host = xtermAdapter(term);
const unsubscribe = host.onKeyData((data) => { sent += data; });

assert.equal(handler({ type: "keydown", key: "Backspace", metaKey: true }), false);
assert.equal(sent, superBackspace);
assert.equal(handler({ type: "keydown", key: "Enter", shiftKey: true }), false);
assert.equal(handler({ type: "keydown", key: "ArrowLeft", metaKey: true }), false);
assert.equal(handler({ type: "keydown", key: "a", metaKey: true }), false);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u`);
assert.equal(handler({ type: "keydown", key: "Backspace", altKey: true }), true);

selected = true;
assert.equal(handler({ type: "keydown", key: "c", metaKey: true }), true);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u`);
assert.equal(handler({ type: "keydown", key: "x", metaKey: true }), true);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u`);
selected = false;
assert.equal(handler({ type: "keydown", key: "c", metaKey: true }), false);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u\x1b[99;9u`);

let cutPrevented = false;
let cutStopped = false;
listeners.get("keydown")({
  type: "keydown", key: "x", metaKey: true,
  shiftKey: false, altKey: false, ctrlKey: false,
  preventDefault() { cutPrevented = true; },
  stopImmediatePropagation() { cutStopped = true; },
});
assert.equal(cutPrevented, true);
assert.equal(cutStopped, true);
assert.equal(sent, `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u\x1b[99;9u\x1b[120;9u`);

let newlinePrevented = false;
let newlineStopped = false;
listeners.get("keydown")({
  type: "keydown", key: "Enter", metaKey: false,
  shiftKey: true, altKey: false, ctrlKey: false,
  preventDefault() { newlinePrevented = true; },
  stopImmediatePropagation() { newlineStopped = true; },
});
assert.equal(newlinePrevented, true);
assert.equal(newlineStopped, true);
assert.equal(
  sent,
  `${superBackspace}\x1b[13;2u\x1b[1;9D\x1b[97;9u\x1b[99;9u\x1b[120;9u\x1b[13;2u`,
);

listeners.get("pointerdown")({ button: 0, pointerId: 1, clientX: 50, clientY: 20 });
listeners.get("pointerup")({
  button: 0, pointerId: 1, clientX: 52, clientY: 22,
  shiftKey: false, altKey: false, ctrlKey: false, metaKey: false,
});
assert.equal(sent.endsWith("\x1b[<0;6;3M\x1b[<0;6;3m"), true);
const afterClick = sent;
listeners.get("pointerdown")({ button: 0, pointerId: 2, clientX: 10, clientY: 10 });
listeners.get("pointerup")({
  button: 0, pointerId: 2, clientX: 50, clientY: 50,
  shiftKey: false, altKey: false, ctrlKey: false, metaKey: false,
});
assert.equal(sent, afterClick);

unsubscribe();
assert.equal(listeners.size, 0);

console.log("xterm adapter passed: browser shortcuts, captured cut and newline, terminal selection priority, and click forwarding");
