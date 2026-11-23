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
// The engine's default lost_limit (src/mcp/core/engine.zig), as ObsLostLimit.
const LOST_LIMIT = 2;
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
  status?: { name: string; phase: string; version: string | null; tools: number; last_error: string | null; list_refusal: string | null }[];
  final?: { ok: boolean; logged: { name: string; lines: number }[] };
}
type Log = { dir: string; line: string }[];
/** One line of the trace every machine writes. */
type Step = { machine: string; inst: string; event: string; from: string; to: string; data?: { id?: number; progress?: number; outcome?: string; ignored?: boolean } };
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
  /**
   * What the elicitation trace's model is told about a form the records don't show (ElicitationTrace.tla):
   * ObsEscaped 1 when a name or choice is written with an escape, ObsFits 1 or 2 when the answer matches the form's strings or not,
   * and ObsRawCompare 1 for a planted control: the engine's trace is then checked against byte-for-byte matching and must be REJECTED.
   */
  elicitation?: { ObsFits?: number; ObsEscaped?: number; ObsRawCompare?: number };
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
        traces.push({ machine: "engine", instance: server, specDir: "tests/tla/mcp", wrapper: "EngineTrace", verdict: control ? "REJECTED" : "ACCEPTED", constants: { ObsMaxAttempts: control?.maxAttempts ?? attempts, ObsLostLimit: LOST_LIMIT } });
      } else if (m === "stdio") traces.push({ machine: "stdio", instance: `${server}.stdio`, specDir: "tests/tla/mcp", wrapper: "StdioConnTrace", verdict: "ACCEPTED", constants: { ObsMaxAttempts: 255 } });
      else if (m === "request") traces.push({ machine: "request", instance: remote, specDir: "tests/tla/mcp", wrapper: "RequestTrace", verdict: "ACCEPTED" });
      else if (m === "era") traces.push({ machine: "era", instance: remote, specDir: "tests/tla/mcp", wrapper: "EraTrace", verdict: "ACCEPTED", constants: { ObsPreferredCount: 1 } });
      else if (m === "catalog") traces.push({ machine: "catalog", instance: remote, specDir: "tests/tla/mcp", wrapper: "CatalogTrace", verdict: "ACCEPTED", constants: { ObsMaxPages: 100 } });
      else if (m === "subscription") traces.push({ machine: "subscription", instance: remote, specDir: "tests/tla/mcp", wrapper: "SubscriptionTrace", verdict: "ACCEPTED", constants: { ObsMaxTries: 8 } });
      else if (m === "elicitation") traces.push({ machine: "elicitation", instance: remote, specDir: "tests/tla/mcp", wrapper: "ElicitationTrace", verdict: c.elicitation?.ObsRawCompare === 1 ? "REJECTED" : "ACCEPTED", constants: { ObsMaxPending: 16, ObsFits: 0, ObsEscaped: 0, ObsRawCompare: 0, ...c.elicitation } });
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

// ---- a form the server writes with escapes ----
//
// The host reads the person's answer with std.json and writes it back, which spells a string without the escapes
// the server used (café, a/b, A, a surrogate pair as UTF-8). JSON gives both spellings one meaning, so the engine must
// match the strings, not the bytes (ELIC-05; Elicitation.tla's FitAccepted). The fake servers write the form with
// `beforeRaw` and `raw`, which keep the escapes that JSON.stringify would drop.

interface Spelling {
  name: string;
  /** What the server writes between the quotes. */
  written: string;
  /** What the host writes back for the same string. */
  sent: string;
}
const SPELLINGS: Spelling[] = [
  { name: "u00e9", written: String.raw`caf\u00e9`, sent: "café" },
  { name: "slash", written: String.raw`a\/b`, sent: "a/b" },
  { name: "u0041", written: String.raw`\u0041`, sent: "A" },
  { name: "surrogate-pair", written: String.raw`\ud83d\ude00`, sent: "😀" },
  { name: "plain", written: "plain", sent: "plain" }, // a guard: no escape, so nothing differs
];
type Place = "key" | "enum" | "oneOf" | "multi";
const PLACES: { place: Place; spellings: string[] }[] = [
  { place: "key", spellings: SPELLINGS.map((x) => x.name) },
  { place: "enum", spellings: SPELLINGS.map((x) => x.name) },
  { place: "oneOf", spellings: ["u00e9"] },
  { place: "multi", spellings: ["u00e9"] },
];

/** The form's JSON text, as the server writes it. */
function escapedForm(place: Place, written: string): string {
  const properties = {
    key: `{"${written}":{"type":"string"}}`,
    enum: `{"c":{"type":"string","enum":["${written}","other"]}}`,
    oneOf: `{"c":{"type":"string","oneOf":[{"const":"${written}","title":"T"},{"const":"other","title":"U"}]}}`,
    multi: `{"c":{"type":"array","items":{"type":"string","enum":["${written}","other"]}}}`,
  }[place];
  return `{"mode":"form","message":"Pick","requestedSchema":{"type":"object","properties":${properties}}}`;
}
/** What the host sends back: the content, with the string written the way std.json writes it. */
function answeredContent(place: Place, sent: string): string {
  const text = JSON.stringify(sent);
  return place === "key" ? `{${text}:"x"}` : place === "multi" ? `{"c":[${text}]}` : `{"c":${text}}`;
}

function escapeScenarios(): Scenario[] {
  const out: Scenario[] = [];
  for (const { place, spellings } of PLACES) {
    for (const name of spellings) {
      const sp = SPELLINGS.find((x) => x.name === name)!;
      const form = escapedForm(place, sp.written);
      const content = answeredContent(place, sp.sent);
      const wanted = JSON.parse(content);
      const escaped = sp.written !== sp.sent;
      out.push(
        engineScenario({
          name: `u12-escape-2025-${place}-${name}`,
          description: `A 2025 server's form has a ${place} written ${escaped ? `with an escape (${sp.written})` : "plainly"}: the host's answer, written without it, goes back to the server as a response (ELIC-05, ELIC-09)`,
          servers: { b: { rules: legacy({ ...ok25("asked"), beforeRaw: [`{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":${form}}`] }) } },
          labFlags: FORM,
          script: ["call b go", "expect b.elicit 5000", `elicit b 1 accept ${content}`, "expect b.called.1.result 5000", "drain 300"],
          machines: { b: ["elicitation"] },
          elicitation: { ObsFits: 1, ObsEscaped: escaped ? 1 : 0 },
          check: (_lines, logs) => same(replies(logs.b).find((m) => m.id === "e1")?.result, { action: "accept", content: wanted }, "the elicitation's answer"),
        }),
        engineScenario({
          name: `u12-escape-2026-${place}-${name}`,
          description: `A 2026 server's input round has a form with a ${place} written ${escaped ? `with an escape (${sp.written})` : "plainly"}: the host's answer, written without it, is the next round's input response (MRTR-03, ELIC-05)`,
          servers: {
            a: {
              rules: modern({
                method: "tools/call",
                times: 1,
                raw: `{"jsonrpc":"2.0","id":{id},"result":{"resultType":"input_required","inputRequests":{"k":{"method":"elicitation/create","params":${form}}}}}`,
              }),
            },
          },
          labFlags: FORM,
          script: ["call a ask", "expect a.input.1", `respond 1 [{"action":"accept","content":${content}}]`, "expect a.called.1.result"],
          machines: { a: [{ mrtr: "x3" }] },
          check: (_lines, logs) => {
            const calls = received(logs.a, "tools/call");
            return first(same(calls.length, 2, "tools/call requests"), same(calls[1]?.params?.inputResponses, { k: { action: "accept", content: wanted } }, "the second round's answers"));
          },
        }),
      );
    }
  }
  // The planted control: the engine's trace of the answer to `café` written as \u00e9, checked against a model that
  // matches bytes, is rejected. That is the model's finding, shown on the real engine's trace.
  const control = SPELLINGS[0];
  out.push(
    engineScenario({
      name: "u12-escape-control-raw-compare",
      description: "Planted control: the trace of an answer accepted for a name the server wrote with an escape, checked against a model that matches bytes, is rejected",
      servers: { b: { rules: legacy({ ...ok25("asked"), beforeRaw: [`{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":${escapedForm("enum", control.written)}}`] }) } },
      labFlags: FORM,
      script: ["call b go", "expect b.elicit 5000", `elicit b 1 accept ${answeredContent("enum", control.sent)}`, "expect b.called.1.result 5000", "drain 300"],
      machines: { b: ["elicitation"] },
      elicitation: { ObsFits: 1, ObsEscaped: 1, ObsRawCompare: 1 },
    }),
  );
  // Two names that are one name once decoded are a duplicate: the form is unreadable, so the host is never asked and
  // the server gets the same error as for a repeated name (the one behavior change for such a form).
  const duplicate = (name: string, a: string, b: string): Scenario => {
    const form = `{"mode":"form","message":"Pick","requestedSchema":{"type":"object","properties":{"${a}":{"type":"string"},"${b}":{"type":"string"}}}}`;
    return engineScenario({
      name,
      description: `A 2025 server's form with the names ${a} and ${b}: ${a === b ? "a repeated name" : "one name once decoded"}, so the form is unreadable and the server is answered with an error`,
      servers: { b: { rules: legacy({ ...ok25("asked"), beforeRaw: [`{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":${form}}`] }) } },
      labFlags: FORM,
      script: ["call b go", "expect b.called.1.result 5000", "drain 300"],
      machines: { b: ["elicitation"] },
      check: (lines, logs) => {
        const reply = replies(logs.b).find((m) => m.id === "e1");
        return first(
          expectThat(!lines.some((l) => l.event?.tag === "b.elicit"), "the host was asked about an unreadable form"),
          same(reply?.error?.code, -32602, "the code of the error the server got"),
          same(reply?.error?.message, "Unsupported elicitation", "the words of the error the server got"),
        );
      },
    });
  };
  out.push(duplicate("u12-escape-duplicate-raw", "A", "A"), duplicate("u12-escape-duplicate-decoded", "A", String.raw`\u0041`));
  return out;
}

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
    name: "u12-deep-reply",
    description: "A reply nested 2,000 levels deep reaches the host whole: the engine's limit is far above the host's depth limit of 128 (tests/tla/mcp/WireDepth.tla), which the host applies where it reads the result",
    servers: { b: { rules: legacy({ method: "tools/call", result: { content: [{ type: "text", text: "deep" }], structuredContent: JSON.parse(`${'{"a":'.repeat(2000)}1${"}".repeat(2000)}`) } }) } },
    script: ["call b add", "expect b.called.1.result"],
    machines: { b: [...BASE, "catalog"] },
    check: (lines) => same(event(lines, "b.called.1")?.answer, '[{"type":"text","text":"deep"}]', "the deep reply's answer"),
  }),
  engineScenario({
    name: "u12-tools-stale",
    description: "The host hears when a server's tools may have changed, so it can list them again before its next call: once for a 2025 list_changed, once when a fresh list's TTL runs out, again after a failed re-list hands over the last list, never for a list that was never fresh, and never before the first list (CAT-05)",
    servers: {
      b: { rules: [initialize, list25("add"), { ...ok25("fine"), before: [{ jsonrpc: "2.0", method: "notifications/tools/list_changed" }] }] },
      t: { rules: [discover, listen, { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")], ttlMs: 300 } }, ok("fine")] },
      z: { rules: modern() },
      f: { rules: [initialize, { ...list25("add"), times: 1 }, { ...ok25("fine"), before: [{ jsonrpc: "2.0", method: "notifications/tools/list_changed" }] }, { method: "tools/list", error: { code: -32603, message: "Internal error" } }] },
    },
    script: ["tools b", "tools t", "tools z", "tools f", "expect b.tools.ok", "expect t.tools.ok", "expect z.tools.ok", "expect f.tools.ok", "call b add", "expect b.called.1.result", "expect b.tools_stale", "call f add", "expect f.called.2.result", "expect f.tools_stale", "tools f", "expect f.tools.ok", "expect f.tools_stale", "expect t.tools_stale 3000", "drain 500"],
    machines: { b: [...BASE, "catalog"], t: [...BASE, "catalog", "subscription"], z: [...BASE, "catalog", "subscription"], f: [...BASE, "catalog"] },
    check(lines) {
      const all = tags(lines);
      const stale = (s: string) => all.filter((t) => t === `${s}.tools_stale`).length;
      const before = (s: string) => all.indexOf(`${s}.tools_stale`) >= 0 && all.indexOf(`${s}.tools_stale`) < all.indexOf(`${s}.tools.ok`);
      return first(
        // f: its list_changed, then the failed re-list that hands over the
        // last list, still stale.
        same([stale("b"), stale("t"), stale("z"), stale("f")], [1, 1, 0, 2], "tools_stale events for b, t, z, f"),
        expectThat(!before("b") && !before("t"), "a tools_stale came before the first list"),
      );
    },
  }),
  engineScenario({
    name: "u12-list-refused",
    description: "A server whose newest tool list fx refused: the status says so with the fixed words, beside the older list it still serves and with no last_error, and the next good list clears it",
    servers: {
      f: { rules: [initialize, { ...list25("add"), times: 1 }, { ...ok25("fine"), before: [{ jsonrpc: "2.0", method: "notifications/tools/list_changed" }] }, { method: "tools/list", result: { tools: 7 }, times: 1 }, list25("add", "sub")] },
    },
    script: ["tools f", "expect f.tools.ok", "status", "call f add", "expect f.called.1.result", "expect f.tools_stale", "tools f", "expect f.tools.ok", "status", "tools f", "expect f.tools.ok", "status"],
    machines: { f: [...BASE, "catalog"] },
    check(lines) {
      // The lab prints one more status when it ends, which repeats the last: the three the script asked for.
      const states = lines.filter((l) => l.status).map((l) => l.status![0]).slice(0, 3);
      return first(
        same(states.map((s) => [s.phase, s.tools, s.list_refusal, s.last_error]), [["ready", 1, null, null], ["ready", 1, '"tools" is not a list', null], ["ready", 2, null, null]], "the status [phase, tools, list_refusal, last_error] after each list"),
      );
    },
  }),
  engineScenario({
    name: "u12-list-refused-first-list",
    description: "A server whose first tool list fx refuses, as a result that is no list or as an error: the host gets the failure, no tools are listed, and the status says why in the fixed words while the server stays ready",
    servers: {
      g: { rules: [initialize, { method: "tools/list", result: { tools: 7 } }] },
      h: { rules: [initialize, { method: "tools/list", error: { code: -32603, message: "Internal error" } }] },
    },
    script: ["tools g", "tools h", "expect g.tools.fail", "expect h.tools.fail", "status"],
    machines: { g: [...BASE, "catalog"], h: [...BASE, "catalog"] },
    check(lines) {
      return first(
        same(["g", "h"].map((n) => { const s = status(lines, n)!; return [s.phase, s.tools, s.list_refusal]; }), [["ready", 0, '"tools" is not a list'], ["ready", 0, "the server answered the list with an error"]], "the status [phase, tools, list_refusal] of g and h"),
      );
    },
  }),
  engineScenario({
    name: "u12-restart-count-is-per-listing",
    description: "A listing restarts once on an invalid cursor, as the model says, and so does the next listing: each starts with its own count, so the second listing's first invalid cursor restarts it, publishes its new list and refuses nothing",
    servers: {
      f: {
        rules: [
          initialize,
          { method: "tools/list", cursor: null, times: 1, result: { tools: [tool("add")], nextCursor: "c1" } },
          { method: "tools/list", cursor: "c1", times: 1, error: { code: -32602, message: "no such cursor" } },
          { method: "tools/list", cursor: null, times: 1, result: { tools: [tool("add")] } },
          { ...ok25("fine"), before: [{ jsonrpc: "2.0", method: "notifications/tools/list_changed" }] },
          { method: "tools/list", cursor: null, times: 1, result: { tools: [tool("add")], nextCursor: "c2" } },
          { method: "tools/list", cursor: "c2", times: 1, error: { code: -32602, message: "no such cursor" } },
          list25("add", "sub"),
        ],
      },
    },
    script: ["tools f", "expect f.tools.ok", "status", "call f add", "expect f.called.1.result", "expect f.tools_stale", "tools f", "expect f.tools.ok", "status"],
    machines: { f: [...BASE, "catalog"] },
    check(lines) {
      // The lab prints one more status when it ends, which repeats the last: the two the script asked for.
      const states = lines.filter((l) => l.status).map((l) => l.status![0]).slice(0, 2);
      return first(
        same(states.map((s) => [s.phase, s.tools, s.list_refusal]), [["ready", 1, null], ["ready", 2, null]], "the status [phase, tools, list_refusal] after each list: the second list is published, and nothing is refused"),
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
    name: "u12-idle-restart",
    description: "A server nothing used for its idle limit stops without a failure, and the next call starts a new process and is answered",
    servers: { a: { rules: modern() } },
    // The runtime lowers a stable limit above the idle one, so both are 300 ms.
    labFlags: ["--no-listen", "--stable-ms", "300", "--idle-ms", "300"],
    script: ["call a echo", "expect a.called.1.result", "drain 1500", "call a echo", "expect a.called.2.result 10000"],
    machines: { a: BASE },
    check: (lines, logs, trace) =>
      first(
        expectThat(trace.some((t) => t.machine === "engine" && t.inst === "a" && t.event === "idle" && t.data?.ignored === false), "no idle stop in the engine trace"),
        same(received(logs.a, "server/discover").length, 2, "processes started"),
        expectThat(event(lines, "a.stopped_idle") !== undefined, "the host never heard the idle stop"),
        same(event(lines, "a.called.2")?.answer, '[{"type":"text","text":"fine"}]', "the second call's answer"),
      ),
  }),
  engineScenario({
    name: "u12-denied",
    description: "A call the host refuses ends denied at once, and its server never starts for it",
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
    description: "A server whose process dies at every start: the waiting call fails transport_failed with the first failed start, the server tries again by itself and gives up after its tries in a row, and a later call fails too; another server is untouched",
    servers: { a: { rules: modern(), flags: ["--exit-at-start", "1"] }, b: { rules: modern() } },
    maxAttempts: 2,
    script: ["call a echo", "call b echo", "expect b.called.2.result", "expect a.called.1.transport_failed 15000", "expect a.phase.failed 5000", "call a echo", "expect a.called.3.transport_failed 2000"],
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
    description: "A command that can't be started fails within its tries instead of looking busy: each failed spawn is a down (found by mcpv2 list --connect), the waiting call ends transport_failed with the first, the server gives up after its tries, and the status names the spawn error",
    servers: { a: { rules: [], argv: ["/nonexistent/mcp-server"] } },
    maxAttempts: 2,
    script: ["call a echo", "expect a.called.1.transport_failed 10000", "expect a.phase.failed 5000", "status"],
    machines: { a: ["engine", "stdio"] },
    check: (lines) => same(lines.filter((l) => l.status).at(-1)?.status?.[0]?.last_error, "FileNotFound", "last errors"),
  }),
  engineScenario({
    name: "u12-progress-note",
    description: "A call's accepted progress reaches the host with its message, terminal-safe: a value that doesn't grow and another token's note never do",
    servers: {
      a: {
        rules: modern({
          method: "tools/call",
          before: [
            { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "$id", progress: 1, total: 4, message: "halfway\u0007 there" } },
            { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "$id", progress: 1, message: "again" } },
            { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "$id", progress: 2 } },
            { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: 999, progress: 3, message: "not ours" } },
          ],
          result: { resultType: "complete", content: [{ type: "text", text: "done" }] },
        }),
      },
    },
    script: ["call a echo", "expect a.called.1.result 10000"],
    machines: { a: [...BASE, "subscription"] },
    check: (lines) => {
      const notes = lines.filter((l) => l.event?.tag === "a.progress.1").map((l) => [l.event.progress, l.event.total, l.event.message]);
      return same(notes, [[1, 4, "halfway? there"], [2, null, null]], "progress events");
    },
  }),
  engineScenario({
    name: "u12-start-failure-detail",
    description: "A server that prints a banner instead of answering and exits: the status keeps its exit code and the banner, terminal-safe, until it starts again",
    servers: { a: { rules: [{ method: "*", noReply: true }], flags: ["--banner", "Server started on stdio\u001b[31m", "--exit-after", "300"] } },
    maxAttempts: 1,
    script: ["call a echo", "expect a.called.1.transport_failed 10000", "expect a.phase.failed 5000", "status"],
    machines: { a: ["engine", "stdio"] },
    check: (lines) => {
      const s = lines.filter((l) => l.status).at(-1)?.status?.[0];
      return first(
        same(s?.exit, { code: 1 }, "exit"),
        same(s?.stray_line, "Server started on stdio?[31m", "stray line"),
      );
    },
  }),
  engineScenario({
    name: "u12-start-failure-stderr",
    description: "A server that writes errors to stderr and exits while starting: its last 3 stderr lines, terminal-safe and joined, are kept with its exit code, until it starts again",
    servers: { a: { rules: [{ method: "*", noReply: true, stderr: ["first", "npm error code E401", "npm error Incorrect\u0007 or missing password.", "last  "] }], flags: ["--exit-after", "300"] } },
    maxAttempts: 1,
    script: ["call a echo", "expect a.called.1.transport_failed 10000", "expect a.phase.failed 5000", "status"],
    machines: { a: ["engine", "stdio"] },
    check: (lines) =>
      first(
        same(lines.filter((l) => l.status).at(-1)?.status?.[0]?.exit, { code: 1 }, "exit"),
        same(lines.filter((l) => l.stderr_tails).at(-1)?.stderr_tails, ["npm error code E401 / npm error Incorrect? or missing password. / last"], "stderr tail"),
      ),
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
    name: "u12-http-lost-restart",
    description: "Two HTTP calls whose answer streams break are lost in a row: the engine drops the link, so the third call detects the server again and is answered",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } },
        { method: "tools/call", sse: true, drop: true, times: 2 },
        { method: "tools/call", result: { resultType: "complete", content: [{ type: "text", text: "third" }] } },
      ],
    },
    servers: {},
    labFlags: ["--no-listen"],
    script: ["tools h", "expect h.phase.ready 5000", "call h echo", "expect h.called.1.lost 10000", "call h echo", "expect h.called.2.lost 10000", "call h echo", "expect h.called.3.result 10000", "status"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (lines, logs) => {
      // The link restarts: the second detection goes out after the second call's stream broke, and call 3 goes out on the new link.
      const raw = logs.h as unknown as { t: number; dir: string; body?: string }[];
      const posts = raw.filter((l) => l.dir === "in" && l.body).map((l) => ({ t: l.t, ...JSON.parse(l.body!) }));
      const detections = posts.filter((m) => m.method === "server/discover");
      const calls = posts.filter((m) => m.method === "tools/call");
      const restarted = detections.length === 2 && calls.length === 3 && detections[1].t > calls[1].t;
      return first(
        same(calls.length, 3, "tools/call posts"),
        same(detections.length, 2, "server/discover posts"),
        restarted ? null : "the second detection did not come after the second lost call",
        same(event(lines, "h.called.3")?.answer, '[{"type":"text","text":"third"}]', "the third call's answer"),
      );
    },
  }),
  engineScenario({
    name: "u12-http-lost-restart-while-listing",
    description: "A tool list still loading when two HTTP calls are lost is failed by the restart, so the next tool request lists again on the new link, and a third call is answered",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] }, delayMs: 3000, times: 1 },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } },
        { method: "tools/call", sse: true, drop: true, times: 2 },
        { method: "tools/call", result: { resultType: "complete", content: [{ type: "text", text: "third" }] } },
      ],
    },
    servers: {},
    labFlags: ["--no-listen"],
    script: ["tools h", "expect h.phase.ready 5000", "call h echo", "expect h.called.1.lost 10000", "call h echo", "expect h.called.2.lost 10000", "expect h.tools.fail 10000", "tools h", "expect h.tools.ok 10000", "call h echo", "expect h.called.3.result 10000", "status"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (lines, logs) => {
      // The restart: the second detection and the second tool list both go out after the second lost call.
      const raw = logs.h as unknown as { t: number; dir: string; body?: string }[];
      const posts = raw.filter((l) => l.dir === "in" && l.body).map((l) => ({ t: l.t, ...JSON.parse(l.body!) }));
      const detections = posts.filter((m) => m.method === "server/discover");
      const listings = posts.filter((m) => m.method === "tools/list");
      const calls = posts.filter((m) => m.method === "tools/call");
      const restarted = detections.length === 2 && calls.length === 3 && detections[1].t > calls[1].t;
      const relisted = listings.length === 2 && calls.length === 3 && listings[1].t > calls[1].t;
      return first(
        same(calls.length, 3, "tools/call posts"),
        same(detections.length, 2, "server/discover posts"),
        same(listings.length, 2, "tools/list posts"),
        restarted ? null : "the second detection did not come after the second lost call",
        relisted ? null : "the second tool list did not come after the second lost call",
        same(event(lines, "h.called.3")?.answer, '[{"type":"text","text":"third"}]', "the third call's answer"),
      );
    },
  }),
  engineScenario({
    name: "u12-http-initialized-timeout",
    description: "A 2025 HTTP server answers initialize but never answers notifications/initialized: after the request timeout the session fails with initialized_timed_out, and the server goes down instead of looking ready with no tools",
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
    name: "u12-invalid-reply",
    description: "A stdio reply with the call's id but no jsonrpc fails that call at once as -32600, not at its timeout; the server keeps running and answers the next call; a refused line naming no request stays ignored",
    servers: {
      b: {
        rules: modern(
          { method: "tools/call", raw: '{"id":{id},"result":{"content":[]}}', before: [{ jsonrpc: "1.0", id: 999, result: {} }], times: 1 },
        ),
      },
    },
    labFlags: ["--timeout-ms", "20000"],
    script: ["call b echo", "expect b.called.1.failure 3000", "call b echo", "expect b.called.2.result 3000"],
    machines: { b: [...BASE, "subscription"] },
    check: (lines, logs) =>
      first(
        same(event(lines, "b.called.1")?.answer, 'error -32600 "invalid reply (its jsonrpc isn\'t \\"2.0\\"): {\\"id\\":3,\\"result\\":{\\"content\\":[]}}"', "the first call's answer"),
        same(event(lines, "b.called.1")?.timed_out, false, "timed out"),
        same(received(logs.b, "server/discover").length, 1, "processes"),
      ),
  }),
  engineScenario({
    name: "u12-start-deadline-legacy",
    description: "A 2025 stdio server that never answers initialize fails its start when the start's time runs out, long before the request timeout, and goes down to retry",
    servers: { b: { rules: [{ ...initialize, noReply: true }] } },
    labFlags: ["--start-ms", "800"],
    script: ["tools b", "expect b.phase.backoff 5000", "status"],
    machines: { b: BASE },
    check: (lines, logs) =>
      first(
        same(received(logs.b, "server/discover").length, 1, "discover requests"),
        same(received(logs.b, "initialize").length, 1, "initialize requests"),
        status(lines, "b")?.last_error ? null : "b has no last error",
      ),
  }),
  engineScenario({
    name: "u12-start-deadline-total",
    description: "A stdio server that answers neither discover nor initialize: the probe falls back after its 1.5 s, and initialize gets only what is left of the 2 s start, so the start fails by 3 s instead of 3.5 s",
    servers: { b: { rules: [{ method: "server/discover", noReply: true }, { ...initialize, noReply: true }] } },
    labFlags: ["--probe-ms", "1500", "--start-ms", "2000"],
    script: ["tools b", "expect b.phase.backoff 3000", "status"],
    machines: { b: BASE },
    check: (_lines, logs) => same(received(logs.b, "initialize").length, 1, "initialize requests"),
  }),
  engineScenario({
    name: "u12-http-reinit-after-start",
    description: "A 2025 HTTP session ends after a call, well after the start's time ran out: the initialize that renews it isn't a start, so it gets the request timeout and the next call answers",
    http: {
      name: "h",
      flags: ["--session"],
      rules: [
        { method: "initialize", result: initialize.result },
        { method: "tools/list", result: { tools: [tool("echo")] } },
        { method: "tools/call", result: { content: [{ type: "text", text: "first" }] }, endSession: true, times: 1 },
        { method: "tools/call", result: { content: [{ type: "text", text: "again" }] } },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--start-ms", "300"],
    script: ["call h echo", "expect h.called.1.result 5000", "drain 600", "call h echo", "expect h.called.2.result 5000", "status"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (lines, logs) => {
      const raw = logs.h as unknown as { dir: string; body?: string }[];
      const inits = raw.filter((l) => l.dir === "in" && l.body && JSON.parse(l.body).method === "initialize");
      return first(same(inits.length, 2, "initialize posts"), same(event(lines, "h.called.2")?.answer, '[{"type":"text","text":"again"}]', "the second call's answer"));
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
    // The call fails with the first start; the give-up comes later.
    script: ["call a echo", "expect a.called.1.transport_failed 15000", "expect a.phase.failed 5000"],
    machines: { a: ["engine"] },
    control: { server: "a", maxAttempts: 3 },
  }),
  ...escapeScenarios(),
  // ---- a protocol field name written with escapes ----
  // The reply lines are raw, so a field name carries a JSON escape: `is\u0045rror` is `isError` once decoded.
  engineScenario({
    name: "u12-escaped-iserror",
    description: "A tool result the server marks with an escaped `isError` is reported as an error, as std.json reads it (CAT-08)",
    servers: { a: { rules: modern({ method: "tools/call", times: 1, raw: '{"jsonrpc":"2.0","id":{id},"result":{"resultType":"complete","content":[{"type":"text","text":"boom"}],"is\\u0045rror":true}}' }) } },
    script: ["call a echo", "expect a.called.1.result"],
    machines: { a: BASE },
    check: (lines) => {
      const called = lines.find((l) => l.event?.tag === "a.called.1.result")?.event as { is_error?: boolean | null } | undefined;
      return expectThat(called?.is_error === true, `the result the server marked isError was reported with is_error ${JSON.stringify(called?.is_error)}`);
    },
  }),
  engineScenario({
    name: "u12-escaped-resulttype",
    description: "A result whose `resultType` name is written with an escape and says input_required asks the host, as std.json reads it (MRTR-01)",
    servers: { a: { rules: modern({ method: "tools/call", times: 1, raw: `{"jsonrpc":"2.0","id":{id},"result":{"result\\u0054ype":"input_required","inputRequests":${JSON.stringify(askName)}}}` }) } },
    labFlags: FORM,
    script: ["call a ask", "expect a.input.1", 'respond 1 [{"action":"accept","content":{"name":"Ada"}}]', "expect a.called.1.result"],
    machines: { a: [...BASE, "subscription", { mrtr: "x3" }] },
    check: (_lines, logs) => {
      const calls = received(logs.a, "tools/call");
      return first(same(calls.length, 2, "tools/call requests"), same(calls[1]?.params?.inputResponses, { k: { action: "accept", content: { name: "Ada" } } }, "the second round's answers"));
    },
  }),
  engineScenario({
    name: "u12-escaped-requeststate",
    description: "A `requestState` name written with an escape is echoed in the next round, as the server asked (MRTR-03)",
    servers: { a: { rules: modern({ method: "tools/call", times: 1, raw: `{"jsonrpc":"2.0","id":{id},"result":{"resultType":"input_required","inputRequests":${JSON.stringify(askName)},"request\\u0053tate":"opaque"}}` }) } },
    labFlags: FORM,
    script: ["call a ask", "expect a.input.1", 'respond 1 [{"action":"accept","content":{"name":"Ada"}}]', "expect a.called.1.result"],
    machines: { a: [...BASE, "subscription", { mrtr: "x3" }] },
    check: (_lines, logs) => {
      const calls = received(logs.a, "tools/call");
      return first(same(calls.length, 2, "tools/call requests"), same(calls[1]?.params?.requestState, "opaque", "the second round's requestState"));
    },
  }),
  engineScenario({
    name: "u12-escaped-nextcursor",
    description: "A tools/list page whose `nextCursor` name is written with an escape is followed to the next page, as std.json reads it (CAT-01)",
    servers: {
      a: {
        rules: [
          discover,
          listen,
          { method: "tools/list", cursor: null, raw: '{"jsonrpc":"2.0","id":{id},"result":{"resultType":"complete","tools":[{"name":"one","inputSchema":{"type":"object"}}],"ne\\u0078tCursor":"c2"}}' },
          { method: "tools/list", cursor: "c2", result: { resultType: "complete", tools: [tool("two")] } },
          ok("fine"),
        ],
      },
    },
    script: ["tools a", "expect a.tools.ok"],
    machines: { a: BASE },
    check: (lines) => {
      const lists = lines.filter((l) => l.event?.tag === "a.tools.ok");
      return same(lists[lists.length - 1]?.event?.names, ["one", "two"], "the tool names after the last list");
    },
  }),
  // ---- a line the engine refuses that names no request: the grace (tests/tla/mcp/Request.tla) ----
  // Setup: the lab flag --refused-ms is read and ignored until the engine has the grace.
  engineScenario({
    name: "u12-refused-grace-silent",
    description: "A stdio line the engine refuses and cannot attach to a call, then silence: the call ends as malformed when the grace runs out, long before its idle timer, and the server is told it was cancelled",
    servers: { a: { rules: modern({ method: "tools/call", tool: "silent", rawBytes: 40, noReply: true }) } },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a silent", "expect a.called.1.malformed 5000"],
    machines: { a: BASE },
    check: (lines, logs, trace) =>
      first(
        same(event(lines, "a.called.1")?.timed_out, false, "timed out"),
        same(received(logs.a, "notifications/cancelled").length, 1, "cancel notices the server got"),
        expectThat(trace.some((t) => t.machine === "request" && t.event === "refused_line"), "no refused_line step in the request trace"),
        expectThat(trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "no grace_expired step in the request trace"),
      ),
  }),
  engineScenario({
    name: "u12-refused-grace-every-waiting-call",
    description: "A stdio line fx cannot read and that names no request is about every call waiting on that one connection: both calls end as malformed when the grace runs out, and the server is told it cancelled each",
    servers: { a: { rules: modern({ method: "tools/call", tool: "silent", delayMs: 400, rawBytes: 40, noReply: true }) } },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a silent", "call a silent", "expect a.called.1.malformed 5000", "expect a.called.2.malformed 5000"],
    machines: { a: BASE },
    check: (lines, logs, trace) =>
      first(
        same(received(logs.a, "notifications/cancelled").length, 2, "cancel notices the server got"),
        same(trace.filter((t) => t.machine === "request" && t.event === "grace_expired").length, 2, "grace_expired steps in the request trace"),
      ),
  }),
  engineScenario({
    name: "u12-refused-grace-progress",
    description: "Progress for the call's own token after the refused line clears its grace: a call that works for longer than the grace returns its result, and no grace ends it",
    servers: {
      a: {
        rules: modern({
          method: "tools/call",
          tool: "alive",
          rawBytes: 40,
          before: Array.from({ length: 10 }, (_, n) => ({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "$id", progress: n + 1 } })),
          beforeEveryMs: 150,
          result: { resultType: "complete", content: [{ type: "text", text: "fine" }] },
        }),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a alive", "expect a.called.1.result 6000"],
    machines: { a: BASE },
    check: (_lines, _logs, trace) =>
      expectThat(!trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "a grace ended a call that had progress"),
  }),
  engineScenario({
    name: "u12-refused-grace-later-call",
    description: "A call sent after the refused line gets no grace: a slow call started after it returns its result, long after the grace would have run out",
    servers: {
      a: {
        rules: modern(
          { method: "tools/call", tool: "once", rawBytes: 40, result: { resultType: "complete", content: [{ type: "text", text: "fine" }] } },
          { method: "tools/call", tool: "slow", delayMs: 1500, result: { resultType: "complete", content: [{ type: "text", text: "fine" }] } },
        ),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a once", "expect a.called.1.result 3000", "call a slow", "expect a.called.2.result 5000"],
    machines: { a: BASE },
    check: (_lines, _logs, trace) =>
      expectThat(!trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "the grace ended a call"),
  }),
  engineScenario({
    name: "u12-refused-grace-valid-reply",
    description: "A valid reply inside the grace still matches its call: the line, a notification 400 ms later, then the reply, with the grace at 600 ms",
    servers: {
      a: {
        rules: modern({
          method: "tools/call",
          tool: "late",
          rawBytes: 40,
          before: [
            { jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "one" } },
            { jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: "two" } },
          ],
          beforeEveryMs: 400,
          result: { resultType: "complete", content: [{ type: "text", text: "fine" }] },
        }),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a late", "expect a.called.1.result 3000"],
    machines: { a: BASE },
    check: (_lines, _logs, trace) =>
      expectThat(!trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "the grace ended a call that was answered inside it"),
  }),
  // ---- a line the engine refuses after an id it read: the request it names (tests/tla/mcp/Request.tla RefusedNaming) ----
  engineScenario({
    name: "u12-refused-named-at-once",
    description:
      "A stdio line the engine refuses after the id of a call, however it goes wrong (not JSON, nested past the limit, a key written twice), ends that call at once as -32600, not as malformed when the grace runs out, and the server is not told it was cancelled",
    servers: {
      a: {
        rules: modern(
          { method: "tools/call", tool: "cut", raw: '{"jsonrpc":"2.0","id":{id},"result":{"content":[nope]}}' },
          { method: "tools/call", tool: "deep", raw: `{"jsonrpc":"2.0","id":{id},"result":{"content":[],"structuredContent":${'{"a":'.repeat(3000)}1${"}".repeat(3000)}}}` },
          { method: "tools/call", tool: "twice", raw: '{"jsonrpc":"2.0","id":{id},"result":{"content":[]},"r\\u0065sult":{"content":[]}}' },
        ),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a cut", "expect a.called.1.failure 3000", "call a deep", "expect a.called.2.failure 3000", "call a twice", "expect a.called.3.failure 3000"],
    machines: { a: BASE },
    check: (lines, logs, trace) =>
      first(
        ...[1, 2, 3].map((n) =>
          expectThat(
            event(lines, `a.called.${n}`)?.answer?.startsWith('error -32600 "invalid reply (it isn\'t valid JSON-RPC): {\\"jsonrpc\\":\\"2.0\\",\\"id\\":') ?? false,
            `call ${n}'s answer (${event(lines, `a.called.${n}`)?.answer})`,
          ),
        ),
        same([1, 2, 3].map((n) => event(lines, `a.called.${n}`)?.timed_out), [false, false, false], "timed out"),
        same(received(logs.a, "notifications/cancelled").length, 0, "cancel notices the server got"),
        expectThat(!trace.some((t) => t.machine === "request" && (t.event === "refused_line" || t.event === "grace_expired")), "a refused line that names its call gave a grace"),
      ),
  }),
  engineScenario({
    name: "u12-refused-named-stray",
    description:
      "A line the engine refuses after the id of a call that is not in flight is a stray, as a late reply is: it gives the call in flight no grace, which returns its result after the grace would have run out",
    servers: {
      a: {
        rules: modern({
          method: "tools/call",
          tool: "slow",
          beforeRaw: ['{"jsonrpc":"2.0","id":99,"result":{"x":nope}}'],
          delayMs: 1500,
          result: { resultType: "complete", content: [{ type: "text", text: "fine" }] },
        }),
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a slow", "expect a.called.1.result 5000"],
    machines: { a: BASE },
    check: (_lines, _logs, trace) =>
      expectThat(!trace.some((t) => t.machine === "request" && (t.event === "refused_line" || t.event === "grace_expired")), "a stray line gave a grace"),
  }),
  engineScenario({
    name: "u12-refused-two-ids",
    description: "A line the engine refuses that writes the id twice names no call, as the decoder refuses it: the call ends as malformed when the grace runs out",
    servers: {
      a: { rules: modern({ method: "tools/call", tool: "twin", beforeRaw: ['{"jsonrpc":"2.0","id":{id},"id":{id},"result":{"content":[]}}'], noReply: true }) },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call a twin", "expect a.called.1.malformed 5000"],
    machines: { a: BASE },
    check: (_lines, _logs, trace) =>
      first(
        expectThat(trace.some((t) => t.machine === "request" && t.event === "refused_line"), "no refused_line step in the request trace"),
        expectThat(trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "no grace_expired step in the request trace"),
      ),
  }),
  engineScenario({
    name: "u12-list-refused-after-its-id",
    description:
      "A stdio tool list reply that goes wrong after its id ends the list at once, and the status says the answer is not a readable tool list, not that the server answered with an error",
    servers: {
      a: {
        rules: [discover, listen, { method: "tools/list", raw: '{"jsonrpc":"2.0","id":{id},"result":{"resultType":"complete","tools":[]},"extra":nope}' }],
      },
    },
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["tools a", "expect a.tools.fail 3000", "status"],
    machines: { a: [...BASE, "catalog"] },
    check: (lines, _logs, trace) =>
      first(
        same(status(lines, "a")?.list_refusal, "the answer is not a readable tool list", "the list refusal"),
        expectThat(!trace.some((t) => t.machine === "request" && (t.event === "refused_line" || t.event === "grace_expired")), "a refused line that names its list gave a grace"),
      ),
  }),
  engineScenario({
    name: "u12-refused-http-json-body",
    description: "An HTTP JSON body the engine cannot read ends its call at once as malformed, not as an HTTP failure",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } },
        { method: "tools/call", raw: '{"jsonrpc":"2.0","result":{"bad":,"id":1}', contentType: "application/json" },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call h echo", "expect h.called.1.malformed 3000"],
    machines: { h: ["engine", "request", "era", "catalog"] },
  }),
  engineScenario({
    name: "u12-refused-http-sse-readable-id",
    description: "An SSE event with the call's id and a jsonrpc that is not 2.0 ends the call at once as -32600, as on stdio, though the stream stays open",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } },
        { method: "tools/call", sse: true, before: [{ jsonrpc: "1.0", id: "$id", result: {} }], hang: true },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call h echo", "expect h.called.1.failure 3000"],
    machines: { h: ["engine", "request", "era", "catalog"] },
  }),
  engineScenario({
    name: "u12-refused-http-sse-other-id",
    description:
      "An SSE event on one call's stream that names another call is a stray, as a valid reply would be: it ends the call whose stream it came on, by its own id, and never the other call in flight, which returns its result",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("slow"), tool("liar")] } },
        { method: "tools/call", name: "slow", delayMs: 1500, result: { resultType: "complete", content: [{ type: "text", text: "fine" }] } },
        // Every id the client could have used, each with a jsonrpc that is not 2.0.
        { method: "tools/call", name: "liar", sse: true, before: Array.from({ length: 12 }, (_, n) => ({ jsonrpc: "1.0", id: n + 1, result: {} })), hang: true },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call h slow", "call h liar", "expect h.called.2.failure 3000", "expect h.called.1.result 6000"],
    machines: { h: ["engine", "request", "era", "catalog"] },
  }),
  engineScenario({
    name: "u12-refused-http-sse-no-id-other-stream",
    description:
      "An SSE event that fx cannot read and that has no readable id is about the call whose stream carried it alone: that call ends as malformed when the grace runs out, and its stream is closed; the other call, on its own stream, is not touched and returns its result",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("slow"), tool("noisy")] } },
        { method: "tools/call", name: "slow", delayMs: 3000, result: { resultType: "complete", content: [{ type: "text", text: "fine" }] } },
        { method: "tools/call", name: "noisy", sse: true, before: ["not an object"], hang: true },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call h slow", "call h noisy", "expect h.called.2.malformed 5000", "expect h.called.1.result 8000"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (_lines, logs, trace) => {
      const raw = logs.h as unknown as { dir: string; id?: number }[];
      return first(
        // Only the call on the noisy stream ends by its grace, and its stream is closed.
        same(trace.filter((t) => t.machine === "request" && t.event === "grace_expired").length, 1, "grace_expired steps in the request trace"),
        expectThat(raw.some((l) => l.dir === "closed"), "the noisy call's stream was not closed"),
      );
    },
  }),
  engineScenario({
    name: "u12-refused-http-sse-no-id",
    description: "An SSE event that names no request, on a stream that stays open: the call ends as malformed when the grace runs out, as a stdio call does",
    http: {
      name: "h",
      rules: [
        { method: "server/discover", result: { resultType: "complete", supportedVersions: [MODERN], capabilities: { tools: {} } } },
        { method: "tools/list", result: { resultType: "complete", tools: [tool("echo")] } },
        { method: "tools/call", sse: true, before: ["not an object"], hang: true },
      ],
    },
    servers: {},
    labFlags: ["--no-listen", "--timeout-ms", "20000", "--refused-ms", "600"],
    script: ["call h echo", "expect h.called.1.malformed 5000"],
    machines: { h: ["engine", "request", "era", "catalog"] },
    check: (_lines, _logs, trace) =>
      expectThat(trace.some((t) => t.machine === "request" && t.event === "grace_expired"), "no grace_expired step in the request trace"),
  }),
];
