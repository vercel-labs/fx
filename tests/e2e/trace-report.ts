// Reads the JSONL traces that `/trace` writes: one JSON object per line, the
// first a `fx_trace` header and the last an `end` record. The schema is
// documented in src/core/app/trace_report.zig.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export type TraceRecord = { type: string; [field: string]: unknown };

export function isTraceReportName(name: string): boolean {
  return name.startsWith("fx-trace-") && name.endsWith(".jsonl");
}

/** The trace files in `dir`, by name; the name starts with the UTC time. */
export function traceReportNames(dir: string): string[] {
  return readdirSync(dir).filter(isTraceReportName).sort();
}

/** The trace file in `dir` that was written last. */
export function latestTraceReportPath(dir: string): string {
  const newest = traceReportNames(dir)
    .map((name) => ({ path: join(dir, name), mtimeMs: statSync(join(dir, name)).mtimeMs }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)[0];
  if (!newest) throw new Error(`no fx-trace-*.jsonl file in ${dir}`);
  return newest.path;
}

export class TraceReport {
  constructor(
    readonly path: string,
    readonly text: string,
    readonly records: TraceRecord[],
  ) {}

  /** Every record of one type, in file order. */
  all(type: string): TraceRecord[] {
    return this.records.filter((record) => record.type === type);
  }

  /** The one record of a type; fails when there is none or more than one. */
  one(type: string): TraceRecord {
    const found = this.all(type);
    if (found.length !== 1) throw new Error(`${this.path}: expected one ${type} record, found ${found.length}`);
    return found[0]!;
  }

  /** The problem records of one kind. */
  problems(kind: string): TraceRecord[] {
    return this.all("problem").filter((record) => record.kind === kind);
  }
}

/**
 * Parses a whole trace. Returns null while the file is still being written,
 * that is, until its last line is the `end` record. Throws when a line is not
 * a JSON object with a string `type`, or the header or end record is wrong.
 */
export function parseTraceReport(path: string, text: string): TraceReport | null {
  if (!text.endsWith("\n")) return null;
  const lines = text.slice(0, -1).split("\n");
  const records = lines.map((line, index) => {
    const value: unknown = JSON.parse(line);
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error(`${path}:${index + 1}: not a JSON object`);
    }
    const record = value as TraceRecord;
    if (typeof record.type !== "string") throw new Error(`${path}:${index + 1}: no string type`);
    if (Object.keys(record)[0] !== "type") throw new Error(`${path}:${index + 1}: type is not the first key`);
    return record;
  });
  const last = records[records.length - 1];
  if (last?.type !== "end") return null;
  if (records[0]?.type !== "fx_trace" || records[0].format_version !== 1) {
    throw new Error(`${path}: the first record is not an fx_trace header with format_version 1`);
  }
  if (last.records !== records.length - 1) {
    throw new Error(`${path}: the end record counts ${String(last.records)} records, the file has ${records.length - 1}`);
  }
  return new TraceReport(path, text, records);
}

/** Reads a finished trace; fails when it is cut off or malformed. */
export function readTraceReport(path: string): TraceReport {
  const report = parseTraceReport(path, readFileSync(path, "utf8"));
  if (!report) throw new Error(`${path}: the trace has no end record`);
  return report;
}

/** Waits for a finished trace in `dir` whose name is not in `before`. */
export async function waitForNewTraceReport(
  dir: string,
  before: Set<string> = new Set(),
  timeoutMs = 15_000,
): Promise<TraceReport> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const fresh = traceReportNames(dir).filter((name) => !before.has(name));
    const name = fresh[fresh.length - 1];
    if (name) {
      const path = join(dir, name);
      const report = parseTraceReport(path, readFileSync(path, "utf8"));
      if (report) return report;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`no finished fx-trace-*.jsonl file appeared in ${dir}`);
}
