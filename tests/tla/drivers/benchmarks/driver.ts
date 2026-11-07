// Runs the real benchmarks/startup.sh along
// tests/tla/benchmarks/StartupFixture.tla and has TLC check every run it
// observes (StartupFixtureTrace.tla).
//
// Each scenario is one run of the script in its own TMPDIR, through run.ts: a
// folder planted at the old PID path, a planted folder with another fixture
// name, early exits (no fx binary, no hyperfine), a read-only, missing, or
// file TMPDIR, a normal run with the real hyperfine and the built fx, SIGTERM
// and SIGKILL at hyperfine's first call, and a run in the TMPDIR a SIGKILLed
// run left. The driver names each fixture folder as the model does: "pid" for
// the run's own PID path, "decoy" for a folder that was there before, and
// "fresh" for one the run made. TLC replays the runs through the model's
// script actions.
//
// --self-check also replays them through the model of the script before the
// change (Bug = "today"), which must reject them, and runs every scenario
// again on each planted bug in run.ts MUTANTS, whose runs the model must
// reject.
//
// Usage (from the repository root, after zig build, with hyperfine installed):
//   bun tests/tla/drivers/benchmarks/driver.ts
//   bun tests/tla/drivers/benchmarks/driver.ts --self-check
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain or harness failure.
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";
import { MUTANTS, PREFIX, type Hyperfine, type RunResult, folderOf, fxBinary, plant, realHyperfine, runStartup } from "./run";

type Scenario = {
  id: string;
  plantPid?: boolean;
  decoy?: boolean; // plant fx-session-list-benchmark.decoy0
  readOnly?: boolean;
  tmpdir?: "dir" | "slash" | "missing" | "file";
  binary?: boolean;
  hyperfine?: Hyperfine;
  reaches?: boolean; // the run must reach hyperfine, or the scenario proves nothing
  inTmpdirOf?: string; // run in the TMPDIR an earlier scenario left
};

const SCENARIOS: Scenario[] = [
  { id: "early-no-binary-pid", plantPid: true },
  { id: "early-no-binary" },
  { id: "early-no-binary-pid-decoy", plantPid: true, decoy: true },
  { id: "early-no-binary-pid-slash", plantPid: true, tmpdir: "slash" },
  { id: "early-no-hyperfine-pid", plantPid: true, binary: true, hyperfine: "missing" },
  { id: "readonly-pid", plantPid: true, readOnly: true },
  { id: "missing-tmpdir", tmpdir: "missing" },
  { id: "file-tmpdir", tmpdir: "file" },
  { id: "normal-pid-decoy", plantPid: true, decoy: true, binary: true, reaches: true },
  { id: "sigterm-pid-decoy", plantPid: true, decoy: true, binary: true, hyperfine: "sigterm", reaches: true },
  { id: "sigkill", binary: true, hyperfine: "sigkill", reaches: true },
  { id: "after-sigkill-pid", plantPid: true, inTmpdirOf: "sigkill" },
];

type Observation = {
  id: string;
  foreign: string[];
  usable: boolean;
  ended: "finished" | "failed" | "signal" | "killed";
  during: string[] | null;
  root: string;
  after: string[];
  wiped: string[];
  evidence: { pid: number; code: number | null; signal: string | null; names: Record<string, string>; tail: string };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tlaDir = join(TLA_ROOT, "benchmarks");
const selfCheck = process.argv.includes("--self-check");

class Harness extends Error {}
// A run the model has no names for, such as one that made two folders.
class Unmodeled extends Error {}

function observe(scenario: Scenario, tmpdir: string, run: RunResult): Observation {
  if (run.gatewayRequests !== 0) {
    throw new Harness(`${scenario.id}: the fake gateway counted ${run.gatewayRequests} requests; expected 0`);
  }
  if (scenario.reaches && !run.during) {
    throw new Harness(`${scenario.id}: the run never reached hyperfine: ${(run.stdout + run.stderr).slice(-400)}`);
  }
  const names: Record<string, string> = {};
  const label = (name: string) => {
    const value = name === run.pidName ? "pid" : run.planted.includes(name) ? "decoy" : "fresh";
    if (names[value] !== undefined && names[value] !== name) {
      throw new Unmodeled(`${scenario.id}: both ${names[value]} and ${name} are "${value}"; the model holds one`);
    }
    names[value] = name;
    return value;
  };
  const labels = (list: string[]) => [...new Set(list.map(label))].sort();
  let ended: Observation["ended"] = "failed";
  if (run.code === 0) ended = "finished";
  else if (run.signal === "SIGKILL") ended = "killed";
  else if (run.signal === "SIGTERM" || run.code === 143) ended = "signal";
  let root = "";
  if (run.during) {
    const folder = folderOf(tmpdir, run.during.home);
    if (!folder || !folder.startsWith(PREFIX)) throw new Unmodeled(`${scenario.id}: HOME ${run.during.home} is not in a fixture folder`);
    root = label(folder);
  }
  const kind = scenario.tmpdir ?? "dir";
  const usable = (kind === "dir" || kind === "slash") && !(scenario.readOnly && run.readOnlyHeld);
  if (scenario.readOnly && !run.readOnlyHeld) console.log(`${scenario.id}: TMPDIR stayed writable (running as root?)`);
  return {
    id: scenario.id,
    foreign: labels(run.planted),
    usable,
    ended,
    during: run.during ? labels(run.during.names) : null,
    root,
    after: labels(run.after),
    wiped: labels(run.planted.filter((name) => !run.intact[name])),
    evidence: { pid: run.pid, code: run.code, signal: run.signal, names, tail: (run.stdout + run.stderr).slice(-300) },
  };
}

async function runScenarios(base: string, mutant: string): Promise<Observation[]> {
  const observations: Observation[] = [];
  const tmpdirs = new Map<string, string>();
  for (const scenario of SCENARIOS) {
    const scratch = mkdtempSync(join(base, `${scenario.id}-`));
    let tmpdir = tmpdirs.get(scenario.inTmpdirOf ?? "") ?? join(scratch, "tmp");
    if (!scenario.inTmpdirOf) {
      const kind = scenario.tmpdir ?? "dir";
      if (kind === "file") writeFileSync(tmpdir, "not a folder\n");
      if (kind === "dir" || kind === "slash") mkdirSync(tmpdir);
      if (kind === "slash") tmpdir = `${tmpdir}/`;
      if (scenario.decoy) plant(tmpdir, `${PREFIX}.decoy0`);
    }
    tmpdirs.set(scenario.id, tmpdir);
    const run = await runStartup({
      scratch,
      tmpdir,
      plantPid: scenario.plantPid,
      readOnly: scenario.readOnly,
      binary: scenario.binary,
      hyperfine: scenario.hyperfine ?? "real",
      mutant,
    });
    const observation = observe(scenario, tmpdir, run);
    observations.push(observation);
    console.log(`${mutant || "script"} ${scenario.id}: ${observation.ended}, foreign [${observation.foreign}], ` +
      `during ${observation.during ? `[${observation.during}] in ${observation.root}` : "-"}, ` +
      `after [${observation.after}], wiped [${observation.wiped}]`);
  }
  return observations;
}

const str = (value: string) => JSON.stringify(value);
const set = (values: string[]) => `{${values.map(str).join(", ")}}`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[foreign |-> ${set(o.foreign)}, usable |-> ${o.usable ? "TRUE" : "FALSE"}, ended |-> ${str(o.ended)}, ` +
    `during |-> ${o.during ? `<<${set(o.during)}>>` : "<<>>"}, root |-> ${str(o.root)}, ` +
    `after |-> ${set(o.after)}, wiped |-> ${set(o.wiped)}]`;
  return [
    "------------------------ MODULE StartupFixtureObserved ------------------------",
    "(* Generated by tests/tla/drivers/benchmarks/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function trace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  writeFileSync(join(dir, "StartupFixtureObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    `CONSTANT Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "StartupFixtureTrace.tla", "trace.cfg", ["StartupFixture.tla", "StartupFixtureTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// Each run starts from its own state, so each can be checked alone.
async function rejectedRuns(observations: Observation[], bug: string, parent: string): Promise<Observation[] | null> {
  const out: Observation[] = [];
  for (const observation of observations) {
    const { verdict } = await trace([observation], bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "REJECTED") out.push(observation);
  }
  return out;
}

async function main(): Promise<number> {
  if (!existsSync(fxBinary())) throw new Harness(`missing ${fxBinary()}; run zig build first or set FX_BIN`);
  if (!realHyperfine()) throw new Harness("hyperfine is not on PATH; the normal run needs it");
  const out = outDir("benchmarks");
  console.log(`output: ${out}`);
  const runs = join(out, "runs");
  mkdirSync(runs);
  const observations = await runScenarios(runs, "");
  writeJson(join(out, "observations.json"), observations);

  const design = await trace(observations, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const rejected = await rejectedRuns(observations, "none", out);
    for (const o of rejected ?? []) console.log(`the model cannot produce run ${o.id}: ${JSON.stringify(o)}`);
    return 1;
  }
  if (selfCheck) {
    const today = await trace(observations, "today", out);
    console.log(`self-check, the model of the script before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
    for (const mutant of Object.keys(MUTANTS)) {
      let verdict: Verdict;
      try {
        verdict = (await trace(await runScenarios(runs, mutant), "none", out)).verdict;
      } catch (error) {
        if (!(error instanceof Unmodeled)) throw error;
        console.log(`planted bug ${mutant}: ${error.message}`);
        verdict = "REJECTED";
      }
      console.log(`self-check, planted bug ${mutant}: ${verdict} (must be REJECTED)`);
      if (verdict !== "REJECTED") return verdict === "TOOL_ERROR" ? 2 : 1;
    }
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  if (error instanceof Unmodeled) {
    console.log(`REJECTED: ${error.message}`);
    process.exit(1);
  }
  console.error(error instanceof Harness ? `TOOL_ERROR: ${error.message}` : error);
  process.exit(2);
}
