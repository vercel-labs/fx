// TLC trace validation: turns one observed run of the real fx acp binary into
// the generated AcpDisconnectObs module and asks TLC whether it is a behavior
// of tests/tla/acp/AcpDisconnect.tla, through AcpDisconnectTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// One step as the model's ClientStep reads it. A prompt is one the client sent,
/// queued ones too. A disconnect is the client closing its input. An ask is a
/// write_file reply the fake Gateway served, the point where a turn needs a
/// permission. A response is a prompt's answer from fx: `outcome` is "completed"
/// for end_turn, "interrupted" for cancelled, and "other" for anything else or
/// an error. An exit is fx exiting; `outcomes` holds each saved turn's outcome
/// from a later session/load. A stuck is fx still running after the client left.
export type Observation = {
  op: "prompt" | "disconnect" | "ask" | "response" | "exit" | "stuck";
  outcome?: "completed" | "interrupted" | "other";
  outcomes?: string[];
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

/// The generated module. Every record carries both fields, with "none" and <<>>
/// where a step has no outcome. The T constants are what this run needs.
export function obsModule(observations: Observation[], rules: boolean, keep: boolean): string {
  const prompts = observations.filter((o) => o.op === "prompt").length;
  const record = (o: Observation) =>
    `[op |-> ${tla(o.op)}, outcome |-> ${tla(o.outcome ?? "none")}, outcomes |-> <<${(o.outcomes ?? []).map(tla).join(", ")}>>]`;
  return [
    "---------------------- MODULE AcpDisconnectObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(rules)}`,
    `TKeep == ${bool(keep)}`,
    `TMaxPrompts == ${prompts}`,
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
  "    Keep <- TKeep",
  "    MaxPrompts <- TMaxPrompts",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model with `Rules` set to `rules` and `Keep` to
/// `keep`, the client's own capability.
export async function validate(observations: Observation[], dir: string, rules: boolean, keep: boolean) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, rules, keep);
  writeFileSync(join(dir, "AcpDisconnectObs.tla"), obs);
  writeFileSync(join(dir, "AcpDisconnectTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpDisconnectTrace.tla", "AcpDisconnectTrace.cfg", ["AcpDisconnect.tla", "AcpDisconnectTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  let matched: number;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) {
    verdict = "ACCEPTED";
    matched = observations.length;
  } else if (run.exitCode === 0 && /No error has been found/.test(run.output)) {
    verdict = "REJECTED";
    // TLC counts the initial state as depth 1, so the search depth less one is
    // the number of observations the model matched before it had no next step.
    matched = run.distinctStates === 0 ? 0 : Math.max(0, (run.depth ?? 1) - 1);
  } else {
    verdict = "TOOL_ERROR";
    matched = 0;
  }
  const result = {
    verdict,
    matched,
    length: observations.length,
    rules,
    keep,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
