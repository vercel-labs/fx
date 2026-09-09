const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
export const maxJournalEntryBytes = 32 * 1024 * 1024;
const maxEntryBytes = maxJournalEntryBytes;
const kinds = new Set(["turn_start", "model_step", "tool_result", "turn_end", "checkpoint"]);

export class JournalConflict extends Error {
  constructor(message = "Journal content conflicts with the recorded history", options) {
    super(message, options);
    this.name = "JournalConflict";
    this.code = "JournalConflict";
  }
}

export class PersistenceUncertain extends Error {
  constructor(message = "Persistence is uncertain; close and recreate from durable records", options) {
    super(message, options);
    this.name = "PersistenceUncertain";
    this.code = "PersistenceUncertain";
  }
}

export class PendingTurnError extends Error {
  constructor(message = "A pending turn requires an explicit recovery decision", options) {
    super(message, options);
    this.name = "PendingTurnError";
    this.code = "PendingTurnError";
  }
}

export class RequestConflict extends Error {
  constructor(message = "Request identity conflicts with a recorded request", options) {
    super(message, options);
    this.name = "RequestConflict";
    this.code = "RequestConflict";
  }
}

export class RecoveryRequired extends Error {
  constructor(message = "The pending tool requires recovery before execution can continue", options) {
    super(message, options);
    this.name = "RecoveryRequired";
    this.code = "RecoveryRequired";
  }
}

export class JournalCapacityExceeded extends Error {
  constructor(message = "Journal capacity is exhausted; close pending work and start a new session", options) {
    super(message, options);
    this.name = "JournalCapacityExceeded";
    this.code = "JournalCapacityExceeded";
  }
}

const roundConstants = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const rotate = (word, count) => (word >>> count) | (word << (32 - count));

// SHA-256 stays synchronous in both browser and Node, including before a runtime loads.
export function hashBytes(bytes) {
  if (!(bytes instanceof Uint8Array)) throw new TypeError("Hash input must be a Uint8Array");
  const padded = new Uint8Array(Math.ceil((bytes.length + 9) / 64) * 64);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(bytes.length / 0x20000000));
  view.setUint32(padded.length - 4, bytes.length * 8);
  const state = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const words = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i++) words[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 64; i++) {
      const x = words[i - 15], y = words[i - 2];
      words[i] = words[i - 16] + (rotate(x, 7) ^ rotate(x, 18) ^ (x >>> 3)) + words[i - 7] + (rotate(y, 17) ^ rotate(y, 19) ^ (y >>> 10));
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let i = 0; i < 64; i++) {
      const t1 = (h + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) + ((e & f) ^ (~e & g)) + roundConstants[i] + words[i]) >>> 0;
      const t2 = ((rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    const block = [a, b, c, d, e, f, g, h];
    for (let i = 0; i < 8; i++) state[i] += block[i];
  }
  return Array.from(state, (word) => word.toString(16).padStart(8, "0")).join("");
}

// JSON.parse alone accepts duplicate fields and isolated UTF-16 surrogates.
// Keep the raw version token too: Zig distinguishes integer 1 from 1.0 and 1e0.
function parseJson(text) {
  validateJsonBounds(text);
  let body;
  try { body = JSON.parse(text); } catch { throw new JournalConflict("Invalid journal JSON"); }
  let offset = 0;
  const versions = new WeakMap();
  const whitespace = () => { while (/[\x20\t\r\n]/.test(text[offset] ?? "x")) offset++; };
  function string() {
    const start = offset++;
    while (offset < text.length) {
      const character = text[offset++];
      if (character === "\\") offset++;
      else if (character === '"') break;
    }
    const value = JSON.parse(text.slice(start, offset));
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff) {
        const low = value.charCodeAt(++i);
        if (!(low >= 0xdc00 && low <= 0xdfff)) throw new JournalConflict("Invalid journal Unicode");
      } else if (code >= 0xdc00 && code <= 0xdfff) throw new JournalConflict("Invalid journal Unicode");
    }
    return value;
  }
  // JSON.parse owns the grammar. This walk only checks depth, field uniqueness,
  // Unicode scalar values, and the numeric spelling of version fields.
  function inspect(value, depth) {
    if (depth > 64) throw new JournalConflict("Journal JSON exceeds 64 levels of nesting");
    whitespace();
    const character = text[offset];
    const container = value !== null && typeof value === "object";
    if (value === undefined ||
        (character === '"') !== (typeof value === "string") ||
        (character === "[") !== Array.isArray(value) ||
        (character === "{") !== (container && !Array.isArray(value))) {
      throw new JournalConflict("Duplicate journal JSON field");
    }
    if (typeof value === "string") { string(); return; }
    if (value !== null && typeof value === "object") {
      const object = !Array.isArray(value);
      const end = object ? "}" : "]";
      const keys = new Set();
      let index = 0;
      offset++;
      whitespace();
      while (text[offset] !== end) {
        let key = index++;
        if (object) {
          key = string();
          if (keys.has(key)) throw new JournalConflict("Duplicate journal JSON field");
          keys.add(key);
          whitespace();
          offset++; // colon
          whitespace();
        }
        const start = offset;
        inspect(value[key], depth + 1);
        if (object && key === "v") versions.set(value, text.slice(start, offset));
        whitespace();
        if (text[offset] !== end) { offset++; whitespace(); }
      }
      offset++;
      Object.freeze(value);
    } else {
      if (typeof value === "number" && !Number.isFinite(value)) throw new JournalConflict("Invalid journal JSON number");
      while (offset < text.length && !/[\x20\t\r\n,}\]]/.test(text[offset])) offset++;
    }
  }
  inspect(body, 0);
  return { body, versions };
}

export function parseJournalJson(text) {
  return parseJson(text).body;
}

// Bound nested JSON strings before parsing them, using the same container-depth
// scan as the core codec. Delimiters inside quoted strings do not add depth.
function validateJsonBounds(text) {
  if (typeof text !== "string" || text.length > maxEntryBytes || new TextEncoder().encode(text).length > maxEntryBytes) throw new JournalConflict("Invalid journal JSON size");
  let depth = 0, quoted = false, escaped = false;
  for (const character of text) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
    } else if (character === '"') quoted = true;
    else if (character === "{" || character === "[") {
      if (++depth > 64) throw new JournalConflict("Journal JSON exceeds 64 levels of nesting");
    } else if ((character === "}" || character === "]") && depth > 0) depth--;
  }
}

/** Malformed, bounded tool arguments remain inspectable as their exact text. */
export function parseToolInput(text) {
  validateJsonBounds(text);
  try { return parseJournalJson(text); } catch (error) {
    if (!(error instanceof JournalConflict)) throw error;
    return text;
  }
}

function versionedBody(bytes, kind) {
  if (!(bytes instanceof Uint8Array)) throw new JournalConflict("Journal bytes must be a Uint8Array");
  if (bytes.length > maxEntryBytes) throw new JournalConflict("Journal entry exceeds 32 MiB");
  let text;
  try { text = decoder.decode(bytes); } catch { throw new JournalConflict("Journal bytes are not valid UTF-8"); }
  const { body, versions } = parseJson(text);
  function validate(record, expectedKind) {
    if (!record || typeof record !== "object" || Array.isArray(record)) throw new JournalConflict("Journal body must be an object");
    if (versions.get(record) === "1") {
      if (Object.hasOwn(record, "nativeBase")) throw new JournalConflict("Native history requires checkpoint version two");
    } else if (versions.get(record) === "2" && expectedKind === "checkpoint") {
      const base = record.nativeBase;
      if (!base || versions.get(base) !== "1" || typeof base.id !== "string" || typeof base.stateJson !== "string" || typeof base.contextJson !== "string") throw new JournalConflict("Invalid native journal base");
    } else throw new JournalConflict("Unsupported journal version");
    if (!kinds.has(record.kind) || record.kind !== expectedKind) throw new JournalConflict("Journal body kind does not match its envelope");
  }
  validate(body, kind);
  if (kind === "checkpoint") {
    if (!Array.isArray(body.records)) throw new JournalConflict("Checkpoint records must be an array");
    for (const record of body.records) {
      if (record?.kind === "checkpoint") throw new JournalConflict("Nested checkpoints are invalid");
      validate(record, record?.kind);
    }
  }
  return body;
}

export function decodeCheckpoint(bytes) {
  return versionedBody(bytes, "checkpoint");
}

/** Validates the exact wire frame, retaining an independent copy of its bytes. */
export function decodeEntry(entry) {
  if (!entry || !Number.isSafeInteger(entry.seq) || entry.seq < 1) throw new JournalConflict("Journal sequence must be a positive safe integer");
  if (!kinds.has(entry.kind)) throw new JournalConflict("Unknown journal entry kind");
  if (!(entry.bytes instanceof Uint8Array)) throw new JournalConflict("Journal bytes must be a Uint8Array");
  if (entry.bytes.length > maxEntryBytes) throw new JournalConflict("Journal entry exceeds 32 MiB");
  if (typeof entry.hash !== "string" || !/^[0-9a-f]{64}$/.test(entry.hash)) throw new JournalConflict("Invalid journal hash");
  const bytes = new Uint8Array(entry.bytes);
  const prefix = encoder.encode(`${entry.seq}\n${entry.kind}\n`);
  const frame = new Uint8Array(prefix.length + bytes.length);
  frame.set(prefix);
  frame.set(bytes, prefix.length);
  if (hashBytes(frame) !== entry.hash) throw new JournalConflict("Journal hash does not match its exact bytes");
  const body = versionedBody(bytes, entry.kind);
  return { seq: entry.seq, kind: entry.kind, bytes, hash: entry.hash, body };
}
export function normalizeTurnUsage(usage) {
  const result = {};
  for (const [camel, snake] of [["inputTokens", "input_tokens"], ["outputTokens", "output_tokens"],
    ["cacheReadTokens", "cache_read_tokens"], ["cacheWriteTokens", "cache_write_tokens"], ["reasoningTokens", "reasoning_tokens"]]) {
    const value = usage?.[camel] ?? usage?.[snake];
    if (Number.isSafeInteger(value)) result[camel] = value;
  }
  return result;
}
