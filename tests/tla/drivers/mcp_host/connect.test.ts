// Connect: the real `fx ask` with one `toolbox` search that starts 10, 25 or 50
// HTTP MCP servers together (tests/e2e/fixtures/mcp-many.ts), and one that
// starts healthy servers beside a port nothing listens on. Each socket's
// connect events are read from the run, one trace per socket, and TLC checks
// each against Connect.tla: a connect that the kernel completed is never
// reported failed, a socket that is connecting is never given a second
// connect, a canceled connect ends canceled, and a stray signal only ends a
// wait.
//
// The events are the FX_TRACE "net" lines of fx's connect
// (src/core/shared/net_connect.zig), on macOS and Linux alike:
//   <ms> [net] connect fd=<n> event=start|intr|done [result=ok|refused|canceled|other]
// `start` is written for each call of the kernel's connect(2). fx calls it once per socket, so a socket
// whose `start` is followed by another `start` before its `done` is a second connect on a connecting socket,
// std's retry: the reader below turns it into a `reissue` record, and then the run fails twice: TLC
// does not accept the trace, and the run counts it.
// A refused connect shows start and then done on both systems: macOS answers a
// non-blocking connect with EINPROGRESS and reports the refusal through
// SO_ERROR, Linux may report it from connect itself, and the model allows
// the kernel's answer at any point after start.
//
// FX_BIN is the binary under test. FX_BIN_RELEASE, when set, is a ReleaseSafe
// binary that runs the same checks.
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

/** A port nothing listens on: listen on a free port, read it, stop. */
function closedPort(): number {
  const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = listener.port;
  listener.stop(true);
  return port;
}

interface Seen { code: number; stderr: string; answer: string; traces: Map<string, TraceRecord[]>; connects: number; intr: number; reissue: number }

/**
 * Reads the per-socket events of one run from the connect's trace lines. A socket's life starts at its `start`
 * event and ends at its `done`: the kernel gives a closed socket's descriptor number to a later connect, so one
 * number can carry several connects one after another. A `start` for a number whose socket has not finished is a
 * second connect on that socket, and is read as a `reissue`.
 */
function eventsOf(trace: string): TraceRecord[][] {
  const sockets: TraceRecord[][] = [];
  const open = new Map<number, TraceRecord[]>();
  for (const line of trace.split("\n")) {
    const m = /\[net\] connect fd=(\d+) event=(start|intr|done)(?: result=(\w+))?/.exec(line);
    if (!m) continue;
    const fd = Number(m[1]);
    let list = open.get(fd);
    if (m[2] === "start" && list !== undefined) {
      list.push({ event: "reissue", data: {} });
      continue;
    }
    if (m[2] === "start" || list === undefined) {
      list = [];
      open.set(fd, list);
      sockets.push(list);
    }
    list.push({ event: m[2]!, data: m[3] === undefined ? {} : { result: m[3] } });
    if (m[2] === "done") open.delete(fd);
  }
  return sockets;
}

async function runOnce(bin: string, servers: number, deadPorts = 0): Promise<Seen> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-connect-")));
  const home = join(root, "home"), workspace = join(root, "workspace"), traceLog = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const many = startManyMcpHttpServers({ servers, toolsPerServer: 4 });
  writeManyMcpConfig(join(home, ".fx", "mcp.json"), many, servers);
  if (deadPorts > 0) {
    // Servers nobody listens on, next to the healthy ones: their connects are refused.
    const config = JSON.parse(readFileSync(join(home, ".fx", "mcp.json"), "utf8")) as { mcp: Record<string, unknown> };
    for (let i = 0; i < deadPorts; i++) config.mcp[`dead${i}`] = { type: "http", url: `http://127.0.0.1:${closedPort()}/mcp`, startup_timeout_ms: 5000 };
    writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify(config));
  }
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
    const sockets = eventsOf(trace);
    // One trace per distinct event pattern: TLC need not see the same pattern twice.
    const traces = new Map<string, TraceRecord[]>();
    let intr = 0, reissue = 0;
    for (const records of sockets) {
      intr += records.filter((r) => r.event === "intr").length;
      reissue += records.filter((r) => r.event === "reissue").length;
      traces.set(records.map((r) => `${r.event}${r.data?.result ?? ""}`).join(","), records);
    }
    return { code: code as number, stderr, answer, traces, connects: sockets.length, intr, reissue };
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
        // Every server's connect left its events: a run that wrote none did not reach the connect.
        expect(seen.connects).toBeGreaterThanOrEqual(servers);
        intr += seen.intr;
        reissue += seen.reissue;
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

for (const [suffix, bin] of binaries) {
  test(`10 healthy HTTP servers beside 2 closed ports${suffix}: the refused connects end failed, the rest connect, and every connect follows the model`, async () => {
    const dir = join(artifacts, `connect-refused${suffix.trim() ? "-release" : ""}`);
    mkdirSync(dir, { recursive: true });
    const checked = new Map<string, string>();
    let refused = 0;
    for (let run = 0; run < 4; run++) {
      const seen = await runOnce(bin, 10, 2);
      expect(seen.stderr).not.toContain("programmer bug caused syscall error");
      expect([run, seen.code]).toEqual([run, 0]);
      expect(seen.answer).toContain("mcp_s0000_tool_01");
      for (const [signature, records] of seen.traces) {
        refused += records.filter((r) => r.event === "done" && r.data?.result === "refused").length;
        if (checked.has(signature)) continue;
        const verdict = await checkTrace({ module: "Connect", records, constants: { ObsStd: false }, dir: join(dir, `${run}-${checked.size}`) });
        checked.set(signature, verdict.verdict);
        expect([signature, verdict.verdict, verdict.broken ?? []]).toEqual([signature, "ACCEPTED", []]);
      }
    }
    // macOS reports the refusal through SO_ERROR after EINPROGRESS and Linux may report it from connect itself; both are start, then done.
    expect(refused).toBeGreaterThan(0);
    writeFileSync(join(dir, "summary.json"), JSON.stringify({ runs: 4, refused, patterns: [...checked] }, null, 2));
  }, 600_000);
}

const lines = (...events: string[]) => events.map((event, i) => `${i} [net] connect fd=7 event=${event}`).join("\n");

test("the trace reader: a second start on a socket that has not finished is a reissue, and a descriptor number used again after done is a new socket", () => {
  expect(eventsOf(lines("start", "intr", "done result=ok")).map((r) => r.map((e) => e.event))).toEqual([["start", "intr", "done"]]);
  // Two connect(2) calls before the socket's done: std's retry.
  expect(eventsOf(lines("start", "intr", "start", "done result=ok")).map((r) => r.map((e) => e.event))).toEqual([["start", "intr", "reissue", "done"]]);
  // The kernel gave descriptor 7 to a later connect.
  expect(eventsOf(lines("start", "done result=ok", "start", "done result=refused")).map((r) => r.map((e) => e.event))).toEqual([
    ["start", "done"],
    ["start", "done"],
  ]);
});

// The startup commands never connect: with the `net` scope on, `fx help` and `fx --version` leave no connect
// line. This holds on any binary, one without the trace line included, so it shows that these commands do not
// connect, and nothing about the line itself.
for (const args of [["help"], ["--version"]]) {
  test(`fx ${args.join(" ")} writes no net connect trace line`, async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-connect-startup-")));
    const home = join(root, "home"), traceLog = join(root, "trace.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    writeFileSync(join(home, ".fx", "settings.json"), "{}");
    const proc = Bun.spawn([binary, ...args], {
      cwd: root, stdout: "pipe", stderr: "pipe",
      env: testEnvironment({ HOME: home, FX_TRACE_LOG: traceLog, FX_TRACE_SCOPES: "net" }),
    });
    const [out, , code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    expect(code).toBe(0);
    expect(out.length).toBeGreaterThan(0);
    const trace = existsSync(traceLog) ? readFileSync(traceLog, "utf8") : "";
    expect(trace).not.toContain("connect fd=");
  }, 60_000);
}
