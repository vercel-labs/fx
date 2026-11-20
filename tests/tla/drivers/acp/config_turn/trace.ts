// TLC trace validation: turns one observed run of the real fx acp binary into
// the generated AcpConfigTurnObs module and asks TLC whether it is a behavior
// of tests/tla/acp/AcpConfigTurn.tla, through AcpConfigTurnTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// One step as the model's ClientStep reads it. A prompt is one the client
/// sent. A request is one model request the fake Gateway got, with `ver` the
/// settings version its model names (-2 when it names none). A config is a
/// set_config_option answer, "ok" or "busy". A response is a prompt's answer.
export type Observation = {
  op: "prompt" | "request" | "config" | "response";
  ver?: number;
  answer?: "ok" | "busy";
  provider?: string;
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

/// The generated module. Every record carries every field, with -1 and "none"
/// where a step does not use one. The T constants are what this run needs.
export function obsModule(observations: Observation[], rules: boolean): string {
  const prompts = observations.filter((o) => o.op === "prompt").length;
  const changes = observations.filter((o) => o.op === "config").length;
  let inTurn = 0;
  let maxRequests = 0;
  for (const o of observations) {
    if (o.op === "prompt") inTurn = 0;
    if (o.op === "request") {
      inTurn += 1;
      maxRequests = Math.max(maxRequests, inTurn);
    }
  }
  const record = (o: Observation) =>
    `[op |-> ${tla(o.op)}, ver |-> ${o.ver ?? -1}, answer |-> ${tla(o.answer ?? "none")}, provider |-> ${tla(o.provider ?? "none")}]`;
  return [
    "---------------------- MODULE AcpConfigTurnObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(rules)}`,
    "TProviders == {\"gateway\", \"codex\"}",
    `TMaxTurns == ${prompts}`,
    `TMaxRequests == ${maxRequests}`,
    `TMaxChanges == ${changes}`,
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
  "    Providers <- TProviders",
  "    MaxTurns <- TMaxTurns",
  "    MaxRequests <- TMaxRequests",
  "    MaxChanges <- TMaxChanges",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model with `Rules` set to `rules`.
export async function validate(observations: Observation[], dir: string, rules: boolean) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, rules);
  writeFileSync(join(dir, "AcpConfigTurnObs.tla"), obs);
  writeFileSync(join(dir, "AcpConfigTurnTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpConfigTurnTrace.tla", "AcpConfigTurnTrace.cfg", ["AcpConfigTurn.tla", "AcpConfigTurnTrace.tla"]);
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
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
