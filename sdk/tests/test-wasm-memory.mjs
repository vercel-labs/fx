#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
const bytes = await readFile(wasmPath);
let offset = 8;

function readUleb() {
  let value = 0;
  let shift = 0;
  for (;;) {
    assert.ok(offset < bytes.length, "truncated Wasm LEB128 value");
    const byte = bytes[offset++];
    value += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return value;
    shift += 7;
    assert.ok(shift < 35, "oversized Wasm LEB128 value");
  }
}

assert.equal(bytes.subarray(0, 4).toString("hex"), "0061736d", "invalid Wasm magic");
let initialPages = null;
while (offset < bytes.length) {
  const sectionId = bytes[offset++];
  const sectionSize = readUleb();
  const sectionEnd = offset + sectionSize;
  assert.ok(sectionEnd <= bytes.length, "truncated Wasm section");
  if (sectionId === 5) {
    assert.equal(readUleb(), 1, "fx-core must define exactly one linear memory");
    const flags = readUleb();
    initialPages = readUleb();
    if ((flags & 1) !== 0) readUleb();
    assert.equal(offset, sectionEnd, "unexpected Wasm memory section contents");
    break;
  }
  offset = sectionEnd;
}

assert.notEqual(initialPages, null, "fx-core did not define linear memory");
assert.ok(initialPages <= 32, `fx-core initial memory exceeds 32 pages: ${initialPages}`);
console.log(`fx-core Wasm memory passed: ${initialPages} initial pages`);
