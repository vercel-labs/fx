/**
 * Model-backed A/B harness for agent-quality rows.
 *
 * This compares two explicit fx binaries on the same focused matrix rows. It is
 * intentionally not a no-key CI gate: results are noisy model-backed signals,
 * reported as paired pass-rate deltas with raw artifacts for inspection.
 */
import { spawn as nodeSpawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  firstToolMatchesExpectation,
  forbiddenToolsUsed,
  matrixRowById,
  type AgentQualityMatrixRow,
  type RecordedToolCall,
} from "./agent-quality-matrix";
import { REPO_ROOT, type HeadlessResult } from "./eval-helpers";

export const DEFAULT_AB_ROW_IDS = [
  "slash-command-definition-search",
  "unfamiliar-feature-inspect-before-question",
  "github-handle-not-needed",
  "github-changelog-local-first",
  "git-history-local",
] as const;

export type AbSide = "baseline" | "candidate";
export type ObservedDelta =
  | "improved"
  | "regressed"
  | "unchanged-pass"
  | "unchanged-fail"
  | "inconclusive";

export interface AbScore {
  passed: boolean;
  reason: string;
  firstTool?: string;
  forbiddenTools: string[];
  predicatePassed: boolean;
}

export interface AbRunResult {
  side: AbSide;
  rowId: string;
  trialIndex: number;
  orderIndex: number;
  binaryPath: string;
  binarySha256: string;
  versionOutput: string;
  stdout: string;
  stderr: string;
  code: number | null;
  json?: HeadlessResult;
  score: AbScore;
}

export interface AbConfig {
  baselineBin: string;
  candidateBin: string;
  model: string;
  rowIds: string[];
  trials: number;
  outputDir: string;
  workspaceRoot: string;
  timeoutMs: number;
}

export interface AbRunOptions {
  env?: Record<string, string | undefined>;
  score?: (result: HeadlessResult) => AbScore;
}

export function createTrialOrder(trialIndex: number): [AbSide, AbSide] {
  return trialIndex % 2 == 0 ? ["baseline", "candidate"] : ["candidate", "baseline"];
}

export function redactSensitiveValue(key: string, value: string): string {
  if (/(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)/i.test(key)) return "[redacted]";
  return value;
}

export function requireAbsoluteExecutableBinary(path: string, label: string): string {
  if (!isAbsolute(path)) {
    throw new Error(`${label} binary must be an absolute path, got ${path}`);
  }
  if (!existsSync(path)) {
    throw new Error(`${label} binary does not exist: ${path}`);
  }
  const stat = statSync(path);
  if (!stat.isFile()) {
    throw new Error(`${label} binary is not a file: ${path}`);
  }
  if ((stat.mode & 0o111) == 0) {
    throw new Error(`${label} binary is not executable: ${path}`);
  }
  return path;
}

export function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function parseRowIds(raw: string | undefined): string[] {
  if (!raw || raw.trim().length == 0) return [...DEFAULT_AB_ROW_IDS];
  return raw
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}

export function loadAbConfigFromEnv(env: NodeJS.ProcessEnv = process.env): AbConfig {
  const baselineBin = requireAbsoluteExecutableBinary(
    env.FX_AB_BASELINE_BIN ?? "",
    "baseline",
  );
  const candidateBin = requireAbsoluteExecutableBinary(
    env.FX_AB_CANDIDATE_BIN ?? "",
    "candidate",
  );
  const model = env.FX_AB_MODEL;
  if (!model) throw new Error("FX_AB_MODEL is required for A/B runs");

  const trials = Number(env.FX_AB_TRIALS ?? "3");
  if (!Number.isInteger(trials) || trials <= 0) {
    throw new Error(`FX_AB_TRIALS must be a positive integer, got ${env.FX_AB_TRIALS}`);
  }

  const outputDir =
    env.FX_AB_OUTPUT_DIR ??
    mkdtempSync(join(tmpdir(), `fx-agent-quality-ab-${Date.now()}-`));

  return {
    baselineBin,
    candidateBin,
    model,
    rowIds: parseRowIds(env.FX_AB_ROWS),
    trials,
    outputDir,
    workspaceRoot: env.FX_AB_WORKSPACE_ROOT ?? REPO_ROOT,
    timeoutMs: Number(env.FX_AB_TIMEOUT_MS ?? "300000"),
  };
}

function rowByIdOrThrow(rowId: string): AgentQualityMatrixRow {
  const row = matrixRowById(rowId);
  if (!row) throw new Error(`Unknown agent quality row: ${rowId}`);
  return row;
}

function toolCallsForScore(result: HeadlessResult): RecordedToolCall[] {
  return result.tool_calls ?? [];
}

function rowPredicate(row: AgentQualityMatrixRow, result: HeadlessResult): boolean {
  const output = result.output.toLowerCase();
  switch (row.id) {
    case "slash-command-definition-search":
      return output.includes("src/core/slash_commands/command_specs.zig") ||
        (output.includes("src/core/slash_commands") && output.includes("command_specs.zig")) ||
        output.includes("slash_commands/command_specs.zig");
    case "unfamiliar-feature-inspect-before-question":
      return output.includes("mcp");
    case "github-handle-not-needed":
      return output.includes("changelog");
    case "github-changelog-local-first":
      return output.includes("changelog");
    case "git-history-local":
      return /\b(commit|commits|change|changes|git|history|log)\b/i.test(result.output);
    default:
      return false;
  }
}

export function scoreAbTrial(row: AgentQualityMatrixRow, result: HeadlessResult): AbScore {
  const toolCalls = toolCallsForScore(result);
  const firstTool = toolCalls[0];
  const firstToolMatches = firstToolMatchesExpectation(row, firstTool);
  const forbiddenTools = forbiddenToolsUsed(row, toolCalls);
  const exitOk = result.exit_code === 0;
  const predicatePassed = rowPredicate(row, result);
  const reasons: string[] = [];
  if (!firstToolMatches) reasons.push("first tool did not match expected category");
  if (forbiddenTools.length > 0) reasons.push(`forbidden tools used: ${forbiddenTools.join(", ")}`);
  if (!exitOk) reasons.push(`exit_code was ${result.exit_code}`);
  if (!predicatePassed) reasons.push("row-specific output predicate failed");
  return {
    passed: reasons.length == 0,
    reason: reasons.length == 0 ? "passed" : reasons.join("; "),
    firstTool: firstTool?.name,
    forbiddenTools,
    predicatePassed,
  };
}

export function classifyObservedDelta(input: {
  baselinePasses: number;
  candidatePasses: number;
  trials: number;
}): ObservedDelta {
  if (input.trials <= 0) return "inconclusive";
  if (input.candidatePasses > input.baselinePasses) return "improved";
  if (input.candidatePasses < input.baselinePasses) return "regressed";
  if (input.candidatePasses > 0) return "unchanged-pass";
  if (input.baselinePasses == 0 && input.candidatePasses == 0) return "unchanged-fail";
  return "inconclusive";
}

function sideBinary(config: AbConfig, side: AbSide): string {
  return side === "baseline" ? config.baselineBin : config.candidateBin;
}

function sanitizedEnvMetadata(model: string): Record<string, string> {
  const keys = ["FX_MODEL", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN", "NO_COLOR"];
  const metadata: Record<string, string> = {};
  for (const key of keys) {
    const value = key === "FX_MODEL" ? model : process.env[key];
    if (value) metadata[key] = redactSensitiveValue(key, value);
  }
  return metadata;
}

async function runProcess(
  command: string,
  args: string[],
  opts: { cwd: string; env: Record<string, string | undefined>; timeoutMs: number },
): Promise<{ stdout: string; stderr: string; code: number | null }> {
  return new Promise((resolvePromise) => {
    const child = nodeSpawn(command, args, {
      cwd: opts.cwd,
      env: opts.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdoutBufs: Buffer[] = [];
    const stderrBufs: Buffer[] = [];
    child.stdout.on("data", (d: Buffer) => stdoutBufs.push(d));
    child.stderr.on("data", (d: Buffer) => stderrBufs.push(d));
    child.stdin.end();
    const timer = setTimeout(() => child.kill("SIGKILL"), opts.timeoutMs);
    child.on("close", (code: number | null) => {
      clearTimeout(timer);
      resolvePromise({
        stdout: Buffer.concat(stdoutBufs).toString(),
        stderr: Buffer.concat(stderrBufs).toString(),
        code,
      });
    });
  });
}

async function versionFor(binaryPath: string, env: Record<string, string | undefined>): Promise<string> {
  const version = await runProcess(binaryPath, ["--version"], {
    cwd: REPO_ROOT,
    env,
    timeoutMs: 15_000,
  });
  const versionOutput = (version.stdout || version.stderr).trim();
  if (version.code === 0 && versionOutput.length > 0) return versionOutput;

  const status = await runProcess(binaryPath, ["status", "--json"], {
    cwd: REPO_ROOT,
    env,
    timeoutMs: 15_000,
  });
  const statusOutput = (status.stdout || status.stderr).trim();
  return `--version unsupported (exit ${version.code}); status --json: ${statusOutput}`;
}

export async function runAbTrial(
  config: AbConfig,
  row: AgentQualityMatrixRow,
  side: AbSide,
  trialIndex: number,
  orderIndex: number,
  options: AbRunOptions = {},
): Promise<AbRunResult> {
  const binaryPath = sideBinary(config, side);
  const trialHome = mkdtempSync(join(tmpdir(), `fx-ab-${row.id}-${trialIndex}-${side}-`));
  const env: Record<string, string | undefined> = {
    ...options.env,
    PATH: process.env.PATH ?? "",
    HOME: trialHome,
    NO_COLOR: "1",
    FX_MODEL: config.model,
    AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
    VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
  };

  try {
    const versionOutput = await versionFor(binaryPath, env);
    const result = await runProcess(
      binaryPath,
      [
        "ask",
        "--auto",
        "--json",
        "--no-save",
        "--timeout",
        String(config.timeoutMs),
        row.userPrompt,
      ],
      {
        cwd: config.workspaceRoot,
        env,
        timeoutMs: config.timeoutMs + 10_000,
      },
    );

    let json: HeadlessResult | undefined;
    let score: AbScore;
    try {
      json = JSON.parse(result.stdout.trim()) as HeadlessResult;
      score = options.score ? options.score(json) : scoreAbTrial(row, json);
      if (json.model !== config.model) {
        score = {
          ...score,
          passed: false,
          reason: `${score.reason}; json.model ${json.model} did not match FX_AB_MODEL ${config.model}`,
        };
      }
    } catch (err) {
      score = {
        passed: false,
        reason: `failed to parse JSON output: ${err instanceof Error ? err.message : String(err)}`,
        forbiddenTools: [],
        predicatePassed: false,
      };
    }

    if (result.code !== 0 || (json && json.exit_code !== 0)) {
      score = {
        ...score,
        passed: false,
        reason: `${score.reason}; process exit ${result.code}, reported exit ${json?.exit_code}`,
      };
    }

    const run: AbRunResult = {
      side,
      rowId: row.id,
      trialIndex,
      orderIndex,
      binaryPath,
      binarySha256: sha256File(binaryPath),
      versionOutput,
      stdout: result.stdout,
      stderr: result.stderr,
      code: result.code,
      json,
      score,
    };
    writeArtifact(config, run);
    return run;
  } finally {
    rmSync(trialHome, { recursive: true, force: true });
  }
}

function writeArtifact(config: AbConfig, run: AbRunResult): void {
  const dir = join(config.outputDir, run.rowId, `trial-${run.trialIndex}`);
  mkdirSync(dir, { recursive: true });
  const artifactPath = join(dir, `${run.orderIndex}-${run.side}.json`);
  writeFileSync(
    artifactPath,
    JSON.stringify(
      {
        ...run,
        env: sanitizedEnvMetadata(config.model),
      },
      null,
      2,
    ),
  );
}

export async function runAbComparison(config = loadAbConfigFromEnv()): Promise<void> {
  mkdirSync(config.outputDir, { recursive: true });
  const summary: Array<{
    rowId: string;
    baselinePasses: number;
    candidatePasses: number;
    trials: number;
    delta: ObservedDelta;
  }> = [];

  for (const rowId of config.rowIds) {
    const row = rowByIdOrThrow(rowId);
    let baselinePasses = 0;
    let candidatePasses = 0;
    for (let trial = 0; trial < config.trials; trial += 1) {
      const order = createTrialOrder(trial);
      for (const [orderIndex, side] of order.entries()) {
        const run = await runAbTrial(config, row, side, trial, orderIndex);
        if (side === "baseline" && run.score.passed) baselinePasses += 1;
        if (side === "candidate" && run.score.passed) candidatePasses += 1;
      }
    }
    summary.push({
      rowId,
      baselinePasses,
      candidatePasses,
      trials: config.trials,
      delta: classifyObservedDelta({ baselinePasses, candidatePasses, trials: config.trials }),
    });
  }

  const summaryPath = join(config.outputDir, "summary.json");
  mkdirSync(dirname(summaryPath), { recursive: true });
  writeFileSync(summaryPath, JSON.stringify({ config: {
    baselineBin: config.baselineBin,
    candidateBin: config.candidateBin,
    model: config.model,
    rowIds: config.rowIds,
    trials: config.trials,
    outputDir: config.outputDir,
    workspaceRoot: resolve(config.workspaceRoot),
  }, summary }, null, 2));

  console.log(`A/B artifacts: ${config.outputDir}`);
  for (const row of summary) {
    console.log(
      `${row.rowId}: baseline ${row.baselinePasses}/${row.trials}, candidate ${row.candidatePasses}/${row.trials} -> ${row.delta}`,
    );
  }
}
