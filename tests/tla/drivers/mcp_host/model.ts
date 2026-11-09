// Model gate for the fx-layer MCP models: each model's smoke config
// (safety and liveness), its stress config, every planted bug, the stated
// properties the code is expected to break (findings), and repair witnesses.
//
// Verdicts, as tests/tla/mcp/run.py gives them:
//   PASS     exit 0, the completed marker, an empty queue
//   CAUGHT   a planted bug: exit 12 naming its invariant, or exit 13 for its property
//   FINDING  a findings config: exit 12 naming the stated invariant (13 for a property)
// Anything else is FAIL. Usage: bun model.ts OUTPUT_DIR [--model NAME]
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { configWith, runTlc, sha256, sha256Text, tlaDir, tools, type TlcRun } from "./tlc";

interface Mutant { description: string; old: string; new: string; invariant?: string; property?: string; config?: string }
interface Entry {
  module: string; smoke: string; stress?: string;
  findings: { config: string; invariant?: string; property?: string; only?: boolean }[];
  repair: string[];
}
export interface GateResult {
  module: string; label: string; kind: "smoke" | "stress" | "mutant" | "finding" | "repair";
  verdict: "PASS" | "CAUGHT" | "FINDING" | "FAIL"; expected?: string; description?: string;
  exit: number; seconds: number; generated?: number; distinct?: number; queued?: number; log: string;
  modelSha256: string; configSha256: string;
}

const catalog = () => JSON.parse(readFileSync(join(tlaDir, "catalog.json"), "utf8")) as Entry[];

function verdictOf(run: TlcRun, expect?: { invariant?: string; property?: string }): "PASS" | "CAUGHT" | "FAIL" {
  if (!expect) return run.exit === 0 && run.completed && run.queued === 0 ? "PASS" : "FAIL";
  if (expect.invariant) return run.exit === 12 && run.violated === expect.invariant ? "CAUGHT" : "FAIL";
  if (run.action !== undefined) return run.exit === 13 && run.action === expect.property ? "CAUGHT" : "FAIL";
  return run.exit === 13 && run.temporal && run.violated === undefined ? "CAUGHT" : "FAIL";
}

export async function runModels(outDir: string, only?: string): Promise<GateResult[]> {
  mkdirSync(outDir, { recursive: true, mode: 0o700 });
  const { java, jar, jarSha256 } = tools();
  const results: GateResult[] = [];
  const save = () => writeFileSync(join(outDir, "gate.json"), JSON.stringify({ java, jar, jarSha256, results }, null, 2));
  for (const entry of catalog()) {
    if (only && entry.module !== only) continue;
    const model = join(tlaDir, `${entry.module}.tla`);
    const record = (kind: GateResult["kind"], run: TlcRun, verdict: GateResult["verdict"], cfgText: string, extra: Partial<GateResult> = {}) => {
      const r: GateResult = {
        module: entry.module, label: run.label, kind, verdict, exit: run.exit, seconds: run.seconds,
        generated: run.generated, distinct: run.distinct, queued: run.queued, log: run.log,
        modelSha256: sha256(model), configSha256: sha256Text(cfgText), ...extra,
      };
      results.push(r);
      save();
      console.log(`${r.verdict.padEnd(8)} ${entry.module.padEnd(19)} ${r.label.padEnd(44)} exit=${r.exit} distinct=${r.distinct ?? "-"} ${r.expected ?? ""}`);
      return r;
    };
    for (const [kind, cfg] of [["smoke", entry.smoke], ["stress", entry.stress]] as const) {
      if (!cfg) continue;
      const cfgText = readFileSync(join(tlaDir, cfg), "utf8");
      const run = await runTlc({ outDir, label: `${entry.module}-${kind}`, module: entry.module, cfgText, timeoutMs: 1_200_000 });
      record(kind, run, verdictOf(run), cfgText);
    }
    const mutants = JSON.parse(readFileSync(join(tlaDir, `${entry.module}.mutants.json`), "utf8")) as Mutant[];
    const source = readFileSync(model, "utf8");
    for (const [index, m] of mutants.entries()) {
      const count = source.split(m.old).length - 1;
      const label = `${entry.module}-mutant-${index + 1}`;
      if (count !== 1) throw new Error(`${label}: 'old' matches ${count} times, needs exactly 1`);
      const base = readFileSync(join(tlaDir, m.config ?? entry.smoke), "utf8");
      const cfgText = m.property ? configWith(base, { onlyProperty: m.property }) : configWith(base, { onlyProperty: "" });
      const run = await runTlc({ outDir, label, module: entry.module, cfgText, files: { [`${entry.module}.tla`]: source.replace(m.old, m.new) } });
      record("mutant", run, verdictOf(run, m), cfgText, { expected: m.invariant ?? m.property, description: m.description });
    }
    for (const [index, f] of entry.findings.entries()) {
      const base = readFileSync(join(tlaDir, f.config), "utf8");
      const cfgText = f.only && f.invariant ? configWith(base, { invariants: [f.invariant] }) : base;
      const run = await runTlc({ outDir, label: `${entry.module}-finding-${index + 1}`, module: entry.module, cfgText });
      const v = verdictOf(run, f);
      record("finding", run, v === "CAUGHT" ? "FINDING" : "FAIL", cfgText, { expected: f.invariant ?? f.property });
    }
    for (const cfg of entry.repair) {
      const cfgText = readFileSync(join(tlaDir, cfg), "utf8");
      const run = await runTlc({ outDir, label: `${entry.module}-repair-${cfg.split(".")[1]}`, module: entry.module, cfgText });
      record("repair", run, verdictOf(run), cfgText);
    }
  }
  return results;
}

if (import.meta.main) {
  const out = process.argv[2];
  if (!out) throw new Error("Usage: bun model.ts NEW_OUTPUT_DIRECTORY [--model NAME]");
  const at = process.argv.indexOf("--model");
  const results = await runModels(resolve(out), at > 0 ? process.argv[at + 1] : undefined);
  const failed = results.filter((r) => r.verdict === "FAIL");
  console.log(`${results.length} runs, ${failed.length} failed`);
  process.exitCode = failed.length ? 1 : 0;
}
