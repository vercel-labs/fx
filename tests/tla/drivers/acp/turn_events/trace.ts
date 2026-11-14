// TLC trace validation: turns one observed run into the generated
// AcpTurnEventsObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpTurnEvents.tla, through AcpTurnEventsTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// A prompt the client sent, or a message it read. A response also carries
/// what the driver knows from its fake Gateway about the turn.
export type Observation =
  | { kind: "prompt" }
  | { kind: "progress" }
  | { kind: "call" }
  | { kind: "comp"; k: number; status: string }
  | { kind: "response"; usage: boolean; calls: number; streamed: boolean; compacted: boolean };

export type Parts = Array<"progress" | "calls" | "usage" | "compaction">;

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

function record(o: Observation): string {
  const k = o.kind === "comp" ? o.k : 0;
  const status = o.kind === "comp" ? o.status : "none";
  const response = o.kind === "response" ? o : { usage: false, calls: 0, streamed: false, compacted: false };
  return `[kind |-> ${tla(o.kind)}, k |-> ${k}, status |-> ${tla(status)}, usage |-> ${bool(response.usage)}, ` +
    `calls |-> ${response.calls}, streamed |-> ${bool(response.streamed)}, compacted |-> ${bool(response.compacted)}]`;
}

/// The bounds a run needs: the most progress messages and model calls in one
/// turn, and the compactions it saw, each at least 1.
export function bounds(observations: Observation[]) {
  let progress = 0, calls = 0, turns = 0, perProgress = 0, ks = 0;
  for (const o of observations) {
    if (o.kind === "prompt") { turns += 1; perProgress = 0; }
    if (o.kind === "progress") progress = Math.max(progress, ++perProgress);
    if (o.kind === "response") calls = Math.max(calls, o.calls);
    if (o.kind === "comp") ks = Math.max(ks, o.k);
  }
  return { maxProgress: Math.max(progress, 1), maxCalls: Math.max(calls, 1), maxTurns: Math.max(turns, 1), ks: Math.max(ks, 1) };
}

export function obsModule(observations: Observation[], rules: boolean, parts: Parts): string {
  const b = bounds(observations);
  return [
    "------------------------ MODULE AcpTurnEventsObs ------------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(rules)}`,
    `TParts == {${parts.map(tla).join(", ")}}`,
    `TKs == 1..${b.ks}`,
    `TMaxProgress == ${b.maxProgress}`,
    `TMaxCalls == ${b.maxCalls}`,
    `TMaxTurns == ${b.maxTurns}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Rules <- TRules",
  "    Parts <- TParts",
  "    Ks <- TKs",
  "    MaxProgress <- TMaxProgress",
  "    MaxCalls <- TMaxCalls",
  "    MaxTurns <- TMaxTurns",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model, with `Rules` set to `rules`.
export async function validate(observations: Observation[], dir: string, rules: boolean, parts: Parts) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, rules, parts);
  writeFileSync(join(dir, "AcpTurnEventsObs.tla"), obs);
  writeFileSync(join(dir, "AcpTurnEventsTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpTurnEventsTrace.tla", "AcpTurnEventsTrace.cfg", ["AcpTurnEvents.tla", "AcpTurnEventsTrace.tla"]);
  const indexes = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1]));
  const finalIndex = indexes.at(-1) ?? null;
  let verdict: Verdict;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  else verdict = "TOOL_ERROR";
  const result = {
    verdict,
    length: observations.length,
    rules,
    parts,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, distinctStates: run.distinctStates, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
