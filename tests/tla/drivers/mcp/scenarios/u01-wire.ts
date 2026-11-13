// U01 wire format, step 6. The real decoder, run by tests/tla/drivers/mcp/labs/wire_lab.zig,
// against every JSON-RPC example in the MCP specification pages
// (fixtures/spec-examples.json), plus hand-written cases for ids, malformed input, and oversized
// messages. U01 has no model, so these cases check exact output instead of
// traces.

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Scenario } from "../scenario";

const EXAMPLES = resolve(import.meta.dir, "../fixtures/spec-examples.json");

interface Case {
  /** Where the input came from, for failure messages. */
  source: string;
  input: string | Buffer;
  /** The exact line wire_lab must print. */
  expected: string;
}

const MAX_U64 = 18446744073709551615n;

/** The decoder's id for a response, computed independently: an integer, or a
 * string of plain decimal digits, that fits in 64 bits. */
function ownId(id: unknown): number | bigint | null {
  if (typeof id === "number") return Number.isSafeInteger(id) && id >= 0 ? id : null;
  if (typeof id === "string" && /^(0|[1-9][0-9]*)$/.test(id)) {
    const value = BigInt(id);
    return value <= MAX_U64 ? value : null;
  }
  return null;
}

function line(fields: [string, unknown][]): string {
  return "{" + fields.map(([k, v]) => `${JSON.stringify(k)}:${typeof v === "bigint" ? v.toString() : JSON.stringify(v)}`).join(",") + "}";
}

/** What wire_lab prints for a valid example message, derived from JSON.parse. */
function expectedFor(message: any): string {
  if ("method" in message) {
    if (!("id" in message)) return line([["kind", "notification"], ["method", message.method]]);
    if (message.id === null) return line([["error", "InvalidId"]]);
    return line([["kind", "request"], ["id", JSON.stringify(message.id)], ["method", message.method]]);
  }
  const id = ownId(message.id);
  if ("error" in message) return line([["kind", "response"], ["id", id], ["code", message.error.code]]);
  const type = message.result?.resultType;
  const kind = type === undefined || type === "complete" ? "complete" : type === "input_required" ? "input_required" : "unrecognized";
  return line([["kind", "response"], ["id", id], ["result", kind]]);
}

/** Every JSON-RPC 2.0 message example in the MCP specification pages, as
 * extracted into fixtures/spec-examples.json with line breaks folded to spaces. */
function specExamples(): Case[] {
  const examples = JSON.parse(readFileSync(EXAMPLES, "utf8")) as { source: string; input: string }[];
  return examples.map(({ source, input }) => ({ source, input, expected: expectedFor(JSON.parse(input)) }));
}

const raw = (source: string, input: string | Buffer, expected: string): Case => ({ source, input, expected });
const response = (id: string, result = "complete") => `{"kind":"response","id":${id},"result":"${result}"}`;
const failure = (name: string) => `{"error":"${name}"}`;

const idCases: Case[] = [
  ...[
    ["7", "7"], ['"7"', "7"], ['"0"', "0"], ["0", "0"], ['"007"', "null"], ['"abc"', "null"], ['"1_0"', "null"],
    ["-1", "null"], ["1.5", "null"], ["1e2", "null"], ["null", "null"],
    ["9007199254740991", "9007199254740991"], ['"18446744073709551615"', "18446744073709551615"],
    ["18446744073709551615", "18446744073709551615"], ["18446744073709551616", "null"],
  ].map(([id, expected]) => raw(`response id ${id}`, `{"jsonrpc":"2.0","id":${id},"result":{}}`, response(expected))),
  raw("response without an id", '{"jsonrpc":"2.0","result":{}}', response("null")),
  raw("response id is an object", '{"jsonrpc":"2.0","id":{},"result":{}}', failure("InvalidId")),
  raw("response id is true", '{"jsonrpc":"2.0","id":true,"result":{}}', failure("InvalidId")),
  raw("server request, string id", '{"jsonrpc":"2.0","id":"srv-1","method":"ping"}', '{"kind":"request","id":"\\"srv-1\\"","method":"ping"}'),
  raw("server request, number id", '{"jsonrpc":"2.0","id":5,"method":"ping"}', '{"kind":"request","id":"5","method":"ping"}'),
  raw("server request, null id", '{"jsonrpc":"2.0","id":null,"method":"ping"}', failure("InvalidId")),
  raw("server request, fractional id", '{"jsonrpc":"2.0","id":1.5,"method":"ping"}', failure("InvalidId")),
];

const deep = (levels: number) => `{"jsonrpc":"2.0","id":1,"result":{"a":${"[".repeat(levels)}${"]".repeat(levels)}}}`;
const malformedCases: Case[] = [
  raw("truncated", '{"jsonrpc":"2.0","id":1,"result":{}', failure("InvalidJson")),
  raw("trailing bytes", '{"jsonrpc":"2.0","id":1,"result":{}} x', failure("InvalidJson")),
  raw("invalid UTF-8 in a string", Buffer.concat([Buffer.from('{"jsonrpc":"2.0","id":1,"result":{"t":"'), Buffer.from([0xff]), Buffer.from('"}}')]), failure("InvalidJson")),
  raw("batch", '[{"jsonrpc":"2.0","method":"ping"}]', failure("NotAnObject")),
  raw("bare null", "null", failure("NotAnObject")),
  raw("empty object", "{}", failure("NotJsonRpc2")),
  raw("version 1.0", '{"jsonrpc":"1.0","id":1,"result":{}}', failure("NotJsonRpc2")),
  raw("version as a number", '{"jsonrpc":2.0,"id":1,"result":{}}', failure("NotJsonRpc2")),
  raw("result and error", '{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}', failure("Ambiguous")),
  raw("neither result nor error", '{"jsonrpc":"2.0","id":1}', failure("Ambiguous")),
  raw("method and error", '{"jsonrpc":"2.0","id":1,"method":"m","error":{"code":1,"message":"x"}}', failure("Ambiguous")),
  raw("response with params", '{"jsonrpc":"2.0","id":1,"params":{},"result":{}}', failure("Ambiguous")),
  raw("duplicate id", '{"jsonrpc":"2.0","id":1,"id":2,"result":{}}', failure("DuplicateField")),
  raw("duplicate result", '{"jsonrpc":"2.0","id":1,"result":{},"result":{}}', failure("DuplicateField")),
  raw("method with escapes", '{"jsonrpc":"2.0","method":"pi\\u006eg"}', failure("InvalidMethod")),
  raw("params as an array", '{"jsonrpc":"2.0","method":"m","params":[1]}', failure("InvalidParams")),
  raw("result as an array", '{"jsonrpc":"2.0","id":1,"result":[]}', failure("InvalidResult")),
  raw("error code 1e3", '{"jsonrpc":"2.0","id":1,"error":{"code":1e3,"message":"x"}}', failure("InvalidErrorObject")),
  raw("error without a message", '{"jsonrpc":"2.0","id":1,"error":{"code":-32600}}', failure("InvalidErrorObject")),
  raw("1,000 levels of nesting", deep(1000), response("1")),
  raw("5,000 levels of nesting", deep(5000), failure("TooDeep")),
  raw("unknown fields are ignored", '{"jsonrpc":"2.0","id":3,"extra":{"id":9},"result":{"resultType":"input_required"}}', response("3", "input_required")),
];

const bigString = "x".repeat(8 * 1024 * 1024);
const manyFields = Array.from({ length: 100_000 }, (_, i) => `"f${i}":${i}`).join(",");
const oversizedCases: Case[] = [
  raw("8 MiB string in a result", `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"${bigString}"}]}}`, response("1")),
  raw("100,000 result fields", `{"jsonrpc":"2.0","id":2,"result":{${manyFields}}}`, response("2")),
  raw("8 MiB notification params", `{"jsonrpc":"2.0","method":"notifications/message","params":{"data":"${bigString}"}}`, '{"kind":"notification","method":"notifications/message"}'),
];

function wireScenario(name: string, description: string, cases: () => Case[], minimum: number, timeoutMs?: number): Scenario {
  let selected: Case[] = [];
  return {
    name,
    unit: "U01",
    description,
    needs: ["wire_lab"],
    setup: (ctx) => {
      selected = cases();
      const parts = selected.flatMap((c) => [typeof c.input === "string" ? Buffer.from(c.input) : c.input, Buffer.from("\n")]);
      writeFileSync(join(ctx.caseDir, "input.jsonl"), Buffer.concat(parts));
    },
    command: (ctx) => [ctx.bin.wire_lab, join(ctx.caseDir, "input.jsonl")],
    expect: {
      exit: 0,
      traces: [],
      stdout: (text) => {
        if (selected.length < minimum) return `only ${selected.length} cases, expected at least ${minimum}`;
        const got = text.split("\n").filter((l) => l.length > 0);
        if (got.length !== selected.length) return `${got.length} output lines for ${selected.length} cases`;
        for (const [i, c] of selected.entries()) {
          if (got[i] !== c.expected) return `${c.source}: got ${got[i].slice(0, 200)}, expected ${c.expected}`;
        }
        return null;
      },
    },
    timeoutMs,
  };
}

// ---- field names: a name written with escapes is the name it spells ----
//
// wire_lab's `fields` mode reads one asked field of one object with the real
// objectFields, for the FieldRead model: the same name plain, with one letter
// escaped, all letters in either case of hex digit, twice (a duplicate, however
// it is spelled), next to names that only look like it, and nested. The
// expected answer comes from the layout the scenario wrote, and for objects
// with at most one such member JSON.parse must agree.

const ASKED = ["mode", "isError", "id", "requestState", "resultType", "ttlMs", "nextCursor", "instructions", "url", "elicitationId"];
const VALUES = ["true", "false", "7", '"s"', '{"a":[1]}', "[]"];

type Style = "plain" | "lower" | "upper";

/** `text` as a JSON string token; each code point is written the way `style` says, where JSON allows it. */
function spell(text: string, style: (letter: number, ch: string) => Style): string {
  let out = '"';
  [...text].forEach((ch, i) => {
    const needsEscape = ch.codePointAt(0)! < 0x20 || ch === '"' || ch === "\\";
    const how = style(i, ch);
    if (how === "plain" && !needsEscape) out += ch;
    else for (let u = 0; u < ch.length; u++) {
      const hex = ch.charCodeAt(u).toString(16).padStart(4, "0");
      out += "\\u" + (how === "upper" ? hex.toUpperCase() : hex);
    }
  });
  return out + '"';
}

interface Member {
  key: string;
  /** The name once decoded, as JSON.parse decodes it. */
  decoded: string;
  value: string;
}

const member = (decoded: string, value: string, style: (i: number, ch: string) => Style = () => "plain"): Member => ({ key: spell(decoded, style), decoded, value });
const escapedAt = (at: number) => (i: number): Style => (i === at ? "lower" : "plain");
const allLower = (): Style => "lower";
const allUpper = (): Style => "upper";
const nulOnly = (_: number, ch: string): Style => (ch === "\u0000" ? "lower" : "plain");

interface Layout {
  label: string;
  members: (name: string, value: string) => Member[];
}

const layouts: Layout[] = [
  { label: "plain", members: (n, v) => [member(n, v)] },
  { label: "one letter escaped", members: (n, v) => [member(n, v, escapedAt(1))] },
  { label: "every letter escaped, capital hex digits", members: (n, v) => [member(n, v, allUpper)] },
  { label: "every other letter escaped", members: (n, v) => [member(n, v, (i) => (i % 2 ? "lower" : "plain"))] },
  { label: "plain then escaped", members: (n, v) => [member(n, v), member(n, v, escapedAt(0))] },
  { label: "escaped then plain", members: (n, v) => [member(n, v, escapedAt(0)), member(n, v)] },
  { label: "escaped twice", members: (n, v) => [member(n, v, allLower), member(n, v, allUpper)] },
  { label: "a name ending in the asked one, with NUL", members: (n, v) => [member("x\u0000" + n, v, nulOnly), member(n, v)] },
  { label: "the asked name and an accent, then the name escaped", members: (n, v) => [member(n + "\u00e9", v, allLower), member(n, v, allLower)] },
  { label: "a dotless i for the first letter", members: (n, v) => [member("\u0131" + n.slice(1), v, allLower)] },
  { label: "the name as the first letters of a longer one", members: (n, v) => [member(n + "\ud83d\ude00", v, allLower)] },
  { label: "an unasked name twice, written two ways, and the name escaped", members: (n, v) => [member("x", v), member("x", v, allLower), member(n, v, escapedAt(0))] },
];

interface FieldCase {
  source: string;
  object: string;
  name: string;
  plain: number;
  escaped: number;
  other: number;
  flag: boolean;
  expected: string;
}

function fieldCases(): FieldCase[] {
  const cases: FieldCase[] = [];
  for (const [k, name] of ASKED.entries()) {
    for (const [l, layout] of layouts.entries()) {
      const value = VALUES[(k + l) % VALUES.length];
      const members = layout.members(name, value);
      const object = "{" + members.map((m) => `${m.key}:${m.value}`).join(",") + "}";
      const parsed = JSON.parse(object); // the objects must be valid JSON
      const matching = members.filter((m) => m.decoded === name);
      if (matching.length <= 1) {
        const want = matching.length === 0 ? undefined : JSON.parse(value);
        if (JSON.stringify(parsed[name]) !== JSON.stringify(want)) throw new Error(`${layout.label}: JSON.parse reads ${object} differently from the layout`);
      }
      cases.push({
        source: `${name}, ${layout.label}`,
        object,
        name,
        plain: matching.filter((m) => !m.key.includes("\\")).length,
        escaped: matching.filter((m) => m.key.includes("\\")).length,
        other: members.filter((m) => m.decoded !== name && m.key.includes("\\")).length,
        flag: value === "true",
        expected: matching.length === 0 ? '{"found":null}' : matching.length === 1 ? `{"found":${JSON.stringify(value)}}` : '{"error":"DuplicateField"}',
      });
    }
  }
  return cases;
}

/** A field read through wire_lab, and its trace checked by FieldRead.tla. `rawKeyRead` 1 asks the model of the code before the fix. */
function fieldScenario(name: string, description: string, rawKeyRead: 0 | 1, verdict: "ACCEPTED" | "REJECTED"): Scenario {
  let selected: FieldCase[] = [];
  return {
    name,
    unit: "U01",
    description,
    needs: ["wire_lab"],
    setup: (ctx) => {
      selected = fieldCases();
      const lines = selected.map(({ object, name: asked, plain, escaped, other, flag }) => JSON.stringify({ object, name: asked, plain, escaped, other, flag }));
      writeFileSync(join(ctx.caseDir, "fields.jsonl"), lines.join("\n") + "\n");
    },
    command: (ctx) => [ctx.bin.wire_lab, "fields", join(ctx.caseDir, "fields.jsonl"), ctx.tracePath],
    expect: {
      exit: 0,
      traces: [{ machine: "FieldRead", instance: "wire", specDir: "tests/tla/mcp", wrapper: "FieldReadTrace", verdict, constants: { ObsRawKeyRead: rawKeyRead, ObsMaxMembers: 3 } }],
      stdout: (text) => {
        const got = text.split("\n").filter((l) => l.length > 0);
        if (got.length !== selected.length) return `${got.length} output lines for ${selected.length} cases`;
        for (const [i, c] of selected.entries()) {
          if (got[i] !== c.expected) return `${c.source}: got ${got[i].slice(0, 200)}, expected ${c.expected} for ${c.object.slice(0, 120)}`;
        }
        return null;
      },
    },
  };
}

export const scenarios: Scenario[] = [
  // The frozen snapshot holds 36 such examples (four more use "..." and aren't JSON).
  wireScenario("u01-spec-examples", "Every JSON-RPC example in the spec snapshot decodes as JSON.parse reads it", specExamples, 36),
  wireScenario("u01-ids", "String and number ids: which ones match the client's, and which are rejected", () => idCases, idCases.length),
  wireScenario("u01-malformed", "Malformed, ambiguous, and too-deep messages fail with the exact error", () => malformedCases, malformedCases.length),
  wireScenario("u01-oversized", "Multi-megabyte messages and 100,000 fields decode without a hidden limit", () => oversizedCases, oversizedCases.length, 60_000),
  fieldScenario("u01-field-names", "A field name written with escapes is read as the name it spells, a duplicate is refused however it is spelled, and look-alike names match nothing; the trace is a behavior of FieldRead.tla", 0, "ACCEPTED"),
  fieldScenario("u01-field-names-raw-model", "Control: the same fixed engine's trace is rejected by the model of the code before the fix (KeyRead raw)", 1, "REJECTED"),
];
