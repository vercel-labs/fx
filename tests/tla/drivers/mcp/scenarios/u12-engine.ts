// U12 engine, step 6: tests/tla/drivers/mcp/labs/engine_lab.zig drives src/mcp/engine.zig
// over fake stdio servers (tests/tla/drivers/mcp/fakes/stdio.ts), one per name. Every
// server's machines trace into one file: the engine gate under the server's
// name, and its stdio core, request table, era, catalog, subscriptions,
// rounds, and elicitations under "<name>.". Request ids and logical handles
// count per server: detection is x1, the tool list listen x2, and calls
// follow, so a call's rounds are the instance after them.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { HttpRule } from "../fakes/http";
import type { Rule } from "../fakes/stdio";
import type { Scenario, ScenarioContext, TraceExpectation } from "../scenario";

const FAKE = join(import.meta.dir, "../fakes/stdio.ts");
const FAKE_HTTP = join(import.meta.dir, "../fakes/http.ts");
const WITH_SERVER = join(import.meta.dir, "../with-server.ts");
const MODERN = "2026-07-28";
const LEGACY = "2025-11-25";

// ---- fake servers ----

const discover: Rule = { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: { listChanged: true } } } };
const listen: Rule = { method: "subscriptions/listen", noReply: true };
const tool = (name: string) => ({ name, inputSchema: { type: "object" } });
const list = (...names: string[]): Rule => ({ method: "tools/list", result: { resultType: "complete", tools: names.map(tool) } });
const ok = (text: string, extra: Partial<Rule> = {}): Rule => ({ method: "tools/call", result: { resultType: "complete", content: [{ type: "text", text }] }, ...extra });
const initialize: Rule = { method: "initialize", result: { protocolVersion: LEGACY, capabilities: { tools: {} }, serverInfo: { name: "fake", version: "1" } } };
const list25 = (...names: string[]): Rule => ({ method: "tools/list", result: { tools: names.map(tool) } });
const ok25 = (text: string, extra: Partial<Rule> = {}): Rule => ({ method: "tools/call", result: { content: [{ type: "text", text }] }, ...extra });
const crash = (name: string): Rule => ({ method: "tools/call", tool: name, noReply: true, then: "crash" });
export const modern = (...extra: Rule[]): Rule[] => [discover, listen, list("echo"), ...extra, ok("fine")];
export const legacy = (...extra: Rule[]): Rule[] => [initialize, list25("add"), ...extra, ok25("fine")];

// ---- the lab ----

interface Line {
  did?: { action?: string; expect?: string; met?: boolean; error?: string; line?: string; k?: number };
  allow?: { server: string; tool: string; ok: boolean };
  event?: { tag: string; maybe_ran?: boolean; answer?: string | null; names?: string[]; k?: number };
  status?: { name: string; phase: string; version: string | null; tools: number; last_error: string | null }[];
  final?: { ok: boolean; logged: { name: string; lines: number }[] };
}
type Log = { dir: string; line: string }[];
/** One line of the trace every machine writes. */
type Step = { machine: string; inst: string; event: string; from: string; to: string; data?: { id?: number; progress?: number; outcome?: string } };
type Machine = "engine" | "stdio" | "request" | "era" | "catalog" | "subscription" | "elicitation" | { mrtr: string };

interface EngineCase {
  name: string;
  description: string;
  /** Each a fake stdio server with these rules, or `argv` run as it is. `{caseDir}` in a flag is the case's directory. */
  servers: { [name: string]: { rules: Rule[]; flags?: string[]; argv?: string[] } };
  /** One server on the fake HTTP server, declared first, as "server <name> http {URL}". */
  http?: { name: string; rules: HttpRule[]; flags?: string[] };
  /** Errors script steps are meant to hit, in order, such as a refused answer. */
  errors?: string[];
  script: string[];
  labFlags?: string[];
  /** The engine's tries in a row. */
  maxAttempts?: number;
  /** The machines to check per server; a server left out is checked for none. */
  machines: { [name: string]: Machine[] };
  /** A planted control: the attempts the engine trace's model is given, and the verdict expected. */
  control?: { server: string; maxAttempts: number };
  check?: (lines: Line[], logs: { [name: string]: Log }, trace: Step[]) => string | null;
  timeoutMs?: number;
}

const BASE: Machine[] = ["engine", "stdio", "request", "era"];
/** One 64 KiB notification line, for `yes` to repeat (u12-flood). */
const FLOOD_LINE = JSON.stringify({ jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "x".repeat(65536) } });
/** server/discover's answer for a stdio server written in shell. */
const STUCK_DISCOVER = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } });

function engineScenario(c: EngineCase): Scenario {
  let caseDir = "";
  let tracePath = "";
  const attempts = c.maxAttempts ?? 8;
  const traces: TraceExpectation[] = [];
  for (const [server, machines] of Object.entries(c.machines)) {
    for (const m of machines) {
      const remote = `${server}.remote`;
      if (m === "engine") {
        const control = c.control?.server === server ? c.control : undefined;
        traces.push({ machine: "engine", instance: server, specDir: "tests/tla/mcp", wrapper: "EngineTrace", verdict: control ? "REJECTED" : "ACCEPTED", constants: { ObsMaxAttempts: control?.maxAttempts ?? attempts } });
      } else if (m === "stdio") traces.push({ machine: "stdio", instance: `${server}.stdio`, specDir: "tests/tla/mcp", wrapper: "StdioConnTrace", verdict: "ACCEPTED", constants: { ObsMaxAttempts: 255 } });
      else if (m === "request") traces.push({ machine: "request", instance: remote, specDir: "tests/tla/mcp", wrapper: "RequestTrace", verdict: "ACCEPTED" });
      else if (m === "era") traces.push({ machine: "era", instance: remote, specDir: "tests/tla/mcp", wrapper: "EraTrace", verdict: "ACCEPTED", constants: { ObsPreferredCount: 1 } });
      else if (m === "catalog") traces.push({ machine: "catalog", instance: remote, specDir: "tests/tla/mcp", wrapper: "CatalogTrace", verdict: "ACCEPTED", constants: { ObsMaxPages: 100 } });
      else if (m === "subscription") traces.push({ machine: "subscription", instance: remote, specDir: "tests/tla/mcp", wrapper: "SubscriptionTrace", verdict: "ACCEPTED", constants: { ObsMaxTries: 8 } });
      else if (m === "elicitation") traces.push({ machine: "elicitation", instance: remote, specDir: "tests/tla/mcp", wrapper: "ElicitationTrace", verdict: "ACCEPTED", constants: { ObsMaxPending: 16 } });
      else traces.push({ machine: "mrtr", instance: `${server}.${m.mrtr}`, specDir: "tests/tla/mcp", wrapper: "MrtrTrace", verdict: "ACCEPTED", constants: { ObsMaxRequests: 10, ObsMaxKeys: 16 } });
    }
  }
  return {
    name: c.name,
    unit: "U12",
    description: c.description,
    needs: ["engine_lab"],
    setup: (ctx: ScenarioContext) => {
      caseDir = ctx.caseDir;
      tracePath = ctx.tracePath;
      const declared = Object.entries(c.servers).map(([name, s]) => {
        const rules = join(ctx.caseDir, `${name}.rules.json`);
        writeFileSync(rules, JSON.stringify(s.rules));
        const flags = (s.flags ?? []).map((f) => f.replaceAll("{caseDir}", ctx.caseDir));
        const argv = s.argv ?? [process.execPath, FAKE, "--script", rules, "--log", join(ctx.caseDir, `${name}.jsonl`), ...flags];
        return `server ${name} stdio ${JSON.stringify(argv)}`;
      });
      if (c.http) {
        writeFileSync(join(ctx.caseDir, "http.rules.json"), JSON.stringify(c.http.rules));
        declared.unshift(`server ${c.http.name} http {URL}`);
      }
      writeFileSync(join(ctx.caseDir, "script.txt"), [...declared, ...c.script].join("\n") + "\n");
    },
    command: (ctx: ScenarioContext) => {
      const lab = [ctx.bin.engine_lab, ctx.tracePath, join(ctx.caseDir, "script.txt"), "--probe-ms", "3000", "--max-attempts", String(attempts), ...(c.labFlags ?? [])];
      if (!c.http) return lab;
      const server = [process.execPath, FAKE_HTTP, "--script", join(ctx.caseDir, "http.rules.json"), "--log", join(ctx.caseDir, `${c.http.name}.jsonl`), ...(c.http.flags ?? [])];
      // Bun takes a leading "--" as its own, so an --env comes first.
      return [process.execPath, WITH_SERVER, "--env", "MCPV2_ENGINE=1", "--", ...server, "--", ...lab, "--define", "URL=http://127.0.0.1:{port}/mcp"];
    },
    expect: {
      exit: 0,
      traces,
      stdout: (text) => {
        const lines = text.split("\n").filter(Boolean).map((l) => JSON.parse(l) as Line);
        const errors = [...(c.errors ?? [])];
        const unmet = lines.find((l) => l.did?.met === false || (l.did?.error !== undefined && l.did.error !== errors.shift()));
        if (unmet) return `script step failed: ${JSON.stringify(unmet.did)}`;
        if (errors.length > 0) return `errors that never came: ${errors.join(", ")}`;
        if (!lines.at(-1)?.final?.ok) return "no final line, or the script didn't finish";
        const logs: { [name: string]: Log } = {};
        for (const name of [...Object.keys(c.servers), ...(c.http ? [c.http.name] : [])]) {
          const path = join(caseDir, `${name}.jsonl`);
          logs[name] = existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
        }
        if (!c.check) return null;
        const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as Step) : [];
        return c.check(lines, logs, trace);
      },
    },
    timeoutMs: c.timeoutMs ?? 60_000,
  };
}

const tags = (lines: Line[]) => lines.filter((l) => l.event).map((l) => l.event!.tag);
const event = (lines: Line[], prefix: string) => lines.find((l) => l.event?.tag.startsWith(prefix))?.event;
const lastStatus = (lines: Line[]) => lines.filter((l) => l.status).at(-1)!.status!;
const status = (lines: Line[], name: string) => lastStatus(lines).find((s) => s.name === name);
const received = (log: Log, method: string) => log.filter((l) => l.dir === "in").map((l) => JSON.parse(l.line)).filter((m) => m.method === method);
/** What the fake HTTP server received, by JSON-RPC method. */
const posted = (log: Log, method: string) =>
  (log as unknown as { dir: string; body?: string }[]).filter((l) => l.dir === "in" && l.body).map((l) => JSON.parse(l.body!)).filter((m) => m.method === method);
const replies = (log: Log) => log.filter((l) => l.dir === "in").map((l) => JSON.parse(l.line)).filter((m) => m.method === undefined);
const first = (...checks: (string | null)[]) => checks.find((x) => x !== null) ?? null;
const expectThat = (ok: boolean, what: string) => (ok ? null : what);
const same = (got: unknown, want: unknown, what: string) => (JSON.stringify(got) === JSON.stringify(want) ? null : `${what} were ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);

const form = { mode: "form", message: "Name?", requestedSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } };
const askName = { k: { method: "elicitation/create", params: form } };
const FORM = ["--capabilities", JSON.stringify({ elicitation: { form: {} } })];

export const scenarios: Scenario[] = [
  engineScenario({
    name: "u12-two-servers",
    description: "Two stdio servers at once, a 2026 one and a 2025 one: each starts for its first call, both answer, both list their tools, and the 2025 one's stderr reaches the host's sink",
    servers: { a: { rules: modern() }, b: { rules: legacy({ ...ok25("from b"), stderr: ["b says hi"] }) } },
    script: ["status", 'call a echo {"x":1}', "call b add", "expect a.called.1.result", "expect b.called.2.result", "tools a", "expect a.tools.ok", "tools b", "expect b.tools.ok"],
    machines: { a: [...BASE, "catalog", "subscription"], b: [...BASE, "catalog"] },
    check(lines) {
      const before = lines.find((l) => l.status)!.status!;
      return first(
        same(before.map((s) => s.phase), ["idle", "idle"], "phases before anything"),
        same([status(lines, "a")?.version, status(lines, "b")?.version], [MODERN, LEGACY], "versions"),
        same([status(lines, "a")?.tools, status(lines, "b")?.tools], [1, 1], "tool counts"),
        same(event(lines, "b.called.2")?.answer, '[{"type":"text","text":"from b"}]', "b's answer"),
        same(lines.at(-1)!.final!.logged, [{ name: "a", lines: 0 }, { name: "b", lines: 1 }], "stderr lines logged"),
      );
    },
  }),
  engineScenario({
    name: "u12-lazy",
    description: "A server nothing needs never starts: listing one server's tools leaves the other idle, with no process (LazyConnect)",
    servers: { a: { rules: modern() }, b: { rules: modern() } },
    script: ["tools a", "expect a.tools.ok", "drain 300"],
    machines: { a: [...BASE, "catalog", "subscription"] },
    check: (lines, logs) => first(same(status(lines, "b")?.phase, "idle", "b's phase"), expectThat(logs.b.length === 0, "b's process saw something"), expectThat(!tags(lines).some((t) => t.startsWith("b.")), "b said something")),
  }),
  engineScenario({
    name: "u12-denied",
    description: "A call the host refuses ends denied at once, and its server never starts for it (SEC-01)",
    servers: { a: { rules: modern() } },
    labFlags: ["--deny", "rm"],
    script: ['call a rm {"path":"/"}', "expect a.called.1.denied 2000", "drain 300"],
    machines: { a: ["engine"] },
    check: (lines, logs) =>
      first(
        same(lines.filter((l) => l.allow).map((l) => l.allow), [{ server: "a", tool: "rm", ok: false }], "permission asks"),
        same(status(lines, "a")?.phase, "idle", "a's phase"),
        expectThat(logs.a.length === 0, "a's process started"),
      ),
  }),
  engineScenario({
    name: "u12-one-failing",
    description: "A server whose process dies at every start gives up after its tries in a row and ends what waits transport_failed, and a later call at once; another server is untouched",
    servers: { a: { rules: modern(), flags: ["--exit-at-start", "1"] }, b: { rules: modern() } },
    maxAttempts: 2,
    script: ["call a echo", "call b echo", "expect b.called.2.result", "expect a.called.1.transport_failed 15000", "call a echo", "expect a.called.3.transport_failed 2000"],
    machines: { a: ["engine", "stdio"], b: [...BASE, "subscription"] },
    check: (lines) =>
      first(
        same([status(lines, "a")?.phase, status(lines, "a")?.last_error], ["failed", "process"], "a's status"),
        same(status(lines, "b")?.phase, "ready", "b's phase"),
        same(tags(lines).filter((t) => t.startsWith("a.phase")), ["a.phase.connecting", "a.phase.backoff", "a.phase.connecting", "a.phase.failed"], "a's phases"),
      ),
  }),
  engineScenario({
    name: "u12-reconnect",
    description: "Reconnect drops a ready server's process and starts a new one, which detects again and serves the next call",
    servers: { a: { rules: modern() } },
    script: ["tools a", "expect a.phase.ready", "expect a.tools.ok", "reconnect a", "expect a.phase.idle", "expect a.phase.ready 10000", "call a echo", "expect a.called.1.result"],
    machines: { a: [...BASE, "catalog", "subscription"] },
    check: (lines, logs) => first(same(received(logs.a, "server/discover").length, 2, "detections"), expectThat(tags(lines).includes("a.phase.idle"), "no idle phase between")),
  }),
  engineScenario({
    name: "u12-crash-lost",
    description: "A process that dies during a call loses it, maybe run; the next call waits out the backoff and starts the server again",
    servers: { a: { rules: modern(crash("boom")) } },
    script: ["call a boom", "expect a.called.1.lost 10000", "call a echo", "expect a.called.2.result 15000"],
    machines: { a: [...BASE, "subscription"] },
    check: (lines, logs) => first(same(event(lines, "a.called.1")?.maybe_ran, true, "maybe_ran"), same(received(logs.a, "server/discover").length, 2, "processes")),
  }),
  engineScenario({
    name: "u12-crash-forgets",
    description: "A process exit also ends what it had in flight in the request table (U02): once the request timeout has passed, the new process hears no cancellation for the old call, and the host no second end",
    servers: { a: { rules: modern(crash("boom")) } },
    labFlags: ["--timeout-ms", "1500"],
    script: ["call a boom", "expect a.called.1.lost 10000", "call a echo", "expect a.called.2.result 15000", "drain 2500"],
    machines: { a: [...BASE, "subscription"] },
    check: (lines, logs) =>
      first(
        same(received(logs.a, "notifications/cancelled").length, 0, "cancellations sent"),
        same(lines.filter((l) => l.event?.tag.startsWith("a.called.1.")).length, 1, "ends of call 1"),
      ),
  }),
  engineScenario({
    name: "u12-spawn-fails",
    description: "A command that can't be started fails within its tries instead of looking busy: each failed spawn is a down (found by mcpv2 list --connect), the waiting call ends transport_failed, and the status names the spawn error",
    servers: { a: { rules: [], argv: ["/nonexistent/mcp-server"] } },
    maxAttempts: 2,
    script: ["call a echo", "expect a.called.1.transport_failed 10000", "expect a.phase.failed 1000", "status"],
    machines: { a: ["engine", "stdio"] },
    check: (lines) => same(lines.filter((l) => l.status).at(-1)?.status?.[0]?.last_error, "FileNotFound", "last errors"),
  }),
  engineScenario({
    name: "u12-stderr-flood",
    description: "5000 stderr lines during a call all reach the host's sink, written by the reader task, with none dropped",
    servers: { a: { rules: modern({ ...ok("done"), stderr: ["noise"], stderrRepeat: 5000 }) } },
    script: ["call a echo", "expect a.called.1.result 20000", "drain 500"],
    machines: { a: [...BASE, "subscription"] },
    check: (lines) => same(lines.at(-1)!.final!.logged, [{ name: "a", lines: 5000 }], "stderr lines logged"),
  }),
  engineScenario({
    name: "u12-flood",
    description: "A server that floods 64 KiB notifications faster than they are read, and never answers, can't hold the engine: another server's call answers meanwhile, and the flooding server's probe and initialize still time out, so it fails. Its stdio trace, a step per line, is left unchecked",
    servers: { a: { rules: [], argv: ["/usr/bin/yes", FLOOD_LINE] }, b: { rules: modern() } },
    maxAttempts: 1,
    labFlags: ["--timeout-ms", "1000"],
    // Before the fix the engine read a's flood without end, so even drain hung.
    script: ["call b echo", "expect b.called.1.result 10000", "tools a", "drain 500", "call b echo", "expect b.called.2.result 700", "expect a.phase.failed 15000"],
    machines: { a: ["engine", "era"], b: [...BASE, "subscription"] },
  }),
  engineScenario({
    name: "u12-cancel-waiting",
    description: "A call cancelled while its server is still starting ends cancelled and never reaches the server",
    servers: { a: { rules: modern(), flags: ["--start-delay", "1500"] } },
    script: ["call a echo", "cancel 1", "expect a.called.1.cancelled 2000", "expect a.phase.ready 10000", "drain 300"],
    machines: { a: [...BASE, "subscription"] },
    check: (_lines, logs) => expectThat(received(logs.a, "tools/call").length === 0, "the call reached the server"),
  }),
  engineScenario({
    name: "u12-input-stdio",
    description: "A 2026 call over stdio that comes back input_required asks the host, and the next round carries its answer under the server's key (MRTR-02, MRTR-03)",
    servers: { a: { rules: modern({ method: "tools/call", times: 1, result: { resultType: "input_required", inputRequests: askName } }) } },
    labFlags: FORM,
    script: ["call a ask", "expect a.input.1", 'respond 1 [{"action":"accept","content":{"name":"Ada"}}]', "expect a.called.1.result"],
    machines: { a: [...BASE, "subscription", { mrtr: "x3" }] },
    check: (_lines, logs) => {
      const calls = received(logs.a, "tools/call");
      return first(same(calls.length, 2, "tools/call requests"), same(calls[1]?.params?.inputResponses, { k: { action: "accept", content: { name: "Ada" } } }, "the second round's answers"));
    },
  }),
  engineScenario({
    name: "u12-elicit-stdio",
    description: "A 2025 server's elicitation/create over stdio reaches the host, whose answer goes back on stdin as a response (ELIC-09)",
    servers: { b: { rules: legacy({ ...ok25("asked"), before: [{ jsonrpc: "2.0", id: "e1", method: "elicitation/create", params: form }] }) } },
    labFlags: FORM,
    script: ["call b go", "expect b.elicit 5000", 'elicit b 1 accept {"name":"Ada"}', "expect b.called.1.result 5000", "drain 300"],
    machines: { b: [...BASE, "elicitation"] },
    check: (_lines, logs) => same(replies(logs.b).find((m) => m.id === "e1")?.result, { action: "accept", content: { name: "Ada" } }, "the elicitation's answer"),
  }),
  engineScenario({
    name: "u12-ping-during-initialize",
    description: "A 2025 stdio server that pings before it answers initialize gets its pong: the connection takes a response before detection ends (STDIO-09)",
    servers: { b: { rules: [{ ...initialize, before: [{ jsonrpc: "2.0", id: "p1", method: "ping" }] }, list25("add"), ok25("fine")] } },
    script: ["tools b", "expect b.tools.ok", "drain 300"],
    machines: { b: BASE },
    check: (_lines, logs) => same(replies(logs.b).find((m) => m.id === "p1")?.result, {}, "the ping's answer"),
  }),
  engineScenario({
    name: "u12-ping-after-initialize",
    description: "Control: a 2025 stdio server's ping once it's ready gets its pong (STDIO-09)",
    servers: { b: { rules: [initialize, { ...list25("add"), before: [{ jsonrpc: "2.0", id: "p2", method: "ping" }] }, ok25("fine")] } },
    script: ["tools b", "expect b.tools.ok", "drain 300"],
    machines: { b: BASE },
    check: (_lines, logs) => same(replies(logs.b).find((m) => m.id === "p2")?.result, {}, "the ping's answer"),
  }),
  engineScenario({
    name: "u12-elicit-withdrawn",
    description: "A 2025 server withdraws its elicitation and asks another, which takes the same slot: the host's answer to the first is refused and reaches no one, and its answer to the second reaches the second (fx P0 bug 8)",
    servers: {
      b: {
        rules: legacy({
          ...ok25("asked"),
          before: [
            { jsonrpc: "2.0", id: "e1", method: "elicitation/create", params: form },
            { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: "e1", reason: "asked again" } },
            { jsonrpc: "2.0", id: "e2", method: "elicitation/create", params: form },
          ],
        }),
      },
    },
    labFlags: FORM,
    errors: ["UnknownElicitation"],
    script: ["call b go", "expect b.elicit 5000", "expect b.elicit_withdrawn 5000", "expect b.elicit 5000", 'elicit b 1 accept {"name":"for-1"}', 'elicit b 2 accept {"name":"for-2"}', "expect b.called.1.result 5000", "drain 300"],
    machines: { b: [...BASE, "elicitation"] },
    check: (lines, logs) =>
      first(
        same(replies(logs.b).filter((m) => m.id === "e1" || m.id === "e2"), [{ jsonrpc: "2.0", id: "e2", result: { action: "accept", content: { name: "for-2" } } }], "the elicitations' answers"),
        same(lines.filter((l) => l.did?.action === "elicit").map((l) => l.did?.error ?? "sent"), ["UnknownElicitation", "sent"], "the host's two answers"),
      ),
  }),
  engineScenario({
    name: "u12-reload",
    description: "A reload without a server drops it and keeps the other running on the same process",
    servers: { a: { rules: modern() }, b: { rules: modern() } },
    script: ["tools a", "tools b", "expect a.tools.ok", "expect b.tools.ok", "reload a", "drain 300", "call a echo", "expect a.called.1.result"],
    machines: { a: [...BASE, "catalog", "subscription"], b: [...BASE, "catalog", "subscription"] },
    check: (lines, logs) => first(same(lastStatus(lines).map((s) => s.name), ["a"], "servers after the reload"), same(received(logs.a, "server/discover").length, 1, "a's detections")),
  }),
  engineScenario({
    name: "u12-subscription-restart",
    description: "After a crash, the tool list subscription waiting to listen again starts the server by itself once the backoff is over, and listens again (SUBS-05)",
    servers: { a: { rules: modern(crash("boom")) } },
    script: ["tools a", "expect a.phase.ready", "expect a.tools.ok", "drain 300", "call a boom", "expect a.called.1.lost 10000", "expect a.phase.ready 15000", "drain 500"],
    machines: { a: [...BASE, "catalog", "subscription"] },
    check: (_lines, logs) => first(same(received(logs.a, "server/discover").length, 2, "processes"), same(received(logs.a, "subscriptions/listen").length, 2, "listens")),
  }),
  engineScenario({
    name: "u12-http-and-stdio",
    description: "An HTTP server and a stdio server behind one engine: both start for their calls and answer; reconnecting the HTTP one drops its detection and detects again, and the stdio one keeps its process",
    http: { name: "h", rules: [{ method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } }, { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } }, { method: "tools/call", result: { resultType: "complete", content: [{ type: "text", text: "from h" }] } }] },
    servers: { a: { rules: modern() } },
    labFlags: ["--no-listen"],
    script: ["call h echo", "call a echo", "expect h.called.1.result", "expect a.called.2.result", "reconnect h", "expect h.phase.idle", "expect h.phase.ready 10000", "tools h", "expect h.tools.ok", "call a echo", "expect a.called.3.result"],
    machines: { h: ["engine", "request", "era", "catalog"], a: BASE },
    check: (lines, logs) =>
      first(
        same(posted(logs.h, "server/discover").length, 2, "h's detections"),
        same(received(logs.a, "server/discover").length, 1, "a's detections"),
        same(event(lines, "h.called.1")?.answer, '[{"type":"text","text":"from h"}]', "h's answer"),
        same([status(lines, "h")?.phase, status(lines, "a")?.phase], ["ready", "ready"], "phases"),
      ),
  }),
  engineScenario({
    name: "u12-http-initialized-timeout",
    description: "A 2025 HTTP server answers initialize but never answers notifications/initialized: after the request timeout the session fails with initialized_timed_out, and the server goes down instead of looking ready with no tools (CORE-6b)",
    http: {
      name: "h",
      flags: ["--session", "--initialized-delay", "30000"],
      rules: [
        { method: "initialize", result: initialize.result },
        { method: "tools/list", result: { tools: [tool("echo")] } },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "800"],
    script: ["tools h", "expect h.phase.ready 5000", "expect h.phase.backoff 5000", "status"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (lines, logs) => {
      const raw = logs.h as unknown as { dir: string; body?: string }[];
      return first(
        same(status(lines, "h")?.last_error, "initialized_timed_out", "h's last error"),
        raw.some((l) => l.dir === "in" && l.body?.includes('"tools/list"')) ? "tools/list went out before initialized was answered" : null,
      );
    },
  }),
  engineScenario({
    name: "u12-http-reinit-timeout",
    description: "A 2025 HTTP session ends after a call, and the new initialize for the next call never answers: that call times out, the initialize times out too, its stream is closed, and the session fails; the server goes down and starts again by itself, and the third call works",
    http: {
      name: "h",
      flags: ["--session"],
      rules: [
        { method: "initialize", result: initialize.result, times: 1 },
        { method: "initialize", result: initialize.result, sse: true, hang: true, times: 1 },
        { method: "initialize", result: initialize.result },
        { method: "tools/list", result: { tools: [tool("echo")] } },
        { method: "tools/call", result: { content: [{ type: "text", text: "first" }] }, endSession: true, times: 1 },
        { method: "tools/call", result: { content: [{ type: "text", text: "again" }] } },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "800"],
    script: ["call h echo", "expect h.called.1.result 5000", "call h echo", "expect h.called.2.cancelled 5000", "expect h.phase.backoff 5000", "call h echo", "expect h.called.3.result 10000", "status"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (lines, logs) => {
      // The hung initialize's stream must close before the restart's
      // initialize, not when the lab exits.
      const raw = logs.h as unknown as { t: number; dir: string; id?: number; body?: string }[];
      const inits = raw.filter((l) => l.dir === "in" && l.body && JSON.parse(l.body).method === "initialize");
      const hung = inits[1] && JSON.parse(inits[1].body!).id;
      const closedAt = raw.find((l) => l.dir === "closed" && l.id === hung)?.t;
      return first(
        same(inits.length, 3, "initialize posts"),
        closedAt !== undefined && closedAt < inits[2].t ? null : "the second initialize's stream was not closed before the restart",
        same(event(lines, "h.called.3")?.answer, '[{"type":"text","text":"again"}]', "the third call's answer"),
      );
    },
  }),
  engineScenario({
    name: "u12-stopped-reading",
    description: "A stdio server stops reading stdin and gets a call bigger than a pipe holds: only that server's stdin writer waits, so another server's call still answers and the stuck call times out",
    servers: {
      // Answers server/discover, then never reads stdin again; a Bun fake
      // keeps reading into its own buffer, so this is a shell.
      a: { rules: [], argv: ["/bin/sh", "-c", `read -r _; printf '%s\\n' '${STUCK_DISCOVER}'; exec sleep 60`] },
      b: { rules: modern() },
    },
    labFlags: ["--no-listen", "--timeout-ms", "800"],
    script: [`call a echo {"text":"${"x".repeat(300_000)}"}`, "call b echo", "expect b.called.2.result 5000", "expect a.called.1.cancelled 5000"],
    machines: { a: BASE, b: BASE },
    check: (lines) =>
      first(
        same(event(lines, "b.called.2")?.answer, '[{"type":"text","text":"fine"}]', "b's answer"),
        same(event(lines, "a.called.1")?.timed_out, true, "the stuck call timed out"),
      ),
  }),
  engineScenario({
    name: "u12-progress-one-idle-timer",
    description: "Progress re-arms a call's idle timer in place: no stale timer is left to fire, another call's idle timer is its own, and the hard limit still ends the call",
    servers: {
      a: {
        rules: modern(
          { method: "tools/call", tool: "hang", noReply: true },
          {
            method: "tools/call",
            tool: "slow",
            before: Array.from({ length: 30 }, (_, n) => ({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "$id", progress: n + 1 } })),
            beforeEveryMs: 100,
            result: { resultType: "complete", content: [{ type: "text", text: "late" }] },
          },
        ),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "300", "--hard-ms", "1500"],
    script: ["call a hang", "call a slow", "expect a.called.1.cancelled 1000", "expect a.called.2.cancelled 4000"],
    machines: { a: BASE },
    check: (lines, _logs, trace) => {
      const calls = trace.filter((t) => t.machine === "request" && t.inst === "a.remote");
      const slow = calls.find((t) => t.event === "send" && t.to === "inflight" && calls.some((u) => u.event === "progress_received" && u.data?.id === t.data?.id))?.data?.id;
      const ended = calls.find((t) => t.data?.id === slow && t.to === "done");
      return first(
        same(event(lines, "a.called.1")?.timed_out, true, "the silent call timed out"),
        same(event(lines, "a.called.2")?.timed_out, true, "the call with progress timed out"),
        expectThat(slow !== undefined, "no call got progress"),
        same(ended?.event, "timer_fired", "what ended the call with progress"),
        expectThat((ended?.data?.progress ?? 0) >= 10, `the call with progress ended after ${ended?.data?.progress} progress, before the hard limit`),
        same(calls.filter((t) => t.data?.id === slow && t.event === "timer_fired" && t.to === "inflight").length, 0, "stale idle timers that fired"),
      );
    },
  }),
  engineScenario({
    name: "u12-retry-recovers",
    description: "A server that crashes once after it is up, with nothing needing it, starts again by itself once its backoff is over, and answers the next call",
    servers: { a: { rules: [{ ...discover, then: "crash" }, list("echo"), ok("fine")], flags: ["--once", "{caseDir}/a.crashed"] } },
    labFlags: ["--no-listen"],
    script: ["tools a", "expect a.phase.ready 5000", "expect a.phase.backoff 5000", "expect a.phase.ready 10000", "call a echo", "expect a.called.1.result 5000"],
    machines: { a: BASE },
    check: (_lines, logs) => same(received(logs.a, "server/discover").length, 2, "processes started"),
  }),
  engineScenario({
    name: "u12-retry-gives-up",
    description: "A server that dies right after every start starts again by itself, with nothing needing it, and gives up after its tries in a row",
    servers: { a: { rules: [{ ...discover, then: "crash" }, list("echo")] } },
    maxAttempts: 3,
    labFlags: ["--no-listen"],
    script: ["tools a", "expect a.phase.failed 20000"],
    machines: { a: BASE },
    check: (_lines, logs) => same(received(logs.a, "server/discover").length, 3, "processes started"),
  }),
  engineScenario({
    name: "u12-retry-stable",
    description: "A server that stays up past --stable-ms before each crash starts its tries over each time, so it never gives up",
    servers: { a: { rules: [discover, list("echo")], flags: ["--exit-after", "800"] } },
    maxAttempts: 2,
    labFlags: ["--no-listen", "--stable-ms", "200"],
    script: ["tools a", "drain 6000", "status"],
    machines: { a: BASE },
    check: (lines, logs) =>
      first(
        same(received(logs.a, "server/discover").length >= 3, true, "at least 3 processes started"),
        same(status(lines, "a")?.phase === "failed", false, "given up"),
      ),
  }),
  engineScenario({
    name: "u12-cancel-sent",
    description: "Cancelling a call in flight over stdio sends notifications/cancelled naming its request, and the call ends cancelled",
    servers: { a: { rules: modern({ ...ok("late"), delayMs: 2000 }) } },
    script: ["tools a", "expect a.tools.ok", "call a slow", "drain 300", "cancel 1", "expect a.called.1.cancelled 2000", "drain 2500"],
    machines: { a: [...BASE, "catalog", "subscription"] },
    check: (_lines, logs) => {
      const [call] = received(logs.a, "tools/call");
      return same(received(logs.a, "notifications/cancelled").map((m) => m.params?.requestId), [call?.id], "cancellations");
    },
  }),
  engineScenario({
    name: "u12-version-switch",
    description: "A call a 2026 server rejects with -32022 after detection goes out once more with the version the error lists (VER-05)",
    servers: {
      a: {
        rules: [
          { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN, "2026-09-09"], capabilities: { tools: {} } } },
          { method: "tools/call", version: MODERN, error: { code: -32022, message: "Unsupported protocol version", data: { supported: ["2026-09-09"] } } },
          { method: "tools/call", version: "2026-09-09", result: { resultType: "complete", content: [{ type: "text", text: "switched" }] } },
        ],
      },
    },
    labFlags: ["--no-listen", "--preferred", `${MODERN},2026-09-09`],
    script: ["call a echo", "expect a.called.1.result"],
    machines: { a: ["engine", "stdio", "request"] },
    check: (lines, logs) =>
      first(
        same(received(logs.a, "tools/call").map((m) => m.params?._meta?.["io.modelcontextprotocol/protocolVersion"]), [MODERN, "2026-09-09"], "the call's versions"),
        same(event(lines, "a.called.1")?.answer, '[{"type":"text","text":"switched"}]', "the answer"),
      ),
  }),
  engineScenario({
    name: "u12-control-attempts",
    description: "Planted control: the engine trace of a server that gives up after 2 tries, checked against a model told 3, is rejected",
    servers: { a: { rules: modern(), flags: ["--exit-at-start", "1"] } },
    maxAttempts: 2,
    script: ["call a echo", "expect a.called.1.transport_failed 15000"],
    machines: { a: ["engine"] },
    control: { server: "a", maxAttempts: 3 },
  }),
];
