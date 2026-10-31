// `bun run verify` from tests/tla/transcript_window/: the one gate for the
// transcript window design. In order, and every step must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on TranscriptWindow.tla with the saved, --no-save, and Ctrl+O
//      liveness configs;
//   3. the state graphs of the two sweep configs;
//   4. pure-core-imports: the core imports only std and touches no clock,
//      file, process, thread, or global state;
//   5. the core's inline tests;
//   6. the harness, built from the real src/ui/transcript/transcript_window.zig;
//   7. spec to code: every edge of both sweep graphs replayed on the real core;
//   8. code to spec: scripted and random traces with real crashes and faulty
//      log replies, saved and --no-save, checked by TLC;
//   9. every planted bug in the spec caught by the law it names;
//  10. every planted bug in the core caught by a conformance direction;
//  11. traceability: DESIGN.md, the configs, the tests, and the bugs agree;
//  12. binary to spec: the built fx binary through three compaction cycles,
//      Ctrl+O, and a resume, its traced window steps replayed on the core and
//      checked by TLC (binary-to-spec.ts). FX_BIN picks the binary.
//
// Settings: FX_TRANSCRIPT_WINDOW_SEED (default 20261030),
// FX_TRANSCRIPT_WINDOW_TRACES (random traces per session kind, default 200),
// FX_TLA_OUT (where the report goes).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc.ts";
import { binaryToSpec } from "./binary-to-spec.ts";
import { codeToSpec } from "./code-to-spec.ts";
import { CORE_SOURCE, PINNED_TLC_VERSION, buildHarness, checkTlc, configConstants, pinnedToolchain, specFiles, type Config } from "./lib.ts";
import { coreMutations, specMutations } from "./mutations.ts";
import { specToCode } from "./spec-to-code.ts";
import { checkTraceability } from "./traceability.ts";

const seed = Number(process.env.FX_TRANSCRIPT_WINDOW_SEED ?? "20261030");
const randomTraces = Number(process.env.FX_TRANSCRIPT_WINDOW_TRACES ?? "200");
const out = outDir("transcript-window");
const report: Record<string, unknown> = { started: new Date().toISOString(), seed, randomTraces, out };
const failures: string[] = [];
const started = performance.now();
const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

function stage(name: string, ok: boolean, summary: string) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  if (!ok) failures.push(name);
}

/// Everything the core may not do, by the text that would do it.
const IMPURE = [/@import\("(?!std")/, /std\.time/, /std\.Io/, /std\.fs/, /std\.process/, /std\.posix/, /std\.os/, /std\.Thread/, /@cImport/, /std\.crypto\.random/, /^var /m];

function sweepConfig(cfg: string): { config: Config; none: number } {
  const constants = configConstants(specFiles()[`${cfg}.cfg`]!);
  return {
    config: { window: Number(constants.Window), read_step: Number(constants.Step), slice: Number(constants.Slice), saved: constants.Saved === "TRUE" },
    none: Number(constants.MaxSeq) + 1,
  };
}

try {
  const toolchain = pinnedToolchain();
  report.toolchain = toolchain;
  stage("toolchain", true, `${toolchain.javaVersion}, tla2tools.jar ${toolchain.jarSha256.slice(0, 12)}`);

  let at = performance.now();
  const models: Record<string, unknown> = {};
  for (const cfg of ["MCTranscriptWindow", "MCTranscriptWindowUnsaved", "MCCtrlOReachesStart"]) {
    const run = await checkTlc(join(out, "model", cfg), "TranscriptWindow", `${cfg}.cfg`, specFiles());
    models[cfg] = { verdict: run.verdict, property: run.property, distinct: run.distinct, depth: run.depth, ms: run.durationMs, tlc: run.tlcVersion };
    const pinned = run.tlcVersion === PINNED_TLC_VERSION;
    stage(`model ${cfg}`, run.verdict === "pass" && pinned, `${run.verdict}${run.property ? ` (${run.property})` : ""}, ${run.distinct} distinct states, depth ${run.depth}${pinned ? "" : `, TLC is ${run.tlcVersion}`}`);
  }
  report.models = models;

  const graphs: Record<string, string> = {};
  for (const cfg of ["MCTranscriptWindowSweep", "MCTranscriptWindowSweepUnsaved"]) {
    const dir = join(out, "graph", cfg);
    const run = await checkTlc(dir, "TranscriptWindow", `${cfg}.cfg`, specFiles(), ["-dump", "dot,actionlabels", join(dir, "graph")]);
    graphs[cfg] = join(dir, "graph.dot");
    stage(`graph ${cfg}`, run.verdict === "pass", `${run.distinct} distinct states`);
  }
  console.log(`  model and graphs: ${elapsed(at)}`);

  const core = readFileSync(CORE_SOURCE, "utf8");
  const code = core.slice(0, core.indexOf("// Tests"));
  const impure = IMPURE.filter((pattern) => pattern.test(code)).map(String);
  stage("pure-core-imports", impure.length === 0, impure.length ? `found ${impure.join(", ")}` : "imports only std; no clock, I/O, threads, or globals");

  const tests = Bun.spawnSync(["zig", "test", CORE_SOURCE, "--cache-dir", join(REPO_ROOT, ".zig-cache")], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  const testOutput = `${tests.stdout.toString()}${tests.stderr.toString()}`;
  stage("core tests", tests.exitCode === 0, /All (\d+) tests passed/.exec(testOutput)?.[0] ?? testOutput.split("\n").slice(-6).join(" "));

  const bin = buildHarness(join(out, "harness"));
  stage("harness", true, bin);

  at = performance.now();
  const sweeps: Record<string, unknown> = {};
  for (const cfg of ["MCTranscriptWindowSweep", "MCTranscriptWindowSweepUnsaved"]) {
    const result = await specToCode({ graphPath: graphs[cfg]!, bin, ...sweepConfig(cfg) });
    sweeps[cfg] = result;
    stage(`spec to code ${cfg}`, result.failure === null,
      result.failure ? `mismatch after ${result.failure.route.join(" -> ")}: expected ${result.failure.expected}, shown ${result.failure.shown}` : `${result.edges} edges, ${result.steps} steps, ${Object.keys(result.byAction).length} actions`);
  }
  report.specToCode = sweeps;
  console.log(`  spec to code: ${elapsed(at)}`);

  at = performance.now();
  const traces: Record<string, unknown> = {};
  for (const saved of [true, false]) {
    const kind = saved ? "saved" : "unsaved";
    const result = await codeToSpec({ bin, saved, dir: join(out, "traces", kind), randomTraces, length: 150, seed });
    traces[kind] = { traces: result.traces, steps: result.steps, rejected: result.rejected, crashes: result.crashes, verdict: result.tlc.verdict, property: result.tlc.property, problem: result.problem };
    stage(`code to spec ${kind}`, result.tlc.verdict === "pass" && result.problem === null,
      `${result.traces} traces, ${result.steps} steps, ${result.rejected} rejected events, ${result.crashes} crashes; TLC ${result.tlc.verdict}${result.tlc.property ? ` (${result.tlc.property})` : ""}${result.problem ? `; ${result.problem}` : ""}`);
  }
  report.codeToSpec = traces;
  console.log(`  code to spec: ${elapsed(at)}`);

  at = performance.now();
  const spec = await specMutations(join(out, "mutations", "spec"));
  const missedSpec = spec.filter((result) => !result.caught);
  stage("spec mutations", missedSpec.length === 0, `${spec.length - missedSpec.length} of ${spec.length} caught${missedSpec.length ? `; missed ${missedSpec.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
  const coreResults = await coreMutations(join(out, "mutations", "core"), graphs);
  const missedCore = coreResults.filter((result) => !result.caught);
  stage("core mutations", missedCore.length === 0, `${coreResults.length - missedCore.length} of ${coreResults.length} caught${missedCore.length ? `; missed ${missedCore.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
  report.mutations = { spec, core: coreResults };
  console.log(`  mutations: ${elapsed(at)}`);

  const traceability = checkTraceability();
  report.traceability = traceability;
  stage("traceability", traceability.problems.length === 0,
    traceability.problems.length ? traceability.problems.join("; ") : `${traceability.laws} laws, ${traceability.entries} enforcement entries`);

  at = performance.now();
  const fx = process.env.FX_BIN ?? join(REPO_ROOT, "zig-out", "bin", "fx");
  const binary = await binaryToSpec({ bin: fx, dir: join(out, "binary-to-spec") });
  report.binaryToSpec = { ...binary, tlc: binary.tlc ? { verdict: binary.tlc.verdict, property: binary.tlc.property, distinct: binary.tlc.distinct } : null };
  stage("binary to spec", binary.problem === null,
    `${binary.windows} windows, ${binary.steps} steps, ${binary.rejected} rejected, ${binary.archiveLoads} archive loads; TLC ${binary.tlc?.verdict ?? "not run"}${binary.problem ? `; ${binary.problem}` : ""}`);
  console.log(`  binary to spec: ${elapsed(at)}`);
} catch (error) {
  stage("verify", false, error instanceof Error ? error.stack ?? error.message : String(error));
}

report.failures = failures;
report.seconds = Math.round((performance.now() - started) / 1000);
writeJson(join(out, "report.json"), report);
console.log(`${failures.length === 0 ? "PASS" : "FAIL"} transcript window verify in ${elapsed(started)}; report ${join(out, "report.json")}`);
process.exitCode = failures.length === 0 ? 0 : 1;
