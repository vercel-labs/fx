// Runs the built fx binary along tests/tla/terminal/ShellSnapshotCapture.tla
// and has TLC check every run it observes (ShellSnapshotCaptureTrace.tla).
//
// Each case is one `fx ask` against a local fake gateway, with a temporary
// HOME, FX_HOME, and ZDOTDIR. The startup files define the model's functions
// in the state the case gives (loaded, an autoload stub, or absent) and do one
// of the model's ZDOTDIR moves, from an inherited ZDOTDIR or from HOME. The
// completion function is loaded from a file of its own name that zsh
// autoloads, or from a file under `completion/` that bash sources. fx runs
// a probe command, the driver edits the startup file the login shell reads,
// and fx runs the probe again. Each probe reports which functions it can call,
// ZDOTDIR and whether it is exported, the marker the startup file exports, and
// how many times the startup files ran.
//
// A window case edits the startup file while fx captures the snapshot. Its
// startup file says it was read and waits; the driver replaces the file at
// that moment and lets the shell go on. The first probe then shows whether fx
// noticed the edit made inside the capture.
//
// A churn case has a startup file that touches itself at every start, so every
// capture ends stale, as when a tool regenerates its own startup file. fx must
// not wait for ever: after the capture and one recapture the command runs with
// the full startup, and the probe shows that (the login flag of its shell, and
// one more load of the startup files). The case has a deadline; a command that
// never ran fails the driver (exit 1).
//
// TLC replays the cases through the model's own actions under fx's rules.
// --self-check also replays them under the rules of fx before the ZDOTDIR
// change (every `_` function dropped, ZDOTDIR read only from the environment)
// and under the rules before the capture-start rule (the moved folder stamped
// when the capture ends), which must reject them. --rules old and --rules head
// swap the two: run against a binary built before the change (FX_BIN), those
// rules must accept its cases and today's must reject them. Those binaries have
// no bound on the captures, so the churn cases are left out of those runs. The
// self-check also replays the cases under the rules before the bound, which
// accept every case but the churn ones.
//
// fx runs the login shell from the passwd entry, so the cases are zsh's or
// bash's, whichever this machine has.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/terminal/capture.ts
//   bun tests/tla/drivers/terminal/capture.ts --self-check
//   bun tests/tla/drivers/terminal/capture.ts --random 40 --seed 7 --jobs 8
//   FX_BIN=/path/to/older/fx bun tests/tla/drivers/terminal/capture.ts --rules old --self-check
//   FX_BIN=/path/to/fx-before-the-capture-start-rule bun tests/tla/drivers/terminal/capture.ts --rules head
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce or a churn command that never ran, 2 a toolchain, build,
// or harness failure.
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Shell = "zsh" | "bash";
type FState = "absent" | "stub" | "loaded";
type ZMode = "keep" | "unset" | "export_moved" | "local_moved" | "assign_moved";
type Dir = "home" | "inherited" | "moved";
type Saw = { callable: string[]; z: string; zexp: boolean; fresh: boolean; captures: number; full: boolean };
type Event = { kind: "run"; saw: Saw } | { kind: "edit" } | { kind: "window_edit" };
type Case = {
  id: string;
  shell: Shell;
  inherited: boolean;
  zmode: ZMode;
  fstate: Record<string, FState>;
  // The edit lands while the capture runs, not between two commands.
  window: boolean;
  // The startup file touches itself at every start, so every capture ends stale.
  churn: boolean;
};
type Observation = Case & {
  events: Event[];
  evidence: { exit: number; requests: number; seconds: number; tail: string; timedOut: boolean };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Rules = { filter: string; zdotdir: string };

// The model's functions: a public wrapper, `_` and `__` helpers it calls, a
// completion function, and one of fx's own capture names. The completion
// function is the one the model puts in its `Completion` set.
const FUNCS = ["wrap", "_helper", "__dunder", "_comp", "__fx_snapshot_x"];
const ZMODES: ZMode[] = ["keep", "unset", "export_moved", "local_moved", "assign_moved"];
const tlaDir = join(TLA_ROOT, "terminal");
// A churn case runs a few login shells and finishes in about a second; fx before
// the bound waits for ever.
const CHURN_DEADLINE_MS = 20_000;
const SPECS = ["ShellSnapshotCapture.tla", "ShellSnapshotCaptureTrace.tla"];

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

type RuleSet = "fixed" | "old" | "head" | "unbounded";
const RULES: Record<RuleSet, Rules> = {
  fixed: { filter: "fixed", zdotdir: "fixed" },
  // fx before the ZDOTDIR change.
  old: { filter: "old", zdotdir: "env_only" },
  // fx with the ZDOTDIR watch, before the capture-start rule.
  head: { filter: "fixed", zdotdir: "stamp_late" },
  // fx before the bound on the captures one command starts.
  unbounded: { filter: "fixed", zdotdir: "unbounded" },
};

function rulesOption(): RuleSet {
  const at = process.argv.indexOf("--rules");
  if (at < 0) return "fixed";
  const value = process.argv[at + 1];
  if (value !== "fixed" && value !== "old" && value !== "head") throw new Error("--rules takes fixed, old, or head");
  return value;
}

const options = {
  rules: rulesOption(),
  selfCheck: process.argv.includes("--self-check"),
  random: option("--random", 20),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
};

// The shell fx runs: the passwd entry's bash or zsh, or the platform default
// (src/core/terminal/shell_resolver.zig supportedLoginShell). Bun's
// userInfo().shell reports $SHELL, so the entry is read with Python's pwd.
function loginShell(): Shell {
  const result = Bun.spawnSync(["python3", "-c", "import os, pwd; print(pwd.getpwuid(os.getuid()).pw_shell)"]);
  if (result.exitCode !== 0) throw new Error("cannot read the passwd entry's shell with python3");
  const name = basename(result.stdout.toString().trim());
  if (name === "zsh" || name === "bash") return name;
  return process.platform === "darwin" ? "zsh" : "bash";
}

// mulberry32: a small seeded generator, so a failing random case replays.
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

function cases(shell: Shell): Case[] {
  const all = (state: FState) => Object.fromEntries(FUNCS.map((f) => [f, state]));
  const patterns: Array<Record<string, FState>> = shell === "zsh"
    ? [
      all("loaded"),
      // compinit's shape: helpers loaded, the completion function a stub.
      { ...all("loaded"), _comp: "stub" },
      // A completion function loaded during startup, a public stub.
      { ...all("absent"), _comp: "loaded", wrap: "stub" },
      all("stub"),
      all("absent"),
    ]
    : [all("loaded"), { ...all("absent"), wrap: "loaded", _helper: "loaded", __dunder: "loaded" }, all("absent")];
  const result: Case[] = [];
  const modes: ZMode[] = shell === "zsh" ? ZMODES : ["keep"];
  const inherit = shell === "zsh" ? [false, true] : [false];
  for (const fstate of patterns) {
    for (const zmode of modes) {
      for (const inherited of inherit) {
        result.push({ id: `case${result.length}`, shell, inherited, zmode, fstate, window: false, churn: false });
      }
    }
  }
  // An edit inside the capture, for every place the startup files can send
  // ZDOTDIR: the model's discriminating cases move it to a folder fx cannot
  // have stamped before the capture.
  for (const zmode of modes) {
    for (const inherited of inherit) {
      result.push({ id: `case${result.length}`, shell, inherited, zmode, fstate: all("loaded"), window: true, churn: false });
    }
  }
  // A startup file that touches itself at every start, for every place the
  // startup files can send ZDOTDIR. Binaries from before the bound never run
  // these commands.
  if (options.rules === "fixed") {
    for (const zmode of modes) {
      for (const inherited of inherit) {
        result.push({ id: `case${result.length}`, shell, inherited, zmode, fstate: all("loaded"), window: false, churn: true });
      }
    }
  }
  const next = generator(options.seed);
  const states: FState[] = shell === "zsh" ? ["absent", "stub", "loaded"] : ["absent", "loaded"];
  for (let i = 0; i < options.random; i++) {
    const fstate = Object.fromEntries(FUNCS.map((f) => [f, states[Math.floor(next() * states.length)]!]));
    const zmode = modes[Math.floor(next() * modes.length)]!;
    const inherited = inherit[Math.floor(next() * inherit.length)]!;
    const window = next() < 0.3;
    result.push({ id: `case${result.length}`, shell, inherited, zmode, fstate, window, churn: false });
  }
  return result;
}

// The model's ReadDir: the folder whose startup file the login shell reads.
function readDir(c: Case): Dir {
  if (c.shell === "bash") return "home";
  if (c.zmode === "export_moved" || c.zmode === "local_moved" || c.zmode === "assign_moved") return "moved";
  if (c.zmode === "unset") return "home";
  return c.inherited ? "inherited" : "home";
}

const ZSHENV: Record<ZMode, string> = {
  keep: "",
  unset: "unset ZDOTDIR\n",
  export_moved: "export ZDOTDIR=\"$HOME/moved\"\n",
  local_moved: "unset ZDOTDIR\nZDOTDIR=\"$HOME/moved\"\n",
  assign_moved: "ZDOTDIR=\"$HOME/moved\"\n",
};

const WINDOW_GATE = [
  "if [ ! -e \"$HOME/release\" ]; then",
  "  : > \"$HOME/reached\"",
  "  i=0",
  "  while [ ! -e \"$HOME/release\" ] && [ \"$i\" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done",
  "fi",
].join("\n");

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function startupFile(c: Case, rcPath: string): string {
  const lines = ["printf '%s\\n' loaded >> \"$HOME/rc.log\"", "export FX_CAPTURE_MARK=0"];
  if (c.shell === "zsh") lines.push("fpath=(\"$HOME/fn\" $fpath)");
  for (const f of FUNCS) {
    const body = f === "wrap" ? "_helper; __dunder" : `printf '%s\\n' ${f}-ran`;
    switch (c.fstate[f]) {
      case "loaded":
        if (f === "_comp" && c.shell === "zsh") {
          // zsh loads a completion function through autoload from a file of its
          // own name, as on first use.
          lines.push("autoload -Uz _comp; _comp >/dev/null");
        } else if (f === "_comp") {
          // bash gets it from a completion script, whose path says so.
          lines.push(". \"$HOME/completion/_comp.bash\"");
        } else {
          lines.push(`${f}() { ${body}; }`);
        }
        break;
      case "stub":
        lines.push(`autoload -Uz ${f}`);
        break;
      case "absent":
        break;
    }
  }
  // The window case's shell says it read this file and waits for the driver to
  // edit it. A later capture finds the release file and goes on.
  if (c.window) lines.push(WINDOW_GATE);
  // New times on the file at every start; its contents never change.
  if (c.churn) lines.push(`touch ${shellQuote(rcPath)}`);
  return `${lines.join("\n")}\n`;
}

// Writes the case's startup files under root/home and returns its folders.
function writeCase(root: string, c: Case) {
  const home = join(root, "home");
  const dirs: Record<Dir, string> = { home, inherited: join(home, "inherited"), moved: join(home, "moved") };
  for (const dir of [...Object.values(dirs), join(home, "fn"), join(root, "fxhome"), join(root, "workspace")]) {
    mkdirSync(dir, { recursive: true });
  }
  for (const f of FUNCS) writeFileSync(join(home, "fn", f), `printf '%s\\n' ${f}-ran\n`);
  if (c.shell === "bash") {
    mkdirSync(join(home, "completion"), { recursive: true });
    writeFileSync(join(home, "completion", "_comp.bash"), "_comp() { printf '%s\\n' _comp-ran; }\n");
  }
  let rcPath: string;
  if (c.shell === "zsh") {
    writeFileSync(join(c.inherited ? dirs.inherited : home, ".zshenv"), ZSHENV[c.zmode]);
    rcPath = join(dirs[readDir(c)], ".zshrc");
  } else {
    rcPath = join(home, ".bash_profile");
  }
  writeFileSync(rcPath, startupFile(c, rcPath));
  return { home, dirs, rcPath, workspace: join(root, "workspace"), fxHome: join(root, "fxhome") };
}

const PROBE = [
  `for f in ${FUNCS.join(" ")}; do if typeset -f "$f" >/dev/null 2>&1; then printf 'fn:%s=1\\n' "$f"; ` +
  `else printf 'fn:%s=0\\n' "$f"; fi; done`,
  "printf 'zdotdir=%s\\n' \"${ZDOTDIR-none}\"",
  "if printenv ZDOTDIR >/dev/null; then echo zexp=1; else echo zexp=0; fi",
  "printf 'mark=%s\\n' \"$FX_CAPTURE_MARK\"",
  "printf 'loads=%s\\n' \"$(wc -l < \"$HOME/rc.log\" | tr -d ' ')\"",
  // fx runs a command from a snapshot in a shell that is not a login shell, and
  // with the full startup in one that is.
  "if [ -n \"$ZSH_VERSION\" ]; then if [[ -o login ]]; then echo login=1; else echo login=0; fi; " +
  "else if shopt -q login_shell; then echo login=1; else echo login=0; fi; fi",
].join("; ");

// The command output in shell tool result `callId` of a request fx sent to
// the gateway. The result is an object, sometimes sent as JSON text, whose
// `output_delta` holds what the command printed.
function toolResult(body: string, callId: string): string | null {
  try {
    for (const message of (JSON.parse(body).prompt ?? []).toReversed()) {
      if (message.role !== "tool") continue;
      for (const part of message.content ?? []) {
        if (part.type !== "tool-result" || part.toolCallId !== callId) continue;
        const value = part.output?.value;
        const result = typeof value === "string" ? JSON.parse(value) : value;
        return typeof result?.output_delta === "string" ? result.output_delta : null;
      }
    }
  } catch {
    return null;
  }
  return null;
}

function readSaw(output: string, dirs: Record<Dir, string>, version: number): Saw | null {
  const callable = FUNCS.filter((f) => output.includes(`fn:${f}=1`));
  const zdotdir = /zdotdir=([^\n]*)/.exec(output)?.[1];
  const zexp = /zexp=([01])/.exec(output)?.[1];
  const mark = /mark=([^\n]*)/.exec(output)?.[1];
  const loads = /loads=(\d+)/.exec(output)?.[1];
  const login = /login=([01])/.exec(output)?.[1];
  if (zdotdir === undefined || zexp === undefined || mark === undefined || loads === undefined || login === undefined) {
    return null;
  }
  const named = (Object.entries(dirs) as Array<[Dir, string]>).find(([, path]) => path === zdotdir)?.[0];
  return {
    callable,
    z: zdotdir === "none" ? "none" : named ?? `other:${zdotdir}`,
    zexp: zexp === "1",
    fresh: mark === String(version),
    captures: Number(loads),
    full: login === "1",
  };
}

// Waits until the shell says it read the startup file, replaces the file the
// way an editor saving it would (a new file under the same name), and lets the
// shell go on. Returns whether it edited.
async function holdAndEdit(home: string, rcPath: string, over: () => boolean): Promise<boolean> {
  const reached = join(home, "reached");
  const deadline = Date.now() + 60_000;
  while (!existsSync(reached)) {
    if (over() || Date.now() > deadline) return false;
    await Bun.sleep(20);
  }
  const next = `${rcPath}.next`;
  writeFileSync(next, `${readFileSync(rcPath, "utf8")}export FX_CAPTURE_MARK=1\n`);
  renameSync(next, rcPath);
  writeFileSync(join(home, "release"), "");
  return true;
}

async function runCase(helpers: any, c: Case, scratch: string): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${c.id}-`));
  const { home, dirs, rcPath, workspace, fxHome } = writeCase(root, c);
  const call = (id: string) =>
    helpers.fakeGatewayToolCall(id, "shell", { request: { action: "run", command: PROBE, yield_time_ms: 30_000 } });
  const gateway = helpers.startFakeGateway(
    c.window
      ? [call("probe_window"), helpers.fakeGatewayFinalText("CAPTURE_CASE_DONE")]
      : c.churn
      ? [call("probe_churn"), helpers.fakeGatewayFinalText("CAPTURE_CASE_DONE")]
      : [
        call("probe_before"),
        () => {
          // The user edits the startup file the shell reads between two commands.
          appendFileSync(rcPath, "export FX_CAPTURE_MARK=1\n");
          return call("probe_after");
        },
        helpers.fakeGatewayFinalText("CAPTURE_CASE_DONE"),
      ],
  );
  try {
    const started = performance.now();
    const env: Record<string, string> = {
      HOME: home,
      FX_HOME: fxHome,
      AI_GATEWAY_API_KEY: "fake-shell-capture-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
    };
    if (c.inherited) env.ZDOTDIR = dirs.inherited;
    const child = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-save", "Probe the shell."], {
      cwd: workspace,
      env: testEnvironment(env),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    // A churn command that has not run by now never will.
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill(9);
    }, c.churn ? CHURN_DEADLINE_MS : 90_000);
    let over = false;
    const edited = c.window ? holdAndEdit(home, rcPath, () => over) : Promise.resolve(false);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    over = true;
    clearTimeout(timer);
    const events: Event[] = [];
    if (c.churn) {
      // Every capture of the case ends stale by what the startup file does, so
      // the edit lands inside each of the two captures, and the command follows.
      const churn = gateway.requests[1] ? toolResult(gateway.requests[1].body, "probe_churn") : null;
      const saw = churn === null ? null : readSaw(churn, dirs, 0);
      if (saw) events.push({ kind: "window_edit" }, { kind: "window_edit" }, { kind: "run", saw });
    } else if (c.window) {
      // One probe, after the edit made inside the capture.
      const window = gateway.requests[1] ? toolResult(gateway.requests[1].body, "probe_window") : null;
      const saw = window === null ? null : readSaw(window, dirs, 1);
      if (saw && (await edited)) events.push({ kind: "window_edit" }, { kind: "run", saw });
    } else {
      const before = gateway.requests[1] ? toolResult(gateway.requests[1].body, "probe_before") : null;
      const after = gateway.requests[2] ? toolResult(gateway.requests[2].body, "probe_after") : null;
      const first = before === null ? null : readSaw(before, dirs, 0);
      const second = after === null ? null : readSaw(after, dirs, 1);
      if (first) events.push({ kind: "run", saw: first });
      if (first && second) events.push({ kind: "edit" }, { kind: "run", saw: second });
    }
    return {
      ...c,
      events,
      evidence: {
        exit,
        // Every request must reach this fake gateway: the probes and the answer.
        requests: gateway.requests.length,
        seconds: Math.round((performance.now() - started) / 100) / 10,
        tail: `${stdout.slice(-400)}\n${stderr.slice(-400)}`,
        timedOut,
      },
    };
  } finally {
    gateway.stop();
  }
}

function tlaString(value: string): string {
  return JSON.stringify(value);
}

function tlaSet(values: string[]): string {
  return `{${values.map(tlaString).join(", ")}}`;
}

function tlaSaw(saw: Saw): string {
  return `[callable |-> ${tlaSet(saw.callable)}, z |-> ${tlaString(saw.z)}, zexp |-> ${saw.zexp ? "TRUE" : "FALSE"}, ` +
    `fresh |-> ${saw.fresh ? "TRUE" : "FALSE"}, captures |-> ${saw.captures}, full |-> ${saw.full ? "TRUE" : "FALSE"}]`;
}

// Edit events, between commands or inside a capture, carry a placeholder, so
// every event record has the same fields.
const NO_SAW: Saw = { callable: [], z: "none", zexp: false, fresh: true, captures: 0, full: false };

function observedModule(observations: Observation[]): string {
  const cases = observations.map((o) => {
    const arms = FUNCS.map((f) => `f = ${tlaString(f)} -> ${tlaString(o.fstate[f]!)}`).join(" [] ");
    const events = o.events.map((e) =>
      `[kind |-> ${tlaString(e.kind)}, saw |-> ${tlaSaw(e.kind === "run" ? e.saw : NO_SAW)}]`
    );
    return `  [shell |-> ${tlaString(o.shell)}, inherited |-> ${o.inherited ? "TRUE" : "FALSE"}, ` +
      `zmode |-> ${tlaString(o.zmode)},\n   fstate |-> [f \\in ${tlaSet(FUNCS)} |-> CASE ${arms}],\n` +
      `   events |-> <<${events.join(",\n     ")}>>]`;
  });
  return [
    "------------------- MODULE ShellSnapshotCaptureObserved -------------------",
    "\\* Generated by tests/tla/drivers/terminal/capture.ts.",
    "EXTENDS Sequences",
    `Observed == <<\n${cases.join(",\n")}\n>>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rules: Rules, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${rules.filter}-${rules.zdotdir}-`));
  writeFileSync(join(dir, "ShellSnapshotCaptureObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  FilterRule = ${tlaString(rules.filter)}`,
    `  ZdotdirRule = ${tlaString(rules.zdotdir)}`,
    // A churn case edits the folder the shell reads once inside each capture.
    "  MaxEdits = 2",
    "  MaxRuns = 2",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "ShellSnapshotCaptureTrace", "trace.cfg", SPECS, tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first case the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], rules: Rules, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), rules, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.log(`TOOL_ERROR: missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const helpers = await targetHelpers();
  const out = outDir("terminal-capture");
  const scratch = join(out, "cases");
  mkdirSync(scratch, { recursive: true });
  const shell = loginShell();
  const all = cases(shell);
  const observations: Observation[] = new Array(all.length);
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < all.length) {
      const index = next++;
      observations[index] = await runCase(helpers, all[index]!, scratch);
    }
  });
  await Promise.all(workers);
  writeJson(join(out, "observations.json"), observations);
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  console.log(`${observations.length} ${shell} cases of ${binary} in ${seconds}s`);
  console.log(`observations: ${join(out, "observations.json")}`);
  // A churn command that never ran is what the bound on the captures prevents:
  // fx kept capturing while the startup file kept changing its own files.
  const stuck = observations.filter((o) => o.churn && o.events.length === 0 && o.evidence.timedOut);
  if (stuck.length > 0) {
    console.log(
      `FAIL: ${stuck.length} churn cases never ran their command in ${CHURN_DEADLINE_MS / 1000}s: ` +
        stuck.map((o) => o.id).join(", "),
    );
    console.log(`first: ${JSON.stringify(stuck[0])}`);
    return 1;
  }
  // A window case has one probe and two events: the edit inside the capture,
  // then the run. A churn case has one probe and three: an edit inside each of
  // the two captures, then the run. The others have two probes and three
  // events: run, edit, run. Every request reaches the fake gateway: the probes
  // and the answer.
  const broken = observations.find((o) => {
    const probes = o.window || o.churn ? 1 : 2;
    const events = o.window ? 2 : 3;
    return o.events.length !== events || o.evidence.exit !== 0 || o.evidence.requests !== probes + 1;
  });
  if (broken) {
    console.log(`TOOL_ERROR: case ${broken.id} did not finish both probes: ${JSON.stringify(broken)}`);
    return 2;
  }

  const label: Record<RuleSet, string> = {
    fixed: "the rules with the change",
    old: "the rules of fx before the ZDOTDIR change",
    head: "the rules of fx before the capture-start rule",
    unbounded: "the rules of fx before the bound on the captures",
  };
  // Rules that must reject what this binary did: the fixed binary against the
  // older rule sets, an older binary against the fixed rules.
  const others: RuleSet[] = options.rules === "fixed" ? ["old", "head", "unbounded"] : ["fixed"];
  const design = await runTrace(observations, RULES[options.rules]!, out);
  console.log(`${label[options.rules]}: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, RULES[options.rules]!, out);
    console.log(`first case the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    for (const other of others) {
      const check = await runTrace(observations, RULES[other], out);
      console.log(`self-check, ${label[other]}: ${check.verdict} (must be REJECTED)`);
      if (check.verdict !== "REJECTED") return check.verdict === "TOOL_ERROR" ? 2 : 1;
    }
    if (options.rules === "fixed") {
      // The window and churn cases alone are what the rules before the
      // capture-start rule cannot produce: every case without an edit inside a
      // capture they accept.
      const plain = observations.filter((o) => !o.window && !o.churn);
      const check = await runTrace(plain, RULES.head, out);
      console.log(`self-check, ${label.head} on the ${plain.length} cases without a window edit: ${check.verdict} (must be ACCEPTED)`);
      if (check.verdict !== "ACCEPTED") return check.verdict === "TOOL_ERROR" ? 2 : 1;
      // The churn cases alone are what the rules before the bound cannot produce.
      const bounded = observations.filter((o) => !o.churn);
      const before = await runTrace(bounded, RULES.unbounded, out);
      console.log(`self-check, ${label.unbounded} on the ${bounded.length} cases without churn: ${before.verdict} (must be ACCEPTED)`);
      if (before.verdict !== "ACCEPTED") return before.verdict === "TOOL_ERROR" ? 2 : 1;
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
