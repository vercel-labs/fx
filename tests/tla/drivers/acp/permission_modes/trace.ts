// TLC trace validation: turns one observed run into the generated
// AcpPermissionModesObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpPermissionModes.tla (through tests/tla/acp/AcpPermissionModesTrace.tla).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Observation } from "./harness";
import { runTlc, sha256Text, writeJson } from "./tlc";

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

export function obsModule(observations: Observation[], profile: string, values: string[]): string {
  const record = (o: Observation) => {
    const v = o.view;
    const view = `[current |-> ${tla(v.current)}, legacy |-> ${tla(v.legacy)}, listed |-> ${tla(v.listed)}, legacyListed |-> ${tla(v.legacyListed)}, names |-> ${tla(v.names)}, schemaOk |-> ${bool(v.schemaOk)}]`;
    return `[op |-> ${tla(o.op)}, arg |-> ${tla(o.arg)}, ok |-> ${bool(o.ok)}, hasView |-> ${bool(o.hasView)}, view |-> ${view}, enforce |-> ${tla(o.enforce)}, stored |-> ${tla(o.stored)}]`;
  };
  return [
    "--------------------- MODULE AcpPermissionModesObs ---------------------",
    "(* Generated from one observed fx acp run. *)",
    `TProfiles == {${tla(profile)}}`,
    `TValues == {${[...new Set(values)].map(tla).join(", ")}}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Profiles <- TProfiles",
  "    Values <- TValues",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export async function validate(observations: Observation[], dir: string, profile: string) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, reason: "empty trace", matched: 0, firstDivergence: null };
  const values = ["auto", "ask", "full-access", ...observations.filter((o) => o.op === "set" || o.op === "legacy").map((o) => o.arg)];
  const obs = obsModule(observations, profile, values);
  writeFileSync(join(dir, "AcpPermissionModesObs.tla"), obs);
  writeFileSync(join(dir, "AcpPermissionModesTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpPermissionModesTrace.tla", "AcpPermissionModesTrace.cfg", ["AcpPermissionModes.tla", "AcpPermissionModesTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  let matched: number;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) {
    verdict = "ACCEPTED";
    matched = observations.length;
  } else if (run.exitCode === 0 && /No error has been found/.test(run.output)) {
    verdict = "REJECTED";
    // The trace's states are i = 1..k, so the search depth is how many steps matched.
    matched = run.distinctStates === 0 ? 0 : run.depth ?? 0;
  } else {
    verdict = "TOOL_ERROR";
    matched = 0;
  }
  const result = {
    verdict,
    matched,
    length: observations.length,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
