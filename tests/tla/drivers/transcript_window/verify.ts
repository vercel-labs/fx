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
//   9. footer runtime to spec: event scripts (output, slash picker open and
//      close, resizes, exit) through the real transcript runtime in the resize
//      harness, checked by TLC against FooterReclaim.tla, with every row
//      counted once in the bytes it wrote (footer-runtime-to-spec.ts);
//  10. every planted bug in the spec caught by the law it names;
//  11. every planted bug in the core caught by a conformance direction;
//  12. every planted bug in the transcript runtime's footer reclaim rule
//      caught by the footer reclaim tests or by step 9;
//  13. traceability: DESIGN.md, the configs, the tests, and the bugs agree;
//  14. binary to spec: the built fx binary through three compaction cycles,
//      Ctrl+O, and a resume, its traced window steps replayed on the core and
//      checked by TLC (binary-to-spec.ts). FX_BIN picks the binary.
//  15. footer signal to spec: the built fx with the slash picker open over a
//      long transcript, also after Ctrl+O and a resize, with an approval
//      that a narrower window moved to the review screen, and right after a
//      resize, ended by a real SIGTERM or SIGHUP, the rows its history and
//      screen hold checked by TLC against FooterReclaim.tla
//      (footer-signal-to-spec.ts);
//  16. every planted bug in the signal close's wiring (a copy of src/ built and
//      run by the signal driver or a tmux test) caught.
//
// With --ci, CI's TLA+ transcript window job leaves out steps 10, 11, 12, 14,
// 15, and 16: the planted bugs measure the checks rather than the code, and
// the binary runs need a built fx and tmux.
//
// Settings: FX_TRANSCRIPT_WINDOW_SEED (default 20261030),
// FX_TRANSCRIPT_WINDOW_TRACES (random traces per session kind, default 200),
// FX_FOOTER_RECLAIM_TRACES (random footer scripts, default 40),
// FX_TLA_OUT (where the report goes).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc.ts";
import { binaryToSpec } from "./binary-to-spec.ts";
import { codeToSpec } from "./code-to-spec.ts";
import { footerRuntimeToSpec } from "./footer-runtime-to-spec.ts";
import { CORE_SOURCE, PINNED_TLC_VERSION, buildHarness, checkTlc, configConstants, pinnedToolchain, specFiles, type Config } from "./lib.ts";
import { coreMutations, runtimeMutations, specMutations, wiringMutations } from "./mutations.ts";
import { footerSignalToSpec } from "./footer-signal-to-spec.ts";
import { specToCode } from "./spec-to-code.ts";
import { checkTraceability } from "./traceability.ts";

const seed = Number(process.env.FX_TRANSCRIPT_WINDOW_SEED ?? "20261030");
const randomTraces = Number(process.env.FX_TRANSCRIPT_WINDOW_TRACES ?? "200");
const footerTraces = Number(process.env.FX_FOOTER_RECLAIM_TRACES ?? "40");
const ci = process.argv.includes("--ci");
const out = outDir("transcript-window");
const report: Record<string, unknown> = { started: new Date().toISOString(), seed, randomTraces, ci, out };
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
  // The footer: the design's config passes, main's rule before it (history
  // follows the footer on the screen) fails FooterAtBottom, the head before
  // the signal repair (SIGTERM and SIGHUP erase the footer without the exit
  // frame) fails ExitKeepsRows, and so do the head before the
  // invalid-anchor repair (the exit frame is drawn only from a stable anchor)
  // and the head before the debounce repair (no exit frame while a resize
  // debounce is pending).
  for (const [cfg, expected] of [
    ["MCFooterReclaim", null],
    ["MCFooterReclaimToday", "FooterAtBottom"],
    ["MCFooterReclaimSignalHead", "ExitKeepsRows"],
    ["MCFooterReclaimInvalidAnchorHead", "ExitKeepsRows"],
    ["MCFooterReclaimDebounceHead", "ExitKeepsRows"],
  ] as const) {
    const run = await checkTlc(join(out, "model", cfg), "FooterReclaim", `${cfg}.cfg`, specFiles());
    models[cfg] = { verdict: run.verdict, property: run.property, distinct: run.distinct, depth: run.depth, ms: run.durationMs, tlc: run.tlcVersion };
    const ok = expected === null ? run.verdict === "pass" : run.verdict === "violated" && run.property === expected;
    stage(`model ${cfg}`, ok && run.tlcVersion === PINNED_TLC_VERSION,
      `${run.verdict}${run.property ? ` (${run.property})` : ""}${expected ? `, expected ${expected} violated` : ""}, ${run.distinct} distinct states`);
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
  const footer = await footerRuntimeToSpec({ dir: join(out, "footer"), randomTraces: footerTraces, length: 30, seed });
  report.footerRuntimeToSpec = { ...footer, tlc: footer.tlc ? { verdict: footer.tlc.verdict, property: footer.tlc.property, distinct: footer.tlc.distinct } : null };
  stage("footer runtime to spec", footer.tlc?.verdict === "pass" && footer.problem === null,
    `${footer.traces} traces, ${footer.steps} steps of the real transcript runtime, base footer ${footer.baseCap ?? "?"} rows, surface +${footer.extra ?? "?"}; TLC ${footer.tlc?.verdict ?? "not run"}${footer.tlc?.property ? ` (${footer.tlc.property})` : ""}${footer.problem ? `; ${footer.problem}` : ""}`);
  console.log(`  footer runtime to spec: ${elapsed(at)}`);

  if (!ci) {
    at = performance.now();
    const spec = await specMutations(join(out, "mutations", "spec"));
    const missedSpec = spec.filter((result) => !result.caught);
    stage("spec mutations", missedSpec.length === 0, `${spec.length - missedSpec.length} of ${spec.length} caught${missedSpec.length ? `; missed ${missedSpec.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
    const coreResults = await coreMutations(join(out, "mutations", "core"), graphs);
    const missedCore = coreResults.filter((result) => !result.caught);
    stage("core mutations", missedCore.length === 0, `${coreResults.length - missedCore.length} of ${coreResults.length} caught${missedCore.length ? `; missed ${missedCore.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
    const runtimeResults = await runtimeMutations(join(out, "mutations", "runtime"));
    const missedRuntime = runtimeResults.filter((result) => !result.caught);
    stage("runtime mutations", missedRuntime.length === 0, `${runtimeResults.length - missedRuntime.length} of ${runtimeResults.length} caught${missedRuntime.length ? `; missed ${missedRuntime.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
    const wiringResults = await wiringMutations(join(out, "mutations", "wiring"));
    const missedWiring = wiringResults.filter((result) => !result.caught);
    stage("signal wiring mutations", missedWiring.length === 0, `${wiringResults.length - missedWiring.length} of ${wiringResults.length} caught${missedWiring.length ? `; missed ${missedWiring.map((result) => `${result.id} (${result.detail})`).join(", ")}` : ""}`);
    report.mutations = { spec, core: coreResults, runtime: runtimeResults, wiring: wiringResults };
    console.log(`  mutations: ${elapsed(at)}`);
  }

  const traceability = checkTraceability();
  report.traceability = traceability;
  stage("traceability", traceability.problems.length === 0,
    traceability.problems.length ? traceability.problems.join("; ") : `${traceability.laws} laws, ${traceability.entries} enforcement entries`);

  if (!ci) {
    at = performance.now();
    const fx = process.env.FX_BIN ?? join(REPO_ROOT, "zig-out", "bin", "fx");
    const binary = await binaryToSpec({ bin: fx, dir: join(out, "binary-to-spec") });
    report.binaryToSpec = { ...binary, tlc: binary.tlc ? { verdict: binary.tlc.verdict, property: binary.tlc.property, distinct: binary.tlc.distinct } : null };
    stage("binary to spec", binary.problem === null,
      `${binary.windows} windows, ${binary.steps} steps, ${binary.rejected} rejected, ${binary.archiveLoads} archive loads; TLC ${binary.tlc?.verdict ?? "not run"}${binary.problem ? `; ${binary.problem}` : ""}`);
    console.log(`  binary to spec: ${elapsed(at)}`);

    at = performance.now();
    const signal = await footerSignalToSpec({ dir: join(out, "footer-signal"), bin: fx });
    report.footerSignalToSpec = { scenarios: signal.scenarios, steps: signal.steps, problems: signal.problems, tlc: signal.tlc ? { verdict: signal.tlc.verdict, property: signal.tlc.property, distinct: signal.tlc.distinct } : null };
    stage("footer signal to spec", signal.tlc?.verdict === "pass" && signal.problems.length === 0,
      `${signal.scenarios} runs of the built binary ended by SIGTERM or SIGHUP with the picker open, after Ctrl+O and a resize, after the approval moved to the review screen, or right after a resize, ${signal.steps} steps; TLC ${signal.tlc?.verdict ?? "not run"}${signal.tlc?.property ? ` (${signal.tlc.property})` : ""}${signal.problems.length ? `; ${signal.problems.join("; ")}` : ""}`);
    console.log(`  footer signal to spec: ${elapsed(at)}`);
  }
} catch (error) {
  stage("verify", false, error instanceof Error ? error.stack ?? error.message : String(error));
}

report.failures = failures;
report.seconds = Math.round((performance.now() - started) / 1000);
writeJson(join(out, "report.json"), report);
console.log(`${failures.length === 0 ? "PASS" : "FAIL"} transcript window verify${ci ? " (--ci: planted bugs and the binary run left out)" : ""} in ${elapsed(started)}; report ${join(out, "report.json")}`);
process.exitCode = failures.length === 0 ? 0 : 1;
