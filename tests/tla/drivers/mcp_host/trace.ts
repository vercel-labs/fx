// The trace bridge: turns what a scenario saw of real fx into TraceObs.tla
// and checks it against a model's trace wrapper, as drivers/mcp/bridge.ts does (sentinel
// invariant: violated exactly when a complete match exists).
//
// Verdicts:
//   ACCEPTED      a complete match exists that keeps every stated property
//   VIOLATES      every complete match breaks a stated property (`broken`
//                 names them, from a match TLC prints)
//   REJECTED      no complete match: the real behavior leaves the model;
//                 `firstBad` is the first record no prefix match can take
//   INCONCLUSIVE  an empty trace
//   TOOL_ERROR    anything else (a parse error, an unexpected exit)
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text } from "./tlc";

export type Value = string | number | boolean | Value[] | { [k: string]: Value };
export interface TraceRecord { event: string; data?: { [k: string]: Value }; at?: number; note?: string }
export interface Verdict {
  module: string; verdict: "ACCEPTED" | "VIOLATES" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";
  records: number; broken?: string[]; firstBad?: { index: number; record: TraceRecord }; detail?: string;
  dir: string; traceSha256: string; runs: { label: string; exit: number; violated?: string; log: string; distinct?: number }[];
}

/** TLA+ for a JSON value: arrays are sets; objects are records. */
export function tla(value: Value): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || Math.abs(value) >= 2 ** 31) throw new Error(`TLC integers are 32-bit: ${value}`);
    return String(value);
  }
  if (Array.isArray(value)) return `{${value.map(tla).join(", ")}}`;
  const keys = Object.keys(value);
  if (keys.length === 0) return "[none |-> 0]";
  return `[${keys.map((k) => `${k} |-> ${tla(value[k]!)}`).join(", ")}]`;
}

export function traceObs(records: TraceRecord[], constants: Record<string, Value>): string {
  const lines = ["---- MODULE TraceObs ----", "EXTENDS Integers, Sequences, FiniteSets", ""];
  lines.push("ObsTrace == <<");
  lines.push(records.map((r) => `    [event |-> ${tla(r.event)}, data |-> ${tla(r.data ?? {})}]`).join(",\n"));
  lines.push(">>", "");
  for (const [name, value] of Object.entries(constants)) lines.push(`${name} == ${tla(value)}`);
  lines.push("====", "");
  return lines.join("\n");
}

const substitutions: Record<string, string[]> = {
  HostLifecycle: ["Servers", "Project", "Reachable", "NeedsAuth", "MaxReloads", "MaxLeases"],
  Credentials: ["Names", "Faults", "InitKinds", "InitEntries", "InitV1"],
  SignIn: ["MaxLogins", "MaxHosts", "MaxLeases", "Bridge"],
  ElicitationRouting: ["Versions", "MaxQ", "Slots", "Guard"],
  UrlRetry: ["Urls", "Slots", "MaxCalls", "Guard"],
  MixedBuilds: ["RevokeOnReplay"],
};

function wrapperCfg(module: string, invariant: string): string {
  const names = substitutions[module];
  if (!names) throw new Error(`no trace wrapper for ${module}`);
  return ["CONSTANTS", ...names.map((n) => `    ${n} <- Obs${n}`), "INIT TraceInit", "NEXT TraceNext", `INVARIANT ${invariant}`, ""].join("\n");
}

/** `constants` holds Obs<Name> for each wrapper constant. */
export async function checkTrace(opts: { module: string; records: TraceRecord[]; constants: Record<string, Value>; dir: string }): Promise<Verdict> {
  const { module, records, constants, dir } = opts;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const text = JSON.stringify(records, null, 2);
  writeFileSync(join(dir, "trace.json"), text);
  const verdict: Verdict = { module, verdict: "TOOL_ERROR", records: records.length, dir, traceSha256: sha256Text(text), runs: [] };
  const finish = (v: Partial<Verdict>) => {
    Object.assign(verdict, v);
    writeFileSync(join(dir, "verdict.json"), JSON.stringify(verdict, null, 2));
    return verdict;
  };
  if (records.length === 0) return finish({ verdict: "INCONCLUSIVE", detail: "empty trace" });
  for (const n of substitutions[module] ?? []) if (!(`Obs${n}` in constants)) return finish({ detail: `missing constant Obs${n}` });
  const run = async (label: string, recs: TraceRecord[], invariant: string) => {
    const r = await runTlc({
      outDir: dir, label, module: `${module}Trace`, cfgText: wrapperCfg(module, invariant),
      files: { "TraceObs.tla": traceObs(recs, constants) }, extraArgs: ["-deadlock"], workers: 2, timeoutMs: 300_000,
    });
    verdict.runs.push({ label, exit: r.exit, violated: r.violated, log: r.log, distinct: r.distinct });
    return r;
  };
  const matched = (r: Awaited<ReturnType<typeof run>>, inv: string) => r.exit === 12 && r.violated === inv;
  const unmatched = (r: Awaited<ReturnType<typeof run>>) => r.exit === 0 && r.completed;

  const whole = await run("match", records, "NotDone");
  if (unmatched(whole)) {
    // The longest prefix that matches; the record after it is the first the model can't take.
    let lo = 0, hi = records.length - 1;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      const r = mid === 0 ? null : await run(`prefix-${mid}`, records.slice(0, mid), "NotDone");
      if (r === null || matched(r, "NotDone")) lo = mid; else if (unmatched(r)) hi = mid - 1; else return finish({ detail: `prefix ${mid}: exit ${r.exit}` });
    }
    return finish({ verdict: "REJECTED", firstBad: { index: lo, record: records[lo]! } });
  }
  if (!matched(whole, "NotDone")) return finish({ detail: `exit ${whole.exit}: ${whole.output.split("\n").filter((l) => /Error|error|Unknown|not/.test(l)).slice(0, 5).join(" | ")}` });
  const clean = await run("clean", records, "NotDoneClean");
  if (matched(clean, "NotDoneClean")) return finish({ verdict: "ACCEPTED" });
  if (!unmatched(clean)) return finish({ detail: `clean: exit ${clean.exit}` });
  const dirty = await run("dirty", records, "NotDoneDirty");
  if (!matched(dirty, "NotDoneDirty")) return finish({ detail: `dirty: exit ${dirty.exit}` });
  const states = dirty.output.split(/^State \d+:/m);
  const last = states[states.length - 1] ?? "";
  const broken = [...(/\/\\ bad = \{([^}]*)\}/.exec(last)?.[1] ?? "").matchAll(/"(\w+)"/g)].map((m) => m[1]!);
  return finish({ verdict: "VIOLATES", broken });
}
