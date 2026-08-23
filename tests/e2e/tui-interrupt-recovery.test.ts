import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readTrace } from "./tui-render-assertions";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const TRACE_SCOPES = "agent,worker,gateway,history,interrupt,prompt";
const PARTIAL_CHUNKS = [
  "INTERRUPTED_PARTIAL_ONE\n",
  "INTERRUPTED_PARTIAL_TWO\n",
  "INTERRUPTED_PARTIAL_THREE\n",
];
const VISIBLE_PARTIAL_CHUNKS = PARTIAL_CHUNKS.slice(0, 2);
const FOLLOW_UP_RESPONSE = "INTERRUPT_FOLLOW_UP_COMPLETE";
const FOLLOW_UP_MODEL = "google/gemini-3.1-flash-lite";

type GatewayHandle = ReturnType<typeof startFakeGateway>;
type HoldState = {
  started: boolean;
  cancelled: boolean;
  cancelCount: number;
  released: boolean;
  release?: () => void;
};

let session: TmuxSession | null = null;
let gateway: GatewayHandle | null = null;
let root: string | null = null;

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
});

describe.skipIf(SKIP)("tui: interrupt recovery", () => {
  test(
    "submitted status text queues behind an active response",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-text-queues-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const held: HoldState = {
        started: false,
        cancelled: false,
        cancelCount: 0,
        released: false,
      };
      const queuedText = "What are you doing right now?";
      gateway = startFakeGateway([
        () => heldUntilReleasedResponse(held),
        fakeGatewayFinalText("QUEUED_STATUS_PROMPT_COMPLETE"),
      ]);
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-text-queues-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: TRACE_SCOPES,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Hold this response until the test releases it.");
      await waitForCondition(() => held.started, "held response start");
      await session.sendText(queuedText);
      await Bun.sleep(250);

      expect(gateway.requests).toHaveLength(1);
      expect(held.cancelled).toBe(false);
      expect(held.cancelCount).toBe(0);
      expect(readTrace(tracePath)).not.toContain("event=interrupt_persisted");

      held.release!();
      await session.waitForText("QUEUED_STATUS_PROMPT_COMPLETE", TIMEOUT);
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "finish processing queued=0") >= 1,
        "both queued turns to finish",
      );

      expect(held.released).toBe(true);
      expect(held.cancelCount).toBe(0);
      expect(gateway.requests).toHaveLength(2);
      const queuedRequest = JSON.parse(gateway.requests[1]!.body) as {
        prompt: unknown;
        tools: unknown[];
      };
      const queuedPrompt = JSON.stringify(queuedRequest.prompt);
      expect(queuedPrompt).toContain(queuedText);
      expect(queuedRequest.tools.length).toBeGreaterThan(0);
      expect(gateway.requests[1]!.body).not.toContain(
        "Treat it as interrupting any previous tool plan.",
      );
      expect(gateway.requests[1]!.body).not.toContain(
        "Continue from the latest meaningful state",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      const sessionRoot = join(home, ".fx", "sessions");
      const eventsPath = readdirSync(sessionRoot, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => join(sessionRoot, entry.name, "events.jsonl"))
        .find((path) => existsSync(path) && readFileSync(path, "utf8").includes(queuedText));
      expect(eventsPath).toBeDefined();
      const events = readFileSync(eventsPath!, "utf8");
      expect(events).not.toContain('"kind":"interrupted"');
      expect(events).toContain(queuedText);
    },
    TIMEOUT * 2,
  );

  test(
    "double Escape clears an active-turn draft without cancelling",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-active-draft-clear-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const held: HoldState = {
        started: false,
        cancelled: false,
        cancelCount: 0,
        released: false,
      };
      gateway = startFakeGateway([
        () => heldUntilReleasedResponse(held),
      ]);
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-active-draft-clear-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Hold this response while I clear a draft.");
      await waitForCondition(() => held.started, "held response start");
      await session.sendLiteral("discard this draft");
      await session.waitForPane(
        (pane) => composerContains(pane, "discard this draft"),
        TIMEOUT,
      );

      await session.sendKeys("Escape");
      await session.sendKeys("Escape");
      await session.waitForPane(hasEmptyComposer, TIMEOUT);

      expect(held.cancelled).toBe(false);
      expect(held.cancelCount).toBe(0);
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      held.release!();
      await session.waitForStableComposer(TIMEOUT);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test(
    "partial output survives cancellation and the next prompt completes",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-interrupt-recovery-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      const settingsPath = join(home, ".fx", "settings.json");
      writeFileSync(
        settingsPath,
        JSON.stringify({ model: FAKE_GATEWAY_MODEL }) + "\n",
      );

      const held: HoldState = {
        started: false,
        cancelled: false,
        cancelCount: 0,
        released: false,
      };
      gateway = startFakeGateway([
        () => heldPartialResponse(held),
        () => providerPortableResponse(FOLLOW_UP_RESPONSE),
      ], {
        models: [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          { id: FOLLOW_UP_MODEL, type: "language", tags: ["tool-use"] },
        ],
      });
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-interrupt-recovery-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_TRACE_SCOPES: TRACE_SCOPES,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Stream a response that I will interrupt.");
      await waitForCondition(() => held.started, "held response start");
      await session.waitForText(VISIBLE_PARTIAL_CHUNKS.at(-1)!.trim(), TIMEOUT);
      await session.sendKeys("Escape");
      await waitForCondition(() => held.cancelled, "gateway stream cancellation");
      await waitForTrace(tracePath, "event=interrupt_persisted", TIMEOUT);
      await session.waitForText("cancelled", TIMEOUT);
      await session.sendText(`/model ${FOLLOW_UP_MODEL}`);
      await waitForCondition(
        () => JSON.parse(readFileSync(settingsPath, "utf8")).model === FOLLOW_UP_MODEL,
        "follow-up model persistence",
      );
      await session.sendText("Confirm that the next prompt still works.");
      const interruptedScrollback = await session.captureFullScrollback();
      for (const chunk of VISIBLE_PARTIAL_CHUNKS) {
        expect(interruptedScrollback).toContain(chunk.trim());
      }
      expect(countOccurrences(interruptedScrollback, "cancelled")).toBe(1);

      await session.waitForText(FOLLOW_UP_RESPONSE, TIMEOUT);
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "finish processing queued=0") >= 2,
        "both worker turns to finish",
      );

      const finalScrollback = await session.captureFullScrollback();
      for (const chunk of VISIBLE_PARTIAL_CHUNKS) {
        expect(finalScrollback).toContain(chunk.trim());
      }
      expect(finalScrollback).toContain(FOLLOW_UP_RESPONSE);
      expect(countOccurrences(finalScrollback, "cancelled")).toBe(1);
      expect(gateway.requests).toHaveLength(2);
      expect(held.cancelCount).toBe(1);
      expect(countOccurrences(readTrace(tracePath), "event=interrupt_persisted")).toBe(1);
      const followUpRequest = JSON.parse(gateway.requests[1]!.body) as {
        prompt: Array<{ role: string }>;
        tools: unknown[];
      };
      const followUpPrompt = JSON.stringify(followUpRequest.prompt);
      expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
        FAKE_GATEWAY_MODEL,
      );
      expect(gateway.requests[1]!.headers.get("ai-language-model-id")).toBe(
        FOLLOW_UP_MODEL,
      );
      expect(
        followUpRequest.prompt
          .filter((entry) => entry.role !== "system")
          .map((entry) => entry.role),
      ).toEqual([
        "user",
        "assistant",
        "user",
        "user",
      ]);
      expect(followUpPrompt).toContain("<turn_aborted>");
      expect(countOccurrences(followUpPrompt, "<turn_aborted>")).toBe(1);
      expect(followUpPrompt).toContain("Confirm that the next prompt still works.");
      expect(followUpRequest.tools.length).toBeGreaterThan(0);
      expect(gateway.requests[1]!.body).not.toContain(
        "Treat it as interrupting any previous tool plan.",
      );
      expect(gateway.requests[1]!.body).not.toContain(
        "Continue from the latest meaningful state",
      );
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(finalScrollback).not.toContain("HTTP 400");

      const sessionRoot = join(home, ".fx", "sessions");
      const sessionIds = readdirSync(sessionRoot, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name)
        .filter((id) => {
          const path = join(sessionRoot, id, "events.jsonl");
          return existsSync(path) && readFileSync(path, "utf8").includes(
            "Stream a response that I will interrupt.",
          );
        });
      expect(sessionIds).toHaveLength(1);
      const events = readFileSync(
        join(sessionRoot, sessionIds[0]!, "events.jsonl"),
        "utf8",
      );
      expect(countOccurrences(events, '"kind":"interrupted"')).toBe(1);
      for (const chunk of PARTIAL_CHUNKS) {
        expect(events).toContain(chunk.trim());
      }
      expect(events).toContain(FOLLOW_UP_RESPONSE);
    },
    TIMEOUT * 2,
  );

  test(
    "workspace mutation waits for cancelled worker unwind",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-workspace-cancel-unwind-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const observed = join(root, "observed");
      const shared = join(root, "shared");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      mkdirSync(observed, { recursive: true });
      mkdirSync(shared, { recursive: true });
      const workspaceRoot = realpathSync(workspace);
      const observedRoot = realpathSync(observed);
      const sharedRoot = realpathSync(shared);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({
          sandbox: "none",
          permission_mode: "auto",
          permission: {},
          workspaces: {
            [workspaceRoot]: { additional_directories: [observedRoot] },
          },
        }),
      );
      const readyPath = join(workspaceRoot, ".workspace-cancel-ready");
      const scriptPath = join(workspaceRoot, "hold-workspace-cancel.sh");
      writeFileSync(
        scriptPath,
        `#!/bin/sh
trap 'sleep 3; exit 130' TERM
: > .workspace-cancel-ready
while :; do sleep 1; done
`,
      );
      chmodSync(scriptPath, 0o755);

      gateway = startFakeGateway([
        fakeGatewayToolCall("workspace-cancel-hold", "terminal", {
          action: "exec",
          command: "./hold-workspace-cancel.sh",
        }),
      ]);
      session = await TmuxSession.create({
        cwd: workspaceRoot,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-workspace-cancel-unwind-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: `${TRACE_SCOPES},core`,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Run the prepared workspace cancellation command.");
      await waitForCondition(
        () => existsSync(readyPath),
        "workspace cancellation command readiness",
      );

      rmSync(observedRoot, { recursive: true, force: true });
      const generationStartsBeforeList = countOccurrences(
        readTrace(tracePath),
        "file index generation started",
      );
      await session.sendText("/workspace list");
      await session.waitForText("available=true active=true", TIMEOUT);
      expect(countOccurrences(readTrace(tracePath), "file index generation started")).toBe(
        generationStartsBeforeList,
      );

      const command = `/workspace add ${sharedRoot}`;
      await session.sendKeys("Escape");
      await waitForTrace(
        tracePath,
        "event=cancel_requested source=input_active_stream",
        TIMEOUT,
      );
      expect(readTrace(tracePath)).not.toContain("finish processing queued=0");
      await session.sendText(command);

      await session.waitForText(
        "Workspace changes are unavailable until the active and queued work finishes.",
        TIMEOUT,
      );
      const beforeRetry = JSON.parse(
        readFileSync(join(home, ".fx", "settings.json"), "utf8"),
      );
      expect(beforeRetry.workspaces[workspaceRoot].additional_directories).toEqual([
        observedRoot,
      ]);

      await waitForTrace(tracePath, "finish processing queued=0", TIMEOUT);
      await session.waitForText(
        "Cancelled ./hold-workspace-cancel.sh · What can fx do differently?",
        TIMEOUT,
      );
      await session.sendText("/workspace list");
      await session.waitForText("available=false active=false", TIMEOUT);
      expect(countOccurrences(readTrace(tracePath), "file index generation started")).toBe(
        generationStartsBeforeList + 1,
      );
      await session.sendText(command);
      await session.waitForText("runtime_changed=true", TIMEOUT);

      const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
      expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
        observedRoot,
        sharedRoot,
      ]);
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );
});

function heldPartialResponse(state: HoldState): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        for (const delta of PARTIAL_CHUNKS) {
          controller.enqueue(encoder.encode(
            `data: ${JSON.stringify({ type: "text-delta", id: "partial", delta })}\n\n`,
          ));
        }
        timer = setInterval(() => {
          if (!closed) controller.enqueue(encoder.encode(": hold-interrupted-turn\n\n"));
        }, 50);
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        state.cancelCount += 1;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function providerPortableResponse(text: string): Response {
  const request = gateway?.requests.at(-1);
  if (!request) return new Response("missing captured request", { status: 500 });
  const payload = JSON.parse(request.body) as { prompt: Array<{ role: string }> };
  let sawNonSystem = false;
  for (const entry of payload.prompt) {
    if (entry.role === "system") {
      if (sawNonSystem) {
        return new Response("system role must remain in the leading prefix", {
          status: 400,
        });
      }
    } else {
      sawNonSystem = true;
    }
  }
  return fakeGatewayFinalText(text);
}

function heldUntilReleasedResponse(state: HoldState): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        controller.enqueue(encoder.encode(
          'data: {"type":"text-delta","id":"held","delta":"ACTIVE_RESPONSE_HELD\\n"}\n\n',
        ));
        timer = setInterval(() => {
          if (!closed) controller.enqueue(encoder.encode(": held-response\n\n"));
        }, 50);
        state.release = () => {
          if (closed) return;
          closed = true;
          state.released = true;
          if (timer) clearInterval(timer);
          controller.enqueue(encoder.encode(
            'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\n' +
              "data: [DONE]\n\n",
          ));
          controller.close();
        };
      },
      cancel() {
        closed = true;
        state.cancelled = true;
        state.cancelCount += 1;
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

async function waitForTrace(path: string, needle: string, timeoutMs: number): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = readTrace(path);
    if (trace.includes(needle)) return trace;
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for trace marker ${needle}.\nTrace contents:\n${readTrace(path)}`);
}

async function waitForCondition(
  predicate: () => boolean,
  description: string,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < TIMEOUT) {
    if (predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}
