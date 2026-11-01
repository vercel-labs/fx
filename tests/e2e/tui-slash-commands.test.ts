import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, HAS_API_KEY } from "../evals/eval-helpers";
import { closeStatusPanel, lastTranscriptRow, panelSession, readPermissionsPanel, readStatusPanel, showsStatusPanel, waitForStatusPanel } from "./info-panel";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TMUX_SKIP = !tmuxAvailable();
const SKIP = TMUX_SKIP || !HAS_API_KEY;
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
  if (gateway) { gateway.stop(); gateway = null; }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function launchAndWait(): Promise<TmuxSession> {
  const root = mkdtempSync(join(tmpdir(), "fx-slash-commands-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  tempDirs.push(root);
  const s = await TmuxSession.create({
    cwd: workspace,
    env: { HOME: home },
  });
  await s.waitForComposer(10_000);
  return s;
}

async function launchNoKeyAndWait(record = false): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
  root: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "fx-slash-commands-no-key-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(home);
  mkdirSync(workspace);
  tempDirs.push(root);
  const terminal = await TmuxSession.create({
    cwd: workspace,
    stderrPath,
    isolated: true,
    env: {
      HOME: home,
      FX_SOUND: "0",
      ...(record ? { FX_RECORD: join(root, "terminal.fxtape"), FX_DEBUG_RECORD_SILENT_BANNER: "1" } : {}),
      AI_GATEWAY_API_KEY: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: undefined,
      FX_TEST_SKIP_ONBOARDING: "1",
      VERCEL_OIDC_TOKEN: undefined,
    },
  });
  await terminal.waitForText("Run /help for commands", 10_000);
  await terminal.waitForStableComposer(10_000);
  return { terminal, stderrPath, root };
}

describe.skipIf(TMUX_SKIP)("tui: no-key slash commands", () => {
  test(
    "/compact with no eligible context leaves no transcript notice",
    async () => {
      const launched = await launchNoKeyAndWait(true);
      session = launched.terminal;
      try {
        await session.sendText("/compact");
        await session.waitForText("No context to compact.", 5_000);
        await session.waitForPane((pane) => !pane.includes("No context to compact."), 5_000);
        await session.waitForComposer(5_000);
        const scrollback = await session.captureFullScrollbackEscapes();
        expect(scrollback).toContain("Run /help for commands");
        expect(scrollback).not.toMatch(/No context to compact|Context:|Compacting/);
        await session.sendKeys("C-o");
        const transcript = await session.waitForText("full detail", 5_000);
        expect(transcript).not.toMatch(/No context to compact|Context:|Compacting/);
        await session.sendKeys("C-o");
        await session.waitForComposer(5_000);
        await session.sendLiteral("composer-after-noop");
        await session.waitForText("composer-after-noop", 5_000);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
      } catch (error) {
        tempDirs.splice(tempDirs.indexOf(launched.root), 1);
        writeFileSync(join(launched.root, "failure.scrollback.ansi"), await session.captureFullScrollbackEscapes());
        console.error(`no-op evidence retained: ${launched.root}`);
        throw error;
      }
    },
    TIMEOUT,
  );

  test(
    "/undo reports the exact empty state",
    async () => {
      session = await launchAndWait();
      await session.sendText("/undo");
      const pane = await session.waitForText("Nothing to undo.", 5_000);
      expect(pane).toContain("Nothing to undo.");
    },
    TIMEOUT,
  );

  test(
    "/permissions shows the mode and how to change it in a panel and leaves a live composer",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;

      const panel = await readPermissionsPanel(session, 5_000);
      expect(["ask", "auto"]).toContain(panel.fields.Mode);
      expect(panel.labels.indexOf("Change mode")).toBeGreaterThan(panel.labels.indexOf("Mode"));
      expect(panel.fields["Change mode"]).toBe("/permissions ask, auto, full-access, or reset");
      expect(await session.captureFullScrollback()).not.toContain("* permissions:");

      await session.sendLiteral("composer-still-usable");
      const pane = await session.waitForText("composer-still-usable", 5_000);
      expect(pane).toContain("composer-still-usable");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  /// A 60x12 shell over `gateway`, recording to a tape, for the tests of the
  /// `/status` panel in a terminal too short for all of it.
  async function launchShortTerminal(name: string): Promise<{ stderrPath: string; tapePath: string }> {
    const root = mkdtempSync(join(tmpdir(), `fx-status-${name}-`));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    const tapePath = join(root, "session.fxtape");
    mkdirSync(home);
    mkdirSync(workspace);
    tempDirs.push(root);
    session = await TmuxSession.create({
      cwd: workspace,
      stderrPath,
      isolated: true,
      width: 60,
      height: 12,
      minimumHistoryLines: 2000,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "status-compact-key",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway!.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway!.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway!.baseUrl}/coding-agent/v1/models`,
        FX_SOUND: "0",
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_PERMISSION_MODE: "auto",
        FX_RECORD: tapePath,
        FX_RECORD_INPUT: "1",
        VERCEL_OIDC_TOKEN: undefined,
        NO_COLOR: "1",
      },
    });
    await session.waitForComposer(10_000);
    return { stderrPath, tapePath };
  }

  /// Rows of `scrollback` that hold a labeled line of the `/status` panel.
  function panelLinesIn(scrollback: string): string[] {
    return scrollback.split("\n").filter((row) =>
      ["Session", "Permissions", "Session grants"].some((label) => new RegExp(`^ {2}${label} {2,}\\S`).test(row)));
  }

  test(
    "compact status panel leaves native scrollback whole",
    async () => {
      gateway = startFakeGateway([]);
      const { stderrPath, tapePath } = await launchShortTerminal("compact");
      expect((await session!.captureFullScrollback()).split("Run /help for commands")).toHaveLength(2);

      // Twelve rows leave the panel room for one line at a time. It scrolls
      // instead of covering the transcript, so the transcript's last row
      // stays in view.
      const kept = lastTranscriptRow((await session!.capturePane()).split("\n"));
      await session!.sendText("/status");
      const panel = await waitForStatusPanel(session!, 5_000);
      expect(panel.labels[0]).toBe("Session");
      expect(panel.labels.at(-1)).toBe("Build");
      expect(panel.fields.Permissions).toBe("auto");
      expect((await session!.capturePane()).split("\n").map((row) => row.trimEnd())).toContain(kept);
      await closeStatusPanel(session!, 5_000);
      await session!.waitForComposer(5_000);
      const scrollback = await session!.captureFullScrollback();
      expect(scrollback.split("Run /help for commands")).toHaveLength(2);
      expect(panelLinesIn(scrollback)).toEqual([]);
      expect(session!.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session!.sendText("/quit");
      expect(await session!.waitForSessionEnd(5_000)).toBe(true);
      session = null;

      const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
        encoding: "utf8",
      }));
      expect(replay.frame_count).toBeGreaterThan(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);
    },
    // Reading every line takes a ↓ and two captures a line.
    60_000,
  );

  test(
    "compact status panel keeps every transcript row when a turn answers while it is open",
    async () => {
      const held = heldFakeGatewayFinalText();
      gateway = startDynamicFakeGateway((body) =>
        body.includes("slow question") ? held.response : fakeGatewayFinalText("unexpected request"));
      const { stderrPath } = await launchShortTerminal("answer");

      await session!.sendText("slow question");
      await session!.waitForText("Thinking", 10_000);
      await session!.sendText("/status");
      await waitForStatusPanel(session!, 5_000, (shown) => shown.labels[0] === "Session");
      held.release("FIRST_ANSWER_LINE\n\nSECOND_ANSWER_LINE\n\nTHIRD_ANSWER_LINE");
      // The answer shows above the panel, which stays open.
      await session!.waitForText("THIRD_ANSWER_LINE", 10_000);
      expect(showsStatusPanel((await session!.capturePane()).split("\n"))).toBe(true);
      await closeStatusPanel(session!, 5_000);
      await session!.waitForComposer(5_000);

      const scrollback = await session!.captureFullScrollback();
      for (const row of ["Run /help for commands", "┃ slow question", "FIRST_ANSWER_LINE", "SECOND_ANSWER_LINE", "THIRD_ANSWER_LINE"]) {
        expect({ row, count: scrollback.split(row).length - 1 }).toEqual({ row, count: 1 });
      }
      expect(panelLinesIn(scrollback)).toEqual([]);
      expect(session!.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP)("tui: slash commands", () => {
  test(
    "/status shows the session, model, and permissions in a panel and Esc closes it",
    async () => {
      session = await launchAndWait();
      const panel = await readStatusPanel(session, 5_000);
      expect(panelSession(panel).id).toMatch(/^[A-Za-z0-9_-]{12}$/);
      expect(panel.fields.Model).toBeTruthy();
      expect(panel.fields.Permissions).toBeTruthy();
      await session.waitForComposer(5_000);
    },
    TIMEOUT,
  );

  test(
    "/settings opens the settings catalog",
    async () => {
      session = await launchAndWait();
      await session.sendText("/settings");
      const pane = await session.waitForText("←→ change", 5_000);
      expect(pane).toContain("Settings");
      expect(pane).toContain("↑↓ navigate");
      expect(pane).not.toContain("[All]");
    },
    TIMEOUT,
  );

  test(
    "/model Enter lists available models inline",
    async () => {
      session = await launchAndWait();
      await session.sendText("/model");
      const pane = await session.waitForText(/anthropic|model/i, 10_000);
      expect(pane.length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );

  test(
    "unknown and removed commands show errors",
    async () => {
      session = await launchAndWait();
      for (const [index, command] of [
        "/foo",
        "/changes",
        "/review",
        "/pr",
        "/issue",
        "/history",
        "/rules",
        "/models",
      ].entries()) {
        await session.sendText(command);
        const expectedCount = index + 1;
        const deadline = Date.now() + 5_000;
        let scrollback = "";
        while (Date.now() < deadline) {
          scrollback = await session.captureFullScrollback();
          const actualCount = scrollback.split("Unknown command. Try /help.").length - 1;
          if (actualCount >= expectedCount) break;
          await Bun.sleep(50);
        }
        expect(
          scrollback.split("Unknown command. Try /help.").length - 1,
        ).toBe(expectedCount);
      }
    },
    TIMEOUT,
  );
});
