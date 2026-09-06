import { describe, expect, test } from "bun:test";
import {
  AGENT_QUALITY_BASELINE_MATRIX,
  COVERAGE_TYPES,
  FAILURE_CATEGORIES,
  SHARED_MODEL_CONTEXT_CONTRACT,
  commandPolicyProgressSummarySurfaced,
  firstToolMatchesExpectation,
  focusedVerificationSummarySurfaced,
  forbiddenToolsUsed,
  matrixRowById,
  releaseBumpChoiceBlockerSurfaced,
  type AgentQualityMatrixRow,
  type RecordedToolCall,
} from "./agent-quality-matrix";

const INITIAL_OR_RUNNABLE_PROMPTS = [
  "Investigate how this repo changelog works in the GitHub repo.",
  "Look for changes/last commits in fx.",
  "Find where slash commands are defined.",
  "Find every use of command policy.",
  "Investigate how command policy is wired in this repo.",
  "What does the MCP feature do in this repo?",
  "Investigate how the current GitHub repo changelog works; do not ask me for my GitHub handle.",
  "Read https://github.com/vercel-labs/fx/pull/57 comments, and if gh is missing or unauthenticated report the blocker.",
  "Remove either the logs directory or the session cache, whichever you think is safer.",
  "Prepare release notes, but first choose whether this should be a patch, minor, or major release.",
  "Read https://github.com/vercel-labs/fx/pull/57 comments.",
  "A command failed, retry it.",
  "Continue.",
  "What are you doing right now?",
  "Continue from the last useful progress update.",
  "Why did this tool fail?",
  "This is taking too long. What are you doing?",
  "Run in noninteractive mode where approval would be needed.",
  "Resume in a different workspace.",
  "Provider returned 429, recover without repeating local tool actions.",
  "The provider hit a length limit while returning tool calls.",
  "A dev server is running in the background; show me its status and logs.",
  "Large command output is needed later.",
  "Summarize https://example.com/docs from that exact URL.",
  "Research current Zig 0.16 HTTP client behavior on the web.",
  "Use a specialized MCP tool for creating a GitHub issue.",
  "I changed tests/evals/agent-quality-matrix.test.ts. Pick and run the focused verification for that change, not a broad suite.",
  "For the current changes, choose focused verification instead of generic command spam.",
] as const;

function expectNonEmpty(value: string, field: string): void {
  expect(value.trim().length, `${field} should not be empty`).toBeGreaterThan(0);
}

function expectCompleteRow(row: AgentQualityMatrixRow): void {
  expectNonEmpty(row.id, `${row.id}.id`);
  expectNonEmpty(row.userPrompt, `${row.id}.userPrompt`);
  expect(FAILURE_CATEGORIES).toContain(row.failureCategory);
  expectNonEmpty(row.expectedFirstTool.category, `${row.id}.expectedFirstTool.category`);
  expectNonEmpty(row.expectedUserVisibleBehavior, `${row.id}.expectedUserVisibleBehavior`);
  expect(COVERAGE_TYPES).toContain(row.deterministicCoverage.type);
  expectNonEmpty(row.deterministicCoverage.notes, `${row.id}.deterministicCoverage.notes`);
  expectNonEmpty(row.modelBackedEval.reason, `${row.id}.modelBackedEval.reason`);
  expectNonEmpty(row.currentBaselineResult.notes, `${row.id}.currentBaselineResult.notes`);
  expectNonEmpty(row.targetResult, `${row.id}.targetResult`);
  expect(row.coveredEntrypoints.length, `${row.id}.coveredEntrypoints`).toBeGreaterThan(0);
  for (const covered of row.coveredEntrypoints) {
    expect(covered.contextContract).toBe(SHARED_MODEL_CONTEXT_CONTRACT);
    expectNonEmpty(covered.notes, `${row.id}.${covered.entrypoint}.notes`);
  }
}

describe("agent quality baseline matrix", () => {
  test("records a complete agent-quality baseline", () => {
    expect(AGENT_QUALITY_BASELINE_MATRIX.length).toBeGreaterThanOrEqual(10);
    expect(AGENT_QUALITY_BASELINE_MATRIX.length).toBeLessThanOrEqual(28);

    const ids = new Set<string>();
    for (const row of AGENT_QUALITY_BASELINE_MATRIX) {
      expectCompleteRow(row);
      expect(ids.has(row.id), `duplicate row id ${row.id}`).toBe(false);
      ids.add(row.id);
    }
  });

  test("covers every requested failure category and runnable prompt", () => {
    const coveredCategories = new Set(
      AGENT_QUALITY_BASELINE_MATRIX.map((row) => row.failureCategory),
    );
    for (const category of FAILURE_CATEGORIES) {
      expect(coveredCategories.has(category), `missing category ${category}`).toBe(true);
    }

    const prompts = new Set(
      AGENT_QUALITY_BASELINE_MATRIX.map((row) => row.userPrompt),
    );
    for (const prompt of INITIAL_OR_RUNNABLE_PROMPTS) {
      expect(prompts.has(prompt), `missing prompt ${prompt}`).toBe(true);
    }
  });

  test("records measured baselines for model-backed rows", () => {
    const requiredEvalRows = AGENT_QUALITY_BASELINE_MATRIX.filter(
      (row) => row.modelBackedEval.required,
    );

    expect(requiredEvalRows.length).toBeGreaterThan(0);
    for (const row of requiredEvalRows) {
      expect(row.currentBaselineResult.status, `${row.id} should be measured`).not.toBe(
        "unmeasured",
      );
    }
  });

  test("separates current baseline observations from target behavior", () => {
    for (const row of AGENT_QUALITY_BASELINE_MATRIX) {
      expect(row.currentBaselineResult.notes).not.toBe(row.targetResult);
    }

    const modelBackedRows = AGENT_QUALITY_BASELINE_MATRIX.filter(
      (row) => row.modelBackedEval.required,
    );
    expect(modelBackedRows.length).toBeGreaterThan(0);
    for (const row of modelBackedRows) {
      if (row.expectedFirstTool.policy === "model-choice") {
        expect(["runtime unit test", "e2e"]).toContain(
          row.deterministicCoverage.type,
        );
      } else {
        expect(row.deterministicCoverage.type).toBe("tool-call recorder test");
      }
    }
  });

  test("evaluates expected first tool against recorded JSON tool calls", () => {
    const row = matrixRowById("git-history-local");
    expect(row).toBeDefined();

    const goodRecording: RecordedToolCall[] = [
      {
        name: "shell",
        command_result: { command: "git log --oneline -5" },
      },
    ];
    const wrongCommand: RecordedToolCall[] = [
      {
        name: "shell",
        command_result: { command: "gh pr list" },
      },
    ];

    expect(firstToolMatchesExpectation(row!, goodRecording[0])).toBe(true);
    expect(firstToolMatchesExpectation(row!, wrongCommand[0])).toBe(false);
  });

  test("evaluates forbidden tools against recorded JSON tool calls", () => {
    const row = matrixRowById("slash-command-definition-search");
    expect(row).toBeDefined();

    const localOnly: RecordedToolCall[] = [
      { name: "glob_files" },
      { name: "read_file" },
    ];
    const webSearch: RecordedToolCall[] = [
      { name: "glob_files" },
      { name: "web_search" },
      { name: "web_search" },
    ];

    expect(forbiddenToolsUsed(row!, localOnly)).toEqual([]);
    expect(forbiddenToolsUsed(row!, webSearch)).toEqual(["web_search"]);
  });

  test("covers local-search routing cases", () => {
    const slashCommand = matrixRowById("slash-command-definition-search");
    const changelog = matrixRowById("github-changelog-local-first");
    const commandPolicy = matrixRowById("command-policy-usage-search");
    const commandPolicyProgress = matrixRowById("command-policy-progress-stop-summary");
    const mcpConcept = matrixRowById("unfamiliar-feature-inspect-before-question");
    const largeOutput = matrixRowById("large-output-retained");

    expect(slashCommand?.expectedFirstTool.tools).toEqual([
      "glob_files",
      "grep_files",
      "read_file",
    ]);
    expect(slashCommand?.targetResult).toContain(
      "src/core/slash_commands/command_specs.zig",
    );
    expect(firstToolMatchesExpectation(changelog!, { name: "task" })).toBe(false);

    expect(commandPolicy?.expectedFirstTool.tools).toContain("grep_files");
    expect(commandPolicy?.targetResult).toContain("local search tools only");
    expect(forbiddenToolsUsed(commandPolicy!, [{ name: "grep_files" }])).toEqual([]);

    expect(commandPolicyProgress?.failureCategory).toBe("approval loop");
    expect(commandPolicyProgress?.userPrompt).toBe(
      "Investigate how command policy is wired in this repo.",
    );
    expect(commandPolicyProgress?.expectedUserVisibleBehavior).toContain(
      "stops when repeated or equivalent searches produce no new evidence",
    );
    expect(commandPolicyProgress?.targetResult).toContain("exits 0");
    expect(firstToolMatchesExpectation(commandPolicyProgress!, { name: "read_file" })).toBe(true);
    expect(firstToolMatchesExpectation(commandPolicyProgress!, {
      name: "shell",
      command_result: { command: "grep command_policy -R src" },
    })).toBe(false);
    expect(forbiddenToolsUsed(commandPolicyProgress!, [{ name: "web_search" }])).toEqual([
      "web_search",
    ]);

    expect(mcpConcept?.expectedFirstTool.tools).toContain("glob_files");
    expect(mcpConcept?.targetResult).toContain("local inspection");

    expect(largeOutput?.failureCategory).toBe("large output");
    expect(largeOutput?.targetResult).toContain("handle or limitation");
  });

  test("keeps session and status tool selection model-owned", () => {
    const continueRow = matrixRowById("continue-resume-intent");
    const statusRow = matrixRowById("status-question-current-context");
    const continueProgressRow = matrixRowById("continue-after-progress-update");
    const frustrationRow = matrixRowById("frustrated-user-progress-check");
    expect(continueRow).toBeDefined();
    expect(statusRow).toBeDefined();
    expect(continueProgressRow).toBeDefined();
    expect(frustrationRow).toBeDefined();

    for (const row of [continueRow!, statusRow!, continueProgressRow!, frustrationRow!]) {
      expect(row.expectedFirstTool.policy).toBe("model-choice");
      expect(firstToolMatchesExpectation(row, undefined)).toBe(true);
      expect(firstToolMatchesExpectation(row, { name: "read_file" })).toBe(true);
      expect(forbiddenToolsUsed(row, [{ name: "read_file" }])).toEqual([]);
    }
    expect(statusRow?.expectedUserVisibleBehavior).toContain("current objective");
    expect(continueRow?.deterministicCoverage.status).toBe("implemented");
    expect(continueRow?.deterministicCoverage.notes).toContain("normal tool schemas");
    expect(continueProgressRow?.deterministicCoverage.status).toBe("implemented");
    expect(continueProgressRow?.deterministicCoverage.notes).toContain("normal tools");
    expect(continueProgressRow?.targetResult).toContain("latest meaningful update");
    expect(frustrationRow?.failureCategory).toBe("frustration");
    expect(frustrationRow?.targetResult.toLowerCase()).toContain("short status update");
  });

  test("covers ask-user and blocker cases", () => {
    const handleRow = matrixRowById("github-handle-not-needed");
    const ghBlockerRow = matrixRowById("github-pr-comments-gh-auth-blocker");
    const destructiveRow = matrixRowById("ambiguous-destructive-action-asks-choice");
    const releaseBumpRow = matrixRowById("genuinely-blocked-release-bump");

    expect(handleRow?.forbiddenTools).toContain("ask_user_question");
    expect(handleRow?.targetResult).toContain("never asks for the user's GitHub handle");
    expect(
      forbiddenToolsUsed(handleRow!, [{ name: "ask_user_question" }]),
    ).toEqual(["ask_user_question"]);

    expect(firstToolMatchesExpectation(ghBlockerRow!, {
      name: "shell",
      command_result: { command: "gh pr view 57 --repo vercel-labs/fx --comments" },
    })).toBe(true);
    expect(firstToolMatchesExpectation(ghBlockerRow!, {
      name: "shell",
      command_result: { command: "git status --short" },
    })).toBe(false);
    expect(ghBlockerRow?.targetResult).toContain("reports missing gh, auth, or permission failures directly");
    expect(ghBlockerRow?.forbiddenTools).toContain("ask_user_question");

    expect(firstToolMatchesExpectation(destructiveRow!, { name: "ask_user_question" })).toBe(true);
    expect(firstToolMatchesExpectation(destructiveRow!, {
      name: "shell",
      command_result: { command: "rm -rf logs" },
    })).toBe(false);
    expect(forbiddenToolsUsed(destructiveRow!, [{
      name: "shell",
      command_result: { command: "rm -rf logs" },
    }])).toEqual([
      "shell",
    ]);
    expect(destructiveRow?.targetResult).toContain("precise multiple-choice question");

    expect(firstToolMatchesExpectation(releaseBumpRow!, { name: "read_file" })).toBe(true);
    expect(firstToolMatchesExpectation(releaseBumpRow!, {
      name: "shell",
      command_result: { command: "git log --oneline -5" },
    })).toBe(true);
    expect(firstToolMatchesExpectation(releaseBumpRow!, {
      name: "shell",
      command_result: { command: "gh release list" },
    })).toBe(false);
    expect(firstToolMatchesExpectation(releaseBumpRow!, { name: "ask_user_question" })).toBe(false);
    expect(forbiddenToolsUsed(releaseBumpRow!, [
      { name: "read_file" },
      { name: "ask_user_question" },
    ])).toEqual([]);
    expect(releaseBumpRow?.expectedUserVisibleBehavior).toContain("surfaces a concrete blocker");
    expect(releaseBumpRow?.targetResult).toContain("patch, minor, or major choice");

    const headlessFailure = {
      output:
        "Blocker: I inspected the local release context, but the release bump is user-owned. Choose patch, minor, or major.",
      tool_calls: [] as RecordedToolCall[],
    };
    expect(headlessFailure.tool_calls).toEqual([]);
    expect(releaseBumpChoiceBlockerSurfaced(headlessFailure.output)).toBe(true);
    expect(releaseBumpChoiceBlockerSurfaced(
      "fx ask: repeated identical tool call requires approval",
    )).toBe(false);
  });

  test("rejects command-policy progress that ends in repeated-tool approval text", () => {
    const usefulSummary =
      "Known: command_policy is wired through terminal semantic exit annotations, and append_terminal_risk_note is defined but not called. Uncertain: whether that helper is leftover or missing a permission-path call. Next useful step: decide whether to wire or delete the orphan helper.";

    expect(commandPolicyProgressSummarySurfaced(usefulSummary)).toBe(true);
    expect(commandPolicyProgressSummarySurfaced(
      "fx ask: repeated identical tool call requires approval\nreason=tool-call-cycle",
    )).toBe(false);
  });

  test("covers focused verification routing cases", () => {
    const matrixTest = matrixRowById("focused-verification-agent-quality-matrix-test");
    const currentChanges = matrixRowById("focused-verification-current-changes");

    expect(matrixTest?.modelBackedEval.required).toBe(true);
    expect(matrixTest?.deterministicCoverage.notes).toContain("does not require AI_GATEWAY_API_KEY");
    expect(firstToolMatchesExpectation(matrixTest!, {
      name: "shell",
      command_result: { command: "bun test tests/evals/agent-quality-matrix.test.ts" },
    })).toBe(true);
    expect(firstToolMatchesExpectation(matrixTest!, {
      name: "shell",
      command_result: { command: "bun test tests/evals" },
    })).toBe(false);
    expect(matrixTest?.forbiddenTools).toContain("ask_user_question");

    expect(firstToolMatchesExpectation(currentChanges!, {
      name: "shell",
      command_result: { command: "git status --short" },
    })).toBe(true);
    expect(firstToolMatchesExpectation(currentChanges!, {
      name: "shell",
      command_result: { command: "git diff" },
    })).toBe(false);
    expect(focusedVerificationSummarySurfaced(
      "Ran `bun test tests/evals/agent-quality-matrix.test.ts` (exit 0, pass). Remaining unverified: full Zig suite.",
    )).toBe(true);
    expect(focusedVerificationSummarySurfaced(
      "fx ask: repeated identical tool call requires approval\nreason=tool-call-cycle",
    )).toBe(false);
    expect(focusedVerificationSummarySurfaced(
      "Agent stopped: detected repeating tool call cycle.",
    )).toBe(false);
  });

  test("covers native web fetch and web_search routing", () => {
    const knownUrl = matrixRowById("known-public-url-web-fetch");
    const broadWeb = matrixRowById("broad-web-research-web-search");
    const localRepo = matrixRowById("slash-command-definition-search");
    const githubMetadata = matrixRowById("github-pr-comments-gh");

    expect(knownUrl?.expectedFirstTool.tools).toEqual(["web_fetch"]);
    expect(firstToolMatchesExpectation(knownUrl!, { name: "web_fetch" })).toBe(true);
    expect(firstToolMatchesExpectation(knownUrl!, { name: "web_search" })).toBe(false);
    expect(forbiddenToolsUsed(knownUrl!, [
      { name: "web_fetch" },
      { name: "web_search" },
      { name: "browser_navigate" },
    ])).toEqual(["web_search", "browser_navigate"]);
    expect(knownUrl?.expectedUserVisibleBehavior).toContain("untrusted content");

    expect(broadWeb?.expectedFirstTool.tools).toEqual(["web_search"]);
    expect(firstToolMatchesExpectation(broadWeb!, { name: "web_search" })).toBe(true);
    expect(firstToolMatchesExpectation(broadWeb!, { name: "web_fetch" })).toBe(false);
    expect(forbiddenToolsUsed(broadWeb!, [
      { name: "web_fetch" },
      { name: "grep_files" },
      { name: "web_search" },
    ])).toEqual(["web_fetch", "grep_files"]);

    expect(localRepo?.forbiddenTools).toContain("web_search");
    expect(broadWeb?.expectedUserVisibleBehavior).toContain("linked sources");
    expect(firstToolMatchesExpectation(githubMetadata!, {
      name: "shell",
      command_result: { command: "gh pr view 57 --repo vercel-labs/fx --comments" },
    })).toBe(true);
    expect(firstToolMatchesExpectation(githubMetadata!, { name: "web_fetch" })).toBe(false);
  });

  test("covers deferred MCP tool discovery", () => {
    const row = matrixRowById("mcp-deferred-tool-discovery");

    expect(row?.expectedFirstTool.tools).toEqual(["capability_search"]);
    expect(firstToolMatchesExpectation(row!, { name: "capability_search" })).toBe(true);
    expect(firstToolMatchesExpectation(row!, { name: "mcp_select_tool" })).toBe(false);
    expect(forbiddenToolsUsed(row!, [
      { name: "capability_search" },
      { name: "web_search" },
      { name: "ask_user_question" },
    ])).toEqual(["web_search", "ask_user_question"]);
    expect(row?.targetResult).toContain("exact-selects");
  });
});
