import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

export type Verdict = "ACCEPTED" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";
export type Model = "turns" | "children" | "fork" | "wiring";
export interface RuntimeEvidence {
  version: 1;
  sessionsRoot: string;
  sessionIds: string[];
  wiringTrace?: string;
  processes?: Array<{ pid: number; exitCode: number | null; signal: string | null }>;
  requiredModels: Model[];
  metadata?: Record<string, unknown>;
}
export interface RuntimeCheck {
  kind: string;
  sessionId?: string;
  verdict: Verdict;
  expected?: number;
  matched?: number;
  exitCode?: number;
  log?: string;
  detail?: string;
}
export interface RuntimeResult {
  version: 1;
  verdict: Verdict;
  checks: RuntimeCheck[];
  report: string;
  detail?: string;
}

const exitCodes: Record<Verdict, number> = { ACCEPTED: 0, REJECTED: 1, INCONCLUSIVE: 2, TOOL_ERROR: 3 };
const checker = resolve(import.meta.dirname, "check_runtime.py");

export function decodeResult(stdout: string, exitCode: number, evidence: RuntimeEvidence): RuntimeResult {
  const result = JSON.parse(stdout) as RuntimeResult;
  if (result.version !== 1 || !(result.verdict in exitCodes) || !Array.isArray(result.checks) ||
      typeof result.report !== "string" || exitCodes[result.verdict] !== exitCode) {
    throw new Error("Invalid TLC bridge result or mismatched process exit");
  }
  if (result.verdict === "ACCEPTED") {
    if (!result.checks.length || result.checks.some(check => check.verdict !== "ACCEPTED" ||
        !Number.isInteger(check.expected) || check.expected! <= 0 || check.matched !== check.expected || check.exitCode !== 12)) {
      throw new Error("TLC acceptance lacks complete, nonempty sentinel proof");
    }
    for (const model of evidence.requiredModels) {
      const checks = result.checks.filter(check => check.kind === model);
      if (!checks.length) throw new Error(`Required ${model} checks absent`);
      if (model === "turns" && evidence.sessionIds.some(id => !checks.some(check => check.sessionId === id))) {
        throw new Error("An expected session lacks its turn proof");
      }
    }
  }
  return result;
}

export async function inspectRuntime(evidence: RuntimeEvidence, reportRoot: string): Promise<RuntimeResult> {
  mkdirSync(reportRoot, { recursive: true, mode: 0o700 });
  const invocation = mkdtempSync(join(reportRoot, "tlc-"));
  const request = join(invocation, "request.json");
  writeFileSync(request, JSON.stringify(evidence, null, 2), { mode: 0o600 });
  const command = ["python3", checker, "--request", request, "--report", join(invocation, "report")];
  const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
  ]);
  writeFileSync(join(invocation, "process.json"), JSON.stringify({ command, exitCode, stdout, stderr }, null, 2), { mode: 0o600 });
  try {
    return decodeResult(stdout, exitCode, evidence);
  } catch (error) {
    throw new Error(`TLC bridge protocol/tool failure; evidence retained at ${invocation}: ${error}`);
  }
}

export function requireAccepted(result: RuntimeResult): void {
  if (result.verdict !== "ACCEPTED") {
    throw new Error(`TLC ${result.verdict}; evidence retained at ${result.report}: ${JSON.stringify(result.checks)}`);
  }
}
