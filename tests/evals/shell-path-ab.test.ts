/**
 * Model-backed A/B eval: shell commands see PATH edits from the user's startup
 * files.
 *
 * Each trial HOME gets a .zshrc and a .bash_profile that prepend a unique
 * marker directory to PATH, so whichever login shell passwd selects loads it.
 * The agent runs `echo $PATH` in 10 separate shell calls and replies DONE. A
 * trial passes when it makes at least 10 successful shell calls, uses no other
 * tool, and every printed PATH contains the marker directory. `fx ask --json`
 * reports no command output, so outputs are read from the raw command output
 * that `fx ask` streams to stderr.
 *
 * The comparison is report-only like agent-quality-ab: it prints and saves
 * per-side pass counts and per-trial wall time, and does not fail on model
 * noise. Per-trial wall time also includes one `fx --version` call.
 *
 * It makes real model calls, so run it only on the test billing lane, with
 * absolute paths to the two binaries:
 *
 *   cd tests/evals
 *   FX_AB_BASELINE_BIN=/abs/path/baseline/zig-out/bin/fx \
 *   FX_AB_CANDIDATE_BIN=/abs/path/candidate/zig-out/bin/fx \
 *   ~/.local/bin/aig test bun test shell-path-ab.test.ts
 *
 * The harness gives every fx run a fresh HOME and passes AI_GATEWAY_API_KEY
 * from the environment, so the test-lane key from `aig test` is the one billed.
 *
 * Optional: FX_AB_MODEL (defaults to EVAL_MODEL), FX_AB_TRIALS (default 3),
 * FX_AB_OUTPUT_DIR, FX_AB_TIMEOUT_MS, FX_AB_WORKSPACE_ROOT (defaults to an
 * empty temporary directory).
 */
import { describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  classifyObservedDelta,
  createTrialOrder,
  loadAbConfigFromEnv,
  runAbTrial,
  type AbConfig,
  type AbScore,
  type AbSide,
} from "./agent-quality-ab";
import {
  SHARED_MODEL_CONTEXT_CONTRACT,
  type AgentQualityMatrixRow,
} from "./agent-quality-matrix";
import { EVAL_MODEL, type HeadlessResult } from "./eval-helpers";

const ECHO_RUNS = 10;

const SHELL_PATH_ROW: AgentQualityMatrixRow = {
  id: "shell-path-startup-files",
  userPrompt:
    "Use the shell tool to run the command `echo $PATH` 10 separate times: one shell tool call per run, one call at a time, with exactly that command each time. Do not combine runs or change the command. After the tenth run, reply with exactly DONE.",
  failureCategory: "stale context",
  expectedFirstTool: { category: "shell", tools: ["shell"], commandPattern: "^echo \\$PATH$" },
  forbiddenTools: [],
  expectedUserVisibleBehavior:
    "Every shell call sees the PATH edits from the user's startup files.",
  deterministicCoverage: {
    type: "e2e",
    status: "planned",
    notes: "Fixture-gateway startup-file coverage lands with the shell snapshot change.",
  },
  modelBackedEval: {
    required: true,
    reason: "Checks that the model keeps calling shell and that each call sees the user's PATH.",
  },
  currentBaselineResult: { status: "unmeasured", notes: "Compared by this A/B eval." },
  targetResult: "The candidate passes every trial the baseline passes, with lower wall time.",
  coveredEntrypoints: [
    {
      entrypoint: "fx ask",
      contextContract: SHARED_MODEL_CONTEXT_CONTRACT,
      notes: "Captured shell calls under the default user profile.",
    },
  ],
};

function writeStartupFiles(home: string): string {
  const marker = join(home, `fx-shell-path-marker-${randomUUID().slice(0, 8)}`);
  mkdirSync(marker);
  const line = `export PATH="${marker}:$PATH"\n`;
  writeFileSync(join(home, ".zshrc"), line);
  writeFileSync(join(home, ".bash_profile"), line);
  return marker;
}

function shellCallCount(result: HeadlessResult | undefined): number {
  return (result?.tool_calls ?? []).filter((call) => call.name === "shell").length;
}

function scoreShellPathCalls(result: HeadlessResult): AbScore {
  const calls = result.tool_calls ?? [];
  const shellCalls = calls.filter((call) => call.name === "shell");
  const otherTools = [...new Set(calls.filter((call) => call.name !== "shell").map((call) => call.name))];
  const failed = shellCalls.filter(
    (call) => call.status !== "success" || call.command_result?.exit_code !== 0,
  ).length;
  const reasons: string[] = [];
  if (shellCalls.length < ECHO_RUNS) {
    reasons.push(`${shellCalls.length} shell calls, expected at least ${ECHO_RUNS}`);
  }
  if (otherTools.length > 0) reasons.push(`non-shell tools used: ${otherTools.join(", ")}`);
  if (failed > 0) reasons.push(`${failed} shell calls failed`);
  if (result.exit_code !== 0) reasons.push(`exit_code was ${result.exit_code}`);
  return {
    passed: reasons.length == 0,
    reason: reasons.length == 0 ? "passed" : reasons.join("; "),
    firstTool: calls[0]?.name,
    forbiddenTools: otherTools,
    predicatePassed: reasons.length == 0,
  };
}

function isPathOutput(line: string): boolean {
  const entries = line.trim().split(":");
  return entries.length > 1 && entries.every((entry) => entry === "" || entry.startsWith("/"));
}

function checkShellPathOutputs(stderr: string, marker: string, shellCalls: number) {
  const outputs = stderr.split("\n").filter(isPathOutput);
  const markedOutputs = outputs.filter((line) => line.trim().split(":").includes(marker)).length;
  const reasons: string[] = [];
  if (shellCalls == 0 || outputs.length < shellCalls) {
    reasons.push(`${outputs.length} PATH outputs for ${shellCalls} shell calls`);
  }
  if (markedOutputs < outputs.length) {
    reasons.push(`${outputs.length - markedOutputs} PATH outputs missing the marker directory`);
  }
  return {
    passed: reasons.length == 0,
    reason: reasons.join("; "),
    pathOutputs: outputs.length,
    markedOutputs,
  };
}

interface ShellPathTrial {
  side: AbSide;
  trialIndex: number;
  orderIndex: number;
  wallMs: number;
  passed: boolean;
  reason: string;
  shellCalls: number;
  pathOutputs: number;
  markedOutputs: number;
}

function sideSummary(trials: ShellPathTrial[], side: AbSide) {
  const runs = trials.filter((trial) => trial.side === side);
  const wall = runs.map((trial) => trial.wallMs).sort((a, b) => a - b);
  return {
    passes: runs.filter((trial) => trial.passed).length,
    trials: runs.length,
    meanWallMs: wall.length ? Math.round(wall.reduce((sum, ms) => sum + ms, 0) / wall.length) : null,
    medianWallMs: wall.length ? wall[Math.floor(wall.length / 2)] : null,
  };
}

async function runShellPathComparison(config: AbConfig): Promise<void> {
  mkdirSync(config.outputDir, { recursive: true });
  const trials: ShellPathTrial[] = [];
  for (let trialIndex = 0; trialIndex < config.trials; trialIndex += 1) {
    for (const [orderIndex, side] of createTrialOrder(trialIndex).entries()) {
      let marker = "";
      const started = performance.now();
      const run = await runAbTrial(config, SHELL_PATH_ROW, side, trialIndex, orderIndex, {
        setupHome: (home) => {
          marker = writeStartupFiles(home);
        },
        score: scoreShellPathCalls,
      });
      const wallMs = Math.round(performance.now() - started);
      const shellCalls = shellCallCount(run.json);
      const outputs = checkShellPathOutputs(run.stderr, marker, shellCalls);
      const reasons = [run.score.passed ? "" : run.score.reason, outputs.reason].filter(Boolean);
      const trial: ShellPathTrial = {
        side,
        trialIndex,
        orderIndex,
        wallMs,
        passed: run.score.passed && outputs.passed,
        reason: reasons.length == 0 ? "passed" : reasons.join("; "),
        shellCalls,
        pathOutputs: outputs.pathOutputs,
        markedOutputs: outputs.markedOutputs,
      };
      trials.push(trial);
      console.log(
        `${side} trial ${trialIndex}: ${trial.passed ? "pass" : "fail"} in ${wallMs} ms ` +
          `(${shellCalls} shell calls, ${trial.markedOutputs}/${trial.pathOutputs} PATH outputs with marker)` +
          (trial.passed ? "" : `: ${trial.reason}`),
      );
    }
  }

  const baseline = sideSummary(trials, "baseline");
  const candidate = sideSummary(trials, "candidate");
  const delta = classifyObservedDelta({
    baselinePasses: baseline.passes,
    candidatePasses: candidate.passes,
    trials: config.trials,
  });
  writeFileSync(
    join(config.outputDir, "shell-path-summary.json"),
    JSON.stringify(
      {
        config: {
          baselineBin: config.baselineBin,
          candidateBin: config.candidateBin,
          model: config.model,
          trials: config.trials,
          workspaceRoot: config.workspaceRoot,
        },
        baseline,
        candidate,
        delta,
        trials,
      },
      null,
      2,
    ),
  );
  console.log(`A/B artifacts: ${config.outputDir}`);
  console.log(
    `${SHELL_PATH_ROW.id}: baseline ${baseline.passes}/${baseline.trials} (median ${baseline.medianWallMs} ms), ` +
      `candidate ${candidate.passes}/${candidate.trials} (median ${candidate.medianWallMs} ms) -> ${delta}`,
  );
}

describe("shell PATH A/B scoring", () => {
  const marker = "/tmp/home/fx-shell-path-marker-test";
  const shell = { name: "shell", status: "success", command_result: { command: "echo $PATH", exit_code: 0 } };
  const headless = (tool_calls: HeadlessResult["tool_calls"]): HeadlessResult => ({
    output: "DONE", exit_code: 0, model: "fixture/model", session_id: "", steps: tool_calls.length, tool_calls,
  });

  test("passes ten successful shell calls whose PATH outputs carry the marker", () => {
    expect(scoreShellPathCalls(headless(Array.from({ length: 10 }, () => shell))).passed).toBe(true);
    const stderr = Array.from({ length: 10 }, () => `Running echo $PATH\n${marker}:/usr/bin:/bin\n`).join("");
    expect(checkShellPathOutputs(stderr, marker, 10)).toMatchObject({ passed: true, pathOutputs: 10, markedOutputs: 10 });
  });

  test("fails short runs, other tools and PATH outputs without the marker", () => {
    expect(scoreShellPathCalls(headless(Array.from({ length: 9 }, () => shell))).passed).toBe(false);
    const mixed = scoreShellPathCalls(headless([...Array.from({ length: 10 }, () => shell), { name: "read_file", status: "success" }]));
    expect(mixed.passed).toBe(false);
    expect(mixed.forbiddenTools).toEqual(["read_file"]);
    const stderr = `Running echo $PATH\n${marker}:/usr/bin\nRunning echo $PATH\n/usr/bin:/bin\n`;
    expect(checkShellPathOutputs(stderr, marker, 2)).toMatchObject({ passed: false, pathOutputs: 2, markedOutputs: 1 });
  });
});

const hasLiveConfig = Boolean(
  process.env.FX_AB_BASELINE_BIN &&
    process.env.FX_AB_CANDIDATE_BIN &&
    (process.env.AI_GATEWAY_API_KEY || process.env.VERCEL_OIDC_TOKEN),
);

describe("shell PATH A/B live comparison", () => {
  (hasLiveConfig ? test : test.skip)(
    "compares startup-file PATH visibility and wall time between binaries",
    async () => {
      const workspace = mkdtempSync(join(tmpdir(), "fx-shell-path-ab-workspace-"));
      try {
        await runShellPathComparison(
          loadAbConfigFromEnv({
            ...process.env,
            FX_AB_MODEL: process.env.FX_AB_MODEL ?? EVAL_MODEL,
            FX_AB_WORKSPACE_ROOT: process.env.FX_AB_WORKSPACE_ROOT ?? workspace,
          }),
        );
      } finally {
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    30 * 60 * 1000,
  );
});
