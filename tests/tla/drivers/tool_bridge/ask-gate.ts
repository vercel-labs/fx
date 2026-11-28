// The ask-wait gate, run by verify.ts after the agent-wait gate.
// In order, and every stage must pass:
//
//   1. TLC on AskWait.tla with ask-design.cfg, which also writes the state
//      graph, and the pinned TLC version;
//   2. the harness, built from the real bridge, `runBridgeAsk`, `QuestionWatch`,
//      worker question slot, and `managed_execution` in a copy of src/;
//   3. spec to code: every distinct step of the graph replayed on the harness
//      across both initial states (`ui` TRUE and FALSE), and the state after
//      each step compared with the model's;
//   4. code to spec: scenarios and random walks with faults, checked by TLC
//      against TraceAskWait.tla;
//   5. every planted bug in ask-mutations.json built into its own copy of src/,
//      and caught by code to spec: its named property fails alone and the full
//      trace check fails.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc } from "../lib/tlc.ts";
import { PINNED_TLC_VERSION } from "../mcp_call/lib.ts";
import { MODEL_DIR, buildAskHarness, loadAskGraph, type AskGraph } from "./ask-lib.ts";
import { aloneConfig, codeToSpec, type AskCodeToSpecResult } from "./ask-traces.ts";
import { specToCode, type WalkResult } from "./ask-walk.ts";

export type AskStage = { name: string; ok: boolean; summary: string };
export type AskGateReport = { stages: AskStage[]; details: Record<string, unknown> };
type Mutation = { id: string; breaks: string; file: string; find: string; replace: string; expect: string };

const MAX_TRACE_LENGTH = 40;
const FAULT_RATE = 0.2;

function finalCounts(output: string) {
  const match = /^(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.$/m.exec(output);
  return { generated: Number(match?.[1] ?? NaN), distinct: Number(match?.[2] ?? NaN), left: Number(match?.[3] ?? NaN) };
}

export async function runAskGate(options: { quick: boolean; seed: number; out: string }): Promise<AskGateReport> {
  const { quick, seed, out } = options;
  const randomTraces = Number(process.env.FX_TLA_TOOL_BRIDGE_TRACES ?? (quick ? "30" : "150"));
  const mutantTraces = quick ? 20 : 60;
  const stages: AskStage[] = [];
  const details: Record<string, unknown> = { seed, randomTraces, quick, out };
  const stage = (name: string, ok: boolean, summary: string) => {
    stages.push({ name, ok, summary });
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  };
  const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

  let graph: AskGraph | null = null;
  let bin = "";
  try {
    const modelDir = join(out, "model");
    let at = performance.now();
    const model = await runTlc(modelDir, "AskWait", "ask-design.cfg", ["AskWait.tla", "ask-design.cfg"], MODEL_DIR, [
      "-dump", "dot,actionlabels", join(modelDir, "graph"),
    ]);
    const counts = finalCounts(model.output);
    const pinned = new RegExp(PINNED_TLC_VERSION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(model.output);
    const passed = model.exitCode === 0 && /Model checking completed\. No error has been found\./.test(model.output) && counts.left === 0;
    details.model = { ...counts, exitCode: model.exitCode, durationMs: model.durationMs };
    stage("ask model check", passed && pinned, `ask-design: ${counts.distinct} distinct of ${counts.generated} generated states, ${elapsed(at)}`);
    if (!passed || !pinned) throw new Error("TLC did not pass ask-design");

    at = performance.now();
    graph = loadAskGraph(join(modelDir, "graph.dot"));
    details.graph = { roots: graph.roots.length, states: graph.shapes.size, edges: graph.edges, transitions: graph.transitions };
    stage("ask graph", true, `${graph.shapes.size} states, ${graph.edges} edges, ${graph.transitions} distinct steps (${graph.roots.length} roots), ${elapsed(at)}`);

    at = performance.now();
    bin = await buildAskHarness(join(out, "harness"));
    stage("ask harness", true, `built from src/ with the real bridge, runBridgeAsk, worker slot, and managed execution in ${elapsed(at)}`);

    at = performance.now();
    const sweep: WalkResult = await specToCode(bin, graph, (n) => join(out, "homes", "walk", String(n)));
    details.specToCode = sweep;
    stage("ask spec to code", sweep.failure === null && sweep.taken === sweep.transitions,
      sweep.failure
        ? `the code left the model after ${sweep.failure.path.slice(-4).join(" > ")}: expected ${sweep.failure.expected}, shown ${sweep.failure.shown}, notes ${JSON.stringify(sweep.failure.notes)}`
        : `${sweep.taken} of ${sweep.transitions} distinct steps, ${sweep.steps} steps, ${sweep.restarts} restarts, ${elapsed(at)}`);
    if (sweep.failure) throw new Error("ask spec to code failed");

    at = performance.now();
    const traces: AskCodeToSpecResult = await codeToSpec({
      bin, dir: join(out, "traces"), graph, seed, randomTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
    });
    details.codeToSpec = { traces: traces.traces, steps: traces.steps, scenarios: traces.scenarios, tlc: traces.tlc.verdict, property: traces.tlc.property, tracesPath: traces.tracesPath };
    stage("ask code to spec", traces.tlc.verdict === "pass",
      `${traces.scenarios} scenarios and ${randomTraces} random traces, ${traces.steps} steps, TLC ${traces.tlc.verdict}${traces.tlc.property ? ` (${traces.tlc.property})` : ""}, ${elapsed(at)}`);
    if (traces.tlc.verdict !== "pass") throw new Error("ask code to spec failed");

    const mutations = JSON.parse(readFileSync(join(MODEL_DIR, "ask-mutations.json"), "utf8")) as Mutation[];
    const results: Record<string, unknown>[] = [];
    at = performance.now();
    for (const mutation of mutations) {
      const work = join(out, "mutants", mutation.id);
      const planted = await buildAskHarness(work, { file: mutation.file, find: mutation.find, replace: mutation.replace });
      const walk = await specToCode(planted, graph, (n) => join(work, "homes", "walk", String(n)), {
        maxSteps: quick ? 400 : undefined,
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
    stage("ask planted bugs", results.every((r) => r.caught), `${results.filter((r) => r.caught).length} of ${results.length} caught, ${elapsed(at)}`);
  } catch (error) {
    stage("ask gate", false, (error as Error).message);
  }
  return { stages, details };
}
