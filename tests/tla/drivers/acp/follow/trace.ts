// TLC trace validation: turns one observed run into the generated
// AcpFollowObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpFollow.tla, through AcpFollowTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// One message of one turn as the model's `has` records it: the turn's
/// number, the id as a number (`n` of a `turn-{n}-{k}` id, -1 for any other),
/// and whether a load replayed it.
export type Held = { turn: number; id: number; replayed: boolean };

/// One step as the model's `Obs` record describes it.
export type Observation = {
  op: "open" | "save" | "close";
  has: Held[];
  detail?: unknown;
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

export function obsModule(observations: Observation[], idRules: boolean): string {
  const held = (value: Held) =>
    `[turn |-> ${value.turn}, id |-> ${value.id}, replayed |-> ${bool(value.replayed)}]`;
  const record = (o: Observation) =>
    `[op |-> ${tla(o.op)}, has |-> <<${o.has.map(held).join(", ")}>>]`;
  const saves = observations.filter((o) => o.op === "save").length;
  return [
    "---------------------- MODULE AcpFollowObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TIdRules == ${bool(idRules)}`,
    "TConns == {\"c1\"}",
    "TFolders == {\"w1\"}",
    `TMaxTurns == ${saves}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Rules = FALSE",
  "    IdRules <- TIdRules",
  "    Conns <- TConns",
  "    Folders <- TFolders",
  "    MaxTurns <- TMaxTurns",
  "    MaxCompactions = 0",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model with `IdRules` set to `idRules`.
export async function validate(observations: Observation[], dir: string, idRules: boolean) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, idRules);
  writeFileSync(join(dir, "AcpFollowObs.tla"), obs);
  writeFileSync(join(dir, "AcpFollowTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpFollowTrace.tla", "AcpFollowTrace.cfg", ["AcpFollow.tla", "AcpFollowTrace.tla"]);
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
    idRules,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
