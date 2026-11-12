// Walks fx's thinking-row clocks (src/core/output/turn_clock.zig, with the
// compaction_activity.State it reads) along their model,
// tests/tla/turn_clock/TurnClock.tla.
//
// TLC writes the model's state graph. The driver walks to every edge the
// code can tell apart, the same action between the same states without the
// model's ghost variables, along a shortest path, and then follows seeded
// random paths. Each model step becomes events for lab.zig, which runs the
// real code at the model's time in milliseconds. After every step the code's
// marks, both clocks, and the compaction's phase must match the model's next
// state. Each model second is 1000 ms, so the code's clocks are exact.
//
// --stress N adds one 24-hour turn with N compactions and N prompts on the
// real code, with UI syncs lagging up to a frame behind each event, checked
// against the time the turn worked to the millisecond.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/turn_clock/driver.ts
//   bun tests/tla/drivers/turn_clock/driver.ts --self-check
//   bun tests/tla/drivers/turn_clock/driver.ts --walks 2000 --steps 60 --seed 7 --stress 10000
//
// Exit codes: 0 every walk matched, 1 a mismatch (or a self-check that was
// not rejected), 2 a toolchain or build failure.
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Op = Record<string, unknown>;
type Result = {
  turn: boolean;
  prompt: boolean;
  started_ms: number;
  waiting_since_ms: number;
  turn_seconds: number | null;
  phase: string;
  compaction_seconds: number | null;
  error: string | null;
  written: number;
};
type Step = { label: string; from: string; to: string; ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: TurnClock.tla constants for the graph it walks.
const MaxTime = 6;
const MS = 1000;

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
  stress: option("--stress", 0),
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

// The lab builds turn_clock.zig as its module; the file's own import of
// compaction_activity.zig comes along from the same folder.
function buildLab(moduleSource: string, out: string, name: string): string {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "turn_clock",
      `-Mroot=${join(TLA_ROOT, "drivers", "turn_clock", "lab.zig")}`, `-Mturn_clock=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", `    MaxTime = ${MaxTime}`, `    Bug = "none"`, ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "TurnClock", "Driver.cfg", ["TurnClock.tla"], join(TLA_ROOT, "turn_clock"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on TurnClock.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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

// What the code can see of a model state: everything but the ghost count of
// worked seconds and whether the UI has synced since the last event.
const codeView = (s: Model) =>
  JSON.stringify([s.now, s.turn, s.prompt, s.phase, s.origin, s.opStart, s.compStart, s.started, s.since, s.written]);

// The model counts the summary on a small scale; these are the percentages
// the code is sent and keeps for each level. 100% is shown only while
// saving, so the count itself stops at 99.
const LEVEL_PERCENT = [0, 25, 50, 75, 99];

const active = (phase: string) => ["preparation", "summary", "publication", "stopping"].includes(phase);

// The operations one model step becomes, at the model's time in ms. An
// automatic Begin alternates the two in-turn origins, which behave alike.
function opsFor(label: string, s: Model, t: Model, index: number): Op[] {
  const now = t.now * MS;
  switch (label) {
    case "Sync": return [{ op: "sync", now }];
    case "TurnStart": return [{ op: "turn_start", now }];
    case "TurnEnd": return [{ op: "turn_end", now }];
    case "PromptOpen": return [{ op: "prompt", open: true, now }];
    case "PromptClose": return [{ op: "prompt", open: false, now }];
    case "Begin": return [{ op: "begin", now, origin: t.origin === "manual" ? "manual" : index % 2 === 0 ? "automatic" : "provider_overflow" }];
    case "Advance": return [{ op: "advance", now, stage: t.phase }];
    case "Stop": return [{ op: "stop", now }];
    case "Settle": return [{ op: "settle", now, ok: t.phase === "done" }];
    case "Dismiss": return [{ op: "dismiss", now }];
    // A write that raises the count names its new level; any other changes
    // nothing, as a 0 does.
    case "Write": return [{ op: "write", now, percent: LEVEL_PERCENT[t.fresh > s.fresh ? t.fresh : 0] }];
    case "StaleWrite": return [{ op: "stale_write", now, percent: LEVEL_PERCENT[3] }];
    case "Tick": return [{ op: "read", now }];
    default: throw new Error(`no mapping for model action ${label}`);
  }
}

const initStep = (graph: Graph): Step => ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk", now: MS }] });

function stepsFor(graph: Graph, hops: { from: string; to: string; label: string }[]): Step[] {
  const steps: Step[] = [initStep(graph)];
  hops.forEach((hop, index) => {
    const s = graph.states.get(hop.from)!;
    const t = graph.states.get(hop.to)!;
    steps.push({ ...hop, ops: opsFor(hop.label, s, t, index) });
  });
  return steps;
}

// Each walk picks among the next steps in proportion to
// 1 / (1 + how often their action was taken so far), so rare actions such
// as Dismiss or Stop are exercised as often as a tick.
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
// show. `tamper` expects the turn clock a second ahead after a tick, to
// prove the checks can fail.
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
      const reading = t.since > 0 && t.since < t.now ? t.since : t.now;
      const turnShown = t.started === 0 || t.now < t.started ? null : reading - t.started + (tamper && step.label === "Tick" && t.turn ? 1 : 0);
      expect("turn running", t.turn, real.turn);
      expect("prompt open", t.prompt, real.prompt);
      expect("turn start mark", t.started * MS, real.started_ms);
      expect("wait start mark", t.since * MS, real.waiting_since_ms);
      expect("turn clock seconds", turnShown, real.turn_seconds);
      expect("compaction phase", t.phase, real.phase);
      expect("compaction clock seconds", active(t.phase) ? t.now - t.compStart : null, real.compaction_seconds);
      expect("summary count", LEVEL_PERCENT[t.written], real.written);
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

// One long turn on the real code, off the model's graph: N compactions and N
// prompts spread over 24 hours, events at any millisecond, and a UI sync up
// to one frame (50 ms) after each event. The turn clock must show exactly
// the time the turn ran while the last sync saw nothing waiting, and each
// running compaction the time since it began.
function stress(bin: string, out: string, count: number): boolean {
  const random = rng(options.seed + 1);
  const day = 24 * 3600 * MS;
  const start = 1_700_000_000_000;
  const ops: Op[] = [{ op: "walk", now: start }, { op: "turn_start", now: start }];
  type Expect = { turn_seconds: number; compaction_seconds: number | null } | null;
  const expected: Expect[] = [null, null];
  let now = start;
  let work = 0;
  let held = false;
  let prompt = false;
  let compaction: { began: number } | null = null;
  const waits = () => prompt || compaction !== null;
  const pass = (ms: number) => {
    if (!held) work += ms;
    now += ms;
  };
  const sync = () => {
    held = waits();
    ops.push({ op: "sync", now });
    expected.push({ turn_seconds: Math.floor(work / MS), compaction_seconds: compaction ? Math.floor((now - compaction.began) / MS) : null });
  };
  // The event lands, the clock runs for up to a frame, then the UI syncs.
  const event = (op: Op, apply: () => void = () => {}) => {
    ops.push({ ...op, now });
    expected.push(null);
    apply();
    pass(Math.floor(random() * 51));
    sync();
  };
  const gap = Math.floor(day / (2 * count + 1));
  for (let i = 0; i < count; i += 1) {
    pass(Math.floor(random() * gap));
    event({ op: "begin", origin: i % 2 === 0 ? "automatic" : "provider_overflow" }, () => { compaction = { began: now }; });
    pass(Math.floor(random() * gap / 4));
    event({ op: "advance", stage: "summary" });
    if (random() < 0.5) event({ op: "prompt", open: true }, () => { prompt = true; });
    pass(Math.floor(random() * gap / 4));
    event({ op: "advance", stage: "publication" });
    const ok = random() < 0.8;
    event({ op: "settle", ok }, () => { compaction = null; });
    if (!ok) event({ op: "dismiss" });
    if (prompt) {
      pass(Math.floor(random() * gap / 4));
      event({ op: "prompt", open: false }, () => { prompt = false; });
    }
  }
  pass(day - (now - start) > 0 ? day - (now - start) : 0);
  sync();
  const started = performance.now();
  const results = runLab(bin, ops, out, "turn_clock_stress");
  let mismatches = 0;
  results.forEach((result, i) => {
    const want = expected[i];
    if (result.error) mismatches += 1;
    if (!want) return;
    if (result.turn_seconds !== want.turn_seconds || result.compaction_seconds !== want.compaction_seconds) {
      if (mismatches === 0) console.log(`  op ${i}: want ${JSON.stringify(want)}, code ${JSON.stringify({ turn: result.turn_seconds, compaction: result.compaction_seconds })}`);
      mismatches += 1;
    }
  });
  const last = results[results.length - 1]!;
  console.log(`stress: ${count} compactions, ${ops.length} operations over ${Math.round((now - start) / 3600 / MS)} h, turn clock ${last.turn_seconds} s for ${Math.floor(work / MS)} s worked, ${mismatches} mismatches, ${Math.round(performance.now() - started)} ms`);
  return mismatches === 0;
}

const out = outDir("turn-clock-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "output", "turn_clock.zig");
const lab = buildLab(module, out, "turn_clock_lab");
const graph = await loadGraph(out);
const edgeSet = edgeWalks(graph);
console.log(`edges: ${edgeSet.edges}, ${edgeSet.distinct} the code can tell apart`);
const walks = [...edgeSet.walks, ...randomWalks(graph, options.seed)];
const results = runLab(lab, walkOps(walks), out, "turn_clock_lab");
const outcome = check(walks, graph, results, false);
let ok = report("code", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);
if (options.stress > 0) ok = stress(lab, out, options.stress) && ok;

if (options.selfCheck) {
  // Planted defects in the code, each a line of turn_clock.zig changed.
  const source = readFileSync(module, "utf8");
  const mutants = [
    { name: "waits only on prompts", target: "return operation.active();", planted: "return operation.active() and false;" },
    { name: "holds the clock for feedback on screen", target: "return operation.active();", planted: "return !operation.dismissed;" },
    {
      name: "does not move the clock past a finished wait",
      target: "if (waited > 0 and next.started_ms > 0) next.started_ms += waited;",
      planted: "_ = waited;",
    },
    {
      name: "starts a wait on a turn that is not running",
      target: "if (running and next.waiting_since_ms == 0) next.waiting_since_ms = now_ms;",
      planted: "if ((running or true) and next.waiting_since_ms == 0) next.waiting_since_ms = now_ms;",
    },
    {
      name: "keeps counting while the turn waits",
      target: "if (marks.waiting_since_ms > 0 and marks.waiting_since_ms < now_ms) marks.waiting_since_ms else now_ms;",
      planted: "if (false and marks.waiting_since_ms < now_ms) marks.waiting_since_ms else now_ms;",
    },
    {
      name: "starts the compaction clock a second early",
      target: "return .{ .started_ms = operation.started_at_ms };",
      planted: "return .{ .started_ms = operation.started_at_ms - std.time.ms_per_s };",
    },
  ];
  let mutantsCaught = true;
  const allOps = walkOps(walks);
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target line for "${mutant.name}" is gone from turn_clock.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    cpSync(join(REPO_ROOT, "src", "core", "output", "compaction_activity.zig"), join(dir, "compaction_activity.zig"));
    writeFileSync(join(dir, "turn_clock.zig"), source.replace(mutant.target, mutant.planted));
    const name = `turn_clock_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "turn_clock.zig"), out, name);
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
