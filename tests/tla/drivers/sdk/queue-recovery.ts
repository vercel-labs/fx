#!/usr/bin/env bun
// Drives the real SDK and world-local through restarts of an app that keeps
// libfx sessions and its own Workflow SDK runs in one World, and has TLC
// check each scenario's trace against tests/tla/sdk/QueueRecovery.tla
// through QueueRecoveryTrace.tla, with the fix's constants.
//
//   bun tests/tla/drivers/sdk/queue-recovery.ts                     # every named edge case
//   bun tests/tla/drivers/sdk/queue-recovery.ts --scenario crash    # one of them
//   bun tests/tla/drivers/sdk/queue-recovery.ts --fuzz 20 --seed 7  # seeded random scenarios, races included
//   bun tests/tla/drivers/sdk/queue-recovery.ts --sessions 300      # one restart over 300 sessions
//
// Each process of a scenario is a Node child, recovery-process.mjs, on one
// data folder: the app's first process creates sessions and app runs, and
// each later one starts the World again, as a restarted app does, with a
// stand-in for the Workflow SDK on the World's default queue
// (sdk/tests/restarted-world.mjs). A crash child is killed with SIGKILL
// mid-turn. A fake clock in each restarted child lets world-local make every
// redelivery it would make, so the trace holds them all. Nothing here starts
// fx or reaches the network.
//
// Each scenario's events, observed module, and TLC log go to a folder under
// FX_TLA_OUT or the system temp folder. Exits 1 when TLC rejects a trace.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Plan = {
  first?: boolean;
  recover?: boolean;
  namespace?: string;
  lateAgent?: boolean;
  race?: boolean;
  sessions?: number;
  appRuns?: number;
  crash?: boolean;
  // How many earlier sessions get a turn once the World started, from the
  // first, or all of them; a session a crash left open is resumed instead.
  turns?: number | "all";
};
type Scenario = { name: string; agent: string; processes: Plan[] };
type Event = {
  op: string;
  runId?: string;
  kind?: string;
  ns?: string;
  agents?: string;
  recover?: boolean;
  queued?: { runId: string; topic: string }[];
  consumer?: string;
  outcome?: string;
  status?: string;
};

const args = process.argv.slice(2);
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const child = join(import.meta.dirname, "recovery-process.mjs");
const node = Bun.which("node");
if (!node) {
  console.error("queue-recovery.ts runs each process in Node, and no node is on PATH");
  process.exit(2);
}
const specDir = join(TLA_ROOT, "sdk");

const named: Scenario[] = [
  { name: "default-agent", agent: "default", processes: [{ first: true, sessions: 1 }, { turns: "all" }] },
  { name: "named-agents", agent: "ops", processes: [{ first: true, sessions: 1 }, { turns: "all" }] },
  { name: "crash", agent: "default", processes: [{ first: true, sessions: 1, crash: true }, { turns: "all" }] },
  { name: "app-runs", agent: "default", processes: [{ first: true, sessions: 1, appRuns: 2 }, { turns: "all" }] },
  { name: "namespace-env", agent: "default", processes: [{ first: true, sessions: 1, appRuns: 1 }, { namespace: "app", turns: "all" }] },
  { name: "two-restarts", agent: "ops", processes: [{ first: true, sessions: 2 }, { turns: "all" }, { turns: "all" }] },
  { name: "own-world", agent: "default", processes: [{ first: true, sessions: 1 }, { recover: false, turns: "all" }] },
  { name: "late-agent", agent: "ops", processes: [{ first: true, sessions: 1 }, { lateAgent: true, turns: "all" }] },
  { name: "race", agent: "default", processes: [{ first: true, sessions: 2 }, { race: true, sessions: 2, turns: "all" }] },
];

// mulberry32: the same scenarios for the same seed.
function random(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fuzzScenarios(count: number, seed: number): Scenario[] {
  const next = random(seed);
  const pick = (n: number) => Math.floor(next() * n);
  return Array.from({ length: count }, (_, index) => {
    const processes: Plan[] = [{ first: true, sessions: 1 + pick(3), appRuns: pick(3), crash: next() < 0.3 }];
    for (let restart = 1 + pick(3); restart > 0; restart -= 1) {
      processes.push({
        recover: next() < 0.85,
        ...(next() < 0.2 ? { namespace: "app" } : {}),
        lateAgent: next() < 0.2,
        race: next() < 0.4,
        sessions: pick(3),
        turns: next() < 0.6 ? "all" : pick(2),
      });
    }
    return { name: `fuzz-${seed}-${index}`, agent: next() < 0.5 ? "default" : "ops", processes };
  });
}

function stressScenario(sessions: number): Scenario {
  return {
    name: `stress-${sessions}`,
    agent: "default",
    processes: [{ first: true, sessions, appRuns: Math.ceil(sessions / 10) }, { turns: 3 }],
  };
}

// Runs one process of a scenario to its end, or until it is ready to be
// killed, and returns its events.
async function runProcess(plan: Plan & Record<string, unknown>, log: string): Promise<Event[]> {
  const planFile = log.replace(/\.log$/, ".plan.json");
  writeJson(planFile, plan);
  const home = mkdtempSync(join(tmpdir(), "fx-tla-recovery-home-"));
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "",
    HOME: home,
    TMPDIR: process.env.TMPDIR ?? tmpdir(),
    FX_HOME: home,
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
  };
  const proc = Bun.spawn([node as string, child, planFile], { env, stdout: "pipe", stderr: Bun.file(log) });
  const events: Event[] = [];
  let buffered = "";
  const timer = setTimeout(() => proc.kill(9), 180_000);
  try {
    for await (const chunk of proc.stdout as unknown as AsyncIterable<Uint8Array>) {
      buffered += new TextDecoder().decode(chunk);
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        const event = JSON.parse(buffered.slice(0, index)) as Event;
        buffered = buffered.slice(index + 1);
        if (event.op === "ready") {
          proc.kill(9);
          continue;
        }
        events.push(event);
      }
    }
    const code = await proc.exited;
    if (!plan.crash && code !== 0) throw new Error(`recovery-process.mjs exited ${code}; see ${log}`);
    if (!plan.crash && events.at(-1)?.op !== "end") throw new Error(`recovery-process.mjs stopped early; see ${log}`);
    return events.filter((event) => event.op !== "end");
  } finally {
    clearTimeout(timer);
    rmSync(home, { recursive: true, force: true });
  }
}

const tla = (value: unknown): string => {
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (value instanceof Set) return `{${[...value].map(tla).join(", ")}}`;
  if (Array.isArray(value)) return `<<${value.map(tla).join(", ")}>>`;
  return `[${Object.entries(value as Record<string, unknown>).map(([key, field]) => `${key} |-> ${tla(field)}`).join(", ")}]`;
};

async function runScenario(scenario: Scenario, root: string) {
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(join(tmpdir(), `fx-tla-recovery-${scenario.name}-`));
  const events: Event[] = [];
  const sessions: string[] = [];
  const crashed: string[] = [];
  try {
    for (const [index, plan] of scenario.processes.entries()) {
      const open = new Set(crashed);
      const settled = sessions.filter((runId) => !open.has(runId));
      const turns = plan.turns === "all" ? settled : settled.slice(0, plan.turns ?? 0);
      const known = events.filter((event) => event.op === "create").map((event) => event.runId as string);
      const seen = await runProcess({
        ...plan,
        dir,
        agent: scenario.agent,
        turns,
        resume: crashed.splice(0),
        known,
      } as Plan & Record<string, unknown>, join(root, `process-${index}.log`));
      for (const event of seen) {
        if (event.op === "create" && event.kind === "libfx") sessions.push(event.runId as string);
      }
      if (plan.crash) {
        const last = seen.filter((event) => event.op === "create").at(-1);
        if (last?.runId) crashed.push(last.runId);
      }
      events.push(...seen);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  writeJson(join(root, "events.json"), events);

  // Each run by a name the model uses: s<n> for a libfx session, w<n> for
  // an app run, in the order the World created them.
  const alias = new Map<string, string>();
  const libfx: string[] = [];
  const app: string[] = [];
  for (const event of events) {
    if (event.op !== "create" || alias.has(event.runId as string)) continue;
    const list = event.kind === "app" ? app : libfx;
    list.push(`${event.kind === "app" ? "w" : "s"}${list.length + 1}`);
    alias.set(event.runId as string, list.at(-1) as string);
  }
  const name = (runId?: string) => (runId ? (alias.get(runId) ?? `unknown:${runId}`) : "none");
  const observed = events.map((event) => ({
    op: event.op,
    run: name(event.runId),
    ns: event.ns ?? "none",
    agents: event.agents ?? "default",
    recover: event.recover ?? false,
    queued: new Set((event.queued ?? []).map((message) => ({ run: name(message.runId), topic: message.topic }))),
    consumer: event.consumer ?? "none",
    outcome: event.outcome ?? "none",
    status: event.status ?? "none",
  }));
  const restarts = events.filter((event) => event.op === "restart").length;
  writeFileSync(join(root, "QueueRecoveryObserved.tla"), [
    "------------------------ MODULE QueueRecoveryObserved ------------------------",
    `\\* Generated by tests/tla/drivers/sdk/queue-recovery.ts for ${scenario.name}.`,
    `ObsLibfxRuns == ${tla(new Set(libfx))}`,
    `ObsAppRuns == ${tla(new Set(app))}`,
    `ObsRestarts == ${restarts}`,
    `Observed == <<\n  ${observed.map(tla).join(",\n  ")}\n>>`,
    "=============================================================================",
    "",
  ].join("\n"));
  writeFileSync(join(root, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "    LibfxRuns <- ObsLibfxRuns",
    "    AppRuns <- ObsAppRuns",
    "    MaxRestarts <- ObsRestarts",
    "    RecordNamespace = TRUE",
    "    AckBare = TRUE",
    "    MaxAttempts = 256",
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  const run = await runTlc(root, "QueueRecoveryTrace.tla", "trace.cfg", ["QueueRecovery.tla", "QueueRecoveryTrace.tla"], specDir);
  const accepted = run.violated === "NotAllMatched";
  // Where a rejected trace stopped: the last k TLC reached.
  const reached = [...run.output.matchAll(/\bk = (\d+)/g)].map((match) => Number(match[1])).reduce((a, b) => Math.max(a, b), 1);
  const stuck = accepted ? null : observed[reached - 1] ?? null;
  return { accepted, events: observed.length, restarts, sessions: libfx.length, appRuns: app.length, stuck };
}

const fuzz = option("--fuzz");
const sessions = option("--sessions");
const only = option("--scenario");
const seed = Number(option("--seed") ?? "1");
const scenarios = fuzz
  ? fuzzScenarios(Number(fuzz), seed)
  : sessions
    ? [stressScenario(Number(sessions))]
    : named.filter((scenario) => !only || scenario.name === only);
if (scenarios.length === 0) {
  console.error(`no scenario named ${only}; the named ones are ${named.map((scenario) => scenario.name).join(", ")}`);
  process.exit(2);
}

const out = outDir("queue-recovery");
console.log(`output: ${out}`);
let rejected = 0;
for (const scenario of scenarios) {
  const root = join(out, scenario.name);
  const started = performance.now();
  const result = await runScenario(scenario, root);
  writeJson(join(root, "result.json"), { scenario, ...result });
  const took = ((performance.now() - started) / 1000).toFixed(1);
  if (result.accepted) {
    console.log(`ACCEPTED ${scenario.name}: ${result.events} events, ${result.sessions} sessions, ${result.appRuns} app runs, ${result.restarts} restarts (${took}s)`);
  } else {
    rejected += 1;
    console.log(`REJECTED ${scenario.name}: the model cannot take ${JSON.stringify(result.stuck, (_key, value) => (value instanceof Set ? [...value] : value))} (${took}s; see ${root})`);
  }
}
console.log(`${scenarios.length - rejected}/${scenarios.length} scenarios accepted`);
process.exit(rejected ? 1 : 0);
