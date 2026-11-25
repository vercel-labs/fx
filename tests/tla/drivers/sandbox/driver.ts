// Runs the built fx along tests/tla/sandbox/SandboxProvider.tla, code to spec:
// each scenario is one `fx ask` whose scripted model makes one shell call that
// a rule in the private sandbox config places locally, with a third-party
// provider (spec L2), or isolated. The provider is provider-fixture.sh in this
// folder: a small shell program that records each step in a JSON log and ends
// with the spec's notes. The driver adds its own steps to that log (a stop or a
// crash), reads what fx told the model, and has TLC check that the model has a
// behavior that gives the whole run (SandboxProviderTrace.tla).
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/sandbox/driver.ts
//   bun tests/tla/drivers/sandbox/driver.ts --self-check
//   bun tests/tla/drivers/sandbox/driver.ts --only workspace-stop
//
// --self-check also changes one fact of every accepted run so that no
// behavior of the model gives it, and requires TLC to reject it.
//
// Exit codes: 0 every run accepted, 1 a rejected run (or a tampered run that
// was accepted), 2 a toolchain or harness failure.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { binary, targetHelpers, testEnvironment, worktree } from "../lib/context";
// runFx runs FX_BIN, which defaults to the same zig-out/bin/fx as `binary`.
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

const helpers = await targetHelpers();
const { fakeGatewayFinalText, fakeGatewayToolCall, fakeShellRun, startFakeGateway, FAKE_GATEWAY_MODEL } = helpers;
const evals = await import(pathToFileURL(join(worktree, "tests", "evals", "eval-helpers.ts")).href);
const { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } = evals;

const FIXTURE = join(worktree, "tests", "tla", "drivers", "sandbox", "provider-fixture.sh");
// The stand-in for a remote sandbox: it runs each command outside fx's process tree.
const DAEMON = join(worktree, "tests", "tla", "drivers", "sandbox", "sandbox-daemon.sh");
const SPEC_DIR = join(TLA_ROOT, "sandbox");
const ALL_PLACEMENTS = ["local", "workspace", "isolated"] as const;
type Placement = (typeof ALL_PLACEMENTS)[number];
// The model calls a remote run `workspace`; the config word for it is `remote`.
const configRunner = (placement: Placement): string => (placement === "workspace" ? "remote" : placement);
// One model tick is about 250 ms of real time (SandboxProvider.tla).
const TICK_MS = 250;

function flag(name: string): boolean {
  return process.argv.includes(name);
}
function option(name: string): string | undefined {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : undefined;
}
function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

type Scenario = {
  name: string;
  placement: Placement;
  tty?: boolean;
  ready?: boolean;
  // What the remote command does after its gate opens; GATE waits for the driver.
  command: string;
  gated?: boolean;
  then?: "stop" | "crash";
  env?: boolean;
  // The provider refuses to create the sandbox (fixture act create-fails).
  act?: "create-fails";
  // The provider waits this long before it starts the command.
  holdMs?: number;
  killDelayMs?: number;
  graceMs?: number;
  // The call's own timeout, which makes fx stop the run.
  timeoutMs?: number;
};

const scenarios: Scenario[] = [
  { name: "local", placement: "local", command: "echo ran-here" },
  { name: "workspace-exit-0", placement: "workspace", command: "cat a.txt; echo made > made.txt" },
  { name: "workspace-exit-1", placement: "workspace", command: "echo failing; exit 1" },
  { name: "workspace-timeout", placement: "workspace", timeoutMs: 2000, command: "sleep 10" },
  { name: "workspace-create-fails", placement: "workspace", act: "create-fails", command: "echo never" },
  { name: "workspace-stop", placement: "workspace", gated: true, then: "stop", command: "echo late > late.txt" },
  { name: "workspace-stop-slow-kill", placement: "workspace", gated: true, then: "stop", killDelayMs: 1500, command: "echo late > late.txt" },
  { name: "workspace-stop-grace-too-short", placement: "workspace", gated: true, then: "stop", graceMs: 1000, killDelayMs: 3000, command: "echo late > late.txt" },
  { name: "workspace-stop-before-start", placement: "workspace", then: "stop", holdMs: 4000, command: "echo never" },
  { name: "workspace-crash", placement: "workspace", gated: true, then: "crash", command: "echo late > late.txt" },
  { name: "isolated-no-keys", placement: "isolated", env: true, command: 'echo "secret=[${SECRET:-}]"; echo out > result.txt' },
  { name: "isolated-stop", placement: "isolated", gated: true, then: "stop", command: "echo late" },
  { name: "tty-placed", placement: "workspace", tty: true, command: "echo never" },
  { name: "provider-missing", placement: "workspace", ready: false, command: "echo never" },
];

type Observation = {
  placement: Placement;
  tty: boolean;
  ready: boolean;
  configured: boolean;
  grants: Placement[];
  events: string[];
  result: string;
  ranLocal: boolean;
  env: string[];
  conflict: boolean;
  lost: boolean;
  orphan: boolean;
};

type Run = { observation: Observation; constants: Record<string, number>; text: string };

function git(cwd: string, args: string[]) {
  execFileSync("git", ["-c", "commit.gpgsign=false", ...args], {
    cwd,
    env: { ...process.env, GIT_AUTHOR_NAME: "fx test", GIT_AUTHOR_EMAIL: "test@example.com", GIT_COMMITTER_NAME: "fx test", GIT_COMMITTER_EMAIL: "test@example.com" },
    stdio: "ignore",
  });
}

function appendEvent(providerHome: string, ev: string) {
  writeFileSync(join(providerHome, "events.jsonl"), `${JSON.stringify({ ev, t: Date.now(), driver: true })}\n`, { flag: "a" });
}

function readEvents(providerHome: string): Array<Record<string, unknown>> {
  const file = join(providerHome, "events.jsonl");
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

async function waitForFile(file: string, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(file)) return;
    await Bun.sleep(20);
  }
  throw new Error(`no ${file} within ${timeoutMs} ms`);
}

async function waitForEvent(providerHome: string, ev: string, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (readEvents(providerHome).some((e) => e.ev === ev)) return;
    await Bun.sleep(25);
  }
  throw new Error(`no ${ev} event within ${timeoutMs} ms`);
}

// The provider is the oldest process whose command line names this run's
// private state folder; only this run starts such processes.
function providerPid(stateDir: string): number | null {
  try {
    const out = execFileSync("pgrep", ["-o", "-f", stateDir], { encoding: "utf8" }).trim();
    return out ? Number(out.split("\n")[0]) : null;
  } catch {
    return null;
  }
}

// The commands this run's provider started, from its log.
function commandPids(events: Array<Record<string, unknown>>): number[] {
  return events.filter((e) => e.ev === "start" && typeof e.child === "number").map((e) => e.child as number);
}

// Whether the process runs. A zombie has ended, but kill -0 still finds it, so
// the process state is read instead.
function alive(pid: number): boolean {
  try {
    const state = execFileSync("ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8" }).trim();
    return state !== "" && !state.startsWith("Z");
  } catch {
    return false;
  }
}

// The provider's log and the driver's steps as model events. The trace hides the
// steps fx cannot see (a refused create, a stop before the start, a SIGKILL that
// left no line, the sends and bring-backs), so they are not listed: an observed
// event the model hides could never match. A timeout is a stop by fx, so a stop
// comes before the first kill when fx says it timed out.
function modelEvents(raw: Array<Record<string, unknown>>, timedOut: boolean): string[] {
  const events: string[] = [];
  for (const e of raw) {
    switch (e.ev) {
      case "exit": events.push("exit"); break;
      case "start": case "killsent": case "killed": case "stop": case "crash":
        events.push(String(e.ev));
        break;
      default: break; // provider, createfail, termexit: hidden in the model
    }
  }
  if (timedOut && !events.includes("stop")) {
    const at = events.indexOf("killsent");
    events.splice(at >= 0 ? at : events.length, 0, "stop");
  }
  return events;
}

function toolTexts(requests: Array<{ body: string }>): string {
  const texts: string[] = [];
  for (const request of requests.slice(1)) {
    const body = JSON.parse(request.body) as { prompt?: Array<{ content: unknown }> };
    for (const message of body.prompt ?? []) {
      if (!Array.isArray(message.content)) continue;
      for (const part of message.content as Array<Record<string, unknown>>) {
        if (part.type !== "tool-result") continue;
        const output = part.output as { value?: unknown };
        texts.push(typeof output?.value === "string" ? output.value : JSON.stringify(output));
      }
    }
  }
  return texts.join("\n");
}

function sessionId(body: string): string {
  const match = /\\?"session_id\\?"\s*:\s*\\?"([^"\\]+)/.exec(body);
  if (!match) throw new Error("the background result has no session_id");
  return match[1]!;
}

// fx's own refusals start with "fx did not run this command:"; the provider's
// notes start with "fx: " and use the spec's wording (N1, N5, N7, N24, N3, N4, N6).
function classify(text: string, events: string[], ranLocal: boolean): string {
  if (ranLocal) return "local";
  if (/fx did not run this command:/.test(text) && events.length === 0) return "refused";
  if (/fx: did not run:|fx: stopped before the command was sent/.test(text)) return "didnotrun";
  if (/fx: result unknown|fx: lost contact|fx: force stop/.test(text)) return "mayhaveran";
  if (/fx: stopped;|fx: timed out after|TimeoutExpired/.test(text)) return "stopped";
  if (events.includes("exit")) return "exit";
  if (events.length === 0) return "refused";
  return "mayhaveran";
}

async function runScenario(s: Scenario, dir: string): Promise<Run> {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const repo = join(root, "repo");
  const providerHome = join(root, "provider");
  const gate = join(root, "gate");
  const stateDir = join(fxHome, "sandbox", "state");
  mkdirSync(join(fxHome, "sandbox"), { recursive: true });
  mkdirSync(repo);
  mkdirSync(providerHome);
  const spool = join(root, "spool");
  mkdirSync(spool);
  // Started in its own session, outside fx's process tree, before fx runs.
  const daemon = spawn("sh", [DAEMON, spool], { stdio: "ignore", detached: true });
  daemon.unref();
  try {
    await waitForFile(join(spool, "daemon.pid"));
  } catch (error) {
    if (daemon.pid !== undefined) process.kill(daemon.pid, "SIGKILL");
    throw error;
  }
  writeFileSync(join(repo, "a.txt"), "hello\n");
  writeFileSync(join(repo, ".gitignore"), "out/\n");
  git(repo, ["init", "-q"]);
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "initial"]);

  const remote = s.gated ? `while [ ! -e ${gate} ]; do sleep 0.05; done; ${s.command}` : s.command;
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ experimental: { sandbox_execution: true } }));
  const config: Record<string, unknown> = {
    provider: ["/bin/sh"],
    provider_args: [FIXTURE],
    grace_ms: s.graceMs ?? 5000,
    env: s.env ? ["SECRET"] : [],
    rules: s.placement === "local" ? [] : [{ command: remote, runner: configRunner(s.placement) }],
  };
  if (s.ready === false) config.provider = ["/nonexistent/fx-sandbox-provider"];
  writeFileSync(join(fxHome, "sandbox", "config.json"), JSON.stringify(config));

  const callArgs = s.then ? { yield_time_ms: 500 } : s.tty ? { tty: true } : {};
  const responses: unknown[] = [fakeShellRun("run_1", remote, { ...callArgs, ...(s.timeoutMs ? { timeout_ms: s.timeoutMs } : {}) })];
  if (s.then === "stop") {
    responses.push(async (body: string) => {
      // The stop follows the start, so the before-start case (holdMs) stops first on purpose.
      if (!s.holdMs) await waitForEvent(providerHome, "start");
      appendEvent(providerHome, "stop");
      return fakeGatewayToolCall("stop_1", "shell", { request: { action: "stop", session_id: sessionId(body) } });
    });
  } else if (s.then === "crash") {
    responses.push(async (body: string) => {
      await waitForEvent(providerHome, "start");
      const pid = providerPid(stateDir);
      if (!pid) throw new Error("no provider process to crash");
      appendEvent(providerHome, "crash");
      process.kill(pid, "SIGKILL");
      return fakeGatewayToolCall("wait_1", "shell", { request: { action: "interact", session_id: sessionId(body), yield_time_ms: 6000 } });
    });
  }
  responses.push(fakeGatewayFinalText("Done."));
  const gateway = startFakeGateway(responses);

  const env: Record<string, string | undefined> = testEnvironment({
    HOME: home,
    AI_GATEWAY_API_KEY: "sandbox-driver-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    L2_PROVIDER_LOG: join(providerHome, "events.jsonl"),
    L2_SPOOL: spool,
    L2_ACT: s.act ?? "",
    L2_HOLD_S: s.holdMs ? String(s.holdMs / 1000) : "0",
    L2_KILL_DELAY_S: s.killDelayMs ? String(s.killDelayMs / 1000) : "0",
    SECRET: "s3cret",
  });
  // runFx passes this process's environment through; no real login reaches fx.
  env.VERCEL_TOKEN = undefined;
  env.VERCEL_OIDC_TOKEN = undefined;

  const editor = s.gated && !s.then
    ? (async () => {
        await waitForEvent(providerHome, "start");
        writeFileSync(gate, "");
      })()
    : Promise.resolve();

  try {
    const saving = s.tty ? [] : ["--no-save"];
    const result = await runFx(["ask", "--json", ...saving, "--permission-mode", "full-access", "Run the command."], {
      cwd: repo, env, timeoutMs: 120_000,
    });
    await editor;
    if (result.code !== 0 && !s.tty) throw new Error(`fx exited ${result.code}: ${result.stderr}`);
    const text = toolTexts(gateway.requests);
    const raw = readEvents(providerHome);
    const orphan = commandPids(raw).some(alive);
    const events = modelEvents(raw, /TimeoutExpired/.test(text));
    const marker = s.placement === "local" && /ran-here/.test(text);
    const startEnv = raw.filter((e) => e.ev === "provider").flatMap((e) => (e.env as string[]) ?? []);
    const observation: Observation = {
      placement: s.placement,
      tty: Boolean(s.tty),
      ready: s.ready !== false,
      configured: Boolean(s.env),
      grants: [...ALL_PLACEMENTS],
      events,
      result: classify(text, events, marker),
      ranLocal: marker,
      env: [...new Set(startEnv)].map(() => "KEY"),
      conflict: /fx: kept your version of/.test(text),
      lost: false,
      orphan,
    };
    const killTicks = Math.max(1, Math.ceil(((s.killDelayMs ?? 0) + 400) / TICK_MS));
    const constants = {
      Grace: Math.max(1, Math.floor((s.graceMs ?? 5000) / TICK_MS)),
      KillTicks: killTicks,
      Timeout: Math.max(1, Math.ceil((s.timeoutMs ?? 30_000) / TICK_MS)),
      MaxEdits: 1,
    };
    writeFileSync(join(dir, "observation.json"), JSON.stringify({ observation, constants, text }, null, 2));
    return { observation, constants, text };
  } finally {
    gateway.stop();
    // Stop only the commands this run's provider started: each one leads its own
    // session, so its process group is the command and its children.
    for (const pid of commandPids(readEvents(providerHome))) {
      if (alive(pid)) {
        try { process.kill(-pid, "SIGKILL"); } catch {}
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    }
    // The daemon is the process this run started; stop it by its pid.
    if (daemon.pid !== undefined) {
      try { process.kill(daemon.pid, "SIGKILL"); } catch {}
    }
    cleanupIsolatedTestHome(root);
  }
}

const tlaString = (v: string) => `"${v}"`;
const tlaSet = (vs: string[]) => `{${vs.map(tlaString).join(", ")}}`;
const tlaBool = (v: boolean) => (v ? "TRUE" : "FALSE");

function observedModule(o: Observation): string {
  return [
    "---------------------- MODULE SandboxProviderObserved ----------------------",
    "\\* Generated by tests/tla/drivers/sandbox/driver.ts.",
    `Observed == [placement |-> ${tlaString(o.placement)}, tty |-> ${tlaBool(o.tty)}, ready |-> ${tlaBool(o.ready)}, configured |-> ${tlaBool(o.configured)},`,
    `    grants |-> ${tlaSet(o.grants)},`,
    `    events |-> <<${o.events.map(tlaString).join(", ")}>>,`,
    `    result |-> ${tlaString(o.result)}, ranLocal |-> ${tlaBool(o.ranLocal)}, env |-> ${tlaSet(o.env)},`,
    `    conflict |-> ${tlaBool(o.conflict)}, lost |-> ${tlaBool(o.lost)}, orphan |-> ${tlaBool(o.orphan)}]`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function accepted(run: { observation: Observation; constants: Record<string, number> }, dir: string): Promise<boolean> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SandboxProviderObserved.tla"), observedModule(run.observation));
  const c = run.constants;
  writeFileSync(join(dir, "trace.cfg"), [
    "INIT TraceInit", "NEXT TraceStep", "CONSTANTS", `    Bug = "none"`, `    Grace = ${c.Grace}`,
    `    KillTicks = ${c.KillTicks}`, `    Timeout = ${c.Timeout}`, `    MaxEdits = ${c.MaxEdits}`,
    "INVARIANT NotAllMatched", "",
  ].join("\n"));
  const tlc = await runTlc(dir, "SandboxProviderTrace", "trace.cfg", ["SandboxProvider.tla", "SandboxProviderTrace.tla"], SPEC_DIR, ["-deadlock"]);
  if (tlc.violated === "NotAllMatched") return true;
  if (tlc.exitCode === 0) return false;
  fail(2, `TLC failed on the trace in ${dir} (exit ${tlc.exitCode}); see ${join(dir, "tlc.log")}`);
}

// One fact changed so that no behavior of the model gives the run.
function tampered(o: Observation): Observation | null {
  if (o.result === "refused") return { ...o, events: ["start"] };
  if (o.placement === "isolated") return { ...o, env: ["KEY"] };
  if (o.result === "stopped") return { ...o, orphan: true };
  if (o.result === "didnotrun") return { ...o, result: "exit" };
  if (o.result === "local") return { ...o, result: "exit" };
  return { ...o, ranLocal: true };
}

if (!existsSync(binary)) fail(2, `missing ${binary}; run zig build first`);
const only = option("--only");
const selected = scenarios.filter((s) => !only || s.name === only);
if (selected.length === 0) fail(2, `no scenario named ${only}`);
const out = outDir("sandbox-driver");
let ok = true;
for (const s of selected) {
  const dir = join(out, s.name);
  mkdirSync(dir, { recursive: true });
  let run: Run;
  try {
    run = await runScenario(s, dir);
  } catch (error) {
    fail(2, `${s.name}: harness failure: ${(error as Error).message}`);
  }
  const accept = await accepted(run, join(dir, "trace"));
  const o = run.observation;
  console.log(`${accept ? "accepted" : "REJECTED"}  ${s.name}: result=${o.result} events=[${o.events.join(" ")}] orphan=${o.orphan} conflict=${o.conflict} env=${o.env.length}`);
  if (!accept) {
    ok = false;
    console.log(`  text: ${run.text.replace(/\s+/g, " ").slice(0, 400)}`);
    continue;
  }
  if (flag("--self-check")) {
    const bad = tampered(o);
    if (bad) {
      const caught = !(await accepted({ observation: bad, constants: run.constants }, join(dir, "tampered")));
      console.log(`  self-check: tampered run ${caught ? "rejected" : "NOT rejected"}`);
      if (!caught) ok = false;
    }
  }
}
process.exit(ok ? 0 : 1);
