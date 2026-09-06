import { afterEach, describe, expect, test } from "bun:test";
import { execSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertFirstToolIn,
  assertNoAskUserQuestionMatching,
  assertNoTerminalExecMatches,
  assertTerminalExecMatches,
  assertToolNotUsed,
  cleanupWorkDir,
  createWorkDir,
  type EvalResult,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 300_000;
const LOCAL_FIRST_TOOLS = [
  "glob_files",
  "grep_files",
  "read_file",
  "shell",
] as const;

let workDir: string | null = null;

afterEach(() => {
  if (workDir) {
    cleanupWorkDir(workDir);
    workDir = null;
  }
});

function seedGitRepo(dir: string, remote: string): void {
  execSync("git init -b main", { cwd: dir, stdio: "pipe" });
  execSync("git config user.email test@example.com", { cwd: dir, stdio: "pipe" });
  execSync("git config user.name Test", { cwd: dir, stdio: "pipe" });
  execSync(`git remote add origin ${JSON.stringify(remote)}`, {
    cwd: dir,
    stdio: "pipe",
  });
}

function seedV0ChangelogRepo(dir: string): void {
  seedGitRepo(dir, "https://github.com/vercel/v0.git");
  mkdirSync(join(dir, "apps", "www"), { recursive: true });
  writeFileSync(
    join(dir, "CHANGELOG.md"),
    [
      "# Changelog",
      "",
      "## 1.0.0",
      "",
      "- The v0 changelog is maintained in this root file.",
      "",
    ].join("\n"),
  );
  writeFileSync(
    join(dir, "apps", "www", "release-notes.ts"),
    "export const changelogPath = '../../CHANGELOG.md';\n",
  );
  execSync("git add . && git commit -m initial", { cwd: dir, stdio: "pipe" });
}

function seedFxHistoryRepo(dir: string): void {
  seedGitRepo(dir, "https://github.com/vercel-labs/fx.git");
  writeFileSync(join(dir, "README.md"), "# fx\n");
  execSync("git add . && git commit -m initial", { cwd: dir, stdio: "pipe" });
}

function assertNoWebSearchOrHandleQuestion(result: EvalResult): void {
  assertToolNotUsed(result, "web_search");
  assertNoAskUserQuestionMatching(result, /GitHub handle/i);
}

function assertFirstActionIsLocal(result: EvalResult): void {
  assertFirstToolIn(result, LOCAL_FIRST_TOOLS);
  const first = result.json.tool_calls[0];
  if (first?.name === "shell") {
    expect(/^git\s+/.test(first.command_result?.command ?? "")).toBe(true);
  }
}

describe("eval: GitHub and repo routing", () => {
  test(
    "inspects matching current GitHub repo locally before remote metadata",
    async () => {
      workDir = createWorkDir();
      seedV0ChangelogRepo(workDir);

      const result = await runEval(
        "investigate how the v0 changelog works in the v0 GitHub repo",
        {
          cwd: workDir,
          timeoutSec: 180,
        },
      );

      assertFirstActionIsLocal(result);
      assertNoWebSearchOrHandleQuestion(result);
      expect(result.json.output.toLowerCase()).toContain("changelog");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "uses local git for current checkout history questions",
    async () => {
      workDir = createWorkDir();
      seedFxHistoryRepo(workDir);

      const result = await runEval(
        "look for changes/last commits in the fx",
        {
          cwd: workDir,
          timeoutSec: 180,
        },
      );

      assertNoWebSearchOrHandleQuestion(result);
      assertNoTerminalExecMatches(result, /^gh\s+/);
      assertTerminalExecMatches(result, /^git\s+(log|status|branch)\b/);
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "routes non-matching GitHub URL metadata through gh before web_search",
    async () => {
      workDir = createWorkDir();
      seedGitRepo(workDir, "https://github.com/vercel-labs/fx.git");

      const result = await runEval(
        "For https://github.com/vercel/v0, use GitHub metadata to tell me how many open pull requests it currently has. Do not answer from the URL alone.",
        {
          cwd: workDir,
          timeoutSec: 180,
        },
      );

      assertTerminalExecMatches(result, /^gh\s+/);
      assertNoWebSearchOrHandleQuestion(result);
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
