// Runtime driver: runs the real `fx acp` binary through directed and
// seeded-random plans over two sessions in two workspaces: opens, prompts,
// tool writes, answers, cancels, closes, loads, and resumes. It records what
// a client observes after each step and asks TLC whether each run is a
// behavior of tests/tla/acp/AcpSessions.tla.
//
//   bun tests/tla/drivers/acp/sessions/driver.ts                 # after zig build
//   bun tests/tla/drivers/acp/sessions/driver.ts --model today   # fx before many sessions
//
// --model rules (the default) checks many sessions. --model today checks the
// model of fx before them; a build of #1786 at 13bb8f7a4, chosen with
// FX_WORKTREE or FX_BIN, fails --model rules. --random sets how many seeded
// plans run, --steps their length, --seed the seed, and --only a pattern of
// plan names. No model calls: every reply comes from a fake Gateway the
// driver holds.
import { existsSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, type Label, type Ws, finalTextOf, marker, waitFor } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Observation, validate } from "./trace";

// ------------------------------------------------------------------ plans --

type Step =
  | { op: "new"; ws: Ws }
  | { op: "prompt" | "write" | "finish" | "cancel" | "close"; s: Label }
  | { op: "load" | "resume"; s: Label; ws: Ws };
type Plan = { name: string; steps: Step[] };

const N = (ws: Ws): Step => ({ op: "new", ws });
const P = (s: Label): Step => ({ op: "prompt", s });
const W = (s: Label): Step => ({ op: "write", s });
const F = (s: Label): Step => ({ op: "finish", s });
const C = (s: Label): Step => ({ op: "cancel", s });
const X = (s: Label): Step => ({ op: "close", s });
const L = (s: Label, ws: Ws): Step => ({ op: "load", s, ws });
const R = (s: Label, ws: Ws): Step => ({ op: "resume", s, ws });

const MAX_PROMPTS = 3;

const DIRECTED: Plan[] = [
  // Two turns at once, each writing in its own workspace and answering on its own.
  { name: "d1-two-turns", steps: [N("W1"), N("W2"), P("A"), P("B"), W("A"), W("B"), F("B"), F("A")] },
  // A cancel stops one session's turn and the other runs on.
  { name: "d2-cancel-one", steps: [N("W1"), N("W1"), P("A"), P("B"), C("A"), F("B"), P("A"), F("A")] },
  // Load and resume reuse an open session while its turn runs; another workspace fails.
  { name: "d3-reuse", steps: [N("W1"), P("A"), F("A"), P("A"), L("A", "W1"), F("A"), R("A", "W1"), N("W2"), L("A", "W2"), X("B")] },
  // A closed session stops answering until a load opens it again, in a workspace of its own.
  { name: "d4-close-and-reopen", steps: [N("W1"), N("W2"), P("A"), X("A"), P("A"), P("B"), W("B"), F("B"), L("A", "W2"), P("A"), W("A"), F("A")] },
  // A prompt to a running session is busy; steps for an unopened session change nothing.
  { name: "d5-busy-and-unopened", steps: [N("W1"), P("A"), P("A"), C("B"), X("B"), F("A"), X("A"), X("A")] },
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

/// Seeded plans that take only steps the rules allow, tracked as the model
/// tracks them.
function randomPlans(count: number, steps: number, seed: number): Plan[] {
  const random = mulberry32(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  const plans: Plan[] = [];
  for (let n = 0; n < count; n += 1) {
    const plan: Step[] = [N(pick(["W1", "W2"]))];
    const open = new Set<Label>(["A"]);
    const ws: Record<Label, Ws | null> = { A: (plan[0] as any).ws, B: null };
    const running: Record<Label, number> = { A: 0, B: 0 };
    const sent: Record<Label, number> = { A: 0, B: 0 };
    const wrote = new Set<string>();
    const saved = new Set<Label>();
    let created = 1;
    let loads = 0;
    while (plan.length < steps) {
      const choices: Step[] = [];
      if (created < 2) choices.push(N(pick(["W1", "W2"])));
      for (const s of ["A", "B"] as const) {
        if (sent[s] < MAX_PROMPTS) choices.push(P(s));
        if (running[s]) {
          if (!wrote.has(`${s}${running[s]}`)) choices.push(W(s));
          choices.push(F(s), F(s));
        }
        choices.push(C(s), X(s));
        if (saved.has(s) && loads < 2) choices.push(pick([L(s, pick(["W1", "W2"])), R(s, pick(["W1", "W2"]))]));
      }
      const step = pick(choices);
      plan.push(step);
      switch (step.op) {
        case "new": { const s: Label = created === 1 ? "B" : "A"; created += 1; open.add(s); ws[s] = step.ws; break; }
        case "prompt": {
          sent[step.s] += 1;
          if (open.has(step.s) && !running[step.s]) { running[step.s] = sent[step.s]; saved.add(step.s); }
          break;
        }
        case "write": wrote.add(`${step.s}${running[step.s]}`); break;
        case "finish": running[step.s] = 0; break;
        case "cancel": if (open.has(step.s)) running[step.s] = 0; break;
        case "close": if (open.has(step.s)) { open.delete(step.s); running[step.s] = 0; } break;
        case "load": case "resume":
          loads += 1;
          if (!open.has(step.s)) { open.add(step.s); ws[step.s] = step.ws; }
          break;
      }
    }
    plans.push({ name: `r${String(n + 1).padStart(2, "0")}-seed${seed}`, steps: plan });
  }
  return plans;
}

// ------------------------------------------------------------------ runner --

const keyIndex = (s: Label, n: number) => (s === "A" ? 0 : MAX_PROMPTS) + n - 1;

function answerOf(message: any): string {
  if (message?.result?.stopReason) return message.result.stopReason;
  const code = message?.error?.code;
  if (code === -32600) return "busy";
  if (code === -32002) return "notfound";
  return `other:${code ?? "none"}`;
}

async function runPlan(plan: Plan, fxBin: string) {
  const fixture = new Fixture(fxBin);
  const observations: Observation[] = [];
  const answers: string[] = Array(2 * MAX_PROMPTS).fill("pending");
  const tags: Array<[[string, number], string]> = [];
  const writes: Array<[[string, number], string]> = [];
  const ids: Record<Label, string | null> = { A: null, B: null };
  const running: Record<Label, number> = { A: 0, B: 0 };
  const sent: Record<Label, number> = { A: 0, B: 0 };
  const answered = new Map<string, Promise<void>>();
  let created = 0;
  const idOf = (s: Label) => ids[s] ?? `never-opened-${s}`;
  const labelOf = (sessionId: string) => (sessionId === ids.A ? "A" : sessionId === ids.B ? "B" : "other");
  const record = (act: string, sid: string, ws: string, ok: boolean) =>
    observations.push({ act, sid, ws, ok, answers: [...answers], tags: [...tags], writes: [...writes] });
  record("init", "none", "none", true);
  let error: string | null = null;
  try {
    await fixture.init();
    const acp = await fixture.start();
    for (const step of plan.steps) {
      switch (step.op) {
        case "new": {
          const label: Label = created === 0 ? "A" : "B";
          created += 1;
          const response = await acp.request("session/new", { cwd: fixture.workspaces[step.ws], mcpServers: [] });
          if (!response.error) ids[label] = response.result.sessionId;
          record("new", label, step.ws, !response.error);
          break;
        }
        case "prompt": {
          const s = step.s;
          const n = (sent[s] += 1);
          const k = keyIndex(s, n);
          const reply = acp.request("session/prompt", { sessionId: idOf(s), prompt: [{ type: "text", text: marker(s, n) }] });
          answered.set(`${s}${n}`, reply.then((message) => { answers[k] = answerOf(message); }));
          await waitFor(`prompt ${s} ${n} to start or be answered`, () => answers[k] !== "pending" || fixture.openHold(s, n));
          if (answers[k] === "pending") running[s] = n;
          record("prompt", s, "none", true);
          break;
        }
        case "write": {
          const s = step.s;
          const n = running[s];
          const hold = fixture.openHold(s, n);
          if (!hold) throw new Error(`no model request to end for ${s} ${n}`);
          hold.end("write");
          await waitFor(`the request after ${s} ${n}'s write`, () => fixture.openHold(s, n));
          writes.push([[s, n], fixture.writeLocation(s, n)]);
          record("write", s, "none", true);
          break;
        }
        case "finish": {
          const s = step.s;
          const n = running[s];
          const hold = fixture.openHold(s, n);
          if (!hold) throw new Error(`no model request to end for ${s} ${n}`);
          hold.end("final");
          await answered.get(`${s}${n}`);
          const final = answers[keyIndex(s, n)];
          answers[keyIndex(s, n)] = "pending";
          const sessions = new Set(
            acp.notifications
              .filter((note) => note.method === "session/update" && note.params?.update?.sessionUpdate === "agent_message_chunk")
              .filter((note) => JSON.stringify(note.params.update).includes(finalTextOf(s, n)))
              .map((note) => labelOf(note.params.sessionId)),
          );
          tags.push([[s, n], sessions.size === 1 ? [...sessions][0]! : sessions.size === 0 ? "none" : "mixed"]);
          record("stream", s, "none", true);
          answers[keyIndex(s, n)] = final!;
          running[s] = 0;
          record("finish", s, "none", true);
          break;
        }
        case "cancel": {
          const s = step.s;
          acp.notify("session/cancel", { sessionId: idOf(s) });
          if (running[s]) {
            await answered.get(`${s}${running[s]}`);
            running[s] = 0;
          } else {
            await Bun.sleep(100);
          }
          record("cancel", s, "none", true);
          break;
        }
        case "close": {
          const s = step.s;
          const response = await acp.request("session/close", { sessionId: idOf(s) });
          if (running[s]) {
            await answered.get(`${s}${running[s]}`);
            running[s] = 0;
          }
          record("close", s, "none", !response.error);
          break;
        }
        case "load":
        case "resume": {
          const s = step.s;
          const response = await acp.request(`session/${step.op}`, { sessionId: idOf(s), cwd: fixture.workspaces[step.ws], mcpServers: [] });
          record(step.op, s, step.ws, !response.error);
          break;
        }
      }
    }
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  } finally {
    await fixture.dispose();
  }
  const loads = plan.steps.filter((step) => step.op === "load" || step.op === "resume").length;
  return { observations, error, processes: fixture.processes, loads, acpLog: fixture.acpLog };
}

// ---------------------------------------------------------------- controls --

/// Moves the first update's tag to the other session, so the run stops
/// matching the model.
function tamper(observations: Observation[]): Observation[] | null {
  const copy: Observation[] = structuredClone(observations);
  const at = copy.findIndex((o) => o.tags.length > 0);
  if (at === -1) return null;
  for (const o of copy.slice(at)) {
    const [k, tag] = o.tags[0]!;
    o.tags[0] = [k, tag === "A" ? "B" : "A"];
  }
  return copy;
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
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const rules = model === "rules";
  const seed = Number(argValue("--seed") ?? "20261112");
  const randomCount = Number(argValue("--random") ?? "8");
  const steps = Number(argValue("--steps") ?? "12");
  const only = argValue("--only");

  const reportDir = outDir(`acp-sessions-${model}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, seed, randomCount, steps, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const plans = [...DIRECTED, ...randomPlans(randomCount, steps, seed)].filter((plan) => !only || new RegExp(only).test(plan.name));
  const results = [];
  let firstAccepted: Observation[] | null = null;
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, binary);
    writeJson(join(dir, "observations.json"), run.observations);
    writeJson(join(dir, "acp-log.json"), run.acpLog);
    const processFailed = run.processes.some((proc) => proc.exit !== 0);
    const checked = run.error ? null : await validate(run.observations, dir, rules, MAX_PROMPTS, Math.max(run.loads, 1));
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : checked!.verdict;
    if (verdict === "ACCEPTED" && !firstAccepted) firstAccepted = run.observations;
    results.push({ name: plan.name, verdict, steps: run.observations.length, error: run.error, firstDivergence: checked?.firstDivergence ?? null, processes: run.processes.map((proc) => proc.exit) });
    const divergence = checked?.firstDivergence;
    const where = divergence ? ` first divergence at step ${divergence.step}: ${JSON.stringify(divergence.observation && { act: divergence.observation.act, sid: divergence.observation.sid })}` : "";
    console.log(`${plan.name}: ${verdict} (${run.observations.length} steps)${run.error ? ` ${run.error}` : where}`);
  }

  // Controls show the checker separates runs the model allows from runs it doesn't.
  const controls = [];
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), rules, MAX_PROMPTS, 1)).verdict });
  if (firstAccepted) {
    const tampered = tamper(firstAccepted);
    if (tampered) controls.push({ name: "tampered-tag", expect: "REJECTED", got: (await validate(tampered, join(reportDir, "controls", "tampered-tag"), rules, MAX_PROMPTS, 2)).verdict });
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.every((control) => control.got === control.expect) && controls.length === 2;
  writeJson(join(reportDir, "summary.json"), { manifest, counts, controlsPassed, controls, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "pass" : "FAIL"}`);
  console.log(`report: ${reportDir}`);
  if (!controlsPassed || results.some((result) => result.verdict !== "ACCEPTED")) process.exit(1);
}

await main();
