// TLC trace validation: turns one observed run into the generated
// AcpTurnEventsObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpTurnEvents.tla, through AcpTurnEventsTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// A prompt the client sent, or a message it read. A shell call's last
/// tool_call_update records where its command result was: "meta" in
/// sh.fx/commandResult, "root" in a root command_result field, "both", or
/// "none". A response also carries what the driver knows from its fake
/// Gateway about the turn.
export type Observation =
  | { kind: "prompt" }
  | { kind: "progress" }
  | { kind: "call" }
  | { kind: "comp"; k: number; status: string }
  | { kind: "tool"; status: "meta" | "root" | "both" | "none" }
  | { kind: "response"; usage: boolean; calls: number; shells: number; streamed: boolean; compacted: boolean };

export type Parts = Array<"progress" | "calls" | "usage" | "compaction" | "command">;

/// rules: the S8d and S8g rules. today: fx acp before S8d. root-field: fx acp
/// with S8d's rules but before S8g, which put a shell call's command result
/// at the root of its update.
export type Model = "rules" | "today" | "root-field";

const MODELS: Record<Model, { rules: boolean; commandMeta: boolean }> = {
  rules: { rules: true, commandMeta: true },
  today: { rules: false, commandMeta: false },
  "root-field": { rules: true, commandMeta: false },
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

function record(o: Observation): string {
  const k = o.kind === "comp" ? o.k : 0;
  const status = o.kind === "comp" || o.kind === "tool" ? o.status : "none";
  const response = o.kind === "response" ? o : { usage: false, calls: 0, shells: 0, streamed: false, compacted: false };
  return `[kind |-> ${tla(o.kind)}, k |-> ${k}, status |-> ${tla(status)}, usage |-> ${bool(response.usage)}, ` +
    `calls |-> ${response.calls}, shells |-> ${response.shells}, streamed |-> ${bool(response.streamed)}, compacted |-> ${bool(response.compacted)}]`;
}

/// The bounds a run needs: the most progress messages, model calls, and
/// shell calls in one turn, and the compactions it saw, each at least 1.
export function bounds(observations: Observation[]) {
  let progress = 0, calls = 0, shells = 0, turns = 0, perProgress = 0, ks = 0;
  for (const o of observations) {
    if (o.kind === "prompt") { turns += 1; perProgress = 0; }
    if (o.kind === "progress") progress = Math.max(progress, ++perProgress);
    if (o.kind === "response") { calls = Math.max(calls, o.calls); shells = Math.max(shells, o.shells); }
    if (o.kind === "comp") ks = Math.max(ks, o.k);
  }
  return { maxProgress: Math.max(progress, 1), maxCalls: Math.max(calls, 1), maxShells: Math.max(shells, 1), maxTurns: Math.max(turns, 1), ks: Math.max(ks, 1) };
}

export function obsModule(observations: Observation[], model: Model, parts: Parts): string {
  const b = bounds(observations);
  const { rules, commandMeta } = MODELS[model];
  return [
    "------------------------ MODULE AcpTurnEventsObs ------------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(rules)}`,
    `TCommandMeta == ${bool(commandMeta)}`,
    `TParts == {${parts.map(tla).join(", ")}}`,
    `TKs == 1..${b.ks}`,
    `TMaxProgress == ${b.maxProgress}`,
    `TMaxCalls == ${b.maxCalls}`,
    `TMaxShells == ${b.maxShells}`,
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
  "    CommandMeta <- TCommandMeta",
  "    Parts <- TParts",
  "    Ks <- TKs",
  "    MaxProgress <- TMaxProgress",
  "    MaxCalls <- TMaxCalls",
  "    MaxShells <- TMaxShells",
  "    MaxTurns <- TMaxTurns",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model that `model` names.
export async function validate(observations: Observation[], dir: string, model: Model, parts: Parts) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, model, parts);
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
    model,
    parts,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, distinctStates: run.distinctStates, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
