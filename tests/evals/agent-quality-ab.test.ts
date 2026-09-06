import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DEFAULT_AB_ROW_IDS,
  classifyObservedDelta,
  createTrialOrder,
  loadAbConfigFromEnv,
  redactSensitiveValue,
  requireAbsoluteExecutableBinary,
  runAbComparison,
  runAbTrial,
  scoreAbTrial,
} from "./agent-quality-ab";
import { matrixRowById, type RecordedToolCall } from "./agent-quality-matrix";

describe("agent quality A/B harness helpers", () => {
  test("custom evidence scoring preserves model and home isolation and cleans its home", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-ab-oracle-"));
    let observedHome: string | undefined;
    try {
      const binary = join(root, "fixture");
      writeFileSync(binary, `#!${process.execPath}\nimport {writeFileSync} from "node:fs";
if (process.argv.includes("--version")) { console.log("fixture"); process.exit(0); }
writeFileSync("observed-home", process.env.HOME);
console.log(JSON.stringify({exit_code:0, model:process.env.FX_TEST_NO_MODEL ? undefined : process.env.FX_MODEL, output:process.env.FX_EVIDENCE, session_id:"", steps:0, tool_calls:[]}));
process.exit(Number(process.env.FX_TEST_EXIT ?? "0"));\n`, { mode: 0o755 });
      const config = {
        baselineBin: binary, candidateBin: binary, model: "fixture/model", rowIds: [],
        trials: 1, outputDir: join(root, "artifacts"), workspaceRoot: root, timeoutMs: 5_000,
      };
      const row = matrixRowById("git-history-local")!;
      const options = {
        env: { FX_EVIDENCE: "independent-proof", HOME: root, FX_MODEL: "wrong/model" },
        score: (result: { output: string }) => ({
          passed: result.output === "independent-proof", reason: "fixture receipt",
          forbiddenTools: [], predicatePassed: result.output === "independent-proof",
        }),
      };
      const run = await runAbTrial(config, row, "candidate", 0, 0, options);
      observedHome = readFileSync(join(root, "observed-home"), "utf8");
      expect(run.score.passed).toBe(true);
      expect(run.json?.model).toBe(config.model);
      expect(observedHome).not.toBe(root);
      expect(existsSync(observedHome)).toBe(false);

      const failed = await runAbTrial(config, row, "candidate", 1, 0, {
        ...options, env: { ...options.env, FX_TEST_EXIT: "17" },
      });
      observedHome = readFileSync(join(root, "observed-home"), "utf8");
      expect(failed.code).toBe(17);
      expect(failed.score.passed).toBe(false);
      expect(failed.score.reason).toContain("process exit");
      expect(existsSync(observedHome)).toBe(false);
      const unidentified = await runAbTrial(config, row, "candidate", 2, 0, {
        ...options, env: { ...options.env, FX_TEST_NO_MODEL: "1" },
      });
      observedHome = readFileSync(join(root, "observed-home"), "utf8");
      expect(unidentified.score.passed).toBe(false);
      expect(unidentified.score.reason).toContain("did not match");
      expect(existsSync(observedHome)).toBe(false);
    } finally {
      if (observedHome?.startsWith(join(tmpdir(), "fx-ab-git-history-local-"))) {
        rmSync(observedHome, { recursive: true, force: true });
      }
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("uses the focused first-turn local-first rows by default", () => {
    expect(DEFAULT_AB_ROW_IDS).toEqual([
      "slash-command-definition-search",
      "unfamiliar-feature-inspect-before-question",
      "github-handle-not-needed",
      "github-changelog-local-first",
      "git-history-local",
    ]);
  });

  test("alternates baseline and candidate order by trial", () => {
    expect(createTrialOrder(0)).toEqual(["baseline", "candidate"]);
    expect(createTrialOrder(1)).toEqual(["candidate", "baseline"]);
    expect(createTrialOrder(2)).toEqual(["baseline", "candidate"]);
  });

  test("rejects bare fx and relative binary paths", () => {
    expect(() => requireAbsoluteExecutableBinary("fx", "baseline")).toThrow(/absolute path/);
    expect(() => requireAbsoluteExecutableBinary("./zig-out/bin/fx", "candidate")).toThrow(/absolute path/);
  });

  test("redacts credential-looking values", () => {
    expect(redactSensitiveValue("AI_GATEWAY_API_KEY", "secret-value")).toBe("[redacted]");
    expect(redactSensitiveValue("FX_MODEL", "provider/test-model")).toBe("provider/test-model");
  });

  test("scores focused rows using first tool forbidden tools and row predicate", () => {
    const row = matrixRowById("slash-command-definition-search");
    expect(row).toBeDefined();

    const toolCalls: RecordedToolCall[] = [{ name: "grep_files" }];
    const score = scoreAbTrial(row!, {
      exit_code: 0,
      model: "provider/test-model",
      output: "Slash commands are defined in src/core/slash_commands/command_specs.zig.",
      session_id: "",
      steps: 2,
      tool_calls: toolCalls.map((toolCall) => ({ ...toolCall, status: "success" })),
    });

    expect(score.passed).toBe(true);
    expect(score.firstTool).toBe("grep_files");
    expect(score.forbiddenTools).toEqual([]);
  });

  test("accepts slash-command output that proves the directory and spec file from local inspection", () => {
    const row = matrixRowById("slash-command-definition-search");
    expect(row).toBeDefined();

    const score = scoreAbTrial(row!, {
      exit_code: 0,
      model: "provider/test-model",
      output:
        "Slash commands are defined in src/core/slash_commands/. command_specs.zig is the central registry.",
      session_id: "",
      steps: 1,
      tool_calls: [{ name: "glob_files", status: "success" }],
    });

    expect(score.passed).toBe(true);
  });

  test("does not fail the GitHub-handle row for mentioning handles without asking", () => {
    const row = matrixRowById("github-handle-not-needed");
    expect(row).toBeDefined();

    const score = scoreAbTrial(row!, {
      exit_code: 0,
      model: "provider/test-model",
      output:
        "The changelog is maintained in CHANGELOG.md. Contributors are listed as GitHub handles when known; no handle is needed from you.",
      session_id: "",
      steps: 2,
      tool_calls: [{ name: "glob_files", status: "success" }],
    });

    expect(score.passed).toBe(true);
  });

  test("fails when a focused row uses forbidden web_search", () => {
    const row = matrixRowById("slash-command-definition-search");
    expect(row).toBeDefined();

    const score = scoreAbTrial(row!, {
      exit_code: 0,
      model: "provider/test-model",
      output: "Slash commands are defined in src/core/slash_commands/command_specs.zig.",
      session_id: "",
      steps: 2,
      tool_calls: [{ name: "web_search", status: "success" }],
    });

    expect(score.passed).toBe(false);
    expect(score.forbiddenTools).toEqual(["web_search"]);
    expect(score.reason).toContain("first tool");
  });

  test("classifies paired trial deltas without deterministic single-run claims", () => {
    expect(classifyObservedDelta({ baselinePasses: 1, candidatePasses: 2, trials: 3 })).toBe(
      "improved",
    );
    expect(classifyObservedDelta({ baselinePasses: 2, candidatePasses: 1, trials: 3 })).toBe(
      "regressed",
    );
    expect(classifyObservedDelta({ baselinePasses: 2, candidatePasses: 2, trials: 3 })).toBe(
      "unchanged-pass",
    );
    expect(classifyObservedDelta({ baselinePasses: 0, candidatePasses: 0, trials: 3 })).toBe(
      "unchanged-fail",
    );
  });
});

const hasLiveAbConfig = Boolean(
  process.env.FX_AB_BASELINE_BIN &&
    process.env.FX_AB_CANDIDATE_BIN &&
    process.env.FX_AB_MODEL &&
    (process.env.AI_GATEWAY_API_KEY || process.env.VERCEL_OIDC_TOKEN),
);

const liveAbTest = hasLiveAbConfig ? test : test.skip;

describe("agent quality A/B live comparison", () => {
  liveAbTest(
    "compares configured baseline and candidate binaries on focused rows",
    async () => {
      await runAbComparison(loadAbConfigFromEnv());
    },
    30 * 60 * 1000,
  );
});
