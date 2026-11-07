// Runtime driver: runs the real `fx acp` binary through plans of prompts,
// steers, queued prompts, tool calls and stops while a turn runs, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpPromptDelivery.tla.
//
//   bun tests/tla/drivers/acp/prompt_delivery/driver.ts                 # after zig build
//   bun tests/tla/drivers/acp/prompt_delivery/driver.ts --model rules   # the baseline
//
// The sh.fx rules have not landed in src/acp/ yet. --model today (the
// default) checks fx's ACP path now, which sends a steer with
// `_meta.fx.steer`; every plan must match it. --model rules checks the sh.fx
// rules against the same build, and the plans that exercise a rule today's
// path breaks must fail it. --next sends `_meta["sh.fx/delivery"]` instead,
// for the change that lands the rules, which removes this flag.
//
// The fake Gateway holds every model reply after its first text piece until
// the driver ends it, with a shell tool call that waits for the driver or with
// final text, so each prompt arrives in a known phase of the turn. No model
// calls.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, waitFor } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Answer, type Bounds, NO_ANSWER, type Observation, validate } from "./trace";

// ------------------------------------------------------------------ plans --

/// P and M are plain prompts, S1 and S2 steers, I a steer with an image, and
/// Q1 and Q2 queued prompts, as in the model.
type Label = "P" | "M" | "S1" | "S2" | "I" | "Q1" | "Q2";
type Step =
  | { op: "send"; msg: Label }   // a prompt while no turn runs starts one; otherwise it arrives mid-turn
  | { op: "tool" }               // the held reply ends with a tool call, which runs
  | { op: "tool_end" }           // the tool ends, and the turn's next request arrives
  | { op: "final" }              // the held reply ends with final text, and the turn ends
  | { op: "cancel" };            // session/cancel
type Plan = { name: string; steps: Step[] };

const send = (msg: Label): Step => ({ op: "send", msg });
const TOOL: Step = { op: "tool" };
const TOOL_END: Step = { op: "tool_end" };
const FINAL: Step = { op: "final" };
const CANCEL: Step = { op: "cancel" };

const PLANS: Plan[] = [
  { name: "t1-steer-joins-after-tool", steps: [send("P"), send("S1"), TOOL, TOOL_END, FINAL] },
  { name: "t2-steer-continues-at-reply-end", steps: [send("P"), send("S1"), FINAL] },
  { name: "t3-stop-during-tool", steps: [send("P"), TOOL, send("S1"), CANCEL] },
  { name: "t4-refusals", steps: [send("P"), send("M"), send("I"), send("Q1"), FINAL] },
  { name: "t5-two-steers", steps: [send("P"), send("S1"), TOOL, send("S2"), TOOL_END, FINAL] },
  { name: "t6-steer-starts-a-turn", steps: [send("S1"), send("Q1"), FINAL] },
  { name: "t7-stop-while-streaming", steps: [send("P"), send("S1"), CANCEL] },
  { name: "t8-second-turn", steps: [send("P"), FINAL, send("Q1"), send("S1"), TOOL, TOOL_END, FINAL] },
];

const KIND: Record<Label, "plain" | "steer" | "queue"> = { P: "plain", M: "plain", S1: "steer", S2: "steer", I: "steer", Q1: "queue", Q2: "queue" };
const marker = (label: string) => `${label}-mk7`;

function promptParams(sessionId: string, label: Label, next: boolean): Record<string, unknown> {
  const prompt = label === "I"
    ? [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]
    : [{ type: "text", text: `${marker(label)} please` }];
  const kind = KIND[label];
  const meta = kind === "plain" ? undefined
    : next ? { "sh.fx/delivery": kind }
    : kind === "steer" ? { fx: { steer: true } }
    // Today fx doesn't know a queued delivery, so this is a prompt during a turn.
    : { "sh.fx/delivery": "queue" };
  return { sessionId, prompt, ...(meta ? { _meta: meta } : {}) };
}

function answerOf(response: any, next: boolean): Answer {
  if (response?.error) return { kind: "err", stop: "", delivery: "", code: Number(response.error.code) };
  const meta = response?.result?._meta ?? {};
  const delivery = (next ? meta["sh.fx/steeringDelivery"] : meta?.fx?.steering) ?? "none";
  return { kind: "ok", stop: String(response?.result?.stopReason ?? ""), delivery: String(delivery), code: 0 };
}

// ------------------------------------------------------------------ runs --

async function runPlan(plan: Plan, dir: string, next: boolean) {
  mkdirSync(dir, { recursive: true });
  const fixture = new Fixture(binary);
  const observations: Observation[] = [];
  const answers: Record<string, Answer> = {};
  const outstanding = new Map<string, Promise<void>>();
  const finished = new Set<string>();   // labels of turns that have ended
  let running = false;
  let holdIndex = 0;                    // the held reply of the running request
  let error: string | null = null;

  const observe = (act: string, msg = "none", check: { answers?: boolean; ctx?: string[] } = {}) => {
    observations.push({
      act, msg, checkAnswers: check.answers ?? false, answers: structuredClone(answers),
      checkCtx: check.ctx !== undefined, ctx: check.ctx ?? [],
    });
  };
  /// The prompts the latest model request holds for the running turn.
  const currentCtx = () => {
    const body = fixture.holds[holdIndex - 1]?.body ?? "";
    return (Object.keys(KIND) as Label[]).filter((label) => body.includes(marker(label)) && !finished.has(label));
  };
  const waitForRequest = async (count: number) => {
    await waitFor(`model request ${count}`, () => fixture.holds.length >= count);
    holdIndex = count;
  };
  /// Waits for every prompt still open to get its answer.
  const settle = async () => {
    const open = [...outstanding.keys()];
    const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`no answer within 30 s for ${open.filter((label) => answers[label] === undefined).join(", ")}`)), 30_000));
    await Promise.race([Promise.all([...outstanding.values()]), timeout]);
    outstanding.clear();
  };

  try {
    await fixture.init();
    const acp = await fixture.start();
    const created = await acp.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
    const sessionId = created.result?.sessionId;
    if (typeof sessionId !== "string") throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);

    for (const step of plan.steps) {
      if (step.op === "send") {
        const label = step.msg;
        const queuedBefore = fixture.queuedSteers();
        let settled = false;
        const pending = acp.request("session/prompt", promptParams(sessionId, label, next)).then((response) => {
          answers[label] = answerOf(response, next);
          settled = true;
        });
        outstanding.set(label, pending);
        if (!running) {
          // No turn runs: the prompt starts one.
          await waitForRequest(fixture.holds.length + 1);
          running = true;
          observe("send", label, { answers: true, ctx: currentCtx() });
        } else {
          // Mid-turn: fx either answers at once or queues the steer. The turn
          // holds what its latest model request holds: today a steer joins
          // only the turn's next request.
          await waitFor(`fx to take ${label}`, () => settled || fixture.queuedSteers() > queuedBefore);
          if (settled) outstanding.delete(label);
          observe("send", label, { answers: true, ctx: currentCtx() });
        }
      } else if (step.op === "tool") {
        fixture.holds[holdIndex - 1]!.end("tool");
        const files = fixture.toolFiles(fixture.toolCount);
        await waitFor("the tool to start", () => existsSync(files.started));
        observe("stream_end");
        observe("tool_call");
      } else if (step.op === "tool_end") {
        writeFileSync(fixture.toolFiles(fixture.toolCount).go, "");
        await waitForRequest(fixture.holds.length + 1);
        observe("tool_end", "none", { ctx: currentCtx() });
      } else if (step.op === "final") {
        // End the held reply with final text. If steers wait, fx goes on with
        // them in a new request of the same turn, which this step ends too.
        for (let round = 1; ; round += 1) {
          if (round > 5) throw new Error("the turn kept going after 5 final replies");
          const requests = fixture.holds.length;
          const ctx = currentCtx();
          fixture.holds[holdIndex - 1]!.end("final");
          const outcome = await waitFor("the turn to end or go on", () =>
            fixture.holds.length > requests ? "continued" : [...outstanding.keys()].every((label) => answers[label] !== undefined) ? "ended" : null);
          observe("stream_end");
          if (outcome === "continued") {
            await waitForRequest(requests + 1);
            observe("reply_end", "none", { ctx: currentCtx() });
            continue;
          }
          outstanding.clear();
          running = false;
          for (const label of ctx) finished.add(label);
          observe("reply_end");
          observe("stop_input");
          observe("finish", "none", { answers: true });
          break;
        }
      } else {
        const ctx = currentCtx();
        acp.notify("session/cancel", { sessionId });
        await settle();
        running = false;
        for (const label of ctx) finished.add(label);
        observe("cancel", "none", { answers: true });
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.dispose();
  }
  writeJson(join(dir, "observations.json"), observations);
  writeFileSync(join(dir, "acp.jsonl"), fixture.acpLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeJson(join(dir, "model-requests.json"), fixture.holds.map((hold) => ({ aborted: hold.aborted, body: hold.body.slice(0, 20_000) })));
  writeJson(join(dir, "processes.json"), fixture.processes);
  return { observations, processes: fixture.processes, error };
}

function boundsOf(plan: Plan, rules: boolean): Bounds {
  const msgs = [...new Set(["P", ...plan.steps.flatMap((step) => (step.op === "send" ? [step.msg] : []))])];
  return {
    rules,
    msgs,
    maxTools: plan.steps.filter((step) => step.op === "tool").length,
    maxCancels: plan.steps.filter((step) => step.op === "cancel").length,
  };
}

// ---------------------------------------------------------------- controls --

const ok = (stop: string, delivery: string): Answer => ({ kind: "ok", stop, delivery, code: 0 });
const err = (code: number): Answer => ({ kind: "err", stop: "", delivery: "", code });

/// t2 as fx's ACP path runs it today: the steer waiting at the reply's end joins
/// the turn's next request.
function syntheticTrace(): Observation[] {
  const step = (act: string, msg: string, answers: Record<string, Answer> | null, ctx: string[] | null): Observation => ({
    act, msg, checkAnswers: answers !== null, answers: answers ?? {}, checkCtx: ctx !== null, ctx: ctx ?? [],
  });
  return [
    step("send", "P", {}, ["P"]),
    step("send", "S1", {}, null),
    step("stream_end", "none", null, null),
    step("reply_end", "none", null, ["P", "S1"]),
    step("stream_end", "none", null, null),
    step("reply_end", "none", null, null),
    step("stop_input", "none", null, null),
    step("finish", "none", { P: ok("end_turn", "none"), S1: ok("end_turn", "absorbed") }, null),
  ];
}

/// Changes the latest checked answer, so the run stops matching the model.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 0; index -= 1) {
    const current = copy[index]!;
    if (current.checkAnswers && Object.keys(current.answers).length > 0) {
      const label = Object.keys(current.answers)[0]!;
      const before = current.answers[label] ?? NO_ANSWER;
      current.answers[label] = before.kind === "err" ? ok("end_turn", "absorbed") : err(-32600);
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
  const model = argValue("--model") ?? "today";
  if (model !== "today" && model !== "rules") throw new Error(`--model must be today or rules, not ${model}`);
  const rules = model === "rules";
  const next = process.argv.includes("--next");
  const only = argValue("--only");

  const reportDir = outDir(`acp-prompt-delivery-${model}${next ? "-next" : ""}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, next, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const plans = PLANS.filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, dir, next);
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, boundsOf(plan, rules));
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    results.push({ name: plan.name, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, processes: run.processes.map((proc) => proc.exit) });
    const divergence = checked?.firstDivergence;
    const where = divergence ? ` first divergence at step ${divergence.step}: ${JSON.stringify({ act: divergence.observation?.act, msg: divergence.observation?.msg, answers: divergence.observation?.checkAnswers ? divergence.observation.answers : undefined, ctx: divergence.observation?.checkCtx ? divergence.observation.ctx : undefined })}` : "";
    console.log(`${plan.name}: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the checker separates runs the model allows from runs it doesn't.
  const controls = [];
  if (!rules) {
    const synthetic = syntheticTrace();
    const bounds: Bounds = { rules: false, msgs: ["P", "S1"], maxTools: 0, maxCancels: 0 };
    controls.push({ name: "synthetic-conforming", expect: "ACCEPTED", got: (await validate(synthetic, join(reportDir, "controls", "synthetic-conforming"), bounds)).verdict });
    controls.push({ name: "synthetic-tampered", expect: "REJECTED", got: (await validate(tamper(synthetic)!, join(reportDir, "controls", "synthetic-tampered"), bounds)).verdict });
  }
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), { rules, msgs: ["P"], maxTools: 0, maxCancels: 0 })).verdict });
  const firstAccepted = results.find((result) => result.verdict === "ACCEPTED");
  if (firstAccepted) {
    const plan = PLANS.find((candidate) => candidate.name === firstAccepted.name)!;
    const observed = (await Bun.file(join(reportDir, "traces", firstAccepted.name, "observations.json")).json()) as Observation[];
    const tampered = tamper(observed);
    if (tampered) controls.push({ name: `tampered-${firstAccepted.name}`, expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", `tampered-${firstAccepted.name}`), boundsOf(plan, rules))).verdict });
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
