// The agent-wait gate, run by verify.ts in the same run as the file-change gate.
// In order, and every stage must pass:
//
//   1. TLC on AgentWait.tla with agent-design.cfg, which also writes the state
//      graph, and the pinned TLC version;
//   2. the harness, built from the real managed execution and subagent host in
//      a copy of src/;
//   3. spec to code: every distinct step of the graph replayed on the harness,
//      and the state after each step compared with the model's;
//   4. code to spec: scenarios and random walks with faults, checked by TLC
//      against TraceAgentWait.tla;
//   5. the bridge grace, timed: after a wait ends, a yield lands after the
//      grace and within the window (agent-timing.ts);
//   6. every planted bug in agent-mutations.json built into its own copy of
//      src/, and caught by code to spec: its named property fails alone and
//      the full trace check fails.
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { runTlc } from "../lib/tlc.ts";
import { PINNED_TLC_VERSION } from "../mcp_call/lib.ts";
import { MODEL_DIR, buildAgentHarness, loadAgentGraph, type AgentGraph } from "./agent-lib.ts";
import { aloneConfig, codeToSpec, type AgentCodeToSpecResult } from "./agent-traces.ts";
import { specToCode, type WalkResult } from "./agent-walk.ts";
import { BRIDGE_GRACE_MS, YIELD_WINDOW_MS, graceProblems, yieldAfterHold, type GraceRun } from "./agent-timing.ts";

export type AgentStage = { name: string; ok: boolean; summary: string };
export type AgentGateReport = { stages: AgentStage[]; details: Record<string, unknown> };
type Mutation = { id: string; breaks: string; file: string; find: string; replace: string; expect: string };

const MAX_TRACE_LENGTH = 40;
const FAULT_RATE = 0.2;
const GRACE_RUNS = 3;

function finalCounts(output: string) {
  const match = /^(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.$/m.exec(output);
  return { generated: Number(match?.[1] ?? NaN), distinct: Number(match?.[2] ?? NaN), left: Number(match?.[3] ?? NaN) };
}

export async function runAgentGate(options: { quick: boolean; seed: number; out: string }): Promise<AgentGateReport> {
  const { quick, seed, out } = options;
  const randomTraces = Number(process.env.FX_TLA_TOOL_BRIDGE_TRACES ?? (quick ? "30" : "150"));
  const mutantTraces = quick ? 30 : 60;
  const stages: AgentStage[] = [];
  const details: Record<string, unknown> = { seed, randomTraces, quick, out };
  const stage = (name: string, ok: boolean, summary: string) => {
    stages.push({ name, ok, summary });
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  };
  const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

  let graph: AgentGraph | null = null;
  let bin = "";
  try {
    const modelDir = join(out, "model");
    let at = performance.now();
    const model = await runTlc(modelDir, "AgentWait", "agent-design.cfg", ["AgentWait.tla", "agent-design.cfg"], MODEL_DIR, [
      "-dump", "dot,actionlabels", join(modelDir, "graph"),
    ]);
    const counts = finalCounts(model.output);
    const pinned = new RegExp(PINNED_TLC_VERSION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(model.output);
    const passed = model.exitCode === 0 && /Model checking completed\. No error has been found\./.test(model.output) && counts.left === 0;
    details.model = { ...counts, exitCode: model.exitCode, durationMs: model.durationMs };
    stage("agent model check", passed && pinned, `agent-design: ${counts.distinct} distinct of ${counts.generated} generated states, ${elapsed(at)}`);
    if (!passed || !pinned) throw new Error("TLC did not pass agent-design");

    at = performance.now();
    graph = loadAgentGraph(join(modelDir, "graph.dot"));
    details.graph = { states: graph.shapes.size, edges: graph.edges, transitions: graph.transitions };
    stage("agent graph", true, `${graph.shapes.size} states, ${graph.edges} edges, ${graph.transitions} distinct steps, ${elapsed(at)}`);

    at = performance.now();
    bin = await buildAgentHarness(join(out, "harness"));
    stage("agent harness", true, `built from src/ with the real managed execution and subagent host in ${elapsed(at)}`);

    at = performance.now();
    const sweep: WalkResult = await specToCode(bin, graph, (n) => join(out, "homes", "walk", String(n)));
    details.specToCode = sweep;
    stage("agent spec to code", sweep.failure === null && sweep.taken === sweep.transitions,
      sweep.failure
        ? `the code left the model after ${sweep.failure.path.slice(-4).join(" > ")}: expected ${sweep.failure.expected}, shown ${sweep.failure.shown}, notes ${JSON.stringify(sweep.failure.notes)}`
        : `${sweep.taken} of ${sweep.transitions} distinct steps, ${sweep.steps} steps, ${sweep.restarts} restarts, ${elapsed(at)}`);
    if (sweep.failure) throw new Error("agent spec to code failed");

    at = performance.now();
    const traces: AgentCodeToSpecResult = await codeToSpec({
      bin, dir: join(out, "traces"), graph, seed, randomTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
    });
    details.codeToSpec = { traces: traces.traces, steps: traces.steps, scenarios: traces.scenarios, tlc: traces.tlc.verdict, property: traces.tlc.property, tracesPath: traces.tracesPath };
    stage("agent code to spec", traces.tlc.verdict === "pass",
      `${traces.scenarios} scenarios and ${randomTraces} random traces, ${traces.steps} steps, TLC ${traces.tlc.verdict}${traces.tlc.property ? ` (${traces.tlc.property})` : ""}, ${elapsed(at)}`);
    if (traces.tlc.verdict !== "pass") throw new Error("agent code to spec failed");

    at = performance.now();
    const grace: GraceRun[] = [];
    for (let n = 1; n <= GRACE_RUNS; n += 1) grace.push(await yieldAfterHold(bin, join(out, "grace", String(n))));
    details.grace = grace;
    const problems = grace.flatMap((run, index) => graceProblems(run).map((problem) => `run ${index + 1}: ${problem}`));
    stage("agent bridge grace", problems.length === 0,
      problems.length === 0
        ? `yield after the hold dropped in ${grace.map((run) => run.delayMs).join(", ")} ms, grace ${BRIDGE_GRACE_MS} ms, window ${YIELD_WINDOW_MS} ms, ${elapsed(at)}`
        : problems.join("; "));
    if (problems.length > 0) throw new Error("agent bridge grace failed");

    const mutations = JSON.parse(readFileSync(join(MODEL_DIR, "agent-mutations.json"), "utf8")) as Mutation[];
    const results: Record<string, unknown>[] = [];
    at = performance.now();
    for (const mutation of mutations) {
      const work = join(out, "mutants", mutation.id);
      const planted = await buildAgentHarness(work, { file: mutation.file, find: mutation.find, replace: mutation.replace });
      const walk = await specToCode(planted, graph, (n) => join(work, "homes", "walk", String(n)), {
        maxSteps: quick ? 600 : undefined,
      });
      const alone = await codeToSpec({
        bin: planted, dir: join(work, "alone"), graph, seed, randomTraces: mutantTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
        cfgName: "Single.cfg", cfgText: aloneConfig(mutation.expect),
      });
      const full = await codeToSpec({
        bin: planted, dir: join(work, "full"), graph, seed, randomTraces: mutantTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
      });
      const caught = alone.tlc.verdict === "violated" && alone.tlc.property === mutation.expect && full.tlc.verdict === "violated";
      const result = {
        id: mutation.id,
        breaks: mutation.breaks,
        expect: mutation.expect,
        caught,
        specToCode: walk.failure
          ? `left the model after ${walk.failure.path.slice(-3).join(" > ")}`
          : walk.taken === walk.transitions ? "no step left the model" : `no step left the model in ${walk.steps} steps`,
        alone: alone.tlc.property ?? alone.tlc.verdict,
        full: full.tlc.property ?? full.tlc.verdict,
      };
      results.push(result);
      console.log(`  ${caught ? "caught" : "MISSED"} ${mutation.id} by ${mutation.expect}: alone ${result.alone}, full ${result.full}; spec to code ${result.specToCode}`);
    }
    details.mutants = results;
    stage("agent planted bugs", results.every((r) => r.caught), `${results.filter((r) => r.caught).length} of ${results.length} caught, ${elapsed(at)}`);
  } catch (error) {
    stage("agent gate", false, (error as Error).message);
  }
  return { stages, details };
}
