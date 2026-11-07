// Runs the built fx binary along tests/tla/tool_admission/CommandEnvironment.tla
// and has TLC check every shell call it observes (CommandEnvironmentTrace.tla).
//
// Each case is one `fx ask --auto` against a local fake gateway that asks for
// one shell call and answers its review clear or caution. The profile's
// startup files define two aliases, `fxprobe` and `git`, that leave a marker
// when they run, so the driver sees whether the user's startup definitions
// applied to the command. The cases are the examiner's: a reviewed command in
// the user's login shell and in a clean shell, captured and on a TTY with an
// explicit bash or zsh, answered clear and caution, and a routine `git status`
// that runs without review in both profiles, which this change must leave as
// it is.
//
// For each call it records the environment and shell fx bound into the
// call's permission identity, what the review packet said about the
// interpreter (`environment:`, `shell:`, `startup_files:`, and
// `action_evidence_incomplete:`), how many reviews the fake gateway counted,
// how the call ended, whether the command ran, and whether an alias marker
// appeared. TLC replays the calls through the model's own actions.
// --self-check also replays them through the model of fx before the change
// (Bug = "today"), which must reject them. --stress N adds one turn with N
// reviewed user-profile calls and prints its wall time.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/tool_admission/driver.ts
//   bun tests/tla/drivers/tool_admission/driver.ts --self-check
//   bun tests/tla/drivers/tool_admission/driver.ts --self-check --stress 40
//
// Exit codes: 0 every call accepted (and the self-check rejected), 1 a call the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import { userInfo } from "node:os";
import { basename, join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Env = "user" | "clean";
type Shell = "zsh" | "bash" | "none";
type Packet = { env: string; shell: string; startup: string; complete: boolean };
type Case = {
  id: string;
  cmd: "reviewed" | "routine";
  profile: Env;
  // A TTY call with an explicit shell; otherwise a captured call in the
  // login shell.
  tty?: { path: string };
  decision: "clear" | "caution";
};
type Observation = {
  id: string;
  call: { cmd: string; env: string; shell: string };
  reviewed: boolean;
  packet: Packet;
  reviewerCalls: number;
  decision: string;
  ran: boolean;
  startupRan: boolean;
  evidence: { exit: number; identity: string; action: string; result: string; seconds: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "openai/gpt-5";
const NO_PACKET: Packet = { env: "absent", shell: "absent", startup: "absent", complete: false };
const tlaDir = join(TLA_ROOT, "tool_admission");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  jobs: option("--jobs", 4),
  stress: option("--stress", 0),
};

// The login shell fx picks for a captured call (shell_resolver.zig
// supportedLoginShell): the passwd shell when it is bash or zsh, otherwise
// zsh on macOS and bash elsewhere.
function loginShell(): string {
  const shell = userInfo().shell ?? "";
  if (["bash", "zsh"].includes(basename(shell))) return shell;
  return process.platform === "darwin" ? "/bin/zsh" : "/bin/bash";
}

function shellName(path: string): Shell | "other" {
  const name = basename(path);
  return name === "zsh" || name === "bash" ? name : "other";
}

function cases(): Case[] {
  const list: Case[] = [];
  for (const profile of ["user", "clean"] as const) {
    for (const decision of ["clear", "caution"] as const) {
      list.push({ id: `captured-${profile}-${decision}`, cmd: "reviewed", profile, decision });
    }
    for (const path of ["/bin/bash", "/bin/zsh"]) {
      if (!existsSync(path)) continue;
      list.push({ id: `tty-${basename(path)}-${profile}`, cmd: "reviewed", profile, tty: { path }, decision: "clear" });
    }
    list.push({ id: `routine-${profile}`, cmd: "routine", profile, decision: "clear" });
  }
  return list;
}

function shellRequest(c: Case, root: string, index: number) {
  const command = c.cmd === "routine"
    ? "git status"
    : `fxprobe ${join(root, `alias-${index}`)}; touch ${join(root, `ran-${index}`)}`;
  if (c.tty) {
    return {
      action: "run",
      command,
      tty: true,
      shell: { kind: "executable", path: c.tty.path, clean_start: c.profile === "clean" },
      yield_time_ms: 5_000,
      timeout_ms: 20_000,
    };
  }
  return { action: "run", command, profile: c.profile, yield_time_ms: 30_000 };
}

// The review data inside <permission_review>, with XML entities decoded.
function reviewData(body: string): string {
  const texts: string[] = [];
  const collect = (value: unknown) => {
    if (typeof value === "string") texts.push(value);
    else if (Array.isArray(value)) value.forEach(collect);
    else if (value && typeof value === "object") Object.values(value).forEach(collect);
  };
  collect(JSON.parse(body));
  const instruction = texts.find((text) => text.includes("<permission_review>")) ?? "";
  const start = instruction.indexOf("<review_data");
  const end = instruction.indexOf("</review_data>");
  return instruction.slice(instruction.indexOf(">", start) + 1, end)
    .replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&quot;", "\"").replaceAll("&amp;", "&");
}

function parsePacket(data: string): { packet: Packet; action: string; identity: string } {
  const action = data.slice(data.lastIndexOf("\naction: ") + 1);
  const lines = action.split("\n");
  const value = (label: string) => {
    const line = lines.find((entry) => entry.startsWith(`${label}: `));
    return line === undefined ? null : line.slice(label.length + 2);
  };
  const shell = value("shell");
  const startup = value("startup_files");
  const packet: Packet = {
    env: value("environment") ?? "absent",
    shell: shell === null ? "absent" : shell === "[evidence unavailable]" ? "none" : shellName(shell),
    startup: startup === null
      ? "absent"
      : startup.startsWith("skipped")
        ? "skipped"
        : startup.includes("apply") ? "applies" : "other",
    complete: value("action_evidence_incomplete") === "false",
  };
  const identity = data.split("\n").find((line) => line.startsWith("target[")) ?? "";
  return { packet, action, identity };
}

// The environment and shell fx bound into the call's permission identity
// (command_environment.zig permissionCommandIdentity).
function identityCall(identity: string): { env: string; shell: string } | null {
  const match = /@fx-terminal-env:(user|clean):(\d+):/.exec(identity);
  if (!match) return null;
  const start = match.index + match[0].length;
  const path = identity.slice(start, start + Number(match[2]));
  return { env: match[1]!, shell: shellName(path) };
}

function toolResult(body: string, callId: string): { type: string; text: string } | null {
  const prompt = (JSON.parse(body).prompt ?? []) as Array<{ content?: unknown }>;
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, any>>) {
      if (part.type === "tool-result" && part.toolCallId === callId) {
        const output = part.output ?? {};
        return { type: String(output.type), text: String(output.value ?? output.reason ?? "") };
      }
    }
  }
  return null;
}

function startupFiles(root: string, home: string) {
  const aliases = [
    "alias fxprobe='touch'",
    `alias git='touch ${join(root, "alias-git")}'`,
    "",
  ].join("\n");
  for (const name of [".zshrc", ".bash_profile", ".bashrc"]) writeFileSync(join(home, name), aliases);
}

async function runTurn(helpers: any, scratch: string, turnId: string, turnCases: Case[]): Promise<Observation[]> {
  const root = mkdtempSync(join(scratch, `${turnId}-`));
  const home = join(root, "home");
  const fxHome = join(root, "fxhome");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(fxHome, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  startupFiles(root, home);
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  const git = Bun.spawnSync(["/usr/bin/git", "init", "-q", "."], { cwd: workspace, env: { HOME: home, PATH: "/usr/bin:/bin" } });
  if (git.exitCode !== 0) throw new Error(`git init failed: ${git.stderr}`);

  const responses = turnCases.map((c, index) => () =>
    helpers.fakeGatewayToolCall(`call_${index}`, "shell", { request: shellRequest(c, root, index) }));
  responses.push(() => helpers.fakeGatewayFinalText(`TURN_DONE_${turnId}`));
  const classifierResponses = turnCases
    .filter((c) => c.cmd === "reviewed")
    .map((c, index) => c.decision === "caution"
      ? helpers.fakeGatewayHeldDecision(`held_${index}`)
      : helpers.fakeGatewayPermissionDecision("clear", `clear_${index}`));
  const gateway = helpers.startFakeGateway(responses, { classifierResponses });
  try {
    const started = performance.now();
    // A TTY call needs a saved session, so every turn saves one in its own
    // FX_HOME.
    const child = Bun.spawn([binary, "ask", "--auto", "--quiet", "Run the shell calls."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        PATH: "/usr/bin:/bin",
        FX_HOME: fxHome,
        AI_GATEWAY_API_KEY: "fake-command-environment-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: MODEL,
        FX_PERMISSION_MODE: "auto",
        NO_COLOR: "1",
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 60_000 + turnCases.length * 5_000);
    const [, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    if (gateway.requests.length !== turnCases.length + 1) {
      throw new Error(`turn ${turnId}: the fake gateway counted ${gateway.requests.length} model requests, ` +
        `expected ${turnCases.length + 1}; exit ${exit}; stderr ${stderr.slice(-400)}`);
    }
    const reviews = gateway.classifierRequests.map((request: { body: string }) => parsePacket(reviewData(request.body)));
    return turnCases.map((c, index) => {
      const command = shellRequest(c, root, index).command;
      const mine = reviews.filter((review: { action: string }) => review.action.includes(`\ncommand: ${command}\n`));
      const result = toolResult(gateway.requests[index + 1]!.body, `call_${index}`) ?? { type: "missing", text: "" };
      const reviewed = mine.length > 0;
      let decision = "unreviewed";
      if (reviewed) {
        if (result.type === "text" || result.type === "error-text") decision = "clear";
        else if (result.text.includes("review_caution")) decision = "caution";
        else if (result.text.includes("review_unavailable") || result.text.includes("review_evidence_incomplete")) decision = "unavailable";
        else decision = `unknown:${result.type}`;
      }
      const identity = reviewed ? mine[0].identity : "";
      const bound = identityCall(identity);
      const requested = { env: c.profile, shell: shellName(c.tty?.path ?? loginShell()) };
      const call = bound ?? requested;
      const ran = c.cmd === "routine"
        ? result.type === "text"
        : existsSync(join(root, `ran-${index}`));
      const startupRan = existsSync(join(root, c.cmd === "routine" ? "alias-git" : `alias-${index}`));
      return {
        id: `${turnId}/${c.id}`,
        call: { cmd: c.cmd, ...call },
        reviewed,
        packet: reviewed ? mine[0].packet : NO_PACKET,
        reviewerCalls: mine.length,
        decision,
        ran,
        startupRan,
        evidence: {
          exit,
          identity,
          action: reviewed ? mine[0].action.trim() : "",
          result: `${result.type}: ${result.text.slice(0, 200)}`,
          seconds,
        },
      };
    });
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const record = (o: Observation) =>
    `[call |-> [cmd |-> ${str(o.call.cmd)}, env |-> ${str(o.call.env)}, shell |-> ${str(o.call.shell)}], ` +
    `reviewed |-> ${o.reviewed ? "TRUE" : "FALSE"}, ` +
    `packet |-> [env |-> ${str(o.packet.env)}, shell |-> ${str(o.packet.shell)}, startup |-> ${str(o.packet.startup)}, ` +
    `complete |-> ${o.packet.complete ? "TRUE" : "FALSE"}], ` +
    `reviewerCalls |-> ${o.reviewerCalls}, decision |-> ${str(o.decision)}, ` +
    `ran |-> ${o.ran ? "TRUE" : "FALSE"}, startupRan |-> ${o.startupRan ? "TRUE" : "FALSE"}]`;
  return [
    "--------------------- MODULE CommandEnvironmentObserved ---------------------",
    "(* Generated by tests/tla/drivers/tool_admission/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(record).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["CommandEnvironment.tla", "CommandEnvironmentTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "CommandEnvironmentObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "  Commands = {\"routine\", \"reviewed\"}",
    "  Shells = {\"zsh\", \"bash\", \"none\"}",
    `  MaxCalls = ${observations.length}`,
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "CommandEnvironmentTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], bug: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("tool_admission");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const turns: Array<{ id: string; cases: Case[] }> = cases().map((c) => ({ id: c.id, cases: [c] }));
  if (options.stress > 0) {
    turns.push({
      id: `stress-${options.stress}`,
      cases: Array.from({ length: options.stress }, (_, i) => ({ id: `call-${i}`, cmd: "reviewed", profile: "user", decision: "clear" })),
    });
  }
  const results: Observation[][] = new Array(turns.length);
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < turns.length) {
      const index = next++;
      results[index] = await runTurn(helpers, scratch, turns[index]!.id, turns[index]!.cases);
    }
  });
  await Promise.all(workers);
  const observations = results.flat();
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  console.log(`${observations.length} shell calls in ${turns.length} turns of ${binary} in ${seconds}s`);
  console.log(`observations: ${join(out, "observations.json")}`);
  for (const o of observations.slice(0, turns.length - (options.stress > 0 ? 1 : 0))) {
    console.log(`  ${o.id}: call ${o.call.env}/${o.call.shell} ${o.call.cmd}, packet ${JSON.stringify(o.packet)}, ` +
      `${o.decision}, ran ${o.ran}, startup ran ${o.startupRan}`);
  }
  if (options.stress > 0) {
    const stress = results.at(-1)!;
    const named = stress.filter((o) => o.packet.env === "user" && o.packet.shell === o.call.shell).length;
    console.log(`stress: ${options.stress} reviewed calls in one turn, ${named} packets named the user shell, ` +
      `${stress[0]?.evidence.seconds}s`);
  }
  const unknown = observations.find((o) => o.decision.startsWith("unknown") || o.packet.shell === "other" ||
    o.packet.startup === "other" || o.call.shell === "other");
  if (unknown) {
    console.log(`REJECTED: call ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  const design = await runTrace(observations, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "none", out);
    console.log(`first call the model cannot produce: ${JSON.stringify(mismatch)}`);
    // A binary from before the change should match the model of it.
    const today = await runTrace(observations, "today", out);
    console.log(`the model of fx before the change: ${today.verdict}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
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
