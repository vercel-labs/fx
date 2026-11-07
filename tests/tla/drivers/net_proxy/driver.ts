// Walks the proxy connector's core (src/core/shared/net_proxy.zig) along its
// model, tests/tla/net_proxy/NetProxy.tla, with the design's constants.
//
// TLC writes the model's state graph. The driver walks every edge along a
// shortest path from an initial state, then seeded random paths. Each model
// step becomes an operation for lab.zig, which runs the real route, CONNECT
// writer, answer reader, error mapping, and failure log the way
// net_proxy_io.zig, web_fetch, and the gateway use them. After every step
// each connection's phase, route, answer, shown text, and claimed target, the
// wire, the failure records, and the number of claims must match the model's
// next state.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/net_proxy/driver.ts
//   bun tests/tla/drivers/net_proxy/driver.ts --self-check
//   bun tests/tla/drivers/net_proxy/driver.ts --walks 500 --steps 14 --seed 7
//
// Exit codes: 0 every walk matched, 1 a mismatch (or a self-check that was
// not rejected), 2 a toolchain or build failure.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; inits: string[] };
type Op = Record<string, unknown> & { op: string };
type Conn = { target: string; phase: string; route: string; answer: string; shown: string; got: string };
type WireRecord = { c: string; hop: string; kind: string; dest: string };
type Result = { conns: { a: Conn; b: Conn }; wire: WireRecord[]; records: string[]; claimed: number; error: string | null };
type Hop = { from: string; to: string; label: string };
type Walk = { init: string; hops: Hop[] };

const conns = ["a", "b"] as const;
const perConn = ["phase", "route", "answer", "shown", "got"] as const;

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
  steps: option("--steps", 14),
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
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "net_proxy", "--dep", "url_policy",
      `-Mroot=${join(TLA_ROOT, "drivers", "net_proxy", "lab.zig")}`, `-Mnet_proxy=${moduleSource}`,
      `-Murl_policy=${join(REPO_ROOT, "src", "tools", "web", "url_policy.zig")}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string): Promise<Graph> {
  const dir = join(out, "graph");
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", "    UseProxy = TRUE", "    AuthOnConnect = TRUE",
    "    TlsAfterConnect = TRUE", "    NoFallback = TRUE", "    SharedFlag = FALSE", "    PinFetchIp = TRUE",
    "    DetailMode = \"own_target\"", "CHECK_DEADLOCK FALSE", ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "NetProxy", "Driver.cfg", ["NetProxy.tla"], join(TLA_ROOT, "net_proxy"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on NetProxy.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
  const dot = readFileSync(join(dir, "graph.dot"), "utf8");
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  const inits: string[] = [];
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
    if (/style\s*=\s*filled/.test(rest!)) inits.push(id!);
  }
  if (inits.length === 0) fail(2, "the graph has no initial state");
  console.log(`graph: ${states.size} states, ${inits.length} initial, ${run.durationMs} ms`);
  return { states, next, inits };
}

// The connection a step moved: the one whose own fields changed.
function movedConn(from: Model, to: Model): string {
  const moved = conns.filter(c => perConn.some(field => from[field][c] !== to[field][c]));
  if (moved.length !== 1) throw new Error(`a step moved ${moved.length} connections`);
  return moved[0]!;
}

function opFor(hop: Hop, graph: Graph): Op {
  const from = graph.states.get(hop.from)!;
  const to = graph.states.get(hop.to)!;
  const c = movedConn(from, to);
  switch (hop.label) {
    case "Lookup": return { op: "lookup", c };
    case "SendConnect": return { op: "send_connect", c };
    case "ProxyAnswers": return { op: "answer", c, a: to.answer[c] };
    case "TunnelOpens": case "TunnelFails": return { op: "finish_connect", c };
    case "SendStep": return { op: "send", c };
    case "Report": return { op: "report", c };
    default: throw new Error(`no mapping for model action ${hop.label}`);
  }
}

// One walk per edge: the shortest path from an initial state to the edge's
// source, then the edge.
function edgeWalks(graph: Graph): Walk[] {
  const parent = new Map<string, { from: string; label: string } | null>();
  const root = new Map<string, string>();
  const queue: string[] = [];
  for (const init of graph.inits) {
    parent.set(init, null);
    root.set(init, init);
    queue.push(init);
  }
  for (let at = 0; at < queue.length; at += 1) {
    const id = queue[at]!;
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id || parent.has(edge.to)) continue;
      parent.set(edge.to, { from: id, label: edge.label });
      root.set(edge.to, root.get(id)!);
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
      walks.push({ init: root.get(id)!, hops });
    }
  }
  return walks;
}

function randomWalks(graph: Graph, seed: number): Walk[] {
  const random = rng(seed);
  const walks: Walk[] = [];
  for (let w = 0; w < options.walks; w += 1) {
    const init = graph.inits[Math.floor(random() * graph.inits.length)]!;
    const hops: Hop[] = [];
    let at = init;
    for (let i = 0; i < options.steps; i += 1) {
      const edges = (graph.next.get(at) ?? []).filter(edge => edge.to !== at);
      if (edges.length === 0) break;
      const edge = edges[Math.floor(random() * edges.length)]!;
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    walks.push({ init, hops });
  }
  return walks;
}

function runLab(bin: string, walks: Walk[], graph: Graph, out: string, name: string): Result[] {
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  const lines: string[] = [];
  for (const walk of walks) {
    const init = graph.states.get(walk.init)!;
    lines.push(JSON.stringify({ op: "walk", targets: init.target }));
    for (const hop of walk.hops) lines.push(JSON.stringify(opFor(hop, graph)));
  }
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map(line => JSON.parse(line) as Result);
  if (results.length !== lines.length) fail(2, `${name} answered ${results.length} of ${lines.length} operations`);
  return results;
}

const sortWire = (wire: WireRecord[]) =>
  wire.map(w => ({ c: w.c, hop: w.hop, kind: w.kind, dest: w.dest })).map(w => JSON.stringify(w)).sort();

// TLC prints a set of strings as a set; parseValue reads it as an array.
const sortSet = (value: unknown): string[] => [...(Array.isArray(value) ? value : [])].map(String).sort();

type Mismatch = { walk: number; step: number; path: string[]; field: string; model: unknown; real: unknown };

// The refinement mapping: each connection's own fields, the wire as a set,
// the failure records as a set, and the number of claims must equal the
// model's. `tamper` expects a 407 to open the tunnel, to prove the checks can
// fail.
function check(walks: Walk[], graph: Graph, results: Result[], tamper: boolean) {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    r += 1; // the walk's reset
    let failed = false;
    walk.hops.forEach((hop, i) => {
      const result = results[r]!;
      r += 1;
      if (failed) return;
      seen.set(hop.label, (seen.get(hop.label) ?? 0) + 1);
      const t = graph.states.get(hop.to)!;
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, path: walk.hops.slice(0, i + 1).map(x => x.label), field, model, real });
      };
      if (result.error) expect("lab error", null, result.error);
      for (const c of conns) {
        for (const field of perConn) {
          const model = tamper && field === "phase" && hop.label === "TunnelFails" && t.answer[c] === "auth" ? "open" : t[field][c];
          expect(`${c}.${field}`, model, result.conns[c][field]);
        }
      }
      expect("wire", sortWire(t.wire as WireRecord[]), sortWire(result.wire));
      expect("records", sortSet(t.records), [...result.records].sort());
      expect("claimed", sortSet(t.claimed).length, result.claimed);
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

const out = outDir("net-proxy-driver");
const started = performance.now();
const module = join(REPO_ROOT, "src", "core", "shared", "net_proxy.zig");
const lab = buildLab(module, out, "net_proxy_lab");
const graph = await loadGraph(out);
const walks = [...edgeWalks(graph), ...randomWalks(graph, options.seed)];
const results = runLab(lab, walks, graph, out, "net_proxy_lab");
const outcome = check(walks, graph, results, false);
let ok = report("module", walks, outcome);
const coverage = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
console.log(`steps per action: ${coverage}`);
for (const label of ["Lookup", "SendConnect", "ProxyAnswers", "TunnelOpens", "TunnelFails", "SendStep", "Report"]) {
  if (!outcome.seen.has(label)) {
    console.log(`action ${label} was never walked`);
    ok = false;
  }
}

if (options.selfCheck) {
  // Planted defects in the core, each one expression of net_proxy.zig.
  const source = readFileSync(module, "utf8");
  const mutants = [
    {
      name: "opens the tunnel on a 407",
      target: "if (status >= 200 and status < 300) return .ok;",
      planted: "if (status >= 200 and status < 500) return .ok;",
    },
    {
      name: "ignores NO_PROXY",
      target: "if (noProxyMatches(entry, host, port)) return .direct;",
      planted: "if (noProxyMatches(entry, host, port) and port == 0) return .direct;",
    },
    {
      name: "sends CONNECT without Proxy-Authorization",
      target: "if (authorization) |value| try w.print(\"Proxy-Authorization: {s}\\r\\n\", .{value});",
      planted: "_ = authorization;",
    },
    {
      name: "claims a failure logged for another target",
      target: "if (!entry.failure.targetIs(host, port)) continue;",
      planted: "if (!entry.failure.targetIs(host, port) and false) continue;",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target for "${mutant.name}" is gone from net_proxy.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "net_proxy.zig"), source.replace(mutant.target, mutant.planted));
    const name = `net_proxy_lab_mutant_${index}`;
    const bin = buildLab(join(dir, "net_proxy.zig"), out, name);
    const caught = check(walks, graph, runLab(bin, walks, graph, out, name), false).mismatches.length > 0;
    console.log(`self-check: core that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  const tamperCaught = check(walks, graph, results, true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
