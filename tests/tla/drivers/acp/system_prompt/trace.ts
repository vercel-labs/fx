// TLC trace validation: turns one observed run into the generated
// AcpSystemPromptObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpSystemPrompt.tla, through AcpSystemPromptTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// One step as the model's `Obs` record describes it.
export type Observation = {
  op: string;
  arg: string;
  ok: boolean;
  code: number;
  cap: boolean;
  sent: string;
  detail?: unknown;
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

export function obsModule(observations: Observation[], fixed: boolean): string {
  const record = (o: Observation) =>
    `[op |-> ${tla(o.op)}, arg |-> ${tla(o.arg)}, ok |-> ${bool(o.ok)}, code |-> ${o.code}, cap |-> ${bool(o.cap)}, sent |-> ${tla(o.sent)}]`;
  return [
    "---------------------- MODULE AcpSystemPromptObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TFixed == ${bool(fixed)}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Fixed <- TFixed",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model with `Fixed` set to `fixed`.
export async function validate(observations: Observation[], dir: string, fixed: boolean) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, fixed);
  writeFileSync(join(dir, "AcpSystemPromptObs.tla"), obs);
  writeFileSync(join(dir, "AcpSystemPromptTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpSystemPromptTrace.tla", "AcpSystemPromptTrace.cfg", ["AcpSystemPrompt.tla", "AcpSystemPromptTrace.tla"]);
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
    fixed,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
