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
import { findFooterBlocks, readTrace } from "./tui-render-assertions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
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
    "Ctrl-C clears the composer before cancelling an active response",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-composer-interrupt-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "render.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const held: HoldState = { started: false, cancelled: false, cancelCount: 0, released: false };
      gateway = startFakeGateway([
        () => heldUntilReleasedResponse(held),
        fakeGatewayFinalText("COMPOSER_INTERRUPT_RECOVERED"),
      ]);
      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        isolated: true,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-composer-interrupt-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: `${TRACE_SCOPES},input`,
          FX_TRACE_LOG: tracePath,
          FX_RECORD: tapePath,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold this response.");
      await waitForCondition(() => held.started, "response start");
      await session.sendLiteral("DISCARD_THIS_DRAFT");
      await session.waitForText("DISCARD_THIS_DRAFT", TIMEOUT);

      await session.sendKeys("C-c");
      const cleared = (await session.capturePaneGrid()).join("\n");
      expect(cleared).not.toContain("DISCARD_THIS_DRAFT");
      expect(cleared).not.toContain("What can fx do differently?");
      expect(held.cancelCount).toBe(0);
      expect(readTrace(tracePath)).toContain("draft cleared reason=ctrl_c");
      expect(readTrace(tracePath)).not.toContain("event=cancel_requested");
      expect(session.isPaneAlive()).toBe(true);

      await session.sendKeys("C-c");
      await waitForCondition(() => held.cancelled, "second Control-C cancellation");
      await session.waitForText("What can fx do differently?", TIMEOUT);
      expect(held.cancelCount).toBe(1);
      expect(session.isPaneAlive()).toBe(true);

      await session.sendText("Continue after cancellation.");
      await session.waitForText("COMPOSER_INTERRUPT_RECOVERED", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(countOccurrences(scrollback, "What can fx do differently?")).toBe(1);
      expect(scrollback).not.toContain("DISCARD_THIS_DRAFT");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).not.toContain("DISCARD_THIS_DRAFT");
      expect(gateway.requests[1]!.body).toContain("<turn_aborted>");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const replay = Bun.spawnSync([join(import.meta.dir, "../../zig-out/bin/fx"), "replay", tapePath]);
      expect(replay.exitCode).toBe(0);
      expect(replay.stdout.toString()).toContain("COMPOSER_INTERRUPT_RECOVERED");
    },
    TIMEOUT * 2,
  );

  test(
    "immediate prompt after cancellation keeps thinking visible and remains cancellable",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cancel-next-prompt-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "render.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(join(workspace, "probe.txt"), "CANCEL_FOLLOW_UP_READ\n");

      const held: HoldState = { started: false, cancelled: false, cancelCount: 0, released: false };
      const followUp: HoldState = { started: false, cancelled: false, cancelCount: 0, released: false };
      gateway = startFakeGateway([
        () => heldUntilReleasedResponse(held, ""),
        fakeGatewayToolCall("read-probe", "read_file", { path: "probe.txt" }),
        () => heldUntilReleasedResponse(followUp, ""),
        fakeGatewayFinalText("CANCEL_NEXT_PROMPT_COMPLETE"),
      ]);
      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        width: 103,
        height: 29,
        isolated: true,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-cancel-next-prompt-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: `${TRACE_SCOPES},input`,
          FX_TRACE_LOG: tracePath,
          FX_RECORD: tapePath,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold this response.");
      await waitForCondition(() => held.started, "first request start");
      await session.waitForText("Thinking", TIMEOUT);

      session.sendKeysImmediate(["C-c", "o", "k", "Enter"]);
      await waitForCondition(() => followUp.started, "follow-up request after tool completion");
      await session.waitForText("Thinking", TIMEOUT);
      const activeGrid = await session.capturePaneGrid();
      expect(activeGrid.join("\n")).toContain("Read probe.txt");
      expect(activeGrid.join("\n")).toContain("Thinking");
      expect(gateway.requests[1]!.body).toContain("<turn_aborted>");
      expect(gateway.requests[1]!.body).not.toContain("<user_steering>");
      expect(countOccurrences(readTrace(tracePath), "event=worker_begin")).toBe(2);

      await session.sendKeys("C-o");
      await session.waitForText("Full detail", TIMEOUT);
      await session.sendKeys("C-o");
      await session.waitForText("Thinking", TIMEOUT);
      await session.sendKeys("C-c");
      await waitForCondition(() => followUp.cancelled, "follow-up cancellation");
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "event=interrupt_persisted") === 2,
        "both cancellations persisted",
      );
      await session.sendText("Finish the check.");
      await session.waitForText("CANCEL_NEXT_PROMPT_COMPLETE", TIMEOUT);
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "finish processing queued=") === 3,
        "final prompt completion",
      );
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("Read probe.txt");
      expect(countOccurrences(scrollback, "What can fx do differently?")).toBe(2);
      expect((await session.capturePaneGrid()).join("\n")).not.toContain("Thinking");
      expect(gateway.requests).toHaveLength(4);
      expect(held.cancelCount).toBe(1);
      expect(followUp.cancelCount).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isPaneAlive()).toBe(true);
      const replay = Bun.spawnSync([join(import.meta.dir, "../../zig-out/bin/fx"), "replay", tapePath]);
      expect(replay.exitCode).toBe(0);
      expect(replay.stdout.toString()).toContain("CANCEL_NEXT_PROMPT_COMPLETE");
      expect(replay.stdout.toString()).not.toContain("Thinking");
    },
    TIMEOUT * 2,
  );

  test(
    "submitted text interrupts a tool-free response and continues immediately",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-text-steering-")));
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
      const steeringText = "What are you doing right now?";
      gateway = startFakeGateway([
        () => heldUntilReleasedResponse(held),
        fakeGatewayFinalText("STEERING_STATUS_PROMPT_COMPLETE"),
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
      await session.sendText(steeringText);
      await waitForCondition(() => held.cancelled, "tool-free steering cancellation");
      await session.waitForText("STEERING_STATUS_PROMPT_COMPLETE", TIMEOUT);
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "finish processing queued=0") >= 1,
        "steering continuation to finish",
      );

      expect(held.released).toBe(false);
      expect(held.cancelCount).toBe(1);
      expect(gateway.requests).toHaveLength(2);
      const steeringRequest = JSON.parse(gateway.requests[1]!.body) as {
        prompt: unknown;
        tools: unknown[];
      };
      const steeringPrompt = JSON.stringify(steeringRequest.prompt);
      expect(steeringPrompt).toContain(steeringText);
      expect(steeringRequest.tools.length).toBeGreaterThan(0);
      expect(gateway.requests[1]!.body).not.toContain(
        "Treat it as interrupting any previous tool plan.",
      );
      expect(gateway.requests[1]!.body).not.toContain(
        "Continue from the latest meaningful state",
      );
      expect(gateway.requests[1]!.body).toContain("<user_steering>");
      expect(gateway.requests[1]!.body).toContain(
        "Apply this live user update to the current task.",
      );
      expect(gateway.requests[1]!.body).toContain("ACTIVE_RESPONSE_HELD");
      expect(gateway.requests[1]!.body).not.toContain("<turn_aborted>");
      expect(gateway.requests[1]!.body).not.toContain(
        "The previous response ended before completion.",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
      expect(session.isPaneAlive()).toBe(true);

      const sessionRoot = join(home, ".fx", "sessions");
      let eventsPath: string | undefined;
      await waitForCondition(() => {
        eventsPath = readdirSync(sessionRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory())
          .map((entry) => join(sessionRoot, entry.name, "events.jsonl"))
          .find((path) => existsSync(path) && readFileSync(path, "utf8").includes(steeringText));
        return eventsPath !== undefined;
      }, "steering history persistence");
      const events = readFileSync(eventsPath!, "utf8");
      expect(events).not.toContain('"kind":"interrupted"');
      expect(events).toContain(steeringText);
      const scrollback = await session.captureFullScrollback();
      expect(countOccurrences(scrollback, steeringText)).toBe(1);
      expect(countOccurrences(scrollback, "ACTIVE_RESPONSE_HELD")).toBe(1);
      expect(scrollback).not.toContain("cancelled");
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
      await session.waitForText("What can fx do differently?", TIMEOUT);
      const cancelledGrid = await session.capturePaneGrid();
      const footer = findFooterBlocks(cancelledGrid).at(-1);
      const cancelledRow = cancelledGrid.findIndex((row) => row.includes("■ Cancelled"));
      expect(footer).toBeDefined();
      expect(cancelledRow).toBeGreaterThanOrEqual(0);
      expect(cancelledRow).toBeLessThan(footer!.topDivider);
      const gapRows = cancelledGrid.slice(cancelledRow + 1, footer!.topDivider);
      expect(gapRows.length).toBeGreaterThanOrEqual(1);
      expect(gapRows.map((row) => row.trim())).toEqual(
        Array.from({ length: gapRows.length }, () => ""),
      );
      await session.sendText(`/model ${FOLLOW_UP_MODEL}`);
      await waitForCondition(
        () => JSON.parse(readFileSync(settingsPath, "utf8")).models?.gateway === FOLLOW_UP_MODEL,
        "follow-up model persistence",
      );
      await session.sendText("Confirm that the next prompt still works.");
      const interruptedScrollback = await session.captureFullScrollback();
      for (const chunk of VISIBLE_PARTIAL_CHUNKS) {
        expect(interruptedScrollback).toContain(chunk.trim());
      }
      expect(
        countOccurrences(interruptedScrollback, "What can fx do differently?"),
      ).toBe(1);
      expect(interruptedScrollback).not.toContain("System: cancelled");
      expect(interruptedScrollback).not.toContain("Cancelling");

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
      expect(
        countOccurrences(finalScrollback, "What can fx do differently?"),
      ).toBe(1);
      expect(finalScrollback).not.toContain("System: cancelled");
      expect(finalScrollback).not.toContain("Cancelling");
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
      const interruptedEvents = events
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line) as { event: Record<string, unknown> })
        .filter((record) => record.event.interrupted !== undefined);
      expect(interruptedEvents).toHaveLength(1);
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
        fakeShellRun("workspace-cancel-hold", "./hold-workspace-cancel.sh", {
          timeout_ms: 600_000,
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
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      const immediateCancellation = await session.waitForText(
        "What can fx do differently?",
        TIMEOUT,
      );
      expect(Date.now() - cancelStartedAt).toBeLessThan(500);
      expect(immediateCancellation).toContain("■ Cancelled");
      expect(immediateCancellation).not.toContain("System: cancelled");
      expect(immediateCancellation).not.toContain("Cancelling");
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

  test(
    "late successful tool settlement stays truthful after Escape",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-late-tool-success-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const corpus = join(workspace, "corpus");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const pattern = "LATE_SUCCESS_NEEDLE";
      const callId = "late_success_grep";
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(corpus, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      for (let index = 0; index < 30_000; index += 1) {
        writeFileSync(
          join(corpus, `candidate-${String(index).padStart(5, "0")}.txt`),
          "ordinary corpus text\n",
        );
      }

      gateway = startFakeGateway([
        fakeGatewayToolCall(callId, "grep_files", {
          path: "corpus",
          pattern,
          head_limit: 5,
        }),
      ]);
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-late-tool-success-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: `${TRACE_SCOPES},tool,ui_activity`,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Search the prepared corpus.");
      await session.waitForText(`Searching ${pattern}`, TIMEOUT);
      expect(readTrace(tracePath)).not.toContain(
        `event=after_tool_execution call_id=${callId}`,
      );

      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      await session.waitForText("What can fx do differently?", TIMEOUT);
      expect(Date.now() - cancelStartedAt).toBeLessThan(500);
      await waitForTrace(tracePath, `event=after_tool_execution`, TIMEOUT);
      await waitForTrace(tracePath, "finish processing queued=0", TIMEOUT);

      const trace = readTrace(tracePath);
      const completedTool = trace.split("\n").find((line) =>
        line.includes("event=after_tool_execution") &&
        line.includes(`call_id=${callId}`) &&
        line.includes("name=grep_files") &&
        line.includes("result_kind=model_output")
      );
      expect(completedTool).toBeDefined();
      await session.waitForText(`Searched ${pattern}`, TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain(`Searched ${pattern}`);
      expect(countOccurrences(scrollback, "What can fx do differently?")).toBe(1);
      expect(scrollback).not.toContain("System: cancelled");
      expect(scrollback).not.toContain("Cancelling");
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
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

function heldUntilReleasedResponse(state: HoldState, text = "ACTIVE_RESPONSE_HELD\n"): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        if (text) controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({ type: "text-delta", id: "held", delta: text })}\n\n`,
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
