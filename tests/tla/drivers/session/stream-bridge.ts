// Connects agent turns of the real fx binary to TLC. One turn's
// observations become TurnStreamObserved.tla, and
// tests/tla/session/TurnStreamTrace.tla replays them through TurnStream's
// own actions. ACCEPTED needs TLC's exit 12 on the NotAllMatched sentinel
// with every observation matched. A finished search is REJECTED; then the
// longest prefix the model can produce names the first observation it
// cannot. Strict verdicts: missing or unreadable evidence is never accepted.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256File, sha256Text, TLA_ROOT, writeJson } from "../lib/tlc";

/// One `sessions_v2_stream` decision, or the session log fx left ("disk").
/// Fields a phase does not use are false, 0 or empty.
export interface Observation {
  phase: "stream" | "commit" | "disk";
  /// Whether every piece the open turn held still stood.
  stood: boolean;
  /// The tool results the rebuild had.
  results: number;
  /// Streamed pieces samePiece had to parse.
  reparsed: number;
  /// The fewest and most tool results that can have arrived by this
  /// decision: the calls the driver issued before the request this decision
  /// followed, and before fx's next request.
  least: number;
  arrived: number;
  /// The live turn's tool results on disk, by call id, in order.
  calls: string[];
  /// Superseded markers on disk.
  superseded: number;
}

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export interface TraceResult {
  verdict: Verdict;
  length: number;
  matched: number;
  detail: string;
  firstMismatch?: { step: number; observation: Observation };
  hashes: Record<string, string>;
}

const SPEC_DIR = join(TLA_ROOT, "session");
const SPECS = ["TurnStream.tla", "TurnStreamTrace.tla"];

const DECISION = /event=sessions_v2_stream session=\S+ phase=(stream|commit) held=(\d+) kept=(\d+) results=(\d+) reparsed=(\d+)/;

/// Each stream and commit decision in fx's session trace, in order.
export function decisions(trace: string): Observation[] {
  return trace.split("\n").flatMap((line) => {
    const match = DECISION.exec(line);
    if (!match) return [];
    const [, phase, held, kept, results, reparsed] = match;
    return [{
      phase: phase as "stream" | "commit",
      stood: held === kept,
      results: Number(results),
      reparsed: Number(reparsed),
      least: 0,
      arrived: Number.MAX_SAFE_INTEGER,
      calls: [],
      superseded: 0,
    }];
  });
}

/// The only session a profile saved: its folder under ~/.fx/sessions/v2.
export function sessionFolder(home: string): string {
  const store = join(home, ".fx", "sessions", "v2");
  const ids = existsSync(store) ? readdirSync(store).filter((id) => !id.startsWith(".") && existsSync(join(store, id, "log.jsonl"))) : [];
  if (ids.length !== 1) throw new Error(`expected one saved session under ${store}, found ${ids.length}`);
  return join(store, ids[0]!);
}

/// A piece's JSON, from its line or from the blob a large one went to.
function pieceData(folder: string, data: any): any {
  if (data && typeof data === "object" && typeof data.$blob === "string") {
    return JSON.parse(readFileSync(join(folder, "blobs", data.$blob), "utf8"));
  }
  return data;
}

/// What the session log holds: the live turn's tool results (call id, stamp,
/// and when fx wrote the line, in order) and the superseded markers.
export function diskTurn(folder: string): { calls: string[]; stamps: number[]; written: number[]; superseded: number; ended: boolean } {
  let calls: string[] = [];
  let stamps: number[] = [];
  let written: number[] = [];
  let superseded = 0;
  let ended = false;
  for (const line of readFileSync(join(folder, "log.jsonl"), "utf8").split("\n")) {
    if (!line) continue;
    const value = JSON.parse(line);
    if (value.kind === "turn_committed" || value.kind === "turn_interrupted") ended = true;
    if (value.kind !== "item") continue;
    if (value.type === "superseded") {
      superseded += 1;
      calls = [];
      stamps = [];
      written = [];
    } else if (value.type === "tool_result") {
      const data = pieceData(folder, value.data);
      calls.push(String(data.call_id));
      stamps.push(Number(data.created_at_ms));
      written.push(Number(value.ts));
    }
  }
  return { calls, stamps, written, superseded, ended };
}

export function diskObservation(folder: string): Observation {
  const turn = diskTurn(folder);
  return { phase: "disk", stood: false, results: 0, reparsed: 0, least: 0, arrived: turn.calls.length, calls: turn.calls, superseded: turn.superseded };
}

const str = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

function observationValue(o: Observation): string {
  return `[phase |-> ${str(o.phase)}, stood |-> ${bool(o.stood)}, results |-> ${o.results}, ` +
    `reparsed |-> ${o.reparsed}, least |-> ${o.least}, arrived |-> ${Math.min(o.arrived, 1_000_000)}, ` +
    `calls |-> <<${o.calls.map(str).join(", ")}>>, ` +
    `superseded |-> ${o.superseded}]`;
}

/// `order` is the tool calls the driver issued, which the hidden RunTool
/// steps follow; a prefix of the run keeps the whole run's order.
export function observedModule(observations: Observation[], order: string[]): string {
  const builds = observations.filter((o) => o.phase !== "disk").length;
  return [
    "--------------------------- MODULE TurnStreamObserved ---------------------------",
    "(* Generated by tests/tla/drivers/session/stream-bridge.ts from one run. Do not edit. *)",
    "EXTENDS Naturals, Sequences",
    `TOrder == <<${order.map(str).join(", ")}>>`,
    "TCalls == {TOrder[i] : i \\in 1..Len(TOrder)}",
    `TMaxBuilds == ${builds}`,
    `Observed == << ${observations.map(observationValue).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "  Calls <- TCalls",
  "  MaxBuilds <- TMaxBuilds",
  "  MissedPaths = FALSE",
  "  Compactions = TRUE",
  "  Recovery = FALSE",
  "  Faults = FALSE",
  '  Mutant = "none"',
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotAllMatched",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

async function replay(observations: Observation[], order: string[], dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "TurnStreamObserved.tla"), observedModule(observations, order));
  writeFileSync(join(dir, "trace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "TurnStreamTrace.tla", "trace.cfg", SPECS, SPEC_DIR);
  const matched = [...run.output.matchAll(/\/\\ k = (\d+)/g)].map((match) => Number(match[1])).at(-1);
  if (run.exitCode === 12 && run.violated === "NotAllMatched" && matched === observations.length) return "ACCEPTED";
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return "REJECTED";
  return "TOOL_ERROR";
}

/// Replays `observations` through the model. `order` is the tool calls the
/// driver issued, in order, which the hidden RunTool steps follow, so the
/// disk record is checked against what was asked for, not against itself.
/// `dir` receives every TLC run. The disk record must come last. While the
/// first mismatch is searched for, a prefix of the decisions is checked
/// against the decisions alone.
export async function checkTrace(observations: Observation[], order: string[], dir: string): Promise<TraceResult> {
  const hashes = {
    ...Object.fromEntries(SPECS.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    observations: sha256Text(JSON.stringify({ observations, order })),
  };
  const result = await (async (): Promise<TraceResult> => {
    const length = observations.length;
    const decided = observations.filter((o) => o.phase !== "disk").length;
    if (decided === 0) return { verdict: "TOOL_ERROR", length, matched: 0, detail: "no stream decisions in the session trace", hashes };
    const last = observations.at(-1)!;
    if (last.phase !== "disk" || observations.slice(0, -1).some((o) => o.phase === "disk")) {
      return { verdict: "TOOL_ERROR", length, matched: 0, detail: "the disk record must come last, once", hashes };
    }
    const whole = await replay(observations, order, join(dir, "whole"));
    if (whole !== "REJECTED") {
      return { verdict: whole, length, matched: whole === "ACCEPTED" ? length : 0, detail: `TLC work in ${dir}`, hashes };
    }
    // A prefix of a behavior is a behavior, so the longest one accepted is
    // found by bisection.
    let good = 0, bad = length;
    while (bad - good > 1) {
      const mid = Math.floor((good + bad) / 2);
      const verdict = await replay(observations.slice(0, mid), order, join(dir, `prefix-${mid}`));
      if (verdict === "TOOL_ERROR") return { verdict, length, matched: 0, detail: `TLC failed on a prefix of ${mid}; see ${dir}`, hashes };
      if (verdict === "ACCEPTED") good = mid;
      else bad = mid;
    }
    return {
      verdict: "REJECTED", length, matched: good, hashes,
      firstMismatch: { step: good + 1, observation: observations[good]! },
      detail: `the model cannot produce step ${good + 1}: ${JSON.stringify(observations[good])}`,
    };
  })();
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
