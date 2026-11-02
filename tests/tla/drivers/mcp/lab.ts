// Shared builder for scenarios that run tests/tla/drivers/mcp/labs/stdio_lab.zig against the
// scripted fake stdio server (U02 transport-level and U03 to U05 scenarios).

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Rule } from "./fakes/stdio";
import type { Scenario, ScenarioContext, TraceExpectation } from "./scenario";

const FAKE = join(import.meta.dir, "fakes/stdio.ts");
export const PING = '{"jsonrpc":"2.0","id":1,"method":"ping"}';
export const PING2 = '{"jsonrpc":"2.0","id":2,"method":"ping"}';

export interface Seen {
  did?: { action?: string; state?: string; error?: string; expect?: string; met?: boolean; era_error?: string };
  era?: { ready?: string; failed?: string };
  tools?: { event: string; fresh?: boolean; count?: number; names?: string[]; invalid?: number; duplicate?: number };
  call?: { id: number; kind: string; is_error?: boolean; content?: string; structured?: string | null; code?: number };
  seen?: { message?: string; stderr?: string; dropped?: string; state?: string; lost?: boolean };
  sub?: { sub: number; deliver?: string; acknowledged?: number; ended?: string };
  outcome?: { id: number; outcome: string };
  final?: {
    state: string;
    generation: number;
    attempts: number;
    term_sent: boolean;
    kill_sent: boolean;
    errored: boolean;
    stderr_dropped: number;
    spawn_error: string | null;
    in_flight?: number;
    era?: string;
    era_version?: string;
    era_failure?: string | null;
    catalog?: string;
    tools?: number;
  };
}

export interface LabCase {
  name: string;
  unit: string;
  description: string;
  rules?: Rule[];
  /** Extra fake-server flags, or a full replacement command when `server` is set. */
  fakeFlags?: string[];
  server?: string[];
  labFlags?: string[];
  script: string[];
  /** The model's failure limit; the lab's default is 8. */
  maxAttempts?: number;
  verdict?: "ACCEPTED" | "REJECTED";
  /** Also check the request machine's trace (U02 over stdio). */
  requestTrace?: boolean;
  /** Also check the era machine's trace (U04): how many preferred versions the lab has. */
  era?: { preferred: number; verdict?: "ACCEPTED" | "REJECTED" };
  /** Also check the catalog machine's trace (U05): the lab's page limit. */
  catalog?: { maxPages: number; verdict?: "ACCEPTED" | "REJECTED" };
  /** Also check the subscription machine's trace (U10). */
  subscription?: { maxTries?: number; verdict?: "ACCEPTED" | "REJECTED" };
  /** Checks the lab's output and the fake server's log of every line it saw. */
  check?: (lines: Seen[], final: NonNullable<Seen["final"]>, serverLog: { dir: string; line: string }[]) => string | null;
  timeoutMs?: number;
  real?: boolean;
}

export function labScenario(c: LabCase): Scenario {
  let caseDir = "";
  const traces: TraceExpectation[] = [
    { machine: "stdio", instance: "lab", specDir: "tests/tla/mcp", wrapper: "StdioConnTrace", verdict: c.verdict ?? "ACCEPTED", constants: { ObsMaxAttempts: c.maxAttempts ?? 8 } },
  ];
  if (c.requestTrace) traces.push({ machine: "request", instance: "lab", specDir: "tests/tla/mcp", wrapper: "RequestTrace", verdict: "ACCEPTED" });
  if (c.era) {
    traces.push({ machine: "era", instance: "lab", specDir: "tests/tla/mcp", wrapper: "EraTrace", verdict: c.era.verdict ?? "ACCEPTED", constants: { ObsPreferredCount: c.era.preferred } });
  }
  if (c.catalog) {
    traces.push({ machine: "catalog", instance: "lab", specDir: "tests/tla/mcp", wrapper: "CatalogTrace", verdict: c.catalog.verdict ?? "ACCEPTED", constants: { ObsMaxPages: c.catalog.maxPages } });
  }
  if (c.subscription) {
    traces.push({ machine: "subscription", instance: "lab", specDir: "tests/tla/mcp", wrapper: "SubscriptionTrace", verdict: c.subscription.verdict ?? "ACCEPTED", constants: { ObsMaxTries: c.subscription.maxTries ?? 8 } });
  }
  return {
    name: c.name,
    unit: c.unit,
    description: c.description,
    needs: ["stdio_lab"],
    setup: (ctx: ScenarioContext) => {
      caseDir = ctx.caseDir;
      writeFileSync(join(ctx.caseDir, "rules.json"), JSON.stringify(c.rules ?? []));
      writeFileSync(join(ctx.caseDir, "script.txt"), c.script.join("\n") + "\n");
    },
    command: (ctx: ScenarioContext) => [
      ctx.bin.stdio_lab,
      ctx.tracePath,
      join(ctx.caseDir, "script.txt"),
      ...(c.labFlags ?? []),
      "--",
      ...(c.server ?? [process.execPath, FAKE, "--script", join(ctx.caseDir, "rules.json"), "--log", join(ctx.caseDir, "server.jsonl"), ...(c.fakeFlags ?? [])]),
    ],
    expect: {
      exit: 0,
      traces,
      stdout: (text) => {
        const lines = text.split("\n").filter(Boolean).map((l) => JSON.parse(l) as Seen);
        const unmet = lines.find((l) => l.did?.met === false || l.did?.error !== undefined);
        if (unmet) return `script step failed: ${JSON.stringify(unmet.did)}`;
        const final = lines.at(-1)?.final;
        if (!final) return "no final line";
        if (!c.check) return null;
        let serverLog: { dir: string; line: string }[] = [];
        try {
          serverLog = readFileSync(join(caseDir, "server.jsonl"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
        } catch {
          // No log: the server never started.
        }
        return c.check(lines, final, serverLog);
      },
    },
    timeoutMs: c.timeoutMs,
    real: c.real,
  };
}

export const messages = (lines: Seen[]) => lines.filter((l) => l.seen?.message !== undefined).map((l) => l.seen!.message!);
export const expectFinal = (final: NonNullable<Seen["final"]>, want: Partial<NonNullable<Seen["final"]>>): string | null => {
  for (const [key, value] of Object.entries(want)) {
    const got = (final as unknown as Record<string, unknown>)[key];
    if (got !== value) return `final ${key} is ${JSON.stringify(got)}, expected ${JSON.stringify(value)}`;
  }
  return null;
};

export const outcomes = (lines: Seen[]) =>
  Object.fromEntries(lines.filter((l) => l.outcome).map((l) => [l.outcome!.id, l.outcome!.outcome]));
