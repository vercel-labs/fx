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

/** Commits one change per subject and sets origin/main to the result, like an up-to-date clone. */
function commitHistory(dir: string, subjects: string[]): void {
  subjects.forEach((subject, index) => {
    writeFileSync(join(dir, "HISTORY.log"), subjects.slice(0, index + 1).join("\n") + "\n");
    execSync(`git add -A && git commit -q -m ${JSON.stringify(subject)}`, { cwd: dir, stdio: "pipe" });
  });
  execSync("git update-ref refs/remotes/origin/main HEAD && git branch -q --set-upstream-to=origin/main main", {
    cwd: dir,
    stdio: "pipe",
  });
}

function seedV0ChangelogRepo(dir: string): void {
  seedGitRepo(dir, "https://github.com/vercel/v0.git");
  mkdirSync(join(dir, "apps", "www"), { recursive: true });
  mkdirSync(join(dir, "scripts"), { recursive: true });
  mkdirSync(join(dir, "docs"), { recursive: true });
  writeFileSync(
    join(dir, "package.json"),
    JSON.stringify({ name: "v0", private: true, scripts: { release: "node scripts/release.mjs" } }, null, 2) + "\n",
  );
  writeFileSync(
    join(dir, "scripts", "release.mjs"),
    "// Moves the Unreleased section of CHANGELOG.md under the new version, then tags the release.\n",
  );
  writeFileSync(
    join(dir, "docs", "changelog.md"),
    "# Writing changelog entries\n\nAdd one line per user-facing change under Unreleased in CHANGELOG.md.\n",
  );
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
  commitHistory(dir, [
    "Set up the v0 web app",
    "Add the release notes page",
    "Generate the changelog during release",
    "Document how changelog entries are written",
    "Release 1.0.0",
  ]);
}

function seedFxHistoryRepo(dir: string): void {
  // A shallow clone of the real repository: its history and origin/main agree with GitHub.
  execSync("git clone -q --depth 20 --single-branch https://github.com/vercel-labs/fx.git .", { cwd: dir, stdio: "pipe" });
}

function assertNoWebSearchOrHandleQuestion(result: EvalResult): void {
  assertToolNotUsed(result, "web_search");
  assertNoAskUserQuestionMatching(result, /GitHub handle/i);
}

/** A shell command that reaches the network: gh, curl, wget, or a git command that talks to a remote. */
function isRemoteCommand(command: string): boolean {
  return /(^|[;&|(]\s*)(gh|curl|wget)\s/.test(command.trim()) || /\bgit\s+(clone|fetch|pull|ls-remote)\b/.test(command);
}

function assertFirstActionIsLocal(result: EvalResult): void {
  assertFirstToolIn(result, LOCAL_FIRST_TOOLS);
  const first = result.json.tool_calls[0];
  // Any command that stays on this machine is a local first step, such as ls or git log.
  if (first?.name === "shell") {
    expect(isRemoteCommand(first.command_result?.command ?? "")).toBe(false);
  }
}

function assertFirstRemoteActionIsGh(result: EvalResult): void {
  const remote = result.json.tool_calls.find(
    (call) => call.name === "web_fetch" || (call.name === "shell" && isRemoteCommand(call.command_result?.command ?? "")),
  );
  expect(remote?.name).toBe("shell");
  expect(/(^|[;&|(]\s*)gh\s/.test(remote?.command_result?.command?.trim() ?? "")).toBe(true);
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
        "For https://github.com/vercel/next.js, use GitHub metadata to tell me how many open pull requests it currently has. Do not answer from the URL alone.",
        {
          cwd: workDir,
          timeoutSec: 180,
        },
      );

      assertFirstRemoteActionIsGh(result);
      assertNoAskUserQuestionMatching(result, /GitHub handle/i);
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
