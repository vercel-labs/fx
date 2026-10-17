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
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { findFooterBlocks, readTrace } from "./tui-render-assertions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  heldFakeGatewayFinalText,
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
  for (const inject of [false, true]) test(`quit reports final history persistence failure with fault=${inject}`, async () => {
    root = realpathSync(mkdtempSync(join(tmpdir(), "fx-shutdown-save-")));
    const home = join(root, "home"), workspace = join(root, "workspace");
    mkdirSync(home); mkdirSync(workspace);
    const library = join(root, process.platform === "darwin" ? "sync-fault.dylib" : "sync-fault.so");
    const source = join(import.meta.dirname, "fixtures", "session-sync-fault.c");
    const flags = process.platform === "darwin" ? ["-dynamiclib"] : ["-shared", "-fPIC"];
    const compiled = Bun.spawnSync(["cc", ...flags, "-O2", "-Wall", "-Wextra", source, "-o", library,
      ...(process.platform === "darwin" ? [] : ["-ldl"])]);
    expect(compiled.exitCode).toBe(0);
    const held = heldFakeGatewayFinalText();
    let requestHeld = false;
    gateway = startFakeGateway([
      fakeGatewayFinalText("SHUTDOWN_SAVED_FACT_281"),
      () => { requestHeld = true; return held.response; },
      fakeGatewayFinalText("SHUTDOWN_RESUMED_281"),
    ]);
    const env = { HOME: home, AI_GATEWAY_API_KEY: "fake-shutdown-save", VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0",
      FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models` };
    try {
      const seeded = await runFx(["ask", "--json", "Save the first fact."], { cwd: workspace, env, timeoutMs: TIMEOUT });
      expect(seeded.code).toBe(0); expect(seeded.stderr).toBe("");
      const id = JSON.parse(seeded.stdout).session_id;
      const eventPath = join(home, ".fx", "sessions", id, "events.jsonl");
      const saved = readFileSync(eventPath);
      const stderrPath = join(root, "stderr.log"), tracePath = join(root, "trace.log");
      const arm = join(root, "armed"), receipt = join(root, "injected.txt");
      const quote = (text: string) => `'${text.replaceAll("'", "'\\''")}'`;
      session = await TmuxSession.create({ cmd: `${quote(FX_BIN)} --resume ${quote(id)}`, cwd: workspace,
        isolated: true, remainOnExit: true, width: 110, height: 36, stderrPath,
        env: { ...env, [process.platform === "darwin" ? "DYLD_INSERT_LIBRARIES" : "LD_PRELOAD"]: library,
          FX_TEST_SYNC_TARGET: eventPath, FX_TEST_SYNC_ARM: arm, FX_TEST_SYNC_RECORD: receipt,
          FX_TEST_SYNC_MATCH: "SHUTDOWN_PENDING_REQUEST_392", FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "session,worker,input", FX_RECORD: join(root, "shutdown.fxtape") } });
      await session.waitForStableComposer(TIMEOUT);
      await session.sendText("SHUTDOWN_PENDING_REQUEST_392");
      await waitForCondition(() => requestHeld, "held shutdown request");
      if (inject) writeFileSync(arm, "armed");
      await session.sendText("/quit");
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
      const output = await session.captureFullScrollback();
      const stderr = readFileSync(stderrPath, "utf8");
      expect(existsSync(receipt)).toBe(inject);
      if (inject) {
        expect(readFileSync(receipt, "utf8")).toContain(`target=${eventPath}`);
        expect(readFileSync(tracePath, "utf8")).toContain("shutdown finished prompt persistence failed");
        expect(session.paneStatus().status).toBe(1);
        expect(output + stderr).toMatch(/save.*fail|fail.*sav|could not.*sav|unable to.*sav/i);
      } else { expect(session.paneStatus().status).toBe(0); expect(stderr).toBe(""); }
      expect(readFileSync(eventPath).subarray(0, saved.length).equals(saved)).toBe(true);
      const resumed = await runFx(["ask", "--json", "--resume-id", id, "Continue without repeating work."], {
        cwd: workspace, env, timeoutMs: TIMEOUT });
      expect(resumed.code).toBe(0); expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).session_id).toBe(id);
      expect(gateway.requests.at(-1)!.body).toContain("SHUTDOWN_SAVED_FACT_281");
    } finally { held.dispose(); }
  }, TIMEOUT * 3);

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
      await session.waitForText("full detail", TIMEOUT);
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
    "up arrow retracts a tool-queued steer into the composer for editing",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-steer-retract-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const startPath = join(workspace, "started");
      const releasePath = join(workspace, "release");
      const finishedPath = join(workspace, "finished");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(
        join(workspace, "check.sh"),
        "printf started > started\nwhile [ ! -f release ]; do sleep 0.05; done\nprintf done > finished\n",
      );

      const steerText = "change the header tone";
      const editSuffix = " and keep it short";
      gateway = startFakeGateway([
        fakeShellRun("steer_retract_command", "sh check.sh"),
        fakeGatewayFinalText("STEER_RETRACT_COMPLETE"),
      ]);
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-steer-retract-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_PERMISSION_MODE: "yolo",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: TRACE_SCOPES,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Run the prepared check.");
      await waitForCondition(() => existsSync(startPath), "held tool start");

      await session.sendText(steerText);
      // The queued steer is only visible as the waiting banner above the composer.
      await session.waitForText(steerText, TIMEOUT);

      await session.sendKeys("Up");
      await waitForTrace(tracePath, "event=prompt_steering_retracted", TIMEOUT);

      await session.sendLiteral(editSuffix);
      await session.sendKeys("Enter");
      await waitForCondition(
        () => countOccurrences(readTrace(tracePath), "event=prompt_enqueue") >= 3,
        "edited steer requeued",
      );

      writeFileSync(releasePath, "go");
      await session.waitForText("STEER_RETRACT_COMPLETE", TIMEOUT);
      await waitForCondition(() => existsSync(finishedPath), "held tool completion");

      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("<user_steering>");
      expect(gateway.requests[1]!.body).toContain(`${steerText}${editSuffix}`);
      const trace = readTrace(tracePath);
      expect(countOccurrences(trace, "event=prompt_steering_retracted")).toBe(1);
      expect(countOccurrences(trace, "event=prompt_steering_consumed")).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isPaneAlive()).toBe(true);
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
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await Bun.sleep(150);
      expect(held.cancelled).toBe(false);
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
      expect(interruptedScrollback).not.toContain("system: cancelled");
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
      expect(finalScrollback).not.toContain("system: cancelled");
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
      await session.sendKeys("Escape");
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await Bun.sleep(150);
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      const immediateCancellation = await session.waitForText(
        "What can fx do differently?",
        TIMEOUT,
      );
      expect(Date.now() - cancelStartedAt).toBeLessThan(500);
      expect(immediateCancellation).toContain("■ Cancelled");
      expect(immediateCancellation).not.toContain("system: cancelled");
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
    "double Ctrl-C during a running command exits cleanly and kills the command",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-exit-running-command-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      const workspaceRoot = realpathSync(workspace);
      const pidPath = join(workspaceRoot, "held-command.pid");
      const scriptPath = join(workspaceRoot, "hold-exit.sh");
      // Ignoring TERM keeps a cooperative stop inside its grace window, so
      // exit has to force-kill the command rather than wait it out.
      writeFileSync(
        scriptPath,
        `#!/bin/sh
trap '' TERM
echo $$ > held-command.pid
while :; do sleep 1; done
`,
      );
      chmodSync(scriptPath, 0o755);

      gateway = startFakeGateway([
        fakeShellRun("exit-hold", "./hold-exit.sh", { timeout_ms: 600_000 }),
      ]);
      session = await TmuxSession.create({
        cwd: workspaceRoot,
        stderrPath,
        isolated: true,
        remainOnExit: true,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-exit-running-command-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: "full-access",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_TRACE_SCOPES: `${TRACE_SCOPES},core,shutdown`,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Run the held exit command.");
      await waitForCondition(
        () => existsSync(pidPath) && readFileSync(pidPath, "utf8").trim().length > 0,
        "held command start",
      );
      const commandPid = Number.parseInt(readFileSync(pidPath, "utf8").trim(), 10);

      // One burst, so exit lands while the first press is still cancelling
      // the command and both paths join the same command thread.
      session.sendKeysImmediate(["C-c", "C-c"]);
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);

      expect(session.paneStatus().status).toBe(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readTrace(tracePath)).toContain("stage name=complete");
      await waitForCondition(() => !processExists(commandPid), "held command termination");
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
      // The search must still be running when the second Escape lands, about
      // half a second after it starts. Linux searches 30,000 files in about a
      // third of a second, so it needs a larger corpus than macOS.
      const corpusFiles = process.platform === "darwin" ? 30_000 : 120_000;
      for (let index = 0; index < corpusFiles; index += 1) {
        writeFileSync(
          join(corpus, `candidate-${String(index).padStart(6, "0")}.txt`),
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

      await session.sendKeys("Escape");
      await session.waitForText("esc again to interrupt", TIMEOUT);
      await Bun.sleep(150);
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      await session.waitForText("What can fx do differently?", TIMEOUT);
      expect(Date.now() - cancelStartedAt).toBeLessThan(500);
      await waitForTrace(tracePath, `event=after_tool_execution`, TIMEOUT);
      await waitForTrace(tracePath, "finish processing queued=0", TIMEOUT);

      const trace = readTrace(tracePath);
      const traceLines = trace.split("\n");
      const completedToolIndex = traceLines.findIndex((line) =>
        line.includes("event=after_tool_execution") &&
        line.includes(`call_id=${callId}`) &&
        line.includes("name=grep_files") &&
        line.includes("result_kind=model_output")
      );
      expect(completedToolIndex).toBeGreaterThanOrEqual(0);
      const cancelIndex = traceLines.findIndex((line) => line.includes("event=cancel_requested"));
      expect(cancelIndex).toBeGreaterThanOrEqual(0);
      expect(cancelIndex).toBeLessThan(completedToolIndex);
      await session.waitForText(`Searched ${pattern}`, TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain(`Searched ${pattern}`);
      expect(countOccurrences(scrollback, "What can fx do differently?")).toBe(1);
      expect(scrollback).not.toContain("system: cancelled");
      expect(scrollback).not.toContain("Cancelling");
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "follow-up sent while a cancellation finalizes is never rejected",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-cancel-send-window-")));
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
      gateway = startFakeGateway([
        () => heldPartialResponse(held),
        fakeGatewayFinalText("SEND_AFTER_CANCEL_ACCEPTED"),
      ]);
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-cancel-send-window-key",
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

      await session.sendText("Start the first response.");
      await waitForCondition(() => held.started, "first response start");
      await session.sendKeys("C-c");
      await waitForCondition(() => held.cancelled, "first response cancellation");
      // Race the finalization window on purpose: the follow-up must be
      // accepted even if the interrupted turn has not finished closing.
      await session.sendText("Send this right after the cancel.");
      await session.waitForText("SEND_AFTER_CANCEL_ACCEPTED", TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).not.toContain("InvalidRecoveryCheckpoint");
      expect(scrollback).not.toContain("request failed");
      expect(gateway.requests).toHaveLength(2);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT * 2,
  );

  test(
    "resume after an unclean exit continues the turn once and asks after a second crash (DUR-87)",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-crash-resume-gate-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");

      const prompt = "Work on the report.";
      const held: HoldState = {
        started: false,
        cancelled: false,
        cancelCount: 0,
        released: false,
      };
      gateway = startFakeGateway([() => heldPartialResponse(held)]);
      const baseEnv = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-crash-resume-gate-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_TRACE_SCOPES: TRACE_SCOPES,
      };
      const resumeSession = (handle: GatewayHandle, name: string, remainOnExit = false) =>
        TmuxSession.create({
          cmd: `${FX_BIN} --resume ${sessionId}`,
          cwd: realpathSync(workspace),
          stderrPath: join(root!, `stderr-${name}.log`),
          width: 120,
          height: 40,
          remainOnExit,
          isolated: true,
          env: {
            ...baseEnv,
            FX_GATEWAY_BASE_URL: handle.baseUrl,
            FX_GATEWAY_CHAT_URL: handle.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: handle.chatUrl,
            FX_TRACE_LOG: join(root!, `trace-${name}.log`),
          },
        });
      session = await TmuxSession.create({
        cwd: realpathSync(workspace),
        stderrPath,
        width: 120,
        height: 40,
        remainOnExit: true,
        isolated: true,
        env: {
          ...baseEnv,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TRACE_LOG: tracePath,
        },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText(prompt);
      await waitForCondition(() => held.started, "held response start");
      // Drop the live stream so the turn enters recovery, then kill fx before
      // any cleanup can run: the checkpoint and the owner marker both survive.
      gateway.stop();
      await waitForTrace(tracePath, "recovery_checkpoint_set", TIMEOUT);
      Bun.spawnSync(["kill", "-9", String(session.processPid())]);
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);

      const sessionsRoot = join(home, ".fx", "sessions");
      const sessionId = readdirSync(sessionsRoot, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name)[0]!;
      const sessionDir = join(sessionsRoot, sessionId);
      expect(existsSync(join(sessionDir, "owner.live"))).toBe(true);
      expect(existsSync(join(sessionDir, "recovery.json"))).toBe(true);
      await session.kill();
      session = null;
      gateway = null;

      // First crash: the next fx continues the interrupted turn with no user
      // action, says so, and sends the model the original prompt.
      const continued: HoldState = {
        started: false,
        cancelled: false,
        cancelCount: 0,
        released: false,
      };
      const continueGateway = startFakeGateway([() => heldPartialResponse(continued)]);
      gateway = continueGateway;
      session = await resumeSession(continueGateway, "continue", true);
      await session.waitForComposer(TIMEOUT);
      await waitForCondition(() => continued.started, "the continued turn's request");
      expect(continueGateway.requests).toHaveLength(1);
      // The prompt, then fx's note that the response was interrupted.
      const resent = userTexts(continueGateway.requests[0]!.body);
      expect(resent).toContain(prompt);
      expect(resent.at(-1)).toContain("The previous response was interrupted");
      const continuedScrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
      expect(continuedScrollback).toContain("fx quit unexpectedly before this response finished. Continuing it now.");
      expect(continuedScrollback).not.toContain("again while continuing");
      expect(existsSync(join(sessionDir, "recovery.crashed"))).toBe(true);

      // Second crash, while the turn is being continued: the turn may be what
      // kills fx, so the next resume asks instead of looping.
      Bun.spawnSync(["kill", "-9", String(session.processPid())]);
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
      expect(existsSync(join(sessionDir, "owner.live"))).toBe(true);
      await session.kill();
      session = null;
      continueGateway.stop();

      const retryGateway = startFakeGateway([
        fakeGatewayFinalText("RECOVERY_RETRY_COMPLETE"),
      ]);
      gateway = retryGateway;
      session = await resumeSession(retryGateway, "ask");
      await session.waitForComposer(TIMEOUT);
      await Bun.sleep(1_500);
      expect(retryGateway.requests).toHaveLength(0);
      const askedScrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
      expect(askedScrollback).toContain("fx quit unexpectedly again while continuing this response, so it was not restarted.");
      expect(askedScrollback).not.toContain("Continuing it now");
      expect(askedScrollback).not.toContain("continues automatically");

      // Quitting without choosing keeps the question sticky: the next resume
      // asks again instead of silently re-arming the turn.
      await session.sendText("/quit");
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
      expect(existsSync(join(sessionDir, "owner.live"))).toBe(false);
      expect(existsSync(join(sessionDir, "recovery.asked"))).toBe(true);
      expect(readFileSync(join(root, "stderr-ask.log"), "utf8")).toBe("");
      await session.kill();
      session = null;

      session = await resumeSession(retryGateway, "reask");
      await session.waitForComposer(TIMEOUT);
      await Bun.sleep(1_500);
      expect(retryGateway.requests).toHaveLength(0);
      const reaskedScrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
      expect(reaskedScrollback).toContain("fx quit unexpectedly again while continuing this response");

      // "continue", as the notice says, reaches the model with the
      // interrupted prompt before it (DUR-23), not on its own.
      await session.sendText("continue");
      await session.waitForText("RECOVERY_RETRY_COMPLETE", TIMEOUT);
      expect(retryGateway.requests).toHaveLength(1);
      const sent = userTexts(retryGateway.requests[0]!.body);
      expect(sent.at(-1)).toBe("continue");
      expect(sent).toContain(prompt);
      const answeredScrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
      expect(countOccurrences(answeredScrollback, `┃ ${prompt}`)).toBe(1);

      await session.sendText("/quit");
      await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
      expect(existsSync(join(sessionDir, "owner.live"))).toBe(false);
      expect(existsSync(join(sessionDir, "recovery.asked"))).toBe(false);
      expect(existsSync(join(sessionDir, "recovery.crashed"))).toBe(false);
      expect(existsSync(join(sessionDir, "recovery.json"))).toBe(false);
      expect(readFileSync(join(root, "stderr-reask.log"), "utf8")).toBe("");
      await session.kill();
      session = null;

      // The interrupted prompt is part of the saved conversation now.
      session = await resumeSession(retryGateway, "saved");
      await session.waitForComposer(TIMEOUT);
      const savedScrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
      // Once as a user turn; the resume header also titles the session with it.
      expect(countOccurrences(savedScrollback, `┃ ${prompt}`)).toBe(1);
      expect(savedScrollback).toContain("RECOVERY_RETRY_COMPLETE");
      expect(retryGateway.requests).toHaveLength(1);
    },
    TIMEOUT * 5,
  );

  test(
    "fx -c after a crash during a shell call continues the turn without rerunning the call",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-crash-during-tool-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      const workspaceRoot = realpathSync(workspace);
      const ledgerPath = join(workspaceRoot, "ledger.txt");
      const releasePath = join(workspaceRoot, "release");
      // Records each start, holds until released, then records its end: the
      // ledger shows how often the command ran.
      writeFileSync(
        join(workspaceRoot, "hold.sh"),
        `#!/bin/sh
echo start >> ledger.txt
while [ ! -e release ]; do sleep 0.1; done
echo end >> ledger.txt
`,
      );
      chmodSync(join(workspaceRoot, "hold.sh"), 0o755);
      const prompt = "Run the held command.";
      const baseEnv = {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-crash-during-tool-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "full-access",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_TRACE_SCOPES: TRACE_SCOPES,
      };
      try {
        gateway = startFakeGateway([
          fakeShellRun("crash-hold", "./hold.sh", { timeout_ms: 600_000 }),
        ]);
        session = await TmuxSession.create({
          cwd: workspaceRoot,
          stderrPath: join(root, "stderr.log"),
          width: 120,
          height: 40,
          remainOnExit: true,
          isolated: true,
          env: {
            ...baseEnv,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_TRACE_LOG: join(root, "trace.log"),
          },
        });
        await session.waitForComposer(TIMEOUT);
        await session.sendText(prompt);
        await waitForCondition(
          () => existsSync(ledgerPath) && readFileSync(ledgerPath, "utf8").includes("start"),
          "the shell call to start",
        );
        Bun.spawnSync(["kill", "-9", String(session.processPid())]);
        await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
        await session.kill();
        session = null;
        gateway.stop();

        const resumeGateway = startFakeGateway([fakeGatewayFinalText("TOOL_RECOVERY_COMPLETE")]);
        gateway = resumeGateway;
        session = await TmuxSession.create({
          cmd: `${FX_BIN} -c`,
          cwd: workspaceRoot,
          stderrPath: join(root, "stderr-continue.log"),
          width: 120,
          height: 40,
          isolated: true,
          env: {
            ...baseEnv,
            FX_GATEWAY_BASE_URL: resumeGateway.baseUrl,
            FX_GATEWAY_CHAT_URL: resumeGateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: resumeGateway.chatUrl,
            FX_TRACE_LOG: join(root, "trace-continue.log"),
          },
        });
        await session.waitForText("TOOL_RECOVERY_COMPLETE", TIMEOUT);
        expect(resumeGateway.requests).toHaveLength(1);
        const sent = userTexts(resumeGateway.requests[0]!.body);
        expect(sent).toContain(prompt);
        // The model hears the call may have run, and is told not to repeat it blindly.
        expect(sent.at(-1)).toContain("Reconcile the available tool evidence above before continuing");
        const scrollback = (await session.captureFullScrollback()).replaceAll(/\s+/g, " ");
        expect(scrollback).toContain("fx quit unexpectedly before this response finished. Continuing it now; a tool call may have partly run");
        expect(scrollback).not.toContain("was not restarted");

        await session.sendText("/quit");
        await session.waitForPane(() => session!.paneStatus().dead, TIMEOUT);
        const sessionsRoot = join(home, ".fx", "sessions");
        const sessionDir = join(sessionsRoot, readdirSync(sessionsRoot)[0]!);
        expect(existsSync(join(sessionDir, "recovery.json"))).toBe(false);
        expect(existsSync(join(sessionDir, "recovery.crashed"))).toBe(false);
        expect(readFileSync(join(root, "stderr-continue.log"), "utf8")).toBe("");
        // DUR-43: the cut-off call never ran again on its own.
        expect(readFileSync(ledgerPath, "utf8").split("\n").filter((line) => line === "start")).toHaveLength(1);
      } finally {
        writeFileSync(releasePath, "");
      }
    },
    TIMEOUT * 3,
  );
});

/** The text of every user message in a captured model request body. */
function userTexts(body: string): string[] {
  const payload = JSON.parse(body) as { prompt?: Array<{ role: string; content: unknown }> };
  return (payload.prompt ?? [])
    .filter((message) => message.role === "user")
    .map((message) => typeof message.content === "string"
      ? message.content
      : (Array.isArray(message.content) ? message.content : [])
        .map((part: { type?: string; text?: string }) => part?.type === "text" ? part.text ?? "" : "")
        .join(""));
}

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

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
