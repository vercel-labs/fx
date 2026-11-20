// Runs the built fx binary along tests/tla/agent_runtime/EmptyReply.tla and has
// TLC check every turn it observes (EmptyReplyTrace.tla).
//
// Each turn is one `fx ask` against a local fake gateway that serves a script
// of replies: tool calls with or without text, a final answer, text that stops
// for `other`, and a reply that stops for `other` with no text and no tool
// call, as Gemini's UNEXPECTED_TOOL_CALL does. The driver runs every script up
// to --depth replies under every step limit in Limits, then --random seeded
// longer scripts. When fx asks for more replies than the script holds, the
// gateway serves a final answer, and that answer is part of what was observed.
//
// For each turn it records the replies served, what each request fx sent
// carried (the prompt, tool results, the empty-reply nudge, or the older
// "Summarize what you just did." continuation), and how the turn ended. TLC
// replays the turns through the model's own actions. --self-check also replays
// them through the model of fx before the change (Bug = "today"), which must
// reject them. --stress N adds one long turn with N separate stalls, each a
// tool step followed by an empty reply, with no step limit, and prints its wall
// time and the binary's peak memory.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/driver.ts
//   bun tests/tla/drivers/agent_runtime/driver.ts --self-check
//   bun tests/tla/drivers/agent_runtime/driver.ts --depth 2 --random 100 --seed 7 --jobs 8
//   bun tests/tla/drivers/agent_runtime/driver.ts --depth 0 --random 0 --stress 400
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Kind = "tool" | "tool_silent" | "text" | "text_other" | "empty_other";
type Carry = "prompt" | "tools" | "nudge" | "summarize" | "unknown";
type Outcome = "answered" | "failed_empty" | "step_limit" | "placeholder" | "unknown";
type Observation = {
  id: string;
  limit: number;
  replies: Kind[];
  sent: Carry[];
  outcome: Outcome;
  evidence: { exit: number; final_output: string; tail: string; seconds: number; max_rss_bytes: number | null };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const KINDS: Kind[] = ["tool", "tool_silent", "text", "text_other", "empty_other"];
const LIMITS = [0, 1, 2, 3];
const MODEL = "google/gemini-4-argon";
// The nudge fx sends after an empty reply (src/core/agent/runtime/orchestrator.zig).
const NUDGE = "Your last reply had no text and no tool call.";
const SUMMARIZE = "Summarize what you just did.";
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
  random: option("--random", 40),
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
    for (let i = 0; i < options.stress; i++) script.push("tool", "empty_other");
    cases.push({ limit: 0, script: [...script, "text"] });
  }
  return cases;
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
  const reply = (kind: Kind, n: number): Response => {
    const finalText = { type: "finish", finishReason: { unified: "stop", raw: "STOP" } };
    switch (kind) {
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
      case "text":
        return fakeGatewaySse([{ type: "text-delta", id: `t${n}`, delta: `ANSWER_${id}` }, finalText]);
      case "text_other":
        return fakeGatewaySse([
          { type: "text-delta", id: `t${n}`, delta: `OTHER_ANSWER_${id}` },
          { type: "finish", finishReason: { unified: "other", raw: "OTHER" } },
        ]);
      case "empty_other":
        return fakeGatewaySse([
          { type: "finish", finishReason: { unified: "other", raw: "UNEXPECTED_TOOL_CALL" } },
        ]);
    }
  };
  const gateway = helpers.startDynamicFakeGateway(() => {
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
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", "Move the project and rename it."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-empty-reply-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
        FX_MAX_AGENT_STEPS: String(limit),
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), script.length > 100 ? 600_000 : 60_000);
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
    const sent: Carry[] = gateway.requests.map((request: { body: string }, index: number) => {
      if (index === 0) return "prompt";
      const prompt = JSON.parse(request.body).prompt as Array<{ role: string; content: unknown }>;
      const last = prompt.at(-1)!;
      const text = JSON.stringify(last.content);
      if (last.role === "tool") return "tools";
      if (last.role === "user" && text.includes(NUDGE)) return "nudge";
      if (last.role === "user" && text.includes(SUMMARIZE)) return "summarize";
      return "unknown";
    });
    let outcome: Outcome = "unknown";
    if (combined.includes("Agent step limit reached")) outcome = "step_limit";
    else if (exit === 1 && combined.includes("The model stopped without a reply (")) outcome = "failed_empty";
    else if (finalOutput === "Done.") outcome = "placeholder";
    else if (exit === 0 && finalOutput.includes(`ANSWER_${id}`)) outcome = "answered";
    return {
      id,
      limit,
      replies: served,
      sent,
      outcome,
      evidence: { exit, final_output: finalOutput, tail: combined.slice(-400), seconds, max_rss_bytes: maxRss },
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.map(str).join(", ")}>>`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[limit |-> ${o.limit}, replies |-> ${seq(o.replies)}, sent |-> ${seq(o.sent)}, outcome |-> ${str(o.outcome)}]`;
  return [
    "------------------------- MODULE EmptyReplyObserved -------------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["EmptyReply.tla", "EmptyReplyTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "EmptyReplyObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Limits = {${LIMITS.join(", ")}}`,
    "  MaxRequests = 1000",
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "EmptyReplyTrace.tla"], {
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
  const out = outDir("agent_runtime");
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
    const nudges = stress.sent.filter((carry) => carry === "nudge").length;
    console.log(`stress: ${options.stress} stalls, ${stress.sent.length} requests, ${nudges} nudges, ` +
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
