// Planted bugs from tests/tla/transcript_window/mutations.json.
//
// A spec bug must be caught by TLC under exactly the law it names: the check
// runs a config that lists only that law, with the constants of the config
// the bug names, and the unmutated spec must pass the same config first, so a
// catch cannot come from a broken config. A core bug must compile, and the
// edge sweep must then fail; if it does not, code to spec gets a run, and the
// bug counts as missed only when both pass.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { codeToSpec } from "./code-to-spec.ts";
import { CORE_SOURCE, MODEL_DIR, buildHarness, checkTlc, configConstants, configNames, specFiles, type Config } from "./lib.ts";
import { specToCode } from "./spec-to-code.ts";

type SpecMutation = { id: string; bug: string; law: string; constants: string; find: string; replace: string };
type CoreMutation = { id: string; bug: string; sweep: string; find: string; replace: string };

export type MutationResult = { id: string; caught: boolean; by: string; detail: string; ms: number };

export function loadMutations(): { spec: SpecMutation[]; core: CoreMutation[] } {
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
  ]);
  return `CONSTANTS\n${block}\nSPECIFICATION Spec\n${invariants.has(law) ? "INVARIANT" : "PROPERTY"}\n    ${law}\n`;
}

export async function specMutations(out: string): Promise<MutationResult[]> {
  const original = specFiles()["TranscriptWindow.tla"]!;
  const controls = new Map<string, boolean>();
  const results: MutationResult[] = [];
  for (const mutation of loadMutations().spec) {
    const started = performance.now();
    const cfg = singleLawConfig(mutation.constants, mutation.law);
    const key = `${mutation.constants}/${mutation.law}`;
    if (!controls.has(key)) {
      const control = await checkTlc(join(out, "control", key.replace("/", "-")), "TranscriptWindow", "Single.cfg", { ...specFiles(original), "Single.cfg": cfg });
      controls.set(key, control.verdict === "pass");
    }
    if (!controls.get(key)) {
      results.push({ id: mutation.id, caught: false, by: "none", detail: `the unmutated spec fails ${key}`, ms: Math.round(performance.now() - started) });
      continue;
    }
    const mutated = replaceOnce(original, mutation.find, mutation.replace, mutation.id);
    const tlc = await checkTlc(join(out, mutation.id), "TranscriptWindow", "Single.cfg", { ...specFiles(mutated), "Single.cfg": cfg });
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
