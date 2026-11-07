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
//
// A revoke that lands while fx waits in poll wakes that poll as a hang-up; one
// that lands between polls leaves every later poll reporting POLLNVAL alone,
// which fx before the change ignored and so spun. --random N adds N seeded
// runs of the revoke scenarios after a random delay. fx has no controlling
// terminal here, so no SIGHUP reaches it: what the terminal reports is all it
// sees. For each run the driver records what it did, how fx ended (status 0,
// status 1 with an fx error, crashed, still running and burning CPU, or
// something else), and what the cleanup left: the terminal's settings after a
// quit, or whether stderr reports an unexpected errno once the terminal is
// gone. TLC
// replays every run through the model's own actions. --self-check also replays
// them through the model of fx before the change (Bug = "today"), which must
// reject them.
//
// revoke(2) exists only on macOS here, so the driver runs only there.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/shell_runtime/driver.ts
//   bun tests/tla/drivers/shell_runtime/driver.ts --self-check
//   bun tests/tla/drivers/shell_runtime/driver.ts --random 20 --seed 7
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, targetModule } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Event = "Type" | "Quit" | "Revoke" | "RevokeStopped" | "Hangup";
type End = "exited" | "failed" | "crashed" | "spinning" | "other";
type Restore = "restored" | "quiet" | "error" | "lost" | "none";
type Scenario =
  | "quit"
  | "hangup"
  | "revoke-idle"
  | "revoke-stopped"
  | "revoke-after-typing"
  | "revoke-during-burst"
  | "revoke-after-quit";
type Observation = {
  id: string;
  scenario: Scenario;
  delay_ms: number;
  events: Event[];
  end: End;
  restore: Restore;
  evidence: {
    exit: { code: number | null; signal: string | null } | null;
    exited_after_ms: number | null;
    cpu_seconds_after: number | null;
    stderr: string;
    gateway: { models: number; chat: number };
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
];
const RANDOM_SCENARIOS: Scenario[] = ["revoke-idle", "revoke-stopped", "revoke-after-typing", "revoke-during-burst"];
const tlaDir = join(TLA_ROOT, "shell_runtime");
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

const options = {
  selfCheck: process.argv.includes("--self-check"),
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

async function runScenario(
  helpers: any,
  pty: any,
  gateway: any,
  id: string,
  scenario: Scenario,
  delayMs: number,
  scratch: string,
): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${id}-`));
  for (const dir of ["home", "fx-home", "workspace", "pty"]) mkdirSync(join(root, dir));
  const modelsBefore = gateway.modelRequests.length;
  const chatBefore = gateway.requests.length;
  const session = await pty.PtySession.launch({
    bin: binary,
    cwd: join(root, "workspace"),
    dir: join(root, "pty"),
    env: {
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
    },
  });
  try {
    if (!(await session.waitForOutput((text: string) => text.includes("┃"), 15_000))) {
      throw new Error(`${id}: fx never drew its composer; stderr: ${session.stderr()}`);
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
        session.revoke();
        events.push("Revoke");
        gone = true;
        break;
      case "revoke-stopped":
        await session.revokeBetweenPolls();
        events.push("RevokeStopped");
        gone = true;
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
    return {
      id,
      scenario,
      delay_ms: delayMs,
      events,
      end,
      restore,
      evidence: {
        exit,
        exited_after_ms: exitedAfter,
        cpu_seconds_after: cpuAfter,
        stderr: stderr().slice(0, 2_000),
        gateway: {
          models: gateway.modelRequests.length - modelsBefore,
          chat: gateway.requests.length - chatBefore,
        },
      },
    };
  } finally {
    await session.dispose();
    rmSync(root, { recursive: true, force: true });
  }
}

function tlaString(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function observedModule(observations: Observation[]): string {
  const records = observations.map((o) =>
    `    [events |-> <<${o.events.map(tlaString).join(", ")}>>, end |-> ${tlaString(o.end)}, restore |-> ${tlaString(o.restore)}]`
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
  const out = outDir("shell-runtime");
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-terminal-revoke-")));
  const gateway = helpers.startFakeGateway([]);
  const runs: Array<{ scenario: Scenario; delay: number }> = SCENARIOS.map((scenario) => ({ scenario, delay: 0 }));
  const next = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    runs.push({
      scenario: RANDOM_SCENARIOS[Math.floor(next() * RANDOM_SCENARIOS.length)]!,
      delay: Math.floor(next() * 800),
    });
  }
  const observations: Observation[] = [];
  try {
    for (const [index, run] of runs.entries()) {
      const observation = await runScenario(helpers, pty, gateway, `run${index + 1}`, run.scenario, run.delay, scratch);
      observations.push(observation);
      const { gateway: counted, exited_after_ms, cpu_seconds_after } = observation.evidence;
      console.log(
        `${observation.id} ${observation.scenario} delay=${observation.delay_ms}ms events=${observation.events.join(",")} ` +
          `end=${observation.end} restore=${observation.restore} exited_after_ms=${exited_after_ms} ` +
          `cpu_after=${cpu_seconds_after} gateway_models=${counted.models} gateway_chat=${counted.chat}`,
      );
      if (counted.models !== 1 || counted.chat !== 0) {
        console.error(`${observation.id}: expected the fake gateway to count 1 models request and no chat request`);
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
