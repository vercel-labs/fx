// Walks the connection-open hand-off (src/gateway/open_job.zig) along its
// model, tests/tla/gateway_open/OpenCancel.tla, with the design's constants.
//
// TLC writes the model's state graph. The driver walks every edge along a
// shortest path from the initial state, then seeded random paths. Each model
// step becomes an operation for lab.zig, which runs the real hand-off the
// way src/gateway/client.zig uses it. After every step what each side holds
// must match the model's next state.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/gateway_open/driver.ts
//   bun tests/tla/drivers/gateway_open/driver.ts --self-check
//   bun tests/tla/drivers/gateway_open/driver.ts --walks 500 --steps 12 --seed 7
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
  state: { worker: string; job: string; conn: string; client: string; state: string; cancelled: boolean };
  error: string | null;
};
type Hop = { from: string; to: string; label: string };
type Walk = { hops: Hop[] };

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
  walks: option("--walks", 200),
  steps: option("--steps", 12),
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
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "open_job",
      `-Mroot=${join(TLA_ROOT, "drivers", "gateway_open", "lab.zig")}`, `-Mopen_job=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", "    Abandon = TRUE", "    CloseLate = TRUE",
    "    AtomicSwap = TRUE", "    StopConnect = TRUE", "    FreeOnReturn = FALSE", "CHECK_DEADLOCK FALSE", ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "OpenCancel", "Driver.cfg", ["OpenCancel.tla"], join(TLA_ROOT, "gateway_open"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on OpenCancel.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// The operation one model step becomes. The design's constants never take
// the split read-and-write actions, which exist for the planted defects.
function opFor(label: string): Op {
  switch (label) {
    case "Cancel": return { op: "cancel" };
    case "LookupReturns": return { op: "lookup_returns" };
    case "ConnectReturns": return { op: "connect_returns" };
    case "JobStopConnect": return { op: "job_watch" };
    case "JobPublishAtomic": return { op: "job_publish" };
    case "WorkerAbandonAtomic": case "WorkerTake": return { op: "worker_poll" };
    case "WorkerDone": return { op: "worker_done" };
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

// The real request polls every few milliseconds while it waits, and the
// job's watch while its open runs, which the model leaves out as
// stuttering. A poll in a state where the request still wants a running
// open, or where the job's open cannot be stopped yet, must change nothing,
// so the driver adds one there.
const pollsWhileWaiting = (t: Model) => t.worker === "waiting" && !t.cancelled && t.state === "running";
const watchesWhileOpening = (t: Model) => t.job === "lookup" || (t.job === "connect" && t.state !== "abandoned");

function opsFor(hop: Hop, graph: Graph): Op[] {
  const t = graph.states.get(hop.to)!;
  const ops = [opFor(hop.label)];
  if (pollsWhileWaiting(t)) ops.push({ op: "worker_poll" });
  if (watchesWhileOpening(t)) ops.push({ op: "job_watch" });
  return ops;
}

// One walk per edge: the shortest path from the initial state to the edge's
// source, then the edge.
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
      const hops: Hop[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) {
        const link = parent.get(at)!;
        hops.unshift({ from: link.from, to: at, label: link.label });
      }
      walks.push({ hops });
    }
  }
  return walks;
}

function randomWalks(graph: Graph, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  for (let w = 0; w < options.walks; w += 1) {
    const hops: Hop[] = [];
    let at = graph.init;
    for (let i = 0; i < options.steps; i += 1) {
      const edges = (graph.next.get(at) ?? []).filter((edge) => edge.to !== at);
      if (edges.length === 0) break;
      const edge = edges[Math.floor(random() * edges.length)]!;
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    walks.push({ hops });
  }
  return walks;
}

function runLab(bin: string, walks: Walk[], graph: Graph, out: string, name: string): Result[] {
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  const lines: string[] = [];
  for (const walk of walks) {
    lines.push(JSON.stringify({ op: "walk" }));
    for (const hop of walk.hops) for (const op of opsFor(hop, graph)) lines.push(JSON.stringify(op));
  }
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Result);
  if (results.length !== lines.length) fail(2, `${name} answered ${results.length} of ${lines.length} operations`);
  return results;
}

type Mismatch = { walk: number; step: number; path: string[]; field: string; model: unknown; real: unknown };

// The refinement mapping: each lab field must equal the model variable of
// the same name. `tamper` expects the job to keep a late connection open, to
// prove the checks can fail.
function check(walks: Walk[], graph: Graph, results: Result[], tamper: boolean) {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    r += 1; // the walk's reset
    let failed = false;
    walk.hops.forEach((hop, i) => {
      const own = results.slice(r, r + opsFor(hop, graph).length);
      r += own.length;
      if (failed) return;
      seen.set(hop.label, (seen.get(hop.label) ?? 0) + 1);
      const t = graph.states.get(hop.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, path: walk.hops.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      // The step, then any poll while waiting: each must leave the model's
      // next state.
      for (const result of own) {
        if (result.error) expect("lab error", null, result.error);
        expect("worker", t.worker, result.state.worker);
        expect("job", t.job, result.state.job);
        const conn = tamper && hop.label === "JobPublishAtomic" && t.conn === "closed" ? "open" : t.conn;
        expect("conn", conn, result.state.conn);
        expect("client", t.client, result.state.client);
        expect("state", t.state, result.state.state);
        expect("cancelled", t.cancelled, result.state.cancelled);
      }
    });
  });
  return { mismatches, seen };
}

function report(name: string, walks: Walk[], outcome: ReturnType<typeof check>): boolean {
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  console.log(`${name}: ${walks.length} walks, ${steps} steps, ${outcome.mismatches.length} mismatching walks`);
  for (const m of outcome.mismatches.slice(0, 3)) {
    console.log(`  walk ${m.walk} step ${m.step}: ${m.field}: model ${JSON.stringify(m.model)}, module ${JSON.stringify(m.real)}`);
    console.log(`    path: ${m.path.join(" > ")}`);
  }
  return outcome.mismatches.length === 0;
}

const out = outDir("gateway-open-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "gateway", "open_job.zig");
const lab = buildLab(module, out, "gateway_open_lab");
const graph = await loadGraph(out);
const walks = [...edgeWalks(graph), ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, graph, out, "gateway_open_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);
for (const label of ["Cancel", "LookupReturns", "ConnectReturns", "JobStopConnect", "JobPublishAtomic", "WorkerAbandonAtomic", "WorkerTake", "WorkerDone"]) {
  if (!outcome.seen.has(label)) {
    console.log(`action ${label} was never walked`);
    ok = false;
  }
}

if (options.selfCheck) {
  // Planted defects in the hand-off, each one expression of open_job.zig.
  const source = readFileSync(module, "utf8");
  const mutants = [
    {
      name: "walks away without the swap, leaving a handed connection open",
      target: "self.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null",
      planted: "self.state.load(.acquire) != .abandoned",
    },
    {
      name: "hands a late connection to a request that walked away",
      target: "self.state.cmpxchgStrong(.running, .handed, .acq_rel, .acquire) == null",
      planted: "self.state.load(.acquire) != .handed",
    },
    {
      name: "takes the open before it is handed over",
      target: "return if (self.state.load(.acquire) == .handed) .take else .wait;",
      planted: "return if (self.state.load(.acquire) != .abandoned) .take else .wait;",
    },
    {
      name: "never stops an open the request walked away from",
      target: "return self.state.load(.acquire) == .abandoned;",
      planted: "_ = self;\n        return false;",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target for "${mutant.name}" is gone from open_job.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "open_job.zig"), source.replace(mutant.target, mutant.planted));
    const name = `gateway_open_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "open_job.zig"), out, name);
    const caught = check(walks, graph, runLab(bin, walks, graph, out, name), false).mismatches.length > 0;
    console.log(`self-check: hand-off that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  const tamperCaught = check(walks, graph, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
