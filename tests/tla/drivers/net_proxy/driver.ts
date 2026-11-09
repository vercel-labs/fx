// Walks the proxy connector's core (src/core/shared/net_proxy.zig) along its
// two models, tests/tla/net_proxy/NetProxy.tla (connections) and
// NetProxyEnv.tla (what fx reads from the environment and keeps), with the
// design's constants, and runs the built fx through proxies that misbehave.
// NetProxyCallers.tla (which caller names a proxy failure) is checked on the
// built fx only.
//
// TLC writes each model's state graph. The driver walks every edge along a
// shortest path from an initial state, then seeded random paths. Each model
// step becomes an operation for a small Zig lab, which runs the real code the
// way net_proxy_io.zig, web_fetch, and the gateway use it:
//   lab.zig      the route, the CONNECT writer, the answer reader (interim
//                heads too), the error mapping, the failure log, and the retry
//                notice's short form and status text, with a 253-byte proxy host
//   lab_env.zig  the real parser, reading environment buffers the lab
//                overwrites in place the way a host program's setenv does
// After every step what the real code holds must match the model's next state.
// binary.ts then runs zig-out/bin/fx through a proxy that sends 102 before its
// 200, one that is down, one that answers 502, a proxy whose host name has 253
// bytes, and a proxy URL whose host has an underscore, and has TLC check what
// fx did against the design. It also runs a Grok client version lookup and
// `fx upgrade` behind a proxy that is down, one that refuses CONNECT, one that
// works while the server fails, and none, and has TLC check, against
// tests/tla/net_proxy/NetProxyCallers.tla, which of them name the proxy. A
// web_fetch call goes behind a proxy that is down, one whose host never
// resolves, one that refuses CONNECT, and a relay that closes after the tunnel
// opens, and TLC checks the same law with the error name the platform gave the
// failed dial.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/net_proxy/driver.ts
//   bun tests/tla/drivers/net_proxy/driver.ts --self-check
//   bun tests/tla/drivers/net_proxy/driver.ts --walks 500 --steps 14 --seed 7
//   bun tests/tla/drivers/net_proxy/driver.ts --binary-only   (just the built fx)
//   bun tests/tla/drivers/net_proxy/driver.ts --no-binary     (just the core)
//
// Exit codes: 0 every walk matched, 1 a mismatch (or a self-check that was
// not rejected), 2 a toolchain or build failure.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";
import { runBinaryScenarios } from "./binary";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; inits: string[] };
type Op = Record<string, unknown> & { op: string };
type Conn = { target: string; phase: string; route: string; answer: string; shown: string; got: string; notice: string; ngot: string };
type WireRecord = { c: string; hop: string; kind: string; dest: string };
type Result = { conns: { a: Conn; b: Conn }; wire: WireRecord[]; records: string[]; claimed: number; error: string | null };
type Obs = { http: string; host: string; internal: string };
type EnvResult = {
  snapped: boolean; s_http: string; s_https: string; s_host: string; obs: Obs[];
  parsed: boolean; accepted: boolean; reason: string; error: string | null;
};
type Hop = { from: string; to: string; label: string };
type Walk = { init: string; hops: Hop[] };

const conns = ["a", "b"] as const;
const perConn = ["phase", "route", "answer", "shown", "got", "notice", "ngot"] as const;

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
  binaryOnly: flag("--binary-only"),
  noBinary: flag("--no-binary"),
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

type Lab = { file: string; deps: string[] };
const connLab: Lab = { file: "lab.zig", deps: ["net_proxy", "url_policy"] };
const envLab: Lab = { file: "lab_env.zig", deps: ["net_proxy"] };

function buildLab(lab: Lab, moduleSource: string, out: string, name: string): string {
  const bin = join(out, name);
  const modules: Record<string, string> = {
    net_proxy: moduleSource,
    url_policy: join(REPO_ROOT, "src", "tools", "web", "url_policy.zig"),
  };
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", ...lab.deps.flatMap(dep => ["--dep", dep]),
      `-Mroot=${join(TLA_ROOT, "drivers", "net_proxy", lab.file)}`,
      ...lab.deps.map(dep => `-M${dep}=${modules[dep]}`),
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) fail(2, `building ${name} failed:\n${new TextDecoder().decode(build.stderr)}`);
  return bin;
}

async function loadGraph(out: string, name: string, module: string, constants: string[]): Promise<Graph> {
  const dir = join(out, `graph-${name}`);
  const cfg = ["INIT Init", "NEXT Next", "CONSTANTS", ...constants.map(line => `    ${line}`), "CHECK_DEADLOCK FALSE", ""].join("\n");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, module, "Driver.cfg", [`${module}.tla`], join(TLA_ROOT, "net_proxy"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on ${module}.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
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
  console.log(`graph ${module}: ${states.size} states, ${inits.length} initial, ${run.durationMs} ms`);
  return { states, next, inits };
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

function runLab<T>(bin: string, walks: Walk[], graph: Graph, out: string, name: string, start: (init: Model) => Op, opFor: (hop: Hop, graph: Graph) => Op): T[] {
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  const lines: string[] = [];
  for (const walk of walks) {
    lines.push(JSON.stringify(start(graph.states.get(walk.init)!)));
    for (const hop of walk.hops) lines.push(JSON.stringify(opFor(hop, graph)));
  }
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) fail(2, `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr)}`);
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map(line => JSON.parse(line) as T);
  if (results.length !== lines.length) fail(2, `${name} answered ${results.length} of ${lines.length} operations`);
  return results;
}

type Mismatch = { walk: number; step: number; path: string[]; field: string; model: unknown; real: unknown };
type Outcome = { mismatches: Mismatch[]; seen: Map<string, number> };

// Walks `walks` through `results` (one start result, then one per hop) and
// compares each step with `compare`, which calls `expect(field, model, real)`.
function check<T>(
  walks: Walk[],
  graph: Graph,
  results: T[],
  compare: (hop: Hop, t: Model, result: T, expect: (field: string, model: unknown, real: unknown) => void) => void,
  error: (result: T) => string | null,
): Outcome {
  const mismatches: Mismatch[] = [];
  const seen = new Map<string, number>();
  let r = 0;
  walks.forEach((walk, w) => {
    r += 1; // the walk's start
    let failed = false;
    walk.hops.forEach((hop, i) => {
      const result = results[r]!;
      r += 1;
      if (failed) return;
      seen.set(hop.label, (seen.get(hop.label) ?? 0) + 1);
      const expect = (field: string, model: unknown, real: unknown) => {
        if (failed || JSON.stringify(model) === JSON.stringify(real)) return;
        failed = true;
        mismatches.push({ walk: w, step: i, path: walk.hops.slice(0, i + 1).map(x => x.label), field, model, real });
      };
      expect("lab error", null, error(result));
      compare(hop, graph.states.get(hop.to)!, result, expect);
    });
  });
  return { mismatches, seen };
}

function report(name: string, walks: Walk[], outcome: Outcome): boolean {
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  console.log(`${name}: ${walks.length} walks, ${steps} steps, ${outcome.mismatches.length} mismatching walks`);
  for (const m of outcome.mismatches.slice(0, 3)) {
    console.log(`  walk ${m.walk} step ${m.step}: ${m.field}: model ${JSON.stringify(m.model)}, module ${JSON.stringify(m.real)}`);
    console.log(`    path: ${m.path.join(" > ")}`);
  }
  return outcome.mismatches.length === 0;
}

function coverage(outcome: Outcome, labels: string[]): boolean {
  const steps = [...outcome.seen.entries()].sort((a, b) => b[1] - a[1]).map(([label, count]) => `${label} ${count}`).join(", ");
  console.log(`steps per action: ${steps}`);
  let ok = true;
  for (const label of labels) {
    if (!outcome.seen.has(label)) {
      console.log(`action ${label} was never walked`);
      ok = false;
    }
  }
  return ok;
}

// TLC prints a set of strings as a set; parseValue reads it as an array.
const sortSet = (value: unknown): string[] => [...(Array.isArray(value) ? value : [])].map(String).sort();

// ---- NetProxy.tla: connections ----

const connConstants = [
  "UseProxy = TRUE", "AuthOnConnect = TRUE", "TlsAfterConnect = TRUE", "NoFallback = TRUE", "SharedFlag = FALSE",
  "PinFetchIp = TRUE", "DetailMode = \"own_target\"", "InterimMode = \"skip_not_101\"", "NoticeMode = \"own_target\"",
  "NoticeForm = \"short\"", "LongHost = TRUE",
];

// The connection a step moved: the one whose own fields changed.
function movedConn(from: Model, to: Model): string {
  const moved = conns.filter(c => perConn.some(field => from[field][c] !== to[field][c]));
  if (moved.length !== 1) throw new Error(`a step moved ${moved.length} connections`);
  return moved[0]!;
}

function connOp(hop: Hop, graph: Graph): Op {
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
    case "Notify": return { op: "notify", c };
    default: throw new Error(`no mapping for model action ${hop.label}`);
  }
}

const sortWire = (wire: WireRecord[]) =>
  wire.map(w => ({ c: w.c, hop: w.hop, kind: w.kind, dest: w.dest })).map(w => JSON.stringify(w)).sort();

// The refinement mapping: each connection's own fields, the wire as a set, the
// failure records as a set, and the number of claims must equal the model's.
// `tamper` expects a 407 to open the tunnel, to prove the checks can fail.
function connCheck(walks: Walk[], graph: Graph, results: Result[], tamper: boolean): Outcome {
  return check(walks, graph, results, (hop, t, result, expect) => {
    for (const c of conns) {
      for (const field of perConn) {
        const model = tamper && field === "phase" && hop.label === "TunnelFails" && t.answer[c] === "auth" ? "open" : t[field][c];
        expect(`${c}.${field}`, model, result.conns[c][field]);
      }
    }
    expect("wire", sortWire(t.wire as WireRecord[]), sortWire(result.wire));
    expect("records", sortSet(t.records), [...result.records].sort());
    expect("claimed", sortSet(t.claimed).length, result.claimed);
  }, result => result.error);
}

// ---- NetProxyEnv.tla: the environment ----

const envConstants = [
  "Guard = \"upper_only\"", "BorrowHost = FALSE", "BorrowNoProxy = FALSE", "AcceptsUnderscore = TRUE", "AcceptsBang = FALSE",
  "NamesReasons = TRUE",
];

function envStart(init: Model): Op {
  return { op: "env_reset", rm: init.rm, up: init.up, lo: init.lo, hs: init.hs, ph: init.ph, np: init.np, cls: init.cls };
}

function envOp(hop: Hop, graph: Graph): Op {
  const to = graph.states.get(hop.to)!;
  switch (hop.label) {
    case "Snap": return { op: "env_snap" };
    case "SetHost": return { op: "env_set_host", ph: to.ph };
    case "SetNoProxy": return { op: "env_set_no_proxy", np: to.np };
    case "Route": return { op: "env_route" };
    case "Parse": return { op: "env_parse" };
    default: throw new Error(`no mapping for model action ${hop.label}`);
  }
}

const sortObs = (obs: Obs[]) => obs.map(o => JSON.stringify({ http: o.http, host: o.host, internal: o.internal })).sort();

// What the snapshot holds, read live from its memory, and every route decided
// so far, must equal the model's; s_np is the model's own record of the list
// the snapshot read, which the code shows only through the routes.
function envCheck(walks: Walk[], graph: Graph, results: EnvResult[]): Outcome {
  return check(walks, graph, results, (_hop, t, result, expect) => {
    expect("snapped", t.snapped, result.snapped);
    expect("s_http", t.s_http, result.s_http);
    expect("s_https", t.s_https, result.s_https);
    expect("s_host", t.s_host, result.s_host);
    expect("obs", sortObs(t.obs as Obs[]), sortObs(result.obs));
    expect("parsed", t.parsed, result.parsed);
    expect("accepted", t.accepted, result.accepted);
    expect("reason", t.reason, result.reason);
  }, result => result.error);
}

// ---- main ----

const out = outDir("net-proxy-driver");
const started = performance.now();
if (options.binaryOnly) {
  const passed = await runBinaryScenarios(out, options.selfCheck);
  console.log(`${passed ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
  process.exit(passed ? 0 : 1);
}

const module = join(REPO_ROOT, "src", "core", "shared", "net_proxy.zig");

const connGraph = await loadGraph(out, "conn", "NetProxy", connConstants);
const connWalks = [...edgeWalks(connGraph), ...randomWalks(connGraph, options.seed)];
const connBin = buildLab(connLab, module, out, "net_proxy_lab");
const connStart = (init: Model): Op => ({ op: "walk", targets: init.target });
const runConn = (bin: string, name: string) => runLab<Result>(bin, connWalks, connGraph, out, name, connStart, connOp);
const connOutcome = connCheck(connWalks, connGraph, runConn(connBin, "net_proxy_lab"), false);
let ok = report("connections", connWalks, connOutcome);
ok = coverage(connOutcome, ["Lookup", "SendConnect", "ProxyAnswers", "TunnelOpens", "TunnelFails", "SendStep", "Report", "Notify"]) && ok;

const envGraph = await loadGraph(out, "env", "NetProxyEnv", envConstants);
const envWalks = [...edgeWalks(envGraph), ...randomWalks(envGraph, options.seed)];
const envBin = buildLab(envLab, module, out, "net_proxy_env_lab");
const runEnv = (bin: string, name: string) => runLab<EnvResult>(bin, envWalks, envGraph, out, name, envStart, envOp);
const envOutcome = envCheck(envWalks, envGraph, runEnv(envBin, "net_proxy_env_lab"));
ok = report("environment", envWalks, envOutcome) && ok;
ok = coverage(envOutcome, ["Snap", "SetHost", "SetNoProxy", "Route", "Parse"]) && ok;

if (options.selfCheck) {
  // Planted defects in the core, each one expression of net_proxy.zig, and the
  // lab whose walks must catch it.
  const source = readFileSync(module, "utf8");
  const mutants: { name: string; lab: "conn" | "env"; target: string; planted: string }[] = [
    {
      name: "opens the tunnel on a 407",
      lab: "conn",
      target: "if (status >= 200 and status < 300) return .ok;",
      planted: "if (status >= 200 and status < 500) return .ok;",
    },
    {
      name: "ignores NO_PROXY",
      lab: "conn",
      target: "if (noProxyMatches(entry, host, port)) return .direct;",
      planted: "if (noProxyMatches(entry, host, port) and port == 0) return .direct;",
    },
    {
      name: "sends CONNECT without Proxy-Authorization",
      lab: "conn",
      target: "if (authorization) |value| try w.print(\"Proxy-Authorization: {s}\\r\\n\", .{value});",
      planted: "_ = authorization;",
    },
    {
      name: "claims a failure logged for another target",
      lab: "conn",
      target: "if (!entry.failure.targetIs(host, port)) continue;",
      planted: "if (!entry.failure.targetIs(host, port) and false) continue;",
    },
    {
      name: "refuses an interim head",
      lab: "conn",
      target: "if (status >= 100 and status < 200 and status != 101) continue;",
      planted: "if (status >= 100 and status < 200 and status != 101 and false) continue;",
    },
    {
      name: "skips a 101 as if it were interim",
      lab: "conn",
      target: "if (status >= 100 and status < 200 and status != 101) continue;",
      planted: "if (status >= 100 and status < 200) continue;",
    },
    {
      name: "drops the proxy note from a retry notice",
      lab: "conn",
      target: "        @memcpy(out[len..][0..sentence.len], sentence);\n        return out[0 .. len + sentence.len];",
      planted: "        @memcpy(out[len..][0..sentence.len], sentence);\n        out[len] = '#';\n        return out[0 .. len + sentence.len];",
    },
    {
      name: "keeps a long proxy host whole in the short notice",
      lab: "conn",
      target: "        if (host.len <= room) {\n            try w.writeAll(host);",
      planted: "        if (host.len <= room or room < max_notice_bytes) {\n            try w.writeAll(host);",
    },
    {
      name: "keeps a slice of the environment for the proxy host",
      lab: "env",
      target: "        .host = host,\n        .port = port,",
      planted: "        .host = bare,\n        .port = port,",
    },
    {
      name: "keeps a slice of the environment for a NO_PROXY domain",
      lab: "env",
      target: "parsed.domain = copy;",
      planted: "parsed.domain = if (copy.len == 0) copy else parsed.domain;",
    },
    {
      name: "reads an uppercase HTTP_PROXY under REQUEST_METHOD",
      lab: "env",
      target: ".{ .name = \"HTTP_PROXY\", .value = if (cgi) null else upper_http },",
      planted: ".{ .name = \"HTTP_PROXY\", .value = upper_http },",
    },
    {
      name: "ignores a lowercase http_proxy under REQUEST_METHOD",
      lab: "env",
      target: ".{ .name = \"http_proxy\", .value = env.getenv(\"http_proxy\") },",
      planted: ".{ .name = \"http_proxy\", .value = if (cgi) null else env.getenv(\"http_proxy\") },",
    },
    {
      name: "refuses a proxy host with an underscore",
      lab: "env",
      target: "out.* = if (byte == '_') 'x' else byte;",
      planted: "out.* = byte;",
    },
    {
      name: "names every refusal the same way",
      lab: "env",
      target: "const component = uri.host orelse return refuse(found.name, .no_host, \"\");",
      planted: "const component = uri.host orelse return refuse(found.name, .unreadable_url, \"\");",
    },
  ];
  let mutantsCaught = true;
  mutants.forEach((mutant, index) => {
    if (!source.includes(mutant.target)) fail(2, `self-check: the target for "${mutant.name}" is gone from net_proxy.zig`);
    const dir = join(out, `mutant-${index}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "net_proxy.zig"), source.replace(mutant.target, mutant.planted));
    const name = `net_proxy_lab_mutant_${index}`;
    const bin = buildLab(mutant.lab === "conn" ? connLab : envLab, join(dir, "net_proxy.zig"), out, name);
    const caught = mutant.lab === "conn"
      ? connCheck(connWalks, connGraph, runConn(bin, name), false).mismatches.length > 0
      : envCheck(envWalks, envGraph, runEnv(bin, name)).mismatches.length > 0;
    console.log(`self-check: core that ${mutant.name} ${caught ? "rejected" : "NOT rejected"}`);
    mutantsCaught &&= caught;
  });
  const tamperCaught = connCheck(connWalks, connGraph, runConn(connBin, "net_proxy_lab"), true).mismatches.length > 0;
  console.log(`self-check: tampered expectation ${tamperCaught ? "rejected" : "NOT rejected"}`);
  ok = ok && mutantsCaught && tamperCaught;
}

if (!options.noBinary) ok = (await runBinaryScenarios(out, options.selfCheck)) && ok;

console.log(`${ok ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
process.exit(ok ? 0 : 1);
