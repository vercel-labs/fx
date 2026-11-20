// TLC trace validation: turns one observed run into the generated
// AcpSessionsObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpSessions.tla, through AcpSessionsTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// What the client saw after one step. `answers` holds every prompt's
/// answer in key order: A's prompts 1..max, then B's.
export type Observation = {
  act: string;
  sid: string;
  ws: string;
  ok: boolean;
  answers: string[];
  tags: Array<[[string, number], string]>;
  writes: Array<[[string, number], string]>;
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const key = ([sid, n]: [string, number]) => `<<${tla(sid)}, ${n}>>`;

export function obsModule(observations: Observation[], rules: boolean, maxPrompts: number, maxLoads: number): string {
  const record = (o: Observation) => [
    `[act |-> ${tla(o.act)}, sid |-> ${tla(o.sid)}, ws |-> ${tla(o.ws)}, ok |-> ${bool(o.ok)},`,
    `     answers |-> <<${o.answers.map(tla).join(", ")}>>,`,
    `     tags |-> {${o.tags.map(([k, tag]) => `<<${key(k)}, ${tla(tag)}>>`).join(", ")}},`,
    `     writes |-> {${o.writes.map(([k, used]) => `<<${key(k)}, ${tla(used)}>>`).join(", ")}}]`,
  ].join("\n");
  return [
    "------------------------ MODULE AcpSessionsObs ------------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(rules)}`,
    `TMaxPrompts == ${maxPrompts}`,
    `TMaxLoads == ${maxLoads}`,
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
  "    MaxPrompts <- TMaxPrompts",
  "    MaxLoads <- TMaxLoads",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Checks one run against the model, with `Rules` set to `rules`.
export async function validate(observations: Observation[], dir: string, rules: boolean, maxPrompts: number, maxLoads: number) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, rules, maxPrompts, maxLoads);
  writeFileSync(join(dir, "AcpSessionsObs.tla"), obs);
  writeFileSync(join(dir, "AcpSessionsTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpSessionsTrace.tla", "AcpSessionsTrace.cfg", ["AcpSessions.tla", "AcpSessionsTrace.tla"]);
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
    rules,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
