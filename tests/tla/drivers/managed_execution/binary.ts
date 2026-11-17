// Runs the built fx along tests/tla/managed_execution/QuietWait.tla, code to
// spec: seeded shell commands that print at chosen moments and then go quiet
// or exit, and a fake model that waits on each with shell interact calls of
// chosen yields. Every interact result becomes one observation: why the wait
// ended (from its state and how long it took), whether it said running,
// carried quiet_notice and output, and whether quiet_ms had reached the
// limit. TLC then checks that QuietWait has a behavior that gives every
// observation in order (QuietWaitTrace.tla).
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/managed_execution/binary.ts
//   bun tests/tla/drivers/managed_execution/binary.ts --self-check
//   bun tests/tla/drivers/managed_execution/binary.ts --runs 20 --seed 7
//
// --self-check also tampers one observation of each run that has one to
// tamper, and requires TLC to reject it.
//
// Exit codes: 0 every run accepted, 1 a rejected run (or a tampered run that
// was accepted), 2 a toolchain or harness failure.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

// The model's clock for this driver: one tick is TickMs of the binary's
// time, and the quiet limit FX_TEST_SHELL_QUIET_NOTICE_MS is Limit ticks.
// An interact without input waits at least 5 seconds
// (effective_interact_yield_time in src/tools/shell/shell.zig), so the
// yields start there.
const TickMs = 1_000;
const Limit = 3;
const LimitMs = Limit * TickMs;
const Yields = [5_000, 6_000, 8_000];
const MaxCeil = Math.max(...Yields) / TickMs + 1;
// A wait that ends this much before its yield ended early; one with a
// notice that ends within EarlyMs of it may have ended either way.
const EarlyMs = 300;
const MODEL = "openai/gpt-5.5";

type Observation = {
  ceils: number[];
  ends: string[];
  running: boolean;
  notice: boolean;
  quietDue: boolean[];
  output: boolean;
  // For the report.
  yieldMs: number;
  waitedMs: number;
  quietMs: number | null;
};

function flag(name: string): boolean {
  return process.argv.includes(name);
}

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = { selfCheck: flag("--self-check"), runs: option("--runs", 6), seed: option("--seed", 1) };

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

type Plan = { command: string; yields: number[] };

// A command prints one to three lines with pauses between them, then either
// stays quiet or exits; the model waits two or three times.
function planFor(random: () => number): Plan {
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  const parts: string[] = [];
  const lines = 1 + Math.floor(random() * 3);
  for (let i = 0; i < lines; i += 1) {
    parts.push(`sleep ${pick([0.3, 1.5, 3.5, 5.5])}`, `printf 'line-${i}\\n'`);
  }
  parts.push(random() < 0.5 ? "sleep 40" : `sleep ${pick([0.5, 4.5])}; exit 0`);
  const yields = Array.from({ length: 2 + Math.floor(random() * 2) }, () => pick(Yields));
  return { command: parts.join("; "), yields };
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function shellResult(body: string, callId: string): Record<string, any> {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content: unknown }> }).prompt;
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && part.toolCallId === callId) return JSON.parse(contentText(part.output));
    }
  }
  throw new Error(`missing tool result for ${callId}`);
}

function observe(result: Record<string, any>, yieldMs: number, waitedMs: number): Observation {
  const running = result.state === "running";
  const ends = !running
    ? ["done"]
    : waitedMs < yieldMs - EarlyMs
      ? ["quiet"]
      : result.quiet_notice !== undefined && waitedMs < yieldMs + EarlyMs ? ["quiet", "ceiling"] : ["ceiling"];
  const quietMs = typeof result.quiet_ms === "number" ? result.quiet_ms : null;
  const base = yieldMs / TickMs;
  return {
    ceils: [base, base + 1],
    ends,
    running,
    notice: typeof result.quiet_notice === "string",
    quietDue: quietMs === null ? [false, true] : [quietMs >= LimitMs],
    output: typeof result.output_delta === "string" && result.output_delta.length > 0,
    yieldMs,
    waitedMs,
    quietMs,
  };
}

async function runOnce(index: number, plan: Plan, out: string): Promise<Observation[]> {
  const { startDynamicFakeGateway, fakeGatewayToolCall, fakeGatewayFinalText } = await targetHelpers();
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-quiet-wait-${index}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const observations: Observation[] = [];
  const problems: string[] = [];
  let sent = 0;
  let sessionId = "";
  let waitStarted = 0;
  const finish = (text: string) => fakeGatewayFinalText(text);
  const gateway = startDynamicFakeGateway((body: string) => {
    const now = Date.now();
    try {
      if (sent === 0) {
        sent += 1;
        // yield 0 returns at once, so every output reaches an interact result.
        return fakeGatewayToolCall("quiet_run", "shell", {
          request: { action: "run", command: plan.command, profile: "clean", yield_time_ms: 0 },
        });
      }
      if (sent === 1) {
        const started = shellResult(body, "quiet_run");
        if (started.state !== "running") throw new Error(`run state ${started.state}`);
        sessionId = started.session_id;
      } else if (sent <= plan.yields.length + 1) {
        const k = sent - 2;
        const result = shellResult(body, `quiet_wait_${k}`);
        observations.push(observe(result, plan.yields[k]!, now - waitStarted));
        if (result.state !== "running") return finish("Quiet wait run ended.");
      } else {
        return finish("Quiet wait run ended.");
      }
      const k = sent - 1;
      sent += 1;
      if (k >= plan.yields.length) {
        return fakeGatewayToolCall("quiet_stop", "shell", { request: { action: "stop", session_id: sessionId } });
      }
      waitStarted = Date.now();
      return fakeGatewayToolCall(`quiet_wait_${k}`, "shell", {
        request: { action: "interact", session_id: sessionId, yield_time_ms: plan.yields[k] },
      });
    } catch (error) {
      problems.push(error instanceof Error ? error.message : String(error));
      return finish("Quiet wait run failed.");
    }
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  try {
    const proc = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-save", "Run the quiet wait fixture."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-quiet-wait-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: MODEL,
        FX_TEST_SHELL_QUIET_NOTICE_MS: String(LimitMs),
      }),
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    writeFileSync(join(out, `run-${index}.log`), `${plan.command}\n${JSON.stringify(plan.yields)}\n${stdout}\n[stderr]\n${stderr}\n`);
    if (problems.length > 0) fail(2, `run ${index}: ${problems.join("; ")}`);
    if (exitCode !== 0) fail(2, `run ${index}: fx exited ${exitCode}: ${stderr}`);
    return observations;
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const tlaBool = (value: boolean) => (value ? "TRUE" : "FALSE");
const tlaSet = (items: string[]) => `{${items.join(", ")}}`;

function observedModule(observations: Observation[]): string {
  const records = observations.map((o) =>
    `[ceils |-> ${tlaSet(o.ceils.map(String))}, ends |-> ${tlaSet(o.ends.map((e) => `"${e}"`))}, ` +
    `running |-> ${tlaBool(o.running)}, notice |-> ${tlaBool(o.notice)}, ` +
    `quietDue |-> ${tlaSet(o.quietDue.map(tlaBool))}, output |-> ${tlaBool(o.output)}]`
  );
  return [
    "------------------------- MODULE QuietWaitObserved -------------------------",
    "\\* Generated by tests/tla/drivers/managed_execution/binary.ts.",
    `Observed == <<${records.join(",\n    ")}>>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function accepted(observations: Observation[], dir: string): Promise<boolean> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "QuietWaitObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "INIT TraceInit", "NEXT TraceStep", "CONSTANTS", `    Limit = ${Limit}`, `    MaxCeil = ${MaxCeil}`,
    `    Bug = "none"`, "INVARIANT NotAllMatched", "",
  ].join("\n"));
  const run = await runTlc(dir, "QuietWaitTrace", "trace.cfg", ["QuietWait.tla", "QuietWaitTrace.tla"],
    join(TLA_ROOT, "managed_execution"), ["-deadlock"]);
  if (run.violated === "NotAllMatched") return true;
  if (run.exitCode === 0) return false;
  fail(2, `TLC failed on the trace in ${dir} (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
}

// One observation changed so that no behavior of the model gives it: a
// notice on a result that had not reached the limit, or none on one that had.
function tampered(observations: Observation[]): Observation[] | null {
  const at = observations.findIndex((o) => o.running && o.quietDue.length === 1);
  if (at < 0) return null;
  const copy = observations.map((o) => ({ ...o }));
  copy[at]!.notice = !copy[at]!.notice;
  return copy;
}

const out = outDir("managed-execution-binary");
const started = performance.now();
const random = rng(options.seed);
let ok = true;
let waits = 0;
let tamperedRuns = 0;
const endCounts = new Map<string, number>();
for (let i = 0; i < options.runs; i += 1) {
  const plan = planFor(random);
  const observations = await runOnce(i, plan, out);
  waits += observations.length;
  for (const o of observations) endCounts.set(o.ends.join("|"), (endCounts.get(o.ends.join("|")) ?? 0) + 1);
  writeFileSync(join(out, `run-${i}.observations.json`), `${JSON.stringify(observations, null, 2)}\n`);
  const good = await accepted(observations, join(out, `trace-${i}`));
  console.log(`run ${i}: ${observations.length} waits ${good ? "ACCEPTED" : "REJECTED"}: ${plan.command} yields ${JSON.stringify(plan.yields)}`);
  if (!good) {
    for (const o of observations) console.log(`  ${JSON.stringify(o)}`);
    ok = false;
  }
  if (options.selfCheck) {
    const bad = tampered(observations);
    if (bad) {
      tamperedRuns += 1;
      const caught = !(await accepted(bad, join(out, `tampered-${i}`)));
      console.log(`self-check: run ${i} with one notice flipped ${caught ? "rejected" : "NOT rejected"}`);
      ok &&= caught;
    }
  }
}
const ends = [...endCounts.entries()].map(([end, count]) => `${end} ${count}`).join(", ");
console.log(`${options.runs} runs, ${waits} waits; ends: ${ends}`);
if (options.selfCheck && tamperedRuns === 0) {
  console.log("self-check: no run had an observation to tamper");
  ok = false;
}
console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
