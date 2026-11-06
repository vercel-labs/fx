// Runtime driver: runs the real `fx acp` binary through directed and
// seeded-random plans of requests that name a session, records what a client
// observes of each answer (success or error, the error code, whether
// `data.sessionId` names the session sent, and the kind of result), and asks
// TLC whether each run is a behavior of tests/tla/acp/AcpSessionTarget.tla.
//
//   bun tests/tla/drivers/acp/session_target/driver.ts              # after zig build
//   bun tests/tla/drivers/acp/session_target/driver.ts --model before
//
// --model fixed (the default) checks ACP v1's error rules. --model before
// checks the model of fx before them; a build of origin/main at 15dab7bb4,
// chosen with FX_WORKTREE or FX_BIN, matches it and fails --model fixed.
// --random sets how many seeded plans run, --steps their length, --seed the
// seed, and --only a pattern of plan names. No model calls: every reply comes
// from the fake Gateway in tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, type Observation, observe } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { validate } from "./trace";

// ------------------------------------------------------------------ plans --

const TARGET_OPS = ["prompt", "mode", "config", "cancel"] as const;
const NAMING_OPS = [...TARGET_OPS, "close", "load", "resume"] as const;
type NamingOp = (typeof NAMING_OPS)[number];
type Target = "A" | "B" | "X" | "none" | "bad";
const TARGETS: Target[] = ["A", "B", "X", "none", "bad"];

type Step = { op: "new" } | { op: "restart" } | { op: "oversize" } | { op: NamingOp; arg: Target };
type Plan = { name: string; steps: Step[] };

const N: Step = { op: "new" };
const R: Step = { op: "restart" };
const O: Step = { op: "oversize" };
const s = (op: NamingOp, arg: Target): Step => ({ op, arg });

const DIRECTED: Plan[] = [
  { name: "d1-open-and-unknown", steps: [
    N, s("prompt", "A"), s("mode", "A"), s("config", "A"), s("cancel", "A"),
    s("prompt", "X"), s("mode", "X"), s("config", "X"), s("cancel", "X"), s("close", "X"),
    s("prompt", "A"), s("close", "A"), s("prompt", "A"), s("close", "A"),
    s("load", "A"), s("prompt", "A"), s("resume", "A"),
  ] },
  { name: "d2-missing-ids", steps: [
    N, s("prompt", "none"), s("prompt", "bad"), s("mode", "none"), s("config", "bad"), s("cancel", "none"),
    s("close", "none"), s("close", "bad"), s("load", "none"), s("resume", "bad"), s("prompt", "A"),
  ] },
  { name: "d3-two-sessions", steps: [
    N, s("prompt", "A"), N, s("prompt", "A"), s("close", "A"), s("prompt", "B"), s("load", "A"),
    s("prompt", "B"), s("close", "B"), s("prompt", "A"), R, s("prompt", "A"), s("resume", "A"),
    s("prompt", "A"), s("load", "B"),
  ] },
  { name: "d4-unsaved", steps: [
    N, s("close", "A"), s("load", "A"), s("resume", "A"), N, R, s("load", "B"), s("resume", "X"), s("load", "X"),
  ] },
  { name: "d5-oversize", steps: [
    N, O, s("prompt", "A"), O, s("close", "A"), O, s("prompt", "A"),
  ] },
  { name: "d6-reload-open", steps: [
    N, s("load", "A"), s("prompt", "A"), s("load", "A"), s("resume", "A"), s("prompt", "A"),
  ] },
  { name: "d7-after-restart", steps: [
    N, s("prompt", "A"), R, s("mode", "A"), s("config", "A"), s("cancel", "A"), s("close", "A"),
    s("load", "A"), s("mode", "A"), s("cancel", "A"),
  ] },
];

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Seeded plans. Each starts with a session, creates at most two, and sends
/// at most one oversized frame, which takes fx a moment to read.
function randomPlans(count: number, steps: number, seed: number): Plan[] {
  const rand = mulberry32(seed);
  const pick = <T>(items: readonly T[]): T => items[Math.floor(rand() * items.length)]!;
  const plans: Plan[] = [];
  for (let n = 0; n < count; n += 1) {
    const plan: Step[] = [N];
    let created = 1;
    let oversized = false;
    while (plan.length < steps) {
      const roll = rand();
      if (roll < 0.08 && created < 2) {
        plan.push(N);
        created += 1;
      } else if (roll < 0.14) {
        plan.push(R);
      } else if (roll < 0.16 && !oversized) {
        plan.push(O);
        oversized = true;
      } else {
        // Favor the sessions a client really has.
        const arg = rand() < 0.7 ? pick(["A", "B"] as const) : pick(TARGETS);
        plan.push(s(pick(NAMING_OPS), arg));
      }
    }
    plans.push({ name: `r${String(n + 1).padStart(2, "0")}-seed${seed}`, steps: plan });
  }
  return plans;
}

// ------------------------------------------------------------------ runs --

/// A session id that fx never created, in the shape of a real one.
const UNKNOWN_ID = "1700000000000-1700000000000000000-00000000deadbeef";

function params(op: NamingOp, sessionId: unknown, workspace: string): [string, Record<string, unknown>] {
  const target = sessionId === undefined ? {} : { sessionId };
  switch (op) {
    case "prompt": return ["session/prompt", { ...target, prompt: [{ type: "text", text: "hello" }] }];
    case "mode": return ["session/set_mode", { ...target, modeId: "auto" }];
    case "config": return ["session/set_config_option", { ...target, configId: "mode", value: "auto" }];
    case "cancel": return ["session/cancel", target];
    case "close": return ["session/close", target];
    case "load": return ["session/load", { ...target, cwd: workspace, mcpServers: [] }];
    case "resume": return ["session/resume", { ...target, cwd: workspace, mcpServers: [] }];
  }
}

async function runPlan(plan: Plan, dir: string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new Fixture(binary);
  const observations: Observation[] = [];
  const ids: Record<string, string> = {};
  let error: string | null = null;
  const sessionIdFor = (target: Target): unknown => {
    if (target === "none") return undefined;
    if (target === "bad") return 42;
    if (target === "X") return UNKNOWN_ID;
    // A label the plan has not created yet names a session that doesn't exist.
    return ids[target] ?? `${UNKNOWN_ID.slice(0, -1)}${target === "A" ? "1" : "2"}`;
  };
  try {
    await fixture.init();
    const started = await fixture.start();
    observations.push({ ...observe("restart", "none", started, undefined), result: "none" });
    for (const step of plan.steps) {
      const acp = fixture.acp!;
      if (step.op === "new") {
        const label = ids.A === undefined ? "A" : "B";
        const response = await acp.call("session/new", { cwd: fixture.workspace, mcpServers: [] });
        const sessionId = response.result?.sessionId;
        if (typeof sessionId === "string") ids[label] = sessionId;
        observations.push(observe("new", label, response, undefined));
      } else if (step.op === "restart") {
        const response = await fixture.start();
        observations.push({ ...observe("restart", "none", response, undefined), result: "none" });
      } else if (step.op === "oversize") {
        observations.push(observe("oversize", "none", await acp.oversize(), undefined));
      } else {
        const sessionId = sessionIdFor(step.arg);
        const [method, body] = params(step.op, sessionId, fixture.workspace);
        observations.push(observe(step.op, step.arg, await acp.call(method, body), sessionId));
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.dispose();
  }
  writeJson(join(dir, "observations.json"), observations);
  writeJson(join(dir, "sessions.json"), ids);
  writeFileSync(join(dir, "acp.jsonl"), fixture.acpLog.map((entry) => JSON.stringify(entry, (key, value) =>
    key === "frame" || typeof value !== "string" || value.length < 4096 ? value : `${value.slice(0, 64)}...(${value.length} bytes)`)).join("\n") + "\n");
  writeJson(join(dir, "processes.json"), fixture.processes);
  return { observations, processes: fixture.processes, error };
}

// ---------------------------------------------------------------- controls --

const ok = (op: string, arg: string, result: string): Observation => ({ op, arg, ok: true, code: 0, dataSid: false, result });
const fail = (op: string, arg: string, code: number, dataSid: boolean): Observation => ({ op, arg, ok: false, code, dataSid, result: "none" });

/// A run the model allows, with the answers that `fixed` selects.
function syntheticTrace(fixed: boolean): Observation[] {
  const notFound = (op: string, arg: string) => (fixed ? fail(op, arg, -32002, true) : fail(op, arg, -32602, false));
  return [
    ok("restart", "none", "none"),
    ok("new", "A", "object"),
    ok("prompt", "A", "end_turn"),
    notFound("prompt", "X"),
    fixed ? ok("close", "X", "empty") : fail("close", "X", -32602, false),
    fail("mode", "none", -32602, false),
    ok("close", "A", "empty"),
    notFound("prompt", "A"),
    ok("load", "A", "object"),
    fail("oversize", "none", fixed ? -32600 : -32000, false),
    ok("cancel", "A", "null"),
  ];
}

/// Changes the latest error's code, or the latest result, so the run stops
/// matching the model.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 1; index -= 1) {
    const step = copy[index]!;
    if (!step.ok) {
      step.code = step.code === -32002 ? -32602 : -32002;
      return copy;
    }
    if (step.result === "empty") {
      step.result = "null";
      return copy;
    }
  }
  return null;
}

// -------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "fixed";
  if (model !== "fixed" && model !== "before") throw new Error(`--model must be fixed or before, not ${model}`);
  const fixed = model === "fixed";
  const seed = Number(argValue("--seed") ?? "20261106");
  const randomCount = Number(argValue("--random") ?? "12");
  const steps = Number(argValue("--steps") ?? "14");
  const only = argValue("--only");

  const reportDir = outDir(`acp-session-target-${model}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, seed, randomCount, steps, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const plans = [...DIRECTED, ...randomPlans(randomCount, steps, seed)].filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, dir);
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, fixed);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    results.push({ name: plan.name, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, processes: run.processes.map((proc) => proc.exit) });
    const divergence = checked?.firstDivergence;
    const where = divergence ? ` first divergence at step ${divergence.step}: ${JSON.stringify({ ...divergence.observation, detail: undefined })}` : "";
    console.log(`${plan.name}: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the checker separates runs the model allows from runs it doesn't.
  const controls = [];
  const synthetic = syntheticTrace(fixed);
  controls.push({ name: "synthetic-conforming", expect: "ACCEPTED", got: (await validate(synthetic, join(reportDir, "controls", "synthetic-conforming"), fixed)).verdict });
  controls.push({ name: "synthetic-tampered", expect: "REJECTED", got: (await validate(tamper(synthetic)!, join(reportDir, "controls", "synthetic-tampered"), fixed)).verdict });
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), fixed)).verdict });
  const firstAccepted = results.find((result) => result.verdict === "ACCEPTED");
  if (firstAccepted) {
    const observed = (await Bun.file(join(reportDir, "traces", firstAccepted.name, "observations.json")).json()) as Observation[];
    const tampered = tamper(observed);
    if (tampered) controls.push({ name: `tampered-${firstAccepted.name}`, expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", `tampered-${firstAccepted.name}`), fixed)).verdict });
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.every((control) => control.got === control.expect);
  writeJson(join(reportDir, "summary.json"), { manifest, counts, controlsPassed, controls, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "passed" : "FAILED"}`);
  console.log(`report: ${reportDir}`);
  process.exit(controlsPassed && results.every((result) => result.verdict === "ACCEPTED") ? 0 : 1);
}

await main();
