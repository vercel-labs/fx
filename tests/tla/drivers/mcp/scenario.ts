// Scenario contract for the MCP engine Bun driver.

import type { Verdict } from "./bridge";

export interface ScenarioContext {
  /** Repository root. */
  root: string;
  /** Binaries built for this run, by name (for example "stdio_lab", "trace_demo"). */
  bin: { [name: string]: string };
  /** Temporary HOME for this case. */
  home: string;
  /** Temporary working directory for this case. */
  workdir: string;
  /** Where the binary under test writes its trace (also exported as MCPV2_TRACE). */
  tracePath: string;
  /** Folder for scenario-specific files such as fake-server scripts and logs. */
  caseDir: string;
}

export interface TraceExpectation {
  machine: string;
  instance?: string;
  /** Folder holding the model and its trace wrapper. Relative paths resolve from the repository root. */
  specDir: string;
  wrapper: string;
  /** ACCEPTED for normal runs. REJECTED only for known-bad controls. */
  verdict: Verdict;
  /** Model constants the trace can't show, defined in the generated TraceObs module. */
  constants?: { [name: string]: number };
}

export interface Scenario {
  /** Unique name, used with --case. */
  name: string;
  /** Ledger item that owns the scenario, for example "S05" or "U03". */
  unit: string;
  description: string;
  /** Binaries the scenario needs, built by the driver. */
  needs: string[];
  /** Command line to run. Called after the case folders exist. */
  command(ctx: ScenarioContext): string[];
  /** Optional setup, for example writing a fake-server script into caseDir. */
  setup?(ctx: ScenarioContext): void;
  expect: {
    exit: number;
    traces: TraceExpectation[];
    /** Optional stdout check. Returns a problem description, or null when stdout is right. */
    stdout?: (text: string) => string | null;
  };
  /** Talks to a real server; the driver here never runs it. */
  real?: boolean;
  /** Hard limit for the command, in milliseconds. Defaults to 30 s. */
  timeoutMs?: number;
}
