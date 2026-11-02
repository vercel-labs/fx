// Runtime driver: drives the real `fx acp` binary from a worktree through
// directed and seeded-random speed scenarios, records what a client observes
// (configOptions projections, JSON-RPC errors, and the lane each prompt sends
// to a local fake Gateway), and asks TLC whether each observed run is a
// behavior of tests/tla/acp/AcpSpeed.tla (trace validation via tests/tla/acp/AcpSpeedTrace.tla).
//
//   bun tests/tla/drivers/acp/speed/driver.ts --label main   # from the repository root, after zig build
//
// No live model calls: completions come from the fake Gateway in the
// worktree's own tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { REPO_ROOT, outDir } from "../../lib/tlc";
import { sha256File, sha256Text, tlcToolchain, utcStamp, writeJson } from "./tlc";
import { Acp, NO_VIEW, type Observation, type View, laneOf, validate, viewOf } from "./trace";

// ---------------------------------------------------------------- catalog --

const BOTH = "openai/gpt-6-astra"; // Fast (priority tier) and Ultrafast
const FAST_ONLY = "openai/gpt-5.6-priority"; // Fast only
const PLAIN = "anthropic/claude-plain"; // neither
const MODELS = [BOTH, FAST_ONLY, PLAIN];
const SUP_FAST = [BOTH, FAST_ONLY];
const SUP_ULTRA = [BOTH];
const TRACE_CATALOG = { models: MODELS, supFast: SUP_FAST, supUltra: SUP_ULTRA };

const CATALOG = [
  {
    id: BOTH, name: "GPT-6 Astra", type: "language", owned_by: "openai", tags: ["tool-use", "reasoning"],
    reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
    pricing: {
      input_cache_read: "0.000001",
      service_tiers: {
        priority: { input: "0.00003", output: "0.00015", input_cache_read: "0.000003" },
        ultrafast: { input: "0.00006", output: "0.0003", input_cache_read: "0.000006" },
      },
    },
  },
  {
    id: FAST_ONLY, name: "GPT-5.6 Priority", type: "language", owned_by: "openai", tags: ["tool-use"],
    pricing: { service_tiers: { priority: { input: "0.00003", output: "0.00015" } } },
  },
  { id: PLAIN, name: "Claude Plain", type: "language", owned_by: "anthropic", tags: ["tool-use"] },
];

// ------------------------------------------------------------------ plans --

type PlanOp =
  | { op: "fast" | "ultrafast"; value: boolean }
  | { op: "model"; model: string }
  | { op: "unknown" }
  | { op: "prompt" }
  | { op: "resume" };

type Plan = { name: string; initialModel: string; defaultFast: boolean; ops: PlanOp[] };

const on = (op: "fast" | "ultrafast"): PlanOp => ({ op, value: true });
const off = (op: "fast" | "ultrafast"): PlanOp => ({ op, value: false });
const to = (model: string): PlanOp => ({ op: "model", model });
const P: PlanOp = { op: "prompt" };
const R: PlanOp = { op: "resume" };
const U: PlanOp = { op: "unknown" };

const DIRECTED: Plan[] = [
  { name: "d1-lanes-exclusive", initialModel: BOTH, defaultFast: false,
    ops: [P, on("fast"), P, on("ultrafast"), P, on("fast"), P, off("fast"), P, U, R, P] },
  { name: "d2-switch-drops-ultrafast", initialModel: BOTH, defaultFast: false,
    ops: [on("ultrafast"), to(PLAIN), P, to(BOTH), P, on("ultrafast"), R, P, to(FAST_ONLY), P] },
  { name: "d3-fast-only-model", initialModel: FAST_ONLY, defaultFast: true,
    ops: [P, on("ultrafast"), off("fast"), P, on("fast"), to(PLAIN), P, to(FAST_ONLY), P, R, P] },
  { name: "d4-plain-model", initialModel: PLAIN, defaultFast: true,
    ops: [P, on("fast"), on("ultrafast"), off("fast"), off("ultrafast"), to(FAST_ONLY), P, R, P] },
  { name: "d5-hidden-default-fast", initialModel: PLAIN, defaultFast: true,
    ops: [P, to(BOTH), P, R, P, on("ultrafast"), to(FAST_ONLY), P] },
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
    () => on("fast"), () => off("fast"), () => on("fast"),
    () => on("ultrafast"), () => off("ultrafast"), () => on("ultrafast"),
    () => to(pick(MODELS)), () => to(pick(MODELS)), () => to(pick(MODELS)),
    () => P, () => P, () => U, () => R,
  ];
  // The v2 session store saves a chat at its first turn, so resuming earlier
  // fails with "Session not found" on main too. Resume therefore only follows
  // a prompt (an explicit assumption in tests/tla/acp/AcpSpeed.tla).
  return Array.from({ length: count }, (_, index) => {
    const name = `r${String(index + 1).padStart(2, "0")}-seed${seed}`;
    const initialModel = pick(MODELS);
    const defaultFast = rand() < 0.5;
    let prompted = false;
    const ops = Array.from({ length: steps }, () => {
      const op = pick(weighted)();
      const chosen = op.op === "resume" && !prompted ? P : op;
      if (chosen.op === "prompt") prompted = true;
      return chosen;
    });
    return { name, initialModel, defaultFast, ops };
  });
}

// ------------------------------------------------------------------ runner --

type Helpers = {
  startDynamicFakeGateway: (respond: (body: string) => Response, options: object) => any;
  fakeGatewayFinalText: (text: string) => Response;
};

async function runPlan(plan: Plan, worktree: string, helpers: Helpers, dir: string) {
  mkdirSync(dir, { recursive: true });
  writeJson(join(dir, "plan.json"), plan);
  const fxBin = join(worktree, "zig-out", "bin", "fx");
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-speed-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true, mode: 0o700 });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    `${JSON.stringify({ session_titles: false, fast_mode: plan.defaultFast, models: { gateway: plan.initialModel } })}\n`,
    { mode: 0o600 },
  );

  const acpLog: object[] = [];
  const gatewayLog: object[] = [];
  let completions: string[] = [];
  const gateway = helpers.startDynamicFakeGateway((body: string) => {
    completions.push(body);
    gatewayLog.push({ n: gatewayLog.length + 1, lane: laneOf(body), model: (() => { try { return JSON.parse(body).model; } catch { return null; } })() });
    return helpers.fakeGatewayFinalText(`reply ${gatewayLog.length}`);
  }, { models: () => CATALOG });

  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries({
    ...process.env,
    NO_COLOR: "1",
    HOME: home,
    AI_GATEWAY_API_KEY: "acp-speed-fake-key",
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TRACE_LOG: join(dir, "fx-trace.log"),
    FX_TRACE_SCOPES: "acp,catalog",
  })) {
    if (value === undefined) continue;
    // FX_PROVIDER and FX_MODEL are process overrides: fx then resumes every
    // chat on the process's model instead of the chat's saved one, which no
    // real ACP host (fx-plus included) does. The Gateway is already the default.
    if (["VERCEL_OIDC_TOKEN", "FX_PROVIDER", "FX_MODEL", "FX_FAST", "FX_ULTRAFAST", "FX_PERMISSION_MODE", "FX_DEBUG_RECORD"].includes(key)) continue;
    env[key] = value;
  }

  const processes: Array<{ exit: number; stderr: string }> = [];
  const spawn = () => new Acp(
    Bun.spawn([fxBin, "acp"], { cwd: workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }),
    (entry) => acpLog.push({ process: processes.length + 1, ...entry }),
  );
  const observations: Observation[] = [];
  let acp = spawn();
  let error: string | null = null;
  try {
    await acp.call("initialize", { protocolVersion: 1 });
    const created = await acp.call("session/new", { cwd: workspace, mcpServers: [] });
    const sessionId = created.result?.sessionId as string | undefined;
    const view = viewOf(created.result?.configOptions);
    if (!sessionId || !view) throw new Error(`session/new failed: ${JSON.stringify(created.error ?? created.result)}`);
    observations.push({ op: "new", arg: "none", ok: true, speed: "none", hasView: true, view });

    const configStep = async (op: string, arg: string, configId: string, value: string) => {
      const response = await acp.call("session/set_config_option", { sessionId, configId, value });
      const stepView = response.error ? null : viewOf(response.result?.configOptions);
      observations.push({
        op, arg, ok: !response.error, speed: "none",
        hasView: stepView !== null, view: stepView ?? NO_VIEW,
        detail: response.error ? { error: response.error } : undefined,
      });
    };

    for (const step of plan.ops) {
      switch (step.op) {
        case "fast":
        case "ultrafast":
          await configStep(step.op, String(step.value), step.op, String(step.value));
          break;
        case "model":
          await configStep("model", step.model, "model", step.model);
          break;
        case "unknown":
          await configStep("unknown", "none", "turbo", "on");
          break;
        case "prompt": {
          completions = [];
          const response = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "speed check" }] });
          const ok = !response.error && response.result?.stopReason === "end_turn";
          const lanes = completions.map(laneOf);
          const speed = !ok ? "none" : lanes.length === 1 ? lanes[0]! : `requests:${lanes.join(",") || "0"}`;
          observations.push({
            op: "prompt", arg: "none", ok, speed, hasView: false, view: NO_VIEW,
            detail: { lanes, error: response.error ?? null, stopReason: response.result?.stopReason ?? null },
          });
          break;
        }
        case "resume": {
          processes.push(await acp.close());
          acp = spawn();
          await acp.call("initialize", { protocolVersion: 1 });
          const resumed = await acp.call("session/resume", { sessionId, cwd: workspace, mcpServers: [] });
          const resumedView = resumed.error ? null : viewOf(resumed.result?.configOptions);
          observations.push({
            op: "resume", arg: "none", ok: !resumed.error, speed: "none",
            hasView: resumedView !== null, view: resumedView ?? NO_VIEW,
            detail: resumed.error ? { error: resumed.error } : undefined,
          });
          break;
        }
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    processes.push(await acp.close());
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }

  writeJson(join(dir, "observations.json"), observations);
  writeFileSync(join(dir, "acp.jsonl"), acpLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeFileSync(join(dir, "gateway.jsonl"), gatewayLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeJson(join(dir, "processes.json"), processes);
  return { observations, processes, error };
}

// ---------------------------------------------------------------- controls --

function syntheticTrace(): Observation[] {
  const v = (fast: string, ultra: string): View => ({ model: BOTH, fast, ultra });
  return [
    { op: "new", arg: "none", ok: true, speed: "none", hasView: true, view: v("false", "false") },
    { op: "fast", arg: "true", ok: true, speed: "none", hasView: true, view: v("true", "false") },
    { op: "prompt", arg: "none", ok: true, speed: "fast", hasView: false, view: NO_VIEW },
    { op: "ultrafast", arg: "true", ok: true, speed: "none", hasView: true, view: v("false", "true") },
    { op: "prompt", arg: "none", ok: true, speed: "ultrafast", hasView: false, view: NO_VIEW },
  ];
}

function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 0; index -= 1) {
    const step = copy[index]!;
    if (step.op === "prompt" && step.ok) {
      step.speed = step.speed === "fast" ? "standard" : "fast";
      return copy;
    }
    if (step.hasView && step.view.fast !== "absent") {
      step.view.fast = step.view.fast === "true" ? "false" : "true";
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
  const seed = Number(argValue("--seed") ?? "20261006");
  const randomCount = Number(argValue("--random") ?? "24");
  const steps = Number(argValue("--steps") ?? "12");

  const reportDir = outDir(`acp-speed-${label}`);
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

  const helpers = await import(join(worktree, "tests", "e2e", "tmux-helpers.ts")) as Helpers;
  const only = argValue("--only");
  const plans = [...DIRECTED, ...randomPlans(randomCount, steps, seed)]
    .filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, worktree, helpers, dir);
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, TRACE_CATALOG);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    results.push({ name: plan.name, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, processes: run.processes.map((proc) => proc.exit) });
    const where = checked?.firstDivergence ? ` first divergence at step ${checked.firstDivergence.step}: ${JSON.stringify(checked.firstDivergence.observation)}` : "";
    console.log(`${plan.name}: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the bridge separates conforming from non-conforming runs.
  const controls = [];
  const synthetic = syntheticTrace();
  controls.push({ name: "synthetic-conforming", expect: "ACCEPTED", got: (await validate(synthetic, join(reportDir, "controls", "synthetic-conforming"), TRACE_CATALOG)).verdict });
  controls.push({ name: "synthetic-tampered", expect: "REJECTED", got: (await validate(tamper(synthetic)!, join(reportDir, "controls", "synthetic-tampered"), TRACE_CATALOG)).verdict });
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), TRACE_CATALOG)).verdict });
  const firstAccepted = results.find((result) => result.verdict === "ACCEPTED");
  if (firstAccepted) {
    const observed = (await Bun.file(join(reportDir, "traces", firstAccepted.name, "observations.json")).json()) as Observation[];
    const tampered = tamper(observed);
    if (tampered) {
      controls.push({ name: `tampered-${firstAccepted.name}`, expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", `tampered-${firstAccepted.name}`), TRACE_CATALOG)).verdict });
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
