// Connect: the real `fx ask` with one `toolbox` search that starts 10, 25 or 50
// HTTP MCP servers together (tests/e2e/fixtures/mcp-many.ts). Each socket's
// connect events are read from the run, one trace per socket, and TLC checks
// each against Connect.tla: a connect that the kernel completed is never
// reported failed, a socket that is connecting is never given a second
// connect, and a cancel wins.
//
// The events are the FX_TRACE "net" lines of the macOS connect
// (src/core/shared/darwin_connect.zig):
//   net connect fd=<n> event=start|intr|reissue|done [result=ok|refused|canceled|other]
// or, for a binary built against a copy of std that logs std's own retry
// (the proof of the bug, kept in the G5b run folder), the "[g5b] connect fd="
// lines of that copy. A test named "control:" holds on any binary.
//
// FX_BIN is the binary under test. FX_BIN_RELEASE, when set, is a ReleaseSafe
// binary that runs the same checks. Off macOS the connect is std's own, so only
// the exit codes and the answers are checked.
import { expect, test } from "bun:test";
import { mkdirSync, readFileSync, existsSync, writeFileSync, realpathSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { artifacts, binary, targetHelpers, targetModule, testEnvironment } from "../lib/context";
import { checkTrace, type TraceRecord } from "./trace";

const { startDynamicFakeGateway, fakeGatewayFinalText, fakeGatewayToolCall } = await targetHelpers();
const { contentText } = await targetModule("conditional-guidance-oracle.ts");
const { startManyMcpHttpServers, writeManyMcpConfig } = await targetModule("fixtures/mcp-many.ts");

const MODEL = "openai/gpt-5";
const ON_MAC = process.platform === "darwin";

interface Seen { code: number; stderr: string; answer: string; traces: Map<string, TraceRecord[]>; intr: number; reissue: number }

/** Reads the per-socket events of one run: the wrapper's trace lines, or the lab std's. */
export function eventsOf(trace: string, stderr: string): Map<number, TraceRecord[]> {
  const byFd = new Map<number, TraceRecord[]>();
  const add = (fd: number, event: string, result?: string) => {
    const list = byFd.get(fd) ?? [];
    if (list.length === 0 && event !== "start") list.push({ event: "start" });
    list.push({ event, data: result === undefined ? {} : { result } });
    byFd.set(fd, list);
  };
  for (const line of trace.split("\n")) {
    const m = /\bnet connect fd=(\d+) event=(start|intr|reissue|done)(?: result=(\w+))?/.exec(line);
    if (m) add(Number(m[1]), m[2]!, m[3]);
  }
  for (const line of stderr.split("\n")) {
    let m = /^\[g5b\] connect fd=(\d+) EINTR is SPURIOUS/.exec(line);
    if (m) { add(Number(m[1]), "intr"); continue; }
    m = /^\[g5b\] connect fd=(\d+) RETRY after EINTR returned errno=(\w+)/.exec(line);
    if (m) add(Number(m[1]), "reissue");
  }
  return byFd;
}

async function runOnce(bin: string, servers: number): Promise<Seen> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-connect-")));
  const home = join(root, "home"), workspace = join(root, "workspace"), traceLog = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const many = startManyMcpHttpServers({ servers, toolsPerServer: 4 });
  writeManyMcpConfig(join(home, ".fx", "mcp.json"), many, servers);
  let answer = "";
  const gateway = startDynamicFakeGateway(
    (body: string) => {
      const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
      const part = prompt.flatMap((m) => (Array.isArray(m.content) ? m.content : []) as Array<Record<string, unknown>>)
        .find((p) => p.type === "tool-result" && p.toolCallId === "search_all");
      if (part) { answer = contentText(part.output); return fakeGatewayFinalText("CONNECT_DONE"); }
      return fakeGatewayToolCall("search_all", "toolbox", { search: "tool_01" });
    },
    { classifierDecision: "clear", models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  try {
    const proc = Bun.spawn([bin, "ask", "--json", "--auto", "--no-save", "Search every MCP server."], {
      cwd: workspace, stdout: "pipe", stderr: "pipe",
      env: testEnvironment({
        HOME: home, AI_GATEWAY_API_KEY: "fake-connect-key", FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: MODEL, FX_TRACE_LOG: traceLog, FX_TRACE_SCOPES: "net",
      }),
    });
    const [, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    const trace = existsSync(traceLog) ? readFileSync(traceLog, "utf8") : "";
    const byFd = eventsOf(trace, stderr);
    // One trace per distinct event pattern: TLC need not see the same pattern twice.
    const traces = new Map<string, TraceRecord[]>();
    let intr = 0, reissue = 0;
    for (const records of byFd.values()) {
      intr += records.filter((r) => r.event === "intr").length;
      reissue += records.filter((r) => r.event === "reissue").length;
      traces.set(records.map((r) => `${r.event}${r.data?.result ?? ""}`).join(","), records);
    }
    return { code: code as number, stderr, answer, traces, intr, reissue };
  } finally {
    gateway.stop();
    many.stop();
  }
}

const binaries: Array<[string, string]> = [["", binary]];
if (process.env.FX_BIN_RELEASE) binaries.push([" (release build)", process.env.FX_BIN_RELEASE]);

for (const [suffix, bin] of binaries) {
  for (const servers of [10, 25, 50]) {
    test(`${servers} HTTP servers started by one search${suffix}: every run ends, and every connect follows the model`, async () => {
      const dir = join(artifacts, `connect-${servers}${suffix.trim() ? "-release" : ""}`);
      mkdirSync(dir, { recursive: true });
      const runs = servers === 10 ? 6 : 10;
      let intr = 0, reissue = 0;
      const checked = new Map<string, string>();
      for (let run = 0; run < runs; run++) {
        const seen = await runOnce(bin, servers);
        // The answer ends the run whole: no abort, no lost server.
        expect(seen.stderr).not.toContain("programmer bug caused syscall error");
        expect([run, seen.code]).toEqual([run, 0]);
        expect(seen.answer).toContain("mcp_s0000_tool_01");
        intr += seen.intr;
        reissue += seen.reissue;
        if (!ON_MAC) continue;
        for (const [signature, records] of seen.traces) {
          if (checked.has(signature)) continue;
          const std = records.some((r) => r.event === "reissue");
          const verdict = await checkTrace({ module: "Connect", records, constants: { ObsStd: std }, dir: join(dir, `${run}-${checked.size}`) });
          checked.set(signature, verdict.verdict);
          expect([signature, verdict.verdict, verdict.broken ?? []]).toEqual([signature, "ACCEPTED", []]);
        }
      }
      // What the run saw: how many stray signals, and how many second connects (none for a correct connect).
      writeFileSync(join(dir, "summary.json"), JSON.stringify({ servers, runs, intr, reissue, patterns: [...checked] }, null, 2));
      expect(reissue).toBe(0);
    }, 600_000);
  }
}

test("control: a trace with a second connect on a connecting socket VIOLATES, and a stray signal that only ends a wait is ACCEPTED", async () => {
  const dir = join(artifacts, "connect-control");
  const ok = [{ event: "start" }, { event: "intr" }, { event: "done", data: { result: "ok" } }] as TraceRecord[];
  const bad = [{ event: "start" }, { event: "intr" }, { event: "reissue" }, { event: "done", data: { result: "unexpected" } }] as TraceRecord[];
  const g = await checkTrace({ module: "Connect", records: ok, constants: { ObsStd: false }, dir: join(dir, "good") });
  const b = await checkTrace({ module: "Connect", records: bad, constants: { ObsStd: true }, dir: join(dir, "bad") });
  expect(g.verdict).toBe("ACCEPTED");
  expect(b.verdict).toBe("VIOLATES");
}, 300_000);
