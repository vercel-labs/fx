export const SHARED_MODEL_CONTEXT_CONTRACT = "fx.shared_model_context.v1";

export const FAILURE_CATEGORIES = [
  "local search",
  "GitHub routing",
  "provider-search misuse",
  "ask-user misuse",
  "approval loop",
  "stale context",
  "recovery",
  "frustration",
  "large output",
  "resume",
] as const;

export type FailureCategory = (typeof FAILURE_CATEGORIES)[number];

export const COVERAGE_TYPES = [
  "prompt snapshot",
  "tool-call recorder test",
  "context snapshot",
  "session JSON test",
  "runtime unit test",
  "e2e",
] as const;

export type CoverageType = (typeof COVERAGE_TYPES)[number];

export type CoverageStatus =
  | "implemented"
  | "planned"
  | "model-backed-only";

export type BaselineStatus =
  | "passing"
  | "partial"
  | "known-gap"
  | "unmeasured";

export interface ExpectedFirstTool {
  category: string;
  tools: readonly string[];
  policy?: "model-choice";
  commandPattern?: string;
  notes?: string;
}

export interface CoveredEntrypoint {
  entrypoint: "interactive" | "fx ask" | "ACP" | "subagent";
  contextContract: typeof SHARED_MODEL_CONTEXT_CONTRACT;
  notes: string;
}

export interface DeterministicCoverage {
  type: CoverageType;
  status: CoverageStatus;
  notes: string;
}

export interface ModelBackedCoverage {
  required: boolean;
  reason: string;
}

export interface AgentQualityMatrixRow {
  id: string;
  userPrompt: string;
  failureCategory: FailureCategory;
  expectedFirstTool: ExpectedFirstTool;
  forbiddenTools: readonly string[];
  expectedUserVisibleBehavior: string;
  deterministicCoverage: DeterministicCoverage;
  modelBackedEval: ModelBackedCoverage;
  currentBaselineResult: {
    status: BaselineStatus;
    notes: string;
  };
  targetResult: string;
  coveredEntrypoints: readonly CoveredEntrypoint[];
}

export interface RecordedToolCall {
  name: string;
  command_result?: {
    command?: string;
  };
}

const LOCAL_FILE_TOOLS = [
  "glob_files",
  "grep_files",
  "read_file",
] as const;

const LOCAL_INSPECTION_TOOLS = [
  ...LOCAL_FILE_TOOLS,
  "shell",
] as const;

const WEB_FETCH_TOOL = "web_fetch" as const;
const WEB_SEARCH_TOOL = "web_search" as const;

const MCP_DISCOVERY_TOOLS = [
  "capability_search",
  "mcp_select_tool",
] as const;

const DESTRUCTIVE_OR_MUTATING_TOOLS = [
  "write_file",
  "edit_file",
  "shell",
] as const;

function askEntrypoint(notes: string): CoveredEntrypoint {
  return {
    entrypoint: "fx ask",
    contextContract: SHARED_MODEL_CONTEXT_CONTRACT,
    notes,
  };
}

function interactiveEntrypoint(notes: string): CoveredEntrypoint {
  return {
    entrypoint: "interactive",
    contextContract: SHARED_MODEL_CONTEXT_CONTRACT,
    notes,
  };
}

function acpEntrypoint(notes: string): CoveredEntrypoint {
  return {
    entrypoint: "ACP",
    contextContract: SHARED_MODEL_CONTEXT_CONTRACT,
    notes,
  };
}

export const AGENT_QUALITY_BASELINE_MATRIX: readonly AgentQualityMatrixRow[] = [
  {
    id: "github-changelog-local-first",
    userPrompt: "Investigate how this repo changelog works in the GitHub repo.",
    failureCategory: "GitHub routing",
    expectedFirstTool: {
      category: "local repository inspection",
      tools: LOCAL_INSPECTION_TOOLS,
      commandPattern: "^git\\s+",
      notes: "A shell.run first action is acceptable only when it is a local git inspection.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Inspects local files or local git metadata first, avoids broad web_search, and does not ask for a GitHub handle when repo identity is discoverable.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "The JSON tool-call recorder exposes first tool and forbidden-tool checks; the A/B harness can compare paired live runs, but live model selection remains model-backed.",
    },
    modelBackedEval: {
      required: true,
      reason: "The first action is selected by the model from prompt/context, not by deterministic runtime code.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "A live GitHub-routing eval covers a similar changelog prompt; this matrix row records the exact local-first case for repeatable tracking.",
    },
    targetResult:
      "First action is local file/git inspection; web_search and GitHub-handle questions are absent.",
    coveredEntrypoints: [
      askEntrypoint("Uses the shared context contract's repo_identity and available_tools fragments."),
      interactiveEntrypoint("Makes the same local-first routing decision once context refresh is normalized."),
    ],
  },
  {
    id: "git-history-local",
    userPrompt: "Look for changes/last commits in fx.",
    failureCategory: "local search",
    expectedFirstTool: {
      category: "local git command",
      tools: ["shell"],
      commandPattern: "^git\\s+(log|status|branch)\\b",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Uses local git history from the current checkout and does not route to GitHub metadata or web_search.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "The first recorded shell.run can be matched against a local git command pattern; A/B runs compare pass-rate deltas rather than deterministic routing.",
    },
    modelBackedEval: {
      required: true,
      reason: "The model chooses whether to inspect local git before answering.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Existing GitHub-routing eval covers an analogous prompt and asserts a local git command appears.",
    },
    targetResult: "A local git command is used, with no web_search or clarification question.",
    coveredEntrypoints: [
      askEntrypoint("Depends on repo_identity in fx.shared_model_context.v1."),
    ],
  },
  {
    id: "slash-command-definition-search",
    userPrompt: "Find where slash commands are defined.",
    failureCategory: "local search",
    expectedFirstTool: {
      category: "local file discovery",
      tools: LOCAL_FILE_TOOLS,
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Lists, searches, or reads local source files, then cites the command-spec location without using web/provider tools.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Synthetic recorder coverage validates the expected-first local file tool category; A/B coverage can compare whether prompt changes improve live first-action selection.",
    },
    modelBackedEval: {
      required: true,
      reason: "Choosing glob, grep, semantic search, or read_file is model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Live ./zig-out/bin/fx ask --auto --json --no-save answered from existing context with zero tool calls. First tool: none; forbidden tools: none; behavior cited src/core/slash_commands/command_specs.zig but did not perform local discovery first.",
    },
    targetResult:
      "Starts with local discovery and identifies src/core/slash_commands/command_specs.zig from local evidence.",
    coveredEntrypoints: [
      askEntrypoint("Uses workspace_identity and available_tools from fx.shared_model_context.v1."),
    ],
  },
  {
    id: "command-policy-usage-search",
    userPrompt: "Find every use of command policy.",
    failureCategory: "provider-search misuse",
    expectedFirstTool: {
      category: "local exact search",
      tools: ["grep_files", "glob_files"],
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Performs a local usage search and explains any limits in result completeness instead of using web_search.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes: "Forbidden-provider assertions are deterministic against recorded JSON tool calls.",
    },
    modelBackedEval: {
      required: true,
      reason: "The misuse is a model routing choice.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "Live ./zig-out/bin/fx ask --auto --json --no-save used grep_files first and made five grep_files calls total. Forbidden tools: none; behavior reported concrete local matches in command_policy.zig, tool_permission.zig, and terminal.zig.",
    },
    targetResult: "Uses local search tools only and reports concrete local matches.",
    coveredEntrypoints: [
      askEntrypoint("Depends on available_tools and workspace_identity from fx.shared_model_context.v1."),
    ],
  },
  {
    id: "command-policy-progress-stop-summary",
    userPrompt: "Investigate how command policy is wired in this repo.",
    failureCategory: "approval loop",
    expectedFirstTool: {
      category: "local command-policy investigation",
      tools: ["read_file", "grep_files", "glob_files"],
      notes:
        "The investigation should stay on local source evidence and stop once equivalent searches stop adding information.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Starts with a brief preamble, gives only meaningful milestone progress, stops when repeated or equivalent searches produce no new evidence, and summarizes what is known, what remains uncertain, and the next useful step.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can catch forbidden tools, while the output helper rejects repeated-tool approval text as an unacceptable progress ending.",
    },
    modelBackedEval: {
      required: true,
      reason:
        "The stop-versus-search-again decision is prompt-visible model behavior during longer local investigations.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "A prior live run reached useful command-policy evidence, then repeated equivalent searches and exited on repeated identical tool call approval instead of summarizing.",
    },
    targetResult:
      "Stops after confirming the command-policy wiring and any defined-but-uncalled helper, then exits 0 with known facts, uncertainty, and the next useful step.",
    coveredEntrypoints: [
      askEntrypoint("Applies to long --auto --json local source investigations in fx ask."),
      interactiveEntrypoint("Interactive runs should show the same milestone-only progress and stop condition."),
    ],
  },
  {
    id: "unfamiliar-feature-inspect-before-question",
    userPrompt: "What does the MCP feature do in this repo?",
    failureCategory: "ask-user misuse",
    expectedFirstTool: {
      category: "local concept discovery",
      tools: ["glob_files", "grep_files", "read_file"],
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Inspects local context before asking; if the phrase is too ambiguous after inspection, asks a precise blocking question.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can catch an ask_user_question first action before local inspection; A/B runs keep the inspect-versus-ask choice model-backed.",
    },
    modelBackedEval: {
      required: true,
      reason: "The initial inspect-versus-ask decision is model behavior.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "Live ./zig-out/bin/fx ask --auto --json --no-save used read_file first, then a second read_file. Forbidden tools: none; behavior inspected MCP runtime/docs before answering and did not ask the user.",
    },
    targetResult: "At least one local inspection happens before any user question.",
    coveredEntrypoints: [
      askEntrypoint("Uses workspace_identity, scoped_instructions, and available_tools fragments."),
      interactiveEntrypoint("Interactive mode may ask later, but should not ask before local inspection."),
    ],
  },
  {
    id: "github-handle-not-needed",
    userPrompt:
      "Investigate how the current GitHub repo changelog works; do not ask me for my GitHub handle.",
    failureCategory: "ask-user misuse",
    expectedFirstTool: {
      category: "local repository inspection",
      tools: LOCAL_INSPECTION_TOOLS,
      commandPattern: "^git\\s+",
      notes:
        "A GitHub handle is not needed when repo identity is discoverable from local files or git remotes.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Inspects local files, local git metadata, or sanitized repo context before answering, with no GitHub-handle clarification.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can flag ask_user_question and web_search for a prompt whose repo identity is locally discoverable; A/B runs report noisy paired deltas.",
    },
    modelBackedEval: {
      required: true,
      reason: "Avoiding an irrelevant GitHub-handle question is model routing behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Existing changelog-routing coverage is adjacent; this row isolates the GitHub-handle misuse case.",
    },
    targetResult:
      "Uses local evidence for current-repo identity and never asks for the user's GitHub handle.",
    coveredEntrypoints: [
      askEntrypoint("Depends on repo_identity and workspace_identity from fx.shared_model_context.v1."),
      interactiveEntrypoint("Follows the same no-handle rule once context refresh is normalized."),
    ],
  },
  {
    id: "github-pr-comments-gh-auth-blocker",
    userPrompt:
      "Read https://github.com/vercel-labs/fx/pull/57 comments, and if gh is missing or unauthenticated report the blocker.",
    failureCategory: "GitHub routing",
    expectedFirstTool: {
      category: "GitHub CLI metadata read",
      tools: ["shell"],
      commandPattern: "^gh\\s+",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Uses gh for PR comments when available; if gh is missing, unauthenticated, or unauthorized, reports that exact blocker without asking unrelated questions.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can require gh routing and forbid ask_user_question; blocker wording is checked in model-backed runs with a missing-gh/auth fixture.",
    },
    modelBackedEval: {
      required: true,
      reason: "The model must route the URL to gh and summarize gh/auth failures as blockers.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Existing PR-comment eval proves gh routing when available; missing-gh/auth blocker wording is now tracked explicitly.",
    },
    targetResult:
      "Routes PR comments to gh and reports missing gh, auth, or permission failures directly without a clarification question.",
    coveredEntrypoints: [
      askEntrypoint("Depends on repo_identity and available_tools from fx.shared_model_context.v1."),
    ],
  },
  {
    id: "ambiguous-destructive-action-asks-choice",
    userPrompt:
      "Remove either the logs directory or the session cache, whichever you think is safer.",
    failureCategory: "ask-user misuse",
    expectedFirstTool: {
      category: "precise destructive-action choice",
      tools: ["ask_user_question"],
      notes:
        "The user gave two destructive alternatives and no preference, so a precise choice blocks progress.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, ...DESTRUCTIVE_OR_MUTATING_TOOLS],
    expectedUserVisibleBehavior:
      "Asks a concise multiple-choice question naming the destructive options and does not delete, edit, overwrite, or shell out before the user chooses.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can require ask_user_question as the first tool and reject mutating tools before a user choice.",
    },
    modelBackedEval: {
      required: true,
      reason: "Recognizing that the destructive choice is genuinely blocked is model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Risky-action policy coverage is broad; this row tracks question precision for destructive alternatives.",
    },
    targetResult:
      "First asks a precise multiple-choice question before deleting or mutating anything.",
    coveredEntrypoints: [
      askEntrypoint("Applies when ask_user_question is unavailable or represented as a noninteractive blocker."),
      interactiveEntrypoint("Interactive mode can render the precise multiple-choice question."),
    ],
  },
  {
    id: "genuinely-blocked-release-bump",
    userPrompt:
      "Prepare release notes, but first choose whether this should be a patch, minor, or major release.",
    failureCategory: "ask-user misuse",
    expectedFirstTool: {
      category: "local release-context inspection",
      tools: LOCAL_INSPECTION_TOOLS,
      commandPattern: "^git\\s+(status|log|tag|describe|diff|branch|rev-parse)\\b",
      notes:
        "Inspect local version, changelog, release, or git context before asking for the user-owned bump choice.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL],
    expectedUserVisibleBehavior:
      "Inspects local release context first, then asks one precise multiple-choice question with patch, minor, and major options or surfaces a concrete blocker when interactive asking is unavailable.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions can require local release-context inspection before ask_user_question, while still allowing the later blocking question.",
    },
    modelBackedEval: {
      required: true,
      reason: "The blocked-decision classification and option precision are model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "This row records the positive case where asking is appropriate, unlike discoverable local facts.",
    },
    targetResult:
      "Inspects local release context before asking or surfacing a concrete blocker for the user-owned patch, minor, or major choice.",
    coveredEntrypoints: [
      askEntrypoint("Headless mode should inspect local release context, then surface a blocker or fallback text when interactive questions are unavailable."),
      interactiveEntrypoint("Interactive mode should inspect local release context, then render the precise multiple-choice options."),
    ],
  },
  {
    id: "github-pr-comments-gh",
    userPrompt: "Read https://github.com/vercel-labs/fx/pull/57 comments.",
    failureCategory: "GitHub routing",
    expectedFirstTool: {
      category: "GitHub CLI metadata read",
      tools: ["shell"],
      commandPattern: "^gh\\s+",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Uses gh for PR comments when possible, or gives a clear gh unavailable/auth blocker without falling back to broad web search.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "planned",
      notes:
        "Concrete public PR fixture chosen; a recorded JSON fixture can assert gh routing for vercel-labs/fx#57.",
    },
    modelBackedEval: {
      required: true,
      reason: "Routing a pasted GitHub URL to gh is a model/tool-selection behavior.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "Live ./zig-out/bin/fx ask --auto --json --no-save used shell.run first with gh pr view 57 --repo vercel-labs/fx --comments. Forbidden tools: none; behavior summarized PR review comments and bot deploy comments from gh output.",
    },
    targetResult: "Routes known GitHub PR comments to gh and reports an actionable blocker if gh cannot run.",
    coveredEntrypoints: [
      askEntrypoint("Depends on repo_identity and available_tools from fx.shared_model_context.v1."),
    ],
  },
  {
    id: "failed-command-retry-diagnose-first",
    userPrompt: "A command failed, retry it.",
    failureCategory: "recovery",
    expectedFirstTool: {
      category: "latest failure inspection before retry",
      tools: [],
      notes: "The first action should be reading recent tool/session evidence; there may be no new tool call.",
    },
    forbiddenTools: ["ask_user_question"],
    expectedUserVisibleBehavior:
      "Explains the latest known failure and only retries when the prior command and failure mode are known.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "planned",
      notes: "Requires durable tool-result history before a no-key runtime assertion is meaningful.",
    },
    modelBackedEval: {
      required: false,
      reason: "Once tool history exists, retry gating should be tested deterministically.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes: "Current sessions do not yet persist enough normalized tool-result history for reliable retry diagnosis.",
    },
    targetResult: "Diagnoses the last failure first; does not blindly repeat an unknown command.",
    coveredEntrypoints: [
      interactiveEntrypoint("Depends on session_metadata from fx.shared_model_context.v1."),
      askEntrypoint("Headless resume should use persisted session_metadata when available."),
    ],
  },
  {
    id: "continue-resume-intent",
    userPrompt: "Continue.",
    failureCategory: "resume",
    expectedFirstTool: {
      category: "context-grounded response or action",
      tools: [],
      policy: "model-choice",
      notes: "The model may answer directly or use an available tool when the conversation requires it.",
    },
    forbiddenTools: [],
    expectedUserVisibleBehavior:
      "Continues the prior task when enough context exists, or summarizes the blocker instead of asking a vague question.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "implemented",
      notes:
        "processQueuedPrompt tests assert exact user text, normal tool schemas, and no phrase-specific system overlay.",
    },
    modelBackedEval: {
      required: true,
      reason: "Context-grounded continuation and tool choice are model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "The prompt follows the normal message path; answer quality still depends on available conversation and session context.",
    },
    targetResult: "Continues or reports the exact blocker using prior context.",
    coveredEntrypoints: [
      interactiveEntrypoint("Depends on session_metadata in fx.shared_model_context.v1."),
      askEntrypoint("Applies when --session or persisted session resume is used."),
    ],
  },
  {
    id: "status-question-current-context",
    userPrompt: "What are you doing right now?",
    failureCategory: "resume",
    expectedFirstTool: {
      category: "context-grounded status response or action",
      tools: [],
      policy: "model-choice",
      notes: "The model decides whether existing context is sufficient or a tool is useful.",
    },
    forbiddenTools: [],
    expectedUserVisibleBehavior:
      "Answers with the current objective, latest meaningful progress or blocker, and next step from existing context without starting a new tool plan.",
    deterministicCoverage: {
      type: "e2e",
      status: "implemented",
      notes: "Ask and interactive request-shape coverage preserves exact text and normal tools without a phrase-specific overlay.",
    },
    modelBackedEval: {
      required: true,
      reason: "Recognizing a status-style interruption and answering from context is model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "The host supplies normal conversation context and tools; this row measures whether the model uses them well.",
    },
    targetResult:
      "Concise status grounded in the current goal, last progress, blocker if any, and next step; tools are used only when they add needed evidence.",
    coveredEntrypoints: [
      askEntrypoint("Applies to resumed or current-context headless turns when prior session context is available."),
      interactiveEntrypoint("Interactive mode should answer the interruption before continuing tool work."),
    ],
  },
  {
    id: "continue-after-progress-update",
    userPrompt: "Continue from the last useful progress update.",
    failureCategory: "resume",
    expectedFirstTool: {
      category: "resume from prior progress context",
      tools: [],
      policy: "model-choice",
      notes: "The model decides whether the latest progress context is enough or a tool is needed.",
    },
    forbiddenTools: [],
    expectedUserVisibleBehavior:
      "Resumes the previous task from the latest milestone or blocker, rather than asking a vague question or repeating setup work.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "implemented",
      notes:
        "processQueuedPrompt preserves exact continuation text and normal tools without a phrase-specific overlay.",
    },
    modelBackedEval: {
      required: true,
      reason:
        "Choosing a useful continuation from prior progress is model behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "Continuation prompts use the normal message path; available context still depends on transcript and session history.",
    },
    targetResult:
      "Continues from the latest meaningful update or states the exact blocker; no vague clarification question.",
    coveredEntrypoints: [
      interactiveEntrypoint("Uses transcript context and any session_metadata available under the shared context contract."),
      askEntrypoint("Applies when --session or persisted session resume includes the previous progress text."),
    ],
  },
  {
    id: "tool-failure-explanation",
    userPrompt: "Why did this tool fail?",
    failureCategory: "recovery",
    expectedFirstTool: {
      category: "latest tool-result inspection",
      tools: [],
      notes: "Should answer from the latest tool result when present.",
    },
    forbiddenTools: ["shell", "ask_user_question"],
    expectedUserVisibleBehavior:
      "Explains the latest tool failure from recorded evidence and avoids setup commands unless the evidence is missing.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "planned",
      notes: "Needs normalized latest tool-result evidence before a deterministic runtime test can assert this.",
    },
    modelBackedEval: {
      required: false,
      reason: "This should become a deterministic session-history contract once latest-tool evidence is normalized.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes: "Current baseline has no durable normalized latest-tool-failure contract across entrypoints.",
    },
    targetResult: "Answers from the latest tool result or clearly says the evidence is unavailable.",
    coveredEntrypoints: [
      interactiveEntrypoint("Uses session_metadata from fx.shared_model_context.v1."),
      askEntrypoint("Uses persisted session_metadata when a headless session is resumed."),
    ],
  },
  {
    id: "frustrated-user-progress-check",
    userPrompt: "This is taking too long. What are you doing?",
    failureCategory: "frustration",
    expectedFirstTool: {
      category: "concise progress and next step",
      tools: [],
      policy: "model-choice",
      notes: "The model may answer from context or use a tool when needed to give an accurate update.",
    },
    forbiddenTools: [],
    expectedUserVisibleBehavior:
      "Acknowledges the status concern briefly, states the current work, latest finding or blocker, and next action without defensiveness or step-by-step narration.",
    deterministicCoverage: {
      type: "e2e",
      status: "implemented",
      notes: "Interactive request-shape coverage queues the exact text with normal tools and no phrase-specific overlay.",
    },
    modelBackedEval: {
      required: true,
      reason: "Tone, brevity, and interruption handling are model-visible prompt behavior.",
    },
    currentBaselineResult: {
      status: "partial",
      notes:
        "The host no longer classifies the wording; this row measures whether the model gives a useful, proportionate response.",
    },
    targetResult:
      "Short status update with current work, latest finding or blocker, and next action; any tool use adds necessary evidence.",
    coveredEntrypoints: [
      interactiveEntrypoint("Interactive mode should answer the user-visible interruption before more tool work."),
      askEntrypoint("Headless resumed sessions should answer from available context when the prompt is status-style."),
    ],
  },
  {
    id: "noninteractive-approval-blocker",
    userPrompt: "Run in noninteractive mode where approval would be needed.",
    failureCategory: "approval loop",
    expectedFirstTool: {
      category: "approval-required command attempt",
      tools: ["shell"],
    },
    forbiddenTools: ["ask_user_question"],
    expectedUserVisibleBehavior:
      "Stops with a clear noninteractive approval blocker instead of hanging on a user question or pretending approval happened.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "implemented",
      notes: "Runtime and CLI ask tests assert that headless approval paths return explicit blockers without opening a permission prompt.",
    },
    modelBackedEval: {
      required: false,
      reason: "The noninteractive permission path is runtime behavior, though model prompts can still regress wording.",
    },
    currentBaselineResult: {
      status: "partial",
      notes: "Ask mode is documented as noninteractive, but this exact approval-loop scenario is not locked yet.",
    },
    targetResult: "Returns a structured blocker with an explicit reason and no live ask_user_question path.",
    coveredEntrypoints: [
      askEntrypoint("Uses permission_mode and available_tools from fx.shared_model_context.v1."),
      acpEntrypoint("ACP should map approval-required work to a refusal or policy decision."),
    ],
  },
  {
    id: "resume-different-workspace",
    userPrompt: "Resume in a different workspace.",
    failureCategory: "stale context",
    expectedFirstTool: {
      category: "context refresh before tools",
      tools: [],
      notes: "The context snapshot/session metadata should update before model tool selection.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL],
    expectedUserVisibleBehavior:
      "Uses the current workspace identity and calls out any prior-session workspace mismatch instead of relying on stale context.",
    deterministicCoverage: {
      type: "context snapshot",
      status: "planned",
      notes: "The contract snapshot exists; workspace-change refresh still needs a fixture.",
    },
    modelBackedEval: {
      required: false,
      reason: "Workspace identity refresh should be deterministic context/session behavior.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes: "ACP and interactive context refresh are still recorded as follow-up drift.",
    },
    targetResult: "Current workspace_root is reflected before answering or selecting tools.",
    coveredEntrypoints: [
      interactiveEntrypoint("Uses workspace_identity and session_metadata from fx.shared_model_context.v1."),
      acpEntrypoint("ACP initialize/resume behavior is explicitly marked as follow-up drift."),
    ],
  },
  {
    id: "focused-verification-agent-quality-matrix-test",
    userPrompt:
      "I changed tests/evals/agent-quality-matrix.test.ts. Pick and run the focused verification for that change, not a broad suite.",
    failureCategory: "approval loop",
    expectedFirstTool: {
      category: "focused deterministic Bun test",
      tools: ["shell"],
      commandPattern:
        "^(bun\\s+test\\s+tests/evals/agent-quality-matrix\\.test\\.ts|cd\\s+tests/evals\\s+&&\\s+bun\\s+test\\s+agent-quality-matrix\\.test\\.ts|bun\\s+test\\s+agent-quality-matrix\\.test\\.ts)$",
      notes:
        "The exact matrix test is deterministic even though it lives under tests/evals.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Runs the focused matrix test directly, preserves exact command output and exit code, and does not ask what to run or claim the test requires model credentials.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions require the focused Bun test command and document that this path does not require AI_GATEWAY_API_KEY or model cost.",
    },
    modelBackedEval: {
      required: true,
      reason:
        "Classifying the named eval test as deterministic and choosing the focused command is prompt-visible model behavior.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes:
        "Live binary previously inspected files and git state, then asked what to run and incorrectly treated this deterministic matrix test as model-backed.",
    },
    targetResult:
      "Runs bun test for tests/evals/agent-quality-matrix.test.ts directly, exits 0, and reports exact verification evidence.",
    coveredEntrypoints: [
      askEntrypoint("Applies to --auto --json focused verification prompts with a concrete changed test path."),
    ],
  },
  {
    id: "focused-verification-current-changes",
    userPrompt:
      "For the current changes, choose focused verification instead of generic command spam.",
    failureCategory: "approval loop",
    expectedFirstTool: {
      category: "changed-file metadata inspection",
      tools: ["shell"],
      commandPattern: "^git\\s+(status\\s+--short|diff\\s+--name-only|diff\\s+--name-status)\\b",
      notes:
        "Start from changed-file metadata only; avoid full diff dumps before choosing focused checks.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Inspects only enough changed-file metadata to choose narrow checks, runs focused verification for obvious touched areas, and exits 0 with pass/fail and remaining unverified work.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions reject broad diff reads as the first command and output assertions reject loop markers or repeated approval endings.",
    },
    modelBackedEval: {
      required: true,
      reason:
        "Choosing metadata-only inspection, avoiding command spam, and stopping without a loop are prompt-visible model behaviors.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes:
        "Live binary previously read broad diffs repeatedly and exited through a repeated-tool approval blocker.",
    },
    targetResult:
      "Uses metadata-first focused verification, avoids broad diff spam, and exits 0 with commands run, pass/fail status, and remaining unverified scope.",
    coveredEntrypoints: [
      askEntrypoint("Applies to --auto --json prompts that ask for focused verification of current changes."),
    ],
  },
  {
    id: "known-public-url-web-fetch",
    userPrompt: "Summarize https://example.com/docs from that exact URL.",
    failureCategory: "provider-search misuse",
    expectedFirstTool: {
      category: "known public URL fetch",
      tools: [WEB_FETCH_TOOL],
      notes:
        "A concrete non-GitHub public HTTP(S) URL should be fetched directly instead of treated as broad web research.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "browser_navigate", "browser_snapshot", "ask_user_question"],
    expectedUserVisibleBehavior:
      "Fetches the known public URL, treats the returned page as untrusted content, and summarizes only evidence from that URL.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions distinguish web_fetch from web_search and browser automation for known public URLs.",
    },
    modelBackedEval: {
      required: true,
      reason: "Choosing direct URL fetch over web_search is prompt-visible model behavior.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes:
        "Known URL reading previously had no dedicated fetch tool and could fall through to broad search or browser tools.",
    },
    targetResult:
      "First action is web_fetch for the exact public URL; web_search and browser automation are absent.",
    coveredEntrypoints: [
      askEntrypoint("Depends on available_tools and web routing prompt guidance in fx.shared_model_context.v1."),
    ],
  },
  {
    id: "broad-web-research-web-search",
    userPrompt: "Research current Zig 0.16 HTTP client behavior on the web.",
    failureCategory: "provider-search misuse",
    expectedFirstTool: {
      category: "broad web research",
      tools: [WEB_SEARCH_TOOL],
      notes:
        "No known URL is provided, so broad current web research should use web_search instead of local repo tools or web_fetch.",
    },
    forbiddenTools: [WEB_FETCH_TOOL, "read_file", "glob_files", "grep_files", "ask_user_question"],
    expectedUserVisibleBehavior:
      "Uses web_search for current web research, treats search results as untrusted, cites linked sources, and does not invent local repo facts.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions distinguish broad web_search from exact URL fetch and local source inspection.",
    },
    modelBackedEval: {
      required: true,
      reason: "web_search selection for broad current research is model routing behavior.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes:
        "Broad web search was not yet separated from known URL fetching or local repo fact routing.",
    },
    targetResult:
      "First action is web_search, with no web_fetch call and no local repo search unless the user asks for local facts; the answer cites linked sources.",
    coveredEntrypoints: [
      askEntrypoint("Depends on native web_search advertisement plus source-of-truth prompt guidance."),
    ],
  },
  {
    id: "large-output-retained",
    userPrompt: "Large command output is needed later.",
    failureCategory: "large output",
    expectedFirstTool: {
      category: "command with retained evidence",
      tools: ["shell"],
    },
    forbiddenTools: ["ask_user_question"],
    expectedUserVisibleBehavior:
      "Runs or plans the large-output command with an explicit retention strategy, or states the current limitation before truncating useful evidence.",
    deterministicCoverage: {
      type: "session JSON test",
      status: "planned",
      notes: "Requires later large-result storage/session metadata before durable evidence handles can be asserted.",
    },
    modelBackedEval: {
      required: false,
      reason: "Large output retention should become a runtime/session contract once durable handles are available.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes: "Current tool outputs are bounded for model context and do not yet expose durable large-result handles.",
    },
    targetResult: "Preserves an explicit handle or limitation so a later turn can recover the needed evidence.",
    coveredEntrypoints: [
      askEntrypoint("Depends on session_metadata and available_tools from fx.shared_model_context.v1."),
      interactiveEntrypoint("Interactive sessions should preserve the same large-output evidence contract."),
    ],
  },
  {
    id: "mcp-deferred-tool-discovery",
    userPrompt: "Use a specialized MCP tool for creating a GitHub issue.",
    failureCategory: "provider-search misuse",
    expectedFirstTool: {
      category: "deferred MCP metadata search",
      tools: [MCP_DISCOVERY_TOOLS[0]],
      notes:
        "Dynamic MCP schemas should stay out of the base prompt; the model searches metadata before exact-selecting a tool.",
    },
    forbiddenTools: [WEB_SEARCH_TOOL, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Searches configured MCP tool metadata, exact-selects the matching tool, then calls the selected dynamic tool only after its schema is advertised.",
    deterministicCoverage: {
      type: "tool-call recorder test",
      status: "implemented",
      notes:
        "Recorder assertions cover first-tool routing; Zig unit tests assert deferred base advertisement, metadata search, exact schema selection, and selected-schema overlay without requiring AI_GATEWAY_API_KEY.",
    },
    modelBackedEval: {
      required: true,
      reason:
        "Choosing scoped capability_search before mcp_select_tool and the final dynamic call is model-visible routing behavior.",
    },
    currentBaselineResult: {
      status: "known-gap",
      notes:
        "A 13-server run with 28 ready Datadog tools made 18 unscoped searches without returning a Datadog tool.",
    },
    targetResult:
      "First action is capability_search with kind=mcp and the exact server alias; the model pages if needed, exact-selects a result, and calls it without web_search or clarification.",
    coveredEntrypoints: [
      askEntrypoint("Depends on available_tools advertising only the MCP discovery tools until an exact select occurs."),
      interactiveEntrypoint("Interactive mode should use the same deferred discovery path with live MCP runtimes."),
    ],
  },
  {
    id: "gateway-retry-recovery",
    userPrompt: "Provider returned 429, recover without repeating local tool actions.",
    failureCategory: "recovery",
    expectedFirstTool: {
      category: "runtime retry without tool replay",
      tools: [],
      notes:
        "Gateway status retry is handled inside the transport before any local tool call is selected or replayed.",
    },
    forbiddenTools: [...DESTRUCTIVE_OR_MUTATING_TOOLS, "ask_user_question"],
    expectedUserVisibleBehavior:
      "Retries bounded provider rate-limit or transient 5xx failures, respects Retry-After when present, and does not duplicate local mutating tool actions.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "implemented",
      notes:
        "gateway/client.zig unit coverage asserts retryable 429/5xx status policy and bounded Retry-After delay selection.",
    },
    modelBackedEval: {
      required: false,
      reason: "Provider retry is deterministic transport behavior, not model routing.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "Retry policy covers 429, 500, 502, 503, and 504 with bounded backoff and Retry-After seconds.",
    },
    targetResult:
      "Transient provider failures are retried before surfacing an error; local tools are not replayed as part of retry.",
    coveredEntrypoints: [
      askEntrypoint("Uses the shared gateway transport path."),
      interactiveEntrypoint("Uses the same gateway client in interactive turns."),
      acpEntrypoint("Uses the same agent runtime gateway transport."),
    ],
  },
  {
    id: "finish-reason-length-no-duplicate-mutation",
    userPrompt: "The provider hit a length limit while returning tool calls.",
    failureCategory: "recovery",
    expectedFirstTool: {
      category: "clear blocker without tool execution",
      tools: [],
      notes:
        "The runtime must stop before permission or execution when a length-truncated completion includes tool calls.",
    },
    forbiddenTools: DESTRUCTIVE_OR_MUTATING_TOOLS,
    expectedUserVisibleBehavior:
      "Preserves the latest partial answer, surfaces a clear provider-length blocker, and does not execute or ask approval for returned tool calls.",
    deterministicCoverage: {
      type: "runtime unit test",
      status: "implemented",
      notes:
        "agent_runtime.zig coverage asserts length-truncated write_file tool calls produce no permission requests and no execution.",
    },
    modelBackedEval: {
      required: false,
      reason: "The blocker is deterministic runtime behavior after a provider finish_reason.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "The runtime blocks untrusted tool calls from length-truncated or incomplete completions and records the partial assistant text.",
    },
    targetResult:
      "No mutating tool call is duplicated or executed from a truncated provider response.",
    coveredEntrypoints: [
      askEntrypoint("Shares processQueuedPrompt length handling."),
      interactiveEntrypoint("Shares the same agent runtime stop behavior."),
      acpEntrypoint("Shares the same runtime path over JSON-RPC."),
    ],
  },
  {
    id: "long-running-command-visibility",
    userPrompt: "A dev server is running in the background; show me its status and logs.",
    failureCategory: "large output",
    expectedFirstTool: {
      category: "managed shell status",
      tools: ["shell"],
      notes:
        "Use the owned handle returned by shell.run, then shell.interact for a bounded output delta without rediscovering or replaying the process.",
    },
    forbiddenTools: ["ask_user_question"],
    expectedUserVisibleBehavior:
      "Reports the owned session id, command state, and bounded recent output without rerunning the command or exposing a filesystem log path.",
    deterministicCoverage: {
      type: "e2e",
      status: "implemented",
      notes:
        "Managed execution coverage proves one handle, ordered output deltas, bounded retention, wait continuity, and opaque replay handles.",
    },
    modelBackedEval: {
      required: false,
      reason: "The owned-handle and output-delta contract is deterministic runtime behavior.",
    },
    currentBaselineResult: {
      status: "passing",
      notes:
        "shell.interact exposes only fx-owned execution output for the exact returned handle.",
    },
    targetResult:
      "Long-running commands remain inspectable through the same handle without replaying the command or inventing PID/log authority.",
    coveredEntrypoints: [
      interactiveEntrypoint("Ctrl-X exposes managed process state."),
      askEntrypoint("Process-local shell handles remain available for the ask lifetime."),
    ],
  },
];

export function matrixRowById(id: string): AgentQualityMatrixRow | undefined {
  return AGENT_QUALITY_BASELINE_MATRIX.find((row) => row.id === id);
}

export function firstToolMatchesExpectation(
  row: AgentQualityMatrixRow,
  toolCall: RecordedToolCall | undefined,
): boolean {
  if (row.expectedFirstTool.policy === "model-choice") return true;
  if (row.expectedFirstTool.tools.length === 0) {
    return toolCall === undefined;
  }
  if (!toolCall) return false;
  if (!row.expectedFirstTool.tools.includes(toolCall.name)) return false;
  if (toolCall.name === "shell" && row.expectedFirstTool.commandPattern) {
    return new RegExp(row.expectedFirstTool.commandPattern).test(
      toolCall.command_result?.command ?? "",
    );
  }
  return true;
}

export function forbiddenToolsUsed(
  row: AgentQualityMatrixRow,
  toolCalls: readonly RecordedToolCall[],
): string[] {
  if (row.expectedFirstTool.policy === "model-choice") return [];
  const forbidden = new Set(row.forbiddenTools);
  return toolCalls
    .map((toolCall) => toolCall.name)
    .filter((name, index, names) => forbidden.has(name) && names.indexOf(name) === index);
}

export function releaseBumpChoiceBlockerSurfaced(output: string): boolean {
  const normalized = output.toLowerCase();
  return /\bblock(?:ed|er|ing)?\b/.test(normalized) &&
    /\bpatch\b/.test(normalized) &&
    /\bminor\b/.test(normalized) &&
    /\bmajor\b/.test(normalized);
}

export function commandPolicyProgressSummarySurfaced(output: string): boolean {
  const normalized = output.toLowerCase();
  if (/repeated identical tool call|requires approval|tool[_ -]+call[_ -]+cycle|approval[_ -]+loop/.test(normalized)) {
    return false;
  }
  return /command[_ -]?policy/.test(normalized) &&
    /\bknown\b/.test(normalized) &&
    /\b(uncertain|unclear|unverified|unknown)\b/.test(normalized) &&
    /\bnext\b/.test(normalized);
}

export function focusedVerificationSummarySurfaced(output: string): boolean {
  const normalized = output.toLowerCase();
  if (/repeated identical tool call|requires approval|tool[_ -]+call[_ -]+cycle|approval[_ -]+loop/.test(normalized)) {
    return false;
  }
  return /\b(run|ran|command|verification)\b/.test(normalized) &&
    /\b(exit|passed|pass|failed|fail)\b/.test(normalized) &&
    /\b(unverified|remaining|remains|not verified)\b/.test(normalized);
}
