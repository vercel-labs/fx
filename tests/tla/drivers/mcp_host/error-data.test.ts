// ErrorData: a real `fx ask` in a terminal whose fake-gateway model calls a
// 2025-06-18 stdio server, tests/e2e/fixtures/mcp-legacy-stdio.mjs, that refuses
// the call with an error that may hold data. One run per kind and size of data.
// The model output each case checks is the text the fake gateway receives in its
// next request, the model's text for the failed call. The harness reads from it
// whether the data is there, how many of its bytes, and whether the text says it
// was cut; and from the trace log and standard error, whether a log line holds the
// data. A case that cuts is read by the bytes of the data before the marker, the
// bytes its escapes add, and whether a character was split. All the cases are one trace, checked against ErrorData.tla twice: with the
// code (Carry "data") it must be ACCEPTED, and the model of the code before the
// change (Carry "drop") must REJECT it, so the check can tell the two apart.
import { expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers, worktree } from "../lib/context";
import { fixture, fxEnv, save, waitFor, writeProfile } from "./driver";
import { checkTrace, type TraceRecord, type Verdict } from "./trace";

const SERVER = join(worktree, "tests", "e2e", "fixtures", "mcp-legacy-stdio.mjs");
const TOOL = "mcp_fixture_echo";
const MODEL = "openai/gpt-5";
const DONE = "ERROR_DATA_TURN_DONE";
const CAP = 8192;
const MARKER = " ... [data truncated";
// `{"detail":"` and `"}`: what the fixture puts around FX_MCP_PROTOCOL_ERROR_DATA_BYTES.
const FRAME = 13;

interface Case {
  name: string;
  code: number;
  /** The data's JSON text; null sends none, and "null" sends a null. */
  data: string | null;
  /** FX_MCP_PROTOCOL_ERROR_DATA_BYTES: a data member of this many bytes. */
  bytes?: number;
  /** FX_MCP_PROTOCOL_ERROR_DATA_RAW: the data's text, written as it is. */
  raw?: string;
  /** The model's `size` when the compact text is not what JS writes: `std.json`'s writing of a float. */
  size?: number;
  /** The data is one the host leaves out because it cannot read it safely. */
  unreadable?: boolean;
  /** What a log line would hold if it carried the data. */
  needle: string;
  /** The character that crosses the cap, so a cut that does not back off splits it. */
  straddle?: boolean;
}

// é is two bytes. `{"detail":"` is 11, so byte 8191 starts a character that byte 8192 ends.
const WIDE = "é".repeat(4200);
const cases: Case[] = [
  { name: "an object", code: -32602, data: '{"errors":[{"path":["limit"],"expected":"number","received":"string"}]}', needle: '"received":"string"}]}' },
  { name: "a string", code: -32602, data: '"limit is too long"', needle: "limit is too long" },
  { name: "a number", code: -32602, data: "42", needle: "=42" },
  { name: "an array", code: -32602, data: '["a","b"]', needle: '["a","b"]' },
  { name: "true", code: -32602, data: "true", needle: "data=true" },
  { name: "escapes and a bell", code: -32602, data: JSON.stringify({ detail: 'line1\nline2 \u0007 "q"' }), needle: "line2" },
  { name: "null", code: -32602, data: "null", needle: "data=null" },
  { name: "no data", code: -32602, data: null, needle: "data=" },
  { name: "exactly the cap", code: -32602, data: null, bytes: CAP - FRAME, needle: "d".repeat(64) },
  { name: "one byte over the cap", code: -32602, data: null, bytes: CAP - FRAME + 1, needle: "d".repeat(64) },
  { name: "a character across the cap", code: -32602, data: JSON.stringify({ detail: WIDE }), needle: "é".repeat(32), straddle: true },
  { name: "300 KB", code: -32602, data: null, bytes: 300_000, needle: "d".repeat(64) },
  // Escapes count against the cap: each byte of these costs two (a quote and a backslash), or about 7 per 6 (a control byte's \\u0007).
  { name: "a string of quotes", code: -32602, data: JSON.stringify('"'.repeat(5000)), needle: '\\"'.repeat(32) },
  { name: "a string of bells", code: -32602, data: JSON.stringify("\u0007".repeat(2000)), needle: "\\u0007".repeat(16) },
  // The host writes the compact text itself (stdio sends one message per line, so these have spaces and no line breaks): spaces go, and a number that std.json writes longer stays under the cap or the data is cut.
  { name: "spaced data that compacts under the cap", code: -32602, data: null, raw: '{  "errors" : [   { "path" : [ "limit" ] }   ]  }', needle: '"limit" ]' },
  { name: "floats that std.json writes much longer", code: -32602, data: null, raw: `[${"1e-300,".repeat(1000)}1e-300]`, size: 303_304, needle: "1e-300,".repeat(16) },
  // Nested past the host's depth limit, which keeps core from writing it again with `std.json` (it runs out at 256 levels).
  { name: "nested a thousand levels", code: -32602, data: `${"[".repeat(1000)}${"]".repeat(1000)}`, unreadable: true, needle: "[".repeat(60) },
  { name: "another code", code: -32603, data: '{"trace":"t-7"}', needle: '"trace":"t-7"' },
  { name: "a -32042 that lists no URL", code: -32042, data: '{"elicitations":[]}', needle: '{"elicitations":[]}' },
];

/** The kind and the size of the data the fixture sends. */
function sent(c: Case): { kind: "none" | "null" | "unreadable" | "text"; size: number } {
  if (c.unreadable) return { kind: "unreadable", size: 0 };
  if (c.size !== undefined) return { kind: "text", size: c.size };
  if (c.bytes !== undefined) return { kind: "text", size: c.bytes + FRAME };
  if (c.raw !== undefined) return { kind: "text", size: Buffer.byteLength(JSON.stringify(JSON.parse(c.raw))) };
  if (c.data === null) return { kind: "none", size: 0 };
  // The fixture parses and writes the data again, so its size is the compact text's.
  if (c.data === "null") return { kind: "null", size: 0 };
  return { kind: "text", size: Buffer.byteLength(JSON.stringify(JSON.parse(c.data))) };
}

/** Every string in a gateway request that holds `needle`. */
function stringsWith(body: string, needle: string): string[] {
  const found: string[] = [];
  const walk = (value: unknown) => {
    if (typeof value === "string") {
      if (value.includes(needle)) found.push(value);
    } else if (Array.isArray(value)) value.forEach(walk);
    else if (value && typeof value === "object") Object.values(value).forEach(walk);
  };
  walk(JSON.parse(body));
  return found;
}

/** What the model's text holds of the data, as the trace wrapper records it. */
function read(text: string): { form: "none" | "whole" | "cut"; prefix: number; extra: number; marked: boolean; split: boolean } {
  const at = text.indexOf("; data=");
  if (at < 0) return { form: "none", prefix: 0, extra: 0, marked: false, split: false };
  const data = text.slice(at + "; data=".length);
  if (data.startsWith('"')) {
    const decoded = JSON.parse(data) as string;
    const marker = decoded.indexOf(MARKER);
    if (marker >= 0) {
      const prefix = Buffer.byteLength(decoded.slice(0, marker));
      // The literal's bytes before the marker are its quotes, the prefix, and the escapes.
      const before = Buffer.byteLength(data) - Buffer.byteLength(data.slice(data.indexOf(MARKER), data.length - 1));
      return { form: "cut", prefix, extra: before - 2 - prefix, marked: true, split: decoded.includes("\ufffd") };
    }
  }
  return { form: "whole", prefix: Buffer.byteLength(data), extra: 0, marked: false, split: false };
}

async function run(c: Case, index: number): Promise<TraceRecord> {
  const f = fixture(artifacts, `error-data-${index}`);
  const wire = join(f.base, "wire.jsonl");
  const env: Record<string, string> = {
    FX_MCP_WIRE_LOG: wire,
    FX_MCP_MODE: "invalid_params",
    FX_MCP_LEGACY_VERSION: "2025-06-18",
    FX_MCP_PROTOCOL_ERROR_CODE: String(c.code),
    FX_MCP_PID_PATH: join(f.base, "mcp.pid"),
  };
  if (c.bytes !== undefined) env.FX_MCP_PROTOCOL_ERROR_DATA_BYTES = String(c.bytes);
  else if (c.raw !== undefined) env.FX_MCP_PROTOCOL_ERROR_DATA_RAW = c.raw;
  else if (c.data !== null) env.FX_MCP_PROTOCOL_ERROR_DATA = c.data;
  writeProfile(f, { fixture: { command: process.execPath, args: [SERVER], env } });
  const { TmuxSession, startFakeGateway, fakeGatewayToolCall, fakeGatewayFinalText } = await targetHelpers();
  const gateway = startFakeGateway([
    fakeGatewayToolCall("open", "toolbox", { open: TOOL }),
    fakeGatewayToolCall("call", "toolbox", { run: TOOL, arguments: { text: "hello" } }),
    fakeGatewayFinalText(DONE),
  ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const traceLog = join(f.base, "trace.log");
  const stderr = join(f.base, "stderr.log");
  const tui = await TmuxSession.create({
    cmd: `${shellQuote(binary)} ask --no-save ${shellQuote("Call the fixture's echo tool.")}`,
    cwd: f.workspace,
    env: fxEnv(f, {
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_TRACE_LOG: traceLog,
      FX_TRACE_SCOPES: "mcp,tools",
    }),
    stderrPath: stderr,
    isolated: true, width: 160, height: 40, remainOnExit: true,
  });
  try {
    await tui.waitForText(DONE, 40_000);
    await waitFor("the last gateway request", () => gateway.requests.length >= 3, 10_000);
    const body = gateway.requests.at(-1)!.body;
    writeFileSync(join(f.base, "model-request.json"), body);
    const texts = stringsWith(body, "MCP protocol error");
    expect(texts.length).toBeGreaterThan(0);
    const text = texts.at(-1)!;
    const logs = (existsSync(traceLog) ? readFileSync(traceLog, "utf8") : "") + (existsSync(stderr) ? readFileSync(stderr, "utf8") : "");
    const seen = read(text);
    const { kind, size } = sent(c);
    const record: TraceRecord = {
      event: "observed",
      note: c.name,
      data: {
        code: c.code === -32042 ? "url_required" : "invalid_params",
        kind, size,
        form: seen.form, prefix: seen.prefix, extra: seen.extra, marked: seen.marked, split: seen.split,
        logged: logs.includes(c.needle) && c.data !== null && c.data !== "null",
      },
    };
    save(join(f.base, "record.json"), record);
    return record;
  } finally {
    await tui.kill();
    gateway.stop();
  }
}

let memo: Promise<TraceRecord[]> | undefined;
/** One run per case, once for all the tests. */
function observe(): Promise<TraceRecord[]> {
  memo ??= (async () => {
    const records: TraceRecord[] = [];
    // FX_ERROR_DATA_ONLY=<text> runs only the cases whose name holds it, to look at one.
    const only = process.env.FX_ERROR_DATA_ONLY;
    for (const [i, c] of cases.entries()) if (!only || c.name.includes(only)) records.push(await run(c, i));
    save(join(artifacts, "error-data-records.json"), records);
    return records;
  })();
  return memo;
}

/** The verdict, and what TLC said when it was not a verdict about the trace. */
function explain(v: Verdict): string {
  const log = v.runs.map((r) => (existsSync(r.log) ? readFileSync(r.log, "utf8").split("\n").slice(-25).join("\n") : "")).join("\n");
  return `${v.verdict} ${v.detail ?? ""} ${JSON.stringify(v.firstBad ?? {})}\n${log}`;
}

const constants = (carry: "data" | "drop") => ({ ObsCap: CAP, ObsMaxSize: 1_048_576, ObsMaxChar: 6, ObsCarry: carry });

test("What the model's text holds of a server's error data follows ErrorData.tla: whole under the cap, cut with a marker over it, nothing for null or a -32042 (trace ACCEPTED)", async () => {
  const records = await observe();
  const verdict = await checkTrace({ module: "ErrorData", records, constants: constants("data"), dir: join(artifacts, "error-data", "trace") });
  save(join(artifacts, "error-data", "verdict.json"), verdict);
  expect(verdict.verdict === "ACCEPTED" ? "ACCEPTED" : explain(verdict)).toBe("ACCEPTED");
}, 900_000);

test("Control: the model of the host before the change, which kept only the code and the message, REJECTS this trace", async () => {
  const records = await observe();
  const verdict = await checkTrace({ module: "ErrorData", records, constants: constants("drop"), dir: join(artifacts, "error-data", "drop") });
  expect(verdict.verdict === "REJECTED" ? "REJECTED" : explain(verdict)).toBe("REJECTED");
}, 900_000);

test("No case's data appears in a trace log or on standard error", async () => {
  const records = await observe();
  expect(records.filter((r) => r.data?.logged === true).map((r) => r.note)).toEqual([]);
}, 900_000);
