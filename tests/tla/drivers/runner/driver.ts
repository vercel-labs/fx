// Checks shell runs and remote runs against tests/tla/runner/RunnerSetup.tla
// and RemoteRun.tla by trace validation (RunnerSetupTrace.tla and
// RemoteRunTrace.tla).
//
// The models describe code that has not landed (src/core/runner/), so the
// run of the built fx needs --next. --self-check needs only TLC.
//
// An observation set describes one scenario. A setup set holds the inputs of
// each shell call, the user's answers and other actions, and the outcome:
// where each call ran or that it was refused, the prompts opened, and the
// writes of config.remote. A run set is the ordered events of one remote run.
// TLC accepts a set when the model has a behavior that gives all of it.
//
// Usage (from the repository root):
//   bun tests/tla/drivers/runner/driver.ts --self-check
//   bun tests/tla/drivers/runner/driver.ts --next          # after zig build
//   bun tests/tla/drivers/runner/driver.ts --self-check --only ac-05 --jobs 4
//
// --self-check reads the hand-written sets in fixtures/*.json, requires TLC
// to accept each one, then changes each set in the one way its fixture names
// (a remote run reported as local, a second send, a write over a Mac edit, a
// prompt after a decline, a write without an accept, and so on) and requires
// TLC to reject it. --next runs each fixture's scenario through the built fx
// against a fake Vercel API (tests/e2e/fixtures/fake-vercel-api.ts) and a fake
// model gateway, turns what happened into the same sets, and checks and
// tampers them the same way.
//
// Exit codes: 0 every check met, 1 a check missed, 2 a harness failure or
// --next without the runner code.
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { binary, targetHelpers, testEnvironment, worktree } from "../lib/context";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

const SPEC_DIR = join(TLA_ROOT, "runner");
const FIXTURES = join(import.meta.dirname, "fixtures");

// ---------------------------------------------------------------------------
// Observation sets.

const REQUESTS = ["none", "local", "remote"] as const;
const RULES = ["none", "local", "remote", "isolated"] as const;
const FLOORS = ["none", "remote", "isolated"] as const;
const LOGINS = ["none", "expired", "valid", "other_user"] as const;
const SURFACES = ["interactive", "headless"] as const;
// accept is the project accept at P2, the consent; team_accept is the team accept at P1.
const ANSWERS = ["accept", "team_accept", "decline", "cancel", "no_answer", "rest_fail"] as const;
const TEAM_COUNTS = ["one", "many"] as const;
// The answers each prompt takes: P1 (team) and P2 (project).
const TEAM_PROMPT_ANSWERS = ["team_accept", "decline", "cancel"] as const;
const PROJECT_PROMPT_ANSWERS = ["accept", "decline", "cancel", "rest_fail"] as const;
const OUTCOMES = ["local", "remote", "isolated", "refused"] as const;
// The answers that set the decline mark (RunnerSetup.tla Answer).
const MARKING_ANSWERS: readonly string[] = ["decline", "cancel", "no_answer"];
const EVENTS = [
  "push_ok", "push_failed", "stop_before_send", "send_ran", "send_not_run", "send_failed", "send_gone", "resumed",
  "id_arrives", "no_id", "cmd_edits", "cmd_exits", "stream_end", "idle_close",
  "reattach_ok", "reattach_lost", "bring_back_written", "bring_back_kept", "bring_back_nothing",
  "mac_edit", "stop_requested", "kill_sent", "stop_exit",
  "exit_cmd", "exit_125", "exit_143", "exit_255",
] as const;
// The scenarios --self-check must cover, by a fixture's `covers`.
const REQUIRED_COVERAGE = [
  "AC-2", "AC-3", "AC-4", "AC-5", "AC-6", "AC-7", "AC-8", "AC-9", "AC-10", "AC-11", "AC-12",
  "sub-agent", "login-change",
];

type Request = (typeof REQUESTS)[number];
type Rule = (typeof RULES)[number];
type Floor = (typeof FLOORS)[number];
type Login = (typeof LOGINS)[number];
type Surface = (typeof SURFACES)[number];
type Answer = (typeof ANSWERS)[number];
type Outcome = (typeof OUTCOMES)[number];
type TeamCount = (typeof TEAM_COUNTS)[number];
type RunEvent = (typeof EVENTS)[number];

type CallInput = { req: Request; rule: Rule; floor: Floor; sub: boolean };

type SetupObs = {
  calls: Record<string, CallInput>;
  surface: Surface;
  login: Login;
  configured: boolean;
  configValid: boolean;
  teams: TeamCount;
  answers: Answer[];
  cancels: Record<string, number>;
  retries: Record<string, number>;
  newTurns: number;
  loginChange: null | { to: Login; before: string };
  outcomes: Record<string, Outcome[]>;
  prompts: number;
  writes: number;
};

type RunObs = { events: RunEvent[] };

type SetupTamper =
  | "outcome-as-local" | "local-as-remote" | "refused-as-remote" | "extra-prompt"
  | "prompt-after-decline" | "write-without-accept" | "prompt-without-channel" | "p2-skipped";
type RunTamper =
  | "resend-after-unknown" | "resend-after-close" | "overwrite-mac" | "exit-without-kill"
  | "stop-before-id" | "early-bring-back" | "exit-code-lie" | "resend-without-resume";

/// How --next drives a fixture's scenario. Everything else comes from the
/// setup set's inputs.
type Drive = {
  command?: string; // the command each call runs after its marker and pwd
  teams?: number; // teams in the fake API, 1 or more
  faults?: Record<string, unknown>; // fake API faults, set before the run
  stop?: boolean; // run in the background, then stop it
  stopWhenExecSent?: boolean; // stop once the exec request reached the fake
  file?: string; // the repository file the command may change
  macEdit?: boolean; // edit `file` on the Mac once the command changed it remotely
};

type Fixture = {
  name: string;
  covers: string[];
  title: string;
  setup?: SetupObs;
  run?: RunObs;
  tamper: { setup?: SetupTamper; run?: RunTamper };
  drive: Drive;
};

class FixtureError extends Error {}

function expect(ok: boolean, where: string, message: string): asserts ok {
  if (!ok) throw new FixtureError(`${where}: ${message}`);
}

function oneOf<T extends string>(values: readonly T[], value: unknown, where: string): T {
  expect(typeof value === "string" && (values as readonly string[]).includes(value), where,
    `${JSON.stringify(value)} is not one of ${values.join(", ")}`);
  return value as T;
}

function keysExactly(value: unknown, keys: string[], where: string, optional: string[] = []): Record<string, any> {
  expect(!!value && typeof value === "object" && !Array.isArray(value), where, "must be an object");
  const record = value as Record<string, any>;
  for (const key of Object.keys(record)) expect(keys.includes(key) || optional.includes(key), where, `unknown key ${key}`);
  for (const key of keys) expect(key in record, where, `missing key ${key}`);
  return record;
}

function count(value: unknown, where: string): number {
  expect(Number.isInteger(value) && (value as number) >= 0, where, "must be a whole number");
  return value as number;
}

function callCounts(value: unknown, calls: string[], where: string): Record<string, number> {
  const record = keysExactly(value, [], where, calls);
  return Object.fromEntries(calls.map((call) => [call, call in record ? count(record[call], `${where}.${call}`) : 0]));
}

function parseSetup(value: unknown, where: string): SetupObs {
  const s = keysExactly(value, [
    "calls", "surface", "login", "configured", "configValid", "teams", "answers", "cancels", "retries",
    "newTurns", "loginChange", "outcomes", "prompts", "writes",
  ], where);
  const callsIn = keysExactly(s.calls, [], `${where}.calls`, Object.keys(s.calls ?? {}));
  const names = Object.keys(callsIn).sort();
  expect(names.length >= 1 && names.length <= 2, `${where}.calls`, "one or two calls");
  const calls: Record<string, CallInput> = {};
  for (const name of names) {
    expect(/^c[1-9]$/.test(name), `${where}.calls`, `call names are c1, c2: ${name}`);
    const c = keysExactly(callsIn[name], ["req", "rule", "floor", "sub"], `${where}.calls.${name}`);
    expect(typeof c.sub === "boolean", `${where}.calls.${name}.sub`, "must be a boolean");
    calls[name] = {
      req: oneOf(REQUESTS, c.req, `${where}.calls.${name}.req`),
      rule: oneOf(RULES, c.rule, `${where}.calls.${name}.rule`),
      floor: oneOf(FLOORS, c.floor, `${where}.calls.${name}.floor`),
      sub: c.sub,
    };
  }
  expect(typeof s.configured === "boolean" && typeof s.configValid === "boolean", where, "configured and configValid are booleans");
  expect(Array.isArray(s.answers), `${where}.answers`, "must be a list");
  let loginChange: SetupObs["loginChange"] = null;
  if (s.loginChange !== null) {
    const change = keysExactly(s.loginChange, ["to", "before"], `${where}.loginChange`);
    expect(change.before === "any" || names.includes(change.before), `${where}.loginChange.before`, "a call or \"any\"");
    loginChange = { to: oneOf(LOGINS, change.to, `${where}.loginChange.to`), before: change.before };
    expect(loginChange.to !== s.login, `${where}.loginChange.to`, "must differ from login");
  }
  const outcomesIn = keysExactly(s.outcomes, names, `${where}.outcomes`);
  const outcomes: Record<string, Outcome[]> = {};
  for (const name of names) {
    expect(Array.isArray(outcomesIn[name]) && outcomesIn[name].length > 0, `${where}.outcomes.${name}`, "a non-empty list");
    outcomes[name] = outcomesIn[name].map((o: unknown, i: number) => oneOf(OUTCOMES, o, `${where}.outcomes.${name}[${i}]`));
  }
  return {
    calls,
    surface: oneOf(SURFACES, s.surface, `${where}.surface`),
    login: oneOf(LOGINS, s.login, `${where}.login`),
    configured: s.configured,
    configValid: s.configValid,
    teams: oneOf(TEAM_COUNTS, s.teams, `${where}.teams`),
    answers: s.answers.map((a: unknown, i: number) => oneOf(ANSWERS, a, `${where}.answers[${i}]`)),
    cancels: callCounts(s.cancels, names, `${where}.cancels`),
    retries: callCounts(s.retries, names, `${where}.retries`),
    newTurns: count(s.newTurns, `${where}.newTurns`),
    loginChange,
    outcomes,
    prompts: count(s.prompts, `${where}.prompts`),
    writes: count(s.writes, `${where}.writes`),
  };
}

function parseRun(value: unknown, where: string): RunObs {
  const r = keysExactly(value, ["events"], where);
  expect(Array.isArray(r.events) && r.events.length > 0, `${where}.events`, "a non-empty list");
  return { events: r.events.map((e: unknown, i: number) => oneOf(EVENTS, e, `${where}.events[${i}]`)) };
}

const SETUP_TAMPERS: SetupTamper[] = [
  "outcome-as-local", "local-as-remote", "refused-as-remote", "extra-prompt",
  "prompt-after-decline", "write-without-accept", "prompt-without-channel", "p2-skipped",
];
const RUN_TAMPERS: RunTamper[] = [
  "resend-after-unknown", "resend-after-close", "overwrite-mac", "exit-without-kill",
  "stop-before-id", "early-bring-back", "exit-code-lie", "resend-without-resume",
];

function parseFixture(path: string): Fixture {
  const name = path.split("/").at(-1)!.replace(/\.json$/, "");
  const f = keysExactly(JSON.parse(readFileSync(path, "utf8")), ["covers", "title", "tamper", "drive"], name, ["setup", "run"]);
  expect(Array.isArray(f.covers) && f.covers.every((c: unknown) => typeof c === "string"), `${name}.covers`, "a list of names");
  expect(typeof f.title === "string", `${name}.title`, "a string");
  expect(f.setup !== undefined || f.run !== undefined, name, "needs a setup set, a run set, or both");
  const setup = f.setup === undefined ? undefined : parseSetup(f.setup, `${name}.setup`);
  const run = f.run === undefined ? undefined : parseRun(f.run, `${name}.run`);
  const tamperIn = keysExactly(f.tamper, [], `${name}.tamper`, ["setup", "run"]);
  expect((tamperIn.setup !== undefined) === (setup !== undefined), `${name}.tamper.setup`, "one tamper for the setup set");
  expect((tamperIn.run !== undefined) === (run !== undefined), `${name}.tamper.run`, "one tamper for the run set");
  const drive = keysExactly(f.drive, [], `${name}.drive`, ["command", "teams", "faults", "stop", "stopWhenExecSent", "file", "macEdit"]);
  if (setup !== undefined) {
    const driveTeams = (drive as Drive).teams ?? 1;
    expect((setup.teams === "many") === (driveTeams >= 2), name, "setup.teams and drive.teams must agree");
  }
  return {
    name,
    covers: f.covers,
    title: f.title,
    setup,
    run,
    tamper: {
      setup: tamperIn.setup === undefined ? undefined : oneOf(SETUP_TAMPERS, tamperIn.setup, `${name}.tamper.setup`),
      run: tamperIn.run === undefined ? undefined : oneOf(RUN_TAMPERS, tamperIn.run, `${name}.tamper.run`),
    },
    drive: drive as Drive,
  };
}

// ---------------------------------------------------------------------------
// Tampers: each changes a set in one way the model forbids.

function copySetup(s: SetupObs): SetupObs {
  return JSON.parse(JSON.stringify(s));
}

/// The first outcome, in call order, that `match` accepts.
function findOutcome(s: SetupObs, match: (o: Outcome) => boolean, last = false): [string, number] {
  const all: Array<[string, number]> = [];
  for (const call of Object.keys(s.outcomes).sort()) {
    s.outcomes[call]!.forEach((o, i) => { if (match(o)) all.push([call, i]); });
  }
  const found = last ? all.at(-1) : all[0];
  if (!found) throw new FixtureError("the tamper has no outcome to change");
  return found;
}

function tamperSetup(s: SetupObs, kind: SetupTamper): { set: SetupObs; why: string } {
  const t = copySetup(s);
  const set = ([call, i]: [string, number], to: Outcome) => {
    const from = t.outcomes[call]![i]!;
    t.outcomes[call]![i] = to;
    return `${call} result ${i + 1} ${from} reported as ${to}`;
  };
  switch (kind) {
    case "outcome-as-local":
      return { set: t, why: set(findOutcome(t, (o) => o !== "local"), "local") };
    case "local-as-remote":
      return { set: t, why: set(findOutcome(t, (o) => o === "local"), "remote") };
    case "refused-as-remote":
      return { set: t, why: set(findOutcome(t, (o) => o === "refused"), "remote") };
    case "extra-prompt":
      t.prompts += 1;
      t.writes += 1;
      t.answers.push("accept");
      return { set: t, why: "one more prompt, accepted and written" };
    case "prompt-after-decline": {
      const at = t.answers.findIndex((a) => MARKING_ANSWERS.includes(a));
      if (at < 0) throw new FixtureError("prompt-after-decline needs a decline");
      t.answers.splice(at + 1, 0, "accept");
      t.prompts += 1;
      t.writes += 1;
      const why = set(findOutcome(t, (o) => o === "refused", true), "remote");
      return { set: t, why: `a prompt after the ${t.answers[at]}, accepted; ${why}` };
    }
    case "write-without-accept":
      t.writes += 1;
      return { set: t, why: "a config write without an accept" };
    case "p2-skipped": {
      // A team accept, then no project prompt: the config is written anyway.
      const at = t.answers.indexOf("team_accept");
      if (at < 0 || at + 1 >= t.answers.length) {
        throw new FixtureError("p2-skipped needs a team accept followed by a project answer");
      }
      t.answers.splice(at + 1, 1);
      t.prompts -= 1;
      t.writes += 1;
      return { set: t, why: "the project prompt after the team accept is skipped, and the config is written" };
    }
    case "prompt-without-channel": {
      t.prompts += 1;
      t.writes += 1;
      t.answers.push("accept");
      const why = set(findOutcome(t, (o) => o === "refused"), "remote");
      return { set: t, why: `a prompt without a prompt channel, accepted; ${why}` };
    }
  }
}

function tamperRun(r: RunObs, kind: RunTamper): { set: RunObs; why: string } {
  const e = [...r.events];
  const at = (event: RunEvent) => {
    const i = e.indexOf(event);
    if (i < 0) throw new FixtureError(`${kind} needs a ${event} event`);
    return i;
  };
  switch (kind) {
    case "resend-after-unknown":
      e.splice(at("no_id") + 1, 0, "send_ran");
      return { set: { events: e }, why: "a second send after an unknown start" };
    case "resend-after-close":
      e[at("reattach_ok")] = "send_ran";
      return { set: { events: e }, why: "a second send in place of the reattach" };
    case "resend-without-resume":
      e.splice(at("resumed"), 1);
      return { set: { events: e }, why: "the exec sent again after its 410, with no resume first" };
    case "overwrite-mac":
      e[at("bring_back_kept")] = "bring_back_written";
      return { set: { events: e }, why: "bring back wrote over the Mac edit" };
    case "exit-without-kill":
      e.splice(at("kill_sent"), 1);
      return { set: { events: e }, why: "a stop exit without the remote kill" };
    case "stop-before-id":
      e.splice(at("id_arrives"), 1);
      e.splice(at("kill_sent"), 1);
      return { set: { events: e }, why: "a stop exit while the id was still awaited" };
    case "early-bring-back": {
      const end = at("stream_end");
      e.splice(end, 1);
      e.splice(at("cmd_exits"), 0, "stream_end");
      return { set: { events: e }, why: "the stream ended before the command exited" };
    }
    case "exit-code-lie": {
      const lie: Record<string, RunEvent> = { exit_125: "exit_cmd", exit_255: "exit_125", exit_143: "exit_cmd", exit_cmd: "exit_255" };
      const last = e.at(-1)!;
      if (!lie[last]) throw new FixtureError("exit-code-lie needs an exit event last");
      e[e.length - 1] = lie[last]!;
      return { set: { events: e }, why: `${last} reported as ${lie[last]}` };
    }
  }
}

// ---------------------------------------------------------------------------
// TLC.

const str = (value: string) => `"${value}"`;
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const tuple = (items: string[]) => `<<${items.join(", ")}>>`;

function perCall(calls: string[], value: (call: string) => string): string {
  return `[c \\in {${calls.map(str).join(", ")}} |-> CASE ${calls.map((c) => `c = ${str(c)} -> ${value(c)}`).join(" [] ")}]`;
}

function setupModule(s: SetupObs): string {
  const calls = Object.keys(s.calls).sort();
  const lines = [
    "------------------------- MODULE RunnerSetupObserved -------------------------",
    "\\* Generated by tests/tla/drivers/runner/driver.ts.",
    `ObsReq == ${perCall(calls, (c) => str(s.calls[c]!.req))}`,
    `ObsRule == ${perCall(calls, (c) => str(s.calls[c]!.rule))}`,
    `ObsFloor == ${perCall(calls, (c) => str(s.calls[c]!.floor))}`,
    `ObsSurface == ${str(s.surface)}`,
    `ObsLogin == ${str(s.login)}`,
    `ObsConfigured == ${bool(s.configured)}`,
    `ObsConfigValid == ${bool(s.configValid)}`,
    `ObsTeams == ${str(s.teams)}`,
    `ObsAnswers == ${tuple(s.answers.map(str))}`,
    `ObsCancels == ${perCall(calls, (c) => String(s.cancels[c] ?? 0))}`,
    `ObsRetries == ${perCall(calls, (c) => String(s.retries[c] ?? 0))}`,
    `ObsNewTurns == ${s.newTurns}`,
    `ObsLoginTo == ${str(s.loginChange?.to ?? "unchanged")}`,
    `ObsLoginBefore == ${str(s.loginChange?.before ?? "any")}`,
    `ObsOutcomes == ${perCall(calls, (c) => tuple(s.outcomes[c]!.map(str)))}`,
    `ObsPrompts == ${s.prompts}`,
    `ObsWrites == ${s.writes}`,
    "=============================================================================",
    "",
  ];
  return lines.join("\n");
}

function setupCfg(s: SetupObs): string {
  const calls = Object.keys(s.calls).sort();
  const subs = calls.filter((c) => s.calls[c]!.sub);
  return [
    "INIT TraceInit",
    "NEXT TraceStep",
    "CONSTANTS",
    `    Calls = {${calls.map(str).join(", ")}}`,
    `    SubCalls = {${subs.map(str).join(", ")}}`,
    `    Requests = {"none", "local", "remote"}`,
    `    MaxAttempts = ${Math.max(0, ...Object.values(s.retries))}`,
    `    MaxTurns = ${s.newTurns + 1}`,
    `    Bug = "none"`,
    "INVARIANT NotAllMatched",
    "",
  ].join("\n");
}

function runModule(r: RunObs): string {
  return [
    "-------------------------- MODULE RemoteRunObserved --------------------------",
    "\\* Generated by tests/tla/drivers/runner/driver.ts.",
    `Observed == ${tuple(r.events.map(str))}`,
    "=============================================================================",
    "",
  ].join("\n");
}

function runCfg(r: RunObs): string {
  return [
    "INIT TraceInit",
    "NEXT TraceStep",
    "CONSTANTS",
    `    MaxMacEdits = ${r.events.filter((e) => e === "mac_edit").length}`,
    `    MaxCloses = ${r.events.filter((e) => e === "idle_close").length}`,
    `    Bug = "none"`,
    "INVARIANT NotAllMatched",
    "",
  ].join("\n");
}

class HarnessError extends Error {}

type Verdict = "ACCEPTED" | "REJECTED";

async function verdict(kind: "setup" | "run", set: SetupObs | RunObs, dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  const [module, specs] = kind === "setup"
    ? ["RunnerSetupTrace", ["RunnerSetup.tla", "RunnerSetupTrace.tla"]]
    : ["RemoteRunTrace", ["RemoteRun.tla", "RemoteRunTrace.tla"]];
  writeFileSync(join(dir, "observations.json"), `${JSON.stringify(set, null, 2)}\n`);
  if (kind === "setup") {
    writeFileSync(join(dir, "RunnerSetupObserved.tla"), setupModule(set as SetupObs));
    writeFileSync(join(dir, "trace.cfg"), setupCfg(set as SetupObs));
  } else {
    writeFileSync(join(dir, "RemoteRunObserved.tla"), runModule(set as RunObs));
    writeFileSync(join(dir, "trace.cfg"), runCfg(set as RunObs));
  }
  const run = await runTlc(dir, module, "trace.cfg", specs, SPEC_DIR, ["-deadlock"]);
  if (run.violated === "NotAllMatched") return "ACCEPTED";
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return "REJECTED";
  throw new HarnessError(`TLC failed on ${dir} (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
}

// ---------------------------------------------------------------------------
// Checks.

type Line = { order: number; text: string; ok: boolean };

type Job = { order: number; label: string; kind: "setup" | "run"; set: SetupObs | RunObs; want: Verdict; dir: string };

function jobsFor(f: Fixture, sets: { setup?: SetupObs; run?: RunObs }, out: string, first: number, tamper = true): Job[] {
  const jobs: Job[] = [];
  let order = first;
  for (const kind of ["setup", "run"] as const) {
    const set = sets[kind];
    if (!set) continue;
    jobs.push({ order: order++, label: `${f.name} ${kind}`, kind, set, want: "ACCEPTED", dir: join(out, f.name, kind) });
    if (!tamper) continue;
    const tampered = kind === "setup"
      ? tamperSetup(set as SetupObs, f.tamper.setup!)
      : tamperRun(set as RunObs, f.tamper.run!);
    jobs.push({
      order: order++,
      label: `${f.name} ${kind} tampered (${kind === "setup" ? f.tamper.setup : f.tamper.run}: ${tampered.why})`,
      kind,
      set: tampered.set,
      want: "REJECTED",
      dir: join(out, f.name, `${kind}-tampered`),
    });
  }
  return jobs;
}

async function runJobs(jobs: Job[], parallel: number): Promise<Line[]> {
  const lines: Line[] = [];
  let next = 0;
  const worker = async () => {
    while (next < jobs.length) {
      const job = jobs[next++]!;
      const got = await verdict(job.kind, job.set, job.dir);
      const ok = got === job.want;
      const line = { order: job.order, text: `${ok ? "ok  " : "MISS"} ${job.label}: ${got}${ok ? "" : `, want ${job.want}; see ${job.dir}`}`, ok };
      console.log(line.text);
      lines.push(line);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, parallel) }, worker));
  return lines.sort((a, b) => a.order - b.order);
}

function loadFixtures(only: string | null): Fixture[] {
  const files = readdirSync(FIXTURES).filter((name) => name.endsWith(".json")).sort();
  const fixtures = files.map((name) => parseFixture(join(FIXTURES, name)));
  return only ? fixtures.filter((f) => f.name.includes(only)) : fixtures;
}

function summarize(lines: Line[], started: number, out: string, extra: string[] = []): number {
  const accepted = lines.filter((l) => l.ok && l.text.includes("ACCEPTED")).length;
  const rejected = lines.filter((l) => l.ok && l.text.includes("REJECTED")).length;
  const missed = lines.filter((l) => !l.ok).length + extra.length;
  for (const problem of extra) console.log(`MISS ${problem}`);
  console.log(`${accepted} sets ACCEPTED, ${rejected} tampered sets REJECTED, ${missed} missed; ${missed === 0 ? "ok" : "FAIL"} in ${Math.round(performance.now() - started)} ms; output in ${out}`);
  return missed === 0 ? 0 : 1;
}

async function selfCheck(only: string | null, parallel: number): Promise<number> {
  const started = performance.now();
  const fixtures = loadFixtures(only);
  if (fixtures.length === 0) throw new FixtureError(`no fixtures${only ? ` match ${only}` : ""} in ${FIXTURES}`);
  const missing = only ? [] : REQUIRED_COVERAGE.filter((name) => !fixtures.some((f) => f.covers.includes(name)));
  const out = outDir("runner-self-check");
  const jobs: Job[] = [];
  for (const f of fixtures) jobs.push(...jobsFor(f, { setup: f.setup, run: f.run }, out, jobs.length));
  console.log(`self-check: ${fixtures.length} fixtures, ${jobs.length} TLC checks, ${parallel} at a time`);
  const lines = await runJobs(jobs, parallel);
  return summarize(lines, started, out, missing.map((name) => `no fixture covers ${name}`));
}

// ---------------------------------------------------------------------------
// --next: the built fx along the same scenarios.
//
// Written against the shell runner contracts (decide, admission, readiness
// and setup, the runner contract, the remote runner, errors E1 to E15 and
// notes N1 to N16, the config file, prompts P1 and P2). It needs
// src/core/runner/ and stops with a message without it.

const NEXT_MODEL = "openai/gpt-5.5";
const VALID_TOKEN = "fake-vercel-token-valid";
const OTHER_TOKEN = "fake-vercel-token-other";
// The token fx sends to a loopback test endpoint, whatever login it read (transport.zig test_token, AC-30).
const TEST_TOKEN = "fx-test-token";
const USER = { id: "user_fake_a", username: "example-a", email: "a@example.com" };
const OTHER_USER = { id: "user_fake_b", username: "example-b", email: "b@example.com" };
const HEADLESS_REFUSAL_MS = 5_000; // AC-7
const TURN_TIMEOUT_MS = 120_000;

type ToolResult = {
  id: string;
  call: string;
  turn: number;
  attempt: number;
  stop: boolean; // the result of the stop of this attempt
  text: string;
  json: Record<string, any> | null;
};

function nextBlocker(): string | null {
  if (!existsSync(join(worktree, "src", "core", "runner"))) {
    return "src/core/runner/ is not in this checkout: the runner code these models describe has not landed";
  }
  if (!existsSync(binary)) return `missing ${binary}; run zig build first or set FX_BIN`;
  return null;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

/// The shell results in one gateway request body, by tool call id.
function toolResults(body: string): Map<string, string> {
  const results = new Map<string, string>();
  const prompt = (JSON.parse(body) as { prompt?: Array<{ content: unknown }> }).prompt ?? [];
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && typeof part.toolCallId === "string") results.set(part.toolCallId, contentText(part.output));
    }
  }
  return results;
}

function parseJson(text: string): Record<string, any> | null {
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

/// A shell call id: `<call>_t<turn>_a<attempt>`, and `_stop` for its stop.
function callId(call: string, turn: number, attempt: number) {
  return `${call}_t${turn}_a${attempt}`;
}

function parseCallId(id: string): { call: string; turn: number; attempt: number; stop: boolean } | null {
  const m = /^(c\d)_t(\d+)_a(\d+)(_stop)?$/.exec(id);
  return m ? { call: m[1]!, turn: Number(m[2]), attempt: Number(m[3]), stop: m[4] !== undefined } : null;
}

async function until(test: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (!test()) {
    if (Date.now() > deadline) return false;
    await Bun.sleep(20);
  }
  return true;
}

function marker(call: string) {
  return `: fx-runner-${call}`;
}

function commandFor(f: Fixture, call: string) {
  return `${marker(call)}; pwd; ${f.drive.command ?? "true"}`;
}

// The refusals: E1 to E15 start with this text, and N1, N2, N10, N11, N12 and
// N16 make the runner exit 125 with a `fx: did not run` line.
function refused(result: ToolResult): boolean {
  if (result.text.includes("fx did not run this command")) return true;
  if (result.json?.error?.executed === false) return true;
  return result.json?.exit_code === 125 && result.text.includes("fx: did not run");
}

/// Stops --next when the built fx's shell tool has no `runner` field with
/// experimental.sandbox_execution on (AC-1): a run would only measure main.
async function schemaBlocker(): Promise<string | null> {
  const { startDynamicFakeGateway, fakeGatewayFinalText } = await targetHelpers();
  const evalHelpers = await import(pathToFileURL(join(worktree, "tests", "evals", "eval-helpers.ts")).href);
  const home: string = evalHelpers.createIsolatedTestHome();
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    bodies.push(body);
    return fakeGatewayFinalText("schema probe done");
  }, { models: [{ id: NEXT_MODEL, type: "language", tags: ["tool-use"] }] });
  try {
    mkdirSync(join(home, ".fx"), { recursive: true });
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { sandbox_execution: true } }));
    const proc = Bun.spawn([binary, "ask", "--json", "--no-save", "Probe the shell schema."], {
      cwd: home,
      env: testEnvironment({
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-runner-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: NEXT_MODEL,
      }),
      stdout: "pipe",
      stderr: "pipe",
    });
    await proc.exited;
    const tools: Array<Record<string, unknown>> = bodies.length > 0 ? JSON.parse(bodies[0]!).tools ?? [] : [];
    const shell = tools.find((tool) => tool.name === "shell");
    if (!shell) return "the built fx sent no shell tool to the fake gateway";
    if (!JSON.stringify(shell).includes("\"runner\"")) {
      return "the built fx's shell tool has no runner field with experimental.sandbox_execution on";
    }
    return null;
  } finally {
    gateway.stop();
    evalHelpers.cleanupIsolatedTestHome(home);
  }
}

function sandboxConfig(f: Fixture, s: SetupObs, workspace: string): string {
  if (!s.configValid) return "{\"rules\": 3}\n";
  const calls = Object.keys(s.calls).sort();
  const floors = new Set(calls.map((c) => s.calls[c]!.floor));
  if (floors.size !== 1) throw new HarnessError(`${f.name}: --next runs one workspace, so every call needs the same floor`);
  const floor = [...floors][0]!;
  const config: Record<string, unknown> = {};
  const rules = calls.filter((c) => s.calls[c]!.rule !== "none")
    .map((c) => ({ command: commandFor(f, c), runner: s.calls[c]!.rule }));
  if (rules.length > 0) config.rules = rules;
  if (floor !== "none") config.workspaces = { [workspace]: floor };
  if (s.configured) {
    config.remote = {
      backend: "vercel",
      team_id: "team_fake_1",
      team_slug: "fake-one",
      project_id: "prj_fake_1",
      project_name: "fake-web",
      user_id: USER.id,
      confirmed_at: "2026-01-01T00:00:00Z",
    };
  }
  return `${JSON.stringify(config, null, 2)}\n`;
}

function writeLogin(home: string, login: Login) {
  // The Vercel CLI's auth.json in both places fx reads it (macOS and XDG).
  const places = [
    join(home, "Library", "Application Support", "com.vercel.cli"),
    join(home, ".local", "share", "com.vercel.cli"),
  ];
  for (const place of places) {
    rmSync(join(place, "auth.json"), { force: true });
    if (login === "none") continue;
    mkdirSync(place, { recursive: true });
    const expiresAt = login === "expired" ? Math.floor(Date.now() / 1000) - 3600 : Math.floor(Date.now() / 1000) + 86_400;
    writeFileSync(join(place, "auth.json"), JSON.stringify({ token: login === "other_user" ? OTHER_TOKEN : VALID_TOKEN, expiresAt }));
  }
}

/// A small ACP client: requests, the prompt loop, and answers to
/// elicitation/create and session/request_permission.
class Acp {
  private buffer = "";
  private waiters: Array<(line: string) => void> = [];
  private lines: string[] = [];
  stderr = "";
  constructor(private proc: ReturnType<typeof Bun.spawn>) {
    void (async () => {
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += new TextDecoder().decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) if (line.trim()) this.push(line);
      }
    })();
    void (async () => {
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += new TextDecoder().decode(chunk);
    })();
  }
  private push(line: string) {
    const waiter = this.waiters.shift();
    if (waiter) waiter(line);
    else this.lines.push(line);
  }
  send(message: object) {
    (this.proc.stdin as import("bun").FileSink).write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  }
  read(timeoutMs: number): Promise<any> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(JSON.parse(line));
    return new Promise((done, fail) => {
      const timer = setTimeout(() => fail(new HarnessError("ACP read timed out")), timeoutMs);
      this.waiters.push((value) => { clearTimeout(timer); done(JSON.parse(value)); });
    });
  }
  async request(id: number, method: string, params: object, onMessage: (m: any) => void = () => {}): Promise<any> {
    this.send({ id, method, params });
    const deadline = Date.now() + TURN_TIMEOUT_MS;
    for (;;) {
      const message = await this.read(Math.max(1, deadline - Date.now()));
      if (message.id === id && message.method === undefined) return message;
      onMessage(message);
    }
  }
  close() {
    this.proc.kill("SIGTERM");
  }
}

type NextObservation = { setup?: SetupObs; run?: RunObs; problems: string[] };

async function driveScenario(f: Fixture, dir: string): Promise<NextObservation> {
  const s = f.setup;
  const { startDynamicFakeGateway, fakeGatewaySse, fakeGatewayFinalText } = await targetHelpers();
  const evalHelpers = await import(pathToFileURL(join(worktree, "tests", "evals", "eval-helpers.ts")).href);
  const { startFakeVercelApi } = await import(pathToFileURL(join(worktree, "tests", "e2e", "fixtures", "fake-vercel-api.ts")).href);
  // The real path, so the pwd a local run prints matches it.
  const home: string = realpathSync(evalHelpers.createIsolatedTestHome());
  const workspace = join(home, "work", "repo");
  mkdirSync(join(home, ".fx", "sandbox"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  const problems: string[] = [];
  const file = f.drive.file ? join(workspace, f.drive.file) : null;
  const pushed = "mac version 0\n";
  if (file) writeFileSync(file, pushed);
  const surface: Surface = s?.surface ?? "interactive";
  const calls = s ? Object.keys(s.calls).sort() : ["c1"];
  const inputs: Record<string, CallInput> = s?.calls ?? { c1: { req: "remote", rule: "none", floor: "none", sub: false } };
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    experimental: { sandbox_execution: true },
    permission_mode: "full-access",
  }));
  const configPath = join(home, ".fx", "sandbox", "config.json");
  writeFileSync(configPath, s ? sandboxConfig(f, s, workspace) : sandboxConfig(f, {
    calls: inputs, surface, login: "valid", configured: true, configValid: true, answers: [], cancels: {}, retries: {},
    newTurns: 0, loginChange: null, outcomes: { c1: ["remote"] }, prompts: 0, writes: 0,
  }, workspace), { mode: 0o600 });
  writeLogin(home, s?.login ?? "valid");

  let loginChanged = false;
  const teams = Array.from({ length: f.drive.teams ?? 1 }, (_, i) => ({ id: `team_fake_${i + 1}`, slug: `fake-${i + 1}`, name: `Fake ${i + 1}` }));
  const api = startFakeVercelApi({
    users: { [VALID_TOKEN]: USER, [OTHER_TOKEN]: OTHER_USER, [TEST_TOKEN]: (s?.login ?? "valid") === "other_user" ? OTHER_USER : USER },
    teams,
    projects: { team_fake_1: [{ id: "prj_fake_1", name: "fake-web" }] },
    privateRoot: join(home, "vercel-private"),
    macRoots: [workspace],
    // A login change "before" a call lands after fx checked the login and
    // before the runner reads it again (V1).
    afterRequest: (entry: { route: string }) => {
      if (s?.loginChange && !loginChanged && entry.route === "user") {
        loginChanged = true;
        writeLogin(home, s.loginChange.to);
      }
    },
  });
  Object.assign(api.faults, f.drive.faults ?? {});

  // Where each call is in the script, by turn.
  let turn = 1;
  const answersLeft = [...(s?.answers ?? [])];
  const answered: Answer[] = [];
  let prompts = 0;
  const cancelsLeft: Record<string, number> = { ...(s?.cancels ?? {}) };
  const cancels: Record<string, number> = Object.fromEntries(calls.map((c) => [c, 0]));
  // ACP only: fx's own status for each tool call, the stop reason of each prompt,
  // and each call the driver cancelled, with the turn it was cancelled in.
  const toolStatus = new Map<string, string>();
  const stopReasons = new Map<number, string>();
  const cancelledAt: Array<{ call: string; turn: number }> = [];
  const configSnapshots: string[] = [readFileSync(configPath, "utf8")];
  const snapshotConfig = () => {
    const now = existsSync(configPath) ? readFileSync(configPath, "utf8") : "";
    if (now !== configSnapshots.at(-1)) configSnapshots.push(now);
  };
  let stopAt: number | null = null;
  let cmdEditAt: number | null = null;
  let macEditAt: number | null = null;
  const results = new Map<string, ToolResult>();

  const shellCall = (call: string, attempt: number) => ({
    type: "tool-call",
    toolCallId: callId(call, turn, attempt),
    toolName: "shell",
    input: {
      request: {
        action: "run",
        command: commandFor(f, call),
        ...(inputs[call]!.req === "none" ? {} : { runner: inputs[call]!.req }),
        yield_time_ms: f.drive.stop ? 0 : 60_000,
      },
    },
  });
  const finishToolCalls = { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } };

  const gateway = startDynamicFakeGateway(async (body: string) => {
    snapshotConfig();
    const seen = toolResults(body);
    for (const [id, text] of seen) {
      const parsed = parseCallId(id);
      if (parsed && !results.has(id)) results.set(id, { id, ...parsed, text, json: parseJson(text) });
    }
    // A scenario with no sub-agent call has no child. The subagent tool is not
    // advertised on every surface, so its absence does not mark a child.
    const isChild = calls.some((c) => inputs[c]!.sub) && !body.includes("\"name\":\"subagent\"");
    const mine = calls.filter((c) => inputs[c]!.sub === isChild);
    if (!isChild && calls.some((c) => inputs[c]!.sub)) {
      const delegate = `sub_t${turn}`;
      if (!seen.has(delegate)) {
        return fakeGatewaySse([{
          type: "tool-call",
          toolCallId: delegate,
          toolName: "subagent",
          input: { request: { action: "message", agent: "runner-child", message: "Run the shell command you are given." } },
        }, finishToolCalls]);
      }
    }
    // The first attempts of this turn go out together, in one response.
    const first = mine.filter((c) => !seen.has(callId(c, turn, 0)));
    if (first.length === mine.length && first.length > 0) return fakeGatewaySse([...first.map((c) => shellCall(c, 0)), finishToolCalls]);
    for (const c of mine) {
      for (let attempt = 0; ; attempt += 1) {
        const id = callId(c, turn, attempt);
        if (!seen.has(id)) break;
        const result = results.get(id)!;
        if (f.drive.stop && result.json?.state === "running" && !seen.has(`${id}_stop`)) {
          // A stop while the runner awaits the id stops once the exec request
          // reached the fake (`stopWhenExecSent`: its command line is held back).
          // Any other stop waits until the fake sent the command line, so the
          // id is out before the stop.
          const reached = f.drive.stopWhenExecSent
            ? await until(() => api.log.some((e: any) => e.kind === "exec"), 30_000)
            : await until(() => api.log.some((e: any) => e.kind === "exec" && e.notes.includes("command line sent")), 30_000);
          if (!reached) problems.push("the command never reached the runner before the stop");
          stopAt = Date.now();
          return fakeGatewaySse([{
            type: "tool-call",
            toolCallId: `${id}_stop`,
            toolName: "shell",
            input: { request: { action: "stop", session_id: result.json.session_id } },
          }, finishToolCalls]);
        }
        if (refused(result) && attempt < (s?.retries[c] ?? 0) && !seen.has(callId(c, turn, attempt + 1))) {
          return fakeGatewaySse([shellCall(c, attempt + 1), finishToolCalls]);
        }
      }
    }
    return fakeGatewayFinalText(`turn ${turn} done`);
  }, { models: [{ id: NEXT_MODEL, type: "language", tags: ["tool-use"] }] });

  const env = testEnvironment({
    HOME: home,
    XDG_DATA_HOME: join(home, ".local", "share"),
    AI_GATEWAY_API_KEY: "fake-runner-key",
    VERCEL_OIDC_TOKEN: "",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_VERCEL_API_URL: api.url,
    FX_MODEL: NEXT_MODEL,
  });

  // Watch the remote and Mac copies of the file while the run goes on (AC-12).
  const watcher = setInterval(() => {
    if (!file || cmdEditAt !== null) return;
    const remote = api.remotePath(file);
    if (existsSync(remote) && readFileSync(remote, "utf8") !== pushed) {
      cmdEditAt = Date.now();
      if (f.drive.macEdit) {
        writeFileSync(file, "mac version 1\n");
        macEditAt = Date.now();
      }
    }
  }, 20);

  let headlessMs = 0;
  try {
    if (surface === "headless") {
      const started = Date.now();
      const proc = Bun.spawn([binary, "ask", "--json", "--no-save", "Run the runner fixture."], {
        cwd: workspace, env, stdout: "pipe", stderr: "pipe",
      });
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
      ]);
      headlessMs = Date.now() - started;
      writeFileSync(join(dir, "fx-ask.log"), `exit ${exitCode}\n${stdout}\n[stderr]\n${stderr}\n`);
    } else {
      const acp = new Acp(Bun.spawn([binary, "acp"], { cwd: workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
      const onMessage = (m: any) => {
        if (m.method === "session/request_permission" && m.id !== undefined) {
          acp.send({ id: m.id, result: { outcome: { outcome: "selected", optionId: "allow_once" } } });
        }
        if (m.method === "session/update" && m.params?.update?.sessionUpdate === "tool_call_update") {
          const update = m.params.update;
          if (typeof update.toolCallId === "string" && typeof update.status === "string") toolStatus.set(update.toolCallId, update.status);
        }
        if (m.method !== "elicitation/create" || m.id === undefined) return;
        snapshotConfig();
        const message = String(m.params?.message ?? "");
        if (!message.startsWith("fx asks: ")) problems.push(`elicitation without the fx asks prefix: ${message}`);
        const isTeam = message.includes("Which Vercel team");
        prompts += 1;
        const pending = calls.find((c) => (cancelsLeft[c] ?? 0) > 0);
        if (pending) {
          cancelsLeft[pending]! -= 1;
          cancels[pending]! += 1;
          cancelledAt.push({ call: pending, turn });
          acp.send({ method: "session/cancel", params: { sessionId: m.params?.sessionId } });
          return;
        }
        const answer = answersLeft.shift();
        if (answer === undefined) {
          problems.push(`an elicitation with no scripted answer: ${message}`);
          acp.send({ id: m.id, result: { action: "cancel" } });
          return;
        }
        if (answer === "no_answer") throw new HarnessError("no_answer waits 15 minutes; --next does not drive it");
        const kindAnswers: readonly string[] = isTeam ? TEAM_PROMPT_ANSWERS : PROJECT_PROMPT_ANSWERS;
        if (!kindAnswers.includes(answer)) {
          problems.push(`the ${isTeam ? "team" : "project"} prompt was scripted ${answer}`);
          acp.send({ id: m.id, result: { action: "cancel" } });
          return;
        }
        answered.push(answer);
        if (answer === "decline" || answer === "cancel") {
          acp.send({ id: m.id, result: { action: answer } });
          return;
        }
        const schema = m.params?.requestedSchema?.properties ?? {};
        const field = isTeam ? "team" : "project";
        const options: Array<{ const: string }> = schema[field]?.oneOf ?? [];
        const content: Record<string, string> = { [field]: options[0]?.const ?? "__create__" };
        // rest_fail: the client picks "Another project" and types a name the fake does not know (U6, E9).
        // The product reads the typed name only when that choice is picked (setup_host.zig:595).
        if (answer === "rest_fail" && !isTeam) {
          content.project = "__other__";
          content.other_project = "fx-missing-project";
        }
        acp.send({ id: m.id, result: { action: "accept", content } });
      };
      try {
        await acp.request(1, "initialize", { protocolVersion: 1, clientCapabilities: { elicitation: { form: {} } } });
        const created = await acp.request(2, "session/new", { cwd: workspace, mcpServers: [] });
        if (created.error) throw new HarnessError(`session/new failed: ${JSON.stringify(created.error)}`);
        for (; turn <= (s?.newTurns ?? 0) + 1; turn += 1) {
          const reply = await acp.request(10 + turn, "session/prompt", {
            sessionId: created.result.sessionId,
            prompt: [{ type: "text", text: `Run the runner fixture, turn ${turn}.` }],
          }, onMessage);
          stopReasons.set(turn, String(reply.result?.stopReason ?? ""));
        }
        turn -= 1;
      } finally {
        writeFileSync(join(dir, "fx-acp.stderr"), acp.stderr);
        acp.close();
      }
    }
  } finally {
    clearInterval(watcher);
    snapshotConfig();
    gateway.stop();
  }
  writeFileSync(join(dir, "vercel-log.json"), `${JSON.stringify(api.log, null, 2)}\n`);
  writeFileSync(join(dir, "results.json"), `${JSON.stringify([...results.values()], null, 2)}\n`);

  const commands: Array<any> = api.commands();
  // Where a call ran, from positive evidence only: its exec in the fake, or
  // the local workspace path that its pwd printed.
  const whereRan = (result: ToolResult): Outcome => {
    if (result.json?.error?.executed === false) {
      problems.push(`${result.id} was refused as an invalid request: ${result.text}`);
      return "refused";
    }
    if (refused(result)) return "refused";
    const ran = commands.find((cmd) => cmd.kind === "exec" && cmd.args.join(" ").includes(marker(result.call)));
    if (ran) return ran.sandbox.startsWith("fx-iso-") ? "isolated" : "remote";
    // A local run prints its own pwd. The floor notice names the workspace too,
    // so only the command's output counts as evidence.
    const output = String(result.json?.output_delta ?? "");
    if (output.includes(workspace) && !output.includes(api.remotePath(workspace))) return "local";
    problems.push(`${result.id}: cannot tell where it ran: ${result.text.slice(0, 200)}`);
    return "refused";
  };

  // A call the driver cancelled while its prompt was open returns no tool result.
  // fx's own status for the call decides; with none, the turn's cancelled stop
  // reason does. A cancelled call never ran, so the model's outcome is refused.
  const canceledOutcome = (cancel: { call: string; turn: number }): Outcome | null => {
    const prefix = `${cancel.call}_t${cancel.turn}_`;
    const statuses = [...toolStatus.entries()].filter(([id]) => id.startsWith(prefix)).map(([, status]) => status);
    if (statuses.some((status) => status === "failed" || status === "canceled")) return "refused";
    if (stopReasons.get(cancel.turn) === "cancelled") return "refused";
    problems.push(`${cancel.call}: cancelled in turn ${cancel.turn}, with no tool status or cancelled stop reason`);
    return null;
  };

  let setup: SetupObs | undefined;
  if (s) {
    const outcomes: Record<string, Outcome[]> = Object.fromEntries(calls.map((c) => [c, [] as Outcome[]]));
    const ordered = [...results.values()].filter((r) => !r.stop && r.json?.state !== "running").sort((a, b) => a.turn - b.turn || a.attempt - b.attempt);
    const placed: Array<{ call: string; turn: number; attempt: number; outcome: Outcome }> = ordered.map((r) => ({
      call: r.call, turn: r.turn, attempt: r.attempt, outcome: whereRan(r),
    }));
    for (const cancel of cancelledAt) {
      const outcome = canceledOutcome(cancel);
      if (outcome !== null) placed.push({ call: cancel.call, turn: cancel.turn, attempt: -1, outcome });
    }
    placed.sort((a, b) => a.turn - b.turn || a.attempt - b.attempt);
    for (const item of placed) outcomes[item.call]!.push(item.outcome);
    const retries = Object.fromEntries(calls.map((c) => [c, Math.max(0, ...ordered.filter((r) => r.call === c).map((r) => r.attempt))]));
    if (surface === "headless" && headlessMs > HEADLESS_REFUSAL_MS && Object.values(outcomes).flat().every((o) => o === "refused")) {
      problems.push(`headless refusal took ${headlessMs} ms, over ${HEADLESS_REFUSAL_MS} ms (AC-7)`);
    }
    setup = {
      ...s,
      answers: answered,
      cancels,
      retries,
      newTurns: turn - 1,
      loginChange: s.loginChange && loginChanged ? s.loginChange : null,
      outcomes,
      prompts: surface === "headless" ? 0 : prompts,
      writes: configSnapshots.length - 1,
    };
  }

  let run: RunObs | undefined;
  if (f.run) {
    run = { events: remoteRunEvents(f, api, commands, [...results.values()], { stopAt, cmdEditAt, macEditAt, file, remoteFile: file ? api.remotePath(file) : null, pushed }) };
  }
  api.stop();
  evalHelpers.cleanupIsolatedTestHome(home);
  return { setup, run, problems };
}

/// The remote run's events from the fake API's log, its commands, the
/// driver's own actions and the final tool result, in time order. Times are
/// Date.now() values; the log's count from the fake's start.
function remoteRunEvents(
  f: Fixture,
  api: { startedAt: number; log: Array<any> },
  commands: Array<any>,
  results: ToolResult[],
  seen: { stopAt: number | null; cmdEditAt: number | null; macEditAt: number | null; file: string | null; remoteFile: string | null; pushed: string },
): RunEvent[] {
  const timed: Array<{ at: number; rank: number; event: RunEvent }> = [];
  const add = (at: number, rank: number, event: RunEvent) => timed.push({ at, rank, event });
  const when = (entry: { at: number }) => api.startedAt + entry.at;
  const end = Date.now();
  const final = results.filter((r) => !r.stop).at(-1);
  const stopResult = results.find((r) => r.stop);
  const exitCode = (stopResult ?? final)?.json?.exit_code;
  const log = api.log;
  const exec = log.find((entry) => entry.kind === "exec");
  const execCmd = exec ? commands.find((cmd) => cmd.id === exec.commandId) : undefined;
  if (seen.stopAt !== null) add(seen.stopAt, 3, "stop_requested");
  if (!exec) {
    // Nothing reached the sandbox as the command: a failed step before the
    // exec (N1, N2), a stop before the send, or a request that failed before
    // it was fully sent.
    const failure = log.find((entry) => entry.status !== null && entry.status >= 400 &&
      ["createSandbox", "getSandbox", "write", "cmd"].includes(entry.route));
    if (exitCode === 143) add(end, 20, "stop_before_send");
    else if (failure) add(when(failure), 1, "push_failed");
    else {
      add(end - 1, 1, "push_ok");
      add(end, 2, "send_failed");
    }
  } else {
    add(when(exec) - 0.5, 1, "push_ok");
    const dropped = exec.notes.find((note: string) => note.startsWith("fault: dropped"));
    add(when(exec), 2, dropped && dropped.includes("not_run") ? "send_not_run" : "send_ran");
    const held = Number(f.drive.faults?.delayCommandLineMs) || 0;
    if (dropped) add(end - 1, 4, "no_id");
    else add(when(exec) + held + 1, 4, "id_arrives");
    // The watcher samples every 20 ms, so a command that writes and exits within
    // one sample is seen after its exit, or not at all. The command's write came
    // before its exit, so an edit seen once the command has exited is placed just
    // before the exit.
    const remoteEdited = seen.remoteFile !== null && existsSync(seen.remoteFile) &&
      readFileSync(seen.remoteFile, "utf8") !== seen.pushed;
    const exitedAt = execCmd?.status === "exited" && execCmd.endedAt !== null ? execCmd.endedAt - 0.5 : null;
    const editAt = seen.cmdEditAt !== null
      ? (exitedAt !== null ? Math.min(seen.cmdEditAt, exitedAt) : seen.cmdEditAt)
      : (remoteEdited ? exitedAt : null);
    if (editAt !== null) add(editAt, 5, "cmd_edits");
    if (seen.macEditAt !== null) add(seen.macEditAt, 6, "mac_edit");
    const idle = exec.notes.find((note: string) => note.startsWith("idle close"));
    const logs = log.filter((entry) => entry.route === "cmdLogs" && entry.commandId === exec.commandId);
    if (idle) {
      add(logs[0] ? when(logs[0]) - 0.5 : end - 2, 7, "idle_close");
      if (logs[0]?.status === 200) add(when(logs[0]), 8, "reattach_ok");
      else if (exitCode === 255) add(end - 1, 8, "reattach_lost");
    }
    const kill = log.find((entry) => entry.route === "kill" && entry.commandId === exec.commandId);
    if (kill) add(when(kill), 9, "kill_sent");
    if (execCmd?.status === "exited" && execCmd.endedAt !== null && exitCode !== 143) add(execCmd.endedAt, 10, "cmd_exits");
    if (exitCode === 143) add(end, 20, "stop_exit");
    const back = log.find((entry) => entry.kind === "bring_back");
    if (back && exitCode !== 143) {
      add(when(back) - 0.5, 11, "stream_end");
      const mac = seen.file && existsSync(seen.file) ? readFileSync(seen.file, "utf8") : seen.pushed;
      const kept = final?.text.includes("fx: kept your version of") ?? false;
      add(when(back), 12, kept ? "bring_back_kept" : mac !== seen.pushed ? "bring_back_written" : "bring_back_nothing");
    }
  }
  timed.sort((a, b) => a.at - b.at || a.rank - b.rank);
  const events = timed.map((t) => t.event);
  events.push(exitCode === 125 ? "exit_125" : exitCode === 143 ? "exit_143" : exitCode === 255 ? "exit_255" : "exit_cmd");
  return events;
}

async function next(only: string | null, parallel: number): Promise<number> {
  const blocker = nextBlocker() ?? await schemaBlocker();
  if (blocker) {
    console.error(`--next stopped: ${blocker}. Nothing ran. --self-check checks the models without it.`);
    return 2;
  }
  const started = performance.now();
  const fixtures = loadFixtures(only);
  const out = outDir("runner-next");
  const lines: Line[] = [];
  const problems: string[] = [];
  for (const f of fixtures) {
    const dir = join(out, f.name, "fx");
    mkdirSync(dir, { recursive: true });
    const observed = await driveScenario(f, dir);
    problems.push(...observed.problems.map((p) => `${f.name}: ${p}`));
    const sets = { setup: observed.setup, run: observed.run };
    let jobs: Job[];
    try {
      jobs = jobsFor(f, sets, out, lines.length);
    } catch (error) {
      // The run did not record an event this fixture's tampered check needs.
      // The fixture is missed with that reason, and its accepted checks still run.
      if (!(error instanceof FixtureError)) throw error;
      problems.push(`${f.name}: the tampered check cannot run: ${error.message}`);
      jobs = jobsFor(f, sets, out, lines.length, false);
    }
    lines.push(...await runJobs(jobs, parallel));
  }
  return summarize(lines, started, out, problems);
}

// ---------------------------------------------------------------------------

function option(name: string): string | null {
  const at = process.argv.indexOf(name);
  return at < 0 ? null : process.argv[at + 1] ?? null;
}

const mode = process.argv.includes("--next") ? "next" : process.argv.includes("--self-check") ? "self-check" : null;
if (!mode) {
  console.error("usage: bun tests/tla/drivers/runner/driver.ts --self-check | --next [--only NAME] [--jobs N]");
  process.exit(2);
}
const jobsOption = Number(option("--jobs") ?? "4");
if (!Number.isInteger(jobsOption) || jobsOption < 1) {
  console.error("--jobs takes a whole number above 0");
  process.exit(2);
}
try {
  process.exit(mode === "next" ? await next(option("--only"), jobsOption) : await selfCheck(option("--only"), jobsOption));
} catch (error) {
  if (error instanceof FixtureError || error instanceof HarnessError) {
    console.error(`${error instanceof FixtureError ? "fixture error" : "harness error"}: ${error.message}`);
    process.exit(2);
  }
  throw error;
}
