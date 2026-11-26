// Walks the real `fx ask` along the states of ask_refusal/AskRefusal.tla under
// design "a" (design-a.cfg). TLC dumps the state graph with its action labels.
// Each case runs fx against the fake gateway. The driver reads what fx printed
// on stderr at each point the case stops, and what the --json run recorded for
// the call. Each reading becomes one view of one call, and it must be a view
// the model has. A model view that no reading reaches fails, unless UNREACHED
// lists it with the reason.
//
// Run: bun test ./tests/tla/drivers/ask_refusal/   (needs a built fx and TLC)

import { expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fxBin, outDir, runTlc, TLA_ROOT } from "../lib/tlc";
import { parseValue } from "../graph.mjs";
import { envWithoutFxHome, providerVersionTestEnv } from "../../../evals/eval-helpers";
import { LiveOutput } from "../../../e2e/live-output";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayHeldDecision,
  fakeGatewayPermissionDecision,
  fakeGatewaySerializedToolCall,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
} from "../../../e2e/tmux-helpers";

const TIMEOUT_MS = 40 * 60 * 1000;
const LINE_DEADLINE_MS = 15_000;
const CFG = "design-a.cfg";
const SPEC_DIR = join(TLA_ROOT, "ask_refusal");

// The text fx prints for each refusal the model names, on stderr and in
// --json. A refusal with other text fails the walk.
const REASON_TEXT: Record<string, string> = {
  R_DENY: "Tool access was denied by configured policy",
  R_FILE: "Tool access was denied by configured policy",
  R_ARGS: "Tool arguments were not valid JSON, so fx did not run the call. The conversation shows its arguments as {}.",
  R_CAUTION: "Action held after safety review",
  R_UNAVAILABLE: "Safety reviewer unavailable; action held",
  R_NO_TERMINAL: "permission required for tool execution in noninteractive mode",
};

// The reason token each refused kind carries in the model.
const REASON_OF_KIND: Record<string, string> = {
  deny: "R_DENY",
  file: "R_FILE",
  validation: "R_ARGS",
  caution: "R_CAUTION",
  unavail: "R_UNAVAILABLE",
  noterm: "R_NO_TERMINAL",
  hook: "R_HOOK",
};

// The model's views for a call that is cancelled before fx prints anything. The
// reading is the same whichever kind the call turns out to be, so each of these
// pairs is checked against the reading.
const PRE_START: Array<[string, boolean]> = [
  ["run", false],
  ["run", true],
  ["deny", false],
  ["validation", false],
  ["file", false],
  ["caution", true],
  ["unavail", true],
  ["noterm", false],
];

// Model views no case reaches, with the reason. Any other unreached view fails.
const UNREACHED: Array<{ match: (view: View) => boolean; reason: string }> = [
  {
    match: (view) => view.kind === "hook",
    reason: "fx on this base has no hook that refuses a call: no config key runs a hook before a tool call (src/core/config has no hooks key)",
  },
  {
    match: (view) => view.reviewing === 0 && view.running === 0 && view.refused === 0 && view.outcome === "none" && view.rec === "",
    reason: "fx prints nothing before a call's first line, and no reading can stop between that line and the state after it",
  },
  {
    match: (view) => view.refused > 0 && view.outcome === "none",
    reason: "a refusal is printed and recorded in the same step, so no reading sees the refusing state before its record",
  },
];

type View = {
  kind: string;
  reviewed: boolean;
  reviewing: number;
  running: number;
  refused: number;
  shown: string;
  rec: string;
  outcome: string;
};

const keyOf = (view: View) =>
  [view.kind, view.reviewed, view.reviewing, view.running, view.refused, view.shown, view.rec, view.outcome].join("|");

// ---- the model -----------------------------------------------------------

function parseState(label: string): Record<string, any> {
  const text = label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  const state: Record<string, any> = {};
  for (const entry of text.split(/\n(?=\/\\ )/)) {
    const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
    if (match) state[match[1]] = parseValue(match[2].trim());
  }
  return state;
}

function viewOfModel(state: Record<string, any>, call: string): View {
  return {
    kind: state.kind[call],
    reviewed: state.reviewed[call] === true,
    reviewing: Number(state.printedReviewing[call]),
    running: state.printedRun[call] === true ? 1 : 0,
    refused: Number(state.printedRefusal[call]),
    shown: state.shownReason[call],
    rec: state.recReason[call],
    outcome: state.outcome[call],
  };
}

type Model = {
  stateCount: number;
  views: Map<string, View>;
  // The lines a view shows, without its record: kind, reviewed, lines, shown.
  linesOf: Set<string>;
  // The actions that lead into a state with each view, for the report.
  actionsInto: Map<string, Set<string>>;
};

async function loadModel(): Promise<Model> {
  const dir = outDir("ask-refusal-graph");
  const dot = join(dir, "graph.dot");
  const run = await runTlc(dir, "AskRefusal", CFG, ["AskRefusal.tla", CFG], SPEC_DIR, ["-dump", "dot,actionlabels", dot]);
  expect(run.exitCode).toBe(0);
  expect(run.violated).toBeNull();
  const ids = new Map<string, number>();
  const states: Record<string, any>[] = [];
  const pending: Array<{ from: string; to: string; action: string }> = [];
  for (const line of readFileSync(dot, "utf8").split("\n")) {
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
    if (node) {
      ids.set(node[1]!, states.length);
      states.push(parseState(node[2]!));
      continue;
    }
    const edge = /^(-?\d+) -> (-?\d+) \[label="([^"]*)"/.exec(line);
    if (edge) pending.push({ from: edge[1]!, to: edge[2]!, action: edge[3]! });
  }
  const views = new Map<string, View>();
  for (const state of states) {
    for (const call of ["c1", "c2"]) {
      const view = viewOfModel(state, call);
      views.set(keyOf(view), view);
    }
  }
  const actionsInto = new Map<string, Set<string>>();
  for (const edge of pending) {
    const target = ids.get(edge.to);
    if (target === undefined) continue;
    const key = keyOf(viewOfModel(states[target]!, "c1"));
    if (!actionsInto.has(key)) actionsInto.set(key, new Set());
    actionsInto.get(key)!.add(edge.action);
  }
  const linesOf = new Set<string>();
  for (const view of views.values()) {
    linesOf.add(`${view.kind}|${view.reviewed}|${view.reviewing}|${view.running}|${view.refused}|${view.shown}`);
  }
  return { stateCount: states.length, views, linesOf, actionsInto };
}

// ---- the real fx ----------------------------------------------------------

type Case = {
  name: string;
  tool: "shell" | "write_file";
  // The call's input: a shell command, or a file to write (outside the workspace,
  // so the reviewer sees it), or raw arguments that do not parse.
  command?: string;
  path?: string;
  rawArgs?: string;
  kind: string;
  reviewed: boolean;
  // A review that holds the call until the test answers it. `refuse` is a
  // caution the confirming review keeps; `clear-after-caution` is a caution the
  // confirming review clears; `unavail` is a reviewer that answers 502 twice.
  review?: "refuse" | "clear" | "clear-after-caution" | "unavail";
  // Full access (--yolo): the reviewer is not asked, so a plain command runs unreviewed.
  yolo?: boolean;
  // Stop the run at a point: before the review answers, or after the start line.
  cancelAt?: "pending" | "running";
  // Cancel before the model answers, so the call never reaches fx's first line.
  preStart?: boolean;
  settings?: Record<string, unknown>;
  mode?: "auto" | "ask";
  start: string;
};

const SLEEP_COMMAND = `python3 -c 'import time; print("started", flush=True); time.sleep(60)'`;
const HELD_COMMAND = `python3 -c 'print("held-cmd")'`;

const CASES: Case[] = [
  { name: "run", tool: "shell", command: "printf ran-ok", kind: "run", reviewed: false, start: "Running " },
  { name: "run then fail", tool: "shell", command: "printf failed-out; exit 1", kind: "run", reviewed: false, start: "Running " },
  { name: "run without review (full access)", tool: "shell", command: "printf ran-ok", kind: "run", reviewed: false, yolo: true, start: "Running " },
  { name: "run cancelled while running (full access)", tool: "shell", command: SLEEP_COMMAND, kind: "run", reviewed: false, yolo: true, cancelAt: "running", start: "Running " },
  { name: "plain review allows", tool: "shell", command: "printf reviewed-ok", kind: "run", reviewed: true, review: "clear", start: "Running " },
  { name: "plain review allows, cancelled while pending", tool: "shell", command: "printf reviewed-ok", kind: "run", reviewed: true, review: "clear", cancelAt: "pending", start: "Running " },
  { name: "review unavailable, cancelled while pending", tool: "shell", command: "printf unavailable", kind: "unavail", reviewed: true, review: "unavail", cancelAt: "pending", start: "Running " },
  { name: "plain review allows, cancelled while running", tool: "shell", command: SLEEP_COMMAND, kind: "run", reviewed: true, review: "clear", cancelAt: "running", start: "Running " },
  { name: "review cancelled while pending", tool: "shell", command: HELD_COMMAND, kind: "caution", reviewed: true, review: "clear", cancelAt: "pending", start: "Running " },
  { name: "held then refused", tool: "shell", command: HELD_COMMAND, kind: "caution", reviewed: true, review: "refuse", start: "Running " },
  { name: "held then cleared", tool: "shell", command: HELD_COMMAND, kind: "caution", reviewed: true, review: "clear-after-caution", start: "Running " },
  { name: "held then cleared, cancelled while running", tool: "shell", command: SLEEP_COMMAND, kind: "caution", reviewed: true, review: "clear-after-caution", cancelAt: "running", start: "Running " },
  { name: "refused by configured deny", tool: "shell", command: "printf denied-cmd", kind: "deny", reviewed: false, settings: { permission: { bash: "deny" } }, start: "Running " },
  { name: "file write refused by configured deny", tool: "write_file", path: "outside-review.txt", kind: "file", reviewed: false, settings: { permission: { edit: "deny" } }, start: "Writing " },
  { name: "file write the review allows", tool: "write_file", path: "outside-review.txt", kind: "run", reviewed: true, review: "clear", start: "Writing " },
  { name: "file write the review holds", tool: "write_file", path: "outside-review.txt", kind: "caution", reviewed: true, review: "refuse", start: "Writing " },
  { name: "bad arguments", tool: "shell", rawArgs: "{not json", kind: "validation", reviewed: false, start: "Running " },
  { name: "review unavailable", tool: "shell", command: "printf unavailable", kind: "unavail", reviewed: true, review: "unavail", start: "Running " },
  { name: "no terminal to approve", tool: "shell", command: "printf denied-cmd", kind: "noterm", reviewed: false, mode: "ask", start: "Running " },
  { name: "cancelled before the model answers", tool: "shell", command: "printf never", kind: "run", reviewed: false, preStart: true, start: "Running " },
];

function holdReview() {
  let arrive!: () => void;
  const arrived = new Promise<void>((resolve) => {
    arrive = resolve;
  });
  let answer!: (response: Response) => void;
  const answered = new Promise<Response>((resolve) => {
    answer = resolve;
  });
  return { arrived, answer, classifier: async () => { arrive(); return answered; } };
}

function within<T>(promise: Promise<T>, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), LINE_DEADLINE_MS);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

function callInput(c: Case, root: string) {
  const id = `call_${c.name.replace(/\W+/g, "_")}`;
  if (c.rawArgs !== undefined) return fakeGatewaySerializedToolCall(id, "shell", c.rawArgs);
  if (c.tool === "shell") return fakeShellRun(id, c.command!);
  return fakeGatewayToolCall(id, "write_file", { path: join(root, c.path!), content: "reviewed\n" });
}

// What the fake reviewer answers when the test has not held it.
function answerFor(c: Case): (body: string) => Response {
  if (c.review === "unavail") return () => new Response("reviewer unavailable", { status: 502 });
  if (c.review === "refuse" || c.review === "clear-after-caution") {
    return (body: string) => fakeGatewayHeldDecision("held_review")(body);
  }
  return () => fakeGatewayPermissionDecision("clear");
}

// A wait that fx did not meet (a line that never printed). The walk records it and
// keeps going, so one run lists every difference from the model.
const anomalies: string[] = [];

type Reading = { gate: "pending" | "running" | "final"; text: string; json: any | null; cancelled: boolean; reviews: number };

async function runCase(c: Case, mode: "text" | "json"): Promise<Reading[]> {
  const root = outDir(`ask-refusal-${c.name.replace(/\W+/g, "-")}`);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(root, "outside-review.txt"), "old\n");
  if (c.settings) {
    mkdirSync(join(home, ".fx"), { recursive: true });
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(c.settings));
  }
  const held = mode === "text" && c.review && !c.preStart ? holdReview() : null;
  let arriveAtModel!: () => void;
  const modelRequest = new Promise<void>((resolve) => {
    arriveAtModel = resolve;
  });
  const hangingModelReply = async () => {
    arriveAtModel();
    return new Promise<Response>(() => {});
  };
  const reviews = c.reviewed
    ? c.review === "unavail"
      ? [held ? held.classifier : answerFor(c), answerFor(c)]
      : [held ? held.classifier : answerFor(c)]
    : [];
  const gateway = startFakeGateway(
    [c.preStart ? hangingModelReply : callInput(c, root), fakeGatewayFinalText("done")],
    {
      classifierResponses: reviews,
      confirmationResponses: c.review === "clear-after-caution"
        ? [fakeGatewayPermissionDecision("clear", "confirm_review")]
        : [],
    },
  );
  const env = providerVersionTestEnv({
    ...envWithoutFxHome({ ...process.env }),
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-ask-refusal-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: c.mode ?? "auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_SOUND: "0",
    NO_COLOR: "1",
  });
  const yolo = c.yolo ? ["--yolo"] : [];
  const args = mode === "json"
    ? ["ask", ...yolo, "--no-save", "--json", "Do the task."]
    : ["ask", ...yolo, "--no-save", "--no-color", "Do the task."];
  const proc = Bun.spawn([fxBin(), ...args], { cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const stdout = new Response(proc.stdout).text();
  const stderr = new LiveOutput(proc.stderr);
  const readings: Reading[] = [];
  let reviewCount = 0;
  try {
    if (c.preStart) {
      await within(modelRequest, "the model request");
      proc.kill("SIGINT");
    }
    if (held) {
      await within(held.arrived, "the review request");
      try {
        await within(stderr.waitFor(`Reviewing ${c.tool}`, LINE_DEADLINE_MS), "the Reviewing line");
      } catch (error) {
        anomalies.push(`${c.name}: ${(error as Error).message}`);
      }
      readings.push({ gate: "pending", text: stderr.text, json: null, cancelled: false, reviews: 0 });
      if (c.cancelAt === "pending") {
        proc.kill("SIGINT");
      } else {
        held.answer(answerFor(c)(gateway.classifierRequests[0]!.body));
      }
    }
    if (c.cancelAt === "running") {
      try {
        await within(stderr.waitFor(c.start, LINE_DEADLINE_MS), "the start line");
      } catch (error) {
        anomalies.push(`${c.name}: ${(error as Error).message}`);
      }
      readings.push({ gate: "running", text: stderr.text, json: null, cancelled: false, reviews: 0 });
      proc.kill("SIGINT");
    }
    await proc.exited;
    await stderr.done;
    reviewCount = gateway.classifierRequests.length;
    const out = await stdout;
    {
      readings.push({
        gate: "final",
        text: stderr.text,
        json: mode === "json" ? JSON.parse(out) : null,
        cancelled: c.cancelAt !== undefined || c.preStart === true,
        reviews: 0,
      });
    }
  } finally {
    if (held) held.answer(fakeGatewayPermissionDecision("clear"));
    if (proc.exitCode === null) proc.kill("SIGKILL");
    gateway.stop();
  }
  return readings.map((reading) => ({ ...reading, reviews: reviewCount }));
}

// ---- readings -> views ----------------------------------------------------

function tokenFor(c: Case, text: string): string {
  const token = REASON_OF_KIND[c.kind];
  if (!token) return `UNKNOWN(${text})`;
  if (REASON_TEXT[token] === text) return token;
  return `UNKNOWN(${text})`;
}

// The text of a refusal line: a Refused line for the case's tool, or for a
// missing terminal the blocker notice's headline, which names the reason.
function refusalTextOf(c: Case, line: string): string | null {
  if (line.startsWith(`Refused ${c.tool}: `)) return line.slice(`Refused ${c.tool}: `.length);
  if (c.kind === "noterm" && line.startsWith("fx ask: ")) {
    const text = line.slice("fx ask: ".length);
    return text === REASON_TEXT.R_NO_TERMINAL ? text : null;
  }
  return null;
}

function viewOfReading(c: Case, reading: Reading): View {
  const lines = reading.text.split("\n");
  const reviewing = lines.filter((line) => line.startsWith(`Reviewing ${c.tool}`)).length;
  const running = lines.filter((line) => line.startsWith(c.start)).length;
  const refusals = lines.map((line) => refusalTextOf(c, line)).filter((text): text is string => text !== null);
  const shown = refusals.length === 0 ? "" : tokenFor(c, refusals[0]!);
  const reviewed = reviewing > 0;
  if (reading.gate !== "final") {
    return { kind: c.kind, reviewed, reviewing, running, refused: refusals.length, shown, rec: "", outcome: "none" };
  }
  const entry = (reading.json?.tool_calls ?? []).find((call: { name: string }) => call.name === c.tool);
  const rec = entry?.reason === undefined ? "" : tokenFor(c, entry.reason);
  const outcome = reading.cancelled ? "cancelled" : refusals.length > 0 ? "refused" : running > 0 ? "ran" : "none";
  return { kind: c.kind, reviewed, reviewing, running, refused: refusals.length, shown, rec, outcome };
}

// ---- the walk -------------------------------------------------------------

test(
  "fx ask walks the design-a model: each state it reaches is one the model has, and each unreached state has a reason",
  async () => {
    expect(existsSync(fxBin())).toBe(true);
    const model = await loadModel();
    const reached = new Set<string>();
    const problems: string[] = [];
    const seen: string[] = [];

    const check = (label: string, view: View) => {
      seen.push(`${label}: ${keyOf(view)}`);
      if (!model.views.has(keyOf(view))) {
        problems.push(`${label}: fx shows a state the model does not have: ${keyOf(view)}`);
        return;
      }
      reached.add(keyOf(view));
    };
    // A text run's final output shows the call's lines but no record, so it
    // must match a model view on those lines alone; the JSON run reaches the state.
    const checkLines = (label: string, view: View) => {
      seen.push(`${label}: ${keyOf(view)}`);
      const lines = `${view.kind}|${view.reviewed}|${view.reviewing}|${view.running}|${view.refused}|${view.shown}`;
      if (!model.linesOf.has(lines)) problems.push(`${label}: fx shows lines the model does not have: ${lines}`);
    };

    for (const c of CASES) {
      const readings = await runCase(c, "text");
      const jsonReadings = c.cancelAt || c.preStart ? [] : await runCase(c, "json");
      for (const reading of [...readings, ...jsonReadings]) {
        if (c.kind === "noterm") {
          // The blocker notice names the blocked call; no Running line shows for it.
          const lines = reading.text.split("\n");
          if (!lines.includes(`fx ask: blocked action: ${c.tool}: ${c.command}`)) {
            problems.push(`${c.name}: the blocker notice does not name the call on its own line`);
          }
          if (lines.some((line) => line.startsWith(c.start))) problems.push(`${c.name}: a Running line printed for the blocked call`);
          const entry = (reading.json?.tool_calls ?? []).find((call: { name: string }) => call.name === c.tool);
          if (reading.json && !(entry && Object.keys(entry).length === 5 && entry.status === "error" && entry.action === "run"
            && entry.error?.category === "rejected" && entry.error?.code === "rejected"
            && entry.reason === REASON_TEXT.R_NO_TERMINAL)) {
            problems.push(`${c.name}: the blocked call's JSON entry is not the rejected entry with the blocker reason: ${JSON.stringify(entry)}`);
          }
        }
        if (c.preStart && reading.gate === "final") {
          for (const [kind, reviewed] of PRE_START) {
            check(`${c.name} [final, before any line]`, {
              kind,
              reviewed,
              reviewing: 0,
              running: 0,
              refused: 0,
              shown: "",
              rec: "",
              outcome: "cancelled",
            });
          }
          continue;
        }
        const label = `${c.name} [${reading.gate}${reading.json ? ", json" : ""}, reviews=${reading.reviews}]`;
        const view = viewOfReading(c, reading);
        if (reading.gate === "final" && reading.json === null && !reading.cancelled && view.refused > 0) {
          checkLines(label, view);
          continue;
        }
        if (reading.gate === "final" && view.outcome === "none") {
          seen.push(`${label}: ${keyOf(view)} stderr=${JSON.stringify(reading.text)}`);
          problems.push(`${label}: the run ended with no closed call (no ran, refused, or cancelled line): ${JSON.stringify(reading.text)}`);
          continue;
        }
        check(label, view);
      }
    }

    problems.push(...anomalies);
    const listed: string[] = [];
    const unlisted: string[] = [];
    for (const [key, view] of model.views) {
      if (reached.has(key)) continue;
      const entry = UNREACHED.find((item) => item.match(view));
      if (entry) {
        listed.push(`${key}  (${entry.reason})`);
      } else {
        unlisted.push(`${key}  (into by ${[...(model.actionsInto.get(key) ?? [])].slice(0, 4).join(", ")})`);
      }
    }
    console.log(`model states: ${model.stateCount}, per-call views: ${model.views.size}, reached: ${reached.size}, listed: ${listed.length}`);
    for (const line of seen) console.log(`seen: ${line}`);
    for (const line of listed) console.log(`unreached, listed: ${line}`);
    for (const line of unlisted) problems.push(`unreached and not listed: ${line}`);
    for (const line of problems) console.log(`PROBLEM: ${line}`);
    expect(problems).toEqual([]);
  },
  TIMEOUT_MS,
);
