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
  AUTO_EXA_SERIALIZED_TOOL_NAMES,
  customProviderGuidanceState,
  findUnavailableCapabilityReferences,
  parseGatewayRequest,
  serializedToolNames,
  toolShapesWithoutDescriptions,
  WEB_SEARCH_GUIDANCE,
  contentText,
} from "./conditional-guidance-oracle";
import {
  composerContains,
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewaySerializedToolCall,
  fakeGatewaySse,
  fakeGatewayToolCall,
  fakeShellRun,
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
      'data: {"type":"tool-input-start","id":"command_provisional","toolName":"shell"}\n\n' +
      `data: ${JSON.stringify({
        type: "tool-call",
        toolCallId: "command_final",
        toolName: "shell",
        input: {
          request: {
            action: "run",
            yield_time_ms: 30_000,
            timeout_ms: 600_000,
            command,
          },
        },
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
    /^• Generating \(\d+(?:h\d+m\d+s|m\d+s|s)\) \(↑\d+(?:\.\d)?k? ↓(\d+(?:\.\d)?k?)\)$/gm,
  )];
  const value = matches.at(-1)?.[1];
  if (!value) return null;
  return value.endsWith("k")
    ? Number.parseFloat(value.slice(0, -1)) * 1000
    : Number.parseFloat(value);
}

function quietToolPayloadOutputTokens(scrollback: string): number | null {
  const matches = [...scrollback.matchAll(
    /^• Running \(\d+(?:h\d+m\d+s|m\d+s|s)\) \(↑\d+(?:\.\d)?k? ↓(\d+(?:\.\d)?k?)\)$/gm,
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
  const enterIndex = findEnterAfterSubmittedPrompt(frames, submittedPrompt);

  const firstOutput = frames
    .slice(enterIndex + 1)
    .find((frame) => frame.kind === 1);
  expect(firstOutput).toBeDefined();
  expect(firstOutput!.payload.includes(Buffer.from(submittedPrompt))).toBe(true);
}

function findEnterAfterSubmittedPrompt(
  frames: ReturnType<typeof readTapeFrames>,
  submittedPrompt: string,
): number {
  const promptInputIndex = frames.findIndex((frame) =>
    frame.kind === 2 && frame.payload.includes(Buffer.from(submittedPrompt))
  );
  expect(promptInputIndex).toBeGreaterThanOrEqual(0);
  const enterIndex = frames.findIndex((frame, index) =>
    index > promptInputIndex &&
    frame.kind === 2 &&
    frame.payload.equals(Buffer.from("\r"))
  );
  expect(enterIndex).toBeGreaterThan(promptInputIndex);
  return enterIndex;
}

function assertSubmittedPromptRowStaysStableAfterEnter(
  tapePath: string,
  framesRoot: string,
  submittedPrompt: string,
) {
  const frames = readTapeFrames(tapePath);
  const enterIndex = findEnterAfterSubmittedPrompt(frames, submittedPrompt);
  const firstOutput = frames.slice(enterIndex + 1).find((frame) => frame.kind === 1);
  expect(firstOutput).toBeDefined();
  const gridDir = join(framesRoot, "frames");
  const frameNames = readdirSync(gridDir)
    .filter((name) => name.endsWith(".grid.txt"))
    .sort();
  const firstGrid = readFileSync(
    join(gridDir, `${String(firstOutput!.index).padStart(4, "0")}.grid.txt`),
    "utf8",
  );
  const thinkingGrid = frameNames
    .filter((name) => Number.parseInt(name, 10) > firstOutput!.index)
    .map((name) => readFileSync(join(gridDir, name), "utf8"))
    .find((grid) => grid.includes("Thinking"));
  expect(thinkingGrid).toBeDefined();

  const promptRow = (grid: string) => {
    const row = grid.split(/\r?\n/).findIndex((line) =>
      line.includes(submittedPrompt)
    );
    expect(row).toBeGreaterThanOrEqual(0);
    return row;
  };
  expect(promptRow(thinkingGrid!)).toBe(
    promptRow(firstGrid),
  );
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
      const help = await waitForPaneOrDone(session, "Commands 35", donePath);
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
  test("file edits keep earlier instruction bytes stable", async () => {
    const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
      "fx-tui-stable-verification-",
      [
        fakeGatewayToolCall("write_first", "write_file", { path: "first.txt", content: "first\n" }),
        fakeGatewayToolCall("write_second", "write_file", { path: "second.txt", content: "second\n" }),
        fakeGatewayFinalText("STABLE_VERIFICATION_DONE"),
      ],
    );
    await session!.sendText("Create first.txt and second.txt with their respective contents.");
    await session!.waitForText("STABLE_VERIFICATION_DONE", TIMEOUT);
    await session!.waitForComposer(TIMEOUT);
    expect(queuedGateway.requests).toHaveLength(3);
    const instructions = queuedGateway.requests.map((request) =>
      JSON.parse(request.body).prompt.filter((message: { role: string }) => message.role === "system")
    );
    expect(instructions[0].length).toBeGreaterThan(0);
    expect(instructions[1]).toEqual(instructions[0]);
    expect(instructions[2]).toEqual(instructions[0]);
    expect(readFileSync(join(root!, "workspace", "first.txt"), "utf8")).toBe("first\n");
    expect(readFileSync(join(root!, "workspace", "second.txt"), "utf8")).toBe("second\n");
    expect(await session!.captureFullScrollback()).toContain("STABLE_VERIFICATION_DONE");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);

  test(
    "clear response language mismatch never reaches TUI scrollback",
    async () => {
      const rejected = "我会先检查锁文件和依赖清单。";
      const accepted = "I will inspect the lockfile next.";
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-response-language-retry-",
        [
          fakeGatewayFinalText(rejected),
          fakeGatewayFinalText(accepted),
        ],
      );

      await session!.sendText(
        "The lockfile is broken again. Say what you will inspect next.",
      );
      await session!.waitForText(accepted, TIMEOUT);
      await session!.waitForComposer(TIMEOUT);

      const scrollback = await session!.captureFullScrollback();
      expect(scrollback).toContain(accepted);
      expect(scrollback).not.toContain(rejected);
      expect(queuedGateway.requests).toHaveLength(2);
      expect(queuedGateway.requests[1]!.body).toContain(
        "The previous candidate used a different language",
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
    "assistant publishes a complete markdown block before the following tool",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-bounded-assistant-pacing-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const framesRoot = join(root, "replay-frames");
      const hold: HoldState = { started: false, cancelled: false };
      const renderedSentence =
        "PACING_STREAM_SENTENCE keeps smooth markdown visible before tool presentation begins.";
      const sourceSentence = renderedSentence.replace("smooth", "**smooth**");
      const toolMarker = "PACING_TOOL_BOUNDARY_DONE";
      const finalText = "PACING_STREAM_COMPLETE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const queuedGateway = startFakeGateway([
        () =>
          heldGatewayResponse(
            hold,
            [{ type: "text-delta", id: "answer_1", delta: `${sourceSentence}\n\n` }],
            [
              { type: "tool-input-start", id: "pacing_tool", toolName: "shell" },
              {
                type: "tool-call",
                toolCallId: "pacing_tool",
                toolName: "shell",
                input: { request: {
                  action: "run",
                  yield_time_ms: 30_000,
                  timeout_ms: 10_000,
                  command: `printf ${toolMarker}`,
                } },
              },
              {
                type: "finish",
                finishReason: { unified: "tool-calls", raw: "tool-calls" },
              },
            ],
          ),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = queuedGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 120,
        height: 40,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-bounded-assistant-pacing-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Render markdown, then run the command.");
      await waitForCondition(
        () => queuedGateway.requests.length === 1 && hold.started,
        "held markdown response",
      );
      await session.waitForText(renderedSentence, TIMEOUT);
      hold.release?.();
      await session.waitForText(finalText, TIMEOUT);

      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", framesRoot], {
        encoding: "utf8",
      });
      const grids = readdirSync(join(framesRoot, "frames"))
        .filter((name) => name.endsWith(".grid.txt"))
        .sort()
        .map((name) => readFileSync(join(framesRoot, "frames", name), "utf8"));
      const prefixLength = (grid: string): number => {
        const rows = grid.split("\n");
        for (let count = renderedSentence.length; count > 0; count -= 1) {
          if (rows.some((row) => row.startsWith(`|  ${renderedSentence.slice(0, count)}`))) {
            return count;
          }
        }
        return 0;
      };
      const prefixLengths = grids
        .map(prefixLength)
        .filter((count, index, values) => count > 0 && count !== values[index - 1]);
      const paragraphFrame = grids.findIndex((grid) => grid.includes(renderedSentence));
      const toolFrame = grids.findIndex((grid) => grid.includes(toolMarker));

      expect(prefixLengths).toEqual([renderedSentence.length]);
      expect(paragraphFrame).toBeGreaterThanOrEqual(0);
      expect(toolFrame).toBeGreaterThanOrEqual(0);
      expect(paragraphFrame).toBeLessThan(toolFrame);
      expect(prefixLength(grids[toolFrame]!)).toBe(renderedSentence.length);
      expect(grids[toolFrame]!.indexOf(renderedSentence)).toBeLessThan(
        grids[toolFrame]!.indexOf(toolMarker),
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "streamed write payload keeps the activity row live",
    async () => {
      const hold: ToolPayloadHoldState = { started: false, cancelled: false };
      const nextStep: HoldState = { started: false, cancelled: false };
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
          () => heldGatewayResponse(nextStep, [], [
            { type: "text-delta", id: "answer_2", delta: finalSentinel },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: {
                inputTokens: { total: 8 },
                outputTokens: { total: 5 },
              },
            },
          ]),
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
      await waitForCondition(
        () => queuedGateway.requests.length === 2 && nextStep.started,
        "next model step after tool completion",
      );
      const nextStepPane = await waitForScrollback(
        session!,
        (value) =>
          /• Thinking \(\d+(?:h\d+m\d+s|m\d+s|s)\) \(↑\d+(?:\.\d)?k? ↓\d+(?:\.\d)?k?\)/.test(
            value,
          ) && !value.includes(finalSentinel),
        "thinking activity during the next admitted model step",
      );
      expect(nextStepPane).not.toContain(finalSentinel);
      nextStep.release?.();
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
          return fakeGatewayToolCall("list_1", "glob_files", { pattern: "*", path: "." });
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
    "provider route recovery counts down and accepts slow response headers",
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
      const queuedGateway = startFakeGateway([
        retryAfterUnavailable(4),
        async () => {
          await Bun.sleep(35_000);
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
      await session.sendText("Recover from provider route failure.");
      await session.waitForText("retrying request in 4s", TIMEOUT);
      await session.waitForText("retrying request in 3s", TIMEOUT);
      await session.waitForText("retrying request in 2s", TIMEOUT);
      await session.waitForText("retrying request in 1s", TIMEOUT);
      await waitForCondition(
        () => queuedGateway.requests.length === 2,
        "silent-head retry request",
      );
      await session.waitForText("attempt 2/10", TIMEOUT);

      const inFlightPane = await session.capturePane();
      expect(inFlightPane).toContain("attempt 2/10");
      expect(inFlightPane).not.toContain("retrying request in 1s");

      await session.resizeWindow(32, 24);
      const narrowPane = await session.capturePane();
      expect(narrowPane).toContain("⚠ Provider unavailable");
      expect(narrowPane).toContain("attempt 2/10");
      expect(narrowPane).not.toContain("▲");

      await session.resizeWindow(72, 24);
      await session.waitForText(finalText, TIMEOUT * 2);
      const scrollback = await session.captureFullScrollback();

      expect(queuedGateway.requests.length).toBe(2);
      expect(scrollback).not.toContain("System");
      expect(scrollback).not.toContain("Attempt 1 failed. Retrying route.");
      expect(scrollback).not.toContain("✓ recovered");
      expect(scrollback).toMatch(TURN_SUMMARY_WITH_TOKENS);
      expect(scrollback).toContain(finalText);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
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
      const continued: HoldState = { started: false, cancelled: false };
      const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
        "fx-tui-recovery-continue-",
        [
          ...Array.from({ length: 10 }, () => retryAfterUnavailable(0)),
          () => heldGatewayResponse(continued, [], [
            { type: "text-delta", id: "answer_1", delta: finalText },
            { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
          ]),
        ],
      );

      await session!.sendText(originalPrompt);
      await session!.waitForText("recovery paused after 10/10 attempts", TIMEOUT);
      await session!.waitForComposer(TIMEOUT);
      expect(queuedGateway.requests).toHaveLength(10);

      await session!.sendText("/continue");
      await waitForCondition(() => continued.started, "continued paused response");
      await session!.waitForText("Thinking", TIMEOUT);
      continued.release?.();
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

  for (const outcome of ["finish", "cancel"] as const) {
    test(
      `reopened recovery shows progress before response text and can ${outcome}`,
      async () => {
        const interrupted: HoldState = { started: false, cancelled: false };
        const resumed: HoldState = { started: false, cancelled: false };
        const prompt = "Read before.txt, then report the result.";
        const finalText = "Reopened recovery completed once.";
        const { queuedGateway, stderrPath } = await launchRouteRecoveryTui(
          "fx-tui-recovery-progress-",
          [
            fakeGatewayToolCall("read_before_resume", "read_file", { path: "before.txt" }),
            () => heldGatewayResponse(interrupted),
            () => heldGatewayResponse(resumed, [], [
              { type: "text-delta", id: "answer_1", delta: finalText },
              { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
            ]),
          ],
        );
        writeFileSync(join(root!, "workspace", "before.txt"), "Completed read survives restart.\n");
        await session!.sendText(prompt);
        await waitForCondition(() => interrupted.started, "checkpointed response");
        await session!.kill();
        session = null;
        const resumedStderr = join(root!, "resumed-stderr.log");
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --resume-last`,
          cwd: join(root!, "workspace"),
          width: 100,
          height: 32,
          stderrPath: resumedStderr,
          env: {
            HOME: join(root!, "home"),
            AI_GATEWAY_API_KEY: "fake-route-recovery-key",
            FX_AUTO_UPGRADE: "0",
            FX_PERMISSION_MODE: "auto",
            FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
            FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${queuedGateway.baseUrl}/coding-agent/v1/models`,
            FX_MODEL: MODEL,
          },
        });
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/continue");
        await waitForCondition(() => resumed.started, "admitted resumed response");
        await session.waitForText("Thinking", TIMEOUT);
        for (let attempt = 0; attempt < 3; attempt++) await session.sendText("/continue");
        await session.waitForText("wait for the current response to finish", TIMEOUT);
        expect(queuedGateway.requests).toHaveLength(3);
        expect(await session.capturePane()).toContain("Thinking");

        if (outcome === "finish") {
          resumed.release?.();
          await session.waitForText(finalText, TIMEOUT);
        } else {
          await session.sendKeys("Escape");
          await session.waitForText("What can fx do differently?", TIMEOUT);
        }
        await session.waitForPane((pane) => !pane.includes("Thinking") && hasEmptyComposer(pane), TIMEOUT);
        const scrollback = await session.captureFullScrollback();
        expect(scrollback.split(prompt).length - 1).toBe(1);
        expect(scrollback.split("└ Read before.txt").length - 1).toBe(1);
        expect(scrollback.split(finalText).length - 1).toBe(outcome === "finish" ? 1 : 0);
        expect(queuedGateway.requests).toHaveLength(3);
        expect(session.isAlive()).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(readFileSync(resumedStderr, "utf8")).toBe("");
      },
      TIMEOUT * 2,
    );
  }

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
        expect(retryRequest.providerOptions?.gateway).toEqual({ caching: "auto" });
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
      await session!.waitForText("What can fx do differently?", TIMEOUT);
      await session!.waitForComposer(TIMEOUT);
      const scrollback = await session!.captureFullScrollback();

      expect(queuedGateway.requests).toHaveLength(3);
      expect(scrollback).toContain("What can fx do differently?");
      expect(scrollback).not.toContain("System: cancelled");
      expect(scrollback).not.toContain("Cancelling");
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
          fakeGatewayFinalText(finalText),
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
      expect(scrollback).toContain("Response interrupted. Restarting.");
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
      expect(secondRequest.providerOptions?.gateway).toEqual({ caching: "auto" });
      const finalRequest = JSON.parse(queuedGateway.requests[3]!.body);
      expect(finalRequest).not.toHaveProperty("fast");
      expect(finalRequest.providerOptions?.gateway).toEqual({ caching: "auto" });
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
    "provider error after assistant output restarts a separate visible response",
    async () => {
      const firstCatalogModel = "anthropic/claude-fable-5";
      const finalText = "A complete replacement response.";
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
            existsSync(join(sessionsRoot, entry, "events.jsonl")),
          ),
        "session event log",
      );
      const sessionId = readdirSync(sessionsRoot).find((entry) =>
        existsSync(join(sessionsRoot, entry, "events.jsonl")),
      );
      if (!sessionId) throw new Error("session event log was not found");

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
      const tracePath = join(root, "fx-trace.log");
      const framesRoot = join(root, "replay-frames");
      const submittedPrompt = "IDLE_SUBMIT_ORDER_SENTINEL";
      const newerDraft = "RAPID_SECOND_DRAFT_SENTINEL";
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
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,worker",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendLiteral(submittedPrompt);
      const preEnterGrid = await session.capturePaneGrid();
      session.sendKeysImmediate(["Enter"]);
      session.sendLiteralImmediate(newerDraft);
      await waitForCondition(
        () => heldGateway.requests.length === 1 && hold.started,
        "held idle submitted prompt stream",
      );
      await session.waitForText("Thinking", TIMEOUT);
      await Bun.sleep(250);
      const thinkingGrid = await session.capturePaneGrid();
      const rowContaining = (grid: string[], needle: string) => {
        const row = grid.findIndex((line) => line.includes(needle));
        expect(row).toBeGreaterThanOrEqual(0);
        return row;
      };
      expect(rowContaining(thinkingGrid, submittedPrompt)).toBe(
        rowContaining(preEnterGrid, submittedPrompt),
      );
      expect(composerContains(thinkingGrid.join("\n"), newerDraft)).toBe(true);
      await session.sendKeys("C-c");
      expect(composerContains((await session.capturePaneGrid()).join("\n"), newerDraft)).toBe(false);
      expect(hold.cancelled).toBe(false);
      await session.sendKeys("C-c");
      const cancelledPane = await session.waitForText(
        "What can fx do differently?",
        TIMEOUT,
      );

      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", framesRoot], {
        encoding: "utf8",
      });
      assertFirstPostEnterOutputShowsSubmittedPrompt(tapePath, submittedPrompt);
      assertSubmittedPromptRowStaysStableAfterEnter(
        tapePath,
        framesRoot,
        submittedPrompt,
      );
      assertThinkingFramesShowSubmittedPrompt(framesRoot, submittedPrompt);
      const trace = readFileSync(tracePath, "utf8");
      const frameCommitted = trace.indexOf("event=pending_prompt_frame_committed");
      const promptQueued = trace.indexOf("event=prompt_enqueue");
      const workerBegin = trace.indexOf("event=worker_begin");
      expect(frameCommitted).toBeGreaterThanOrEqual(0);
      expect(promptQueued).toBeGreaterThan(frameCommitted);
      expect(workerBegin).toBeGreaterThan(promptQueued);
      expect(composerContains(cancelledPane, newerDraft)).toBe(false);

      expect(hold.cancelled).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(existsSync(tapePath)).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "idle submitted prompt keeps its canonical row after a completed turn",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-idle-submit-multiturn-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const framesRoot = join(root, "replay-frames");
      const seedPrompt = "MULTI_TURN_SEED_PROMPT";
      const seedReply = "MULTI_TURN_SEED_REPLY";
      const submittedPrompt = "MULTI_TURN_ROW_SENTINEL";
      const hold: HoldState = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const queuedGateway = startFakeGateway([
        fakeGatewayFinalText(seedReply),
        () => heldGatewayResponse(hold),
      ]);
      gateway = queuedGateway;
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        width: 96,
        height: 28,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-idle-submit-multiturn-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: queuedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: queuedGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText(seedPrompt);
      await session.waitForText(seedReply, TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      await session.sendLiteral(submittedPrompt);
      session.sendKeysImmediate(["Enter"]);
      await waitForCondition(
        () => queuedGateway.requests.length === 2 && hold.started,
        "held multi-turn submitted prompt stream",
      );
      await session.waitForText("Thinking", TIMEOUT);
      await Bun.sleep(250);
      await session.sendKeys("C-c");
      await session.waitForText("What can fx do differently?", TIMEOUT);

      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", framesRoot], {
        encoding: "utf8",
      });
      assertFirstPostEnterOutputShowsSubmittedPrompt(tapePath, submittedPrompt);
      assertSubmittedPromptRowStaysStableAfterEnter(
        tapePath,
        framesRoot,
        submittedPrompt,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "visible assistant prefix precedes immediate steering in scrollback",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-prompt-boundary-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const tracePath = join(root, "trace.log");
      const firstResponse: HoldState = { started: false, cancelled: false };
      const secondResponse = { started: false, cancelled: false };
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const splitGateway = startFakeGateway([
        () =>
          heldGatewayResponse(
            firstResponse,
            [{ type: "text-delta", id: "split_old", delta: `${SPLIT_OLD_RESPONSE}\n` }],
            [
              {
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
                usage: {
                  inputTokens: { total: 3 },
                  outputTokens: { total: 5 },
                },
              },
            ],
          ),
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
      await waitForCondition(
        () => splitGateway.requests.length === 1 && firstResponse.started,
        "held first Gateway stream",
      );
      await session.waitForText("SPLIT_OLD_TAIL_FINAL", TIMEOUT);

      await session.sendText(SPLIT_NEW_USER_PROMPT);
      const cutoffPane = await session.capturePane();
      expect(cutoffPane).not.toContain(
        `┋ ${SPLIT_NEW_USER_PROMPT}`,
      );
      expect(cutoffPane).toMatch(/Thinking|Generating/);
      const tapeFrames = readTapeFrames(tapePath);
      const enterIndex = findEnterAfterSubmittedPrompt(tapeFrames, SPLIT_NEW_USER_PROMPT);
      const firstOutput = tapeFrames.slice(enterIndex + 1).find((frame) => frame.kind === 1)!;
      expect(firstOutput).toBeDefined();
      const framesRoot = join(root, "steering-frames");
      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", framesRoot], { encoding: "utf8" });
      const firstGrid = readFileSync(
        join(framesRoot, "frames", `${String(firstOutput.index).padStart(4, "0")}.grid.txt`),
        "utf8",
      );
      const firstRows = firstGrid.split(/\r?\n/);
      const submittedRow = firstRows.findIndex((row) => row.includes(SPLIT_NEW_USER_PROMPT));
      const activityRow = firstRows.findIndex((row) => /Thinking|Generating/.test(row));
      expect(submittedRow).toBeGreaterThanOrEqual(0);
      expect(firstRows[submittedRow]).toContain("┃");
      expect(submittedRow).toBeLessThan(activityRow);
      await waitForCondition(
        () => firstResponse.cancelled,
        "visible assistant steering cancellation",
      );
      await waitForCondition(
        () => splitGateway.requests.length === 2 && secondResponse.started,
        "immediate steering Gateway stream",
      );
      const handoffScrollback = await waitForEscapedScrollback(
        session,
        (candidate) => {
          const promptIndex = candidate.lastIndexOf(SPLIT_NEW_USER_PROMPT);
          return promptIndex >= 0 && candidate.lastIndexOf("Thinking") > promptIndex;
        },
        "thinking activity after the steering user row",
        3_000,
      );
      expect(handoffScrollback.lastIndexOf("Thinking")).toBeGreaterThan(
        handoffScrollback.lastIndexOf(SPLIT_NEW_USER_PROMPT),
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

      expect(splitGateway.requests[1]!.body).toContain("<user_steering>");
      expect(splitGateway.requests[1]!.body).toContain(SPLIT_NEW_USER_PROMPT);
      const trace = readFileSync(tracePath, "utf8");
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
    "cancelled buffered assistant tail stays before steering and the next answer",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-steering-late-tail-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const firstResponse: HoldState = { started: false, cancelled: false };
      const visiblePrefix = "CANCELLED_RESPONSE_VISIBLE_PREFIX";
      const bufferedTail = "CANCELLED_RESPONSE_BUFFERED_TAIL";
      const steering = "Replace the cancelled response with the short corrected answer.";
      const finalText = "STEERED_RESPONSE_FRESH";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const lateTailGateway = startFakeGateway([
        () =>
          heldGatewayResponse(firstResponse, [{
            type: "text-delta",
            id: "cancelled_response",
            delta: `${visiblePrefix}\n\n${bufferedTail}`,
          }]),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = lateTailGateway;
      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 34,
        minimumHistoryLines: 2_000,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-steering-late-tail-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_GATEWAY_BASE_URL: lateTailGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: lateTailGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: lateTailGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,gateway,stream,worker,input,prompt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Start the cancelled response fixture.");
      await session.waitForText(visiblePrefix, TIMEOUT);
      expect(await session.captureFullScrollback()).not.toContain(bufferedTail);

      await session.sendText(steering);
      await waitForScrollback(
        session,
        (candidate) => candidate.split("\n").some((line) => line.trim() === finalText),
        "fresh steered assistant response",
      );
      await waitForCondition(
        () => lateTailGateway.requests.length === 2,
        "steered response request",
      );

      const scrollback = await session.captureFullScrollback();
      const visibleIndex = scrollback.lastIndexOf(visiblePrefix);
      const tailIndex = scrollback.lastIndexOf(bufferedTail);
      const steeringIndex = scrollback.lastIndexOf(steering);
      const finalIndex = scrollback.lastIndexOf(finalText);
      expect(visibleIndex).toBeGreaterThanOrEqual(0);
      expect(tailIndex).toBeGreaterThan(visibleIndex);
      expect(steeringIndex).toBeGreaterThan(tailIndex);
      expect(finalIndex).toBeGreaterThan(steeringIndex);
      expect(scrollback.slice(steeringIndex)).not.toContain(bufferedTail);

      const lines = scrollback.split("\n").map((line) => line.trimEnd());
      const steeringLine = lines.findIndex((line) => line.includes(steering));
      const finalLine = lines.findIndex((line, index) =>
        index > steeringLine && line.includes(finalText)
      );
      expect(steeringLine).toBeGreaterThanOrEqual(0);
      expect(finalLine).toBeGreaterThan(steeringLine);
      expect(
        lines.slice(steeringLine + 1, finalLine).some((line) => line.trim() === ""),
      ).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "steering waits across streamed tool handoff before authoritative start",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-steering-tool-handoff-")));
      const home = join(root, "home");
      const workspacePath = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      const toolHandoff: HoldState = { started: false, cancelled: false };
      const toolOutput = "TOOL_HANDOFF_EXECUTED";
      const steering = "Respond exactly TOOL_HANDOFF_STEERING_COMPLETE.";
      const finalText = "TOOL_HANDOFF_STEERING_COMPLETE";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspacePath, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspace = realpathSync(workspacePath);

      const handoffGateway = startFakeGateway([
        () => heldGatewayResponse(
          toolHandoff,
          [
            { type: "tool-input-start", id: "handoff_tool", toolName: "shell" },
            { type: "text-start", id: "handoff_text" },
            {
              type: "text-delta",
              id: "handoff_text",
              delta: "Preparing the tool handoff.",
            },
          ],
          [
            { type: "text-end", id: "handoff_text" },
            { type: "tool-input-end", id: "handoff_tool" },
            {
              type: "tool-call",
              toolCallId: "handoff_tool",
              toolName: "shell",
              input: {
                request: {
                  action: "run",
                  yield_time_ms: 30_000,
                  timeout_ms: 30_000,
                  command: `printf ${toolOutput}`,
                },
              },
            },
            {
              type: "finish",
              finishReason: { unified: "tool-calls", raw: "tool-calls" },
              usage: {
                inputTokens: { total: 11 },
                outputTokens: { total: 17 },
              },
            },
          ],
        ),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = handoffGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 34,
        minimumHistoryLines: 500,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-steering-tool-handoff-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: handoffGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: handoffGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: handoffGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,worker,input,tool,interrupt",
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the streamed tool handoff fixture.");
      await waitForCondition(
        () => handoffGateway.requests.length === 1 && toolHandoff.started,
        "held tool handoff response",
      );
      await session.waitForText("Generating", TIMEOUT);

      await session.sendText(steering);
      await Bun.sleep(150);
      const pendingPane = await session.capturePane();
      expect(toolHandoff.cancelled).toBe(false);
      expect(pendingPane).toContain(`┋ ${steering}`);
      expect(pendingPane).not.toContain("Esc to steer now");
      expect(handoffGateway.requests).toHaveLength(1);

      toolHandoff.release?.();
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => handoffGateway.requests.length === 2,
        "steering request after tool handoff",
      );

      const continuedBody = handoffGateway.requests[1]!.body;
      expect(continuedBody.indexOf(toolOutput)).toBeGreaterThanOrEqual(0);
      expect(continuedBody.indexOf(steering)).toBeGreaterThan(
        continuedBody.indexOf(toolOutput),
      );
      expect(continuedBody).toContain("<user_steering>");
      expect(await session.captureFullScrollback()).not.toContain("Cancelled");
      expect(readFileSync(tracePath, "utf8")).toContain(
        "event=prompt_steering_consumed",
      );
      const replay = execFileSync(FX_BIN, ["replay", tapePath, "--frames"], {
        encoding: "utf8",
      });
      expect(replay).toContain(finalText);
      expect(replay).not.toContain("Cancelled");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "ordinary Enter keeps pending steering visible through narrow resize",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-cooperative-steering-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const releasePath = join(workspace, ".release-steering-tool");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const command =
        `while [ ! -f ${JSON.stringify(releasePath)} ]; do sleep 0.05; done; ` +
        "printf COOPERATIVE_TOOL_DONE";
      const firstSteering = "FIRST_BEGIN what is this\nLockfile failed policy check\nHIDDEN_STEERING_TAIL keep the entire message";
      const secondSteering = "SECOND_BEGIN keep the answer concise while preserving its result SECOND_END";
      const thirdSteering = "THIRD_BEGIN mention the completed command before the conclusion THIRD_END";
      const finalText = "COOPERATIVE_STEERING_COMPLETE";
      const steeringGateway = startFakeGateway([
        fakeGatewayToolCall("cooperative_steering_tool", "shell", {
          request: {
            action: "run",
            yield_time_ms: 30_000,
            timeout_ms: 600_000,
            command,
          },
        }),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = steeringGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-cooperative-steering-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: steeringGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,worker,input,tool,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the cooperative steering fixture.");
      await session.waitForText("Running while", TIMEOUT);
      await session.pasteText(firstSteering);
      await session.sendKeys("Enter");
      await session.sendText(secondSteering);
      await session.sendText(thirdSteering);
      await Bun.sleep(150);
      const pendingPane = await session.capturePane();
      expect(pendingPane).toContain("┋ FIRST_BEGIN what is this");
      expect(pendingPane).toContain("┋ Lockfile failed policy check…");
      expect(pendingPane).not.toContain("HIDDEN_STEERING_TAIL");
      expect(pendingPane).not.toContain("\\x0a");
      expect(pendingPane).toContain(`┋ ${secondSteering}`);
      expect(pendingPane).toContain(`┋ ${thirdSteering}`);
      expect(pendingPane.indexOf("FIRST_BEGIN")).toBeLessThan(
        pendingPane.indexOf(secondSteering),
      );
      expect(pendingPane.indexOf(secondSteering)).toBeLessThan(
        pendingPane.indexOf(thirdSteering),
      );
      expect(pendingPane).not.toContain("Esc to steer now");
      const pendingLines = pendingPane.split("\n");
      const pendingComposer = pendingLines.findLastIndex(isComposerLine);
      const pendingSteering = pendingLines.findLastIndex((line) =>
        line.trimStart().startsWith("┋ ")
      );
      expect(pendingComposer - pendingSteering).toBe(2);
      expect(pendingLines[pendingSteering + 1]!.trim()).toBe("");
      expect(pendingPane).not.toContain("Waiting for tool");
      expect(pendingPane).not.toContain("pending message");
      expect(pendingPane).not.toContain("queued 1");
      expect(steeringGateway.requests).toHaveLength(1);

      await session.resizeWindow(60, 16);
      const narrowPane = await session.capturePane();
      for (const marker of [
        "FIRST_BEGIN",
        "Lockfile failed policy check…",
        "SECOND_BEGIN",
        "SECOND_END",
        "THIRD_BEGIN",
        "THIRD_END",
      ]) {
        expect(narrowPane).toContain(marker);
      }
      expect(narrowPane).not.toContain("Esc to steer now");
      const narrowLines = narrowPane.split("\n");
      expect(
        narrowLines.filter((line) => line.trimStart().startsWith("┋ ")),
      ).toHaveLength(6);
      const narrowComposer = narrowLines.findLastIndex(isComposerLine);
      const narrowSteering = narrowLines.findLastIndex((line) =>
        line.trimStart().startsWith("┋ ")
      );
      expect(narrowComposer - narrowSteering).toBe(2);
      expect(narrowLines[narrowSteering + 1]!.trim()).toBe("");
      expect(narrowPane).not.toContain("queued message");
      await session.resizeWindow(120, 40);

      writeFileSync(releasePath, "release\n");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => steeringGateway.requests.length === 2,
        "cooperative steering request",
      );

      const continuedBody = steeringGateway.requests[1]!.body;
      const trace = readFileSync(tracePath, "utf8");
      expect(continuedBody.indexOf("COOPERATIVE_TOOL_DONE")).toBeGreaterThanOrEqual(0);
      expect(continuedBody.indexOf(JSON.stringify(firstSteering).slice(1, -1))).toBeGreaterThan(
        continuedBody.indexOf("COOPERATIVE_TOOL_DONE"),
      );
      expect(continuedBody.indexOf(secondSteering)).toBeGreaterThan(
        continuedBody.indexOf(JSON.stringify(firstSteering).slice(1, -1)),
      );
      expect(continuedBody.indexOf(thirdSteering)).toBeGreaterThan(
        continuedBody.indexOf(secondSteering),
      );
      expect(continuedBody).toContain("live user update");
      expect(trace).toContain("event=prompt_steering_consumed");
      const fullScrollback = await session.captureFullScrollback();
      expect(fullScrollback).toContain("HIDDEN_STEERING_TAIL");
      expect(fullScrollback).not.toContain("\\x0a");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "rich steering waits for the running tool and hands off without queue UI",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-rich-steering-tool-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const releasePath = join(workspace, ".release-rich-steering-tool");
      const imagePath = join(workspace, "steering-image.png");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      copyFileSync(join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"), imagePath);
      const expectedImageData = readFileSync(imagePath).toString("base64");
      const command =
        `while [ ! -f ${JSON.stringify(releasePath)} ]; do sleep 0.05; done; ` +
        "printf RICH_STEERING_TOOL_DONE";
      const steering = "Use the attached image after this command finishes.";
      const finalText = "RICH_STEERING_HANDOFF_COMPLETE";
      const steeringGateway = startFakeGateway([
        fakeGatewayToolCall("rich_steering_tool", "shell", {
          request: {
            action: "run",
            yield_time_ms: 30_000,
            timeout_ms: 600_000,
            command,
          },
        }),
        fakeGatewayFinalText(finalText),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["vision", "file-input", "tool-use"] }],
      });
      gateway = steeringGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-rich-steering-tool-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: steeringGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${steeringGateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,worker,input,tool,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the rich steering tool fixture.");
      await session.waitForText("Running while", TIMEOUT);
      await session.sendText(`/image ${imagePath}`);
      await session.waitForText("attached image: steering-image.png", TIMEOUT);
      await session.sendText(steering);
      const pendingPane = await session.waitForText("┋", TIMEOUT);
      expect(pendingPane).toContain(steering);
      expect(pendingPane).not.toContain("Esc to steer now");
      expect(steeringGateway.requests).toHaveLength(1);

      writeFileSync(releasePath, "release\n");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => steeringGateway.requests.length === 2,
        "rich steering handoff request",
      );

      const continuedBody = steeringGateway.requests[1]!.body;
      const continuedRequest = JSON.parse(continuedBody) as {
        prompt: Array<{ role?: string; content?: unknown }>;
      };
      const continuedUser = continuedRequest.prompt.filter((message) =>
        message.role === "user"
      ).at(-1);
      expect(continuedUser).toBeDefined();
      expect(Array.isArray(continuedUser!.content)).toBe(true);
      const continuedParts = continuedUser!.content as Array<Record<string, unknown>>;
      expect(continuedParts.filter((part) => part.type === "file")).toEqual([{
        type: "file",
        mediaType: "image/png",
        data: expectedImageData,
      }]);
      expect(continuedBody).toContain("RICH_STEERING_TOOL_DONE");
      expect(continuedBody).toContain("<user_steering>");
      expect(continuedBody).toContain(steering);
      expect(continuedBody).not.toContain("<turn_aborted>");
      expect(continuedBody).not.toContain(
        "The previous response ended before completion.",
      );
      expect(continuedBody).not.toContain("Interrupted by user after completing");
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("outcome_kind=steering_handoff");
      const scrollback = await session.captureFullScrollback();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "failed tool result precedes pending steering",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-failed-tool-steering-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const releasePath = join(workspace, ".release-failed-steering-tool");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const command =
        `while [ ! -f ${JSON.stringify(releasePath)} ]; do sleep 0.05; done; ` +
        "printf FAILED_TOOL_STEERING_RESULT; exit 7";
      const steering = "Respond exactly FAILED_TOOL_STEERING_COMPLETE.";
      const steeringGateway = startFakeGateway([
        fakeGatewayToolCall("failed_steering_tool", "shell", {
          request: {
            action: "run",
            yield_time_ms: 30_000,
            timeout_ms: 600_000,
            command,
          },
        }),
        fakeGatewayFinalText("FAILED_TOOL_STEERING_COMPLETE"),
      ]);
      gateway = steeringGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-failed-tool-steering-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: steeringGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,worker,input,tool,interrupt",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the failed steering tool fixture.");
      await session.waitForText("Running while", TIMEOUT);
      await session.sendText(steering);
      await session.waitForText(`┋ ${steering}`, TIMEOUT);
      expect(steeringGateway.requests).toHaveLength(1);

      writeFileSync(releasePath, "release\n");
      await session.waitForText("FAILED_TOOL_STEERING_COMPLETE", TIMEOUT);
      await waitForCondition(
        () => steeringGateway.requests.length === 2,
        "failed tool steering request",
      );

      const continuedBody = steeringGateway.requests[1]!.body;
      expect(continuedBody.indexOf("FAILED_TOOL_STEERING_RESULT")).toBeGreaterThanOrEqual(0);
      expect(continuedBody.indexOf(steering)).toBeGreaterThan(
        continuedBody.indexOf("FAILED_TOOL_STEERING_RESULT"),
      );
      expect(continuedBody).toContain("<user_steering>");
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).toContain("event=prompt_steering_consumed");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "Escape interrupts a running tool and starts pending steering without review",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-immediate-steering-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const steering = "Apply IMMEDIATE_STEERING_SENTINEL now.";
      const finalText = "IMMEDIATE_STEERING_COMPLETE";
      const steeringGateway = startFakeGateway([
        fakeGatewayToolCall("immediate_steering_tool", "shell", {
          request: {
            action: "run",
            yield_time_ms: 30_000,
            timeout_ms: 600_000,
            command: "sleep 30",
          },
        }),
        fakeGatewayFinalText(finalText),
      ]);
      gateway = steeringGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-immediate-steering-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: steeringGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "agent,worker,input,tool,interrupt,history",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Run the immediate steering fixture.");
      await session.waitForText("Running sleep 30", TIMEOUT);
      await session.sendText(steering);
      await session.waitForText(`┋ ${steering}`, TIMEOUT);
      expect(steeringGateway.requests).toHaveLength(1);

      await session.sendKeys("Escape");
      await session.waitForText(finalText, TIMEOUT);
      await waitForCondition(
        () => steeringGateway.requests.length === 2,
        "immediate steering request",
      );

      const continuedBody = steeringGateway.requests[1]!.body;
      const trace = readFileSync(tracePath, "utf8");
      expect(continuedBody).toContain("Run the immediate steering fixture.");
      expect(continuedBody).toContain(steering);
      expect(trace).toContain("steering_pending=true");
      expect(trace).toContain("outcome_kind=interrupted");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "rich steering interrupts tool-free generation without queue UI",
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
      const imagePath = join(nested, "steering-snapshot.png");
      copyFileSync(
        join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
        imagePath,
      );
      const image = realpathSync(imagePath);
      const expectedImageData = readFileSync(image).toString("base64");
      const oldGlobalRule = "STEERING_SNAPSHOT_OLD_GLOBAL_RULE";
      const oldAncestorRule = "STEERING_SNAPSHOT_OLD_ANCESTOR_RULE";
      const oldRootRule = "STEERING_SNAPSHOT_OLD_ROOT_RULE";
      const oldNestedRule = "STEERING_SNAPSHOT_OLD_NESTED_RULE";
      const oldSiblingRule = "STEERING_SNAPSHOT_OLD_SIBLING_MUST_BE_ABSENT";
      const newGlobalRule = "STEERING_SNAPSHOT_NEW_GLOBAL_MUST_BE_ABSENT";
      const newAncestorRule = "STEERING_SNAPSHOT_NEW_ANCESTOR_MUST_BE_ABSENT";
      const newRootRule = "STEERING_SNAPSHOT_NEW_ROOT_MUST_BE_ABSENT";
      const newNestedRule = "STEERING_SNAPSHOT_NEW_NESTED_MUST_BE_ABSENT";
      const newSiblingRule = "STEERING_SNAPSHOT_NEW_SIBLING_MUST_BE_ABSENT";
      writeFileSync(join(home, ".fx", "AGENTS.md"), `${oldGlobalRule}\n`);
      writeFileSync(join(launchAncestor, "AGENTS.md"), `${oldAncestorRule}\n`);
      writeFileSync(join(workspace, "AGENTS.md"), `${oldRootRule}\n`);
      writeFileSync(join(nested, "AGENTS.md"), `${oldNestedRule}\n`);
      writeFileSync(join(sibling, "AGENTS.md"), `${oldSiblingRule}\n`);
      const hold: HoldState = { started: false, cancelled: false };
      const activeBefore = "ACTIVE_ASSISTANT_BEFORE_STEERING_SENTINEL\n";
      const activeAfter = "ACTIVE_ASSISTANT_AFTER_STEERING_MUST_BE_ABSENT\n";
      const steeringPrompt = "RICH_STEERING_CANONICAL_ORDER_SENTINEL";
      const steeringDone = "RICH_STEERING_CANONICAL_ORDER_DONE";
      const steeringGateway = startFakeGateway(
        [
          () => splitHeldTextResponse(hold, activeBefore, activeAfter),
          fakeGatewayFinalText(steeringDone),
        ],
        {
          models: [{
            id: MODEL,
            type: "language",
            tags: ["vision", "file-input", "tool-use"],
          }],
        },
      );
      gateway = steeringGateway;

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 120,
        height: 40,
        minimumHistoryLines: 2_000,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-rich-steering-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: steeringGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: steeringGateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${steeringGateway.baseUrl}/coding-agent/v1/models`,
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
        () => steeringGateway.requests.length === 1 && hold.started,
        "held active Gateway request",
      );
      await session.waitForText("Generating", TIMEOUT);

      await session.sendText(`/image ${image}`);
      await session.waitForText("attached image: steering-snapshot.png", TIMEOUT);
      await session.sendText(steeringPrompt);

      writeFileSync(join(home, ".fx", "AGENTS.md"), `${newGlobalRule}\n`);
      writeFileSync(join(launchAncestor, "AGENTS.md"), `${newAncestorRule}\n`);
      writeFileSync(join(workspace, "AGENTS.md"), `${newRootRule}\n`);
      writeFileSync(join(nested, "AGENTS.md"), `${newNestedRule}\n`);
      writeFileSync(join(sibling, "AGENTS.md"), `${newSiblingRule}\n`);

      await waitForCondition(() => hold.cancelled, "rich steering cancellation");
      await session.waitForText(steeringDone, TIMEOUT);
      await waitForCondition(
        () => steeringGateway.requests.length === 2,
        "rich steering request",
      );

      const steeringBody = steeringGateway.requests[1]!.body;
      const steeringRequest = JSON.parse(steeringBody) as {
        prompt: Array<{ role?: string; content?: unknown }>;
      };
      const steeringUser = steeringRequest.prompt.filter((message) =>
        message.role === "user"
      ).at(-1);
      expect(steeringUser).toBeDefined();
      expect(Array.isArray(steeringUser!.content)).toBe(true);
      const steeringParts = steeringUser!.content as Array<Record<string, unknown>>;
      expect(steeringParts.filter((part) => part.type === "file")).toEqual([{
        type: "file",
        mediaType: "image/png",
        data: expectedImageData,
      }]);
      expect(steeringBody).toContain("<user_steering>");
      expect(steeringBody).not.toContain("<turn_aborted>");
      expect(steeringBody).not.toContain(
        "The previous response ended before completion.",
      );
      expect(countOccurrences(steeringBody, oldGlobalRule)).toBe(1);
      expect(countOccurrences(steeringBody, oldAncestorRule)).toBe(1);
      expect(countOccurrences(steeringBody, oldRootRule)).toBe(1);
      expect(countOccurrences(steeringBody, oldNestedRule)).toBe(1);
      expect(steeringBody.indexOf(oldGlobalRule)).toBeLessThan(
        steeringBody.indexOf(oldAncestorRule),
      );
      expect(steeringBody.indexOf(oldAncestorRule)).toBeLessThan(
        steeringBody.indexOf(oldRootRule),
      );
      expect(steeringBody.indexOf(oldRootRule)).toBeLessThan(
        steeringBody.indexOf(oldNestedRule),
      );
      expect(steeringBody).not.toContain(oldSiblingRule);
      expect(steeringBody).not.toContain(newGlobalRule);
      expect(steeringBody).not.toContain(newAncestorRule);
      expect(steeringBody).not.toContain(newRootRule);
      expect(steeringBody).not.toContain(newNestedRule);
      expect(steeringBody).not.toContain(newSiblingRule);

      const finalScrollback = await session.captureFullScrollbackEscapes();
      const steeringPromptIndex = finalScrollback.indexOf(steeringPrompt);
      const steeringDoneIndex = finalScrollback.indexOf(steeringDone);
      expect(finalScrollback).not.toContain(activeBefore.trim());
      expect(finalScrollback).not.toContain(activeAfter.trim());
      expect(steeringPromptIndex).toBeGreaterThanOrEqual(0);
      expect(steeringDoneIndex).toBeGreaterThan(steeringPromptIndex);
      expect(countOccurrences(finalScrollback, steeringPrompt)).toBe(1);
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
            visible.includes("Generating");
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
          !pane.includes("Generating"),
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
        (pane) => pane.includes(followupResponse) && !pane.includes("Generating"),
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
      const afterFirst = await session.waitForText(
        "What can fx do differently?",
        TIMEOUT,
      );
      await waitForCondition(() => hold.cancelled, "stream cancellation");
      expect(afterFirst).toContain("■ Cancelled");
      expect(afterFirst).not.toContain("System: cancelled");
      expect(afterFirst).not.toContain("Cancelling");
      expect(session.isPaneAlive()).toBe(true);

      const scrollbackAfterFirst = await session.captureFullScrollbackEscapes();
      expect(
        countOccurrences(scrollbackAfterFirst, "What can fx do differently?"),
      ).toBe(1);

      await session.sendKeys("C-c");
      await waitForCondition(
        () => !session!.isPaneAlive(),
        "pane exit after second Ctrl+C",
        3_000,
      );

      const scrollback = await session.captureFullScrollback();
      const trace = readFileSync(tracePath, "utf8");
      expect(scrollback).toContain("What can fx do differently?");
      expect(
        countOccurrences(scrollback, "What can fx do differently?"),
      ).toBe(1);
      expect(scrollback).not.toContain("System: cancelled");
      expect(scrollback).not.toContain("Cancelling");
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
        countOccurrences(normalizedPane, `├ Read ${CANONICAL_READ_PATH}`),
      ).toBe(1);
      expect(
        countOccurrences(
          normalizedPane,
          `└ Searched ${CANONICAL_GREP_PATTERN}`,
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
    "parallel read lifecycle updates preserve current grouped scrollback",
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
        JSON.stringify({}),
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
      expect(scrollback).toContain("├ Read one.txt");
      expect(scrollback).toContain("└ Read two.txt");
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
          statusLine: { context: true },
          yolo_acknowledged: true,
        }),
      );
      writeFileSync(stderrPath, "");

      const tableGateway = startFakeGateway([
        fakeGatewaySerializedToolCall(
          "launch-history-list",
          "glob_files",
          JSON.stringify({ pattern: "*", path: "." }),
          "I'll inspect the docs and determine their authorship.",
        ),
        fakeGatewaySerializedToolCall(
          "launch-history-command",
          "shell",
          JSON.stringify({
            request: {
              action: "run",
              yield_time_ms: 30_000,
              timeout_ms: 600_000,
              command:
                "for i in $(seq -w 1 27); do printf 'docs/source-%s.md\\tWalter (1)\\n' \"$i\"; done",
            },
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
          JSON.stringify({}),
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
        JSON.stringify({}),
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
    "instruction refresh resumes the command without a failed compact summary",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-instruction-refresh-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const nested = join(workspace, "nested");
      const markerPath = join(nested, "executions.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const instruction = "NESTED_INSTRUCTION_REFRESH_SENTINEL";
      const command = "cat AGENTS.md && printf 'executed\\n' >> executions.log";
      const finalText = "INSTRUCTION_REFRESH_FINAL";
      const refreshLabel = "Reading project instructions before continuing:";
      const header = "● 2 tool calls · 2 commands";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(nested, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(join(nested, "AGENTS.md"), `${instruction}\n`);

      let executedBeforeRetry: boolean | undefined;
      let executionAtFinal: string | undefined;
      const refreshGateway = startFakeGateway([
        fakeShellRun("before_instruction_refresh", command, { cwd: nested }),
        () => {
          executedBeforeRetry = existsSync(markerPath);
          return fakeShellRun("after_instruction_refresh", command, { cwd: nested });
        },
        () => {
          executionAtFinal = existsSync(markerPath)
            ? readFileSync(markerPath, "utf8")
            : undefined;
          return fakeGatewayFinalText(finalText);
        },
      ]);
      gateway = refreshGateway;
      session = await TmuxSession.create({
        cwd: workspace,
        width: 120,
        height: 40,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-instruction-refresh-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "auto",
          FX_GATEWAY_BASE_URL: refreshGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: refreshGateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: refreshGateway.chatUrl,
          FX_MODEL: MODEL,
          FX_RECORD: tapePath,
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("Read nested/AGENTS.md and record one execution in nested/executions.log.");
      await session.waitForText(finalText, TIMEOUT);
      await session.waitForText(header, TIMEOUT);
      const compact = await session.captureFullScrollback();
      const escapes = await session.captureFullScrollbackEscapes();

      expect(refreshGateway.requests).toHaveLength(3);
      expect(refreshGateway.requests[0]!.body).not.toContain(instruction);
      expect(refreshGateway.requests[1]!.body).toContain(instruction);
      expect(refreshGateway.requests[1]!.body).toContain(
        "Scoped project instructions were added before execution.",
      );
      expect(executedBeforeRetry).toBe(false);
      expect(executionAtFinal).toBe("executed\n");
      expect(readFileSync(markerPath, "utf8")).toBe("executed\n");
      expect(compact).toContain(`${header}\n`);
      expect(compact).toContain(refreshLabel);
      expect(compact).toContain(`Ran ${command}`);
      expect(hasEmptyComposer(await session.capturePane())).toBe(true);
      for (const output of [compact, escapes]) {
        expect(output).not.toMatch(/command not run|project instructions changed|\bfailed\b/i);
      }
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      const recorded = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload))
        .toString("utf8");
      expect(recorded).toContain(refreshLabel);
      expect(recorded).not.toMatch(/command not run|project instructions changed/i);
      const replay = execFileSync(FX_BIN, ["replay", tapePath], { encoding: "utf8" });
      expect(replay).toContain(finalText);
    },
    TIMEOUT,
  );

  test(
    "current compact view keeps unsupported tool failures visible with supported calls",
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
        JSON.stringify({}),
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
            toolName: "shell",
            input: { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: supportedCommand } },
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
      const full = await session.waitForText(
        `├ Failed ${unsupportedToolName}`,
        TIMEOUT,
      );
      expect(full).toContain(`├ Failed ${unsupportedToolName}`);
      expect(full).toContain(`└ Ran ${supportedCommand}`);
      expect(countOccurrences(full, `Failed ${unsupportedToolName}`)).toBe(1);
      expect(countOccurrences(full, `Ran ${supportedCommand}`)).toBe(1);
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
        `event=execution_start turn_id=1 step_id=1 call_id=${supportedCallId} name=shell`,
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
    "subagent rows show task previews and named replies through resume",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-subagent-rows-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(join(workspace, "fixture.txt"), "ROW_FILE_CONTENT");
      const tasks = ["Check one-off cleanup", "Check provider replay", "Check replay again"];
      const rootPrompt = "SUBAGENT_ROW_FIXTURE";
      const finalText = "SUBAGENT_ROWS_FINISHED";
      let parentStep = 0;
      const releases: Array<() => void> = [];
      const childGates = tasks.map(() => new Promise<void>((resolve) => releases.push(resolve)));
      const rowGateway = startDynamicFakeGateway(async (body) => {
        const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
        const userText = contentText(request.prompt?.findLast((message) => message.role === "user")?.content);
        const child = tasks.findIndex((task) => userText.includes(task));
        if (child >= 0 && !userText.includes(rootPrompt)) {
          await childGates[child];
          return fakeGatewayFinalText(`CHILD_ROW_REPLY_${child}`);
        }
        if (parentStep < tasks.length) {
          const step = parentStep++;
          return fakeGatewayToolCall(`row_child_${step}`, "subagent", {
            request: step === 0
              ? { action: "run", task: tasks[step] }
              : { action: "message", agent: "reviewer", message: tasks[step] },
          });
        }
        if (parentStep === tasks.length) {
          parentStep += 1;
          return fakeGatewayToolCall("row_invalid", "subagent", {
            request: { action: "message", agent: "Invalid Agent", message: "Check failure visibility" },
          });
        }
        if (parentStep++ === tasks.length + 1) {
          return fakeGatewayToolCall("row_read", "read_file", { path: "fixture.txt" });
        }
        return fakeGatewayFinalText(finalText);
      });
      gateway = rowGateway;
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-subagent-row-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "auto",
        FX_GATEWAY_BASE_URL: rowGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: rowGateway.chatUrl,
        FX_E2E_GATEWAY_CHAT_URL: rowGateway.chatUrl,
        FX_MODEL: MODEL,
      };
      session = await TmuxSession.create({ cwd: workspace, env, width: 110, height: 35, stderrPath });
      try {
        await session.waitForComposer(TIMEOUT);
        await session.sendText(rootPrompt);
        for (let index = 0; index < tasks.length; index += 1) {
          await session.waitForText(`${index === 0 ? "Subagent" : "reviewer"} working`, TIMEOUT);
          const active = await session.captureFullScrollback();
          expect(active).toContain(tasks[index]);
          releases[index]();
          await session.waitForText(`${index === 0 ? "Subagent finished" : "reviewer replied"} · ${tasks[index]}`, TIMEOUT);
        }
        await session.waitForText(finalText, TIMEOUT);
        const compact = await session.captureFullScrollback();
        expect(compact).toContain("● 5 tool calls · 4 subagent · 1 read");
        expect(compact).toContain("Invalid Agent failed · Check failure visibility");
        expect(compact).not.toContain("Invalid Agent replied");
        for (let index = 0; index < tasks.length; index += 1) {
          expect(countOccurrences(compact, `${index === 0 ? "Subagent finished" : "reviewer replied"} · ${tasks[index]}`)).toBe(1);
        }
        expect(compact).not.toContain("Managed subagent");
        await session.resizeWindow(45, 30);
        await session.waitForText(finalText, TIMEOUT);
        const narrow = await session.capturePane();
        expect(narrow).toContain("reviewer replied · Check replay again");
        await session.resizeWindow(110, 35);
        await session.sendKeys("C-o");
        await session.waitForText("Full detail", TIMEOUT);
        let details = await session.capturePane();
        for (let page = 0; page < 8 && !details.includes("CHILD_ROW_REPLY_0"); page += 1) {
          await session.sendKeys("PPage");
          details += await session.capturePane();
        }
        expect(details).toContain("CHILD_ROW_REPLY_0");
        expect(details).toContain("Check one-off cleanup");
        await session.sendKeys("C-o");
        const requestCount = rowGateway.requests.length;
        expect(requestCount).toBe(9);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        await session.kill();
        session = await TmuxSession.create({ cmd: `${FX_BIN} --resume-last`, cwd: workspace, env, width: 110, height: 35, stderrPath: join(root, "resumed-stderr.log") });
        await session.waitForText(finalText, TIMEOUT);
        const resumed = await session.captureFullScrollback();
        expect(resumed).toContain("● 5 tool calls · 4 subagent · 1 read");
        expect(resumed).toContain("Invalid Agent failed · Check failure visibility");
        expect(resumed).toContain("Subagent finished · Check one-off cleanup");
        expect(resumed).toContain("reviewer replied · Check replay again");
        expect(rowGateway.requests.length).toBe(requestCount);
        expect(readFileSync(join(root, "resumed-stderr.log"), "utf8")).toBe("");
      } finally {
        for (const release of releases) release();
      }
    },
    TIMEOUT * 3,
  );

  test(
    "current compact command summaries hide no-op cwd prefixes and abbreviate the active workspace path",
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
        JSON.stringify({}),
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
            toolName: "shell",
            input: { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: firstCommand } },
          },
          {
            type: "tool-call",
            toolCallId: "tool_summary_nested",
            toolName: "shell",
            input: { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: nestedCommand } },
          },
          {
            type: "tool-call",
            toolCallId: "tool_summary_third",
            toolName: "shell",
            input: { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: thirdCommand } },
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
      const fullAtTail = await session.waitForText(finalText, TIMEOUT);
      let fullAtNested = fullAtTail;
      for (let page = 0; page < 10 && !fullAtNested.includes(
        "├ Ran cd ./vercel/packages/cli/test/fixtures/unit/commands/git/connect/unlink",
      ); page += 1) {
        await session.sendKeys("PPage");
        fullAtNested = await session.capturePane();
      }
      expect(fullAtNested).toContain(
        "├ Ran cd ./vercel/packages/cli/test/fixtures/unit/commands/git/connect/unlink",
      );
      expect(fullAtTail).toContain(`└ Ran ${thirdCommand}`);
      expect(withoutWorkspaceStatusline(fullAtTail)).not.toContain(workspace);

      for (let page = 0; page < 10; page += 1) {
        await session.sendKeys("PPage");
      }
      const fullAtFirst = await session.waitForText(firstDisplayCommand, TIMEOUT);
      expect(fullAtFirst).toContain(`├ Ran ${firstDisplayCommand}`);
      expect(fullAtFirst).not.toContain(`Ran ${firstCommand}`);
      expect(withoutWorkspaceStatusline(fullAtFirst)).not.toContain(workspace);

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
});
