import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText as finalText,
  fakeGatewaySse,
  fakeGatewayToolCall as toolCall,
  type FakeGatewayResponse,
  isVolatileTokenStatusRow,
  startFakeGateway as startGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { findActiveFileApprovalBlock } from "./tui-render-assertions";
import { stdoutFrames } from "./render-lab/tape";

const TIMEOUT = 30_000;
const MAXIMUM_WRITE_TIMEOUT = 120_000;
const APPLY_QUESTION = "Apply this change?";
const REVEAL_QUESTION = "Reveal that this file already matches?";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
  external: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let activeSession: TmuxSession | null = null;

function startFakeGateway(responses: FakeGatewayResponse[]) {
  const gateway = startGateway(responses);
  gateways.push(gateway);
  return gateway;
}

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(): IsolatedRoot {
  const tempRoot = existsSync("/private/tmp") ? "/private/tmp" : tmpdir();
  const root = realpathSync(
    mkdtempSync(join(tempRoot, "fx-file-approval-e2e-")),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const external = join(root, "external");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(external, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      sandbox: "none",
      permission_mode: "ask",
      permission: {},
    }),
  );
  roots.push(root);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
    external: realpathSync(external),
  };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  overrides: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-file-approval-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "ask",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
    ...overrides,
  };
}

async function launch(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  size: { width?: number; height?: number } = {},
  envOverrides: Record<string, string | undefined> = {},
) {
  const stderrPath = join(root.root, "stderr.log");
  writeFileSync(stderrPath, "");
  activeSession = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: root.workspace,
    env: gatewayEnv(root, gateway, envOverrides),
    stderrPath,
    width: size.width ?? 120,
    height: size.height ?? 40,
  });
  await activeSession.waitForComposer(TIMEOUT);
  return { session: activeSession, stderrPath };
}

function fileHash(path: string): string | null {
  if (!existsSync(path)) return null;
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function expectCleanStderr(path: string) {
  expect(readFileSync(path, "utf8")).toBe("");
}

function expectDiffSentinelOnRail(text: string, sentinel: string) {
  const rows = text.split("\n").filter((row) => row.includes(sentinel));
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) expect(row.startsWith("  │")).toBe(true);
}

function fullDisplayClearCount(tapePath: string): number {
  const clear = Buffer.from("\x1b[2J");
  let count = 0;
  for (const frame of stdoutFrames(tapePath)) {
    let offset = 0;
    while (offset < frame.payload.length) {
      const next = frame.payload.indexOf(clear, offset);
      if (next < 0) break;
      count += 1;
      offset = next + clear.length;
    }
  }
  return count;
}

function expectAtomicApprovalExit(tapePath: string, frameStart: number) {
  const frames = stdoutFrames(tapePath).slice(frameStart);
  const leaveFrames = frames.filter((frame) =>
    frame.payload.includes("\x1b[?1049l")
  );
  expect(leaveFrames).toHaveLength(1);
  const payload = leaveFrames[0]!.payload;
  const restoreIndex = payload.indexOf(
    "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25l",
  );
  const syncStart = payload.indexOf("\x1b[?2026h");
  const syncEnd = payload.indexOf("\x1b[?2026l");
  const cursorHide = payload.indexOf("\x1b[?25l");
  const resetClear = payload.indexOf("\x1b[0m\x1b[2J\x1b[3J\x1b[H");
  expect(syncStart).toBeGreaterThanOrEqual(0);
  expect(cursorHide).toBeGreaterThan(syncStart);
  if (resetClear >= 0) {
    expect(resetClear).toBeGreaterThan(cursorHide);
    expect(resetClear).toBeLessThan(restoreIndex);
  }
  expect(restoreIndex).toBeGreaterThan(syncStart);
  expect(syncEnd).toBeGreaterThan(restoreIndex);
  expect(payload.length).toBeGreaterThan(
    Buffer.byteLength("\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25l"),
  );
}

function sessionIdFromHome(root: IsolatedRoot): string {
  const sessionsRoot = join(root.home, ".fx", "sessions");
  const sessionIds = readdirSync(sessionsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== "latest")
    .map((entry) => entry.name);
  expect(sessionIds).toHaveLength(1);
  return sessionIds[0]!;
}

type ApprovalIntent = "apply" | "reveal";

async function waitForFileApproval(
  session: TmuxSession,
  opts: {
    intent?: ApprovalIntent;
    required?: string[];
    timeoutMs?: number;
  } = {},
): Promise<string> {
  const intent = opts.intent ?? "apply";
  const question = intent === "apply" ? APPLY_QUESTION : REVEAL_QUESTION;
  const required = opts.required ?? [];
  await session.waitForPane(
    (pane) =>
      pane.includes(question) &&
      required.every((token) => pane.includes(token)),
    opts.timeoutMs ?? TIMEOUT,
  );
  const block = findActiveFileApprovalBlock(await session.capturePaneGrid());
  expect(block).not.toBeNull();
  expect(block!.text).toContain(question);
  for (const token of required) expect(block!.text).toContain(token);
  return block!.text;
}

function expectApprovalControls(
  block: string,
  opts: {
    intent?: ApprovalIntent;
    scope: string;
    scrollable?: boolean;
  },
) {
  const intent = opts.intent ?? "apply";
  const verb = intent === "apply" ? "Apply" : "Reveal";
  const denial = intent === "apply" ? "Don't apply" : "Don't reveal";
  const choices = [
    `1  ${verb} once`,
    `2  ${verb} + allow ${opts.scope}`,
    `3  ${denial}`,
  ];
  const choiceRows = choices.map((choice) =>
    block.split("\n").findIndex((row) => row.includes(choice))
  );

  if (!choiceRows.every((row) => row >= 0)) {
    throw new Error(
      `Missing canonical file approval choice.\nExpected:\n${
        choices.join("\n")
      }\nBlock:\n${block}`,
    );
  }
  expect(choiceRows[0]).toBeLessThan(choiceRows[1]!);
  expect(choiceRows[1]).toBeLessThan(choiceRows[2]!);
  expect(block.match(/^\s*❯\s+[123]\s+/mg)).toHaveLength(1);
  expect(block).toContain("1–3 Choose");
  expect(block).toContain("Enter Confirm");
  expect(block).toContain("Esc Cancel");
  expect(block).toContain("↑↓ Options");
  if (opts.scrollable) expect(block).toContain("Wheel Scroll");

  expect(block).not.toMatch(/^\s*[123][YAN]\b/m);
  for (const oldCopy of [
    "1. Yes, proceed",
    "2. Yes, and don't ask again",
    "3. No, and tell fx",
    "This action changes files in your workspace.",
  ]) {
    expect(block).not.toContain(oldCopy);
  }
}

function chunkedWriteToolCall(id: string, path: string, content: string) {
  const argumentsJson = JSON.stringify({ path, content });
  const chunkBytes = 32 * 1024;
  const deltas = Array.from(
    { length: Math.ceil(argumentsJson.length / chunkBytes) },
    (_, index) => ({
      type: "tool-input-delta",
      id,
      delta: argumentsJson.slice(index * chunkBytes, (index + 1) * chunkBytes),
    }),
  );
  return fakeGatewaySse([
    {
      type: "tool-input-start",
      id,
      toolName: "write_file",
    },
    ...deltas,
    {
      type: "tool-input-end",
      id,
    },
    {
      type: "tool-call",
      toolCallId: id,
      toolName: "write_file",
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

async function waitForPaneGridChange(
  session: TmuxSession,
  previous: string,
  timeoutMs = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    latest = (await session.capturePaneGrid()).join("\n");
    if (latest !== previous) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for pane grid to change.\n${latest}`);
}

async function sendHexUntilPane(
  session: TmuxSession,
  hexBytes: readonly string[],
  matches: (pane: string) => boolean,
  timeoutMs = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let latest = "";
  while (Date.now() < deadline) {
    await session.sendHexBytes(hexBytes);
    latest = await session.capturePane();
    if (matches(latest)) return latest;
  }
  throw new Error(`Timed out sending terminal input for the expected pane.\n${latest}`);
}

function normalizeVolatileStatusRows(grid: string[]): string[] {
  return grid.map((line) =>
    /^• Streaming \([^)]*\)$/.test(line) ||
      isVolatileTokenStatusRow(line)
      ? "<status>"
      : line
  );
}

test("volatile token status rows normalize before file transcript comparison", () => {
  expect(normalizeVolatileStatusRows(["  (↑10 ↓5)"])).toEqual(["<status>"]);
  expect(normalizeVolatileStatusRows(["  0s (↑10 ↓5)"])).toEqual(["<status>"]);
});

async function decide(session: TmuxSession, choice: 1 | 2 | 3) {
  await session.sendKeys(String(choice));
}

describe.skipIf(!tmuxAvailable())("tui: file permissions", () => {

  test(
    "decomposed prompt and file approval remain visible across resize",
    async () => {
      const root = createIsolatedRoot();
      const marker = "visibility-marker-e\u0301-end";
      const plainMarker = "visibility-marker-e-end";
      const target = join(root.workspace, "combining-visibility.txt");
      const gateway = startFakeGateway([
        toolCall("combining_visibility", "write_file", {
          path: "combining-visibility.txt",
          content: `${marker}\n`,
        }),
        finalText("combining visibility complete"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 120, height: 34 },
      );

      await session.sendText(`Create the combining fixture: ${marker}`);
      let approval = await waitForFileApproval(session, {
        required: [marker],
      });
      expect(approval).toContain(marker);
      expect(approval).not.toContain(plainMarker);
      expect(approval).toContain("┃ Create the combining fixture");
      expect(approval).not.toContain("❯ Create the combining fixture");
      expect(gateway.requests[0]!.body).toContain(marker);
      expect(gateway.requests[0]!.body).not.toContain(plainMarker);

      await session.resizeWindow(70, 16, 500);
      approval = await waitForFileApproval(session, {
        required: [marker],
      });
      expect(approval).toContain(marker);
      expect(approval).not.toContain(plainMarker);
      expect(approval).toContain("┃ Create the combining fixture");
      expect(approval).not.toContain("❯ Create the combining fixture");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });

      await decide(session, 1);
      await session.waitForText("combining visibility complete", TIMEOUT);
      expect(readFileSync(target, "utf8")).toBe(`${marker}\n`);
      expectCleanStderr(stderrPath);
    },
    60_000,
  );

  test(
    "pauses paced assistant text while a file approval is active",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "pacer-gate.txt");
      const marker = "PENDING-FILE-APPROVAL-PACER-SENTINEL";
      const tapePath = join(root.root, "pacer-gate.fxtape");
      const gateway = startFakeGateway([
        fakeGatewaySse([
          {
            type: "text-delta",
            id: "answer_1",
            delta: `x${marker} ${"x".repeat(2_048)}`,
          },
          {
            type: "tool-call",
            toolCallId: "pacer_gate_write",
            toolName: "write_file",
            input: {
              path: "pacer-gate.txt",
              content: "must not be written\n",
            },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        finalText("file approval pacer gate completed"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        {},
        { FX_RECORD: tapePath, FX_SYNC_UPDATES: "1" },
      );

      await session.sendText("Run the file approval pacing fixture.");
      await waitForFileApproval(session, {
        required: ["pacer-gate.txt", "+ must not be written"],
        timeoutMs: 5_000,
      });
      await session.sendKeys("Down");
      await session.sendKeys("Up");

      const stdoutBeforeDecision = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString().replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
      expect(stdoutBeforeDecision.includes(marker)).toBe(false);

      const approvalExitFrameStart = stdoutFrames(tapePath).length;
      await decide(session, 3);
      await session.waitForText("file approval pacer gate completed", 5_000);
      expectAtomicApprovalExit(tapePath, approvalExitFrameStart);

      const stdoutAfterDecision = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString().replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
      expect(stdoutAfterDecision.split(marker)).toHaveLength(2);
      expect(existsSync(target)).toBe(false);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "file approval keeps fragmented mouse scrolling inside the review",
    async () => {
      const root = createIsolatedRoot();
      const tapePath = join(root.root, "full-review.fxtape");
      const tracePath = join(root.root, "full-review.trace.log");
      const injectionLogPath = join(root.root, "full-review.injected-input.log");
      const lines = Array.from(
        { length: 90 },
        (_, index) => `review-line-${String(index + 1).padStart(2, "0")}`,
      );
      const completeWheel = [
        "1b", "5b", "3c", "36", "34", "3b", "37", "39", "3b", "31", "32", "4d",
      ];
      const fragmentedWheel = [
        "1b", "5b", "3c", "36", "35", "3b", "37", "39", "3b", "31", "32", "4d",
      ];
      const fragmentedWheelDelayMs = 40;
      const priorMarker = "prior approval transcript marker";
      const gateway = startFakeGateway([
        finalText(Array.from({ length: 40 }, () => priorMarker).join("\n")),
        toolCall("full_review", "write_file", {
          path: "full-review.txt",
          content: `${lines.join("\n")}\n`,
        }),
        finalText("full review complete"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 80, height: 14 },
        {
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,permission",
        },
      );

      await session.sendText("Record the prior approval transcript marker.");
      await session.waitForText(priorMarker, TIMEOUT);
      await session.sendText("Create the full review fixture.");
      let approval = await waitForFileApproval(session, {
        required: ["full-review.txt", "+ review-line-90"],
      });
      expect(approval).not.toContain("review-line-01");
      const initialRows = approval.split("\n");
      const headerRow = initialRows.findIndex((row) =>
        row.includes("Permission needed · Review change") &&
        row.includes("Write")
      );
      const reviewRow = initialRows.findIndex((row) =>
        row.includes("90 + review-line-90")
      );
      const approvalDividerRow = initialRows.findIndex((row) =>
        row.trim().match(/^┄+$/)
      );
      const bottomDividerRow = initialRows.findIndex((row) =>
        row.trim().match(/^─+$/)
      );
      const questionRow = initialRows.findIndex((row) =>
        row.includes(APPLY_QUESTION)
      );
      expect(headerRow).toBeGreaterThanOrEqual(0);
      expect(reviewRow).toBeGreaterThanOrEqual(0);
      expect(approvalDividerRow).toBeGreaterThan(reviewRow);
      expect(headerRow).toBeGreaterThan(approvalDividerRow);
      expect(questionRow).toBeGreaterThan(headerRow);
      expect(bottomDividerRow).toBeGreaterThan(questionRow);

      await session.sendKeys("Right");
      await session.waitForText(
        "❯ 2  Apply + allow workspace file access for this session",
        TIMEOUT,
      );
      await session.sendKeys("Left");
      await session.waitForText("❯ 1  Apply once", TIMEOUT);

      await session.sendHexBytes(completeWheel);
      const completeSgrApproval = (await session.capturePaneGrid()).join("\n");
      expect(completeSgrApproval).not.toBe(approval);
      expect(completeSgrApproval).not.toContain("Cancelled file");

      await session.sendFragmentedHexBytes(fragmentedWheel, fragmentedWheelDelayMs, injectionLogPath);
      const fragmentedScrollback = await session.captureFullScrollbackEscapes();
      expect(fragmentedScrollback).not.toContain("Cancelled file");
      expect(fragmentedScrollback).not.toContain("4;79;12M");
      expect(readFileSync(injectionLogPath, "utf8")).toBe(
        fragmentedWheel.map((byte, index) =>
          `write=${index + 1}/12 byte=${byte} delay_before_ms=${
            index === 0 ? 0 : fragmentedWheelDelayMs
          }`
        ).join("\n") + "\n",
      );
      await waitForPaneGridChange(session, completeSgrApproval);
      const approvalFrames = Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload));
      expect(approvalFrames.includes(Buffer.from("\x1b[?1000h\x1b[?1006h"))).toBe(true);
      expect(readFileSync(tracePath, "utf8")).not.toContain("discard pending mouse report");

      const clears_before_wheel = fullDisplayClearCount(tapePath);
      expect(clears_before_wheel).toBeGreaterThan(0);
      await sendHexUntilPane(
        session,
        [
          "1b", "5b", "4d", "60", "2a", "25",
        ],
        (pane) => pane.includes("+ review-line-01") && !pane.includes(APPLY_QUESTION),
      );
      approval = (await session.capturePaneGrid()).join("\n");
      expect(approval).not.toContain(APPLY_QUESTION);
      expect(findActiveFileApprovalBlock(approval.split("\n"))).toBeNull();
      expect(fullDisplayClearCount(tapePath)).toBe(clears_before_wheel);

      for (let index = 0; index < 4; index++) {
        await session.sendHexBytes([
          "1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d",
        ]);
      }
      await session.waitForPane(
        (pane) => pane.includes(priorMarker) && !pane.includes(APPLY_QUESTION),
        TIMEOUT,
      );
      approval = (await session.capturePaneGrid()).join("\n");
      expect(approval).not.toContain(APPLY_QUESTION);
      expect(findActiveFileApprovalBlock(approval.split("\n"))).toBeNull();

      await sendHexUntilPane(
        session,
        [
          "1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d",
        ],
        (pane) => pane.includes("+ review-line-90") && pane.includes("3  Don't apply"),
      );
      approval = await waitForFileApproval(session, {
        required: ["+ review-line-90"],
      });
      expect(approval).toContain("❯ 1  Apply once");
      expect(approval).toContain("2  Apply + allow workspace file access for this session");
      expect(approval).toContain("3  Don't apply");

      await decide(session, 1);
      await session.waitForText("full review complete", TIMEOUT);
      expect(gateway.requests).toHaveLength(3);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).not.toContain("Apply this change?");
      expect(scrollback).not.toContain("+ review-line-15");
      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: root.workspace,
        env: { HOME: root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain("full review complete");
      expectCleanStderr(stderrPath);
    },
    90_000,
  );

  test(
    "five-line file approval context shows fallback hunks and returns to approval controls",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "five-line-context.txt");
      const original = Array.from(
        { length: 1000 },
        (_, index) => `line-${String(index + 1).padStart(4, "0")}`,
      ).join("\n");
      writeFileSync(target, `${original}\n`);
      const gateway = startFakeGateway([
        toolCall("five_line_context", "edit_file", {
          path: "five-line-context.txt",
          old_string: "line-0500\n",
          new_string: "line-0500\ninserted-context-a\ninserted-context-b\n",
        }),
        finalText("five-line context complete"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 80, height: 14 },
      );

      await session.sendText("Add the five-line approval context fixture.");
      let approval = await waitForFileApproval(session, {
        required: ["⋯ 495 unchanged lines ⋯", "line-0505"],
      });
      expect(approval).not.toContain("inserted-context-a");

      for (let index = 0; index < 2; index++) {
        await session.sendHexBytes([
          "1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d",
        ]);
      }
      await session.waitForPane(
        (pane) =>
          pane.includes("inserted-context-a") &&
          pane.includes("line-0500") &&
          pane.includes("line-0501"),
        TIMEOUT,
      );

      for (let index = 0; index < 2; index++) {
        await session.sendHexBytes([
          "1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d",
        ]);
      }
      approval = await waitForFileApproval(session, {
        required: ["⋯ 495 unchanged lines ⋯", "line-0505"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
        scrollable: true,
      });

      await decide(session, 1);
      await session.waitForText("five-line context complete", TIMEOUT);
      expect(readFileSync(target, "utf8")).toBe(
        original.replace(
          "line-0500\n",
          "line-0500\ninserted-context-a\ninserted-context-b\n",
        ) + "\n",
      );
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).not.toContain("Apply this change?");
      expect(scrollback).not.toContain("line-0500");
      expect(scrollback).not.toContain("line-0501");
      expect(scrollback).not.toContain("⋯ 495 unchanged lines ⋯");
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "short file approval captures wheel input without moving the selected choice",
    async () => {
      const root = createIsolatedRoot();
      const tapePath = join(root.root, "short-review.fxtape");
      const gateway = startFakeGateway([
        toolCall("short_review", "write_file", {
          path: "short-review.txt",
          content: "short review\n",
        }),
        finalText("short review complete"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 80, height: 30 },
        { FX_RECORD: tapePath, FX_SYNC_UPDATES: "1" },
      );

      await session.sendText("Create the short review fixture.");
      let approval = await waitForFileApproval(session, {
        required: ["short-review.txt", "+ short review"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });
      expect(approval).not.toContain("Wheel Scroll");
      const grid = await session.capturePaneGrid();
      expect(grid[0]).toContain("Run /help for commands");
      const bottomDividerRow = grid.findLastIndex((row) =>
        /^─+$/.test(row.trim()),
      );
      expect(bottomDividerRow).toBeGreaterThanOrEqual(0);
      expect(grid[bottomDividerRow + 1]).toContain("1–3 Choose");
      const rows = approval.split("\n");
      const headerRow = rows.findIndex((row) =>
        row.includes("Permission needed · Review change"),
      );
      const questionRow = rows.findIndex((row) => row.includes(APPLY_QUESTION));
      const choiceOneRow = rows.findIndex((row) => row.includes("1  Apply once"));
      const choiceThreeRow = rows.findIndex((row) => row.includes("3  Don't apply"));
      const hintRow = rows.findIndex((row) => row.includes("1–3 Choose"));
      expect(rows[headerRow + 1]!.trim()).toBe("");
      expect(questionRow).toBe(headerRow + 2);
      expect(rows[questionRow + 1]!.trim()).toBe("");
      expect(choiceOneRow).toBe(questionRow + 2);
      expect(rows[choiceThreeRow + 1]!.trim()).toBe("");
      expect(rows[choiceThreeRow + 2]!.trim()).toMatch(/^─+$/);
      expect(hintRow).toBe(choiceThreeRow + 3);

      const stdout = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      );
      expect(stdout.includes(Buffer.from("\x1b[?1000h\x1b[?1006h"))).toBe(true);

      await session.sendHexBytes([
        "1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d",
      ]);
      approval = await waitForFileApproval(session, {
        required: ["❯ 1  Apply once"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });

      const approvalExitFrameStart = stdoutFrames(tapePath).length;
      await decide(session, 1);
      await session.waitForText("short review complete", TIMEOUT);
      expectAtomicApprovalExit(tapePath, approvalExitFrameStart);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "file approval keeps an amended response through resize and delivers it after the result",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "amended-review.txt");
      const feedback = "summarize the file change after applying it";
      const gateway = startFakeGateway([
        toolCall("amended_review", "write_file", {
          path: "amended-review.txt",
          content: "amended review content\n",
        }),
        finalText("amended review complete"),
      ]);
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 120, height: 40 },
      );

      await session.sendText("Create the amended review fixture.");
      await waitForFileApproval(session, {
        required: ["amended-review.txt", "+ amended review content"],
      });
      await session.sendKeys("Tab");
      await session.waitForText("Apply once, and tell fx what to do next", TIMEOUT);
      await session.sendLiteralText(feedback);
      await session.waitForText(`Apply once, ${feedback}`, TIMEOUT);

      await session.resizeWindow(80, 18, 500);
      const resized = await waitForFileApproval(session, {
        required: ["amended-review.txt", "+ amended review content"],
      });
      expect(resized).toContain(`Apply once, ${feedback}`);

      await session.sendKeys("Enter");
      await session.waitForText("amended review complete", TIMEOUT);
      const finalPane = await session.capturePane();
      expect(finalPane).toContain(feedback);
      const terminalTool = finalPane.indexOf("Wrote amended-review.txt");
      const feedbackCard = finalPane.indexOf(feedback);
      expect(terminalTool).toBeGreaterThanOrEqual(0);
      expect(feedbackCard).toBeGreaterThan(terminalTool);
      expect(readFileSync(target, "utf8")).toBe("amended review content\n");
      expect(gateway.requests).toHaveLength(2);
      const followup = gateway.requests[1]!.body;
      expect(followup.indexOf('"role":"tool"')).toBeGreaterThanOrEqual(0);
      expect(followup.indexOf(feedback)).toBeGreaterThan(
        followup.indexOf('"role":"tool"'),
      );
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd()).toBe(true);
      await session.kill();
      activeSession = null;

      const sessionId = sessionIdFromHome(root);
      const events = readFileSync(
        join(root.home, ".fx", "sessions", sessionId, "events.jsonl"),
        "utf8",
      );
      expect(events).toContain('"permission_feedback"');
      expect(events).toContain(feedback);

      const resumedGateway = startFakeGateway([finalText("amended review resume complete")]);
      const resumed = await runFx(
        [
          "ask",
          "--auto",
          "--resume-id",
          sessionId,
          "Continue the amended review session.",
        ],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, resumedGateway),
        },
      );
      expect(resumed.code).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(resumedGateway.requests).toHaveLength(1);
      const resumedRequest = resumedGateway.requests[0]!.body;
      expect(resumedRequest.indexOf('"role":"tool"')).toBeGreaterThanOrEqual(0);
      expect(resumedRequest.indexOf(feedback)).toBeGreaterThan(
        resumedRequest.indexOf('"role":"tool"'),
      );
      expectCleanStderr(stderrPath);
    },
    60_000,
  );

  test(
    "stale edit approval preserves external bytes and reports rejection",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "stale.txt");
      writeFileSync(target, "one\ntwo\nthree\n");
      const gateway = startFakeGateway([
        toolCall("edit_stale", "edit_file", {
          path: "stale.txt",
          old_string: "two",
          new_string: "TWO",
        }),
        finalText("stale rejection complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Edit the stale fixture.");
      const approval = await waitForFileApproval(session, {
        required: ["- two", "+ TWO"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });
      expect(approval).toContain("Edit ");
      expect(approval).toContain("stale.txt");
      expect(approval).toContain("- two");
      expect(approval).toContain("+ TWO");

      const external = "one\nexternal\nthree\n";
      writeFileSync(target, external);
      const externalHash = fileHash(target);
      await decide(session, 1);
      const settled = await session.waitForText("stale rejection complete", TIMEOUT);

      expect(readFileSync(target, "utf8")).toBe(external);
      expect(fileHash(target)).toBe(externalHash);
      expect(gateway.requests[1]!.body).toContain("file changed after preview");
      expect(gateway.requests[1]!.body).not.toContain("edited stale.txt");
      expect(settled).not.toContain("Edited stale.txt");
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "external missing parents are absent before decision and created only on approval",
    async () => {
      const root = createIsolatedRoot();
      const deniedTarget = join(root.external, "denied", "nested", "file.txt");
      const deniedParent = join(root.external, "denied");
      const deniedGateway = startFakeGateway([
        toolCall("external_deny", "write_file", {
          path: deniedTarget,
          content: "denied\n",
        }),
        toolCall("external_deny_after_context", "write_file", {
          path: deniedTarget,
          content: "denied\n",
        }),
        finalText("external denial complete"),
      ]);
      let launched = await launch(root, deniedGateway, {
        width: 180,
        height: 40,
      });

      await launched.session.sendText("Create the denied external fixture.");
      let approval = await waitForFileApproval(launched.session, {
        required: ["file.txt", "+ denied"],
      });
      expect(deniedGateway.requests).toHaveLength(1);
      expect(deniedGateway.requests[0]!.body).not.toContain("target outside workspace");
      expect(deniedGateway.requests[0]!.body).not.toContain("Not executed");
      expectApprovalControls(approval, {
        scope: `file changes under ${root.external} for this session`,
      });
      expect(approval).toContain("Write ");
      expect(approval).toContain("file.txt");
      expect(approval).toContain("+ denied");
      expect(existsSync(deniedParent)).toBe(false);
      await decide(launched.session, 3);
      await launched.session.waitForText("external denial complete", TIMEOUT);
      expect(existsSync(deniedParent)).toBe(false);
      expectCleanStderr(launched.stderrPath);

      await launched.session.kill();
      activeSession = null;

      const approvedTarget = join(root.external, "approved", "nested", "file.txt");
      const approvedParent = join(root.external, "approved");
      const approvedGateway = startFakeGateway([
        toolCall("external_approve", "write_file", {
          path: approvedTarget,
          content: "approved\n",
        }),
        toolCall("external_approve_after_context", "write_file", {
          path: approvedTarget,
          content: "approved\n",
        }),
        finalText("external approval complete"),
      ]);
      launched = await launch(root, approvedGateway, {
        width: 180,
        height: 40,
      });

      await launched.session.sendText("Create the approved external fixture.");
      approval = await waitForFileApproval(launched.session, {
        required: ["file.txt", "+ approved"],
      });
      expect(approvedGateway.requests).toHaveLength(1);
      expect(approvedGateway.requests[0]!.body).not.toContain("target outside workspace");
      expect(approvedGateway.requests[0]!.body).not.toContain("Not executed");
      expectApprovalControls(approval, {
        scope: `file changes under ${root.external} for this session`,
      });
      expect(approval).toContain("+ approved");
      expect(existsSync(approvedParent)).toBe(false);
      await decide(launched.session, 1);
      await launched.session.waitForText("external approval complete", TIMEOUT);

      expect(readFileSync(approvedTarget, "utf8")).toBe("approved\n");
      expectCleanStderr(launched.stderrPath);
    },
    TIMEOUT * 2,
  );

  test(
    "Esc cancels a file approval turn without writing and leaves the shell usable",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "cancelled.txt");
      const tapePath = join(root.root, "cancelled.fxtape");
      const gateway = startFakeGateway([
        toolCall("cancel_write", "write_file", {
          path: "cancelled.txt",
          content: "must not be written\n",
        }),
        finalText("shell recovered after cancellation"),
      ]);
      const launched = await launch(
        root,
        gateway,
        {},
        { FX_RECORD: tapePath, FX_SYNC_UPDATES: "1" },
      );

      await launched.session.sendText("Create the cancellation fixture.");
      const approval = await waitForFileApproval(launched.session, {
        required: ["cancelled.txt", "+ must not be written"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });

      const approvalExitFrameStart = stdoutFrames(tapePath).length;
      await launched.session.sendKeys("Escape");
      await launched.session.waitForPane(
        (pane) => !pane.includes(APPLY_QUESTION),
        TIMEOUT,
      );
      await new Promise((resolve) => setTimeout(resolve, 300));
      expectAtomicApprovalExit(tapePath, approvalExitFrameStart);

      expect(existsSync(target)).toBe(false);
      expect(gateway.requests).toHaveLength(1);

      await launched.session.sendText("Confirm the shell recovered.");
      await launched.session.waitForText(
        "shell recovered after cancellation",
        TIMEOUT,
      );

      expect(gateway.requests).toHaveLength(2);
      expect(existsSync(target)).toBe(false);
      expectCleanStderr(launched.stderrPath);
    },
    TIMEOUT,
  );

  test(
    "denied and cancelled file tools use current compact outcomes",
    async () => {
      const cases = [
        {
          name: "denied",
          outcome: "1 denied",
          resolve: async (session: TmuxSession) => {
            await decide(session, 3);
          },
          responses: [
            toolCall("marker_denied", "write_file", {
              path: "marker-denied.txt",
              content: "denied\n",
            }),
            finalText("marker denied complete"),
          ],
        },
        {
          name: "cancelled",
          outcome: "■ Cancelled",
          resolve: async (session: TmuxSession) => {
            await session.sendKeys("Escape");
          },
          responses: [
            toolCall("marker_cancelled", "write_file", {
              path: "marker-cancelled.txt",
              content: "cancelled\n",
            }),
          ],
        },
      ];

      for (const testCase of cases) {
        const root = createIsolatedRoot();
        const target = join(root.workspace, `marker-${testCase.name}.txt`);
        const gateway = startFakeGateway(testCase.responses);
        const launched = await launch(
          root,
          gateway,
          { width: 120, height: 40 },
          { FX_THEME: "dark", NO_COLOR: undefined },
        );

        await launched.session.sendText(`Create the ${testCase.name} marker fixture.`);
        await waitForFileApproval(launched.session, {
          required: [target.split("/").at(-1)!],
        });
        await testCase.resolve(launched.session);
        await launched.session.waitForText(testCase.outcome, TIMEOUT);

        const compact = await launched.session.captureFullScrollback();
        expect(compact).toContain(testCase.outcome);
        expect(compact).not.toContain("⊘");
        expect(existsSync(target)).toBe(false);
        expectCleanStderr(launched.stderrPath);

        await launched.session.kill();
        activeSession = null;
      }
    },
    60_000,
  );

  test(
    "read-denied equality uses reveal copy and never changes file bytes",
    async () => {
      const cases: Array<{
        name: string;
        choice: 1 | 2 | 3;
        revealsEquality: boolean;
      }> = [
        { name: "deny", choice: 3, revealsEquality: false },
        { name: "once", choice: 1, revealsEquality: true },
        { name: "always", choice: 2, revealsEquality: true },
      ];

      for (const decision of cases) {
        const root = createIsolatedRoot();
        const target = join(root.external, "private.txt");
        const content = "private-value\n";
        writeFileSync(target, content);
        writeFileSync(
          join(root.home, ".fx", "settings.json"),
          JSON.stringify({
            sandbox: "none",
            permission: {
              read: {
                [`${root.external}/**`]: "deny",
              },
              edit: {
                [`${root.external}/**`]: "allow",
              },
            },
          }),
        );

        const responses = [
          toolCall(`${decision.name}_equality`, "write_file", {
            path: target,
            content,
          }),
          toolCall(`${decision.name}_equality_after_context`, "write_file", {
            path: target,
            content,
          }),
          finalText(`${decision.name} equality complete`),
        ];
        const gateway = startFakeGateway(responses);
        const launched = await launch(root, gateway, {
          width: 180,
          height: 40,
        });
        const before = statSync(target, { bigint: true });
        const beforeHash = fileHash(target);

        await launched.session.sendText(
          `Check the ${decision.name} equality fixture.`,
        );
        const approval = await waitForFileApproval(launched.session, {
          intent: "reveal",
          required: ["Check ", "private.txt", "No content changes"],
        });
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.body).not.toContain("target outside workspace");
        expect(gateway.requests[0]!.body).not.toContain("Not executed");
        expectApprovalControls(approval, {
          intent: "reveal",
          scope: `file changes under ${root.external} for this session`,
        });
        expect(approval).not.toContain("Apply once");
        await decide(launched.session, decision.choice);
        if (decision.revealsEquality) {
          const repeatedApproval = await waitForFileApproval(launched.session, {
            intent: "reveal",
            required: ["private.txt", "No content changes"],
          });
          expectApprovalControls(repeatedApproval, {
            intent: "reveal",
            scope: `file changes under ${root.external} for this session`,
          });
          await decide(launched.session, decision.choice);
        }
        await launched.session.waitForText(
          `${decision.name} equality complete`,
          TIMEOUT,
        );

        const after = statSync(target, { bigint: true });
        expect(readFileSync(target, "utf8")).toBe(content);
        expect(fileHash(target)).toBe(beforeHash);
        expect(after.ino).toBe(before.ino);
        expect(after.mtimeNs).toBe(before.mtimeNs);
        if (decision.revealsEquality) {
          expect(gateway.requests.at(-1)!.body).toContain(
            "already contains the requested content",
          );
        } else {
          expect(gateway.requests.at(-1)!.body).not.toContain(
            "already contains the requested content",
          );
        }

        expectCleanStderr(launched.stderrPath);
        await launched.session.kill();
        activeSession = null;
      }
    },
    90_000,
  );

  test(
    "file approval style roles render under light and dark themes",
    async () => {
      for (const theme of ["dark", "light"] as const) {
        const root = createIsolatedRoot();
        const target = join(root.workspace, `${theme}-theme.txt`);
        const gateway = startFakeGateway([
          toolCall(`${theme}_theme`, "write_file", {
            path: `${theme}-theme.txt`,
            content: `${theme}\n`,
          }),
          finalText(`${theme} theme complete`),
        ]);
        const launched = await launch(
          root,
          gateway,
          { width: 120, height: 40 },
          { FX_THEME: theme, NO_COLOR: undefined },
        );

        await launched.session.sendText(
          `Create the ${theme} theme fixture.`,
        );
        const approval = await waitForFileApproval(launched.session, {
          required: [`${theme}-theme.txt`, `+ ${theme}`],
        });
        expectApprovalControls(approval, {
          scope: "workspace file access for this session",
        });
        const escapes = await launched.session.capturePaneEscapes();
        expect(escapes).toContain(
          theme === "light"
            ? "\x1b[38;5;235m"
            : "\x1b[38;5;255m",
        );
        expect(escapes).toContain("\x1b[1m");
        expect(escapes).toContain(
          theme === "light"
            ? "\x1b[38;5;238m"
            : "\x1b[38;5;252m",
        );

        await decide(launched.session, 3);
        await launched.session.waitForText(
          `${theme} theme complete`,
          TIMEOUT,
        );
        expect(existsSync(target)).toBe(false);
        expectCleanStderr(launched.stderrPath);
        await launched.session.kill();
        activeSession = null;
      }
    },
    60_000,
  );


  test(
    "file session grant reuses the canonical target without a second prompt",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "granted.txt");
      const gateway = startFakeGateway([
        toolCall("grant_first", "write_file", {
          path: "granted.txt",
          content: "first\n",
        }),
        finalText("first grant complete"),
        toolCall("grant_second", "write_file", {
          path: "granted.txt",
          content: "second\n",
        }),
        finalText("second grant complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Create the granted fixture.");
      const approval = await waitForFileApproval(session);
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });
      await decide(session, 2);
      await session.waitForText("first grant complete", TIMEOUT);
      expect(readFileSync(target, "utf8")).toBe("first\n");

      await session.sendText("Update the granted fixture.");
      const settled = await session.waitForText("second grant complete", TIMEOUT);

      expect(readFileSync(target, "utf8")).toBe("second\n");
      expect(gateway.requests).toHaveLength(4);
      expect(gateway.requests[3]!.body).toContain("wrote granted.txt (7 bytes)");
      expect(settled).not.toContain(APPLY_QUESTION);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "keeps each expanded file diff matched to its Ctrl-O detail",
    async () => {
      const root = createIsolatedRoot();
      const firstLines = Array.from(
        { length: 120 },
        (_, index) => `CTRL_O_FIRST_${String(index + 1).padStart(3, "0")}`,
      );
      const secondLines = Array.from(
        { length: 60 },
        (_, index) => `CTRL_O_SECOND_${String(index + 1).padStart(3, "0")}`,
      );
      const gateway = startFakeGateway([
        toolCall("ctrl_o_first", "write_file", {
          path: "first.txt",
          content: `${firstLines.join("\n")}\n`,
        }),
        finalText("CTRL_O_FIRST_DONE"),
        toolCall("ctrl_o_second", "write_file", {
          path: "second.txt",
          content: `${secondLines.join("\n")}\n`,
        }),
        finalText("CTRL_O_SECOND_DONE"),
      ]);
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      activeSession = await TmuxSession.create({
        cmd: `${FX_BIN} --record`,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 180,
        height: 40,
      });
      const session = activeSession;

      await session.waitForText("visual terminal capture:", TIMEOUT);
      const recording = (await session.capturePaneGrid()).join("\n");
      const tapePath = recording.match(
        /visual terminal capture:\s*(\S+\.fxtape)/,
      )?.[1];
      if (!tapePath) {
        throw new Error(`recording path was not printed:\n${recording}`);
      }
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Create the first Ctrl-O file fixture.");
      await waitForFileApproval(session, {
        required: ["CTRL_O_FIRST_120"],
      });
      await decide(session, 1);
      await session.waitForText("CTRL_O_FIRST_DONE", TIMEOUT);

      await session.sendText("Create the second Ctrl-O file fixture.");
      await waitForFileApproval(session, {
        required: ["CTRL_O_SECOND_060"],
      });
      await decide(session, 1);
      await session.waitForText("CTRL_O_SECOND_DONE", TIMEOUT);
      expect(readFileSync(join(root.workspace, "first.txt"), "utf8")).toBe(
        `${firstLines.join("\n")}\n`,
      );
      expect(readFileSync(join(root.workspace, "second.txt"), "utf8")).toBe(
        `${secondLines.join("\n")}\n`,
      );

      const compactGrid = await session.capturePaneGrid();
      const compactScrollback = await session.captureFullScrollback();
      expect(compactScrollback).toContain("Wrote first.txt +120");
      expect(compactScrollback).toContain("Wrote second.txt +60");
      expect(compactScrollback).not.toContain("CTRL_O_FIRST_060");

      await session.sendKeys("C-o");
      await session.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
      await session.sendKeys("Right");
      for (let page = 0; page < 20; page += 1) {
        await session.sendHexBytes(["1b", "5b", "36", "7e"]);
      }
      await session.waitForText("CTRL_O_SECOND_060", TIMEOUT);
      const fullSecond = await session.capturePane();
      expect(fullSecond).toContain("CTRL_O_SECOND_060");
      expect(fullSecond).not.toContain("omitted");
      expect(fullSecond).not.toContain('"content":"CTRL_O_SECOND');

      for (let page = 0; page < 2; page += 1) {
        await session.sendHexBytes(["1b", "5b", "35", "7e"]);
      }
      await session.waitForText("CTRL_O_FIRST_120", TIMEOUT);
      const fullFirst = await session.capturePane();
      expect(fullFirst).toContain("CTRL_O_FIRST_120");
      expect(fullFirst).not.toContain("omitted");
      expect(fullFirst).not.toContain('"content":"CTRL_O_FIRST');

      await session.sendKeys("C-o");
      await session.waitForComposer(TIMEOUT);
      expect(normalizeVolatileStatusRows(
        await session.waitForStableGrid(compactGrid, normalizeVolatileStatusRows, TIMEOUT),
      )).toEqual(
        normalizeVolatileStatusRows(compactGrid),
      );
      expectCleanStderr(stderrPath);

      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: root.workspace,
        env: { HOME: root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain("CTRL_O_FIRST_001");
      expect(replay.stdout).toContain("CTRL_O_SECOND_060");
    },
    90_000,
  );

  test(
    "wraps file diff continuations inside their gutters",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "wrapped.txt");
      const oldLine = `const wrapped_value = "${"A".repeat(180)}OLD_WRAP_TAIL";\n`;
      const newLine = `const wrapped_value = "${"B".repeat(180)}NEW_WRAP_TAIL";\n`;
      writeFileSync(target, oldLine);
      const gateway = startFakeGateway([
        toolCall("wrap_diff", "edit_file", {
          path: "wrapped.txt",
          old_string: oldLine,
          new_string: newLine,
        }),
        finalText("WRAP_DIFF_COMPLETE"),
      ]);
      const tapePath = join(root.root, "diff-wrap.fxtape");
      const { session, stderrPath } = await launch(
        root,
        gateway,
        { width: 72, height: 40 },
        { FX_RECORD: tapePath },
      );

      await session.sendText("Replace the wrapped fixture value.");
      await waitForFileApproval(session, {
        required: ["OLD_WRAP_TAIL", "NEW_WRAP_TAIL"],
      });
      await decide(session, 1);
      await session.waitForText("WRAP_DIFF_COMPLETE", TIMEOUT);
      expect(readFileSync(target, "utf8")).toBe(newLine);

      const inline = await session.captureFullScrollback();
      expect(inline).not.toContain("OLD_WRAP_TAIL");
      expect(inline).not.toContain("NEW_WRAP_TAIL");

      await session.sendKeys("C-o");
      await session.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
      const review = await session.capturePane();
      expectDiffSentinelOnRail(review, "OLD_WRAP_TAIL");
      expectDiffSentinelOnRail(review, "NEW_WRAP_TAIL");

      await session.sendKeys("Right");
      await session.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
      const full = await session.capturePane();
      expectDiffSentinelOnRail(full, "OLD_WRAP_TAIL");
      expectDiffSentinelOnRail(full, "NEW_WRAP_TAIL");

      await session.resizeWindow(56, 40, 500);
      const narrow = await session.capturePane();
      expectDiffSentinelOnRail(narrow, "OLD_WRAP_TAIL");
      expectDiffSentinelOnRail(narrow, "NEW_WRAP_TAIL");

      await session.resizeWindow(100, 40, 500);
      const wide = await session.capturePane();
      expectDiffSentinelOnRail(wide, "OLD_WRAP_TAIL");
      expectDiffSentinelOnRail(wide, "NEW_WRAP_TAIL");

      expect(session.isAlive()).toBe(true);
      expectCleanStderr(stderrPath);
      const replay = await runFx(["replay", tapePath, "--frames"], {
        cwd: root.workspace,
        env: { HOME: root.home },
      });
      expect(replay.code).toBe(0);
      expect(replay.stderr).toBe("");
      expect(replay.stdout).toContain("NEW_WRAP_TAIL");
    },
    90_000,
  );

  test(
    "edit preflight failure shows the exact mismatch",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "preflight.txt");
      writeFileSync(target, "before\n");
      const gateway = startFakeGateway([
        toolCall("edit_preflight_failure", "edit_file", {
          path: "preflight.txt",
          old_string: "missing",
          new_string: "after",
        }),
        finalText("edit failure handled"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Attempt the requested edit once.");
      const settled = await session.waitForText(
        "edit failure handled",
        TIMEOUT,
      );
      const scrollback = await session.captureFullScrollback();

      expect(scrollback).toContain("old_string not found in file");
      expect(scrollback).not.toContain("preflight failed");
      expect(settled).not.toContain(APPLY_QUESTION);
      expect(readFileSync(target, "utf8")).toBe("before\n");
      expect(gateway.requests).toHaveLength(2);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "persistent session reevaluates every write and edit turn",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "demo.txt");
      const turns: Array<{
        prompt: string;
        tool: "write_file" | "edit_file";
        input: Record<string, string>;
        expectedContent: string;
        approval?: { choice: 1 | 3; lines: string[] };
        noop?: true;
      }> = [
        {
          prompt: "Turn 1: create demo.txt.",
          tool: "write_file",
          input: { path: "demo.txt", content: "alpha\nbeta\n" },
          expectedContent: "alpha\nbeta\n",
          approval: { choice: 1, lines: ["+ alpha", "+ beta"] },
        },
        {
          prompt: "Turn 2: write the same content again.",
          tool: "write_file",
          input: { path: "demo.txt", content: "alpha\nbeta\n" },
          expectedContent: "alpha\nbeta\n",
          noop: true,
        },
        {
          prompt: "Turn 3: change beta to gamma with write_file.",
          tool: "write_file",
          input: { path: "demo.txt", content: "alpha\ngamma\n" },
          expectedContent: "alpha\ngamma\n",
          approval: { choice: 1, lines: ["- beta", "+ gamma"] },
        },
        {
          prompt: "Turn 4: change gamma to delta with edit_file.",
          tool: "edit_file",
          input: { path: "demo.txt", old_string: "gamma", new_string: "delta" },
          expectedContent: "alpha\ndelta\n",
          approval: { choice: 1, lines: ["- gamma", "+ delta"] },
        },
        {
          prompt: "Turn 5: deny changing alpha to ALPHA with edit_file.",
          tool: "edit_file",
          input: { path: "demo.txt", old_string: "alpha", new_string: "ALPHA" },
          expectedContent: "alpha\ndelta\n",
          approval: { choice: 3, lines: ["- alpha", "+ ALPHA"] },
        },
      ];
      const responses = turns.flatMap((turn, index) => [
        toolCall(`turn_${index + 1}`, turn.tool, turn.input),
        finalText(`turn ${index + 1} complete`),
      ]);
      const gateway = startFakeGateway(responses);
      const { session, stderrPath } = await launch(root, gateway);

      for (const [index, turn] of turns.entries()) {
        const before = turn.noop ? statSync(target, { bigint: true }) : null;
        await session.sendText(turn.prompt);
        if (turn.approval) {
          const approval = await waitForFileApproval(session, {
            required: turn.approval.lines,
          });
          expectApprovalControls(approval, {
            scope: "workspace file access for this session",
          });
          await decide(session, turn.approval.choice);
        }
        const settled = await session.waitForText(
          `turn ${index + 1} complete`,
          TIMEOUT,
        );
        expect(readFileSync(target, "utf8")).toBe(turn.expectedContent);
        if (before) {
          const after = statSync(target, { bigint: true });
          expect(after.ino).toBe(before.ino);
          expect(after.mtimeNs).toBe(before.mtimeNs);
          expect(gateway.requests[index * 2 + 1]!.body).toContain(
            "already contains the requested content",
          );
          expect(settled).toContain("No changes to demo.txt");
        }
      }

      expect(gateway.requests).toHaveLength(turns.length * 2);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "consolidated tool calls cross the Gateway transport buffer",
    async () => {
      const root = createIsolatedRoot();
      const controlTarget = join(root.workspace, "consolidated-control.txt");
      const largeTarget = join(root.workspace, "consolidated-large.txt");
      const gateway = startFakeGateway([
        toolCall("consolidated_control", "write_file", {
          path: "consolidated-control.txt",
          content: "x".repeat(192 * 1024),
        }),
        finalText("consolidated control complete"),
        toolCall("consolidated_large", "write_file", {
          path: "consolidated-large.txt",
          content: "x".repeat(300 * 1024),
        }),
        finalText("consolidated large complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Create the consolidated control fixture.");
      let pane = await waitForFileApproval(session, {
        required: ["consolidated-control.txt"],
      });
      expectApprovalControls(pane, {
        scope: "workspace file access for this session",
      });
      expect(gateway.requests).toHaveLength(1);
      expect(existsSync(controlTarget)).toBe(false);
      await decide(session, 3);
      await session.waitForText("consolidated control complete", TIMEOUT);

      await session.sendText("Create the consolidated large fixture.");
      pane = await waitForFileApproval(session, {
        required: ["consolidated-large.txt"],
      });
      expectApprovalControls(pane, {
        scope: "workspace file access for this session",
      });
      expect(pane).toContain(APPLY_QUESTION);
      expect(pane).toContain("consolidated-large.txt");
      expect(gateway.requests).toHaveLength(3);
      expect(existsSync(largeTarget)).toBe(false);
      await decide(session, 3);
      await session.waitForText("consolidated large complete", TIMEOUT);

      expect(existsSync(controlTarget)).toBe(false);
      expect(existsSync(largeTarget)).toBe(false);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "maximum-size chunked write stays reviewable and commits exact bytes",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "maximum.txt");
      const content = "x".repeat(4 * 1024 * 1024);
      const expectedHash = createHash("sha256").update(content).digest("hex");
      const gateway = startFakeGateway([
        chunkedWriteToolCall("maximum_write", "maximum.txt", content),
        finalText("maximum write complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Create the maximum-size fixture.");
      const approval = await waitForFileApproval(session, {
        timeoutMs: MAXIMUM_WRITE_TIMEOUT,
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });
      expect(existsSync(target)).toBe(false);

      await decide(session, 1);
      await session.waitForText("maximum write complete", MAXIMUM_WRITE_TIMEOUT);

      expect(statSync(target).size).toBe(content.length);
      expect(fileHash(target)).toBe(expectedHash);
      expectCleanStderr(stderrPath);
    },
    MAXIMUM_WRITE_TIMEOUT + 30_000,
  );

  test(
    "oversized chunked write fails before approval without touching disk",
    async () => {
      const root = createIsolatedRoot();
      const target = join(root.workspace, "oversized.txt");
      const content = "x".repeat(4 * 1024 * 1024 + 1);
      const gateway = startFakeGateway([
        chunkedWriteToolCall("oversized_write", "oversized.txt", content),
        finalText("oversized write complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Create the oversized fixture.");
      const settled = await session.waitForText(
        "oversized write complete",
        60_000,
      );

      expect(settled).not.toContain(APPLY_QUESTION);
      expect(existsSync(target)).toBe(false);
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain(
        "write_file failed: content exceeds the 4 MiB preparation limit",
      );
      expectCleanStderr(stderrPath);
    },
    90_000,
  );

  test(
    "hostile path stays encoded through approval transcript changes and undo",
    async () => {
      const root = createIsolatedRoot();
      const hostileName = "name\x1b]2;FX_PWN\x07\nfile.txt";
      const encodedName = "name\\x1b]2;FX_PWN\\x07\\x0afile.txt";
      const target = join(root.workspace, hostileName);
      const gateway = startFakeGateway([
        toolCall("hostile_write", "write_file", {
          path: hostileName,
          content: "hostile\n",
        }),
        finalText("hostile write complete"),
      ]);
      const { session, stderrPath } = await launch(root, gateway);

      await session.sendText("Create the hostile fixture.");
      const approval = await waitForFileApproval(session, {
        required: [encodedName, "+ hostile"],
      });
      expectApprovalControls(approval, {
        scope: "workspace file access for this session",
      });
      expect(approval).toContain(encodedName);
      expect(approval).toContain("+ hostile");
      expect(existsSync(target)).toBe(false);
      await decide(session, 1);
      let settled = await session.waitForText("hostile write complete", TIMEOUT);

      expect(readFileSync(target, "utf8")).toBe("hostile\n");
      expect(settled).toContain(encodedName);
      expect(settled).not.toContain("\x1b]2;FX_PWN\x07");

      await session.sendText("/undo");
      settled = await session.waitForText("Deleted", TIMEOUT);
      expect(settled).toContain(encodedName);
      expect(settled).not.toContain("\x1b]2;FX_PWN\x07");
      expect(existsSync(target)).toBe(false);
      expectCleanStderr(stderrPath);
    },
    TIMEOUT,
  );
});
