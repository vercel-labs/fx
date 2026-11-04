// `bun run verify` from tests/tla/mcp_call/: the one gate for the `fx mcp
// call` bridge design. In order, and every step must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on McpCall.tla with MCMcpCall.cfg, which also writes the state
//      graph;
//   3. the core's own tests, `zig test src/core/mcp_host/mcp_call.zig`;
//   4. the harness, built from the real src/core/mcp_host/mcp_call.zig;
//   5. spec to code: every distinct transition of the graph replayed against
//      the real core;
//   6. code to spec: scripted and random traces with faults, checked by TLC;
//   7. every planted bug in the spec caught by its property;
//   8. every planted bug in the code caught in both directions;
//   9. traceability: DESIGN.md accounts for every question, rule, and law,
//      and rejects designs that drop one.
//
// The shell around the core has not landed, so nothing here runs the fx
// binary yet; design/FINISH.md tracks the binary stage.
//
// Settings: FX_MCP_CALL_SEED (default 20261029), FX_MCP_CALL_TRACES (random
// traces, default 300), FX_TLA_OUT (where the report goes).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc.ts";
import { codeToSpec } from "./code-to-spec.ts";
import { CORE_SOURCE, MODEL_DIR, PINNED_TLC_VERSION, buildHarness, checkTlc, pinnedToolchain, specFiles } from "./lib.ts";
import { codeMutations, specMutations } from "./mutations.ts";
import { specToCode } from "./spec-to-code.ts";
import { checkTraceability } from "./traceability.ts";

const seed = Number(process.env.FX_MCP_CALL_SEED ?? "20261029");
const randomTraces = Number(process.env.FX_MCP_CALL_TRACES ?? "300");
// TLC's distinct-state count does not depend on the worker count.
const workers = ["-workers", "auto"];
const out = outDir("mcp-call");
const report: Record<string, unknown> = { started: new Date().toISOString(), seed, randomTraces, out };
const failures: string[] = [];
const started = performance.now();
const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

function stage(name: string, ok: boolean, summary: string) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  if (!ok) failures.push(name);
}

/// TLC's final counts: "N states generated, M distinct states found, 0 states left on queue."
function finalCounts(output: string) {
  const match = /^(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.$/m.exec(output);
  return { generated: Number(match?.[1] ?? NaN), distinct: Number(match?.[2] ?? NaN), left: Number(match?.[3] ?? NaN) };
}

try {
  const toolchain = pinnedToolchain();
  report.toolchain = toolchain;
  stage("toolchain", true, `tla2tools.jar sha256 ${toolchain.jarSha256.slice(0, 12)}, ${toolchain.javaVersion}`);

  let at = performance.now();
  const model = await checkTlc(join(out, "model"), "McpCall", "MCMcpCall.cfg", specFiles(), [...workers, "-dump", "dot,actionlabels", join(out, "model", "graph")]);
  const counts = finalCounts(model.output);
  report.model = { verdict: model.verdict, property: model.property, ...counts, depth: model.depth, durationMs: model.durationMs, tlcVersion: model.tlcVersion };
  stage("model check", model.verdict === "pass" && model.tlcVersion === PINNED_TLC_VERSION && counts.left === 0,
    `${model.verdict}${model.property ? ` (${model.property})` : ""}, ${counts.distinct} distinct of ${counts.generated} generated states, depth ${model.depth}, ${model.durationMs} ms, ${model.tlcVersion}`);
  const graphPath = join(out, "model", "graph.dot");

  at = performance.now();
  const tests = Bun.spawnSync(["zig", "test", CORE_SOURCE, "--cache-dir", join(REPO_ROOT, ".zig-cache")], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  const testOutput = `${tests.stdout.toString()}${tests.stderr.toString()}`;
  const passed = /All (\d+) tests passed\./.exec(testOutput)?.[1];
  report.coreTests = { exitCode: tests.exitCode, passed: passed ? Number(passed) : null };
  stage("core tests", tests.exitCode === 0 && passed !== undefined, tests.exitCode === 0 ? `${passed} tests passed in ${elapsed(at)}` : testOutput.slice(-2000));

  at = performance.now();
  const bin = buildHarness(join(out, "harness"));
  stage("harness", true, `built from src/core/mcp_host/mcp_call.zig in ${elapsed(at)}`);

  at = performance.now();
  const sweep = await specToCode(bin, graphPath);
  report.specToCode = sweep;
  stage("spec to code", sweep.failure === null,
    sweep.failure
      ? `the core left the model after ${sweep.failure.path.join(" > ")}: expected ${sweep.failure.expected}, shown ${sweep.failure.shown}`
      : `${sweep.transitions} of ${sweep.transitions} distinct transitions (from ${sweep.edges} graph edges over ${sweep.states} states, ${sweep.coreStates} core states), ${sweep.steps} steps, ${sweep.crashes} crashes, ${elapsed(at)}`);

  at = performance.now();
  const traces = await codeToSpec({ bin, dir: join(out, "code-to-spec"), seed, randomTraces, maxLength: 40 });
  report.codeToSpec = { traces: traces.traces, steps: traces.steps, crashes: traces.crashes, tracesPath: traces.tracesPath, verdict: traces.tlc.verdict, property: traces.tlc.property, ...finalCounts(traces.tlc.output), durationMs: traces.tlc.durationMs };
  stage("code to spec", traces.tlc.verdict === "pass",
    `${traces.traces} traces, ${traces.steps} steps, ${traces.crashes} crashes, TLC ${traces.tlc.verdict}${traces.tlc.property ? ` (${traces.tlc.property})` : ""}, ${finalCounts(traces.tlc.output).distinct} distinct states, ${elapsed(at)}`);

  at = performance.now();
  const specBugs = await specMutations(join(out, "spec-mutations"), workers);
  report.specMutations = specBugs;
  for (const bug of specBugs) console.log(`  ${bug.caught ? "caught" : "MISSED"} ${bug.id} by ${bug.expect}: alone ${bug.detail.alone}, full ${bug.detail.full}`);
  stage("spec mutations", specBugs.every((bug) => bug.caught), `${specBugs.filter((bug) => bug.caught).length} of ${specBugs.length} caught, ${elapsed(at)}`);

  at = performance.now();
  const codeBugs = await codeMutations(join(out, "code-mutations"), graphPath, seed, Math.min(randomTraces, 150));
  report.codeMutations = codeBugs;
  for (const bug of codeBugs) console.log(`  ${bug.caught ? "caught" : "MISSED"} ${bug.id} by ${bug.expect}: alone ${bug.detail.alone}, full ${bug.detail.full}; spec to code ${bug.detail.specToCode}`);
  stage("code mutations", codeBugs.every((bug) => bug.caught), `${codeBugs.filter((bug) => bug.caught).length} of ${codeBugs.length} caught, ${elapsed(at)}`);

  const trace = checkTraceability();
  report.traceability = trace;
  for (const problem of trace.problems) console.log(`  ${problem}`);
  // The check itself must reject a design that drops a rule, names a check
  // that does not exist, or leaves a question unanswered.
  const design = readFileSync(join(MODEL_DIR, "design", "DESIGN.md"), "utf8");
  const broken = [
    ["a missing rule row", design.replace(/^\| R6 \|.*\n/m, "")],
    ["an invariant that does not exist", design.replace("`inv:LiveWorkHasOwner`", "`inv:LiveWorkHasOwners`")],
    ["an unanswered question", design.replace(/^- Q12:.*\n/m, "")],
    ["a law without a planted bug", design.replace(/^(\| L5 \|.*?), `mutation:S15`, `mutation:C14`/m, "$1")],
  ] as const;
  const rejected = broken.filter(([, text]) => {
    const path = join(out, "traceability", "DESIGN.md");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
    return text !== design && checkTraceability(path).problems.length > 0;
  });
  report.traceabilitySelfCheck = rejected.map(([name]) => name);
  stage("traceability", trace.problems.length === 0 && rejected.length === broken.length,
    `${trace.questions} questions, ${trace.rules} rules, ${trace.laws} laws, ${trace.entries} enforcement entries, ${trace.problems.length} problems; rejects ${rejected.length} of ${broken.length} broken designs`);
} catch (error) {
  failures.push("verify");
  console.error(`FAIL verify: ${(error as Error).message}`);
  report.error = (error as Error).stack;
}

report.failures = failures;
report.durationMs = Math.round(performance.now() - started);
writeJson(join(out, "report.json"), report);
console.log(`${failures.length === 0 ? "verify passed" : `verify failed: ${failures.join(", ")}`} in ${elapsed(started)}; report ${join(out, "report.json")}`);
process.exitCode = failures.length === 0 ? 0 : 1;
