// Runtime driver: runs the real `fx acp` binary from a worktree through
// directed and seeded-random permission-mode plans, records what a client
// observes (mode option and older modes field, JSON-RPC errors, the
// profile's saved mode, and how each prompt's shell call was enforced), and
// asks TLC whether each observed run is a behavior of
// tests/tla/acp/AcpPermissionModes.tla.
//
//   bun tests/tla/drivers/acp/permission_modes/driver.ts --label main   # from the repository root, after zig build
//
// No model calls: completions and reviewer answers come from the fake
// Gateway in tests/e2e/tmux-helpers.ts. --worktree runs another checkout's build.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { Fixture, NO_VIEW, type Observation, loadHelpers, viewOf } from "./harness";
import { REPO_ROOT, outDir } from "../../lib/tlc";
import { sha256File, sha256Text, tlcToolchain, utcStamp, writeJson } from "./tlc";
import { validate } from "./trace";

// ------------------------------------------------------------------ plans --

const MODES = ["auto", "ask", "full-access"];
const UNKNOWN = ["code", "yolo"];
const PROFILES = ["unset", ...MODES];

type PlanOp =
  | { op: "set" | "legacy" | "other"; value: string }
  | { op: "prompt" }
  | { op: "resume" }
  | { op: "fresh" }
  | { op: "new" }
  | { op: "status" };

type Plan = { name: string; profile: string; ops: PlanOp[] };

const set = (value: string): PlanOp => ({ op: "set", value });
const legacy = (value: string): PlanOp => ({ op: "legacy", value });
const other = (value: string): PlanOp => ({ op: "other", value });
const P: PlanOp = { op: "prompt" };
const R: PlanOp = { op: "resume" };
const F: PlanOp = { op: "fresh" };
const N: PlanOp = { op: "new" };
const S: PlanOp = { op: "status" };

const DIRECTED: Plan[] = [
  { name: "d1-unset-is-auto", profile: "unset",
    ops: [P, set("ask"), P, set("full-access"), P, set("auto"), P, R, P] },
  { name: "d2-profile-ask", profile: "ask",
    ops: [P, F, legacy("full-access"), P, F, P, R, set("auto"), F, P] },
  { name: "d3-unknown-rejected", profile: "auto",
    ops: [set("code"), legacy("code"), set("yolo"), legacy("yolo"), P, set("ask"), set("code"), P] },
  { name: "d4-profile-full-access", profile: "full-access",
    ops: [P, set("ask"), P, R, P, F, P] },
  { name: "d5-legacy-only", profile: "unset",
    ops: [legacy("ask"), P, legacy("auto"), P, legacy("full-access"), P, R, P, F] },
  // A warm process (like fx-plus's spare) must not start new sessions in a
  // mode another process has since replaced.
  { name: "d6-other-process", profile: "full-access",
    ops: [P, other("ask"), P, N, P, other("full-access"), P, R, P, set("auto"), N, P] },
  // fx status reports the next session's mode, which an open session may not share.
  { name: "d7-status", profile: "unset",
    ops: [S, set("full-access"), S, other("ask"), S, P, N, S, legacy("auto"), F, S] },
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

function randomPlans(count: number, steps: number, seed: number): Plan[] {
  const rand = mulberry32(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(rand() * items.length)]!;
  const weighted: Array<() => PlanOp> = [
    () => set(pick(MODES)), () => set(pick(MODES)), () => set(pick(MODES)), () => set(pick(UNKNOWN)),
    () => legacy(pick(MODES)), () => legacy(pick(MODES)), () => legacy(pick(UNKNOWN)),
    () => other(pick(MODES)), () => N, () => S,
    () => P, () => P, () => P, () => R, () => F,
  ];
  // fx saves a chat at its first turn, so resume only follows a prompt in
  // the current session (an explicit assumption in the spec).
  return Array.from({ length: count }, (_, index) => {
    const name = `r${String(index + 1).padStart(2, "0")}-seed${seed}`;
    const profile = pick(PROFILES);
    let prompted = false;
    const ops = Array.from({ length: steps }, () => {
      const op = pick(weighted)();
      const chosen = op.op === "resume" && !prompted ? P : op;
      if (chosen.op === "prompt") prompted = true;
      if (chosen.op === "fresh" || chosen.op === "new") prompted = false;
      return chosen;
    });
    return { name, profile, ops };
  });
}

// ------------------------------------------------------------------ runner --

async function runPlan(plan: Plan, worktree: string, helpers: Awaited<ReturnType<typeof loadHelpers>>, dir: string) {
  mkdirSync(dir, { recursive: true });
  writeJson(join(dir, "plan.json"), plan);
  const fixture = new Fixture(worktree, helpers, plan.profile, join(dir, "fx-trace.log"));
  const observations: Observation[] = [];
  let error: string | null = null;
  const sessionStep = (op: string, response: any) => {
    const view = response.error ? null : viewOf(response.result);
    observations.push({
      op, arg: "none", ok: !response.error && view !== null, hasView: view !== null, view: view ?? NO_VIEW,
      enforce: "none", stored: fixture.stored(),
      detail: response.error ? { error: response.error } : view ? undefined : { result: response.result },
    });
    return response.result?.sessionId as string | undefined;
  };
  try {
    let acp = await fixture.start();
    let sessionId = sessionStep("new", await acp.call("session/new", { cwd: fixture.workspace, mcpServers: [] }));
    if (!sessionId) throw new Error("session/new returned no session");

    for (const step of plan.ops) {
      switch (step.op) {
        case "set": {
          const response = await acp.call("session/set_config_option", { sessionId, configId: "mode", value: step.value });
          const view = response.error ? null : viewOf(response.result);
          observations.push({
            op: "set", arg: step.value, ok: !response.error, hasView: view !== null, view: view ?? NO_VIEW,
            enforce: "none", stored: fixture.stored(), detail: response.error ? { error: response.error } : undefined,
          });
          break;
        }
        case "legacy": {
          const response = await acp.call("session/set_mode", { sessionId, modeId: step.value });
          observations.push({
            op: "legacy", arg: step.value, ok: !response.error, hasView: false, view: NO_VIEW,
            enforce: "none", stored: fixture.stored(),
            detail: response.error ? { error: response.error } : { result: response.result ?? null },
          });
          break;
        }
        case "prompt": {
          const probe = await fixture.probePrompt(sessionId);
          observations.push({
            op: "prompt", arg: "none", ok: probe.ok, hasView: false, view: NO_VIEW,
            enforce: probe.enforce, stored: fixture.stored(), detail: probe.detail,
          });
          break;
        }
        case "resume": {
          acp = await fixture.restart();
          sessionStep("resume", await acp.call("session/resume", { sessionId, cwd: fixture.workspace, mcpServers: [] }));
          break;
        }
        case "fresh": {
          acp = await fixture.restart();
          const next = sessionStep("fresh", await acp.call("session/new", { cwd: fixture.workspace, mcpServers: [] }));
          if (!next) throw new Error("session/new in a fresh process returned no session");
          sessionId = next;
          break;
        }
        case "new": {
          const next = sessionStep("new", await acp.call("session/new", { cwd: fixture.workspace, mcpServers: [] }));
          if (!next) throw new Error("session/new returned no session");
          sessionId = next;
          break;
        }
        case "status": {
          const status = fixture.status();
          observations.push({
            op: "status", arg: "none", ok: status.ok, hasView: status.view !== null, view: status.view ?? NO_VIEW,
            enforce: "none", stored: fixture.stored(), detail: status.detail,
          });
          break;
        }
        case "other": {
          fixture.saveFromOtherProcess(step.value);
          observations.push({
            op: "other", arg: step.value, ok: true, hasView: false, view: NO_VIEW,
            enforce: "none", stored: fixture.stored(),
          });
          break;
        }
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.dispose();
  }

  writeJson(join(dir, "observations.json"), observations);
  writeFileSync(join(dir, "acp.jsonl"), fixture.acpLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeFileSync(join(dir, "gateway.jsonl"), fixture.gatewayLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeJson(join(dir, "processes.json"), fixture.processes);
  return { observations, processes: fixture.processes, error };
}

// ---------------------------------------------------------------- controls --

function syntheticTrace(): Observation[] {
  const session = (current: string) => ({
    current, legacy: current, listed: "auto,ask,full-access", legacyListed: "auto,ask,full-access",
    names: "Auto,Ask,Full access", schemaOk: true,
  });
  const config = (current: string) => ({ ...session(current), legacy: "n/a", legacyListed: "n/a" });
  const quiet = { hasView: false, view: NO_VIEW };
  return [
    { op: "new", arg: "none", ok: true, hasView: true, view: session("auto"), enforce: "none", stored: "unset" },
    { op: "prompt", arg: "none", ok: true, ...quiet, enforce: "reviewed/ran", stored: "unset" },
    { op: "set", arg: "ask", ok: true, hasView: true, view: config("ask"), enforce: "none", stored: "ask" },
    { op: "prompt", arg: "none", ok: true, ...quiet, enforce: "asked/no-run", stored: "ask" },
    { op: "set", arg: "code", ok: false, ...quiet, enforce: "none", stored: "ask" },
    { op: "legacy", arg: "full-access", ok: true, ...quiet, enforce: "none", stored: "full-access" },
    { op: "prompt", arg: "none", ok: true, ...quiet, enforce: "direct/ran", stored: "full-access" },
    { op: "resume", arg: "none", ok: true, hasView: true, view: session("full-access"), enforce: "none", stored: "full-access" },
    { op: "other", arg: "ask", ok: true, ...quiet, enforce: "none", stored: "ask" },
    { op: "status", arg: "none", ok: true, hasView: true, view: config("ask"), enforce: "none", stored: "ask" },
    { op: "prompt", arg: "none", ok: true, ...quiet, enforce: "direct/ran", stored: "ask" },
    { op: "new", arg: "none", ok: true, hasView: true, view: session("ask"), enforce: "none", stored: "ask" },
    { op: "prompt", arg: "none", ok: true, ...quiet, enforce: "asked/no-run", stored: "ask" },
  ];
}

/// Flips the latest prompt's enforcement (or a shown mode), so a conforming
/// trace stops conforming.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 0; index -= 1) {
    const step = copy[index]!;
    if (step.op === "prompt" && step.ok) {
      step.enforce = step.enforce === "direct/ran" ? "asked/no-run" : "direct/ran";
      return copy;
    }
    if (step.hasView) {
      step.view.current = step.view.current === "ask" ? "auto" : "ask";
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

function git(worktree: string, ...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  const worktree = resolve(argValue("--worktree") ?? REPO_ROOT);
  const fxBin = join(worktree, "zig-out", "bin", "fx");
  if (!existsSync(fxBin)) throw new Error(`missing ${fxBin}; run zig build first`);
  const label = argValue("--label") ?? "run";
  const seed = Number(argValue("--seed") ?? "20261007");
  const randomCount = Number(argValue("--random") ?? "20");
  const steps = Number(argValue("--steps") ?? "12");

  const reportDir = outDir(`acp-permission-modes-${label}`);
  mkdirSync(reportDir, { recursive: true });
  const status = git(worktree, "status", "--porcelain");
  const manifest = {
    label,
    worktree,
    head: git(worktree, "rev-parse", "HEAD"),
    dirty: status.length > 0,
    status: status.split("\n").filter(Boolean),
    diff_sha256: status ? sha256Text(git(worktree, "diff", "HEAD")) : null,
    fx_binary_sha256: sha256File(fxBin),
    toolchain: tlcToolchain(),
    bun: Bun.version,
    seed,
    randomCount,
    steps,
    argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);
  if (status) writeFileSync(join(reportDir, "worktree.diff"), git(worktree, "diff", "HEAD") + "\n");

  const helpers = await loadHelpers(worktree);
  const only = argValue("--only");
  const plans = [...DIRECTED, ...randomPlans(randomCount, steps, seed)]
    .filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, worktree, helpers, dir);
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, plan.profile);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    results.push({ name: plan.name, profile: plan.profile, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, processes: run.processes.map((proc) => proc.exit) });
    const divergence = checked?.firstDivergence;
    const where = divergence
      ? ` first divergence at step ${divergence.step}: ${JSON.stringify({ ...divergence.observation, detail: undefined })}`
      : "";
    console.log(`${plan.name} [${plan.profile}]: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the bridge separates conforming from non-conforming runs.
  const controls = [];
  const synthetic = syntheticTrace();
  controls.push({ name: "synthetic-conforming", expect: "ACCEPTED", got: (await validate(synthetic, join(reportDir, "controls", "synthetic-conforming"), "unset")).verdict });
  controls.push({ name: "synthetic-tampered", expect: "REJECTED", got: (await validate(tamper(synthetic)!, join(reportDir, "controls", "synthetic-tampered"), "unset")).verdict });
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), "unset")).verdict });
  const firstAccepted = results.find((result) => result.verdict === "ACCEPTED");
  if (firstAccepted) {
    const observed = (await Bun.file(join(reportDir, "traces", firstAccepted.name, "observations.json")).json()) as Observation[];
    const tampered = tamper(observed);
    if (tampered) {
      controls.push({ name: `tampered-${firstAccepted.name}`, expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", `tampered-${firstAccepted.name}`), firstAccepted.profile)).verdict });
    }
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.every((control) => control.got === control.expect);
  const summary = { manifest, counts, controlsPassed, controls, results };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "passed" : "FAILED"}`);
  console.log(`report: ${reportDir}`);
  const allAccepted = results.every((result) => result.verdict === "ACCEPTED");
  process.exit(controlsPassed && allAccepted ? 0 : 1);
}

await main();
