import assert from "node:assert/strict";
import { decodeEntry } from "../../../sdk/journal-codec.js";

const kinds = ["turn_start", "model_step", "tool_result", "turn_end", "checkpoint"];

// Read the complete prefix while a writer may still be appending its last frame.
// The SDK codec verifies the same envelope hash and payload version as the core.
export function decodeNativeJournal(bytes: Buffer) {
  const entries = [];
  let previous = 0;
  for (let offset = 0; offset < bytes.length;) {
    if (bytes.length - offset < 84) break;
    assert.equal(bytes.subarray(offset, offset + 4).toString(), "FXEJ");
    assert.equal(bytes.readUInt16LE(offset + 4), 1);
    assert.equal(bytes[offset + 7], 0);
    const kind = kinds[bytes[offset + 6]!];
    assert.ok(kind);
    const end = offset + 84 + bytes.readUInt32LE(offset + 16);
    if (end > bytes.length) break;
    const entry = {
      seq: Number(bytes.readBigUInt64LE(offset + 8)), kind,
      bytes: bytes.subarray(offset + 84, end),
      hash: bytes.subarray(offset + 20, offset + 84).toString(),
    };
    assert.ok(Number.isSafeInteger(entry.seq) && entry.seq > 0);
    assert.ok(previous ? entry.seq === previous + 1 : kind === "checkpoint");
    decodeEntry(entry);
    entries.push(entry);
    previous = entry.seq;
    offset = end;
  }
  return entries;
}
