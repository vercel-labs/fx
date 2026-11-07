// Runs the real benchmarks/startup.sh in a private TMPDIR and records what it
// leaves there. driver.ts has TLC check these runs against
// tests/tla/benchmarks/StartupFixture.tla, and
// benchmarks/startup_fixture.test.ts asserts on them directly.
//
// Each run copies the script, and the Python helpers it calls, into a scratch
// repository root, so it never writes the checkout's benchmarks/results/, and
// links zig-out/bin/fx there to the built binary when the run needs one. It
// starts the script through `env -i` with every variable written out: HOME,
// PATH (a folder of links to the tools the script calls), TMPDIR, a temporary
// FX_HOME, FX_DISABLE_KEYCHAIN=1, FX_SOUND=0, and the URLs and key of a local
// fake gateway that counts every request. No benchmarked command calls a
// model, so every run expects 0.
//
// A prelude in the same process can plant a folder at the old path,
// fx-session-list-benchmark-$$, with a marker file, and make TMPDIR read-only,
// before it execs the script. exec keeps the PID, so the planted folder has
// the name the script before the change used.
//
// hyperfine on that PATH is a spy: on its first call it records HOME and
// TMPDIR's listing, then runs the real hyperfine, or stops the script with
// SIGTERM or SIGKILL.
//
//   FX_BIN             the fx binary to link (default: zig-out/bin/fx)
//   FX_STARTUP_SCRIPT  the script to run (default: benchmarks/startup.sh)
//   FX_STARTUP_MUTANT  plant one of MUTANTS in the copy of the script
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc";

export const PREFIX = "fx-session-list-benchmark";
export const MARKER = "unrelated-marker";
const HELPERS = ["session_list_fixture.py", "summarize.py", "check_budgets.py"];
// Every program the script runs by name, apart from hyperfine.
const TOOLS = ["bash", "chmod", "dirname", "mkdir", "mktemp", "python3", "rm"];

// Planted bugs, each a text change to the script after the fix. A test or the
// driver must reject a run of each.
export const MUTANTS: Record<string, { from: string; to: string }> = {
  // The script before the change: the folder named from the PID.
  "pid-path": {
    from: 'SESSION_FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fx-session-list-benchmark.XXXXXX")"',
    to: 'SESSION_FIXTURE_ROOT="${TMPDIR:-/tmp}/fx-session-list-benchmark-$$"',
  },
  // Cleanup removes every folder with the fixture prefix.
  "glob-cleanup": {
    from: 'rm -rf "$SESSION_FIXTURE_ROOT"',
    to: 'rm -rf "${TMPDIR:-/tmp}"/fx-session-list-benchmark*',
  },
  // No EXIT trap, so nothing is removed.
  "no-trap": { from: "trap cleanup EXIT\n", to: "" },
};

export type Hyperfine = "real" | "missing" | "sigterm" | "sigkill";

export type RunOptions = {
  scratch: string; // a private folder for this run's repository copy, PATH, and logs
  tmpdir: string; // the TMPDIR the script gets; it may be missing or a file
  plantPid?: boolean; // plant a folder at the old path before the script starts
  readOnly?: boolean; // make TMPDIR read-only after planting
  binary?: boolean; // link zig-out/bin/fx to the built binary
  hyperfine?: Hyperfine;
  mutant?: string; // one of MUTANTS; FX_STARTUP_MUTANT when left out
  timeoutMs?: number;
};

export type RunResult = {
  pid: number;
  code: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
  pidName: string; // fx-session-list-benchmark-<pid>
  planted: string[]; // fixture names in TMPDIR before the script ran, the planted PID folder included
  during: { home: string; names: string[] } | null; // at hyperfine's first call
  after: string[]; // fixture names in TMPDIR after the run
  intact: Record<string, boolean>; // each planted name: still there with the same entries
  gatewayRequests: number;
  readOnlyHeld: boolean; // readOnly was asked for and TMPDIR refused a new folder
};

const PRELUDE = [
  "set -e",
  'if [ -n "$1" ]; then',
  '  mkdir "$TMPDIR/fx-session-list-benchmark-$$"',
  "  printf 'keep\\n' > \"$TMPDIR/fx-session-list-benchmark-$$/unrelated-marker\"",
  "fi",
  'if [ -n "$2" ]; then chmod a-w "$TMPDIR"; fi',
  "printf '%s\\n' \"$$\" > \"$3\"",
  "shift 3",
  'exec bash "$@"',
].join("\n");

export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function fxBinary(): string {
  return process.env.FX_BIN ?? join(REPO_ROOT, "zig-out", "bin", "fx");
}

export function realHyperfine(): string | null {
  return Bun.which("hyperfine");
}

/// The script under test: FX_STARTUP_SCRIPT or the checkout's, with
/// FX_STARTUP_MUTANT or `mutant` planted in it.
export function scriptText(mutant = process.env.FX_STARTUP_MUTANT ?? ""): string {
  const text = readFileSync(process.env.FX_STARTUP_SCRIPT ?? join(REPO_ROOT, "benchmarks", "startup.sh"), "utf8");
  if (!mutant) return text;
  const planted = MUTANTS[mutant];
  if (!planted) throw new Error(`no mutant ${mutant}; known: ${Object.keys(MUTANTS).join(", ")}`);
  if (!text.includes(planted.from)) throw new Error(`mutant ${mutant} no longer applies to the script`);
  return text.replace(planted.from, planted.to);
}

/// Plants a folder of someone else's in TMPDIR, with a marker file in it.
export function plant(tmpdir: string, name: string) {
  mkdirSync(join(tmpdir, name));
  writeFileSync(join(tmpdir, name, MARKER), "keep\n");
}

export function fixtureNames(dir: string): string[] {
  try {
    return readdirSync(dir).filter((name) => name.startsWith(PREFIX)).sort();
  } catch {
    return [];
  }
}

function entries(dir: string): string | null {
  try {
    return JSON.stringify(readdirSync(dir).sort());
  } catch {
    return null;
  }
}

function isDir(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function startGateway() {
  let requests = 0;
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch() {
      requests++;
      return new Response("this fake gateway expects no requests", { status: 503 });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, requests: () => requests, stop: () => server.stop(true) };
}

function tool(name: string): string {
  const path = Bun.which(name);
  if (!path) throw new Error(`${name} is not on PATH`);
  return path;
}

export async function runStartup(options: RunOptions): Promise<RunResult> {
  const hyperfine = options.hyperfine ?? "real";
  const repo = join(options.scratch, "repo");
  const bin = join(options.scratch, "bin");
  const spy = join(options.scratch, "spy");
  const home = join(options.scratch, "home");
  const fxHome = join(options.scratch, "fx-home");
  const receipt = join(options.scratch, "pid");
  for (const dir of [join(repo, "benchmarks"), bin, spy, home]) mkdirSync(dir, { recursive: true });
  writeFileSync(join(repo, "benchmarks", "startup.sh"), scriptText(options.mutant));
  for (const name of HELPERS) copyFileSync(join(REPO_ROOT, "benchmarks", name), join(repo, "benchmarks", name));
  if (options.binary) {
    const binary = fxBinary();
    if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
    mkdirSync(join(repo, "zig-out", "bin"), { recursive: true });
    symlinkSync(binary, join(repo, "zig-out", "bin", "fx"));
  }
  for (const name of TOOLS) symlinkSync(tool(name), join(bin, name));
  if (hyperfine !== "missing") {
    const real = hyperfine === "real" ? realHyperfine() : null;
    if (hyperfine === "real" && !real) throw new Error("hyperfine is not on PATH");
    const stop = hyperfine === "sigterm" ? "TERM" : hyperfine === "sigkill" ? "KILL" : "";
    writeFileSync(join(bin, "hyperfine"), [
      "#!/bin/sh",
      `if [ ! -e ${shellQuote(join(spy, "seen"))} ]; then`,
      `  { printf 'HOME=%s\\n' "$HOME"; ${shellQuote(tool("ls"))} -A "$TMPDIR"; } > ${shellQuote(join(spy, "seen.part"))}`,
      `  ${shellQuote(tool("mv"))} ${shellQuote(join(spy, "seen.part"))} ${shellQuote(join(spy, "seen"))}`,
      stop ? `  kill -${stop} "$PPID"; exit 0` : "  :",
      "fi",
      real ? `exec ${shellQuote(real)} "$@"` : "exit 1",
      "",
    ].join("\n"));
    chmodSync(join(bin, "hyperfine"), 0o755);
  }

  const before = fixtureNames(options.tmpdir);
  const snapshot = new Map(before.map((name) => [name, entries(join(options.tmpdir, name))]));
  const gateway = startGateway();
  try {
    // From the repository root, as CI runs it: check_budgets.py reads
    // benchmarks/results/ from the folder it starts in.
    const child = Bun.spawn([
      tool("env"), "-i",
      `HOME=${home}`,
      `PATH=${bin}`,
      `TMPDIR=${options.tmpdir}`,
      `FX_HOME=${fxHome}`,
      "FX_DISABLE_KEYCHAIN=1",
      "FX_SOUND=0",
      "FX_AUTO_UPGRADE=0",
      "FX_E2E_DISABLE_DOTENV=1",
      "AI_GATEWAY_API_KEY=fake-startup-fixture-key",
      `FX_GATEWAY_BASE_URL=${gateway.url}`,
      `FX_GATEWAY_CHAT_URL=${gateway.url}/v4/ai/language-model`,
      `FX_TEST_GATEWAY_CHAT_URL=${gateway.url}/v4/ai/language-model`,
      `FX_TEST_GATEWAY_MODELS_URL=${gateway.url}/coding-agent/v1/models`,
      join(bin, "bash"), "-c", PRELUDE, "startup-prelude",
      options.plantPid ? "1" : "", options.readOnly ? "1" : "", receipt,
      join(repo, "benchmarks", "startup.sh"), "--ci",
    ], { cwd: repo, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill(9);
    }, options.timeoutMs ?? 300_000);
    const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    await child.exited;
    clearTimeout(timer);
    if (timedOut) throw new Error(`benchmarks/startup.sh did not end in ${options.timeoutMs ?? 300_000} ms: ${stdout.slice(-400)}`);

    const pidName = `${PREFIX}-${child.pid}`;
    const planted = [...before];
    if (options.plantPid) {
      const recorded = existsSync(receipt) ? readFileSync(receipt, "utf8").trim() : "";
      if (recorded !== String(child.pid)) {
        throw new Error(`the prelude did not plant ${pidName} (receipt ${JSON.stringify(recorded)}): ${stderr.slice(-400)}`);
      }
      planted.push(pidName);
      snapshot.set(pidName, JSON.stringify([MARKER]));
    }
    let readOnlyHeld = false;
    if (options.readOnly && isDir(options.tmpdir)) {
      try {
        mkdirSync(join(options.tmpdir, ".probe"));
        rmSync(join(options.tmpdir, ".probe"), { recursive: true, force: true });
      } catch {
        readOnlyHeld = true;
      }
    }
    const after = fixtureNames(options.tmpdir);
    const intact: Record<string, boolean> = {};
    for (const name of planted) intact[name] = entries(join(options.tmpdir, name)) === snapshot.get(name);
    if (options.readOnly && isDir(options.tmpdir)) chmodSync(options.tmpdir, 0o755);

    let during: RunResult["during"] = null;
    if (existsSync(join(spy, "seen"))) {
      const lines = readFileSync(join(spy, "seen"), "utf8").split("\n");
      const homeLine = lines.find((line) => line.startsWith("HOME=")) ?? "HOME=";
      during = {
        home: homeLine.slice("HOME=".length),
        names: lines.filter((line) => line.startsWith(PREFIX)).sort(),
      };
    }
    return {
      pid: child.pid,
      code: child.exitCode,
      signal: child.signalCode ?? null,
      stdout,
      stderr,
      pidName,
      planted,
      during,
      after,
      intact,
      gatewayRequests: gateway.requests(),
      readOnlyHeld,
    };
  } finally {
    gateway.stop();
  }
}

/// The name of the folder directly under `tmpdir` that holds `home`, or null.
/// The script joins TMPDIR and the name with a slash, so a TMPDIR that ends
/// in one gives two.
export function folderOf(tmpdir: string, home: string): string | null {
  if (!home.startsWith(tmpdir)) return null;
  const rest = home.slice(tmpdir.length);
  if (!tmpdir.endsWith("/") && !rest.startsWith("/")) return null;
  return rest.replace(/^\/+/, "").split("/")[0] || null;
}
