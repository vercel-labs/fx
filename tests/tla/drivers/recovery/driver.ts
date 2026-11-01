// Walks fx's request-recovery module (src/core/recovery/recovery.zig) along
// its model, tests/tla/recovery/Recovery.tla.
//
// TLC writes the model's state graph. The driver walks to every edge of the
// graph along a shortest path, so every model transition is checked at least
// once, and then follows seeded random paths. Each model step becomes
// operations on lab.zig, which runs the real module and plays fx's part
// around it. After every step the module's state, its plan, the status it
// shows, and the saved record must match the model's next state. Steps that
// belong to the world (the network, the gateway, a fault only the user can
// fix) reach the module only through the next answer, so they change nothing
// the lab holds.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/recovery/driver.ts
//   bun tests/tla/drivers/recovery/driver.ts --self-check
//   bun tests/tla/drivers/recovery/driver.ts --walks 1000 --steps 80 --seed 7
//
// Exit codes: 0 every walk matched, 1 a mismatch (or a self-check that was
// not rejected), 2 a toolchain or build failure.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Op = Record<string, unknown>;
type Result = {
  plan: { save: boolean; send: { compact: boolean; no_fast: boolean } | null; status: { kind: string; need: string | null } | null; finish: string | null } | null;
  state: { phase: string; need: string | null; attempt: number; deaths: number; clean: boolean; flowing: boolean };
  disk: { ph: string; clean: boolean; deaths: number; need: string | null } | null;
  error: string | null;
};
type Step = { label: string; from: string; to: string; ops: Op[] };
type Walk = { steps: Step[] };

const MaxAttempt = 3; // Recovery.tla MaxAttempt
const Active = new Set(["working", "waiting", "need_user"]);
// Steps after which the model has a send on the wire, when it has one.
const Sends = new Set(["Init", "TimerFires", "UserActs", "Relaunch"]);

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
  selfCheck: flag("--self-check"),
  walks: option("--walks", 300),
  steps: option("--steps", 60),
  seed: option("--seed", 1),
  faults: option("--faults", 3),
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

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    MaxFaults = ${options.faults}`,
    "    Ladder = 3", `    Bug = "none"`, ""].join("\n");
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
  console.log(`graph: ${states.size} states, ${run.durationMs} ms`);
  return { states, next, init };
}

// The operations one model step becomes. `Respond` answers as the world
// stands, in the model's order: no network, then trouble only the user can
// fix, then a broken gateway, otherwise a complete answer.
function opsFor(label: string, s: Model): Op[] {
  switch (label) {
    case "Responding": return [{ op: "event", name: "responding" }];
    case "Respond":
      if (s.net === "down") return [{ op: "failed", kind: "offline" }];
      if (s.needUser) return [{ op: "failed", kind: "sign_in" }];
      if (s.gateway === "broken") return [{ op: "failed", kind: "server" }];
      return [{ op: "event", name: "succeeded" }];
    case "Drop": return [{ op: "failed", kind: "dropped" }];
    case "TimerFires": return [{ op: "wait" }];
    case "Crash": return [{ op: "exit" }];
    case "Close": return [{ op: "event", name: "closing" }, { op: "exit" }];
    case "Relaunch": return [{ op: "start", resume: true }];
    case "UserCancels": return [{ op: "event", name: "user_cancel" }];
    case "UserActs": return [{ op: "event", name: "user_continue" }];
    case "NetDown": case "NetUp": case "GatewayBreak": case "GatewayHeal": case "NeedUserFault":
      return [];
    default:
      throw new Error(`no mapping for model action ${label}`);
  }
}

const initStep = (graph: Graph): Step =>
  ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk" }, { op: "start", resume: false }] });

// Each walk picks among the possible next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such as
// a close or a crash loop are exercised as often as Esc.
function randomWalks(graph: Graph, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  const taken = new Map<string, number>();
  for (let w = 0; w < options.walks; w += 1) {
    const steps: Step[] = [initStep(graph)];
    let at = graph.init;
    for (let i = 0; i < options.steps; i += 1) {
      const edges = (graph.next.get(at) ?? []).filter((edge) => edge.to !== at);
      if (edges.length === 0) break;
      const weights = edges.map((candidate) => 1 / (1 + (taken.get(candidate.label) ?? 0)));
      let pick = random() * weights.reduce((sum, weight) => sum + weight, 0);
      let edge = edges[edges.length - 1]!;
      for (let k = 0; k < edges.length; k += 1) {
        pick -= weights[k]!;
        if (pick < 0) { edge = edges[k]!; break; }
      }
      taken.set(edge.label, (taken.get(edge.label) ?? 0) + 1);
      steps.push({ label: edge.label, from: at, to: edge.to, ops: opsFor(edge.label, graph.states.get(at)!) });
      at = edge.to;
    }
    walks.push({ steps });
  }
  return walks;
}

// One walk per edge of the graph: the shortest path from the initial state to
// the edge's source, then the edge. Every model transition is checked against
// the module at least once.
function edgeWalks(graph: Graph): Walk[] {
  const parent = new Map<string, { from: string; label: string } | null>([[graph.init, null]]);
  const queue = [graph.init];
  for (let at = 0; at < queue.length; at += 1) {
    const id = queue[at]!;
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id || parent.has(edge.to)) continue;
      parent.set(edge.to, { from: id, label: edge.label });
      queue.push(edge.to);
    }
  }
  const walks: Walk[] = [];
  for (const id of queue) {
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id) continue;
      const hops: { from: string; to: string; label: string }[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      const steps: Step[] = [initStep(graph)];
      for (const hop of hops) steps.push({ ...hop, ops: opsFor(hop.label, graph.states.get(hop.from)!) });
      walks.push({ steps });
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
// its plan, the screen, and the saved record must look like. `tamper` reads
// the module's waiting phase as working, to prove the checks can fail.
const phaseOf = (phase: string, tamper: boolean) =>
  ({ sending: "working", waiting: tamper ? "working" : "waiting", need_user: "need_user", idle: "idle" })[phase] ?? phase;

type Mismatch = { walk: number; step: number; label: string; path: string[]; field: string; model: unknown; real: unknown };

function check(walks: Walk[], graph: Graph, results: Result[], tamper: boolean): { mismatches: Mismatch[]; seen: Map<string, number> } {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
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
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      // The world changed; the module has not heard of it yet.
      if (own.length === 0) return;
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      const last = own[own.length - 1]!;

      // The saved record, after every step that reaches the lab.
      expect("record says a send is in flight", t.savedInflight, last.disk?.ph === "sending");
      expect("record marks a clean exit", t.savedClean, last.disk?.clean ?? false);

      // A failure never resends at once (NoHotRetry); time, a relaunch, or
      // the user comes first. Every step that sends in the model sends here.
      const sent = own.some((result) => result.plan?.send);
      expect("send planned", Sends.has(step.label) && t.inflight, sent);

      // The status line, which a new process starts without.
      if (step.label === "Init" || step.label === "Relaunch") shown = "clear";
      for (const result of own) if (result.plan?.status) shown = result.plan.status.kind;
      if (!t.alive) shown = "none";
      expect("status", t.status, shown);

      const real = last.state;
      if (!t.alive) return;
      if (!Active.has(t.phase)) {
        expect("finished", t.phase === "done_ok" ? "succeeded" : "cancelled", own.find((x) => x.plan?.finish)?.plan?.finish ?? null);
        expect("phase", "idle", real.phase);
        expect("record deleted", null, last.disk);
        return;
      }
      expect("phase", t.phase, phaseOf(real.phase, tamper));
      expect("attempt", t.attempt, Math.min(real.attempt, MaxAttempt));
      expect("flowing", t.flowing, real.flowing);
      expect("abrupt deaths", t.seenDeaths, Math.min(real.deaths, options.faults));
      // A relaunch that asks first asks about the crash loop, unless the
      // request was already waiting for the user.
      if (step.label === "Relaunch" && t.phase === "need_user" && s.phase !== "need_user") {
        expect("need", "crash_loop", real.need);
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
const graph = await loadGraph(out);
const walks = [...edgeWalks(graph), ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, out, "recovery_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);

if (options.selfCheck) {
  // Planted defects in the module, each a line of recovery.zig changed.
  const source = readFileSync(module, "utf8");
  const mutants = [
    {
      name: "resends at once after a failure",
      target: ".offline, .dropped, .server, .rate_limited => waitAfter(state, failure, now_ms),",
      planted: ".offline, .dropped, .server, .rate_limited => sendNow(state, now_ms, .{}),",
    },
    {
      name: "forgets its crashes when the user signs in",
      target: "if (state.need == .crash_loop) state.abrupt_deaths = 0;",
      planted: "state.abrupt_deaths = 0;",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target line for "${mutant.name}" is gone from recovery.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "recovery.zig"), source.replace(mutant.target, mutant.planted));
    const name = `recovery_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "recovery.zig"), out, name);
    const caught = check(walks, graph, runLab(bin, walks, out, name), false).mismatches.length > 0;
    console.log(`self-check: module that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  // A tampered expectation: the mapping reads waiting as working.
  const tamperCaught = check(walks, graph, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
