// `bun tests/tla/drivers/tool_bridge/verify.ts` (run through tests/tla/tool_bridge/check.sh):
// the one gate for the bash tool's file-change design. In order, and every stage
// must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on ToolEdit.tla with design-bridge.cfg, which also writes the state
//      graph;
//   3. the harness, built from the real bridge core, file change, and change
//      tracker in a copy of src/;
//   4. spec to code: every distinct step of the graph replayed on the harness,
//      and the state after each step compared with the model's;
//   5. code to spec: scripted cases and random walks with faults, checked by TLC
//      against TraceToolEdit.tla;
//   6. every planted bug in mutations.json built into its own copy of src/,
//      and caught by code to spec: its named property fails alone and the full
//      trace check fails.
//
// Settings: FX_TLA_TOOL_BRIDGE_QUICK=1 (fewer random traces, and fewer for the
// planted bugs), FX_TLA_TOOL_BRIDGE_SEED (default 20261125), FX_TLA_TOOL_BRIDGE_TRACES,
// and FX_TLA_OUT (where the report goes).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { outDir, runTlc, writeJson } from "../lib/tlc.ts";
import { PINNED_TLC_VERSION, pinnedToolchain } from "../mcp_call/lib.ts";
import { MODEL_DIR, buildHarness, loadGraph, type Graph } from "./lib.ts";
import { aloneConfig, codeToSpec, type CodeToSpecResult } from "./traces.ts";
import { specToCode, type WalkResult } from "./walk.ts";
import { runAgentGate } from "./agent-gate.ts";

type Mutation = { id: string; breaks: string; file: string; find: string; replace: string; expect: string };
type Stage = { name: string; ok: boolean; summary: string };
export type GateReport = {
  ok: boolean;
  failures: string[];
  stages: Stage[];
  details: Record<string, unknown>;
};

const MAX_TRACE_LENGTH = 40;
const FAULT_RATE = 0.2;
/// Steps a planted bug's walk takes in quick mode; its traces decide the catch.
const QUICK_MUTANT_STEPS = 2000;

function finalCounts(output: string) {
  const match = /^(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.$/m.exec(output);
  return { generated: Number(match?.[1] ?? NaN), distinct: Number(match?.[2] ?? NaN), left: Number(match?.[3] ?? NaN) };
}

export async function runGate(options: { quick: boolean }): Promise<GateReport> {
  const quick = options.quick;
  const seed = Number(process.env.FX_TLA_TOOL_BRIDGE_SEED ?? "20261125");
  const randomTraces = Number(process.env.FX_TLA_TOOL_BRIDGE_TRACES ?? (quick ? "60" : "300"));
  const mutantTraces = quick ? 60 : 150;
  const out = outDir("tool-bridge");
  const stages: Stage[] = [];
  const details: Record<string, unknown> = { seed, randomTraces, quick, out };
  const stage = (name: string, ok: boolean, summary: string) => {
    stages.push({ name, ok, summary });
    console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  };
  const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;
  const started = performance.now();

  let graph: Graph | null = null;
  let bin = "";
  try {
    const toolchain = pinnedToolchain();
    details.toolchain = toolchain;
    stage("toolchain", true, `tla2tools.jar sha256 ${toolchain.jarSha256.slice(0, 12)}, ${toolchain.javaVersion}`);

    let at = performance.now();
    const modelDir = join(out, "model");
    const model = await runTlc(modelDir, "ToolEdit", "design-bridge.cfg", ["ToolEdit.tla", "design-bridge.cfg"], MODEL_DIR, [
      "-dump", "dot,actionlabels", join(modelDir, "graph"),
    ]);
    const counts = finalCounts(model.output);
    const pinned = new RegExp(PINNED_TLC_VERSION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).test(model.output);
    const passed = model.exitCode === 0 && /Model checking completed\. No error has been found\./.test(model.output) && counts.left === 0;
    details.model = { ...counts, exitCode: model.exitCode, durationMs: model.durationMs };
    stage("model check", passed && pinned, `design-bridge: ${counts.distinct} distinct of ${counts.generated} generated states, ${elapsed(at)}`);
    if (!passed || !pinned) throw new Error("TLC did not pass design-bridge");

    at = performance.now();
    graph = loadGraph(join(modelDir, "graph.dot"));
    details.graph = { states: graph.shapes.size, edges: graph.edges, transitions: graph.transitions };
    stage("graph", true, `${graph.shapes.size} states, ${graph.edges} edges, ${graph.transitions} distinct steps, ${elapsed(at)}`);

    at = performance.now();
    bin = await buildHarness(join(out, "harness"));
    stage("harness", true, `built from src/ with the real core, file change, and change tracker in ${elapsed(at)}`);

    at = performance.now();
    const sweep: WalkResult = await specToCode(bin, graph, (n) => join(out, "ws", "walk", String(n)));
    details.specToCode = sweep;
    stage("spec to code", sweep.failure === null && sweep.taken === sweep.transitions,
      sweep.failure
        ? `the code left the model after ${sweep.failure.path.join(" > ")}: expected ${sweep.failure.expected}, shown ${sweep.failure.shown}`
        : `${sweep.taken} of ${sweep.transitions} distinct steps, ${sweep.steps} steps, ${sweep.restarts} restarts, ${elapsed(at)}`);
    if (sweep.failure) throw new Error("spec to code failed");

    at = performance.now();
    const traces: CodeToSpecResult = await codeToSpec({
      bin, dir: join(out, "traces"), graph, seed, randomTraces, maxLength: MAX_TRACE_LENGTH, faultRate: FAULT_RATE,
    });
    details.codeToSpec = { traces: traces.traces, steps: traces.steps, scenarios: traces.scenarios, tlc: traces.tlc.verdict, property: traces.tlc.property, tracesPath: traces.tracesPath };
    stage("code to spec", traces.tlc.verdict === "pass",
      `${traces.scenarios} scenarios and ${randomTraces} random traces, ${traces.steps} steps, TLC ${traces.tlc.verdict}${traces.tlc.property ? ` (${traces.tlc.property})` : ""}, ${elapsed(at)}`);
    if (traces.tlc.verdict !== "pass") throw new Error("code to spec failed");

    const mutations = JSON.parse(readFileSync(join(MODEL_DIR, "mutations.json"), "utf8")) as Mutation[];
    const results: Record<string, unknown>[] = [];
    at = performance.now();
    for (const mutation of mutations) {
      const work = join(out, "mutants", mutation.id);
      const planted = await buildHarness(work, { file: mutation.file, find: mutation.find, replace: mutation.replace });
      const walk = await specToCode(planted, graph, (n) => join(work, "ws", "walk", String(n)), {
        maxSteps: quick ? QUICK_MUTANT_STEPS : undefined,
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
    stage("planted bugs", results.every((r) => r.caught), `${results.filter((r) => r.caught).length} of ${results.length} caught, ${elapsed(at)}`);
  } catch (error) {
    stage("gate", false, (error as Error).message);
  }

  // AgentWait: the wait of `fx tool agent wait` on the real managed execution and subagent host.
  const agent = await runAgentGate({ quick, seed, out: join(out, "agent") });
  stages.push(...agent.stages);
  details.agent = agent.details;

  const failures = stages.filter((s) => !s.ok).map((s) => s.name);
  details.durationMs = Math.round(performance.now() - started);
  writeJson(join(out, "report.json"), { stages, details, failures });
  console.log(`${failures.length === 0 ? "gate passed" : `gate failed: ${failures.join(", ")}`} in ${elapsed(started)}; report ${join(out, "report.json")}`);
  return { ok: failures.length === 0, failures, stages, details };
}

if (import.meta.main) {
  const report = await runGate({ quick: process.env.FX_TLA_TOOL_BRIDGE_QUICK === "1" });
  process.exitCode = report.ok ? 0 : 1;
}
