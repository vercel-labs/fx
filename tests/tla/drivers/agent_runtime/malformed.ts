// Runs the built fx binary along tests/tla/agent_runtime/MalformedToolCall.tla
// and has TLC check every turn it observes (MalformedToolCallTrace.tla).
//
// Each turn is one `fx ask` against a local fake gateway that serves a script
// of replies: a valid read_file call, a final answer, a read_file call that
// ends with Gemini's MALFORMED_FUNCTION_CALL, the same finish with no call, a
// provider search start that ends with a provider error, and a provider error
// with nothing else. The driver runs every script up to --depth replies under
// every step limit in Limits, then --random seeded longer scripts. When fx
// asks for more replies than the script holds, the gateway serves a final
// answer, and that answer is part of what was observed.
//
// For each turn it records the replies served; what each request fx sent
// carried (the prompt, tool results, the first or second malformed-call
// feedback, the regenerate, search, or reconcile prompt, or the same request
// again); whether it went with tools on; whether fx waited the backoff before
// it; and how the turn ended. TLC replays the turns through the model's own
// actions. --self-check also replays them through the model of fx before the
// change (Bug = "today"), which must reject them. --stress N adds one long turn
// with N separate stalls, each a malformed reply followed by a valid tool step,
// with no step limit, and prints its wall time and the binary's peak memory.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/malformed.ts
//   bun tests/tla/drivers/agent_runtime/malformed.ts --self-check
//   bun tests/tla/drivers/agent_runtime/malformed.ts --depth 2 --random 100 --seed 7 --jobs 8
//   bun tests/tla/drivers/agent_runtime/malformed.ts --depth 0 --random 0 --stress 200
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Kind = "tool" | "text" | "malformed" | "malformed_bare" | "search_failed" | "transient";
type Carry =
  | "prompt"
  | "tools"
  | "feedback1"
  | "feedback2"
  | "resend"
  | "regenerate"
  | "search"
  | "reconcile"
  | "unknown";
type Outcome = "answered" | "failed_malformed" | "review" | "step_limit" | "unknown";
type Observation = {
  id: string;
  limit: number;
  replies: Kind[];
  sent: Carry[];
  tools: boolean[];
  waited: boolean[];
  outcome: Outcome;
  evidence: {
    exit: number;
    final_output: string;
    gaps_ms: number[];
    tail: string;
    seconds: number;
    max_rss_bytes: number | null;
  };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const KINDS: Kind[] = ["tool", "text", "malformed", "malformed_bare", "search_failed", "transient"];
// Every kind the model knows, including one no real tool can produce here.
const MODEL_KINDS = [...KINDS, "unsafe_failed"];
const LIMITS = [0, 1, 2];
const MODEL = "google/gemini-4-carbon";
// What fx sends back (src/core/agent/runtime/orchestrator.zig and
// src/core/agent/runtime/resend_strategy.zig).
const FEEDBACK = "could not be read";
const FEEDBACK_AGAIN = "could not be read again";
const SEARCH = "search again if you still need one";
const RECONCILE = "Reconcile the available tool evidence";
const REGENERATE = "fx did not execute that call";
const FAILED = "could not be read 3 times in a row";
// The shortest backoff is 1 s (src/core/recovery/recovery.zig backoff_ms); a
// request that comes sooner after the one before did not wait.
const WAIT_MS = 700;
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
  depth: option("--depth", 3),
  random: option("--random", 30),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
  stress: option("--stress", 0),
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
  if (options.stress > 0) {
    const script: Kind[] = [];
    for (let i = 0; i < options.stress; i++) script.push("malformed", "tool");
    cases.push({ limit: 0, script: [...script, "text"] });
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

const isFeedback = (message: Message) =>
  message.role === "user" && text(message).includes(FEEDBACK) && text(message).includes("MALFORMED_FUNCTION_CALL");

// What request `index` carried, from what it added to the request before it:
// tool results and feedback stay in the turn, while the regenerate, search,
// and reconcile prompts end only the request they go with.
function carry(bodies: string[], index: number): Carry {
  if (index === 0) return "prompt";
  const current = messages(bodies[index]!);
  const previous = messages(bodies[index - 1]!);
  const count = (list: Message[], test: (message: Message) => boolean) => list.filter(test).length;
  if (count(current, (m) => m.role === "tool") > count(previous, (m) => m.role === "tool")) return "tools";
  if (count(current, isFeedback) > count(previous, isFeedback)) {
    const newest = current.filter(isFeedback).at(-1)!;
    return text(newest).includes(FEEDBACK_AGAIN) ? "feedback2" : "feedback1";
  }
  const last = current.at(-1)!;
  if (last.role === "user") {
    if (text(last).includes(SEARCH)) return "search";
    if (text(last).includes(RECONCILE)) return "reconcile";
    if (text(last).includes(REGENERATE)) return "regenerate";
  }
  if (current.length >= previous.length) return "resend";
  return "unknown";
}

async function runTurn(
  helpers: any,
  id: string,
  limit: number,
  script: Kind[],
  scratch: string,
): Promise<Observation> {
  const { fakeGatewaySse } = helpers;
  const served: Kind[] = [];
  const arrivals: number[] = [];
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
      case "malformed":
        return fakeGatewaySse([
          { type: "tool-input-start", id: `bad_${n}`, toolName: "read_file" },
          { type: "tool-call", toolCallId: `bad_${n}`, toolName: "read_file", input: { path: "notes.txt" } },
          { type: "finish", finishReason: { unified: "error", raw: "MALFORMED_FUNCTION_CALL" } },
        ]);
      case "malformed_bare":
        return fakeGatewaySse([
          { type: "finish", finishReason: { unified: "error", raw: "MALFORMED_FUNCTION_CALL" } },
        ]);
      case "search_failed":
        return fakeGatewaySse([
          { type: "tool-input-start", id: `search_${n}`, toolName: "exa_search" },
          { type: "finish", finishReason: { unified: "error", raw: "provider_error" } },
        ]);
      case "transient":
        return fakeGatewaySse([
          { type: "finish", finishReason: { unified: "error", raw: "provider_error" } },
        ]);
    }
  };
  const gateway = helpers.startDynamicFakeGateway(() => {
    arrivals.push(performance.now());
    const kind: Kind = script[served.length] ?? "text";
    served.push(kind);
    return reply(kind, served.length);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", "Read notes.txt and report."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-malformed-driver-key",
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
    const timer = setTimeout(() => child.kill(9), script.length > 100 ? 600_000 : 90_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    const maxRss = child.resourceUsage()?.maxRSS ?? null;
    let finalOutput = "";
    try {
      finalOutput = String(JSON.parse(stdout.trim()).final_output ?? "");
    } catch {
      finalOutput = "";
    }
    const combined = `${stdout}\n${stderr}`;
    const bodies: string[] = gateway.requests.map((request: { body: string }) => request.body);
    const sent = bodies.map((_, index) => carry(bodies, index));
    const tools = bodies.map((body) => !body.includes('"toolChoice":{"type":"none"}'));
    const gaps = arrivals.map((at, index) => (index === 0 ? 0 : Math.round(at - arrivals[index - 1]!)));
    const waited = gaps.map((gap, index) => index > 0 && gap >= WAIT_MS);
    let outcome: Outcome = "unknown";
    if (combined.includes("Agent step limit reached")) outcome = "step_limit";
    else if (exit !== 0 && combined.includes(FAILED)) outcome = "failed_malformed";
    else if (combined.includes("Tool state needs review")) outcome = "review";
    else if (exit === 0 && finalOutput.includes(`ANSWER_${id}`)) outcome = "answered";
    return {
      id,
      limit,
      replies: served,
      sent,
      tools,
      waited,
      outcome,
      evidence: { exit, final_output: finalOutput, gaps_ms: gaps, tail: combined.slice(-400), seconds, max_rss_bytes: maxRss },
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
    `tools |-> ${seq(o.tools)}, waited |-> ${seq(o.waited)}, outcome |-> ${str(o.outcome)}]`;
  return [
    "--------------------- MODULE MalformedToolCallObserved ---------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/malformed.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["MalformedToolCall.tla", "MalformedToolCallTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "MalformedToolCallObserved.tla"), observedModule(observations));
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
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "MalformedToolCallTrace.tla"], {
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

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("agent_runtime_malformed");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const cases = scripts();
  const observations: Observation[] = new Array(cases.length);
  const started = performance.now();
  let next = 0;
  // A turn that fails before the gateway serves any reply, such as a local
  // connection dropped under load, says nothing about the step loop. It runs
  // again, at most twice, and is reported; one that never reaches the gateway
  // is a harness failure, not an observation.
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
  console.log(`observations: ${join(out, "observations.json")}`);
  if (options.stress > 0) {
    const stress = observations.at(-1)!;
    const feedback = stress.sent.filter((carry) => carry === "feedback1" || carry === "feedback2").length;
    console.log(`stress: ${options.stress} stalls, ${stress.sent.length} requests, ${feedback} feedback messages, ` +
      `outcome ${stress.outcome}, ${stress.evidence.seconds}s, peak RSS ${stress.evidence.max_rss_bytes} bytes`);
  }

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
