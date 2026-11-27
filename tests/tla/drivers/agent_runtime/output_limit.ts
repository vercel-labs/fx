// Runs the built fx binary along tests/tla/agent_runtime/OutputLimit.tla and
// has TLC check every turn it observes (OutputLimitTrace.tla).
//
// Each turn is one `fx ask` against a local fake gateway that serves a script
// of replies: a valid read_file call, a final answer, a reply cut off at the
// output limit after a complete read_file call with an edit_file call left
// unfinished, a reply cut off while its only call, an edit_file, was
// unfinished, a reply cut off right after its only call, a whole read_file,
// that fx must not run, a reply cut off while it wrote text, which fx keeps
// for the model to go on from, and a reply cut off while it only reasoned.
// The catalog gives the model an output limit as large as its
// context window, so fx asks for its own bound of 32768 tokens and may raise
// it to 65536. The driver runs every script up to --depth replies under every
// step limit in Limits, then --random seeded longer scripts. When fx asks for
// more replies than the script holds, the gateway serves a final answer, and
// that answer is part of what was observed.
//
// For each turn it records the replies served; what each request fx sent
// carried (the prompt, tool results, the complete calls' results with the
// note, the cut text with the note to go on from it, or the note alone, each
// after a cut or again after one); whether it asked for the raised limit; how
// many replies' text the final answer joined; and how the turn ended. TLC replays the turns
// through the model's own actions. --self-check also replays them through the
// model of fx before the change (Bug = "today"), which must reject them.
// --no-check only records and summarizes the turns, for a run of another
// binary that the model does not describe, such as a before-and-after run.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/output_limit.ts
//   bun tests/tla/drivers/agent_runtime/output_limit.ts --self-check
//   bun tests/tla/drivers/agent_runtime/output_limit.ts --depth 2 --random 100 --seed 7 --jobs 8
//   FX_BIN=/path/to/old/fx bun tests/tla/drivers/agent_runtime/output_limit.ts --no-check
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Kind = "tool" | "text" | "cut_complete" | "cut_only" | "cut_closed" | "cut_text" | "cut_empty";
type Carry = "prompt" | "tools" | "ran_note" | "ran_note_again" | "note" | "note_again" | "text_note" | "text_note_again" | "unknown";
type Outcome = "answered" | "failed_cut" | "step_limit" | "unknown";
type Observation = {
  id: string;
  limit: number;
  replies: Kind[];
  sent: Carry[];
  big: boolean[];
  answer: number;
  outcome: Outcome;
  evidence: {
    exit: number;
    final_output: string;
    max_output_tokens: Array<number | null>;
    tail: string;
    seconds: number;
  };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const KINDS: Kind[] = ["tool", "text", "cut_complete", "cut_only", "cut_closed", "cut_text", "cut_empty"];
// Every kind the model knows, including one the gateway cannot produce: its
// client gives a call with no id an id of fx's own.
const MODEL_KINDS = [...KINDS, "cut_bad_id"];
const LIMITS = [0, 1, 2];
const MODEL = "google/gemini-4-carbon";
// fx's bound on a catalog limit that fills the context window, and the limit
// a cut reply raises it to (src/core/config/model_capabilities.zig).
const BOUND = 32768;
const RAISED = 65536;
// What fx sends back and shows (src/core/agent/runtime/orchestrator.zig).
const NOTE = "Your last reply reached";
const RAN = "fx ran its";
const AGAIN = " again";
const CONTINUE = "Continue exactly where it stopped";
// fx before the change said "so I did not run them"; both end the turn, as
// does the end of a turn whose replies were cut before any tool call.
const FAILED = "did not run them";
const STOPPED = "so fx stopped the turn";
const tlaDir = join(TLA_ROOT, "agent_runtime");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  noCheck: process.argv.includes("--no-check"),
  depth: option("--depth", 3),
  random: option("--random", 30),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
};

// mulberry32: a small seeded generator, so a failing random script replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function scripts(): Array<{ limit: number; script: Kind[] }> {
  const cases: Array<{ limit: number; script: Kind[] }> = [];
  const grow = (prefix: Kind[]) => {
    if (prefix.length > 0) for (const limit of LIMITS) cases.push({ limit, script: prefix });
    if (prefix.length === options.depth) return;
    for (const kind of KINDS) grow([...prefix, kind]);
  };
  grow([]);
  const next = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    const length = 4 + Math.floor(next() * 4);
    const script = Array.from({ length }, () => KINDS[Math.floor(next() * KINDS.length)]!);
    cases.push({ limit: LIMITS[Math.floor(next() * LIMITS.length)]!, script });
  }
  return cases;
}

type Message = { role: string; content: unknown };

function messages(body: string): Message[] {
  return JSON.parse(body).prompt as Message[];
}

function text(message: Message): string {
  return typeof message.content === "string" ? message.content : JSON.stringify(message.content);
}

const isNote = (message: Message) => message.role === "user" && text(message).includes(NOTE);

function maxOutputTokens(body: string): number | null {
  const value = JSON.parse(body).maxOutputTokens;
  return typeof value === "number" ? value : null;
}

// What request `index` carried, from what it added to the request before it.
function carry(bodies: string[], index: number): Carry {
  if (index === 0) return "prompt";
  const current = messages(bodies[index]!);
  const previous = messages(bodies[index - 1]!);
  const count = (list: Message[], test: (message: Message) => boolean) => list.filter(test).length;
  if (count(current, isNote) > count(previous, isNote)) {
    const note = current.filter(isNote).at(-1)!;
    const newest = text(note);
    const again = newest.includes(AGAIN);
    if (newest.includes(RAN)) return again ? "ran_note_again" : "ran_note";
    if (newest.includes(CONTINUE)) {
      // The cut text goes back to the model right before the note.
      const before = current[current.lastIndexOf(note) - 1];
      if (before?.role !== "assistant" || !text(before).includes("PART_")) return "unknown";
      return again ? "text_note_again" : "text_note";
    }
    return again ? "note_again" : "note";
  }
  if (count(current, (m) => m.role === "tool") > count(previous, (m) => m.role === "tool")) return "tools";
  return "unknown";
}

async function runTurn(helpers: any, id: string, limit: number, script: Kind[], scratch: string): Promise<Observation> {
  const { fakeGatewaySse } = helpers;
  const served: Kind[] = [];
  const cutFinish = { type: "finish", finishReason: { unified: "length", raw: "MAX_TOKENS" } };
  const reply = (kind: Kind, n: number): Response => {
    switch (kind) {
      case "tool":
        return fakeGatewaySse([
          { type: "tool-call", toolCallId: `read_${n}`, toolName: "read_file", input: { path: "notes.txt" } },
          { type: "finish", finishReason: { unified: "tool-calls", raw: "STOP" } },
        ]);
      case "text":
        return fakeGatewaySse([
          { type: "text-delta", id: `t${n}`, delta: `ANSWER_${id}` },
          { type: "finish", finishReason: { unified: "stop", raw: "STOP" } },
        ]);
      // The AI SDK streams each call's start before the finished call.
      case "cut_complete":
        return fakeGatewaySse([
          { type: "tool-input-start", id: `read_${n}`, toolName: "read_file" },
          { type: "tool-call", toolCallId: `read_${n}`, toolName: "read_file", input: { path: "notes.txt" } },
          { type: "tool-input-start", id: `cut_${n}`, toolName: "edit_file" },
          { type: "tool-input-delta", id: `cut_${n}`, delta: '{"path":"notes.txt","old_string":"fix' },
          cutFinish,
        ]);
      case "cut_only":
        return fakeGatewaySse([
          { type: "tool-input-start", id: `cut_${n}`, toolName: "edit_file" },
          { type: "tool-input-delta", id: `cut_${n}`, delta: '{"path":"notes.txt","old_string":"fix' },
          cutFinish,
        ]);
      case "cut_closed":
        return fakeGatewaySse([
          { type: "tool-input-start", id: `closed_${n}`, toolName: "read_file" },
          { type: "tool-call", toolCallId: `closed_${n}`, toolName: "read_file", input: { path: "notes.txt" } },
          cutFinish,
        ]);
      case "cut_text":
        return fakeGatewaySse([
          { type: "text-delta", id: `t${n}`, delta: `PART_${id}_${n} ` },
          cutFinish,
        ]);
      case "cut_empty":
        return fakeGatewaySse([
          { type: "reasoning-start", id: `r${n}` },
          { type: "reasoning-delta", id: `r${n}`, delta: "thinking until the limit runs out" },
          { type: "reasoning-end", id: `r${n}` },
          cutFinish,
        ]);
    }
  };
  const gateway = helpers.startDynamicFakeGateway(() => {
    const kind: Kind = script[served.length] ?? "text";
    served.push(kind);
    return reply(kind, served.length);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"], context_window: 1_000_000, max_tokens: 1_000_000 }] });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", "Edit notes.txt and report."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-output-limit-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
        FX_MAX_AGENT_STEPS: String(limit),
        FX_SOUND: "0",
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 90_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    let finalOutput = "";
    try {
      finalOutput = String(JSON.parse(stdout.trim()).final_output ?? "");
    } catch {
      finalOutput = "";
    }
    const combined = `${stdout}\n${stderr}`;
    const bodies: string[] = gateway.requests.map((request: { body: string }) => request.body);
    const limits = bodies.map(maxOutputTokens);
    const sent = bodies.map((_, index) => {
      // A request that asks for neither limit is one the model does not know.
      if (limits[index] !== BOUND && limits[index] !== RAISED) return "unknown" as const;
      return carry(bodies, index);
    });
    let outcome: Outcome = "unknown";
    if (combined.includes("Agent step limit reached")) outcome = "step_limit";
    else if (exit !== 0 && (combined.includes(FAILED) || combined.includes(STOPPED) || combined.includes("ran out of output tokens"))) outcome = "failed_cut";
    else if (exit === 0 && finalOutput.includes(`ANSWER_${id}`)) outcome = "answered";
    // The replies whose text the final answer joined: each cut reply's part,
    // then the answer.
    const answer = outcome === "answered" ? finalOutput.split(`PART_${id}_`).length : 0;
    return {
      id,
      limit,
      replies: served,
      sent,
      big: limits.map((value) => value === RAISED),
      answer,
      outcome,
      evidence: { exit, final_output: finalOutput, max_output_tokens: limits, tail: combined.slice(-400), seconds },
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: Array<string | boolean>) =>
  `<<${values.map((value) => (typeof value === "boolean" ? (value ? "TRUE" : "FALSE") : str(value))).join(", ")}>>`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[limit |-> ${o.limit}, replies |-> ${seq(o.replies)}, sent |-> ${seq(o.sent)}, ` +
    `big |-> ${seq(o.big)}, answer |-> ${o.answer}, outcome |-> ${str(o.outcome)}]`;
  return [
    "----------------------- MODULE OutputLimitObserved -----------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/output_limit.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["OutputLimit.tla", "OutputLimitTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "OutputLimitObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Limits = {${LIMITS.join(", ")}}`,
    "  MaxRequests = 1000",
    `  ReplyKinds = {${MODEL_KINDS.map(str).join(", ")}}`,
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "OutputLimitTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], bug: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

// What the turns show without a model: how the turns with a cut reply ended.
function summary(observations: Observation[]) {
  const cut = observations.filter((o) => o.replies.some((kind) => kind.startsWith("cut_")));
  const counts: Record<string, number> = {};
  for (const o of cut) counts[o.outcome] = (counts[o.outcome] ?? 0) + 1;
  const ranAfterCut = cut.filter((o) => o.sent.some((carry) => carry === "ran_note" || carry === "ran_note_again")).length;
  const joined = observations.filter((o) => o.answer > 1).length;
  return { turns: observations.length, turns_with_cut: cut.length, cut_outcomes: counts, turns_that_ran_complete_calls: ranAfterCut, turns_that_joined_an_answer: joined };
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("agent_runtime_output_limit");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const cases = scripts();
  const observations: Observation[] = new Array(cases.length);
  const started = performance.now();
  let next = 0;
  // A turn that fails before the gateway serves any reply says nothing about
  // the step loop. It runs again, at most twice, and is reported.
  const harnessRetries: string[] = [];
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < cases.length) {
      const index = next++;
      const { limit, script } = cases[index]!;
      let observation = await runTurn(helpers, `turn${index}`, limit, script, scratch);
      for (let attempt = 1; attempt < 3 && observation.replies.length === 0; attempt++) {
        harnessRetries.push(`turn${index}: ${observation.evidence.tail.replace(/\s+/g, " ").slice(-200)}`);
        observation = await runTurn(helpers, `turn${index}`, limit, script, scratch);
      }
      observations[index] = observation;
    }
  });
  await Promise.all(workers);
  for (const retry of harnessRetries) console.log(`harness retry (no reply served): ${retry}`);
  const unreached = observations.find((o) => o.replies.length === 0);
  if (unreached) {
    console.log(`TOOL_ERROR: turn ${unreached.id} never reached the gateway: ${JSON.stringify(unreached.evidence)}`);
    return 2;
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) counts[o.outcome] = (counts[o.outcome] ?? 0) + 1;
  console.log(`${observations.length} turns of ${binary} in ${seconds}s, outcomes ${JSON.stringify(counts)}`);
  console.log(`summary: ${JSON.stringify(summary(observations))}`);
  console.log(`observations: ${join(out, "observations.json")}`);
  if (options.noCheck) return 0;

  const unknown = observations.find((o) => o.outcome === "unknown" || o.sent.includes("unknown"));
  if (unknown) {
    console.log(`REJECTED: turn ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  const design = await runTrace(observations, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "none", out);
    console.log(`first turn the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
