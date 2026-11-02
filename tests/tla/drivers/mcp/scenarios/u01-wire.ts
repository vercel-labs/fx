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

export const scenarios: Scenario[] = [
  // The frozen snapshot holds 36 such examples (four more use "..." and aren't JSON).
  wireScenario("u01-spec-examples", "Every JSON-RPC example in the spec snapshot decodes as JSON.parse reads it", specExamples, 36),
  wireScenario("u01-ids", "String and number ids: which ones match the client's, and which are rejected", () => idCases, idCases.length),
  wireScenario("u01-malformed", "Malformed, ambiguous, and too-deep messages fail with the exact error", () => malformedCases, malformedCases.length),
  wireScenario("u01-oversized", "Multi-megabyte messages and 100,000 fields decode without a hidden limit", () => oversizedCases, oversizedCases.length, 60_000),
];
