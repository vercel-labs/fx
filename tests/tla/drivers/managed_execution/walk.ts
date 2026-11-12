// Walks fx's quiet notice (src/core/execution/quiet_notice.zig) along its
// model, tests/tla/managed_execution/QuietWait.tla.
//
// TLC writes the model's state graph. Two of its variables, under and
// outDuring, and the last result are history the code does not keep. Edges
// that look the same to the code, the same action from the same visible
// state to the same visible state, are walked once: the driver walks to each
// such edge along a shortest path, so every transition the code can tell
// apart is checked at least once, and then follows seeded random paths. Each
// model step becomes operations for lab.zig, which runs the real module at
// the times the driver's clock gives. After every step the lab's state, and
// the end, arm, and notice of every wait that ends, must match the model.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/managed_execution/walk.ts
//   bun tests/tla/drivers/managed_execution/walk.ts --self-check
//   bun tests/tla/drivers/managed_execution/walk.ts --walks 1000 --steps 80 --seed 7
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
type Times = { running_ms: number; quiet_ms: number; notice: boolean };
type Result = {
  running: boolean;
  waiting: boolean;
  armed: boolean;
  quiet_ms: number;
  end: string | null;
  ended_armed: boolean | null;
  times: Times | null;
  error: string | null;
};
type Hop = { from: string; to: string; label: string };
type Step = Hop & { ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: QuietWait.tla constants for the graph it walks, and
// how many lab milliseconds one model tick takes.
const Limit = 2;
const MaxCeil = 3;
const QSat = Limit + 1;
const TickMs = 100;
const Start = 1_000;

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
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "quiet_notice",
      `-Mroot=${join(TLA_ROOT, "drivers", "managed_execution", "lab.zig")}`, `-Mquiet_notice=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    Limit = ${Limit}`, `    MaxCeil = ${MaxCeil}`,
    `    Bug = "none"`, ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "QuietWait", "Driver.cfg", ["QuietWait.tla"], join(TLA_ROOT, "managed_execution"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on QuietWait.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// What the code can see of a model state: everything but the ghosts and the
// last result.
const codeView = (s: Model) => JSON.stringify([s.cmd, s.quiet, s.waiting, s.ceil, s.waitAge, s.armed, s.polled]);

// The operations one model step becomes, at the driver's clock `now` after
// the step's time has passed.
function opsFor(label: string, t: Model, now: number): Op[] {
  switch (label) {
    case "Output": return [{ op: "output", now }];
    case "Finish": return [{ op: "finish", now }];
    case "Begin": return [{ op: "begin", now, ceiling: t.ceil * TickMs }];
    case "Poll": return [{ op: "poll", now }];
    case "Tick": return [];
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

const initStep = (graph: Graph): Step =>
  ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk", now: Start, limit: Limit * TickMs }] });

function stepsFor(graph: Graph, hops: Hop[]): Step[] {
  const steps: Step[] = [initStep(graph)];
  let now = Start;
  for (const hop of hops) {
    if (hop.label === "Tick") now += TickMs;
    steps.push({ ...hop, ops: opsFor(hop.label, graph.states.get(hop.to)!, now) });
  }
  return steps;
}

// Each walk picks among the next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such as
// a finish during a wait are exercised as often as a tick.
function randomWalks(graph: Graph, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  const taken = new Map<string, number>();
  for (let w = 0; w < options.walks; w += 1) {
    const hops: Hop[] = [];
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
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    walks.push({ steps: stepsFor(graph, hops) });
  }
  return walks;
}

// A shortest path to every state, then one walk per edge the code can tell
// apart.
function edgeWalks(graph: Graph): { walks: Walk[]; edges: number; distinct: number } {
  const parent = new Map<string, Hop | null>([[graph.init, null]]);
  const queue = [graph.init];
  for (let i = 0; i < queue.length; i += 1) {
    const id = queue[i]!;
    for (const edge of graph.next.get(id) ?? []) {
      if (parent.has(edge.to)) continue;
      parent.set(edge.to, { from: id, to: edge.to, label: edge.label });
      queue.push(edge.to);
    }
  }
  const walks: Walk[] = [];
  const seen = new Set<string>();
  let edges = 0;
  for (const id of queue) {
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id) continue;
      edges += 1;
      const key = `${codeView(graph.states.get(id)!)} ${edge.label} ${codeView(graph.states.get(edge.to)!)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const hops: Hop[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      walks.push({ steps: stepsFor(graph, hops) });
    }
  }
  return { walks, edges, distinct: seen.size };
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

type Mismatch = { walk: number; step: number; label: string; path: string[]; field: string; model: unknown; real: unknown };

// The refinement mapping: what the model's next state says the lab must
// report. `tamper` expects a notice one tick early, to prove the checks can
// fail.
function check(walks: Walk[], graph: Graph, results: Result[], tamper: boolean): { mismatches: Mismatch[]; seen: Map<string, number> } {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
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
      // Time passed; the code has not looked.
      if (own.length === 0) return;
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      const real = own[own.length - 1]!;
      if (step.label === "Init") return;
      expect("running", t.cmd === "running", real.running);
      expect("waiting", t.waiting, real.waiting);
      expect("quiet ticks", t.quiet, Math.min(Math.floor(real.quiet_ms / TickMs), QSat));
      if (t.waiting) expect("armed", t.armed, real.armed);
      if (step.label !== "Poll") return;
      const ended = s.waiting && !t.waiting;
      expect("wait ended", ended ? t.result.end : null, real.end);
      if (!ended) return;
      expect("arm at the end", t.result.armed, real.ended_armed);
      expect("time fields", t.result.running, real.times !== null);
      const notice = tamper ? t.result.running && t.quiet >= Limit - 1 : t.result.notice;
      expect("notice", notice, real.times?.notice ?? false);
      if (real.times) {
        expect("quiet at the end", t.result.quietDue, real.times.quiet_ms >= Limit * TickMs);
        expect("running covers quiet", true, real.times.running_ms >= real.times.quiet_ms);
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

const out = outDir("managed-execution-walk");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "execution", "quiet_notice.zig");
const lab = buildLab(module, out, "quiet_notice_lab");
const graph = await loadGraph(out);
const edgeSet = edgeWalks(graph);
console.log(`edges: ${edgeSet.edges}, ${edgeSet.distinct} the code can tell apart`);
const walks = [...edgeSet.walks, ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, out, "quiet_notice_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);

if (options.selfCheck) {
  // Planted defects in the module, each a line of quiet_notice.zig changed.
  const source = readFileSync(module, "utf8");
  const mutants = [
    { name: "never arms a wait on new output", target: "if (!due) next.armed = true;", planted: "if (!due) next.armed = wait.armed;" },
    {
      name: "ends a wait that began past the limit",
      target: "if (next.armed and due) return .{ .wait = next, .end = .quiet };",
      planted: "if (due) return .{ .wait = next, .end = .quiet };",
    },
    { name: "asks for a check one tick late", target: "return quiet_ms >= limit_ms;", planted: "return quiet_ms > limit_ms;" },
    {
      name: "runs a wait past its ceiling",
      target: "if (elapsedMs(wait.started_ms, now_ms) >= wait.ceiling_ms)",
      planted: "if (elapsedMs(wait.started_ms, now_ms) > wait.ceiling_ms)",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target line for "${mutant.name}" is gone from quiet_notice.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "quiet_notice.zig"), source.replace(mutant.target, mutant.planted));
    const name = `quiet_notice_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "quiet_notice.zig"), out, name);
    const caught = check(walks, graph, runLab(bin, walks, out, name), false).mismatches.length > 0;
    console.log(`self-check: module that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  const tamperCaught = check(walks, graph, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
