// Trace bridge for the MCP engine models in tests/tla/mcp/.
//
// Turns a JSONL step trace into a generated TLA+ module (TraceObs) and asks TLC
// whether it is a behavior of the machine's model, using a hand-written trace
// wrapper that EXTENDS the model and TraceObs. Acceptance uses the sentinel
// technique of the session manager's drivers: the wrapper's NotDone invariant is violated only
// once every observed step has been matched, and the matched count must equal
// the trace length.
//
// CLI: bun tests/tla/drivers/mcp/bridge.ts --trace <file> --machine <name> [--instance <id>]
//        --spec-dir <dir> --wrapper <Module> --report-dir <dir>
// Exit: 0 ACCEPTED, 1 REJECTED, 2 INCONCLUSIVE, 3 TOOL_ERROR.

import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

export type Verdict = "ACCEPTED" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";

export const verdictExit: Record<Verdict, number> = {
  ACCEPTED: 0,
  REJECTED: 1,
  INCONCLUSIVE: 2,
  TOOL_ERROR: 3,
};

export interface TraceRequest {
  trace: string;
  machine: string;
  instance?: string;
  specDir: string;
  wrapper: string;
  reportDir: string;
  /** Extra definitions for TraceObs, such as model constants the trace can't show. */
  constants?: { [name: string]: number };
}

export interface TraceResult {
  verdict: Verdict;
  reason: string;
  steps: number;
  matched: number | null;
  reportDir: string;
}

type DataValue = number | boolean | string;

interface TraceLine {
  v: number;
  seq: number;
  machine: string;
  inst: string;
  event: string;
  from: string;
  to: string;
  effects: string[];
  data: { [name: string]: DataValue };
}

const TLC_SH = resolve(import.meta.dir, "../../lib/run-tlc.sh");
const SENTINEL = "NotDone";
const TLC_INT_MIN = -(2 ** 31);
const TLC_INT_MAX = 2 ** 31 - 1;
const TLA_IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

function sha256(bytes: string | Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

class Inconclusive extends Error {}

function parseTrace(text: string): TraceLine[] {
  if (text.length === 0) throw new Inconclusive("trace is empty");
  if (!text.endsWith("\n")) throw new Inconclusive("last record is incomplete (no trailing newline)");
  const lines = text.slice(0, -1).split("\n");
  return lines.map((line, index) => {
    const at = `line ${index + 1}`;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      throw new Inconclusive(`${at} is not valid JSON`);
    }
    const r = value as TraceLine;
    if (typeof r !== "object" || r === null) throw new Inconclusive(`${at} is not an object`);
    if (r.v !== 1) throw new Inconclusive(`${at} has unsupported format version ${String(r.v)}`);
    if (r.seq !== index + 1) throw new Inconclusive(`${at} has seq ${String(r.seq)}, expected ${index + 1}`);
    for (const key of ["machine", "inst", "event", "from", "to"] as const) {
      if (typeof r[key] !== "string") throw new Inconclusive(`${at} field ${key} is not a string`);
    }
    if (!Array.isArray(r.effects) || !r.effects.every((e) => typeof e === "string")) {
      throw new Inconclusive(`${at} field effects is not a list of strings`);
    }
    if (typeof r.data !== "object" || r.data === null || Array.isArray(r.data)) {
      throw new Inconclusive(`${at} field data is not an object`);
    }
    for (const [name, v] of Object.entries(r.data)) {
      if (!TLA_IDENT.test(name)) throw new Inconclusive(`${at} data field ${JSON.stringify(name)} is not a TLA+ identifier`);
      if (typeof v === "number" && (!Number.isInteger(v) || v < TLC_INT_MIN || v > TLC_INT_MAX)) {
        throw new Inconclusive(`${at} data field ${name} is not a TLC integer`);
      }
      if (!["number", "boolean", "string"].includes(typeof v)) {
        throw new Inconclusive(`${at} data field ${name} has unsupported type`);
      }
    }
    return r;
  });
}

function tlaString(s: string): string {
  const escaped = s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t");
  if (/[\x00-\x1f]/.test(escaped)) throw new Inconclusive("string contains an unsupported control character");
  return `"${escaped}"`;
}

function tlaValue(v: DataValue): string {
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  if (typeof v === "number") return String(v);
  return tlaString(v);
}

function observationModule(steps: TraceLine[], source: string, constants: { [name: string]: number }): string {
  const definitions = Object.entries(constants).map(([name, value]) => {
    if (!TLA_IDENT.test(name) || !Number.isInteger(value) || value < TLC_INT_MIN || value > TLC_INT_MAX) {
      throw new Inconclusive(`constant ${name} = ${value} is not a TLA+ identifier and TLC integer`);
    }
    return `${name} == ${value}`;
  });
  const rows = steps.map((r) => {
    const fields = Object.entries(r.data);
    const data = fields.length === 0 ? "<<>>" : `[${fields.map(([k, v]) => `${k} |-> ${tlaValue(v)}`).join(", ")}]`;
    const effects = `<<${r.effects.map(tlaString).join(", ")}>>`;
    return `  [event |-> ${tlaString(r.event)}, from |-> ${tlaString(r.from)}, to |-> ${tlaString(r.to)}, effects |-> ${effects}, data |-> ${data}]`;
  });
  return [
    "---- MODULE TraceObs ----",
    `\\* Generated by tests/tla/drivers/mcp/bridge.ts from ${basename(source)} (${steps.length} steps). Do not edit.`,
    // Integers for negative values.
    "EXTENDS Integers",
    ...definitions,
    "ObsTrace == <<",
    rows.join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
}

function finish(request: TraceRequest, result: Omit<TraceResult, "reportDir">, extra: object = {}): TraceResult {
  const full: TraceResult = { ...result, reportDir: request.reportDir };
  writeFileSync(join(request.reportDir, "verdict.json"), JSON.stringify({ ...full, ...extra }, null, 2) + "\n");
  return full;
}

export function checkTrace(request: TraceRequest): TraceResult {
  mkdirSync(request.reportDir, { recursive: true });
  writeFileSync(join(request.reportDir, "request.json"), JSON.stringify(request, null, 2) + "\n");

  if (!existsSync(request.trace)) {
    return finish(request, { verdict: "INCONCLUSIVE", reason: "trace file is missing", steps: 0, matched: null });
  }
  const raw = readFileSync(request.trace);
  writeFileSync(join(request.reportDir, "trace.jsonl"), raw);

  let steps: TraceLine[];
  try {
    steps = parseTrace(raw.toString("utf8")).filter(
      (r) => r.machine === request.machine && (request.instance === undefined || r.inst === request.instance),
    );
  } catch (error) {
    if (error instanceof Inconclusive) {
      return finish(request, { verdict: "INCONCLUSIVE", reason: error.message, steps: 0, matched: null });
    }
    throw error;
  }
  if (steps.length === 0) {
    return finish(request, {
      verdict: "INCONCLUSIVE",
      reason: `no steps for machine ${request.machine}${request.instance ? ` instance ${request.instance}` : ""}`,
      steps: 0,
      matched: null,
    });
  }

  const wrapperTla = join(request.specDir, `${request.wrapper}.tla`);
  const wrapperCfg = join(request.specDir, `${request.wrapper}.cfg`);
  if (!existsSync(wrapperTla) || !existsSync(wrapperCfg)) {
    return finish(request, {
      verdict: "TOOL_ERROR",
      reason: `trace wrapper ${request.wrapper}.tla or .cfg not found in ${request.specDir}`,
      steps: steps.length,
      matched: null,
    });
  }

  let observation: string;
  try {
    observation = observationModule(steps, request.trace, request.constants ?? {});
  } catch (error) {
    if (error instanceof Inconclusive) {
      return finish(request, { verdict: "INCONCLUSIVE", reason: error.message, steps: steps.length, matched: null });
    }
    throw error;
  }

  const modelDir = join(request.reportDir, "model");
  mkdirSync(modelDir, { recursive: true });
  const hashes: { [file: string]: string } = {};
  for (const name of readdirSync(request.specDir)) {
    if (name.endsWith(".tla") || name.endsWith(".cfg")) {
      copyFileSync(join(request.specDir, name), join(modelDir, name));
      hashes[name] = sha256(readFileSync(join(modelDir, name)));
    }
  }
  writeFileSync(join(modelDir, "TraceObs.tla"), observation);
  hashes["TraceObs.tla"] = sha256(observation);
  hashes["trace.jsonl"] = sha256(raw);

  const tlc = Bun.spawnSync([TLC_SH, join(modelDir, `${request.wrapper}.tla`), join(modelDir, `${request.wrapper}.cfg`), "-deadlock"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const output = tlc.stdout.toString() + tlc.stderr.toString();
  writeFileSync(join(request.reportDir, "tlc.log"), output);
  const jar = /jar_sha256=([0-9a-f]{64})/.exec(output)?.[1] ?? null;
  const extra = { tlcExit: tlc.exitCode, jarSha256: jar, hashes };

  if (tlc.exitCode === 12 && output.includes(`Invariant ${SENTINEL} is violated`)) {
    const values = [...output.matchAll(/\/\\ i = (\d+)/g)].map((m) => Number(m[1]));
    const matched = values.length > 0 ? values[values.length - 1] : null;
    if (matched === steps.length) {
      return finish(request, { verdict: "ACCEPTED", reason: `all ${steps.length} steps are a behavior of the model`, steps: steps.length, matched }, extra);
    }
    return finish(request, { verdict: "TOOL_ERROR", reason: `sentinel reached at i=${matched}, expected ${steps.length}`, steps: steps.length, matched }, extra);
  }
  if (tlc.exitCode === 0 && output.includes("Model checking completed. No error has been found.")) {
    // Search depth also counts a wrapper's hidden environment steps, so find
    // the first step the model rejects by checking prefixes of the trace.
    const accepts = (count: number): boolean => {
      writeFileSync(join(modelDir, "TraceObs.tla"), observationModule(steps.slice(0, count), request.trace, request.constants ?? {}));
      const run = Bun.spawnSync([TLC_SH, join(modelDir, `${request.wrapper}.tla`), join(modelDir, `${request.wrapper}.cfg`), "-deadlock"], { stdout: "pipe", stderr: "pipe" });
      return run.exitCode === 12 && (run.stdout.toString() + run.stderr.toString()).includes(`Invariant ${SENTINEL} is violated`);
    };
    let matched = 0;
    let rejected = steps.length;
    while (rejected - matched > 1) {
      const mid = Math.floor((matched + rejected) / 2);
      if (accepts(mid)) matched = mid;
      else rejected = mid;
    }
    writeFileSync(join(modelDir, "TraceObs.tla"), observation);
    const next = steps[matched];
    const detail = `; step ${matched + 1} (${next.event}: ${next.from} -> ${next.to}) is not allowed`;
    return finish(request, { verdict: "REJECTED", reason: `the model matches only ${matched} of ${steps.length} steps${detail}`, steps: steps.length, matched }, extra);
  }
  const firstError = output.split("\n").find((line) => /error/i.test(line)) ?? `TLC exit ${tlc.exitCode}`;
  return finish(request, { verdict: "TOOL_ERROR", reason: firstError.trim(), steps: steps.length, matched: null }, extra);
}

export function requireAccepted(result: TraceResult): void {
  if (result.verdict !== "ACCEPTED") {
    throw new Error(`trace ${result.verdict}: ${result.reason} (evidence: ${result.reportDir})`);
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const get = (flag: string) => {
    const index = args.indexOf(flag);
    return index >= 0 ? args[index + 1] : undefined;
  };
  const trace = get("--trace");
  const machine = get("--machine");
  const specDir = get("--spec-dir");
  const wrapper = get("--wrapper");
  const reportDir = get("--report-dir");
  if (!trace || !machine || !specDir || !wrapper || !reportDir) {
    console.error("usage: bun tests/tla/drivers/mcp/bridge.ts --trace <file> --machine <name> [--instance <id>] --spec-dir <dir> --wrapper <Module> --report-dir <dir> [--constant Name=Value ...]");
    process.exit(verdictExit.TOOL_ERROR);
  }
  const constants: { [name: string]: number } = {};
  args.forEach((arg, index) => {
    if (arg !== "--constant") return;
    const [name, value] = (args[index + 1] ?? "").split("=");
    constants[name] = Number(value);
  });
  const result = checkTrace({ trace: resolve(trace), machine, instance: get("--instance"), specDir: resolve(specDir), wrapper, reportDir: resolve(reportDir), constants });
  console.log(JSON.stringify(result));
  process.exit(verdictExit[result.verdict]);
}
