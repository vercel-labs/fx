// Runs the built fx binary along tests/tla/shell_runtime/TerminalRevoke.tla and
// has TLC check every run it observes (TerminalRevokeTrace.tla).
//
// Each run starts fx on a pseudo-terminal the driver owns
// (tests/e2e/pty-session.ts), against a local fake gateway, waits for the
// composer, and then does one thing to fx's terminal while the terminal's
// other side stays open:
//
//   quit                  type /quit
//   hangup                close the other side
//   revoke-idle           revoke(2) the terminal while fx waits in its poll
//   revoke-stopped        stop fx, revoke, and continue it, so the revoke
//                         lands between two polls
//   revoke-after-typing   type text, wait for it on screen, then revoke as
//                         revoke-stopped does
//   revoke-during-burst   revoke after the first 64 KB of a 256 KB paste
//   revoke-after-quit     type /quit and revoke at once, racing the cleanup
//   revoke-idle-eio       revoke-idle, answered the way macos-15-arm64 answers
//                         a revoked controlling terminal: stdin-eio.c makes
//                         the revoked stdin poll as readable and fail reads
//                         with EIO, so only tcgetattr shows it is gone
//   revoke-stopped-eio    revoke-stopped, answered the same way
//   live-eio              stdin-eio.c fails reads with EIO on the terminal
//                         while it is still there, as for a background read
//                         that SIGTTIN does not stop, and the driver types a key
//
// One more run starts fx teams on the PTY and revokes the terminal while its
// team picker waits for a key, answered the macOS 15 way as revoke-idle-eio is:
//
//   team-picker-revoke-eio  the picker's read fails with EIO, fx teams returns
//                         its error, and the picker's restore meets a terminal
//                         that is gone: it must stay quiet (no unexpected errno)
//
// Two more runs start fx from an interactive bash in tmux and take it through
// Ctrl+Z, bg, fg, and /quit: job-control with SIGTTIN and SIGTTOU at their
// default, and job-control-signals-ignored with fx started with both ignored.
//
// A revoke that lands while fx waits in poll wakes that poll as a hang-up; one
// that lands between polls leaves every later poll reporting POLLNVAL alone,
// which fx before the change ignored and so spun. --random N adds N seeded
// runs of the revoke scenarios after a random delay. In the PTY runs fx has no
// controlling terminal, so no SIGHUP reaches it: what the terminal reports is
// all it sees. For each run the driver records what it did, how fx ended (status 0,
// status 1 with an fx error, crashed, still running and burning CPU, or
// something else), and what the cleanup left: the terminal's settings after a
// quit, or whether stderr reports an unexpected errno once the terminal is
// gone. TLC
// replays every run through the model's own actions. --self-check also replays
// them through the model of fx before the change (Bug = "today"), which must
// reject them, and the team picker run through the model of fx before the
// prompts' fix (Bug = "prompts_strict"), which must reject it too.
//
// revoke(2) exists only on macOS here, so the driver runs only there.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/shell_runtime/driver.ts
//   bun tests/tla/drivers/shell_runtime/driver.ts --self-check
//   bun tests/tla/drivers/shell_runtime/driver.ts --random 20 --seed 7
//   bun tests/tla/drivers/shell_runtime/driver.ts --scenario team-picker-revoke-eio
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, targetModule } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Event = "Type" | "Quit" | "Revoke" | "RevokeStopped" | "Hangup" | "Suspend" | "Bg" | "Fg" | "Background";
type End = "exited" | "failed" | "crashed" | "spinning" | "other";
type Restore = "restored" | "quiet" | "clean" | "error" | "lost" | "none";
type Site = "shell" | "team_picker";
type Scenario =
  | "quit"
  | "hangup"
  | "revoke-idle"
  | "revoke-stopped"
  | "revoke-after-typing"
  | "revoke-during-burst"
  | "revoke-after-quit"
  | "revoke-idle-eio"
  | "revoke-stopped-eio"
  | "live-eio"
  | "team-picker-revoke-eio"
  | "job-control"
  | "job-control-signals-ignored";
type Observation = {
  id: string;
  scenario: Scenario;
  delay_ms: number;
  events: Event[];
  end: End;
  restore: Restore;
  eio: boolean;
  stops: boolean;
  site: Site;
  evidence: {
    exit: { code: number | null; signal: string | null } | null;
    exited_after_ms: number | null;
    cpu_seconds_after: number | null;
    stderr: string;
    gateway: { models: number; chat: number };
    issuer: string[];
    interposer: string[];
    job_states: Array<string | null>;
    trace_errors: string[];
  };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const SCENARIOS: Scenario[] = [
  "quit",
  "hangup",
  "revoke-idle",
  "revoke-stopped",
  "revoke-after-typing",
  "revoke-during-burst",
  "revoke-after-quit",
  "revoke-idle-eio",
  "revoke-stopped-eio",
  "live-eio",
  "team-picker-revoke-eio",
  "job-control",
  "job-control-signals-ignored",
];
const RANDOM_SCENARIOS: Scenario[] = [
  "revoke-idle",
  "revoke-stopped",
  "revoke-after-typing",
  "revoke-during-burst",
  "revoke-idle-eio",
  "revoke-stopped-eio",
];
const EIO_MODE: Partial<Record<Scenario, "revoked" | "live">> = {
  "revoke-idle-eio": "revoked",
  "revoke-stopped-eio": "revoked",
  "live-eio": "live",
  "team-picker-revoke-eio": "revoked",
};
const tlaDir = join(TLA_ROOT, "shell_runtime");
// An fx error line on stderr: `fx: ...`, or `fx <command>: ...`.
const FX_ERROR = /^fx(?: [\w-]+)?: /m;
// How long fx has to exit after its terminal goes away, and how long a run that
// is still going is watched for CPU use before it counts as spinning.
const EXIT_WAIT_MS = 3_000;
const SPIN_WINDOW_MS = 1_000;
const SPIN_CPU_SECONDS = 0.5;

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function scenarioOption(): Scenario | null {
  const at = process.argv.indexOf("--scenario");
  if (at < 0) return null;
  const name = process.argv[at + 1] as Scenario;
  if (!SCENARIOS.includes(name)) throw new Error(`--scenario takes one of: ${SCENARIOS.join(", ")}`);
  return name;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  scenario: scenarioOption(),
  random: option("--random", 6),
  seed: option("--seed", 1),
};

// mulberry32: a small seeded generator, so a failing random run replays.
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

function sameFlags(a: Record<string, number>, b: Record<string, number>): boolean {
  return Object.keys(a).every((key) => a[key] === b[key]);
}

let stdinEio: string | null = null;
// stdin-eio.c, built once per run.
function stdinEioLibrary(out: string): string {
  if (stdinEio) return stdinEio;
  const library = join(out, "stdin-eio.dylib");
  const source = join(import.meta.dirname, "stdin-eio.c");
  const built = Bun.spawnSync(["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", source, "-o", library]);
  if (built.exitCode !== 0) throw new Error(`building stdin-eio.c failed: ${built.stderr.toString()}`);
  return (stdinEio = library);
}

function fxEnv(helpers: any, gateway: any, root: string): Record<string, string> {
  return {
    HOME: join(root, "home"),
    PATH: "/usr/bin:/bin",
    TERM: "xterm-256color",
    FX_HOME: join(root, "fx-home"),
    FX_DISABLE_KEYCHAIN: "1",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_INPUT_LOOP_NETWORK_GUARD: "1",
    AI_GATEWAY_API_KEY: "fake-terminal-revoke-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
  };
}

async function waitForModels(gateway: any, before: number): Promise<void> {
  const deadline = Date.now() + 15_000;
  while (gateway.modelRequests.length <= before) {
    if (Date.now() > deadline) throw new Error("fx never asked the fake gateway for its models");
    await Bun.sleep(10);
  }
}

function readLines(path: string): string[] {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean) : [];
}

async function runScenario(
  helpers: any,
  pty: any,
  gateway: any,
  id: string,
  scenario: Scenario,
  delayMs: number,
  scratch: string,
  out: string,
): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${id}-`));
  for (const dir of ["home", "fx-home", "workspace", "pty"]) mkdirSync(join(root, dir));
  const modelsBefore = gateway.modelRequests.length;
  const chatBefore = gateway.requests.length;
  const eioMode = EIO_MODE[scenario];
  const eioRecord = join(root, "stdin-eio.record");
  const eioArm = join(root, "stdin-eio.arm");
  const env = fxEnv(helpers, gateway, root);
  if (eioMode) {
    env.DYLD_INSERT_LIBRARIES = stdinEioLibrary(out);
    env.FX_STDIN_EIO_MODE = eioMode;
    env.FX_STDIN_EIO_RECORD = eioRecord;
    env.FX_STDIN_EIO_ARM = eioArm;
  }
  const session = await pty.PtySession.launch({
    bin: binary,
    cwd: join(root, "workspace"),
    dir: join(root, "pty"),
    env,
  });
  try {
    if (!(await session.waitForOutput((text: string) => text.includes("┃"), 15_000))) {
      throw new Error(`${id}: fx never drew its composer; stderr: ${session.stderr()}`);
    }
    if (eioMode) {
      // Act only once fx waits in its input loop.
      await waitForModels(gateway, modelsBefore);
      await session.waitForQuietOutput(300, 15_000);
    }
    if (delayMs > 0) await Bun.sleep(delayMs);
    const events: Event[] = [];
    let gone = false;
    switch (scenario) {
      case "quit":
        session.write("/quit\r");
        events.push("Quit");
        break;
      case "hangup":
        session.hangUp();
        events.push("Hangup");
        gone = true;
        break;
      case "revoke-idle":
      case "revoke-idle-eio":
        session.revoke();
        events.push("Revoke");
        gone = true;
        break;
      case "revoke-stopped":
      case "revoke-stopped-eio":
        await session.revokeBetweenPolls();
        events.push("RevokeStopped");
        gone = true;
        break;
      case "live-eio":
        writeFileSync(eioArm, "");
        events.push("Background");
        session.write("x");
        events.push("Type");
        break;
      case "revoke-after-typing":
        session.write("hello terminal");
        if (!(await session.waitForOutput((text: string) => text.includes("hello terminal"), 5_000))) {
          throw new Error(`${id}: typed text never reached the screen`);
        }
        events.push("Type");
        await session.revokeBetweenPolls();
        events.push("RevokeStopped");
        gone = true;
        break;
      case "revoke-during-burst": {
        const chunk = "x".repeat(4096);
        for (let sent = 0; sent < 256 * 1024; sent += chunk.length) {
          if (sent === 64 * 1024) {
            session.revoke();
            events.push("Type", "Revoke");
            gone = true;
          }
          try {
            session.write(chunk);
          } catch {
            break;
          }
        }
        break;
      }
      case "revoke-after-quit":
        session.write("/quit\r");
        events.push("Quit");
        if (!session.exited()) {
          session.revoke();
          events.push("Revoke");
          gone = true;
        }
        break;
    }
    const started = performance.now();
    const exit = await session.waitForExit(EXIT_WAIT_MS);
    const exitedAfter = exit ? Math.round(performance.now() - started) : null;
    let end: End;
    let restore: Restore = "none";
    let cpuAfter: number | null = null;
    const stderr = () => session.stderr();
    if (exit) {
      if (exit.code === 0) end = "exited";
      else if (exit.signal === "SIGABRT" || /panic/.test(stderr())) end = "crashed";
      else if (exit.code === 1 && /^fx: /m.test(stderr())) end = "failed";
      else end = "other";
      if (end === "exited" || end === "failed") {
        if (/unexpected errno/.test(stderr())) restore = "error";
        else if (gone) restore = "quiet";
        else restore = sameFlags(session.flagsBefore, session.flagsNow()) ? "restored" : "lost";
      }
    } else {
      const before = session.cpuSeconds();
      await Bun.sleep(SPIN_WINDOW_MS);
      cpuAfter = session.cpuSeconds();
      const burned = before !== null && cpuAfter !== null ? cpuAfter - before : 0;
      end = burned >= SPIN_CPU_SECONDS ? "spinning" : "other";
    }
    const interposer = readLines(eioRecord);
    if (eioMode && !interposer.some((line) => line.startsWith("read-eio"))) {
      throw new Error(`${id}: stdin-eio.c never failed a read, so the run did not reach the EIO path`);
    }
    return {
      id,
      scenario,
      delay_ms: delayMs,
      events,
      end,
      restore,
      eio: eioMode === "revoked",
      stops: eioMode !== "live",
      site: "shell",
      evidence: {
        exit,
        exited_after_ms: exitedAfter,
        cpu_seconds_after: cpuAfter,
        stderr: stderr().slice(0, 2_000),
        gateway: {
          models: gateway.modelRequests.length - modelsBefore,
          chat: gateway.requests.length - chatBefore,
        },
        issuer: [],
        interposer: [...new Set(interposer)],
        job_states: [],
        trace_errors: [],
      },
    };
  } finally {
    await session.dispose();
    rmSync(root, { recursive: true, force: true });
  }
}

// fx teams on the PTY, revoked while its team picker waits for a key. A local
// fake issuer answers the one request for the account's two teams. stdin-eio.c
// makes the revoked stdin fail reads with EIO, as macos-15-arm64 answers; this
// machine answers a read of 0 instead. The picker's read fails, it returns its
// error, and the restore on its way out meets a terminal that is gone.
async function runTeamPicker(
  helpers: any,
  pty: any,
  gateway: any,
  id: string,
  scratch: string,
  out: string,
): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${id}-`));
  for (const dir of ["home", "fx-home", "workspace", "pty"]) mkdirSync(join(root, dir));
  const modelsBefore = gateway.modelRequests.length;
  const chatBefore = gateway.requests.length;
  const issuerRequests: string[] = [];
  const issuer = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      issuerRequests.push(`${request.method} ${url.pathname}`);
      if (url.pathname !== "/v2/teams") return new Response("not found", { status: 404 });
      return Response.json({
        teams: [
          { id: "team_1", slug: "example-one", name: "Example One" },
          { id: "team_2", slug: "example-two", name: "Example Two" },
        ],
      });
    },
  });
  const issuerUrl = `http://127.0.0.1:${issuer.port}`;
  writeFileSync(
    join(root, "fx-home", "auth.json"),
    JSON.stringify({
      version: 1,
      issuer: issuerUrl,
      client_id: "test-client",
      access_token: "fake-access-token",
      refresh_token: "fake-refresh-token",
      expires_at_ms: Date.now() + 3_600_000,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
      team_id: "team_1",
      team_slug: "example-one",
    }) + "\n",
    { mode: 0o600 },
  );
  const eioRecord = join(root, "stdin-eio.record");
  const session = await pty.PtySession.launch({
    bin: binary,
    args: ["teams"],
    cwd: join(root, "workspace"),
    dir: join(root, "pty"),
    env: {
      ...fxEnv(helpers, gateway, root),
      FX_TEST_OAUTH_ISSUER_URL: issuerUrl,
      DYLD_INSERT_LIBRARIES: stdinEioLibrary(out),
      FX_STDIN_EIO_MODE: "revoked",
      FX_STDIN_EIO_RECORD: eioRecord,
    },
  });
  try {
    if (!(await session.waitForOutput((text: string) => text.includes("Example Two"), 15_000))) {
      throw new Error(`${id}: fx teams never drew its team picker; stderr: ${session.stderr()}`);
    }
    // The picker is waiting for a key.
    await session.waitForQuietOutput(300, 15_000);
    session.revoke();
    const started = performance.now();
    const exit = await session.waitForExit(EXIT_WAIT_MS);
    const exitedAfter = exit ? Math.round(performance.now() - started) : null;
    const stderr = session.stderr();
    let end: End;
    let restore: Restore = "none";
    let cpuAfter: number | null = null;
    if (exit) {
      if (exit.code === 0) end = "exited";
      else if (exit.signal === "SIGABRT" || /panic/.test(stderr)) end = "crashed";
      else if (exit.code === 1 && FX_ERROR.test(stderr)) end = "failed";
      else end = "other";
      if (end === "exited" || end === "failed") restore = /unexpected errno/.test(stderr) ? "error" : "quiet";
    } else {
      const before = session.cpuSeconds();
      await Bun.sleep(SPIN_WINDOW_MS);
      cpuAfter = session.cpuSeconds();
      const burned = before !== null && cpuAfter !== null ? cpuAfter - before : 0;
      end = burned >= SPIN_CPU_SECONDS ? "spinning" : "other";
    }
    const interposer = readLines(eioRecord);
    if (!interposer.some((line) => line.startsWith("read-eio"))) {
      throw new Error(`${id}: stdin-eio.c never failed a read, so the run did not reach the EIO path`);
    }
    return {
      id,
      scenario: "team-picker-revoke-eio",
      delay_ms: 0,
      events: ["Revoke"],
      end,
      restore,
      eio: true,
      stops: true,
      site: "team_picker",
      evidence: {
        exit,
        exited_after_ms: exitedAfter,
        cpu_seconds_after: cpuAfter,
        stderr: stderr.slice(0, 2_000),
        gateway: {
          models: gateway.modelRequests.length - modelsBefore,
          chat: gateway.requests.length - chatBefore,
        },
        issuer: issuerRequests,
        interposer: [...new Set(interposer)],
        job_states: [],
        trace_errors: [],
      },
    };
  } finally {
    await session.dispose();
    issuer.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

// fx from an interactive bash in tmux, through Ctrl+Z, bg, fg, and /quit.
async function runJobControl(
  helpers: any,
  jobs: any,
  gateway: any,
  id: string,
  scenario: Scenario,
  scratch: string,
): Promise<Observation> {
  const ignore = scenario === "job-control-signals-ignored";
  const root = mkdtempSync(join(scratch, `${id}-`));
  for (const dir of ["home", "fx-home", "workspace"]) mkdirSync(join(root, dir));
  const stderrPath = join(root, "stderr.log");
  const modelsBefore = gateway.modelRequests.length;
  const chatBefore = gateway.requests.length;
  const session = await helpers.TmuxSession.create({
    cmd: jobs.JOB_SHELL,
    cwd: join(root, "workspace"),
    isolated: true,
    width: 100,
    height: 30,
    env: {
      ...fxEnv(helpers, gateway, root),
      ...jobs.JOB_SHELL_ENV,
      FX_TRACE_LOG: join(root, "trace.log"),
      VERCEL_OIDC_TOKEN: undefined,
    },
  });
  try {
    const events: Event[] = [];
    const states: Array<string | null> = [];
    const traceErrors = () =>
      readLines(join(root, "trace.log"))
        .filter((line) => /error|InputOutput|read_failed/.test(line) && !/tmux_clear/.test(line))
        .map((line) => line.replace(/^\d+ /, ""))
        .slice(-4);
    const observation = (end: End, code: number | null, stderr: string): Observation => ({
      id,
      scenario,
      delay_ms: 0,
      events,
      end,
      restore: /unexpected errno/.test(stderr) ? "error" : "clean",
      eio: false,
      stops: !ignore,
      site: "shell",
      evidence: {
        exit: code === null ? null : { code, signal: null },
        exited_after_ms: null,
        cpu_seconds_after: null,
        stderr: stderr.slice(0, 2_000),
        gateway: {
          models: gateway.modelRequests.length - modelsBefore,
          chat: gateway.requests.length - chatBefore,
        },
        issuer: [],
        interposer: [],
        job_states: states,
        trace_errors: traceErrors(),
      },
    });
    await session.waitForText(/^\$/m, 15_000);
    await session.sendText(jobs.launchLine(binary, stderrPath, ignore));
    await session.waitForComposer(15_000);
    await waitForModels(gateway, modelsBefore);
    await session.waitForStableComposer(15_000, 500);

    await session.sendKeys("C-z");
    events.push("Suspend");
    await session.waitForText("Stopped", 15_000);
    states.push(await jobs.waitForFxState(session, binary, jobs.stopped, 15_000));

    // With the default signals fx stops again at its resume's tcsetattr; with
    // them ignored it runs on in the background, where its repaint clears the
    // shell's lines.
    await session.sendText("bg");
    events.push("Bg");
    if (!ignore) await session.waitForText(/ &$/m, 15_000);
    // A run where fx is gone in the background is an observation too.
    const background = ignore ? (state: string | null) => !jobs.stopped(state) : jobs.stopped;
    const afterBg = await jobs.waitForFxState(session, binary, background, 15_000, 500);
    states.push(afterBg);
    if (afterBg === null) {
      const stderr = readFileSync(stderrPath, "utf8");
      return observation(/^fx: /m.test(stderr) ? "failed" : "other", null, stderr);
    }

    await session.sendText("fg; echo fx-exit=$?");
    if (ignore) {
      // fx in the background reads this line too. That read fails with EIO
      // on a terminal that is still there, which ends fx with an error, as
      // before the change, unless the shell's fg wins the race.
      events.push("Type");
      const next = await jobs.waitForFxState(session, binary, (state: string | null) => state === null || jobs.inForeground(state), 15_000);
      if (next === null) {
        states.push(null);
        const stderr = readFileSync(stderrPath, "utf8");
        return observation(/^fx: /m.test(stderr) ? "failed" : "other", null, stderr);
      }
    }
    events.push("Fg");
    states.push(await jobs.waitForFxState(session, binary, jobs.inForeground, 15_000));
    if (!ignore) await session.waitForStableComposer(15_000, 500);
    await session.sendText("/quit");
    events.push("Quit");
    const pane = await session.waitForText(/fx-exit=\d+/, 15_000);
    const code = Number(pane.match(/fx-exit=(\d+)/)![1]);
    const stderr = readFileSync(stderrPath, "utf8");
    return observation(code === 0 ? "exited" : code === 1 && /^fx: /m.test(stderr) ? "failed" : "other", code, stderr);
  } finally {
    await session.kill();
    rmSync(root, { recursive: true, force: true });
  }
}

function tlaString(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function observedModule(observations: Observation[]): string {
  const records = observations.map((o) =>
    `    [events |-> <<${o.events.map(tlaString).join(", ")}>>, end |-> ${tlaString(o.end)}, ` +
      `restore |-> ${tlaString(o.restore)}, eio |-> ${o.eio ? "TRUE" : "FALSE"}, stops |-> ${o.stops ? "TRUE" : "FALSE"}, ` +
      `site |-> ${tlaString(o.site)}]`
  );
  return [
    "---------------------- MODULE TerminalRevokeObserved ----------------------",
    "EXTENDS Sequences",
    "Observed == <<",
    records.join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

async function check(dir: string, observations: Observation[], bug: string): Promise<{ verdict: Verdict; states: number | null }> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "TerminalRevokeObserved.tla"), observedModule(observations));
  writeFileSync(
    join(dir, "trace.cfg"),
    [
      "CONSTANTS",
      "    MaxSpins = 2",
      "    MaxIntr = 2",
      `    Bug = "${bug}"`,
      "INIT TraceInit",
      "NEXT TraceNext",
      "INVARIANT NotAllMatched",
      "CHECK_DEADLOCK FALSE",
      "",
    ].join("\n"),
  );
  const run = await runTlc(dir, "TerminalRevokeTrace", "trace.cfg", ["TerminalRevoke.tla", "TerminalRevokeTrace.tla"], tlaDir);
  const verdict: Verdict = run.violated === "NotAllMatched"
    ? "ACCEPTED"
    : run.exitCode === 0
    ? "REJECTED"
    : "TOOL_ERROR";
  return { verdict, states: run.distinctStates };
}

async function main(): Promise<number> {
  if (process.platform !== "darwin") {
    console.error("this driver needs revoke(2), which only macOS has here");
    return 2;
  }
  const helpers = await targetHelpers();
  const pty = await targetModule("pty-session.ts");
  const jobs = await targetModule("job-control.ts");
  const out = outDir("shell-runtime");
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-terminal-revoke-")));
  const gateway = helpers.startFakeGateway([]);
  const runs: Array<{ scenario: Scenario; delay: number }> = (options.scenario ? [options.scenario] : SCENARIOS).map(
    (scenario) => ({ scenario, delay: 0 }),
  );
  const next = generator(options.seed);
  for (let i = 0; i < (options.scenario ? 0 : options.random); i++) {
    runs.push({
      scenario: RANDOM_SCENARIOS[Math.floor(next() * RANDOM_SCENARIOS.length)]!,
      delay: Math.floor(next() * 800),
    });
  }
  const observations: Observation[] = [];
  try {
    for (const [index, run] of runs.entries()) {
      const id = `run${index + 1}`;
      const observation = run.scenario.startsWith("job-control")
        ? await runJobControl(helpers, jobs, gateway, id, run.scenario, scratch)
        : run.scenario === "team-picker-revoke-eio"
        ? await runTeamPicker(helpers, pty, gateway, id, scratch, out)
        : await runScenario(helpers, pty, gateway, id, run.scenario, run.delay, scratch, out);
      observations.push(observation);
      const { gateway: counted, issuer, exited_after_ms, cpu_seconds_after, interposer, job_states, trace_errors } = observation.evidence;
      console.log(
        `${observation.id} ${observation.scenario} delay=${observation.delay_ms}ms events=${observation.events.join(",")} ` +
          `end=${observation.end} restore=${observation.restore} exited_after_ms=${exited_after_ms} ` +
          `cpu_after=${cpu_seconds_after} gateway_models=${counted.models} gateway_chat=${counted.chat}` +
          (issuer.length ? ` issuer=${issuer.join(",")}` : "") +
          (interposer.length ? ` stdin_eio=${interposer.join(",")}` : "") +
          (job_states.length ? ` fx_states=${job_states.join(",")}` : "") +
          (trace_errors.length ? ` trace=${JSON.stringify(trace_errors.join(" | ").slice(0, 200))}` : "") +
          (observation.end !== "exited" ? ` stderr=${JSON.stringify(observation.evidence.stderr.slice(0, 120))}` : ""),
      );
      // A shell run asks the fake gateway for its models once; fx teams never does.
      const expectedModels = observation.site === "shell" ? 1 : 0;
      if (counted.models !== expectedModels || counted.chat !== 0) {
        console.error(`${observation.id}: expected the fake gateway to count ${expectedModels} models request and no chat request`);
        return 2;
      }
      if (observation.site === "team_picker" && issuer.join(",") !== "GET /v2/teams") {
        console.error(`${observation.id}: expected the fake issuer to count one teams request, saw ${issuer.join(",") || "none"}`);
        return 2;
      }
    }
  } finally {
    gateway.stop();
    rmSync(scratch, { recursive: true, force: true });
  }
  writeJson(join(out, "observations.json"), observations);

  const design = await check(join(out, "design"), observations, "none");
  console.log(`TLC TerminalRevokeTrace Bug=none: ${design.verdict} (${design.states} distinct states)`);
  let status = design.verdict === "ACCEPTED" ? 0 : design.verdict === "REJECTED" ? 1 : 2;
  if (options.selfCheck) {
    const today = await check(join(out, "today"), observations, "today");
    console.log(`TLC TerminalRevokeTrace Bug=today: ${today.verdict} (must be REJECTED)`);
    if (today.verdict === "TOOL_ERROR") status = 2;
    else if (today.verdict !== "REJECTED" && status === 0) status = 1;
    // The team picker run alone, through fx before the prompts' fix: its
    // restore reported an unexpected errno, so a quiet restore must not fit.
    const prompts = observations.filter((o) => o.site !== "shell");
    if (prompts.length > 0) {
      const strict = await check(join(out, "prompts-strict"), prompts, "prompts_strict");
      console.log(`TLC TerminalRevokeTrace Bug=prompts_strict (prompt runs only): ${strict.verdict} (must be REJECTED)`);
      if (strict.verdict === "TOOL_ERROR") status = 2;
      else if (strict.verdict !== "REJECTED" && status === 0) status = 1;
    }
  }
  console.log(`output: ${out}`);
  return status;
}

try {
  process.exitCode = await main();
} catch (error) {
  console.error(error);
  process.exitCode = 2;
}
