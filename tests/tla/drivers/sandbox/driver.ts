// Runs the built fx along tests/tla/sandbox/SandboxProvider.tla, code to spec:
// each scenario is one `fx ask` whose scripted model makes one shell call that
// a rule in the private sandbox config places locally, in the workspace
// sandbox, or in an isolated one. fx runs the real default provider,
// src/core/sandbox/providers/vercel.sh, against the fake sandbox CLI in
// tests/e2e/fixtures/fake-sandbox-cli.ts, which logs every sandbox step. The
// driver adds its own steps to that log (a local edit, a stop, a provider
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
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { binary, targetHelpers, testEnvironment, worktree } from "../lib/context";
// runFx runs FX_BIN, which defaults to the same zig-out/bin/fx as `binary`.
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

const helpers = await targetHelpers();
const { fakeGatewayFinalText, fakeGatewayToolCall, fakeShellRun, startFakeGateway, FAKE_GATEWAY_MODEL } = helpers;
const evals = await import(pathToFileURL(join(worktree, "tests", "evals", "eval-helpers.ts")).href);
const { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } = evals;

const FAKE_CLI = join(worktree, "tests", "e2e", "fixtures", "fake-sandbox-cli.ts");
const SPEC_DIR = join(TLA_ROOT, "sandbox");
const ALL_PLACEMENTS = ["local", "workspace", "isolated"] as const;
type Placement = (typeof ALL_PLACEMENTS)[number];
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
  edit?: boolean;
  env?: boolean;
  failCreate?: boolean;
  createDelayMs?: number;
  killDelayMs?: number;
  graceMs?: number;
  timeoutMs?: number;
  sweepAfter?: boolean;
};

const scenarios: Scenario[] = [
  { name: "local", placement: "local", command: "echo ran-here" },
  { name: "workspace-exit-0", placement: "workspace", command: "cat a.txt; echo made > made.txt" },
  { name: "workspace-exit-1", placement: "workspace", command: "echo failing; exit 1" },
  { name: "workspace-edit-kept", placement: "workspace", gated: true, edit: true, command: "echo remote > a.txt; echo new > b.txt" },
  { name: "workspace-timeout", placement: "workspace", timeoutMs: 2000, command: "sleep 10" },
  { name: "workspace-create-fails", placement: "workspace", failCreate: true, command: "echo never" },
  { name: "workspace-stop", placement: "workspace", gated: true, then: "stop", command: "echo late > late.txt" },
  { name: "workspace-stop-slow-kill", placement: "workspace", gated: true, then: "stop", killDelayMs: 1500, command: "echo late > late.txt" },
  { name: "workspace-stop-grace-too-short", placement: "workspace", gated: true, then: "stop", graceMs: 1000, killDelayMs: 3000, command: "echo late > late.txt" },
  { name: "workspace-stop-before-start", placement: "workspace", then: "stop", createDelayMs: 4000, command: "echo never" },
  { name: "workspace-crash", placement: "workspace", gated: true, then: "crash", command: "echo late > late.txt" },
  { name: "isolated-no-keys", placement: "isolated", env: true, command: "echo \"secret=[${SECRET:-}]\"; echo out > result.txt" },
  { name: "isolated-stop", placement: "isolated", gated: true, then: "stop", command: "echo late" },
  { name: "isolated-crash-then-sweep", placement: "isolated", gated: true, then: "crash", sweepAfter: true, command: "echo late" },
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

// The fake's daemon runs the detached commands outside fx's process tree, as a
// real sandbox does.
async function startFakeDaemon(fakeHome: string): Promise<ChildProcess> {
  const daemon = spawn(FAKE_CLI, ["__daemon"], { env: { ...process.env, FAKE_SANDBOX_HOME: fakeHome }, stdio: "ignore" });
  const deadline = Date.now() + 10_000;
  while (!existsSync(join(fakeHome, "daemon.pid"))) {
    if (Date.now() > deadline) throw new Error("the fake sandbox daemon did not start");
    await Bun.sleep(10);
  }
  return daemon;
}

function appendEvent(fakeHome: string, ev: string) {
  writeFileSync(join(fakeHome, "events.jsonl"), `${JSON.stringify({ ev, t: Date.now(), driver: true })}\n`, { flag: "a" });
}

function readEvents(fakeHome: string): Array<Record<string, unknown>> {
  const file = join(fakeHome, "events.jsonl");
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

async function waitForEvent(fakeHome: string, ev: string, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (readEvents(fakeHome).some((e) => e.ev === ev)) return;
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

// The fake's commands that still run, with their process groups.
function runningCommands(fakeHome: string): number[] {
  const dir = join(fakeHome, "commands");
  if (!existsSync(dir)) return [];
  const pids: number[] = [];
  for (const id of readdirSync(dir)) {
    if (existsSync(join(dir, id, "exit")) || !existsSync(join(dir, id, "pid"))) continue;
    const pid = Number(readFileSync(join(dir, id, "pid"), "utf8"));
    try {
      process.kill(pid, 0);
      pids.push(pid);
    } catch {}
  }
  return pids;
}

// The fake log and the driver's steps as model events. Exits that a kill or a
// removal caused are part of those steps. fx sweeps at every start, so an ls
// is hidden; an rm after the driver's next-start marker is that start's sweep.
function modelEvents(raw: Array<Record<string, unknown>>): string[] {
  const events: string[] = [];
  let sweeping = false;
  for (const e of raw) {
    switch (e.ev) {
      case "next-start": sweeping = true; break;
      case "rm": events.push(sweeping ? "sweep" : "rm"); break;
      case "exit": if (!e.by) events.push("exit"); break;
      case "createfail": case "start": case "timeout": case "killsent": case "killed":
      case "edit": case "stop": case "crash":
        events.push(String(e.ev));
        break;
      default: break; // create and foreground exec calls (sends, bring-backs) are hidden steps
    }
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
// notes start with "fx: ".
function classify(text: string, events: string[], ranLocal: boolean): string {
  if (ranLocal) return "local";
  if (/fx did not run this command:/.test(text) && events.length === 0) return "refused";
  if (/fx: the command did not run|fx: stopped before the command started/.test(text)) return "didnotrun";
  if (/fx: stopped the command in the sandbox/.test(text)) return "stopped";
  if (/fx: ran in /.test(text)) return "exit";
  if (events.length === 0) return "refused";
  return "mayhaveran";
}

async function runScenario(s: Scenario, dir: string): Promise<Run> {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const repo = join(root, "repo");
  const fakeHome = join(root, "fake");
  const gate = join(root, "gate");
  const stateDir = join(fxHome, "sandbox", "state");
  mkdirSync(join(fxHome, "sandbox"), { recursive: true });
  mkdirSync(repo);
  mkdirSync(fakeHome);
  writeFileSync(join(repo, "a.txt"), "hello\n");
  writeFileSync(join(repo, ".gitignore"), "out/\n");
  git(repo, ["init", "-q"]);
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "initial"]);
  chmodSync(FAKE_CLI, 0o755);

  const remote = s.gated ? `while [ ! -e ${gate} ]; do sleep 0.05; done; ${s.command}` : s.command;
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ experimental: { sandbox_execution: true } }));
  const timeoutMs = s.timeoutMs ?? 30_000;
  const config: Record<string, unknown> = {
    provider_args: ["--cli", FAKE_CLI, "--remote-base", join(fakeHome, "fs"), "--command-timeout", `${timeoutMs}ms`],
    grace_ms: s.graceMs ?? 5000,
    env: s.env ? ["SECRET"] : [],
    rules: s.placement === "local" ? [] : [{ command: remote, placement: s.placement }],
  };
  if (s.ready === false) config.provider = ["/nonexistent/fx-sandbox-provider"];
  writeFileSync(join(fxHome, "sandbox", "config.json"), JSON.stringify(config));

  const responses: unknown[] = [fakeShellRun("run_1", remote, s.then ? { yield_time_ms: 500 } : s.tty ? { tty: true } : {})];
  if (s.then === "stop") {
    responses.push((body: string) => {
      appendEvent(fakeHome, "stop");
      return fakeGatewayToolCall("stop_1", "shell", { request: { action: "stop", session_id: sessionId(body) } });
    });
  } else if (s.then === "crash") {
    responses.push(async (body: string) => {
      await waitForEvent(fakeHome, "start");
      const pid = providerPid(stateDir);
      if (!pid) throw new Error("no provider process to crash");
      appendEvent(fakeHome, "crash");
      process.kill(pid, "SIGKILL");
      return fakeGatewayToolCall("wait_1", "shell", { request: { action: "interact", session_id: sessionId(body), yield_time_ms: 6000 } });
    });
  }
  responses.push(fakeGatewayFinalText("Done."));
  const gateway = startFakeGateway(responses);
  const daemon = await startFakeDaemon(fakeHome);

  const env: Record<string, string | undefined> = testEnvironment({
    HOME: home,
    AI_GATEWAY_API_KEY: "sandbox-driver-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FAKE_SANDBOX_HOME: fakeHome,
    SECRET: "s3cret",
    ...(s.failCreate ? { FAKE_SANDBOX_FAIL_CREATE: "1" } : {}),
    ...(s.createDelayMs ? { FAKE_SANDBOX_CREATE_DELAY_MS: String(s.createDelayMs) } : {}),
    ...(s.killDelayMs ? { FAKE_SANDBOX_KILL_DELAY_MS: String(s.killDelayMs) } : {}),
  });
  // runFx passes this process's environment through; no real login reaches fx.
  env.VERCEL_TOKEN = undefined;
  env.VERCEL_OIDC_TOKEN = undefined;

  let edited = false;
  const editor = s.edit
    ? (async () => {
        await waitForEvent(fakeHome, "start");
        writeFileSync(join(repo, "a.txt"), "local edit\n");
        edited = true;
        appendEvent(fakeHome, "edit");
        writeFileSync(gate, "");
      })()
    : s.gated && !s.then
      ? (async () => {
          await waitForEvent(fakeHome, "start");
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
    const orphan = runningCommands(fakeHome).length > 0;

    if (s.sweepAfter) {
      // The next fx start sweeps what the crashed provider left.
      appendEvent(fakeHome, "next-start");
      const next = startFakeGateway([fakeGatewayFinalText("Nothing to do.")]);
      await runFx(["ask", "--json", "--no-save", "--permission-mode", "full-access", "Nothing."], {
        cwd: repo, env: { ...env, FX_GATEWAY_BASE_URL: next.baseUrl, FX_GATEWAY_CHAT_URL: next.chatUrl, FX_TEST_GATEWAY_CHAT_URL: next.chatUrl }, timeoutMs: 60_000,
      });
      const deadline = Date.now() + 20_000;
      while (Date.now() < deadline && !readEvents(fakeHome).some((e) => e.ev === "rm")) await Bun.sleep(50);
      next.stop();
    }

    const events = modelEvents(readEvents(fakeHome));
    const marker = s.placement === "local" && /ran-here/.test(text);
    const startEnv = readEvents(fakeHome).filter((e) => e.ev === "start").flatMap((e) => (e.env as string[]) ?? []);
    const aText = readFileSync(join(repo, "a.txt"), "utf8");
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
      lost: edited && aText.startsWith("remote"),
      orphan,
    };
    const killTicks = Math.max(1, Math.ceil(((s.killDelayMs ?? 0) + 400) / TICK_MS));
    const constants = {
      Grace: Math.max(1, Math.floor((s.graceMs ?? 5000) / TICK_MS)),
      KillTicks: killTicks,
      Timeout: Math.max(1, Math.ceil(timeoutMs / TICK_MS)),
      MaxEdits: 1,
    };
    writeFileSync(join(dir, "observation.json"), JSON.stringify({ observation, constants, text }, null, 2));
    return { observation, constants, text };
  } finally {
    gateway.stop();
    daemon.kill("SIGKILL");
    // Stop only the fake commands this run started, by their process groups.
    for (const pid of runningCommands(fakeHome)) {
      try { process.kill(-pid, "SIGKILL"); } catch {}
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
