// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpTakeoverObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpTakeover.tla, through AcpTakeoverTrace.tla. An accepted run
// takes one TLC run. A rejected run also reports how many of its observations the
// model matched: the longest prefix that TLC accepts.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson, SPEC_DIR } from "./tlc";

export type Proc = "p1" | "p2" | "p3";
export type Mutation = "none" | "today";

/// One observation of the run. `proc` names the process, or the lock read's
/// target (none, other, or a process). `arg` carries a stop reason, a folder
/// state, a count, or the name of an answer.
export type Obs = { op: string; proc?: string; arg?: string | number };

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const PROCS: Proc[] = ["p1", "p2", "p3"];
const tla = (value: string) => JSON.stringify(value);

/// The generated module: the run's TraceLog, the constants this run needs, and
/// the mapping from a process name in the log to its model value.
export function obsModule(observations: Obs[], mutation: Mutation): string {
  const record = (o: Obs) => {
    const proc = o.proc ?? "none";
    const arg = typeof o.arg === "number" ? String(o.arg) : tla(o.arg ?? "none");
    return `[op |-> ${tla(o.op)}, proc |-> ${tla(proc)}, arg |-> ${arg}]`;
  };
  return [
    "---------------------- MODULE AcpTakeoverObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "CONSTANTS p1, p2, p3",
    `TProcs == {${PROCS.join(", ")}}`,
    `TMutation == ${tla(mutation)}`,
    'P(name) == CASE name = "p1" -> p1 [] name = "p2" -> p2 [] name = "p3" -> p3',
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    p1 = p1",
  "    p2 = p2",
  "    p3 = p3",
  "    Procs <- TProcs",
  "    Mutation <- TMutation",
  "    MaxAsks = 4",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type TlcRun = Awaited<ReturnType<typeof runTlc>>;

/// Checks the first `prefix.length` observations, in `dir`. ACCEPTED is TLC
/// violating NotDone at the last observation; REJECTED is TLC finding no such
/// state.
async function checkPrefix(prefix: Obs[], dir: string, mutation: Mutation) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpTakeoverObs.tla"), obsModule(prefix, mutation));
  writeFileSync(join(dir, "AcpTakeoverTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(
    dir,
    "AcpTakeoverTrace.tla",
    "AcpTakeoverTrace.cfg",
    ["AcpTakeover.tla", "AcpTakeoverTrace.tla"],
    SPEC_DIR,
    [],
  );
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
  mutation: Mutation;
  firstDivergence: { step: number; observation: Obs | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  prefixes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpTakeover under `mutation`, and writes verdict.json in `dir`.
export async function validate(observations: Obs[], dir: string, mutation: Mutation): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), mutation);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const prefixes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // A prefix of an accepted prefix is accepted, so the first rejected prefix ends the search.
    matched = 0;
    for (let k = 1; k < length; k++) {
      const check = await checkPrefix(observations.slice(0, k), join(dir, `prefix-${k}`), mutation);
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
    mutation,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    full: {
      exitCode: full.run.exitCode,
      violated: full.run.violated,
      finalIndex: full.finalIndex,
      distinctStates: full.run.distinctStates,
      depth: full.run.depth,
    },
    prefixes,
    obs_sha256: sha256Text(obsModule(observations, mutation)),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
