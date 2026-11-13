// WireDepth: a real `fx ask` against tests/e2e/fixtures/mcp-legacy-stdio.mjs, a
// 2025-11-25 stdio server whose tool result, or one tool of its tool list, is nested to
// a chosen depth. One run per entry point, site and depth, at 127, 128 and 129 levels
// (the limit and its two sides), 255, 256 and 257 (the writers' stack of 256), and 2000
// (the engine hands the host a tool up to 2,581 levels deep). The verdict each run records is what the
// model got, or the process did: the result reached the model or the tool was listed
// (accepted), the call ended with the depth limit's words or the tool was dropped
// (refused), or fx aborted (crashed). All the runs are one trace, checked against
// tests/tla/mcp/WireDepth.tla twice: with the limit of 128 it must be ACCEPTED, and the
// model of the host before the limit (Limit = the engine's own) must REJECT it, so the
// check can tell the two apart. The form entry point has no run here: a form reaches
// it only through an ACP client (tests/e2e/acp.test.ts, and the Zig tests in
// src/core/mcp/elicitation.zig).
import { expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers, worktree } from "../lib/context";
import { fixture, fxEnv, save, writeProfile } from "./driver";
import { checkTrace, type TraceRecord, type Verdict } from "./trace";

const SERVER = join(worktree, "tests", "e2e", "fixtures", "mcp-legacy-stdio.mjs");
const TOOL = "mcp_fixture_echo";
const MODEL = "openai/gpt-5";
const SPEC_DIR = join(worktree, "tests", "tla", "mcp");
const WORDS = "the server's reply is nested deeper than fx accepts (128 levels)";

interface Case { entry: "result" | "tool"; site: string; depth: number }

const depths = [127, 128, 129, 255, 256, 257, 2000];
const cases: Case[] = [
  ...["structured", "content_meta"].flatMap((site) => depths.map((depth) => ({ entry: "result" as const, site, depth }))),
  ...["tool_meta", "tool_icons"].flatMap((site) => depths.map((depth) => ({ entry: "tool" as const, site, depth }))),
];

/** What the model's last request holds for each tool call, by call id. */
function toolResults(body: string): Record<string, string> {
  const found: Record<string, string> = {};
  const walk = (value: unknown): void => {
    if (Array.isArray(value)) value.forEach(walk);
    else if (value && typeof value === "object") {
      const o = value as Record<string, unknown>;
      if (o.type === "tool-result" && typeof o.toolCallId === "string") found[o.toolCallId] = JSON.stringify(o.output);
      Object.values(o).forEach(walk);
    }
  };
  walk(JSON.parse(body));
  return found;
}

async function run(c: Case, index: number): Promise<TraceRecord> {
  const f = fixture(artifacts, `wire-depth-${index}`);
  writeProfile(f, {
    fixture: {
      command: process.execPath,
      args: [SERVER],
      env: {
        FX_MCP_LEGACY_VERSION: "2025-11-25",
        FX_MCP_DEEP_SITE: c.site,
        FX_MCP_DEEP_DEPTH: String(c.depth),
        FX_MCP_PID_PATH: join(f.base, "mcp.pid"),
      },
    },
  });
  const { startFakeGateway, fakeGatewayToolCall, fakeGatewayFinalText } = await targetHelpers();
  const gateway = startFakeGateway([
    fakeGatewayToolCall("open", "toolbox", { open: TOOL }),
    fakeGatewayToolCall("call", "toolbox", { run: TOOL, arguments: { text: "hello" } }),
    ...(c.entry === "tool" ? [fakeGatewayToolCall("deep", "toolbox", { open: "mcp_fixture_deep" })] : []),
    fakeGatewayFinalText("WIRE_DEPTH_TURN_DONE"),
  ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const traceLog = join(f.base, "trace.log");
  const proc = Bun.spawn([binary, "ask", "--no-save", "Call the fixture's echo tool."], {
    cwd: f.workspace,
    env: fxEnv(f, {
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_TRACE_LOG: traceLog,
      FX_TRACE_SCOPES: "mcp",
    }),
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
  });
  const timer = setTimeout(() => proc.kill(), 30_000);
  try {
    const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    const code = await proc.exited;
    const crashed = proc.signalCode !== null || /panic|index out of bounds/i.test(stderr);
    let verdict = "crashed";
    if (!crashed) {
      const body = gateway.requests.at(-1)?.body ?? "{}";
      const results = toolResults(body);
      const text = c.entry === "result" ? (results.call ?? "") : (results.deep ?? "");
      if (c.entry === "result") verdict = text.includes(WORDS) ? "refused" : text.includes("LEGACY_MCP_TOOL_RESULT") ? "accepted" : `unknown: ${text.slice(0, 80)}`;
      else verdict = text.includes("Nothing named mcp_fixture_deep is in the toolbox menu") ? "refused" : text.includes("A tool whose listing is nested deeper than fx accepts") ? "accepted" : `unknown: ${text.slice(0, 80)}`;
      expect(code).toBe(0);
    }
    const record: TraceRecord = {
      event: "observed",
      note: `${c.site} at ${c.depth}`,
      data: { entry: c.entry, depth: c.depth, verdict },
    };
    save(join(f.base, "record.json"), { record, stdout: stdout.slice(0, 200), stderr: stderr.slice(0, 300), log: existsSync(traceLog) ? readFileSync(traceLog, "utf8").split("\n").filter((l) => l.includes("JSON refused")).slice(0, 3) : [] });
    return record;
  } finally {
    clearTimeout(timer);
    gateway.stop();
  }
}

let memo: Promise<TraceRecord[]> | undefined;
/** One run per case, once for all the tests. */
function observe(): Promise<TraceRecord[]> {
  memo ??= (async () => {
    const records: TraceRecord[] = [];
    // FX_WIRE_DEPTH_ONLY=<text> runs only the cases whose site holds it, to look at one.
    const only = process.env.FX_WIRE_DEPTH_ONLY;
    for (const [i, c] of cases.entries()) if (!only || c.site.includes(only)) records.push(await run(c, i));
    save(join(artifacts, "wire-depth-records.json"), records);
    console.log(`wire-depth verdicts:\n${records.map((r) => `  ${r.note}: ${String(r.data?.verdict)}`).join("\n")}`);
    return records;
  })();
  return memo;
}

function explain(v: Verdict): string {
  const log = v.runs.map((r) => (existsSync(r.log) ? readFileSync(r.log, "utf8").split("\n").slice(-25).join("\n") : "")).join("\n");
  return `${v.verdict} ${v.detail ?? ""} ${JSON.stringify(v.firstBad ?? {})}\n${log}`;
}

const constants = (limit: number) => ({ ObsLimit: limit, ObsCapacity: 256, ObsEngineLimit: 2581, ObsMaxDepth: 2600 });

test("What fx does with a server's nested JSON follows WireDepth.tla: accepted up to 128 levels, refused past them, never an abort (trace ACCEPTED)", async () => {
  const records = await observe();
  const verdict = await checkTrace({ module: "WireDepth", records, constants: constants(128), dir: join(artifacts, "wire-depth", "trace"), specDir: SPEC_DIR });
  save(join(artifacts, "wire-depth", "verdict.json"), verdict);
  expect(verdict.verdict === "ACCEPTED" ? "ACCEPTED" : explain(verdict)).toBe("ACCEPTED");
}, 900_000);

test("Control: the model of the host before the limit, which accepted whatever the engine handed it, REJECTS this trace", async () => {
  const records = await observe();
  const verdict = await checkTrace({ module: "WireDepth", records, constants: constants(2581), dir: join(artifacts, "wire-depth", "before"), specDir: SPEC_DIR });
  expect(verdict.verdict === "REJECTED" ? "REJECTED" : explain(verdict)).toBe("REJECTED");
}, 900_000);

test("Every run ended in a verdict: no result or tool was neither accepted nor refused", async () => {
  const records = await observe();
  expect(records.filter((r) => String(r.data?.verdict).startsWith("unknown")).map((r) => `${r.note}: ${r.data?.verdict}`)).toEqual([]);
});
