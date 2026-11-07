// Runtime driver: runs the real `fx acp` binary through plans of sessions,
// turns, session/list, and session/status on one connection, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpSessionState.tla.
//
//   bun tests/tla/drivers/acp/session_state/driver.ts                 # after zig build
//   bun tests/tla/drivers/acp/session_state/driver.ts --model rules   # the baseline
//
// The sh.fx rules have not landed in src/acp/ yet. --model today (the
// default) checks fx's ACP path now, and every plan must match it.
// --model rules checks the sh.fx rules against the same build, and each plan
// must fail it. The change that lands the rules makes rules the default.
//
// The client lists sh.fx/sessionState and sh.fx/listChanges at initialize,
// which today's fx ignores. The fake Gateway holds each model reply until the
// driver ends it, so a list or status request arrives while the turn runs.
// No model calls.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, waitFor } from "../prompt_delivery/harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Bounds, type Observation, type StatusAnswer, validate } from "./trace";

// ------------------------------------------------------------------ plans --

type Step =
  | { op: "new"; s: string }          // session/new
  | { op: "prompt"; s: string }       // session/prompt, held at its first model reply
  | { op: "end"; s: string }          // the held reply ends, and the turn ends
  | { op: "cancel"; s: string }       // session/cancel
  | { op: "close"; s: string }        // session/close
  | { op: "list"; f: "A" | "*" }      // session/list of the workspace, or of every folder
  | { op: "status"; s: string };      // session/status
type Plan = { name: string; steps: Step[] };

const PLANS: Plan[] = [
  { name: "d1-list-during-turn", steps: [
    { op: "new", s: "s1" }, { op: "status", s: "s1" }, { op: "prompt", s: "s1" },
    { op: "list", f: "A" }, { op: "status", s: "s1" }, { op: "end", s: "s1" },
    { op: "list", f: "A" }, { op: "status", s: "s1" },
  ] },
  { name: "d2-two-sessions", steps: [
    { op: "new", s: "s1" }, { op: "prompt", s: "s1" }, { op: "end", s: "s1" },
    { op: "new", s: "s2" }, { op: "list", f: "*" }, { op: "prompt", s: "s2" },
    { op: "list", f: "*" }, { op: "cancel", s: "s2" }, { op: "list", f: "A" },
  ] },
  { name: "d3-close-then-status", steps: [
    { op: "new", s: "s1" }, { op: "prompt", s: "s1" }, { op: "end", s: "s1" },
    { op: "close", s: "s1" }, { op: "status", s: "s1" }, { op: "list", f: "A" },
  ] },
];

const STATE_METHOD = "_sh.fx/session/state_update";
const HINT_METHOD = "_sh.fx/session/list_changed";

function statusOf(response: any): StatusAnswer {
  const none = { status: "none", state: "none" };
  if (response?.error) {
    const code = Number(response.error.code);
    if (code === -32601) return { kind: "no_method", ...none };
    if (code === -32600) return { kind: "busy", ...none };
    if (code === -32002) return { kind: "unknown", ...none };
    return { kind: "none", status: `error ${code}`, state: "none" };
  }
  const result = response?.result ?? {};
  return { kind: "ok", status: String(result.status ?? "none"), state: String(result._meta?.["sh.fx/state"] ?? "none") };
}

// ------------------------------------------------------------------ runs --

async function runPlan(plan: Plan, dir: string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new Fixture(binary);
  const observations: Observation[] = [];
  const ids = new Map<string, string>();     // model name -> sessionId
  const prompts = new Map<string, Promise<any>>();
  let holdIndex = 0;
  let error: string | null = null;

  const base = (act: Observation["act"], extra: Partial<Observation> = {}): Observation => ({
    act, s: "none", stop: "none", f: "none", refused: false, rows: {},
    answer: { kind: "none", status: "none", state: "none" }, states: 0, hints: 0, ...extra,
  });
  /// After fx answers, every notification it wrote before the answer has arrived.
  const sync = () => {
    const methods = fixture.acp!.notifications.map((n) => n.method);
    observations.push(base("sync", {
      states: methods.filter((m) => m === STATE_METHOD).length,
      hints: methods.filter((m) => m === HINT_METHOD).length,
    }));
  };
  const nameOf = (sessionId: string) => [...ids.entries()].find(([, id]) => id === sessionId)?.[0];

  try {
    await fixture.init();
    const acp = await fixture.start({
      protocolVersion: 1,
      clientCapabilities: { _meta: { "sh.fx/sessionState": {}, "sh.fx/listChanges": {} } },
    });
    for (const step of plan.steps) {
      if (step.op === "new") {
        const created = await acp.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
        const sessionId = created.result?.sessionId;
        if (typeof sessionId !== "string") throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
        ids.set(step.s, sessionId);
        observations.push(base("open", { s: step.s }));
        sync();
      } else if (step.op === "prompt") {
        const requests = fixture.holds.length;
        prompts.set(step.s, acp.request("session/prompt", { sessionId: ids.get(step.s)!, prompt: [{ type: "text", text: "work" }] }));
        await waitFor("the turn's model request", () => fixture.holds.length > requests);
        holdIndex = fixture.holds.length;
        observations.push(base("prompt", { s: step.s }));
      } else if (step.op === "end" || step.op === "cancel") {
        if (step.op === "end") fixture.holds[holdIndex - 1]!.end("final");
        else acp.notify("session/cancel", { sessionId: ids.get(step.s)! });
        const response = await Promise.race([
          prompts.get(step.s)!,
          Bun.sleep(30_000).then(() => { throw new Error(`no answer to the prompt of ${step.s}`); }),
        ]);
        const stop = String(response?.result?.stopReason ?? "none");
        observations.push(base("end", { s: step.s, stop }));
        sync();
      } else if (step.op === "close") {
        const closed = await acp.request("session/close", { sessionId: ids.get(step.s)! });
        if (closed.error) throw new Error(`session/close failed: ${JSON.stringify(closed.error)}`);
        observations.push(base("close", { s: step.s }));
        sync();
      } else if (step.op === "list") {
        const response = await acp.request("session/list", step.f === "A" ? { cwd: fixture.workspace } : {});
        const refused = response?.error?.code === -32600;
        if (response?.error && !refused) throw new Error(`session/list failed: ${JSON.stringify(response.error)}`);
        const rows: Record<string, string> = Object.fromEntries([...ids.keys()].map((name) => [name, "absent"]));
        for (const row of response?.result?.sessions ?? []) {
          const name = nameOf(row.sessionId);
          if (name) rows[name] = String(row._meta?.["sh.fx/state"] ?? "none");
        }
        observations.push(base("list", { f: step.f, refused, rows }));
        sync();
      } else {
        const response = await acp.request("session/status", { sessionId: ids.get(step.s)! });
        observations.push(base("status", { s: step.s, answer: statusOf(response) }));
        sync();
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.dispose();
  }
  writeJson(join(dir, "observations.json"), observations);
  writeFileSync(join(dir, "acp.jsonl"), fixture.acpLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  writeJson(join(dir, "processes.json"), fixture.processes);
  return { observations, processes: fixture.processes, error, sessions: [...ids.keys()] };
}

// ---------------------------------------------------------------- controls --

/// Changes the latest list or status observation, so the run stops matching.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  for (let index = copy.length - 1; index >= 0; index -= 1) {
    const current = copy[index]!;
    if (current.act === "list") {
      current.refused = !current.refused;
      return copy;
    }
    if (current.act === "status") {
      current.answer = { ...current.answer, kind: current.answer.kind === "busy" ? "no_method" : "busy" };
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
  const only = argValue("--only");

  const reportDir = outDir(`acp-session-state-${model}`);
  const status = git("status", "--porcelain");
  writeJson(join(reportDir, "manifest.json"), {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, argv: process.argv.slice(1),
  });

  const plans = PLANS.filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, dir);
    const bounds: Bounds = { rules, sessions: run.sessions, maxTurns: plan.steps.filter((step) => step.op === "prompt").length };
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, bounds);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    results.push({ name: plan.name, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, bounds });
    const divergence = checked?.firstDivergence;
    const where = divergence ? ` first divergence at step ${divergence.step}: ${JSON.stringify(divergence.observation)}` : "";
    console.log(`${plan.name}: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the checker separates runs the model allows from runs it doesn't.
  const controls = [];
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), { rules, sessions: ["s1"], maxTurns: 0 })).verdict });
  const firstAccepted = results.find((result) => result.verdict === "ACCEPTED");
  if (firstAccepted) {
    const observed = (await Bun.file(join(reportDir, "traces", firstAccepted.name, "observations.json")).json()) as Observation[];
    const tampered = tamper(observed);
    if (tampered) controls.push({ name: `tampered-${firstAccepted.name}`, expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", `tampered-${firstAccepted.name}`), firstAccepted.bounds)).verdict });
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.every((control) => control.got === control.expect);
  writeJson(join(reportDir, "summary.json"), { model, counts, controlsPassed, controls, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "passed" : "FAILED"}`);
  console.log(`report: ${reportDir}`);
  process.exit(controlsPassed && results.every((result) => result.verdict === "ACCEPTED") ? 0 : 1);
}

await main();
