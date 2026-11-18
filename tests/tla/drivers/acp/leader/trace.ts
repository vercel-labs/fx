// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpLeaderObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpLeader.tla, through AcpLeaderTrace.tla. An accepted run takes
// one TLC run. A rejected run also reports how many of its observations the model
// matched, found as the longest prefix that TLC accepts.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Proc = "p1" | "p2";

/// One observation of the run. A read names the process its lock record names:
/// a process the driver started, or "other" for a pid it did not start.
export type Observation =
  | { op: "start"; proc: Proc; canListen: boolean }
  | { op: "published"; proc: Proc }
  | { op: "read"; target: "none" | Proc | "other" }
  | { op: "connect"; result: "connected" | "stale" }
  | { op: "ask"; result: "found" | "notleader" }
  | { op: "exit"; proc: Proc }
  | { op: "kill"; proc: Proc };

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

/// The fields every record carries. Where a step has no value, the field is
/// "none", and canListen is FALSE.
function fields(o: Observation) {
  return {
    op: o.op,
    proc: "proc" in o ? o.proc : "none",
    canListen: o.op === "start" ? o.canListen : false,
    target: o.op === "read" ? o.target : "none",
    result: "result" in o ? o.result : "none",
  };
}

/// The generated module: the run's TraceLog, the constants this run needs, and
/// the mapping from a process name in the log to its model value.
export function obsModule(observations: Observation[], records: boolean): string {
  const record = (o: Observation) => {
    const f = fields(o);
    return `[op |-> ${tla(f.op)}, proc |-> ${tla(f.proc)}, canListen |-> ${bool(f.canListen)}, target |-> ${tla(f.target)}, result |-> ${tla(f.result)}]`;
  };
  return [
    "---------------------- MODULE AcpLeaderObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "CONSTANTS p1, p2",
    `TRecords == ${bool(records)}`,
    "TProcs == {p1, p2}",
    'P(name) == CASE name = "p1" -> p1 [] name = "p2" -> p2',
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
  "    Records <- TRecords",
  "    Procs <- TProcs",
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
async function checkPrefix(prefix: Observation[], dir: string, records: boolean) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpLeaderObs.tla"), obsModule(prefix, records));
  writeFileSync(join(dir, "AcpLeaderTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(dir, "AcpLeaderTrace.tla", "AcpLeaderTrace.cfg", ["AcpLeader.tla", "AcpLeaderTrace.tla"]);
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
  records: boolean;
  firstDivergence: { step: number; observation: Observation | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  prefixes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpLeader with Records set to `records`, and writes
/// verdict.json in `dir`.
export async function validate(observations: Observation[], dir: string, records: boolean): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), records);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const prefixes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // A prefix of an accepted prefix is accepted, so the first prefix TLC rejects ends the search.
    matched = 0;
    for (let k = 1; k < length; k++) {
      const check = await checkPrefix(observations.slice(0, k), join(dir, `prefix-${k}`), records);
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
    records,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    full: {
      exitCode: full.run.exitCode,
      violated: full.run.violated,
      finalIndex: full.finalIndex,
      distinctStates: full.run.distinctStates,
      depth: full.run.depth,
    },
    prefixes,
    obs_sha256: sha256Text(obsModule(observations, records)),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
