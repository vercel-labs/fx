// Runtime driver for tests/tla/acp/AcpNotices.tla: runs the built `fx acp`
// against a local fake Gateway, once for a client that advertises ACP v1
// Session Notices and once for one that does not, and has TLC check each
// turn the client saw through tests/tla/acp/AcpNoticesTrace.tla. It also
// checks, for the notices client, that the turn's agent messages match what
// session/load replays, except an HTTP failure, which fx doesn't save.
//
//   bun tests/tla/drivers/acp/notices/driver.ts                # after zig build
//   bun tests/tla/drivers/acp/notices/driver.ts --stress 100   # adds one turn with 100 stalls
//
// FX_BIN names another binary. No live model calls: every fx process gets
// its environment written out in full, with a fake key and the fake
// Gateway's URLs, and each turn checks the fake Gateway saw the requests the
// plan expects.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fakeGatewaySse, startDynamicFakeGateway } from "../../../../e2e/tmux-helpers";
import { REPO_ROOT, fxBin, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "../../lib/tlc";

const SPEC_DIR = join(REPO_ROOT, "tests", "tla", "acp");
const MODEL = "openai/gpt-5";
const SPECS = ["AcpNotices.tla", "AcpNoticesTrace.tla"];

// ------------------------------------------------------------------- plans --

// What the fake Gateway answers each model request with.
type Reply =
  | "reply" //          text, then stop
  | "empty_other" //    no text, stops for `other`: fx nudges once, then fails
  | "empty_stop" //     no text, stops: fx shows and saves "Done."
  | "unauthorized" //   HTTP 401
  | "length_text" //    text cut by the output limit
  | "length_tools" //   only a tool call cut by the output limit
  | "partial_eof" //    text, then the stream ends without a finish
  | "tool_step"; //     text and a glob_files call

// requests is how many model requests the fake Gateway must see. replay
// says whether the notices client's agent messages must match what
// session/load replays: fx saves no HTTP failure (it saves "fx stopped
// before this turn finished"), and saves no partial answer it restarted.
export type Plan = { name: string; replies: Reply[]; requests: number; replay: boolean };

const PLANS: Plan[] = [
  { name: "nudge-then-reply", replies: ["empty_other", "reply"], requests: 2, replay: true },
  { name: "empty-twice-fails", replies: ["empty_other", "empty_other"], requests: 2, replay: true },
  { name: "done-placeholder", replies: ["empty_stop"], requests: 1, replay: true },
  { name: "auth-failure", replies: ["unauthorized"], requests: 1, replay: false },
  { name: "length-cut-text", replies: ["length_text"], requests: 1, replay: true },
  { name: "length-cut-tools", replies: ["length_tools", "length_tools"], requests: 2, replay: true },
  { name: "restart-after-partial", replies: ["partial_eof", "reply"], requests: 2, replay: false },
];

export function stressPlan(stalls: number): Plan {
  const replies: Reply[] = [];
  for (let n = 0; n < stalls; n++) replies.push("tool_step", "empty_other");
  replies.push("reply");
  return { name: `stress-${stalls}-stalls`, replies, requests: replies.length, replay: true };
}

function respond(reply: Reply, n: number): Response {
  const stop = { type: "finish", finishReason: { unified: "stop", raw: "stop" } };
  switch (reply) {
    case "reply":
      return fakeGatewaySse([{ type: "text-delta", id: `t${n}`, delta: `REPLY_${n}` }, stop]);
    case "empty_other":
      return fakeGatewaySse([{ type: "finish", finishReason: { unified: "other", raw: "UNEXPECTED_TOOL_CALL" } }]);
    case "empty_stop":
      return fakeGatewaySse([stop]);
    case "unauthorized":
      return new Response(JSON.stringify({ error: { message: "rejected fake key" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    case "length_text":
      return fakeGatewaySse([
        { type: "text-delta", id: `t${n}`, delta: `REPLY_${n}` },
        { type: "finish", finishReason: { unified: "length", raw: "length" } },
      ]);
    case "length_tools":
      return fakeGatewaySse([
        { type: "tool-call", toolCallId: `call_${n}`, toolName: "glob_files", input: { pattern: "*" } },
        { type: "finish", finishReason: { unified: "length", raw: "length" } },
      ]);
    case "partial_eof":
      return new Response(`data: ${JSON.stringify({ type: "text-delta", id: `t${n}`, delta: `PARTIAL_${n}` })}\n\n`, {
        headers: { "content-type": "text/event-stream" },
      });
    case "tool_step":
      return fakeGatewaySse([
        { type: "text-delta", id: `t${n}`, delta: `STEP_${n}` },
        { type: "tool-call", toolCallId: `call_${n}`, toolName: "glob_files", input: { pattern: "*" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
      ]);
  }
}

// ------------------------------------------------------------- abstraction --

export type Observation = { kind: string; blank: boolean; type: "message" | "notice"; severity: string; same: boolean; text: string };

// The kind of text fx emitted, read from the text a client got. A text no
// rule names is "unknown", which no step of the spec matches.
export function classify(raw: string): string {
  const text = raw.trim();
  if (/^(REPLY|PARTIAL|STEP)_\d+$/.test(text)) return "assistant";
  if (/^The model stopped without a reply \(.*\)\. Asking it to continue\.$/.test(text)) return "operational";
  if (/^The reply ran out of output tokens before any text\. Retrying with /.test(text)) return "operational";
  if (/^Ultrafast was requested/.test(text)) return "operational";
  if (/^The model stopped without a reply \(.*\)\. Continue with a follow-up prompt if needed\.$/.test(text)) return "turn_failure";
  if (/^Agent step limit reached|^Repeated malformed tool arguments/.test(text)) return "turn_failure";
  if (text === "Done.") return "saved_reply";
  if (/^The reply ran out of output tokens before (any text\.$|its tool calls were complete)/.test(text)) return "saved_reply";
  if (/Restarted the answer$|^Response interrupted\. Restarting\.$/.test(text)) return "restarted";
  if (/^response hit provider length limit|^File change committed, but some secondary reporting failed\.$/.test(text)) return "system";
  if (/authentication failed · HTTP \d{3}$|^HTTP \d{3}/.test(text)) return "http_failure";
  if (/^\[context\]|^skill discovery /.test(text)) return "context";
  return "unknown";
}

function observe(updates: any[]): Observation[] {
  const out: Observation[] = [];
  let lastMessage: string | null = null;
  for (const update of updates) {
    if (update?.sessionUpdate === "agent_message_chunk") {
      const text: string = update.content?.text ?? "";
      const blank = text.trim() === "";
      out.push({ kind: blank ? "any" : classify(text), blank, type: "message", severity: "-", same: lastMessage !== null && update.messageId === lastMessage, text });
      lastMessage = update.messageId;
    } else if (update?.sessionUpdate === "notice") {
      const title: string = update.title ?? "";
      out.push({ kind: classify(title), blank: title.trim() === "", type: "notice", severity: String(update.severity), same: false, text: title });
    }
  }
  return out;
}

// --------------------------------------------------------------- ACP client --

class Acp {
  private buffer = "";
  private lines: any[] = [];
  private waiters: Array<() => void> = [];
  private nextId = 1;
  stderr = "";
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly log: object[]) {
    this.exited = proc.exited.then((code) => {
      for (const waiter of this.waiters.splice(0)) waiter();
      return code;
    });
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk, { stream: true });
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) if (line.trim()) this.lines.push(JSON.parse(line));
        for (const waiter of this.waiters.splice(0)) waiter();
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk, { stream: true });
    })();
  }

  // Sends a request and returns its response with the notifications that came first.
  async call(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<{ response: any; notes: any[] }> {
    const id = this.nextId++;
    this.log.push({ dir: "out", id, method, params });
    const stdin = this.proc.stdin as any;
    stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    stdin.flush?.();
    const notes: any[] = [];
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const message = this.lines.shift();
      if (!message) {
        await new Promise<void>((wake) => { this.waiters.push(wake); setTimeout(wake, 250); });
        continue;
      }
      this.log.push({ dir: "in", ...message });
      if ("method" in message && "id" in message) {
        stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "cancelled" } } })}\n`);
        continue;
      }
      if (message.id === id) return { response: message, notes };
      if (message.method === "session/update") notes.push(message.params?.update);
    }
    throw new Error(`no response to ${method} within ${timeoutMs} ms: ${this.stderr}`);
  }

  async close(): Promise<number> {
    (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const code = await this.exited;
    clearTimeout(timer);
    return code;
  }
}

// ------------------------------------------------------------------ runner --

export type Client = "notices" | "plain";

export async function runPlan(plan: Plan, client: Client, binary: string, dir: string) {
  mkdirSync(dir, { recursive: true });
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-notices-")));
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const workspace = join(root, "workspace");
  mkdirSync(join(fxHome, "skills"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true, mode: 0o700 });
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  writeFileSync(join(fxHome, "settings.json"), `${JSON.stringify({ session_titles: false, models: { gateway: MODEL } })}\n`, { mode: 0o600 });

  let served = 0;
  const gateway = startDynamicFakeGateway(() => {
    const reply = plan.replies[served] ?? "reply";
    served += 1;
    return respond(reply, served);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });

  // Written out in full: nothing comes from the driver's own environment.
  const env: Record<string, string> = {
    HOME: home,
    PATH: "/usr/bin:/bin",
    TMPDIR: tmpdir(),
    FX_HOME: fxHome,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-acp-notices-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
  };
  const capabilities = client === "notices" ? { session: { notices: {} } } : {};
  const log: object[] = [];
  const exits: number[] = [];
  const spawn = () => new Acp(Bun.spawn([binary, "acp"], { cwd: workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }), log);
  let stderr = "";
  let updates: any[] = [];
  let stopReason: string | null = null;
  let replayed: any[] = [];
  let error: string | null = null;
  let acp = spawn();
  try {
    await acp.call("initialize", { protocolVersion: 1, clientCapabilities: capabilities });
    const created = await acp.call("session/new", { cwd: workspace, mcpServers: [] });
    const sessionId = created.response.result?.sessionId as string | undefined;
    if (!sessionId) throw new Error(`session/new failed: ${JSON.stringify(created.response)}`);
    await acp.call("session/set_mode", { sessionId, modeId: "auto" });
    const prompt = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "Answer the notice check." }] }, 120_000);
    if (prompt.response.error) throw new Error(`session/prompt failed: ${JSON.stringify(prompt.response.error)}`);
    stopReason = prompt.response.result?.stopReason ?? null;
    updates = prompt.notes;
    stderr += acp.stderr;
    exits.push(await acp.close());

    acp = spawn();
    await acp.call("initialize", { protocolVersion: 1, clientCapabilities: capabilities });
    const loaded = await acp.call("session/load", { sessionId, cwd: workspace, mcpServers: [] });
    if (loaded.response.error) throw new Error(`session/load failed: ${JSON.stringify(loaded.response.error)}`);
    replayed = loaded.notes;
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    stderr += acp.stderr;
    exits.push(await acp.close());
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }

  const observations = observe(updates);
  const live = observations
    .filter((o) => o.type === "message" && o.kind !== "http_failure")
    .map((o) => o.text).join("").replace(/\s+/g, " ").trim();
  const replay = replayed
    .filter((u) => u?.sessionUpdate === "agent_message_chunk")
    .map((u) => u.content?.text ?? "").join("").replace(/\s+/g, " ").trim();
  writeJson(join(dir, "observations.json"), observations);
  writeJson(join(dir, "result.json"), { plan, client, served, stopReason, exits, stderr, error, live, replay });
  writeFileSync(join(dir, "acp.jsonl"), log.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  return { observations, served, stopReason, exits, stderr, error, live, replay };
}

// ---------------------------------------------------------------- TLC side --

const tla = (value: string) => JSON.stringify(value);

function obsModule(observations: Observation[], notices: boolean): string {
  const record = (o: Observation) =>
    `[kind |-> ${tla(o.kind)}, blank |-> ${o.blank ? "TRUE" : "FALSE"}, type |-> ${tla(o.type)}, severity |-> ${tla(o.severity)}, same |-> ${o.same ? "TRUE" : "FALSE"}]`;
  return [
    "---------------------------- MODULE AcpNoticesObs ----------------------------",
    "(* Generated from one observed fx acp turn. *)",
    `Notices == ${notices ? "TRUE" : "FALSE"}`,
    `TMaxSteps == ${observations.length * 4 + 4}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  '    Mode = "fixed"',
  "    MaxSteps <- TMaxSteps",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "VIEW TraceView",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

async function validate(observations: Observation[], notices: boolean, dir: string) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, states: null };
  writeFileSync(join(dir, "AcpNoticesObs.tla"), obsModule(observations, notices));
  writeFileSync(join(dir, "AcpNoticesTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpNoticesTrace.tla", "AcpNoticesTrace.cfg", SPECS, SPEC_DIR);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict = "TOOL_ERROR";
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  const result = { verdict, states: run.distinctStates, durationMs: run.durationMs, exitCode: run.exitCode };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}

// -------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

async function main() {
  const binary = fxBin();
  const label = argValue("--label") ?? "run";
  const stress = Number(argValue("--stress") ?? "0");
  const only = argValue("--only");
  const report = outDir(`acp-notices-${label}`);
  writeJson(join(report, "manifest.json"), { binary, binary_sha256: sha256File(binary), toolchain: tlcToolchain(), bun: Bun.version, stress, argv: process.argv.slice(1) });

  const plans = [...PLANS, ...(stress > 0 ? [stressPlan(stress)] : [])].filter((plan) => !only || new RegExp(only).test(plan.name));
  const results: object[] = [];
  let failed = false;
  for (const plan of plans) {
    for (const client of ["notices", "plain"] as Client[]) {
      const name = `${plan.name}-${client}`;
      const dir = join(report, "traces", name);
      const started = performance.now();
      const run = await runPlan(plan, client, binary, dir);
      const checked = run.error ? null : await validate(run.observations, client === "notices", dir);
      const problems: string[] = [];
      if (run.error) problems.push(run.error);
      if (checked && checked.verdict !== "ACCEPTED") problems.push(`TLC ${checked.verdict}`);
      if (run.served !== plan.requests) problems.push(`fake Gateway served ${run.served} model requests, expected ${plan.requests}`);
      if (run.stderr.trim() !== "") problems.push(`stderr: ${run.stderr.trim().slice(0, 300)}`);
      if (run.exits.some((code) => code !== 0)) problems.push(`exit codes ${run.exits.join(",")}`);
      if (client === "notices" && plan.replay && run.live !== run.replay) problems.push(`live messages ${JSON.stringify(run.live)} differ from session/load ${JSON.stringify(run.replay)}`);
      const notices = run.observations.filter((o) => o.type === "notice").length;
      const messages = run.observations.length - notices;
      const ms = Math.round(performance.now() - started);
      results.push({ name, verdict: checked?.verdict ?? "RUN_ERROR", states: checked?.states ?? null, served: run.served, stopReason: run.stopReason, notices, messages, ms, problems });
      if (problems.length > 0) failed = true;
      console.log(`${name}: ${problems.length === 0 ? "ok" : "FAIL"} (${notices} notices, ${messages} messages, ${run.served} requests, stop ${run.stopReason}, ${ms} ms)${problems.length ? `\n  ${problems.join("\n  ")}` : ""}`);
      if (problems.length > 0) {
        for (const o of run.observations) console.log(`    ${o.type} ${o.kind}${o.type === "notice" ? `/${o.severity}` : o.same ? " same" : " new"} ${JSON.stringify(o.text)}`);
      }
    }
  }

  // Controls: the bridge tells a conforming turn from one with the bug.
  const notice = (kind: string, severity = "info"): Observation => ({ kind, blank: false, type: "notice", severity, same: false, text: "" });
  const message = (kind: string, same = false): Observation => ({ kind, blank: false, type: "message", severity: "-", same, text: "" });
  const controls = [
    { name: "conforming", expect: "ACCEPTED", notices: true, obs: [notice("operational"), message("assistant"), message("turn_failure")] },
    { name: "operational-as-message", expect: "REJECTED", notices: true, obs: [message("operational"), message("assistant")] },
    { name: "failure-as-notice", expect: "REJECTED", notices: true, obs: [notice("turn_failure", "error")] },
    { name: "reply-joins-across-notice", expect: "REJECTED", notices: true, obs: [message("assistant"), notice("restarted"), message("assistant", true)] },
    { name: "plain-gets-notice", expect: "REJECTED", notices: false, obs: [notice("system", "warning")] },
    { name: "empty", expect: "TOOL_ERROR", notices: true, obs: [] as Observation[] },
  ];
  for (const control of controls) {
    const got = (await validate(control.obs, control.notices, join(report, "controls", control.name))).verdict;
    const ok = got === control.expect;
    if (!ok) failed = true;
    console.log(`control ${control.name}: ${got} (expected ${control.expect})${ok ? "" : " FAIL"}`);
  }
  writeJson(join(report, "summary.json"), { results });
  console.log(`report: ${report}`);
  process.exit(failed ? 1 : 0);
}

if (import.meta.main) await main();
