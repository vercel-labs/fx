// Walks fx's web search slot state (src/core/tooling/web_search_slots.zig)
// along its model, tests/tla/web_search/WebSearchSlots.tla.
//
// TLC writes the design's state graph. The driver walks to every distinct
// transition the slot state can tell apart along a shortest path, then
// follows seeded random paths. Each model step becomes operations for
// lab.zig, which runs the real module: a request's send reads its team's
// view, a refusal blocks the slot for the request's team, and a team change
// makes the new team current, as a turn's configure does. After every step
// the slot the request carries, the slots a refusal newly blocked (one
// notice each), and what the current team has refused must match the model.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/web_search/driver.ts
//   bun tests/tla/drivers/web_search/driver.ts --self-check
//   bun tests/tla/drivers/web_search/driver.ts --walks 1000 --steps 40 --seed 7
//
// --self-check records each refusal for the team that is current instead of
// the team the request was built for, which is the bug the team key
// prevents; the driver must reject it.
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
type Result = { slot: string | null; newly: string[]; blocked: string[]; error: string | null };
type Hop = { from: string; to: string; label: string };
type Step = Hop & { ops: Op[] };
type Walk = { steps: Step[] };

// The driver's model: the design's constants (web-search-slots.cfg).
const ORDER = ["exa", "native", "parallel"];
const CONSTANTS = [
  "    Agents = {main, child}",
  '    RefusedByInit = {"exa", "native", "parallel"}',
  "    RefusedByOther = {}",
  "    MaxGen = 1",
  "    MaxRequests = 2",
  "    Advance = TRUE",
  "    KeyByTeam = TRUE",
  "    AtomicBlock = TRUE",
];

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

function buildLab(out: string): string {
  const bin = join(out, "web-search-slots-lab");
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "web_search_slots",
      `-Mroot=${join(TLA_ROOT, "drivers", "web_search", "lab.zig")}`,
      `-Mweb_search_slots=${join(REPO_ROOT, "src", "core", "tooling", "web_search_slots.zig")}`,
      "--name", "web-search-slots-lab", `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building the lab failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

// A function over the Agents model values, which TLC prints as
// `(main :> "idle" @@ child :> "sent")`, or any value graph.mjs reads.
function readValue(text: string): unknown {
  const fn = /^\(([\s\S]*)\)$/.exec(text);
  if (!fn) return parseValue(text);
  const record: Record<string, unknown> = {};
  for (const entry of fn[1]!.split("@@")) {
    const pair = /^\s*([A-Za-z_]\w*)\s*:>\s*([\s\S]*?)\s*$/.exec(entry);
    if (!pair) throw new Error(`not a function over names: ${text}`);
    record[pair[1]!] = parseValue(pair[2]!);
  }
  return record;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["SPECIFICATION Spec", "CONSTANTS", ...CONSTANTS, "CONSTRAINT StateBound", "CHECK_DEADLOCK FALSE", ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "WebSearchSlots", "Driver.cfg", ["WebSearchSlots.tla"], join(TLA_ROOT, "web_search"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on WebSearchSlots.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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
      if (!match) continue;
      // notices and teamOf have tuple or number keys, which the driver
      // derives instead of reading.
      try {
        state[match[1]!] = readValue(match[2]!.trim());
      } catch {}
    }
    states.set(id!, state);
    if (/style\s*=\s*filled/.test(rest!)) init = id!;
  }
  if (!init) fail(2, "the graph has no initial state");
  console.log(`graph: ${states.size} states, ${run.durationMs} ms`);
  return { states, next, init };
}

const team = (generation: number) => `team-${generation}`;

// The blocked slots a request built in generation g sees (Eff with the
// team key).
function effective(s: Model, generation: number): string[] {
  const blocked: string[] = s.blockedGen === generation ? s.blocked : [];
  return ORDER.filter((slot) => blocked.includes(slot));
}

function agentWhere(s: Model, t: Model, from: string, to: string): string {
  const agent = Object.keys(t.pc).find((name) => s.pc[name] === from && t.pc[name] === to);
  if (!agent) throw new Error(`no agent moved from ${from} to ${to}`);
  return agent;
}

function opsFor(label: string, s: Model, t: Model): Op[] {
  const current = team(t.gen);
  switch (label) {
    case "Send":
      return [{ op: "send", team: team(s.gen), current }];
    case "BlockAtomic": {
      const agent = agentWhere(s, t, "sent", "idle");
      const owner = options.selfCheck ? s.gen : s.sentGen[agent];
      return [{ op: "block", team: team(owner), slot: s.sentSlot[agent], current }];
    }
    case "SwitchTeam":
      return [{ op: "adopt", team: team(t.gen), current }];
    case "ReplyOk": case "NextRequest":
      return [];
    default:
      throw new Error(`no mapping for model action ${label}`);
  }
}

const initStep = (graph: Graph): Step =>
  ({ label: "Init", from: graph.init, to: graph.init, ops: [{ op: "walk", order: ORDER, current: team(0) }] });

function stepsFor(graph: Graph, hops: Hop[]): Step[] {
  return [initStep(graph), ...hops.map((hop) =>
    ({ ...hop, ops: opsFor(hop.label, graph.states.get(hop.from)!, graph.states.get(hop.to)!) }))];
}

// What the slot state can tell apart: the team, its blocked set, and each
// agent's place and request.
const slotView = (s: Model) => JSON.stringify([s.gen, s.blocked, s.blockedGen, s.pc, s.sentSlot, s.sentGen]);

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
      const key = `${slotView(graph.states.get(id)!)} ${edge.label} ${slotView(graph.states.get(edge.to)!)}`;
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
    walks.push({ steps: stepsFor(graph, hops) });
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

type Mismatch = { walk: number; step: number; label: string; path: string[]; field: string; model: unknown; real: unknown };

function check(walks: Walk[], graph: Graph, results: Result[]): { mismatches: Mismatch[]; seen: Map<string, number> } {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    let failed = false;
    walk.steps.forEach((step, i) => {
      const own = results.slice(r, r + step.ops.length);
      r += step.ops.length;
      if (failed || own.length === 0) return;
      seen.set(step.label, (seen.get(step.label) ?? 0) + 1);
      const s = graph.states.get(step.from)!;
      const t = graph.states.get(step.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, label: step.label, path: walk.steps.slice(0, i + 1).map((x) => x.label), field, model, real });
      };
      const result = own[own.length - 1]!;
      expect("lab error", null, result.error);
      if (step.label === "Send") {
        const agent = agentWhere(s, t, "idle", "sent");
        expect("slot the request carries", t.sentSlot[agent], result.slot);
      }
      if (step.label === "BlockAtomic") {
        const agent = agentWhere(s, t, "sent", "idle");
        const slot = s.sentSlot[agent];
        const generation = s.sentGen[agent];
        const notice = generation === s.gen && !effective(s, generation).includes(slot);
        expect("slots newly blocked (one notice each)", notice ? [slot] : [], result.newly);
      }
      expect("what the current team has refused", effective(t, t.gen), result.blocked);
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

const out = outDir(options.selfCheck ? "web-search-driver-self-check" : "web-search-driver");
const graph = await loadGraph(out);
const bin = buildLab(out);
const covering = edgeWalks(graph);
console.log(`edges: ${covering.edges}, distinct for the slot state: ${covering.distinct}`);
const random = randomWalks(graph, options.seed);
const coverOutcome = check(covering.walks, graph, runLab(bin, covering.walks, out, "cover"));
const randomOutcome = check(random, graph, runLab(bin, random, out, "random"));
const ok = [report("cover", covering.walks, coverOutcome), report("random", random, randomOutcome)].every(Boolean);
const actions = new Map<string, number>();
for (const outcome of [coverOutcome, randomOutcome]) {
  for (const [label, count] of outcome.seen) actions.set(label, (actions.get(label) ?? 0) + count);
}
console.log(`steps checked by action: ${[...actions].map(([label, count]) => `${label}=${count}`).join(" ")}`);
for (const needed of ["Send", "BlockAtomic", "SwitchTeam"]) {
  if (!actions.has(needed)) fail(1, `no walk checked ${needed}`);
}
if (options.selfCheck) {
  if (ok) fail(1, "self-check: the driver accepted refusals recorded for the wrong team");
  console.log("self-check: rejected, as it must be");
  process.exit(0);
}
process.exit(ok ? 0 : 1);
