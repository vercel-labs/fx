// Planted bugs from tests/tla/transcript_window/mutations.json.
//
// A spec bug must be caught by TLC under exactly the law it names: the check
// runs a config that lists only that law, with the constants of the config
// the bug names, and the unmutated spec must pass the same config first, so a
// catch cannot come from a broken config. A core bug must compile, and the
// edge sweep must then fail; if it does not, code to spec gets a run, and the
// bug counts as missed only when both pass. A runtime bug is planted in a copy
// of src/ (the transcript runtime's footer reclaim rule) and must compile; the
// footer reclaim tests in src/ui/resize_tests.zig must then fail, or else the
// footer runtime driver must fail TLC or count a row other than once. A wiring
// bug is planted in a copy of the checkout (the signal close's hand-off between
// its closer thread and the main thread) and the copy is built; the built
// binary must then fail the signal driver or the named tmux test.
import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc.ts";
import { codeToSpec } from "./code-to-spec.ts";
import { footerRuntimeToSpec } from "./footer-runtime-to-spec.ts";
import { SIGNAL_SCENARIOS, footerSignalToSpec } from "./footer-signal-to-spec.ts";
import { CORE_SOURCE, MODEL_DIR, buildHarness, checkTlc, configConstants, configNames, specFiles, type Config } from "./lib.ts";
import { specToCode } from "./spec-to-code.ts";

type SpecMutation = { id: string; bug: string; law: string; constants: string; find: string; replace: string; spec?: string };
type CoreMutation = { id: string; bug: string; sweep: string; find: string; replace: string };
type RuntimeMutation = { id: string; bug: string; file: string; find: string; replace: string };
/// `proof` is "driver" (the built-binary signal driver) or "e2e:<test name>".
type WiringMutation = RuntimeMutation & { proof: string };

/// The footer reclaim tests in src/ui/resize_tests.zig that a runtime bug runs
/// first; the fuzz target needs `zig build`, so the seeded walk stands in.
const FOOTER_RECLAIM_TESTS = [
  "puts the footer back on the bottom row",
  "reaches history in order and close paints the held rows back",
  "exit with the slash picker open leaves every row",
  "rows a multi-line draft covers from the first frames",
  "resize with the slash picker open keeps the covered rows held",
  "takeover with the slash picker open recovers only the rows it displaced",
  "recovery from an invalid anchor with the slash picker open keeps the held rows owed",
  "exit after a resize while a screen covers the slash picker leaves every row",
  "exit after output and a resize while a screen covers the slash picker repeats no row",
  "a held-rows settle is asked for by every anchor that may hold rows",
  "footer reclaim keeps every row once on seeded random event scripts",
];

export type MutationResult = { id: string; caught: boolean; by: string; detail: string; ms: number };

export function loadMutations(): { spec: SpecMutation[]; core: CoreMutation[]; runtime: RuntimeMutation[]; wiring: WiringMutation[] } {
  return JSON.parse(readFileSync(join(MODEL_DIR, "mutations.json"), "utf8"));
}

function replaceOnce(text: string, find: string, replace: string, id: string): string {
  const first = text.indexOf(find);
  if (first < 0 || text.indexOf(find, first + find.length) >= 0) throw new Error(`mutation ${id}: its text must occur exactly once`);
  return text.slice(0, first) + replace + text.slice(first + find.length);
}

/// A config with the constants of `constantsCfg` that checks only `law`.
export function singleLawConfig(constantsCfg: string, law: string): string {
  const files = specFiles();
  const block = /CONSTANTS\n([\s\S]*?)\nSPECIFICATION/.exec(files[`${constantsCfg}.cfg`]!)?.[1];
  if (!block) throw new Error(`${constantsCfg}.cfg has no CONSTANTS block`);
  const invariants = new Set([
    ...(configNames(files["MCTranscriptWindow.cfg"]!).INVARIANT ?? []),
    ...(configNames(files["MCTranscriptWindowUnsaved.cfg"]!).INVARIANT ?? []),
    ...(configNames(files["MCFooterReclaim.cfg"]!).INVARIANT ?? []),
  ]);
  return `CONSTANTS\n${block}\nSPECIFICATION Spec\n${invariants.has(law) ? "INVARIANT" : "PROPERTY"}\n    ${law}\n`;
}

export async function specMutations(out: string): Promise<MutationResult[]> {
  const controls = new Map<string, boolean>();
  const results: MutationResult[] = [];
  for (const mutation of loadMutations().spec) {
    const started = performance.now();
    const module = mutation.spec ?? "TranscriptWindow";
    const original = specFiles()[`${module}.tla`]!;
    const cfg = singleLawConfig(mutation.constants, mutation.law);
    const key = `${mutation.constants}/${mutation.law}`;
    if (!controls.has(key)) {
      const control = await checkTlc(join(out, "control", key.replace("/", "-")), module, "Single.cfg", { ...specFiles(), "Single.cfg": cfg });
      controls.set(key, control.verdict === "pass");
    }
    if (!controls.get(key)) {
      results.push({ id: mutation.id, caught: false, by: "none", detail: `the unmutated spec fails ${key}`, ms: Math.round(performance.now() - started) });
      continue;
    }
    const mutated = replaceOnce(original, mutation.find, mutation.replace, mutation.id);
    const tlc = await checkTlc(join(out, mutation.id), module, "Single.cfg", { ...specFiles(), [`${module}.tla`]: mutated, "Single.cfg": cfg });
    const caught = tlc.verdict === "violated" && tlc.property === mutation.law;
    results.push({
      id: mutation.id,
      caught,
      by: caught ? `TLC ${mutation.law}` : "none",
      detail: caught ? `${mutation.constants} constants` : `verdict ${tlc.verdict}, property ${tlc.property}`,
      ms: Math.round(performance.now() - started),
    });
  }
  return results;
}

export async function coreMutations(out: string, graphs: Record<string, string>): Promise<MutationResult[]> {
  const original = readFileSync(CORE_SOURCE, "utf8");
  const files = specFiles();
  const results: MutationResult[] = [];
  for (const mutation of loadMutations().core) {
    const started = performance.now();
    const dir = join(out, mutation.id);
    mkdirSync(dir, { recursive: true });
    const source = join(dir, "transcript_window.zig");
    writeFileSync(source, replaceOnce(original, mutation.find, mutation.replace, mutation.id));
    let bin: string;
    try {
      bin = buildHarness(join(dir, "bin"), source);
    } catch (error) {
      results.push({ id: mutation.id, caught: false, by: "none", detail: `does not compile: ${String(error).slice(0, 300)}`, ms: Math.round(performance.now() - started) });
      continue;
    }
    const constants = configConstants(files[`${mutation.sweep}.cfg`]!);
    const config: Config = { window: Number(constants.Window), read_step: Number(constants.Step), slice: Number(constants.Slice), saved: constants.Saved === "TRUE" };
    const sweep = await specToCode({ graphPath: graphs[mutation.sweep]!, bin, config, none: Number(constants.MaxSeq) + 1 });
    if (sweep.failure) {
      results.push({
        id: mutation.id,
        caught: true,
        by: "spec to code",
        detail: `${mutation.sweep}, after ${sweep.failure.route.length} steps: ${sweep.failure.route.slice(-3).join(" -> ")}`,
        ms: Math.round(performance.now() - started),
      });
      continue;
    }
    const traces = await codeToSpec({ bin, saved: config.saved, dir: join(dir, "traces"), randomTraces: 20, length: 150, seed: 7 });
    const caught = traces.tlc.verdict !== "pass" || traces.problem !== null;
    results.push({
      id: mutation.id,
      caught,
      by: caught ? "code to spec" : "none",
      detail: caught ? `TLC ${traces.tlc.verdict} ${traces.tlc.property ?? ""} ${traces.problem ?? ""}`.trim() : "both directions pass",
      ms: Math.round(performance.now() - started),
    });
  }
  return results;
}

export async function runtimeMutations(out: string): Promise<MutationResult[]> {
  const results: MutationResult[] = [];
  for (const mutation of loadMutations().runtime) {
    const started = performance.now();
    const root = join(out, mutation.id, "repo");
    mkdirSync(root, { recursive: true });
    cpSync(join(REPO_ROOT, "src"), join(root, "src"), { recursive: true });
    const source = join(root, mutation.file);
    writeFileSync(source, replaceOnce(readFileSync(source, "utf8"), mutation.find, mutation.replace, mutation.id));
    const tests = Bun.spawnSync(
      ["zig", "test", "-lc", "src/footer_reclaim_root.zig", ...FOOTER_RECLAIM_TESTS.flatMap((name) => ["--test-filter", name]), "--cache-dir", join(REPO_ROOT, ".zig-cache")],
      { cwd: root, env: { ...process.env, FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1" }, stdout: "pipe", stderr: "pipe" },
    );
    const testOutput = `${tests.stdout.toString()}${tests.stderr.toString()}`;
    if (/\.zig:\d+:\d+: error:/.test(testOutput)) {
      results.push({ id: mutation.id, caught: false, by: "none", detail: `does not compile: ${testOutput.slice(0, 300)}`, ms: Math.round(performance.now() - started) });
      continue;
    }
    if (tests.exitCode !== 0) {
      const failed = /test\.(.+?)\.\.\.FAIL/.exec(testOutput)?.[1] ?? /error: '([^']+)' failed/.exec(testOutput)?.[1] ?? "a footer reclaim test";
      results.push({ id: mutation.id, caught: true, by: "resize tests", detail: failed, ms: Math.round(performance.now() - started) });
      continue;
    }
    const footer = await footerRuntimeToSpec({ dir: join(out, mutation.id, "footer"), randomTraces: 8, length: 20, seed: 7, root });
    const caught = !footer.compileError && (footer.tlc?.verdict !== "pass" || footer.problem !== null);
    results.push({
      id: mutation.id,
      caught,
      by: caught ? "footer runtime to spec" : "none",
      detail: caught ? `TLC ${footer.tlc?.verdict ?? "not run"} ${footer.tlc?.property ?? ""} ${footer.problem ?? ""}`.trim() : "the tests and the driver pass",
      ms: Math.round(performance.now() - started),
    });
  }
  return results;
}

/// The files a build of the checkout needs, and the E2E tests that run it.
const WIRING_COPY = ["build.zig", "build.zig.zon", "src", "tests"];

export async function wiringMutations(out: string): Promise<MutationResult[]> {
  const results: MutationResult[] = [];
  for (const mutation of loadMutations().wiring) {
    const started = performance.now();
    const root = join(out, mutation.id, "repo");
    mkdirSync(root, { recursive: true });
    for (const name of WIRING_COPY) {
      cpSync(join(REPO_ROOT, name), join(root, name), { recursive: true, filter: (path) => !path.includes("node_modules") });
    }
    const source = join(root, mutation.file);
    writeFileSync(source, replaceOnce(readFileSync(source, "utf8"), mutation.find, mutation.replace, mutation.id));
    const build = Bun.spawnSync(["zig", "build", "--cache-dir", join(out, "zig-cache")], { cwd: root, stdout: "pipe", stderr: "pipe" });
    if (build.exitCode !== 0) {
      results.push({ id: mutation.id, caught: false, by: "none", detail: `does not compile: ${build.stderr.toString().slice(0, 300)}`, ms: Math.round(performance.now() - started) });
      continue;
    }
    const bin = join(root, "zig-out", "bin", "fx");
    if (mutation.proof === "driver") {
      const run = await footerSignalToSpec({ dir: join(out, mutation.id, "driver"), bin, scenarios: [SIGNAL_SCENARIOS[2]!] });
      const caught = run.tlc?.verdict !== "pass" || run.problems.length > 0;
      results.push({
        id: mutation.id,
        caught,
        by: caught ? "footer signal to spec" : "none",
        detail: caught ? `TLC ${run.tlc?.verdict ?? "not run"} ${run.tlc?.property ?? ""}`.trim() : "the driver passes",
        ms: Math.round(performance.now() - started),
      });
      continue;
    }
    const filter = mutation.proof.replace(/^e2e:/, "");
    const env = { ...process.env, FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1" };
    delete env.AI_GATEWAY_API_KEY;
    const test = Bun.spawnSync(["bun", "test", "tests/e2e/tui-slash-menu.test.ts", "-t", filter], { cwd: root, env, stdout: "pipe", stderr: "pipe" });
    const output = `${test.stdout.toString()}${test.stderr.toString()}`;
    const ran = /\(pass\)|\(fail\)/.test(output);
    const caught = test.exitCode !== 0 && ran;
    results.push({
      id: mutation.id,
      caught,
      by: caught ? "tmux test" : "none",
      detail: caught ? (/\(fail\) (.+?) \[/.exec(output)?.[1] ?? filter) : ran ? "the test passes" : `the test did not run: ${output.slice(-300)}`,
      ms: Math.round(performance.now() - started),
    });
  }
  return results;
}

// `bun mutations.ts --runtime` or `--wiring` runs the runtime or the signal
// wiring bugs on their own; verify.ts runs every kind as stages of check.sh.
if (import.meta.main && (process.argv.includes("--runtime") || process.argv.includes("--wiring"))) {
  const { outDir } = await import("../lib/tlc.ts");
  const wiring = process.argv.includes("--wiring");
  const results = wiring
    ? await wiringMutations(join(outDir("footer-signal-mutations"), "wiring"))
    : await runtimeMutations(join(outDir("footer-reclaim-mutations"), "runtime"));
  for (const result of results) console.log(`${result.caught ? "CAUGHT" : "MISSED"} ${result.id}: ${result.by}; ${result.detail} (${result.ms} ms)`);
  const missed = results.filter((result) => !result.caught);
  console.log(`${missed.length === 0 ? "PASS" : "FAIL"} ${wiring ? "wiring" : "runtime"} mutations: ${results.length - missed.length} of ${results.length} caught`);
  process.exit(missed.length === 0 ? 0 : 1);
}
