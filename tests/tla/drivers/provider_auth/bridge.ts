// Connects runs of the real credential edge to TLC.
//
// 1. The run's events become AuthObserved.tla. AuthTrace replays them through
//    ProviderAuth's own Next under the scenario's constants. ACCEPTED needs TLC
//    exit 12 on the NotAllMatched sentinel; a completed search is REJECTED.
// 2. After acceptance, each property is checked on the same replay.
//
// Unreadable, partial or anomalous evidence is never acceptance.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { observedModule, type Run } from "./driver";
import { completed, constantDefinitions, constantOverrides, hashes, PROPERTIES, runTlc, stage, violated } from "./tlc";

export type TraceVerdict = "ACCEPTED" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";

export interface TraceResult {
  scenario: string;
  verdict: TraceVerdict;
  detail: string;
  events: number;
  properties: Record<string, "HOLDS" | "VIOLATED" | "NOT_CHECKED" | "TOOL_ERROR">;
  report: string;
  hashes: Record<string, string>;
}

export async function checkTrace(run: Run, reportRoot: string): Promise<TraceResult> {
  mkdirSync(reportRoot, { recursive: true, mode: 0o700 });
  const root = mkdtempSync(join(reportRoot, `${run.scenario}-`));
  const properties: TraceResult["properties"] = Object.fromEntries(PROPERTIES.map((p) => [p, "NOT_CHECKED" as const]));
  const finish = (verdict: TraceVerdict, detail: string): TraceResult => {
    const result = { scenario: run.scenario, verdict, detail, events: run.events.length, properties, report: root, hashes: hashes() };
    writeFileSync(join(root, "verdict.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
    return result;
  };
  writeFileSync(join(root, "run.json"), JSON.stringify(run, null, 2), { mode: 0o600 });
  if (!run.events.length) return finish("INCONCLUSIVE", "empty run");
  if (run.anomalies.length) return finish("INCONCLUSIVE", `driver anomalies: ${run.anomalies.join("; ")}`);

  const observed = observedModule(run, constantDefinitions(run.setup));
  const cfg = (invariant: string) => `SPECIFICATION TraceSpec\nINVARIANT ${invariant}\nCONSTANTS\n${constantOverrides}\n`;
  const conformance = await runTlc(stage(root, "conformance", { "AuthObserved.tla": observed }), "AuthTrace.tla", cfg("NotAllMatched"));
  if (!(conformance.exitCode === 12 && violated(conformance.log, "NotAllMatched"))) {
    if (conformance.exitCode === 0 && completed(conformance.log)) {
      return finish("REJECTED", `the run diverges from the model; see ${join(conformance.dir, "tlc.log")}`);
    }
    return finish("TOOL_ERROR", `unexpected TLC exit ${conformance.exitCode}; see ${join(conformance.dir, "tlc.log")}`);
  }
  for (const property of PROPERTIES) {
    const check = await runTlc(stage(root, `property-${property}`, { "AuthObserved.tla": observed }), "AuthTrace.tla", cfg(property));
    properties[property] = check.exitCode === 0 && completed(check.log) ? "HOLDS"
      : check.exitCode === 12 && violated(check.log, property) ? "VIOLATED" : "TOOL_ERROR";
  }
  return finish("ACCEPTED", `all ${run.events.length} events match the model`);
}
