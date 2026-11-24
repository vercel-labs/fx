// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpApprovalsObs module, and asks TLC whether it is a behavior of
// tests/tla/acp/AcpApprovals.tla, through AcpApprovalsTrace.tla. Design "A" is the
// rules fx builds; design "current" is the code before the approvals change. An
// accepted run takes one TLC run. A rejected run also reports the longest prefix
// that TLC accepts, found by bisection: a prefix of an accepted run is accepted.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Client = "opener" | "f1";
export type Opt = "once" | "always" | "reject";
export type Dec = "once" | "always" | "deny";
export type Design = "A" | "current";
export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// What the driver observed, in order. Each one is fx's output or the driver's act.
export type Obs =
  | { op: "join"; c: Client; k: number }
  | { op: "prompt"; c: Client }
  | { op: "ask" }
  | { op: "wrote"; c: Client; k: number }
  | { op: "answer"; c: Client; k: number; opt: Opt }
  | { op: "cancel"; c: Client; k: number }
  | { op: "leave"; c: Client }
  | { op: "sessionCancel"; c: Client }
  | { op: "resolved"; dec: Dec }
  | { op: "turnEnd" }
  | { op: "end" }
  | { op: "unmatched"; what: string };

const q = (value: string) => JSON.stringify(value);

const FIELDS = ["op", "c", "k", "opt", "dec"] as const;

/// One observation as a TLA record. Every record has the same fields, so the trace
/// module reads any of them; a field an observation does not use has a fixed default.
export function record(o: Obs): string {
  const f: Record<(typeof FIELDS)[number], string> = { op: q(o.op), c: q("none"), k: "0", opt: q("none"), dec: q("none") };
  switch (o.op) {
    case "join":
    case "wrote":
    case "cancel":
      f.c = q(o.c);
      f.k = String(o.k);
      break;
    case "answer":
      f.c = q(o.c);
      f.k = String(o.k);
      f.opt = q(o.opt);
      break;
    case "prompt":
    case "leave":
    case "sessionCancel":
      f.c = q(o.c);
      break;
    case "resolved":
      f.dec = q(o.dec);
      break;
    default:
      break;
  }
  return `[${FIELDS.map((name) => `${name} |-> ${f[name]}`).join(", ")}]`;
}

/// The generated module: this run's TraceLog and the design it is checked against.
export function obsModule(observations: Obs[], design: Design): string {
  return [
    "---------------------- MODULE AcpApprovalsObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    `TDesign == ${q(design)}`,
    `TOpener == ${q("opener")}`,
    `TConns == {${q("opener")}, ${q("f1")}}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Conns <- TConns",
  "    Opener <- TOpener",
  "    Design <- TDesign",
  '    Mutant = "none"',
  "    MaxJoins = 2",
  "    MaxLeaves = 2",
  "    MaxAsks = 1",
  "    MaxPrompts = 1",
  "    MaxId = 3",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

type TlcRun = Awaited<ReturnType<typeof runTlc>>;

/// Checks the first `prefix.length` observations, in `dir`. ACCEPTED is TLC
/// violating NotDone at the last observation; REJECTED is TLC finding no such state.
async function checkPrefix(prefix: Obs[], dir: string, design: Design) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpApprovalsObs.tla"), obsModule(prefix, design));
  writeFileSync(join(dir, "AcpApprovalsTrace.cfg"), TRACE_CFG);
  const run: TlcRun = await runTlc(dir, "AcpApprovalsTrace.tla", "AcpApprovalsTrace.cfg", ["AcpApprovals.tla", "AcpApprovalsTrace.tla"]);
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
  design: Design;
  firstDivergence: { step: number; observation: Obs | null } | null;
  full: { exitCode: number; violated: string | null; finalIndex: number | null; distinctStates: number | null; depth: number | null };
  prefixes: Array<{ length: number; verdict: Verdict }>;
  obs_sha256: string;
};

/// Checks one run against AcpApprovals in `design`, and writes verdict.json in `dir`.
export async function validate(observations: Obs[], dir: string, design: Design): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const length = observations.length;
  const full = await checkPrefix(observations, join(dir, "full"), design);
  let verdict: Verdict = full.verdict;
  let matched = length;
  const prefixes: Array<{ length: number; verdict: Verdict }> = [];
  if (full.verdict === "REJECTED") {
    // The empty prefix is taken as matched. Bisect for the longest accepted prefix.
    let low = 0;
    let high = length - 1;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      const check = await checkPrefix(observations.slice(0, middle), join(dir, `prefix-${middle}`), design);
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
    design,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    full: {
      exitCode: full.run.exitCode,
      violated: full.run.violated,
      finalIndex: full.finalIndex,
      distinctStates: full.run.distinctStates,
      depth: full.run.depth,
    },
    prefixes,
    obs_sha256: sha256Text(obsModule(observations, design)),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
