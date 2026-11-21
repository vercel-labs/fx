// Walks the number on fx's compaction row (src/core/output/compaction_progress.zig,
// through the compaction_activity.State that owns it) along its model,
// tests/tla/compaction_progress/CompactionProgress.tla.
//
// TLC writes the model's state graph. The driver walks to every edge the
// code can tell apart, along a shortest path, and then follows seeded random
// paths. Each model step becomes an event for lab.zig, which runs the real
// code at the model's time in milliseconds, also when the model sets its
// clock back or forward. After every step the number the code's row shows,
// its phase,
// and the marks behind the number must match the model's next state. Each
// model tick is 20,000 ms, so the code's arithmetic gives the model's whole
// numbers.
//
// --self-check plants nine defects, one line each, in copies of the code
// and requires the walks to reject every copy, then requires a wrong
// expectation to be rejected too.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/compaction_progress/driver.ts
//   bun tests/tla/drivers/compaction_progress/driver.ts --self-check
//   bun tests/tla/drivers/compaction_progress/driver.ts --walks 2000 --steps 60 --seed 7
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
  phase: string;
  row: number | null;
  floor: number;
  base: number;
  notes: number;
  waiting: boolean;
  waited_ms: number;
  seen_ms: number;
  error: string | null;
};
type Step = { label: string; from: string; to: string; ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: CompactionProgress.tla constants for the graph it walks.
const MaxTime = 5;
const MaxBacks = 1;
const TICK_MS = 20_000;
const LEVELS = [33, 66, 99];

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

// The lab builds compaction_activity.zig as its module; the file's own import of
// compaction_progress.zig comes along from the same folder.
function buildLab(moduleSource: string, out: string, name: string): string {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "compaction_activity",
      `-Mroot=${join(TLA_ROOT, "drivers", "compaction_progress", "lab.zig")}`, `-Mcompaction_activity=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    MaxTime = ${MaxTime}`, `    MaxBacks = ${MaxBacks}`, `    Levels = {${LEVELS.join(", ")}}`, `    Bug = "none"`, ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "CompactionProgress", "Driver.cfg", ["CompactionProgress.tla"], join(TLA_ROOT, "compaction_progress"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on CompactionProgress.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// What the code can see of a model state: everything but the count of times
// the clock was set back, which only bounds the model.
const codeView = (s: Model) =>
  JSON.stringify([s.now, s.phase, s.floor, s.base, s.notes, s.waiting, s.waited, s.seen, s.row]);

// The operations one model step becomes, at the model's time in ms.
function opsFor(label: string, s: Model, t: Model): Op[] {
  const now = t.now * TICK_MS;
  switch (label) {
    case "Begin": return [{ op: "begin", now }];
    case "Summarize": return [{ op: "summarize", now }];
    case "Ask": return [{ op: "ask", now }];
    case "Write": return [{ op: "write", now, percent: t.notes }];
    case "Save": return [{ op: "save", now }];
    case "Settle": return [{ op: "settle", now }];
    case "Tick": return [{ op: "read", now }];
    case "ClockBack": return [{ op: "read", now }];
    case "ClockJump": return [{ op: "read", now }];
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

const initStep = (graph: Graph): Step => ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk", now: TICK_MS }] });

function stepsFor(graph: Graph, hops: { from: string; to: string; label: string }[]): Step[] {
  const steps: Step[] = [initStep(graph)];
  hops.forEach((hop) => {
    const s = graph.states.get(hop.from)!;
    const t = graph.states.get(hop.to)!;
    steps.push({ ...hop, ops: opsFor(hop.label, s, t) });
  });
  return steps;
}

// Each walk picks among the next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such
// as Settle are exercised as often as a tick.
function randomWalks(graph: Graph, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  const taken = new Map<string, number>();
  for (let w = 0; w < options.walks; w += 1) {
    const hops: { from: string; to: string; label: string }[] = [];
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

// One walk per edge the code can tell apart: the shortest path from the
// initial state to the edge's source, then the edge.
function edgeWalks(graph: Graph): { walks: Walk[]; edges: number; distinct: number } {
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
  const seen = new Set<string>();
  let edges = 0;
  for (const id of queue) {
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id) continue;
      edges += 1;
      const key = `${codeView(graph.states.get(id)!)} ${edge.label} ${codeView(graph.states.get(edge.to)!)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const hops: { from: string; to: string; label: string }[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      walks.push({ steps: stepsFor(graph, hops) });
    }
  }
  return { walks, edges, distinct: seen.size };
}

function runLab(bin: string, ops: Op[], out: string, name: string): Result[] {
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  writeFileSync(opsPath, `${ops.map((op) => JSON.stringify(op)).join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Result);
  if (results.length !== ops.length) fail(2, `${name} answered ${results.length} of ${ops.length} operations`);
  return results;
}

const walkOps = (walks: Walk[]) => walks.flatMap((walk) => walk.steps.flatMap((step) => step.ops));

type Mismatch = { walk: number; step: number; label: string; path: string[]; field: string; model: unknown; real: unknown };

// The refinement mapping: what the model's next state says the code must
// show after each step. `tamper` expects the row one higher after a tick
// while the model summarizes, to prove the checks can fail.
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
      const t = graph.states.get(step.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      const real = own[own.length - 1]!;
      const counting = ["preparation", "summary", "publication"].includes(t.phase);
      expect("phase", t.phase, real.phase);
      expect("row number", counting ? t.row + (tamper && step.label === "Tick" && t.phase === "summary" ? 1 : 0) : null, real.row);
      if (counting) {
        expect("floor", t.floor, real.floor);
        expect("base", t.base, real.base);
        expect("notes", t.notes, real.notes);
        expect("waiting", t.waiting, real.waiting);
        expect("wait", t.waited * TICK_MS, real.waited_ms);
        expect("time seen", t.seen * TICK_MS, real.seen_ms);
      }
    });
  });
  return { mismatches, seen };
}

function report(name: string, walks: Walk[], outcome: ReturnType<typeof check>): boolean {
  const steps = walks.reduce((sum, walk) => sum + walk.steps.length, 0);
  console.log(`${name}: ${walks.length} walks, ${steps} steps, ${outcome.mismatches.length} mismatching walks`);
  for (const m of outcome.mismatches.slice(0, 3)) {
    console.log(`  walk ${m.walk} step ${m.step} (${m.label}): ${m.field}: model ${JSON.stringify(m.model)}, code ${JSON.stringify(m.real)}`);
    console.log(`    path: ${m.path.join(" > ")}`);
  }
  return outcome.mismatches.length === 0;
}

const out = outDir("compaction-progress-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "output", "compaction_activity.zig");
const lab = buildLab(module, out, "compaction_progress_lab");
const graph = await loadGraph(out);
const edgeSet = edgeWalks(graph);
console.log(`edges: ${edgeSet.edges}, ${edgeSet.distinct} the code can tell apart`);
const walks = [...edgeSet.walks, ...randomWalks(graph, options.seed)];
const results = runLab(lab, walkOps(walks), out, "compaction_progress_lab");
const outcome = check(walks, graph, results, false);
let ok = report("code", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);

if (options.selfCheck) {
  // Planted defects in the code, each a line of one source file changed.
  const folder = join(REPO_ROOT, "src", "core", "output");
  const files = ["compaction_activity.zig", "compaction_progress.zig"];
  const mutants = [
    {
      name: "gives a waiting request nothing",
      file: "compaction_progress.zig",
      target: "return wait_share * waited / (waited + wait_half_ms);",
      planted: "return 0 * waited;",
    },
    {
      name: "lets a wait earn all the room that is left",
      file: "compaction_progress.zig",
      target: "const wait_share: u64 = 5_000;",
      planted: "const wait_share: u64 = 10_000;",
    },
    {
      name: "keeps crediting the wait after the notes arrive",
      file: "compaction_progress.zig",
      target: "self.waiting = false;",
      planted: "self.waiting = self.waiting;",
    },
    {
      name: "starts a new request from zero",
      file: "compaction_progress.zig",
      target: "self.floor = self.value();",
      planted: "self.floor = self.value() * 0;",
    },
    {
      name: "counts notes the row already shows at a new request",
      file: "compaction_progress.zig",
      target: "self.base = self.notes;",
      planted: "self.base = @min(self.base, self.notes);",
    },
    {
      name: "shows 100% before saving",
      file: "compaction_progress.zig",
      target: "const top_hundredths: u64 = @as(u64, all_notes) * 100;",
      planted: "const top_hundredths: u64 = 10_000;",
    },
    {
      name: "gives the wait back when the clock is set back",
      file: "compaction_progress.zig",
      target: "self.seen_ms = now_ms;",
      planted: "if (self.waiting and now_ms < self.seen_ms) self.waited_ms -|= @as(u32, @intCast(self.seen_ms - now_ms)); self.seen_ms = now_ms;",
    },
    {
      name: "counts a clock set forward as waiting",
      file: "compaction_progress.zig",
      target: "if (passed <= longest_step_ms) {",
      planted: "if (passed <= longest_wait_ms) {",
    },
    {
      name: "shows less than 100% while fx saves",
      file: "compaction_activity.zig",
      target: ".publication => 100,",
      planted: ".publication => self.progress.shown(),",
    },
  ];
  let mutantsCaught = true;
  const allOps = walkOps(walks);
  mutants.forEach((mutant, index) => {
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    for (const file of files) {
      const source = readFileSync(join(folder, file), "utf8");
      if (file !== mutant.file) {
        writeFileSync(join(dir, file), source);
        continue;
      }
      // The target must be one line of the file, so the copy differs by exactly that line.
      if (source.split(mutant.target).length !== 2) fail(2, `self-check: the target line for "${mutant.name}" is not exactly once in ${file}`);
      writeFileSync(join(dir, file), source.replace(mutant.target, mutant.planted));
    }
    const name = `compaction_progress_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "compaction_activity.zig"), out, name);
    const caught = check(walks, graph, runLab(bin, allOps, out, name), false).mismatches.length > 0;
    console.log(`self-check: code that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  const tamperCaught = check(walks, graph, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
