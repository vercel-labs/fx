// Walks fx's cache-warming planner (src/core/agent/runtime/cache_warming.zig)
// along its model, tests/tla/cache_warming/CacheWarming.tla.
//
// TLC writes the model's state graph. Most of its variables describe the
// world the planner cannot see: the provider's entry, evictions, and sleeps.
// Edges that look the same to the planner, the same action from the same
// planner-visible state to the same planner-visible state, are walked once:
// the driver walks to each such edge along a shortest path, so every
// transition the planner can tell apart is checked at least once, and then
// follows seeded random paths. Each model step becomes events for lab.zig,
// which runs the real module at the times the driver's clock gives. After
// every step the module's state and plan must match the model's next state.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/cache_warming/driver.ts
//   bun tests/tla/drivers/cache_warming/driver.ts --self-check
//   bun tests/tla/drivers/cache_warming/driver.ts --walks 1000 --steps 80 --seed 7
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
  plan: { kind: string; at: number | null; stop: string | null } | null;
  state: { armed: boolean; pings: number; in_flight: boolean; stopped: string; last_touch: number; request_started: number };
  error: string | null;
};
type Step = { label: string; from: string; to: string; ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: CacheWarming.tla constants for the graph it walks.
const TTL = 20;
const Cap = 20;
const MaxSend = 1;
const MaxSleep = 3;
const Interval = TTL - Math.floor(TTL / 10);
const MaxPings = Math.floor(Cap / Interval);

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
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "cache_warming",
      `-Mroot=${join(TLA_ROOT, "drivers", "cache_warming", "lab.zig")}`, `-Mcache_warming=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    TTL = ${TTL}`, `    Cap = ${Cap}`,
    `    MaxSend = ${MaxSend}`, `    MaxSleep = ${MaxSleep}`, `    Bug = "none"`, ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "CacheWarming", "Driver.cfg", ["CacheWarming.tla"], join(TLA_ROOT, "cache_warming"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on CacheWarming.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// What the planner can see of a model state: everything but the world.
const plannerView = (s: Model) =>
  JSON.stringify([s.awake, s.sending, s.sendAge, s.armed, s.touchAge, s.reqAge, s.pings, s.inflight,
    s.pingAge, s.pingStale, s.pingHit, s.stopped]);

// How far the clock moved in a step: the largest change of an age that did
// not saturate. A step whose ages all saturated changes no planner decision,
// so any length past the largest saturation does.
function elapsed(label: string, s: Model, t: Model): number {
  if (label === "Tick") return 1;
  if (label !== "Sleep") return 0;
  const gaps = [
    t.reqAge < Cap + TTL + 1 ? t.reqAge - s.reqAge : 0,
    t.touchAge < TTL + 1 ? t.touchAge - s.touchAge : 0,
    t.cacheAge < TTL ? t.cacheAge - s.cacheAge : 0,
  ];
  const gap = Math.max(...gaps);
  return gap > 0 ? gap : MaxSleep;
}

// The ping's answer as the next state shows it. A stale answer changes
// nothing the planner holds, so any outcome the provider allows will do.
function outcomeOf(s: Model, t: Model): string {
  if (s.pingStale) return s.pingHit ? "read" : "missed";
  if (t.stopped === "failed" || t.stopped === "missed") return t.stopped;
  return "read";
}

// The operations one model step becomes, at the driver's clock `now` after
// the step's time has passed.
function opsFor(label: string, s: Model, t: Model, now: number): Op[] {
  switch (label) {
    case "Send": case "Reset": case "Shutdown": return [{ op: "disarmed", now }];
    case "Complete": return [{ op: "armed", now, started: now - s.sendAge }];
    case "Wake": return [{ op: "woke", now }];
    case "Answer": return [{ op: "answered", now, outcome: outcomeOf(s, t) }];
    case "Fail": case "Tick": case "Sleep": case "Evict": case "Closed": return [];
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

const Start = 1_000;
const initStep = (graph: Graph): Step =>
  ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk", ttl: TTL, cap: Cap }] });

// Turns a path of model edges into steps with ops on one clock.
function stepsFor(graph: Graph, hops: { from: string; to: string; label: string }[]): Step[] {
  const steps: Step[] = [initStep(graph)];
  let now = Start;
  for (const hop of hops) {
    const s = graph.states.get(hop.from)!;
    const t = graph.states.get(hop.to)!;
    now += elapsed(hop.label, s, t);
    steps.push({ ...hop, ops: opsFor(hop.label, s, t, now) });
  }
  return steps;
}

// Each walk picks among the possible next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such as
// a late wake or a stale answer are exercised as often as a tick.
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

// One walk per edge the planner can tell apart: the shortest path from the
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
      const s = graph.states.get(id)!;
      const t = graph.states.get(edge.to)!;
      const key = `${plannerView(s)} ${edge.label} ${plannerView(t)}`;
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

// The refinement mapping: what the model's next state says the planner and
// its plan must be. `tamper` expects a ping on the wire one step late, to
// prove the checks can fail.
function check(walks: Walk[], graph: Graph, results: Result[], tamper: boolean): { mismatches: Mismatch[]; seen: Map<string, number> } {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    let failed = false;
    let now = Start;
    walk.steps.forEach((step, i) => {
      const own = results.slice(r, r + step.ops.length);
      r += step.ops.length;
      for (const op of step.ops) if (typeof op.now === "number") now = op.now;
      if (failed) return;
      seen.set(step.label, (seen.get(step.label) ?? 0) + 1);
      const s = graph.states.get(step.from)!;
      const t = graph.states.get(step.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      // The world changed; the planner has not heard of it.
      if (own.length === 0) return;
      for (const result of own) if (result.error) expect("lab error", null, result.error);
      const last = own[own.length - 1]!;
      const real = last.state;
      const plan = last.plan;

      expect("armed", t.armed, real.armed);
      expect("why warming last stopped", t.stopped, real.stopped);
      // A shutdown cancels the ping; the planner never hears its answer.
      if (t.awake) expect("ping on the wire", tamper && step.label === "Wake" ? s.inflight : t.inflight, real.in_flight);
      if (t.armed) {
        expect("pings since the arm", t.pings, Math.min(real.pings, MaxPings + 2));
        if (t.touchAge <= TTL) expect("last touch", now - t.touchAge, real.last_touch);
        if (t.reqAge <= Cap + TTL) expect("armed request start", now - t.reqAge, real.request_started);
      }
      // The plan the warmer carries out.
      if (step.label === "Wake" && t.inflight && !s.inflight) expect("plan", "ping", plan?.kind);
      if (t.stopped !== s.stopped && t.stopped !== "none") expect("plan", { kind: "stopped", stop: t.stopped }, { kind: plan?.kind, stop: plan?.stop });
      if (t.armed && !t.inflight && step.label !== "Wake") expect("planned wake", now - t.touchAge + Interval, plan?.at);
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

const out = outDir("cache-warming-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "agent", "runtime", "cache_warming.zig");
const lab = buildLab(module, out, "cache_warming_lab");
const graph = await loadGraph(out);
const edgeSet = edgeWalks(graph);
console.log(`edges: ${edgeSet.edges}, ${edgeSet.distinct} the planner can tell apart`);
const walks = [...edgeSet.walks, ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, out, "cache_warming_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);

if (options.selfCheck) {
  // Planted defects in the module, each a line of cache_warming.zig changed.
  const source = readFileSync(module, "utf8");
  const mutants = [
    {
      name: "pings when the entry expires",
      target: "return self.ttl_ms - @divTrunc(self.ttl_ms, 10);",
      planted: "return self.ttl_ms;",
    },
    {
      name: "keeps pinging past the cap",
      target: "if (due(state, timing) > state.request_started_ms + timing.cap_ms) return stop(state, .cap);",
      planted: "",
    },
    {
      name: "trusts a wake after a long sleep",
      target: "if (woke.now_ms > due_ms + timing.late()) return stop(state, .late);",
      planted: "",
    },
    {
      name: "lets a stale answer reach a newer arm",
      target: "if (!state.armed or answered.generation != state.generation) return next(state, timing);",
      planted: "if (!state.armed) return next(state, timing);",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target line for "${mutant.name}" is gone from cache_warming.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "cache_warming.zig"), source.replace(mutant.target, mutant.planted));
    const name = `cache_warming_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "cache_warming.zig"), out, name);
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
