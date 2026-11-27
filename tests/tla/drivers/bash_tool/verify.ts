// `bun tests/tla/drivers/bash_tool/verify.ts` (run through tests/tla/bash_tool/check.sh):
// the one gate for the bash tool's result store. In order, and every stage must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on the two-program instances (result-store-small-room2.cfg and -room1.cfg), which also write their state graphs;
//   3. the harness, built from the real result files, bash results, and program output in a copy of src/;
//   4. spec to code: every distinct step of each instance's graph replayed on the harness, and the state after each step compared with the model's;
//   5. code to spec: the three named scenarios and random walks, checked by TLC against the three-program ResultStore in TraceResultStore.tla, and each witness reached by its own scenario;
//   6. every planted bug in mutations.json built into its own copy of src/, and caught by code to spec: its named property fails alone and the full trace check fails.
//
// Why two programs in stage 4: the three-program design (result-store.cfg) has
// 10,845,949 distinct states and about 28 million generated states, too many for a walk. Each
// witness needs three programs, so stage 5 checks the three-program rules on
// recorded runs instead. check.sh's TLC verdicts still check the design itself.
//
// Settings: FX_TLA_BASH_TOOL_QUICK=1 (fewer random traces, and fewer steps for the planted bugs),
// FX_TLA_BASH_TOOL_SEED (default 20261126), FX_TLA_BASH_TOOL_TRACES, and FX_TLA_OUT (where the report goes).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { outDir, runTlc, writeJson } from "../lib/tlc.ts";
import { PINNED_TLC_VERSION, pinnedToolchain } from "../mcp_call/lib.ts";
import { MODEL_DIR, TWO_PROGRAMS, buildHarness, loadGraph, shapeOf, type Graph } from "./lib.ts";
import { FULL, ORPHAN, RESUME, SCENARIOS, aloneConfig, baseConfig, checkRuns, recordRuns, witnessConfig, type TraceRun } from "./traces.ts";
import { specToCode, type WalkResult } from "./walk.ts";

type Mutation = { id: string; breaks: string; file: string; find: string; replace: string; expect: string };
type Stage = { name: string; ok: boolean; summary: string };
export type GateReport = {
  ok: boolean;
  failures: string[];
  stages: Stage[];
  details: Record<string, unknown>;
};

/// The two-program instances the walk takes every distinct step of. Together they
/// have every kind of step: room for two files, and a folder that is full.
const INSTANCES = [
  { name: "result-store-small-room2", room: 2 },
  { name: "result-store-small-room1", room: 1 },
];

const MAX_TRACE_LENGTH = 40;
const FAULT_RATE = 0.2;
/// Steps a planted bug's walk takes in quick mode; its traces decide the catch.
const QUICK_MUTANT_STEPS = 2000;

/// Each witness and the named scenario that must reach it.
const WITNESSES = [
  { witness: "OrphanWitness", scenario: ORPHAN },
  { witness: "FullWitness", scenario: FULL },
  { witness: "ResumeWitness", scenario: RESUME },
];

function finalCounts(output: string) {
  const match = /^(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.$/m.exec(output);
  return { generated: Number(match?.[1] ?? NaN), distinct: Number(match?.[2] ?? NaN), left: Number(match?.[3] ?? NaN) };
}

/// How many different three-program states the recorded runs showed.
function distinctStates(runs: TraceRun[]): number {
  const seen = new Set<string>();
  for (const run of runs) for (const state of run.states) seen.add(shapeOf(state));
  return seen.size;
}

export async function runGate(options: { quick: boolean }): Promise<GateReport> {
  const quick = options.quick;
  const seed = Number(process.env.FX_TLA_BASH_TOOL_SEED ?? "20261126");
  const randomTraces = Number(process.env.FX_TLA_BASH_TOOL_TRACES ?? (quick ? "60" : "300"));
  const mutantTraces = quick ? 60 : 150;
  const out = outDir("bash-tool");
  const stages: Stage[] = [];
  const details: Record<string, unknown> = { seed, randomTraces, quick, out };
  const stage = (name: string, ok: boolean, summary: string) => {
    stages.push({ name, ok, summary });
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  };
  const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;
  const started = performance.now();

  let graphs: { name: string; graph: Graph }[] = [];
  let bin = "";
  try {
    const toolchain = pinnedToolchain();
    details.toolchain = toolchain;
    stage("toolchain", true, `tla2tools.jar sha256 ${toolchain.jarSha256.slice(0, 12)}, ${toolchain.javaVersion}`);

    let at = performance.now();
    const modelDir = join(out, "model");
    const checks = [];
    for (const { name, room } of INSTANCES) {
      const dir = join(modelDir, name);
      const model = await runTlc(dir, "ResultStore", `${name}.cfg`, ["ResultStore.tla", `${name}.cfg`], MODEL_DIR, [
        "-dump", "dot,actionlabels", join(dir, "graph"),
      ]);
      const counts = finalCounts(model.output);
      const passed = model.exitCode === 0 && /Model checking completed\. No error has been found\./.test(model.output) && counts.left === 0;
      checks.push({ name, room, ...counts, passed, exitCode: model.exitCode, durationMs: model.durationMs, dir });
    }
    const pinned = new RegExp(PINNED_TLC_VERSION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(
      readFileSync(join(modelDir, INSTANCES[0]!.name, "tlc.log"), "utf8"),
    );
    details.model = checks.map(({ dir: _dir, ...rest }) => rest);
    const allPassed = checks.every((c) => c.passed) && pinned;
    stage("model check", allPassed,
      checks.map((c) => `${c.name}: ${c.distinct} distinct of ${c.generated} generated states${c.passed ? "" : " (not passed)"}`).join("; ") + `, ${elapsed(at)}`);
    if (!allPassed) throw new Error("TLC did not pass the two-program instances");

    at = performance.now();
    graphs = checks.map((c) => ({ name: c.name, graph: loadGraph(join(c.dir, "graph.dot"), TWO_PROGRAMS, c.room) }));
    details.graphs = graphs.map(({ name, graph }) => ({ name, states: graph.shapes.size, edges: graph.edges, transitions: graph.transitions }));
    stage("graph", true, graphs.map(({ name, graph }) => `${name}: ${graph.shapes.size} states, ${graph.transitions} distinct steps`).join("; ") + `, ${elapsed(at)}`);

    at = performance.now();
    bin = await buildHarness(join(out, "harness"));
    stage("harness", true, `built from src/ with the real result files, bash results, and program output in ${elapsed(at)}`);

    at = performance.now();
    const sweeps: Record<string, WalkResult> = {};
    for (const { name, graph } of graphs) {
      sweeps[name] = await specToCode(bin, graph, join(out, "walk", name));
    }
    details.specToCode = sweeps;
    const failed = Object.entries(sweeps).find(([, sweep]) => sweep.failure !== null);
    const covered = Object.values(sweeps).every((sweep) => sweep.taken === sweep.transitions);
    stage("spec to code", covered && !failed,
      failed
        ? `${failed[0]} left the model after ${failed[1].failure!.path.join(" > ")}: expected ${failed[1].failure!.expected}, shown ${failed[1].failure!.shown}`
        : Object.entries(sweeps).map(([name, sweep]) => `${name}: ${sweep.taken} of ${sweep.transitions} distinct steps, ${sweep.steps} steps, ${sweep.resets} resets`).join("; ") + `, ${elapsed(at)}`);
    if (failed || !covered) throw new Error("spec to code failed");

    at = performance.now();
    const recorded = await recordRuns({
      bin, dir: join(out, "traces"), seed, randomTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
    });
    const tlc = await checkRuns(out, "traces-check", recorded.runs, "TraceResultStore.cfg", baseConfig());
    const visited = distinctStates(recorded.runs);
    details.codeToSpec = {
      runs: recorded.runs.length,
      steps: recorded.steps,
      scenarios: Object.keys(SCENARIOS).length,
      distinctStates: visited,
      tlc: tlc.verdict,
      property: tlc.property,
      tracesPath: recorded.path,
    };
    stage("code to spec", tlc.verdict === "pass",
      `${Object.keys(SCENARIOS).length} scenarios and ${randomTraces} random traces, ${recorded.steps} steps, ${visited} distinct states shown, TLC ${tlc.verdict}${tlc.property ? ` (${tlc.property})` : ""}, ${elapsed(at)}`);
    if (tlc.verdict !== "pass") throw new Error("code to spec failed");

    at = performance.now();
    const witnesses = [];
    for (const { witness, scenario } of WITNESSES) {
      const runs = recorded.runs.filter((run) => run.name === scenario);
      const check = await checkRuns(out, `witness-${witness}`, runs, `${witness}.cfg`, witnessConfig(witness));
      witnesses.push({ witness, reached: check.verdict === "violated" && check.property === witness, verdict: check.verdict, property: check.property });
    }
    details.witnesses = witnesses;
    stage("witnesses", witnesses.every((w) => w.reached),
      `${witnesses.filter((w) => w.reached).length} of ${witnesses.length} witnesses reached by their scenarios, ${elapsed(at)}`);
    if (!witnesses.every((w) => w.reached)) throw new Error("a witness was not reached");

    const mutations = JSON.parse(readFileSync(join(MODEL_DIR, "mutations.json"), "utf8")) as Mutation[];
    const results: Record<string, unknown>[] = [];
    at = performance.now();
    for (const mutation of mutations) {
      const work = join(out, "mutants", mutation.id);
      const planted = await buildHarness(work, { file: mutation.file, find: mutation.find, replace: mutation.replace });
      const walks: WalkResult[] = [];
      for (const { name, graph } of graphs) {
        walks.push(await specToCode(planted, graph, join(work, "walk", name), {
          maxSteps: quick ? QUICK_MUTANT_STEPS : undefined,
        }));
      }
      const walk = walks.find((w) => w.failure !== null) ?? walks[0]!;
      const runs = await recordRuns({
        bin: planted, dir: join(work, "traces"), seed, randomTraces: mutantTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
      });
      const alone = await checkRuns(work, "alone", runs.runs, "Single.cfg", aloneConfig(mutation.expect));
      const full = await checkRuns(work, "full", runs.runs, "TraceResultStore.cfg", baseConfig());
      const caught = alone.verdict === "violated" && alone.property === mutation.expect && full.verdict === "violated";
      const result = {
        id: mutation.id,
        breaks: mutation.breaks,
        expect: mutation.expect,
        caught,
        specToCode: walk.failure
          ? `left the model after ${walk.failure.path.slice(-3).join(" > ")}`
          : walk.taken === walk.transitions ? "no step left the model" : `no step left the model in ${walk.steps} steps`,
        alone: alone.property ?? alone.verdict,
        full: full.property ?? full.verdict,
      };
      results.push(result);
      console.log(`  ${caught ? "caught" : "MISSED"} ${mutation.id} by ${mutation.expect}: alone ${result.alone}, full ${result.full}; spec to code ${result.specToCode}`);
    }
    details.mutants = results;
    stage("planted bugs", results.every((r) => r.caught), `${results.filter((r) => r.caught).length} of ${results.length} caught, ${elapsed(at)}`);
  } catch (error) {
    stage("gate", false, (error as Error).message);
  }

  const failures = stages.filter((s) => !s.ok).map((s) => s.name);
  details.durationMs = Math.round(performance.now() - started);
  writeJson(join(out, "report.json"), { stages, details, failures });
  console.log(`${failures.length === 0 ? "gate passed" : `gate failed: ${failures.join(", ")}`} in ${elapsed(started)}; report ${join(out, "report.json")}`);
  return { ok: failures.length === 0, failures, stages, details };
}

if (import.meta.main) {
  const report = await runGate({ quick: process.env.FX_TLA_BASH_TOOL_QUICK === "1" });
  process.exitCode = report.ok ? 0 : 1;
}
