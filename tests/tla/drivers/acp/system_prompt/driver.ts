// Runtime driver: runs the real `fx acp` binary through directed and
// seeded-random plans that send `systemPrompt` in each shape on session/new,
// session/load and session/resume, runs turns, and restarts the process. It
// records each answer, whether initialize lists the systemPrompt capability,
// and which prompt the model request of each turn carried, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpSystemPrompt.tla.
//
//   bun tests/tla/drivers/acp/system_prompt/driver.ts               # after zig build
//   bun tests/tla/drivers/acp/system_prompt/driver.ts --model before
//
// --model fixed (the default) checks ACP v1's rules. --model before checks the
// model of fx before them; a build of origin/main at 15dab7bb4, chosen with
// FX_WORKTREE or FX_BIN, matches it and fails --model fixed. --random,
// --steps, --seed and --only work as in ../session_target/driver.ts. No model
// calls: every reply comes from the fake Gateway in tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture } from "../session_target/harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Observation, validate } from "./trace";

// ---------------------------------------------------------------- prompts --

type Label = "P1" | "P2" | "array" | "override" | "nomode" | "empty" | "image" | "none";
const LABELS: Label[] = ["P1", "P2", "array", "override", "nomode", "empty", "image", "none"];

/// Each label's text carries a marker, so a model request shows which prompt it holds.
const MARKERS: Record<string, string> = { P1: "P1-7f3a", P2: "P2-9c1d", array: "ARRAY-4e2b", override: "OVERRIDE-1a2b", nomode: "NOMODE-5d6e" };
const text = (label: string) => ({ type: "text", text: `Follow rule ${MARKERS[label]}.` });

function systemPrompt(label: Label): unknown {
  switch (label) {
    case "P1":
    case "P2": return { mode: "append", content: [text(label)] };
    case "array": return [text("array")];
    case "override": return { mode: "override", content: [text("override")] };
    case "nomode": return { content: [text("nomode")] };
    case "empty": return { mode: "append", content: [] };
    case "image": return { mode: "append", content: [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }] };
    case "none": return undefined;
  }
}

/// The prompt a model request carried, by its marker.
function sentIn(body: string | undefined): string {
  if (body === undefined) return "no-request";
  const found = Object.entries(MARKERS).filter(([, marker]) => body.includes(marker)).map(([label]) => label);
  return found.length === 0 ? "none" : found.length === 1 ? found[0]! : `several:${found.join("+")}`;
}

// ------------------------------------------------------------------ plans --

type Step = { op: "new" | "load" | "resume"; arg: Label } | { op: "prompt" } | { op: "restart" };
type Plan = { name: string; steps: Step[] };

const P: Step = { op: "prompt" };
const R: Step = { op: "restart" };
const s = (op: "new" | "load" | "resume", arg: Label): Step => ({ op, arg });

const DIRECTED: Plan[] = [
  { name: "s1-apply-and-keep", steps: [
    s("new", "P1"), P, s("load", "P2"), P, s("resume", "none"), P, R, s("load", "none"), P, s("resume", "P1"), P,
  ] },
  { name: "s2-new-refusals", steps: [
    s("new", "array"), s("new", "override"), s("new", "nomode"), s("new", "empty"), s("new", "image"), s("new", "P2"), P,
  ] },
  { name: "s3-load-refusals", steps: [
    s("new", "P1"), P, s("load", "array"), s("load", "override"), s("load", "empty"), s("load", "image"), s("load", "nomode"),
    P, R, s("resume", "array"), s("resume", "image"), s("load", "P2"), P,
  ] },
  { name: "s4-no-prompt", steps: [
    s("new", "none"), P, s("load", "P1"), P, R, s("resume", "none"), P, s("load", "none"), P,
  ] },
  { name: "s5-before-saved", steps: [
    s("load", "P1"), s("resume", "none"), s("new", "P2"), s("load", "P1"), P, R, s("resume", "P2"), P,
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

function randomPlans(count: number, steps: number, seed: number): Plan[] {
  const rand = mulberry32(seed);
  const pick = <T>(items: readonly T[]): T => items[Math.floor(rand() * items.length)]!;
  const plans: Plan[] = [];
  for (let n = 0; n < count; n += 1) {
    const plan: Step[] = [s("new", rand() < 0.6 ? pick(["P1", "P2", "none"] as const) : pick(LABELS))];
    while (plan.length < steps) {
      const roll = rand();
      if (roll < 0.35) plan.push(P);
      else if (roll < 0.45) plan.push(R);
      else if (roll < 0.5) plan.push(s("new", pick(LABELS)));
      else plan.push(s(rand() < 0.5 ? "load" : "resume", rand() < 0.6 ? pick(["P1", "P2", "none"] as const) : pick(LABELS)));
    }
    plans.push({ name: `r${String(n + 1).padStart(2, "0")}-seed${seed}`, steps: plan });
  }
  return plans;
}

// ------------------------------------------------------------------ runs --

/// A session id that fx never created.
const UNKNOWN_ID = "1700000000000-1700000000000000000-00000000deadbeef";

const failed = (response: any) => response?.error ?? null;

async function runPlan(plan: Plan, dir: string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new Fixture(binary);
  const observations: Observation[] = [];
  let error: string | null = null;
  // Only what the driver needs to pick its next request; the model checks the rest.
  let sessionId: string | null = null;
  let open = false;
  let saved = false;
  const record = (op: string, arg: string, response: any, cap: boolean, sent: string) => {
    const err = failed(response);
    observations.push({ op, arg, ok: err === null, code: err === null ? 0 : Number(err.code), cap, sent, detail: err ? { error: err } : undefined });
    return err === null;
  };
  const restart = async () => {
    const response = await fixture.start();
    open = false;
    const cap = response?.result?.agentCapabilities?.sessionCapabilities?.systemPrompt !== undefined;
    record("restart", "none", response, cap, "none");
  };
  try {
    await fixture.init();
    await restart();
    for (const step of plan.steps) {
      const acp = fixture.acp!;
      if (step.op === "restart") {
        await restart();
      } else if (step.op === "prompt") {
        // A turn needs an open session.
        if (!open) continue;
        const before = fixture.gatewayBodies.length;
        const response = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "hello" }] });
        const bodies = fixture.gatewayBodies.slice(before);
        const ok = record("prompt", "none", response, false, bodies.length === 1 ? sentIn(bodies[0]) : `requests:${bodies.length}`);
        if (ok) saved = true;
      } else if (step.op === "new") {
        // One session at a time, as the model's A.
        if (open || saved) continue;
        const prompt = systemPrompt(step.arg);
        const response = await acp.call("session/new", { cwd: fixture.workspace, mcpServers: [], ...(prompt === undefined ? {} : { systemPrompt: prompt }) });
        if (record("new", step.arg, response, false, "none")) {
          sessionId = response.result.sessionId;
          open = true;
        }
      } else {
        const prompt = systemPrompt(step.arg);
        const method = step.op === "load" ? "session/load" : "session/resume";
        const response = await acp.call(method, {
          sessionId: sessionId ?? UNKNOWN_ID, cwd: fixture.workspace, mcpServers: [], ...(prompt === undefined ? {} : { systemPrompt: prompt }),
        });
        if (record(step.op, step.arg, response, false, "none")) open = true;
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.dispose();
  }
  writeJson(join(dir, "observations.json"), observations);
  writeFileSync(join(dir, "acp.jsonl"), fixture.acpLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeJson(join(dir, "gateway-bodies.json"), fixture.gatewayBodies.map((body) => body.slice(0, 20_000)));
  writeJson(join(dir, "processes.json"), fixture.processes);
  return { observations, processes: fixture.processes, error };
}

// ---------------------------------------------------------------- controls --

const step = (op: string, arg: string, ok: boolean, code: number, cap: boolean, sent: string): Observation => ({ op, arg, ok, code, cap, sent });

/// A run the model allows, with the answers that `fixed` selects.
function syntheticTrace(fixed: boolean): Observation[] {
  const first = fixed ? "P1" : "array";
  return [
    step("restart", "none", true, 0, true, "none"),
    step("new", fixed ? "array" : "P1", false, -32602, false, "none"),
    step("new", first, true, 0, false, "none"),
    step("prompt", "none", true, 0, false, first),
    step("load", "P2", true, 0, false, "none"),
    step("prompt", "none", true, 0, false, fixed ? "P2" : first),
    step("restart", "none", true, 0, true, "none"),
    step("resume", "none", true, 0, false, "none"),
    step("prompt", "none", true, 0, false, fixed ? "P2" : first),
  ];
}

/// Changes the latest turn's prompt, so the run stops matching the model.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 0; index -= 1) {
    const current = copy[index]!;
    if (current.op === "prompt") {
      current.sent = current.sent === "P1" ? "P2" : "P1";
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
  const seed = Number(argValue("--seed") ?? "20261107");
  const randomCount = Number(argValue("--random") ?? "10");
  const steps = Number(argValue("--steps") ?? "12");
  const only = argValue("--only");

  const reportDir = outDir(`acp-system-prompt-${model}`);
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
