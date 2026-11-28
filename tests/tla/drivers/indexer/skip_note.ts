// Runs the built fx along tests/tla/indexer/SkipNote.tla and has TLC check
// every glob_files and grep_files result it observes (SkipNoteTrace.tla).
//
// Each case builds a folder from a layout, in or out of a git repository, and
// runs one `fx ask` against a local fake gateway whose model calls glob_files
// and grep_files on the workspace and on every folder of the layout. A reuse
// case first waits until the folder's stamps are older than the indexer's
// reuse margin, then launches the TUI in tmux with the same HOME so its file
// index saves the @-completion snapshot. fx's trace log says which searches
// reused the snapshot. The driver records each result's files and note, and
// TLC replays them through SkipNoteRules.tla.
//
// --self-check also replays them under Bug = "today" (fx before the note) and
// "unsaved" (a snapshot without the skipped list), which must reject them.
// --faults adds snapshots cut short, readable by others, or marked with the
// older v3 format, a snapshot save the file system refuses
// (../lib/path-fault.c), an unreadable skipped folder, and TUI kills at seeded
// times while it scans and saves, both for a first save and for a refresh
// after an edit. --stress N adds a folder of N packages with build/, dist/ and
// node_modules/ each, searched fresh and from the snapshot.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/indexer/skip_note.ts
//   bun tests/tla/drivers/indexer/skip_note.ts --self-check --faults
//   bun tests/tla/drivers/indexer/skip_note.ts --random 30 --seed 7 --stress 2000
//
// Exit codes: 0 every result accepted (and the self-check rejected), 1 a result
// the model cannot produce, 2 a toolchain or harness failure.
import { createHash } from "node:crypto";
import {
  chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync,
  truncateSync, writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { binary, shellQuote, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Snapshot = "none" | "v4" | "v3" | "garbage";
type Fault = "none" | "truncated" | "readable" | "v3" | "refused" | "unreadable" | "killed";
type Layout = { name: string; files: string[] };
type Case = {
  id: string;
  layout: Layout;
  repo: boolean;
  reuse: boolean;
  fault: Fault;
  // For "killed": milliseconds after the TUI starts, and whether it refreshes
  // a snapshot saved before an edit.
  killAfterMs?: number;
  refresh?: boolean;
  // Searches limited to these roots; every folder when absent.
  roots?: string[];
};
type Search = { tool: "glob_files" | "grep_files"; root: string };
type Observation = {
  id: string;
  repo: boolean;
  fault: Fault;
  snapshot: Snapshot;
  reused: boolean;
  tool: string;
  root: string;
  keep: boolean;
  listed: string[];
  truncated: boolean;
  note: { count: number; names: string[] };
  output: string;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "openai/gpt-5";
// The names fx skips outside a repository (src/main.zig ignored_list_entries),
// without .git, which every scan drops whatever the mode.
const SKIP = [".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage"];
const NOTE = /^\.\.\. skipped (\d+) entr(?:y|ies) named (.+) outside a git repository; pass path to search one$/;
const tlaDir = join(TLA_ROOT, "indexer");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  faults: process.argv.includes("--faults"),
  random: option("--random", 12),
  seed: option("--seed", 1),
  jobs: option("--jobs", 6),
  stress: option("--stress", 0),
  kills: option("--kills", 6),
};

// mulberry32: a small seeded generator, so a failing random layout replays.
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

const FIXED: Layout[] = [
  // The issue's folder.
  { name: "issue", files: ["src/app.py", "build/config.py", "dist/old.py", "coverage/c.py"] },
  // Nested and hidden skips, a skip inside a skipped folder, and a file named build.
  {
    name: "nested",
    files: [
      "src/ok.py", "app/build/gen.py", "app/src/main.py", "build/dist/deep.py", "tools/build",
      ".next/cache.js", ".cache/dist/x.js", "node_modules/pkg/index.js", "zig-out/bin/tool",
    ],
  },
  // Nothing to skip.
  { name: "clean", files: ["src/a.py", "lib/b.py", "lib/deep/c.py"] },
];

function randomLayout(random: () => number, index: number): Layout {
  const names = ["src", "lib", "app", "pkg", "build", "dist", "coverage", "node_modules", "zig-out", ".next", ".zig-cache", ".cache"];
  const pick = <T>(items: T[]) => items[Math.floor(random() * items.length)]!;
  const files = new Set<string>();
  const count = 3 + Math.floor(random() * 10);
  for (let n = 0; n < count; n++) {
    const depth = 1 + Math.floor(random() * 3);
    const parts = Array.from({ length: depth }, () => pick(names));
    // Now and then a file takes a skipped name itself.
    parts.push(random() < 0.15 ? pick(["build", "dist", "coverage"]) : `f${n}.txt`);
    files.add(parts.join("/"));
  }
  // A path can't be both a file and a folder.
  const list = [...files].sort();
  const folders = new Set(list.flatMap((file) => prefixes(file)));
  return { name: `random${index}`, files: list.filter((file) => !folders.has(file)) };
}

function prefixes(path: string): string[] {
  const parts = path.split("/");
  return parts.slice(0, -1).map((_, k) => parts.slice(0, k + 1).join("/"));
}

function foldersOf(layout: Layout): string[] {
  return [...new Set(layout.files.flatMap((file) => prefixes(file)))].sort();
}

function stressLayout(packages: number): Layout {
  const files: string[] = [];
  for (let i = 0; i < packages; i++) {
    files.push(`pkg${i}/src/index.js`, `pkg${i}/dist/out.js`, `pkg${i}/build/b.js`, `pkg${i}/node_modules/x/i.js`);
  }
  return { name: `stress${packages}`, files };
}

function cases(): Case[] {
  const list: Case[] = [];
  for (const layout of FIXED) {
    for (const repo of [false, true]) {
      for (const reuse of [false, true]) list.push({ id: `${layout.name}-${repo ? "repo" : "plain"}-${reuse ? "reuse" : "fresh"}`, layout, repo, reuse, fault: "none" });
    }
  }
  const random = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    const layout = randomLayout(random, i);
    const repo = random() < 0.3;
    const reuse = random() < 0.5;
    list.push({ id: `${layout.name}-${repo ? "repo" : "plain"}-${reuse ? "reuse" : "fresh"}`, layout, repo, reuse, fault: "none" });
  }
  if (options.faults) {
    const issue = FIXED[0]!;
    const nested = FIXED[1]!;
    for (const fault of ["truncated", "readable", "v3", "refused"] as const) {
      list.push({ id: `fault-${fault}`, layout: nested, repo: false, reuse: true, fault });
    }
    list.push({ id: "fault-unreadable", layout: issue, repo: false, reuse: false, fault: "unreadable", roots: ["", "src"] });
    // Big enough that the TUI's scan and save take a while.
    const big = stressLayout(400);
    const kills = generator(options.seed + 1000);
    for (let k = 0; k < options.kills; k++) {
      const refresh = k % 2 === 1;
      list.push({
        id: `fault-killed-${refresh ? "refresh" : "first"}-${k}`, layout: big, repo: false, reuse: true, fault: "killed",
        killAfterMs: Math.floor(kills() * 300), refresh, roots: ["", "pkg0", "pkg1/dist"],
      });
    }
  }
  if (options.stress > 0) {
    const layout = stressLayout(options.stress);
    for (const reuse of [false, true]) list.push({ id: `stress-${reuse ? "reuse" : "fresh"}`, layout, repo: false, reuse, fault: "none", roots: ["", "pkg0", "pkg7/dist"] });
  }
  return list;
}

// tool_files.pathContainsHiddenDirectoryComponent.
function hiddenFolderIn(path: string): boolean {
  const parts = path.split("/");
  return parts.slice(0, -1).some((part) => part.length > 1 && part.startsWith("."));
}

// Whether the tool keeps hidden folders: glob_files when its root has a hidden
// folder (shouldIncludeHidden), grep_files inside a repository
// (include_hidden_in_repository).
function keepsHidden(search: Search, repo: boolean): boolean {
  return search.tool === "glob_files" ? hiddenFolderIn(search.root === "" ? "." : search.root) : repo;
}

function parseResult(output: string) {
  const lines = output.split("\n").filter((line) => line.length > 0);
  const listed: string[] = [];
  const unknown: string[] = [];
  let truncated = /\(showing \d+-\d+ of \d+\)/.test(lines[0] ?? "");
  let note = { count: 0, names: [] as string[] };
  if (!/^\[(glob|grep)\] /.test(lines[0] ?? "")) unknown.push(lines[0] ?? "(empty)");
  for (const line of lines.slice(1)) {
    const match = NOTE.exec(line);
    if (line.startsWith(" - ")) listed.push(line.slice(3));
    else if (/^\.\.\. truncated to first \d+ matches$/.test(line) || /^\.\.\. more files available; use offset \d+ to continue$/.test(line) ||
      /^\.\.\. match collection cap reached at \d+ matches before all candidate files were scanned$/.test(line)) truncated = true;
    else if (match) note = { count: Number(match[1]), names: match[2]!.split(", ") };
    else unknown.push(line);
  }
  return { listed, truncated, note, unknown };
}

function snapshotFiles(home: string): string[] {
  const dir = join(home, ".fx", "file-index");
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter((name) => name.endsWith(".idx")).map((name) => join(dir, name));
}

function snapshotTemps(home: string): number {
  const dir = join(home, ".fx", "file-index");
  return existsSync(dir) ? readdirSync(dir).filter((name) => name.includes(".tmp.")).length : 0;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(check: () => boolean, timeoutMs: number): Promise<boolean> {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (check()) return true;
    await sleep(25);
  }
  return check();
}

let pathFault: string | null = null;
// ../lib/path-fault.c, built once per run.
function pathFaultLibrary(out: string): string {
  if (pathFault) return pathFault;
  const library = join(out, "path-fault.dylib");
  const source = join(import.meta.dirname, "../lib/path-fault.c");
  const built = Bun.spawnSync(["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", source, "-o", library]);
  if (built.exitCode !== 0) throw new Error(`building the path fault failed: ${built.stderr.toString()}`);
  return (pathFault = library);
}

// The magic and digest framing of src/core/indexer/snapshot.zig: the first
// line, then a SHA-256 of the payload.
function remarkSnapshot(path: string, magic: string) {
  const bytes = readFileSync(path);
  const end = bytes.indexOf(0x0a) + 1;
  const payload = bytes.subarray(end + 32);
  const digest = createHash("sha256").update(payload).digest();
  writeFileSync(path, Buffer.concat([Buffer.from(magic), digest, payload]), { mode: 0o600 });
}

function writeLayout(workspace: string, layout: Layout) {
  const made = new Set<string>();
  for (const file of layout.files) {
    const folder = join(workspace, ...file.split("/").slice(0, -1));
    if (!made.has(folder)) mkdirSync(folder, { recursive: true });
    made.add(folder);
    writeFileSync(join(workspace, file), "NEEDLE\n");
  }
}

type Env = Record<string, string>;

// The fx process under a tmux pane, once it has started: the wrappers tmux
// runs first are not fx, and killing one would not crash it.
async function startedFxPid(tui: any): Promise<number> {
  const until = Date.now() + 20_000;
  while (Date.now() < until) {
    const queue = [tui.panePid()];
    while (queue.length > 0) {
      const pid = queue.shift()!;
      const name = Bun.spawnSync(["ps", "-o", "comm=", "-p", String(pid)], { stdout: "pipe", stderr: "ignore" }).stdout.toString().trim();
      if (name.split("/").pop() === "fx") return pid;
      const children = Bun.spawnSync(["pgrep", "-P", String(pid)], { stdout: "pipe", stderr: "ignore" }).stdout.toString();
      queue.push(...children.split("\n").map(Number).filter((child) => Number.isSafeInteger(child) && child > 0));
    }
    await sleep(2);
  }
  throw new Error("fx never started in the tmux pane");
}

async function launchTui(helpers: any, workspace: string, env: Env) {
  return await helpers.TmuxSession.create({ cmd: shellQuote(binary), cwd: workspace, env, isolated: true, width: 100, height: 30, startupWaitMs: 0 });
}

// Saves the snapshot through the TUI's file index, applying the case's fault,
// and returns what is on disk afterwards.
async function saveSnapshot(helpers: any, c: Case, root: string, workspace: string, home: string, env: Env, out: string): Promise<Snapshot> {
  // A stamp is reusable only when it is older than the scan's start by the
  // granularity margin (src/core/indexer/tree.zig, 2 s).
  await sleep(2300);
  let tuiEnv = env;
  let record = "";
  if (c.fault === "refused") {
    const arm = join(root, "fault-armed");
    record = join(root, "fault-hits.txt");
    writeFileSync(arm, "armed");
    mkdirSync(join(home, ".fx", "file-index"), { recursive: true, mode: 0o700 });
    tuiEnv = {
      ...env, DYLD_INSERT_LIBRARIES: pathFaultLibrary(out), FX_PATH_FAULT_MODE: "refuse", FX_PATH_FAULT_ARM: arm,
      FX_PATH_FAULT_RECORD: record, FX_PATH_FAULT_TARGETS: join(home, ".fx", "file-index"),
    };
  }
  if (c.fault === "killed" && c.refresh) {
    // A whole snapshot first, then an edit, then the refresh that gets killed.
    const first = await launchTui(helpers, workspace, env);
    const saved = await waitFor(() => snapshotFiles(home).length > 0, 20_000);
    await first.kill();
    if (!saved) throw new Error(`${c.id}: the first TUI never saved a snapshot`);
    writeFileSync(join(workspace, "pkg0", "build", "late.js"), "NEEDLE\n");
    mkdirSync(join(workspace, "pkg1", "coverage"), { recursive: true });
    writeFileSync(join(workspace, "pkg1", "coverage", "late.js"), "NEEDLE\n");
    c.layout = { name: c.layout.name, files: [...c.layout.files, "pkg0/build/late.js", "pkg1/coverage/late.js"] };
    await sleep(2300);
  }
  const tui = await launchTui(helpers, workspace, tuiEnv);
  try {
    if (c.fault === "killed") {
      const pid = await startedFxPid(tui);
      await sleep(c.killAfterMs ?? 0);
      // SIGKILL, as in a crash, not the hangup tmux sends when it closes.
      process.kill(pid, "SIGKILL");
    } else if (c.fault === "refused") {
      const reached = await waitFor(() => existsSync(record) && readFileSync(record, "utf8").length > 0, 20_000);
      if (!reached) throw new Error(`${c.id}: the TUI never tried to save its snapshot`);
    } else {
      const saved = await waitFor(() => snapshotFiles(home).length > 0, 20_000);
      if (!saved) throw new Error(`${c.id}: the TUI never saved a snapshot`);
    }
  } finally {
    await tui.kill();
  }
  const files = snapshotFiles(home);
  if (files.length === 0) return "none";
  const path = files[0]!;
  switch (c.fault) {
    case "truncated":
      truncateSync(path, Math.floor(statSync(path).size / 2));
      return "garbage";
    case "readable":
      chmodSync(path, 0o644);
      return "garbage";
    case "v3":
      remarkSnapshot(path, "fx-file-index-v3\n");
      return "v3";
    default:
      return "v4";
  }
}

async function runCase(helpers: any, c: Case, scratch: string, out: string): Promise<{ observations: Observation[]; error?: string; evidence: object }> {
  // Real paths: ../lib/path-fault.c compares them, and /tmp is a link on macOS.
  const root = realpathSync(mkdtempSync(join(scratch, `${c.id}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeLayout(workspace, c.layout);
  if (c.repo) {
    const init = Bun.spawnSync(["git", "init", "-q"], { cwd: workspace, env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home } });
    if (init.exitCode !== 0) return { observations: [], error: `git init failed: ${init.stderr.toString()}`, evidence: {} };
  }
  const searches: Search[] = [];
  for (const folder of c.roots ?? ["", ...foldersOf(c.layout)]) {
    for (const tool of ["glob_files", "grep_files"] as const) searches.push({ tool, root: folder });
  }
  const served: number[] = [];
  const gateway = helpers.startDynamicFakeGateway((body: string) => {
    const index = served.length;
    served.push(index);
    const search = searches[index];
    if (!search) {
      return helpers.fakeGatewaySse([
        { type: "text-delta", id: "done", delta: "searched" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ]);
    }
    const input = search.tool === "glob_files"
      ? { pattern: "**/*", ...(search.root ? { path: search.root } : {}) }
      : { pattern: "NEEDLE", mode: "files_with_matches", ...(search.root ? { path: search.root } : {}) };
    return helpers.fakeGatewaySse([
      { type: "tool-call", toolCallId: `call_${index}`, toolName: search.tool, input },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const trace = join(root, "trace.log");
  const env: Env = testEnvironment({
    HOME: home,
    FX_HOME: join(home, ".fx"),
    AI_GATEWAY_API_KEY: "fake-skip-note-driver-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: MODEL,
    FX_MAX_AGENT_STEPS: String(searches.length + 5),
  });
  let unreadable = "";
  try {
    const snapshot: Snapshot = c.reuse ? await saveSnapshot(helpers, c, root, workspace, home, env, out) : "none";
    const temps = snapshotTemps(home);
    if (c.fault === "unreadable") {
      unreadable = join(workspace, "build");
      chmodSync(unreadable, 0o000);
    }
    const started = performance.now();
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", "Search the folder."], {
      cwd: workspace,
      env: { ...env, FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "core" },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 120_000);
    const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    const maxRss = child.resourceUsage()?.maxRSS ?? null;
    const evidence = { exit, seconds, max_rss_bytes: maxRss, requests: gateway.requests.length, searches: searches.length, snapshot, temps };
    if (exit !== 0) return { observations: [], error: `fx ask exited ${exit}: ${stderr.slice(-400)} ${stdout.slice(-200)}`, evidence };
    // One request per search plus the final answer, or the run proves nothing.
    if (gateway.requests.length !== searches.length + 1) return { observations: [], error: `gateway counted ${gateway.requests.length} requests, expected ${searches.length + 1}`, evidence };
    const last = JSON.parse(gateway.requests.at(-1)!.body) as { prompt: Array<{ content: unknown }> };
    const parts = last.prompt.flatMap((message) => (Array.isArray(message.content) ? message.content : [])) as Array<Record<string, any>>;
    const text = (value: any): string => typeof value === "string" ? value : Array.isArray(value) ? value.map(text).join("") : value && typeof value === "object" ? [text(value.text), text(value.value), text(value.content)].join("") : "";
    const lines = existsSync(trace) ? readFileSync(trace, "utf8").split("\n") : [];
    const listings = lines.filter((line) => line.includes("tool files reused snapshot") || line.includes("tool files scanned"));
    if (listings.length !== searches.length) return { observations: [], error: `trace log shows ${listings.length} listings for ${searches.length} searches`, evidence };
    const observations: Observation[] = [];
    for (const [index, search] of searches.entries()) {
      const result = parts.find((part) => part.type === "tool-result" && part.toolCallId === `call_${index}`);
      if (!result) return { observations: [], error: `no result for call_${index}`, evidence };
      const output = text(result.output);
      const parsed = parseResult(output);
      if (parsed.unknown.length > 0) return { observations: [], error: `call_${index} (${search.tool} ${search.root || "."}) has lines the driver cannot read: ${JSON.stringify(parsed.unknown)}`, evidence };
      observations.push({
        id: `${c.id}#${index}`,
        repo: c.repo,
        fault: c.fault,
        snapshot,
        reused: listings[index]!.includes("reused snapshot"),
        tool: search.tool,
        root: search.root,
        keep: keepsHidden(search, c.repo),
        listed: parsed.listed,
        truncated: parsed.truncated,
        note: parsed.note,
        output,
      });
    }
    // A plain reuse case that never reused proves nothing about reuse.
    if (c.reuse && c.fault === "none" && snapshot === "v4" && !observations[0]!.reused) {
      return { observations: [], error: "the workspace search did not reuse the saved snapshot", evidence };
    }
    return { observations, evidence };
  } finally {
    if (unreadable) chmodSync(unreadable, 0o755);
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const seq = (path: string) => (path === "" ? "<<>>" : `<<${path.split("/").map(str).join(", ")}>>`);
const set = (paths: string[]) => `{${paths.map(seq).join(", ")}}`;

function observedModule(observations: Observation[], layouts: Map<string, { repo: boolean; layout: Layout }>): string {
  const defs: string[] = [];
  const keyOf = new Map<string, string>();
  for (const [id, { layout }] of layouts) {
    const key = `L${keyOf.size}`;
    keyOf.set(id, key);
    const folders = foldersOf(layout);
    defs.push(`${key}files == ${set(layout.files)}`, `${key}folders == ${set(folders)}`, `${key}fs == ${key}files \\cup ${key}folders`);
  }
  const value = (o: Observation) => {
    const key = keyOf.get(o.id.split("#")[0]!)!;
    return `[repo |-> ${o.repo ? "TRUE" : "FALSE"}, fs |-> ${key}fs, files |-> ${key}files, folders |-> ${key}folders, ` +
      `snapshot |-> ${str(o.snapshot)}, reused |-> ${o.reused ? "TRUE" : "FALSE"}, root |-> ${seq(o.root)}, ` +
      `keep |-> ${o.keep ? "TRUE" : "FALSE"}, listed |-> ${set(o.listed)}, truncated |-> ${o.truncated ? "TRUE" : "FALSE"}, ` +
      `note |-> [count |-> ${o.note.count}, names |-> {${o.note.names.map(str).join(", ")}}]]`;
  };
  return [
    "---- MODULE SkipNoteObserved ----",
    "(* Generated by tests/tla/drivers/indexer/skip_note.ts. Do not edit. *)",
    "EXTENDS Sequences",
    ...defs,
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "====",
    "",
  ].join("\n");
}

function hiddenNames(layouts: Map<string, { layout: Layout }>): string[] {
  const names = new Set<string>();
  for (const { layout } of layouts.values()) {
    for (const file of layout.files) for (const part of file.split("/")) if (part.length > 1 && part.startsWith(".")) names.add(part);
  }
  return [...names].sort();
}

async function runTrace(observations: Observation[], layouts: Map<string, { repo: boolean; layout: Layout }>, bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["SkipNoteRules.tla", "SkipNoteTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "SkipNoteObserved.tla"), observedModule(observations, layouts));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Skip = {${SKIP.map(str).join(", ")}}`,
    `  Hidden = {${hiddenNames(layouts).map(str).join(", ")}}`,
    `  Bug = ${str(bug)}`,
    "INVARIANT AllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss16m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "SkipNoteTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant AllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], layouts: Map<string, { repo: boolean; layout: Layout }>, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), layouts, "none", parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  if (!helpers.tmuxAvailable()) {
    console.log("TOOL_ERROR: tmux is required for the reuse cases");
    return 2;
  }
  const out = outDir("indexer-skip-note");
  const scratch = join(out, "cases");
  mkdirSync(scratch, { recursive: true });
  const list = cases();
  const results: Array<Awaited<ReturnType<typeof runCase>>> = new Array(list.length);
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < list.length) {
      const index = next++;
      try {
        results[index] = await runCase(helpers, list[index]!, scratch, out);
      } catch (error) {
        results[index] = { observations: [], error: String(error), evidence: {} };
      }
    }
  });
  await Promise.all(workers);
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  const failed = list.map((c, index) => ({ c, r: results[index]! })).filter(({ r }) => r.error);
  for (const { c, r } of failed) console.log(`TOOL_ERROR: case ${c.id}: ${r.error} ${JSON.stringify(r.evidence)}`);
  if (failed.length > 0) return 2;

  const observations = results.flatMap((r) => r.observations);
  const layouts = new Map(list.map((c) => [c.id, { repo: c.repo, layout: c.layout }]));
  writeJson(join(out, "observations.json"), { seed: options.seed, cases: list.map((c, i) => ({ ...c, layout: c.layout.name, evidence: results[i]!.evidence })), observations });
  const reused = observations.filter((o) => o.reused).length;
  const noted = observations.filter((o) => o.note.count > 0).length;
  console.log(`${list.length} cases, ${observations.length} results of ${binary} in ${seconds}s (seed ${options.seed}); ${reused} from the snapshot, ${noted} with a note`);
  for (const [index, c] of list.entries()) {
    if (c.id.startsWith("stress") || c.fault !== "none") console.log(`  ${c.id}: ${JSON.stringify(results[index]!.evidence)}`);
  }
  console.log(`observations: ${join(out, "observations.json")}`);

  const design = await runTrace(observations, layouts, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, layouts, out);
    console.log(`first result the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    for (const bug of ["today", "unsaved"]) {
      const check = await runTrace(observations, layouts, bug, out);
      console.log(`self-check, Bug = ${bug}: ${check.verdict} (must be REJECTED)`);
      if (check.verdict !== "REJECTED") return check.verdict === "TOOL_ERROR" ? 2 : 1;
    }
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
