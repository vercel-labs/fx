import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT } from "../evals/eval-helpers";
import {
  AUTO_DUAL_SEARCH_SERIALIZED_TOOL_NAMES,
  AUTO_PERPLEXITY_SERIALIZED_TOOL_NAMES,
  customProviderGuidanceState,
  findUnavailableCapabilityReferences,
  parseGatewayRequest,
  serializedToolNames,
  toolShapesWithoutDescriptions,
  WEB_SEARCH_GUIDANCE,
  contentText,
} from "./conditional-guidance-oracle";
import {
  classifierEvidenceFromRequest,
  composerContains,
  fakeGatewayFinalText,
  fakeGatewaySerializedToolCall,
  fakeGatewaySse,
  fakeGatewayToolCall,
  hasEmptyComposer,
  isEmptyComposerLine,
  isComposerLine,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  type FakeGatewayModel,
  type FakeGatewayResponse,
  tmuxAvailable,
} from "./tmux-helpers";
import { expectPermissionModeContext } from "./permission-mode-context";
import { readTapeFrames, stdoutFrames } from "./render-lab/tape";

const MODEL = "openai/gpt-5.5";
const GLM_MODEL = "zai/glm-5.2";
const TURN_SUMMARY_WITH_TOKENS =
  /^ {2}(?:\d+s|\d+m \d+s|\d+h \d{2}m) \(↑\d+(?:\.\d)?k? ↓\d+(?:\.\d)?k?\)$/m;
const TIMEOUT = 30_000;
const SPLIT_BOUNDARY_WAIT_TIMEOUT = TIMEOUT * 3;
const SPLIT_BOUNDARY_TEST_TIMEOUT = SPLIT_BOUNDARY_WAIT_TIMEOUT + 5_000;
const CANONICAL_PRE_TOOL_TEXT =
  "FX_MODEL_TEXT_SENTINEL before tools must remain contiguous.";
const CANONICAL_FINAL_TEXT = "FX_FINAL_RESPONSE_SENTINEL completed.";
const CANONICAL_READ_PATH = "alpha-FX_PATH_SENTINEL.txt";
const CANONICAL_GREP_PATTERN = "FX_PATTERN_SENTINEL";
const APPROVAL_PROMPT = "Would you like to allow this action?";
const SPLIT_NEW_USER_PROMPT = "SPLIT_NEW_USER_PROMPT";
const SPLIT_OLD_SENTINELS = [
  "SPLIT_OLD_HEAD",
  ...Array.from(
    { length: 250 },
    (_, index) => `SPLIT_OLD_TAIL_${index.toString().padStart(3, "0")}`,
  ),
  "SPLIT_OLD_TAIL_FINAL",
];
const SPLIT_OLD_RESPONSE = SPLIT_OLD_SENTINELS
  .map((sentinel) => `${sentinel} ${"paced assistant text ".repeat(12)}\n`)
  .join("");
if (Buffer.byteLength(SPLIT_OLD_RESPONSE) < 30 * 1024) {
  throw new Error("split fixture must exceed 30 KiB");
}
const CANONICAL_A_B_SSE =
  'data: {"type":"text-start","id":"text_before"}\n\n' +
  `data: ${JSON.stringify({
    type: "text-delta",
    id: "text_before",
    delta: CANONICAL_PRE_TOOL_TEXT,
  })}\n\n` +
  'data: {"type":"text-end","id":"text_before"}\n\n' +
  'data: {"type":"tool-input-start","id":"read_a","toolName":"read_file"}\n\n' +
  'data: {"type":"tool-input-delta","id":"read_a","delta":"{\\"path\\":\\"alpha-FX_PATH_SENTINEL"}\n\n' +
  'data: {"type":"tool-input-start","id":"grep_b","toolName":"grep_files"}\n\n' +
  'data: {"type":"tool-input-delta","id":"grep_b","delta":"{\\"pattern\\":\\"FX_PATTERN_SENTINEL\\",\\"path\\":\\""}\n\n' +
  'data: {"type":"tool-input-delta","id":"read_a","delta":".txt\\"}"}\n\n' +
  'data: {"type":"tool-input-end","id":"read_a"}\n\n' +
  `data: ${JSON.stringify({
    type: "tool-call",
    toolCallId: "read_a",
    toolName: "read_file",
    input: { path: CANONICAL_READ_PATH },
  })}\n\n` +
  'data: {"type":"tool-input-delta","id":"grep_b","delta":".\\"}"}\n\n' +
  'data: {"type":"tool-input-end","id":"grep_b"}\n\n' +
  `data: ${JSON.stringify({
    type: "tool-call",
    toolCallId: "grep_b",
    toolName: "grep_files",
    input: { pattern: CANONICAL_GREP_PATTERN, path: "." },
  })}\n\n` +
  'data: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"},"usage":{"inputTokens":{"total":11},"outputTokens":{"total":17}}}\n\n' +
  "data: [DONE]\n\n";
const CANONICAL_A_B_SHA256 =
  "15b963713444428d1548b060b5ee883a209f7cea43ff80e0fdaa33a98b41e34e";

type LifecycleStage =
  | "baseline-silent"
  | "fatal-reported"
  | "correlation-corrected"
  | "corrected";
type GatewayHandle = { stop(): void };
type HeldModelsGateway = GatewayHandle & {
  readonly modelsUrl: string;
  requestCount(): number;
  release(): void;
};

let session: TmuxSession | null = null;
let gateway: GatewayHandle | null = null;
let root: string | null = null;
let artifactRoot: string | null = null;
let preserveArtifacts = false;

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  if (root) {
    rmSync(root, { recursive: true, force: true });
    root = null;
  }
  if (artifactRoot && !preserveArtifacts) {
    rmSync(artifactRoot, { recursive: true, force: true });
  }
  artifactRoot = null;
  preserveArtifacts = false;
});

function missingFinishResponse() {
  return new Response(
    'data: {"type":"tool-input-start","id":"read_1","toolName":"read_file"}\n\n' +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function lengthLimitedCommandResponse(command: string) {
  return new Response(
    'data: {"type":"text-delta","id":"answer_1","delta":"TUI partial output"}\n\n' +
      'data: {"type":"tool-input-start","id":"command_provisional","toolName":"terminal"}\n\n' +
      `data: ${JSON.stringify({
        type: "tool-call",
        toolCallId: "command_final",
        toolName: "terminal",
        input: { action: "exec", command },
      })}\n\n` +
      'data: {"type":"finish","finishReason":{"unified":"length","raw":"length"}}\n\n' +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function providerErrorResponse(detail = "route temporarily unavailable"): Response {
  return fakeGatewaySse([
    {
      type: "error",
      error: { code: "provider_error", message: detail },
    },
    {
      type: "finish",
      finishReason: { unified: "error", raw: "provider_error" },
      usage: {
        inputTokens: { total: 1 },
        outputTokens: { total: 1 },
      },
    },
  ]);
}

function hasEmptyStandaloneAssistant(body: string): boolean {
  const request = JSON.parse(body) as {
    prompt?: Array<{ role?: unknown; content?: unknown }>;
  };
  return (request.prompt ?? []).some((message) =>
    message.role === "assistant" &&
    (message.content === "" ||
      message.content == null ||
      (Array.isArray(message.content) && message.content.length === 0))
  );
}

function restrictedProviderResponse(): Response {
  const message =
    "Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer";
  return new Response(
    JSON.stringify({
      error: {
        message,
        type: "no_providers_available",
        param: { name: "RestrictedProvidersError", message },
      },
    }),
    {
      status: 403,
      headers: { "content-type": "application/json" },
    },
  );
}

function contentFilterResponse(): Response {
  return fakeGatewaySse([
    {
      type: "finish",
      finishReason: { unified: "content-filter", raw: "content_filter" },
    },
  ]);
}

function providerErrorAfterTextResponse(): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: "partial unsafe output" },
    {
      type: "finish",
      finishReason: { unified: "error", raw: "provider_error" },
    },
  ]);
}

function providerErrorAfterToolStartResponse(): Response {
  return fakeGatewaySse([
    { type: "tool-input-start", id: "read_1", toolName: "read_file" },
    {
      type: "finish",
      finishReason: { unified: "error", raw: "provider_error" },
    },
  ]);
}

function retryAfterUnavailable(seconds: number): Response {
  return new Response(
    JSON.stringify({ error: { message: "provider temporarily unavailable" } }),
    {
      status: 503,
      headers: {
        "content-type": "application/json",
        "retry-after": String(seconds),
      },
    },
  );
}

function partialEofResponse(text: string): Response {
  return new Response(
    `data: ${JSON.stringify({
      type: "text-delta",
      id: "answer_1",
      delta: text,
    })}\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function startGateway(response: () => Response) {
  return startDynamicFakeGateway(response, {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
}

function startHeldModelsGateway(
  models: FakeGatewayModel[] = [
    { id: MODEL, type: "language", tags: ["tool-use"] },
  ],
): HeldModelsGateway {
  let requestCount = 0;
  let released = false;
  let resolveRelease: (() => void) | null = null;
  const releasePromise = new Promise<void>((resolve) => {
    resolveRelease = resolve;
  });
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method !== "GET" || url.pathname !== "/v1/models") {
        return new Response("not found", { status: 404 });
      }
      requestCount += 1;
      await releasePromise;
      return Response.json({ data: models });
    },
  });

  return {
    modelsUrl: `http://127.0.0.1:${server.port}/v1/models`,
    requestCount: () => requestCount,
    release() {
      if (released) return;
      released = true;
      resolveRelease?.();
    },
    stop() {
      resolveRelease?.();
      server.stop(true);
    },
  };
}

type HoldState = {
  started: boolean;
  cancelled: boolean;
  release?: () => void;
};

type TokenProgressHoldState = HoldState & {
  sendContent?: () => void;
  sendMoreContent?: () => void;
  finish?: () => void;
};

type ToolPayloadHoldState = HoldState & {
  sendMoreInput?: () => void;
  finish?: () => void;
};

function streamingOutputTokens(scrollback: string): number | null {
  const matches = [...scrollback.matchAll(
    /^  \(↑\d+(?:\.\d)?k? ↓(\d+(?:\.\d)?k?)\)$/gm,
  )];
  const value = matches.at(-1)?.[1];
  if (!value) return null;
  return value.endsWith("k")
    ? Number.parseFloat(value.slice(0, -1)) * 1000
    : Number.parseFloat(value);
}

function quietToolPayloadOutputTokens(scrollback: string): number | null {
  const matches = [...scrollback.matchAll(
    /^•(?: \(\d+s\))? \(↑\d+(?:\.\d)?k? ↓(\d+(?:\.\d)?k?)\)$/gm,
  )];
  const value = matches.at(-1)?.[1];
  if (!value) return null;
  return value.endsWith("k")
    ? Number.parseFloat(value.slice(0, -1)) * 1000
    : Number.parseFloat(value);
}

function heldGatewayResponse(
  state: HoldState,
  initialEvents: Record<string, unknown>[] = [],
  releaseEvents?: Record<string, unknown>[],
): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        for (const event of initialEvents) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
        }
        const keepAlive = () => {
          if (!closed) controller.enqueue(encoder.encode(": hold-active-turn\n\n"));
        };
        keepAlive();
        timer = setInterval(keepAlive, 50);
        if (releaseEvents) {
          state.release = () => {
            if (closed) return;
            closed = true;
            if (timer) clearInterval(timer);
            for (const event of releaseEvents) {
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(event)}\n\n`),
              );
            }
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          };
        }
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function stagedTokenProgressResponse(
  state: TokenProgressHoldState,
  reasoning: string,
  content: string,
): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  let firstContentSent = false;
  let allContentSent = false;
  const split = Math.floor(content.length / 2);
  const send = (
    controller: ReadableStreamDefaultController<Uint8Array>,
    event: object,
  ) => {
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
  };
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        send(controller, { type: "reasoning-start", id: "reasoning_1" });
        send(controller, {
          type: "reasoning-delta",
          id: "reasoning_1",
          delta: reasoning,
        });
        timer = setInterval(() => {
          if (!closed) controller.enqueue(encoder.encode(": hold-token-progress\n\n"));
        }, 50);
        state.sendContent = () => {
          if (closed || firstContentSent) return;
          firstContentSent = true;
          send(controller, { type: "reasoning-end", id: "reasoning_1" });
          send(controller, { type: "text-start", id: "answer_1" });
          send(controller, {
            type: "text-delta",
            id: "answer_1",
            delta: content.slice(0, split),
          });
        };
        state.sendMoreContent = () => {
          if (closed || !firstContentSent || allContentSent) return;
          allContentSent = true;
          send(controller, {
            type: "text-delta",
            id: "answer_1",
            delta: content.slice(split),
          });
        };
        state.finish = () => {
          if (closed || !allContentSent) return;
          closed = true;
          if (timer) clearInterval(timer);
          send(controller, { type: "text-end", id: "answer_1" });
          send(controller, {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 50_000 },
              outputTokens: { total: 20_000 },
            },
          });
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        };
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function stagedToolPayloadResponse(
  state: ToolPayloadHoldState,
  assistantText: string,
  path: string,
  content: string,
): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  let moreInputSent = false;
  const input = JSON.stringify({ path, content });
  const split = Math.floor(input.length / 2);
  const send = (
    controller: ReadableStreamDefaultController<Uint8Array>,
    event: object,
  ) => {
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
  };
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        send(controller, { type: "text-start", id: "answer_1" });
        send(controller, {
          type: "text-delta",
          id: "answer_1",
          delta: assistantText,
        });
        send(controller, { type: "text-end", id: "answer_1" });
        send(controller, {
          type: "tool-input-start",
          id: "write_payload",
          toolName: "write_file",
        });
        send(controller, {
          type: "tool-input-delta",
          id: "write_payload",
          delta: input.slice(0, split),
        });
        timer = setInterval(() => {
          if (!closed) controller.enqueue(encoder.encode(": hold-tool-payload\n\n"));
        }, 50);
        state.sendMoreInput = () => {
          if (closed || moreInputSent) return;
          moreInputSent = true;
          send(controller, {
            type: "tool-input-delta",
            id: "write_payload",
            delta: input.slice(split),
          });
        };
        state.finish = () => {
          if (closed || !moreInputSent) return;
          closed = true;
          if (timer) clearInterval(timer);
          send(controller, { type: "tool-input-end", id: "write_payload" });
          send(controller, {
            type: "tool-call",
            toolCallId: "write_payload",
            toolName: "write_file",
            input: { path, content },
          });
          send(controller, {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
            usage: {
              inputTokens: { total: 8 },
              outputTokens: { total: 4_096 },
            },
          });
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        };
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function fakeGatewayFinalTextWithUsage(
  text: string,
  inputTokens: number,
  outputTokens: number,
): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: inputTokens },
        outputTokens: { total: outputTokens },
      },
    },
  ]);
}

function splitHeldTextResponse(
  state: HoldState,
  before: string,
  after: string,
): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  const send = (controller: ReadableStreamDefaultController<Uint8Array>, event: object) => {
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
  };
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        send(controller, { type: "text-start", id: "answer_1" });
        send(controller, { type: "text-delta", id: "answer_1", delta: before });
        const keepAlive = () => {
          if (!closed) controller.enqueue(encoder.encode(": hold-split-turn\n\n"));
        };
        timer = setInterval(keepAlive, 50);
        state.release = () => {
          if (closed) return;
          closed = true;
          if (timer) clearInterval(timer);
          send(controller, { type: "text-delta", id: "answer_1", delta: after });
          send(controller, { type: "text-end", id: "answer_1" });
          send(controller, {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
          });
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        };
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function duplicateKeyToolResponse(): Response {
  return fakeGatewaySse([
    { type: "tool-input-start", id: "queued_duplicate_list", toolName: "list_files" },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: '{"' },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: "dept" },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: 'h"' },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: ":1" },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: ', "' },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: "dept" },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: 'h"' },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: ":2" },
    { type: "tool-input-delta", id: "queued_duplicate_list", delta: "}" },
    { type: "tool-input-end", id: "queued_duplicate_list" },
    {
      type: "tool-call",
      toolCallId: "queued_duplicate_list",
      toolName: "list_files",
      input: '{"depth":1, "depth":2}',
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

async function waitForCondition(
  predicate: () => boolean,
  description: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function waitForCursorRow(
  session: TmuxSession,
  text: string,
  description: string,
  timeoutMs = TIMEOUT,
): Promise<{ cursor: { row: number; col: number }; grid: string[] }> {
  const started = Date.now();
  let cursor = session.cursorPosition();
  let grid: string[] = [];
  while (Date.now() - started < timeoutMs) {
    const before = session.cursorPosition();
    grid = await session.capturePaneGrid();
    cursor = session.cursorPosition();
    if (
      before.row === cursor.row &&
      before.col === cursor.col &&
      grid[cursor.row]?.includes(text)
    ) {
      return { cursor, grid };
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `timed out waiting for ${description}; cursor=${JSON.stringify(cursor)}\n${grid.join("\n")}`,
  );
}

async function waitForEscapedScrollback(
  session: TmuxSession,
  predicate: (scrollback: string) => boolean,
  description: string,
  timeoutMs = TIMEOUT,
): Promise<string> {
  const started = Date.now();
  let lastScrollback = "";
  while (Date.now() - started < timeoutMs) {
    const scrollback = await session.captureFullScrollbackEscapes();
    if (scrollback.length > 0 || lastScrollback.length === 0) {
      lastScrollback = scrollback;
    }
    if (predicate(scrollback)) return scrollback;
    await Bun.sleep(25);
  }
  throw new Error(
    `timed out waiting for ${description}.\nLast escaped scrollback:\n${lastScrollback}`,
  );
}

async function waitForScrollback(
  session: TmuxSession,
  predicate: (scrollback: string) => boolean,
  description: string,
  timeoutMs = TIMEOUT,
): Promise<string> {
  const started = Date.now();
  let lastScrollback = "";
  while (Date.now() - started < timeoutMs) {
    lastScrollback = await session.captureFullScrollback();
    if (predicate(lastScrollback)) return lastScrollback;
    await Bun.sleep(25);
  }
  throw new Error(
    `timed out waiting for ${description}.\nLast scrollback:\n${lastScrollback}`,
  );
}

function lifecycleStage(): LifecycleStage {
  const value = process.env.FX_LIFECYCLE_STAGE ?? "corrected";
  if (
    value !== "baseline-silent" &&
    value !== "fatal-reported" &&
    value !== "correlation-corrected" &&
    value !== "corrected"
  ) {
    throw new Error(`invalid FX_LIFECYCLE_STAGE: ${JSON.stringify(value)}`);
  }
  return value;
}

function createArtifactRoot(): string {
  const configured = process.env.FX_LIFECYCLE_ARTIFACT_DIR;
  if (configured) {
    mkdirSync(configured, { recursive: true });
    preserveArtifacts = true;
    artifactRoot = realpathSync(configured);
  } else {
    artifactRoot = realpathSync(
      mkdtempSync(join(tmpdir(), "fx-streamed-tool-lifecycle-artifacts-")),
    );
  }
  return artifactRoot;
}

function writeLifecycleWrapper(
  artifacts: string,
  invocation: "interactive" | "invalid-added-root" = "interactive",
): string {
  const wrapperPath = join(artifacts, "run-fixture.sh");
  const fxCommand = invocation === "invalid-added-root"
    ? '"$fx_bin" --add-dir "$FX_INVALID_ADDED_ROOT"'
    : '"$fx_bin"';
  writeFileSync(
    wrapperPath,
    `#!/bin/sh
set -u

artifact_dir="\${FX_LIFECYCLE_ARTIFACT_DIR:?}"
fx_bin="\${FX_TEST_BIN:?}"

write_atomic() {
  name="$1"
  value="$2"
  target="$artifact_dir/$name"
  printf '%s\\n' "$value" > "$target.tmp"
  /bin/mv "$target.tmp" "$target"
}

write_atomic "wrapper.pid" "$$"
write_atomic "stty.before" "$(/bin/stty -g)"
: > "$artifact_dir/stderr.log"

${fxCommand} 2>"$artifact_dir/stderr.log"
child_status=$?

write_atomic "child.status" "$child_status"
write_atomic "stty.after" "$(/bin/stty -g)"
: > "$artifact_dir/done.tmp"
/bin/mv "$artifact_dir/done.tmp" "$artifact_dir/done"

while [ ! -e "$artifact_dir/release" ]; do
  /bin/sleep 0.05
done

write_atomic "wrapper.status" "0"
`,
  );
  chmodSync(wrapperPath, 0o700);
  return wrapperPath;
}

test("generated lifecycle wrapper uses POSIX sh syntax", () => {
  const artifacts = createArtifactRoot();
  const wrapperPath = writeLifecycleWrapper(artifacts);
  const wrapper = readFileSync(wrapperPath, "utf8");

  expect(wrapperPath.endsWith("run-fixture.sh")).toBe(true);
  expect(wrapper.startsWith("#!/bin/sh\n")).toBe(true);
  execFileSync("/bin/sh", ["-n", wrapperPath]);
});

function normalizedPaneText(pane: string): string {
  return pane
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function countOccurrences(value: string, needle: string): number {
  if (needle.length === 0) throw new Error("needle must not be empty");
  return value.split(needle).length - 1;
}

function queuedSummaryText(count: number): string {
  return count === 1
    ? "1 queued message · ↑ to edit"
    : `${count} queued messages · ↑ to edit`;
}

function writeDelayedMcpFixture(
  fixtureRoot: string,
  home: string,
  delayMs: number,
) {
  const scriptPath = join(fixtureRoot, "mcp-delayed-fixture.js");
  const callStartedPath = join(fixtureRoot, "mcp-call-started.json");
  writeFileSync(
    scriptPath,
    `const { appendFileSync } = require("node:fs");
let buffer = Buffer.alloc(0);

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\\n");
}

function handle(message) {
  if (message.method === "server/discover") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32601, message: "Method not found" },
    });
    return;
  }
  if (message.method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "fixture", version: "1.0.0" },
      },
    });
    return;
  }
  if (message.method === "tools/list") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        tools: [{
          name: "echo",
          description: "Delayed echo fixture",
          inputSchema: {
            type: "object",
            properties: { text: { type: "string" } },
            required: ["text"],
          },
        }],
      },
    });
    return;
  }
  if (message.method === "tools/call") {
    appendFileSync(
      process.env.FX_MCP_CALL_STARTED,
      JSON.stringify({
        id: message.id,
        timestamp_ms: Date.now(),
        arguments: message.params.arguments,
      }) + "\\n",
    );
    setTimeout(() => send({
      jsonrpc: "2.0",
      id: message.id,
      result: { content: [{ type: "text", text: "MCP_DELAY_DONE" }] },
    }), ${delayMs});
  }
}

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const lineEnd = buffer.indexOf("\\n");
    if (lineEnd < 0) return;
    const line = buffer.subarray(0, lineEnd).toString("utf8").replace(/\\r+$/, "");
    buffer = buffer.subarray(lineEnd + 1);
    if (line.length > 0) handle(JSON.parse(line));
  }
});
`,
  );
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, scriptPath],
          enabled: true,
          environment: {
            FX_MCP_CALL_STARTED: callStartedPath,
          },
        },
      },
    }),
  );
  return { callStartedPath };
}

function readDelayedMcpCalls(path: string): Array<{ arguments: unknown }> {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { arguments: unknown });
}

function readSubagentCommunicationRecords(home: string): string[] {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot)
    .map((sessionId) =>
      join(sessionsRoot, sessionId, "subagent", "communication.json")
    )
    .filter(existsSync)
    .map((path) => readFileSync(path, "utf8"));
}

function assertThinkingFramesShowSubmittedPrompt(
  framesRoot: string,
  submittedPrompt: string,
) {
  const frameDir = join(framesRoot, "frames");
  const frameNames = readdirSync(frameDir)
    .filter((name) => name.endsWith(".grid.txt"))
    .sort();
  let thinkingFrameCount = 0;

  for (const frameName of frameNames) {
    const frame = readFileSync(join(frameDir, frameName), "utf8");
    const rows = frame.split(/\r?\n/);
    const thinkingRow = rows.findIndex((row) => row.includes("Thinking"));
    if (thinkingRow < 0) continue;
    thinkingFrameCount += 1;

    const submittedPromptVisible = rows.some((row, rowIndex) =>
      rowIndex < thinkingRow && row.includes(submittedPrompt)
    );
    if (!submittedPromptVisible) {
      throw new Error(
        `${frameName} shows Thinking before submitted prompt card:\n${frame}`,
      );
    }
  }

  expect(thinkingFrameCount).toBeGreaterThan(0);
}

function assertFirstPostEnterOutputShowsSubmittedPrompt(
  tapePath: string,
  submittedPrompt: string,
) {
  const frames = readTapeFrames(tapePath);
  const enterIndex = frames.findIndex(
    (frame) =>
      frame.kind === 2 &&
      frame.payload.equals(Buffer.from("\r")),
  );
  expect(enterIndex).toBeGreaterThanOrEqual(0);

  const firstOutput = frames
    .slice(enterIndex + 1)
    .find((frame) => frame.kind === 1);
  expect(firstOutput).toBeDefined();
  expect(firstOutput!.payload.includes(Buffer.from(submittedPrompt))).toBe(true);
}

function hasBareRunningRow(value: string): boolean {
  return value.split(/\r?\n/).some((line) => line.trim() === "● Running");
}

function readTrimmed(path: string): string {
  return readFileSync(path, "utf8").trim();
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForOnlyChildPid(
  parentPid: number,
  timeoutMs = TIMEOUT,
): Promise<number> {
  const started = Date.now();
  let stablePid: number | null = null;
  let stableCount = 0;
  while (Date.now() - started < timeoutMs) {
    let output = "";
    try {
      output = execFileSync("pgrep", ["-P", String(parentPid)], {
        encoding: "utf8",
      }).trim();
    } catch {}
    const pids = output
      .split(/\s+/)
      .filter(Boolean)
      .map((value) => Number.parseInt(value, 10))
      .filter(Number.isInteger);
    if (pids.length === 1) {
      if (pids[0] === stablePid) {
        stableCount += 1;
      } else {
        stablePid = pids[0];
        stableCount = 1;
      }
      if (stableCount >= 2) return pids[0];
    } else {
      stablePid = null;
      stableCount = 0;
    }
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for one child of wrapper ${parentPid}`);
}

async function waitForPath(path: string, timeoutMs = TIMEOUT): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for artifact ${path}`);
}

async function waitForPaneOrDone(
  activeSession: TmuxSession,
  pattern: string,
  donePath: string,
  timeoutMs = TIMEOUT,
): Promise<{ matched: boolean; pane: string }> {
  const started = Date.now();
  let pane = "";
  while (Date.now() - started < timeoutMs) {
    pane = await activeSession.capturePane();
    if (pane.includes(pattern)) return { matched: true, pane };
    if (existsSync(donePath)) return { matched: false, pane };
    await Bun.sleep(25);
  }
  throw new Error(
    `timed out waiting for ${JSON.stringify(pattern)} or ${donePath}\n${pane}`,
  );
}

function countTraceEvent(trace: string, event: string, callId?: string): number {
  return trace.split("\n").filter((line) =>
    line.includes(`event=${event}`) &&
    (callId === undefined || line.includes(`call_id=${callId}`))
  ).length;
}

function collectToolResultIds(value: unknown, result: string[] = []): string[] {
  if (Array.isArray(value)) {
    for (const item of value) collectToolResultIds(item, result);
    return result;
  }
  if (value === null || typeof value !== "object") return result;

  const record = value as Record<string, unknown>;
  if (record.type === "tool-result" && typeof record.toolCallId === "string") {
    result.push(record.toolCallId);
  }
  for (const nested of Object.values(record)) {
    collectToolResultIds(nested, result);
  }
  return result;
}

function collectTypedToolResults(value: unknown): Array<{
  toolCallId: string;
  toolName: string;
  outputType: string;
}> {
  const results: Array<{
    toolCallId: string;
    toolName: string;
    outputType: string;
  }> = [];

  function visit(candidate: unknown) {
    if (Array.isArray(candidate)) {
      for (const item of candidate) visit(item);
      return;
    }
    if (candidate === null || typeof candidate !== "object") return;

    const record = candidate as Record<string, unknown>;
    if (record.type === "tool-result") {
      const output =
        record.output !== null && typeof record.output === "object"
          ? (record.output as Record<string, unknown>)
          : {};
      if (
        typeof record.toolCallId === "string" &&
        typeof record.toolName === "string" &&
        typeof output.type === "string"
      ) {
        results.push({
          toolCallId: record.toolCallId,
          toolName: record.toolName,
          outputType: output.type,
        });
      }
    }
    for (const nested of Object.values(record)) visit(nested);
  }

  visit(value);
  return results;
}

async function runCanonicalLifecycleFixture(
  stage: LifecycleStage,
  traceStderr = false,
) {
  root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-gateway-ordering-")));
  const home = join(root, "home");
  const workspacePath = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspacePath, { recursive: true });
  const workspace = realpathSync(workspacePath);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "ask",
      maxxing_mode: "legacy",
      permission: {
        read: {
          "*": "ask",
        },
        grep: {
          "*": "ask",
        },
      },
    }),
  );
  writeFileSync(join(workspace, CANONICAL_READ_PATH), "alpha fixture\n");
  writeFileSync(
    join(workspace, "beta.txt"),
    `first line\n${CANONICAL_GREP_PATTERN}\nlast line\n`,
  );

  const artifacts = createArtifactRoot();
  const donePath = join(artifacts, "done");
  const releasePath = join(artifacts, "release");
  const tracePath = join(artifacts, "trace.log");
  const wrapperPath = writeLifecycleWrapper(artifacts);
  writeFileSync(join(artifacts, "canonical.sse"), CANONICAL_A_B_SSE);
  writeFileSync(
    join(artifacts, "fixture.sha256"),
    `${createHash("sha256").update(CANONICAL_A_B_SSE).digest("hex")}\n`,
  );

  const queuedGateway = startFakeGateway([
    new Response(CANONICAL_A_B_SSE, {
      headers: { "content-type": "text/event-stream" },
    }),
    fakeGatewayFinalText(CANONICAL_FINAL_TEXT),
  ]);
  gateway = queuedGateway;

  session = await TmuxSession.create({
    cmd: wrapperPath,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-streamed-tool-lifecycle-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
      FX_MODEL: MODEL,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: undefined,
      FX_TRACE_STDERR: traceStderr ? "1" : undefined,
      FX_TEST_BIN: FX_BIN,
      FX_LIFECYCLE_ARTIFACT_DIR: artifacts,
    },
  });

  await session.waitForComposer(TIMEOUT);
  await waitForPath(join(artifacts, "wrapper.pid"));
  const wrapperPid = Number.parseInt(
    readTrimmed(join(artifacts, "wrapper.pid")),
    10,
  );
  const childPid = await waitForOnlyChildPid(wrapperPid);
  writeFileSync(join(artifacts, "child.pid"), `${childPid}\n`);
  await session.sendText("Inspect both canonical fixtures.");

  let reachedFinal = false;
  let helpVisible = false;
  let requestCountAfterHelp: number | null = null;
  if (stage === "correlation-corrected" || stage === "corrected") {
    let approval = await session.waitForPane(
      (pane) =>
        pane.includes(APPROVAL_PROMPT) &&
        pane.includes(`read_file ${CANONICAL_READ_PATH}`),
      TIMEOUT,
    );
    if (!approval.includes(APPROVAL_PROMPT)) {
      throw new Error("read_file approval prompt did not render");
    }
    await session.sendKeys("Enter");

    approval = await session.waitForPane(
      (pane) =>
        pane.includes(APPROVAL_PROMPT) &&
        pane.includes(`grep_files ${CANONICAL_GREP_PATTERN}`),
      TIMEOUT,
    );
    if (!approval.includes(APPROVAL_PROMPT)) {
      throw new Error("grep_files approval prompt did not render");
    }
    await session.sendKeys("Enter");

    const settled = await waitForPaneOrDone(
      session,
      CANONICAL_FINAL_TEXT,
      donePath,
    );
    reachedFinal = settled.matched;
    if (reachedFinal) {
      await session.sendText("/help");
      const help = await waitForPaneOrDone(session, "Commands 39", donePath);
      helpVisible = help.matched;
      requestCountAfterHelp = queuedGateway.requests.length;
      if (helpVisible) {
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("Enter Insert"), TIMEOUT);
        await session.sendText("/quit");
      }
    }
  }

  await waitForPath(donePath);
  const pane = await session.capturePane();
  const childStatus = Number.parseInt(
    readTrimmed(join(artifacts, "child.status")),
    10,
  );
  const sttyBefore = readTrimmed(join(artifacts, "stty.before"));
  const sttyAfter = readTrimmed(join(artifacts, "stty.after"));
  const stderr = readFileSync(join(artifacts, "stderr.log"), "utf8");
  const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
  const parsedRequests = queuedGateway.requests.map(({ body }) => JSON.parse(body));
  const wrapperAliveAtCapture = session.isAlive() && session.isPaneAlive();
  const childAliveAtCapture = isProcessAlive(childPid);

  writeFileSync(join(artifacts, "pane.txt"), pane);
  writeFileSync(
    join(artifacts, "requests.json"),
    `${JSON.stringify(parsedRequests, null, 2)}\n`,
  );

  writeFileSync(releasePath, "");
  await session.waitForSessionEnd(TIMEOUT);
  session = null;
  const wrapperStatus = Number.parseInt(
    readTrimmed(join(artifacts, "wrapper.status")),
    10,
  );
  const fixtureSha256 = readTrimmed(join(artifacts, "fixture.sha256"));
  const observation = {
    stage,
    traceStderr,
    fixtureSha256,
    pane,
    stderr,
    trace,
    parsedRequests,
    requestCount: queuedGateway.requests.length,
    requestCountAfterHelp,
    reachedFinal,
    helpVisible,
    childPid,
    wrapperPid,
    childStatus,
    childAliveAtCapture,
    wrapperAliveAtCapture,
    wrapperStatus,
    sttyBefore,
    sttyAfter,
  };
  writeFileSync(
    join(artifacts, "manifest.json"),
    `${JSON.stringify(
      {
        stage,
        traceStderr,
        fixtureSha256,
        requestCount: observation.requestCount,
        requestCountAfterHelp,
        reachedFinal,
        helpVisible,
        childPid,
        wrapperPid,
        childStatus,
        childAliveAtCapture,
        wrapperAliveAtCapture,
        wrapperStatus,
        sttyBefore,
        sttyAfter,
        stderrBytes: Buffer.byteLength(stderr),
        traceBytes: Buffer.byteLength(trace),
        paneBytes: Buffer.byteLength(pane),
        done: existsSync(donePath),
      },
      null,
      2,
    )}\n`,
  );
  return observation;
}

async function launchRouteRecoveryTui(
  prefix: string,
  responses: FakeGatewayResponse[],
  options: {
    model?: string;
    models?: FakeGatewayModel[];
    settings?: Record<string, unknown>;
  } = {},
) {
  root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspacePath = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspacePath, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(options.settings ?? {}));
  const workspace = realpathSync(workspacePath);
  const model = options.model ?? MODEL;

  const queuedGateway = startFakeGateway(responses, {
    models: options.models ?? [{ id: model, type: "language", tags: ["tool-use"] }],
  });
  gateway = queuedGateway;

  session = await TmuxSession.create({
    cwd: workspace,
    width: 72,
    height: 24,
    minimumHistoryLines: 200,
    stderrPath,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-route-recovery-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: "auto",
      FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: model,
    },
  });
  await session.waitForComposer(TIMEOUT);
  return { queuedGateway, stderrPath };
}

describe.skipIf(!tmuxAvailable())("TUI gateway stream lifecycle", () => {
  test(
    "full-window output limit is omitted from the agent request",
    async () => {
      const model = "meta/muse-spark-1.2-contributor";
      const finalText = "Full-window output limit omitted.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-full-window-output-limit-",
        [fakeGatewayFinalText(finalText)],
        {
          model,
          models: [{
            id: model,
            type: "language",
            tags: ["reasoning", "tool-use", "implicit-caching", "file-input", "vision"],
            context_window: 1_048_576,
            max_tokens: 1_048_576,
          }],
          settings: { model },
        },
      );
      await waitForCondition(
        () => queuedGateway.modelRequests.length === 1,
        "full-window model catalog",
      );

      await session!.sendText("hi");
      await session!.waitForText(finalText, TIMEOUT);
      await session!.waitForComposer(TIMEOUT);

      expect(queuedGateway.modelRequests).toHaveLength(1);
      expect(queuedGateway.requests).toHaveLength(1);
      expect(JSON.parse(queuedGateway.requests[0]!.body)).not.toHaveProperty(
        "maxOutputTokens",
      );
      expect(session!.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session!.sendText("/quit");
      expect(await session!.waitForSessionEnd(TIMEOUT)).toBe(true);
      await session!.kill();
      session = null;
    },
    TIMEOUT * 2,
  );

  test(
    "live token counter includes submitted input, reasoning, and streamed text",
    async () => {
      const hold: TokenProgressHoldState = { started: false, cancelled: false };
      const finalSentinel = "FX_LIVE_TOKEN_COUNTER_COMPLETE";
      const streamedText = `${"streaming output\n".repeat(256)}${finalSentinel}`;
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-live-token-counter-",
        [
          () =>
            stagedTokenProgressResponse(
              hold,
              "reasoning tokens should advance while hidden from the transcript",
              streamedText,
            ),
        ],
      );

      await session!.sendText("Exercise the live token counter.");
      const reasoningPane = await waitForScrollback(
        session!,
        (value) =>
          /Thinking \(\d+s\) \(↑8 ↓[1-9]\d*(?:\.\d)?k?\)/.test(
            value,
          ),
        "reasoning token progress",
      );
      expect(reasoningPane).not.toContain(
        "reasoning tokens should advance while hidden from the transcript",
      );
      expect(queuedGateway.requests).toHaveLength(1);

      hold.sendContent?.();
      const streamingPane = await waitForScrollback(
        session!,
        (value) =>
          streamingOutputTokens(value) !== null &&
          !value.includes(finalSentinel),
        "first estimated live token progress while text is paced",
      );
      const firstOutputTokens = streamingOutputTokens(streamingPane)!;

      hold.sendMoreContent?.();
      const laterStreamingPane = await waitForScrollback(
        session!,
        (value) => {
          const outputTokens = streamingOutputTokens(value);
          return outputTokens !== null &&
            outputTokens > firstOutputTokens &&
            !value.includes(finalSentinel);
        },
        "increasing estimated live token progress",
      );
      expect(streamingOutputTokens(laterStreamingPane)).toBeGreaterThan(
        firstOutputTokens,
      );

      hold.finish?.();
      await waitForScrollback(
        session!,
        (value) =>
          value.includes("  (↑8 ↓20k)") &&
          !value.includes(finalSentinel),
        "exact token progress during the paced response tail",
      );
      await session!.waitForText(finalSentinel, TIMEOUT);
      const finalScrollback = await waitForScrollback(
        session!,
        (value) =>
          value.includes(finalSentinel) &&
          / {2}(?:\d+s|\d+m \d+s|\d+h \d{2}m) \(↑8 ↓20k\)/.test(
            value,
          ),
        "final compact token summary",
      );
      expect(finalScrollback).toContain(finalSentinel);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "streamed write payload keeps the activity row live",
    async () => {
      const hold: ToolPayloadHoldState = { started: false, cancelled: false };
      const payloadPath = "payload-progress.md";
      // Preserve two substantial streamed input chunks for the live
      // activity-row assertions.
      const payloadContent = "staged tool payload content\n".repeat(64);
      const assistantText = "I will write the staged payload now.";
      const finalSentinel = "FX_TOOL_PAYLOAD_PROGRESS_COMPLETE";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-tool-payload-progress-",
        [
          () =>
            stagedToolPayloadResponse(
              hold,
              assistantText,
              payloadPath,
              payloadContent,
            ),
          fakeGatewayFinalText(finalSentinel),
        ],
      );

      await session!.sendText("Write the staged payload file.");
      const firstPayloadPane = await waitForScrollback(
        session!,
        (value) =>
          value.includes(assistantText) &&
          quietToolPayloadOutputTokens(value) !== null,
        "activity marker during the first tool payload chunk",
      );
      const firstOutputTokens = quietToolPayloadOutputTokens(firstPayloadPane)!;
      expect(queuedGateway.requests).toHaveLength(1);

      hold.sendMoreInput?.();
      const laterPayloadPane = await waitForScrollback(
        session!,
        (value) => {
          const outputTokens = quietToolPayloadOutputTokens(value);
          return outputTokens !== null && outputTokens > firstOutputTokens;
        },
        "increasing token progress during the tool payload",
      );
      expect(quietToolPayloadOutputTokens(laterPayloadPane)).toBeGreaterThan(
        firstOutputTokens,
      );

      hold.finish?.();
      await session!.waitForText(finalSentinel, TIMEOUT);
      expect(queuedGateway.classifierRequests).toHaveLength(0);
      const writtenPath = join(root!, "workspace", payloadPath);
      await waitForCondition(
        () => existsSync(writtenPath),
        "staged payload file",
      );
      expect(readFileSync(writtenPath, "utf8")).toBe(payloadContent);
      expect(queuedGateway.requests).toHaveLength(2);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "follow-up input counter excludes retained context and provider input usage",
    async () => {
      const firstFinal = `FIRST_TURN_CONTEXT_COMPLETE ${"retained assistant context ".repeat(128)}`;
      const followupFinal = "FOLLOWUP_INPUT_COUNTER_COMPLETE";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-followup-input-counter-",
        [
          fakeGatewayFinalTextWithUsage(firstFinal, 30_000, 600),
          fakeGatewayFinalTextWithUsage(followupFinal, 16_000, 5),
        ],
      );

      await session!.sendText("Seed retained context for the follow-up.");
      await waitForScrollback(
        session!,
        (value) =>
          value.includes("FIRST_TURN_CONTEXT_COMPLETE") &&
          TURN_SUMMARY_WITH_TOKENS.test(value),
        "first turn summary",
      );

      await session!.sendText("open it for me");
      const followupScrollback = await waitForScrollback(
        session!,
        (value) =>
          value.includes(followupFinal) &&
          / {2}(?:\d+s|\d+m \d+s|\d+h \d{2}m) \(↑4 ↓5\)/.test(
            value,
          ),
        "follow-up submitted input summary",
      );

      expect(queuedGateway.requests).toHaveLength(2);
      expect(queuedGateway.requests[1].body).toContain(
        "FIRST_TURN_CONTEXT_COMPLETE",
      );
      expect(followupScrollback).not.toContain("(↑16k ↓5)");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "agent-owned HTTP retry renders the final token counter without markers",
    async () => {
      const finalText = "Internal retry token counter completed.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-live-token-counter-retry-",
        [
          new Response(
            JSON.stringify({ error: { message: "temporarily unavailable" } }),
            {
              status: 503,
              headers: { "content-type": "application/json" },
            },
          ),
          fakeGatewayFinalText(finalText),
        ],
      );

      await session!.sendText("Exercise an internal Gateway retry.");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await waitForScrollback(
        session!,
        (value) =>
          value.includes(finalText) &&
          / {2}(?:\d+s|\d+m \d+s|\d+h \d{2}m) \(↑9 ↓5\)/.test(
            value,
          ),
        "summary after an ambiguous internal retry",
      );

      expect(queuedGateway.requests).toHaveLength(2);
      expect(scrollback).toContain(finalText);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "HTTP restricted provider error renders sticky status row",
    async () => {
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-route-http-403-",
        [restrictedProviderResponse()],
      );

      await session!.sendText("Trigger restricted provider.");
      await session!.waitForText(
        "⚠ API access denied · HTTP 403 · Provider: wafer",
        TIMEOUT,
      );
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(1);
      expect(scrollback).toContain(
        "⚠ API access denied · HTTP 403 · Provider: wafer",
      );
      expect(scrollback).toContain(
        "no_providers_available: Your team has restricted access to this",
      );
      expect(scrollback).toContain("no_providers_available");
      expect(scrollback).not.toContain('{"error"');
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "post-tool HTTP 503 omits empty assistant from follow-up",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-empty-assistant-history-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const finalText = "Follow-up accepted after HTTP 503.";

      let responseIndex = 0;
      let queuedGateway: ReturnType<typeof startDynamicFakeGateway>;
      queuedGateway = startDynamicFakeGateway(() => {
        responseIndex += 1;
        if (responseIndex === 1) {
          return fakeGatewayToolCall("list_1", "list_files", { path: "." });
        }
        if (responseIndex >= 2 && responseIndex <= 11) {
          return new Response(
            JSON.stringify({ error: { message: "route temporarily unavailable" } }),
            {
              status: 503,
              headers: {
                "content-type": "application/json",
                "retry-after": "0",
              },
            },
          );
        }
        if (responseIndex === 12) {
          if (hasEmptyStandaloneAssistant(queuedGateway.requests.at(-1)!.body)) {
            return new Response(
              JSON.stringify({
                error: {
                  message:
                    "Invalid request: the message with role 'assistant' must not be empty",
                },
              }),
              {
                status: 400,
                headers: { "content-type": "application/json" },
              },
            );
          }
          return fakeGatewayFinalText(finalText);
        }
        return new Response("unexpected request", { status: 500 });
      }, {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 105,
        height: 32,
        minimumHistoryLines: 200,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-empty-assistant-history-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("List the current directory, then summarize it.");
      await waitForCondition(
        () => queuedGateway.requests.length === 11,
        "bounded HTTP 503 attempts",
      );
      const failedScrollback = await waitForScrollback(
        session,
        (value) => value.includes("recovery paused after 10/10 attempts"),
        "provider-unavailable recovery pause",
      );
      await session.sendText("/continue");
      await waitForCondition(
        () => queuedGateway.requests.length === 12,
        "continued recovery request",
      );

      const followUpBody = queuedGateway.requests[11]!.body;
      expect(hasEmptyStandaloneAssistant(followUpBody)).toBe(false);
      await session.waitForText(finalText, TIMEOUT);
      const followUp = JSON.parse(followUpBody) as {
        prompt: Array<{ content?: unknown }>;
      };
      const parts = followUp.prompt.flatMap((message) =>
        Array.isArray(message.content)
          ? message.content as Array<Record<string, unknown>>
          : []
      );
      const finalScrollback = await session.captureFullScrollback();

      expect(failedScrollback).toContain("recovery paused after 10/10 attempts");
      expect(parts).toContainEqual(expect.objectContaining({
        type: "tool-call",
        toolCallId: "list_1",
      }));
      expect(parts).toContainEqual(expect.objectContaining({
        type: "tool-result",
        toolCallId: "list_1",
      }));
      expect(finalScrollback).toContain(finalText);
      expect(finalScrollback).not.toContain("HTTP 400");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "provider route recovery renders retry, transient recovery, and normal summary row",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-route-recovery-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const finalText = "TUI route recovery completed.";
      let releaseFinalResponse: (() => void) | null = null;
      const finalResponseRelease = new Promise<void>((resolve) => {
        releaseFinalResponse = resolve;
      });
      const queuedGateway = startFakeGateway([
        providerErrorResponse("tui route failed once"),
        async () => {
          await finalResponseRelease;
          return fakeGatewayFinalText(finalText);
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 72,
        height: 24,
        minimumHistoryLines: 200,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-route-recovery-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      const retryVisible = session.waitForText(
        "provider_error: tui route failed once",
        TIMEOUT,
      );
      await session.sendText("Recover from provider route failure.");
      await Promise.all([
        retryVisible,
        waitForCondition(
          () => queuedGateway.requests.length === 2,
          "second route recovery request",
        ),
      ]);

      await session.resizeWindow(32, 24);
      const narrowPane = await session.capturePane();
      expect(narrowPane).toContain("⚠ Provider unavailable");
      expect(narrowPane).toContain("provider_error:");
      expect(narrowPane).toContain("attempt 1/10");
      expect(narrowPane).not.toContain("▲");

      await session.resizeWindow(72, 24);
      releaseFinalResponse?.();
      await session.waitForText(finalText, TIMEOUT);
      const scrollback = await session.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(2);
      expect(scrollback).not.toContain("System");
      expect(scrollback).not.toContain("Attempt 1 failed. Retrying route.");
      expect(scrollback).not.toContain("✓ recovered");
      expect(scrollback).toMatch(TURN_SUMMARY_WITH_TOKENS);
      expect(scrollback).toContain(finalText);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "content filter opens local recovery modal without transcript card",
    async () => {
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-route-content-filter-",
        [contentFilterResponse()],
      );

      await session!.sendText("Trigger content filter.");
      const pane = await session!.waitForText("Try again later", TIMEOUT);
      await session!.sendKeys("Down");
      await session!.sendKeys("Enter");
      await session!.waitForComposer(TIMEOUT);
      await session!.waitForText("⚠ blocked · content_filter · content filter", TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(1);
      expect(scrollback).not.toContain("What should fx do?");
      expect(pane).toContain("Change model");
      expect(pane).toContain("Try again later");
      expect(pane).toContain("Response blocked by content filter");
      expect(scrollback).toContain("⚠ blocked · content_filter · content filter");
      expect(pane).not.toContain("Disable Fast");
      expect(pane).not.toContain("Retry same route");
      expect(scrollback).not.toContain("System");
      expect(scrollback).not.toContain("Change model");
      expect(scrollback).not.toContain("request failed: ModelError");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "paused response resumes through slash continue without a second user turn",
    async () => {
      const originalPrompt = "Preserve this interactive prompt.";
      const finalText = "Interactive recovery completed.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-continue-",
        [
          ...Array.from({ length: 10 }, () => retryAfterUnavailable(0)),
          fakeGatewayFinalText(finalText),
        ],
      );

      await session!.sendText(originalPrompt);
      await session!.waitForText("recovery paused after 10/10 attempts", TIMEOUT);
      await session!.waitForComposer(TIMEOUT);
      expect(queuedGateway.requests).toHaveLength(10);

      await session!.sendText("/continue");
      try {
        await session!.waitForText(finalText, TIMEOUT);
      } catch (err) {
        const stderr = readFileSync(stderrPath, "utf8");
        const scrollback = await session!.captureFullScrollback();
        throw new Error(
          `${String(err)}\n` +
            `session_alive=${session!.isAlive()} request_count=${queuedGateway.requests.length}\n` +
            `stderr:\n${stderr}\nscrollback:\n${scrollback}`,
        );
      }
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(11);
      expect(queuedGateway.requests[10]!.body).toContain(originalPrompt);
      expect(scrollback.split(originalPrompt).length - 1).toBe(1);
      expect(scrollback).toContain(finalText);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "slash continue cannot duplicate an active checkpointed request",
    async () => {
      const hold: HoldState = { started: false, cancelled: false };
      const finalText = "Active checkpointed request completed once.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-active-continue-",
        [
          () => heldGatewayResponse(hold, [], [
            { type: "text-delta", id: "answer_1", delta: finalText },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
            },
          ]),
        ],
      );

      await session!.sendText("Hold one response while recovery state exists.");
      await waitForCondition(() => hold.started, "held checkpointed request");
      expect(queuedGateway.requests).toHaveLength(1);

      await session!.sendText("/continue");
      const busy = await waitForScrollback(
        session!,
        (value) =>
          value.includes("wait for the current response to finish") &&
          value.includes("before continuing"),
        "active recovery continuation rejection",
      );
      expect(busy).toContain("wait for the current response to finish");
      expect(queuedGateway.requests).toHaveLength(1);

      hold.release?.();
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(1);
      expect(scrollback.split(finalText).length - 1).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "paused tool lifecycle admits resumed tools on the same turn",
    async () => {
      const finalText = "Resumed tool lifecycle completed.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-tool-lifecycle-",
        [
          fakeGatewayToolCall("read_before_pause", "read_file", { path: "before.txt" }),
          ...Array.from({ length: 10 }, () => retryAfterUnavailable(0)),
          fakeGatewayToolCall("read_after_pause", "read_file", { path: "after.txt" }),
          fakeGatewayFinalText(finalText),
        ],
      );
      writeFileSync(join(root!, "workspace", "before.txt"), "before\n");
      writeFileSync(join(root!, "workspace", "after.txt"), "after\n");

      await session!.sendText("Read both fixture files across recovery.");
      await session!.waitForText("recovery paused after 10/10 attempts", TIMEOUT);
      expect(queuedGateway.requests).toHaveLength(11);

      await session!.sendText("/continue");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(13);
      expect(scrollback).toContain("└ Read before.txt");
      expect(scrollback).toContain("└ Read after.txt");
      expect(scrollback).toContain(finalText);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "Fast failure heartbeat preserves exact model identity through its retry budget",
    async () => {
      const responses: FakeGatewayResponse[] = [];
      for (let index = 0; index < 10; index += 1) {
        responses.push(retryAfterUnavailable(0));
      }
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-fast-budget-",
        responses,
        {
          model: GLM_MODEL,
          models: [{
            id: GLM_MODEL,
            type: "language",
            tags: ["tool-use"],
            fast_options: [{ type: "toggle" }],
          }],
          settings: { model: GLM_MODEL, fast_mode: true },
        },
      );

      await session!.sendText("Preserve the Fast recovery budget.");
      await session!.waitForText("recovery paused after 10/10 attempts", TIMEOUT);

      expect(queuedGateway.requests).toHaveLength(10);
      expect(queuedGateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
        GLM_MODEL,
      );
      for (const request of queuedGateway.requests.slice(1)) {
        expect(request.headers.get("ai-language-model-id")).toBe(GLM_MODEL);
      }
      const firstRequest = JSON.parse(queuedGateway.requests[0]!.body);
      expect(firstRequest).not.toHaveProperty("fast");
      expect(firstRequest).toMatchObject({
        providerOptions: { gateway: { speed: "fast" } },
      });
      for (const request of queuedGateway.requests.slice(1)) {
        const retryRequest = JSON.parse(request.body);
        expect(retryRequest).not.toHaveProperty("fast");
        expect(retryRequest.providerOptions?.gateway).toBeUndefined();
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "process restart during backoff preserves a direct Fast model ID",
    async () => {
      const directFastModel = `${GLM_MODEL}-fast`;
      const finalText = "Canonical route recovered after process restart.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-fast-backoff-restart-",
        [retryAfterUnavailable(5), fakeGatewayFinalText(finalText)],
        {
          model: directFastModel,
          models: [
            { id: directFastModel, type: "language", tags: ["tool-use"] },
            { id: GLM_MODEL, type: "language", tags: ["tool-use"] },
          ],
          settings: { model: directFastModel, fast_mode: false },
        },
      );

      await session!.sendText("Keep the canonical fallback through restart.");
      await session!.waitForText(
        "HTTP 503",
        TIMEOUT,
      );
      expect(queuedGateway.requests).toHaveLength(1);
      expect(queuedGateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
        directFastModel,
      );

      await session!.kill();
      session = null;
      const resumedStderrPath = join(root!, "resumed-stderr.log");
      session = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: join(root!, "workspace"),
        width: 72,
        height: 24,
        minimumHistoryLines: 200,
        stderrPath: resumedStderrPath,
        env: {
          HOME: join(root!, "home"),
          AI_GATEWAY_API_KEY: "fake-route-recovery-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: directFastModel,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/continue");
      await session.waitForText(finalText, TIMEOUT);

      expect(queuedGateway.requests).toHaveLength(2);
      expect(queuedGateway.requests[1]!.headers.get("ai-language-model-id")).toBe(
        directFastModel,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "Escape during provider recovery backoff cancels without ModelError",
    async () => {
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-backoff-cancel-",
        [
          providerErrorResponse("route failed once"),
          providerErrorResponse("route failed twice"),
          providerErrorResponse("route failed three times"),
          fakeGatewayFinalText("must not send"),
        ],
      );

      await session!.sendText("Cancel during provider recovery backoff.");
      await session!.waitForText(
        "provider_error: route failed three times",
        TIMEOUT,
      );
      await session!.sendKeys("Escape");
      await session!.waitForText("cancelled", TIMEOUT);
      await session!.waitForComposer(TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(3);
      expect(scrollback).toContain("cancelled");
      expect(scrollback).not.toContain("request failed: ModelError");
      expect(scrollback).not.toContain("must not send");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "slash continue does not render checkpointed partial output twice",
    async () => {
      const partialText = "Partial output before EOF.";
      const finalText = "Recovered final output once.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-partial-continue-",
        [
          partialEofResponse(partialText),
          ...Array.from({ length: 9 }, () => retryAfterUnavailable(0)),
          fakeGatewayFinalText(`${partialText}${finalText}`),
        ],
      );

      await session!.sendText("Recover the interrupted response without duplication.");
      await session!.waitForText("recovery paused after 10/10 attempts", TIMEOUT);
      await session!.waitForComposer(TIMEOUT);
      expect(queuedGateway.requests).toHaveLength(10);

      await session!.sendText("/continue");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(11);
      expect(scrollback.split(partialText).length - 1).toBe(1);
      expect(scrollback.split(finalText).length - 1).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "Fast route failure automatically falls back without changing transcript history",
    async () => {
      const finalText = "Recovered after disabling Fast.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-route-disable-fast-",
        [
          providerErrorResponse("fast route failed once"),
          providerErrorResponse("fast route failed twice"),
          providerErrorResponse("fast route failed three times"),
          fakeGatewayFinalText(finalText),
        ],
        {
          model: GLM_MODEL,
          models: [{
            id: GLM_MODEL,
            type: "language",
            tags: ["tool-use"],
            fast_options: [{ type: "toggle" }],
          }],
          settings: {
            model: GLM_MODEL,
            fast_mode: true,
            permission_mode: "auto",
          },
        },
      );

      await session!.sendText("Recover by disabling Fast.");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await waitForScrollback(
        session!,
        (value) =>
          value.includes(finalText) &&
          TURN_SUMMARY_WITH_TOKENS.test(value) &&
          !value.includes("✓ recovered"),
        "Fast recovery final transcript",
      );

      expect(queuedGateway.requests.length).toBe(4);
      for (const request of queuedGateway.requests) {
        expect(request.headers.get("ai-language-model-id")).toBe(GLM_MODEL);
      }
      const firstRequest = JSON.parse(queuedGateway.requests[0]!.body);
      expect(firstRequest).not.toHaveProperty("fast");
      expect(firstRequest).toMatchObject({
        providerOptions: { gateway: { speed: "fast" } },
      });
      const secondRequest = JSON.parse(queuedGateway.requests[1]!.body);
      expect(secondRequest).not.toHaveProperty("fast");
      expect(secondRequest.providerOptions?.gateway).toBeUndefined();
      const finalRequest = JSON.parse(queuedGateway.requests[3]!.body);
      expect(finalRequest).not.toHaveProperty("fast");
      expect(finalRequest.providerOptions?.gateway).toBeUndefined();
      expect(scrollback).toContain(finalText);
      expect(scrollback).toMatch(TURN_SUMMARY_WITH_TOKENS);
      expect(scrollback).not.toContain("✓ recovered");
      expect(scrollback).not.toContain("What should fx do?");
      expect(scrollback).not.toContain("request failed: ModelError");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "provider error after assistant output continues the same visible response",
    async () => {
      const firstCatalogModel = "anthropic/claude-fable-5";
      const finalText = "partial unsafe output completed";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-route-unsafe-text-",
        [providerErrorAfterTextResponse(), fakeGatewayFinalText(finalText)],
        {
          models: [
            {
              id: firstCatalogModel,
              type: "language",
              released: 1,
              tags: ["tool-use"],
            },
            {
              id: MODEL,
              type: "language",
              released: 1,
              tags: ["tool-use"],
            },
          ],
        },
      );

      await session!.sendText("Fail after visible output.");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(2);
      expect(scrollback.split("partial unsafe output").length - 1).toBe(1);
      expect(scrollback).toContain(finalText);
      expect(scrollback).not.toContain("What should fx do?");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "provider error after streamed tool start regenerates without a recovery modal",
    async () => {
      const finalText = "Recovered after unstarted tool activity.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-route-unsafe-tool-",
        [providerErrorAfterToolStartResponse(), fakeGatewayFinalText(finalText)],
      );

      await session!.sendText("Fail after tool start.");
      await session!.waitForText(finalText, TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(2);
      expect(scrollback).toContain(finalText);
      expect(scrollback).not.toContain("What should fx do?");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "unavailable read_tool_result renders and persists a failed result",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-read-tool-result-failure-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const expectedFailure =
        "read_tool_result failed for handle unknown-dogfood-handle: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.";
      const finalText = "Read tool result failure lifecycle completed.";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const queuedGateway = startFakeGateway([
        fakeGatewayToolCall(
          "read_result_unknown_1",
          "read_tool_result",
          {
            handle: "unknown-dogfood-handle",
            start_byte: 1,
            byte_count: 64,
          },
        ),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-read-tool-result-failure-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Exercise the unavailable tool-result handle.");
      const pane = await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "tool-result continuation request",
      );

      const sessionsRoot = join(home, ".fx", "sessions");
      await waitForCondition(
        () =>
          existsSync(sessionsRoot) &&
          readdirSync(sessionsRoot).some((entry) =>
            existsSync(join(sessionsRoot, entry, "checkpoint.json")),
          ),
        "session checkpoint",
      );
      const sessionId = readdirSync(sessionsRoot).find((entry) =>
        existsSync(join(sessionsRoot, entry, "checkpoint.json")),
      );
      if (!sessionId) throw new Error("session checkpoint was not found");

      const readSavedSession = () =>
        execFileSync(FX_BIN, ["session", "--id", sessionId, "--json"], {
          cwd: workspace,
          env: { ...process.env, HOME: home },
          encoding: "utf8",
        });
      await waitForCondition(
        () => readSavedSession().includes('"status":"failure"'),
        "completed persisted tool failure",
      );

      const scrollback = await session.captureFullScrollback();
      const continuation = queuedGateway.requests[1]!.body;
      const savedSession = readSavedSession();

      expect(pane).toContain(finalText);
      expect(scrollback).toContain("Failed tool result");
      expect(continuation).toContain(expectedFailure);
      expect(savedSession).toContain('"status":"failure"');
      expect(savedSession).toContain(expectedFailure);
      expect(existsSync(tapePath)).toBe(true);
      expect(existsSync(tracePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "typing during a streamed response leaves the native cursor visible",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-streaming-caret-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const draft = "draft while stream is active";
      const stream = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const streamingGateway = startFakeGateway([
        () => heldGatewayResponse(stream),
      ]);
      gateway = streamingGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-tui-streaming-caret-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: streamingGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: streamingGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: streamingGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Start the streamed response.");
      await waitForCondition(() => stream.started, "stream start");
      await session.waitForText("Thinking", TIMEOUT);
      await session.sendLiteral(draft);
      const pane = await session.waitForText(draft, TIMEOUT);

      const draftFrames = stdoutFrames(tapePath).filter((frame) =>
        frame.payload.includes(Buffer.from(draft)),
      );
      const cursorVisibility = draftFrames.flatMap((frame) =>
        [...frame.payload.toString("binary").matchAll(/\x1b\[\?25([hl])/g)]
          .map((match) => match[1]!),
      );

      expect(pane).toContain("Thinking");
      expect(draftFrames).not.toHaveLength(0);
      expect(cursorVisibility.at(-1)).toBe("h");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "idle submitted prompt stays visible across a first-use context notice",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-idle-submit-order-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const framesRoot = join(root, "replay-frames");
      const submittedPrompt = "IDLE_SUBMIT_ORDER_SENTINEL";
      const hold: HoldState = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(
        join(root, "outside-instructions.md"),
        "# Outside instructions\n",
      );
      symlinkSync("../outside-instructions.md", join(workspacePath, "AGENTS.md"));
      const workspace = realpathSync(workspacePath);

      const heldGateway = startFakeGateway([
        () => heldGatewayResponse(hold),
      ]);
      gateway = heldGateway;
      session = await TmuxSession.create({
        cwd: workspace,
        width: 96,
        height: 28,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-idle-submit-order-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: heldGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(submittedPrompt);
      await waitForCondition(
        () => heldGateway.requests.length === 1 && hold.started,
        "held idle submitted prompt stream",
      );
      await session.waitForText("Thinking", TIMEOUT);
      await Bun.sleep(250);
      await session.sendKeys("C-c");
      await session.waitForText("cancelled", TIMEOUT);

      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", framesRoot], {
        encoding: "utf8",
      });
      assertFirstPostEnterOutputShowsSubmittedPrompt(tapePath, submittedPrompt);
      assertThinkingFramesShowSubmittedPrompt(framesRoot, submittedPrompt);

      expect(hold.cancelled).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "completed paced assistant text drains before a queued user prompt reaches scrollback",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-prompt-boundary-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const secondResponse = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const splitGateway = startFakeGateway([
        fakeGatewaySse([
          { type: "text-delta", id: "split_old", delta: SPLIT_OLD_RESPONSE },
          {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 3 },
              outputTokens: { total: 5 },
            },
          },
        ]),
        () => heldGatewayResponse(secondResponse),
      ]);
      gateway = splitGateway;
      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 34,
        minimumHistoryLines: 2_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-prompt-boundary-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: splitGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: splitGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: splitGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Return the first split fixture.");
      const beforePrompt = await waitForScrollback(
        session,
        (candidate) =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=stream_complete") &&
          candidate.includes("SPLIT_OLD_TAIL_005") &&
          !candidate.includes("SPLIT_OLD_TAIL_FINAL"),
        "completed Gateway stream with assistant presentation still draining",
      );
      expect(beforePrompt).not.toContain("SPLIT_OLD_TAIL_FINAL");

      await session.sendText(SPLIT_NEW_USER_PROMPT);
      await waitForCondition(
        () => splitGateway.requests.length === 2 && secondResponse.started,
        "held second Gateway stream",
      );

      const rawScrollback = await waitForEscapedScrollback(
        session,
        (candidate) => {
          const promptIndex = candidate.lastIndexOf(SPLIT_NEW_USER_PROMPT);
          if (promptIndex < 0) return false;
          const finalTailIndex = candidate.lastIndexOf("SPLIT_OLD_TAIL_FINAL");
          return finalTailIndex >= 0 && finalTailIndex < promptIndex;
        },
        "old assistant final tail before the next user prompt",
        SPLIT_BOUNDARY_WAIT_TIMEOUT,
      );
      const scrollback = await session.captureFullScrollback();
      const promptIndex = rawScrollback.lastIndexOf(SPLIT_NEW_USER_PROMPT);
      expect(promptIndex).toBeGreaterThanOrEqual(0);

      const finalTailIndex = rawScrollback.lastIndexOf("SPLIT_OLD_TAIL_FINAL");
      expect(finalTailIndex).toBeGreaterThanOrEqual(0);
      expect(finalTailIndex).toBeLessThan(promptIndex);
      expect(countOccurrences(rawScrollback, SPLIT_NEW_USER_PROMPT)).toBe(1);

      expect(scrollback).toContain("SPLIT_OLD_TAIL_FINAL");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(existsSync(tracePath)).toBe(true);
      expect(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
          encoding: "utf8",
        }),
      ).not.toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    SPLIT_BOUNDARY_TEST_TIMEOUT,
  );

  test(
    "confirmed post-cancel queued prompt recovers duplicate-key tool arguments",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-cancel-integrity-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: HoldState = { started: false, cancelled: false };
      const duplicateArguments = '{"depth":1, "depth":2}';
      const finalText = "Queued recovery completed after sanitized history.";
      const queuedGateway = startFakeGateway([
        fakeGatewaySerializedToolCall(
          "first_turn_command",
          "terminal",
          '{"action":"exec","command":"printf preflight-failed > preflight.txt"}',
        ),
        () => heldGatewayResponse(hold),
        fakeGatewaySerializedToolCall(
          "queued_grep_command",
          "terminal",
          '{"action":"exec","command":"grep -R \\"preflight\\" -n . | head"}',
        ),
        duplicateKeyToolResponse(),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-cancel-integrity-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,core,gateway,stream,tool,sse,worker,input,prompt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(
        "Create dogfood-notes.txt with three lines, then report its byte count.",
      );
      await waitForCondition(
        () => queuedGateway.requests.length >= 2 && hold.started,
        "held second gateway request",
      );

      await session.sendText(
        "Why did preflight fail? Do not write anything; just explain briefly.",
      );
      await session.waitForText(queuedSummaryText(1), TIMEOUT);
      await session.sendKeys("C-c");
      await session.waitForPane(
        (candidate) =>
          candidate.includes("Why did preflight fail?") &&
          candidate.includes("paused") &&
          candidate.includes("enter to send"),
        TIMEOUT,
      );
      expect(queuedGateway.requests).toHaveLength(2);
      await session.sendKeys("Enter");
      const pane = await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 5 && hold.cancelled,
        "fifth gateway request after held request cancellation",
      );

      const finalRequest = JSON.parse(queuedGateway.requests[4].body) as {
        prompt: Array<{ content?: Array<Record<string, unknown>> }>;
      };
      const parts = finalRequest.prompt.flatMap((message) => message.content ?? []);
      const repairedCalls = parts.filter((part) =>
        part.type === "tool-call" &&
        part.toolCallId === "queued_duplicate_list" &&
        part.toolName === "list_files"
      );
      const repairedResults = parts.filter((part) =>
        part.type === "tool-result" &&
        part.toolCallId === "queued_duplicate_list" &&
        part.toolName === "list_files"
      );
      const trace = readFileSync(tracePath, "utf8");
      const stderr = readFileSync(stderrPath, "utf8");

      expect(repairedCalls).toEqual([
        expect.objectContaining({ input: {} }),
      ]);
      expect(repairedResults).toEqual([
        expect.objectContaining({
          output: expect.objectContaining({
            type: "text",
            value: expect.stringContaining("tool_execution_failed"),
          }),
        }),
      ]);
      expect(queuedGateway.requests[4].body).not.toContain(duplicateArguments);
      expect(trace).toContain("event=tool_argument_integrity");
      expect(trace).toContain("failure=malformed_json");
      expect(trace).toContain("event=queue_review_started");
      expect(trace).toContain("reason=post_cancel");
      expect(trace).toContain("event=queue_review_committed");
      expect(trace).toContain("event=queue_review_resumed");
      expect(trace).not.toContain(duplicateArguments);
      expect(pane).not.toContain("InvalidGatewayHistory");
      expect(stderr).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
      expect(existsSync(tapePath)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "queued prompt stays pending until active assistant text completes",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-order-")));
      const home = join(root, "home");
      const launchAncestor = join(home, "projects");
      const workspacePath = join(launchAncestor, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const nested = join(workspace, "assets", "nested");
      const sibling = join(workspace, "sibling");
      mkdirSync(nested, { recursive: true });
      mkdirSync(sibling, { recursive: true });
      const imagePath = join(nested, "queued-snapshot.png");
      copyFileSync(
        join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
        imagePath,
      );
      const image = realpathSync(imagePath);
      const expectedImageData = readFileSync(image).toString("base64");
      const oldGlobalRule = "QUEUED_SNAPSHOT_OLD_GLOBAL_RULE";
      const oldAncestorRule = "QUEUED_SNAPSHOT_OLD_ANCESTOR_RULE";
      const oldRootRule = "QUEUED_SNAPSHOT_OLD_ROOT_RULE";
      const oldNestedRule = "QUEUED_SNAPSHOT_OLD_NESTED_RULE";
      const oldSiblingRule = "QUEUED_SNAPSHOT_OLD_SIBLING_MUST_BE_ABSENT";
      const newGlobalRule = "QUEUED_SNAPSHOT_NEW_GLOBAL_MUST_BE_ABSENT";
      const newAncestorRule = "QUEUED_SNAPSHOT_NEW_ANCESTOR_MUST_BE_ABSENT";
      const newRootRule = "QUEUED_SNAPSHOT_NEW_ROOT_MUST_BE_ABSENT";
      const newNestedRule = "QUEUED_SNAPSHOT_NEW_NESTED_MUST_BE_ABSENT";
      const newSiblingRule = "QUEUED_SNAPSHOT_NEW_SIBLING_MUST_BE_ABSENT";
      writeFileSync(join(home, ".fx", "AGENTS.md"), `${oldGlobalRule}\n`);
      writeFileSync(join(launchAncestor, "AGENTS.md"), `${oldAncestorRule}\n`);
      writeFileSync(join(workspace, "AGENTS.md"), `${oldRootRule}\n`);
      writeFileSync(join(nested, "AGENTS.md"), `${oldNestedRule}\n`);
      writeFileSync(join(sibling, "AGENTS.md"), `${oldSiblingRule}\n`);
      const hold: HoldState = { started: false, cancelled: false };
      const activeBefore = "ACTIVE_ASSISTANT_BEFORE_QUEUE_SENTINEL\n";
      const activeAfter = "ACTIVE_ASSISTANT_AFTER_QUEUE_SENTINEL\n";
      const queuedPrompt = "QUEUED_PROMPT_CANONICAL_ORDER_SENTINEL";
      const queuedDone = "QUEUED_PROMPT_CANONICAL_ORDER_DONE";
      const queuedGateway = startFakeGateway(
        [
          () => splitHeldTextResponse(hold, activeBefore, activeAfter),
          fakeGatewayFinalText(queuedDone),
        ],
        {
          models: [{
            id: MODEL,
            type: "language",
            tags: ["vision", "file-input", "tool-use"],
          }],
        },
      );
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        minimumHistoryLines: 2_000,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-transcript-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the active turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active Gateway request",
      );
      await session.waitForText("Thinking", TIMEOUT);

      await session.sendText(`/image ${image}`);
      await session.waitForText("attached image: queued-snapshot.png", TIMEOUT);
      await session.sendText(queuedPrompt);
      const heldScrollback = await waitForEscapedScrollback(
        session,
        (candidate) =>
          queuedGateway.requests.length === 1 &&
          hold.started &&
          candidate.includes(queuedSummaryText(1)) &&
          !candidate.includes(queuedPrompt),
        "queued prompt count shown before active turn releases",
      );

      expect(heldScrollback).not.toContain(queuedPrompt);
      expect(heldScrollback).not.toContain("next:");
      expect(countOccurrences(heldScrollback, queuedPrompt)).toBe(0);
      expect(heldScrollback).not.toContain(activeBefore.trim());
      expect(heldScrollback).not.toContain(activeAfter.trim());
      expect(queuedGateway.requests).toHaveLength(1);

      writeFileSync(join(home, ".fx", "AGENTS.md"), `${newGlobalRule}\n`);
      writeFileSync(join(launchAncestor, "AGENTS.md"), `${newAncestorRule}\n`);
      writeFileSync(join(workspace, "AGENTS.md"), `${newRootRule}\n`);
      writeFileSync(join(nested, "AGENTS.md"), `${newNestedRule}\n`);
      writeFileSync(join(sibling, "AGENTS.md"), `${newSiblingRule}\n`);

      hold.release?.();
      await session.waitForText(queuedDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "queued prompt drained",
      );

      const queuedBody = queuedGateway.requests[1]!.body;
      const queuedRequest = JSON.parse(queuedBody) as {
        prompt: Array<{ role?: string; content?: unknown }>;
      };
      const queuedUser = queuedRequest.prompt.filter((message) =>
        message.role === "user"
      ).at(-1);
      expect(queuedUser).toBeDefined();
      expect(Array.isArray(queuedUser!.content)).toBe(true);
      const queuedParts = queuedUser!.content as Array<Record<string, unknown>>;
      expect(queuedParts.filter((part) => part.type === "file")).toEqual([{
        type: "file",
        mediaType: "image/png",
        data: expectedImageData,
      }]);
      expect(countOccurrences(queuedBody, oldGlobalRule)).toBe(1);
      expect(countOccurrences(queuedBody, oldAncestorRule)).toBe(1);
      expect(countOccurrences(queuedBody, oldRootRule)).toBe(1);
      expect(countOccurrences(queuedBody, oldNestedRule)).toBe(1);
      expect(queuedBody.indexOf(oldGlobalRule)).toBeLessThan(
        queuedBody.indexOf(oldAncestorRule),
      );
      expect(queuedBody.indexOf(oldAncestorRule)).toBeLessThan(
        queuedBody.indexOf(oldRootRule),
      );
      expect(queuedBody.indexOf(oldRootRule)).toBeLessThan(
        queuedBody.indexOf(oldNestedRule),
      );
      expect(queuedBody).not.toContain(oldSiblingRule);
      expect(queuedBody).not.toContain(newGlobalRule);
      expect(queuedBody).not.toContain(newAncestorRule);
      expect(queuedBody).not.toContain(newRootRule);
      expect(queuedBody).not.toContain(newNestedRule);
      expect(queuedBody).not.toContain(newSiblingRule);

      const finalScrollback = await session.captureFullScrollbackEscapes();
      const beforeIndex = finalScrollback.indexOf(activeBefore.trim());
      const afterIndex = finalScrollback.indexOf(activeAfter.trim());
      const queuedPromptIndex = finalScrollback.indexOf(queuedPrompt);
      const queuedDoneIndex = finalScrollback.indexOf(queuedDone);
      const summaryOffset = finalScrollback
        .slice(afterIndex)
        .search(
          / {2}(?:\d+s|\d+m \d+s|\d+h \d{2}m) \(↑\d+(?:\.\d)?k? ↓\d+(?:\.\d)?k?\)/,
        );
      const firstSummaryAfterActiveIndex =
        summaryOffset < 0 ? -1 : afterIndex + summaryOffset;
      expect(beforeIndex).toBeGreaterThanOrEqual(0);
      expect(afterIndex).toBeGreaterThan(beforeIndex);
      expect(firstSummaryAfterActiveIndex).toBeGreaterThan(afterIndex);
      expect(firstSummaryAfterActiveIndex).toBeLessThan(queuedPromptIndex);
      expect(queuedPromptIndex).toBeGreaterThan(afterIndex);
      expect(queuedDoneIndex).toBeGreaterThan(queuedPromptIndex);
      expect(countOccurrences(finalScrollback, queuedPrompt)).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "active /permissions preserves a held post-tool turn and next prompt",
    async () => {
      const artifacts = createArtifactRoot();
      const home = join(artifacts, "home");
      const workspacePath = join(artifacts, "workspace");
      const stderrPath = join(artifacts, "stderr.log");
      const readFilename = "ACTIVE_PERMISSION_READ_SENTINEL.txt";
      const toolHeader = "● 1 tool call · 1 read";
      const toolMarker = `└ Read ${readFilename}`;
      const permissionMarker = "● Permissions: mode=auto";
      const activeBefore = "ACTIVE_PERMISSION_BEFORE_SENTINEL\n";
      const activeAfter = "ACTIVE_PERMISSION_AFTER_SENTINEL\n";
      const followupPrompt = "ACTIVE_PERMISSION_FOLLOWUP_PROMPT_SENTINEL";
      const followupResponse = "ACTIVE_PERMISSION_FOLLOWUP_RESPONSE_SENTINEL";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(join(workspacePath, readFilename), "active permission fixture\n");
      const workspace = realpathSync(workspacePath);
      const hold: HoldState = { started: false, cancelled: false };
      const heldGateway = startFakeGateway([
        fakeGatewayToolCall(
          "active_permission_read",
          "read_file",
          { path: readFilename },
        ),
        () => splitHeldTextResponse(hold, activeBefore, activeAfter),
        fakeGatewayFinalText(followupResponse),
      ]);
      gateway = heldGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-active-permission-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: heldGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Exercise the active permissions fixture.");
      await waitForCondition(
        () => heldGateway.requests.length === 2 && hold.started,
        "held post-tool continuation",
      );

      await session.sendText("/permissions");
      await waitForEscapedScrollback(
        session,
        (candidate) => {
          const visible = normalizedPaneText(candidate);
          return heldGateway.requests.length === 2 &&
            hold.started &&
            visible.includes(toolHeader) &&
            visible.includes(toolMarker) &&
            visible.includes(permissionMarker) &&
            visible.includes("Thinking");
        },
        "local permissions output during held post-tool continuation",
      );
      expect(heldGateway.requests).toHaveLength(2);
      expect(hold.cancelled).toBe(false);

      hold.release?.();
      await session.waitForPane(
        (pane) =>
          pane.includes(activeBefore.trim()) &&
          pane.includes(activeAfter.trim()) &&
          !pane.includes("Thinking"),
        TIMEOUT,
      );
      expect(heldGateway.requests).toHaveLength(2);

      await session.sendText(followupPrompt);
      await waitForCondition(
        () => heldGateway.requests.length === 3,
        "follow-up Gateway request",
      );
      await session.waitForText(followupResponse, TIMEOUT);
      await session.waitForPane(
        (pane) => pane.includes(followupResponse) && !pane.includes("Thinking"),
        TIMEOUT,
      );

      const followupRequest = JSON.parse(heldGateway.requests[2]!.body) as {
        prompt: Array<{ role: string; content: unknown }>;
      };
      const followupContext = JSON.stringify(followupRequest.prompt);
      expect(followupContext).toContain(readFilename);
      expect(followupContext).toContain(activeBefore.trim());
      expect(followupContext).toContain(activeAfter.trim());
      expect(followupContext).toContain(followupPrompt);
      expect(heldGateway.requests).toHaveLength(3);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "Up pauses queued admission and commits every edited prompt in FIFO order",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-review-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const activeAfter = "ACTIVE_FINISHED_WHILE_QUEUE_PAUSED";
      const firstQueued = "Continue with QUEUE_REVIEW_FIRST_SENTINEL.";
      const firstEdited = " QUEUE_REVIEW_EDITED_SENTINEL";
      const secondQueued = "Continue with QUEUE_REVIEW_SECOND_SENTINEL.";
      const secondEdited = " QUEUE_REVIEW_SECOND_EDITED_SENTINEL";
      const firstDone = "QUEUE_REVIEW_FIRST_DONE";
      const secondDone = "QUEUE_REVIEW_SECOND_DONE";
      const queuedGateway = startFakeGateway([
        () => splitHeldTextResponse(hold, "ACTIVE_QUEUE_REVIEW_STARTED\n", activeAfter),
        fakeGatewayFinalText(firstDone),
        fakeGatewayFinalText(secondDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-review-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the active queue review turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for manual queue review",
      );
      await session.sendText(firstQueued);
      await session.sendText(secondQueued);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(2)) &&
          !pane.includes(firstQueued) &&
          !pane.includes(secondQueued),
        TIMEOUT,
      );

      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(secondQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      const queuedCardLine = (await session.capturePaneEscapes())
        .split("\n")
        .find((line) => line.includes(firstQueued));
      expect(queuedCardLine).toBeDefined();
      expect(queuedCardLine).toContain("┃");
      expect(queuedCardLine).not.toContain("\x1b[48;");
      await session.sendLiteral(secondEdited);
      await session.waitForPane(
        (pane) => pane.includes(secondQueued + secondEdited),
        TIMEOUT,
      );
      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(firstQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );

      hold.release?.();
      await session.waitForText(activeAfter, TIMEOUT);
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=stream_complete"),
        "active stream completion while queue review is paused",
      );
      await Bun.sleep(250);
      expect(queuedGateway.requests).toHaveLength(1);
      expect(hold.cancelled).toBe(false);

      await session.pasteText(firstEdited);
      await session.sendKeys("Enter");
      await session.waitForText(secondDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 3,
        "edited and remaining queued prompts in FIFO order",
      );

      const firstQueuedBody = queuedGateway.requests[1].body;
      const secondQueuedBody = queuedGateway.requests[2].body;
      const trace = readFileSync(tracePath, "utf8");
      expect(firstQueuedBody).toContain(firstQueued);
      expect(firstQueuedBody).toContain(firstEdited.trim());
      expect(firstQueuedBody).not.toContain(secondQueued);
      expect(secondQueuedBody).toContain(secondQueued);
      expect(secondQueuedBody).toContain(secondEdited.trim());
      expect(trace).toContain("event=queue_review_started");
      expect(trace).toContain("reason=manual");
      expect(trace).toContain("event=queue_review_committed");
      expect(trace).toContain("event=queue_review_batch_committed");
      expect(trace).toContain("event=queue_review_resumed");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "Escape hides a focused queue editor without cancelling the active stream",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-review-escape-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const queuedPrompt = "Keep QUEUE_ESCAPE_FOCUS_SENTINEL pending.";
      const editorSuffix = " QUEUE_ESCAPE_EDITOR_SUFFIX";
      const composerText = "NEW_COMPOSER_OWNER";
      const queuedGateway = startFakeGateway([
        () =>
          splitHeldTextResponse(
            hold,
            "ACTIVE_QUEUE_ESCAPE_STARTED\n",
            "ACTIVE_QUEUE_ESCAPE_FINISHED",
          ),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-review-escape-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the queue Escape ownership turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for queue Escape ownership",
      );
      await session.sendText(queuedPrompt);
      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedPrompt) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      await session.sendLiteralText(editorSuffix);
      await session.waitForText(queuedPrompt + editorSuffix, TIMEOUT);

      await session.sendKeys("Escape");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=queue_review_hidden"),
        "hidden queue review before stream cancellation",
      );
      await session.waitForPane(
        (pane) => pane.includes("Thinking"),
        TIMEOUT,
      );
      expect(hold.cancelled).toBe(false);

      await session.sendLiteralText(composerText);
      await session.waitForPane(
        (pane) =>
          pane.includes(composerText) &&
          !pane.includes(queuedPrompt + editorSuffix + composerText),
        TIMEOUT,
      );

      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("event=queue_review_hidden");
      expect(trace).not.toContain("event=cancel_requested");
      expect(queuedGateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "queued review preserves pasted backing and follows a long draft cursor",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-semantic-drafts-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const pastedPrompt =
        `QUEUE_PASTE_START_${"q".repeat(5000)}_QUEUE_PASTE_END`;
      const pastedEdit = "Z";
      const longPrompt =
        `QUEUE_CURSOR_HEAD_${"e".repeat(1800)}_QUEUE_CURSOR_TAIL`;
      const longEdit = "_EDITED_AT_TAIL";
      const pastedDone = "QUEUE_PASTE_DONE";
      const longDone = "QUEUE_CURSOR_DONE";
      const queuedGateway = startFakeGateway([
        () =>
          splitHeldTextResponse(
            hold,
            "ACTIVE_SEMANTIC_QUEUE_STARTED\n",
            "ACTIVE_SEMANTIC_QUEUE_FINISHED",
          ),
        fakeGatewayFinalText(pastedDone),
        fakeGatewayFinalText(longDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 80,
        height: 24,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-semantic-draft-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the semantic queue review turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for semantic queue review",
      );

      await session.pasteText(pastedPrompt);
      await session.waitForPane(
        (pane) => pane.includes("[Pasted text #"),
        TIMEOUT,
      );
      await session.sendKeys("Enter");
      await session.sendLiteralText(longPrompt);
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => pane.includes(queuedSummaryText(2)),
        TIMEOUT,
      );

      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes("QUEUE_CURSOR_TAIL") &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      let { cursor, grid } = await waitForCursorRow(
        session,
        "QUEUE_CURSOR_TAIL",
        "long queued draft cursor row",
      );
      expect(grid[cursor.row]).toContain("QUEUE_CURSOR_TAIL");
      await session.sendLiteral(longEdit);
      await session.waitForPane((pane) => pane.includes(longEdit), TIMEOUT);

      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) => pane.includes("[Pasted text #") && pane.includes("paused"),
        TIMEOUT,
      );
      ({ cursor, grid } = await waitForCursorRow(
        session,
        "[Pasted text #",
        "pasted queued draft cursor row",
      ));
      expect(grid[cursor.row]).toContain("[Pasted text #");
      await session.sendLiteral(pastedEdit);
      await session.waitForPane((pane) => pane.includes("]Z"), TIMEOUT);

      await session.sendKeys("Enter");
      hold.release?.();
      await session.waitForText(longDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 3,
        "semantic queued prompts after active turn",
      );

      expect(queuedGateway.requests[1].body).toContain(
        pastedPrompt + pastedEdit,
      );
      expect(queuedGateway.requests[2].body).toContain(longPrompt + longEdit);
      expect(readFileSync(tracePath, "utf8")).toContain(
        "event=queue_review_batch_committed",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 3,
  );

  test(
    "queued review shows file completions and preserves the accepted path",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-file-picker-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(workspacePath, "src"), { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(
        join(workspacePath, "src", "main.zig"),
        "pub fn main() void {}\n",
      );
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const olderPrompt = "OLDER_QUEUE_DRAFT";
      const completedPrompt = "Review @src/main.zig";
      const queuedDone = "QUEUE_FILE_PICKER_DONE";
      const queuedGateway = startFakeGateway([
        () =>
          splitHeldTextResponse(
            hold,
            "ACTIVE_FILE_PICKER_QUEUE_STARTED\n",
            "ACTIVE_FILE_PICKER_QUEUE_FINISHED",
          ),
        fakeGatewayFinalText(olderPrompt),
        fakeGatewayFinalText(queuedDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 80,
        height: 24,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-file-picker-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the queued file picker turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for queued file picker",
      );
      await session.sendText(olderPrompt);
      await session.sendText(completedPrompt);
      await session.waitForPane(
        (pane) => pane.includes(queuedSummaryText(2)),
        TIMEOUT,
      );

      await session.sendKeys("Up");
      await session.waitForText("paused", TIMEOUT);
      await session.sendKeys("BSpace BSpace BSpace BSpace");
      await session.waitForPane(
        (pane) =>
          pane.includes("Review @src/main") &&
          pane.includes("src/main.zig"),
        TIMEOUT,
      );
      await session.sendKeys("Up");
      await session.waitForText(olderPrompt, TIMEOUT);
      await session.sendKeys("Down");
      await session.waitForPane(
        (pane) =>
          pane.includes("Review @src/main") &&
          pane.includes("src/main.zig"),
        TIMEOUT,
      );

      await session.sendKeys("Enter");
      await session.waitForText(completedPrompt, TIMEOUT);
      await session.sendKeys("Up");
      await session.waitForText(olderPrompt, TIMEOUT);
      await session.sendKeys("Down");
      await session.waitForText(completedPrompt, TIMEOUT);
      await session.sendKeys("Enter");

      hold.release?.();
      await session.waitForText(queuedDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 3,
        "queued prompts after file picker review",
      );

      expect(queuedGateway.requests[2].body).toContain(completedPrompt);
      expect(readFileSync(tracePath, "utf8")).toContain(
        "file picker Enter consumed selected=true",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 3,
  );

  test(
    "streaming model selection applies to the next turn without changing the active request",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-next-turn-model-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          model: GLM_MODEL,
          effort: "auto",
          fast_mode: false,
        }),
      );
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const nextModel = "openai/gpt-5";
      const nextTurnDone = "NEXT_TURN_MODEL_SELECTION_DONE";
      const queuedGateway = startFakeGateway(
        [
          () =>
            splitHeldTextResponse(
              hold,
              "ACTIVE_ORIGINAL_MODEL_STARTED\n",
              "ACTIVE_ORIGINAL_MODEL_FINISHED",
            ),
          fakeGatewayFinalText(nextTurnDone),
        ],
        {
          models: [
            { id: GLM_MODEL, type: "language", tags: ["tool-use"] },
            {
              id: nextModel,
              type: "language",
              tags: ["reasoning", "tool-use"],
              reasoning_options: [{ type: "effort", values: ["low", "high"] }],
            },
          ],
        },
      );
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 80,
        height: 24,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-next-turn-model-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the original model turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held original-model request",
      );
      await waitForCondition(
        () => queuedGateway.modelRequests.length > 0,
        "next-turn model catalog warmup",
      );

      await session.sendLiteralText(`/model ${nextModel}`);
      await session.sendKeys("Space");
      await session.sendLiteralText("auto");
      await session.waitForPane(
        (pane) => composerContains(pane, `/model ${nextModel} auto`),
        TIMEOUT,
      );
      await session.sendKeys("Enter");
      await session.waitForText(`Next turn will use ${nextModel}`, TIMEOUT);

      expect(queuedGateway.requests).toHaveLength(1);
      expect(
        queuedGateway.requests[0]!.headers.get("ai-language-model-id"),
      ).toBe(GLM_MODEL);
      expect(hold.cancelled).toBe(false);
      expect(hasEmptyComposer(await session.capturePane())).toBe(true);

      hold.release?.();
      await session.waitForText("ACTIVE_ORIGINAL_MODEL_FINISHED", TIMEOUT);
      await session.sendText("Use the selected model now.");
      await session.waitForText(nextTurnDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "next-turn selected-model request",
      );

      expect(
        queuedGateway.requests[1]!.headers.get("ai-language-model-id"),
      ).toBe(nextModel);
      expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")))
        .toMatchObject({ model: nextModel, effort: "auto" });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 3,
  );

  test(
    "queued review keeps the disabled model picker hidden",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-model-picker-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const hiddenModel = "provider/queued-hidden-model";
      const queuedGateway = startFakeGateway(
        [
          () =>
            splitHeldTextResponse(
              hold,
              "ACTIVE_MODEL_PICKER_QUEUE_STARTED\n",
              "ACTIVE_MODEL_PICKER_QUEUE_FINISHED",
            ),
        ],
        {
          models: [
            { id: MODEL, type: "language", tags: ["tool-use"] },
            { id: hiddenModel, type: "language", tags: ["tool-use"] },
          ],
        },
      );
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 80,
        height: 24,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-model-picker-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the queued model picker turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for queued model picker",
      );
      await waitForCondition(
        () => queuedGateway.modelRequests.length > 0,
        "queued model picker catalog warmup",
      );
      await session.sendText("QUEUED_MODEL_PICKER_DRAFT");
      await session.waitForPane(
        (pane) => pane.includes(queuedSummaryText(1)),
        TIMEOUT,
      );

      await session.sendKeys("Up");
      await session.waitForText("paused", TIMEOUT);
      await session.sendKeys("C-u");
      await session.sendLiteralText("/model provider/queued-hidden");
      await session.waitForPane(
        (pane) => pane.includes("/model provider/queued-hidden"),
        TIMEOUT,
      );
      await Bun.sleep(200);

      let pane = await session.capturePane();
      expect(pane).not.toContain(hiddenModel);
      await session.sendKeys("Tab");
      pane = await session.capturePane();
      expect(pane).toContain("/model provider/queued-hidden");
      expect(pane).not.toContain(hiddenModel);
      await session.sendKeys("Enter");
      pane = await session.capturePane();
      expect(pane).toContain("/model provider/queued-hidden");
      expect(pane).not.toContain(hiddenModel);
      expect(queuedGateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "empty Enter resumes a hidden paused queue without editing it",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-empty-enter-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const queuedPrompt = "Continue with EMPTY_ENTER_QUEUE_SENTINEL.";
      const queuedDone = "EMPTY_ENTER_QUEUE_DONE";
      const queuedGateway = startFakeGateway([
        () =>
          splitHeldTextResponse(
            hold,
            "ACTIVE_EMPTY_ENTER_STARTED\n",
            "ACTIVE_EMPTY_ENTER_FINISHED",
          ),
        fakeGatewayFinalText(queuedDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-empty-enter-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the empty Enter queue turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for empty Enter queue review",
      );
      await session.sendText(queuedPrompt);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(1)) &&
          !pane.includes(queuedPrompt),
        TIMEOUT,
      );
      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedPrompt) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      await session.sendKeys("Down");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=queue_review_hidden"),
        "hidden queue review after Down before empty Enter",
      );

      await session.sendKeys("Enter");
      await waitForCondition(
        () =>
          readFileSync(tracePath, "utf8").includes(
            "event=queue_review_finished source=unchanged_queue",
          ),
        "unchanged queue submission from empty composer",
      );
      expect(queuedGateway.requests).toHaveLength(1);

      hold.release?.();
      await session.waitForText(queuedDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "unchanged queued prompt after active turn",
      );

      const trace = readFileSync(tracePath, "utf8");
      expect(queuedGateway.requests[1].body).toContain(queuedPrompt);
      expect(trace).toContain("event=queue_review_resumed");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "Up edits a queued card in place and repeated Ctrl+U deletes only the empty draft",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-inline-delete-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: SplitHoldState = { started: false, cancelled: false };
      const firstQueued = "Keep QUEUE_INLINE_FIRST_SENTINEL.";
      const firstQueuedEdit = " this";
      const secondQueued = "Delete QUEUE_INLINE_SECOND_SENTINEL.";
      const firstDone = "QUEUE_INLINE_FIRST_DONE";
      const queuedGateway = startFakeGateway([
        () =>
          splitHeldTextResponse(
            hold,
            "ACTIVE_QUEUE_INLINE_STARTED\n",
            "ACTIVE_QUEUE_INLINE_FINISHED",
          ),
        fakeGatewayFinalText(firstDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-inline-delete-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the inline queue editor turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for inline queue editing",
      );
      await session.sendText(firstQueued);
      await session.sendText(secondQueued);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(2)) &&
          !pane.includes(firstQueued) &&
          !pane.includes(secondQueued),
        TIMEOUT,
      );

      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(secondQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      let { cursor, grid } = await waitForCursorRow(
        session,
        secondQueued,
        "second queued draft cursor row",
      );
      expect(grid[cursor.row]).toContain(secondQueued);
      const pausedRow = grid.findIndex((line) => line.includes("paused"));
      const emptyComposerRow = grid.findIndex(
        (line, index) => index > pausedRow && isEmptyComposerLine(line),
      );
      expect(pausedRow).toBeGreaterThanOrEqual(0);
      expect(emptyComposerRow).toBeGreaterThan(pausedRow);
      expect(cursor.row).not.toBe(emptyComposerRow);

      await session.sendKeys("Up");
      await session.waitForPane((pane) => pane.includes(firstQueued), TIMEOUT);
      await session.sendKeys("Left");
      await session.sendKeys("Right");
      await session.sendLiteral(firstQueuedEdit);
      await session.waitForPane(
        (pane) => pane.includes(firstQueued + firstQueuedEdit),
        TIMEOUT,
      );
      await session.sendKeys("Down");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes(
            "event=queue_review_navigate direction=newer index=1",
          ),
        "edited draft followed by newer queue navigation",
      );
      ({ cursor, grid } = await waitForCursorRow(
        session,
        secondQueued,
        "newer queued draft cursor row",
      ));
      expect(grid[cursor.row]).toContain(secondQueued);
      await session.waitForPane(
        (pane) => pane.includes(firstQueued + firstQueuedEdit),
        TIMEOUT,
      );

      await session.sendKeys("C-u");
      await session.waitForPane(
        (pane) =>
          pane.includes(firstQueued) &&
          !pane.includes(secondQueued) &&
          pane.includes("delete again to remove queued prompt") &&
          pane.includes("enter to send unchanged"),
        TIMEOUT,
      );
      await session.sendKeys("C-u");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes(
            "event=queue_review_draft_deleted",
          ),
        "selected empty queued draft deletion",
      );
      await session.waitForPane(
        (pane) =>
          pane.includes(firstQueued) &&
          !pane.includes(secondQueued) &&
          pane.includes("queued 1"),
        TIMEOUT,
      );
      ({ cursor, grid } = await waitForCursorRow(
        session,
        firstQueued,
        "remaining queued draft cursor row",
      ));
      expect(grid[cursor.row]).toContain(firstQueued);
      expect(queuedGateway.requests).toHaveLength(1);

      await session.sendKeys("Enter");
      hold.release?.();
      await session.waitForText(firstDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "remaining queued prompt after inline deletion",
      );

      const trace = readFileSync(tracePath, "utf8");
      expect(queuedGateway.requests[1].body).toContain(
        firstQueued + firstQueuedEdit,
      );
      expect(queuedGateway.requests[1].body).not.toContain(secondQueued);
      expect(trace).toContain("event=queue_review_deleted");
      expect(trace).toContain("event=queue_review_draft_deleted");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "queued image yank survives deleting its queue card",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-image-yank-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const imagePath = join(workspacePath, "queued-image.png");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      copyFileSync(
        join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
        imagePath,
      );
      const workspace = realpathSync(workspacePath);
      const image = realpathSync(imagePath);
      const expectedImageData = readFileSync(image).toString("base64");
      const hold: HoldState = { started: false, cancelled: false };
      const queuedPrompt = "Describe FXC141_QUEUED_IMAGE_YANK.";
      const done = "FXC141_QUEUED_IMAGE_YANK_DONE";
      const queuedGateway = startFakeGateway(
        [
          () =>
            heldGatewayResponse(hold, [
              { type: "text-start", id: "answer_1" },
              {
                type: "text-delta",
                id: "answer_1",
                delta: "ACTIVE_QUEUED_IMAGE_YANK_STARTED\n",
              },
            ]),
          fakeGatewayFinalText(done),
        ],
        {
          models: [{
            id: MODEL,
            type: "language",
            tags: ["vision", "file-input", "tool-use"],
          }],
        },
      );
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 100,
        height: 30,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-image-yank-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the queued image yank turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for queued image yank",
      );
      await session.sendText(`/image ${image}`);
      await session.waitForText("attached image: queued-image.png", TIMEOUT);
      await session.sendText(queuedPrompt);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(1)) &&
          !pane.includes(queuedPrompt),
        TIMEOUT,
      );
      rmSync(image);

      await session.sendKeys("C-c");
      await waitForCondition(() => hold.cancelled, "queued image active request cancellation");
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedPrompt) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );

      await session.sendKeys("End");
      await session.sendKeys("C-u");
      await session.waitForPane(
        (pane) =>
          !pane.includes(queuedPrompt) &&
          pane.includes("delete again to remove queued prompt"),
        TIMEOUT,
      );
      await session.sendKeys("C-k");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes(
            "event=queue_review_draft_deleted",
          ),
        "empty queued image card deletion",
      );

      await session.sendKeys("C-y");
      await session.waitForPane(
        (pane) =>
          pane.includes("[Image 2]") &&
          pane.includes("FXC141_QUEUED_IMAGE_YANK"),
        TIMEOUT,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      await session.sendKeys("Enter");
      await session.waitForText(done, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "yanked image Gateway request",
      );

      const yankedBody = queuedGateway.requests[1]!.body;
      const trace = readFileSync(tracePath, "utf8");
      expect(yankedBody.match(/"type":"file"/g) ?? []).toHaveLength(1);
      expect(yankedBody).toContain(expectedImageData);
      expect(yankedBody).toContain("[Image #2]" + queuedPrompt);
      expect(yankedBody).not.toContain(image);
      expect(trace).toContain("event=queue_review_started");
      expect(trace).toContain("reason=post_cancel");
      expect(trace).toContain("event=queue_review_deleted");
      expect(trace).toContain("event=queue_review_draft_deleted");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "Ctrl+C pauses two queued prompts until the visible draft is confirmed",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-post-cancel-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: HoldState = { started: false, cancelled: false };
      const firstQueued = "Continue with FOLLOWUP_FIRST_SENTINEL.";
      const firstEdited = " FOLLOWUP_EDITED_SENTINEL";
      const secondQueued = "Continue with FOLLOWUP_SECOND_SENTINEL.";
      const firstDone = "FOLLOWUP_FIRST_DONE";
      const secondDone = "FOLLOWUP_SECOND_DONE";
      const queuedGateway = startFakeGateway([
        () =>
          heldGatewayResponse(hold, [
            { type: "text-start", id: "answer_1" },
            {
              type: "text-delta",
              id: "answer_1",
              delta: "ACTIVE_POST_CANCEL_REVIEW_STARTED\n",
            },
          ]),
        fakeGatewayFinalText(firstDone),
        fakeGatewayFinalText(secondDone),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-post-cancel-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the active post-cancel turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request for post-cancel queue review",
      );
      await session.sendText(firstQueued);
      await session.sendText(secondQueued);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(2)) &&
          !pane.includes(firstQueued) &&
          !pane.includes(secondQueued),
        TIMEOUT,
      );
      expect(queuedGateway.requests).toHaveLength(1);
      await session.sendKeys("C-c");
      await waitForCondition(() => hold.cancelled, "active request cancellation");
      await session.waitForPane(
        (pane) =>
          pane.includes(secondQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      await Bun.sleep(250);
      expect(queuedGateway.requests).toHaveLength(1);

      await session.sendKeys("Escape");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=queue_review_hidden"),
        "hidden post-cancel queue draft",
      );
      await Bun.sleep(250);
      expect(queuedGateway.requests).toHaveLength(1);

      await session.sendText("/status");
      await Bun.sleep(250);
      expect(queuedGateway.requests).toHaveLength(1);
      expect(readFileSync(tracePath, "utf8")).not.toContain(
        "event=queue_review_resumed",
      );

      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(secondQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      await session.sendKeys("Up");
      await session.waitForPane(
        (pane) =>
          pane.includes(firstQueued) &&
          pane.includes("paused") &&
          pane.includes("enter to send"),
        TIMEOUT,
      );
      await session.pasteText(firstEdited);
      await session.sendKeys("Enter");
      await session.waitForText(secondDone, TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 3,
        "post-cancel edited and remaining queued prompts",
      );

      const firstQueuedBody = queuedGateway.requests[1].body;
      const secondQueuedBody = queuedGateway.requests[2].body;
      const trace = readFileSync(tracePath, "utf8");
      expect(firstQueuedBody).toContain(firstQueued);
      expect(firstQueuedBody).toContain(firstEdited.trim());
      expect(firstQueuedBody).not.toContain(secondQueued);
      expect(secondQueuedBody).toContain(secondQueued);
      expect(trace).toContain("event=queue_review_started");
      expect(trace).toContain("reason=post_cancel");
      expect(trace).toContain("event=queue_review_hidden");
      expect(trace).toContain("event=queue_review_committed");
      expect(trace).toContain("event=queue_review_resumed");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  for (const scenario of [
    { name: "at stable geometry", slug: "stable", resize: null },
    {
      name: "after a settled resize",
      slug: "resized",
      resize: { width: 68, height: 18 },
    },
  ]) {
    test(
      `queue resume preserves streamed scrollback ${scenario.name}`,
      async () => {
        const artifactBase = createArtifactRoot();
        const artifacts = join(artifactBase, scenario.slug);
        const home = join(artifacts, "home");
        const workspace = join(artifacts, "workspace");
        const tracePath = join(artifacts, "trace.log");
        const stderrPath = join(artifacts, "stderr.log");
        const tapePath = join(artifacts, "session.fxtape");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            sandbox: "none",
            permission_mode: "auto",
            permission: {},
          }),
        );

        const numberedLines = Array.from(
          { length: 24 },
          (_, index) => `QUEUE_SCROLLBACK_LINE_${String(index + 1).padStart(2, "0")}`,
        );
        const firstQueued = "QUEUE_SCROLLBACK_FIRST_PROMPT";
        const secondQueued = "QUEUE_SCROLLBACK_SECOND_PROMPT";
        const draft = "QUEUE_SCROLLBACK_DRAFT_PROMPT";
        const firstDone = "QUEUE_SCROLLBACK_FIRST_DONE";
        const secondDone = "QUEUE_SCROLLBACK_SECOND_DONE";
        const draftDone = "QUEUE_SCROLLBACK_DRAFT_DONE";
        const queuedGateway = startFakeGateway([
          fakeGatewaySse([
            { type: "text-start", id: "answer_1" },
            ...numberedLines.map((line) => ({
              type: "text-delta",
              id: "answer_1",
              delta: `${line}\n`,
            })),
            { type: "text-end", id: "answer_1" },
            {
              type: "tool-call",
              toolCallId: "queue_scrollback_command",
              toolName: "terminal",
              input: { action: "exec", command: "sleep 30" },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          fakeGatewayFinalText(firstDone),
          fakeGatewayFinalText(secondDone),
          fakeGatewayFinalText(draftDone),
        ]);
        gateway = queuedGateway;

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          stderrPath,
          width: 124,
          height: 36,
          minimumHistoryLines: 2_000,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "fake-queue-scrollback-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_PERMISSION_MODE: "auto",
            FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
            FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
            FX_MODEL: MODEL,
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt,scroll",
          },
        });

        await session.waitForComposer(TIMEOUT);
        await session.sendText("Start the queue scrollback stream.");
        await session.waitForText("Running sleep 30", TIMEOUT);
        await session.waitForText(numberedLines.at(-1)!, TIMEOUT);

        await session.sendText(firstQueued);
        await session.sendText(secondQueued);
        await session.waitForPane(
          (pane) =>
            pane.includes(queuedSummaryText(2)) &&
            !pane.includes(firstQueued) &&
            !pane.includes(secondQueued),
          TIMEOUT,
        );
        await session.sendLiteral(draft);
        await session.waitForText(draft, TIMEOUT);

        await session.sendKeys("C-o");
        await Bun.sleep(250);
        await session.sendKeys("Right");
        await Bun.sleep(250);
        await session.sendKeys("C-o");
        await session.waitForText(draft, TIMEOUT);
        if (scenario.resize) {
          await session.resizeWindow(scenario.resize.width, scenario.resize.height);
          await session.waitForText(draft, TIMEOUT);
        }

        await session.sendKeys("C-c");
        await session.waitForPane(
          (pane) =>
            pane.includes("Cancelled sleep 30") &&
            pane.includes("paused") &&
            pane.includes("enter to send"),
          TIMEOUT,
        );
        expect(queuedGateway.requests).toHaveLength(1);

        await session.sendKeys("Enter");
        await session.waitForText(draftDone, TIMEOUT);
        await waitForCondition(
          () => queuedGateway.requests.length === 4,
          "resumed queued prompts and submitted draft",
        );

        const scrollback = await session.captureFullScrollback();
        for (const line of numberedLines) {
          expect(countOccurrences(scrollback, line)).toBe(1);
        }
        for (const text of [
          firstQueued,
          firstDone,
          secondQueued,
          secondDone,
          draft,
          draftDone,
        ]) {
          expect(countOccurrences(scrollback, text)).toBe(1);
        }
        const orderedMarkers = [
          numberedLines[0]!,
          numberedLines.at(-1)!,
          firstQueued,
          firstDone,
          secondQueued,
          secondDone,
          draft,
          draftDone,
        ];
        for (let index = 1; index < orderedMarkers.length; index += 1) {
          expect(scrollback.indexOf(orderedMarkers[index - 1]!)).toBeLessThan(
            scrollback.indexOf(orderedMarkers[index]!),
          );
        }

        expect(queuedGateway.requests[1]!.body).toContain(firstQueued);
        expect(queuedGateway.requests[2]!.body).toContain(secondQueued);
        expect(queuedGateway.requests[3]!.body).toContain(draft);

        const sessionsRoot = join(home, ".fx", "sessions");
        let eventsPath = "";
        await waitForCondition(() => {
          if (!existsSync(sessionsRoot)) return false;
          const sessionId = readdirSync(sessionsRoot).find((entry) =>
            existsSync(join(sessionsRoot, entry, "events.jsonl"))
          );
          if (!sessionId) return false;
          eventsPath = join(sessionsRoot, sessionId, "events.jsonl");
          return readFileSync(eventsPath, "utf8").includes(draftDone);
        }, "complete queue scrollback session history");
        const events = readFileSync(eventsPath, "utf8");
        for (const marker of [...numberedLines, firstQueued, secondQueued, draft]) {
          expect(events).toContain(marker);
        }

        const trace = readFileSync(tracePath, "utf8");
        expect(
          trace.split("\n").some((line) =>
            line.includes("transcript_anchor_invalidate") &&
            line.includes("atomic_user_prompt_append")
          ),
        ).toBe(false);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(existsSync(tapePath)).toBe(true);
        expect(
          execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
            encoding: "utf8",
          }),
        ).not.toBe("");
        expect(session.isAlive()).toBe(true);
        expect(session.isPaneAlive()).toBe(true);
      },
      TIMEOUT * 3,
    );
  }

  test(
    "post-cancel hidden queue offers Escape to cancel every queued prompt",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-queued-cancel-all-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);
      const hold: HoldState = { started: false, cancelled: false };
      const firstQueued = "Keep ESC_QUEUE_FIRST_SENTINEL pending.";
      const secondQueued = "Keep ESC_QUEUE_SECOND_SENTINEL pending.";
      const queuedGateway = startFakeGateway([
        () =>
          heldGatewayResponse(hold, [
            { type: "text-start", id: "answer_1" },
            {
              type: "text-delta",
              id: "answer_1",
              delta: "ACTIVE_ESC_QUEUE_CANCEL_ALL_STARTED\n",
            },
          ]),
      ]);
      gateway = queuedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-queued-cancel-all-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold the Escape cancel-all turn open.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held active request before Escape queue cancellation",
      );
      await session.sendText(firstQueued);
      await session.sendText(secondQueued);
      await session.waitForPane(
        (pane) =>
          pane.includes(queuedSummaryText(2)) &&
          !pane.includes(firstQueued) &&
          !pane.includes(secondQueued),
        TIMEOUT,
      );

      await session.sendKeys("C-c");
      await waitForCondition(() => hold.cancelled, "active request cancellation before queue cancel-all");
      await session.waitForPane(
        (pane) => pane.includes(secondQueued) && pane.includes("paused"),
        TIMEOUT,
      );

      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) => pane.includes("press esc to cancel all queued"),
        TIMEOUT,
      );
      expect(queuedGateway.requests).toHaveLength(1);

      await session.sendKeys("Escape");
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes(
            "event=queue_review_cancelled_all",
          ),
        "all queued prompts cancelled by Escape",
      );
      await session.waitForPane(
        (pane) =>
          !pane.includes(firstQueued) &&
          !pane.includes(secondQueued) &&
          !pane.includes("press esc to cancel all queued"),
        TIMEOUT,
      );
      await Bun.sleep(250);

      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("event=queued_prompts_cleared");
      expect(queuedGateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "second Ctrl+C exits after active stream cancellation",
    async () => {
      const artifacts = createArtifactRoot();
      const home = join(artifacts, "home");
      const workspace = join(artifacts, "workspace");
      const stderrPath = join(artifacts, "stderr.log");
      const tracePath = join(artifacts, "trace.log");
      const tapePath = join(artifacts, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const hold: HoldState = { started: false, cancelled: false };
      const heldGateway = startFakeGateway([
        () => heldGatewayResponse(hold),
      ]);
      gateway = heldGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        remainOnExit: true,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-active-ctrlc-exit-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: heldGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: heldGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "gateway,app,input,interrupt,worker,sse",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(
        "Write a slow long response in 120 numbered short lines. Start immediately and do not use tools.",
      );
      await waitForCondition(
        () => heldGateway.requests.length === 1 && hold.started,
        "held active stream",
      );
      await session.waitForText("Thinking", TIMEOUT);

      await session.sendKeys("C-c");
      const afterFirst = await session.waitForText("cancelled", TIMEOUT);
      await waitForCondition(() => hold.cancelled, "stream cancellation");
      expect(afterFirst).toContain("cancelled");
      expect(session.isPaneAlive()).toBe(true);

      const scrollbackAfterFirst = await session.captureFullScrollbackEscapes();
      expect(countOccurrences(scrollbackAfterFirst, "cancelled")).toBe(1);

      await session.sendKeys("C-c");
      await waitForCondition(
        () => !session!.isPaneAlive(),
        "pane exit after second Ctrl+C",
        3_000,
      );

      const scrollback = await session.captureFullScrollback();
      const trace = readFileSync(tracePath, "utf8");
      expect(scrollback).toContain("cancelled");
      expect(countOccurrences(scrollback, "cancelled")).toBe(1);
      expect(countOccurrences(trace, "source=input_active_stream")).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
          encoding: "utf8",
        }),
      ).not.toBe("");
    },
    TIMEOUT,
  );

  test(
    "Ctrl+C exit hint disarms for history recall, bare Escape, and idle expiry",
    async () => {
      const artifacts = createArtifactRoot();
      const home = join(artifacts, "home");
      const workspace = join(artifacts, "workspace");
      const stderrPath = join(artifacts, "stderr.log");
      const tracePath = join(artifacts, "trace.log");
      const tapePath = join(artifacts, "session.fxtape");
      const prompt = "Recall CTRL_C_EXIT_HISTORY_SENTINEL exactly.";
      const finalText = "CTRL_C_EXIT_HISTORY_DONE";
      const exitHint = "press ctrl+c again to exit";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        '{"prompt_history":{"enabled":true}}',
      );

      const fakeGateway = startFakeGateway([
        fakeGatewayFinalText(finalText),
      ]);
      gateway = fakeGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        remainOnExit: true,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-ctrl-c-history-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(prompt);
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () =>
          existsSync(tracePath) &&
          readFileSync(tracePath, "utf8").includes("event=stream_complete"),
        "completed prompt before Ctrl+C history recall",
      );

      await session.sendKeys("C-c");
      await session.waitForText(exitHint, TIMEOUT);
      await session.sendKeys("Up");
      const recalledPane = await session.waitForPane(
        (pane) => countOccurrences(pane, prompt) >= 2 && !pane.includes(exitHint),
        TIMEOUT,
      );
      expect(countOccurrences(recalledPane, prompt)).toBeGreaterThanOrEqual(2);
      expect(session.isPaneAlive()).toBe(true);

      await session.sendKeys("C-c");
      const rearmedPane = await session.waitForPane(
        (pane) =>
          countOccurrences(pane, prompt) === 1 &&
          pane.split("\n").some(isEmptyComposerLine) &&
          pane.includes(exitHint),
        TIMEOUT,
      );
      expect(rearmedPane).toContain(exitHint);
      expect(session.isPaneAlive()).toBe(true);

      await session.waitForPane(
        (pane) => !pane.includes(exitHint),
        5_000,
      );
      expect(session.isPaneAlive()).toBe(true);

      await session.sendKeys("C-c");
      await session.waitForText(exitHint, TIMEOUT);
      expect(session.isPaneAlive()).toBe(true);

      const semanticDisarm =
        "event=ctrl_c_exit_disarmed reason=semantic_action";
      const semanticDisarmsBeforeEscape = countOccurrences(
        readFileSync(tracePath, "utf8"),
        semanticDisarm,
      );
      await session.sendKeys("Escape");
      await waitForCondition(
        () =>
          countOccurrences(
            readFileSync(tracePath, "utf8"),
            semanticDisarm,
          ) === semanticDisarmsBeforeEscape + 1,
        "bare Escape semantic disarm",
        1_000,
      );
      await session.waitForPane((pane) => !pane.includes(exitHint), 1_000);
      expect(session.isPaneAlive()).toBe(true);

      await session.sendKeys("C-c");
      await session.waitForText(exitHint, TIMEOUT);
      expect(session.isPaneAlive()).toBe(true);

      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain(semanticDisarm);
      expect(trace).toContain("event=ctrl_c_exit_disarmed reason=timeout");

      await session.sendKeys("C-c");
      await waitForCondition(
        () => !session!.isPaneAlive(),
        "pane exit after valid second Ctrl+C",
        3_000,
      );

      expect(fakeGateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
          encoding: "utf8",
        }),
      ).not.toBe("");
    },
    TIMEOUT,
  );

  test(
    "canonical interleaved tool streams preserve ordering and lifecycle identity",
    async () => {
      const stage = lifecycleStage();
      const observed = await runCanonicalLifecycleFixture(stage);
      const normalizedPane = normalizedPaneText(observed.pane);

      expect(observed.fixtureSha256).toBe(CANONICAL_A_B_SHA256);
      expect(observed.wrapperAliveAtCapture).toBe(true);
      expect(observed.childAliveAtCapture).toBe(false);
      expect(observed.wrapperStatus).toBe(0);
      expect(observed.sttyAfter).toBe(observed.sttyBefore);

      if (stage === "baseline-silent" || stage === "fatal-reported") {
        expect(observed.childStatus).toBe(1);
        expect(observed.requestCount).toBe(1);
        expect(countTraceEvent(observed.trace, "before_tool_execution")).toBe(0);
        expect(observed.trace).toContain("LifecycleReconciliationCollision");
        expect(observed.pane).toContain("● Reading");
        expect(observed.pane).toContain(`Searching ${CANONICAL_GREP_PATTERN}`);
        expect(normalizedPane).not.toContain(CANONICAL_PRE_TOOL_TEXT);
        expect(observed.stderr).toBe(
          stage === "baseline-silent"
            ? ""
            : "fx: LifecycleReconciliationCollision\n",
        );
        return;
      }

      expect(observed.reachedFinal).toBe(true);
      expect(observed.helpVisible).toBe(true);
      expect(observed.childStatus).toBe(0);
      expect(observed.requestCount).toBe(2);
      expect(observed.requestCountAfterHelp).toBe(2);
      expect(observed.stderr).toBe("");
      expect(observed.trace).not.toContain("LifecycleReconciliationCollision");
      if (stage === "corrected") {
        expect(
          countOccurrences(normalizedPane, CANONICAL_PRE_TOOL_TEXT),
        ).toBe(1);
        expect(normalizedPane.indexOf(CANONICAL_PRE_TOOL_TEXT)).toBeLessThan(
          normalizedPane.indexOf(CANONICAL_READ_PATH),
        );
        expect(normalizedPane.indexOf(CANONICAL_PRE_TOOL_TEXT)).toBeLessThan(
          normalizedPane.indexOf(CANONICAL_GREP_PATTERN),
        );
      }
      expect(
        countOccurrences(normalizedPane, `● Read ${CANONICAL_READ_PATH}`),
      ).toBe(1);
      expect(
        countOccurrences(
          normalizedPane,
          `● Searched ${CANONICAL_GREP_PATTERN}`,
        ),
      ).toBe(1);
      expect(countOccurrences(normalizedPane, CANONICAL_FINAL_TEXT)).toBe(1);

      const resultIds = collectToolResultIds(observed.parsedRequests[1]).sort();
      expect(resultIds).toEqual(["grep_b", "read_a"]);
      expect(
        collectTypedToolResults(observed.parsedRequests[1]).sort((a, b) =>
          a.toolCallId.localeCompare(b.toolCallId)
        ),
      ).toEqual([
        {
          toolCallId: "grep_b",
          toolName: "grep_files",
          outputType: "text",
        },
        {
          toolCallId: "read_a",
          toolName: "read_file",
          outputType: "text",
        },
      ]);
      expect(countTraceEvent(observed.trace, "before_tool_execution", "read_a"))
        .toBe(1);
      expect(countTraceEvent(observed.trace, "before_tool_execution", "grep_b"))
        .toBe(1);
      for (
        const sentinel of [
          "FX_MODEL_TEXT_SENTINEL",
          "FX_FINAL_RESPONSE_SENTINEL",
          "FX_PATH_SENTINEL",
          "FX_PATTERN_SENTINEL",
        ]
      ) {
        expect(observed.trace).not.toContain(sentinel);
      }
    },
    60_000,
  );

  test(
    "parallel read lifecycle updates preserve full legacy scrollback",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-status-scrollback-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const pre_tool_lines = Array.from(
        { length: 10 },
        (_, index) => `SCROLL_PRE_${String(index + 1).padStart(2, "0")}`,
      );
      const final_text = "SCROLLBACK_FINAL_SENTINEL";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "legacy" }),
      );
      writeFileSync(join(workspace, "one.txt"), "first fixture\n");
      writeFileSync(join(workspace, "two.txt"), "second fixture\n");

      const scrollback_gateway = startFakeGateway([
        fakeGatewaySse([
          { type: "text-start", id: "scrollback_text" },
          {
            type: "text-delta",
            id: "scrollback_text",
            delta: `${pre_tool_lines.slice(0, 5).join("\n")}\n`,
          },
          {
            type: "text-delta",
            id: "scrollback_text",
            delta: `${pre_tool_lines.slice(5).join("\n")}\n`,
          },
          { type: "text-end", id: "scrollback_text" },
          {
            type: "tool-call",
            toolCallId: "scrollback_read_one",
            toolName: "read_file",
            input: { path: "one.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "scrollback_read_two",
            toolName: "read_file",
            input: { path: "two.txt" },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(final_text),
      ]);
      gateway = scrollback_gateway;
      session = await TmuxSession.create({
        cwd: workspace,
        width: 64,
        height: 16,
        minimumHistoryLines: 200,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-status-scrollback-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: scrollback_gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: scrollback_gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: scrollback_gateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Read both fixtures.");
      await session.waitForText(final_text, TIMEOUT);
      await Bun.sleep(250);
      const scrollback = await session.captureFullScrollback();

      let previous_index = -1;
      for (const line of pre_tool_lines) {
        expect(countOccurrences(scrollback, line)).toBe(1);
        const line_index = scrollback.indexOf(line);
        expect(line_index).toBeGreaterThan(previous_index);
        previous_index = line_index;
      }
      expect(scrollback).toContain("● Read one.txt");
      expect(scrollback).toContain("● Read two.txt");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "launch-row release preserves complete history during a large table append",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-launch-history-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "launch-history.fxtape");
      const prefillMarkers = Array.from(
        { length: 5_000 },
        (_, index) =>
          `PREFILL_HISTORY_ROW_${String(index + 1).padStart(4, "0")}`,
      );
      const tableMarkers = Array.from(
        { length: 27 },
        (_, index) => `TABLE_HISTORY_ROW_${String(index + 1).padStart(2, "0")}`,
      );
      const intro = "TABLE_HISTORY_INTRO";
      const tail = "TABLE_HISTORY_TAIL";
      const response = [
        intro,
        "",
        "| Document | Author |",
        "| --- | --- |",
        ...tableMarkers.map((marker) => `| ${marker}.md | Walter |`),
        "",
        tail,
      ].join("\n");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      mkdirSync(join(workspace, "docs"), { recursive: true });
      for (let index = 1; index <= 27; index += 1) {
        writeFileSync(
          join(workspace, "docs", `source-${String(index).padStart(2, "0")}.md`),
          `source row ${index}\n`,
        );
      }
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "yolo",
          permission: {},
          startup_scrollback: false,
          input_appearance: "lines",
          maxxing_mode: "minimal",
          statusLine: { context: true },
          yolo_acknowledged: true,
        }),
      );
      writeFileSync(stderrPath, "");

      const tableGateway = startFakeGateway([
        fakeGatewaySerializedToolCall(
          "launch-history-list",
          "list_files",
          JSON.stringify({ path: "." }),
          "I'll inspect the docs and determine their authorship.",
        ),
        fakeGatewaySerializedToolCall(
          "launch-history-command",
          "terminal",
          JSON.stringify({
            action: "exec",
            command:
              "for i in $(seq -w 1 27); do printf 'docs/source-%s.md\\tWalter (1)\\n' \"$i\"; done",
          }),
        ),
        fakeGatewayFinalText(response),
      ]);
      gateway = tableGateway;
      const launchScript = [
        `i=1; while [ "$i" -le ${prefillMarkers.length} ]; do printf "PREFILL_HISTORY_ROW_%04d\\n" "$i"; i=$((i + 1)); done`,
        `exec ${FX_BIN}`,
      ].join("; ");
      session = await TmuxSession.create({
        cmd: `/bin/sh -c '${launchScript}'`,
        cwd: workspace,
        width: 210,
        height: 60,
        minimumHistoryLines: 10_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-launch-history-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: tableGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: tableGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: tableGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Render the launch-history table.");
      await session.waitForText(tail, TIMEOUT);
      await session.waitForPane(hasEmptyComposer, TIMEOUT);
      await Bun.sleep(100);

      const scrollback = await session.captureFullScrollback();
      const escapedScrollback = await session.captureFullScrollbackEscapes();
      let previousIndex = -1;
      for (const marker of [...prefillMarkers, intro, ...tableMarkers, tail]) {
        expect(countOccurrences(scrollback, marker)).toBe(1);
        const index = scrollback.indexOf(marker);
        expect(index).toBeGreaterThan(previousIndex);
        previousIndex = index;
      }
      const introIndex = scrollback.indexOf(intro);
      const firstTableIndex = scrollback.indexOf(tableMarkers[0]!);
      expect(scrollback.slice(introIndex, firstTableIndex)).not.toMatch(
        /(?:Thinking \(|\(↑\d)/,
      );
      expect(escapedScrollback).toContain(prefillMarkers[0]!);
      expect(escapedScrollback).toContain(tableMarkers.at(-1)!);
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "dynamic MCP approval shows exact arguments and preserves deny once and session scope",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-mcp-approval-")));
      const dynamicToolName = "mcp_fixture_echo";
      const argumentSentinel = "FXC194_ARGUMENT_SENTINEL";
      const secondArgumentSentinel = "FXC194_SECOND_ARGUMENT_SENTINEL";
      for (const decision of ["deny", "allow", "session"] as const) {
        const runRoot = join(root, decision);
        const home = join(runRoot, "home");
        const workspace = join(runRoot, "workspace");
        const stderrPath = join(runRoot, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({ maxxing_mode: "minimal" }),
        );
        const fixture = writeDelayedMcpFixture(runRoot, home, 0);
        const finalText = `FXC194_${decision.toUpperCase()}_COMPLETE`;
        const mcpGateway = startFakeGateway([
          fakeGatewaySse([
            {
              type: "tool-call",
              toolCallId: `select_approval_mcp_${decision}`,
              toolName: "mcp_select_tool",
              input: { name: dynamicToolName },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          fakeGatewaySse([
            {
              type: "tool-call",
              toolCallId: `call_approval_mcp_${decision}`,
              toolName: dynamicToolName,
              input: { text: argumentSentinel },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
            },
          ]),
          ...(decision === "session"
            ? [fakeGatewaySse([
              {
                type: "tool-call",
                toolCallId: "call_approval_mcp_session_second",
                toolName: dynamicToolName,
                input: { text: secondArgumentSentinel },
              },
              {
                type: "finish",
                finishReason: { unified: "tool-calls", raw: "tool-calls" },
              },
            ])]
            : []),
          fakeGatewayFinalText(finalText),
        ]);
        gateway = mcpGateway;

        try {
          session = await TmuxSession.create({
            cwd: workspace,
            width: 100,
            height: 28,
            stderrPath,
            env: {
              HOME: home,
              AI_GATEWAY_API_KEY: "fake-mcp-approval-key",
              VERCEL_OIDC_TOKEN: undefined,
              FX_AUTO_UPGRADE: "0",
              FX_PERMISSION_MODE: "ask",
              FX_GATEWAY_BASE_URL: mcpGateway.baseUrl,
              FX_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
              FX_E2E_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
              FX_MODEL: MODEL,
            },
          });

          await session.waitForComposer(TIMEOUT);
          await session.sendText("Run the MCP fixture with the exact sentinel.");
          const approval = await session.waitForText(
            "Allow this MCP tool call?",
            TIMEOUT,
          );
          expect(approval).toContain("MCP tool");
          expect(approval).toContain("Arguments for this request");
          expect(approval).toContain("Allow once");
          expect(approval).toContain("Allow this MCP tool for this session");
          expect(approval).toContain("Deny");
          expect(approval).toContain(dynamicToolName);
          expect(approval).toContain(`{"text":"${argumentSentinel}"}`);
          expect(existsSync(fixture.callStartedPath)).toBe(false);

          await session.sendLiteralText(
            decision === "deny" ? "3" : decision === "session" ? "2" : "1",
          );
          await session.waitForText(finalText, TIMEOUT);
          if (decision === "deny") {
            expect(existsSync(fixture.callStartedPath)).toBe(false);
          } else {
            const calls = readDelayedMcpCalls(fixture.callStartedPath);
            expect(calls).toHaveLength(decision === "session" ? 2 : 1);
            expect(calls[0]?.arguments).toEqual({ text: argumentSentinel });
            if (decision === "session") {
              expect(calls[1]?.arguments).toEqual({ text: secondArgumentSentinel });
            }
          }
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          await session?.kill();
          session = null;
          mcpGateway.stop();
          gateway = null;
        }
      }
    },
    90_000,
  );

  test(
    "dynamic MCP approval from a child preserves live arguments and durable redaction",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-child-mcp-approval-")));
      const dynamicToolName = "mcp_fixture_echo";
      const argumentSentinel = "FXC194_CHILD_ARGUMENT_SENTINEL";
      const childPrompt = "Select and call the inherited MCP echo fixture once.";
      const parentPrompt = "Create a one-off child to call the inherited MCP fixture.";

      for (const decision of ["deny", "allow"] as const) {
        const runRoot = join(root, decision);
        const home = join(runRoot, "home");
        const workspace = join(runRoot, "workspace");
        const stderrPath = join(runRoot, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            maxxing_mode: "minimal",
            permission_mode: "ask",
            permission: { subagent: "allow" },
          }),
        );
        const fixture = writeDelayedMcpFixture(runRoot, home, 0);
        const finalText = `FXC194_CHILD_${decision.toUpperCase()}_COMPLETE`;
        const childSelectId = `child_mcp_select_${decision}`;
        const childCallId = `child_mcp_call_${decision}`;
        const parentCreateId = `parent_subagent_create_${decision}`;
        let releaseParent!: (response: Response) => void;
        const parentCompletion = new Promise<Response>((resolve) => {
          releaseParent = resolve;
        });
        let parentReleased = false;
        const mcpGateway = startDynamicFakeGateway((body) => {
          if (body.includes(`"toolCallId":"${childCallId}"`)) {
            if (!parentReleased) {
              parentReleased = true;
              releaseParent(fakeGatewayFinalText(finalText));
            }
            return fakeGatewayFinalText("Child MCP request resolved.");
          }
          if (body.includes(`"toolCallId":"${childSelectId}"`)) {
            return fakeGatewayToolCall(childCallId, dynamicToolName, {
              text: argumentSentinel,
            });
          }
          if (body.includes(`"toolCallId":"${parentCreateId}"`)) {
            return parentCompletion;
          }
          if (body.includes(childPrompt)) {
            return fakeGatewayToolCall(childSelectId, "mcp_select_tool", {
              name: dynamicToolName,
            });
          }
          if (body.includes(parentPrompt)) {
            return fakeGatewayToolCall(parentCreateId, "subagent", {
              command: {
                create: {
                  name: `fxc194-${decision}-child`,
                  mode: "one_off",
                  prompt: childPrompt,
                },
              },
            });
          }
          return new Response("unexpected Gateway request", { status: 500 });
        }, {
          classifierDecision: "allow",
          models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
        });
        gateway = mcpGateway;

        try {
          session = await TmuxSession.create({
            cwd: workspace,
            width: 100,
            height: 34,
            stderrPath,
            env: {
              HOME: home,
              AI_GATEWAY_API_KEY: "fake-child-mcp-approval-key",
              VERCEL_OIDC_TOKEN: undefined,
              FX_AUTO_UPGRADE: "0",
              FX_PERMISSION_MODE: "ask",
              FX_GATEWAY_BASE_URL: mcpGateway.baseUrl,
              FX_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
              FX_E2E_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
              FX_MODEL: MODEL,
              FX_SOUND: "0",
            },
          });

          await session.waitForComposer(TIMEOUT);
          await session.sendText(parentPrompt);
          const approval = await session.waitForText(
            "Allow this MCP tool call?",
            TIMEOUT,
          );
          expect(approval).toContain(dynamicToolName);
          expect(approval).toContain(`{"text":"${argumentSentinel}"}`);
          expect(existsSync(fixture.callStartedPath)).toBe(false);

          await waitForCondition(
            () => readSubagentCommunicationRecords(home).length > 0,
            "pending child communication ledger",
          );
          const communicationRecords = readSubagentCommunicationRecords(home);
          expect(communicationRecords.length).toBeGreaterThan(0);
          for (const record of communicationRecords) {
            expect(record).not.toContain(argumentSentinel);
            expect(record).not.toContain("tool_arguments_preview");
          }

          await session.sendLiteralText(decision === "deny" ? "3" : "1");
          await session.waitForText(finalText, TIMEOUT);
          const calls = readDelayedMcpCalls(fixture.callStartedPath);
          if (decision === "deny") {
            expect(calls).toHaveLength(0);
          } else {
            expect(calls).toHaveLength(1);
            expect(calls[0]?.arguments).toEqual({ text: argumentSentinel });
          }
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          await session?.kill();
          session = null;
          mcpGateway.stop();
          gateway = null;
        }
      }
    },
    120_000,
  );

  test(
    "dynamic MCP approval ellipsizes overlong arguments in a narrow terminal",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-narrow-mcp-approval-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const dynamicToolName = "mcp_fixture_echo";
      const argumentTail = "FXC194_OVERLONG_TAIL";
      const overlongText = `FXC194_OVERLONG_HEAD_${"x".repeat(5_000)}\u001b[31m${argumentTail}`;
      const finalText = "FXC194_NARROW_DENY_COMPLETE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "minimal" }),
      );
      const fixture = writeDelayedMcpFixture(root, home, 0);
      const mcpGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "select_narrow_approval_mcp",
            toolName: "mcp_select_tool",
            input: { name: dynamicToolName },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "call_narrow_approval_mcp",
            toolName: dynamicToolName,
            input: { text: overlongText },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = mcpGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 44,
        height: 28,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-narrow-mcp-approval-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "ask",
          FX_GATEWAY_BASE_URL: mcpGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_SOUND: "0",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the MCP fixture with overlong arguments.");
      const approval = await session.waitForText(
        "Allow this MCP tool call?",
        TIMEOUT,
      );
      expect(approval).toContain(dynamicToolName);
      expect(approval).toContain("FXC194_OVER");
      expect(approval).toContain("…");
      expect(approval).not.toContain(argumentTail);
      expect(approval.split("\n").every((line) => [...line].length <= 44)).toBe(true);
      expect(existsSync(fixture.callStartedPath)).toBe(false);

      await session.sendLiteralText("3");
      await session.waitForText(finalText, TIMEOUT);
      expect(readDelayedMcpCalls(fixture.callStartedPath)).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    60_000,
  );

  test(
    "dynamic MCP child rows transition from running to ran",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-mcp-lifecycle-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "fx-trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "minimal" }),
      );
      const fixture = writeDelayedMcpFixture(root, home, 2_000);

      const finalText = "MCP_LIFECYCLE_FINAL";
      const dynamicToolName = "mcp_fixture_echo";
      const mcpGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "select_delayed_mcp",
            toolName: "mcp_select_tool",
            input: { name: dynamicToolName },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "call_delayed_mcp",
            toolName: dynamicToolName,
            input: { text: "delayed" },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = mcpGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 88,
        height: 24,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-mcp-lifecycle-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: mcpGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: mcpGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "tool",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/mcp reload");
      await session.waitForText("MCP configuration reloaded successfully.", TIMEOUT);
      const readyDeadline = Date.now() + TIMEOUT;
      let mcpStatus = "";
      const readyStatus = "fixture source=profile scope=profile policy=optional transport=stdio state=ready";
      while (Date.now() < readyDeadline) {
        await session.sendText("/mcp list");
        mcpStatus = await session.captureFullScrollback();
        if (mcpStatus.includes(readyStatus)) break;
        await Bun.sleep(100);
      }
      if (!mcpStatus.includes(readyStatus)) {
        throw new Error(`timed out waiting for MCP fixture readiness\n${mcpStatus}`);
      }
      await session.sendText("Run the delayed MCP fixture once.");
      await waitForCondition(
        () => existsSync(fixture.callStartedPath),
        "delayed MCP fixture call",
      );
      const active = await session.waitForText(
        `└ Running MCP ${dynamicToolName}`,
        5_000,
      );
      expect(active).toContain("● 2 tool calls · 1 read · 1 command");
      expect(active).toContain(`├ Selected MCP tool ${dynamicToolName}`);
      expect(countOccurrences(active, `Running MCP ${dynamicToolName}`)).toBe(1);

      await session.waitForText(finalText, TIMEOUT);
      const completed = await session.captureFullScrollback();
      expect(completed).toContain(`└ Ran MCP ${dynamicToolName}`);
      expect(completed).not.toContain(`Running MCP ${dynamicToolName}`);
      expect(mcpGateway.requests).toHaveLength(3);
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain(
        `event=execution_start turn_id=1 step_id=2 call_id=call_delayed_mcp name=${dynamicToolName}`,
      );
      expect(trace).toContain(
        `event=execution_result turn_id=1 step_id=2 call_id=call_delayed_mcp name=${dynamicToolName}`,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    90_000,
  );

  test(
    "minimal keeps unsupported tool failures visible with supported calls",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-unsupported-tool-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const resumedStderrPath = join(root, "resumed-stderr.log");
      const tracePath = join(root, "fx-trace.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "minimal" }),
      );

      const unsupportedCallId = "unsupported_compat_call";
      const unsupportedToolName = "mcp__filesystem__read_text_file";
      const supportedCallId = "supported_after_unknown";
      const supportedCommand = "printf SUPPORTED_AFTER_UNKNOWN";
      const finalText = "UNSUPPORTED_TOOL_PROBE_FINAL";
      const unsupportedGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: unsupportedCallId,
            toolName: unsupportedToolName,
            input: { path: "README.md" },
          },
          {
            type: "tool-call",
            toolCallId: supportedCallId,
            toolName: "terminal",
            input: { action: "exec", command: supportedCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = unsupportedGateway;

      const gatewayEnv = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-unsupported-tool-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "auto",
        FX_GATEWAY_BASE_URL: unsupportedGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: unsupportedGateway.chatUrl,
        FX_E2E_GATEWAY_CHAT_URL: unsupportedGateway.chatUrl,
        FX_MODEL: MODEL,
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "tool",
      };
      session = await TmuxSession.create({
        cwd: workspace,
        width: 100,
        height: 30,
        stderrPath,
        env: {
          ...gatewayEnv,
          FX_RECORD: tapePath,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the supported call after the unknown call.");
      await session.waitForText(finalText, TIMEOUT);
      const header = "● 2 tool calls · 2 commands · 1 failed";
      const failedRow = `├ Failed ${unsupportedToolName}`;
      const completedRow = `└ Ran ${supportedCommand}`;
      const compact = await session.captureFullScrollback();
      expect(compact).toContain(`${header}\n${failedRow}\n${completedRow}`);
      expect(countOccurrences(compact, `Failed ${unsupportedToolName}`)).toBe(1);
      expect(countOccurrences(compact, `Ran ${supportedCommand}`)).toBe(1);
      expect(compact).not.toContain(`Running ${unsupportedToolName}`);

      await session.resizeWindow(72, 24);
      const resized = await session.waitForText(header, TIMEOUT);
      expect(resized).toContain(`Failed ${unsupportedToolName}`);
      expect(resized).toContain(`Ran ${supportedCommand}`);

      await session.sendKeys("C-o");
      const review = await session.waitForText(
        `├ Failed ${unsupportedToolName}`,
        TIMEOUT,
      );
      expect(review).toContain(`└ Ran ${supportedCommand}`);
      expect(countOccurrences(review, `Failed ${unsupportedToolName}`)).toBe(1);
      expect(countOccurrences(review, `Ran ${supportedCommand}`)).toBe(1);

      await session.sendKeys("Right");
      const full = await session.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      expect(full).toContain(`├ Failed ${unsupportedToolName}`);
      expect(full).toContain(`└ Ran ${supportedCommand}`);
      await session.sendKeys("C-o");
      await session.waitForText(header, TIMEOUT);
      expect(unsupportedGateway.requests).toHaveLength(2);
      expect(
        countOccurrences(
          unsupportedGateway.requests[1].body,
          `Unsupported tool: ${unsupportedToolName}`,
        ),
      ).toBe(1);
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain(
        `event=execution_result turn_id=1 step_id=1 call_id=${unsupportedCallId} name=${unsupportedToolName} result_kind=unsupported`,
      );
      expect(
        trace.split("\n").some((line) =>
          line.includes("event=execution_start") &&
          line.includes(`call_id=${unsupportedCallId}`)
        ),
      ).toBe(false);
      expect(trace).toContain(
        `event=execution_start turn_id=1 step_id=1 call_id=${supportedCallId} name=terminal`,
      );
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      await session.kill();
      session = null;

      session = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: workspace,
        width: 100,
        height: 30,
        stderrPath: resumedStderrPath,
        env: gatewayEnv,
      });
      await session.waitForText(finalText, TIMEOUT);
      const resumed = await session.capturePane();
      expect(resumed).toContain(`${header}\n${failedRow}\n${completedRow}`);
      expect(countOccurrences(resumed, `Failed ${unsupportedToolName}`)).toBe(1);
      expect(countOccurrences(resumed, `Ran ${supportedCommand}`)).toBe(1);
      expect(unsupportedGateway.requests).toHaveLength(2);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "minimal command summaries hide no-op cwd prefixes and abbreviate the active workspace path",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-command-summary-")));
      const home = join(root, "home");
      const workspace = join(
        root,
        "Users",
        "jeffsee",
        "code",
        "worktrees",
        "vercel",
        "smart-spruce",
      );
      const nested = join(
        workspace,
        "vercel",
        "packages",
        "cli",
        "test",
        "fixtures",
        "unit",
        "commands",
        "git",
        "connect",
        "unlink",
      );
      const stderrPath = join(root, "stderr.log");
      const resumedStderrPath = join(root, "resumed-stderr.log");
      const tracePath = join(root, "fx-trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(nested, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "minimal" }),
      );

      const firstCommand = "cd . && printf TOOL_SUMMARY_FIRST_COMMAND";
      const firstDisplayCommand = "printf TOOL_SUMMARY_FIRST_COMMAND";
      const nestedCommand = `cd ${nested} && pwd`;
      const thirdCommand = "printf TOOL_SUMMARY_THIRD_COMMAND";
      const finalText = "TOOL_SUMMARY_FINAL";
      const summaryGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "tool_summary_first",
            toolName: "terminal",
            input: { action: "exec", command: firstCommand },
          },
          {
            type: "tool-call",
            toolCallId: "tool_summary_nested",
            toolName: "terminal",
            input: { action: "exec", command: nestedCommand },
          },
          {
            type: "tool-call",
            toolCallId: "tool_summary_third",
            toolName: "terminal",
            input: { action: "exec", command: thirdCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = summaryGateway;

      const gatewayEnv = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-tool-summary-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "auto",
        FX_GATEWAY_BASE_URL: summaryGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: summaryGateway.chatUrl,
        FX_E2E_GATEWAY_CHAT_URL: summaryGateway.chatUrl,
        FX_MODEL: MODEL,
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "tool",
      };
      const withoutWorkspaceStatusline = (text: string): string =>
        text.split("\n").filter((line) =>
          !(line.includes(workspace) && line.includes(" · "))
        ).join("\n");

      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 30,
        stderrPath,
        env: gatewayEnv,
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the prepared command summary fixture.");
      await session.waitForText(finalText, TIMEOUT);

      const compact = await session.captureFullScrollback();
      expect(compact).toContain("● 3 tool calls · 3 commands");
      expect(compact).toContain(
        "Ran cd ./vercel/packages/cli/test/fixtures/unit/commands/git/connect/unlink && pwd",
      );
      expect(withoutWorkspaceStatusline(compact)).not.toContain(workspace);
      expect(countOccurrences(compact, `Ran ${firstDisplayCommand}`)).toBe(1);
      expect(compact).not.toContain(`Ran ${firstCommand}`);
      expect(countOccurrences(compact, `Ran ${thirdCommand}`)).toBe(1);

      await session.resizeWindow(80, 24);
      await session.waitForText("● 3 tool calls · 3 commands", TIMEOUT);
      await session.sendKeys("C-o");
      const review = await session.waitForText(finalText, TIMEOUT);
      expect(review).toContain(
        "├ Ran cd ./vercel/packages/cli/test/fixtures/unit/commands/git/connect/unlink",
      );
      expect(review).toContain(`├ Ran ${firstDisplayCommand}`);
      expect(review).not.toContain(`Ran ${firstCommand}`);
      expect(review).toContain("● 3 tool calls · 3 commands");
      expect(withoutWorkspaceStatusline(review)).not.toContain(workspace);

      await session.sendKeys("Right");
      const full = await session.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      expect(full).toContain(finalText);
      await session.sendKeys("PPage");
      const fullAtSummary = await session.waitForText("● 3 tool calls · 3 commands", TIMEOUT);
      expect(fullAtSummary).toContain("● 3 tool calls · 3 commands");
      expect(withoutWorkspaceStatusline(fullAtSummary)).not.toContain(workspace);

      const trace = readFileSync(tracePath, "utf8");
      for (const callId of [
        "tool_summary_first",
        "tool_summary_nested",
        "tool_summary_third",
      ]) {
        expect(
          countOccurrences(trace, `event=execution_start turn_id=1 step_id=1 call_id=${callId}`),
        ).toBe(1);
        expect(
          countOccurrences(trace, `event=execution_result turn_id=1 step_id=1 call_id=${callId}`),
        ).toBe(1);
      }
      expect(summaryGateway.requests).toHaveLength(2);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session.sendKeys("C-o");
      await session.waitForText("● 3 tool calls · 3 commands", TIMEOUT);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      await session.kill();
      session = null;

      session = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: workspace,
        width: 120,
        height: 30,
        stderrPath: resumedStderrPath,
        env: gatewayEnv,
      });
      await session.waitForText(finalText, TIMEOUT);
      const resumed = await session.captureFullScrollback();
      expect(resumed).toContain("● 3 tool calls · 3 commands");
      expect(resumed).toContain(
        "Ran cd ./vercel/packages/cli/test/fixtures/unit/commands/git/connect/unlink && pwd",
      );
      expect(resumed).toContain(`Ran ${firstDisplayCommand}`);
      expect(resumed).not.toContain(`Ran ${firstCommand}`);
      expect(withoutWorkspaceStatusline(resumed)).not.toContain(workspace);
      expect(summaryGateway.requests).toHaveLength(2);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "minimal maxxing groups compact tool rows while Ctrl-O keeps full details",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-minimal-tool-groups-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const wrappedToolDetail = Array.from(
        { length: 16 },
        (_, index) => `WRAPPED_TOOL_DETAIL_${String(index + 1).padStart(2, "0")}`,
      ).join(" ");
      writeFileSync(
        join(workspace, "one.txt"),
        `MINIMAL_GROUP_DETAIL_ONE ${wrappedToolDetail}\n`,
      );
      writeFileSync(join(workspace, "two.txt"), "MINIMAL_GROUP_DETAIL_TWO\n");
      writeFileSync(join(workspace, "three.txt"), "MINIMAL_GROUP_DETAIL_THREE\n");
      writeFileSync(join(workspace, "four.txt"), "MINIMAL_GROUP_DETAIL_FOUR\n");
      writeFileSync(join(workspace, "five.txt"), "MINIMAL_GROUP_DETAIL_FIVE\n");
      writeFileSync(join(workspace, "six.txt"), "MINIMAL_GROUP_DETAIL_SIX\n");
      writeFileSync(join(workspace, "seven.txt"), "MINIMAL_GROUP_DETAIL_SEVEN\n");
      mkdirSync(join(workspace, "nested"));

      const finalText = "MINIMAL_GROUP_FINAL";
      const secondStepText = "MINIMAL_GROUP_SECOND_STEP";
      const firstCommand = "printf FIRST_GROUP_COMMAND";
      const secondCommand = "printf SECOND_GROUP_COMMAND";
      const liveCommand = "sleep 1; printf SECOND_GROUP_LIVE_COMMAND";
      const groupedGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "minimal_read_one",
            toolName: "read_file",
            input: { path: "one.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_read_two",
            toolName: "read_file",
            input: { path: "two.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_read_three",
            toolName: "read_file",
            input: { path: "three.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_list_workspace",
            toolName: "list_files",
            input: { path: "." },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_list_nested",
            toolName: "list_files",
            input: { path: "nested" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_command_one",
            toolName: "terminal",
            input: { action: "exec", command: firstCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "minimal_read_four",
            toolName: "read_file",
            input: { path: "four.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_read_five",
            toolName: "read_file",
            input: { path: "five.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_read_six",
            toolName: "read_file",
            input: { path: "six.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_command_two",
            toolName: "terminal",
            input: { action: "exec", command: secondCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewaySse([
          { type: "text-delta", id: "second_step", delta: secondStepText },
          {
            type: "tool-call",
            toolCallId: "minimal_read_seven",
            toolName: "read_file",
            input: { path: "seven.txt" },
          },
          {
            type: "tool-call",
            toolCallId: "minimal_command_live",
            toolName: "terminal",
            input: { action: "exec", command: liveCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = groupedGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 100,
        height: 90,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-minimal-tool-group-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: groupedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: groupedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: groupedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/maxxing");
      await session.waitForPane(
        (pane) =>
          pane.includes("Appearance") &&
          pane.includes("Maxxing mode") &&
          pane.includes("minimal  legacy"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run both prepared tool groups.");
      const running = await session.waitForText(
        "└ Running sleep 1; printf SECOND_GROUP_LIVE_COMMAND",
        TIMEOUT,
      );
      expect(running).toContain(
        "● 2 tool calls · 1 read · 1 command\n├ Read seven.txt\n└ Running sleep 1; printf SECOND_GROUP_LIVE_COMMAND",
      );
      expect(running).toMatch(/\n *(?:• )?Thinking \(\d+s\)/);
      await session.waitForText(finalText, TIMEOUT);
      const compact = await session.capturePane();
      expect(compact).toContain(
        "● 10 tool calls · 6 read · 2 list · 2 commands",
      );
      expect(compact).toContain("├ Read one.txt");
      expect(compact).toContain("├ Read six.txt");
      expect(compact).toContain("└ Ran printf SECOND_GROUP_COMMAND");
      expect(compact).toContain(secondStepText);
      expect(compact).toContain("● 2 tool calls · 1 read · 1 command");
      expect(compact).toContain("├ Read seven.txt");
      expect(compact).toContain("└ Ran sleep 1; printf SECOND_GROUP_LIVE_COMMAND");
      expect(compact.indexOf("● 10 tool calls")).toBeLessThan(
        compact.indexOf(secondStepText),
      );
      expect(compact.indexOf(secondStepText)).toBeLessThan(
        compact.indexOf("● 2 tool calls"),
      );
      expect(compact).not.toContain("\n● Ran printf FIRST_GROUP_COMMAND");
      expect(compact).not.toContain("\n● Ran printf SECOND_GROUP_COMMAND");

      await session.sendKeys("C-o");
      await session.waitForText("MINIMAL_GROUP_DETAIL_SIX", TIMEOUT);
      await session.sendKeys("Right");
      await session.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      const full = await session.captureFullScrollback();
      expect(full).toContain("MINIMAL_GROUP_DETAIL_ONE");
      expect(full).toContain("├ Read one.txt");
      expect(full).toContain("├ Read six.txt");
      expect(full).toContain("├ Read seven.txt");
      expect(full).toContain("├ Ran printf FIRST_GROUP_COMMAND");
      expect(full).toContain("└ Ran printf SECOND_GROUP_COMMAND");
      expect(full).toContain("└ Ran sleep 1; printf SECOND_GROUP_LIVE_COMMAND");
      const wrappedDetailRows = full
        .split("\n")
        .filter((row) => row.includes("WRAPPED_TOOL_DETAIL_"));
      expect(wrappedDetailRows.length).toBeGreaterThan(1);
      for (const row of wrappedDetailRows) {
        expect(row.startsWith("│")).toBe(true);
      }
      const replayFrames = execFileSync(FX_BIN, ["replay", tapePath, "--frames"], {
        encoding: "utf8",
      });
      const replayWrappedRows = replayFrames
        .split("\n")
        .filter((row) => row.includes("WRAPPED_TOOL_DETAIL_"));
      expect(replayWrappedRows.length).toBeGreaterThan(1);
      for (const row of replayWrappedRows) {
        expect(row.startsWith("|│")).toBe(true);
      }

      await session.sendKeys("C-o");
      await session.waitForText(finalText, TIMEOUT);
      await session.sendText("/maxxing legacy");
      await session.waitForText("● Maxxing: switched to legacy", TIMEOUT);
      const restored = await session.capturePane();
      expect(restored).not.toContain("● 10 tool calls");
      expect(restored).toContain("● Read one.txt");
      expect(restored).toContain("● Read seven.txt");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "minimal maxxing keeps cancelled command feedback below its semantic group",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-minimal-cancelled-tool-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "auto",
          permission: {},
        }),
      );

      const cancelledGateway = startFakeGateway([
        fakeGatewayToolCall("minimal_cancelled_command", "terminal", {
          action: "exec",
          command: "sleep 30",
        }),
      ]);
      gateway = cancelledGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 100,
        height: 32,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-minimal-cancelled-tool-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: cancelledGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: cancelledGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: cancelledGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_THEME: "dark",
          NO_COLOR: undefined,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/maxxing");
      await session.waitForPane(
        (pane) =>
          pane.includes("Appearance") &&
          pane.includes("Maxxing mode") &&
          pane.includes("minimal  legacy"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the cancellable command.");
      await session.waitForText("└ Running sleep 30", TIMEOUT);
      const runningGrid = await session.capturePaneGrid();
      const runningComposerRow = runningGrid.findLastIndex(
        (row) => row.trim() === "┃",
      );
      expect(runningComposerRow).toBeGreaterThanOrEqual(0);
      await session.sendKeys("Escape");

      const feedback = "■ Cancelled sleep 30 · What can fx do differently?";
      const transitionComposerRows: number[] = [];
      let compact = "";
      const feedbackDeadline = Date.now() + TIMEOUT;
      while (Date.now() < feedbackDeadline) {
        const grid = await session.capturePaneGrid();
        const composerRow = grid.findLastIndex((row) => row.trim() === "┃");
        if (composerRow >= 0) transitionComposerRows.push(composerRow);
        compact = grid.join("\n");
        if (compact.includes(feedback)) break;
        await Bun.sleep(5);
      }
      expect(compact).toContain(feedback);
      expect(transitionComposerRows.length).toBeGreaterThan(0);
      expect(Math.min(...transitionComposerRows)).toBeGreaterThanOrEqual(
        runningComposerRow,
      );
      const header = "● 1 tool call · 1 command · 1 cancelled";
      expect(compact).toContain(header);
      expect(compact).toContain(
        `${header}\n└ Cancelled sleep 30\n\n${feedback}`,
      );
      expect(compact).not.toContain("● System: cancelled");

      const escapes = await session.capturePaneEscapes();
      expect(escapes).toContain(
        "\x1b[38;5;255m●\x1b[39m \x1b[38;5;245m1 tool call · 1 command · 1 cancelled",
      );
      expect(escapes).toContain(
        "\x1b[38;5;252m■\x1b[38;5;255m Cancelled",
      );
      expect(escapes).not.toContain("\x1b[38;5;203m■");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "minimal maxxing labels provisional tool calls that never execute",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-minimal-not-executed-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const provisionalGateway = startFakeGateway([
        fakeGatewaySse([
          { type: "tool-input-start", id: "preview_only", toolName: "read_file" },
          {
            type: "tool-input-delta",
            id: "preview_only",
            delta: '{"path":"never-read.txt"}',
          },
          { type: "tool-input-end", id: "preview_only" },
          {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
          },
        ]),
      ]);
      gateway = provisionalGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 100,
        height: 32,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-minimal-not-executed-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: provisionalGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: provisionalGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: provisionalGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/maxxing");
      await session.waitForPane(
        (pane) =>
          pane.includes("Appearance") &&
          pane.includes("Maxxing mode") &&
          pane.includes("minimal  legacy"),
        TIMEOUT,
      );
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Preview a read without executing it.");
      const compact = await session.waitForText("1 not executed", TIMEOUT);
      expect(compact).toContain("● 1 tool call · 1 read · 1 not executed");
      expect(compact).not.toContain("running");

      await session.sendKeys("C-o");
      const full = await session.waitForText("Tool was not executed", TIMEOUT);
      expect(full).toContain("Tool was not executed");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "trace stderr mirrors canonical metadata without payload sentinels",
    async () => {
      const stage = lifecycleStage();
      if (stage === "baseline-silent" || stage === "fatal-reported") return;

      const observed = await runCanonicalLifecycleFixture(stage, true);
      expect(observed.fixtureSha256).toBe(CANONICAL_A_B_SHA256);
      expect(observed.childStatus).toBe(0);
      expect(observed.wrapperStatus).toBe(0);
      expect(observed.sttyAfter).toBe(observed.sttyBefore);
      expect(observed.stderr).toContain("[sse] event type=text-delta");
      expect(observed.stderr).toContain("[sse] event type=tool-call");
      expect(observed.stderr).toContain("[sse] event type=tool-input-end");
      for (
        const sentinel of [
          "FX_MODEL_TEXT_SENTINEL",
          "FX_FINAL_RESPONSE_SENTINEL",
          "FX_PATH_SENTINEL",
          "FX_PATTERN_SENTINEL",
        ]
      ) {
        expect(observed.stderr).not.toContain(sentinel);
      }
    },
    60_000,
  );

  test(
    "height-three startup rollback restores the fixture PTY",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-small-startup-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const artifacts = createArtifactRoot();
      const donePath = join(artifacts, "done");
      const releasePath = join(artifacts, "release");
      const wrapperPath = writeLifecycleWrapper(artifacts);

      session = await TmuxSession.create({
        cmd: wrapperPath,
        cwd: realpathSync(workspacePath),
        height: 3,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_TEST_BIN: FX_BIN,
          FX_LIFECYCLE_ARTIFACT_DIR: artifacts,
        },
      });

      await waitForPath(donePath);
      expect(readTrimmed(join(artifacts, "child.status"))).toBe("0");
      expect(readFileSync(join(artifacts, "stderr.log"), "utf8")).toBe(
        "fx needs at least 5 terminal rows.\n",
      );
      expect(readTrimmed(join(artifacts, "stty.after"))).toBe(
        readTrimmed(join(artifacts, "stty.before")),
      );
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      writeFileSync(releasePath, "");
      await session.waitForSessionEnd(TIMEOUT);
      session = null;
      expect(readTrimmed(join(artifacts, "wrapper.status"))).toBe("0");
    },
    60_000,
  );

  test(
    "invalid added root startup restores the fixture PTY",
    async () => {
      root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-tui-invalid-added-root-")),
      );
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const invalidRoot = join(root, "missing-root");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const artifacts = createArtifactRoot();
      const donePath = join(artifacts, "done");
      const releasePath = join(artifacts, "release");
      const wrapperPath = writeLifecycleWrapper(artifacts, "invalid-added-root");

      session = await TmuxSession.create({
        cmd: wrapperPath,
        cwd: realpathSync(workspacePath),
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_TEST_BIN: FX_BIN,
          FX_INVALID_ADDED_ROOT: invalidRoot,
          FX_LIFECYCLE_ARTIFACT_DIR: artifacts,
        },
      });

      await waitForPath(donePath);
      expect(readTrimmed(join(artifacts, "child.status"))).not.toBe("0");
      expect(readFileSync(join(artifacts, "stderr.log"), "utf8")).toBe(
        "fx: PathNotFound\n",
      );
      expect(readTrimmed(join(artifacts, "stty.after"))).toBe(
        readTrimmed(join(artifacts, "stty.before")),
      );
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      writeFileSync(releasePath, "");
      await session.waitForSessionEnd(TIMEOUT);
      session = null;
      expect(readTrimmed(join(artifacts, "wrapper.status"))).toBe("0");
    },
    60_000,
  );

  test(
    "missing finish regenerates the unstarted tool and completes the response",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-gateway-lifecycle-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const finalText = "Recovered after the incomplete tool stream.";
      const queuedGateway = startFakeGateway([
        missingFinishResponse(),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = queuedGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-tui-gateway-lifecycle-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Exercise the incomplete tool stream.");
      const pane = await session.waitForText(finalText, TIMEOUT);

      expect(queuedGateway.requests).toHaveLength(2);
      expect(pane).toContain("● 1 tool call · 1 read · 1 failed");
      expect(pane).toContain("└ Connection interrupted before read_file ran");
      expect(pane).not.toContain("● Reading");
    },
    TIMEOUT,
  );

  test(
    "argless streamed terminal start never renders bare Running while held open",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-run-command-provisional-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const stream = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ maxxing_mode: "legacy" }),
      );

      const streamingGateway = startFakeGateway([
        () =>
          heldGatewayResponse(stream, [
            {
              type: "tool-input-start",
              id: "command_provisional",
              toolName: "terminal",
            },
          ]),
      ]);
      gateway = streamingGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-run-command-provisional-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: streamingGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: streamingGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: streamingGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,tool,sse,worker,input,prompt,ui_activity,command_output",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("trigger a terminal but keep the stream open");
      await waitForCondition(
        () => streamingGateway.requests.length === 1 && stream.started,
        "held terminal stream start",
      );
      const scrollback = await waitForScrollback(
        session,
        (candidate) =>
          candidate.includes("● Preparing command") &&
          !hasBareRunningRow(candidate),
        "argless terminal provisional row",
      );

      expect(stream.cancelled).toBe(false);
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
      expect(streamingGateway.requests).toHaveLength(1);
      expect(hasBareRunningRow(scrollback)).toBe(false);
      expect(scrollback).toContain("● Preparing command");
      expect(scrollback).toContain("Thinking");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(existsSync(tracePath)).toBe(true);

      await session.kill();
      session = null;
      expect(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
          encoding: "utf8",
        }),
      ).not.toBe("");
    },
    TIMEOUT,
  );

  test(
    "provider search renders a transcript lifecycle row with URL detail",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-provider-search-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const sourceUrl = "https://example.test/fx-provider-search";
      const finalText = "PROVIDER_SEARCH_DONE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const providerGateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "provider_search_direct",
            toolName: "perplexity_search",
            input: {},
          },
          {
            type: "tool-result",
            toolCallId: "provider_search_direct",
            result: {
              results: [{ title: "Fx provider source", url: sourceUrl }],
            },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = providerGateway;

      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 96,
        height: 30,
        minimumHistoryLines: 400,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-provider-search-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: providerGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: providerGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: providerGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,tool,sse,worker,input,prompt,ui_activity,command_output",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Search for the provider fixture.");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => providerGateway.requests.length === 2,
        "provider search synthesis request",
      );

      const initialRequest = parseGatewayRequest(providerGateway.requests[0]!.body);
      const continuingRequest = parseGatewayRequest(providerGateway.requests[1]!.body);
      expect(serializedToolNames(initialRequest)).toEqual(
        AUTO_DUAL_SEARCH_SERIALIZED_TOOL_NAMES,
      );
      expect(serializedToolNames(continuingRequest)).toEqual(
        AUTO_DUAL_SEARCH_SERIALIZED_TOOL_NAMES,
      );
      expect(toolShapesWithoutDescriptions(continuingRequest)).toEqual(
        toolShapesWithoutDescriptions(initialRequest),
      );
      for (const request of [initialRequest, continuingRequest]) {
        const toolNames = serializedToolNames(request);
        expect(toolNames.filter((name) => name === "terminal")).toHaveLength(1);
        expect(toolNames.filter((name) => name === "perplexity_search"))
          .toHaveLength(1);
        expect(findUnavailableCapabilityReferences(request)).toEqual([]);
        expect(customProviderGuidanceState(request)).toEqual({
          providerToolIndices: [23],
          guidanceMessageIndices: [1],
        });
        expect(
          request.prompt?.filter((message) =>
            message.role === "system" && contentText(message.content) === WEB_SEARCH_GUIDANCE
          ),
        ).toHaveLength(1);
      }

      const compact = await session.captureFullScrollback();
      expect(compact).toContain("● 1 tool call · 1 read");
      expect(compact).toContain("└ Searched web");
      expect(compact).not.toContain("● Running");
      expect(compact).not.toContain("Working perplexity_search");

      await session.sendKeys("C-o");
      const detail = await session.waitForText(sourceUrl, TIMEOUT);
      expect(detail).toContain(sourceUrl);
      expect(detail).toContain("└ Searched web");

      const replay = execFileSync(FX_BIN, ["replay", tapePath, "--frames"], {
        encoding: "utf8",
      });
      expect(replay).toContain("● 1 tool call · 1 read");
      expect(replay).toContain("└ Searched web");
      expect(replay).not.toContain("Working perplexity_search");
      expect(existsSync(tracePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "explicit TUI Fx search worker uses the admitted adapter",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-local-search-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const finalText = "FX_SEARCH_WORKER_DONE";
      const sourceUrl = "https://example.test/fx-local-search";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const searchGateway = startFakeGateway([
        fakeGatewayToolCall("fx_search_1", "web_search", {
          query: "Fx local search fixture",
        }),
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "worker_provider_search_1",
            toolName: "perplexity_search",
            input: {},
          },
          {
            type: "tool-result",
            toolCallId: "worker_provider_search_1",
            result: {
              results: [{ title: "Fx local source", url: sourceUrl }],
            },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = searchGateway;

      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 96,
        height: 30,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "connection-a-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: searchGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: searchGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: searchGateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Use the installed Fx search worker.");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => searchGateway.requests.length === 3,
        "Fx search worker completion",
      );

      expect(searchGateway.requests.map((request) =>
        request.headers.get("authorization")
      )).toEqual([
        "Bearer connection-a-key",
        "Bearer connection-a-key",
        "Bearer connection-a-key",
      ]);
      expect(searchGateway.requests.map((request) =>
        request.headers.get("ai-language-model-id")
      )).toEqual([MODEL, MODEL, MODEL]);
      expect(serializedToolNames(parseGatewayRequest(searchGateway.requests[0]!.body))).toEqual(
        AUTO_DUAL_SEARCH_SERIALIZED_TOOL_NAMES,
      );
      expect(searchGateway.requests[1]!.body).toContain("gateway.perplexity_search");
      expect(searchGateway.requests[1]!.body).not.toContain('"name":"web_search"');
      expect(searchGateway.requests[2]!.body).toContain(sourceUrl);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("└ Searched Fx local search fixture");
      expect(scrollback).not.toContain("Would you like to allow this action?");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "multiline terminal keeps raw approval and persistence with compact activity",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-multiline-command-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const command = "cat <<'EOF'\nline one\nEOF";
      const compactActivity = "● Ran cat <<'EOF' line one EOF";
      const finalText = "MULTILINE_COMMAND_DONE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      const workspace = realpathSync(workspacePath);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "ask",
          permission: {},
          maxxing_mode: "legacy",
        }),
      );
      writeFileSync(stderrPath, "");

      const commandGateway = startFakeGateway([
        fakeGatewayToolCall("multiline_command", "terminal", { action: "exec", command }),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = commandGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 40,
        minimumHistoryLines: 400,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-multiline-command-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "ask",
          FX_GATEWAY_BASE_URL: commandGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: commandGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: commandGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the multiline command fixture.");
      const approval = await session.waitForText(
        "Would you like to run the following command?",
        TIMEOUT,
      );
      expect(approval).toMatch(/cat <<'EOF'\s*\n\s*line one\s*\n\s*EOF/);
      expect(approval).not.toContain("\\x0a");
      await session.sendKeys("1");
      await session.sendKeys("Enter");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => commandGateway.requests.length === 2,
        "multiline command continuation request",
      );

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain(compactActivity);
      expect(scrollback).not.toContain(`Ran cat <<'EOF'\\x0a`);
      expect(commandGateway.requests[1]!.body).toContain(
        "exit_code=0\\n<stdout>\\nline one\\n</stdout>",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const sessionsRoot = join(home, ".fx", "sessions");
      const sessionId = readdirSync(sessionsRoot).find((entry) =>
        existsSync(join(sessionsRoot, entry, "session.json"))
      );
      if (!sessionId) throw new Error("multiline command session was not found");
      const saved = JSON.parse(
        execFileSync(FX_BIN, ["session", "--id", sessionId, "--json"], {
          cwd: workspace,
          env: { ...process.env, HOME: home },
          encoding: "utf8",
        }),
      ) as any;
      const step = saved.history
        .flatMap((turn: any) => turn.execution?.tool_steps ?? [])
        .find((entry: any) =>
          entry.tool_calls?.some((call: any) => call.name === "terminal")
        );
      expect(step).toBeDefined();
      const savedCall = step.tool_calls.find((call: any) => call.name === "terminal");
      expect(JSON.parse(savedCall.arguments_json).command).toBe(command);
      expect(step.tool_results).toContainEqual(
        expect.objectContaining({
          tool_call_id: savedCall.id,
          tool_name: "terminal",
          status: "success",
        }),
      );

      const replay = execFileSync(FX_BIN, ["replay", tapePath], {
        encoding: "utf8",
      });
      expect(replay).toContain(compactActivity);
      expect(replay).not.toContain(`Ran cat <<'EOF'\\x0a`);
    },
    TIMEOUT * 2,
  );

  test(
    "same-step streamed terminal calls complete with owned output blocks",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-parallel-command-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const firstCommand = "printf 'FIRST_CMD_%s\\n' DONE";
      const secondCommand =
        "i=1; while [ \"$i\" -le 30 ]; do printf 'SECOND_CMD_LINE_%02d\\n' \"$i\"; i=$((i+1)); done";
      const finalText = "SAME_STEP_COMMAND_DONE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "auto",
          permission: {},
          maxxing_mode: "legacy",
        }),
      );

      const commandGateway = startFakeGateway([
        fakeGatewaySse([
          { type: "tool-input-start", id: "stream_cmd_one", toolName: "terminal" },
          {
            type: "tool-input-delta",
            id: "stream_cmd_one",
            delta: JSON.stringify({ action: "exec", command: firstCommand }),
          },
          { type: "tool-input-end", id: "stream_cmd_one" },
          { type: "tool-input-start", id: "stream_cmd_two", toolName: "terminal" },
          {
            type: "tool-input-delta",
            id: "stream_cmd_two",
            delta: JSON.stringify({ action: "exec", command: secondCommand }),
          },
          { type: "tool-input-end", id: "stream_cmd_two" },
          {
            type: "tool-call",
            toolCallId: "stream_cmd_one",
            toolName: "terminal",
            input: { action: "exec", command: firstCommand },
          },
          {
            type: "tool-call",
            toolCallId: "stream_cmd_two",
            toolName: "terminal",
            input: { action: "exec", command: secondCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = commandGateway;

      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 104,
        height: 32,
        minimumHistoryLines: 800,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-same-step-command-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: commandGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: commandGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: commandGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,tool,sse,worker,input,prompt,ui_activity,command_output",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the two command fixtures in one step.");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => commandGateway.requests.length === 2,
        "command continuation request",
      );

      const scrollback = await waitForScrollback(
        session,
        (candidate) =>
          candidate.includes(finalText) &&
          !hasBareRunningRow(candidate) &&
          candidate.includes("SECOND_CMD_LINE_05") &&
          candidate.includes(
            "│ … 25 lines more (ctrl o to view)",
          ),
        "completed same-step command transcript",
        5_000,
      );
      expect(hasBareRunningRow(scrollback)).toBe(false);
      expect(scrollback).toContain("SECOND_CMD_LINE_05");
      expect(scrollback).not.toContain("SECOND_CMD_LINE_06");
      expect(scrollback).not.toContain("SECOND_CMD_LINE_30");
      expect(scrollback).toContain(
        "│ … 25 lines more (ctrl o to view)",
      );
      const continuationBody = commandGateway.requests[1]!.body;
      const firstResult = "exit_code=0\\n<stdout>\\nFIRST_CMD_DONE\\n</stdout>";
      const secondResultTail = "SECOND_CMD_LINE_30";
      expect(continuationBody).toContain(firstResult);
      expect(continuationBody).toContain(secondResultTail);
      expect(continuationBody.indexOf(firstResult)).toBeLessThan(
        continuationBody.indexOf(secondResultTail),
      );

      await session.sendKeys("C-o");
      await session.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
      const reviewEscapes = await session.capturePaneEscapes();
      expect(reviewEscapes).not.toContain("\x1b[38;5;245m│");
      expect(reviewEscapes).toContain("│\x1b[38;5;245m  30 output lines");
      await session.sendKeys("Right");
      for (let page = 0; page < 10; page += 1) {
        await session.sendHexBytes(["1b", "5b", "36", "7e"]);
      }
      await session.waitForText("SECOND_CMD_LINE_30", TIMEOUT);
      const full = await session.capturePane();
      expect(full).toContain("SECOND_CMD_LINE_30");
      expect(full).not.toContain("lines more (ctrl o");
      await session.sendKeys("C-o");
      await session.waitForText(finalText, TIMEOUT);

      const finalReplay = execFileSync(FX_BIN, ["replay", tapePath], {
        encoding: "utf8",
      });
      expect(hasBareRunningRow(finalReplay)).toBe(false);
      const trace = readFileSync(tracePath, "utf8");
      expect(countOccurrences(trace, "lifecycle_reduced kind=terminal turn_id=1"))
        .toBeGreaterThanOrEqual(2);
      expect(countOccurrences(trace, "lifecycle_reduced kind=terminal turn_id=1 records=2"))
        .toBeGreaterThanOrEqual(2);

      const replayFrames = execFileSync(FX_BIN, ["replay", tapePath, "--frames"], {
        encoding: "utf8",
      });
      const stableSecondCommandLine = "SECOND_CMD_LINE_24";
      expect(replayFrames).toContain("FIRST_CMD_DONE");
      expect(replayFrames).toContain(stableSecondCommandLine);
      expect(replayFrames.indexOf("FIRST_CMD_DONE")).toBeLessThan(
        replayFrames.indexOf(stableSecondCommandLine),
      );
      expect(replayFrames).toContain("SECOND_CMD_LINE_30");
      expect(replayFrames).toContain(
        "│ … 25 lines more (ctrl o to view)",
      );
      expect(replayFrames).toContain(finalText);
      expect(existsSync(tracePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "later command turn does not overwrite earlier completed command output",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-command-followup-scrollback-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const firstCommand =
        "printf 'LINE_01\\nLINE_02\\nLINE_03\\nLINE_04\\nLINE_05\\nLINE_06\\nLINE_07\\nLINE_08\\n'; printf 'STDERR_LINE\\n' >&2; sleep 0.4; exit 7";
      const alphaCommand =
        "printf 'alpha\\nbeta\\ngamma\\n'; echo 'note on stderr' >&2; true";
      const seqCommand = "seq 1 5; printf 'done\\n'";
      const failingCommand =
        "printf 'will fail\\n'; printf 'error detail\\n' >&2; exit 3";
      const firstFinal =
        "LINE_01\nLINE_02\nLINE_03\nLINE_04\nLINE_05\nLINE_06\nLINE_07\nLINE_08";
      const secondFinal =
        "FOLLOWUP_COMMANDS_COMPLETE\n\n1. true path — exit 0\n2. seq 1 5 — exit 0\n3. forced fail — exit 3";
      const finalHold: HoldState = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "auto",
          permission: {},
          maxxing_mode: "legacy",
        }),
      );

      const followupGateway = startFakeGateway([
        fakeGatewayToolCall("first_command", "terminal", { action: "exec", command: firstCommand }),
        fakeGatewayFinalText(firstFinal),
        fakeGatewaySse([
          {
            type: "text-delta",
            id: "followup_intro",
            delta: "Running a few more shell commands with mixed stdout/stderr and exit codes.",
          },
          {
            type: "tool-call",
            toolCallId: "alpha_command",
            toolName: "terminal",
            input: { action: "exec", command: alphaCommand },
          },
          {
            type: "tool-call",
            toolCallId: "seq_command",
            toolName: "terminal",
            input: { action: "exec", command: seqCommand },
          },
          {
            type: "tool-call",
            toolCallId: "failing_command",
            toolName: "terminal",
            input: { action: "exec", command: failingCommand },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        () => heldGatewayResponse(finalHold, [], [
          { type: "text-delta", id: "held_final", delta: secondFinal },
          {
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
          },
        ]),
      ]);
      gateway = followupGateway;

      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 120,
        height: 36,
        minimumHistoryLines: 800,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-command-followup-scrollback-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: followupGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: followupGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: followupGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(
        "Use terminal to execute exactly this shell command, then do not explain: printf 'LINE_01\\nLINE_02\\nLINE_03\\nLINE_04\\nLINE_05\\nLINE_06\\nLINE_07\\nLINE_08\\n'; printf 'STDERR_LINE\\n' >&2; sleep 0.4; exit 7",
      );
      await waitForCondition(
        () => followupGateway.requests.length >= 2,
        "first command continuation and final response",
      );
      await Bun.sleep(250);
      await session.sendText("run some more cmds");
      await waitForCondition(
        () => finalHold.started,
        "held follow-up final response",
        5_000,
      );

      const firstOutput =
        "│ LINE_01\n│ LINE_02\n│ LINE_03\n│ LINE_04\n│ exit code 7\n│ … 5 lines more (ctrl o to view)";
      const alphaOutput = "│ alpha\n│ beta\n│ gamma\n│ note on stderr";
      const duringFinalStream = await waitForScrollback(
        session,
        (scrollback) =>
          scrollback.includes(firstOutput) && scrollback.includes(alphaOutput),
        "both command outputs before the held final response",
      );
      try {
        expect(duringFinalStream).toContain(firstOutput);
        expect(duringFinalStream).toContain(alphaOutput);
      } finally {
        finalHold.release?.();
      }
      await session.waitForText("3. forced fail — exit 3", TIMEOUT);
      await Bun.sleep(250);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain(firstOutput);
      expect(scrollback).toContain(alphaOutput);
      expect(countOccurrences(scrollback, "│ LINE_01")).toBe(1);
      expect(scrollback.indexOf(firstOutput)).toBeLessThan(
        scrollback.indexOf("FOLLOWUP_COMMANDS_COMPLETE"),
      );
      expect(scrollback.indexOf(alphaOutput)).toBeLessThan(
        scrollback.indexOf("FOLLOWUP_COMMANDS_COMPLETE"),
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      const replayFrames = execFileSync(FX_BIN, ["replay", tapePath, "--frames"], {
        encoding: "utf8",
      });
      expect(replayFrames).toContain("│ LINE_01");
      expect(replayFrames).toContain("FOLLOWUP_COMMANDS_COMPLETE");
      const liveCommandFrame = replayFrames
        .split(/\n--- frame [^\n]+ ---\n/)
        .find((frame) =>
          frame.includes("● Running printf") && frame.includes("│ LINE_01")
        );
      expect(liveCommandFrame).toBeDefined();
      expect(liveCommandFrame!.indexOf("● Running printf")).toBeLessThan(
        liveCommandFrame!.indexOf("│ LINE_01"),
      );
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "length-truncated tool completion preserves output and terminalizes failed row",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-gateway-length-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const sentinelPath = join(workspace, "command-must-not-run.txt");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      gateway = startGateway(() =>
        lengthLimitedCommandResponse("printf executed > command-must-not-run.txt")
      );
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-tui-gateway-length-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the fixture command.");
      const pane = await session.waitForText("did not execute the returned tool calls", TIMEOUT);

      expect(pane).toContain("partial output");
      expect(pane).toContain("● 1 tool call · 1 command · 1 failed");
      expect(pane).toContain("└ Tool failed");
      expect(existsSync(sentinelPath)).toBe(false);
      expect(gateway.requestCount()).toBe(1);

      await session.sendText("/help");
      await session.waitForText("Commands 39", TIMEOUT);
      expect(gateway.requestCount()).toBe(1);
      await session.sendKeys("Escape");
    },
    TIMEOUT,
  );

  test(
    "model catalog opened during warmup refreshes without input or resize",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-model-cache-picker-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const settingsPath = join(home, ".fx", "settings.json");
      const initialSettings = "{}";
      const firstCatalogModel = "anthropic/claude-fable-5";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(settingsPath, initialSettings);

      const heldGateway = startHeldModelsGateway([
        {
          id: firstCatalogModel,
          type: "language",
          released: 1,
          tags: ["tool-use"],
        },
        {
          id: MODEL,
          type: "language",
          released: 1,
          tags: ["tool-use"],
        },
      ]);
      gateway = heldGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 104,
        height: 32,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-model-cache-picker-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_E2E_GATEWAY_MODELS_URL: heldGateway.modelsUrl,
          FX_MODEL: MODEL,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await waitForCondition(
        () => heldGateway.requestCount() === 1,
        "held model-catalog request",
      );
      await session.sendText("/models");
      await session.waitForText("Loading models", TIMEOUT);

      heldGateway.release();
      const catalogPane = await session.waitForPane(
        (pane) => pane.includes(firstCatalogModel) && pane.includes(MODEL),
        TIMEOUT,
      );

      expect(catalogPane).toContain("Models 2");
      expect(catalogPane).toContain("[All]");
      expect(readFileSync(settingsPath, "utf8")).toBe(initialSettings);
      expect(heldGateway.requestCount()).toBe(1);
      expect(session.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session.sendKeys("C-[");
      await session.waitForPane((pane) => pane.includes("𝒇x") && !pane.includes("Tab Provider"), TIMEOUT);
    },
    TIMEOUT,
  );

  test(
    "double Ctrl+C exits while model-cache warmup is held",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-model-cache-exit-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const heldGateway = startHeldModelsGateway();
      gateway = heldGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        remainOnExit: true,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-model-cache-exit-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_E2E_GATEWAY_MODELS_URL: heldGateway.modelsUrl,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "gateway,app,input",
        },
      });

      await session.waitForText("Run /help", TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      await waitForCondition(
        () => heldGateway.requestCount() === 1,
        "held model-catalog request",
      );

      await session.sendKeys("C-c");
      await session.waitForText("press ctrl+c again to exit", TIMEOUT);
      await session.sendKeys("C-c");

      await waitForCondition(
        () => !session!.isPaneAlive(),
        "pane exit before model-catalog release",
        3_000,
      );

      const scrollback = await session.captureFullScrollback();
      const rawScrollback = await session.captureFullScrollbackEscapes();
      expect(scrollback).toContain("Run /help");
      expect(scrollback).not.toContain("press ctrl+c again to exit");
      expect(rawScrollback).toContain("Run /help");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(existsSync(tracePath)).toBe(true);
      expect(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
          encoding: "utf8",
        }),
      ).not.toBe("");

      heldGateway.release();
    },
    TIMEOUT,
  );
});

describe.skipIf(!tmuxAvailable())("transcript scrollback release", () => {
  const SB_TIMEOUT = 60_000;
  let root: string | undefined;
  let session: TmuxSession | undefined;
  let gateway: { stop: () => void } | undefined;

  afterEach(async () => {
    await session?.kill();
    session = undefined;
    gateway?.stop();
    gateway = undefined;
    if (root) rmSync(root, { recursive: true, force: true });
    root = undefined;
  });

  function sbSseEvent(event: object): string {
    return `data: ${JSON.stringify(event)}\n\n`;
  }

  function sbTokenChunks(text: string, size: number): string[] {
    const chunks: string[] = [];
    for (let index = 0; index < text.length; index += size) {
      chunks.push(text.slice(index, index + size));
    }
    return chunks;
  }

  function sbStreamedFinalText(lines: string[], delayMs: number) {
    return () =>
      new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            const encoder = new TextEncoder();
            for (const line of lines) {
              controller.enqueue(
                encoder.encode(
                  sbSseEvent({
                    type: "text-delta",
                    id: "answer_1",
                    delta: `${line}\n`,
                  }),
                ),
              );
              await Bun.sleep(delayMs);
            }
            controller.enqueue(
              encoder.encode(
                sbSseEvent({
                  type: "finish",
                  finishReason: { unified: "stop", raw: "stop" },
                  usage: {
                    inputTokens: { total: 3 },
                    outputTokens: { total: 5 },
                  },
                }),
              ),
            );
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
  }

  // Models an ordinary model/network wait: the transcript sits byte-stable
  // for several render ticks while this response is already pending. Release
  // must not treat that quiet window as finality.
  function sbHeldSerializedToolCall(
    id: string,
    name: string,
    input: string,
    holdMs: number,
  ) {
    return () =>
      new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            const encoder = new TextEncoder();
            await Bun.sleep(holdMs);
            controller.enqueue(
              encoder.encode(
                sbSseEvent({
                  type: "tool-call",
                  toolCallId: id,
                  toolName: name,
                  input,
                }),
              ),
            );
            controller.enqueue(
              encoder.encode(
                sbSseEvent({
                  type: "finish",
                  finishReason: { unified: "tool-calls", raw: "tool-calls" },
                }),
              ),
            );
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
  }

  function sbToolCallBatch(
    calls: Array<{ id: string; name: string; input: object }>,
    assistantText?: string,
    reasoning?: { chunks: string[]; delayMs: number; id: string },
  ) {
    const finishEvents = (): object[] => {
      const events: object[] = [];
      if (assistantText) {
        events.push({
          type: "text-delta",
          id: "answer_1",
          delta: assistantText,
        });
      }
      for (const call of calls) {
        events.push({
          type: "tool-call",
          toolCallId: call.id,
          toolName: call.name,
          input: call.input,
        });
      }
      events.push({
        type: "finish",
        finishReason: { unified: "tool-calls", raw: "tool-calls" },
      });
      return events;
    };
    if (!reasoning) {
      return new Response(
        `${finishEvents()
          .map((event) => sbSseEvent(event))
          .join("")}data: [DONE]\n\n`,
        { headers: { "content-type": "text/event-stream" } },
      );
    }
    return () =>
      new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            const encoder = new TextEncoder();
            controller.enqueue(
              encoder.encode(
                sbSseEvent({ type: "reasoning-start", id: reasoning.id }),
              ),
            );
            for (const chunk of reasoning.chunks) {
              controller.enqueue(
                encoder.encode(
                  sbSseEvent({
                    type: "reasoning-delta",
                    id: reasoning.id,
                    delta: chunk,
                  }),
                ),
              );
              await Bun.sleep(reasoning.delayMs);
            }
            controller.enqueue(
              encoder.encode(
                sbSseEvent({ type: "reasoning-end", id: reasoning.id }),
              ),
            );
            for (const event of finishEvents()) {
              controller.enqueue(encoder.encode(sbSseEvent(event)));
            }
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
  }

  function sbReasoningThenStreamedFinalText(
    reasoningChunks: string[],
    chunks: string[],
    delayMs: number,
  ) {
    return () =>
      new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            const encoder = new TextEncoder();
            controller.enqueue(
              encoder.encode(
                sbSseEvent({ type: "reasoning-start", id: "r-final" }),
              ),
            );
            for (const chunk of reasoningChunks) {
              controller.enqueue(
                encoder.encode(
                  sbSseEvent({
                    type: "reasoning-delta",
                    id: "r-final",
                    delta: chunk,
                  }),
                ),
              );
              await Bun.sleep(delayMs);
            }
            controller.enqueue(
              encoder.encode(
                sbSseEvent({ type: "reasoning-end", id: "r-final" }),
              ),
            );
            controller.enqueue(
              encoder.encode(sbSseEvent({ type: "text-start", id: "answer_1" })),
            );
            for (const chunk of chunks) {
              controller.enqueue(
                encoder.encode(
                  sbSseEvent({
                    type: "text-delta",
                    id: "answer_1",
                    delta: chunk,
                  }),
                ),
              );
              await Bun.sleep(delayMs);
            }
            controller.enqueue(
              encoder.encode(sbSseEvent({ type: "text-end", id: "answer_1" })),
            );
            controller.enqueue(
              encoder.encode(
                sbSseEvent({
                  type: "finish",
                  finishReason: { unified: "stop", raw: "stop" },
                  usage: {
                    inputTokens: { total: 3 },
                    outputTokens: { total: 5 },
                  },
                }),
              ),
            );
            controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
  }

  function sbSettings(): string {
    return JSON.stringify({
      sandbox: "none",
      permission_mode: "yolo",
      permission: {},
      startup_scrollback: false,
      input_appearance: "lines",
      maxxing_mode: "minimal",
      statusLine: { context: true },
      yolo_acknowledged: true,
    });
  }

  test(
    "closed tool groups enter native scrollback before the turn finishes",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-sb-tool-groups-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      for (let index = 1; index <= 3; index += 1) {
        writeFileSync(join(workspace, `source-${index}.txt`), `source ${index}\n`);
      }
      writeFileSync(join(home, ".fx", "settings.json"), sbSettings());
      writeFileSync(stderrPath, "");

      const finalText = "TOOL_GROUP_SCROLLBACK_FINAL";
      gateway = startFakeGateway([
        sbToolCallBatch(
          Array.from({ length: 3 }, (_, index) => ({
            id: `group-a-read-${index + 1}`,
            name: "read_file",
            input: { path: `source-${index + 1}.txt` },
          })),
          "FIRST_GROUP_INTRO",
        ),
        sbToolCallBatch(
          [
            {
              id: "group-b-command",
              name: "terminal",
              input: {
                action: "exec",
                command: "sleep 5; printf HELD_COMMAND_DONE",
              },
            },
          ],
          "SECOND_GROUP_INTRO",
        ),
        fakeGatewayFinalText(finalText),
      ]);
      const fakeGateway = gateway as ReturnType<typeof startFakeGateway>;

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        width: 80,
        height: 14,
        minimumHistoryLines: 10_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-sb-tool-groups-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_MAX_AGENT_STEPS: "4",
        },
      });

      const assertClosedGroupOnce = (scrollback: string, label: string) => {
        expect(
          countOccurrences(scrollback, "FIRST_GROUP_INTRO"),
          `${label}: first intro`,
        ).toBe(1);
        expect(
          countOccurrences(scrollback, "● 3 tool calls · 3 read"),
          `${label}: first header`,
        ).toBe(1);
        for (let index = 1; index <= 3; index += 1) {
          expect(
            countOccurrences(scrollback, `Read source-${index}.txt`),
            `${label}: source ${index}`,
          ).toBe(1);
        }
      };

      await session.waitForComposer(SB_TIMEOUT);
      await session.sendText("Run the two prepared groups.");
      await session.waitForText("Running sleep 5; printf HELD_COMMAND_DONE", SB_TIMEOUT);
      await Bun.sleep(150);

      const beforeResize = await session.captureFullScrollback();
      assertClosedGroupOnce(beforeResize, "before resize");
      expect(beforeResize).toContain("SECOND_GROUP_INTRO");

      await session.resizeWindow(81, 15, 500);
      const afterResize = await session.captureFullScrollback();
      assertClosedGroupOnce(afterResize, "after resize");
      expect(afterResize).toContain("SECOND_GROUP_INTRO");

      await session.waitForText(finalText, SB_TIMEOUT);
      await session.waitForPane(hasEmptyComposer, SB_TIMEOUT);
      const completed = await session.captureFullScrollback();
      assertClosedGroupOnce(completed, "after completion");
      expect(countOccurrences(completed, finalText)).toBe(1);
      expect(fakeGateway.requests).toHaveLength(3);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    SB_TIMEOUT + 30_000,
  );

  test(
    "sequential tool group and streamed markdown keep native scrollback final",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-sb-release-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "sb-release.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(workspace, "docs"), { recursive: true });
      for (let index = 1; index <= 17; index += 1) {
        writeFileSync(
          join(workspace, "docs", `source-${String(index).padStart(2, "0")}.md`),
          `source row ${index}\n`,
        );
      }
      writeFileSync(join(home, ".fx", "settings.json"), sbSettings());
      writeFileSync(stderrPath, "");

      const codeALines = Array.from(
        { length: 6 },
        (_, index) => `CODE_A_LINE_${String(index + 1).padStart(2, "0")}();`,
      );
      const codeBLines = Array.from(
        { length: 4 },
        (_, index) => `CODE_B_LINE_${String(index + 1).padStart(2, "0")}();`,
      );
      const responseLines = [
        "RESP_INTRO here is how the hook works today.",
        "",
        "1. RESP_ITEM_ONE the hook is mounted with:",
        "",
        "```ts",
        ...codeALines,
        "```",
        "",
        "2. RESP_ITEM_TWO its logical cache key is generated from only:",
        "",
        "```ts",
        ...codeBLines,
        "```",
        "",
        "RESP_TAIL that is the whole flow.",
      ];

      const readResponse = (index: number) => {
        const input = JSON.stringify({
          path: `docs/source-${String(index).padStart(2, "0")}.md`,
        });
        if (index === 15) {
          return sbHeldSerializedToolCall(
            `sb-read-${index}`,
            "read_file",
            input,
            350,
          );
        }
        return fakeGatewaySerializedToolCall(
          `sb-read-${index}`,
          "read_file",
          input,
        );
      };
      gateway = startFakeGateway([
        fakeGatewaySerializedToolCall(
          "sb-list",
          "list_files",
          JSON.stringify({ path: "docs" }),
          "I'll inspect the SWR wiring end to end.",
        ),
        ...Array.from({ length: 17 }, (_, index) => readResponse(index + 1)),
        sbStreamedFinalText(responseLines, 60),
      ]);
      const fakeGateway = gateway as ReturnType<typeof startFakeGateway>;

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        width: 100,
        height: 20,
        minimumHistoryLines: 10_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-sb-release-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(SB_TIMEOUT);
      await session.sendText("Explain the SWR hook wiring.");
      await session.waitForText("RESP_TAIL", SB_TIMEOUT);
      await session.waitForPane(hasEmptyComposer, SB_TIMEOUT);
      await Bun.sleep(250);

      const scrollback = await session.captureFullScrollback();

      // The group header must survive as its final text exactly once; a
      // frozen intermediate count would add another "tool call" line.
      expect(countOccurrences(scrollback, "tool call")).toBe(1);
      expect(scrollback).toContain("18 tool calls");
      for (let index = 1; index <= 17; index += 1) {
        expect(
          countOccurrences(
            scrollback,
            `Read docs/source-${String(index).padStart(2, "0")}.md`,
          ),
        ).toBe(1);
      }

      const orderedMarkers = [
        "RESP_INTRO",
        "RESP_ITEM_ONE",
        ...codeALines.map((line) => line.slice(0, line.length - 3)),
        "RESP_ITEM_TWO",
        ...codeBLines.map((line) => line.slice(0, line.length - 3)),
        "RESP_TAIL",
      ];
      let previousIndex = -1;
      for (const marker of orderedMarkers) {
        expect(countOccurrences(scrollback, marker)).toBe(1);
        const index = scrollback.indexOf(marker);
        expect(index).toBeGreaterThan(previousIndex);
        previousIndex = index;
      }
      const introIndex = scrollback.indexOf("RESP_INTRO");
      const tailIndex = scrollback.indexOf("RESP_TAIL");
      const responseRegion = scrollback.slice(introIndex, tailIndex);
      expect(responseRegion).not.toContain("Read docs/source-");
      expect(responseRegion).not.toMatch(/(?:Thinking \(|\(↑\d)/);
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    SB_TIMEOUT + 30_000,
  );

  test(
    "parallel tool batches and token-streamed markdown keep native scrollback final",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-sb-batch-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "sb-batch.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(workspace, "docs"), { recursive: true });
      for (let index = 1; index <= 20; index += 1) {
        writeFileSync(
          join(workspace, "docs", `source-${String(index).padStart(2, "0")}.md`),
          `alpha scoped row ${index}\n`.repeat(3),
        );
      }
      writeFileSync(join(home, ".fx", "settings.json"), sbSettings());
      writeFileSync(stderrPath, "");

      const fillerLines = Array.from(
        { length: 45 },
        (_, index) =>
          `FILLER_ROW_${String(index + 1).padStart(2, "0")} history line.`,
      );
      let readCounter = 0;
      const readCall = () => {
        readCounter += 1;
        return {
          id: `sb-read-${readCounter}`,
          name: "read_file",
          input: {
            path: `docs/source-${String(readCounter).padStart(2, "0")}.md`,
          },
        };
      };
      let grepCounter = 0;
      const grepCall = (pattern: string) => {
        grepCounter += 1;
        return {
          id: `sb-grep-${grepCounter}`,
          name: "grep_files",
          input: { pattern, path: "docs", include: "*.md", mode: "matches" },
        };
      };
      const responseLines = [
        "RESP_INTRO teamData is cached client-side, but not by scope.",
        "The path is:",
        "",
        "1. RESP_ITEM_ONE the dropdown calls:",
        "",
        "```ts",
        "CODE_A_LINE_01(['scoped', 'team'], {}, {",
        "CODE_A_LINE_02: true,",
        "CODE_A_LINE_03: true,",
        "})",
        "```",
        "",
        "2. RESP_ITEM_TWO its logical cache key is generated from only:",
        "",
        "```ts",
        'CODE_B_LINE_01 // ["team", {}]',
        "```",
        "",
        "3. RESP_ITEM_THREE scoped data is stored in a singleton atom:",
        "",
        "```ts",
        "CODE_C_LINE_01: atom(ASSERT_SWR_DATA)",
        "```",
        "",
        "4. RESP_ITEM_FOUR revalidateNever disables all refresh paths:",
        "",
        "```ts",
        "CODE_D_LINE_01: false",
        "CODE_D_LINE_02: false",
        "CODE_D_LINE_03: false",
        "CODE_D_LINE_04: false",
        "```",
        "",
        "RESP_TAIL that is why the previous atom value remains indefinitely.",
      ];

      gateway = startFakeGateway([
        sbStreamedFinalText(fillerLines, 10),
        sbToolCallBatch(
          [
            readCall(),
            readCall(),
            grepCall("useServerQuerySWR"),
            grepCall("revalidateNever"),
          ],
          "I'll trace how the cache keys are built end to end.",
        ),
        sbToolCallBatch([
          {
            id: "sb-glob",
            name: "glob_files",
            input: { pattern: "**/*.md", path: "docs", mode: "matches" },
          },
          readCall(),
          readCall(),
          grepCall("ScopedPromisesProvider"),
        ]),
        sbToolCallBatch([
          readCall(),
          readCall(),
          readCall(),
          grepCall("revalidateOnFocus"),
        ]),
        sbToolCallBatch([
          readCall(),
          readCall(),
          readCall(),
          grepCall("ContextSWRProvider"),
        ]),
        sbToolCallBatch([
          readCall(),
          grepCall("getWritableScopedAtoms"),
          grepCall("AltProvidersProbe"),
          grepCall("scope change"),
        ]),
        sbToolCallBatch([grepCall("router.")], undefined, {
          chunks: Array.from(
            { length: 10 },
            (_, index) => `thinking hard step ${index} `,
          ),
          delayMs: 350,
          id: "r-pause",
        }),
        sbToolCallBatch([readCall()]),
        sbReasoningThenStreamedFinalText(
          Array.from(
            { length: 8 },
            (_, index) => `assembling the final answer ${index} `,
          ),
          sbTokenChunks(responseLines.join("\n"), 10),
          20,
        ),
      ]);
      const fakeGateway = gateway as ReturnType<typeof startFakeGateway>;

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        width: 149,
        height: 51,
        minimumHistoryLines: 10_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-sb-batch-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(SB_TIMEOUT);
      await session.sendText("Fill the history first.");
      await session.waitForText("FILLER_ROW_45", SB_TIMEOUT);
      await session.waitForPane(hasEmptyComposer, SB_TIMEOUT);
      await session.sendText("How would client-side teamData go stale?");
      await session.waitForText("RESP_TAIL", SB_TIMEOUT);
      await session.waitForPane(hasEmptyComposer, SB_TIMEOUT);
      await Bun.sleep(250);

      const scrollback = await session.captureFullScrollback();

      const childMarkers = [
        ...Array.from(
          { length: 12 },
          (_, index) =>
            `Read docs/source-${String(index + 1).padStart(2, "0")}.md`,
        ),
        "Searched useServerQuerySWR",
        "Searched revalidateNever",
        "Searched ScopedPromisesProvider",
        "Searched revalidateOnFocus",
        "Searched ContextSWRProvider",
        "Searched getWritableScopedAtoms",
        "Searched AltProvidersProbe",
        "Searched scope change",
        "Searched router.",
        "Matched **/*.md",
      ];
      for (const marker of childMarkers) {
        expect(countOccurrences(scrollback, marker)).toBe(1);
      }
      const orderedResponseMarkers = [
        "RESP_INTRO",
        "RESP_ITEM_ONE",
        "CODE_A_LINE_01",
        "CODE_A_LINE_02",
        "CODE_A_LINE_03",
        "RESP_ITEM_TWO",
        "CODE_B_LINE_01",
        "RESP_ITEM_THREE",
        "CODE_C_LINE_01",
        "RESP_ITEM_FOUR",
        "CODE_D_LINE_01",
        "CODE_D_LINE_04",
        "RESP_TAIL",
      ];
      let previousIndex = -1;
      for (const marker of orderedResponseMarkers) {
        expect(countOccurrences(scrollback, marker)).toBe(1);
        const index = scrollback.indexOf(marker);
        expect(index).toBeGreaterThan(previousIndex);
        previousIndex = index;
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    SB_TIMEOUT + 60_000,
  );
});
