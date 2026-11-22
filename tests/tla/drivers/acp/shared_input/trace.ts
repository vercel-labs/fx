// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpSharedInputObs module, and asks TLC whether it is a behavior of
// tests/tla/acp/AcpSharedInput.tla, through AcpSharedInputTrace.tla. An accepted
// run takes one TLC run. A rejected run also reports the longest prefix that
// TLC accepts, found by bisection: a prefix of an accepted run is accepted.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Who = "owner" | "follower";
export type Req = { who: Who; n: number };
export type Kind = "none" | "steer" | "queue";
export type Sys = "old" | "new" | "other";
export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// What the driver observed, in order. Each one is fx's output or the driver's act.
export type Obs =
  | { op: "join"; rs: Req[] }
  | { op: "join_refused" }
  | { op: "load"; v: Sys }
  | { op: "start"; r: Req; k: Kind; v: Sys }
  | { op: "refuse"; r: Req; k: Kind; code: number }
  | { op: "queued"; r: Req }
  | { op: "pending"; r: Req }
  | { op: "chunks"; r: Req; to: Who[] }
  | { op: "absorb"; rs: Req[]; to: Who[] }
  | { op: "request"; v: Sys }
  | { op: "started"; r: Req; v: Sys }
  | { op: "idle" }
  | { op: "finish"; rs: Req[]; ok: boolean }
  | { op: "cancel"; by: Who }
  | { op: "stopped"; rs: Req[]; by: Who; ok: boolean }
  | { op: "leave"; who: Who }
  | { op: "unmatched"; what: string }
  | { op: "end" };

const q = (value: string) => JSON.stringify(value);
const tlaReq = (r: Req) => `<<${q(r.who)}, ${r.n}>>`;
const tlaSet = (items: string[]) => `{${items.join(", ")}}`;
const tlaBool = (value: boolean) => (value ? "TRUE" : "FALSE");

const FIELDS = ["op", "r", "k", "v", "to", "rs", "code", "ok", "by"] as const;

/// One observation as a TLA record. Every record has the same fields, so the
/// trace module reads any of them; a field an observation does not use has a
/// fixed default.
export function record(o: Obs): string {
  const f: Record<(typeof FIELDS)[number], string> = {
    op: q(o.op), r: `<<"none", 0>>`, k: q("none"), v: q("none"), to: "{}", rs: "{}", code: "0", ok: "TRUE", by: q("none"),
  };
  switch (o.op) {
    case "join":
      f.rs = tlaSet(o.rs.map(tlaReq));
      break;
    case "start":
      f.r = tlaReq(o.r);
      f.k = q(o.k);
      f.v = q(o.v);
      break;
    case "refuse":
      f.r = tlaReq(o.r);
      f.k = q(o.k);
      // TLA+ has no negative literals: the model compares the magnitude of the code.
      f.code = String(Math.abs(o.code));
      break;
    case "load":
      f.v = q(o.v);
      break;
    case "queued":
    case "pending":
      f.r = tlaReq(o.r);
      break;
    case "chunks":
      f.r = tlaReq(o.r);
      f.to = tlaSet(o.to.map(q));
      break;
    case "absorb":
      f.rs = tlaSet(o.rs.map(tlaReq));
      f.to = tlaSet(o.to.map(q));
      break;
    case "request":
      f.v = q(o.v);
      break;
    case "started":
      f.r = tlaReq(o.r);
      f.v = q(o.v);
      break;
    case "finish":
      f.rs = tlaSet(o.rs.map(tlaReq));
      f.ok = tlaBool(o.ok);
      break;
    case "cancel":
      f.by = q(o.by);
      break;
    case "stopped":
      f.rs = tlaSet(o.rs.map(tlaReq));
      f.by = q(o.by);
      f.ok = tlaBool(o.ok);
      break;
    case "leave":
      f.by = q(o.who);
      break;
    default:
      break;
  }
  return `[${FIELDS.map((name) => `${name} |-> ${f[name]}`).join(", ")}]`;
}

/// The generated module: this run's TraceLog and the rules flag it checks against.
export function obsModule(observations: Obs[], rules: boolean): string {
  return [
    "---------------------- MODULE AcpSharedInputObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    `TRules == ${tlaBool(rules)}`,
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
  "    MaxSends = 2",
  "    FollowerSends = 1",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type TlcRun = Awaited<ReturnType<typeof runTlc>>;

/// Checks the first `prefix.length` observations, in `dir`. ACCEPTED is TLC
/// violating NotDone at the last observation; REJECTED is TLC finding no such state.
async function checkPrefix(prefix: Obs[], dir: string, rules: boolean) {
  mkdirSync(dir, { recursive: true });
  const module = obsModule(prefix, rules);
  writeFileSync(join(dir, "AcpSharedInputObs.tla"), module);
  writeFileSync(join(dir, "AcpSharedInputTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(dir, "AcpSharedInputTrace.tla", "AcpSharedInputTrace.cfg", ["AcpSharedInput.tla", "AcpSharedInputTrace.tla"]);
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
  firstDivergence: { step: number; observation: Obs | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  prefixes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpSharedInput with Rules set to `rules`, and writes
/// verdict.json in `dir`.
export async function validate(observations: Obs[], dir: string, rules: boolean): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), rules);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const prefixes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // The empty prefix is taken as matched. Bisect for the longest accepted prefix.
    let low = 0;
    let high = length - 1;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      const check = await checkPrefix(observations.slice(0, middle), join(dir, `prefix-${middle}`), rules);
      prefixes.push({ length: middle, verdict: check.verdict });
      if (check.verdict === "TOOL_ERROR") {
        verdict = "TOOL_ERROR";
        break;
      }
      if (check.verdict === "ACCEPTED") low = middle;
      else high = middle - 1;
    }
    matched = verdict === "TOOL_ERROR" ? 0 : low;
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
