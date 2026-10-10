// Minimal receiver for fx remote reports (FX_REPORT_URL).
//
//   POST /v1/reports   store one report batch (JSON, schema 1)
//   GET  /v1/reports   most recent batches, ?limit=N (default 50, max 500)
//   GET  /v1/summary   aggregates across every stored batch
//   GET  /health       liveness
//
// Reports are appended to a JSONL file. When REPORT_TOKEN is set, every
// /v1 route requires `Authorization: Bearer <REPORT_TOKEN>`.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

const MAX_BODY_BYTES = 1024 * 1024;

export type NetworkEvent = {
  kind: string;
  started_at_ms: number;
  duration_ms: number;
  status: number;
  response_bytes: number;
  input_tokens: number;
  output_tokens: number;
  web_search_requests: number;
  subagent: boolean;
  model: string;
  error: string;
  stop_reason: string;
};

export type ToolEvent = {
  name: string;
  outcome: string;
  started_at_ms: number;
  duration_ms: number;
  subagent: boolean;
};

export type Report = {
  schema: number;
  run_id: string;
  fx_version: string;
  commit: string;
  os: string;
  arch: string;
  sent_at_ms: number;
  dropped_network: number;
  dropped_tools: number;
  network: NetworkEvent[];
  tools: ToolEvent[];
};

export type StoredReport = Report & { received_at_ms: number };

export function validateReport(value: unknown): Report | string {
  if (typeof value !== "object" || value === null) return "body must be a JSON object";
  const r = value as Record<string, unknown>;
  if (r.schema !== 1) return "unsupported schema";
  for (const key of ["run_id", "fx_version", "commit", "os", "arch"]) {
    if (typeof r[key] !== "string") return `${key} must be a string`;
  }
  if (!Array.isArray(r.network)) return "network must be an array";
  if (!Array.isArray(r.tools)) return "tools must be an array";
  return r as unknown as Report;
}

function percentile(sorted: number[], p: number) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

function durationStats(durations: number[]) {
  const sorted = [...durations].sort((a, b) => a - b);
  const total = sorted.reduce((sum, d) => sum + d, 0);
  return {
    avg_ms: sorted.length ? Math.round(total / sorted.length) : 0,
    p50_ms: percentile(sorted, 50),
    p95_ms: percentile(sorted, 95),
    max_ms: sorted.at(-1) ?? 0,
  };
}

function increment(map: Record<string, number>, key: string) {
  map[key] = (map[key] ?? 0) + 1;
}

export function summarize(reports: StoredReport[]) {
  const versions: Record<string, number> = {};
  const platforms: Record<string, number> = {};
  const models: Record<string, { durations: number[]; calls: number; failures: number; input_tokens: number; output_tokens: number; errors: Record<string, number>; statuses: Record<string, number> }> = {};
  const tools: Record<string, { durations: number[]; calls: number; outcomes: Record<string, number> }> = {};
  let dropped = 0;

  for (const report of reports) {
    increment(versions, report.fx_version || "unknown");
    increment(platforms, `${report.os}-${report.arch}`);
    dropped += (report.dropped_network ?? 0) + (report.dropped_tools ?? 0);

    for (const call of report.network) {
      const key = call.kind === "gateway" ? call.model || "unknown" : `${call.kind}`;
      const entry = (models[key] ??= { durations: [], calls: 0, failures: 0, input_tokens: 0, output_tokens: 0, errors: {}, statuses: {} });
      entry.calls += 1;
      entry.durations.push(call.duration_ms);
      entry.input_tokens += call.input_tokens;
      entry.output_tokens += call.output_tokens;
      increment(entry.statuses, String(call.status));
      if (call.error || call.status === 0 || call.status >= 400) {
        entry.failures += 1;
        if (call.error) increment(entry.errors, call.error);
      }
    }

    for (const tool of report.tools) {
      const entry = (tools[tool.name] ??= { durations: [], calls: 0, outcomes: {} });
      entry.calls += 1;
      entry.durations.push(tool.duration_ms);
      increment(entry.outcomes, tool.outcome);
    }
  }

  return {
    reports: reports.length,
    runs: new Set(reports.map((r) => r.run_id)).size,
    dropped_events: dropped,
    versions,
    platforms,
    network: Object.fromEntries(
      Object.entries(models).map(([key, { durations, ...rest }]) => [key, { ...rest, ...durationStats(durations) }]),
    ),
    tools: Object.fromEntries(
      Object.entries(tools).map(([key, { durations, ...rest }]) => [key, { ...rest, ...durationStats(durations) }]),
    ),
  };
}

export function readReports(dataFile: string): StoredReport[] {
  if (!existsSync(dataFile)) return [];
  const reports: StoredReport[] = [];
  for (const line of readFileSync(dataFile, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      reports.push(JSON.parse(line));
    } catch {
      // Skip a torn line rather than failing the whole summary.
    }
  }
  return reports;
}

export function createReportServer(opts: { port?: number; hostname?: string; dataFile: string; token?: string }) {
  mkdirSync(dirname(opts.dataFile), { recursive: true });
  const token = opts.token?.trim() || undefined;

  return Bun.serve({
    port: opts.port ?? 0,
    hostname: opts.hostname ?? "127.0.0.1",
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/health") return Response.json({ ok: true });
      if (!url.pathname.startsWith("/v1/")) return new Response("not found", { status: 404 });
      if (token && req.headers.get("authorization") !== `Bearer ${token}`) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }

      if (url.pathname === "/v1/reports" && req.method === "POST") {
        const body = await req.text();
        if (body.length > MAX_BODY_BYTES) return Response.json({ error: "body too large" }, { status: 413 });
        let parsed: unknown;
        try {
          parsed = JSON.parse(body);
        } catch {
          return Response.json({ error: "invalid JSON" }, { status: 400 });
        }
        const report = validateReport(parsed);
        if (typeof report === "string") return Response.json({ error: report }, { status: 400 });
        const stored: StoredReport = { ...report, received_at_ms: Date.now() };
        appendFileSync(opts.dataFile, JSON.stringify(stored) + "\n");
        return Response.json({ ok: true }, { status: 201 });
      }

      if (url.pathname === "/v1/reports" && req.method === "GET") {
        const limit = Math.min(500, Math.max(1, Number(url.searchParams.get("limit")) || 50));
        return Response.json(readReports(opts.dataFile).slice(-limit).reverse());
      }

      if (url.pathname === "/v1/summary" && req.method === "GET") {
        return Response.json(summarize(readReports(opts.dataFile)));
      }

      return new Response("not found", { status: 404 });
    },
  });
}

if (import.meta.main) {
  const server = createReportServer({
    port: Number(process.env.PORT ?? 8787),
    hostname: process.env.HOST ?? "127.0.0.1",
    dataFile: process.env.REPORT_DATA ?? "./data/reports.jsonl",
    token: process.env.REPORT_TOKEN,
  });
  console.log(`fx report server listening on http://${server.hostname}:${server.port}`);
}
