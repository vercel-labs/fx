// Runs the mod store (`src/core/mods/store.zig`) along every edge of
// `tests/tla/mods/ModStore.tla` (Design "b", Nonideal) through `lab_store.zig`.
//
// Parts:
//   mods-walk  TLC dumps the state graph of ModStore.tla (`N = 2`,
//              `MaxVersion = 2`, `Design = "b"`, `Nonideal = TRUE`), and the
//              driver walks paths covering every edge. Each hop drives
//              `lab_store change` step-by-step, injects `SIGKILL` for `Crash`,
//              and runs `lab_store load` after every hop to verify it matches
//              the model's `Loaded`.
//
// --self-check rejects a tampered expectation and three planted store mutants:
// without the lock, collect deleting the live version, and add replacing an
// existing link.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/mods/driver.ts mods-walk --self-check
//
// Exit codes: 0 accepted (and all self-checks rejected), 1 mismatch or
// self-check not rejected, 2 tool or setup failure.

import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; inits: string[] };
type Hop = { from: string; to: string; label: string };
type Walk = { init: string; hops: Hop[] };
type LoadedView = { state: "none" } | { state: "bad" } | { state: "mod"; v: number; off: boolean };
type Patch = { target: string; planted: string };
type Mutant = { name: string; patches: Patch[] };

const tlaDir = join(TLA_ROOT, "mods");
const storeModule = join(REPO_ROOT, "src", "core", "mods", "store.zig");
const manifestModule = join(REPO_ROOT, "src", "core", "mods", "manifest.zig");
const labSource = join(TLA_ROOT, "drivers", "mods", "lab_store.zig");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const parts = ["mods-walk"].filter((part) => process.argv.includes(part));
const options = {
  parts: parts.length > 0 ? parts : ["mods-walk"],
  selfCheck: process.argv.includes("--self-check"),
  walks: option("--walks", 300),
  steps: option("--steps", 14),
  seed: option("--seed", 1),
  jobs: option("--jobs", 16),
};

const REQUIRED_ACTIONS = ["Start", "TakeLock", "CopyStart", "CopyDone", "Switch", "Collect", "Crash", "Load"];

const STORE_MUTANTS: Mutant[] = [
  {
    name: "runs without taking the lock",
    patches: [{ target: "try acquireModLock(store, name)", planted: "LockAttempt{ .acquired = .{} }" }],
  },
  {
    name: "collects the version folder named by the live link",
    patches: [{
      target: "if (isLiveStoreFolder(live_on, live_off, entry.name)) continue;",
      planted: "if (false and isLiveStoreFolder(live_on, live_off, entry.name)) continue;",
    }],
  },
  {
    name: "replaces an existing link on add",
    patches: [
      { target: "if (kind == .add and seen != .none) return .exists;", planted: "if (false and kind == .add and seen != .none) return .exists;" },
      {
        target:
          "            createAddLink(root_dir, io, target_rel, name) catch |err| switch (err) {\n" +
          "                error.PathAlreadyExists => return .exists,\n" +
          "                else => return err,\n" +
          "            };",
        planted: "            try root_dir.symLinkAtomic(io, target_rel, name, .{ .is_directory = true });",
      },
    ],
  },
];

function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

async function pool<T>(count: number, jobs: number, run: (index: number) => Promise<T>): Promise<T[]> {
  const results: T[] = new Array(count);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, jobs) }, async () => {
    while (next < count) {
      const index = next++;
      results[index] = await run(index);
    }
  }));
  return results;
}

function buildLab(storeSourcePath: string, out: string, name: string): string | null {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "store",
      `-Mroot=${labSource}`, `-Mstore=${storeSourcePath}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) {
    console.log(`building ${name} failed:\n${new TextDecoder().decode(build.stderr).slice(0, 2000)}`);
    return null;
  }
  return bin;
}

function parseDotGraph(path: string): Graph | null {
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  const inits: string[] = [];
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const from = edge[1]!;
      const to = edge[2]!;
      const label = edge[3]!;
      if (from === to) continue;
      if (!next.has(from)) next.set(from, []);
      next.get(from)!.push({ to, label });
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const id = node[1]!;
    const state: Model = {};
    for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(id, state);
    if (/style\s*=\s*filled/.test(node[3]!)) inits.push(id);
  }
  if (inits.length === 0) return null;
  return { states, next, inits };
}

async function loadModStoreGraph(out: string): Promise<Graph | null> {
  const dir = join(out, "mods-graph");
  mkdirSync(dir, { recursive: true });
  const baseCfg = readFileSync(join(tlaDir, "mods-design-b.cfg"), "utf8");
  const driverCfg = baseCfg
    .replace(/N\s*=\s*\d+/, "N = 2")
    .replace(/MaxVersion\s*=\s*\d+/, "MaxVersion = 2")
    .replace(/Nonideal\s*=\s*(?:TRUE|FALSE)/, "Nonideal = TRUE");
  writeFileSync(join(dir, "Driver.cfg"), driverCfg);

  const run = await runTlc(dir, "ModStore", "Driver.cfg", ["ModStore.tla"], tlaDir, ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) {
    console.log(`TLC failed on ModStore.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
    return null;
  }
  const graph = parseDotGraph(join(dir, "graph.dot"));
  if (!graph) {
    console.log("mods-walk: the graph has no initial states");
    return null;
  }
  console.log(`mods-walk: graph of ${graph.states.size} states (${graph.inits.length} initial), ${run.durationMs} ms`);
  return graph;
}

// Covers every non-self-loop edge in the state graph using shortest paths from
// the matching initial state (deepest targets first so shared prefixes are
// marked covered once), plus explicit Load checks and seeded random walks.
function walksOf(graph: Graph): Walk[] {
  const parent = new Map<string, { from: string; label: string } | null>();
  const initOf = new Map<string, string>();
  const queue: string[] = [];
  for (const initId of graph.inits) {
    parent.set(initId, null);
    initOf.set(initId, initId);
    queue.push(initId);
  }
  for (let at = 0; at < queue.length; at += 1) {
    const from = queue[at]!;
    for (const edge of graph.next.get(from) ?? []) {
      if (parent.has(edge.to)) continue;
      parent.set(edge.to, { from, label: edge.label });
      initOf.set(edge.to, initOf.get(from)!);
      queue.push(edge.to);
    }
  }

  const covered = new Set<string>();
  const walks: Walk[] = [];

  for (const initId of graph.inits) {
    walks.push({ init: initId, hops: [{ from: initId, to: initId, label: "Load" }] });
  }

  for (let idx = queue.length - 1; idx >= 0; idx -= 1) {
    const id = queue[idx]!;
    for (const edge of graph.next.get(id) ?? []) {
      const key = `${id}>${edge.to}>${edge.label}`;
      if (covered.has(key)) continue;
      covered.add(key);
      const hops: Hop[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let cur = id; parent.get(cur); cur = parent.get(cur)!.from) {
        const p = parent.get(cur)!;
        covered.add(`${p.from}>${cur}>${p.label}`);
        hops.unshift({ from: p.from, to: cur, label: p.label });
      }
      walks.push({ init: initOf.get(id)!, hops });
    }
  }

  const random = generator(options.seed);
  for (let w = 0; w < options.walks; w += 1) {
    const init = graph.inits[Math.floor(random() * graph.inits.length)]!;
    const hops: Hop[] = [];
    let at = init;
    for (let i = 0; i < options.steps; i += 1) {
      const edges = graph.next.get(at) ?? [];
      if (edges.length === 0) break;
      const edge = edges[Math.floor(random() * edges.length)]!;
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    walks.push({ init, hops });
  }
  return walks;
}

function modelLoaded(state: Model): LoadedView {
  const linkOn: number = state.link_on;
  const linkOff: number = state.link_off;
  const folders: Array<{ v: number; complete: boolean }> = state.folders;
  if (linkOn !== 0 && linkOff !== 0) return { state: "bad" };
  if (linkOn !== 0) {
    const f = folders[linkOn - 1]!;
    return f.complete ? { state: "mod", v: f.v, off: false } : { state: "bad" };
  }
  if (linkOff !== 0) {
    const f = folders[linkOff - 1]!;
    return f.complete ? { state: "mod", v: f.v, off: true } : { state: "bad" };
  }
  return { state: "none" };
}

class LineProc {
  proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private decoder = new TextDecoder();
  private buf = "";

  constructor(cmd: string[]) {
    this.proc = Bun.spawn(cmd, { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    this.reader = this.proc.stdout.getReader();
  }

  async readLine(timeoutMs = 5000): Promise<string | null> {
    const deadline = performance.now() + timeoutMs;
    for (;;) {
      const nl = this.buf.indexOf("\n");
      if (nl >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        return line;
      }
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw new Error("timed out waiting for lab_store output");
      const chunk = await Promise.race([
        this.reader.read(),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out waiting for lab_store output")), remaining)),
      ]);
      if (chunk.done) return null;
      this.buf += this.decoder.decode(chunk.value, { stream: true });
    }
  }

  sendLine() {
    this.proc.stdin.write("\n");
    this.proc.stdin.flush();
  }

  async killAndWait() {
    try {
      this.proc.kill("SIGKILL");
    } catch {}
    await this.proc.exited;
  }
}

function runLabLoad(bin: string, root: string): { ok: true; view: LoadedView } | { ok: false; detail: string } {
  const res = Bun.spawnSync([bin, "load", root, "m"], { stdout: "pipe", stderr: "pipe" });
  if (res.exitCode !== 0) {
    return { ok: false, detail: `lab_store load exited ${res.exitCode}: ${new TextDecoder().decode(res.stderr).trim()}` };
  }
  const text = new TextDecoder().decode(res.stdout).trim();
  try {
    return { ok: true, view: JSON.parse(text) as LoadedView };
  } catch {
    return { ok: false, detail: `lab_store load returned invalid JSON: ${JSON.stringify(text)}` };
  }
}

async function runSetupChange(bin: string, args: string[]): Promise<string | null> {
  const proc = new LineProc([bin, ...args]);
  try {
    for (;;) {
      const line = await proc.readLine();
      if (line === null) return `setup ${args.join(" ")} ended without result`;
      if (line.startsWith("step ")) {
        proc.sendLine();
        continue;
      }
      if (line === "result ok") {
        const code = await proc.proc.exited;
        return code === 0 ? null : `setup ${args.join(" ")} exited ${code}`;
      }
      return `setup ${args.join(" ")} got unexpected line: ${line}`;
    }
  } finally {
    await proc.killAndWait();
  }
}

function createSources(dir: string): [string, string] {
  const s1 = join(dir, "src1");
  const s2 = join(dir, "src2");
  mkdirSync(join(s1, "bin"), { recursive: true });
  writeFileSync(join(s1, "mod.json"), JSON.stringify({ name: "m", version: "1", description: "v1" }));
  writeFileSync(join(s1, "bin", "helper"), "#!/bin/sh\necho v1\n");
  writeFileSync(join(s1, "README.txt"), "mod m v1\n");

  mkdirSync(join(s2, "notes"), { recursive: true });
  writeFileSync(join(s2, "mod.json"), JSON.stringify({ name: "m", version: "2", description: "v2" }));
  writeFileSync(join(s2, "notes", "info.txt"), "mod m v2\n");
  return [s1, s2];
}

function sameLoaded(a: LoadedView, b: LoadedView): boolean {
  if (a.state !== b.state) return false;
  if (a.state === "mod" && b.state === "mod") return a.v === b.v && a.off === b.off;
  return true;
}

function changedInstaller(from: Model, to: Model, pred: (pcFrom: string, pcTo: string) => boolean): number {
  const found: number[] = [];
  for (let i = 0; i < from.pc.length; i += 1) {
    if (pred(from.pc[i]!, to.pc[i]!)) found.push(i);
  }
  if (found.length !== 1) throw new Error(`expected 1 changed installer, got ${found.length}`);
  return found[0]!;
}

async function runOneWalk(
  bin: string,
  walk: Walk,
  walkIndex: number,
  graph: Graph,
  sources: [string, string],
  scratchBase: string,
  tamper: boolean,
): Promise<string | null> {
  const root = mkdtempSync(join(scratchBase, `w${walkIndex}-`));
  const procs: Array<LineProc | null> = [null, null];
  const trace: string[] = [];

  const checkLoaded = (targetState: Model, where: string): string | null => {
    const got = runLabLoad(bin, root);
    if (!got.ok) return `walk ${walkIndex} ${where}: ${got.detail}`;
    let expected = modelLoaded(targetState);
    if (tamper) {
      expected = expected.state === "none" ? { state: "mod", v: 1, off: false } : { state: "none" };
    }
    if (!sameLoaded(got.view, expected)) {
      return `walk ${walkIndex} ${where}: load mismatch: model ${JSON.stringify(expected)}, lab ${JSON.stringify(got.view)}`;
    }
    return null;
  };

  try {
    const initState = graph.states.get(walk.init)!;
    const initCommitted = initState.committed;
    if (initCommitted.v === 1) {
      const err1 = await runSetupChange(bin, ["change", root, "add", "m", sources[0]]);
      if (err1) return `walk ${walkIndex} init: ${err1}`;
      if (initCommitted.off) {
        const err2 = await runSetupChange(bin, ["change", root, "disable", "m"]);
        if (err2) return `walk ${walkIndex} init: ${err2}`;
      }
    }
    const initLoadErr = checkLoaded(initState, "init");
    if (initLoadErr) return initLoadErr;

    for (let stepIdx = 0; stepIdx < walk.hops.length; stepIdx += 1) {
      const hop = walk.hops[stepIdx]!;
      const from = graph.states.get(hop.from)!;
      const to = graph.states.get(hop.to)!;
      trace.push(hop.label);
      const where = `step ${stepIdx} (${trace.join(" > ")})`;

      switch (hop.label) {
        case "Start": {
          const idx = changedInstaller(from, to, (a, b) => a === "idle" && b === "lock");
          const opName: string = to.op[idx]!;
          const ver: number = to.ver[idx]!;
          const cmd = [bin, "change", root, opName, "m"];
          if (opName === "add" || opName === "update") cmd.push(sources[ver - 1]!);
          const proc = new LineProc(cmd);
          procs[idx] = proc;
          const line = await proc.readLine();
          if (line !== "step start") {
            return `walk ${walkIndex} ${where}: installer ${idx + 1} expected "step start", got ${JSON.stringify(line)}`;
          }
          break;
        }
        case "TakeLock":
        case "CopyStart":
        case "CopyDone":
        case "Switch":
        case "Collect": {
          const expectedPrev: Record<string, string> = {
            TakeLock: "lock",
            CopyStart: "copy",
            CopyDone: "copied",
            Switch: "switched",
            Collect: "collect",
          };
          const idx = changedInstaller(from, to, (a, b) => a === expectedPrev[hop.label] && b !== a);
          const proc = procs[idx];
          if (!proc) return `walk ${walkIndex} ${where}: installer ${idx + 1} is not running`;
          proc.sendLine();
          const line = await proc.readLine();

          let expectedLine: string;
          let finishes = false;
          if (hop.label === "TakeLock") {
            if (to.pc[idx] === "done") {
              expectedLine = `result ${to.result[idx]}`;
              finishes = true;
            } else {
              expectedLine = "step locked";
            }
          } else if (hop.label === "CopyStart") {
            expectedLine = "step copy_started";
          } else if (hop.label === "CopyDone") {
            expectedLine = "step copy_done";
          } else if (hop.label === "Switch") {
            expectedLine = "step switched";
          } else {
            expectedLine = `result ${to.result[idx]}`;
            finishes = true;
          }

          if (line !== expectedLine) {
            return `walk ${walkIndex} ${where}: installer ${idx + 1} expected ${JSON.stringify(expectedLine)}, got ${JSON.stringify(line)}`;
          }
          if (finishes) {
            const exitCode = await proc.proc.exited;
            procs[idx] = null;
            if (exitCode !== 0) {
              return `walk ${walkIndex} ${where}: installer ${idx + 1} exited ${exitCode}`;
            }
          }
          break;
        }
        case "Crash": {
          const idx = changedInstaller(from, to, (a, b) => a !== "crashed" && b === "crashed");
          const proc = procs[idx];
          if (!proc) return `walk ${walkIndex} ${where}: installer ${idx + 1} is not running`;
          await proc.killAndWait();
          procs[idx] = null;
          break;
        }
        case "Load": {
          break;
        }
        default:
          return `walk ${walkIndex} ${where}: unknown model action ${hop.label}`;
      }

      const loadErr = checkLoaded(to, where);
      if (loadErr) return loadErr;
    }
    return null;
  } catch (err) {
    return `walk ${walkIndex} (${trace.join(" > ")}): ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    for (const proc of procs) {
      if (proc) await proc.killAndWait();
    }
    rmSync(root, { recursive: true, force: true });
  }
}

async function runWalks(
  bin: string,
  walks: Walk[],
  graph: Graph,
  sources: [string, string],
  scratchBase: string,
  tamper: boolean,
  stopOnFirst: boolean,
): Promise<{ mismatches: string[] }> {
  const mismatches: string[] = [];
  let next = 0;
  let stopped = false;

  await Promise.all(Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (!stopped && next < walks.length) {
      const idx = next++;
      const err = await runOneWalk(bin, walks[idx]!, idx, graph, sources, scratchBase, tamper);
      if (err) {
        mismatches.push(err);
        if (stopOnFirst) stopped = true;
      }
    }
  }));
  return { mismatches };
}

async function modsWalkPart(out: string): Promise<number> {
  const lab = buildLab(storeModule, out, "lab_store");
  const graph = await loadModStoreGraph(out);
  if (!lab || !graph) return 2;

  const walks = walksOf(graph);
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  const walked = new Set(walks.flatMap((w) => w.hops.map((h) => h.label)));
  for (const action of REQUIRED_ACTIONS) {
    if (!walked.has(action)) {
      console.log(`mods-walk: action ${action} was never walked`);
      return 1;
    }
  }

  const scratchBase = mkdtempSync(join(tmpdir(), "fx-mods-walk-"));
  try {
    const sourcesDir = join(out, "sources");
    mkdirSync(sourcesDir, { recursive: true });
    const sources = createSources(sourcesDir);

    const started = performance.now();
    const { mismatches } = await runWalks(lab, walks, graph, sources, scratchBase, false, false);
    const elapsed = ((performance.now() - started) / 1000).toFixed(1);
    console.log(`mods-walk: ${walks.length} walks, ${steps} steps, ${mismatches.length} mismatches in ${elapsed}s`);
    if (mismatches.length > 0) {
      console.log(`first mismatch: ${mismatches[0]}`);
      return 1;
    }
    console.log("mods-walk: ACCEPTED");

    if (options.selfCheck) {
      const tampered = await runWalks(lab, walks.slice(0, 10), graph, sources, scratchBase, true, true);
      const tamperedRejected = tampered.mismatches.length > 0;
      console.log(`self-check: mods-walk, tampered expectation ${tamperedRejected ? "rejected" : "NOT rejected"}`);
      let allCaught = tamperedRejected;

      const originalSource = readFileSync(storeModule, "utf8");
      for (const [index, mutant] of STORE_MUTANTS.entries()) {
        let patched = originalSource;
        let missingTarget = false;
        for (const patch of mutant.patches) {
          if (!patched.includes(patch.target)) {
            console.log(`self-check: target missing in store.zig for "${mutant.name}": ${patch.target}`);
            missingTarget = true;
            break;
          }
          patched = patched.replace(patch.target, patch.planted);
        }
        if (missingTarget) {
          allCaught = false;
          continue;
        }
        const mutantDir = join(out, `mutant-${index}`);
        mkdirSync(mutantDir, { recursive: true });
        const mutantStore = join(mutantDir, "store.zig");
        writeFileSync(mutantStore, patched);
        copyFileSync(manifestModule, join(mutantDir, "manifest.zig"));

        const mutantBin = buildLab(mutantStore, out, `lab_store_mutant_${index}`);
        if (!mutantBin) {
          allCaught = false;
          continue;
        }
        const mutantRun = await runWalks(mutantBin, walks, graph, sources, scratchBase, false, true);
        const rejected = mutantRun.mismatches.length > 0;
        console.log(`self-check: mods-walk that ${mutant.name} ${rejected ? "rejected" : "NOT rejected"}`);
        allCaught &&= rejected;
      }
      if (!allCaught) return 1;
    }

    return 0;
  } finally {
    rmSync(scratchBase, { recursive: true, force: true });
  }
}

async function main(): Promise<number> {
  const out = outDir("mods");
  let code = 0;
  if (options.parts.includes("mods-walk")) {
    const partCode = await modsWalkPart(out);
    if (partCode !== 0) code = partCode;
  }
  return code;
}

process.exit(await main());
