// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpJoinObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpJoin.tla, through AcpJoinTrace.tla. An accepted run takes one
// TLC run. A rejected run also reports how many of its observations the model
// matched, found as the longest prefix that TLC accepts.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Item } from "./harness";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// What the driver observed, in the order it observed it. Each item is fx's text,
/// its answer, or its refusal; the driver's own steps are start and the releases
/// it allows in the model.
export type Observation =
  | { op: "start" }
  | { op: "send"; item: Item }
  | { op: "end"; turn: number }
  | { op: "load" | "resume"; who: Joiner; seq: Item[] }
  | { op: "load_refused" | "resume_refused"; who: Joiner }
  | { op: "close"; who: Joiner }
  | { op: "close_failed"; who: Joiner }
  | { op: "change_refused"; who: Joiner }
  | { op: "change_other"; who: Joiner }
  | { op: "finish"; who: Joiner; seq: Item[] };

export type Joiner = "j1" | "j2";
export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const item = (value: Item) => `[t |-> ${value.t}, k |-> ${value.k}]`;
const sequence = (items: Item[]) => `<<${items.map(item).join(", ")}>>`;

/// One observation as a TLA record. Every record has the same fields: `who` names
/// the joiner, `n` the turn, and `seq` the items the step checks.
function record(o: Observation): string {
  const who = "who" in o ? o.who : "none";
  const n = o.op === "end" ? o.turn : 0;
  const seq = o.op === "send" ? [o.item] : "seq" in o ? o.seq : [];
  return `[op |-> ${tla(o.op)}, who |-> ${tla(who)}, n |-> ${n}, seq |-> ${sequence(seq)}]`;
}

/// The generated module: this run's TraceLog, and the constants this run needs. The
/// trace config sets Rules to TRules, so one module serves both models.
export function obsModule(observations: Observation[], rules: boolean): string {
  return [
    "---------------------- MODULE AcpJoinObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "CONSTANTS j1, j2",
    "TJoiners == {j1, j2}",
    `TRules == ${bool(rules)}`,
    "TMaxTurns == 2",
    "TMaxSends == 2",
    // Two items per turn at most, and a copy holds one turn's items at a time: a
    // limit of two never drops in these plans.
    "TLimit == 2",
    'J(name) == CASE name = "j1" -> j1 [] name = "j2" -> j2',
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    j1 = j1",
  "    j2 = j2",
  "    Joiners <- TJoiners",
  "    MaxTurns <- TMaxTurns",
  "    MaxSends <- TMaxSends",
  "    Limit <- TLimit",
  "    Rules <- TRules",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type TlcRun = Awaited<ReturnType<typeof runTlc>>;

/// Checks the first `prefix.length` observations, in `dir`. ACCEPTED is TLC
/// violating NotDone at the last observation; REJECTED is TLC finding no such state.
async function checkPrefix(prefix: Observation[], dir: string, rules: boolean) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpJoinObs.tla"), obsModule(prefix, rules));
  writeFileSync(join(dir, "AcpJoinTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(dir, "AcpJoinTrace.tla", "AcpJoinTrace.cfg", ["AcpJoin.tla", "AcpJoinTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict = "TOOL_ERROR";
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === prefix.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  return { verdict, finalIndex, run };
}

export type Checked = {
  verdict: Verdict;
  /// Observations the model matched: all of them when ACCEPTED, the longest accepted prefix when REJECTED.
  matched: number;
  length: number;
  rules: boolean;
  firstDivergence: { step: number; observation: Observation | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  prefixes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpJoin with Rules set to `rules`, and writes
/// verdict.json in `dir`.
export async function validate(observations: Observation[], dir: string, rules: boolean): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), rules);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const prefixes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // A prefix of an accepted prefix is accepted, so the first prefix TLC rejects ends the search.
    matched = 0;
    for (let k = 1; k < length; k++) {
      const check = await checkPrefix(observations.slice(0, k), join(dir, `prefix-${k}`), rules);
      prefixes.push({ length: k, verdict: check.verdict });
      if (check.verdict === "TOOL_ERROR") {
        verdict = "TOOL_ERROR";
        break;
      }
      if (check.verdict !== "ACCEPTED") break;
      matched = k;
    }
  }
  const result: Checked = {
    verdict,
    matched,
    length,
    rules,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    full: {
      exitCode: full.run.exitCode,
      violated: full.run.violated,
      finalIndex: full.finalIndex,
      distinctStates: full.run.distinctStates,
      depth: full.run.depth,
    },
    prefixes,
    obs_sha256: sha256Text(obsModule(observations, rules)),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
