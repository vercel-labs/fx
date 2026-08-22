import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, HAS_API_KEY } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TMUX_SKIP = !tmuxAvailable();
const SKIP = TMUX_SKIP || !HAS_API_KEY;
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
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

async function launchNoKeyAndWait(): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
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
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: undefined,
      FX_SKIP_ONBOARDING: "1",
      VERCEL_OIDC_TOKEN: undefined,
    },
  });
  await terminal.waitForComposer(10_000);
  return { terminal, stderrPath };
}

describe.skipIf(TMUX_SKIP)("tui: no-key slash commands", () => {
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
    "/permissions shows state before switching usage and leaves a live composer",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;

      await session.sendText("/permissions");
      await session.waitForText("usage: /permissions [ask|auto|yolo|reset]", 5_000);
      const scrollback = await session.captureFullScrollback();
      const statusIndex = scrollback.search(/● Permissions: mode=(?:ask|auto)/);
      const usageIndex = scrollback.indexOf(
        "usage: /permissions [ask|auto|yolo|reset]",
      );
      expect(statusIndex).toBeGreaterThanOrEqual(0);
      expect(usageIndex).toBeGreaterThan(statusIndex);

      await session.sendLiteral("composer-still-usable");
      const pane = await session.waitForText("composer-still-usable", 5_000);
      expect(pane).toContain("composer-still-usable");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "compact status notice preserves native scrollback",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-status-compact-"));
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
        width: 60,
        height: 12,
        minimumHistoryLines: 2000,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "status-compact-key",
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
      expect((await session.captureFullScrollback()).split("Run /help for commands")).toHaveLength(2);

      await session.sendText("/status");
      await session.waitForText("agent_step_limit=", 5_000);
      await session.waitForComposer(5_000);
      const scrollback = await session.captureFullScrollback();

      for (const field of [
        "Run /help for commands",
        "auth_refreshable=",
        "permission_mode=auto",
      ]) {
        expect(scrollback.split(field)).toHaveLength(2);
      }
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(5_000)).toBe(true);
      session = null;

      const replay = JSON.parse(execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
        encoding: "utf8",
      }));
      expect(replay.frame_count).toBeGreaterThan(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP)("tui: slash commands", () => {
  test(
    "/status shows session info",
    async () => {
      session = await launchAndWait();
      await session.sendText("/status");
      const pane = await session.waitForText(/model|permission/i, 5_000);
      expect(pane.toLowerCase()).toMatch(/model|permission/);
    },
    TIMEOUT,
  );

  test(
    "/settings opens the settings catalog",
    async () => {
      session = await launchAndWait();
      await session.sendText("/settings");
      const pane = await session.waitForText("←→ Change", 5_000);
      expect(pane).toContain("Settings");
      expect(pane).toContain("↑↓ Navigate");
      expect(pane).not.toContain("[All]");
    },
    TIMEOUT,
  );

  test(
    "/models lists available models",
    async () => {
      session = await launchAndWait();
      await session.sendText("/models");
      const pane = await session.waitForText(/anthropic|model/i, 10_000);
      expect(pane.length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );

  test(
    "/compact shows compaction message",
    async () => {
      session = await launchAndWait();
      await session.sendText("/compact");
      const pane = await session.waitForText(/compact/i, 5_000);
      expect(pane.toLowerCase()).toContain("compact");
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
