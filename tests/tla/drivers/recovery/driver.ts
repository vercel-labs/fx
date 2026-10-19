// Walks fx's request-recovery module (src/core/recovery/recovery.zig) along
// its model, tests/tla/recovery/Recovery.tla.
//
// TLC writes the model's state graph, with and without Fast. The driver walks
// to every edge of each graph along a shortest path, so every model
// transition is checked at least once, and then follows seeded random paths.
// Each model step becomes operations on lab.zig, which runs the real module
// and plays fx's part around it. After every step the module's state, its
// plan, the status it shows, and the saved record must match the model's next
// state. Steps that are fx's alone (the world, the wire, fx's own stop)
// change only what the lab keeps around the module; at fx's stop the driver
// also asks a copy of the module whether its next send would differ.
//
// Torn records are skipped unless --next is given: the model counts a torn
// record as one abrupt death, and recovery.zig still starts fresh from one,
// so --next fails until recovery.zig takes that rule.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/recovery/driver.ts
//   bun tests/tla/drivers/recovery/driver.ts --self-check
//   bun tests/tla/drivers/recovery/driver.ts --next
//   bun tests/tla/drivers/recovery/driver.ts --walks 1000 --steps 80 --seed 7
//
// Exit codes: 0 every walk matched, 1 a mismatch (or a self-check that was
// not rejected), 2 a toolchain or build failure.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Op = Record<string, unknown>;
type Result = {
  plan: { save: boolean; send: { compact: boolean; no_fast: boolean } | null; status: { kind: string; need: string | null } | null; finish: string | null } | null;
  state: { phase: string; need: string | null; attempt: number; deaths: number; no_fast: boolean; compacted: boolean; clean: boolean; streak: number; streak_kind: string | null; flowing: boolean };
  disk: { ph: string; clean: boolean; deaths: number; need: string | null; no_fast: boolean; compacted: boolean; streak: number; streak_kind: string | null } | null;
  pending: boolean;
  differs: boolean | null;
  error: string | null;
};
type Step = { label: string; from: string; to: string; ops: Op[] };
type Walk = { fast: boolean; steps: Step[] };

const EscalateAfter = 3; // recovery.zig escalate_after
const CrashLoopAfter = 2; // recovery.zig crash_loop_after
const RepeatStop = 3; // request_recovery.zig repeat_stop_sends
const Active = new Set(["working", "waiting", "need_user"]);

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

const options = {
  next: flag("--next"),
  selfCheck: flag("--self-check"),
  walks: option("--walks", 300),
  steps: option("--steps", 60),
  seed: option("--seed", 1),
  faults: option("--faults", 2),
};

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

// mulberry32: small, seedable, and the same in every runtime.
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

function buildLab(moduleSource: string, out: string, name: string): string {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "recovery",
      `-Mroot=${join(TLA_ROOT, "drivers", "recovery", "lab.zig")}`, `-Mrecovery=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string, fast: boolean): Promise<Graph> {
  const dir = join(out, `graph-${fast ? "fast" : "standard"}`);
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    MaxFaults = ${options.faults}`,
    `    Fast = ${fast ? "TRUE" : "FALSE"}`, `    Bug = "none"`, ""].join("\n");
  const { mkdirSync } = await import("node:fs");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "Recovery", "Driver.cfg", ["Recovery.tla"], join(TLA_ROOT, "recovery"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on Recovery.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
  const dot = readFileSync(join(dir, "graph.dot"), "utf8");
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  let init = "";
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to, label] = edge;
      if (!next.has(from!)) next.set(from!, []);
      next.get(from!)!.push({ to: to!, label: label! });
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const [, id, label, rest] = node;
    const state: Model = {};
    for (const entry of unescape(label!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(id!, state);
    if (/style\s*=\s*filled/.test(rest!)) init = id!;
  }
  if (!init) fail(2, "the graph has no initial state");
  console.log(`graph Fast=${fast}: ${states.size} states, ${run.durationMs} ms`);
  return { states, next, init };
}

// The operations one model step becomes.
function opsFor(label: string, s: Model, t: Model, fast: boolean): Op[] {
  switch (label) {
    case "Sync": return [{ op: "sync" }];
    case "Responding": return [{ op: "event", name: "responding" }];
    case "RespondOk": return [{ op: "event", name: "succeeded" }];
    case "RespondOffline": return [{ op: "failed", kind: "offline" }];
    case "RespondServer": return [{ op: "failed", kind: "server" }];
    case "Drop": case "StaleSocket": return [{ op: "failed", kind: "dropped" }];
    case "RespondNeedUser": return [{ op: "failed", kind: "sign_in" }];
    case "RespondTooLong": return [{ op: "failed", kind: "too_long" }];
    case "RespondUnclear": {
      const probe = { op: "probe", kind: s.unclear, times: EscalateAfter };
      return t.phase === "fx_stopped" ? [probe, { op: "fx_end" }] : [probe, { op: "failed", kind: s.unclear }];
    }
    case "TerminalFail": return [{ op: "fx_end" }];
    case "TimerFires": return [{ op: "wait" }];
    case "Crash": {
      const kept = canonical(t.disk) === canonical(s.disk);
      return [{ op: "crash", disk: kept ? "keep" : t.disk.ph === "torn" ? "torn" : "write" }];
    }
    case "Closing": return [{ op: "event", name: "closing" }];
    case "ExitClean": case "ExitAfterEnd": return [{ op: "exit" }];
    case "Relaunch": return [{ op: "start", fast, resume: true }];
    case "UserCancels": return [{ op: "event", name: "user_cancel" }];
    case "UserActs": return [{ op: "event", name: "user_continue" }];
    case "LateOutcome": return [{ op: "late" }];
    // The wire and the world: nothing reaches the module.
    case "SendOut": case "NetDown": case "NetUp": case "GatewayBreak": case "GatewayHeal":
    case "UnclearBreak": case "UnclearHeal": case "NeedUserFault": case "TooLongFault":
      return [];
    default:
      throw new Error(`no mapping for model action ${label}`);
  }
}

// Each walk picks among the possible next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such as
// a close or an unclear failure are exercised as often as Esc.
function makeWalks(graph: Graph, fast: boolean, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  const taken = new Map<string, number>();
  for (let w = 0; w < options.walks; w += 1) {
    const steps: Step[] = [{ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk" }, { op: "start", fast, resume: false }] }];
    let at = graph.init;
    for (let i = 0; i < options.steps; i += 1) {
      const s = graph.states.get(at)!;
      const edges = (graph.next.get(at) ?? []).filter((edge) => {
        if (edge.to === at) return false;
        const t = graph.states.get(edge.to)!;
        return options.next || t.disk.ph !== "torn";
      });
      if (edges.length === 0) break;
      const weights = edges.map((candidate) => 1 / (1 + (taken.get(candidate.label) ?? 0)));
      let pick = random() * weights.reduce((sum, weight) => sum + weight, 0);
      let edge = edges[edges.length - 1]!;
      for (let k = 0; k < edges.length; k += 1) {
        pick -= weights[k]!;
        if (pick < 0) { edge = edges[k]!; break; }
      }
      taken.set(edge.label, (taken.get(edge.label) ?? 0) + 1);
      const t = graph.states.get(edge.to)!;
      steps.push({ label: edge.label, from: at, to: edge.to, ops: opsFor(edge.label, s, t, fast) });
      at = edge.to;
    }
    walks.push({ fast, steps });
  }
  return walks;
}

// One walk per edge of the graph: the shortest path from the initial state to
// the edge's source, then the edge. Every model transition is checked against
// the module at least once.
function edgeWalks(graph: Graph, fast: boolean): Walk[] {
  const allowed = (id: string) => options.next || graph.states.get(id)!.disk.ph !== "torn";
  const parent = new Map<string, { from: string; label: string } | null>([[graph.init, null]]);
  const queue = [graph.init];
  for (let at = 0; at < queue.length; at += 1) {
    const id = queue[at]!;
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id || parent.has(edge.to) || !allowed(edge.to)) continue;
      parent.set(edge.to, { from: id, label: edge.label });
      queue.push(edge.to);
    }
  }
  const walks: Walk[] = [];
  for (const id of queue) {
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id || !allowed(edge.to)) continue;
      const hops: { from: string; to: string; label: string }[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      const steps: Step[] = [{ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk" }, { op: "start", fast, resume: false }] }];
      for (const hop of hops) {
        steps.push({ ...hop, ops: opsFor(hop.label, graph.states.get(hop.from)!, graph.states.get(hop.to)!, fast) });
      }
      walks.push({ fast, steps });
    }
  }
  return walks;
}

function runLab(bin: string, walks: Walk[], out: string, name: string): Result[] {
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  const lines: string[] = [];
  for (const walk of walks) for (const step of walk.steps) for (const op of step.ops) lines.push(JSON.stringify(op));
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Result);
  if (results.length !== lines.length) fail(2, `${name} answered ${results.length} of ${lines.length} operations`);
  return results;
}

// The refinement mapping: what the model's next state says the real module,
// its plan, the screen, and the saved record must look like.
const needOf = (need: string | null) => (need === null ? "none" : need === "crash_loop" ? "crash_loop" : "user");
const kindOf = (kind: string | null) => (kind === null ? "none" : kind);
const phaseOf = (phase: string, tamper: boolean) =>
  ({ sending: "working", waiting: tamper ? "retrying" : "waiting", need_user: "need_user", idle: "idle" })[phase] ?? phase;

function diskOf(disk: Result["disk"]): Model {
  if (disk === null) return { ph: "none", clean: false, deaths: 0, need: "none", noFast: false, compacted: false, streak: 0, streakKind: "none" };
  if (disk.ph === "torn") return { ph: "torn", clean: false, deaths: 0, need: "none", noFast: false, compacted: false, streak: 0, streakKind: "none" };
  return {
    ph: disk.ph, clean: disk.clean, deaths: Math.min(disk.deaths, CrashLoopAfter), need: needOf(disk.need),
    noFast: disk.no_fast, compacted: disk.compacted, streak: Math.min(disk.streak, EscalateAfter), streakKind: kindOf(disk.streak_kind),
  };
}

type Mismatch = { walk: number; step: number; label: string; path: string[]; field: string; model: unknown; real: unknown };

// JSON with sorted keys, since TLC orders record fields its own way.
function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${canonical(item)}`).join(",")}}`;
}

function check(walks: Walk[], graphs: Map<boolean, Graph>, results: Result[], tamper: boolean): { mismatches: Mismatch[]; seen: Map<string, number> } {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    const graph = graphs.get(walk.fast)!;
    let shown = "clear";
    let failed = false;
    walk.steps.forEach((step, i) => {
      const own = results.slice(r, r + step.ops.length);
      r += step.ops.length;
      if (failed) return;
      seen.set(step.label, (seen.get(step.label) ?? 0) + 1);
      const s = graph.states.get(step.from)!;
      const t = graph.states.get(step.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || canonical(model) === canonical(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      if (own.length === 0) return;
      const last = own[own.length - 1]!;
      // The saved record, after every step that reaches the lab.
      expect("disk", t.disk, diskOf(last.disk));
      if (step.label === "LateOutcome") {
        expect("late outcome ignored", { save: false, send: null, status: null, finish: null }, last.plan);
        return;
      }
      if (step.label === "RespondUnclear") {
        const differs = s.sendCompact || own[0]!.differs === true;
        if (t.phase === "fx_stopped") expect("next send repeats the last one", false, differs);
        else if (t.rep >= RepeatStop) expect("next send differs", true, differs);
      }
      if (step.label === "Relaunch" || step.label === "Init") shown = "clear";
      for (const result of own) if (result.plan?.status) shown = result.plan.status.kind;
      if (step.label === "TerminalFail" || (step.label === "RespondUnclear" && t.phase === "fx_stopped")) shown = "stopped";
      if (!t.alive) shown = "none";
      expect("status", t.status, shown);
      const real = last.state;
      if (!t.alive || !Active.has(t.phase)) {
        expect("phase", "idle", real.phase);
        return;
      }
      expect("phase", t.phase, phaseOf(real.phase, tamper));
      expect("need", t.need, needOf(real.need));
      expect("abrupt deaths", t.mdeaths, Math.min(real.deaths, CrashLoopAfter));
      expect("no_fast", t.noFast, real.no_fast);
      expect("compacted", t.compacted, real.compacted);
      expect("streak", t.streak, Math.min(real.streak, EscalateAfter));
      expect("streak kind", t.streakKind, kindOf(real.streak_kind));
      expect("flowing", t.flowing, real.flowing);
      expect("clean exit", t.closing, real.clean);
      expect("save pending", t.dirty, last.pending);
      const plan = own.find((result) => result.plan?.send)?.plan ?? null;
      if (["Init", "Relaunch", "TimerFires", "UserActs", "RespondTooLong", "Responding"].includes(step.label) ||
        step.label.startsWith("Respond") || step.label === "Drop" || step.label === "StaleSocket") {
        expect("send planned", t.pendingSend, plan !== null);
        if (plan?.send) {
          expect("send compact", t.sendCompact, plan.send.compact);
          expect("send no_fast", t.noFast, plan.send.no_fast);
          expect("attempt", t.attempt, Math.min(real.attempt, 2));
        }
      }
    });
  });
  return { mismatches, seen };
}

function report(name: string, walks: Walk[], outcome: ReturnType<typeof check>): boolean {
  const steps = walks.reduce((sum, walk) => sum + walk.steps.length, 0);
  console.log(`${name}: ${walks.length} walks, ${steps} steps, ${outcome.mismatches.length} mismatching walks`);
  for (const m of outcome.mismatches.slice(0, 3)) {
    console.log(`  walk ${m.walk} step ${m.step} (${m.label}): ${m.field}: model ${JSON.stringify(m.model)}, module ${JSON.stringify(m.real)}`);
    console.log(`    path: ${m.path.join(" > ")}`);
  }
  return outcome.mismatches.length === 0;
}

const out = outDir("recovery-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "recovery", "recovery.zig");
const lab = buildLab(module, out, "recovery_lab");
const graphs = new Map<boolean, Graph>();
for (const fast of [true, false]) graphs.set(fast, await loadGraph(out, fast));
const walks = [
  ...edgeWalks(graphs.get(true)!, true),
  ...edgeWalks(graphs.get(false)!, false),
  ...makeWalks(graphs.get(true)!, true, options.seed),
  ...makeWalks(graphs.get(false)!, false, options.seed + 1),
];
const results = runLab(lab, walks, out, "recovery_lab");
const outcome = check(walks, graphs, results, false);
let ok = report(options.next ? "module, torn records included (--next)" : "module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);
if (options.next && !ok) {
  console.log("expected until recovery.zig counts a torn record as one abrupt death");
}

if (options.selfCheck) {
  // A planted defect in the module: a transient failure resends at once.
  const mutantDir = join(out, "mutant");
  const { mkdirSync } = await import("node:fs");
  mkdirSync(mutantDir, { recursive: true });
  const source = readFileSync(module, "utf8");
  const target = ".offline, .dropped, .server, .rate_limited => waitAfter(state, failure, now_ms),";
  if (!source.includes(target)) fail(2, "self-check: the planted defect's target line is gone from recovery.zig");
  writeFileSync(join(mutantDir, "recovery.zig"), source.replace(target, ".offline, .dropped, .server, .rate_limited => sendNow(state, now_ms, .{}),"));
  const mutant = buildLab(join(mutantDir, "recovery.zig"), out, "recovery_lab_mutant");
  const mutantOutcome = check(walks, graphs, runLab(mutant, walks, out, "recovery_lab_mutant"), false);
  const mutantCaught = mutantOutcome.mismatches.length > 0;
  console.log(`self-check: module that resends at once after a failure ${mutantCaught ? "rejected" : "NOT rejected"}`);
  // A tampered expectation: the mapping reads waiting as retrying.
  const tamperCaught = check(walks, graphs, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
