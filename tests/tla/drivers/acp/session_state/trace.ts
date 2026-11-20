// TLC trace validation: turns one observed run into the generated
// AcpSessionStateObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpSessionState.tla, through AcpSessionStateTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type StatusAnswer = { kind: "ok" | "unknown" | "no_method" | "busy" | "none"; status: string; state: string };

/// One step of the run, with what the driver observed.
export type Observation = {
  act: "open" | "close" | "prompt" | "end" | "list" | "status" | "sync";
  s: string;
  stop: string;
  f: string;
  refused: boolean;
  rows: Record<string, string>;
  answer: StatusAnswer;
  states: number;
  hints: number;
};

export type Bounds = { rules: boolean; sessions: string[]; maxTurns: number };

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

export function obsModule(observations: Observation[], bounds: Bounds): string {
  const rows = (o: Observation) => `[${bounds.sessions.map((s) => `${s} |-> ${tla(o.rows[s] ?? "absent")}`).join(", ")}]`;
  const answer = (a: StatusAnswer) => `[kind |-> ${tla(a.kind)}, status |-> ${tla(a.status)}, state |-> ${tla(a.state)}]`;
  const record = (o: Observation) =>
    `[act |-> ${tla(o.act)}, s |-> ${tla(o.s)}, stop |-> ${tla(o.stop)}, f |-> ${tla(o.f)}, refused |-> ${bool(o.refused)}, rows |-> ${rows(o)}, answer |-> ${answer(o.answer)}, states |-> ${o.states}, hints |-> ${o.hints}]`;
  return [
    "---------------------- MODULE AcpSessionStateObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(bounds.rules)}`,
    `TSessions == {${bounds.sessions.map(tla).join(", ")}}`,
    `TFolderOf == [s \\in TSessions |-> "A"]`,
    `TMaxTurns == ${bounds.maxTurns}`,
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
  "    Conns = {\"c1\"}",
  "    Sessions <- TSessions",
  "    FolderOf <- TFolderOf",
  "    MaxTurns <- TMaxTurns",
  "    MaxChanges = 0",
  "    AllowApproval = FALSE",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// Runs TLC on one observed run, and says whether the model accepts it.
async function check(observations: Observation[], dir: string, bounds: Bounds) {
  mkdirSync(dir, { recursive: true });
  const obs = obsModule(observations, bounds);
  writeFileSync(join(dir, "AcpSessionStateObs.tla"), obs);
  writeFileSync(join(dir, "AcpSessionStateTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpSessionStateTrace.tla", "AcpSessionStateTrace.cfg", ["AcpSessionState.tla", "AcpSessionStateTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  const verdict: Verdict =
    run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length ? "ACCEPTED"
    : run.exitCode === 0 && /No error has been found/.test(run.output) ? "REJECTED"
    : "TOOL_ERROR";
  return { verdict, run, finalIndex, obs };
}

export async function validate(observations: Observation[], dir: string, bounds: Bounds) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const { verdict, run, finalIndex, obs } = await check(observations, dir, bounds);
  let matched = verdict === "ACCEPTED" ? observations.length : 0;
  if (verdict === "REJECTED") {
    // Client reads don't advance i, so TLC's depth doesn't give the first
    // step that fails. Find the longest prefix the model accepts instead.
    let low = 0;
    let high = observations.length - 1;
    while (low < high) {
      const mid = Math.ceil((low + high) / 2);
      const prefix = await check(observations.slice(0, mid), join(dir, "prefixes", String(mid)), bounds);
      if (prefix.verdict === "ACCEPTED") low = mid;
      else high = mid - 1;
    }
    matched = low;
  }
  const result = {
    verdict,
    matched,
    length: observations.length,
    bounds,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
