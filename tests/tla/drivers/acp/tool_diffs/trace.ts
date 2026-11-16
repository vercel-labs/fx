// TLC trace validation: turns one observed run into the generated
// AcpToolDiffsObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpToolDiffs.tla, through AcpToolDiffsTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

/// An update the client read for an edit call: `c` is the call's number in
/// the run, `diff` the versions its diff showed, or null.
export type Observation = { c: number; status: "permission" | "completed" | "failed"; content: boolean; diff: [number, number] | null };

/// What the run's model needs besides the trace: each call's file, the
/// calls that asked for approval or were over the limit, each file's first
/// version, and the versions edits wrote.
export type Setup = { fileOf: string[]; ask: number[]; big: number[]; initVer: Record<string, number>; vs: number[] };

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const call = (c: number) => tla(`c${c}`);

export function obsModule(observations: Observation[], rules: boolean, setup: Setup): string {
  const calls = setup.fileOf.map((_, index) => index + 1);
  const files = Object.keys(setup.initVer);
  const fileOf = calls.map((c) => `${call(c)} :> ${tla(setup.fileOf[c - 1]!)}`).join(" @@ ");
  const initVer = files.map((f) => `${tla(f)} :> ${setup.initVer[f]}`).join(" @@ ");
  const record = (o: Observation) =>
    `[c |-> ${call(o.c)}, status |-> ${tla(o.status)}, content |-> ${bool(o.content)}, diff |-> ${o.diff ? `<<${o.diff[0]}, ${o.diff[1]}>>` : "<<>>"}]`;
  return [
    "------------------------ MODULE AcpToolDiffsObs ------------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers, TLC",
    `TRules == ${bool(rules)}`,
    `TCalls == {${calls.map(call).join(", ")}}`,
    `TFiles == {${files.map(tla).join(", ")}}`,
    `TFileOf == ${fileOf}`,
    `TAsk == {${setup.ask.map(call).join(", ")}}`,
    `TBig == {${setup.big.map(call).join(", ")}}`,
    `TInitVer == ${initVer}`,
    `TVs == {${setup.vs.join(", ")}}`,
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
  "    Calls <- TCalls",
  "    Files <- TFiles",
  "    FileOf <- TFileOf",
  "    Ask <- TAsk",
  "    Big <- TBig",
  "    InitVer <- TInitVer",
  "    Vs <- TVs",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export async function validate(observations: Observation[], dir: string, rules: boolean, setup: Setup) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict };
  const obs = obsModule(observations, rules, setup);
  writeFileSync(join(dir, "AcpToolDiffsObs.tla"), obs);
  writeFileSync(join(dir, "AcpToolDiffsTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpToolDiffsTrace.tla", "AcpToolDiffsTrace.cfg", ["AcpToolDiffs.tla", "AcpToolDiffsTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  else verdict = "TOOL_ERROR";
  const result = { verdict, length: observations.length, rules, setup, tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, distinctStates: run.distinctStates }, obs_sha256: sha256Text(obs) };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
