import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
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
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  fakeGatewayToolCall,
  hasEmptyComposer,
  isVolatileTokenStatusRow,
  paneExitMatches,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { readTapeFrames, stdoutFrames } from "./render-lab/tape";

const TIMEOUT = 30_000;

async function pasteVisibleText(
  session: TmuxSession,
  text: string,
  visibleText = text,
): Promise<void> {
  await session.pasteText(text);
  await session.waitForText(visibleText, TIMEOUT);
}

async function readLiveStdoutFrames(
  path: string,
  timeoutMs = TIMEOUT,
): Promise<ReturnType<typeof stdoutFrames>> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      return stdoutFrames(path);
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !error.message.startsWith("truncated tape frame")
      ) throw error;
      lastError = error;
    }
    await Bun.sleep(25);
  }
  throw lastError;
}

async function waitForLiveStdoutFrames(
  path: string,
  afterFrame: number,
  label: string,
  predicate: (frames: ReturnType<typeof stdoutFrames>) => boolean,
  timeoutMs = TIMEOUT,
): Promise<ReturnType<typeof stdoutFrames>> {
  const deadline = Date.now() + timeoutMs;
  let frames: ReturnType<typeof stdoutFrames> = [];
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      frames = stdoutFrames(path).slice(afterFrame);
      lastError = undefined;
      if (predicate(frames)) return frames;
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !error.message.startsWith("truncated tape frame")
      ) throw error;
      lastError = error;
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `[${label}] timed out waiting for recorded frames after ${afterFrame}; ` +
      `read ${frames.length} frame(s). Last tape error: ${String(lastError)}`,
  );
}

function normalizeVolatileTokenRows(grid: string[]): string[] {
  return grid.map((line) =>
    isVolatileTokenStatusRow(line)
      ? "<status>"
      : line
  );
}

function persistedCommunicationText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!value || typeof value !== "object") {
    throw new Error("persisted communication text is not encoded text");
  }
  const wire = value as { encoding?: unknown; data?: unknown };
  if (wire.encoding !== "base64" || typeof wire.data !== "string") {
    throw new Error("persisted communication text has an unknown encoding");
  }
  return Buffer.from(wire.data, "base64").toString("utf8");
}

test("volatile token rows normalize before restored subagent comparison", () => {
  expect(normalizeVolatileTokenRows(["  (↑7 ↓5)"])).toEqual(["<status>"]);
  expect(normalizeVolatileTokenRows(["  0s (↑7 ↓5)"])).toEqual(["<status>"]);
});

function controlledTextResponse(initialText: string) {
  const encoder = new TextEncoder();
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  let released = false;
  const response = new Response(
    new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        value.enqueue(
          encoder.encode(
            `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: initialText })}\n\n`,
          ),
        );
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
  return {
    response,
    push(text: string) {
      if (released || !controller) throw new Error("controlled response already released");
      controller.enqueue(
        encoder.encode(
          `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n`,
        ),
      );
    },
    release(finalText: string) {
      if (released || !controller) throw new Error("controlled response already released");
      released = true;
      controller.enqueue(
        encoder.encode(
          `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: finalText })}\n\n` +
            `data: ${JSON.stringify({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: {
                inputTokens: { total: 3 },
                outputTokens: { total: 5 },
              },
            })}\n\ndata: [DONE]\n\n`,
        ),
      );
      controller.close();
    },
    released: () => released,
  };
}

function providerErrorResponse(detail: string): Response {
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

function normalizeThinkingFrame(grid: string[]) {
  return grid.map((line) =>
    line.includes("Thinking (") ? "<animated thinking frame>" : line
  );
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function latestPrompt(body: string): string {
  const request = JSON.parse(body) as { prompt?: unknown[] };
  return JSON.stringify(request.prompt?.at(-1) ?? "");
}

function textHex(text: string): string[] {
  return [...new TextEncoder().encode(text)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  );
}

let session: TmuxSession | null = null;
let root: string | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
});

function createFixture() {
  root = realpathSync(mkdtempSync(join(tmpdir(), "fx-subagent-manager-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
  );
  writeFileSync(stderrPath, "");
  return { home, workspace: realpathSync(workspace), stderrPath };
}

type TestGateway = { baseUrl: string; chatUrl: string };
type SeededChat = { exit_code: number; session_id: string };
type RelationshipControl = {
  configuration: { name: string };
  operations: Array<{
    code: string;
    identity_source?: string;
    target_id: string;
  }>;
};

type ConfigurationControl = {
  child_id: string;
  parent_id: string;
  generation: number;
  configuration: {
    name: string;
    effort: string;
    permission_mode: string;
    notifications: {
      terminal: {
        completed: boolean;
        failed: boolean;
        cancelled: boolean;
      };
      milestones: string[];
      report_interval_ms: number | null;
      report_duration_ms: number | null;
      stop_conditions: string[];
    };
  };
  operations: Array<{
    id: string;
    code: string;
    identity_source?: string;
    generation: number;
  }>;
};

function configurationControlPath(
  fixture: ReturnType<typeof createFixture>,
): string {
  const sessionsDir = join(fixture.home, ".fx", "sessions");
  const path = readdirSync(sessionsDir)
    .map((id) => join(sessionsDir, id, "subagent", "control.json"))
    .find((candidate) => existsSync(candidate));
  if (!path) throw new Error("child control record was not found");
  return path;
}

function readConfigurationControl(path: string): ConfigurationControl {
  return JSON.parse(readFileSync(path, "utf8")) as ConfigurationControl;
}

async function waitForConfigurationControl(
  path: string,
  predicate: (control: ConfigurationControl) => boolean,
): Promise<ConfigurationControl> {
  const startedAt = Date.now();
  let control = readConfigurationControl(path);
  while (Date.now() - startedAt < TIMEOUT) {
    control = readConfigurationControl(path);
    if (predicate(control)) return control;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for control state: ${JSON.stringify(control)}`);
}

async function waitForFullScrollback(
  active: TmuxSession,
  predicate: (scrollback: string) => boolean,
): Promise<string> {
  const startedAt = Date.now();
  let scrollback = "";
  while (Date.now() - startedAt < TIMEOUT) {
    scrollback = await active.captureFullScrollback();
    if (predicate(scrollback)) return scrollback;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for restored scrollback\n${scrollback}`);
}

function relationshipTestEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: TestGateway,
  key: string,
) {
  return Object.fromEntries(Object.entries({
    ...process.env,
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: key,
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    NO_COLOR: "1",
  }).filter((entry): entry is [string, string] => entry[1] !== undefined));
}

async function seedSavedChat(
  fixture: ReturnType<typeof createFixture>,
  gateway: TestGateway,
  key: string,
  title: string,
): Promise<SeededChat> {
  const child = Bun.spawn([FX_BIN, "ask", "--json", "--auto", title], {
    cwd: fixture.workspace,
    env: relationshipTestEnv(fixture, gateway, key),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(exitCode).toBe(0);
  expect(stderr).toBe("");
  const result = JSON.parse(stdout) as SeededChat;
  expect(result.exit_code).toBe(0);
  return result;
}

function readRelationshipControl(
  fixture: ReturnType<typeof createFixture>,
  sessionId: string,
): RelationshipControl | null {
  const path = join(
    fixture.home,
    ".fx",
    "sessions",
    sessionId,
    "subagent",
    "control.json",
  );
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8")) as RelationshipControl;
}

async function launch(
  fixture: ReturnType<typeof createFixture>,
  remainOnExit = false,
  tracePath?: string,
) {
  session = await TmuxSession.create({
    cwd: fixture.workspace,
    env: {
      HOME: fixture.home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: tracePath ? "subagent" : undefined,
      NO_COLOR: "1",
    },
    width: 80,
    height: 20,
    stderrPath: fixture.stderrPath,
    remainOnExit,
  });
  await session.waitForComposer(TIMEOUT);
  return session;
}

describe.skipIf(!tmuxAvailable())("tui: Agents & processes", () => {
  test(
    "empty manager preserves the exact main screen, composer, cursor, resize, and repeated cycles",
    async () => {
      const fixture = createFixture();
      const pasteTracePath = join(fixture.home, "manager-paste.trace");
      const active = await launch(fixture, false, pasteTracePath);
      await active.sendLiteralText("MANAGER_COMPOSER_SENTINEL");
      await active.waitForText("MANAGER_COMPOSER_SENTINEL", TIMEOUT);

      const gridBefore = await active.capturePaneGrid();
      const cursorBefore = active.cursorPosition();
      await active.sendKeys("C-x");
      let manager = await active.waitForText("Agents & processes", TIMEOUT);
      expect(manager).toContain("Agents 0");
      expect(manager).toContain("No active agents");
      expect(manager).toContain("Background processes 0");
      expect(manager).toContain("No background processes");
      expect(manager).toContain(
        "↑↓ select   enter inspect   c new agent   t attach   r archives   ctrl-x close",
      );
      expect(manager).not.toContain("Command center");
      expect(manager).not.toContain("Esc stays here");
      expect(manager).not.toContain("MANAGER_COMPOSER_SENTINEL");

      await active.pasteText("ROOT_PASTE_LEAK");
      manager = await active.waitForText("Agents & processes", TIMEOUT);
      expect(manager).not.toContain("ROOT_PASTE_LEAK");
      const pasteDeadline = Date.now() + TIMEOUT;
      let pasteTrace = "";
      while (Date.now() < pasteDeadline) {
        pasteTrace = existsSync(pasteTracePath)
          ? readFileSync(pasteTracePath, "utf8")
          : "";
        if (pasteTrace.includes(
          "manager paste dropped bytes=15 reason=route_without_composer",
        )) break;
        await Bun.sleep(25);
      }
      expect(pasteTrace).toContain(
        "manager paste dropped bytes=15 reason=route_without_composer",
      );
      await active.sendKeys("C-x");
      await active.waitForPane(
        (pane) =>
          !pane.includes("Agents & processes") &&
          pane.includes("MANAGER_COMPOSER_SENTINEL"),
        TIMEOUT,
      );
      expect(await active.capturePaneGrid()).toEqual(gridBefore);
      expect(active.cursorPosition()).toEqual(cursorBefore);
      await active.sendKeys("C-x");
      await active.waitForText("Agents & processes", TIMEOUT);

      await active.sendKeys("Escape");
      await Bun.sleep(300);
      manager = await active.waitForText("Agents & processes", TIMEOUT);
      expect(manager).toContain("r archives");

      await active.sendKeys("C-x");
      await active.waitForPane(
        (pane) =>
          !pane.includes("Agents & processes") &&
          pane.includes("MANAGER_COMPOSER_SENTINEL"),
        TIMEOUT,
      );
      expect(await active.capturePaneGrid()).toEqual(gridBefore);
      expect(active.cursorPosition()).toEqual(cursorBefore);

      await active.sendKeys("Escape");
      await active.sendKeys("C-x");
      await active.waitForText("Agents & processes", TIMEOUT);
      await active.sendKeys("C-x");
      await active.waitForText("MANAGER_COMPOSER_SENTINEL", TIMEOUT);
      expect(await active.capturePaneGrid()).toEqual(gridBefore);
      expect(active.cursorPosition()).toEqual(cursorBefore);

      for (let cycle = 0; cycle < 3; cycle++) {
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("MANAGER_COMPOSER_SENTINEL", TIMEOUT);
      }
      expect(await active.capturePaneGrid()).toEqual(gridBefore);
      expect(active.cursorPosition()).toEqual(cursorBefore);

      await active.sendKeys("C-x");
      await active.waitForText("Agents & processes", TIMEOUT);
      await active.resizeWindow(52, 10);
      const narrow = await active.waitForText("Agents & processes", TIMEOUT);
      expect(narrow).toContain("ctrl-x close");
      expect(active.paneSize()).toEqual({ cols: 52, rows: 10 });
      await active.resizeWindow(80, 20);
      await active.waitForText("Agents & processes", TIMEOUT);
      await active.sendKeys("C-x");
      await active.waitForText("MANAGER_COMPOSER_SENTINEL", TIMEOUT);
      expect(active.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    60_000,
  );

  test(
    "Ctrl-X isolates an idle child from active parent streaming and restores the current parent immediately",
    async () => {
      const fixture = createFixture();
      const tapePath = join(fixture.home, "isolated-child-surface.fxtape");
      const childPrompt = "ISOLATED_CHILD_PROMPT";
      const childToolPath = "isolated-child.txt";
      writeFileSync(join(fixture.workspace, childToolPath), "isolated child fixture\n");
      const parentStream = controlledTextResponse("PARENT_BACKGROUND_0\n");
      let releaseParent!: (response: Response) => void;
      let parentReleased = false;
      const parentCompletion = new Promise<Response>((resolve) => {
        releaseParent = (response) => {
          parentReleased = true;
          resolve(response);
        };
      });
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"isolated_parent_read"')) {
          return parentStream.response;
        }
        if (body.includes('"toolCallId":"isolated_child_create"')) {
          return parentCompletion;
        }
        if (body.includes('"toolCallId":"isolated_child_read"')) {
          return fakeGatewayFinalText("ISOLATED_CHILD_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall("isolated_child_read", "read_file", {
            path: childToolPath,
          });
        }
        return fakeGatewayToolCall("isolated_child_create", "subagent", {
          command: {
            create: {
              name: "isolated-child",
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "isolated-surface-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            FX_RECORD_INPUT: "1",
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the isolated child fixture.");

        await active.sendKeys("C-x");
        const manager = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("isolated-child") &&
            pane.includes("idle"),
          TIMEOUT,
        );
        expect(manager).not.toContain("PARENT_BACKGROUND_0");
        await active.sendKeys("Enter");
        const child = await active.waitForPane(
          (pane) =>
            pane.includes("ISOLATED_CHILD_COMPLETE") &&
            pane.includes(`Read ${childToolPath}`),
          TIMEOUT,
        );
        expect(child).not.toContain("PARENT_BACKGROUND_0");
        const childId = child.match(/isolated-child\s+·\s+([^\s]+)/)?.[1];
        if (!childId) throw new Error("isolated child did not expose its immutable ID");
        const control = JSON.parse(readFileSync(
          join(fixture.home, ".fx", "sessions", childId, "subagent", "control.json"),
          "utf8",
        )) as { configuration: { permission_mode: string } };
        expect(control.configuration.permission_mode).toBe("auto");
        const settledChildGrid = await active.capturePaneGrid();

        const parentStreamingFrameStart = stdoutFrames(tapePath).length;
        releaseParent(fakeGatewayToolCall("isolated_parent_read", "read_file", {
          path: childToolPath,
        }));
        const parentToolStartedAt = Date.now();
        while (
          !gateway.requests.some((request) =>
            request.body.includes('"toolCallId":"isolated_parent_read"')
          ) &&
          Date.now() - parentToolStartedAt < TIMEOUT
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) =>
          request.body.includes('"toolCallId":"isolated_parent_read"')
        )).toBe(true);
        for (let index = 1; index <= 20; index++) {
          parentStream.push(`PARENT_BACKGROUND_${index}\n`);
          await Bun.sleep(15);
        }
        await Bun.sleep(500);
        const parentStreamingFrames = stdoutFrames(tapePath).slice(
          parentStreamingFrameStart,
        );
        expect(
          parentStreamingFrames.filter((frame) => frame.payload.length >= 1_024),
        ).toHaveLength(0);
        expect(
          parentStreamingFrames.reduce(
            (total, frame) => total + frame.payload.length,
            0,
          ),
        ).toBeLessThan(8_192);
        expect(await active.capturePaneGrid()).toEqual(settledChildGrid);
        expect(await active.capturePane()).not.toContain("PARENT_BACKGROUND_20");

        parentStream.release("PARENT_BACKGROUND_DONE");
        await Bun.sleep(250);
        expect(await active.capturePaneGrid()).toEqual(settledChildGrid);

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        const handoffFrameStart = readTapeFrames(tapePath).at(-1)?.index ?? 0;
        await active.sendKeys("C-x");
        const restored = await active.waitForText("PARENT_BACKGROUND_DONE", TIMEOUT);
        expect(restored).not.toContain("Agents & processes");
        expect(restored).not.toContain("ISOLATED_CHILD_COMPLETE");
        let handoffFrames = readTapeFrames(tapePath);
        let inputIndex = -1;
        let leaveIndex = -1;
        const handoffStartedAt = Date.now();
        while (Date.now() - handoffStartedAt < TIMEOUT) {
          try {
            handoffFrames = readTapeFrames(tapePath);
          } catch {
            await Bun.sleep(25);
            continue;
          }
          inputIndex = handoffFrames.findIndex((frame) =>
            frame.index > handoffFrameStart &&
            frame.kind === 2 &&
            frame.payload.includes(0x18)
          );
          leaveIndex = handoffFrames.findIndex((frame, index) =>
            index > inputIndex &&
            frame.kind === 1 &&
            frame.payload.includes("\x1b[?1049l")
          );
          if (inputIndex >= 0 && leaveIndex > inputIndex) break;
          await Bun.sleep(25);
        }
        expect(inputIndex).toBeGreaterThanOrEqual(0);
        expect(leaveIndex).toBeGreaterThan(inputIndex);
        const handoffDelayMs = handoffFrames
          .slice(inputIndex + 1, leaveIndex + 1)
          .reduce((total, frame) => total + frame.deltaMs, 0);
        expect(handoffDelayMs).toBeLessThanOrEqual(16);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        if (!parentReleased) releaseParent(fakeGatewayFinalText("CLEANUP"));
        if (!parentStream.released()) parentStream.release("CLEANUP");
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "selected child renders terminal-safe identity across restart",
    async () => {
      const fixture = createFixture();
      const resumedStderrPath = join(root!, "terminal-safe-child-resumed.stderr");
      const rawName = "lf\ncr\rred\x1b[31mchild\x1b[0m-c1-\u{0080}-δοκιμή";
      const visibleName =
        "lf\\x0acr\\x0dred\\x1b[31mchild\\x1b[0m-c1-\\u{0080}-δοκιμή";
      const parentPrompt = "TERMINAL_SAFE_CHILD_CREATE";
      const childPrompt = "TERMINAL_SAFE_CHILD_INITIAL";
      const routedMessage = "TERMINAL_SAFE_CHILD_ROUTED_MESSAGE";
      const parentComplete = "TERMINAL_SAFE_PARENT_COMPLETE";
      const childComplete = "TERMINAL_SAFE_CHILD_COMPLETE";
      const routedComplete = "TERMINAL_SAFE_ROUTED_COMPLETE";
      writeFileSync(resumedStderrPath, "");

      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"terminal_safe_child_create"')) {
          return fakeGatewayFinalText(parentComplete);
        }
        if (body.includes(routedMessage)) {
          return fakeGatewayFinalText(routedComplete);
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayFinalText(childComplete);
        }
        if (body.includes(parentPrompt)) {
          return fakeGatewayToolCall(
            "terminal_safe_child_create",
            "subagent",
            {
              command: {
                create: {
                  name: rawName,
                  mode: "persistent",
                  prompt: childPrompt,
                },
              },
            },
          );
        }
        return fakeGatewayFinalText("unexpected terminal-safe child request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: "terminal-safe-child-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      };

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 180,
          height: 40,
          stderrPath: fixture.stderrPath,
          remainOnExit: true,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText(parentPrompt);
        await active.waitForText(parentComplete, TIMEOUT);

        await active.sendKeys("C-x");
        const manager = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(visibleName) &&
            pane.includes("idle"),
          TIMEOUT,
        );
        expect(manager).not.toContain("redchild");
        expect(
          (await active.capturePaneGrid()).filter((row) =>
            row.includes(visibleName)
          ),
        ).toHaveLength(1);
        expect(await active.capturePaneEscapes()).not.toContain(
          "red\x1b[31mchild",
        );

        await active.sendKeys("Enter");
        const selected = await active.waitForPane(
          (pane) =>
            pane.includes(childComplete) &&
            pane.includes("status: idle") &&
            countOccurrences(pane, visibleName) >= 2,
          TIMEOUT,
        );
        expect(selected).not.toContain("redchild");
        expect(
          (await active.capturePaneGrid()).filter((row) =>
            row.includes(visibleName)
          ),
        ).toHaveLength(2);
        expect(await active.capturePaneEscapes()).not.toContain(
          "red\x1b[31mchild",
        );

        await active.sendText(routedMessage);
        await active.waitForText(routedComplete, TIMEOUT);

        type Control = {
          child_id: string;
          parent_id: string | null;
          configuration: { name: string };
        };
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const control = readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .filter((path) => existsSync(path))
          .map((path) => JSON.parse(readFileSync(path, "utf8")) as Control)
          .find((candidate) => candidate.configuration.name === rawName);
        if (!control) throw new Error("terminal-safe child control was not persisted");
        if (!control.parent_id) throw new Error("terminal-safe child lost its root");
        expect(control.configuration.name).toBe(rawName);
        expect(
          readFileSync(join(sessionsDir, control.child_id, "events.jsonl"), "utf8"),
        ).toContain(routedMessage);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        await active.sendKeys("C-x");
        await active.waitForText(parentComplete, TIMEOUT);
        await active.sendText("/quit");
        await active.waitForPane(() => active.paneStatus().dead, TIMEOUT);
        expect(paneExitMatches(active.paneStatus(), 0)).toBe(true);
        await active.kill();
        session = null;

        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${control.parent_id}`,
          cwd: fixture.workspace,
          env,
          width: 180,
          height: 40,
          stderrPath: resumedStderrPath,
          remainOnExit: true,
        });
        const resumed = session;
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendKeys("C-x");
        await resumed.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(visibleName) &&
            pane.includes("idle"),
          TIMEOUT,
        );
        await resumed.sendKeys("Enter");
        const reopened = await resumed.waitForPane(
          (pane) =>
            pane.includes(routedComplete) &&
            pane.includes("status: idle") &&
            countOccurrences(pane, visibleName) >= 2,
          TIMEOUT,
        );
        expect(reopened).not.toContain("redchild");
        expect(await resumed.capturePaneEscapes()).not.toContain(
          "red\x1b[31mchild",
        );

        await resumed.resizeWindow(96, 28);
        const narrow = await resumed.waitForPane(
          (pane) => pane.includes("lf\\x0a") && pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(narrow).not.toContain("redchild");
        expect(await resumed.capturePaneEscapes()).not.toContain(
          "red\x1b[31mchild",
        );
        expect(resumed.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");

        await resumed.sendKeys("C-x");
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendText("/quit");
        await resumed.waitForPane(() => resumed.paneStatus().dead, TIMEOUT);
        expect(paneExitMatches(resumed.paneStatus(), 0)).toBe(true);
        await resumed.kill();
        session = null;
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "manager-created children default to yolo and execute tools without approval",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const childName = "default-yolo-child";
      const childPrompt = "DEFAULT_YOLO_CHILD_PROMPT";
      const marker = join(fixture.workspace, "default-yolo-effect.txt");
      const callId = "default_yolo_child_effect";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${callId}"`)) {
          return fakeGatewayFinalText("DEFAULT_YOLO_TOOL_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall(callId, "terminal", {
            action: "exec",
            command: `printf yolo > ${JSON.stringify(marker)}`,
          });
        }
        return fakeGatewayFinalText("unexpected default-yolo request");
      }, {
        classifierDecision: "ask",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "default-yolo-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, childPrompt);
        await active.sendKeys("Enter");

        const completed = await active.waitForPane(
          (pane) =>
            pane.includes("DEFAULT_YOLO_TOOL_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(completed).not.toContain("Permission needed");
        expect(completed).not.toContain("[pending]");
        expect(existsSync(marker)).toBe(true);
        expect(readFileSync(marker, "utf8")).toBe("yolo");

        const childId = completed.match(
          /default-yolo-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("default-yolo child did not expose its ID");
        const childRoot = join(
          fixture.home,
          ".fx",
          "sessions",
          childId,
          "subagent",
        );
        const control = JSON.parse(readFileSync(
          join(childRoot, "control.json"),
          "utf8",
        )) as { configuration: { permission_mode: string } };
        expect(control.configuration.permission_mode).toBe("yolo");
        const communication = JSON.parse(readFileSync(
          join(childRoot, "communication.json"),
          "utf8",
        )) as { ledger: { approvals: unknown[] } };
        expect(communication.ledger.approvals).toEqual([]);
        expect(gateway.requests).toHaveLength(2);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent child writes a new file and recovers from ordinary read failures",
    async () => {
      const fixture = createFixture();
      const childName = "file-authority-child";
      const writePrompt = "CHILD_WRITE_NEW_FILE";
      const readPrompt = "CHILD_READ_MISSING_FILE";
      const notDirPrompt = "CHILD_READ_NON_DIRECTORY_ANCESTOR";
      const outputPath = join(fixture.workspace, "child-created.txt");
      const missingPath = join(fixture.home, "definitely-missing-child-file.txt");
      writeFileSync(join(fixture.workspace, "not-a-dir"), "regular file\n");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"child_read_not_dir"')) {
          return fakeGatewayFinalText("CHILD_NOT_DIR_RECOVERED");
        }
        if (latestPrompt(body).includes(notDirPrompt)) {
          return fakeGatewayToolCall("child_read_not_dir", "read_file", {
            path: "not-a-dir/child.txt",
          });
        }
        if (body.includes('"toolCallId":"child_read_missing"')) {
          return fakeGatewayFinalText("CHILD_READ_RECOVERED");
        }
        if (latestPrompt(body).includes(readPrompt)) {
          return fakeGatewayToolCall("child_read_missing", "read_file", {
            path: missingPath,
          });
        }
        if (body.includes('"toolCallId":"child_write_new"')) {
          return fakeGatewayFinalText("CHILD_WRITE_RECOVERED");
        }
        if (body.includes(writePrompt)) {
          return fakeGatewayToolCall("child_write_new", "write_file", {
            path: "child-created.txt",
            content: "child write succeeded\n",
          });
        }
        return fakeGatewayFinalText("unexpected child file request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-file-authority-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 104,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, writePrompt);
        await active.sendKeys("Enter");

        const written = await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_WRITE_RECOVERED") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(written).not.toContain("Latest failure:");
        expect(readFileSync(outputPath, "utf8")).toBe("child write succeeded\n");

        await active.sendText(readPrompt);
        const recovered = await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_READ_RECOVERED") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(recovered).toContain("1 read · 1 failed");
        expect(recovered).toContain("└ Failed ");
        expect(recovered).not.toContain("Latest failure:");

        await active.sendText(notDirPrompt);
        const notDirRecovered = await active.waitForPane(
          (pane) => pane.includes("CHILD_NOT_DIR_RECOVERED"),
          TIMEOUT,
        );
        expect(notDirRecovered).toContain("1 read · 1 failed");
        expect(notDirRecovered).toContain("└ Failed ");
        expect(notDirRecovered).not.toContain("Latest failure:");
        expect(gateway.requests).toHaveLength(6);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "one Ctrl-C cancels a streaming persistent child without exiting Fx",
    async () => {
      const fixture = createFixture();
      const childName = "ctrl-c-child";
      const parentPrompt = "CREATE_CTRL_C_CHILD";
      const parentReady = "CTRL_C_PARENT_READY";
      const childPrompt = "CTRL_C_CHILD_STREAM";
      const resumedStderrPath = join(root!, "ctrl-c-resumed.stderr");
      writeFileSync(resumedStderrPath, "");
      const stream = controlledTextResponse("CTRL_C_STREAM_STARTED\n");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"ctrl_c_child_create"')) {
          return fakeGatewayFinalText(parentReady);
        }
        if (body.includes(childPrompt)) return stream.response;
        if (body.includes(parentPrompt)) {
          return fakeGatewayToolCall("ctrl_c_child_create", "subagent", {
            command: {
              create: {
                name: childName,
                mode: "persistent",
                prompt: childPrompt,
                notifications: {
                  terminal: {
                    completed: false,
                    failed: false,
                    cancelled: true,
                  },
                  stop_conditions: ["terminal"],
                },
              },
            },
          });
        }
        return fakeGatewayFinalText("unexpected Ctrl-C request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: "child-ctrl-c-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      };
      type Control = {
        child_id: string;
        parent_id: string | null;
        configuration: {
          notifications: { terminal: { cancelled: boolean } };
        };
        queue: Array<{ id: string; status: string }>;
      };
      type Communication = {
        ledger: {
          deliveries: Array<{
            source_id: string;
            target_id: string;
            work_id: string | null;
            payload: { terminal?: string };
          }>;
        };
      };
      const sessionsDir = join(fixture.home, ".fx", "sessions");
      const cancelledDeliveries = (childId: string) => {
        const communication = JSON.parse(readFileSync(
          join(sessionsDir, childId, "subagent", "communication.json"),
          "utf8",
        )) as Communication;
        return communication.ledger.deliveries.filter(
          (delivery) => delivery.payload.terminal === "cancelled",
        );
      };
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText(parentPrompt);
        await active.waitForText(parentReady, TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(childName) &&
            pane.includes("running"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const running = await active.waitForPane(
          (pane) =>
            pane.includes("CTRL_C_STREAM_STARTED") &&
            pane.includes("status: running"),
          TIMEOUT,
        );
        const childId = running.match(
          /ctrl-c-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("Ctrl-C child did not expose its ID");

        await active.sendKeys("C-c");
        await active.waitForPane(
          (pane) =>
            pane.includes(childName) &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(active.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        const control = JSON.parse(readFileSync(
          join(sessionsDir, childId, "subagent", "control.json"),
          "utf8",
        )) as Control;
        expect(control.configuration.notifications.terminal.cancelled).toBe(true);
        expect(control.queue).toEqual([
          expect.objectContaining({ status: "cancelled" }),
        ]);
        if (!control.parent_id) throw new Error("Ctrl-C child lost its root");
        expect(cancelledDeliveries(control.child_id)).toEqual([
          expect.objectContaining({
            source_id: control.child_id,
            target_id: control.parent_id,
            work_id: control.queue[0]!.id,
          }),
        ]);

        const targetPid = active.processPid();
        expect(Number.isInteger(targetPid)).toBe(true);
        process.kill(targetPid, "SIGTERM");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${control.parent_id}`,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: resumedStderrPath,
        });
        const resumed = session;
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendKeys("C-x");
        await resumed.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(childName) &&
            pane.includes("idle") &&
            pane.includes("unread 1"),
          TIMEOUT,
        );
        expect(cancelledDeliveries(control.child_id)).toHaveLength(1);
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");

        await resumed.sendKeys("C-x");
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendText("/quit");
        expect(await resumed.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        if (!stream.released()) {
          try {
            stream.release("CTRL_C_CLEANUP");
          } catch {
            // The cancelled response stream is already closed by the client.
          }
        }
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "ask root rejects model-created auto child before any file write",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const childPrompt = "ASK_WRITE_CHILD_PROMPT";
      const marker = join(fixture.workspace, "ask-child-created.txt");
      let childWriteIssued = false;
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"ask_write_create"')) {
          return fakeGatewayFinalText("ASK_WRITE_PARENT_READY");
        }
        if (body.includes('"toolCallId":"ask_write_file"')) {
          return fakeGatewayFinalText("ASK_WRITE_CHILD_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          childWriteIssued = true;
          return fakeGatewayToolCall("ask_write_file", "write_file", {
            path: "ask-child-created.txt",
            content: "approved child write\n",
          });
        }
        return fakeGatewayToolCall("ask_write_create", "subagent", {
          command: {
            create: {
              name: "ask-write-child",
              mode: "persistent",
              prompt: childPrompt,
              permission_mode: "auto",
            },
          },
        });
      }, {
        classifierDecision: "ask",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "ask-write-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the ask-write child.");
        await active.waitForText("ASK_WRITE_PARENT_READY", TIMEOUT);
        expect(existsSync(marker)).toBe(false);
        expect(gateway.requests.some((request) =>
          request.body.includes("permission_escalation")
        )).toBe(true);
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const controls = readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .filter((path) => existsSync(path));
        expect(controls).toHaveLength(0);
        expect(childWriteIssued).toBe(false);
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent auto child bypasses review for its first new-file write",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
      );
      const childPrompt = "AUTO_WRITE_CHILD_PROMPT";
      const marker = join(fixture.workspace, "auto-child-created.txt");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"auto_write_create"')) {
          return fakeGatewayFinalText("AUTO_WRITE_PARENT_READY");
        }
        if (body.includes('"toolCallId":"auto_write_file"')) {
          return fakeGatewayFinalText("AUTO_WRITE_CHILD_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall("auto_write_file", "write_file", {
            path: "auto-child-created.txt",
            content: "classified child write\n",
          });
        }
        return fakeGatewayToolCall("auto_write_create", "subagent", {
          command: {
            create: {
              name: "auto-write-child",
              mode: "persistent",
              prompt: childPrompt,
              permission_mode: "auto",
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "auto-write-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the auto-write child.");
        await active.waitForText("AUTO_WRITE_PARENT_READY", TIMEOUT);
        const markerDeadline = Date.now() + TIMEOUT;
        while (!existsSync(marker) && Date.now() < markerDeadline) {
          await Bun.sleep(25);
        }
        expect(existsSync(marker)).toBe(true);
        expect(readFileSync(marker, "utf8")).toBe("classified child write\n");
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent auto child replans a direct delete before review",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
      );
      const childPrompt = "AUTO_DELETE_CHILD_PROMPT";
      const marker = join(fixture.workspace, "auto-child-keep.txt");
      writeFileSync(marker, "keep\n");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"auto_delete_create"')) {
          return fakeGatewayFinalText("AUTO_DELETE_PARENT_READY");
        }
        if (body.includes('"toolCallId":"auto_delete_file"')) {
          return fakeGatewayFinalText("AUTO_DELETE_CHILD_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall("auto_delete_file", "delete_file", {
            path: marker,
          });
        }
        return fakeGatewayToolCall("auto_delete_create", "subagent", {
          command: {
            create: {
              name: "auto-delete-child",
              mode: "persistent",
              prompt: childPrompt,
              permission_mode: "auto",
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "auto-delete-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the auto-delete child.");
        await active.waitForText("AUTO_DELETE_PARENT_READY", TIMEOUT);
        const denialDeadline = Date.now() + TIMEOUT;
        while (
          !gateway.requests.some((request) => request.body.includes("auto_denied")) &&
          Date.now() < denialDeadline
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) =>
          request.body.includes("auto_denied")
        )).toBe(true);
        expect(readFileSync(marker, "utf8")).toBe("keep\n");
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "child file always approval reuses canonical scope and keeps external writes governed",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const childName = "always-write-child";
      const childPrompt = "ALWAYS_WRITE_CHILD_INITIAL";
      const secondPrompt = "ALWAYS_WRITE_CHILD_SECOND";
      const externalPrompt = "ALWAYS_WRITE_CHILD_EXTERNAL";
      const marker = join(fixture.workspace, "always-child.txt");
      const externalMarker = join(root!, "external-child.txt");
      const createId = "always_write_create";
      const firstId = "always_write_first";
      const secondId = "always_write_second";
      const externalId = "always_write_external";
      const gateway = startDynamicFakeGateway((body) => {
        const latest = latestPrompt(body);
        if (latest.includes(`"toolCallId":"${externalId}"`)) {
          return fakeGatewayFinalText("ALWAYS_WRITE_EXTERNAL_DONE");
        }
        if (latest.includes(externalPrompt)) {
          return fakeGatewayToolCall(externalId, "write_file", {
            path: externalMarker,
            content: "EXTERNAL\n",
          });
        }
        if (latest.includes(`"toolCallId":"${secondId}"`)) {
          return fakeGatewayFinalText("ALWAYS_WRITE_SECOND_DONE");
        }
        if (latest.includes(secondPrompt)) {
          return fakeGatewayToolCall(secondId, "write_file", {
            path: "always-child.txt",
            content: "SECOND\n",
          });
        }
        if (latest.includes(`"toolCallId":"${firstId}"`)) {
          return fakeGatewayFinalText("ALWAYS_WRITE_FIRST_DONE");
        }
        if (latest.includes(childPrompt)) {
          return fakeGatewayToolCall(firstId, "write_file", {
            path: "always-child.txt",
            content: "FIRST\n",
          });
        }
        if (latest.includes(`"toolCallId":"${createId}"`)) {
          return fakeGatewayFinalText("ALWAYS_WRITE_PARENT_READY");
        }
        return fakeGatewayToolCall(createId, "subagent", {
          command: {
            create: {
              name: childName,
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "always-write-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the always-write child.");
        const firstApproval = await active.waitForText(
          `Subagent ${childName} needs permission`,
          TIMEOUT,
        );
        expect(firstApproval).toContain("always-child.txt");
        expect(firstApproval).toContain("FIRST");
        expect(existsSync(marker)).toBe(false);
        await active.sendLiteralText("2");
        await active.waitForText("ALWAYS_WRITE_PARENT_READY", TIMEOUT);

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) => pane.includes(childName) && pane.includes("idle"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("ALWAYS_WRITE_FIRST_DONE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(readFileSync(marker, "utf8")).toBe("FIRST\n");

        await active.sendText(secondPrompt);
        const secondOutcome = await active.waitForPane(
          (pane) =>
            pane.includes("ALWAYS_WRITE_SECOND_DONE") ||
            pane.includes(`Subagent ${childName} needs permission`),
          TIMEOUT,
        );
        expect(secondOutcome).toContain("ALWAYS_WRITE_SECOND_DONE");
        expect(secondOutcome).not.toContain(`Subagent ${childName} needs permission`);
        expect(readFileSync(marker, "utf8")).toBe("SECOND\n");

        const sessionRoot = join(fixture.home, ".fx", "sessions");
        const authorityGrants = readdirSync(sessionRoot).flatMap((id) => {
          const path = join(sessionRoot, id, "subagent", "communication.json");
          if (!existsSync(path)) return [];
          const record = JSON.parse(readFileSync(path, "utf8")) as {
            ledger: { authority_grants: Array<{ tool_name: string; target_path: unknown }> };
          };
          return record.ledger.authority_grants.map((grant) => ({
            tool_name: grant.tool_name,
            target_path: persistedCommunicationText(grant.target_path),
          }));
        });
        expect(authorityGrants.map((grant) => grant.tool_name)).toEqual([
          "edit",
          "create_folder",
          "open_file",
          "rename_file",
          "copy_file",
          "read",
          "list",
          "glob",
          "grep",
        ]);
        expect(authorityGrants.every(
          (grant) => grant.target_path === join(fixture.workspace, "**"),
        )).toBe(true);
        expect(authorityGrants).not.toContainEqual({
          tool_name: "write_file",
          target_path: "write_file",
        });

        await active.sendText(externalPrompt);
        const externalApproval = await active.waitForPane(
          (pane) =>
            pane.includes("external-child.txt") &&
            pane.includes("3  Don't apply") &&
            pane.includes("Enter Confirm"),
          TIMEOUT,
        );
        expect(externalApproval).toContain("Permission needed");
        expect(externalApproval).toContain("external-child.txt");
        expect(externalApproval).toContain("EXTERNAL");
        expect(existsSync(externalMarker)).toBe(false);
        await active.sendLiteralText("3");
        await active.waitForPane(
          (pane) =>
            pane.includes("ALWAYS_WRITE_EXTERNAL_DONE") &&
            pane.includes(`${childName} · idle`),
          TIMEOUT,
        );
        expect(existsSync(externalMarker)).toBe(false);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "selecting a command-running persistent child remains stable across surface switches",
    async () => {
      const fixture = createFixture();
      const childName = "command-stream-child";
      const childPrompt = "COMMAND_STREAM_CHILD_PROMPT";
      const commandCount = 10;
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"command_stream_create"')) {
          return fakeGatewayFinalText("COMMAND_STREAM_PARENT_COMPLETE");
        }
        const completedCommands = [
          ...body.matchAll(/"toolCallId":"command_stream_(\d+)"/g),
        ].map((match) => Number(match[1]));
        if (completedCommands.length > 0) {
          const next = Math.max(...completedCommands) + 1;
          if (next > commandCount) {
            return fakeGatewayFinalText("COMMAND_STREAM_CHILD_COMPLETE");
          }
          return fakeGatewayToolCall(`command_stream_${next}`, "terminal", {
            action: "exec",
            command:
              `printf COMMAND_${next}_START; sleep 0.35; printf COMMAND_${next}_END`,
          });
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall("command_stream_1", "terminal", {
            action: "exec",
            command:
              "printf COMMAND_1_START; sleep 0.35; printf COMMAND_1_END",
          });
        }
        return fakeGatewayToolCall("command_stream_create", "subagent", {
          command: {
            create: {
              name: childName,
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "command-stream-child-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
          remainOnExit: true,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the command-stream child.");
        await active.waitForText("COMMAND_STREAM_PARENT_COMPLETE", TIMEOUT);

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(childName) &&
            pane.includes("running"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes(childName) &&
            pane.includes("status: running") &&
            pane.includes("command"),
          TIMEOUT,
        );

        for (let cycle = 0; cycle < 2; cycle += 1) {
          await active.sendKeys("Escape");
          await active.waitForText("Agents & processes", TIMEOUT);
          await active.sendKeys("Enter");
          await active.waitForText(childName, TIMEOUT);
        }
        for (let cycle = 0; cycle < 2; cycle += 1) {
          await active.sendKeys("C-x");
          await active.waitForText("COMMAND_STREAM_PARENT_COMPLETE", TIMEOUT);
          await active.sendKeys("C-x");
          await active.waitForText("Agents & processes", TIMEOUT);
          await active.sendKeys("Enter");
          await active.waitForText(childName, TIMEOUT);
        }

        const completed = await active.waitForPane(
          (pane) =>
            pane.includes("COMMAND_STREAM_CHILD_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(completed).toContain("10 tool calls");
        expect(active.paneStatus()).toEqual({ dead: false, status: null });
        expect(gateway.requests).toHaveLength(commandCount + 3);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "one-burst Escape Down Enter routes the next message to the selected sibling",
    async () => {
      const fixture = createFixture();
      const childA = "fast-route-child-a";
      const childB = "fast-route-child-b";
      const marker = "FAST_ROUTE_B_ONLY_MESSAGE";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(marker)) {
          return fakeGatewayFinalText("FAST_ROUTE_B_COMPLETE");
        }
        if (body.includes("FAST_ROUTE_A_INITIAL")) {
          return fakeGatewayFinalText("FAST_ROUTE_A_READY");
        }
        if (body.includes("FAST_ROUTE_B_INITIAL")) {
          return fakeGatewayFinalText("FAST_ROUTE_B_READY");
        }
        return fakeGatewayFinalText("unexpected fast route request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fast-route-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childA);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "FAST_ROUTE_A_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForText("FAST_ROUTE_A_READY", TIMEOUT);

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childB);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "FAST_ROUTE_B_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForText("FAST_ROUTE_B_READY", TIMEOUT);

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Up");
        const selectedA = await active.waitForPane(
          (pane) => pane.split("\n").some((line) =>
            line.startsWith("› ") && line.includes(childA)
          ),
          TIMEOUT,
        );
        expect(selectedA).toContain(childB);
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes(childA) &&
            pane.includes("status: idle") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );

        await active.sendHexBytes(["1b", "1b", "5b", "42", "0d"]);
        await active.waitForPane(
          (pane) =>
            pane.includes(childB) &&
            pane.includes("status: idle") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        await active.sendText(marker);
        await active.waitForText("FAST_ROUTE_B_COMPLETE", TIMEOUT);

        type Control = {
          child_id: string;
          configuration: { name: string };
        };
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const controls = readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .filter((path) => existsSync(path))
          .map((path) =>
            JSON.parse(readFileSync(path, "utf8")) as Control
          );
        const idFor = (name: string) => {
          const control = controls.find(
            (candidate) => candidate.configuration.name === name,
          );
          if (!control) throw new Error(`missing control for ${name}`);
          return control.child_id;
        };
        const eventsFor = (name: string) =>
          readFileSync(join(sessionsDir, idFor(name), "events.jsonl"), "utf8");
        expect(eventsFor(childA)).not.toContain(marker);
        expect(eventsFor(childB)).toContain(marker);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "same active turn replays one subagent create identity and rejects changed arguments",
    async () => {
      const fixture = createFixture();
      const invocationId = "same_active_turn_create";
      const original = {
        command: {
          create: {
            name: "same-active-turn-child",
            mode: "persistent",
          },
        },
      };
      const changed = {
        command: {
          create: {
            name: "changed-active-turn-child",
            mode: "persistent",
          },
        },
      };
      const responses = [
        fakeGatewayToolCall(invocationId, "subagent", original),
        fakeGatewayToolCall(invocationId, "subagent", original),
        fakeGatewayToolCall(invocationId, "subagent", changed),
        fakeGatewayFinalText("SAME_ACTIVE_TURN_REPLAY_COMPLETE"),
      ];
      let responseIndex = 0;
      const gateway = startDynamicFakeGateway(() => {
        const response = responses[responseIndex];
        responseIndex += 1;
        if (!response) return new Response("unexpected request", { status: 500 });
        return response;
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "same-active-turn-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Exercise one same-turn subagent replay.");
        await active.waitForText("SAME_ACTIVE_TURN_REPLAY_COMPLETE", TIMEOUT);
        await active.waitForComposer(TIMEOUT);
        expect(responseIndex).toBe(4);

        type ToolResult = {
          tool_call_id: string;
          tool_name: string;
          status: "success" | "failure";
          output: string;
        };
        type HistoryFrame = {
          kind: string;
          payload: {
            turn?: {
              kind: string;
              execution?: {
                tool_steps: Array<{ tool_results: ToolResult[] }>;
              };
            };
          };
        };
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        let sessionIds: string[] = [];
        let rootState: { id: string; frames: HistoryFrame[] } | undefined;
        const persistenceDeadline = Date.now() + TIMEOUT;
        while (Date.now() < persistenceDeadline && !rootState) {
          sessionIds = readdirSync(sessionsDir).filter((id) =>
            existsSync(join(sessionsDir, id, "session.json"))
          );
          for (const id of sessionIds) {
            let frames: HistoryFrame[] = [];
            try {
              const eventText = readFileSync(
                join(sessionsDir, id, "events.jsonl"),
                "utf8",
              ).trim();
              frames = eventText.length === 0
                ? []
                : eventText.split("\n").map((line) => JSON.parse(line) as HistoryFrame);
            } catch {
              continue;
            }
            if (frames.some((frame) => frame.kind === "history_turn_committed")) {
              rootState = { id, frames };
              break;
            }
          }
          if (!rootState) await Bun.sleep(25);
        }
        expect(sessionIds).toHaveLength(2);
        if (!rootState) throw new Error("root session history was not persisted");
        const turn = rootState.frames.findLast(
          (frame) => frame.kind === "history_turn_committed",
        )?.payload.turn;
        if (!turn?.execution) throw new Error("root turn execution was not persisted");
        expect(turn.execution.tool_steps).toHaveLength(3);
        const results = turn.execution.tool_steps.map((step) => step.tool_results[0]);
        expect(results[0].output).toBe(results[1].output);
        const first = JSON.parse(results[0].output) as {
          operation_id: string;
          child_id: string;
        };
        const replay = JSON.parse(results[1].output) as {
          operation_id: string;
          child_id: string;
        };
        const conflict = JSON.parse(results[2].output) as {
          error_code: string;
        };
        expect(replay.operation_id).toBe(first.operation_id);
        expect(replay.child_id).toBe(first.child_id);
        expect(results.map((result) => result.status)).toEqual([
          "success",
          "success",
          "failure",
        ]);
        expect(conflict.error_code).toBe("operation_conflict");

        const identities = JSON.parse(readFileSync(
          join(
            sessionsDir,
            rootState.id,
            "subagent",
            "create-operations.json",
          ),
          "utf8",
        )) as { entries: unknown[]; outstanding_operations: unknown[] };
        expect(identities.entries).toHaveLength(1);
        expect(identities.outstanding_operations).toHaveLength(0);
        const control = JSON.parse(readFileSync(
          join(
            sessionsDir,
            first.child_id,
            "subagent",
            "control.json",
          ),
          "utf8",
        )) as { operations: unknown[]; events: unknown[]; queue: unknown[] };
        expect(control.operations).toHaveLength(1);
        expect(control.events).toHaveLength(1);
        expect(control.queue).toHaveLength(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "human create configure attach detach close and reopen routes preserve the main composer",
    async () => {
      const fixture = createFixture();
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("CHECKPOINT2_CHILD_COMPLETE"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-two-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteralText("CHECKPOINT2_MAIN_COMPOSER");
        await active.waitForText("CHECKPOINT2_MAIN_COMPOSER", TIMEOUT);
        const mainCursor = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "checkpoint-two-child");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CREATE_INITIAL_🦎");
        await active.sendKeys("Enter");
        const created = await active.waitForPane(
          (pane) =>
            pane.includes("checkpoint-two-child") &&
            pane.includes("CHECKPOINT2_CHILD_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        const childId = created.match(
          /checkpoint-two-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("created child did not expose its immutable ID");

        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "renamed-human-λ");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("renamed-human-λ") &&
            pane.includes(childId) &&
            pane.includes("status: idle"),
          TIMEOUT,
        );

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("t");
        const detach = await active.waitForPane(
          (pane) => pane.includes("Attach visible chat") && pane.includes("[detach]"),
          TIMEOUT,
        );
        expect(detach).toContain("CREATE_INITIAL_🦎");
        await active.sendKeys("Enter");
        await active.waitForText("No active agents", TIMEOUT);

        await active.sendLiteralText("t");
        const attach = await active.waitForPane(
          (pane) => pane.includes("Attach visible chat") && pane.includes("[attach]"),
          TIMEOUT,
        );
        expect(attach).toContain("CREATE_INITIAL_🦎");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("Agents & processes") && pane.includes("renamed-human-λ"),
          TIMEOUT,
        );

        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("Subagent") && pane.includes(childId),
          TIMEOUT,
        );
        await active.sendKeys("Tab");
        await active.sendLiteralText("x");
        await active.waitForText("Actions — renamed-human-λ", TIMEOUT);
        await active.sendLiteralText("x");
        await active.waitForText("No active agents", TIMEOUT);
        await active.sendLiteralText("r");
        const archived = await active.waitForText("Archived subagents", TIMEOUT);
        expect(archived).toContain("renamed-human-λ");
        await active.sendLiteralText("o");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent") &&
            pane.includes(childId) &&
            pane.includes("status: idle"),
          TIMEOUT,
        );

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Escape");
        await Bun.sleep(200);
        expect(await active.capturePane()).toContain("Agents & processes");
        await active.sendKeys("C-x");
        const restored = await active.waitForPane(
          (pane) =>
            pane.includes("CHECKPOINT2_MAIN_COMPOSER") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        expect(restored).not.toContain("renamed-human-λ");
        expect(active.cursorPosition()).toEqual(mainCursor);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "short attach picker keeps the selected target and load more action visible before authorization",
    async () => {
      const fixture = createFixture();
      const key = "short-relationship-disclosure-key";
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("RELATIONSHIP_DISCLOSURE_READY"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      try {
        const seeded: SeededChat[] = [];
        for (let index = 0; index < 12; index++) {
          seeded.push(await seedSavedChat(
            fixture,
            gateway,
            key,
            `ATTACH_WINDOW_${index.toString().padStart(2, "0")}`,
          ));
        }

        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: relationshipTestEnv(fixture, gateway, key),
          width: 74,
          height: 12,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("ACTIVE_RELATIONSHIP_ROOT");
        await active.waitForText("RELATIONSHIP_DISCLOSURE_READY", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("t");
        await active.waitForPane(
          (pane) => pane.includes("ATTACH_WINDOW_11") && pane.includes("] Load 10 more visible chats"),
          TIMEOUT,
        );
        for (let index = 0; index < 8; index++) await active.sendLiteralText("j");

        const selected = await active.waitForPane(
          (pane) => pane.split("\n").some((line) =>
            line.startsWith("> ") &&
            line.includes("ATTACH_WINDOW_03") &&
            line.includes("[attach]")
          ) && pane.includes("] Load 10 more visible chats"),
          TIMEOUT,
        );
        const selectedLine = selected.split("\n").find((line) => line.startsWith("> "));
        expect(selectedLine).toContain("ATTACH_WINDOW_03");
        expect(selectedLine).toContain("[attach]");
        const scrollback = await active.captureFullScrollback();
        expect(scrollback).toContain("ATTACH_WINDOW_03");
        expect(scrollback).toContain("] Load 10 more visible chats");

        const target = seeded[3]!;
        await active.sendKeys("Enter");
        await active.waitForPane(
          () => readRelationshipControl(fixture, target.session_id) !== null,
          TIMEOUT,
        );
        const control = readRelationshipControl(fixture, target.session_id);
        expect(control?.configuration.name).toBe("ATTACH_WINDOW_03");
        expect(control?.operations).toHaveLength(1);
        expect(control?.operations[0]).toMatchObject({
          code: "relationship_changed",
          identity_source: "human",
          target_id: target.session_id,
        });
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "narrow attach picker discloses the shared-prefix target and action before authorization",
    async () => {
      const fixture = createFixture();
      const key = "narrow-relationship-disclosure-key";
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("RELATIONSHIP_DISCLOSURE_READY"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      try {
        const titles = [
          "Shared subagent relationship authorization candidate alpha",
          "Shared subagent relationship authorization candidate beta",
          "Shared subagent relationship authorization candidate gamma",
        ];
        const seeded: SeededChat[] = [];
        for (const title of titles) {
          seeded.push(await seedSavedChat(fixture, gateway, key, title));
        }

        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: relationshipTestEnv(fixture, gateway, key),
          width: 40,
          height: 16,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("ACTIVE_RELATIONSHIP_ROOT");
        await active.waitForText("RELATIONSHIP_DISCLOSURE_READY", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("t");
        await active.waitForText("Shared sub", TIMEOUT);
        await active.sendLiteralText("j");

        const selected = await active.waitForPane(
          (pane) => pane.split("\n").some((line) =>
            line.startsWith("> ") && line.includes("beta") && line.includes("[attach]")
          ),
          TIMEOUT,
        );
        const selectedLine = selected.split("\n").find((line) => line.startsWith("> "));
        expect(selectedLine).toContain("beta");
        expect(selectedLine).toContain("[attach]");
        const scrollback = await active.captureFullScrollback();
        expect(scrollback).toContain("beta");
        expect(scrollback).toContain("[attach]");

        const target = seeded[1]!;
        await active.sendKeys("Enter");
        await active.waitForPane(
          () => readRelationshipControl(fixture, target.session_id) !== null,
          TIMEOUT,
        );
        const control = readRelationshipControl(fixture, target.session_id);
        expect(control?.configuration.name).toBe(titles[1]);
        expect(control?.operations).toHaveLength(1);
        expect(control?.operations[0]).toMatchObject({
          code: "relationship_changed",
          identity_source: "human",
          target_id: target.session_id,
        });
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "model approval reparent applies the reviewed relationship exactly once",
    async () => {
      const fixture = createFixture();
      const tapePath = join(root!, "model-approved-reparent.fxtape");
      const sessionsDir = join(fixture.home, ".fx", "sessions");
      const parentName = "approved-reparent-parent";
      const childName = "approved-reparent-child";
      const createParentCallId = "approved_reparent_create_parent";
      const createChildCallId = "approved_reparent_create_child";
      const reparentCallId = "approved_reparent_child";
      const inspectCallId = "approved_reparent_inspect";
      type Control = {
        child_id: string;
        parent_id: string | null;
        generation: number;
        operations: Array<{
          code: string;
          identity_source?: string;
          target_id: string;
        }>;
        events: unknown[];
        configuration: { name: string };
      };
      type Communication = {
        ledger: {
          approvals: Array<{
            kind: string;
            status: string;
            relationship: {
              action: string;
              prospective_parent_id: string;
              operation_id: string;
            } | null;
          }>;
        };
      };
      const controls = (): Array<{ path: string; control: Control }> => {
        if (!existsSync(sessionsDir)) return [];
        return readdirSync(sessionsDir).flatMap((id) => {
          const path = join(sessionsDir, id, "subagent", "control.json");
          if (!existsSync(path)) return [];
          return [{ path, control: JSON.parse(readFileSync(path, "utf8")) as Control }];
        });
      };
      const controlByName = (name: string) => {
        const found = controls().find(({ control }) =>
          control.configuration.name === name
        );
        if (!found) throw new Error(`missing ${name} control`);
        return found;
      };
      const communicationFor = (childId: string) => JSON.parse(readFileSync(
        join(sessionsDir, childId, "subagent", "communication.json"),
        "utf8",
      )) as Communication;

      let phase: "setup" | "inspect" = "setup";
      let step = 0;
      const gateway = startDynamicFakeGateway(() => {
        const responses = phase === "setup"
          ? [
            () => fakeGatewayToolCall(createParentCallId, "subagent", {
              command: {
                create: { name: parentName, mode: "persistent" },
              },
            }),
            () => fakeGatewayToolCall(createChildCallId, "subagent", {
              command: {
                create: { name: childName, mode: "persistent" },
              },
            }),
            () => fakeGatewayToolCall(reparentCallId, "subagent", {
              command: {
                relationship: {
                  action: "reparent",
                  id: controlByName(childName).control.child_id,
                  parent_id: controlByName(parentName).control.child_id,
                },
              },
            }),
            () => fakeGatewayFinalText("MODEL_APPROVAL_SETUP_COMPLETE"),
          ]
          : [
            () => fakeGatewayToolCall(inspectCallId, "subagent", {
              command: {
                inspect: {
                  id: controlByName(childName).control.child_id,
                  sections: ["status", "relationship", "events"],
                },
              },
            }),
            () => fakeGatewayFinalText("MODEL_APPROVAL_INSPECT_COMPLETE"),
          ];
        const response = responses[step++];
        return response?.() ?? new Response("unexpected gateway step", { status: 500 });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "approved-reparent-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            FX_RECORD: tapePath,
            NO_COLOR: "1",
          },
          width: 132,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create two children and reparent the second under the first.");
        const approvalPane = await active.waitForText("Reparent subagent", 60_000);
        expect(approvalPane).toContain("1. Yes");

        const parentBefore = controlByName(parentName).control;
        const childBefore = controlByName(childName).control;
        const rootId = parentBefore.parent_id;
        if (!rootId) throw new Error("parent fixture is not attached to the root");
        expect(childBefore.parent_id).toBe(rootId);
        const generationBefore = childBefore.generation;
        const operationCountBefore = childBefore.operations.length;
        const eventCountBefore = childBefore.events.length;
        const approvalBefore = communicationFor(childBefore.child_id).ledger.approvals
          .find((approval) => approval.kind === "relationship");
        expect(approvalBefore).toMatchObject({
          status: "pending",
          relationship: {
            action: "reparent",
            prospective_parent_id: parentBefore.child_id,
          },
        });

        await active.sendLiteralText("1");
        await active.waitForPane((pane) => {
          try {
            const child = controlByName(childName).control;
            return hasEmptyComposer(pane) &&
              child.parent_id === parentBefore.child_id &&
              child.generation === generationBefore + 1;
          } catch {
            return false;
          }
        }, 60_000);
        await active.waitForText("MODEL_APPROVAL_SETUP_COMPLETE", 60_000);

        const childAfter = controlByName(childName).control;
        expect(childAfter.parent_id).toBe(parentBefore.child_id);
        expect(childAfter.generation).toBe(generationBefore + 1);
        expect(childAfter.operations).toHaveLength(operationCountBefore + 1);
        expect(childAfter.events).toHaveLength(eventCountBefore + 1);
        expect(childAfter.operations.at(-1)).toMatchObject({
          code: "relationship_changed",
          identity_source: "model",
          target_id: childBefore.child_id,
        });
        const approvalAfter = communicationFor(childBefore.child_id).ledger.approvals
          .find((approval) => approval.kind === "relationship");
        expect(approvalAfter).toMatchObject({ status: "consumed" });

        phase = "inspect";
        step = 0;
        await active.sendText("Inspect the approved child's relationship.");
        await active.waitForText("MODEL_APPROVAL_INSPECT_COMPLETE", 60_000);
        const scrollback = await active.captureFullScrollback();
        expect(scrollback).toContain("Create two children and reparent the second");
        expect(scrollback).toContain("MODEL_APPROVAL_INSPECT_COMPLETE");
        expect(scrollback).not.toContain("approval pending");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        expect(readFileSync(tapePath).toString("latin1")).not.toContain("Approval ID:");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "human Ctrl-X reparent moves one nested child to the interactive root exactly once",
    async () => {
      const fixture = createFixture();
      const tapePath = join(root!, "direct-tty-reparent.fxtape");
      const parentName = "tty-reparent-parent";
      const childName = "tty-reparent-child";
      const parentPrompt = "DIRECT_TTY_REPARENT_PARENT_WORK";
      const childPrompt = "DIRECT_TTY_REPARENT_CHILD_WORK";
      const createParentCallId = "direct_tty_reparent_create_parent";
      const createChildCallId = "direct_tty_reparent_create_child";
      const relationshipSetupTimeout = 60_000;
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${createChildCallId}"`)) {
          return fakeGatewayFinalText("DIRECT_TTY_REPARENT_PARENT_COMPLETE");
        }
        if (body.includes(`"toolCallId":"${createParentCallId}"`)) {
          return fakeGatewayFinalText("DIRECT_TTY_REPARENT_ROOT_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayFinalText("DIRECT_TTY_REPARENT_CHILD_COMPLETE");
        }
        if (body.includes(parentPrompt)) {
          return fakeGatewayToolCall(createChildCallId, "subagent", {
            command: {
              create: {
                name: childName,
                mode: "persistent",
                prompt: childPrompt,
              },
            },
          });
        }
        return fakeGatewayToolCall(createParentCallId, "subagent", {
          command: {
            create: {
              name: parentName,
              mode: "persistent",
              prompt: parentPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "direct-tty-reparent-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            NO_COLOR: "1",
          },
          width: 160,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Build the direct TTY reparent fixture.");
        await active.waitForText("DIRECT_TTY_REPARENT_ROOT_COMPLETE", TIMEOUT);

        type Control = {
          child_id: string;
          generation: number;
          parent_id: string | null;
          state: string;
          configuration: { name: string };
          events: unknown[];
          operations: Array<{
            code: string;
            target_id: string;
            identity_source: string | null;
            generation: number;
          }>;
        };
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const controlPathFor = (id: string) =>
          join(sessionsDir, id, "subagent", "control.json");
        const readControl = (path: string) =>
          JSON.parse(readFileSync(path, "utf8")) as Control;
        const controlPaths = () =>
          readdirSync(sessionsDir)
            .map((id) => controlPathFor(id))
            .filter((path) => existsSync(path));
        await active.waitForPane(
          () => gateway.requestCount() >= 5,
          relationshipSetupTimeout,
        );
        expect(gateway.requestCount()).toBe(5);
        await active.waitForPane(() => {
          const paths = controlPaths();
          if (paths.length !== 2) return false;
          const controls = paths.map(readControl);
          return controls.every((control) => control.state === "idle") &&
            controls.some((control) => control.configuration.name === parentName) &&
            controls.some((control) => control.configuration.name === childName);
        }, relationshipSetupTimeout);

        const beforeByName = new Map(
          controlPaths().map((path) => {
            const control = readControl(path);
            return [control.configuration.name, { path, control }] as const;
          }),
        );
        const parentBefore = beforeByName.get(parentName);
        const childBefore = beforeByName.get(childName);
        if (!parentBefore || !childBefore) {
          throw new Error("nested reparent controls were not persisted");
        }
        const rootId = parentBefore.control.parent_id;
        if (!rootId) throw new Error("persistent parent was not attached to the root");
        expect(childBefore.control.parent_id).toBe(parentBefore.control.child_id);
        expect(childBefore.control.child_id).not.toBe(parentBefore.control.child_id);
        expect(new Set([
          rootId,
          parentBefore.control.child_id,
          childBefore.control.child_id,
        ]).size).toBe(3);
        const sessionIdsBefore = [
          rootId,
          parentBefore.control.child_id,
          childBefore.control.child_id,
        ].map((id) => {
          const record = JSON.parse(
            readFileSync(join(sessionsDir, id, "session.json"), "utf8"),
          ) as { id: string };
          expect(record.id).toBe(id);
          return record.id;
        });
        const childGenerationBefore = childBefore.control.generation;
        const childOperationCountBefore = childBefore.control.operations.length;
        const childEventCountBefore = childBefore.control.events.length;
        const parentGenerationBefore = parentBefore.control.generation;
        const parentOperationCountBefore = parentBefore.control.operations.length;

        await active.sendLiteralText("DIRECT_TTY_REPARENT_MAIN_COMPOSER");
        await active.waitForText("DIRECT_TTY_REPARENT_MAIN_COMPOSER", TIMEOUT);

        await active.sendKeys("C-x");
        const nestedTree = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.split("\n").some((line) =>
              line.includes(parentName) && line.includes("idle")
            ) &&
            pane.split("\n").some((line) =>
              line.includes(childName) && line.includes("idle")
            ),
          TIMEOUT,
        );
        const nestedParentLine = nestedTree.split("\n").find((line) =>
          line.includes(parentName)
        );
        const nestedChildLine = nestedTree.split("\n").find((line) =>
          line.includes(childName)
        );
        if (!nestedParentLine || !nestedChildLine) {
          throw new Error("nested manager tree did not render both controls");
        }
        expect(nestedChildLine.indexOf(childName)).toBeGreaterThan(
          nestedParentLine.indexOf(parentName),
        );

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("DIRECT_TTY_REPARENT_MAIN_COMPOSER") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        const mainGridBefore = await active.capturePaneGrid();
        const mainCursorBefore = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("t");
        const attach = await active.waitForPane(
          (pane) =>
            pane.includes("Attach visible chat") &&
            pane.split("\n").some((line) =>
              line.includes("[reparent]") &&
              line.includes(`relationship:${parentBefore.control.child_id}`)
            ),
          TIMEOUT,
        );
        const candidates = attach.split("\n").filter((line) =>
          /\[(?:attach|detach|reparent)\]/.test(line)
        );
        const selectedIndex = candidates.findIndex((line) => line.startsWith("> "));
        const childIndex = candidates.findIndex((line) =>
          line.includes("[reparent]") &&
          line.includes(`relationship:${parentBefore.control.child_id}`)
        );
        if (selectedIndex < 0 || childIndex < 0) {
          throw new Error("attach route did not expose a selectable reparent candidate");
        }
        const direction = selectedIndex < childIndex ? "j" : "k";
        for (let index = 0; index < Math.abs(childIndex - selectedIndex); index++) {
          await active.sendLiteralText(direction);
        }
        const selectedReparent = await active.waitForPane(
          (pane) =>
            pane.split("\n").some((line) =>
              line.startsWith("> ") &&
              line.includes("[reparent]") &&
              line.includes(`relationship:${parentBefore.control.child_id}`)
            ),
          TIMEOUT,
        );
        expect(selectedReparent).toContain("Enter explicitly authorizes the labeled action.");
        const requestsBeforeReparent = gateway.requestCount();
        await active.sendKeys("Enter");

        const directTree = await active.waitForPane((pane) => {
          if (!pane.includes("Agents & processes")) return false;
          const child = readControl(childBefore.path);
          if (
            child.parent_id !== rootId ||
            child.generation !== childGenerationBefore + 1
          ) return false;
          const parentLine = pane.split("\n").find((line) => line.includes(parentName));
          const childLine = pane.split("\n").find((line) => line.includes(childName));
          return parentLine !== undefined &&
            childLine !== undefined &&
            childLine.indexOf(childName) === parentLine.indexOf(parentName);
        }, TIMEOUT);
        expect(directTree).not.toContain("approval pending");
        expect(gateway.requestCount()).toBe(requestsBeforeReparent);

        const parentAfter = readControl(parentBefore.path);
        const childAfter = readControl(childBefore.path);
        expect(parentAfter.child_id).toBe(parentBefore.control.child_id);
        expect(parentAfter.parent_id).toBe(rootId);
        expect(parentAfter.generation).toBe(parentGenerationBefore);
        expect(parentAfter.operations).toHaveLength(parentOperationCountBefore);
        expect(childAfter.child_id).toBe(childBefore.control.child_id);
        expect(childAfter.parent_id).toBe(rootId);
        expect(childAfter.generation).toBe(childGenerationBefore + 1);
        expect(childAfter.operations).toHaveLength(childOperationCountBefore + 1);
        expect(childAfter.events).toHaveLength(childEventCountBefore + 1);
        expect(childAfter.operations.at(-1)).toMatchObject({
          code: "relationship_changed",
          target_id: childBefore.control.child_id,
          identity_source: "human",
          generation: childGenerationBefore + 1,
        });
        const sessionIdsAfter = [
          rootId,
          parentAfter.child_id,
          childAfter.child_id,
        ].map((id) => {
          const record = JSON.parse(
            readFileSync(join(sessionsDir, id, "session.json"), "utf8"),
          ) as { id: string };
          return record.id;
        });
        expect(sessionIdsAfter).toEqual(sessionIdsBefore);

        await active.sendKeys("C-x");
        const restored = await active.waitForPane(
          (pane) =>
            pane.includes("DIRECT_TTY_REPARENT_MAIN_COMPOSER") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        expect(restored).not.toContain(parentName);
        expect(restored).not.toContain(childName);
        expect(await active.capturePaneGrid()).toEqual(mainGridBefore);
        expect(active.cursorPosition()).toEqual(mainCursorBefore);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        await active.sendKeys("C-u");
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        const tape = readFileSync(tapePath).toString("latin1");
        expect(tape).not.toContain("Approval ID:");
        expect(tape).not.toContain("main chat approval pending");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "SIGTERM from the manager restores the normal buffer before abnormal exit",
    async () => {
      const fixture = createFixture();
      const active = await launch(fixture, true);
      await active.sendLiteralText("ABNORMAL_MANAGER_COMPOSER");
      await active.waitForText("ABNORMAL_MANAGER_COMPOSER", TIMEOUT);
      await active.sendKeys("C-x");
      await active.waitForText("Agents & processes", TIMEOUT);

      const targetPid = active.processPid();
      expect(Number.isInteger(targetPid)).toBe(true);
      process.kill(targetPid, "SIGTERM");
      await active.waitForPane(
        (pane) => pane.includes("ABNORMAL_MANAGER_COMPOSER") && !pane.includes("Agents & processes"),
        TIMEOUT,
      );
      await active.waitForPane(() => active.paneStatus().dead, TIMEOUT);
      expect(active.paneStatus().dead).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    40_000,
  );

  test(
    "restart preserves auto child permission context until explicit resume",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
      );
      const resumedStderrPath = join(root!, "resumed-stderr.log");
      const childPrompt = "CHECKPOINT3_RESTART_INTERRUPTED_CHILD";
      const interruptedPrefix = "CHECKPOINT3_INTERRUPTED_STREAM_";
      const resumedText = "CHECKPOINT3_EXPLICIT_RESUME_COMPLETE";
      const resumedMarker = join(fixture.workspace, "restart-auto-child.txt");
      const childStream = controlledTextResponse(interruptedPrefix);
      let childAttempts = 0;
      writeFileSync(resumedStderrPath, "");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"checkpoint3_restart_create"')) {
          return fakeGatewayFinalText("CHECKPOINT3_PARENT_CREATED_CHILD");
        }
        if (body.includes('"toolCallId":"checkpoint3_restart_write"')) {
          return fakeGatewayFinalText(resumedText);
        }
        if (body.includes(childPrompt)) {
          childAttempts += 1;
          return childAttempts === 1
            ? childStream.response
            : fakeGatewayToolCall(
              "checkpoint3_restart_write",
              "write_file",
              {
                path: "restart-auto-child.txt",
                content: "restored auto context\n",
              },
            );
        }
        return fakeGatewayToolCall("checkpoint3_restart_create", "subagent", {
          command: {
            create: {
              name: "restart-child",
              mode: "persistent",
              prompt: childPrompt,
              permission_mode: "auto",
              notifications: {
                milestones: ["checkpoint3"],
                stop_conditions: ["terminal"],
              },
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-restart-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 108,
          height: 30,
          stderrPath: fixture.stderrPath,
          remainOnExit: true,
        });
        let active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create a persistent restart fixture.");
        await active.waitForText("CHECKPOINT3_PARENT_CREATED_CHILD", TIMEOUT);
        await active.sendKeys("C-x");
        const tree = await active.waitForPane(
          (pane) => pane.includes("restart-child") && pane.includes("running"),
          TIMEOUT,
        );
        expect(tree).toContain("Agents & processes");
        await active.sendKeys("Enter");
        const running = await active.waitForPane(
          (pane) =>
            pane.includes("restart-child") &&
            pane.includes("status: running") &&
            pane.includes("running"),
          TIMEOUT,
        );
        expect(running).toContain("Parent agent");
        const childId = running.match(
          /restart-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("running child did not expose its ID");
        const controlPath = join(
          fixture.home,
          ".fx",
          "sessions",
          childId,
          "subagent",
          "control.json",
        );
        const controlBeforeCrash = JSON.parse(readFileSync(controlPath, "utf8")) as {
          parent_id: string;
          state: string;
          queue: Array<{
            content: string;
            root_user_intent_context: string;
            status: string;
          }>;
        };
        expect(controlBeforeCrash.state).toBe("running");
        expect(controlBeforeCrash.queue).toEqual([
          expect.objectContaining({
            content: childPrompt,
            root_user_intent_context: expect.stringContaining(
              "Create a persistent restart fixture.",
            ),
            status: "running",
          }),
        ]);

        const targetPid = active.processPid();
        process.kill(targetPid, "SIGKILL");
        await active.waitForPane(() => active.paneStatus().dead, TIMEOUT);
        const requestsAfterCrash = gateway.requestCount();
        expect(childAttempts).toBe(1);
        await active.kill();
        session = null;

        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${controlBeforeCrash.parent_id}`,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-restart-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 108,
          height: 30,
          stderrPath: resumedStderrPath,
        });
        active = session;
        const resumedRoot = await active.waitForText("● Session resumed:", TIMEOUT);
        expect(resumedRoot).toContain("CHECKPOINT3_PARENT_CREATED_CHILD");
        expect(resumedRoot).not.toContain("ctrl+x manager");
        expect(hasEmptyComposer(resumedRoot)).toBe(true);
        expect(gateway.requestCount()).toBe(requestsAfterCrash);
        expect(childAttempts).toBe(1);

        await active.sendKeys("C-x");
        const interruptedTree = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("restart-child") &&
            pane.includes("interrupted"),
          TIMEOUT,
        );
        expect(interruptedTree).not.toContain("running");
        expect(gateway.requestCount()).toBe(requestsAfterCrash);
        await active.sendKeys("Enter");
        const interrupted = await active.waitForPane(
          (pane) =>
            pane.includes(childId) &&
            pane.includes("status: interrupted") &&
            pane.includes("interrupted"),
          TIMEOUT,
        );
        expect(interrupted).toContain(`Parent: ${controlBeforeCrash.parent_id}`);
        expect(interrupted).toContain("Mode: persistent");
        expect(interrupted.replaceAll(/\s/g, "")).toContain(childPrompt);

        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        const configuration = await active.waitForText("Configure child", TIMEOUT);
        expect(configuration).toContain("checkpoint3");
        await active.sendKeys("Escape");
        await active.waitForText("status: interrupted", TIMEOUT);

        await active.sendKeys("Escape");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("restart-child") &&
            !pane.includes("Activity —"),
          TIMEOUT,
        );
        await active.sendLiteralText("a");
        const activity = await active.waitForText("Activity — restart-child", TIMEOUT);
        expect(activity).toContain(childId);
        await active.sendKeys("Escape");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("restart-child") &&
            !pane.includes("Activity —"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        await active.waitForText("status: interrupted", TIMEOUT);
        await active.sendKeys("Tab");
        await active.sendLiteralText("x");
        await active.waitForText("Actions — restart-child", TIMEOUT);
        await active.sendLiteralText("r");
        const completed = await active.waitForPane(
          (pane) => pane.includes(resumedText) && pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(completed.match(new RegExp(resumedText, "g"))).toHaveLength(1);
        expect(childAttempts).toBe(2);
        expect(gateway.requestCount()).toBe(requestsAfterCrash + 2);
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readFileSync(resumedMarker, "utf8")).toBe(
          "restored auto context\n",
        );

        const recoveredControl = JSON.parse(readFileSync(controlPath, "utf8")) as {
          parent_id: string;
          state: string;
          configuration: { notifications: { milestones: string[] } };
          queue: Array<{
            content: string;
            root_user_intent_context: string;
            status: string;
          }>;
          events: Array<{ kind: string; current?: string }>;
        };
        expect(recoveredControl.parent_id).toBe(controlBeforeCrash.parent_id);
        expect(recoveredControl.state).toBe("idle");
        expect(recoveredControl.configuration.notifications.milestones).toEqual([
          "checkpoint3",
        ]);
        expect(recoveredControl.queue).toEqual([
          expect.objectContaining({
            content: childPrompt,
            root_user_intent_context:
              controlBeforeCrash.queue[0]?.root_user_intent_context,
            status: "completed",
          }),
        ]);
        expect(recoveredControl.events.some((event) =>
          event.kind === "work_transition" && event.current === "interrupted"
        )).toBe(true);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "direct child resume stays inline while manager enqueue waits for one explicit retry",
    async () => {
      const fixture = createFixture();
      const parentTapePath = join(root!, "parent-manager.fxtape");
      const directTapePath = join(root!, "direct-child.fxtape");
      const directStderrPath = join(root!, "direct-stderr.log");
      const queuedMessage = "CHECKPOINT3_QUEUED_UNDER_DIRECT_LOCK_🦎";
      const completedText = "CHECKPOINT3_DIRECT_QUEUE_COMPLETE";
      writeFileSync(directStderrPath, "");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(queuedMessage)) return fakeGatewayFinalText(completedText);
        return fakeGatewayFinalText("unexpected checkpoint three request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      let direct: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-direct-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: parentTapePath,
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "direct-resume-child");
        await active.sendKeys("Enter");
        const created = await active.waitForPane(
          (pane) =>
            pane.includes("direct-resume-child") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        const childId = created.match(
          /direct-resume-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("manager-created child did not expose its ID");

        await active.sendKeys("C-x");
        await active.waitForPane((pane) => !pane.includes("Agents & processes"), TIMEOUT);
        await pasteVisibleText(active, "CHECKPOINT3_MAIN_COMPOSER_RESTORED");
        await active.sendKeys("Left");
        const mainGridBefore = await active.capturePaneGrid();
        const mainCursorBefore = active.cursorPosition();

        direct = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${childId}`,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-direct-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: directTapePath,
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: directStderrPath,
        });
        const directPane = await direct.waitForText("● Session resumed:", TIMEOUT);
        expect(hasEmptyComposer(directPane)).toBe(true);
        expect(directPane).not.toContain("Agents & processes");

        const eventsPath = join(
          fixture.home,
          ".fx",
          "sessions",
          childId,
          "events.jsonl",
        );
        const transcriptBeforeEnqueue = readFileSync(eventsPath, "utf8");

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        const relationship = await active.waitForPane(
          (pane) =>
            pane.includes(childId) &&
            pane.includes("Parent:") &&
            pane.includes("Mode: persistent"),
          TIMEOUT,
        );
        expect(relationship).toContain("status: idle");
        await pasteVisibleText(active, queuedMessage);
        await active.sendKeys("Enter");
        const blocked = await active.waitForPane(
          (pane) =>
            pane.replaceAll(/\s/g, "").includes(queuedMessage) &&
            pane.includes("[pending]") &&
            pane.includes("status: queued") &&
            pane.includes("busy: yes"),
          TIMEOUT,
        );
        expect(blocked).toContain("You");
        expect(blocked).toContain("status: queued");
        expect(gateway.requestCount()).toBe(0);
        expect(readFileSync(eventsPath, "utf8")).toBe(transcriptBeforeEnqueue);
        expect(await direct.capturePane()).not.toContain(queuedMessage);

        await active.resizeWindow(72, 18);
        await active.waitForText("[pending]", TIMEOUT);
        await active.resizeWindow(96, 28);
        await active.waitForText("[pending]", TIMEOUT);

        await direct.sendText("/quit");
        expect(await direct.waitForSessionEnd(TIMEOUT)).toBe(true);
        await direct.kill();
        direct = null;

        await active.sendKeys("Tab");
        await active.sendLiteralText("x");
        await active.waitForText("Actions — direct-resume-child", TIMEOUT);
        await active.sendLiteralText("r");
        const completed = await active.waitForPane(
          (pane) =>
            pane.includes(completedText) &&
            pane.includes("status: idle") &&
            !pane.includes("[pending]"),
          TIMEOUT,
        );
        expect(completed.match(new RegExp(completedText, "g"))).toHaveLength(1);
        expect(gateway.requestCount()).toBe(1);
        expect(gateway.requests.filter((request) =>
          request.body.includes(queuedMessage)
        )).toHaveLength(1);
        const committedQueuedTurns = readFileSync(eventsPath, "utf8")
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line) as {
            kind?: string;
            payload?: { turn?: { user?: { text?: string } } };
          })
          .filter((frame) =>
            frame.kind === "history_turn_committed" &&
            frame.payload?.turn?.user?.text === queuedMessage
          );
        expect(committedQueuedTurns).toHaveLength(1);

        await active.sendKeys("Tab");
        await active.sendLiteralText("x");
        await active.waitForText("Actions — direct-resume-child", TIMEOUT);
        await active.sendLiteralText("x");
        await active.waitForText("No active agents", TIMEOUT);
        await active.sendLiteralText("r");
        await active.waitForText("Archived subagents", TIMEOUT);
        await active.sendLiteralText("o");
        await active.waitForPane(
          (pane) => pane.includes(childId) && pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("CHECKPOINT3_MAIN_COMPOSER_RESTORED", TIMEOUT);
        expect(await active.capturePaneGrid()).toEqual(mainGridBefore);
        expect(active.cursorPosition()).toEqual(mainCursorBefore);

        const parentTape = readFileSync(parentTapePath).toString("latin1");
        expect(countOccurrences(parentTape, "\x1b[?1049h")).toBe(2);
        expect(countOccurrences(parentTape, "\x1b[?1049l")).toBe(2);
        const directTape = readFileSync(directTapePath).toString("latin1");
        expect(countOccurrences(directTape, "\x1b[?1049h")).toBe(0);
        expect(countOccurrences(directTape, "\x1b[?1049l")).toBe(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
        expect(readFileSync(directStderrPath, "utf8")).toBe("");
      } finally {
        await direct?.kill();
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "in-process resumed parent bounds external-owner recovery and disables cancel",
    async () => {
      const fixture = createFixture();
      const childName = "external-owner-child";
      const parentPrompt = "EXTERNAL_OWNER_PARENT_SESSION";
      const parentComplete = "EXTERNAL_OWNER_PARENT_SAVED";
      const directMessage = "EXTERNAL_OWNER_DIRECT_TURN";
      const queuedMessage = "EXTERNAL_OWNER_QUEUED_TURN";
      const queuedComplete = "EXTERNAL_OWNER_QUEUE_COMPLETE";
      const directStream = controlledTextResponse("EXTERNAL_OWNER_STREAM_START\n");
      const parentStderrPath = join(root!, "external-owner-parent.stderr");
      const parentTracePath = join(root!, "external-owner-parent.trace");
      const directStderrPath = join(root!, "external-owner-direct.stderr");
      writeFileSync(parentStderrPath, "");
      writeFileSync(parentTracePath, "");
      writeFileSync(directStderrPath, "");
      const gateway = startDynamicFakeGateway((body) => {
        const latest = latestPrompt(body);
        if (latest.includes(parentPrompt)) return fakeGatewayFinalText(parentComplete);
        if (latest.includes(queuedMessage)) return fakeGatewayFinalText(queuedComplete);
        if (latest.includes(directMessage)) return directStream.response;
        return fakeGatewayFinalText("unexpected external-owner request");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      let direct: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "external-owner-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const setup = session;
        await setup.waitForComposer(TIMEOUT);
        await setup.sendText(parentPrompt);
        await setup.waitForText(parentComplete, TIMEOUT);
        await setup.sendKeys("C-x");
        await setup.waitForText("Agents & processes", TIMEOUT);
        await setup.sendLiteralText("c");
        await setup.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(setup, childName);
        await setup.sendKeys("Enter");
        const created = await setup.waitForPane(
          (pane) => pane.includes(childName) && pane.includes("status: idle"),
          TIMEOUT,
        );
        const childId = created.match(
          new RegExp(`${childName}\\s+·\\s+([^\\s]+)`),
        )?.[1];
        if (!childId) throw new Error("manager-created child did not expose its ID");
        const parentId = readdirSync(
          join(fixture.home, ".fx", "sessions"),
          { withFileTypes: true },
        ).find((entry) =>
          entry.isDirectory() && entry.name !== "latest" && entry.name !== childId
        )?.name;
        if (!parentId) throw new Error("parent session ID was not persisted");
        const controlPath = join(
          fixture.home,
          ".fx",
          "sessions",
          childId,
          "subagent",
          "control.json",
        );

        await setup.sendKeys("C-x");
        await setup.waitForComposer(TIMEOUT);
        await setup.sendText("/quit");
        expect(await setup.waitForSessionEnd(TIMEOUT)).toBe(true);
        await setup.kill();
        session = null;

        direct = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${childId}`,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "external-owner-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: directStderrPath,
        });
        await direct.waitForComposer(TIMEOUT);
        await direct.sendText(directMessage);
        await direct.waitForPane(
          () => gateway.requests.some((request) =>
            latestPrompt(request.body).includes(directMessage)
          ),
          TIMEOUT,
        );
        directStream.push("EXTERNAL_OWNER_STREAM_HELD\n");
        directStream.push("EXTERNAL_OWNER_STREAM_READY\n");
        await direct.waitForText("EXTERNAL_OWNER_STREAM_HELD", TIMEOUT);
        const childEventsPath = join(
          fixture.home,
          ".fx",
          "sessions",
          childId,
          "events.jsonl",
        );
        const childEventsBeforeResume = readFileSync(childEventsPath, "utf8");

        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "external-owner-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_TRACE_LOG: parentTracePath,
            NO_COLOR: "1",
          },
          width: 96,
          height: 28,
          stderrPath: parentStderrPath,
        });
        const parent = session;
        await parent.waitForComposer(TIMEOUT);
        const requestsBeforeResume = gateway.requestCount();
        await parent.sendText("/resume");
        await parent.waitForText("Sessions", TIMEOUT);
        await parent.sendLiteralText(parentPrompt);
        await parent.waitForPane(
          (pane) => pane.includes("Sessions 1") && pane.includes(parentPrompt),
          TIMEOUT,
        );
        await parent.sendKeys("Enter");
        await parent.waitForText(`● Session resumed: ${parentPrompt}`, TIMEOUT);
        const recoveryMarker = `background host recovery finished root_id=${parentId}`;
        await parent.waitForPane(
          () => readFileSync(parentTracePath, "utf8").includes(recoveryMarker),
          TIMEOUT,
        );
        const recoveryTrace = readFileSync(parentTracePath, "utf8");
        expect(recoveryTrace).toContain("state=deferred");
        expect(recoveryTrace).toContain("busy=1");
        expect(gateway.requestCount()).toBe(requestsBeforeResume);

        await Bun.sleep(1_300);
        await parent.sendKeys("C-x");
        const externalTree = await parent.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes(childName) &&
            pane.includes("external busy"),
          TIMEOUT,
        );
        const externalLine = externalTree.split("\n").find((line) =>
          line.includes(childName)
        );
        expect(externalLine).toContain("external busy");
        expect(externalLine).not.toContain("idle");
        await parent.sendKeys("C-x");
        await parent.waitForComposer(TIMEOUT);
        await parent.sendKeys("C-x");
        await parent.waitForText("Agents & processes", TIMEOUT);
        expect(countOccurrences(
          readFileSync(parentTracePath, "utf8"),
          recoveryMarker,
        )).toBe(1);
        expect(gateway.requestCount()).toBe(requestsBeforeResume);
        expect(readFileSync(childEventsPath, "utf8")).toBe(childEventsBeforeResume);
        await parent.sendKeys("Enter");
        const externalDetail = await parent.waitForPane(
          (pane) =>
            pane.includes("status: idle") &&
            pane.includes("busy: yes"),
          TIMEOUT,
        );
        expect(externalDetail).not.toContain("busy: no");

        const generationBeforeCancel = (JSON.parse(
          readFileSync(controlPath, "utf8"),
        ) as { generation: number }).generation;
        await parent.sendKeys("Tab");
        await parent.sendLiteralText("x");
        const idleActions = await parent.waitForPane(
          (pane) =>
            pane.includes(`Actions — ${childName}`) &&
            pane.includes("another Fx process owns this child"),
          TIMEOUT,
        );
        expect(idleActions).not.toContain("C cancel");
        await parent.sendLiteralText("c");
        await Bun.sleep(300);
        directStream.push("EXTERNAL_OWNER_AFTER_CANCEL\n");
        directStream.push("EXTERNAL_OWNER_AFTER_CANCEL_FLUSH\n");
        await direct.waitForText("EXTERNAL_OWNER_AFTER_CANCEL", TIMEOUT);
        expect((JSON.parse(readFileSync(controlPath, "utf8")) as {
          generation: number;
        }).generation).toBe(generationBeforeCancel);

        await parent.sendKeys("Escape");
        await parent.waitForText("status: idle", TIMEOUT);
        await parent.pasteText(queuedMessage);
        await parent.sendKeys("Enter");
        await parent.waitForPane(
          (pane) =>
            pane.replaceAll(/\s/g, "").includes(queuedMessage) &&
            pane.includes("[pending]") &&
            pane.includes("status: queued") &&
            pane.includes("busy: yes"),
          TIMEOUT,
        );
        const queuedControl = JSON.parse(readFileSync(controlPath, "utf8")) as {
          generation: number;
          queue: Array<{ content: string; status: string }>;
        };
        expect(queuedControl.queue.find((item) =>
          item.content === queuedMessage
        )?.status).toBe("pending");
        await parent.sendKeys("Tab");
        await parent.sendLiteralText("x");
        const queuedActions = await parent.waitForText(
          "another Fx process owns this child",
          TIMEOUT,
        );
        expect(queuedActions).not.toContain("C cancel");
        await parent.sendLiteralText("c");
        await Bun.sleep(300);
        const afterQueuedCancel = JSON.parse(
          readFileSync(controlPath, "utf8"),
        ) as {
          generation: number;
          queue: Array<{ content: string; status: string }>;
        };
        expect(afterQueuedCancel.generation).toBe(queuedControl.generation);
        expect(afterQueuedCancel.queue.find((item) =>
          item.content === queuedMessage
        )?.status).toBe("pending");
        expect(await direct.capturePane()).toContain(
          "EXTERNAL_OWNER_AFTER_CANCEL",
        );

        directStream.release("EXTERNAL_OWNER_DIRECT_COMPLETE");
        await direct.waitForText("EXTERNAL_OWNER_DIRECT_COMPLETE", TIMEOUT);
        await direct.waitForComposer(TIMEOUT);
        await direct.sendText("/quit");
        expect(await direct.waitForSessionEnd(TIMEOUT)).toBe(true);
        await direct.kill();
        direct = null;

        await parent.sendLiteralText("r");
        const locallyOwnedChild = await parent.waitForPane(
          (pane) =>
            pane.includes(childName) &&
            !pane.includes("another Fx process owns this child") &&
            ((pane.includes(`Actions — ${childName}`) &&
              (pane.includes("Current state: idle") ||
                pane.includes("Current state: interrupted"))) ||
              (pane.includes("status: idle") && pane.includes("busy: no"))),
          TIMEOUT,
        );
        expect(locallyOwnedChild).not.toContain(
          "another Fx process owns this child",
        );
        expect(gateway.requests.filter((request) =>
          latestPrompt(request.body).includes(directMessage)
        )).toHaveLength(1);
        expect(gateway.requests.filter((request) =>
          latestPrompt(request.body).includes(queuedMessage)
        ).length).toBeLessThanOrEqual(1);

        await parent.sendKeys("C-x");
        await parent.waitForComposer(TIMEOUT);
        await parent.sendText("/quit");
        expect(await parent.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
        expect(readFileSync(parentStderrPath, "utf8")).toBe("");
        expect(readFileSync(directStderrPath, "utf8")).toBe("");
      } finally {
        if (!directStream.released()) {
          try {
            directStream.release("CLEANUP");
          } catch {
            // The client may already have closed the response stream.
          }
        }
        await direct?.kill();
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "selected child preserves and resolves its approval across Ctrl-X reopen",
    async () => {
      const fixture = createFixture();
      const tapePath = join(fixture.home, "inline-child-approval-toggle.fxtape");
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const marker = join(fixture.workspace, "child-approval-effect.txt");
      const initialPrompt = "CHECKPOINT2_CHILD_INITIAL_PROMPT";
      const parentPrompt = "CHECKPOINT2_PARENT_SENDS_CHILD_FOLLOWUP";
      const parentMessage = "CHECKPOINT2_PARENT_AGENT_FOLLOWUP";
      const childPrompt = "CHECKPOINT2_CHILD_APPROVAL_PROMPT";
      const filePrompt = "CHECKPOINT2_FILE_REVIEW_PROMPT";
      const callId = "checkpoint2_child_approval_effect";
      const fileCallId = "checkpoint2_child_file_approval_effect";
      const parentCallId = "checkpoint2_parent_send_followup";
      const fileTarget = join(fixture.workspace, "child-approval-file-effect.txt");
      const fileContent = Array.from(
        { length: 80 },
        (_, index) => `handoff-line-${String(index + 1).padStart(2, "0")}`,
      ).join("\n") + "\n";
      const initialStream = controlledTextResponse("CHECKPOINT2_CHILD_INITIAL_STREAM");
      const heldStream = controlledTextResponse("CHECKPOINT2_PARENT_FOLLOWUP_STREAM");
      let releaseChildApproval!: (response: Response) => void;
      let childApprovalReleased = false;
      const childApprovalResponse = new Promise<Response>((resolve) => {
        releaseChildApproval = (response) => {
          childApprovalReleased = true;
          resolve(response);
        };
      });
      let childId: string | undefined;
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${fileCallId}"`)) {
          return fakeGatewayFinalText("CHECKPOINT2_CHILD_FILE_APPROVAL_COMPLETE");
        }
        if (body.includes(filePrompt)) {
          return fakeGatewayToolCall(fileCallId, "write_file", {
            path: "child-approval-file-effect.txt",
            content: fileContent,
          });
        }
        if (body.includes(`"toolCallId":"${callId}"`)) {
          return fakeGatewayFinalText("CHECKPOINT2_CHILD_APPROVAL_COMPLETE");
        }
        if (body.includes(`"toolCallId":"${parentCallId}"`)) {
          return fakeGatewayFinalText("CHECKPOINT2_PARENT_SEND_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          return childApprovalResponse;
        }
        if (body.includes(parentMessage)) return heldStream.response;
        if (body.includes(parentPrompt)) {
          if (!childId) throw new Error("parent follow-up requested before child ID was known");
          return fakeGatewayToolCall(parentCallId, "subagent", {
            command: {
              message: {
                send: {
                  id: childId,
                  content: parentMessage,
                },
              },
            },
          });
        }
        if (body.includes(initialPrompt)) return initialStream.response;
        return fakeGatewayFinalText("unexpected checkpoint two request");
      }, {
        classifierDecision: "ask",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-two-approval-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            NO_COLOR: "1",
          },
          width: 160,
          height: 48,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "approval-child");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, initialPrompt);
        for (let index = 0; index < 5; index += 1) await active.sendKeys("Tab");
        await active.sendLiteralText(" ");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("approval-child") &&
            pane.includes("status: running"),
          TIMEOUT,
        );
        initialStream.release("CHECKPOINT2_CHILD_INITIAL_COMPLETE");
        await active.waitForPane(
          (pane) =>
            pane.includes("CHECKPOINT2_CHILD_INITIAL_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        const initialChild = await active.capturePane();
        childId = initialChild.match(/approval-child\s+·\s+([^\s]+)/)?.[1];
        if (!childId) throw new Error("selected child did not expose its immutable ID");

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText(parentPrompt);
        await active.waitForText("CHECKPOINT2_PARENT_SEND_COMPLETE", TIMEOUT);
        await active.sendLiteralText("APPROVAL_MAIN_COMPOSER");
        await active.waitForText("APPROVAL_MAIN_COMPOSER", TIMEOUT);
        const mainCursor = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes(parentMessage) &&
            pane.includes("status: running"),
          TIMEOUT,
        );
        await active.sendText(childPrompt);
        await active.waitForText("[pending]", TIMEOUT);
        heldStream.release("CHECKPOINT2_PARENT_FOLLOWUP_COMPLETE");
        const childApprovalRequestStartedAt = Date.now();
        while (
          !gateway.requests.some((request) => request.body.includes(childPrompt)) &&
          Date.now() - childApprovalRequestStartedAt < TIMEOUT
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) => request.body.includes(childPrompt))).toBe(true);
        await active.sendKeys("C-o");
        await active.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
        await active.sendKeys("Right");
        await active.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
        releaseChildApproval(fakeGatewayToolCall(callId, "terminal", {
          action: "exec",
          command: "printf approved > child-approval-effect.txt",
        }));
        const childApproval = await active.waitForPane(
          (pane) =>
            pane.includes("Subagent approval-child needs permission") &&
            pane.includes("1. Yes") &&
            pane.includes("2. Yes, and don't ask again") &&
            pane.includes("3. No"),
          TIMEOUT,
        );
        expect(childApproval).toContain("Command");
        expect(childApproval).toContain("printf approved");
        expect(childApproval).toContain("$ # terminal.exec profile=user shell=");
        expect(childApproval).toContain("printf approved > child-approval-effect.txt");
        expect(childApproval).toContain("1. Yes");
        expect(childApproval).toContain("2. Yes, and don't ask again");
        expect(childApproval).toContain("3. No");
        expect(childApproval).toContain("❯ 1. Yes");
        expect(childApproval).not.toContain("APPROVAL_MAIN_COMPOSER");
        expect(childApproval).not.toContain("Review · ←/→ switch · ctrl o close");
        expect(childApproval).not.toContain("Full detail · ←/→ switch · ctrl o close");

        await active.sendKeys("C-o");
        await Bun.sleep(100);
        const approvalAfterCtrlO = await active.capturePane();
        expect(approvalAfterCtrlO).toContain("Subagent approval-child needs permission");
        expect(approvalAfterCtrlO).not.toContain("Review · ←/→ switch · ctrl o close");
        expect(approvalAfterCtrlO).not.toContain("Full detail · ←/→ switch · ctrl o close");

        await active.sendKeys("C-x");
        const mainApproval = await active.waitForPane(
          (pane) =>
            pane.includes("Subagent approval-child needs permission") &&
            pane.includes("Command") &&
            pane.includes("$ # terminal.exec profile=user shell=") &&
            pane.includes("printf approved > child-approval-effect.txt") &&
            !pane.includes(childPrompt),
          TIMEOUT,
        );
        expect(mainApproval).toContain("Command");
        expect(mainApproval).toContain("$ # terminal.exec profile=user shell=");
        expect(mainApproval).toContain("printf approved > child-approval-effect.txt");
        expect(mainApproval).not.toContain(childPrompt);

        const inlineApprovalToggleStart = (
          await readLiveStdoutFrames(tapePath)
        ).length;
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        const inlineApprovalToggleFrames = await waitForLiveStdoutFrames(
          tapePath,
          inlineApprovalToggleStart,
          "inline approval manager enter",
          (frames) => frames.some((frame) =>
            frame.payload.includes("\x1b[?1049h")
          ),
        );
        expect(inlineApprovalToggleFrames.some((frame) =>
          frame.payload.includes("\x1b[?1049h")
        )).toBe(true);
        expect(inlineApprovalToggleFrames.some((frame) =>
          frame.payload.includes("\x1b[?1049l")
        )).toBe(false);
        await active.sendKeys("Enter");
        const reopenedApproval = await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: approval-child") &&
            pane.includes("Subagent approval-child needs permission") &&
            pane.includes("status: approval") &&
            pane.includes("Command") &&
            pane.includes("$ # terminal.exec profile=user shell=") &&
            pane.includes("printf approved > child-approval-effect.txt") &&
            pane.includes("❯ 1. Yes"),
          TIMEOUT,
        );
        expect(reopenedApproval).not.toContain("APPROVAL_MAIN_COMPOSER");

        await active.sendKeys("Right");
        const movedApproval = await active.waitForPane(
          (pane) => pane.includes("❯ 2. Yes, and don't ask again"),
          TIMEOUT,
        );
        expect(movedApproval).not.toContain("❯ 1. Yes");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("CHECKPOINT2_CHILD_APPROVAL_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(readFileSync(marker, "utf8")).toBe("approved");
        const childGrid = await active.capturePaneGrid();
        const childCursor = active.cursorPosition();
        const childPane = await active.capturePane();
        expect(childPane).toContain("You");
        expect(childPane).toContain(childPrompt);

        await active.sendKeys("C-x");
        const restored = await active.waitForText("APPROVAL_MAIN_COMPOSER", TIMEOUT);
        expect(restored).not.toContain("Agents & processes");
        expect(restored).not.toContain("Subagent approval-child needs permission");
        expect(active.cursorPosition()).toEqual(mainCursor);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForText("CHECKPOINT2_CHILD_APPROVAL_COMPLETE", TIMEOUT);
        expect(await active.capturePaneGrid()).toEqual(childGrid);
        expect(active.cursorPosition()).toEqual(childCursor);
        expect(gateway.classifierRequests).toHaveLength(0);

        await active.sendText(filePrompt);
        await active.waitForText("child-approval-file-effect.txt", TIMEOUT);
        const mainFileApprovalStart = (
          await readLiveStdoutFrames(tapePath)
        ).length;
        await active.sendKeys("C-x");
        const mainFileApproval = await active.waitForPane(
          (pane) =>
            pane.includes("child-approval-file-effect.txt") &&
            pane.includes("Apply this change?") &&
            pane.includes("handoff-line-80"),
          TIMEOUT,
        );
        expect(mainFileApproval).toContain("1  Apply once");
        const ownedApprovalFrames = await waitForLiveStdoutFrames(
          tapePath,
          mainFileApprovalStart,
          "owned file approval enter",
          (frames) =>
            frames.some((frame) => frame.payload.includes("\x1b[?1049h")) &&
            frames.some((frame) =>
              frame.payload.includes("\x1b[?1000h\x1b[?1006h")
            ),
        );
        expect(ownedApprovalFrames.some((frame) =>
          frame.payload.includes("\x1b[?1049h")
        )).toBe(true);
        expect(ownedApprovalFrames.some((frame) =>
          frame.payload.includes("\x1b[?1000h\x1b[?1006h")
        )).toBe(true);

        const ownedApprovalToggleStart = (
          await readLiveStdoutFrames(tapePath)
        ).length;
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        const ownedApprovalToggleFrames = await waitForLiveStdoutFrames(
          tapePath,
          ownedApprovalToggleStart,
          "owned file approval manager enter",
          (frames) => frames.some((frame) =>
            frame.payload.includes("\x1b[?1000l\x1b[?1006l")
          ),
        );
        expect(ownedApprovalToggleFrames.some((frame) =>
          frame.payload.includes("\x1b[?1000l\x1b[?1006l")
        )).toBe(true);
        expect(ownedApprovalToggleFrames.some((frame) =>
          frame.payload.includes("\x1b[?1049l") || frame.payload.includes("\x1b[?1049h")
        )).toBe(false);

        await active.sendKeys("Enter");
        await active.waitForText("child-approval-file-effect.txt", TIMEOUT);
        await active.sendLiteralText("3");
        await active.waitForText("CHECKPOINT2_CHILD_FILE_APPROVAL_COMPLETE", TIMEOUT);
        expect(existsSync(fileTarget)).toBe(false);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        if (!initialStream.released()) {
          try {
            initialStream.release("CLEANUP");
          } catch {}
        }
        if (!heldStream.released()) {
          try {
            heldStream.release("CLEANUP");
          } catch {}
        }
        if (!childApprovalReleased) {
          releaseChildApproval(fakeGatewayFinalText("CLEANUP"));
        }
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "terminal one-off delivers once retires and leaves persistent controls intact",
    async () => {
      const fixture = createFixture();
      const childName = "temporary-result";
      const persistentName = "persistent-control";
      const persistentInitial = "PERSISTENT_CONTROL_INITIAL";
      const persistentReady = "PERSISTENT_CONTROL_READY";
      const persistentResume = "PERSISTENT_CONTROL_SECOND";
      const persistentResumed = "PERSISTENT_CONTROL_RESUMED";
      const mainPrompt = "ONEOFF_RETIREMENT_MAIN";
      const childPrompt = "ONEOFF_RETIREMENT_CHILD";
      const childDone = "ONEOFF_RETIREMENT_RESULT";
      const parentAck = "ONEOFF_RETIREMENT_ACK";
      const parentAckDone = "ONEOFF_RETIREMENT_ACK_DONE";
      const childStream = controlledTextResponse("ONEOFF_RETIREMENT_STREAM_");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(persistentResume)) return fakeGatewayFinalText(persistentResumed);
        if (body.includes(parentAck) && body.includes(childDone)) {
          return fakeGatewayFinalText(parentAckDone);
        }
        if (body.includes(persistentInitial)) return fakeGatewayFinalText(persistentReady);
        if (body.includes('"toolCallId":"create_temporary_result"')) {
          return fakeGatewayFinalText("ONEOFF_RETIREMENT_MAIN_DONE");
        }
        if (body.includes(childPrompt)) return childStream.response;
        if (body.includes(mainPrompt)) {
          return fakeGatewayToolCall("create_temporary_result", "subagent", {
            command: {
              create: {
                name: childName,
                mode: "one_off",
                prompt: childPrompt,
              },
            },
          });
        }
        return fakeGatewayFinalText("unexpected retirement request");
      }, {
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = relationshipTestEnv(fixture, gateway, "oneoff-retirement");

      type ResumeControl = {
        child_id: string;
        parent_id: string;
        mode: "persistent" | "one_off";
        state: string;
        configuration: { name: string };
      };
      const sessionsDir = join(fixture.home, ".fx", "sessions");
      const readControls = () =>
        readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .filter((path) => existsSync(path))
          .map((path) => ({
            path,
            value: JSON.parse(readFileSync(path, "utf8")) as ResumeControl,
          }));

      async function waitForControl(name: string, state: string) {
        const deadline = Date.now() + TIMEOUT;
        while (Date.now() < deadline) {
          const found = readControls().find((entry) =>
            entry.value.configuration.name === name &&
            entry.value.state === state
          );
          if (found) return found;
          await Bun.sleep(25);
        }
        throw new Error(`control did not reach ${name}:${state}`);
      }

      async function runAsk(args: string[]) {
        const child = Bun.spawn([FX_BIN, "ask", ...args], {
          cwd: fixture.workspace,
          env,
          stdout: "pipe",
          stderr: "pipe",
        });
        const [stdout, stderr, exitCode] = await Promise.all([
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
          child.exited,
        ]);
        return { stdout, stderr, exitCode };
      }

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 80,
          height: 24,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, persistentName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, persistentInitial);
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes(persistentReady) && pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);

        await active.sendText(mainPrompt);
        await active.waitForPane(
          (pane) => pane.includes("ONEOFF_RETIREMENT_MAIN_DONE") && !pane.includes("Streaming ("),
          TIMEOUT,
        );
        const childStartedDeadline = Date.now() + TIMEOUT;
        while (
          !gateway.requests.some((request) => request.body.includes(childPrompt)) &&
          Date.now() < childStartedDeadline
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) => request.body.includes(childPrompt))).toBe(true);
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes(childName) &&
            pane.includes("running") &&
            pane.includes(persistentName),
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        childStream.release(childDone);
        const oneOff = await waitForControl(childName, "completed");
        const persistent = await waitForControl(persistentName, "idle");

        await active.sendKeys("C-x");
        const managerPane = await active.waitForPane(
          (pane) => pane.includes(persistentName) && !pane.includes(childName),
          TIMEOUT,
        );
        expect(managerPane).not.toContain(childName);
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);

        await active.sendText(parentAck);
        await active.waitForText(parentAckDone, TIMEOUT);
        expect(
          gateway.requests.some((request) =>
            request.body.includes(parentAck) && request.body.includes(childDone)
          ),
        ).toBe(true);

        const childDir = join(sessionsDir, oneOff.value.child_id);
        const retirementDeadline = Date.now() + TIMEOUT;
        while (existsSync(childDir) && Date.now() < retirementDeadline) {
          await Bun.sleep(25);
        }
        expect(existsSync(childDir)).toBe(false);

        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        const retired = await runAsk([
          "--json",
          "--auto",
          "--resume-id",
          oneOff.value.child_id,
          "must not resume",
        ]);
        expect(retired.exitCode).toBe(1);
        expect(retired.stderr).toBe("");
        expect(JSON.parse(retired.stdout)).toMatchObject({
          exit_code: 1,
          error: "SessionNotFound",
        });

        const persistentControl = await runAsk([
          "--json",
          "--auto",
          "--resume-id",
          persistent.value.child_id,
          persistentResume,
        ]);
        expect(persistentControl.exitCode).toBe(0);
        expect(persistentControl.stderr).toBe("");
        expect(JSON.parse(persistentControl.stdout)).toMatchObject({
          exit_code: 0,
          output: persistentResumed,
        });
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        if (!childStream.released()) {
          try {
            childStream.release("CLEANUP");
          } catch {}
        }
        gateway.stop();
      }
    },
    60_000,
  );
  test(
    "persistent child quit exits locally without sending a model turn",
    async () => {
      const fixture = createFixture();
      const childName = "child-local-quit";
      const childPrompt = "CHILD_LOCAL_QUIT_INITIAL";
      const gateway = startDynamicFakeGateway((body) =>
        fakeGatewayFinalText(
          body.includes("/quit")
            ? "CHILD_QUIT_REACHED_MODEL"
            : "CHILD_LOCAL_QUIT_READY",
        ), {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-local-quit",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, childPrompt);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_QUIT_READY", TIMEOUT);

        const requestCountBeforeQuit = gateway.requests.length;
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        expect(gateway.requests).toHaveLength(requestCountBeforeQuit);
        expect(
          gateway.requests.some((request) => request.body.includes("/quit")),
        ).toBe(false);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent child executes models locally and configures the selected model",
    async () => {
      const fixture = createFixture();
      const childName = "child-local-models";
      const childPrompt = "CHILD_LOCAL_MODELS_INITIAL";
      const selectedModel = "other/child-model";
      let releaseModels!: () => void;
      const modelsReady = new Promise<void>((resolve) => {
        releaseModels = resolve;
      });
      const gateway = startDynamicFakeGateway((body) =>
        fakeGatewayFinalText(
          body.includes("/models")
            ? "CHILD_MODELS_REACHED_MODEL"
            : "CHILD_LOCAL_MODELS_READY",
        ), {
        classifierDecision: "allow",
        models: async () => {
          await modelsReady;
          return [
            { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
            { id: selectedModel, type: "language", tags: ["tool-use"] },
          ];
        },
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-local-models",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 72,
          height: 16,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteralText("MAIN_MODELS_DRAFT");
        await active.waitForText("MAIN_MODELS_DRAFT", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, childPrompt);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_MODELS_READY", TIMEOUT);

        const requestCountBeforeModels = gateway.requestCount();
        await active.sendText("/models");
        await active.waitForText("Loading models", TIMEOUT);
        await active.sendKeys("C-x");
        const mainWhileModelsLoad = await active.waitForPane(
          (pane) =>
            pane.includes("MAIN_MODELS_DRAFT") &&
            !pane.includes("Loading models"),
          TIMEOUT,
        );
        expect(mainWhileModelsLoad).toContain("MAIN_MODELS_DRAFT");
        expect(gateway.requestCount()).toBe(requestCountBeforeModels);

        releaseModels();
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_MODELS_READY", TIMEOUT);
        await active.sendText("/models");
        const models = await active.waitForText(selectedModel, TIMEOUT);
        expect(models).toContain("Models 2");
        expect(gateway.requestCount()).toBe(requestCountBeforeModels);
        expect(
          gateway.requests.some((request) => request.body.includes("/models")),
        ).toBe(false);

        await active.sendLiteralText("missing-child-model-filter");
        await active.waitForText("No models found.", TIMEOUT);
        await active.sendKeys("Escape");
        const escapedModels = await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_LOCAL_MODELS_READY") &&
            !pane.includes("Models 2") &&
            !pane.includes("Esc Close") &&
            hasEmptyComposer(pane),
          TIMEOUT,
        );
        expect(escapedModels).not.toContain("Navigate     Tab Provider");
        await active.sendText("/models");
        await active.waitForText(selectedModel, TIMEOUT);

        await active.sendKeys("C-x");
        const mainAfterModelsResolve = await active.waitForPane(
          (pane) =>
            pane.includes("MAIN_MODELS_DRAFT") &&
            !pane.includes(selectedModel),
          TIMEOUT,
        );
        expect(mainAfterModelsResolve).toContain("MAIN_MODELS_DRAFT");
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_MODELS_READY", TIMEOUT);
        await active.sendText("/models");
        await active.waitForText(selectedModel, TIMEOUT);
        expect(gateway.requestCount()).toBe(requestCountBeforeModels);

        await active.sendKeys("C-j");
        await active.sendKeys("Enter");
        const configure = await active.waitForText("Configure child", TIMEOUT);
        expect(configure).toContain(selectedModel);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_MODELS_READY", TIMEOUT);
        expect(gateway.requestCount()).toBe(requestCountBeforeModels);

        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const controlPath = readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .find((path) => existsSync(path));
        if (!controlPath) throw new Error("child control record was not found");
        const control = JSON.parse(readFileSync(controlPath, "utf8")) as {
          configuration: { model?: string };
        };
        expect(control.configuration.model).toBe(selectedModel);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent child pointer drag replaces the selected composer range",
    async () => {
      const fixture = createFixture();
      const gateway = startDynamicFakeGateway(
        (body) => fakeGatewayFinalText(
          latestPrompt(body).includes("POINTER_CHILD_INITIAL")
            ? "CHILD_POINTER_READY"
            : "CHILD_POINTER_EDITED",
        ),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-pointer-selection",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 100,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "pointer-child");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "POINTER_CHILD_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_POINTER_READY", TIMEOUT);

        await active.sendLiteralText("abcdef");
        const pane = await active.waitForText("abcdef", TIMEOUT);
        const composerRow = pane
          .split("\n")
          .findIndex((line) => line.includes("abcdef")) + 1;
        expect(composerRow).toBeGreaterThan(0);

        await active.sendHexBytes(textHex(`\x1b[<0;4;${composerRow}M`));
        await Bun.sleep(50);
        await active.sendHexBytes(textHex(`\x1b[<32;7;${composerRow}M`));
        await Bun.sleep(50);
        await active.sendHexBytes(textHex(`\x1b[<0;7;${composerRow}m`));
        await Bun.sleep(50);
        await active.sendLiteralText("X");
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_POINTER_EDITED", TIMEOUT);

        expect(latestPrompt(gateway.requests.at(-1)!.body)).toContain("aXef");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent child executes skills locally and binds the selected skill",
    async () => {
      const fixture = createFixture();
      const childName = "child-local-skills";
      const childPrompt = "CHILD_LOCAL_SKILLS_INITIAL";
      const skillName = "child-local-skill";
      const skillDir = join(fixture.home, ".fx", "skills", skillName);
      mkdirSync(skillDir, { recursive: true });
      writeFileSync(
        join(skillDir, "SKILL.md"),
        [
          "---",
          `name: ${skillName}`,
          "description: A deterministic child chat skill.",
          "---",
          "",
          "Use this skill only for the selected-child catalog regression.",
          "",
        ].join("\n"),
      );
      const gateway = startDynamicFakeGateway((body) =>
        fakeGatewayFinalText(
          latestPrompt(body).includes("/skills")
            ? "CHILD_SKILLS_REACHED_MODEL"
            : "CHILD_LOCAL_SKILLS_READY",
        ), {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-local-skills",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 88,
          height: 24,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteralText("MAIN_SKILLS_DRAFT");
        await active.waitForText("MAIN_SKILLS_DRAFT", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, childPrompt);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_SKILLS_READY", TIMEOUT);

        const requestCountBeforeSkills = gateway.requestCount();
        await active.sendText("/skills");
        await active.waitForPane(
          (pane) => pane.includes("Skills 1") && pane.includes(skillName),
          TIMEOUT,
        );
        expect(gateway.requestCount()).toBe(requestCountBeforeSkills);
        expect(
          gateway.requests.some((request) =>
            latestPrompt(request.body).includes("/skills")
          ),
        ).toBe(false);

        await active.sendLiteralText("missing-child-skill-filter");
        await active.waitForText("No skills found.", TIMEOUT);
        await active.sendKeys("Escape");
        const escapedSkills = await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_LOCAL_SKILLS_READY") &&
            !pane.includes("Skills 1") &&
            !pane.includes("Esc Close") &&
            hasEmptyComposer(pane),
          TIMEOUT,
        );
        expect(escapedSkills).not.toContain("Navigate     Tab Source");
        await active.sendText("/skills");
        await active.waitForPane(
          (pane) => pane.includes("Skills 1") && pane.includes(skillName),
          TIMEOUT,
        );

        await active.sendKeys("C-x");
        const mainWithSkillsOpen = await active.waitForPane(
          (pane) =>
            pane.includes("MAIN_SKILLS_DRAFT") &&
            !pane.includes(skillName),
          TIMEOUT,
        );
        expect(mainWithSkillsOpen).toContain("MAIN_SKILLS_DRAFT");
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_LOCAL_SKILLS_READY", TIMEOUT);
        await active.sendText("/skills");
        await active.waitForPane(
          (pane) => pane.includes("Skills 1") && pane.includes(skillName),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const bound = await active.waitForPane(
          (pane) =>
            pane.includes(`┃ ${skillName}`) &&
            !pane.includes("Skills 1"),
          TIMEOUT,
        );
        expect(bound).toContain(`┃ ${skillName}`);
        expect(gateway.requestCount()).toBe(requestCountBeforeSkills);

        await active.sendKeys("C-x");
        const restoredMain = await active.waitForPane(
          (pane) =>
            pane.includes("MAIN_SKILLS_DRAFT") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        expect(restoredMain).not.toContain("ctrl+x manager");
        await active.sendKeys("C-u");
        await active.waitForPane(hasEmptyComposer, TIMEOUT);
        await active.sendKeys("C-l");
        const freshSession = await active.waitForPane(
          (pane) =>
            hasEmptyComposer(pane) &&
            !pane.includes("MAIN_SKILLS_DRAFT"),
          TIMEOUT,
        );
        expect(freshSession).not.toContain("ctrl+x manager");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "narrow child configuration keeps every focused control visible",
    async () => {
      const fixture = createFixture();
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("CHILD_NARROW_CONFIG_READY"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-narrow-config",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 60,
          height: 12,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "child-narrow-config");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CHILD_NARROW_CONFIG_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_NARROW_CONFIG_READY", TIMEOUT);

        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const controlPath = readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .find((path) => existsSync(path));
        if (!controlPath) throw new Error("child control record was not found");
        const completedValue = () =>
          (JSON.parse(readFileSync(controlPath, "utf8")) as {
            configuration: { notifications: { terminal: { completed: boolean } } };
          }).configuration.notifications.terminal.completed;
        const completedBefore = completedValue();

        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        await active.sendKeys("Escape");
        const escaped = await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_NARROW_CONFIG_READY") &&
            !pane.includes("Configure child"),
          TIMEOUT,
        );
        expect(escaped).not.toContain("Report interval:");
        expect(escaped).not.toContain("Permission mode:");
        expect(escaped).not.toContain("Notify completed:");

        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        const focusedLabels = [
          "Name:",
          "Model:",
          "Milestones",
          "Report interval",
          "Report duration",
          "Effort:",
          "Permission mode:",
          "Notify completed:",
        ];
        for (const [index, label] of focusedLabels.entries()) {
          if (index > 0) await active.sendKeys("Tab");
          const pane = await active.waitForPane(
            (value) => value.split("\n").some((line) =>
              line.startsWith("> ") && line.includes(label)
            ),
            TIMEOUT,
          );
          expect(pane).toContain("Configure child");
        }
        await active.sendLiteralText(" ");
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_NARROW_CONFIG_READY", TIMEOUT);
        expect(completedValue()).toBe(!completedBefore);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "configure duration derives its stop boundary and survives restart",
    async () => {
      const fixture = createFixture();
      const resumedStderrPath = join(root!, "duration-resumed.stderr");
      writeFileSync(resumedStderrPath, "");
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("DURATION_CHILD_READY"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      const env = {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: "duration-configuration-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      };

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        let active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "duration-worker");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "DURATION_CHILD_PROMPT");
        await active.sendKeys("Enter");
        await active.waitForText("DURATION_CHILD_READY", TIMEOUT);

        const controlPath = configurationControlPath(fixture);
        const initial = readConfigurationControl(controlPath);
        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "100");
        await active.sendKeys("Tab");
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "900");
        const durationForm = await active.waitForText(
          "Duration sets the stop boundary; clear duration to disable.",
          TIMEOUT,
        );
        expect(durationForm).not.toContain("Stop after duration:");
        await active.sendKeys("Enter");
        await active.waitForPane((pane) => !pane.includes("Configure child"), TIMEOUT);

        const withDuration = await waitForConfigurationControl(
          controlPath,
          (control) =>
            control.generation === initial.generation + 1 &&
            control.configuration.notifications.report_duration_ms === 900,
        );
        expect(withDuration.configuration.notifications).toMatchObject({
          report_interval_ms: 100,
          report_duration_ms: 900,
          stop_conditions: ["terminal", "duration_elapsed"],
        });
        expect(withDuration.operations).toHaveLength(initial.operations.length + 1);
        expect(withDuration.operations.at(-1)).toMatchObject({
          code: "configured",
          identity_source: "human",
          generation: initial.generation + 1,
        });

        await active.sendKeys("Tab");
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${withDuration.parent_id}`,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: resumedStderrPath,
        });
        active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) => pane.includes("duration-worker") && pane.includes("idle"),
          TIMEOUT,
        );
        expect(readConfigurationControl(controlPath)).toEqual(withDuration);

        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: duration-worker") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("C-u");
        const clearedForm = await active.waitForText(
          "Duration sets the stop boundary; clear duration to disable.",
          TIMEOUT,
        );
        expect(clearedForm).not.toContain("Stop after duration:");
        await active.sendKeys("Enter");
        await active.waitForPane((pane) => !pane.includes("Configure child"), TIMEOUT);

        const withoutDuration = await waitForConfigurationControl(
          controlPath,
          (control) =>
            control.generation === withDuration.generation + 1 &&
            control.configuration.notifications.report_duration_ms === null,
        );
        expect(withoutDuration.configuration.notifications).toMatchObject({
          report_interval_ms: 100,
          report_duration_ms: null,
          stop_conditions: ["terminal"],
        });
        expect(withoutDuration.operations).toHaveLength(
          withDuration.operations.length + 1,
        );
        expect(withoutDuration.operations.at(-1)).toMatchObject({
          code: "configured",
          identity_source: "human",
          generation: withDuration.generation + 1,
        });
        expect(readConfigurationControl(controlPath)).toEqual(withoutDuration);
        await active.sendKeys("Tab");
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "configure rejects a concurrent winner then retries the preserved draft once",
    async () => {
      const fixture = createFixture();
      const resumedStderrPath = join(root!, "configure-contention-resumed.stderr");
      writeFileSync(resumedStderrPath, "");
      let releaseExternal!: (response: Response) => void;
      let externalReleased = false;
      const externalResponse = new Promise<Response>((resolve) => {
        releaseExternal = (response) => {
          externalReleased = true;
          resolve(response);
        };
      });
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"external_configure"')) {
          return fakeGatewayFinalText("BACKGROUND_CONFIGURED");
        }
        if (body.includes("BACKGROUND_CONFIGURE")) return externalResponse;
        return fakeGatewayFinalText("STALE_CHILD_READY");
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: "configure-contention-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      };

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        let active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "stale-form-child");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "STALE_CHILD_PROMPT");
        await active.sendKeys("Enter");
        await active.waitForText("STALE_CHILD_READY", TIMEOUT);

        const controlPath = configurationControlPath(fixture);
        const initial = readConfigurationControl(controlPath);
        await active.sendKeys("Tab");
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("BACKGROUND_CONFIGURE");
        const requestStartedAt = Date.now();
        while (
          !gateway.requests.some((request) =>
            request.body.includes("BACKGROUND_CONFIGURE")
          ) && Date.now() - requestStartedAt < TIMEOUT
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) =>
          request.body.includes("BACKGROUND_CONFIGURE")
        )).toBe(true);

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("stale-form-child"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: stale-form-child") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendKeys("Tab");
        await active.sendLiteralText("s");
        await active.waitForText("Configure child", TIMEOUT);
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "tui-draft-final");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "tui-mark");
        await active.sendKeys("Tab");
        await active.sendKeys("C-u");
        await pasteVisibleText(active, "700");

        releaseExternal(fakeGatewayToolCall("external_configure", "subagent", {
          command: {
            configure: {
              id: initial.child_id,
              name: "external-winner",
              model: FAKE_GATEWAY_MODEL,
              effort: "high",
              permission_mode: "auto",
              notifications: {
                terminal: { completed: true, failed: true, cancelled: true },
                milestones: ["external-mark"],
                report_interval_ms: 900,
                stop_conditions: ["terminal"],
              },
            },
          },
        }));
        const external = await waitForConfigurationControl(
          controlPath,
          (control) =>
            control.generation === initial.generation + 1 &&
            control.configuration.name === "external-winner",
        );
        const refreshed = await active.waitForPane(
          (pane) =>
            pane.includes("Configure child") &&
            pane.includes("Effective/current name: external-winner") &&
            pane.includes("Name: tui-draft-final"),
          TIMEOUT,
        );
        expect(refreshed).toContain("Effective/current permission mode: auto");
        expect(external.operations).toHaveLength(initial.operations.length + 1);
        expect(external.operations.at(-1)).toMatchObject({
          code: "configured",
          identity_source: "model",
          generation: initial.generation + 1,
        });

        await active.sendKeys("Enter");
        const rejected = await active.waitForPane(
          (pane) =>
            pane.includes("Command failed: stale_generation (retryable)") &&
            pane.includes("Name: tui-draft-final") &&
            pane.includes("Effective/current name: external-winner"),
          TIMEOUT,
        );
        expect(rejected).toContain("Report interval ms: 700");
        expect(readConfigurationControl(controlPath)).toEqual(external);

        await active.sendKeys("Enter");
        await active.waitForPane((pane) => !pane.includes("Configure child"), TIMEOUT);
        const final = await waitForConfigurationControl(
          controlPath,
          (control) =>
            control.generation === external.generation + 1 &&
            control.configuration.name === "tui-draft-final",
        );
        expect(final.configuration).toMatchObject({
          name: "tui-draft-final",
          effort: "auto",
          permission_mode: "yolo",
          notifications: {
            milestones: ["tui-mark"],
            report_interval_ms: 700,
            report_duration_ms: null,
            stop_conditions: ["terminal"],
          },
        });
        expect(final.operations).toHaveLength(external.operations.length + 1);
        expect(final.operations.at(-1)).toMatchObject({
          code: "configured",
          identity_source: "human",
          generation: external.generation + 1,
        });

        await active.sendKeys("Tab");
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${final.parent_id}`,
          cwd: fixture.workspace,
          env,
          width: 96,
          height: 28,
          stderrPath: resumedStderrPath,
        });
        active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) => pane.includes("tui-draft-final") && pane.includes("idle"),
          TIMEOUT,
        );
        expect(readConfigurationControl(controlPath)).toEqual(final);
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      } finally {
        if (!externalReleased) {
          releaseExternal(fakeGatewayFinalText("BACKGROUND_CONFIGURE_CLEANUP"));
        }
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "persistent child preserves its reading position across both reopen paths",
    async () => {
      const fixture = createFixture();
      const childName = "child-position";
      const historyLines = Array.from(
        { length: 90 },
        (_, index) => `CHILD_POSITION_${String(index + 1).padStart(3, "0")}`,
      );
      const gateway = startDynamicFakeGateway(() =>
        fakeGatewayFinalText(historyLines.join("\n")), {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const visibleRange = (pane: string) => {
        const values = [...pane.matchAll(/CHILD_POSITION_(\d{3})/g)].map(
          (match) => Number.parseInt(match[1]!, 10),
        );
        return {
          min: Math.min(...values),
          max: Math.max(...values),
        };
      };

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-position",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 60,
          height: 12,
          stderrPath: fixture.stderrPath,
          minimumHistoryLines: 100_000,
          isolated: true,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CHILD_POSITION_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("CHILD_POSITION_090") &&
            pane.includes(`${childName} · idle`),
          TIMEOUT,
        );

        for (let index = 0; index < 5; index += 1) {
          const before = await active.capturePane();
          await active.sendKeys("PageUp");
          await active.waitForPane((pane) => pane !== before, TIMEOUT);
        }
        const beforeEscape = visibleRange(await active.capturePane());
        expect(beforeEscape.max).toBeLessThan(90);

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        const afterEscape = await active.waitForPane(
          (pane) => pane.includes("CHILD_POSITION_"),
          TIMEOUT,
        );
        expect(visibleRange(afterEscape)).toEqual(beforeEscape);

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        const afterCtrlX = await active.waitForPane(
          (pane) => pane.includes("CHILD_POSITION_"),
          TIMEOUT,
        );
        expect(visibleRange(afterCtrlX)).toEqual(beforeEscape);

        await active.sendKeys("C-o");
        await active.waitForPane(
          (pane) => pane.includes("CHILD_POSITION_"),
          TIMEOUT,
        );
        await active.sendKeys("Right");
        await active.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
        for (let index = 0; index < 5; index += 1) {
          const before = await active.capturePane();
          await active.sendKeys("PageUp");
          await active.waitForPane((pane) => pane !== before, TIMEOUT);
        }
        const beforeFullRoundTrip = visibleRange(await active.capturePane());
        expect(beforeFullRoundTrip.max).toBeLessThan(90);

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        const afterFullRoundTrip = await active.waitForPane(
          (pane) => pane.includes("CHILD_POSITION_"),
          TIMEOUT,
        );
        expect(visibleRange(afterFullRoundTrip)).toEqual(beforeFullRoundTrip);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "resizing an open persistent child preserves its draft and main scrollback",
    async () => {
      const fixture = createFixture();
      const childName = "child-resize";
      const draft = "CHILD_RESIZE_DRAFT";
      const mainLines = Array.from(
        { length: 160 },
        (_, index) => `MAIN_SCROLLBACK_${String(index + 1).padStart(3, "0")}`,
      );
      const gateway = startDynamicFakeGateway((body) =>
        body.includes("CHILD_RESIZE_INITIAL")
          ? fakeGatewayFinalText("CHILD_RESIZE_READY")
          : fakeGatewayFinalText(mainLines.join("\n")), {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-resize",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
          remainOnExit: true,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Fill the main transcript for resize isolation.");
        await active.waitForText("MAIN_SCROLLBACK_160", TIMEOUT);
        // Finished rows settle into native scrollback a frame after the final
        // marker paints, so wait for the settled capture instead of sampling
        // the instant the marker appears.
        const mainScrollbackBefore = await waitForFullScrollback(
          active,
          (scrollback) =>
            scrollback.includes("MAIN_SCROLLBACK_001") &&
            countOccurrences(scrollback, "MAIN_SCROLLBACK_") >= 150,
        );
        const mainLineCountBefore = countOccurrences(
          mainScrollbackBefore,
          "MAIN_SCROLLBACK_",
        );
        expect(mainScrollbackBefore).toContain("MAIN_SCROLLBACK_001");
        expect(mainLineCountBefore).toBeGreaterThanOrEqual(150);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CHILD_RESIZE_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForText("CHILD_RESIZE_READY", TIMEOUT);
        await active.pasteText(draft);
        await active.waitForText(draft, TIMEOUT);

        await active.resizeWindow(112, 34, 500);
        const resized = await active.waitForPane(
          (pane) => pane.includes(childName) && pane.includes(draft),
          TIMEOUT,
        );
        expect(resized).toContain("CHILD_RESIZE_READY");
        expect(active.paneStatus()).toEqual({ dead: false, status: null });
        expect(active.paneSize()).toEqual({ cols: 112, rows: 34 });

        await active.sendKeys("C-x");
        await active.waitForText("MAIN_SCROLLBACK_160", TIMEOUT);
        const mainScrollbackAfter = await waitForFullScrollback(
          active,
          (scrollback) =>
            scrollback.includes("MAIN_SCROLLBACK_001") &&
            countOccurrences(scrollback, "MAIN_SCROLLBACK_") >= mainLineCountBefore,
        );
        expect(mainScrollbackAfter).toContain("MAIN_SCROLLBACK_001");
        expect(countOccurrences(
          mainScrollbackAfter,
          "MAIN_SCROLLBACK_",
        )).toBeGreaterThanOrEqual(mainLineCountBefore);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "persistent children preserve independent unsent drafts across navigation and reopen paths",
    async () => {
      const fixture = createFixture();
      const childA = "child-draft-a";
      const childB = "child-draft-b";
      const mainDraft = "MAIN_DRAFT_PRESERVED";
      const draftA = "CHILD_A_DRAFT_LINE_ONE\nCHILD_A_DRAFT_LINE_TWO";
      const draftB = "CHILD_B_DRAFT_LINE_ONE\nCHILD_B_DRAFT_LINE_TWO";
      const gateway = startDynamicFakeGateway((body) =>
        fakeGatewayFinalText(
          body.includes("CHILD_DRAFT_A_INITIAL")
            ? "CHILD_DRAFT_A_READY"
            : "CHILD_DRAFT_B_READY",
        ), {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-draft",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 72,
          height: 16,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteralText(mainDraft);
        await active.waitForText(mainDraft, TIMEOUT);
        const mainCursor = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childA);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CHILD_DRAFT_A_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("CHILD_DRAFT_A_READY") && pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.pasteText(draftA);
        await active.waitForText("CHILD_A_DRAFT_LINE_TWO", TIMEOUT);
        const childACursor = active.cursorPosition();

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childB);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "CHILD_DRAFT_B_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("CHILD_DRAFT_B_READY") && pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.pasteText(draftB);
        await active.waitForText("CHILD_B_DRAFT_LINE_TWO", TIMEOUT);
        const childBCursor = active.cursorPosition();

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Up");
        await active.waitForPane(
          (pane) => pane.split("\n").some((line) =>
            line.startsWith("› ") && line.includes(childA)
          ),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const afterSiblingSwitch = await active.waitForText(
          "CHILD_A_DRAFT_LINE_TWO",
          TIMEOUT,
        );
        expect(afterSiblingSwitch).toContain("CHILD_A_DRAFT_LINE_ONE");
        expect(active.cursorPosition()).toEqual(childACursor);

        await active.sendKeys("Escape");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Down");
        await active.waitForPane(
          (pane) => pane.split("\n").some((line) =>
            line.startsWith("› ") && line.includes(childB)
          ),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const returnedToB = await active.waitForText(
          "CHILD_B_DRAFT_LINE_TWO",
          TIMEOUT,
        );
        expect(returnedToB).toContain("CHILD_B_DRAFT_LINE_ONE");
        expect(active.cursorPosition()).toEqual(childBCursor);

        await active.sendKeys("C-x");
        await active.waitForText(mainDraft, TIMEOUT);
        expect(active.cursorPosition()).toEqual(mainCursor);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        const afterCtrlX = await active.waitForText("CHILD_B_DRAFT_LINE_TWO", TIMEOUT);
        expect(afterCtrlX).toContain("CHILD_B_DRAFT_LINE_ONE");
        expect(active.cursorPosition()).toEqual(childBCursor);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "responses watched in a selected child remain read after both exit paths",
    async () => {
      const fixture = createFixture();
      const childName = "child-visible";
      const parentPrompt = "VISIBLE_CHILD_PARENT_SENDS_WHILE_CLOSED";
      const parentMessage = "VISIBLE_CHILD_UNREAD_BEFORE_OPEN";
      const parentCallId = "visible_child_parent_send";
      const preopenResponse = "VISIBLE_CHILD_PREOPEN_DONE";
      let childId: string | undefined;
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${parentCallId}"`)) {
          return fakeGatewayFinalText("VISIBLE_CHILD_PARENT_SEND_DONE");
        }
        if (body.includes(parentPrompt)) {
          if (!childId) throw new Error("visible child ID was not captured");
          return fakeGatewayToolCall(parentCallId, "subagent", {
            command: {
              message: {
                send: { id: childId, content: parentMessage },
              },
            },
          });
        }
        if (body.includes(parentMessage)) {
          return fakeGatewayFinalText(preopenResponse);
        }
        return fakeGatewayFinalText(
          body.includes("VISIBLE_CHILD_SECOND")
            ? "VISIBLE_CHILD_SECOND_DONE"
            : "VISIBLE_CHILD_INITIAL_DONE",
        );
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      const childLine = (pane: string) =>
        pane.split("\n").find((line) => line.includes(childName));
      const humanAcknowledgedSequence = () => {
        if (!childId) throw new Error("visible child ID was not captured");
        const record = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "communication.json",
          ),
          "utf8",
        )) as {
          ledger: {
            cursors: Array<{
              consumer_id: string;
              projection: string;
              acknowledged_sequence: number;
            }>;
          };
        };
        return record.ledger.cursors.find(
          (cursor) =>
            cursor.consumer_id === "subagent-manager-ui" &&
            cursor.projection === "human",
        )?.acknowledged_sequence ?? 0;
      };

      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "child-visible",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, childName);
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "VISIBLE_CHILD_INITIAL");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("VISIBLE_CHILD_INITIAL_DONE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        childId = (await active.capturePane()).match(
          /Subagent:\s+child-visible\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("visible child header did not expose its ID");

        await active.sendKeys("Escape");
        const afterEscape = await active.waitForPane((pane) => {
          const line = childLine(pane);
          return pane.includes("Agents & processes") &&
            line !== undefined &&
            !line.includes("unread");
        }, TIMEOUT);
        expect(childLine(afterEscape)).not.toContain("unread");

        await active.sendKeys("Enter");
        await active.waitForText("VISIBLE_CHILD_INITIAL_DONE", TIMEOUT);
        await active.sendText("VISIBLE_CHILD_SECOND");
        await active.waitForPane(
          (pane) =>
            pane.includes("VISIBLE_CHILD_SECOND_DONE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        const afterCtrlX = await active.waitForPane((pane) => {
          const line = childLine(pane);
          return pane.includes("Agents & processes") &&
            line !== undefined &&
            !line.includes("unread");
        }, TIMEOUT);
        expect(childLine(afterCtrlX)).not.toContain("unread");

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText(parentPrompt);
        await active.waitForText("VISIBLE_CHILD_PARENT_SEND_DONE", TIMEOUT);
        await active.sendKeys("C-x");
        const unreadBeforeOpen = await active.waitForPane((pane) => {
          const line = childLine(pane);
          return line !== undefined &&
            line.includes("idle") &&
            line.includes("unread");
        }, TIMEOUT);
        expect(childLine(unreadBeforeOpen)).toContain("unread");
        const acknowledgedBeforeOpen = humanAcknowledgedSequence();

        await active.sendKeys("Enter");
        await active.waitForText(preopenResponse, TIMEOUT);
        expect(humanAcknowledgedSequence()).toBe(acknowledgedBeforeOpen);
        await active.sendKeys("Escape");
        const readAfterPresentation = await active.waitForPane((pane) => {
          const line = childLine(pane);
          return pane.includes("Agents & processes") &&
            line !== undefined &&
            !line.includes("unread");
        }, TIMEOUT);
        expect(childLine(readAfterPresentation)).not.toContain("unread");
        expect(humanAcknowledgedSequence()).toBeGreaterThan(acknowledgedBeforeOpen);
        expect(gateway.requests).toHaveLength(5);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "two simultaneous child approvals keep one identity and advance across both surfaces",
    async () => {
      const fixture = createFixture();
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const firstMarker = join(fixture.workspace, "child-approval-first.txt");
      const secondMarker = join(fixture.workspace, "child-approval-second.txt");
      const firstPrompt = "CHECKPOINT2_FIRST_SIMULTANEOUS_APPROVAL";
      const secondPrompt = "CHECKPOINT2_SECOND_SIMULTANEOUS_APPROVAL";
      const firstCallId = "checkpoint2_first_simultaneous_effect";
      const secondCallId = "checkpoint2_second_simultaneous_effect";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${firstCallId}"`)) {
          return fakeGatewayFinalText("CHECKPOINT2_FIRST_APPROVAL_COMPLETE");
        }
        if (body.includes(`"toolCallId":"${secondCallId}"`)) {
          return fakeGatewayFinalText("CHECKPOINT2_SECOND_APPROVAL_COMPLETE");
        }
        if (body.includes(firstPrompt)) {
          return fakeGatewayToolCall(firstCallId, "terminal", {
            action: "exec",
            command: `printf first > ${JSON.stringify(firstMarker)}`,
          });
        }
        if (body.includes(secondPrompt)) {
          return fakeGatewayToolCall(secondCallId, "terminal", {
            action: "exec",
            command: `printf second > ${JSON.stringify(secondMarker)}`,
          });
        }
        return fakeGatewayFinalText("unexpected simultaneous approval request");
      }, {
        classifierDecision: "ask",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-two-simultaneous-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 160,
          height: 28,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteralText("SIMULTANEOUS_APPROVAL_MAIN_COMPOSER");
        await active.waitForText("SIMULTANEOUS_APPROVAL_MAIN_COMPOSER", TIMEOUT);
        const mainCursor = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "approval-first");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, firstPrompt);
        for (let index = 0; index < 5; index += 1) await active.sendKeys("Tab");
        await active.sendLiteralText(" ");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("approval-first") && pane.includes("status: approval"),
          TIMEOUT,
        );

        await active.sendKeys("C-x");
        await active.waitForText(
          "Subagent approval-first needs permission",
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "approval-second");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, secondPrompt);
        for (let index = 0; index < 5; index += 1) await active.sendKeys("Tab");
        await active.sendLiteralText(" ");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("approval-second") && pane.includes("status: approval"),
          TIMEOUT,
        );

        await active.sendKeys("C-x");
        const firstMain = await active.waitForText(
          "Subagent approval-first needs permission",
          TIMEOUT,
        );
        expect(firstMain).toContain("Command");
        expect(firstMain).toContain("$ # terminal.exec profile=user shell=");
        expect(firstMain).toContain("printf first >");

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: approval-second") &&
            pane.includes("status: approval"),
          TIMEOUT,
        );
        await active.sendKeys("C-o");
        await active.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
        await active.sendKeys("PageUp");
        expect(await active.capturePane()).toContain("Review · ←/→ switch · ctrl o close");
        await active.sendKeys("Escape");
        await active.waitForText("Subagent: approval-second", TIMEOUT);
        await active.sendKeys("C-o");
        await active.waitForText("Review · ←/→ switch · ctrl o close", TIMEOUT);
        await active.sendKeys("Right");
        await active.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
        await active.sendKeys("PageDown");
        expect(await active.capturePane()).toContain("Full detail · ←/→ switch · ctrl o close");
        await active.sendKeys("C-c");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: approval-second") &&
            pane.includes("status: approval"),
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        await active.waitForText(
          "Subagent approval-first needs permission",
          TIMEOUT,
        );

        await active.sendKeys("C-x");
        await active.waitForText(
          "Notification: approval-first approval pending",
          TIMEOUT,
        );
        await active.sendLiteralText("n");
        const firstDetails = await active.waitForText(
          "Approval — approval-first",
          TIMEOUT,
        );
        const firstRequestId = firstDetails.match(/Approval ID:\s+([^\s]+)/)?.[1];
        if (!firstRequestId) throw new Error("first approval detail did not expose its ID");
        await active.sendKeys("C-x");
        await active.waitForText(
          "Subagent approval-first needs permission",
          TIMEOUT,
        );
        await active.sendLiteralText("1");

        const secondMain = await active.waitForText(
          "Subagent approval-second needs permission",
          TIMEOUT,
        );
        expect(secondMain).toContain("Command");
        expect(secondMain).toContain("$ # terminal.exec profile=user shell=");
        expect(secondMain).toContain("printf second >");

        await active.sendKeys("C-x");
        await active.waitForText(
          "Notification: approval-second approval pending",
          TIMEOUT,
        );
        await active.sendLiteralText("n");
        const secondDetails = await active.waitForText(
          "Approval — approval-second",
          TIMEOUT,
        );
        const secondRequestId = secondDetails.match(/Approval ID:\s+([^\s]+)/)?.[1];
        if (!secondRequestId) throw new Error("second approval detail did not expose its ID");
        expect(secondRequestId).not.toBe(firstRequestId);
        await active.sendLiteralText("1");
        await active.waitForPane(
          (pane) =>
            pane.split("\n").some((line) =>
              line.includes("approval-first") && line.includes("idle")
            ) && pane.split("\n").some((line) =>
              line.includes("approval-second") && line.includes("idle")
            ),
          TIMEOUT,
        );
        expect(readFileSync(firstMarker, "utf8")).toBe("first");
        expect(readFileSync(secondMarker, "utf8")).toBe("second");

        await active.sendKeys("C-x");
        const restored = await active.waitForText(
          "SIMULTANEOUS_APPROVAL_MAIN_COMPOSER",
          TIMEOUT,
        );
        expect(restored).not.toContain("Agents & processes");
        expect(restored).not.toContain("approval pending");
        expect(active.cursorPosition()).toEqual(mainCursor);
        expect(gateway.classifierRequests).toHaveLength(0);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "assembled TTY tree keeps persistent configuration and hides settled one-offs",
    async () => {
      const fixture = createFixture();
      const persistentPrompt = "CHECKPOINT3_PERSISTENT_CREATES_NESTED";
      const nestedPrompt = "CHECKPOINT3_NESTED_ONE_OFF";
      const oneOffPrompt = "CHECKPOINT3_ROOT_ONE_OFF";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"checkpoint3_nested_create"')) {
          return fakeGatewayFinalText("CHECKPOINT3_PERSISTENT_COMPLETE");
        }
        if (body.includes('"toolCallId":"checkpoint3_root_one_off"')) {
          return fakeGatewayFinalText("CHECKPOINT3_ASSEMBLED_PARENT_COMPLETE");
        }
        if (body.includes('"toolCallId":"checkpoint3_root_persistent"')) {
          return fakeGatewayToolCall("checkpoint3_root_one_off", "subagent", {
            command: {
              create: {
                name: "assembled-one-off",
                mode: "one_off",
                prompt: oneOffPrompt,
                notifications: { stop_conditions: ["terminal"] },
              },
            },
          });
        }
        if (body.includes(nestedPrompt) && !body.includes(persistentPrompt)) {
          return fakeGatewayFinalText("CHECKPOINT3_NESTED_COMPLETE");
        }
        if (body.includes(oneOffPrompt)) {
          return fakeGatewayFinalText("CHECKPOINT3_ONE_OFF_COMPLETE");
        }
        if (body.includes(persistentPrompt)) {
          return fakeGatewayToolCall("checkpoint3_nested_create", "subagent", {
            command: {
              create: {
                name: "assembled-nested",
                mode: "one_off",
                prompt: nestedPrompt,
              },
            },
          });
        }
        return fakeGatewayToolCall("checkpoint3_root_persistent", "subagent", {
          command: {
            create: {
              name: "assembled-persistent",
              mode: "persistent",
              prompt: persistentPrompt,
              notifications: {
                milestones: ["assembled-checkpoint"],
                report_interval_ms: 1000,
                report_duration_ms: 250,
                stop_conditions: ["terminal"],
              },
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-assembled-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Build the checkpoint three assembled tree.");
        await active.waitForText("CHECKPOINT3_ASSEMBLED_PARENT_COMPLETE", TIMEOUT);
        await active.sendKeys("C-x");
        const tree = await active.waitForPane(
          (pane) =>
            pane.includes("assembled-persistent") &&
            pane.includes("idle") &&
            !pane.includes("assembled-one-off") &&
            !pane.includes("assembled-nested"),
          TIMEOUT,
        );
        expect(tree).toContain("Agents & processes");
        expect(tree).not.toContain("assembled-one-off");
        expect(tree).not.toContain("assembled-nested");

        type Control = {
          child_id: string;
          parent_id: string;
          mode: "persistent" | "one_off";
          state: string;
          configuration: {
            name: string;
            notifications: { milestones: string[]; stop_conditions: string[] };
          };
          queue: Array<{ content: string; status: string }>;
        };
        const sessionsDir = join(fixture.home, ".fx", "sessions");
        const readControls = () => readdirSync(sessionsDir)
          .map((id) => join(sessionsDir, id, "subagent", "control.json"))
          .filter((path) => existsSync(path))
          .map((path) => JSON.parse(readFileSync(path, "utf8")) as Control);
        let persistent: Control | undefined;
        const controlsDeadline = Date.now() + TIMEOUT;
        while (Date.now() < controlsDeadline) {
          persistent = readControls().find(
            (control) => control.configuration.name === "assembled-persistent" &&
              control.state === "idle",
          );
          if (persistent) break;
          await Bun.sleep(25);
        }
        if (!persistent) throw new Error("assembled persistent control did not settle");
        expect(persistent!.mode).toBe("persistent");
        expect(persistent!.state).toBe("idle");
        expect(persistent!.configuration.notifications).toMatchObject({
          milestones: ["assembled-checkpoint"],
          stop_conditions: ["terminal", "duration_elapsed"],
        });

        await active.sendKeys("Enter");
        const persistentChat = await active.waitForPane(
          (pane) =>
            pane.includes("assembled-persistent") &&
            pane.includes(persistent!.child_id) &&
            pane.includes("status: idle") &&
            pane.includes("CHECKPOINT3_PERSISTENT_COMPLETE"),
          TIMEOUT,
        );
        expect(persistentChat).toContain(`Parent: ${persistent!.parent_id}`);
        for (const request of gateway.requests) {
          expect(request.body).toContain('"name":"subagent"');
          expect(request.body).not.toContain('"name":"task"');
        }
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    120_000,
  );

  test(
    "manager cancel preserves a persistent child chat and returns it idle",
    async () => {
      const fixture = createFixture();
      const childPrompt = "CHECKPOINT3_MANAGER_CANCEL_ACTIVE";
      const childStream = controlledTextResponse("CHECKPOINT3_CANCEL_STREAM_\n");
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"checkpoint3_cancel_create"')) {
          return fakeGatewayFinalText("CHECKPOINT3_CANCEL_PARENT_READY");
        }
        if (body.includes(childPrompt)) return childStream.response;
        return fakeGatewayToolCall("checkpoint3_cancel_create", "subagent", {
          command: {
            create: {
              name: "manager-cancel-child",
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "checkpoint-three-cancel-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 104,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the active cancellation fixture.");
        await active.waitForText("CHECKPOINT3_CANCEL_PARENT_READY", TIMEOUT);
        const childStartedAt = Date.now();
        while (
          !gateway.requests.some((request) => request.body.includes(childPrompt)) &&
          Date.now() - childStartedAt < TIMEOUT
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) => request.body.includes(childPrompt))).toBe(true);
        await active.sendLiteralText("CHECKPOINT3_CANCEL_MAIN_COMPOSER");
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("manager-cancel-child") &&
            pane.includes("running"),
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        const restoredMain = await active.waitForPane(
          (pane) =>
            pane.includes("CHECKPOINT3_CANCEL_MAIN_COMPOSER") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        expect(restoredMain).not.toContain("ctrl+x manager");
        const mainGrid = await active.capturePaneGrid();
        const mainCursor = active.cursorPosition();

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("manager-cancel-child") &&
            pane.includes("running"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const running = await active.waitForPane(
          (pane) =>
            pane.includes("manager-cancel-child") &&
            pane.includes("status: running") &&
            pane.includes("running") &&
            pane.includes("CHECKPOINT3_CANCEL_STREAM_"),
          TIMEOUT,
        );
        const childId = running.match(
          /manager-cancel-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("cancel child did not expose its ID");

        await active.sendKeys("Tab");
        await active.sendLiteralText("x");
        await active.waitForText("Actions — manager-cancel-child", TIMEOUT);
        await active.sendLiteralText("c");
        const cancelled = await active.waitForPane(
          (pane) =>
            pane.includes("manager-cancel-child") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(cancelled).toContain("CHECKPOINT3_CANCEL_STREAM_");
        const control = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "control.json",
          ),
          "utf8",
        )) as { state: string; queue: Array<{ content: string; status: string }> };
        expect(control.state).toBe("idle");
        expect(control.queue).toEqual([
          expect.objectContaining({ content: childPrompt, status: "cancelled" }),
        ]);
        expect(gateway.requests.filter((request) =>
          request.body.includes(childPrompt) &&
          !request.body.includes('"toolCallId":"checkpoint3_cancel_create"')
        )).toHaveLength(1);

        await active.sendKeys("C-x");
        await active.waitForText("CHECKPOINT3_CANCEL_MAIN_COMPOSER", TIMEOUT);
        expect(await active.capturePaneGrid()).toEqual(mainGrid);
        expect(active.cursorPosition()).toEqual(mainCursor);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        if (!childStream.released()) {
          try {
            childStream.release("CLEANUP");
          } catch {}
        }
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "host shutdown releases a blocked approval waiter and recovers it stale",
    async () => {
      const fixture = createFixture();
      const resumedStderrPath = join(root!, "approval-shutdown-resumed.stderr");
      writeFileSync(resumedStderrPath, "");
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      const marker = join(fixture.workspace, "cancelled-approval-effect.txt");
      const parentPrompt = "CANCEL_BLOCKED_APPROVAL_PARENT";
      const childPrompt = "CANCEL_BLOCKED_APPROVAL_CHILD";
      const parentCallId = "cancel_blocked_approval_create";
      const childCallId = "cancel_blocked_approval_effect";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes(`"toolCallId":"${parentCallId}"`)) {
          return fakeGatewayFinalText("CANCEL_BLOCKED_APPROVAL_PARENT_READY");
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall(childCallId, "terminal", {
            action: "exec",
            command: "printf denied > cancelled-approval-effect.txt",
          });
        }
        return fakeGatewayToolCall(parentCallId, "subagent", {
          command: {
            create: {
              name: "approval-cancel-child",
              mode: "persistent",
              prompt: childPrompt,
              permission_mode: "ask",
            },
          },
        });
      }, {
        classifierDecision: "ask",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "cancel-blocked-approval-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText(parentPrompt);
        await active.waitForText(
          "Subagent approval-cancel-child needs permission",
          TIMEOUT,
        );

        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("approval-cancel-child") &&
            pane.includes("approval"),
          TIMEOUT,
        );
        await active.sendKeys("Enter");
        const blocked = await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: approval-cancel-child") &&
            pane.includes("status: approval") &&
            pane.includes("Subagent approval-cancel-child needs permission") &&
            pane.includes("Command") &&
            pane.includes("$ # terminal.exec profile=user shell=") &&
            pane.includes("printf denied > cancelled-approval-effect.txt") &&
            pane.includes("❯ 1. Yes"),
          TIMEOUT,
        );
        const childId = blocked.match(
          /approval-cancel-child\s+·\s+([^\s]+)/,
        )?.[1];
        if (!childId) throw new Error("approval child did not expose its ID");
        const requestCountBeforeShutdown = gateway.requests.length;
        const targetPid = active.processPid();
        expect(Number.isInteger(targetPid)).toBe(true);
        process.kill(targetPid, "SIGTERM");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        expect(gateway.requests).toHaveLength(requestCountBeforeShutdown);
        expect(existsSync(marker)).toBe(false);
        const control = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "control.json",
          ),
          "utf8",
        )) as {
          parent_id: string | null;
          state: string;
          queue: Array<{ status: string }>;
        };
        expect(control.state).toBe("awaiting_approval");
        expect(control.queue).toEqual([
          expect.objectContaining({ status: "awaiting_approval" }),
        ]);
        const communication = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "communication.json",
          ),
          "utf8",
        )) as { ledger: { approvals: Array<{ status: string }> } };
        expect(communication.ledger.approvals).toEqual([
          expect.objectContaining({ status: "pending" }),
        ]);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

        if (!control.parent_id) throw new Error("approval child lost its root");
        session = await TmuxSession.create({
          cmd: `${FX_BIN} resume ${control.parent_id}`,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "cancel-blocked-approval-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 120,
          height: 36,
          stderrPath: resumedStderrPath,
        });
        const resumed = session;
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendKeys("C-x");
        await resumed.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("approval-cancel-child") &&
            pane.includes("interrupted"),
          TIMEOUT,
        );
        const recoveredControl = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "control.json",
          ),
          "utf8",
        )) as { state: string; queue: Array<{ status: string }> };
        expect(recoveredControl.state).toBe("interrupted");
        expect(recoveredControl.queue).toEqual([
          expect.objectContaining({ status: "interrupted" }),
        ]);
        const recoveredCommunication = JSON.parse(readFileSync(
          join(
            fixture.home,
            ".fx",
            "sessions",
            childId,
            "subagent",
            "communication.json",
          ),
          "utf8",
        )) as { ledger: { approvals: Array<{ status: string }> } };
        expect(recoveredCommunication.ledger.approvals).toEqual([
          expect.objectContaining({ status: "stale" }),
        ]);
        expect(gateway.requests).toHaveLength(requestCountBeforeShutdown);
        expect(readFileSync(resumedStderrPath, "utf8")).toBe("");

        await resumed.sendKeys("C-x");
        await resumed.waitForComposer(TIMEOUT);
        await resumed.sendText("/quit");
        expect(await resumed.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "selected child renders provider route recovery status",
    async () => {
      const fixture = createFixture();
      const tapePath = join(root!, "selected-child-route-recovery.fxtape");
      const childPrompt = "SELECTED_CHILD_ROUTE_RECOVERY";
      const finalText = "SELECTED_CHILD_RECOVERED";
      const retryText = "⚠ Provider unavailable · provider_error: selected child route failed once";
      let childRequests = 0;
      let releaseProviderError!: (response: Response) => void;
      const providerError = new Promise<Response>((resolve) => {
        releaseProviderError = resolve;
      });
      let releaseChild!: (response: Response) => void;
      const childCompletion = new Promise<Response>((resolve) => {
        releaseChild = resolve;
      });
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"selected_child_create"')) {
          return fakeGatewayFinalText("SELECTED_CHILD_PARENT_COMPLETE");
        }
        if (body.includes(childPrompt)) {
          childRequests += 1;
          if (childRequests === 1) return providerError;
          return childCompletion;
        }
        return fakeGatewayToolCall("selected_child_create", "subagent", {
          command: {
            create: {
              name: "route-child",
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "selected-child-route-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            NO_COLOR: "1",
          },
          width: 90,
          height: 24,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the route recovery child fixture.");

        const startedAt = Date.now();
        while (childRequests < 1 && Date.now() - startedAt < TIMEOUT) {
          await Bun.sleep(25);
        }
        expect(childRequests).toBe(1);

        await active.sendKeys("C-x");
        await active.waitForText("route-child", TIMEOUT);
        await active.sendKeys("Enter");
        await active.waitForText(childPrompt, TIMEOUT);

        releaseProviderError(providerErrorResponse("selected child route failed once"));
        const recoveryStartedAt = Date.now();
        let recordedOutput = "";
        while (Date.now() - recoveryStartedAt < TIMEOUT) {
          recordedOutput = stdoutFrames(tapePath)
            .map((frame) => frame.payload)
            .join("");
          if (recordedOutput.includes(retryText)) break;
          await Bun.sleep(25);
        }
        expect(recordedOutput).toContain(retryText);
        expect(recordedOutput).toContain("route-child");

        releaseChild(fakeGatewayFinalText(finalText));
        await active.waitForText(finalText, TIMEOUT);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    60_000,
  );

  test(
    "selected child chat renders history and queues bracketed Unicode human messages without disturbing main chat",
    async () => {
      const fixture = createFixture();
      const tapePath = join(root!, "selected-child-live.fxtape");
      const childPrompt = "CHILD1";
      const childToolPath = "child-ui-parity.txt";
      writeFileSync(
        join(fixture.workspace, childToolPath),
        "child UI parity fixture\n",
      );
      const humanOneLines = ["HUMAN1_🦎", "line-two", "[]{}"];
      const humanOne = humanOneLines.join("\n");
      const humanTwo = "HUMAN2";
      const childStream = controlledTextResponse("MANAGER_CHILD_LIVE_\n");
      const humanOneStream = controlledTextResponse("MANAGER_HUMAN_ONE_LIVE_\n");
      const humanTwoStream = controlledTextResponse("MANAGER_HUMAN_TWO_LIVE_\n");
      let releaseParent!: (response: Response) => void;
      let parentReleased = false;
      let authoritativeChildId: string | undefined;
      const parentCompletion = new Promise<Response>((resolve) => {
        releaseParent = (response) => {
          parentReleased = true;
          resolve(response);
        };
      });
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"manager_archive_1"')) {
          return fakeGatewayFinalText("MANAGER_PARENT_COMPLETE");
        }
        if (body.includes('"toolCallId":"manager_create_1"')) return parentCompletion;
        if (body.includes('"toolCallId":"manager_child_read_1"')) {
          return humanTwoStream.response;
        }
        if (body.includes(humanTwo)) {
          return fakeGatewayToolCall("manager_child_read_1", "read_file", {
            path: childToolPath,
          });
        }
        if (body.includes(humanOneLines[0]!)) return humanOneStream.response;
        if (body.includes(childPrompt)) return childStream.response;
        return fakeGatewayToolCall("manager_create_1", "subagent", {
          command: {
            create: {
              name: "live-child",
              mode: "persistent",
              prompt: childPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "manager-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_RECORD: tapePath,
            NO_COLOR: "1",
          },
          width: 90,
          height: 24,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the live manager fixture.");
        const startedAt = Date.now();
        while (gateway.requestCount() < 3 && Date.now() - startedAt < TIMEOUT) {
          await Bun.sleep(25);
        }
        expect(gateway.requestCount()).toBeGreaterThanOrEqual(3);

        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendKeys("C-x");
        const restoredMain = await active.waitForPane(
          (pane) =>
            pane.includes("Create the live manager fixture.") &&
            !pane.includes("Agents & processes"),
          TIMEOUT,
        );
        expect(restoredMain).not.toContain("ctrl+x manager");
        const mainGridBeforeManager = await active.capturePaneGrid();
        const mainCursorBeforeManager = active.cursorPosition();
        await active.sendKeys("C-x");
        const rootView = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.split("\n").some((line) =>
              line.startsWith("› ") &&
              line.includes("live-child") &&
              line.includes("running")
            ),
          TIMEOUT,
        );
        expect(rootView).toContain("running");
        await active.sendKeys("Enter");
        const detail = await active.waitForPane(
          (pane) =>
            pane.includes("Subagent") &&
            pane.includes("live-child") &&
            pane.includes("MANAGER_CHILD_LIVE_"),
          TIMEOUT,
        );
        const childId = detail.match(/live-child\s+·\s+([^\s]+)/)?.[1];
        if (!childId) throw new Error("child chat did not expose the immutable child ID");
        authoritativeChildId = childId;
        expect(detail).toContain("Parent:");
        expect(detail).toContain("Mode: persistent");
        expect(detail).toContain("status: running");
        expect(detail).toContain("busy: yes");
        expect(detail).toContain("Model:");
        expect(detail).toContain("effort:");
        expect(detail).not.toContain("Source:");
        expect(detail).not.toContain("Enter Send");
        expect(detail).not.toContain("Subagent live-child  •  status:");
        expect(detail).not.toContain("Context:");
        expect(detail).toContain(FAKE_GATEWAY_MODEL);

        await active.sendKeys("Escape");
        const streamingRoot = await active.waitForPane(
          (pane) =>
            pane.includes("Agents & processes") &&
            pane.includes("live-child") &&
            pane.includes("running") &&
            pane.includes("r archives"),
          TIMEOUT,
        );
        expect(streamingRoot).not.toContain("Interrupted by User");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => pane.includes("Subagent") && pane.includes(childId),
          TIMEOUT,
        );

        const requestsBeforePaste = gateway.requestCount();
        await active.pasteText(humanOne);
        await Bun.sleep(300);
        const pastedDraft = await active.capturePane();
        for (const line of humanOneLines) expect(pastedDraft).toContain(line);
        expect(gateway.requestCount()).toBe(requestsBeforePaste);
        await active.sendKeys("Enter");
        const queuedOne = await active.waitForPane(
          (pane) =>
            humanOneLines.every((line) => pane.includes(line)) &&
            pane.includes("[pending]") &&
            pane.includes("status: running"),
          TIMEOUT,
        );
        expect(queuedOne).toContain("MANAGER_CHILD_LIVE_");

        childStream.release("UPDATE_COMPLETE");
        const runningOne = await active.waitForPane(
          (pane) =>
            pane.includes(childPrompt) &&
            pane.includes("MANAGER_CHILD_LIVE_") &&
            pane.includes("UPDATE_COMPLETE") &&
            pane.includes("MANAGER_HUMAN_ONE_LIVE_") &&
            pane.includes("running"),
          TIMEOUT,
        );
        for (const line of humanOneLines) expect(runningOne).toContain(line);
        expect(runningOne).not.toContain("MANAGER_CHILD_LIVE_\\x0aUPDATE_COMPLETE");
        const runningLines = runningOne.split("\n");
        const liveLine = runningLines.findIndex((line) =>
          line.includes("MANAGER_CHILD_LIVE_")
        );
        const completionLine = runningLines.findIndex((line) =>
          line.includes("UPDATE_COMPLETE")
        );
        expect(liveLine).toBeGreaterThanOrEqual(0);
        expect(completionLine).toBeGreaterThan(liveLine);

        await active.sendLiteralText(humanTwo);
        await active.sendKeys("Enter");
        const queuedTwo = await active.waitForPane(
          (pane) =>
            pane.includes(`┃ ${humanTwo}`) &&
            pane.includes("[pending]") &&
            pane.includes("MANAGER_HUMAN_ONE_LIVE_"),
          TIMEOUT,
        );
        expect(queuedTwo).toContain("running");

        humanOneStream.release("COMPLETE");
        const humanTwoStartedAt = Date.now();
        while (
          !gateway.requests.some((request) => request.body.includes(humanTwo)) &&
          Date.now() - humanTwoStartedAt < TIMEOUT
        ) {
          await Bun.sleep(25);
        }
        expect(gateway.requests.some((request) => request.body.includes(humanTwo))).toBe(true);
        const liveTool = await active.waitForPane(
          (pane) =>
            pane.includes("● 1 tool call · 1 read") &&
            pane.includes(`└ Reading ${childToolPath}`) &&
            pane.includes("MANAGER_HUMAN_TWO_LIVE_"),
          TIMEOUT,
        );
        expect(liveTool).not.toContain("Context:");
        const stableLiveStart = stdoutFrames(tapePath).length;
        await Bun.sleep(1_200);
        const stableLiveFrames = stdoutFrames(tapePath).slice(stableLiveStart);
        expect(
          stableLiveFrames.filter((frame) => frame.payload.length >= 1_024),
        ).toHaveLength(0);
        expect(
          stableLiveFrames.reduce((total, frame) => total + frame.payload.length, 0),
        ).toBeLessThan(8_192);
        humanTwoStream.release("COMPLETE");
        const completed = await active.waitForPane(
          (pane) =>
            pane.includes("MANAGER_HUMAN_TWO_LIVE_") &&
            pane.includes(`└ Read ${childToolPath}`) &&
            !pane.includes("running"),
          TIMEOUT,
        );
        for (const line of humanOneLines) expect(completed).toContain(line);
        expect(completed).toContain(humanTwo);
        expect(completed).toContain(`┃ ${humanOneLines[0]}`);
        expect(completed).toContain("live-child · idle ·");
        expect(completed).not.toContain("Enter Send");
        expect(completed).not.toContain("Source:");
        expect(completed).not.toContain("Subagent live-child  •  status:");
        expect(completed).toContain("● 1 tool call · 1 read");
        expect(completed).toContain(`└ Read ${childToolPath}`);
        expect(completed.match(/MANAGER_HUMAN_ONE_LIVE_/g)).toHaveLength(1);
        expect(completed.match(/MANAGER_HUMAN_TWO_LIVE_/g)).toHaveLength(1);
        const settledChildGrid = await active.capturePaneGrid();
        expect(settledChildGrid.join("\n")).not.toContain("child UI parity fixture");

        await active.sendKeys("C-o");
        const fullChild = await active.waitForPane(
          (pane) =>
            pane.includes("child UI parity fixture") &&
            pane.includes(`Read ${childToolPath}`),
          TIMEOUT,
        );
        expect(fullChild).not.toContain("Create the live manager fixture.");
        await active.sendKeys("Right");
        await active.waitForText("Full detail · ←/→ switch · ctrl o close", TIMEOUT);
        const fullChildGrid = await active.capturePaneGrid();
        expect(fullChildGrid).not.toEqual(settledChildGrid);
        await active.sendHexBytes(["1b", "5b", "35", "7e"]);
        await active.waitForPane(
          (pane) =>
            pane.includes("Parent agent") &&
            !pane.includes("MANAGER_HUMAN_TWO_LIVE_"),
          TIMEOUT,
        );
        expect(await active.capturePaneGrid()).not.toEqual(fullChildGrid);
        await active.sendHexBytes(["1b", "5b", "36", "7e"]);
        await active.waitForText("MANAGER_HUMAN_TWO_LIVE_", TIMEOUT);
        await active.sendKeys("C-o");
        await active.waitForPane(
          (pane) =>
            pane.includes("MANAGER_HUMAN_TWO_LIVE_") &&
            !pane.includes("child UI parity fixture") &&
            !pane.includes("Full detail ·"),
          TIMEOUT,
        );
        expect(await active.capturePaneGrid()).toEqual(settledChildGrid);

        await active.sendHexBytes(["1b", "5b", "35", "7e"]);
        const scrolled = await active.waitForPane(
          (pane) =>
            pane.includes("Mode: persistent") &&
            !pane.includes("MANAGER_HUMAN_TWO_LIVE_"),
          TIMEOUT,
        );
        expect(scrolled).not.toContain("Context:");
        expect(scrolled).not.toContain("Source:");
        expect(scrolled).not.toContain("Enter Send");
        await active.sendHexBytes(["1b", "5b", "36", "7e"]);
        await active.waitForText("MANAGER_HUMAN_TWO_LIVE_", TIMEOUT);

        await active.sendKeys("Escape");
        await active.waitForPane(
          (pane) => pane.includes("Agents & processes") && pane.includes("r archives"),
          TIMEOUT,
        );
        const idleReopenFrameStart = stdoutFrames(tapePath).length;
        await active.sendKeys("Enter");
        await active.waitForText("MANAGER_HUMAN_TWO_LIVE_", TIMEOUT);
        await Bun.sleep(1_500);
        const idleReopenFrames = stdoutFrames(tapePath).slice(idleReopenFrameStart);
        const identityFrameAllowance = Buffer.byteLength(fixture.workspace) +
          Buffer.byteLength(" · ");
        expect(
          idleReopenFrames.filter(
            (frame) => frame.payload.length >= 1_024 + identityFrameAllowance,
          ),
        ).toHaveLength(0);
        expect(
          idleReopenFrames.reduce((total, frame) => total + frame.payload.length, 0),
        ).toBeLessThan(8_192);
        expect(await active.capturePaneGrid()).toEqual(settledChildGrid);
        await active.sendKeys("Escape");
        await active.waitForPane(
          (pane) => pane.includes("Agents & processes") && pane.includes("r archives"),
          TIMEOUT,
        );
        await active.sendLiteralText("a");
        const activity = await active.waitForText("Activity — live-child", TIMEOUT);
        expect(activity).toContain(childId);
        await active.sendKeys("Escape");
        await active.waitForPane(
          (pane) => pane.includes("r archives") && !pane.includes("Activity —"),
          TIMEOUT,
        );
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) => !pane.includes("Agents & processes") && pane.includes("Create the live manager fixture."),
          TIMEOUT,
        );
        expect(normalizeThinkingFrame(await active.capturePaneGrid())).toEqual(
          normalizeThinkingFrame(mainGridBeforeManager),
        );
        expect(active.cursorPosition()).toEqual(mainCursorBeforeManager);
        releaseParent(fakeGatewayToolCall("manager_archive_1", "subagent", {
          command: {
            lifecycle: {
              id: authoritativeChildId!,
              action: "close",
            },
          },
        }));
        await active.waitForText("MANAGER_PARENT_COMPLETE", TIMEOUT);

        await active.sendKeys("C-x");
        const activeTree = await active.waitForText("Agents & processes", TIMEOUT);
        expect(activeTree).not.toContain(`› live-child`);
        await active.sendLiteralText("r");
        const archived = await active.waitForText("Archived subagents", TIMEOUT);
        expect(archived).toContain("live-child");
        await active.sendKeys("Enter");
        const archivedDetail = await active.waitForPane(
          (pane) =>
            pane.includes("Read-only child") &&
            pane.includes(`Read ${childToolPath}`),
          TIMEOUT,
        );
        expect(archivedDetail).toContain("Read-only child");
        expect(archivedDetail).not.toContain("Enter Send");
        expect(archivedDetail).not.toContain("Context:");
        expect(hasEmptyComposer(archivedDetail)).toBe(false);
        await active.sendKeys("Escape");
        await active.waitForText("Archived subagents", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane((pane) => !pane.includes("Agents & processes"), TIMEOUT);

        const restoredBeforeRepeat = await active.capturePaneGrid();
        const cursorBeforeRepeat = active.cursorPosition();
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("r");
        await active.waitForText("Archived subagents", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane((pane) => !pane.includes("Agents & processes"), TIMEOUT);
        expect(await active.capturePaneGrid()).toEqual(restoredBeforeRepeat);
        expect(active.cursorPosition()).toEqual(cursorBeforeRepeat);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        if (!childStream.released()) childStream.release("CLEANUP");
        if (!humanOneStream.released()) humanOneStream.release("CLEANUP");
        if (!humanTwoStream.released()) humanTwoStream.release("CLEANUP");
        if (!parentReleased) releaseParent(fakeGatewayFinalText("parent cleanup"));
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "Ctrl-X traverses a bounded 101-child tree through stable pages",
    async () => {
      const fixture = createFixture();
      let createIndex = 0;
      const gateway = startDynamicFakeGateway(() => {
        if (createIndex === 101) {
          return fakeGatewayFinalText("MANAGER_BOUNDED_TREE_COMPLETE");
        }
        const index = createIndex;
        createIndex += 1;
        return fakeGatewayToolCall(
          `manager_bounded_create_${index.toString().padStart(3, "0")}`,
          "subagent",
          {
            command: {
              create: {
                name: `page-child-${index.toString().padStart(3, "0")}`,
                mode: "persistent",
              },
            },
          },
        );
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "manager-bounded-tree-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            NO_COLOR: "1",
          },
          width: 100,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the bounded manager tree.");
        await active.waitForText("MANAGER_BOUNDED_TREE_COMPLETE", 120_000);
        expect(createIndex).toBe(101);

        await active.sendKeys("C-x");
        const first = await active.waitForPane(
          (pane) => pane.includes("page-child-000"),
          TIMEOUT,
        );
        expect(first).not.toContain("page-child-100");

        await active.sendLiteralText("]");
        const second = await active.waitForPane(
          (pane) =>
            pane.includes("page-child-100") &&
            pane.includes("Previous children available: [ previous page."),
          TIMEOUT,
        );
        expect(second).not.toContain("page-child-000");

        await active.sendLiteralText("[");
        const returned = await active.waitForPane(
          (pane) => pane.includes("page-child-000"),
          TIMEOUT,
        );
        expect(returned).not.toContain("page-child-100");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    150_000,
  );

  test(
    "zero-turn parent that owns a persistent child remains available in resume",
    async () => {
      const fixture = createFixture();
      const gateway = startDynamicFakeGateway(
        () => fakeGatewayFinalText("ZERO_TURN_CHILD_READY"),
        {
          classifierDecision: "allow",
          models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
        },
      );
      const env = {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: "zero-turn-resume-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_SOUND: "0",
        NO_COLOR: "1",
      };
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 100,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        let active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForText("Agents & processes", TIMEOUT);
        await active.sendLiteralText("c");
        await active.waitForText("Create persistent agent", TIMEOUT);
        await pasteVisibleText(active, "zero-turn-child");
        await active.sendKeys("Tab");
        await active.sendKeys("Tab");
        await pasteVisibleText(active, "ZERO_TURN_CHILD_PROMPT");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("ZERO_TURN_CHILD_READY") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );

        const controls = readdirSync(join(fixture.home, ".fx", "sessions"))
          .map((id) => join(fixture.home, ".fx", "sessions", id, "subagent", "control.json"))
          .filter((path) => existsSync(path))
          .map((path) => JSON.parse(readFileSync(path, "utf8")) as {
            child_id: string;
            parent_id: string;
          });
        expect(controls).toHaveLength(1);
        expect(controls[0]!.parent_id).not.toBe(controls[0]!.child_id);

        await active.sendKeys("C-x");
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;

        writeFileSync(fixture.stderrPath, "");
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env,
          width: 100,
          height: 30,
          stderrPath: fixture.stderrPath,
        });
        active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("/resume");
        const picker = await active.waitForPane(
          (pane) => pane.includes("Sessions 2"),
          TIMEOUT,
        );
        expect(picker).toContain("ZERO_TURN_CHILD_PROMPT");
        expect(picker).toContain("0 turns");
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );

  test(
    "root manager can send a direct human message to an attached nested child",
    async () => {
      const fixture = createFixture();
      const outerPrompt = "NESTED_SEND_OUTER_PROMPT";
      const innerPrompt = "NESTED_SEND_INNER_PROMPT";
      const directMessage = "NESTED_SEND_DIRECT_MESSAGE";
      const gateway = startDynamicFakeGateway((body) => {
        if (body.includes('"toolCallId":"nested_send_root_create"')) {
          return fakeGatewayFinalText("NESTED_SEND_ROOT_READY");
        }
        if (body.includes('"toolCallId":"nested_send_inner_create"')) {
          return fakeGatewayFinalText("NESTED_SEND_OUTER_READY");
        }
        if (body.includes(directMessage)) {
          return fakeGatewayFinalText("NESTED_SEND_DIRECT_COMPLETE");
        }
        if (body.includes(innerPrompt) && !body.includes(outerPrompt)) {
          return fakeGatewayFinalText("NESTED_SEND_INNER_READY");
        }
        if (body.includes(outerPrompt)) {
          return fakeGatewayToolCall("nested_send_inner_create", "subagent", {
            command: {
              create: {
                name: "nested-send-inner",
                mode: "persistent",
                prompt: innerPrompt,
              },
            },
          });
        }
        return fakeGatewayToolCall("nested_send_root_create", "subagent", {
          command: {
            create: {
              name: "nested-send-outer",
              mode: "persistent",
              prompt: outerPrompt,
            },
          },
        });
      }, {
        classifierDecision: "allow",
        models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
      });
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "nested-send-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_SOUND: "0",
            NO_COLOR: "1",
          },
          width: 112,
          height: 32,
          stderrPath: fixture.stderrPath,
        });
        const active = session;
        await active.waitForComposer(TIMEOUT);
        await active.sendText("Create the nested direct-message fixture.");
        await active.waitForText("NESTED_SEND_ROOT_READY", TIMEOUT);
        await active.sendKeys("C-x");
        await active.waitForPane(
          (pane) =>
            pane.includes("nested-send-outer") &&
            pane.includes("nested-send-inner") &&
            pane.includes("idle"),
          TIMEOUT,
        );
        await active.sendKeys("Down");
        const selected = await active.waitForPane(
          (pane) =>
            pane.split("\n").some((line) =>
              line.startsWith("› ") && line.includes("nested-send-inner")
            ),
          TIMEOUT,
        );
        expect(selected).toContain("nested-send-outer");
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) =>
            pane.includes("Subagent: nested-send-inner") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        await active.sendText(directMessage);
        const completed = await active.waitForPane(
          (pane) =>
            pane.includes("NESTED_SEND_DIRECT_COMPLETE") &&
            pane.includes("status: idle"),
          TIMEOUT,
        );
        expect(completed).not.toContain("Send failed");
        expect(gateway.requests.some((request) =>
          request.body.includes(directMessage)
        )).toBe(true);
        expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
      }
    },
    90_000,
  );
});
