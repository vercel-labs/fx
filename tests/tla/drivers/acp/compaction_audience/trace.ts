// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpCompactionAudienceObs module, and asks TLC whether it is a behavior
// of tests/tla/acp/AcpCompactionAudience.tla, through AcpCompactionAudienceTrace.tla.
// The model is design "a", with Mutation "none" (the design) or "today" (fx acp
// before the change). A run is ACCEPTED when TLC matches every observation; a
// rejected run reports the longest prefix TLC accepts, found by binary search.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Member = "m1" | "m2" | "m3";
export type Msg = "in_progress" | "completed" | "failed" | "cancelled" | "done";
export type Mutation = "none" | "today";
export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// What the driver observed, in order. Each one is a step the driver took, or a message
/// fx wrote that one client read. `m1` is the main client, the one on stdio.
export type Obs =
  | { op: "start" }
  | { op: "join"; who: Member }
  | { op: "leave"; who: Member }
  | { op: "main_gone" }
  | { op: "read"; who: Member; msg: Msg }
  | { op: "settle"; arg: "completed" | "failed" | "cancelled" }
  | { op: "quiet" };

const tla = (value: string) => JSON.stringify(value);

/// One observation as a TLA record. Every record has the same four fields, so the
/// trace reads any of them; a field an observation does not use is "none".
function record(o: Obs): string {
  const fields = { op: o.op, who: "none", msg: "none", arg: "none" };
  if ("who" in o) fields.who = o.who;
  if (o.op === "read") fields.msg = o.msg;
  if (o.op === "settle") fields.arg = o.arg;
  return `[op |-> ${tla(fields.op)}, who |-> ${tla(fields.who)}, msg |-> ${tla(fields.msg)}, arg |-> ${tla(fields.arg)}]`;
}

/// The generated module: this run's TraceLog, the members that list session.compaction,
/// and the model the trace checks.
export function obsModule(observations: Obs[], mutation: Mutation, listers: Member[]): string {
  return [
    "---------------------- MODULE AcpCompactionAudienceObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "CONSTANTS m1, m2, m3",
    "TMembers == {m1, m2, m3}",
    "TMain == m1",
    `TLists == {${listers.join(", ")}}`,
    'TDesign == "a"',
    'TClass == "nonideal"',
    `TMutation == ${tla(mutation)}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    m1 = m1",
  "    m2 = m2",
  "    m3 = m3",
  "    Members <- TMembers",
  "    Main <- TMain",
  "    Lists <- TLists",
  "    Design <- TDesign",
  "    Class <- TClass",
  "    Mutation <- TMutation",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type TlcRun = Awaited<ReturnType<typeof runTlc>>;

/// Checks the first `prefix.length` observations in `dir`. ACCEPTED is TLC violating
/// NotDone at the last observation; REJECTED is TLC finding no such state.
async function checkPrefix(prefix: Obs[], dir: string, mutation: Mutation, listers: Member[]) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpCompactionAudienceObs.tla"), obsModule(prefix, mutation, listers));
  writeFileSync(join(dir, "AcpCompactionAudienceTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(dir, "AcpCompactionAudienceTrace.tla", "AcpCompactionAudienceTrace.cfg", [
    "AcpCompactionAudience.tla",
    "AcpCompactionAudienceTrace.tla",
  ]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict = "TOOL_ERROR";
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === prefix.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  return { verdict, finalIndex, run };
}

export type Checked = {
  verdict: Verdict;
  /// Observations the model matched: all of them when ACCEPTED, else the longest accepted prefix.
  matched: number;
  length: number;
  mutation: Mutation;
  listers: Member[];
  firstDivergence: { step: number; observation: Obs | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  probes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpCompactionAudience under `mutation`, and writes verdict.json in `dir`.
export async function validate(observations: Obs[], dir: string, mutation: Mutation, listers: Member[]): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), mutation, listers);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const probes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // A prefix that TLC accepts makes every shorter prefix accepted, so the search
    // keeps the longest accepted prefix found: lo is accepted, hi is the longest still possible.
    let lo = 0;
    let hi = length - 1;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      const check = await checkPrefix(observations.slice(0, mid), join(dir, `prefix-${mid}`), mutation, listers);
      probes.push({ length: mid, verdict: check.verdict });
      if (check.verdict === "TOOL_ERROR") {
        verdict = "TOOL_ERROR";
        break;
      }
      if (check.verdict === "ACCEPTED") lo = mid;
      else hi = mid - 1;
    }
    matched = lo;
  }
  const result: Checked = {
    verdict,
    matched,
    length,
    mutation,
    listers,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    full: {
      exitCode: full.run.exitCode,
      violated: full.run.violated,
      finalIndex: full.finalIndex,
      distinctStates: full.run.distinctStates,
      depth: full.run.depth,
    },
    probes,
    obs_sha256: sha256Text(obsModule(observations, mutation, listers)),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
