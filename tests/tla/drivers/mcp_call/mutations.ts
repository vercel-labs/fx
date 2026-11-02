// Proves no check is vacuous. Each planted bug in mutations.json breaks one
// guard, in the spec or in the code, and must make its named property fail.
//
// A spec bug is checked twice: TLC on the mutated model with only the named
// property, which must report exactly that property violated, and with all of
// MCMcpCall.cfg, which must fail. A code bug is planted in a copy of
// src/core/mcp_host/mcp_call.zig, the harness is rebuilt from the copy, and
// both directions run: the spec-to-code sweep must find the core leaving the
// model, and the code-to-spec traces must violate the named property alone and
// fail the full trace check.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { codeToSpec } from "./code-to-spec.ts";
import { CORE_SOURCE, MODEL_DIR, SPEC_DIR, buildHarness, checkTlc, configNames, plant, singleConfig, specFiles } from "./lib.ts";
import { specToCode } from "./spec-to-code.ts";

type Mutation = { id: string; breaks: string; find: string; replace: string; expect: string };
export const mutations = JSON.parse(readFileSync(join(MODEL_DIR, "mutations.json"), "utf8")) as { spec: Mutation[]; code: Mutation[] };

export type MutationResult = {
  id: string;
  breaks: string;
  expect: string;
  caught: boolean;
  detail: Record<string, string | number | null>;
};

export async function specMutations(dir: string, workers: string[]): Promise<MutationResult[]> {
  const spec = readFileSync(join(SPEC_DIR, "McpCall.tla"), "utf8");
  const baseCfg = readFileSync(join(SPEC_DIR, "MCMcpCall.cfg"), "utf8");
  const { invariants } = configNames(baseCfg);
  const results: MutationResult[] = [];
  for (const mutation of mutations.spec) {
    const mutated = plant(spec, mutation.find, mutation.replace, mutation.id);
    const files = specFiles(mutated);
    const single = await checkTlc(join(dir, mutation.id, "single"), "McpCall", "Single.cfg", {
      ...files,
      "Single.cfg": singleConfig(mutation.expect, "Spec", invariants, baseCfg),
    }, workers);
    const full = await checkTlc(join(dir, mutation.id, "full"), "McpCall", "MCMcpCall.cfg", files, workers);
    results.push({
      id: mutation.id,
      breaks: mutation.breaks,
      expect: mutation.expect,
      caught: single.verdict === "violated" && single.property === mutation.expect && full.verdict === "violated",
      detail: { alone: single.property ?? single.verdict, full: full.property ?? full.verdict, states: single.distinctStates },
    });
  }
  return results;
}

export async function codeMutations(dir: string, graphPath: string, seed: number, randomTraces: number): Promise<MutationResult[]> {
  const core = readFileSync(CORE_SOURCE, "utf8");
  const traceCfg = readFileSync(join(SPEC_DIR, "TraceMcpCall.cfg"), "utf8");
  const { invariants } = configNames(traceCfg);
  const results: MutationResult[] = [];
  for (const mutation of mutations.code) {
    const work = join(dir, mutation.id);
    mkdirSync(work, { recursive: true });
    const source = join(work, "mcp_call.zig");
    writeFileSync(source, plant(core, mutation.find, mutation.replace, mutation.id));
    const bin = buildHarness(work, source);
    const sweep = await specToCode(bin, graphPath);
    const alone = await codeToSpec({
      bin, dir: join(work, "alone"), seed, randomTraces, maxLength: 40,
      cfgName: "Single.cfg", cfgText: singleConfig(mutation.expect, "TraceSpec", invariants, traceCfg),
    });
    const full = await codeToSpec({ bin, dir: join(work, "full"), seed, randomTraces, maxLength: 40 });
    results.push({
      id: mutation.id,
      breaks: mutation.breaks,
      expect: mutation.expect,
      caught: sweep.failure !== null && alone.tlc.verdict === "violated" && alone.tlc.property === mutation.expect && full.tlc.verdict === "violated",
      detail: {
        specToCode: sweep.failure ? `left the model after ${sweep.failure.path.slice(-3).join(" > ")}` : "not detected",
        alone: alone.tlc.property ?? alone.tlc.verdict,
        full: full.tlc.property ?? full.tlc.verdict,
      },
    });
  }
  return results;
}
