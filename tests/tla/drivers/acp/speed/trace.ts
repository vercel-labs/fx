// Shared pieces of the runtime bridge: the ACP stdio client, the
// client-visible projection of configOptions, the lane a Gateway request
// asks for, and TLC trace validation against tests/tla/acp/AcpSpeedTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

// ------------------------------------------------------------ observation --

export type View = { model: string; fast: string; ultra: string };
export type Observation = { op: string; arg: string; ok: boolean; speed: string; hasView: boolean; view: View; detail?: unknown };
export const NO_VIEW: View = { model: "", fast: "", ultra: "" };

export function viewOf(configOptions: unknown): View | null {
  if (!Array.isArray(configOptions)) return null;
  const byId = new Map(configOptions.map((option: any) => [option?.id, option]));
  const model = byId.get("model")?.currentValue;
  if (typeof model !== "string") return null;
  const lane = (id: string) => {
    const option = byId.get(id);
    if (!option) return "absent";
    return typeof option.currentValue === "string" ? option.currentValue : "invalid";
  };
  return { model, fast: lane("fast"), ultra: lane("ultrafast") };
}

export function laneOf(body: string): string {
  try {
    const providerOptions = JSON.parse(body).providerOptions ?? {};
    if (providerOptions.openai?.serviceTier === "ultrafast") return "ultrafast";
    if (providerOptions.gateway?.speed === "fast") return "fast";
    return "standard";
  } catch {
    return "unparseable";
  }
}

// -------------------------------------------------------------- ACP client --

export class Acp {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private nextId = 1;
  stderr = "";
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly log: (entry: object) => void) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      for (const waiter of this.waiters.splice(0)) waiter("");
      return code;
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) {
          if (!line.trim()) continue;
          const waiter = this.waiters.shift();
          if (waiter) waiter(line);
          else this.lines.push(line);
        }
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  private async readLine(): Promise<any> {
    const buffered = this.lines.shift();
    if (buffered) return JSON.parse(buffered);
    if (this.closed) throw new Error(`fx acp exited: ${this.stderr}`);
    const line = await new Promise<string>((resolveLine, reject) => {
      const timer = setTimeout(() => reject(new Error(`fx acp read timeout: ${this.stderr}`)), 20_000);
      this.waiters.push((value) => { clearTimeout(timer); resolveLine(value); });
    });
    if (!line) throw new Error(`fx acp exited: ${this.stderr}`);
    return JSON.parse(line);
  }

  async call(method: string, params: Record<string, unknown>): Promise<any> {
    const id = this.nextId++;
    this.log({ dir: "out", id, method, params });
    (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    (this.proc.stdin as any).flush?.();
    while (true) {
      const message = await this.readLine();
      if ("method" in message && "id" in message) {
        this.log({ dir: "in-request", method: message.method });
        (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "cancelled" } } })}\n`);
        continue;
      }
      if (message.id === id) {
        this.log({ dir: "in", id, method, error: message.error ?? null, result: message.result ?? null });
        return message;
      }
    }
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

// ---------------------------------------------------------------- TLC side --

const tla = (value: string) => JSON.stringify(value);
const tlaSet = (values: string[]) => `{${values.map(tla).join(", ")}}`;

export type TraceCatalog = { models: string[]; supFast: string[]; supUltra: string[] };

export function obsModule(observations: Observation[], catalog: TraceCatalog): string {
  const record = (o: Observation) => {
    const view = `[model |-> ${tla(o.view.model)}, fast |-> ${tla(o.view.fast)}, ultra |-> ${tla(o.view.ultra)}]`;
    return `[op |-> ${tla(o.op)}, arg |-> ${tla(o.arg)}, ok |-> ${o.ok ? "TRUE" : "FALSE"}, speed |-> ${tla(o.speed)}, hasView |-> ${o.hasView ? "TRUE" : "FALSE"}, view |-> ${view}]`;
  };
  return [
    "---------------------------- MODULE AcpSpeedObs ----------------------------",
    "(* Generated from one observed fx acp run. *)",
    `TModels == ${tlaSet(catalog.models)}`,
    `TSupFast == ${tlaSet(catalog.supFast)}`,
    `TSupUltra == ${tlaSet(catalog.supUltra)}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Models <- TModels",
  "    SupFast <- TSupFast",
  "    SupUltra <- TSupUltra",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export async function validate(observations: Observation[], dir: string, catalog: TraceCatalog) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, reason: "empty trace", matched: 0 };
  const obs = obsModule(observations, catalog);
  writeFileSync(join(dir, "AcpSpeedObs.tla"), obs);
  writeFileSync(join(dir, "AcpSpeedTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpSpeedTrace.tla", "AcpSpeedTrace.cfg", ["AcpSpeed.tla", "AcpSpeedTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  let matched: number;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) {
    verdict = "ACCEPTED";
    matched = observations.length;
  } else if (run.exitCode === 0 && /No error has been found/.test(run.output)) {
    verdict = "REJECTED";
    matched = run.distinctStates === 0 ? 0 : run.depth ?? 0;
  } else {
    verdict = "TOOL_ERROR";
    matched = 0;
  }
  const result = {
    verdict,
    matched,
    length: observations.length,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
