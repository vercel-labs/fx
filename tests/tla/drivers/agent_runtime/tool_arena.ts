// Runs the built fx binary along tests/tla/agent_runtime/ToolArena.tla and has
// TLC check every turn it observes (ToolArenaTrace.tla).
//
// Each turn is one `fx ask --json --yolo` against a local fake gateway that
// serves a script of steps: read_file of a file the gateway rewrites before
// every reply, grep_files, glob_files, read_file of a missing path, a tool fx
// does not have, a shell command, write_file, and batches of read_file calls
// that fx runs in parallel. Every turn runs twice, once with the files it
// reads at --large bytes and once at 1 KiB. The difference in fx's peak RSS
// says what the turn kept of its large reads: "scratch" when it grew by at
// least half of the bytes the turn's large reads read, or "results" when it
// did not. One read's own scratch, or one parallel batch's, is far below that
// bar, so a turn that frees each call's scratch reads as "results".
//
// TLC replays the turns through the model's own actions. --self-check also
// replays them through the model of fx before the change (Bug = "today"),
// which must reject them. --stress N adds one turn of N large reads and
// prints its peak memory at both sizes.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/tool_arena.ts
//   bun tests/tla/drivers/agent_runtime/tool_arena.ts --self-check
//   bun tests/tla/drivers/agent_runtime/tool_arena.ts --reads 32 --large 2097152 --stress 300
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Step = "read" | "grep" | "glob" | "missing" | "unknown" | "shell" | "write" | "batch";
type Kind = "dispatched" | "backend" | "mutation" | "parallel" | "prelude";
type Outcome = "success" | "failure";
type ObservedCall = { kind: Kind; outcome: Outcome; large: boolean };
type Run = {
  exit: number;
  final_output: string;
  requests: number;
  max_rss_bytes: number;
  statuses: string[];
  tail: string;
};
type Observation = {
  id: string;
  steps: Step[];
  calls: ObservedCall[];
  kept: "scratch" | "results";
  evidence: { large: Run; small: Run; large_reads: number; bar_bytes: number; grew_bytes: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "openai/gpt-5.5";
const SMALL = 1024;
const DONE = "TOOL_ARENA_DONE";
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
  reads: option("--reads", 24),
  large: option("--large", 1024 * 1024),
  width: option("--width", 4),
  jobs: option("--jobs", 4),
  stress: option("--stress", 0),
};
if (options.reads < 24) throw new Error("--reads must be at least 24, so one call's scratch stays below the bar");

const LARGE_STEPS: Step[] = ["read", "batch"];

function scripts(): Array<{ id: string; steps: Step[] }> {
  const reads = Array<Step>(options.reads).fill("read");
  const mixed: Step[] = [];
  const others: Step[] = ["grep", "glob", "missing", "unknown", "shell", "write"];
  for (let i = 0; i < options.reads; i++) {
    mixed.push("read");
    if (i % 4 === 3) mixed.push(others[(i >> 2) % others.length]!);
  }
  const batches = Array<Step>(Math.max(2, options.reads / options.width)).fill("batch");
  const small: Step[] = [...others, ...others];
  const cases = [
    { id: "reads", steps: reads },
    { id: "mixed", steps: mixed },
    { id: "batches", steps: batches },
    { id: "no_large_reads", steps: small },
  ];
  if (options.stress > 0) cases.push({ id: `stress_${options.stress}`, steps: Array<Step>(options.stress).fill("read") });
  return cases;
}

function callsOf(step: Step): number {
  return step === "batch" ? options.width : 1;
}

function kindOf(step: Step): Kind {
  switch (step) {
    case "read":
    case "grep":
    case "glob":
    case "missing":
      return "dispatched";
    case "unknown":
      return "prelude";
    case "shell":
      return "backend";
    case "write":
      return "mutation";
    case "batch":
      return "parallel";
  }
}

function content(serial: number, bytes: number): string {
  // A different file every time, so no read can be answered from an earlier one.
  return `${serial} ${"x".repeat(bytes)}\n`;
}

async function runTurn(helpers: any, steps: Step[], bytes: number, scratch: string, label: string): Promise<Run> {
  const { fakeGatewaySse, startDynamicFakeGateway } = helpers;
  const root = mkdtempSync(join(scratch, `${label}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ session_titles: false }));
  writeFileSync(join(workspace, "notes.txt"), "needle\n");
  let served = 0;
  let serial = 0;
  const finish = { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } };
  const reply = (step: Step, n: number): Response => {
    const call = (name: string, input: object, suffix = "") =>
      ({ type: "tool-call", toolCallId: `call_${n}${suffix}`, toolName: name, input });
    switch (step) {
      case "read":
        writeFileSync(join(workspace, "big.txt"), content(++serial, bytes));
        return fakeGatewaySse([call("read_file", { path: "big.txt" }), finish]);
      case "batch": {
        const events: object[] = [];
        for (let j = 0; j < options.width; j++) {
          writeFileSync(join(workspace, `big_${j}.txt`), content(++serial, bytes));
          events.push(call("read_file", { path: `big_${j}.txt` }, `_${j}`));
        }
        return fakeGatewaySse([...events, finish]);
      }
      case "grep":
        return fakeGatewaySse([call("grep_files", { pattern: "needle" }), finish]);
      case "glob":
        return fakeGatewaySse([call("glob_files", { pattern: "*.txt" }), finish]);
      case "missing":
        return fakeGatewaySse([call("read_file", { path: "missing/nope.txt" }), finish]);
      case "unknown":
        return fakeGatewaySse([call("no_such_tool", {}), finish]);
      case "shell":
        return fakeGatewaySse([call("shell", { request: { action: "run", command: "printf ok" } }), finish]);
      case "write":
        return fakeGatewaySse([call("write_file", { path: `out_${n}.txt`, content: "x\n" }), finish]);
    }
  };
  const gateway = startDynamicFakeGateway(() => {
    const step = steps[served];
    served++;
    if (step) return reply(step, served);
    return fakeGatewaySse([
      { type: "text-delta", id: "answer", delta: DONE },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  try {
    const child = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-save", "Work through the files the fixture names."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        FX_HOME: join(home, ".fx"),
        AI_GATEWAY_API_KEY: "fake-tool-arena-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
        FX_MAX_AGENT_STEPS: "0",
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 600_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    let parsed: any = {};
    try {
      parsed = JSON.parse(stdout.trim());
    } catch {
      parsed = {};
    }
    const calls: Array<{ name?: string; status?: string }> = Array.isArray(parsed.tool_calls) ? parsed.tool_calls : [];
    return {
      exit,
      final_output: String(parsed.final_output ?? ""),
      requests: gateway.requests.length,
      max_rss_bytes: child.resourceUsage()?.maxRSS ?? 0,
      statuses: calls.map((c) => `${c.name}:${c.status}`),
      tail: `${stdout}\n${stderr}`.slice(-600),
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

// Each call of the turn, in order, with the outcome fx reported for it.
function observedCalls(steps: Step[], run: Run): ObservedCall[] | null {
  const expected = steps.reduce((sum, step) => sum + callsOf(step), 0);
  if (run.statuses.length !== expected) return null;
  const calls: ObservedCall[] = [];
  let at = 0;
  for (const step of steps) {
    for (let j = 0; j < callsOf(step); j++) {
      const status = run.statuses[at++]!.split(":").at(-1);
      if (status !== "success" && status !== "error") return null;
      calls.push({ kind: kindOf(step), outcome: status === "success" ? "success" : "failure", large: LARGE_STEPS.includes(step) });
    }
  }
  return calls;
}

function completed(steps: Step[], run: Run): boolean {
  return run.exit === 0 && run.final_output.includes(DONE) && run.requests === steps.length + 1;
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const call = (c: ObservedCall) => `[kind |-> ${str(c.kind)}, outcome |-> ${str(c.outcome)}, large |-> ${c.large ? "TRUE" : "FALSE"}]`;
  const value = (o: Observation) => `[calls |-> <<${o.calls.map(call).join(", ")}>>, kept |-> ${str(o.kept)}]`;
  return [
    "------------------------ MODULE ToolArenaObserved ------------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/tool_arena.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["ToolArena.tla", "ToolArenaTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "ToolArenaObserved.tla"), observedModule(observations));
  const maxCalls = Math.max(...observations.map((o) => o.calls.length));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  MaxCalls = ${maxCalls}`,
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "ToolArenaTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("tool_arena");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const cases = scripts();
  const runs: Array<{ id: string; steps: Step[]; size: number }> = [];
  for (const c of cases) for (const size of [options.large, SMALL]) runs.push({ ...c, size });
  const results = new Map<string, Run>();
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < runs.length) {
      const run = runs[next++]!;
      results.set(`${run.id}:${run.size}`, await runTurn(helpers, run.steps, run.size, scratch, `${run.id}-${run.size}`));
    }
  });
  await Promise.all(workers);
  const observations: Observation[] = [];
  for (const c of cases) {
    const large = results.get(`${c.id}:${options.large}`)!;
    const small = results.get(`${c.id}:${SMALL}`)!;
    for (const [label, run] of [["large", large], ["small", small]] as const) {
      if (!completed(c.steps, run)) {
        console.log(`TOOL_ERROR: turn ${c.id} (${label}) did not finish its script: ${JSON.stringify(run)}`);
        return 2;
      }
    }
    const calls = observedCalls(c.steps, large);
    if (!calls || JSON.stringify(observedCalls(c.steps, small)) !== JSON.stringify(calls)) {
      console.log(`REJECTED: turn ${c.id} reported calls the driver cannot read: ${JSON.stringify({ large: large.statuses, small: small.statuses })}`);
      return 1;
    }
    const largeReads = calls.filter((call) => call.large).length;
    const bar = Math.floor(0.5 * largeReads * options.large);
    const grew = large.max_rss_bytes - small.max_rss_bytes;
    const kept = largeReads > 0 && grew >= bar ? "scratch" : "results";
    observations.push({ id: c.id, steps: c.steps, calls, kept, evidence: { large, small, large_reads: largeReads, bar_bytes: bar, grew_bytes: grew } });
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  console.log(`${observations.length} turns of ${binary}, each at ${options.large} and ${SMALL} bytes, in ${seconds}s`);
  for (const o of observations) {
    const mib = (bytes: number) => (bytes / 1048576).toFixed(1);
    console.log(`  ${o.id}: ${o.calls.length} calls, ${o.evidence.large_reads} large reads, peak RSS ${mib(o.evidence.large.max_rss_bytes)} vs ${mib(o.evidence.small.max_rss_bytes)} MiB, grew ${mib(o.evidence.grew_bytes)} MiB (bar ${mib(o.evidence.bar_bytes)}), kept ${o.kept}`);
  }
  console.log(`observations: ${join(out, "observations.json")}`);

  const design = await runTrace(observations, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    for (const o of observations) {
      const alone = await runTrace([o], "none", out);
      if (alone.verdict !== "ACCEPTED") console.log(`the model cannot produce turn ${o.id}: kept ${o.kept}`);
    }
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
