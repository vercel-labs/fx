import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  findFooterBlocks,
  isDividerRow,
  readTrace,
  visibleText,
} from "./tui-render-assertions";
import {
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewaySerializedToolCall,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { stdoutFrames } from "./render-lab/tape";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const OUTER_MODEL = "openai/gpt-5";
const APPROVAL_PROMPT = "Would you like to run the following command?";
const DEFAULT_COMMAND_APPROVAL_REASON =
  "Reason: fx needs your approval before running this shell command.";
const COMMAND_ALWAYS_CHOICE = "Yes, and don't ask again for this exact command";
const COMMAND_YES_CHOICE = "Yes";
const COMMAND_NO_CHOICE = "No";
const COMMAND_YES_AMENDMENT = "Yes, and tell fx what to do next";
const COMMAND_NO_AMENDMENT = "No, and tell fx what to do differently";
const QUESTION_PROMPT = "Choose next step?";
const FORBIDDEN_TYPING = "typing a reply";
const FORBIDDEN_TYPING_SUFFIX = "ping a reply";
const QUESTION_TYPING = "typing a reply hjkl";
const CTRL_C_HINT = "press ctrl+c again to exit";
const ESC_HINT = "esc again to clear";
const ARGUMENT_RECOVERY_CALL_ID = "argument_recovery_question_1";
const ARGUMENT_RECOVERY_TOOL_NAME = "ask_user_question";
const VALID_QUESTION_PREAMBLE = "I need one detail before continuing.";
const MALFORMED_ARGUMENTS = "{]";
const MALFORMED_LABEL_SENTINEL = "FX_MALFORMED_LABEL_SENTINEL";
const MALFORMED_STREAMED_ARGUMENTS =
  `{"path":"${MALFORMED_LABEL_SENTINEL}",`;
const LONG_QUESTION =
  "When you ask fx to ask a question interactively, the question text must remain fully visible even when it wraps.";
const LONG_QUESTION_ANSWER =
  "Run the complete verification suite before pushing this branch";
const LONG_QUESTION_DESCRIPTION =
  "Keep the entire explanation visible even when it wraps across several terminal rows";
const VALID_QUESTION_ARGUMENTS = JSON.stringify({
  questions: [
    {
      question: QUESTION_PROMPT,
      options: [
        {
          label: "Inspect repo state",
          description: "Review local files first.",
        },
        {
          label: "Run tests",
          description: "Start with verification.",
        },
      ],
    },
  ],
});

const PASTE_START = ["1b", "5b", "32", "30", "30", "7e"] as const;
const PASTE_END = ["1b", "5b", "32", "30", "31", "7e"] as const;
const LEADING_ZERO_START = ["1b", "5b", "30", "32", "30", "30", "7e"] as const;
const PARAMETERIZED_START = ["1b", "5b", "32", "30", "30", "3b", "31", "7e"] as const;
const LONG_PARAMETERIZED_START = [
  "1b",
  "5b",
  "32",
  "30",
  "30",
  "3b",
  "39",
  "39",
  "39",
  "39",
  "39",
  "39",
  "7e",
] as const;
const CSI_U_DIGIT_ONE = ["1b", "5b", "34", "39", "3b", "35", "75"] as const;
const CSI_U_ESCAPE = ["1b", "5b", "32", "37", "75"] as const;
const RESTARTED_CSI_U_DIGIT_ONE = [
  "1b",
  "5b",
  "1b",
  "5b",
  "34",
  "39",
  "3b",
  "35",
  "75",
] as const;

type GatewayRequest = {
  body: string;
  headers: Headers;
};

type GatewayResponse = Response | (() => Response | Promise<Response>);
type ClassifierDecision = (body: string) => "clear" | "caution";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

let session: TmuxSession | null = null;
const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function sse(events: object[], done = true) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      (done ? "data: [DONE]\n\n" : ""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function outerToolCalls(calls: Array<{ id: string; name: string; input: object }>) {
  return sse(
    [
      ...calls.map((call) => ({
        type: "tool-call",
        toolCallId: call.id,
        toolName: call.name,
        input: call.input,
      })),
      {
        type: "finish",
        finishReason: { unified: "tool-calls", raw: "tool-calls" },
      },
    ],
  );
}

function outerCommandCall() {
  return outerToolCalls([
    {
      id: "command_outer_1",
      name: "shell",
      input: {
        request: {
          action: "run",
          command: "touch generic-preview-accepted.txt",
          yield_time_ms: 30_000,
          timeout_ms: 600_000,
        },
      },
    },
  ]);
}

const LONG_COMMAND_START = "LONG_COMMAND_APPROVAL_START";
const LONG_COMMAND_END = "LONG_COMMAND_APPROVAL_END";
const COMMAND_SCROLL_LINE_PREFIX = "APPROVAL_SCROLL_DOGFOOD_LINE_";
const FITTING_COMMAND_START = `grep -r "asChild\\|render" node_modules/@base-ui/react/menu/trigger/`;
const FITTING_COMMAND_END = "ls node_modules/@base-ui/react/menu/trigger/ 2>/dev/null";

function outerLongCommandCall() {
  const command =
    `touch long-command-approval-marker && printf '%s\\n' '` +
    `${LONG_COMMAND_START}${"x".repeat(600)}${LONG_COMMAND_END}'`;
  return outerToolCalls([
    {
      id: "long_command_outer_1",
      name: "shell",
      input: {
        request: {
          action: "run",
          command,
          yield_time_ms: 30_000,
          timeout_ms: 600_000,
        },
      },
    },
  ]);
}

function outerScrollableLongCommandCall() {
  const reviewLines = Array.from(
    { length: 90 },
    (_, index) => `${COMMAND_SCROLL_LINE_PREFIX}${String(index + 1).padStart(3, "0")}`,
  ).join(" ");
  const command =
    `touch long-command-approval-marker && printf '%s\\n' '` +
    `${LONG_COMMAND_START} ${reviewLines} ${LONG_COMMAND_END}'`;
  return outerToolCalls([
    {
      id: "scrollable_long_command_outer_1",
      name: "shell",
      input: {
        request: {
          action: "run",
          command,
          yield_time_ms: 30_000,
          timeout_ms: 600_000,
        },
      },
    },
  ]);
}

function outerFittingCommandCall() {
  const command =
    `${FITTING_COMMAND_START} 2>/dev/null | head -20; ` +
    `echo '==='; ${FITTING_COMMAND_END}`;
  return outerToolCalls([
    {
      id: "fitting_command_outer_1",
      name: "shell",
      input: {
        request: {
          action: "run",
          command,
          yield_time_ms: 30_000,
          timeout_ms: 600_000,
        },
      },
    },
  ]);
}

function outerQuestionCall() {
  return outerToolCalls([
    {
      id: "question_outer_1",
      name: "ask_user_question",
      input: {
        questions: [
          {
            question: QUESTION_PROMPT,
            options: [
              {
                label: "Inspect repo state",
                description: "Review local files first.",
              },
              {
                label: "Run tests",
                description: "Start with verification.",
              },
            ],
          },
        ],
      },
    },
  ]);
}

function outerQuestionBatchCall() {
  return outerToolCalls([
    {
      id: "question_batch_outer_1",
      name: "ask_user_question",
      input: {
        questions: [
          {
            question: "Which verification depth should I use?",
            options: [
              { label: "Thorough", description: "Run the full verification set." },
              { label: "Focused", description: "Run only the closest checks." },
            ],
          },
          {
            question: "Should I push after verification?",
            options: [
              { label: "Yes", description: "Push when every check passes." },
              { label: "No", description: "Leave the branch local." },
            ],
          },
          {
            question: "What should I report?",
            options: [
              { label: "Summary", description: "Return a concise result." },
              { label: "Details", description: "Include the verification evidence." },
            ],
          },
        ],
      },
    },
  ]);
}

function outerLongQuestionAnswerCall() {
  return outerToolCalls([
    {
      id: "long_question_answer_outer_1",
      name: "ask_user_question",
      input: {
        questions: [
          {
            question: LONG_QUESTION,
            options: [
              {
                label: LONG_QUESTION_ANSWER,
                description: LONG_QUESTION_DESCRIPTION,
              },
              { label: "Skip verification" },
            ],
          },
        ],
      },
    },
  ]);
}

function outerText(text: string) {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 3 },
        outputTokens: { total: 5 },
      },
    },
  ]);
}

function controlledGatewayResponse(response: Response) {
  let signalRequested!: () => void;
  let releaseResponse!: () => void;
  const requested = new Promise<void>((resolve) => signalRequested = resolve);
  const released = new Promise<void>((resolve) => releaseResponse = resolve);
  return {
    requested,
    release: releaseResponse,
    next: async () => {
      signalRequested();
      await released;
      return response;
    },
  };
}

function startFakeGateway(
  responses: GatewayResponse[],
  classifierDecision: ClassifierDecision = () => "clear",
) {
  const requests: GatewayRequest[] = [];
  const classifierRequests: GatewayRequest[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: [{ id: OUTER_MODEL, type: "language", tags: ["tool-use"] }],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes('"permission_decision"')) {
        classifierRequests.push({ body, headers: req.headers });
        return fakeGatewayPermissionDecision(classifierDecision(body));
      }
      requests.push({ body, headers: req.headers });
      const next = responses.shift();
      if (!next) return new Response("unexpected request", { status: 500 });
      return typeof next === "function" ? await next() : next;
    },
  });

  return {
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    baseUrl: `http://127.0.0.1:${server.port}`,
    requests,
    classifierRequests,
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot(
  permissionMode: "ask" | "auto" = "ask",
  permission: Record<string, unknown> = {},
) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-decision-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ permission_mode: permissionMode, permission }),
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function definedStringEnv(env: Record<string, string | undefined>) {
  return Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );
}

function fakeGatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  extra: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: OUTER_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
    ...extra,
  };
}

async function launchScenario(
  responses: GatewayResponse[],
  traceScopes = "input",
  env: Record<string, string | undefined> = {},
  permissionMode: "ask" | "auto" = "ask",
  classifierDecision: ClassifierDecision = () => "clear",
  permission: Record<string, unknown> = {},
) {
  const root = createIsolatedRoot(permissionMode, permission);
  const gateway = startFakeGateway(responses, classifierDecision);
  gateways.push(gateway);
  const tracePath = join(root.root, "trace.log");
  const stderrPath = join(root.root, "stderr.log");
  writeFileSync(stderrPath, "");

  session = await TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${stderrPath}`,
    cwd: root.workspace,
    env: definedStringEnv(fakeGatewayEnv(root, gateway, {
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: traceScopes,
      ...env,
    })),
    width: 120,
    height: 40,
  });
  await session.waitForComposer(TIMEOUT);
  return { root, gateway, tracePath, stderrPath, session };
}

function readFilesRecursively(path: string): string {
  if (!existsSync(path)) return "";
  let output = "";
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) {
      output += readFilesRecursively(child);
    } else {
      output += readFileSync(child, "utf8");
    }
  }
  return output;
}

async function openApprovalPrompt(
  label: string,
  env: Record<string, string | undefined> = {},
  extraResponses: Response[] = [],
) {
  const ctx = await launchScenario(
    [outerCommandCall(), outerText(`${label} handled`), ...extraResponses],
    "input",
    env,
  );
  await ctx.session.sendText("Run the generic approval fixture.");
  const pane = await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
  expect(pane).toContain("touch generic-preview-accepted.txt");
  return ctx;
}

async function openQuestionPrompt(label: string, extraResponses: Response[] = []) {
  const ctx = await launchScenario([
    outerQuestionCall(),
    outerText(`${label} handled`),
    ...extraResponses,
  ]);
  await ctx.session.sendText("Ask me which path to take.");
  const pane = await ctx.session.waitForText(QUESTION_PROMPT, TIMEOUT);
  await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
  expectBlankRowAboveQuestionPanel(await ctx.session.capturePaneGrid(), QUESTION_PROMPT);
  return ctx;
}

async function primeComposerKillRing(activeSession: TmuxSession, sentinel: string) {
  await activeSession.sendLiteralText(sentinel);
  await activeSession.sendHexBytes(["15"]);
  expect(currentFooterText(await activeSession.capturePaneGrid())).not.toContain(sentinel);
}

async function exerciseQuestionHiddenDraftControl(options: {
  controlHex: string;
  hiddenDraft: string;
  visibleAnswer: string;
  visibleAnswerAfterControl?: string;
  startPrompt: string;
  handledMarker: string;
  draftMarker: string;
}) {
  const delayedQuestion = controlledGatewayResponse(outerQuestionCall());
  const ctx = await launchScenario([
    delayedQuestion.next,
    outerText(options.handledMarker),
    outerText(options.draftMarker),
  ]);

  await ctx.session.sendText(options.startPrompt);
  await delayedQuestion.requested;
  await ctx.session.sendLiteralText(options.hiddenDraft);
  expect(currentFooterText(await ctx.session.capturePaneGrid())).toContain(options.hiddenDraft);
  delayedQuestion.release();

  await ctx.session.waitForText(QUESTION_PROMPT, TIMEOUT);
  await ctx.session.sendLiteralText("3");
  await waitForQuestionPane(ctx.session, "question hidden draft freeform selected", (value) =>
    hasQuestionSelection(value, 3, ""),
  );
  await ctx.session.sendLiteralText(options.visibleAnswer);
  await ctx.session.sendHexBytes([options.controlHex]);
  if (options.visibleAnswerAfterControl !== undefined) {
    await ctx.session.sendLiteralText(options.visibleAnswerAfterControl);
  }
  const submittedAnswer = options.visibleAnswerAfterControl ?? options.visibleAnswer;
  await waitForQuestionPane(ctx.session, "question hidden draft control isolated", (value) =>
    hasQuestionSelection(value, 3, submittedAnswer),
  );

  await ctx.session.sendKeys("Enter");
  await ctx.session.waitForText(options.handledMarker, TIMEOUT);
  const restoredFooter = currentFooterText(await ctx.session.capturePaneGrid());
  expect(restoredFooter).toContain(options.hiddenDraft);
  expect(restoredFooter).not.toContain(options.startPrompt);

  await ctx.session.sendKeys("Enter");
  await ctx.session.waitForText(options.draftMarker, TIMEOUT);
  expect(ctx.gateway.requests).toHaveLength(3);
  expect(requestContainsExactString(
    ctx.gateway.requests[1]!.body,
    submittedAnswer,
  )).toBe(true);
  expect(requestContainsExactString(
    ctx.gateway.requests[2]!.body,
    options.hiddenDraft,
  )).toBe(true);
  await assertProcessAliveAndClean(ctx);
}

async function resolveApprovalWithDeny(activeSession: TmuxSession) {
  await activeSession.sendLiteralText("3");
}

async function resolveQuestionWithSecondOption(activeSession: TmuxSession) {
  await activeSession.sendKeys("Down");
  await activeSession.sendKeys("Enter");
}

async function waitForPaneState(
  activeSession: TmuxSession,
  label: string,
  predicate: (pane: string) => boolean,
  timeoutMs = 5_000,
) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const pane = await activeSession.capturePane();
    if (predicate(pane)) return pane;
    await sleep(100);
  }
  const pane = await activeSession.capturePane();
  throw new Error(`[${label}] timed out waiting for pane state.\n${pane}`);
}

async function waitForGridState(
  activeSession: TmuxSession,
  label: string,
  predicate: (grid: string[]) => boolean,
  timeoutMs = 5_000,
) {
  const start = Date.now();
  let last: string[] = [];
  let previous = "";
  let stableMatches = 0;
  while (Date.now() - start < timeoutMs) {
    last = await activeSession.capturePaneGrid();
    const current = last.join("\n");
    if (predicate(last)) {
      stableMatches = current === previous ? stableMatches + 1 : 1;
      if (stableMatches >= 3) return last;
    } else {
      stableMatches = 0;
    }
    previous = current;
    await sleep(100);
  }
  throw new Error(`[${label}] timed out waiting for grid state.\n${last.join("\n")}`);
}

async function assertProcessAliveAndClean(ctx: {
  session: TmuxSession;
  stderrPath: string;
}) {
  expect(ctx.session.isAlive()).toBe(true);
  const stderr = readFileSync(ctx.stderrPath, "utf8");
  expect(stderr).toBe("");
}

function expectNoForbiddenComposerText(pane: string) {
  expect(pane).not.toContain(FORBIDDEN_TYPING);
  expect(pane).not.toContain(FORBIDDEN_TYPING_SUFFIX);
  expect(pane).not.toContain(QUESTION_TYPING);
}

function expectApprovalSelection(pane: string, ordinal: number, selectedLabel: string) {
  expect(hasApprovalSelection(pane, ordinal, selectedLabel)).toBe(true);
}

async function expectQuestionSelection(
  activeSession: TmuxSession,
  ordinal: number,
  selectedLabel: string,
) {
  const pane = await activeSession.capturePaneEscapes();
  expect(hasQuestionSelection(pane, ordinal, selectedLabel)).toBe(true);
}

// Polls with color so question selection (now signalled purely by the white
// style, no caret) is observable — plain capture drops SGR.
async function waitForQuestionPane(
  activeSession: TmuxSession,
  label: string,
  predicate: (paneEscapes: string) => boolean,
  timeoutMs = 5_000,
) {
  const start = Date.now();
  let last = "";
  while (Date.now() - start < timeoutMs) {
    last = await activeSession.capturePaneEscapes();
    if (predicate(last)) return last;
    await sleep(100);
  }
  throw new Error(`[${label}] timed out waiting for question pane.\n${last}`);
}

async function waitForVisibleScrollback(
  activeSession: TmuxSession,
  label: string,
  predicate: (scrollback: string) => boolean,
  timeoutMs = 10_000,
) {
  const start = Date.now();
  let last = "";
  while (Date.now() - start < timeoutMs) {
    last = visibleText(await activeSession.captureFullScrollback());
    if (predicate(last)) return last;
    await sleep(100);
  }
  throw new Error(`[${label}] timed out waiting for scrollback.\n${last}`);
}

function stripAnsi(value: string): string {
  return value.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
}

function hasSelection(pane: string, ordinal: number, selectedLabel: string) {
  return visibleText(pane).includes(visibleText(`› ${ordinal}. ${selectedLabel}`));
}

// The selected option is the only row carrying the white (255) style; match
// the ordinal/label on that row after stripping the interleaved escapes.
function hasQuestionSelection(paneEscapes: string, ordinal: number, selectedLabel: string) {
  const needle = visibleText(`${ordinal}) ${selectedLabel}`);
  return paneEscapes.split(/\r?\n/).some((line) =>
    line.includes("38;5;255") && visibleText(stripAnsi(line)).includes(needle)
  );
}

function hasApprovalSelection(pane: string, ordinal: number, selectedLabel: string) {
  return visibleText(pane).includes(visibleText(`❯ ${ordinal}. ${selectedLabel}`));
}

function requestContainsExactString(body: string, expected: string) {
  const seen = new Set<string>();

  function visit(value: unknown): boolean {
    if (typeof value === "string") {
      if (value === expected) return true;
      if (seen.has(value)) return false;
      seen.add(value);
      try {
        return visit(JSON.parse(value));
      } catch {
        return false;
      }
    }
    if (Array.isArray(value)) return value.some(visit);
    if (value && typeof value === "object") {
      return Object.values(value).some(visit);
    }
    return false;
  }

  return visit(JSON.parse(body));
}

function currentFooterText(grid: string[]) {
  const footers = findFooterBlocks(grid);
  const footer = footers[footers.length - 1];
  if (!footer) return "";
  return grid.slice(footer.input, footer.bottomDivider).join("\n");
}

function expectBlankRowAboveQuestionPanel(grid: string[], question: string) {
  const questionRow = grid.findIndex((row) => row.includes(question));
  expect(questionRow).toBeGreaterThan(0);

  let topDividerRow = questionRow - 1;
  while (topDividerRow >= 0 && !isDividerRow(grid[topDividerRow]!)) {
    topDividerRow -= 1;
  }
  expect(topDividerRow).toBeGreaterThan(0);
  expect(grid[topDividerRow - 1]!.trim()).toBe("");
}

function countOccurrences(value: string, needle: string) {
  let count = 0;
  let offset = 0;
  while (true) {
    const next = value.indexOf(needle, offset);
    if (next < 0) return count;
    count += 1;
    offset = next + needle.length;
  }
}

async function waitForDropTrace(
  tracePath: string,
  bytes: number,
  expectedCount: number,
  timeoutMs = 5_000,
) {
  const needle = `decision prompt paste dropped bytes=${bytes} reason=decision_prompt_active`;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = readTrace(tracePath);
    if (countOccurrences(trace, needle) >= expectedCount) return trace;
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for ${expectedCount} trace lines: ${needle}\nTrace:\n${readTrace(tracePath)}`,
  );
}

async function waitForInputTrace(
  tracePath: string,
  needle: string,
  timeoutMs = 5_000,
) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = readTrace(tracePath);
    if (trace.includes(needle)) return trace;
    await sleep(100);
  }
  throw new Error(`Timed out waiting for trace line: ${needle}\nTrace:\n${readTrace(tracePath)}`);
}

async function waitForTraceAfter(
  tracePath: string,
  start: number,
  needle: string,
  timeoutMs = TIMEOUT,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const trace = readTrace(tracePath);
    if (trace.slice(start).includes(needle)) return trace;
    await sleep(25);
  }
  throw new Error(
    `Timed out waiting for trace line after offset ${start}: ${needle}\nTrace:\n${readTrace(tracePath)}`,
  );
}

async function waitForPath(path: string, timeoutMs = TIMEOUT) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await sleep(25);
  }
  throw new Error(`Timed out waiting for path: ${path}`);
}

async function waitForFreeformLimitTrace(
  tracePath: string,
  bytes: number,
  timeoutMs = 5_000,
) {
  return waitForInputTrace(
    tracePath,
    `question freeform paste dropped bytes=${bytes} reason=input_limit`,
    timeoutMs,
  );
}

function expectNoDropTrace(tracePath: string) {
  expect(readTrace(tracePath)).not.toContain("decision prompt paste dropped");
}

function textHex(text: string) {
  return Array.from(Buffer.from(text, "utf8"), (byte) =>
    byte.toString(16).padStart(2, "0"),
  );
}

function concatHex(...chunks: readonly (readonly string[])[]) {
  return chunks.flatMap((chunk) => [...chunk]);
}

function repeatHex(chunk: readonly string[], count: number) {
  return Array.from({ length: count }, () => chunk).flatMap((part) => [...part]);
}

async function sendPaste(activeSession: TmuxSession, payload: readonly string[]) {
  await activeSession.sendHexBytes(concatHex(PASTE_START, payload, PASTE_END));
}

async function sendBytesThenTab(
  activeSession: TmuxSession,
  label: string,
  bytes: readonly string[],
  predicate: (pane: string) => boolean,
) {
  await activeSession.sendHexBytes(bytes);
  await activeSession.sendKeys("Tab");
  return waitForPaneState(activeSession, label, predicate);
}

function decisionPastePayload() {
  return concatHex(
    textHex("yp123 hjkl"),
    ["0a"],
    ["03"],
    ["1b", "5b", "39", "39", "3b", "35", "75"],
    ["1b", "5b", "41"],
    ["1b", "5b", "32", "78"],
    PASTE_START,
  );
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe.skipIf(SKIP)("tui: decision prompt input isolation", () => {
  test(
    "valid serialized ask control with matching identity opens the question and continues",
    async () => {
      const ctx = await launchScenario(
        [
          fakeGatewaySerializedToolCall(
            ARGUMENT_RECOVERY_CALL_ID,
            ARGUMENT_RECOVERY_TOOL_NAME,
            VALID_QUESTION_ARGUMENTS,
            VALID_QUESTION_PREAMBLE,
          ),
          fakeGatewayFinalText("Valid question continued."),
        ],
        "agent,gateway,input",
      );

      await ctx.session.sendText("Run the valid question control.");
      const questionPane = await waitForPaneState(
        ctx.session,
        "valid question prompt",
        (pane) => pane.includes(QUESTION_PROMPT),
        TIMEOUT,
      );
      expect(questionPane).toContain(VALID_QUESTION_PREAMBLE);
      expect(questionPane.indexOf(VALID_QUESTION_PREAMBLE)).toBeLessThan(
        questionPane.indexOf(QUESTION_PROMPT),
      );
      await expectQuestionSelection(ctx.session, 1, "Inspect repo state");

      await resolveQuestionWithSecondOption(ctx.session);
      const finalPane = await ctx.session.waitForText("Valid question continued.", TIMEOUT);
      expect(finalPane).toContain(VALID_QUESTION_PREAMBLE);
      expect(finalPane).not.toContain("SyntaxError");
      expect(finalPane).not.toContain("Request failed");
      expect(ctx.gateway.requests).toHaveLength(2);
      const followup = ctx.gateway.requests[1].body;
      expect(followup).toContain(`"toolCallId":"${ARGUMENT_RECOVERY_CALL_ID}"`);
      expect(followup).toContain(`"toolName":"${ARGUMENT_RECOVERY_TOOL_NAME}"`);
      expect(followup).toContain("Run tests");
      expect(followup).not.toContain("tool_execution_failed");
      await assertProcessAliveAndClean(ctx);

      await ctx.session.sendText("/quit");
      expect(await ctx.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "malformed ask arguments recover without opening a question prompt",
    async () => {
      const ctx = await launchScenario(
        [
          fakeGatewaySerializedToolCall(
            ARGUMENT_RECOVERY_CALL_ID,
            ARGUMENT_RECOVERY_TOOL_NAME,
            MALFORMED_ARGUMENTS,
            "I need one detail before continuing.",
          ),
          fakeGatewayFinalText("Malformed question recovered."),
        ],
        "agent,gateway,input",
      );

      await ctx.session.sendText("Run the malformed question fixture.");
      const pane = await ctx.session.waitForText("Malformed question recovered.", TIMEOUT);
      expect(pane).toContain("I need one detail before continuing.");
      expect(pane).not.toContain(QUESTION_PROMPT);
      expect(pane).not.toContain(APPROVAL_PROMPT);
      expect(pane).not.toContain("SyntaxError");
      expect(pane).not.toContain("Request failed");
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests[1].body).toContain(
        `"toolCallId":"${ARGUMENT_RECOVERY_CALL_ID}"`,
      );
      expect(ctx.gateway.requests[1].body).toContain('"input":{}');
      expect(ctx.gateway.requests[1].body).toContain("tool_execution_failed");
      expect(ctx.gateway.requests[1].body).not.toContain(MALFORMED_ARGUMENTS);
      await assertProcessAliveAndClean(ctx);

      await ctx.session.sendText("/quit");
      expect(await ctx.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      const trace = readTrace(ctx.tracePath);
      const sessions = readFilesRecursively(join(ctx.root.home, ".fx", "sessions"));
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
      expect(trace).not.toContain(MALFORMED_ARGUMENTS);
      expect(sessions).not.toContain(MALFORMED_ARGUMENTS);
      expect(sessions).toContain("tool_execution_failed");
    },
    TIMEOUT,
  );

  test(
    "malformed streamed read arguments never publish their provisional label",
    async () => {
      const malformedCallId = "malformed_streamed_read_1";
      const ctx = await launchScenario(
        [
          sse([
            {
              type: "text-delta",
              id: "text_before",
              delta: "I need to inspect one file before continuing.",
            },
            {
              type: "tool-input-start",
              id: malformedCallId,
              toolName: "read_file",
            },
            {
              type: "tool-input-delta",
              id: malformedCallId,
              delta: MALFORMED_STREAMED_ARGUMENTS,
            },
            { type: "tool-input-end", id: malformedCallId },
            { type: "tool-call", toolCallId: malformedCallId },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          fakeGatewayFinalText("Malformed streamed read recovered."),
        ],
        "agent,gateway,input",
      );

      await ctx.session.sendText("Run the malformed streamed read fixture.");
      const pane = await ctx.session.waitForText(
        "Malformed streamed read recovered.",
        TIMEOUT,
      );
      expect(pane).toContain("I need to inspect one file before continuing.");
      expect(pane).not.toContain(MALFORMED_LABEL_SENTINEL);
      expect(pane).not.toContain("● Reading");
      expect(pane).not.toContain(APPROVAL_PROMPT);
      expect(pane).not.toContain(QUESTION_PROMPT);
      expect(pane).not.toContain("SyntaxError");
      expect(pane).not.toContain("Request failed");
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests[1].body).toContain(
        `"toolCallId":"${malformedCallId}"`,
      );
      expect(ctx.gateway.requests[1].body).toContain('"input":{}');
      expect(ctx.gateway.requests[1].body).toContain("tool_execution_failed");
      expect(ctx.gateway.requests[1].body).not.toContain(
        MALFORMED_STREAMED_ARGUMENTS,
      );
      expect(ctx.gateway.requests[1].body).not.toContain(
        MALFORMED_LABEL_SENTINEL,
      );
      await assertProcessAliveAndClean(ctx);

      await ctx.session.sendText("/quit");
      expect(await ctx.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      const trace = readTrace(ctx.tracePath);
      const sessions = readFilesRecursively(join(ctx.root.home, ".fx", "sessions"));
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
      expect(trace).not.toContain(MALFORMED_STREAMED_ARGUMENTS);
      expect(trace).not.toContain(MALFORMED_LABEL_SENTINEL);
      expect(sessions).not.toContain(MALFORMED_STREAMED_ARGUMENTS);
      expect(sessions).not.toContain(MALFORMED_LABEL_SENTINEL);
      expect(sessions).toContain("tool_execution_failed");
    },
    TIMEOUT,
  );

  test(
    "publishes a complete assistant block before an ask-user question and continues after its answer",
    async () => {
      const preStart = "PRE_QUESTION_ASSISTANT_START";
      const preEnd = "PRE_QUESTION_ASSISTANT_END";
      const postAnswer = "POST_QUESTION_ASSISTANT_CONTINUATION";
      const markdown = [
        preStart,
        "",
        "## Streaming boundary fixture",
        "",
        ...Array.from(
          { length: 96 },
          (_, index) =>
            `- wrapped Markdown row ${String(index).padStart(3, "0")}: ` +
            "this assistant text must be committed before the interactive question opens. ".repeat(2),
        ),
        "",
        `The final pre-question paragraph has **bold text**, \`inline code\`, and ${preEnd}.`,
      ].join("\n");
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-question-pacer-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "question.fxtape");
      const ctx = await launchScenario(
        [
          sse([
            {
              type: "text-delta",
              id: "answer_1",
              delta: markdown,
            },
            {
              type: "tool-call",
              toolCallId: "pacer_gate_question",
              toolName: "ask_user_question",
              input: {
                questions: [
                  {
                    question: QUESTION_PROMPT,
                    options: [
                      {
                        label: "Inspect repo state",
                        description: "Review local files first.",
                      },
                      {
                        label: "Run tests",
                        description: "Start with verification.",
                      },
                    ],
                  },
                ],
              },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          outerText(postAnswer),
        ],
        "input",
        { FX_RECORD: tapePath },
      );

      await ctx.session.sendText("Run the question pacing fixture.");
      await ctx.session.waitForText(QUESTION_PROMPT, TIMEOUT);

      const activeScrollback = await waitForVisibleScrollback(
        ctx.session,
        "complete assistant block before question",
        (scrollback) => {
          const end = scrollback.indexOf(preEnd);
          const question = scrollback.indexOf(
            visibleText(QUESTION_PROMPT),
            end + preEnd.length,
          );
          return end >= 0 && question > end;
        },
      );
      const activeStart = activeScrollback.indexOf(preStart);
      const activeEnd = activeScrollback.indexOf(preEnd);
      const activeQuestion = activeScrollback.indexOf(
        visibleText(QUESTION_PROMPT),
        activeEnd + preEnd.length,
      );
      expect(activeStart).toBeGreaterThanOrEqual(0);
      expect(activeEnd).toBeGreaterThan(activeStart);
      expect(activeQuestion).toBeGreaterThan(activeEnd);
      const activeGrid = await ctx.session.capturePaneGrid();
      expectBlankRowAboveQuestionPanel(activeGrid, QUESTION_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.resizeWindow(60, 12);
      await waitForQuestionPane(
        ctx.session,
        "compact question after complete assistant block",
        (value) => value.includes(QUESTION_PROMPT),
      );
      const compactGrid = await ctx.session.capturePaneGrid();
      expectBlankRowAboveQuestionPanel(compactGrid, QUESTION_PROMPT);

      await resolveQuestionWithSecondOption(ctx.session);
      await ctx.session.waitForText(postAnswer, TIMEOUT);
      const finalScrollback = visibleText(await ctx.session.captureFullScrollback());
      const finalPreStart = finalScrollback.indexOf(preStart);
      const finalPreEnd = finalScrollback.indexOf(preEnd);
      const finalQuestion = finalScrollback.indexOf(visibleText(QUESTION_PROMPT));
      const finalPostAnswer = finalScrollback.indexOf(postAnswer);
      expect(finalPreStart).toBeGreaterThanOrEqual(0);
      expect(finalPreEnd).toBeGreaterThan(finalPreStart);
      expect(finalQuestion).toBeGreaterThan(finalPreEnd);
      expect(finalPostAnswer).toBeGreaterThan(finalQuestion);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests[1]!.body).toContain("Run tests");
      await assertProcessAliveAndClean(ctx);
      await ctx.session.sendText("/quit");
      expect(await ctx.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: ctx.root.workspace,
        env: { HOME: ctx.root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      const replayEnd = replay.stdout.indexOf(preEnd);
      const replayQuestion = replay.stdout.indexOf(QUESTION_PROMPT);
      const replayPostAnswer = replay.stdout.indexOf(postAnswer);
      expect(replayEnd).toBeGreaterThanOrEqual(0);
      expect(replayQuestion).toBeGreaterThan(replayEnd);
      expect(replayPostAnswer).toBeGreaterThan(replayQuestion);
    },
    TIMEOUT,
  );

  test(
    "generic approval stays inline through resize and denial",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-inline-generic-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await openApprovalPrompt("generic approval denied", {
        FX_RECORD: tapePath,
      });
      let pane = await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      expect(pane).toContain("touch generic-preview-accepted.txt");
      expect(pane).not.toContain(DEFAULT_COMMAND_APPROVAL_REASON);
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);

      await ctx.session.sendKeys("Down");
      pane = await waitForPaneState(ctx.session, "inline generic approval selection", (value) =>
        value.includes(APPROVAL_PROMPT) &&
        hasApprovalSelection(value, 2, COMMAND_ALWAYS_CHOICE),
      );
      expectApprovalSelection(pane, 2, COMMAND_ALWAYS_CHOICE);

      await ctx.session.resizeWindow(72, 20);
      pane = await waitForPaneState(ctx.session, "inline generic approval after resize", (value) =>
        value.includes(APPROVAL_PROMPT) &&
        hasApprovalSelection(value, 2, COMMAND_ALWAYS_CHOICE),
      );
      expect(pane).toContain("touch generic-preview-accepted.txt");

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("generic approval denied handled", TIMEOUT);
      expect(await ctx.session.capturePane()).not.toContain(APPROVAL_PROMPT);
      const stdout = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(stdout.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      const mouseTrackingEnter = Buffer.from("\x1b[?1000h\x1b[?1006h");
      const mouseTrackingLeave = Buffer.from("\x1b[?1000l\x1b[?1006l");
      const approvalPrompt = Buffer.from(APPROVAL_PROMPT);
      const firstApprovalIndex = stdout.indexOf(approvalPrompt);
      const lastApprovalIndex = stdout.lastIndexOf(approvalPrompt);
      expect(stdout.includes(mouseTrackingEnter)).toBe(false);
      expect(stdout.includes(mouseTrackingLeave)).toBe(false);
      expect(firstApprovalIndex).toBeGreaterThanOrEqual(0);
      expect(lastApprovalIndex).toBeGreaterThanOrEqual(firstApprovalIndex);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "long command approval renders the complete command before a decision",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-long-command-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const traceEnv = process.env.FX_TRACE_LOG
        ? {
            FX_TRACE_LOG: process.env.FX_TRACE_LOG,
            FX_TRACE_SCOPES: process.env.FX_TRACE_SCOPES ?? "input,permission",
          }
        : {};
      const ctx = await launchScenario([outerLongCommandCall()], "input", {
        FX_RECORD: tapePath,
        FX_RECORD_INPUT: "1",
        ...traceEnv,
      });

      await ctx.session.sendText("Request the long command approval fixture.");
      const pane = await waitForPaneState(
        ctx.session,
        "complete long command approval",
        (value) => {
          const commandReview = value.replaceAll("\n    ", "");
          return value.includes(APPROVAL_PROMPT) &&
            commandReview.includes(LONG_COMMAND_START) &&
            commandReview.includes(LONG_COMMAND_END);
        },
        TIMEOUT,
      );
      const commandReview = pane.replaceAll("\n    ", "");
      expect(commandReview).toContain(LONG_COMMAND_START);
      expect(commandReview).toContain(LONG_COMMAND_END);
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "long command approval keeps fragmented mouse scrolling inside the review",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-fragmented-command-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await launchScenario(
        [outerScrollableLongCommandCall(), outerText("long command fragmented approval complete")],
        "input,permission",
        {
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      );
      const fragmentedWheel = [
        "1b", "5b", "3c", "36", "35", "3b", "37", "39", "3b", "31", "32", "4d",
      ];
      const completeWheel = [
        "1b", "5b", "3c", "36", "34", "3b", "37", "39", "3b", "31", "32", "4d",
      ];
      await ctx.session.resizeWindow(80, 14);
      await ctx.session.sendText("Request the long command approval fixture.");
      const initialPane = await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      expect(initialPane).toContain(`${COMMAND_SCROLL_LINE_PREFIX}001`);
      const initialRows = initialPane.split("\n");
      const initialChoiceThreeRow = initialRows.findIndex((row) => row.includes("3. No"));
      const initialControlsRow = initialRows.findIndex((row) => row.includes("1–3 Choose"));
      expect(initialRows[initialChoiceThreeRow + 1]!.trim()).toBe("");
      expect(initialRows[initialChoiceThreeRow + 2]!.trim()).toMatch(/^─+$/);
      expect(initialControlsRow).toBe(initialChoiceThreeRow + 3);
      await sleep(250);
      const initialFrames = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(initialFrames.includes(Buffer.from("\x1b[?1000h\x1b[?1006h"))).toBe(true);

      await ctx.session.sendHexBytes(completeWheel);
      const completePane = await ctx.session.capturePane();
      expect(completePane).not.toBe(initialPane);
      expect(completePane).not.toContain(`${COMMAND_SCROLL_LINE_PREFIX}001`);
      expect(completePane).not.toContain("Cancelled");

      await ctx.session.sendHexBytes(fragmentedWheel.slice(0, 6));
      await ctx.session.sendHexBytes(fragmentedWheel.slice(6));
      const fragmentedPane = await waitForPaneState(
        ctx.session,
        "fragmented mouse scroll",
        (pane) =>
          pane.includes(`${COMMAND_SCROLL_LINE_PREFIX}001`) &&
          hasApprovalSelection(pane, 1, COMMAND_YES_CHOICE),
        TIMEOUT,
      );
      expect(fragmentedPane).not.toContain("Cancelled");
      const fragmentedScrollback = await ctx.session.captureFullScrollbackEscapes();
      expect(fragmentedScrollback).not.toContain("Cancelled");
      expect(fragmentedScrollback).not.toContain("4;79;12M");
      const approvalFrames = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(approvalFrames.includes(Buffer.from("\x1b[?1000h\x1b[?1006h"))).toBe(true);
      expect(readFileSync(ctx.tracePath, "utf8")).not.toContain("discard pending mouse report");

      await ctx.session.sendLiteralText("1");
      await ctx.session.waitForText("long command fragmented approval complete", TIMEOUT);
      expect(ctx.gateway.requests).toHaveLength(2);
      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: ctx.root.workspace,
        env: { HOME: ctx.root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain("long command fragmented approval complete");
      await assertProcessAliveAndClean(ctx);
    },
    90_000,
  );

  test(
    "wrapped command approval stays inline when its complete footer fits",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-inline-command-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await launchScenario([
        outerFittingCommandCall(),
        outerText("fitting command approval denied handled"),
      ], "input", { FX_RECORD: tapePath, FX_RECORD_INPUT: "1" });

      await ctx.session.resizeWindow(72, 40);
      await ctx.session.sendText("Request the fitting command approval fixture.");
      const pane = await waitForPaneState(
        ctx.session,
        "inline command approval footer",
        (value) =>
          value.includes(APPROVAL_PROMPT) && value.includes("1–3 Choose"),
        TIMEOUT,
      );
      const command = pane.replaceAll("\n    ", " ");
      expect(command).toContain(FITTING_COMMAND_START);
      expect(command).toContain(FITTING_COMMAND_END);
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);
      const paneRows = pane.split("\n");
      const choiceThreeRow = paneRows.findIndex((row) => row.includes("3. No"));
      const controlsRow = paneRows.findIndex((row) => row.includes("1–3 Choose"));
      expect(paneRows[choiceThreeRow + 1]!.trim()).toBe("");
      expect(paneRows[choiceThreeRow + 2]!.trim()).toMatch(/^─+$/);
      expect(controlsRow).toBe(choiceThreeRow + 3);
      expect(pane).not.toContain("ask · gpt-5");

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("fitting command approval denied handled", TIMEOUT);
      const stdout = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(stdout.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      expect(await ctx.session.capturePane()).not.toContain(APPROVAL_PROMPT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "vertically overflowing command approval exits review on Escape and recovers",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-overflow-command-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await launchScenario([
        outerFittingCommandCall(),
        outerText("overflow command approval Escape recovered"),
      ], "input", { FX_RECORD: tapePath });

      await ctx.session.resizeWindow(40, 13);
      await ctx.session.sendText("Request the overflowing command approval fixture.");
      await ctx.session.waitForText("Permission needed", TIMEOUT);

      await ctx.session.sendKeys("Escape");
      const cancelled = await ctx.session.waitForText("■ Cancelled", TIMEOUT);
      expect(cancelled).not.toContain(APPROVAL_PROMPT);

      await ctx.session.resizeWindow(72, 20);
      await ctx.session.sendText("Confirm the shell recovered after overflow cancellation.");
      const recovered = await ctx.session.waitForText(
        "overflow command approval Escape recovered",
        TIMEOUT,
      );
      expect(recovered).not.toContain(APPROVAL_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(2);

      const stdout = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(stdout.includes(Buffer.from("\x1b[?1049h"))).toBe(true);
      expect(stdout.includes(Buffer.from("\x1b[?1049l"))).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "command approval switches between inline and review on resize",
    async () => {
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-command-approval-resize-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await launchScenario([outerFittingCommandCall()], "input", {
        FX_RECORD: tapePath,
      });

      await ctx.session.resizeWindow(72, 20);
      await ctx.session.sendText("Request the resize command approval fixture.");
      let pane = await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      expect(pane.replaceAll("\n    ", " ")).toContain(FITTING_COMMAND_END);

      await ctx.session.resizeWindow(40, 13);
      await ctx.session.waitForText("Permission needed", TIMEOUT);

      await ctx.session.resizeWindow(72, 20);
      pane = await waitForPaneState(ctx.session, "command approval inline after resize", (value) =>
        value.includes(APPROVAL_PROMPT) &&
        value.replaceAll("\n    ", " ").includes(FITTING_COMMAND_END),
      );
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);

      const stdout = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(stdout.includes(Buffer.from("\x1b[?1049h"))).toBe(true);
      expect(stdout.includes(Buffer.from("\x1b[?1049l"))).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "permission prompt growth preserves displaced transcript history",
    async () => {
      const markers = Array.from(
        { length: 34 },
        (_, index) => `APPROVAL_SCROLLBACK_MARKER_${String(index + 1).padStart(2, "0")}`,
      );
      const finalMarker = "generic approval accepted handled";
      const tapeRoot = process.env.FX_RECORD
        ? null
        : mkdtempSync(join(tmpdir(), "fx-accepted-generic-approval-"));
      if (tapeRoot) roots.push(tapeRoot);
      const tapePath = process.env.FX_RECORD ?? join(tapeRoot!, "approval.fxtape");
      const ctx = await launchScenario(
        [
          outerText(markers.join("\n")),
          outerCommandCall(),
          outerText(finalMarker),
        ],
        "input,permission,scroll,frame_diff,frame_commit",
        {
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
        "ask",
        () => "clear",
      );
      await ctx.session.resizeWindow(120, 36);

      await ctx.session.sendText("Seed the approval scrollback fixture.");
      const beforeApproval = await waitForVisibleScrollback(
        ctx.session,
        "complete approval scrollback seed",
        (scrollback) => markers.every((marker) =>
          scrollback.split(marker).length - 1 === 1
        ),
        90_000,
      );
      for (const marker of markers) {
        expect(beforeApproval.split(marker).length - 1).toBe(1);
      }
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendText("Create the generic approval acceptance fixture.");
      const pane = await ctx.session.waitForText(
        "Would you like to run the following command?",
        TIMEOUT,
      );
      expect(pane).toContain("# shell.run profile=user shell=");
      expect(pane).toContain("touch generic-preview-accepted.txt");
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);

      const activeApproval = await waitForVisibleScrollback(
        ctx.session,
        "complete approval scrollback replay",
        (scrollback) => markers.every((marker) =>
          scrollback.split(marker).length - 1 === 1
        ),
        TIMEOUT,
      );
      for (const marker of markers) {
        expect(activeApproval.split(marker).length - 1).toBe(1);
      }
      const promptTraceLines = readTrace(ctx.tracePath).split(/\r?\n/);
      const transitionDiagnostics = promptTraceLines.filter((line) =>
        line.includes("transcript_transition_plan") ||
        line.includes("transcript_anchor_structured_rewrite") ||
        line.includes("[permission]")
      ).slice(-40).join("\n");
      const promptPlanIndex = promptTraceLines.findIndex((line) =>
        line.includes("transcript_transition_plan") &&
        line.includes("replay_displaced_footer_history=true") &&
        /planned_rows=[1-9][0-9]*/.test(line)
      );
      expect(promptPlanIndex, transitionDiagnostics).toBeGreaterThanOrEqual(0);
      const promptCommit = promptTraceLines.slice(promptPlanIndex).find((line) =>
        line.includes("[frame_diff] attempt_result") &&
        /planned_scroll_rows=[1-9][0-9]*/.test(line)
      );
      expect(promptCommit).toMatch(
        /planned_scroll_rows=([1-9][0-9]*) committed_scroll_rows=\1 .*unplanned_scroll_rows=0/,
      );
      expect(ctx.gateway.classifierRequests).toHaveLength(0);
      expect(ctx.gateway.requests).toHaveLength(2);

      await ctx.session.sendLiteralText("1");
      await ctx.session.waitForText(finalMarker, TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(true);
      expect(await ctx.session.capturePane()).not.toContain(APPROVAL_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(3);

      const afterApproval = await waitForVisibleScrollback(
        ctx.session,
        "complete post-approval scrollback",
        (scrollback) => markers.every((marker) =>
          scrollback.split(marker).length - 1 === 1
        ),
        TIMEOUT,
      );
      for (const marker of markers) {
        expect(afterApproval.split(marker).length - 1).toBe(1);
      }

      const stdout = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(stdout.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: ctx.root.workspace,
        env: { HOME: ctx.root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain(finalMarker);
      await assertProcessAliveAndClean(ctx);
    },
    120_000,
  );

  test(
    "amended denial follows its denied result without executing the command",
    async () => {
      const ctx = await openApprovalPrompt("amended generic denial");

      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Down");
      await waitForPaneState(ctx.session, "select generic denial", (value) =>
        hasApprovalSelection(value, 3, COMMAND_NO_CHOICE),
      );
      await ctx.session.sendKeys("Tab");
      await waitForPaneState(ctx.session, "open generic denial amendment", (value) =>
        hasApprovalSelection(value, 3, COMMAND_NO_AMENDMENT),
      );
      await ctx.session.sendLiteralText("inspect the file before changing it");
      const amended = await waitForPaneState(ctx.session, "type generic denial amendment", (value) =>
        hasApprovalSelection(value, 3, "No, inspect the file before changing it"),
      );
      expectApprovalSelection(amended, 3, "No, inspect the file before changing it");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("amended generic denial handled", TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(false);
      expect(ctx.gateway.requests).toHaveLength(2);
      const followup = ctx.gateway.requests[1]!.body;
      expect(requestContainsExactString(
        followup,
        "inspect the file before changing it",
      )).toBe(true);
      expect(followup.indexOf("tool_permission_denied")).toBeLessThan(
        followup.indexOf("inspect the file before changing it"),
      );
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "long approval amendment keeps its tail and cursor visible before exact denial submission",
    async () => {
      const ctx = await launchScenario([
        outerCommandCall(),
        outerText("long approval amendment handled"),
      ]);
      await ctx.session.sendText("Run the generic approval fixture.");
      const initial = await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      expect(initial).toContain("touch generic-preview-accepted.txt");
      await ctx.session.resizeWindow(112, 32);
      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Tab");

      const tailMarker = "TAIL_MARKER_4000";
      const expected = `${"A".repeat(4000)}${tailMarker}`;
      await sendPaste(ctx.session, repeatHex(["41"], 4000));
      await ctx.session.sendLiteralText(tailMarker);
      const amended = await waitForPaneState(
        ctx.session,
        "long approval amendment tail",
        (value) => value.includes(tailMarker),
      );
      expect(amended).toContain(tailMarker);

      const escapes = await ctx.session.capturePaneEscapes();
      const amendmentRow = escapes.split(/\r?\n/).find((line) =>
        visibleText(stripAnsi(line)).includes(tailMarker)
      );
      expect(amendmentRow).toBeDefined();
      expect(amendmentRow).toContain("\x1b[7m ");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("long approval amendment handled", TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(false);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, expected)).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "exact-command option advertises Tab movement before denial amendment",
    async () => {
      const ctx = await openApprovalPrompt("exact-command tab contract");

      await ctx.session.sendKeys("Down");
      let pane = await waitForPaneState(ctx.session, "select exact-command option", (value) =>
        hasApprovalSelection(value, 2, COMMAND_ALWAYS_CHOICE),
      );
      expectApprovalSelection(pane, 2, COMMAND_ALWAYS_CHOICE);
      expect(pane).toContain("Tab Options");
      expect(pane).not.toContain("Tab Amend");

      await ctx.session.sendKeys("Tab");
      pane = await waitForPaneState(ctx.session, "tab to denial", (value) =>
        hasApprovalSelection(value, 3, COMMAND_NO_CHOICE) && value.includes("Tab Amend"),
      );
      expectApprovalSelection(pane, 3, COMMAND_NO_CHOICE);

      await ctx.session.sendKeys("Tab");
      await waitForPaneState(ctx.session, "open denial amendment after navigation", (value) =>
        hasApprovalSelection(value, 3, COMMAND_NO_AMENDMENT),
      );
      await ctx.session.sendLiteralText("use a safer command");
      const amended = await waitForPaneState(ctx.session, "type denial after navigation", (value) =>
        hasApprovalSelection(value, 3, "No, use a safer command"),
      );
      expectApprovalSelection(amended, 3, "No, use a safer command");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("exact-command tab contract handled", TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(false);
      expect(requestContainsExactString(
        ctx.gateway.requests[1]!.body,
        "use a safer command",
      )).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval digit submits immediately before ordinary modal input",
    async () => {
      const ctx = await openApprovalPrompt("approval digits");

      await ctx.session.sendLiteralText("3");
      await ctx.session.waitForText("approval digits handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval raw CSI-u digit tails do not submit",
    async () => {
      const ctx = await openApprovalPrompt("approval raw csi-u");

      const pane = await sendBytesThenTab(
        ctx.session,
        "approval raw csi-u",
        CSI_U_DIGIT_ONE,
        (value) => hasApprovalSelection(value, 1, COMMAND_YES_AMENDMENT),
      );
      expectApprovalSelection(pane, 1, COMMAND_YES_AMENDMENT);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Down");
      await ctx.session.sendLiteralText("3");
      await ctx.session.waitForText("approval raw csi-u handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval fresh ESC restart keeps CSI-u digit tails isolated",
    async () => {
      const ctx = await openApprovalPrompt("approval restarted csi-u");

      const pane = await sendBytesThenTab(
        ctx.session,
        "approval restarted csi-u",
        RESTARTED_CSI_U_DIGIT_ONE,
        (value) => hasApprovalSelection(value, 1, COMMAND_YES_AMENDMENT),
      );
      expectApprovalSelection(pane, 1, COMMAND_YES_AMENDMENT);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Down");
      await ctx.session.sendLiteralText("3");
      await ctx.session.waitForText("approval restarted csi-u handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval ignores encoded digits through resize thrash until a literal digit submits",
    async () => {
      const ctx = await openApprovalPrompt("approval stress");

      for (const [cols, rows] of [[16, 7], [240, 70], [24, 9], [120, 40]] as const) {
        await ctx.session.resizeWindow(cols, rows);
        await assertProcessAliveAndClean(ctx);
      }

      let pane = await waitForPaneState(
        ctx.session,
        "approval after resize churn",
        (value) => hasApprovalSelection(value, 1, COMMAND_YES_CHOICE),
        TIMEOUT,
      );
      expectApprovalSelection(pane, 1, COMMAND_YES_CHOICE);
      expect(ctx.gateway.requests).toHaveLength(1);

      for (let batch = 0; batch < 4; batch += 1) {
        await ctx.session.sendHexBytes(repeatHex(CSI_U_DIGIT_ONE, 32));
      }
      await ctx.session.sendKeys("Tab");
      pane = await waitForPaneState(
        ctx.session,
        "approval repeated csi-u flood",
        (value) => hasApprovalSelection(value, 1, COMMAND_YES_AMENDMENT),
      );
      expectApprovalSelection(pane, 1, COMMAND_YES_AMENDMENT);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Down");
      await ctx.session.sendLiteralText("3");
      await ctx.session.waitForText("approval stress handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "repeated approval and question cycles reset prompt state in one process",
    async () => {
      const cycles = 12;
      const responses: Response[] = [];
      for (let index = 0; index < cycles; index += 1) {
        responses.push(index % 2 === 0 ? outerCommandCall() : outerQuestionCall());
        responses.push(outerText(`decision cycle ${index} handled`));
      }

      const ctx = await launchScenario(responses);
      for (let index = 0; index < cycles; index += 1) {
        const approval = index % 2 === 0;
        await ctx.session.sendText(
          approval
            ? `Run command for cycle ${index}.`
            : `Ask me which path to take for cycle ${index}.`,
        );
        if (approval) {
          await waitForPaneState(
            ctx.session,
            `decision cycle ${index} approval active`,
            (value) => hasApprovalSelection(value, 1, COMMAND_YES_CHOICE),
          );
        } else {
          await waitForQuestionPane(
            ctx.session,
            `decision cycle ${index} question active`,
            (value) => hasQuestionSelection(value, 1, "Inspect repo state"),
            TIMEOUT,
          );
        }
        expect(ctx.gateway.requests).toHaveLength(index * 2 + 1);

        if (approval) {
          await ctx.session.sendLiteralText("3");
        } else {
          await ctx.session.sendLiteralText("2");
        }

        await ctx.session.waitForText(`decision cycle ${index} handled`, TIMEOUT);
        expect(ctx.gateway.requests).toHaveLength(index * 2 + 2);
        await assertProcessAliveAndClean(ctx);
      }
    },
    TIMEOUT * 3,
  );

  test(
    "approval ordinary typing stays modal-owned while Tab still amends",
    async () => {
      const ctx = await openApprovalPrompt("approval typing");

      await ctx.session.sendLiteralText(FORBIDDEN_TYPING);
      const modalPane = await waitForPaneState(ctx.session, "approval ignores ordinary typing", (value) =>
        value.includes(APPROVAL_PROMPT),
      );
      expect(ctx.gateway.requests).toHaveLength(1);
      expectNoForbiddenComposerText(modalPane);

      await ctx.session.sendKeys("Tab");
      await ctx.session.sendLiteralText("summarize the command output");
      const amended = await waitForPaneState(ctx.session, "approval amendment typing", (value) =>
        hasApprovalSelection(value, 1, "Yes, summarize the command output"),
      );
      expectApprovalSelection(amended, 1, "Yes, summarize the command output");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("approval typing handled", TIMEOUT);
      const finalPane = await ctx.session.capturePane();
      expect(finalPane).toContain("summarize the command output");
      const terminalTool = finalPane.indexOf("Ran touch generic-preview-accepted.txt");
      const feedbackCard = finalPane.indexOf("summarize the command output");
      expect(terminalTool).toBeGreaterThanOrEqual(0);
      expect(feedbackCard).toBeGreaterThan(terminalTool);
      expect(requestContainsExactString(
        ctx.gateway.requests[1]!.body,
        "summarize the command output",
      )).toBe(true);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests.some((request) =>
        requestContainsExactString(request.body, FORBIDDEN_TYPING)
      )).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval amendment supports focused editor shortcut alias parity",
    async () => {
      const ctx = await openApprovalPrompt("approval shortcut alias parity");
      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Tab");

      await ctx.session.sendLiteralText("alpha beta gamma");
      await ctx.session.sendHexBytes(["01"]);
      await ctx.session.sendLiteralText("[");
      await ctx.session.sendHexBytes(["05"]);
      await ctx.session.sendLiteralText("]");
      await ctx.session.sendHexBytes(["02"]);
      await ctx.session.sendLiteralText("B");
      await ctx.session.sendHexBytes(["06"]);
      await ctx.session.sendLiteralText("F");
      await waitForPaneState(ctx.session, "approval cursor control aliases", (value) =>
        hasApprovalSelection(value, 3, "No, [alpha beta gammaB]F"),
      );

      await ctx.session.sendHexBytes(["15"]);
      await ctx.session.sendLiteralText("alpha beta gamma");
      await ctx.session.sendHexBytes(["17"]);
      await ctx.session.sendLiteralText("W");
      await waitForPaneState(ctx.session, "approval ctrl-w alias", (value) =>
        hasApprovalSelection(value, 3, "No, alpha beta W"),
      );

      await ctx.session.sendHexBytes(["15"]);
      await ctx.session.sendLiteralText("alpha beta");
      await ctx.session.sendHexBytes(["01", "1b", "64"]);
      await waitForPaneState(ctx.session, "approval alt-d alias", (value) =>
        hasApprovalSelection(value, 3, "No, beta"),
      );
      await ctx.session.sendHexBytes(["05", "1b", "7f"]);
      await waitForPaneState(ctx.session, "approval alt-backspace alias", (value) =>
        hasApprovalSelection(value, 3, "No"),
      );

      await ctx.session.sendLiteralText("left right");
      await ctx.session.sendHexBytes(["01", "06", "0b"]);
      const finalPane = await waitForPaneState(ctx.session, "approval ctrl-k alias", (value) =>
        hasApprovalSelection(value, 3, "No, l"),
      );
      expectApprovalSelection(finalPane, 3, "No, l");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("approval shortcut alias parity handled", TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(false);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, "l")).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval amendment Ctrl+Y cannot yank into the hidden composer",
    async () => {
      const sentinel = "hidden approval kill ring";
      const amendment = "inspect the target before changing it";
      const probe = "approval composer remains isolated";
      const ctx = await launchScenario([
        outerCommandCall(),
        outerText("approval shortcut isolation handled"),
        outerText("approval composer probe handled"),
      ]);

      await primeComposerKillRing(ctx.session, sentinel);
      await ctx.session.sendText("Run the generic approval fixture.");
      await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Down");
      await waitForPaneState(ctx.session, "select denial for shortcut isolation", (value) =>
        hasApprovalSelection(value, 3, COMMAND_NO_CHOICE),
      );
      await ctx.session.sendKeys("Tab");
      await ctx.session.sendLiteralText(amendment);
      await ctx.session.sendHexBytes(["19"]);
      const amended = await waitForPaneState(ctx.session, "approval shortcut isolation", (value) =>
        hasApprovalSelection(value, 3, `No, ${amendment}`),
      );
      expectApprovalSelection(amended, 3, `No, ${amendment}`);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("approval shortcut isolation handled", TIMEOUT);
      expect(existsSync(join(ctx.root.workspace, "generic-preview-accepted.txt"))).toBe(false);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, amendment)).toBe(true);

      await ctx.session.sendText(probe);
      await ctx.session.waitForText("approval composer probe handled", TIMEOUT);
      expect(ctx.gateway.requests).toHaveLength(3);
      expect(requestContainsExactString(ctx.gateway.requests[2]!.body, probe)).toBe(true);
      expect(ctx.gateway.requests.some((request) =>
        requestContainsExactString(request.body, sentinel)
      )).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval amendment accepts bracketed paste without executing early",
    async () => {
      const ctx = await openApprovalPrompt("approval amendment paste");
      const expected = "pasted amendment marker \\x1b[200~[200~[201;1~ tabbed line";
      const payload = concatHex(
        textHex("pasted amendment marker "),
        textHex("\\x1b[200~"),
        PASTE_START,
        ["1b", "5b", "32", "30", "31", "3b", "31", "7e"],
        ["09"],
        textHex("tabbed"),
        ["0d"],
        textHex("line"),
        ["03"],
      );

      await ctx.session.sendKeys("Tab");
      await sendPaste(ctx.session, payload);
      const amended = await waitForPaneState(ctx.session, "approval amendment paste", (value) =>
        hasApprovalSelection(value, 1, `Yes, ${expected}`),
      );
      expectApprovalSelection(amended, 1, `Yes, ${expected}`);
      expectNoForbiddenComposerText(amended);
      expect(ctx.gateway.requests).toHaveLength(1);
      expectNoDropTrace(ctx.tracePath);
      expect(readTrace(ctx.tracePath)).not.toContain("approval amendment paste dropped");

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("approval amendment paste handled", TIMEOUT);
      const finalPane = await ctx.session.capturePane();
      expect(finalPane).toContain(expected);
      expect(finalPane).toContain("Ran touch generic-preview-accepted.txt");
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, expected)).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval prompt discards bracketed paste controls and nested markers",
    async () => {
      const ctx = await openApprovalPrompt("approval paste");
      const payload = decisionPastePayload();

      await sendPaste(ctx.session, payload);
      const pane = await waitForPaneState(ctx.session, "approval paste", (value) =>
        value.includes(APPROVAL_PROMPT),
      );
      expectNoForbiddenComposerText(pane);
      await waitForDropTrace(ctx.tracePath, payload.length, 1);

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("approval paste handled", TIMEOUT);
      expectNoForbiddenComposerText(await ctx.session.capturePane());
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "false paste starts do not pin ownership under approval or question prompts",
    async () => {
      const cases = [
        { kind: "approval", marker: LEADING_ZERO_START, label: "approval leading-zero" },
        { kind: "approval", marker: PARAMETERIZED_START, label: "approval parameterized" },
        { kind: "approval", marker: LONG_PARAMETERIZED_START, label: "approval long-parameterized" },
        { kind: "question", marker: LEADING_ZERO_START, label: "question leading-zero" },
        { kind: "question", marker: PARAMETERIZED_START, label: "question parameterized" },
      ] as const;

      for (const scenario of cases) {
        if (session) {
          await session.kill();
          session = null;
        }
        const ctx = scenario.kind === "approval"
          ? await openApprovalPrompt(scenario.label)
          : await openQuestionPrompt(scenario.label);

        await ctx.session.sendHexBytes(scenario.marker);
        await assertProcessAliveAndClean(ctx);
        const pane = await waitForPaneState(ctx.session, scenario.label, (value) =>
          scenario.kind === "approval"
            ? value.includes(APPROVAL_PROMPT)
            : value.includes(QUESTION_PROMPT),
        );
        if (scenario.kind === "question") await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
        expectNoDropTrace(ctx.tracePath);

        if (scenario.kind === "approval") {
          await resolveApprovalWithDeny(ctx.session);
        } else {
          await resolveQuestionWithSecondOption(ctx.session);
        }
        await ctx.session.waitForText(`${scenario.label} handled`, TIMEOUT);
        await assertProcessAliveAndClean(ctx);
      }
    },
    TIMEOUT * 2,
  );

  test(
    "approval paste start re-synchronizes after an incomplete generic escape prefix",
    async () => {
      const ctx = await openApprovalPrompt("opening resync");

      await ctx.session.sendHexBytes([
        "1b", "5b", "32", "30",
        "1b", "5b", "32", "30", "30", "7e",
        "78",
        "1b", "5b", "32", "30", "31", "7e",
      ]);
      const pane = await waitForPaneState(ctx.session, "opening resync", (value) =>
        value.includes(APPROVAL_PROMPT),
      );
      expectNoForbiddenComposerText(pane);
      await waitForDropTrace(ctx.tracePath, 1, 1);

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("opening resync handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "composer paste start resets pending Ctrl+C and Esc gestures",
    async () => {
      const ctx = await launchScenario([]);

      await ctx.session.sendHexBytes(["03"]);
      let pane = await ctx.session.waitForText(CTRL_C_HINT, TIMEOUT);
      expect(pane).toContain(CTRL_C_HINT);

      await ctx.session.sendHexBytes(PASTE_START);
      pane = await waitForPaneState(ctx.session, "ctrl-c paste reset", (value) =>
        !value.includes(CTRL_C_HINT),
      );
      expect(pane).not.toContain(CTRL_C_HINT);
      await ctx.session.sendHexBytes(PASTE_END);

      await ctx.session.sendHexBytes(["03"]);
      pane = await ctx.session.waitForText(CTRL_C_HINT, TIMEOUT);
      expect(pane).toContain(CTRL_C_HINT);
      await assertProcessAliveAndClean(ctx);

      if (session) {
        await session.kill();
        session = null;
      }

      const escCtx = await launchScenario([]);
      await escCtx.session.sendLiteralText("seed");
      await escCtx.session.waitForText("seed", TIMEOUT);
      await escCtx.session.sendHexBytes(["1b"]);
      pane = await waitForPaneState(escCtx.session, "initial esc clear arm", (value) =>
        value.includes(ESC_HINT),
      );
      expect(pane).toContain(ESC_HINT);
      expect(pane).toContain("seed");

      await escCtx.session.sendHexBytes(PASTE_START);
      pane = await waitForPaneState(escCtx.session, "esc paste start reset", (value) =>
        value.includes("seed") && !value.includes(ESC_HINT),
      );
      expect(pane).toContain("seed");
      expect(pane).not.toContain(ESC_HINT);

      await escCtx.session.sendHexBytes(concatHex(textHex(" plus"), PASTE_END));
      pane = await waitForPaneState(escCtx.session, "esc paste reset", (value) =>
        value.includes("seed plus") && !value.includes(ESC_HINT),
      );
      expect(pane).toContain("seed plus");
      expect(pane).not.toContain(ESC_HINT);
      await waitForInputTrace(escCtx.tracePath, "paste end owner=composer bytes=5");

      await escCtx.session.sendHexBytes(["1b"]);
      pane = await waitForPaneState(escCtx.session, "post-paste esc clear arm", (value) =>
        value.includes(ESC_HINT),
      );
      expect(pane).toContain("seed plus");
      expect(pane).toContain(ESC_HINT);
      await assertProcessAliveAndClean(escCtx);
    },
    90_000,
  );

  test(
    "approval paste closes only on exact end markers at boundary cases",
    async () => {
      const ctx = await openApprovalPrompt("delimiter boundary");
      const longDigits = textHex("9".repeat(80));
      const cases = [
        { label: "incomplete candidate", payload: ["1b", "5b", "32", "30"], bytes: 4 },
        { label: "content esc", payload: ["1b"], bytes: 1 },
        {
          label: "parameterized false end",
          payload: concatHex(["1b", "5b", "32", "30", "31", "3b", "31", "7e"], textHex("q")),
          bytes: 9,
        },
        {
          label: "long numeric payload",
          payload: concatHex(["1b", "5b"], longDigits),
          bytes: 82,
        },
      ] as const;

      for (const row of cases) {
        await sendPaste(ctx.session, row.payload);
        const pane = await waitForPaneState(ctx.session, row.label, (value) =>
          value.includes(APPROVAL_PROMPT),
        );
        expectNoForbiddenComposerText(pane);
        await waitForDropTrace(ctx.tracePath, row.bytes, 1);
        await assertProcessAliveAndClean(ctx);
      }

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("delimiter boundary handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question ordinary typing stays modal-owned while option controls still work",
    async () => {
      const ctx = await openQuestionPrompt("question typing");

      await ctx.session.sendLiteralText(QUESTION_TYPING);
      const pane = await waitForPaneState(ctx.session, "question ignores ordinary typing", (value) =>
        value.includes(QUESTION_PROMPT),
      );
      await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
      expectNoForbiddenComposerText(pane);
      expect(ctx.gateway.requests).toHaveLength(1);

      await resolveQuestionWithSecondOption(ctx.session);
      await ctx.session.waitForText("question typing handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", "Run tests")).toBe(true);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests.some((request) =>
        requestContainsExactString(request.body, QUESTION_TYPING)
      )).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform Ctrl+Y cannot yank into the hidden composer",
    async () => {
      const sentinel = "hidden question kill ring";
      const answer = "verify the focused question editor";
      const probe = "question composer remains isolated";
      const ctx = await launchScenario([
        outerQuestionCall(),
        outerText("question shortcut isolation handled"),
        outerText("question composer probe handled"),
      ]);

      await primeComposerKillRing(ctx.session, sentinel);
      await ctx.session.sendText("Ask me which path to take.");
      await ctx.session.waitForText(QUESTION_PROMPT, TIMEOUT);
      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question shortcut freeform selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );
      await ctx.session.sendLiteralText(answer);
      await ctx.session.sendHexBytes(["19"]);
      await waitForQuestionPane(ctx.session, "question shortcut isolation", (value) =>
        hasQuestionSelection(value, 3, answer),
      );

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question shortcut isolation handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, answer)).toBe(true);

      await ctx.session.sendText(probe);
      await ctx.session.waitForText("question composer probe handled", TIMEOUT);
      expect(ctx.gateway.requests).toHaveLength(3);
      expect(requestContainsExactString(ctx.gateway.requests[2]!.body, probe)).toBe(true);
      expect(ctx.gateway.requests.some((request) =>
        requestContainsExactString(request.body, sentinel)
      )).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform Ctrl+U edits the visible answer without deleting a hidden composer draft",
    async () => {
      await exerciseQuestionHiddenDraftControl({
        controlHex: "15",
        hiddenDraft: "question draft must survive ctrl-u",
        visibleAnswer: "visible ctrl-u answer",
        visibleAnswerAfterControl: "edited ctrl-u answer",
        startPrompt: "Ask a delayed question for ctrl-u.",
        handledMarker: "question ctrl-u isolation handled",
        draftMarker: "question ctrl-u draft handled",
      });
    },
    TIMEOUT,
  );

  test(
    "question freeform supports focused editor shortcut alias parity",
    async () => {
      const ctx = await openQuestionPrompt("question shortcut alias parity");
      await ctx.session.sendLiteralText("3");

      await ctx.session.sendLiteralText("alpha beta gamma");
      await ctx.session.sendHexBytes(["01"]);
      await ctx.session.sendLiteralText("[");
      await ctx.session.sendHexBytes(["05"]);
      await ctx.session.sendLiteralText("]");
      await ctx.session.sendHexBytes(["02"]);
      await ctx.session.sendLiteralText("B");
      await ctx.session.sendHexBytes(["06"]);
      await ctx.session.sendLiteralText("F");
      await waitForQuestionPane(ctx.session, "question cursor control aliases", (value) =>
        hasQuestionSelection(value, 3, "[alpha beta gammaB]F"),
      );

      await ctx.session.sendHexBytes(["15"]);
      await ctx.session.sendLiteralText("alpha beta gamma");
      await ctx.session.sendHexBytes(["17"]);
      await ctx.session.sendLiteralText("W");
      await waitForQuestionPane(ctx.session, "question ctrl-w alias", (value) =>
        hasQuestionSelection(value, 3, "alpha beta W"),
      );

      await ctx.session.sendHexBytes(["15"]);
      await ctx.session.sendLiteralText("alpha beta");
      await ctx.session.sendHexBytes(["01", "1b", "64"]);
      await waitForQuestionPane(ctx.session, "question alt-d alias", (value) =>
        hasQuestionSelection(value, 3, "beta"),
      );
      await ctx.session.sendHexBytes(["05", "1b", "7f"]);
      await waitForQuestionPane(ctx.session, "question alt-backspace alias", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      await ctx.session.sendLiteralText("left right");
      await ctx.session.sendHexBytes(["01", "06", "0b"]);
      await waitForQuestionPane(ctx.session, "question ctrl-k alias", (value) =>
        hasQuestionSelection(value, 3, "l"),
      );

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question shortcut alias parity handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]!.body, "l")).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform Ctrl+P cannot replace a hidden composer draft from history",
    async () => {
      await exerciseQuestionHiddenDraftControl({
        controlHex: "10",
        hiddenDraft: "original hidden question draft",
        visibleAnswer: "visible ctrl-p answer",
        startPrompt: "Ask a delayed question for ctrl-p.",
        handledMarker: "question ctrl-p isolation handled",
        draftMarker: "question ctrl-p draft handled",
      });
    },
    TIMEOUT,
  );

  test(
    "question batch tabs navigate every page and out-of-order answers return to unanswered pages",
    async () => {
      const finalMarker = "question pagination handled";
      const ctx = await launchScenario([
        outerQuestionBatchCall(),
        outerText(finalMarker),
      ]);
      const waitForPage = (ordinal: number, question: string) =>
        waitForPaneState(
          ctx.session,
          `question page ${ordinal} of 3`,
          (value) =>
            value.includes(question) && value.includes(`Question ${ordinal} of 3`),
          TIMEOUT,
        );

      await ctx.session.sendText("Ask the prepared batch of questions.");
      let pane = await waitForPage(1, "Which verification depth should I use?");
      expect(pane).not.toContain("Input needed");
      await expectQuestionSelection(ctx.session, 1, "Thorough");
      expect(pane).not.toContain("Should I push after verification?");

      await ctx.session.sendKeys("Tab");
      pane = await waitForPage(2, "Should I push after verification?");
      expect(pane).not.toContain("Which verification depth should I use?");
      expect(pane).not.toContain("What should I report?");

      await ctx.session.sendKeys("Tab");
      pane = await waitForPage(3, "What should I report?");
      expect(pane).not.toContain("Should I push after verification?");

      await ctx.session.sendKeys("Tab");
      await waitForPage(1, "Which verification depth should I use?");

      await ctx.session.sendKeys("Down");
      await ctx.session.sendKeys("Enter");
      await waitForPage(2, "Should I push after verification?");

      await ctx.session.sendLiteralText("1");
      await waitForPage(3, "What should I report?");

      await ctx.session.sendKeys("Tab");
      await waitForPage(1, "Which verification depth should I use?");

      await ctx.session.sendKeys("Tab");
      await waitForPage(2, "Should I push after verification?");

      await ctx.session.sendKeys("Down");
      await waitForQuestionPane(
        ctx.session,
        "revisited question draft selection",
        (value) => hasQuestionSelection(value, 2, "No"),
      );
      await expectQuestionSelection(ctx.session, 2, "No");

      await ctx.session.sendKeys("Left");
      await waitForPage(1, "Which verification depth should I use?");

      await ctx.session.sendKeys("Tab");
      await waitForPage(2, "Should I push after verification?");
      await waitForQuestionPane(
        ctx.session,
        "backward navigation preserved question draft",
        (value) => hasQuestionSelection(value, 2, "No"),
      );
      await expectQuestionSelection(ctx.session, 2, "No");

      await ctx.session.sendKeys("Enter");
      await waitForPage(3, "What should I report?");

      await ctx.session.sendLiteralText("2");
      await ctx.session.waitForText(finalMarker, TIMEOUT);
      const followup = ctx.gateway.requests[1]?.body ?? "";
      expect(requestContainsExactString(followup, "Focused")).toBe(true);
      expect(requestContainsExactString(followup, "No")).toBe(true);
      expect(requestContainsExactString(followup, "Details")).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "raw Escape cancels a question turn before a new prompt",
    async () => {
      const nextPrompt = "Start a new turn after raw question cancellation.";
      const ctx = await openQuestionPrompt("raw question cancellation completed");

      await ctx.session.sendKeys("Escape");
      const cancelled = await ctx.session.waitForText("■ Cancelled", TIMEOUT);
      expect(countOccurrences(cancelled, "■ Cancelled")).toBe(1);
      expect(cancelled).not.toContain(QUESTION_PROMPT);
      expect(cancelled).not.toContain("raw question cancellation completed");
      const cancelledGrid = await ctx.session.capturePaneGrid();
      const footer = findFooterBlocks(cancelledGrid).at(-1);
      const cancelledRow = cancelledGrid.findIndex((row) => row.includes("■ Cancelled"));
      expect(footer).toBeDefined();
      expect(cancelledRow).toBeGreaterThanOrEqual(0);
      expect(cancelledRow).toBeLessThan(footer!.topDivider);
      const gapRows = cancelledGrid.slice(cancelledRow + 1, footer!.topDivider);
      expect(gapRows.length).toBeGreaterThanOrEqual(1);
      expect(gapRows.every((row) => row.trim() === "")).toBe(true);

      await ctx.session.sendText(nextPrompt);
      const pane = await ctx.session.waitForText("raw question cancellation completed", TIMEOUT);

      expect(pane).not.toContain(QUESTION_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", nextPrompt)).toBe(true);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", "(user cancelled the question)")).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "resized question cancellation keeps the footer bottom anchored through the first edit",
    async () => {
      const ctx = await launchScenario(
        [
          outerText("Prior turn completed."),
          outerQuestionCall(),
          outerText("resized question cancellation anchoring handled"),
        ],
      );
      await ctx.session.resizeWindow(120, 36);
      await ctx.session.sendText("Complete a harmless prior turn.");
      await ctx.session.waitForText("Prior turn completed.", TIMEOUT);
      await ctx.session.sendText(
        "Use the question tool to ask me which harmless label I prefer, with choices Alpha and Beta, and wait for my answer. Do not use any other tool.",
      );
      await ctx.session.waitForText(QUESTION_PROMPT, TIMEOUT);
      await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
      await ctx.session.resizeWindow(60, 12);
      await waitForQuestionPane(
        ctx.session,
        "resized question prompt",
        (value) =>
          value.includes(QUESTION_PROMPT) &&
          hasQuestionSelection(value, 1, "Inspect repo state"),
      );

      await ctx.session.sendKeys("Escape");
      const cancelledGrid = await waitForGridState(
        ctx.session,
        "bottom-anchored question cancellation",
        (grid) => {
          const footer = findFooterBlocks(grid).at(-1);
          return (
            grid.some((row) => row.includes("■ Cancelled")) &&
            footer?.bottomDivider === grid.length - 2
          );
        },
      );
      const cancelledFooter = findFooterBlocks(cancelledGrid).at(-1);
      const cancelledRow = cancelledGrid.findIndex((row) => row.includes("■ Cancelled"));
      expect(cancelledFooter).toBeDefined();
      expect(cancelledRow).toBeGreaterThanOrEqual(0);
      expect(cancelledRow).toBeLessThan(cancelledFooter!.topDivider);
      expect(
        cancelledGrid
          .slice(cancelledRow + 1, cancelledFooter!.topDivider)
          .every((row) => row.trim() === ""),
      ).toBe(true);

      await ctx.session.sendLiteralText("x");
      const editedGrid = await waitForGridState(
        ctx.session,
        "bottom-anchored question cancellation after edit",
        (grid) => {
          const footer = findFooterBlocks(grid).at(-1);
          return (
            currentFooterText(grid).includes("x") &&
            footer?.bottomDivider === grid.length - 2
          );
        },
      );
      const editedFooter = findFooterBlocks(editedGrid).at(-1);
      expect(editedFooter).toEqual(cancelledFooter);
      expect(countOccurrences(editedGrid.join("\n"), "■ Cancelled")).toBe(1);
      expect(editedGrid.join("\n")).not.toContain(QUESTION_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(2);
      await assertProcessAliveAndClean(ctx);
    },
    90_000,
  );

  test(
    "kitty Escape cancels a question turn before a new prompt",
    async () => {
      const nextPrompt = "Start a new turn after kitty question cancellation.";
      const ctx = await openQuestionPrompt("kitty question cancellation completed");

      await ctx.session.sendHexBytes(CSI_U_ESCAPE);
      const cancelled = await ctx.session.waitForText("■ Cancelled", TIMEOUT);
      expect(countOccurrences(cancelled, "■ Cancelled")).toBe(1);
      expect(cancelled).not.toContain(QUESTION_PROMPT);
      expect(cancelled).not.toContain("kitty question cancellation completed");

      await ctx.session.sendText(nextPrompt);
      const pane = await ctx.session.waitForText("kitty question cancellation completed", TIMEOUT);

      expect(pane).not.toContain(QUESTION_PROMPT);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", nextPrompt)).toBe(true);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", "(user cancelled the question)")).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question digit submits the selected label without Enter",
    async () => {
      const ctx = await openQuestionPrompt("question digits");

      await ctx.session.sendLiteralText("2");
      await ctx.session.waitForText("question digits handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", "Run tests")).toBe(true);
      expect(currentFooterText(await ctx.session.capturePaneGrid())).not.toContain(QUESTION_PROMPT);
      const scrollback = visibleText(await ctx.session.captureFullScrollbackEscapes());
      expect(scrollback).toContain(visibleText(`1) ${QUESTION_PROMPT}`));
      expect(scrollback).toContain(visibleText("Run tests"));
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform ordinal keeps following digits as text",
    async () => {
      const ctx = await openQuestionPrompt("question freeform digits");

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question freeform selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );
      await ctx.session.sendLiteralText("42");
      const pane = await waitForQuestionPane(ctx.session, "question freeform digits", (value) =>
        hasQuestionSelection(value, 3, "42"),
      );
      await expectQuestionSelection(ctx.session, 3, "42");
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform digits handled", TIMEOUT);
      const body = ctx.gateway.requests[1]?.body ?? "";
      expect(requestContainsExactString(body, "42")).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "long question content wraps onto aligned continuation rows",
    async () => {
      const finalMarker = "long question answer handled";
      const ctx = await launchScenario([
        outerLongQuestionAnswerCall(),
        outerText(finalMarker),
      ]);
      await ctx.session.resizeWindow(80, 24);

      await ctx.session.sendText("Ask the prepared question.");
      const pane = await waitForPaneState(
        ctx.session,
        "long question content wrapped rows",
        (value) =>
          value.includes("remain fully visible even when it wraps.") &&
          value.includes("verification suite before") &&
          value.includes("pushing this branch") &&
          value.includes("when it wraps across several terminal rows"),
      );
      const questionContinuation = pane
        .split("\n")
        .find((line) => line.includes("remain fully visible even when it wraps."));
      const questionLead = pane
        .split("\n")
        .find((line) => line.includes("When you ask fx to ask a question"));
      const labelContinuation = pane
        .split("\n")
        .find((line) => line.includes("verification suite before"));
      const labelLead = pane
        .split("\n")
        .find((line) => line.includes("Run the complete"));
      const descriptionContinuation = pane
        .split("\n")
        .find((line) => line.includes("when it wraps across several terminal rows"));
      const descriptionLead = pane
        .split("\n")
        .find((line) => line.includes("Keep the entire explanation"));
      expect(questionContinuation?.indexOf("remain fully visible even when it wraps.")).toBe(
        questionLead?.indexOf("When you ask fx to ask a question"),
      );
      expect(labelContinuation?.indexOf("verification suite before")).toBe(
        labelLead?.indexOf("Run the complete"),
      );
      expect(descriptionContinuation?.indexOf("when it wraps across several terminal rows")).toBe(
        descriptionLead?.indexOf("Keep the entire explanation"),
      );
      expect(pane).not.toContain("question text must remain fully…");
      expect(pane).not.toContain("Run the complete verification…");
      expect(pane).not.toContain("Keep the entire explanation visible even…");

      await ctx.session.sendLiteralText("1");
      await ctx.session.waitForText(finalMarker, TIMEOUT);
      expect(
        requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", LONG_QUESTION_ANSWER),
      ).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform answer wraps onto continuation rows as it grows",
    async () => {
      const ctx = await openQuestionPrompt("question freeform wraps");
      await ctx.session.resizeWindow(48, 20);

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question freeform wrap selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      const answer =
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789wraps-below";
      await ctx.session.sendLiteralText(answer);
      const pane = await waitForPaneState(
        ctx.session,
        "question freeform wrapped rows",
        (value) => visibleText(value).includes(answer),
      );
      expect(visibleText(pane)).toContain(answer);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform wraps handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", answer)).toBe(true);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform hint keeps enter and esc guidance at 72x16",
    async () => {
      const ctx = await openQuestionPrompt("question freeform narrow hint");

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question freeform hint selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );
      await ctx.session.sendLiteralText("Canary");
      await ctx.session.resizeWindow(72, 16);

      const pane = await waitForPaneState(
        ctx.session,
        "question freeform narrow hint",
        (value) => value.includes("Shift+↑↓ Options"),
      );
      expect(pane).toContain(
        "↑↓ Cursor · Shift+↑↓ Options · Tab Questions · Enter Answer · Esc Cancel",
      );
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform narrow hint handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "approval hint keeps enter and esc guidance at 60x12",
    async () => {
      const ctx = await launchScenario([
        outerCommandCall(),
        outerText("approval narrow hint handled"),
      ]);
      await ctx.session.sendText("Run the marker command.");
      await ctx.session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      await ctx.session.resizeWindow(60, 12);

      const pane = await waitForPaneState(
        ctx.session,
        "approval narrow hint",
        (value) => value.includes("Enter Confirm    Esc Cancel"),
      );
      expect(pane).toContain("1–3 Choose now    Enter Confirm    Esc Cancel");

      await resolveApprovalWithDeny(ctx.session);
      await ctx.session.waitForText("approval narrow hint handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform accepts Cmd-V bracketed paste with newlines",
    async () => {
      const ctx = await openQuestionPrompt("question freeform paste");
      await ctx.session.resizeWindow(64, 20);

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question freeform paste selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      const first = "pasted with cmd-v";
      const second = "and this stays on the next line";
      const answer = `${first}\n${second}`;
      await sendPaste(ctx.session, concatHex(textHex(first), ["0a"], textHex(second)));

      const pane = await waitForPaneState(
        ctx.session,
        "question freeform pasted text",
        (value) => value.includes(first) && value.includes(second),
      );
      expect(pane).toContain(first);
      expect(pane).toContain(second);
      expectNoDropTrace(ctx.tracePath);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform paste handled", TIMEOUT);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", answer)).toBe(true);
      const scrollback = visibleText(stripAnsi(
        await ctx.session.captureFullScrollbackEscapes(),
      ));
      expect(scrollback).toContain(visibleText(`1) ${QUESTION_PROMPT}`));
      expect(scrollback).toContain(visibleText(first));
      expect(scrollback).toContain(visibleText(second));
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "plain arrows edit multiline freeform answers while modified arrows choose options",
    async () => {
      const ctx = await openQuestionPrompt("question freeform vertical movement");
      await ctx.session.resizeWindow(64, 20);

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question multiline selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      const pasted = "line-one\nxy\nline-three";
      await sendPaste(ctx.session, concatHex(textHex("line-one"), ["0a"], textHex("xy"), ["0a"], textHex("line-three")));
      await waitForPaneState(ctx.session, "question multiline pasted", (value) =>
        value.includes("line-one") && value.includes("line-three"),
      );

      await ctx.session.sendKeys("Up");
      await ctx.session.sendLiteralText("!");
      const edited = await waitForQuestionPane(ctx.session, "question multiline edited", (value) =>
        hasQuestionSelection(value, 3, "") && stripAnsi(value).includes("xy!"),
      );
      expect(edited).toContain("line-three");
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendHexBytes(["1b", "5b", "31", "3b", "32", "41"]);
      const predefined = await waitForQuestionPane(ctx.session, "question modified up", (value) =>
        hasQuestionSelection(value, 2, "Run tests"),
      );
      const answerColumns = ["line-one", "xy!", "line-three"].map((text) => {
        const line = predefined.split("\n").find((candidate) =>
          stripAnsi(candidate).includes(text)
        );
        return line ? stripAnsi(line).indexOf(text) : -1;
      });
      expect(answerColumns[0]).toBeGreaterThanOrEqual(0);
      expect(answerColumns[1]).toBe(answerColumns[0]);
      expect(answerColumns[2]).toBe(answerColumns[0]);

      await ctx.session.sendHexBytes(["1b", "5b", "31", "3b", "32", "42"]);
      await waitForQuestionPane(ctx.session, "question modified down", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform vertical movement handled", TIMEOUT);
      const answer = "line-one\nxy!\nline-three";
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", answer)).toBe(true);
      expect(requestContainsExactString(ctx.gateway.requests[1]?.body ?? "", pasted)).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question raw CSI-u digit tails do not select",
    async () => {
      const ctx = await openQuestionPrompt("question raw csi-u");
      await ctx.session.sendHexBytes(CSI_U_DIGIT_ONE);
      let pane = await waitForQuestionPane(
        ctx.session,
        "question raw csi-u",
        (value) => hasQuestionSelection(value, 1, "Inspect repo state"),
      );
      await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Down");
      pane = await waitForQuestionPane(ctx.session, "question raw down", (value) =>
        hasQuestionSelection(value, 2, "Run tests"),
      );
      await expectQuestionSelection(ctx.session, 2, "Run tests");
      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question raw csi-u handled", TIMEOUT);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question raw CSI-u digit tails do not type into freeform",
    async () => {
      const ctx = await openQuestionPrompt("question freeform raw csi-u");
      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question freeform raw selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      await ctx.session.sendHexBytes(CSI_U_DIGIT_ONE);
      await ctx.session.sendLiteralText("x");
      const pane = await waitForQuestionPane(ctx.session, "question freeform raw text", (value) =>
        hasQuestionSelection(value, 3, "x"),
      );
      await expectQuestionSelection(ctx.session, 3, "x");
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform raw csi-u handled", TIMEOUT);
      const body = ctx.gateway.requests[1]?.body ?? "";
      expect(requestContainsExactString(body, "x")).toBe(true);
      expect(requestContainsExactString(body, "1x")).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question freeform survives large paste escape and cursor-edit thrash",
    async () => {
      const ctx = await openQuestionPrompt("question freeform stress");
      const paste_flood = "9".repeat(8192);
      const typed = "0123456789".repeat(128);

      await ctx.session.sendLiteralText("3");
      await waitForQuestionPane(ctx.session, "question stress freeform selected", (value) =>
        hasQuestionSelection(value, 3, ""),
      );

      await ctx.session.sendHexBytes(repeatHex(CSI_U_DIGIT_ONE, 128));
      await ctx.session.sendHexBytes(PASTE_START);
      await ctx.session.sendLiteralText(paste_flood);
      await ctx.session.sendHexBytes(PASTE_END);
      await waitForFreeformLimitTrace(ctx.tracePath, paste_flood.length);
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendLiteralText(typed);
      await ctx.session.sendHexBytes(repeatHex(["1b", "5b", "44"], 32));
      await ctx.session.sendHexBytes(repeatHex(["7f"], 16));
      await ctx.session.sendLiteralText("42");
      expect(ctx.gateway.requests).toHaveLength(1);

      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("question freeform stress handled", TIMEOUT);

      const expected = `${typed.slice(0, typed.length - 48)}42${typed.slice(typed.length - 32)}`;
      const body = ctx.gateway.requests[1]?.body ?? "";
      expect(requestContainsExactString(body, expected)).toBe(true);
      expect(requestContainsExactString(body, paste_flood)).toBe(false);
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );

  test(
    "question prompt discards pasted controls without freeform or composer leaks",
    async () => {
      const ctx = await openQuestionPrompt("question paste");
      const payload = decisionPastePayload();

      await sendPaste(ctx.session, payload);
      const pane = await waitForPaneState(ctx.session, "question paste", (value) =>
        value.includes(QUESTION_PROMPT),
      );
      await expectQuestionSelection(ctx.session, 1, "Inspect repo state");
      expectNoForbiddenComposerText(pane);
      await waitForDropTrace(ctx.tracePath, payload.length, 1);

      await resolveQuestionWithSecondOption(ctx.session);
      await ctx.session.waitForText("question paste handled", TIMEOUT);
      expect(ctx.gateway.requests[1]?.body ?? "").toContain("Run tests");
      const finalGrid = await ctx.session.capturePaneGrid();
      expect(currentFooterText(finalGrid)).not.toContain("yp123 hjkl");
      await assertProcessAliveAndClean(ctx);
    },
    TIMEOUT,
  );
});
