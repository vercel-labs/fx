// Walks fx's Rex session rename queue (src/core/rex_rename/queue.zig) along
// its model, tests/tla/rex_rename/RexRename.tla.
//
// TLC writes the model's state graph. The driver walks to every edge along a
// shortest path from the initial state, so every transition of the model is
// checked at least once, and then follows seeded random paths. Each step that
// calls the queue in renamer.zig (Request, StartFails, TakeTitle, TakeNone,
// Stop) becomes one operation for lab.zig, which runs the real module. After
// every such step the module's State and outputs must match the model's next
// state. The other steps (StartTask, Apply, End, AwaitStop) do not touch the
// queue, so they send nothing.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/rex_rename/driver.ts
//   bun tests/tla/drivers/rex_rename/driver.ts --self-check
//   bun tests/tla/drivers/rex_rename/driver.ts --walks 1000 --steps 80 --seed 7
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
type Op = { op: string };
type Result = {
  state: { waiting: boolean; running: boolean; stopped: boolean };
  keep_title: boolean | null;
  start_task: boolean | null;
  apply_title: boolean | null;
  error: string | null;
};
type Hop = { from: string; to: string; label: string };
type Step = Hop & { ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: RexRename.tla with three titles.
const N = 3;

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
  steps: option("--steps", 40),
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
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "rex_rename_queue",
      `-Mroot=${join(TLA_ROOT, "drivers", "rex_rename", "lab.zig")}`, `-Mrex_rename_queue=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    N = ${N}`, `    Bug = "none"`, ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "RexRename", "Driver.cfg", ["RexRename.tla"], join(TLA_ROOT, "rex_rename"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on RexRename.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// The queue call one model step makes in renamer.zig, if any.
function opsFor(label: string): Op[] {
  switch (label) {
    case "Request": return [{ op: "request" }];
    case "StartFails": return [{ op: "start_failed" }];
    case "TakeTitle": case "TakeNone": return [{ op: "take" }];
    case "Stop": return [{ op: "stop" }];
    case "StartTask": case "Apply": case "End": case "AwaitStop": case "Done": return [];
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

const stepsFor = (graph: Graph, hops: Hop[]): Step[] => [
  { label: "Init", from: graph.init, to: graph.init, ops: [{ op: "reset" }] },
  ...hops.map((hop) => ({ ...hop, ops: opsFor(hop.label) })),
];

// Each walk picks among the possible next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such as
// a failed start or a stop with a title waiting come up as often as a take.
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

// One walk per edge: the shortest path from the initial state to the edge's
// source, then the edge.
function edgeWalks(graph: Graph): { walks: Walk[]; edges: number } {
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
      const hops: Hop[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      walks.push({ steps: stepsFor(graph, hops) });
    }
  }
  return { walks, edges: walks.length };
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

// The refinement mapping: the model's `waiting` holds a title where the
// module holds a flag, and the outputs follow from the model's next state.
// `tamper` expects every request to start a task, to prove the checks can
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
      if (own.length === 0) return;
      const t = graph.states.get(step.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      const real = own[own.length - 1]!;
      expect("waiting", t.waiting !== 0, real.state.waiting);
      expect("running", t.running, real.state.running);
      expect("stopped", t.stopped, real.state.stopped);
      if (step.label === "Request") {
        // A kept title is the newest one: titles are requested in order.
        expect("keep_title", t.waiting === t.requested, real.keep_title);
        expect("start_task", tamper || t.main === "start", real.start_task);
      }
      if (step.label === "TakeTitle" || step.label === "TakeNone") {
        expect("apply_title", step.label === "TakeTitle", real.apply_title);
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

const out = outDir("rex-rename-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "rex_rename", "queue.zig");
const lab = buildLab(module, out, "rex_rename_lab");
const graph = await loadGraph(out);
const edgeSet = edgeWalks(graph);
console.log(`edges: ${edgeSet.edges}`);
const walks = [...edgeSet.walks, ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, out, "rex_rename_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);
for (const action of ["Request", "StartTask", "StartFails", "Stop", "AwaitStop", "TakeTitle", "TakeNone", "Apply", "End"]) {
  if (!outcome.seen.has(action)) {
    console.log(`the walks never took ${action}`);
    ok = false;
  }
}

if (options.selfCheck) {
  // Planted defects in the module, each a line of queue.zig changed.
  const source = readFileSync(module, "utf8");
  const mutants = [
    {
      name: "starts a second task while one runs",
      target: ".start_task = !state.running };",
      planted: ".start_task = true };",
    },
    {
      name: "keeps a title after the stop",
      target: "if (state.stopped) return .{ .state = state, .keep_title = false, .start_task = false };",
      planted: "",
    },
    {
      name: "hands out a title after the stop",
      target: "if (state.waiting and !state.stopped) {",
      planted: "if (state.waiting) {",
    },
    {
      name: "does not mark the task ended when nothing waits",
      target: "    next.waiting = false;\n    next.running = false;\n    return .{ .state = next, .apply_title = false };",
      planted: "    next.waiting = false;\n    return .{ .state = next, .apply_title = false };",
    },
    {
      name: "keeps the title after a failed start",
      target: "pub fn startFailed(state: State) State {\n    var next = state;\n    next.waiting = false;\n",
      planted: "pub fn startFailed(state: State) State {\n    var next = state;\n",
    },
    {
      name: "ignores the stop",
      target: "next.stopped = true;",
      planted: "next.stopped = false;",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target line for "${mutant.name}" is gone from queue.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "queue.zig"), source.replace(mutant.target, mutant.planted));
    const name = `rex_rename_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "queue.zig"), out, name);
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
