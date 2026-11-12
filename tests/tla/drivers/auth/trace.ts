// The trace bridge for tests/tla/auth/SharedLoginRefreshTrace.tla, the way
// drivers/mcp_host/trace.ts bridges its models: it writes TraceObs.tla from
// the ordered log of tests/e2e/shared-login-fakes.ts and runs TLC with
// sentinel invariants. NotDone is violated exactly when the whole log is a
// behavior of the wrapper; NotDoneClean and NotDoneDirty then tell whether
// that match keeps every rule.
//
// Verdicts:
//   ACCEPTED      the log matches and keeps every rule
//   VIOLATES      the log matches and breaks a rule (`broken` names them)
//   REJECTED      no match: `firstBad` is the first record no prefix match takes
//   INCONCLUSIVE  an empty log
//   TOOL_ERROR    anything else
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { SharedLoginEvent } from "../../../e2e/shared-login-fakes";
import { TLA_ROOT, runTlc, sha256Text } from "../lib/tlc";

export type Verdict = {
  verdict: "ACCEPTED" | "VIOLATES" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";
  records: number;
  broken: string[];
  firstBad?: { index: number; record: SharedLoginEvent };
  detail?: string;
  dir: string;
  traceSha256: string;
  runs: { label: string; exit: number; violated: string | null; distinct: number | null }[];
};

type Value = string | number | boolean | { [key: string]: Value } | Value[];

/** TLA+ for a JSON value: arrays are sets and objects are records. */
function tla(value: Value): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || Math.abs(value) >= 2 ** 31) throw new Error(`TLC integers are 32-bit: ${value}`);
    return String(value);
  }
  if (Array.isArray(value)) return `{${value.map(tla).join(", ")}}`;
  return `[${Object.entries(value).map(([key, item]) => `${key} |-> ${tla(item)}`).join(", ")}]`;
}

function traceObs(records: SharedLoginEvent[], procs: string[]): string {
  return [
    "---- MODULE TraceObs ----",
    "EXTENDS Integers, Sequences",
    "ObsTrace == <<",
    records.map((r) => `    [event |-> ${tla(r.event)}, data |-> ${tla(r.data as Value)}]`).join(",\n"),
    ">>",
    `ObsProcs == ${tla(procs)}`,
    "====",
    "",
  ].join("\n");
}

const MODULE = "SharedLoginRefreshTrace";

/** Checks one run's log against SharedLoginRefreshTrace.tla; writes everything under `dir`. */
export async function checkTrace(records: SharedLoginEvent[], procs: string[], dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const text = JSON.stringify(records, null, 2);
  writeFileSync(join(dir, "trace.json"), text);
  const verdict: Verdict = { verdict: "TOOL_ERROR", records: records.length, broken: [], dir, traceSha256: sha256Text(text), runs: [] };
  const finish = (update: Partial<Verdict>) => {
    Object.assign(verdict, update);
    writeFileSync(join(dir, "verdict.json"), JSON.stringify(verdict, null, 2));
    return verdict;
  };
  if (records.length === 0) return finish({ verdict: "INCONCLUSIVE", detail: "empty trace" });

  const run = async (label: string, recs: SharedLoginEvent[], invariant: string) => {
    const runDir = join(dir, label);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(join(runDir, "TraceObs.tla"), traceObs(recs, procs));
    writeFileSync(join(runDir, `${MODULE}.cfg`), `INIT TraceInit\nNEXT TraceNext\nINVARIANT ${invariant}\n`);
    const result = await runTlc(runDir, MODULE, `${MODULE}.cfg`, [`${MODULE}.tla`], join(TLA_ROOT, "auth"), ["-deadlock"]);
    verdict.runs.push({ label, exit: result.exitCode, violated: result.violated, distinct: result.distinctStates });
    return result;
  };
  const matched = (r: Awaited<ReturnType<typeof run>>, invariant: string) => r.exitCode === 12 && r.violated === invariant;
  const unmatched = (r: Awaited<ReturnType<typeof run>>) => r.exitCode === 0 && /No error has been found/.test(r.output);

  const whole = await run("match", records, "NotDone");
  if (unmatched(whole)) {
    // The longest prefix that matches; the record after it is the first the model can't take.
    let lo = 0;
    let hi = records.length - 1;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      const r = await run(`prefix-${mid}`, records.slice(0, mid), "NotDone");
      if (matched(r, "NotDone")) lo = mid;
      else if (unmatched(r)) hi = mid - 1;
      else return finish({ detail: `prefix ${mid}: exit ${r.exitCode}` });
    }
    return finish({ verdict: "REJECTED", firstBad: { index: lo, record: records[lo]! } });
  }
  if (!matched(whole, "NotDone")) {
    const errors = whole.output.split("\n").filter((line) => /Error|error|Unknown|not/.test(line)).slice(0, 5);
    return finish({ detail: `exit ${whole.exitCode}: ${errors.join(" | ")}` });
  }
  const clean = await run("clean", records, "NotDoneClean");
  if (matched(clean, "NotDoneClean")) return finish({ verdict: "ACCEPTED" });
  if (!unmatched(clean)) return finish({ detail: `clean: exit ${clean.exitCode}` });
  const dirty = await run("dirty", records, "NotDoneDirty");
  if (!matched(dirty, "NotDoneDirty")) return finish({ detail: `dirty: exit ${dirty.exitCode}` });
  const states = dirty.output.split(/^State \d+:/m);
  const last = states[states.length - 1] ?? "";
  const broken = [...(/\/\\ bad = \{([^}]*)\}/.exec(last)?.[1] ?? "").matchAll(/"(\w+)"/g)].map((m) => m[1]!);
  return finish({ verdict: "VIOLATES", broken });
}
