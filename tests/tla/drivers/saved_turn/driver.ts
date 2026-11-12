// Runs the built fx binary along tests/tla/saved_turn/SavedTurn.tla and has TLC
// check every turn it observes (SavedTurnTrace.tla).
//
// Each scenario is one turn of fx against a local fake gateway that serves a
// script of replies: tool calls, an empty reply that stops for `other` (which
// fx answers with its nudge), a blank reply after silent tool steps (which fx
// answers with "Summarize what you just did."), and a final answer. Some replies
// switch the git branch of the workspace while fx handles them, as another
// process would, so the runtime context changes between two steps and fx adds a
// note at the next one. Then a second turn follows: `fx ask --resume`, or a
// second ACP prompt in the same session.
//
// The driver maps every request of the first turn, and the part of the second
// turn's first request that holds the first turn, to the model's atoms (C, R,
// A, N, K, T: see SavedTurn.tla), and TLC replays them through the model's own
// actions. A request the model cannot send, or a next turn whose restored turn
// is not what the model's Restore gives, is REJECTED.
//
// Every scenario is also replayed through the model of fx before the change
// (Bug = "append_notes"). The scenarios where a note and fx's own prompt share a
// boundary tell the two models apart, so a run is a self-check of the model too:
//   --self-check   the built binary, which must be ACCEPTED by the design in every
//                  scenario, and REJECTED by the old model in the order-sensitive
//                  ones
//   --planted      a binary that has the bug (FX_BIN, such as one built before the
//                  change), which the design must REJECT in the order-sensitive
//                  scenarios, where the old model ACCEPTS it
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/saved_turn/driver.ts --self-check
//   FX_BIN=/path/to/older/fx bun tests/tla/drivers/saved_turn/driver.ts --planted
//
// Exit codes: 0 every verdict as expected, 1 a verdict that is not, 2 a
// toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Kind = "tool" | "tool_silent" | "empty" | "blank" | "final";
type Reply = { kind: Kind; switchBranch?: boolean };
type Scenario = {
  name: string;
  via: "ask" | "acp";
  replies: Reply[];
  // A note and fx's own prompt share a boundary, so the order they join in matters.
  orderSensitive: boolean;
};
type Observation = { name: string; sent: string[][]; next: string[]; evidence: Record<string, unknown> };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "google/gemini-4-argon";
const FIRST_PROMPT = "Answer briefly.";
const SECOND_PROMPT = "And once more.";
const NUDGE = "Your last reply had no text and no tool call.";
const SUMMARIZE = "Summarize what you just did.";
const NOTE_BLOCK = "\n\n<fx-context-update>";
const NOTE_OPEN = "<fx-context-update>";
const BRANCH = "feature/saved-order";
const tlaDir = join(TLA_ROOT, "saved_turn");

const scenarios: Scenario[] = [
  { name: "nudge", via: "ask", orderSensitive: false, replies: [{ kind: "empty" }, { kind: "final" }] },
  { name: "nudge-note", via: "ask", orderSensitive: true, replies: [{ kind: "empty", switchBranch: true }, { kind: "final" }] },
  { name: "tool-note", via: "ask", orderSensitive: false, replies: [{ kind: "tool", switchBranch: true }, { kind: "final" }] },
  {
    name: "tool-nudge-note",
    via: "ask",
    orderSensitive: true,
    replies: [{ kind: "tool" }, { kind: "empty", switchBranch: true }, { kind: "final" }],
  },
  {
    name: "summarize-note",
    via: "ask",
    orderSensitive: true,
    replies: [{ kind: "tool_silent" }, { kind: "tool_silent" }, { kind: "blank", switchBranch: true }, { kind: "final" }],
  },
  {
    name: "double-trail-note",
    via: "ask",
    orderSensitive: true,
    replies: [
      { kind: "tool_silent" },
      { kind: "tool_silent" },
      { kind: "blank" },
      { kind: "empty", switchBranch: true },
      { kind: "final" },
    ],
  },
  { name: "acp-nudge-note", via: "acp", orderSensitive: true, replies: [{ kind: "empty", switchBranch: true }, { kind: "final" }] },
];

function reply(helpers: any, reply: Reply, n: number): Response {
  const { fakeGatewaySse } = helpers;
  switch (reply.kind) {
    case "tool":
      return fakeGatewaySse([
        { type: "text-delta", id: `t${n}`, delta: "Checking the files." },
        { type: "tool-call", toolCallId: `call_${n}`, toolName: "glob_files", input: { pattern: "*" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "STOP" } },
      ]);
    case "tool_silent":
      return fakeGatewaySse([
        { type: "tool-call", toolCallId: `call_${n}`, toolName: "glob_files", input: { pattern: "*" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "STOP" } },
      ]);
    case "empty":
      return fakeGatewaySse([{ type: "finish", finishReason: { unified: "other", raw: "UNEXPECTED_TOOL_CALL" } }]);
    case "blank":
      return fakeGatewaySse([
        { type: "text-delta", id: `t${n}`, delta: " \n" },
        { type: "finish", finishReason: { unified: "stop", raw: "STOP" } },
      ]);
    case "final":
      return fakeGatewaySse([
        { type: "text-delta", id: `t${n}`, delta: `FINAL_${n}` },
        { type: "finish", finishReason: { unified: "stop", raw: "STOP" } },
      ]);
  }
}

type Part = { type?: string; text?: string; output?: { value?: unknown } };
type PromptMessage = { role: string; content: unknown };

function parts(message: PromptMessage): Part[] {
  return Array.isArray(message.content) ? (message.content as Part[]) : [];
}

function textOf(message: PromptMessage): string {
  if (typeof message.content === "string") return message.content;
  return parts(message).map((part) => (part.type === "text" ? (part.text ?? "") : "")).join("");
}

function promptOf(body: string): PromptMessage[] {
  return JSON.parse(body).prompt as PromptMessage[];
}

// The atom of a user message fx wrote or the user typed, without a carried note.
function userAtom(own: string): string {
  if (own.includes(NUDGE) || own.includes(SUMMARIZE)) return "K";
  throw new Error(`a user message the driver cannot map: ${JSON.stringify(own.slice(0, 120))}`);
}

// The atoms of the messages in prompt[from, to). A context note rides on the
// message before it, so its text carries the note's block; the note is an atom
// of its own right after that message's own.
function atoms(prompt: PromptMessage[], from: number, to: number): string[] {
  const result: string[] = [];
  for (const message of prompt.slice(from, to)) {
    if (message.role === "system") {
      result.push("N");
    } else if (message.role === "assistant") {
      result.push(parts(message).some((part) => part.type === "tool-call") ? "C" : "A");
    } else if (message.role === "tool") {
      const results = parts(message).filter((part) => part.type === "tool-result");
      result.push(...results.map(() => "R"));
      if (results.some((part) => String(part.output?.value ?? "").includes(NOTE_OPEN))) result.push("N");
    } else if (message.role === "user") {
      const text = textOf(message);
      const at = text.indexOf(NOTE_BLOCK);
      result.push(userAtom(at >= 0 ? text.slice(0, at) : text));
      if (at >= 0) result.push("N");
    } else {
      throw new Error(`a message role the driver cannot map: ${message.role}`);
    }
  }
  return result;
}

// The turn's own user message, and the atoms after it, whose note it may carry.
function turnAtoms(prompt: PromptMessage[], rootText: string, end: number = prompt.length): string[] {
  const root = prompt.findIndex((message) => message.role === "user" && textOf(message).startsWith(rootText));
  if (root < 0) throw new Error(`no user message starts with ${JSON.stringify(rootText)}`);
  const own = textOf(prompt[root]!);
  return [...(own.includes(NOTE_BLOCK) ? ["N"] : []), ...atoms(prompt, root + 1, end)];
}

type Workspace = { root: string; home: string; workspace: string };

function makeWorkspace(scratch: string, name: string): Workspace {
  const root = mkdtempSync(join(scratch, `${name}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  const init = Bun.spawnSync(["git", "init", "-q", "-b", "main"], { cwd: workspace });
  if (init.exitCode !== 0) throw new Error(`git init: ${init.stderr.toString()}`);
  return { root, home, workspace };
}

function environment(ws: Workspace, gateway: { baseUrl: string; chatUrl: string }) {
  return testEnvironment({
    HOME: ws.home,
    AI_GATEWAY_API_KEY: "fake-saved-turn-driver-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: MODEL,
  });
}

async function runAsk(args: string[], ws: Workspace, env: Record<string, string>) {
  const child = Bun.spawn([binary, "ask", "--json", "--auto", ...args], {
    cwd: ws.workspace,
    env,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), 60_000);
  const [stdout, stderr, exit] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  clearTimeout(timer);
  let json: { session_id?: string; final_output?: string } = {};
  try {
    json = JSON.parse(stdout.trim());
  } catch {
    // The evidence below says what fx printed.
  }
  return { exit, json, tail: `${stdout}\n${stderr}`.slice(-400) };
}

async function runScenario(helpers: any, scenario: Scenario, scratch: string): Promise<Observation> {
  const ws = makeWorkspace(scratch, scenario.name);
  const served: string[] = [];
  const bodies: string[] = [];
  const gateway = helpers.startDynamicFakeGateway(
    (body: string) => {
      const index = bodies.length;
      bodies.push(body);
      const next: Reply = scenario.replies[index] ?? { kind: "final" };
      served.push(next.kind);
      if (next.switchBranch) writeFileSync(join(ws.workspace, ".git", "HEAD"), `ref: refs/heads/${BRANCH}\n`);
      return reply(helpers, next, index + 1);
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  try {
    const env = environment(ws, gateway);
    let evidence: Record<string, unknown>;
    if (scenario.via === "ask") {
      const first = await runAsk([FIRST_PROMPT], ws, env);
      const turnRequests = bodies.length;
      const second = await runAsk(["--resume", first.json.session_id ?? "missing", SECOND_PROMPT], ws, env);
      evidence = { first: first.exit, second: second.exit, firstTail: first.tail, secondTail: second.tail, turnRequests };
    } else {
      // The turn's own requests are the ones before the second prompt's.
      let turnRequests = 0;
      const stops = await runAcpTwice(ws, env, () => {
        turnRequests = bodies.length;
      });
      evidence = { stops, turnRequests };
    }
    const turnRequests = evidence.turnRequests as number;
    if (turnRequests < 1 || bodies.length < turnRequests + 1) {
      throw new Error(`scenario ${scenario.name}: ${bodies.length} requests, ${turnRequests} in the first turn; ${JSON.stringify(evidence)}`);
    }
    const sent = bodies.slice(0, turnRequests).map((body) => turnAtoms(promptOf(body), FIRST_PROMPT));
    // The second turn's first request: its last message is the new prompt, and
    // the first turn's final reply is the one before it.
    const followUp = promptOf(bodies[turnRequests]!);
    const next = turnAtoms(followUp, FIRST_PROMPT, followUp.length - 2);
    return { name: scenario.name, sent, next, evidence: { ...evidence, served } };
  } finally {
    gateway.stop();
    rmSync(ws.root, { recursive: true, force: true });
  }
}

// A minimal ACP client: JSON lines over the agent's standard input and output.
// Two prompts in one session; `afterFirst` runs when the first one has ended.
async function runAcpTwice(ws: Workspace, env: Record<string, string>, afterFirst: () => void): Promise<string[]> {
  const child = Bun.spawn([binary, "acp"], { cwd: ws.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const lines: string[] = [];
  const waiters: Array<(line: string) => void> = [];
  (async () => {
    let buffer = "";
    for await (const chunk of child.stdout) {
      buffer += new TextDecoder().decode(chunk);
      const pieces = buffer.split("\n");
      buffer = pieces.pop() ?? "";
      for (const line of pieces) {
        if (!line.trim()) continue;
        const waiter = waiters.shift();
        if (waiter) waiter(line);
        else lines.push(line);
      }
    }
  })();
  const readLine = () =>
    new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("ACP read timed out")), 60_000);
      const done = (line: string) => {
        clearTimeout(timer);
        resolve(line);
      };
      const queued = lines.shift();
      if (queued !== undefined) done(queued);
      else waiters.push(done);
    });
  let id = 0;
  const request = async (method: string, params: object) => {
    const mine = ++id;
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: mine, method, params })}\n`);
    child.stdin.flush();
    for (;;) {
      const message = JSON.parse(await readLine());
      if (message.id === mine && (message.result !== undefined || message.error !== undefined)) return message;
    }
  };
  const stops: string[] = [];
  try {
    await request("initialize", { protocolVersion: 1 });
    const created = await request("session/new", { cwd: ws.workspace, mcpServers: [] });
    if (created.error) throw new Error(`session/new: ${JSON.stringify(created.error)}`);
    const sessionId = created.result.sessionId;
    const mode = await request("session/set_mode", { sessionId, modeId: "auto" });
    if (mode.error) throw new Error(`session/set_mode: ${JSON.stringify(mode.error)}`);
    for (const [index, text] of [FIRST_PROMPT, SECOND_PROMPT].entries()) {
      const done = await request("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
      stops.push(done.error ? `error ${JSON.stringify(done.error)}` : String(done.result.stopReason));
      if (index === 0) afterFirst();
    }
    return stops;
  } finally {
    child.stdin.end();
    const killer = setTimeout(() => child.kill(9), 5_000);
    await child.exited;
    clearTimeout(killer);
  }
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.map(str).join(", ")}>>`;

function observedModule(observation: Observation): string {
  return [
    "-------------------------- MODULE SavedTurnObserved --------------------------",
    "(* Generated by tests/tla/drivers/saved_turn/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == [sent |-> <<${observation.sent.map(seq).join(", ")}>>, next |-> ${seq(observation.next)}]`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observation: Observation, bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${observation.name}-${bug}-`));
  for (const file of ["SavedTurn.tla", "SavedTurnTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "SavedTurnObserved.tla"), observedModule(observation));
  writeFileSync(
    join(dir, "trace.cfg"),
    [
      "SPECIFICATION TraceSpec",
      "CONSTANTS",
      "  MaxAtoms = 30",
      "  MaxRequests = 30",
      '  Notices = "none"',
      "  Review = FALSE",
      "  Hook = TRUE",
      "  DoubleTrail = TRUE",
      `  Bug = ${str(bug)}`,
      "CONSTRAINT TraceBounded",
      "INVARIANT NotAllMatched",
      "CHECK_DEADLOCK FALSE",
      "",
    ].join("\n"),
  );
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn(
    [java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar, "tlc2.TLC",
      "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "SavedTurnTrace.tla"],
    { cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

async function main(): Promise<number> {
  const planted = process.argv.includes("--planted");
  const helpers = await targetHelpers();
  const out = outDir("saved_turn");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const observations: Array<{ scenario: Scenario; observation: Observation }> = [];
  for (const scenario of scenarios) {
    observations.push({ scenario, observation: await runScenario(helpers, scenario, scratch) });
  }
  writeJson(join(out, "observations.json"), observations.map((o) => o.observation));
  console.log(`${observations.length} scenarios of ${binary}; observations: ${join(out, "observations.json")}`);

  let failures = 0;
  const rows: string[] = [];
  for (const { scenario, observation } of observations) {
    const design = await runTrace(observation, "none", out);
    const today = await runTrace(observation, "append_notes", out);
    if (design.verdict === "TOOL_ERROR" || today.verdict === "TOOL_ERROR") {
      console.log(`TOOL_ERROR in ${scenario.name}: ${design.dir} ${today.dir}`);
      return 2;
    }
    // The binary under test is the design's, or a planted bug's.
    const wantDesign: Verdict = planted && scenario.orderSensitive ? "REJECTED" : "ACCEPTED";
    const wantToday: Verdict = scenario.orderSensitive ? (planted ? "ACCEPTED" : "REJECTED") : "ACCEPTED";
    const ok = design.verdict === wantDesign && today.verdict === wantToday;
    if (!ok) failures++;
    rows.push(
      `${ok ? "ok  " : "FAIL"} ${scenario.name.padEnd(20)} design ${design.verdict} (want ${wantDesign}), before the change ${today.verdict} (want ${wantToday})`,
    );
    rows.push(`       requests ${observation.sent.map((s) => s.join("")).join(" | ")}; next turn holds ${observation.next.join("")}`);
  }
  for (const row of rows) console.log(row);
  console.log(failures === 0 ? (planted ? "PLANTED BUG CAUGHT" : "ACCEPTED") : `${failures} scenario(s) not as expected`);
  return failures === 0 ? 0 : 1;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
