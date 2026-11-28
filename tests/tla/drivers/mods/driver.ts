// Runs the mod store (`src/core/mods/store.zig`) along `ModStore.tla`, the
// pin protocol (`src/core/mods/pins.zig` + `store.zig`) along `ModUse.tla`, and
// mod MCP servers (`src/core/mcp_host/runtime.zig` + `src/mcp/engine.zig`)
// along `ModServe.tla`.
//
// Parts:
//   mods-walk   TLC dumps ModStore.tla (`N = 2`, `MaxVersion = 2`, `Design = "b"`,
//               `Nonideal = TRUE`), walked through `lab_store.zig` with `SIGKILL`.
//   use-walk    TLC dumps ModUse.tla (`NR = 2`, `MaxVersion = 3`, `Design = "pin"`),
//               walked through `lab_use.zig` with two readers and `SIGKILL`.
//   serve-walk  TLC dumps ModServe.tla (`NR = 2`, `MaxVersion = 3`, `MaxRetire = 2`),
//               walked through `lab_serve.zig` (`mcp_host.Runtime` + `Engine`) and
//               `fixtures/mod-stdio-server.ts`, plus curated cases for
//               release_on_reload, release_on_first_exit, mixed v1/v2, crash
//               cleanup, and detached UnusedVersionsGo.
//
// --self-check rejects tampered expectations and planted mutants per walk.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/mods/driver.ts --self-check
//   bun tests/tla/drivers/mods/driver.ts mods-walk --self-check
//   bun tests/tla/drivers/mods/driver.ts use-walk --self-check
//   bun tests/tla/drivers/mods/driver.ts serve-walk --self-check
//
// Exit codes: 0 accepted (and all self-checks rejected), 1 mismatch or
// self-check not rejected, 2 tool or setup failure.

import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
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
type Patch = { file: "store" | "pins" | "runtime"; target: string; planted: string };
type Mutant = { name: string; patches: Patch[] };

const tlaDir = join(TLA_ROOT, "mods");
const storeModule = join(REPO_ROOT, "src", "core", "mods", "store.zig");
const pinsModule = join(REPO_ROOT, "src", "core", "mods", "pins.zig");
const manifestModule = join(REPO_ROOT, "src", "core", "mods", "manifest.zig");
const labStoreSource = join(TLA_ROOT, "drivers", "mods", "lab_store.zig");
const labUseSource = join(TLA_ROOT, "drivers", "mods", "lab_use.zig");
const labServeSource = join(TLA_ROOT, "drivers", "mods", "lab_serve.zig");
const serveFixturePath = join(TLA_ROOT, "drivers", "mods", "fixtures", "mod-stdio-server.ts");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const ALL_PARTS = ["mods-walk", "use-walk", "serve-walk"] as const;
const selectedParts = ALL_PARTS.filter((part) => process.argv.includes(part));
const options = {
  parts: selectedParts.length > 0 ? selectedParts : [...ALL_PARTS],
  selfCheck: process.argv.includes("--self-check"),
  planOnly: process.argv.includes("--plan"),
  walks: option("--walks", 300),
  serveWalks: option("--serve-walks", 20),
  steps: option("--steps", 14),
  serveSteps: option("--serve-steps", 12),
  seed: option("--seed", 1),
  jobs: option("--jobs", 16),
};

const REQUIRED_STORE_ACTIONS = ["Start", "TakeLock", "CopyStart", "CopyDone", "Switch", "Collect", "Crash", "Load"];
const REQUIRED_USE_ACTIONS = ["Install", "Remove", "Cleanup", "Start", "Resolve", "Lock", "Check", "StartUse", "EndUse", "Reload", "Exit"];
const REQUIRED_SERVE_ACTIONS = ["Install", "Remove", "Cleanup", "Start", "Reload", "StartServer", "StopServer", "RetireDone", "Exit", "Crash", "DyingDone"];

const STORE_MUTANTS: Mutant[] = [
  {
    name: "runs without taking the lock",
    patches: [{ file: "store", target: "try acquireModLock(store, name)", planted: "LockAttempt{ .acquired = .{} }" }],
  },
  {
    name: "collects the version folder named by the live link",
    patches: [{
      file: "store",
      target: "if (isLiveStoreFolder(live_on, live_off, entry.name)) continue;",
      planted: "if (false and isLiveStoreFolder(live_on, live_off, entry.name)) continue;",
    }],
  },
  {
    name: "replaces an existing link on add",
    patches: [
      { file: "store", target: "if (kind == .add and seen != .none) return .exists;", planted: "if (false and kind == .add and seen != .none) return .exists;" },
      {
        file: "store",
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

const USE_MUTANTS: Mutant[] = [
  {
    name: "skips the exclusive try-lock during cleanup",
    patches: [{
      file: "store",
      target: "const lock_attempt = try pins.tryAcquireExclusive(io, pins_dir, folder_name);",
      planted: "const lock_attempt = pins.ExclusiveAttempt{ .acquired = try pins_dir.createFile(io, folder_name, .{ .read = true, .truncate = false }) };",
    }],
  },
  {
    name: "pins without checking folder existence after locking",
    patches: [{
      file: "pins",
      target: "if (!try versionDirExists(root_dir, io, folder_name)) {",
      planted: "if (false and !try versionDirExists(root_dir, io, folder_name)) {",
    }],
  },
  {
    name: "keeps the old pin after reload",
    patches: [{
      file: "pins",
      target:
        "        .pinned, .not_installed => {\n" +
        "            if (old_pin.*) |*old| {\n" +
        "                old.release(alloc, ops.io);\n" +
        "                old_pin.* = null;\n" +
        "            }\n" +
        "        },",
      planted: "        .pinned, .not_installed => { _ = old_pin; },",
    }],
  },
];

const SERVE_MUTANTS: Mutant[] = [
  {
    name: "releases a version pin on reload while a retired slot still runs",
    patches: [{
      file: "runtime",
      target: "                if (hv.in_list or hv.slots > 0) {",
      planted: "                if (hv.in_list) {",
    }],
  },
  {
    name: "releases a version pin on the first destroyed slot",
    patches: [{
      file: "runtime",
      target: "                if (hv.slots > 0) hv.slots -= 1;",
      planted: "                hv.slots = 0;",
    }],
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

function buildLab(sourcePath: string, storeSourcePath: string, out: string, name: string): string | null {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", "store",
      `-Mroot=${sourcePath}`, `-Mstore=${storeSourcePath}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) {
    console.log(`building ${name} failed:\n${new TextDecoder().decode(build.stderr).slice(0, 2000)}`);
    return null;
  }
  return bin;
}

function buildMutantStore(mutant: Mutant, mutantDir: string): string | null {
  mkdirSync(mutantDir, { recursive: true });
  let storeSrc = readFileSync(storeModule, "utf8");
  let pinsSrc = readFileSync(pinsModule, "utf8");

  for (const patch of mutant.patches) {
      if (patch.file === "store") {
        if (!storeSrc.includes(patch.target)) {
          console.log(`self-check: target missing in store.zig for "${mutant.name}": ${patch.target}`);
          return null;
        }
        storeSrc = storeSrc.replaceAll(patch.target, patch.planted);
      } else {
        if (!pinsSrc.includes(patch.target)) {
          console.log(`self-check: target missing in pins.zig for "${mutant.name}": ${patch.target}`);
          return null;
        }
        pinsSrc = pinsSrc.replaceAll(patch.target, patch.planted);
      }
  }

  const mutantStore = join(mutantDir, "store.zig");
  writeFileSync(mutantStore, storeSrc);
  writeFileSync(join(mutantDir, "pins.zig"), pinsSrc);
  copyFileSync(manifestModule, join(mutantDir, "manifest.zig"));
  return mutantStore;
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
function walksOf(graph: Graph, includeLoadInit = true): Walk[] {
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

  if (includeLoadInit) {
    for (const initId of graph.inits) {
      walks.push({ init: initId, hops: [{ from: initId, to: initId, label: "Load" }] });
    }
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

  constructor(cmd: string[], env?: Record<string, string>) {
    this.proc = Bun.spawn(cmd, { stdin: "pipe", stdout: "pipe", stderr: "pipe", env });
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

  sendText(text: string) {
    this.proc.stdin.write(text);
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
  const lab = buildLab(labStoreSource, storeModule, out, "lab_store");
  const graph = await loadModStoreGraph(out);
  if (!lab || !graph) return 2;

  const walks = walksOf(graph);
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  const walked = new Set(walks.flatMap((w) => w.hops.map((h) => h.label)));
  for (const action of REQUIRED_STORE_ACTIONS) {
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

      for (const [index, mutant] of STORE_MUTANTS.entries()) {
        const mutantStore = buildMutantStore(mutant, join(out, `store-mutant-${index}`));
        if (!mutantStore) {
          allCaught = false;
          continue;
        }
        const mutantBin = buildLab(labStoreSource, mutantStore, out, `lab_store_mutant_${index}`);
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

function tokenOf(v: number): string {
  return String(v).padStart(16, "0");
}

function versionFromToken(token: string): number {
  const n = Number(token);
  if (!Number.isInteger(n) || n < 1) throw new Error(`unexpected token ${JSON.stringify(token)}`);
  return n;
}

function createUseSources(dir: string): [string, string, string] {
  const out: string[] = [];
  for (const v of [1, 2, 3]) {
    const src = join(dir, `src${v}`);
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "mod.json"), JSON.stringify({ name: "m", version: String(v), description: `v${v}` }));
    writeFileSync(join(src, "marker.txt"), `${v}\n`);
    out.push(src);
  }
  return [out[0]!, out[1]!, out[2]!];
}

async function loadModUseGraph(out: string): Promise<Graph | null> {
  const dir = join(out, "use-graph");
  mkdirSync(dir, { recursive: true });
  copyFileSync(join(tlaDir, "mods-use-pin.cfg"), join(dir, "mods-use-pin.cfg"));
  const run = await runTlc(dir, "ModUse", "mods-use-pin.cfg", ["ModUse.tla"], tlaDir, ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) {
    console.log(`TLC failed on ModUse.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
    return null;
  }
  const graph = parseDotGraph(join(dir, "graph.dot"));
  if (!graph) {
    console.log("use-walk: the graph has no initial states");
    return null;
  }
  console.log(`use-walk: graph of ${graph.states.size} states (${graph.inits.length} initial), ${run.durationMs} ms`);
  return graph;
}

function inspectDisk(root: string): { link: number; present: number[] } {
  let link = 0;
  try {
    const target = readlinkSync(join(root, "m"));
    const match = /^\.store\/m-([0-9a-f]{16})$/.exec(target);
    if (!match) throw new Error(`bad link target ${JSON.stringify(target)}`);
    link = versionFromToken(match[1]!);
  } catch (err: any) {
    if (err?.code !== "ENOENT") throw err;
  }

  const present: number[] = [];
  try {
    for (const name of readdirSync(join(root, ".store"))) {
      const match = /^m-([0-9a-f]{16})$/.exec(name);
      if (match) present.push(versionFromToken(match[1]!));
    }
  } catch (err: any) {
    if (err?.code !== "ENOENT") throw err;
  }
  present.sort((a, b) => a - b);
  return { link, present };
}

async function runChangerCmd(proc: LineProc, cmd: string, expectedResult = "result ok"): Promise<string | null> {
  proc.sendText(`${cmd}\n`);
  const line = await proc.readLine();
  if (line !== expectedResult) {
    return `${cmd} expected ${JSON.stringify(expectedResult)}, got ${JSON.stringify(line)}`;
  }
  return null;
}

function changedReader(from: Model, to: Model, pred: (rpcFrom: string, rpcTo: string) => boolean): number {
  const found: number[] = [];
  for (let i = 0; i < from.rpc.length; i += 1) {
    if (pred(from.rpc[i]!, to.rpc[i]!)) found.push(i);
  }
  if (found.length !== 1) throw new Error(`expected 1 changed reader, got ${found.length}`);
  return found[0]!;
}

function pinnedOldVersion(state: Model): number | null {
  const link: number = state.link;
  const present: number[] = state.present;
  const pins: Record<string, number[]> | number[][] = state.pins;
  for (const v of present) {
    if (v === link) continue;
    const holders = Array.isArray(pins) ? pins[v - 1] : pins[String(v)];
    if (holders && holders.length > 0) return v;
  }
  return null;
}

async function runOneUseWalk(
  bin: string,
  walk: Walk,
  walkIndex: number,
  graph: Graph,
  sources: [string, string, string],
  scratchBase: string,
  tamper: boolean,
): Promise<string | null> {
  const root = mkdtempSync(join(scratchBase, `u${walkIndex}-`));
  const changer = new LineProc([bin, "changer", root, "m"]);
  const procs: Array<LineProc | null> = [null, null];
  const readerLoaded: [number, number] = [0, 0];
  const trace: string[] = [];

  const verifyState = (state: Model, where: string): string | null => {
    const disk = inspectDisk(root);
    let expectedLink: number = state.link;
    const expectedPresent = [...(state.present as number[])].sort((a, b) => a - b);
    if (tamper) {
      expectedLink = expectedLink === 0 ? 1 : 0;
    }
    if (disk.link !== expectedLink) {
      return `walk ${walkIndex} ${where}: link mismatch: model ${expectedLink}, disk ${disk.link}`;
    }
    if (JSON.stringify(disk.present) !== JSON.stringify(expectedPresent)) {
      return `walk ${walkIndex} ${where}: present mismatch: model ${JSON.stringify(expectedPresent)}, disk ${JSON.stringify(disk.present)}`;
    }
    const modelLoadedList: number[] = state.loaded;
    for (let r = 0; r < 2; r += 1) {
      if (readerLoaded[r] !== modelLoadedList[r]) {
        return `walk ${walkIndex} ${where}: reader ${r + 1} loaded mismatch: model ${modelLoadedList[r]}, lab ${readerLoaded[r]}`;
      }
    }
    return null;
  };

  try {
    const changerReady = await changer.readLine();
    if (changerReady !== "ready") return `walk ${walkIndex} init: changer expected "ready", got ${JSON.stringify(changerReady)}`;

    const initState = graph.states.get(walk.init)!;
    const initErr = await runChangerCmd(changer, `install ${sources[0]} ${tokenOf(1)}`);
    if (initErr) return `walk ${walkIndex} init: ${initErr}`;
    const initCheck = verifyState(initState, "init");
    if (initCheck) return initCheck;

    let collectProbed = false;
    for (let stepIdx = 0; stepIdx < walk.hops.length; stepIdx += 1) {
      const hop = walk.hops[stepIdx]!;
      const from = graph.states.get(hop.from)!;
      const to = graph.states.get(hop.to)!;
      trace.push(hop.label);
      const where = `step ${stepIdx} (${trace.join(" > ")})`;

      switch (hop.label) {
        case "Install": {
          const v: number = to.latest;
          const err = await runChangerCmd(changer, `install ${sources[v - 1]!} ${tokenOf(v)}`);
          if (err) return `walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Remove": {
          const err = await runChangerCmd(changer, "remove");
          if (err) return `walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Cleanup": {
          const fromSet = new Set<number>(from.present);
          const toSet = new Set<number>(to.present);
          const removed = [...fromSet].filter((v) => !toSet.has(v));
          if (removed.length !== 1) return `walk ${walkIndex} ${where}: expected 1 cleaned version, got ${removed.length}`;
          const err = await runChangerCmd(changer, `cleanup-version ${tokenOf(removed[0]!)}`);
          if (err) return `walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Start": {
          const r = changedReader(from, to, (a, b) => a === "off" && b === "resolve");
          const proc = new LineProc([bin, "reader", root, "m"]);
          procs[r] = proc;
          const line = await proc.readLine();
          if (line !== "ready") return `walk ${walkIndex} ${where}: reader ${r + 1} expected "ready", got ${JSON.stringify(line)}`;
          break;
        }
        case "Resolve": {
          const r = changedReader(from, to, (a, b) => a === "resolve" && b !== "resolve");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("resolve\n");
          const line = await proc.readLine();
          if (to.rpc[r] === "lock") {
            if (line !== "step resolved") {
              return `walk ${walkIndex} ${where}: reader ${r + 1} expected "step resolved", got ${JSON.stringify(line)}`;
            }
          } else {
            if (line !== "result none") {
              return `walk ${walkIndex} ${where}: reader ${r + 1} expected "result none", got ${JSON.stringify(line)}`;
            }
            readerLoaded[r] = 0;
          }
          break;
        }
        case "Lock": {
          const r = changedReader(from, to, (a, b) => a === "lock" && b === "check");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("lock\n");
          const line = await proc.readLine();
          if (line !== "step locked") {
            return `walk ${walkIndex} ${where}: reader ${r + 1} expected "step locked", got ${JSON.stringify(line)}`;
          }
          break;
        }
        case "Check": {
          const r = changedReader(from, to, (a, b) => a === "check" && b !== "check");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("check\n");
          const line = await proc.readLine();
          if (to.rpc[r] === "ready") {
            const expectedV: number = to.loaded[r];
            const expectedLine = `result pinned ${tokenOf(expectedV)}`;
            if (line !== expectedLine) {
              return `walk ${walkIndex} ${where}: reader ${r + 1} expected ${JSON.stringify(expectedLine)}, got ${JSON.stringify(line)}`;
            }
            readerLoaded[r] = expectedV;
          } else {
            if (line !== "step retry") {
              return `walk ${walkIndex} ${where}: reader ${r + 1} expected "step retry", got ${JSON.stringify(line)}`;
            }
          }
          break;
        }
        case "StartUse": {
          const r = changedReader(from, to, (a, b) => a === "ready" && b === "using");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("use\n");
          const line = await proc.readLine();
          const expectedLine = `used ${to.held[r]}`;
          if (line !== expectedLine) {
            return `walk ${walkIndex} ${where}: reader ${r + 1} expected ${JSON.stringify(expectedLine)}, got ${JSON.stringify(line)}`;
          }
          break;
        }
        case "EndUse": {
          const r = changedReader(from, to, (a, b) => a === "using" && b === "ready");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("end_use\n");
          const line = await proc.readLine();
          const expectedLine = `ended ${from.held[r]}`;
          if (line !== expectedLine) {
            return `walk ${walkIndex} ${where}: reader ${r + 1} expected ${JSON.stringify(expectedLine)}, got ${JSON.stringify(line)}`;
          }
          break;
        }
        case "Reload": {
          const r = changedReader(from, to, (a, b) => a === "ready" && b === "resolve");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("reload\n");
          const line = await proc.readLine();
          if (line !== "step reload") {
            return `walk ${walkIndex} ${where}: reader ${r + 1} expected "step reload", got ${JSON.stringify(line)}`;
          }
          break;
        }
        case "Exit": {
          const r = changedReader(from, to, (a, b) => a !== "off" && b === "off");
          const proc = procs[r];
          if (!proc) return `walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          await proc.killAndWait();
          procs[r] = null;
          readerLoaded[r] = 0;
          break;
        }
        default:
          return `walk ${walkIndex} ${where}: unknown model action ${hop.label}`;
      }

      const checkErr = verifyState(to, where);
      if (checkErr) return checkErr;

      // Probe store.collectVersion once per walk when a non-live version is pinned:
      // cleanup must skip it and keep disk state identical.
      if (!collectProbed) {
        const pinnedV = pinnedOldVersion(to);
        if (pinnedV !== null) {
          collectProbed = true;
          const collectErr = await runChangerCmd(changer, `cleanup-version ${tokenOf(pinnedV)}`);
          if (collectErr) return `walk ${walkIndex} ${where} collect-probe: ${collectErr}`;
          const afterProbe = verifyState(to, `${where} after collect-probe`);
          if (afterProbe) return afterProbe;
        }
      }
    }
    return null;
  } catch (err) {
    return `walk ${walkIndex} (${trace.join(" > ")}): ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    await changer.killAndWait();
    for (const proc of procs) {
      if (proc) await proc.killAndWait();
    }
    rmSync(root, { recursive: true, force: true });
  }
}

async function runUseWalks(
  bin: string,
  walks: Walk[],
  graph: Graph,
  sources: [string, string, string],
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
      const err = await runOneUseWalk(bin, walks[idx]!, idx, graph, sources, scratchBase, tamper);
      if (err) {
        mismatches.push(err);
        if (stopOnFirst) stopped = true;
      }
    }
  }));
  return { mismatches };
}

function reloadCleanupWalks(graph: Graph): Walk[] {
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

  const extra: Walk[] = [];
  for (const [uId, edges] of graph.next.entries()) {
    for (const reloadEdge of edges) {
      if (reloadEdge.label !== "Reload") continue;
      const u = graph.states.get(uId)!;
      const v = graph.states.get(reloadEdge.to)!;
      const r = changedReader(u, v, (a, b) => a === "ready" && b === "resolve");
      const vOld: number = u.loaded[r];
      if (vOld <= 0) continue;

      // Forward BFS from `reloadEdge.to` without letting reader `r` exit,
      // until `Cleanup` removes `vOld`.
      const fwdParent = new Map<string, { from: string; label: string } | null>();
      fwdParent.set(reloadEdge.to, null);
      const fwdQueue: string[] = [reloadEdge.to];
      let targetEnd: string | null = null;

      outer: for (let at = 0; at < fwdQueue.length; at += 1) {
        const cur = fwdQueue[at]!;
        const curState = graph.states.get(cur)!;
        for (const e of graph.next.get(cur) ?? []) {
          const nextState = graph.states.get(e.to)!;
          if (e.label === "Exit" && curState.rpc[r] !== "off" && nextState.rpc[r] === "off") continue;
          if (!fwdParent.has(e.to)) {
            fwdParent.set(e.to, { from: cur, label: e.label });
            if (e.label === "Cleanup" && curState.present.includes(vOld) && !nextState.present.includes(vOld)) {
              targetEnd = e.to;
              break outer;
            }
            fwdQueue.push(e.to);
          }
        }
      }
      if (!targetEnd) continue;

      const hops: Hop[] = [];
      for (let cur = targetEnd; fwdParent.get(cur); cur = fwdParent.get(cur)!.from) {
        const p = fwdParent.get(cur)!;
        hops.unshift({ from: p.from, to: cur, label: p.label });
      }
      hops.unshift({ from: uId, to: reloadEdge.to, label: reloadEdge.label });
      for (let cur = uId; parent.get(cur); cur = parent.get(cur)!.from) {
        const p = parent.get(cur)!;
        hops.unshift({ from: p.from, to: cur, label: p.label });
      }
      extra.push({ init: initOf.get(uId)!, hops });
      if (extra.length >= 8) return extra;
    }
  }
  return extra;
}

async function useWalkPart(out: string): Promise<number> {
  const lab = buildLab(labUseSource, storeModule, out, "lab_use");
  const graph = await loadModUseGraph(out);
  if (!lab || !graph) return 2;

  const walks = [...walksOf(graph, false), ...reloadCleanupWalks(graph)];
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  const walked = new Set(walks.flatMap((w) => w.hops.map((h) => h.label)));
  for (const action of REQUIRED_USE_ACTIONS) {
    if (!walked.has(action)) {
      console.log(`use-walk: action ${action} was never walked`);
      return 1;
    }
  }

  const scratchBase = mkdtempSync(join(tmpdir(), "fx-use-walk-"));
  try {
    const sourcesDir = join(out, "use-sources");
    mkdirSync(sourcesDir, { recursive: true });
    const sources = createUseSources(sourcesDir);

    const started = performance.now();
    const { mismatches } = await runUseWalks(lab, walks, graph, sources, scratchBase, false, false);
    const elapsed = ((performance.now() - started) / 1000).toFixed(1);
    console.log(`use-walk: ${walks.length} walks, ${steps} steps, ${mismatches.length} mismatches in ${elapsed}s`);
    if (mismatches.length > 0) {
      console.log(`first mismatch: ${mismatches[0]}`);
      return 1;
    }
    console.log("use-walk: ACCEPTED");

    if (options.selfCheck) {
      const tampered = await runUseWalks(lab, walks.slice(0, 10), graph, sources, scratchBase, true, true);
      const tamperedRejected = tampered.mismatches.length > 0;
      console.log(`self-check: use-walk, tampered expectation ${tamperedRejected ? "rejected" : "NOT rejected"}`);
      let allCaught = tamperedRejected;

      for (const [index, mutant] of USE_MUTANTS.entries()) {
        const mutantStore = buildMutantStore(mutant, join(out, `use-mutant-${index}`));
        if (!mutantStore) {
          allCaught = false;
          continue;
        }
        const mutantBin = buildLab(labUseSource, mutantStore, out, `lab_use_mutant_${index}`);
        if (!mutantBin) {
          allCaught = false;
          continue;
        }
        const mutantRun = await runUseWalks(mutantBin, walks, graph, sources, scratchBase, false, true);
        const rejected = mutantRun.mismatches.length > 0;
        console.log(`self-check: use-walk that ${mutant.name} ${rejected ? "rejected" : "NOT rejected"}`);
        allCaught &&= rejected;
      }
      if (!allCaught) return 1;
    }

    return 0;
  } finally {
    rmSync(scratchBase, { recursive: true, force: true });
  }
}

type ServeServerEvent = {
  t: number;
  name: string;
  pid: number;
  ppid?: number;
  cwd: string;
  ev: string;
  phase?: string;
  marker?: string;
  code?: string;
  id?: string | number;
  tool?: string;
};

type CuratedServeScenario =
  | "release_on_reload"
  | "release_on_first_exit"
  | "mixed_v1_v2"
  | "crash_then_cleanup"
  | "unused_versions_go";

function readServeEvents(logPath: string): ServeServerEvent[] {
  if (!existsSync(logPath)) return [];
  return readFileSync(logPath, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as ServeServerEvent);
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForServeCondition<T>(
  what: string,
  probe: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  timeoutMs = 5_000,
  everyMs = 25,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await probe();
    if (val) return val;
    await Bun.sleep(everyMs);
  }
  throw new Error(`timed out waiting for ${what}`);
}

// Hold timing policy (matching `src/mcp/core/stdio_conn.zig` and `src/mcp/engine.zig`):
// - `stdio_conn.Config` waits `grace_ms = 1,500` ms after closing stdin before SIGTERM,
//   then `term_ms = 1,500` ms before SIGKILL; `Engine.sweep` kills a retired slot after
//   `3,500` ms.
// - Normal graph walks and curated drain/mixed scenarios take the graceful path:
//   every fixture hold is capped at `FIXTURE_MAX_HOLD_MS = 900` ms (well under `1,500` ms)
//   and released explicitly as soon as pin/disk probes finish.
// - `crash_then_cleanup` and `Crash` hops take the crash path (`SIGKILL` on `lab_serve`),
//   leaving `src/mcp/io/process.zig`'s helper up to its `2,000` ms TERM->KILL window.
function createServeSources(dir: string, controlDir: string, logPath: string): [string, string, string] {
  const out: string[] = [];
  for (const v of [1, 2, 3]) {
    const src = join(dir, `src${v}`);
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "version.txt"), `${v}\n`);
    writeFileSync(join(src, "mod.json"), JSON.stringify({
      name: "m",
      version: String(v),
      description: `serve mod v${v}`,
      mcp: {
        srv: {
          command: [process.execPath, serveFixturePath],
          env: {
            FIXTURE_NAME: `srv-v${v}`,
            FIXTURE_LOG: logPath,
            FIXTURE_CONTROL: controlDir,
            FIXTURE_HOLD_CALL_FILE: `hold-call-v${v}`,
            FIXTURE_HOLD_EXIT_FILE: `hold-exit-v${v}`,
            FIXTURE_MAX_HOLD_MS: "900",
          },
        },
      },
    }));
    out.push(src);
  }
  return [out[0]!, out[1]!, out[2]!];
}

function createTwoServerSource(dir: string, v: number, controlDir: string, logPath: string): string {
  const src = join(dir, `src${v}_two`);
  mkdirSync(src, { recursive: true });
  writeFileSync(join(src, "version.txt"), `${v}\n`);
  writeFileSync(join(src, "mod.json"), JSON.stringify({
    name: "m",
    version: String(v),
    description: `two-server v${v}`,
    mcp: {
      s1: {
        command: [process.execPath, serveFixturePath],
        env: {
          FIXTURE_NAME: `s1-v${v}`,
          FIXTURE_LOG: logPath,
          FIXTURE_CONTROL: controlDir,
          FIXTURE_HOLD_EXIT_FILE: `hold-s1-v${v}`,
          FIXTURE_MAX_HOLD_MS: "900",
        },
      },
      s2: {
        command: [process.execPath, serveFixturePath],
        env: {
          FIXTURE_NAME: `s2-v${v}`,
          FIXTURE_LOG: logPath,
          FIXTURE_CONTROL: controlDir,
          FIXTURE_HOLD_CALL_FILE: `hold-s2-call-v${v}`,
          FIXTURE_HOLD_EXIT_FILE: `hold-s2-v${v}`,
          FIXTURE_MAX_HOLD_MS: "900",
        },
      },
    },
  }));
  return src;
}

function buildServeLab(
  out: string,
  name: string,
  patches: Patch[] = [],
): string | null {
  const stageDir = join(out, `${name}-stage`);
  const stageSrc = join(stageDir, "src");
  rmSync(stageDir, { recursive: true, force: true });
  mkdirSync(stageDir, { recursive: true });
  cpSync(join(REPO_ROOT, "src"), stageSrc, { recursive: true });
  copyFileSync(labServeSource, join(stageSrc, "lab_serve_root.zig"));

  if (patches.length > 0) {
    const rtPath = join(stageSrc, "core", "mcp_host", "runtime.zig");
    let rtSrc = readFileSync(rtPath, "utf8");
    for (const patch of patches) {
      if (patch.file !== "runtime") continue;
      if (!rtSrc.includes(patch.target)) {
        console.log(`self-check: target missing in runtime.zig for "${name}": ${patch.target}`);
        return null;
      }
      rtSrc = rtSrc.replaceAll(patch.target, patch.planted);
    }
    writeFileSync(rtPath, rtSrc);
  }

  const targetsJson = JSON.parse(readFileSync(join(REPO_ROOT, "tests", "fuzz", "targets.json"), "utf8")) as {
    targets: Array<{ name: string }>;
  };
  const fcText = targetsJson.targets.map((t) => `pub const ${t.name}: *const [0][]const u8 = &.{};`).join("\n") + "\n";
  const fcPath = join(stageDir, "fc.zig");
  const boPath = join(stageDir, "bo.zig");
  const smBoPath = join(stageDir, "sm_bo.zig");
  const tpPath = join(stageDir, "tp.zig");
  writeFileSync(fcPath, fcText);
  writeFileSync(boPath, [
    'pub const git_commit = "test";',
    'pub const app_version = "0.0.0-test";',
    'pub const update_channel = "stable";',
    "pub const WasmSurface = enum { none, core, term };",
    "pub const wasm_surface: WasmSurface = .none;",
    "pub const libfx = false;",
    "pub const builtin_tools = true;",
    "",
  ].join("\n"));
  writeFileSync(smBoPath, [
    "pub const hooks = false;",
    'pub const trace_dir = "/tmp/sm-traces";',
    'pub const src_dir = "src/core/session_manager";',
    "",
  ].join("\n"));
  writeFileSync(tpPath, [
    'pub const product_exe = "zig-out/bin/fx";',
    'pub const source_root = "src";',
    'pub const fixtures_dir = "tests";',
    "",
  ].join("\n"));

  const bin = join(out, name);
  const build = Bun.spawnSync(
    [
      "zig", "build-exe", "-O", "ReleaseSafe", "-lc",
      "--dep", "fuzz_seed", "--dep", "fuzz_corpus", "--dep", "build_options", "--dep", "test_paths", "--dep", "session_manager",
      `-Mroot=${join(stageSrc, "lab_serve_root.zig")}`,
      `-Mfuzz_seed=${join(stageSrc, "fuzz_seed.zig")}`,
      `-Mfuzz_corpus=${fcPath}`,
      `-Mbuild_options=${boPath}`,
      `-Mtest_paths=${tpPath}`,
      "--dep", "build_options=sm_bo",
      `-Msession_manager=${join(stageSrc, "core", "session_manager", "api.zig")}`,
      `-Msm_bo=${smBoPath}`,
      "--name", name,
      `-femit-bin=${bin}`,
    ],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) {
    console.log(`building ${name} failed:\n${new TextDecoder().decode(build.stderr).slice(0, 2000)}`);
    return null;
  }
  return bin;
}

async function loadModServeGraph(out: string): Promise<Graph | null> {
  const dir = join(out, "serve-graph");
  mkdirSync(dir, { recursive: true });
  // `check.sh` checks PROPERTIES ServesCurrent and UnusedVersionsGo; drop
  // PROPERTIES here so TLC dumps the exact 81,182-state graph in one pass.
  const cfg = readFileSync(join(tlaDir, "mods-serve.cfg"), "utf8")
    .split("\n")
    .filter((line) => !/^PROPERTIES\b/.test(line.trim()))
    .join("\n");
  writeFileSync(join(dir, "Driver.cfg"), cfg);
  const run = await runTlc(dir, "ModServe", "Driver.cfg", ["ModServe.tla"], tlaDir, ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) {
    console.log(`TLC failed on ModServe.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
    return null;
  }
  const graph = parseDotGraph(join(dir, "graph.dot"));
  if (!graph) {
    console.log("serve-walk: the graph has no initial states");
    return null;
  }
  console.log(`serve-walk: graph of ${graph.states.size} states (${graph.inits.length} initial), ${run.durationMs} ms`);
  return graph;
}

function retiringTotalForReader(state: Model, readerIdx: number): number {
  const ret: number[] = state.retiring[readerIdx]!;
  let sum = 0;
  for (const c of ret) sum += c;
  return sum;
}

// Same-name rule: Runtime holds a server-starting request (`tools`/`call`) while
// any retired slot under that same server name is still stopping (`engine.stopping`,
// `src/core/mcp_host/runtime.zig:1296`). Skip `StartServer(r)` edges while `r`
// still has any server in `retiring[r]`.
function isServeEdgeBlockedBySameName(from: Model, to: Model, label: string): boolean {
  if (label !== "StartServer") return false;
  for (let r = 0; r < from.serving.length; r += 1) {
    if (from.serving[r] === 0 && to.serving[r] !== 0) {
      return retiringTotalForReader(from, r) > 0;
    }
  }
  return false;
}

function serveEdgeSignature(from: Model, to: Model, label: string): string {
  switch (label) {
    case "Start": {
      const r = from.up.findIndex((u: boolean, i: number) => !u && to.up[i]);
      return `Start:r${r}:link=${from.link}`;
    }
    case "Reload": {
      const r = from.loaded.findIndex((v: number, i: number) => v !== to.loaded[i]);
      return `Reload:r${r}:from=${from.loaded[r]}:srv=${from.serving[r]}:ret=${retiringTotalForReader(from, r)}:to=${to.loaded[r]}`;
    }
    case "StartServer": {
      const r = from.serving.findIndex((v: number, i: number) => v === 0 && to.serving[i] !== 0);
      return `StartServer:r${r}:v=${to.serving[r]}`;
    }
    case "StopServer": {
      const r = from.serving.findIndex((v: number, i: number) => v !== 0 && to.serving[i] === 0);
      return `StopServer:r${r}:v=${from.serving[r]}`;
    }
    case "RetireDone": {
      for (let r = 0; r < from.retiring.length; r += 1) {
        for (let v = 0; v < from.retiring[r]!.length; v += 1) {
          if (from.retiring[r]![v]! > to.retiring[r]![v]!) {
            const keepList = from.loaded[r] === v + 1;
            const rem = to.retiring[r]![v]!;
            return `RetireDone:v${v + 1}:keep=${keepList}:rem=${rem}`;
          }
        }
      }
      return "RetireDone";
    }
    case "Exit": {
      const r = from.up.findIndex((u: boolean, i: number) => u && !to.up[i]);
      return `Exit:r${r}:had=${from.loaded[r]}`;
    }
    case "Crash": {
      const r = from.up.findIndex((u: boolean, i: number) => u && !to.up[i]);
      const hadLive = from.serving[r] !== 0 || retiringTotalForReader(from, r) > 0;
      return `Crash:r${r}:live=${hadLive}`;
    }
    case "DyingDone": {
      const lost = from.dying.find((v: number) => !to.dying.includes(v)) ?? 0;
      return `DyingDone:inPresent=${from.present.includes(lost)}`;
    }
    case "Cleanup": {
      const gone = from.present.find((v: number) => !to.present.includes(v)) ?? 0;
      return `Cleanup:v=${gone}:rem=${to.present.length}`;
    }
    case "Install":
      return `Install:v=${to.latest}`;
    case "Remove":
      return `Remove:had=${from.link}`;
    default:
      return label;
  }
}

function boundedServeWalks(graph: Graph): Walk[] {
  const parent = new Map<string, { from: string; label: string } | null>();
  const initOf = new Map<string, string>();
  const queue: string[] = [];
  for (const initId of graph.inits) {
    parent.set(initId, null);
    initOf.set(initId, initId);
    queue.push(initId);
  }
  for (let at = 0; at < queue.length; at += 1) {
    const fromId = queue[at]!;
    const fromState = graph.states.get(fromId)!;
    for (const edge of graph.next.get(fromId) ?? []) {
      if (parent.has(edge.to)) continue;
      const toState = graph.states.get(edge.to)!;
      if (isServeEdgeBlockedBySameName(fromState, toState, edge.label)) continue;
      parent.set(edge.to, { from: fromId, label: edge.label });
      initOf.set(edge.to, initOf.get(fromId)!);
      queue.push(edge.to);
    }
  }

  const seenSigs = new Set<string>();
  const walks: Walk[] = [];
  const pathTo = (targetId: string, finalEdge?: Edge): Walk => {
    const hops: Hop[] = finalEdge ? [{ from: targetId, to: finalEdge.to, label: finalEdge.label }] : [];
    for (let cur = targetId; parent.get(cur); cur = parent.get(cur)!.from) {
      const p = parent.get(cur)!;
      hops.unshift({ from: p.from, to: cur, label: p.label });
    }
    return { init: initOf.get(targetId)!, hops };
  };

  for (const id of queue) {
    const fromState = graph.states.get(id)!;
    for (const edge of graph.next.get(id) ?? []) {
      const toState = graph.states.get(edge.to)!;
      if (isServeEdgeBlockedBySameName(fromState, toState, edge.label)) continue;
      const sig = serveEdgeSignature(fromState, toState, edge.label);
      if (seenSigs.has(sig)) continue;
      seenSigs.add(sig);
      walks.push(pathTo(id, edge));
    }
  }

  // Add seeded random walks for multi-step interleavings across both readers.
  const random = generator(options.seed);
  for (let w = 0; w < options.serveWalks; w += 1) {
    const init = graph.inits[Math.floor(random() * graph.inits.length)]!;
    const hops: Hop[] = [];
    let at = init;
    for (let i = 0; i < options.serveSteps; i += 1) {
      const fromState = graph.states.get(at)!;
      const edges = (graph.next.get(at) ?? []).filter((e) =>
        !isServeEdgeBlockedBySameName(fromState, graph.states.get(e.to)!, e.label),
      );
      if (edges.length === 0) break;
      const edge = edges[Math.floor(random() * edges.length)]!;
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    if (hops.length > 0) walks.push({ init, hops });
  }
  return walks;
}

function changedServeReader(from: Model, to: Model, pred: (i: number) => boolean): number {
  const found: number[] = [];
  for (let i = 0; i < from.up.length; i += 1) {
    if (pred(i)) found.push(i);
  }
  if (found.length !== 1) throw new Error(`expected 1 changed serve reader, got ${found.length}`);
  return found[0]!;
}

function serveLabEnv(): Record<string, string> {
  return {
    ...process.env,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
  };
}

async function runOneServeWalk(
  labBin: string,
  walk: Walk,
  walkIndex: number,
  graph: Graph,
  scratchBase: string,
  tamper: boolean,
): Promise<string | null> {
  const root = mkdtempSync(join(scratchBase, `s${walkIndex}-`));
  const sourcesDir = join(root, ".src");
  const controlDir = join(root, ".ctrl");
  const logPath = join(root, ".srv.jsonl");
  mkdirSync(sourcesDir, { recursive: true });
  mkdirSync(controlDir, { recursive: true });
  const sources = createServeSources(sourcesDir, controlDir, logPath);
  const labEnv = serveLabEnv();
  const changer = new LineProc([labBin, "changer", root, "m"], labEnv);
  const readers: Array<LineProc | null> = [null, null];
  const readerLoaded: [number, number] = [0, 0];
  const readerServingPid: [number | null, number | null] = [null, null];
  const retiringPids: Array<Map<number, number[]>> = [new Map(), new Map()];
  const trace: string[] = [];

  const probePinBusy = async (v: number): Promise<boolean> => {
    const res = await runChangerCmdRaw(changer, `probe-pin ${tokenOf(v)}`);
    if (res === "pin busy") return true;
    if (res === "pin free") return false;
    throw new Error(`unexpected probe-pin response: ${JSON.stringify(res)}`);
  };

  const verifyServeState = async (state: Model, where: string): Promise<string | null> => {
    const disk = inspectDisk(root);
    let expectedLink: number = state.link;
    const expectedPresent = [...(state.present as number[])].sort((a, b) => a - b);
    if (tamper) expectedLink = expectedLink === 0 ? 1 : 0;
    if (disk.link !== expectedLink) {
      return `serve walk ${walkIndex} ${where}: link mismatch: model ${expectedLink}, disk ${disk.link}`;
    }
    if (JSON.stringify(disk.present) !== JSON.stringify(expectedPresent)) {
      return `serve walk ${walkIndex} ${where}: present mismatch: model ${JSON.stringify(expectedPresent)}, disk ${JSON.stringify(disk.present)}`;
    }
    for (let r = 0; r < 2; r += 1) {
      if (readerLoaded[r] !== state.loaded[r]) {
        return `serve walk ${walkIndex} ${where}: reader ${r + 1} loaded mismatch: model ${state.loaded[r]}, lab ${readerLoaded[r]}`;
      }
      const isUp = readers[r] !== null && readers[r]!.proc.exitCode === null;
      if (isUp !== state.up[r]) {
        return `serve walk ${walkIndex} ${where}: reader ${r + 1} up mismatch: model ${state.up[r]}, lab ${isUp}`;
      }
    }
    for (const v of expectedPresent) {
      const expectedHeld = (state.pins[v - 1] ?? state.pins[String(v)] ?? []).length > 0;
      const gotHeld = await probePinBusy(v);
      if (gotHeld !== expectedHeld) {
        return `serve walk ${walkIndex} ${where}: pin[${v}] mismatch: model held=${expectedHeld}, flock busy=${gotHeld}`;
      }
    }
    return null;
  };

  try {
    const changerReady = await changer.readLine();
    if (changerReady !== "ready") return `serve walk ${walkIndex} init: changer expected "ready", got ${JSON.stringify(changerReady)}`;

    const initState = graph.states.get(walk.init)!;
    const initErr = await runChangerCmd(changer, `install ${sources[0]} ${tokenOf(1)}`);
    if (initErr) return `serve walk ${walkIndex} init: ${initErr}`;
    const initCheck = await verifyServeState(initState, "init");
    if (initCheck) return initCheck;

    for (let stepIdx = 0; stepIdx < walk.hops.length; stepIdx += 1) {
      const hop = walk.hops[stepIdx]!;
      const from = graph.states.get(hop.from)!;
      const to = graph.states.get(hop.to)!;
      trace.push(hop.label);
      const where = `step ${stepIdx} (${trace.join(" > ")})`;

      switch (hop.label) {
        case "Install": {
          const v: number = to.latest;
          const err = await runChangerCmd(changer, `install ${sources[v - 1]!} ${tokenOf(v)}`);
          if (err) return `serve walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Remove": {
          const err = await runChangerCmd(changer, "remove");
          if (err) return `serve walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Cleanup": {
          const fromSet = new Set<number>(from.present);
          const toSet = new Set<number>(to.present);
          const removed = [...fromSet].filter((v) => !toSet.has(v));
          if (removed.length !== 1) return `serve walk ${walkIndex} ${where}: expected 1 cleaned version, got ${removed.length}`;
          const err = await runChangerCmd(changer, `cleanup-version ${tokenOf(removed[0]!)}`);
          if (err) return `serve walk ${walkIndex} ${where}: ${err}`;
          break;
        }
        case "Start": {
          const r = changedServeReader(from, to, (i) => !from.up[i] && to.up[i]);
          const proc = new LineProc([labBin, "reader", root, "m", "--no-cleanup"], labEnv);
          readers[r] = proc;
          const line = await proc.readLine(10_000);
          if (line !== "ready") return `serve walk ${walkIndex} ${where}: reader ${r + 1} expected "ready", got ${JSON.stringify(line)}`;
          break;
        }
        case "Reload": {
          const r = changedServeReader(from, to, (i) => from.loaded[i] !== to.loaded[i]);
          const proc = readers[r];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          const oldLive = readerServingPid[r];
          if (oldLive !== null && from.serving[r] > 0) {
            const prevV: number = from.serving[r];
            const list = retiringPids[r]!.get(prevV) ?? [];
            list.push(oldLive);
            retiringPids[r]!.set(prevV, list);
            readerServingPid[r] = null;
          }
          proc.sendText("reload\n");
          const line = await proc.readLine(10_000);
          const wantV: number = to.loaded[r];
          const wantLine = wantV === 0 ? "reloaded none" : `reloaded ${tokenOf(wantV)}`;
          if (line !== wantLine) return `serve walk ${walkIndex} ${where}: reader ${r + 1} expected ${JSON.stringify(wantLine)}, got ${JSON.stringify(line)}`;
          readerLoaded[r] = wantV;
          break;
        }
        case "StartServer": {
          const r = changedServeReader(from, to, (i) => from.serving[i] === 0 && to.serving[i] !== 0);
          const proc = readers[r];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          const v: number = to.serving[r];
          writeFileSync(join(controlDir, `hold-exit-v${v}`), "hold\n");
          writeFileSync(join(controlDir, `hold-call-v${v}`), "hold\n");
          const beforeCount = readServeEvents(logPath).filter((e) => e.ev === "start" && e.name === `srv-v${v}`).length;
          proc.sendText("start_server\n");
          const line = await proc.readLine(10_000);
          if (!line || !line.startsWith("started ")) {
            return `serve walk ${walkIndex} ${where}: reader ${r + 1} expected "started ...", got ${JSON.stringify(line)}`;
          }
          const startedEv = await waitForServeCondition(
            `srv-v${v} start`,
            () => {
              const evs = readServeEvents(logPath).filter((e) => e.ev === "start" && e.name === `srv-v${v}`);
              return evs.length > beforeCount ? evs[evs.length - 1]! : null;
            },
            5_000,
          );
          readerServingPid[r] = startedEv.pid;
          break;
        }
        case "StopServer": {
          const r = changedServeReader(from, to, (i) => from.serving[i] !== 0 && to.serving[i] === 0);
          const proc = readers[r];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          const prevV: number = from.serving[r];
          const livePid = readerServingPid[r];
          if (livePid !== null) {
            const list = retiringPids[r]!.get(prevV) ?? [];
            list.push(livePid);
            retiringPids[r]!.set(prevV, list);
            readerServingPid[r] = null;
          }
          proc.sendText("stop_server\n");
          const line = await proc.readLine(10_000);
          if (line !== "stopped") return `serve walk ${walkIndex} ${where}: reader ${r + 1} expected "stopped", got ${JSON.stringify(line)}`;
          break;
        }
        case "RetireDone": {
          let targetR = -1;
          let targetV = 0;
          for (let r = 0; r < from.retiring.length; r += 1) {
            for (let v = 0; v < from.retiring[r]!.length; v += 1) {
              if (from.retiring[r]![v]! > to.retiring[r]![v]!) {
                targetR = r;
                targetV = v + 1;
              }
            }
          }
          if (targetR < 0) return `serve walk ${walkIndex} ${where}: no retiring server decreased`;
          const proc = readers[targetR];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${targetR + 1} not running`;
          const list = retiringPids[targetR]!.get(targetV) ?? [];
          const pid = list.shift();
          rmSync(join(controlDir, `hold-call-v${targetV}`), { force: true });
          rmSync(join(controlDir, `hold-exit-v${targetV}`), { force: true });
          if (pid !== undefined) {
            await waitForServeCondition(`retiring pid ${pid} exit`, () => !pidAlive(pid), 5_000);
          }
          proc.sendText("sweep\n");
          const sweepLine = await proc.readLine(10_000);
          if (sweepLine !== "swept") return `serve walk ${walkIndex} ${where}: reader ${targetR + 1} expected "swept", got ${JSON.stringify(sweepLine)}`;
          if (to.retiring[targetR]![targetV - 1] === 0 && to.loaded[targetR] !== targetV) {
            await waitForServeCondition(`pin v${targetV} release`, async () => !(await probePinBusy(targetV)), 2_000).catch(() => {});
          }
          break;
        }
        case "Exit": {
          const r = changedServeReader(from, to, (i) => from.up[i] && !to.up[i]);
          const proc = readers[r];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          proc.sendText("quit\n");
          const code = await proc.proc.exited;
          readers[r] = null;
          readerLoaded[r] = 0;
          if (code !== 0) return `serve walk ${walkIndex} ${where}: reader ${r + 1} exited ${code}`;
          break;
        }
        case "Crash": {
          const r = changedServeReader(from, to, (i) => from.up[i] && !to.up[i]);
          const proc = readers[r];
          if (!proc) return `serve walk ${walkIndex} ${where}: reader ${r + 1} not running`;
          await proc.killAndWait();
          readers[r] = null;
          readerLoaded[r] = 0;
          break;
        }
        case "DyingDone": {
          const goneV = (from.dying as number[]).find((v) => !(to.dying as number[]).includes(v)) ?? 0;
          for (let r = 0; r < 2; r += 1) {
            const pLive = readerServingPid[r];
            if (pLive !== null && from.serving[r] === goneV) {
              await waitForServeCondition(`dying pid ${pLive} exit`, () => !pidAlive(pLive), 4_500);
              readerServingPid[r] = null;
            }
            const ret = retiringPids[r]!.get(goneV) ?? [];
            for (const p of ret) {
              await waitForServeCondition(`dying retired pid ${p} exit`, () => !pidAlive(p), 4_500);
            }
            retiringPids[r]!.delete(goneV);
          }
          break;
        }
        default:
          return `serve walk ${walkIndex} ${where}: unknown model action ${hop.label}`;
      }

      const checkErr = await verifyServeState(to, where);
      if (checkErr) return checkErr;
    }
    return null;
  } catch (err) {
    return `serve walk ${walkIndex} (${trace.join(" > ")}): ${err instanceof Error ? err.message : String(err)}`;
  } finally {
    await changer.killAndWait();
    for (const proc of readers) {
      if (proc) await proc.killAndWait();
    }
    rmSync(root, { recursive: true, force: true });
  }
}

async function runChangerCmdRaw(proc: LineProc, cmd: string): Promise<string | null> {
  proc.sendText(`${cmd}\n`);
  return await proc.readLine();
}

function curateServeScenarios(): CuratedServeScenario[] {
  return [
    "release_on_reload",
    "release_on_first_exit",
    "mixed_v1_v2",
    "crash_then_cleanup",
    "unused_versions_go",
  ];
}

async function runCuratedServeScenario(
  labBin: string,
  scenario: CuratedServeScenario,
  scratchBase: string,
): Promise<string | null> {
  const root = mkdtempSync(join(scratchBase, `curated-${scenario}-`));
  const sourcesDir = join(root, ".src");
  const controlDir = join(root, ".ctrl");
  const logPath = join(root, ".srv.jsonl");
  mkdirSync(sourcesDir, { recursive: true });
  mkdirSync(controlDir, { recursive: true });
  const sources = createServeSources(sourcesDir, controlDir, logPath);
  const twoServerV1 = createTwoServerSource(sourcesDir, 1, controlDir, logPath);
  const twoServerV2 = createTwoServerSource(sourcesDir, 2, controlDir, logPath);
  const labEnv = serveLabEnv();
  const changer = new LineProc([labBin, "changer", root, "m"], labEnv);
  const readers: LineProc[] = [];

  const probePinBusy = async (v: number): Promise<boolean> => {
    const res = await runChangerCmdRaw(changer, `probe-pin ${tokenOf(v)}`);
    if (res === "pin busy") return true;
    if (res === "pin free") return false;
    throw new Error(`unexpected probe-pin response: ${JSON.stringify(res)}`);
  };

  try {
    if ((await changer.readLine()) !== "ready") return `${scenario}: changer did not print ready`;
    const isTwoServer = scenario === "release_on_first_exit" || scenario === "mixed_v1_v2";
    const installSrc = isTwoServer ? twoServerV1 : sources[0];
    const err1 = await runChangerCmd(changer, `install ${installSrc} ${tokenOf(1)}`);
    if (err1) return `${scenario}: init install failed: ${err1}`;

    const cleanupFlag = scenario === "unused_versions_go" ? "--cleanup" : "--no-cleanup";
    const reader = new LineProc([labBin, "reader", root, "m", cleanupFlag], labEnv);
    readers.push(reader);
    if ((await reader.readLine(10_000)) !== "ready") return `${scenario}: reader not ready`;

    reader.sendText("reload\n");
    if ((await reader.readLine(10_000)) !== `reloaded ${tokenOf(1)}`) return `${scenario}: initial reload failed`;

    if (isTwoServer) {
      // Graceful drain holds (< 900 ms, under stdio_conn's 1,500 ms SIGTERM grace):
      // s1 exits at once on reload, while s2 holds its slow call on v1.
      writeFileSync(join(controlDir, "hold-s2-call-v1"), "hold\n");
      writeFileSync(join(controlDir, "hold-s2-v1"), "hold\n");
      reader.sendText("start_server s1\n");
      if (!(await reader.readLine(10_000))?.startsWith("started ")) return `${scenario}: s1 start failed`;
      reader.sendText("start_call s2 slow\n");
      if (!(await reader.readLine(10_000))?.startsWith("calling ")) return `${scenario}: s2 slow call failed`;
      await waitForServeCondition("s2-v1 call_start", () =>
        readServeEvents(logPath).find((e) => e.ev === "call_start" && e.name === "s2-v1"), 5_000);

      const v2Src = scenario === "mixed_v1_v2" ? twoServerV2 : sources[1];
      const err2 = await runChangerCmd(changer, `install ${v2Src} ${tokenOf(2)}`);
      if (err2) return `${scenario}: install v2 failed: ${err2}`;
      reader.sendText("reload\n");
      if ((await reader.readLine(10_000)) !== `reloaded ${tokenOf(2)}`) return `${scenario}: reload v2 failed`;

      // s1-v1 exits immediately while s2-v1 still drains its slow call on v1.
      const s1Pid = readServeEvents(logPath).find((e) => e.ev === "start" && e.name === "s1-v1")!.pid;
      await waitForServeCondition("s1-v1 exit", () => !pidAlive(s1Pid), 5_000);
      reader.sendText("sweep\n");
      if ((await reader.readLine(10_000)) !== "swept") return `${scenario}: sweep after s1 exit failed`;

      if (!(await probePinBusy(1))) return `${scenario}: pin v1 dropped on first server exit while s2 still runs`;
      const cleanupWhileBusy = await runChangerCmd(changer, `cleanup-version ${tokenOf(1)}`);
      if (cleanupWhileBusy) return `${scenario}: cleanup probe failed: ${cleanupWhileBusy}`;
      if (!inspectDisk(root).present.includes(1)) return `${scenario}: v1 folder deleted while s2 still runs`;

      if (scenario === "mixed_v1_v2") {
        // Start s1 on v2 while s2 on v1 is still stopping/draining: both versions stay pinned
        // and each server reads its own version.txt.
        reader.sendText("start_server s1\n");
        if (!(await reader.readLine(10_000))?.startsWith("started ")) return `${scenario}: s1 on v2 failed to start while s2-v1 stops`;
        await waitForServeCondition("s1-v2 read_ok", () =>
          readServeEvents(logPath).find((e) => e.ev === "read_ok" && e.name === "s1-v2" && e.marker === "2"), 5_000);
        if (!(await probePinBusy(1)) || !(await probePinBusy(2))) {
          return `${scenario}: expected both v1 and v2 pinned during mixed execution`;
        }
        if (!inspectDisk(root).present.includes(1) || !inspectDisk(root).present.includes(2)) {
          return `${scenario}: missing v1 or v2 folder during mixed execution`;
        }
      }

      rmSync(join(controlDir, "hold-s2-call-v1"), { force: true });
      rmSync(join(controlDir, "hold-s2-v1"), { force: true });
      await waitForServeCondition("s2-v1 call_end marker read", () =>
        readServeEvents(logPath).find((e) => e.ev === "read_ok" && e.name === "s2-v1" && e.phase === "call_end" && e.marker === "1"), 5_000);
      reader.sendText("wait_call\n");
      const callRes = await reader.readLine(10_000);
      if (!callRes?.startsWith("call_done ")) return `${scenario}: s2 slow call join failed: ${JSON.stringify(callRes)}`;
      const s2Pid = readServeEvents(logPath).find((e) => e.ev === "start" && e.name === "s2-v1")!.pid;
      await waitForServeCondition("s2-v1 exit", () => !pidAlive(s2Pid), 5_000);
      reader.sendText("sweep\n");
      if ((await reader.readLine(10_000)) !== "swept") return `${scenario}: final sweep failed`;
      await waitForServeCondition("pin v1 release", async () => !(await probePinBusy(1)), 2_000);
      const cleanupDone = await runChangerCmd(changer, `cleanup-version ${tokenOf(1)}`);
      if (cleanupDone) return `${scenario}: final cleanup failed: ${cleanupDone}`;
      if (inspectDisk(root).present.includes(1)) return `${scenario}: v1 folder stayed after last server exited`;
      if (scenario === "mixed_v1_v2" && !(await probePinBusy(2))) return `${scenario}: v2 pin lost while s1-v2 runs`;
      reader.sendText("quit\n");
      if ((await reader.proc.exited) !== 0) return `${scenario}: reader non-zero exit`;
      return null;
    }

    // `release_on_reload`, `crash_then_cleanup`, and `unused_versions_go` hold a slow call on v1 across v2 reload
    // (graceful path: <= 900 ms hold unless crash_then_cleanup sends SIGKILL immediately).
    writeFileSync(join(controlDir, "hold-call-v1"), "hold\n");
    writeFileSync(join(controlDir, "hold-exit-v1"), "hold\n");
    reader.sendText("start_call srv slow\n");
    if (!(await reader.readLine(10_000))?.startsWith("calling ")) return `${scenario}: v1 slow call did not start`;
    const v1Start = await waitForServeCondition("srv-v1 call_start", () =>
      readServeEvents(logPath).find((e) => e.ev === "call_start" && e.name === "srv-v1"), 5_000);

    const err2 = await runChangerCmd(changer, `install ${sources[1]} ${tokenOf(2)}`);
    if (err2) return `${scenario}: install v2 failed: ${err2}`;
    reader.sendText("reload\n");
    if ((await reader.readLine(10_000)) !== `reloaded ${tokenOf(2)}`) return `${scenario}: reload v2 failed`;

    if (scenario === "crash_then_cleanup") {
      // Crash path: SIGKILL drops reader pins in the OS kernel; process.zig helper kills dying server within 2 s.
      await reader.killAndWait();
      if (await probePinBusy(1)) return `${scenario}: pin v1 stayed held after reader SIGKILL`;
      if (await probePinBusy(2)) return `${scenario}: pin v2 stayed held after reader SIGKILL`;
      const cleanupErr = await runChangerCmd(changer, `cleanup-version ${tokenOf(1)}`);
      if (cleanupErr) return `${scenario}: cleanup after crash failed: ${cleanupErr}`;
      if (inspectDisk(root).present.includes(1)) return `${scenario}: v1 remained after crash cleanup`;
      await waitForServeCondition("dying srv-v1 killed by helper", () => !pidAlive(v1Start.pid), 4_500);
      return null;
    }

    if (!(await probePinBusy(1))) return `${scenario}: pin v1 released on reload while retired server still drains`;
    if (scenario === "release_on_reload") {
      const cleanupBusy = await runChangerCmd(changer, `cleanup-version ${tokenOf(1)}`);
      if (cleanupBusy) return `${scenario}: cleanup probe failed: ${cleanupBusy}`;
    }
    if (!inspectDisk(root).present.includes(1)) return `${scenario}: v1 deleted while retired server still drains`;

    rmSync(join(controlDir, "hold-call-v1"), { force: true });
    rmSync(join(controlDir, "hold-exit-v1"), { force: true });
    await waitForServeCondition("srv-v1 call_end marker read", () =>
      readServeEvents(logPath).find((e) => e.ev === "read_ok" && e.name === "srv-v1" && e.phase === "call_end" && e.marker === "1"), 5_000);
    reader.sendText("wait_call\n");
    const callRes = await reader.readLine(10_000);
    if (!callRes?.startsWith("call_done ")) return `${scenario}: v1 slow call join failed: ${JSON.stringify(callRes)}`;
    await waitForServeCondition("srv-v1 exit", () => !pidAlive(v1Start.pid), 5_000);
    reader.sendText("sweep\n");
    if ((await reader.readLine(10_000)) !== "swept") return `${scenario}: final sweep failed`;
    await waitForServeCondition("pin v1 release", async () => !(await probePinBusy(1)), 2_000);

    if (scenario === "unused_versions_go") {
      await waitForServeCondition("detached cleanup removes v1", () => !inspectDisk(root).present.includes(1), 5_000);
    } else {
      const cleanupDone = await runChangerCmd(changer, `cleanup-version ${tokenOf(1)}`);
      if (cleanupDone) return `${scenario}: cleanup failed: ${cleanupDone}`;
      if (inspectDisk(root).present.includes(1)) return `${scenario}: v1 remained after final cleanup`;
    }
    reader.sendText("quit\n");
    const exitCode = await reader.proc.exited;
    if (exitCode !== 0) return `${scenario}: reader exited ${exitCode}`;
    return null;
  } finally {
    await changer.killAndWait();
    for (const r of readers) await r.killAndWait();
    rmSync(root, { recursive: true, force: true });
  }
}

async function runServeWalkSet(
  labBin: string,
  walks: Walk[],
  curated: CuratedServeScenario[],
  graph: Graph,
  scratchBase: string,
  tamper: boolean,
  stopOnFirst: boolean,
): Promise<string[]> {
  const mismatches: string[] = [];
  let next = 0;
  let stopped = false;

  await Promise.all(Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (!stopped && next < walks.length) {
      const idx = next++;
      const err = await runOneServeWalk(labBin, walks[idx]!, idx, graph, scratchBase, tamper);
      if (err) {
        mismatches.push(err);
        if (stopOnFirst) stopped = true;
      }
    }
  }));
  if (!stopOnFirst || mismatches.length === 0) {
    for (const scenario of curated) {
      const err = await runCuratedServeScenario(labBin, scenario, scratchBase);
      if (err) {
        mismatches.push(err);
        if (stopOnFirst) break;
      }
    }
  }
  return mismatches;
}

async function serveWalkPart(out: string): Promise<number> {
  const graph = await loadModServeGraph(out);
  if (!graph) return 2;

  const walks = boundedServeWalks(graph);
  const curated = curateServeScenarios();
  const steps = walks.reduce((sum, walk) => sum + walk.hops.length, 0);
  const walked = new Set(walks.flatMap((w) => w.hops.map((h) => h.label)));
  for (const action of REQUIRED_SERVE_ACTIONS) {
    if (!walked.has(action)) {
      console.log(`serve-walk: action ${action} was never walked`);
      return 1;
    }
  }

  if (options.planOnly) {
    console.log(`serve-walk: selected ${walks.length} graph walks (${steps} steps) + ${curated.length} curated scenarios`);
    return 0;
  }

  const serveLab = buildServeLab(out, "lab_serve");
  if (!serveLab) return 2;

  const scratchBase = mkdtempSync(join(tmpdir(), "fx-serve-walk-"));
  try {
    const started = performance.now();
    const mismatches = await runServeWalkSet(serveLab, walks, curated, graph, scratchBase, false, false);
    const elapsed = ((performance.now() - started) / 1000).toFixed(1);
    console.log(`serve-walk: ${walks.length} graph walks + ${curated.length} curated scenarios (${steps} steps), ${mismatches.length} mismatches in ${elapsed}s`);
    if (mismatches.length > 0) {
      console.log(`first mismatch: ${mismatches[0]}`);
      return 1;
    }
    console.log("serve-walk: ACCEPTED");

    if (options.selfCheck) {
      const tampered = await runServeWalkSet(serveLab, walks.slice(0, 10), [], graph, scratchBase, true, true);
      const tamperedRejected = tampered.length > 0;
      console.log(`self-check: serve-walk, tampered expectation ${tamperedRejected ? "rejected" : "NOT rejected"}`);
      let allCaught = tamperedRejected;

      for (const [index, mutant] of SERVE_MUTANTS.entries()) {
        const mutantBin = buildServeLab(out, `lab_serve_mutant_${index}`, mutant.patches);
        if (!mutantBin) {
          allCaught = false;
          continue;
        }
        const mutantMismatches = await runServeWalkSet(mutantBin, walks, curated, graph, scratchBase, false, true);
        const rejected = mutantMismatches.length > 0;
        console.log(`self-check: serve-walk that ${mutant.name} ${rejected ? "rejected" : "NOT rejected"}`);
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
  if (options.parts.includes("use-walk")) {
    const partCode = await useWalkPart(out);
    if (partCode !== 0) code = partCode;
  }
  if (options.parts.includes("serve-walk")) {
    const partCode = await serveWalkPart(out);
    if (partCode !== 0) code = partCode;
  }
  return code;
}

process.exit(await main());
