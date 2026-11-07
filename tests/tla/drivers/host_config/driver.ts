// Runs fx-term.wasm and the built fx along tests/tla/host_config/HostPreferences.tla
// and has TLC check every run (HostPreferencesTrace.tla).
//
// fx-term.wasm runs in this process through createFxTerminal (sdk/node.js,
// WebAssembly backend) in a headless xterm, with a mock fetch that counts its
// requests and a config store: once with no HOME in its env (home "unset") and
// once with HOME=/Users/example, where WASI has no files (home "broken"). The
// built fx runs in tmux with a temporary HOME and FX_HOME and a fake gateway:
// once with a fresh profile (home "writable") and once with settings.json
// overwritten with malformed bytes after startup, as another process might
// leave it, so every settings write refuses it (home "broken"; fx refuses to
// start on a malformed file).
//
// Each run sends a script of /model, /permissions ask|auto, /permissions
// full-access, and /settings startup-scrollback on|off. The fixed script sends
// every command at least twice; --walks N adds N seeded random scripts per
// surface. After each command the driver waits until the screen is quiet and
// records what the run has shown so far: the labels of "not saved to global
// settings" notices, the labels of lines that claim a save, the labels whose
// keys settings.json holds, the keys the config store holds, and whether the
// command showed the full-access warning. TLC replays the runs through the
// model's own actions. --self-check also replays them through the model of fx
// before the change (Rule = "today"), which must reject them.
//
// Usage (from the repository root, after zig build -Dwasm-surface=term and
// npm ci --prefix sdk/node):
//   bun tests/tla/drivers/host_config/driver.ts
//   bun tests/tla/drivers/host_config/driver.ts --self-check --walks 4 --seed 7
//   bun tests/tla/drivers/host_config/driver.ts --wasm-only
//   bun tests/tla/drivers/host_config/driver.ts --native-only
//
// FX_TERM_WASM picks the WebAssembly module (default
// <checkout>/zig-out/bin/fx-term.wasm); FX_BIN picks the native binary.
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../../../../sdk/node.js";
import { binary, targetHelpers, worktree } from "../lib/context";
import { REPO_ROOT, TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Cmd = "model" | "mode" | "full_access" | "scrollback";
type Profile = "native" | "js_host";
type Home = "unset" | "writable" | "broken";
type Step = {
  cmd: Cmd;
  text: string;
  errors: string[];
  saved: string[];
  file: string[];
  host: string[];
  warned: boolean;
};
type Run = { id: string; profile: Profile; home: Home; steps: Step[]; requests: number };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tlaDir = join(TLA_ROOT, "host_config");
const wasmPath = process.env.FX_TERM_WASM ?? join(worktree, "zig-out", "bin", "fx-term.wasm");
const MODELS = ["sdk/host-config-a", "sdk/host-config-b"];
const WARNING = "Full access enabled";
const STEP_TIMEOUT_MS = 15_000;

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  wasmOnly: process.argv.includes("--wasm-only"),
  nativeOnly: process.argv.includes("--native-only"),
  walks: option("--walks", 2),
  steps: option("--steps", 6),
  seed: option("--seed", 1),
};

// mulberry32: a small seeded generator, so a failing random script replays.
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

// Each entry is "<cmd> <text>".
const FIXED = [
  `model /model ${MODELS[0]}`,
  `model /model ${MODELS[0]}`,
  "mode /permissions ask",
  "full_access /permissions full-access",
  "mode /permissions auto",
  "full_access /permissions full-access",
  "scrollback /settings startup-scrollback off",
  `model /model ${MODELS[1]}`,
  "scrollback /settings startup-scrollback on",
];

function randomScript(next: () => number): string[] {
  const choices = [
    () => `model /model ${MODELS[Math.floor(next() * MODELS.length)]}`,
    () => `mode /permissions ${next() < 0.5 ? "ask" : "auto"}`,
    () => "full_access /permissions full-access",
    () => `scrollback /settings startup-scrollback ${next() < 0.5 ? "off" : "on"}`,
  ];
  return Array.from({ length: options.steps }, () => choices[Math.floor(next() * choices.length)]!());
}

function count(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

// A notice is "<glyph> <label>: <body>". Native /model with a model catalog
// reports under "model picker" (session_commands.zig), the same write.
const LABEL = "([a-z][a-z -]*?)";
const FAILURE = new RegExp(`✗ ${LABEL}: (?:active for this process but )?not saved to global settings|✗ ${LABEL}: global settings persistence uncertain`, "g");
const SAVED = new RegExp(`\\* ${LABEL}: saved to global settings`, "g");
const SCROLLBACK_SAVED = /startup_scrollback: (?:on|off) \((?:applies on next launch|saved user default)/;
const label = (raw: string) => (raw === "model picker" ? "model" : raw);

function labels(text: string): { errors: string[]; saved: string[] } {
  const errors = new Set<string>();
  for (const match of text.matchAll(FAILURE)) errors.add(label(match[1] ?? match[2]!));
  const saved = new Set<string>();
  for (const match of text.matchAll(SAVED)) saved.add(label(match[1]!));
  if (SCROLLBACK_SAVED.test(text)) saved.add("startup-scrollback");
  return { errors: [...errors].sort(), saved: [...saved].sort() };
}

function fileLabels(path: string): string[] {
  if (!existsSync(path)) return [];
  let settings: any;
  try {
    settings = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return [];
  }
  const found: string[] = [];
  if (settings?.models?.gateway !== undefined || settings?.model !== undefined) found.push("model");
  if (settings?.permission_mode !== undefined) found.push("permission-mode");
  if (settings?.yolo_acknowledged !== undefined) found.push("full-access-acknowledgment");
  if (settings?.startup_scrollback !== undefined) found.push("startup-scrollback");
  return found.sort();
}

// What shows that a command ran: its state line, or for startup scrollback
// either its state line or a failed save.
function signal(text: string, line: string): number {
  const [cmd, ...rest] = line.split(" ");
  const args = rest.join(" ");
  if (cmd === "model") return count(text, `Switched to ${args.split(" ")[1]}`);
  if (cmd === "mode") return count(text, `mode set to ${args.split(" ")[1]}`);
  if (cmd === "full_access") return count(text, "mode set to full access");
  const value = args.split(" ").at(-1);
  return count(text, `startup_scrollback: ${value}`) +
    count(text, "startup-scrollback: not saved") +
    count(text, "startup-scrollback: active for this process but not saved") +
    count(text, "startup-scrollback: global settings persistence uncertain");
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function runWasm(id: string, home: "unset" | "broken", script: string[]): Promise<Run> {
  const { Terminal } = createRequire(join(REPO_ROOT, "sdk", "node", "package.json"))("@xterm/headless");
  const wasm = readFileSync(wasmPath);
  const terminal = new Terminal({ cols: 200, rows: 50, allowProposedApi: true, scrollback: 5000 });
  const stored: string[] = [];
  let requests = 0;
  let exited: number | undefined;
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: {
      AI_GATEWAY_API_KEY: "host-config-fake-key",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      ...(home === "broken" ? { HOME: "/Users/example" } : {}),
    },
    configStore: {
      get() { return null; },
      set(key: string) { stored.push(key); },
    },
    fetch: async () => {
      requests += 1;
      return new Response('{"object":"list","data":[]}', {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  });
  runtime.exited.then((code: number) => { exited = code; });
  const flush = () => new Promise<void>((resolve) => terminal.write("", resolve));
  const grid = () => {
    const lines: string[] = [];
    for (let row = 0; row < terminal.buffer.active.length; row++) {
      lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  };
  const viewport = () => {
    const lines: string[] = [];
    const top = terminal.buffer.active.viewportY;
    for (let row = top; row < top + terminal.rows; row++) {
      lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  };
  // Waits until predicate holds and the grid has not changed for 300 ms.
  const settle = async (predicate: () => boolean, what: string) => {
    const deadline = performance.now() + STEP_TIMEOUT_MS;
    let last = "";
    let since = performance.now();
    while (true) {
      await flush();
      if (exited !== undefined) throw new Error(`${id} exited with code ${exited} waiting for ${what}`);
      const now = grid();
      if (now !== last) { last = now; since = performance.now(); }
      if (predicate() && performance.now() - since >= 300) return;
      if (performance.now() >= deadline) throw new Error(`${id} timed out waiting for ${what}:\n${now}`);
      await sleep(10);
    }
  };

  const steps: Step[] = [];
  try {
    await settle(() => grid().includes("Run /help for commands"), "startup");
    for (const line of script) {
      const before = signal(grid(), line);
      const text = line.slice(line.indexOf(" ") + 1);
      runtime.write(`${text}\r`);
      await settle(() => signal(grid(), line) > before, text);
      const cmd = line.split(" ")[0] as Cmd;
      steps.push({
        cmd,
        text,
        ...labels(grid()),
        file: [],
        host: [...new Set(stored.filter((key) => key === "model" || key === "mode"))].sort(),
        warned: cmd === "full_access" && viewport().includes(WARNING),
      });
    }
    runtime.write("/exit\r");
    await Promise.race([runtime.exited, sleep(5000)]);
  } finally {
    if (exited === undefined) runtime.abort?.();
  }
  if (requests === 0) throw new Error(`${id}: the mock fetch counted no requests`);
  return { id, profile: "js_host", home, steps, requests };
}

async function runNative(helpers: any, id: string, home: "writable" | "broken", script: string[], scratch: string): Promise<Run> {
  const { TmuxSession, startFakeGateway } = helpers;
  const root = mkdtempSync(join(scratch, `${id}-`));
  const homeDir = join(root, "home");
  const fxHome = join(homeDir, ".fx");
  const workspace = join(root, "workspace");
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  const settingsPath = join(fxHome, "settings.json");
  const stderrPath = join(root, "stderr.log");
  const gateway = startFakeGateway([], {
    models: MODELS.map((model) => ({ id: model, type: "language", tags: ["tool-use"] })),
  });
  let session: any = null;
  try {
    session = await TmuxSession.create({
      cmd: binary,
      cwd: workspace,
      width: 200,
      height: 50,
      isolated: true,
      stderrPath,
      env: {
        HOME: homeDir,
        FX_HOME: fxHome,
        AI_GATEWAY_API_KEY: "host-config-fake-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_E2E_DISABLE_DOTENV: "1",
      },
    });
    await session.waitForText("Run /help", STEP_TIMEOUT_MS);
    // /model resolves names from the model list; wait until fx has asked for
    // it, so a cold list never sends the command's own request.
    const listed = Date.now() + STEP_TIMEOUT_MS;
    while (gateway.modelRequests.length === 0) {
      if (Date.now() > listed) throw new Error(`${id}: fx never asked the fake gateway for the model list`);
      await sleep(25);
    }
    await session.waitForStableComposer(STEP_TIMEOUT_MS, 300);
    // A malformed settings.json makes every later settings write fail.
    if (home === "broken") writeFileSync(settingsPath, "{ not json\n", { mode: 0o600 });
    const steps: Step[] = [];
    for (const line of script) {
      if (!session.isAlive()) {
        const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, "utf8").slice(-2000) : "";
        throw new Error(`${id}: fx exited before ${line}; stderr:\n${stderr}`);
      }
      const before = signal(await session.captureFullScrollback(), line);
      const text = line.slice(line.indexOf(" ") + 1);
      await session.sendText(text);
      const scrollback = await session.waitForStableScrollback(
        (current: string) => signal(current, line) > before,
        STEP_TIMEOUT_MS,
        400,
      ).catch((error: Error) => {
        const stderr = existsSync(stderrPath) ? readFileSync(stderrPath, "utf8").slice(-2000) : "";
        throw new Error(`${id}: ${text}: ${error.message}\nfx alive: ${session.isAlive()}; stderr:\n${stderr}`);
      });
      const cmd = line.split(" ")[0] as Cmd;
      const pane = await session.capturePane();
      steps.push({
        cmd,
        text,
        ...labels(scrollback),
        file: fileLabels(settingsPath),
        host: [],
        warned: cmd === "full_access" && pane.includes(WARNING),
      });
    }
    const requests = gateway.modelRequests.length;
    if (requests === 0) throw new Error(`${id}: the fake gateway counted no model requests`);
    return { id, profile: "native", home, steps, requests };
  } finally {
    if (session) await session.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const set = (values: string[]) => `{${[...new Set(values)].sort().map(str).join(", ")}}`;

function observedModule(runs: Run[]): string {
  const step = (s: Step) =>
    `[cmd |-> ${str(s.cmd)}, errors |-> ${set(s.errors)}, saved |-> ${set(s.saved)}, ` +
    `file |-> ${set(s.file)}, host |-> ${set(s.host)}, warned |-> ${s.warned ? "TRUE" : "FALSE"}]`;
  const run = (r: Run) =>
    `[profile |-> ${str(r.profile)}, home |-> ${str(r.home)}, steps |-> <<${r.steps.map(step).join(",\n    ")}>>]`;
  return [
    "----------------------- MODULE HostPreferencesObserved -----------------------",
    "(* Generated by tests/tla/drivers/host_config/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${runs.map(run).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(runs: Run[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${rule}-`));
  for (const file of ["HostPreferences.tla", "HostPreferencesTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "HostPreferencesObserved.tla"), observedModule(runs));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Rule = ${str(rule)}`,
    "  MaxSteps = 100000",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "HostPreferencesTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first run the model cannot produce, and in it the first step.
async function firstMismatch(runs: Run[], rule: string, parent: string): Promise<{ run: string; step: Step | null } | null> {
  for (const run of runs) {
    for (let length = 1; length <= run.steps.length; length++) {
      const { verdict } = await runTrace([{ ...run, steps: run.steps.slice(0, length) }], rule, parent);
      if (verdict === "TOOL_ERROR") return null;
      if (verdict === "REJECTED") return { run: run.id, step: run.steps[length - 1]! };
    }
  }
  return null;
}

async function main(): Promise<number> {
  if (!supportsJspi()) {
    console.log("TOOL_ERROR: this runtime has no WebAssembly JSPI");
    return 2;
  }
  if (!existsSync(wasmPath)) {
    console.log(`TOOL_ERROR: missing ${wasmPath}; run zig build -Dwasm-surface=term`);
    return 2;
  }
  const out = outDir("host_config");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const next = generator(options.seed);
  const scripts = [FIXED, ...Array.from({ length: options.walks }, () => randomScript(next))];
  console.log(`seed ${options.seed}, ${scripts.length} scripts, wasm ${wasmPath}${options.wasmOnly ? "" : `, native ${binary}`}`);

  const runs: Run[] = [];
  const started = performance.now();
  if (!options.nativeOnly) {
    for (const [index, script] of scripts.entries()) {
      for (const home of ["unset", "broken"] as const) {
        runs.push(await runWasm(`wasm-${home}-${index}`, home, script));
      }
    }
  }
  if (!options.wasmOnly) {
    const helpers = await targetHelpers();
    for (const [index, script] of scripts.entries()) {
      for (const home of ["writable", "broken"] as const) {
        runs.push(await runNative(helpers, `native-${home}-${index}`, home, script, scratch));
      }
    }
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "runs.json"), runs);
  console.log(`${runs.length} runs, ${runs.reduce((sum, run) => sum + run.steps.length, 0)} commands in ${seconds}s`);
  for (const run of runs) {
    const last = run.steps.at(-1)!;
    console.log(`  ${run.id}: requests ${run.requests}, errors ${set(last.errors)}, saved ${set(last.saved)}, ` +
      `file ${set(last.file)}, host ${set(last.host)}, warnings ${run.steps.filter((s) => s.warned).length}`);
  }
  console.log(`runs: ${join(out, "runs.json")}`);

  const design = await runTrace(runs, "fixed", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(runs, "fixed", out);
    console.log(`first step the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(runs, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
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
