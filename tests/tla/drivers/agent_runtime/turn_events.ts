// Runs the built fx binary along tests/tla/agent_runtime/TurnEvents.tla and has
// TLC check what each front end showed of one turn (TurnEventsTrace.tla).
//
// The turn is one prompt against a local fake gateway: text and a read_file
// call, text and an edit_file call, then a final answer. The agent loop emits
// its events in that order: each text, then each tool call's start and end.
// The driver runs the turn through `fx acp` and `fx ask`, records the order in
// which each front end showed those events, and asks TLC whether that order
// is a behavior of the model, in which a front end shows every event the loop
// emits, in the loop's order. Each front end's script holds the events it
// shows: fx acp shows a tool call's start and end as updates, and fx ask shows
// a tool call as one line.
//
// --self-check also checks two runs the model must reject: one with two
// events swapped and one with the last text missing.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/turn_events.ts
//   bun tests/tla/drivers/agent_runtime/turn_events.ts --self-check
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { realpathSync } from "node:fs";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";
import { Client } from "../acp/turn_events/harness";

type Kind = "text" | "tool";
type Observation = { at: number; kind: Kind };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const SPEC_DIR = join(TLA_ROOT, "agent_runtime");
const READ_ID = "te_read_1";
const EDIT_ID = "te_edit_1";
type Script = Array<{ kind: Kind; marker: string }>;
// What the loop emits, in order, and the marker a front end shows it by.
const ACP_SCRIPT: Script = [
  { kind: "text", marker: "TE_TEXT_1" },
  { kind: "tool", marker: `start:${READ_ID}` },
  { kind: "tool", marker: `end:${READ_ID}` },
  { kind: "text", marker: "TE_TEXT_2" },
  { kind: "tool", marker: `start:${EDIT_ID}` },
  { kind: "tool", marker: `end:${EDIT_ID}` },
  { kind: "text", marker: "TE_TEXT_3" },
];
const ASK_SCRIPT: Script = [
  { kind: "text", marker: "TE_TEXT_1" },
  { kind: "tool", marker: `call:${READ_ID}` },
  { kind: "text", marker: "TE_TEXT_2" },
  { kind: "tool", marker: `call:${EDIT_ID}` },
  { kind: "text", marker: "TE_TEXT_3" },
];

class Fixture {
  readonly root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-turn-events-")));
  readonly home = join(this.root, "home");
  readonly workspace = join(this.root, "workspace");
  gateway: any = null;

  constructor() {
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, permission_mode: "full-access" })}\n`, { mode: 0o600 });
    writeFileSync(join(this.workspace, "read-me.txt"), "TURN_EVENTS_READ\n");
    writeFileSync(join(this.workspace, "edit-me.txt"), "before\n");
  }

  async env(): Promise<Record<string, string>> {
    const helpers = await targetHelpers();
    const finish = (unified: string) => ({ type: "finish", finishReason: { unified, raw: unified } });
    this.gateway = helpers.startFakeGateway([
      helpers.fakeGatewaySse([
        { type: "text-delta", id: "t1", delta: "TE_TEXT_1" },
        { type: "tool-call", toolCallId: READ_ID, toolName: "read_file", input: { path: "read-me.txt" } },
        finish("tool-calls"),
      ]),
      helpers.fakeGatewaySse([
        { type: "text-delta", id: "t2", delta: "TE_TEXT_2" },
        { type: "tool-call", toolCallId: EDIT_ID, toolName: "edit_file", input: { path: "edit-me.txt", old_string: "before", new_string: "after" } },
        finish("tool-calls"),
      ]),
      helpers.fakeGatewaySse([{ type: "text-delta", id: "t3", delta: "TE_TEXT_3" }, finish("stop")]),
    ], { models: [{ id: helpers.FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }] });
    return testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "turn-events-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
  }

  dispose() {
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}

/// The script positions of the markers in `shown`, in the order shown, each
/// once: a front end may show one event in several pieces.
function observe(script: Script, shown: string[]): Observation[] {
  const seen = new Set<number>();
  const out: Observation[] = [];
  for (const marker of shown) {
    const at = script.findIndex((entry) => entry.marker === marker);
    if (at < 0 || seen.has(at)) continue;
    seen.add(at);
    out.push({ at: at + 1, kind: script[at].kind });
  }
  return out;
}

/// fx acp: a plain ACP client's message chunks and each tool call's first and
/// last update.
async function runAcp(): Promise<{ observations: Observation[]; error: string | null }> {
  const fixture = new Fixture();
  try {
    const env = await fixture.env();
    const client = new Client(Bun.spawn([binary, "acp"], { cwd: fixture.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    const created = await client.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
    const sessionId = created.answer.result.sessionId;
    const { answer } = await client.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "Read read-me.txt, then edit edit-me.txt." }] });
    if (answer.result?.stopReason !== "end_turn") throw new Error(`prompt failed: ${JSON.stringify(answer)}`);
    const shown: string[] = [];
    for (const message of client.inbox) {
      const update = message.method === "session/update" ? message.params?.update : null;
      if (!update) continue;
      if (update.sessionUpdate === "agent_message_chunk") shown.push(String(update.content?.text ?? "").trim());
      else if (update.sessionUpdate === "tool_call") shown.push(`start:${update.toolCallId}`);
      else if (update.sessionUpdate === "tool_call_update" && ["completed", "failed"].includes(update.status)) shown.push(`end:${update.toolCallId}`);
    }
    const end = await client.close();
    if (end.exit !== 0 || end.stderr !== "") throw new Error(`fx acp exited ${end.exit}: ${end.stderr.slice(0, 300)}`);
    return { observations: observe(ACP_SCRIPT, shown), error: null };
  } catch (err) {
    return { observations: [], error: err instanceof Error ? err.message : String(err) };
  } finally {
    fixture.dispose();
  }
}

/// fx ask: its text answer and its tool lines, written to one pipe in the
/// order fx wrote them. A tool call's line names its file.
async function runAsk(): Promise<{ observations: Observation[]; error: string | null; output: string }> {
  const fixture = new Fixture();
  try {
    const env = await fixture.env();
    const child = Bun.spawn(["/bin/sh", "-c", 'exec "$0" ask --no-save "$1" 2>&1', binary, "Read read-me.txt, then edit edit-me.txt."], {
      cwd: fixture.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const [output, exit] = await Promise.all([new Response(child.stdout).text(), child.exited]);
    if (exit !== 0) throw new Error(`fx ask exited ${exit}: ${output.slice(-300)}`);
    const shown: string[] = [];
    for (const match of output.matchAll(/TE_TEXT_\d|read-me\.txt|edit-me\.txt/g)) {
      const token = match[0];
      shown.push(token.startsWith("TE_TEXT_") ? token : `call:${token === "read-me.txt" ? READ_ID : EDIT_ID}`);
    }
    return { observations: observe(ASK_SCRIPT, shown), error: null, output };
  } catch (err) {
    return { observations: [], error: err instanceof Error ? err.message : String(err), output: "" };
  } finally {
    fixture.dispose();
  }
}

function obsModule(script: Script, observations: Observation[]): string {
  const kinds = script.map((entry) => JSON.stringify(entry.kind)).join(", ");
  return [
    "--------------------------- MODULE TurnEventsObs ---------------------------",
    "(* Generated from one observed fx run. *)",
    "EXTENDS Integers",
    `TScript == <<${kinds}>>`,
    "TraceLog == <<",
    observations.map((o) => `  [at |-> ${o.at}, kind |-> ${JSON.stringify(o.kind)}]`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Script <- TScript",
  "    Queued = FALSE",
  "    Today = FALSE",
  '    Mutation = "none"',
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

async function validate(script: Script, observations: Observation[], dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return "TOOL_ERROR";
  writeFileSync(join(dir, "TurnEventsObs.tla"), obsModule(script, observations));
  writeFileSync(join(dir, "TurnEventsTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "TurnEventsTrace.tla", "TurnEventsTrace.cfg", ["TurnEvents.tla", "TurnEventsTrace.tla"], SPEC_DIR);
  if (run.exitCode === 12 && run.violated === "NotDone") return "ACCEPTED";
  if (run.exitCode === 0 && /No error has been found/.test(run.output)) return "REJECTED";
  return "TOOL_ERROR";
}

async function main(): Promise<number> {
  try {
    readFileSync(binary);
  } catch {
    console.error(`missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const selfCheck = process.argv.includes("--self-check");
  const reportDir = outDir("agent-runtime-turn-events");
  const results: Array<{ name: string; verdict: Verdict; expect: Verdict; observed: Observation[]; error: string | null }> = [];
  const acp = await runAcp();
  const ask = await runAsk();
  for (const [name, run, script] of [["fx acp", acp, ACP_SCRIPT], ["fx ask", ask, ASK_SCRIPT]] as const) {
    const verdict = run.error ? "TOOL_ERROR" : await validate(script, run.observations, join(reportDir, name.replace(" ", "-")));
    results.push({ name, verdict, expect: "ACCEPTED", observed: run.observations, error: run.error });
  }
  if (selfCheck && !acp.error && acp.observations.length >= 2) {
    const swapped = acp.observations.map((o) => ({ ...o }));
    [swapped[0], swapped[1]] = [swapped[1], swapped[0]];
    results.push({ name: "control swapped", verdict: await validate(ACP_SCRIPT, swapped, join(reportDir, "control-swapped")), expect: "REJECTED", observed: swapped, error: null });
    const missing = acp.observations.slice(0, -1);
    results.push({ name: "control missing", verdict: await validate(ACP_SCRIPT, missing, join(reportDir, "control-missing")), expect: "REJECTED", observed: missing, error: null });
  }
  for (const result of results) {
    const order = result.observed.map((o) => `${o.kind}${o.at}`).join(" ");
    console.log(`${result.name}: ${result.verdict} (expected ${result.expect}) [${order}]${result.error ? ` ${result.error}` : ""}`);
  }
  writeJson(join(reportDir, "summary.json"), { results, askOutput: ask.output.slice(-2000) });
  console.log(`report: ${reportDir}`);
  if (results.some((result) => result.verdict === "TOOL_ERROR")) return 2;
  return results.every((result) => result.verdict === result.expect) ? 0 : 1;
}

process.exit(await main());
