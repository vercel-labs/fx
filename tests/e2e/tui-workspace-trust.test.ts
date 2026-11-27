import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
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
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
} from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP_TMUX = !tmuxAvailable();
const TIMEOUT = 30_000;
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const QUESTION_START = "Allow fx to read, edit, delete and run files in this folder";

let activeSession: TmuxSession | null = null;
let activeGateway: ReturnType<typeof startDynamicFakeGateway> | null = null;
const cleanupHomes: string[] = [];
const cleanupDirs: string[] = [];

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  if (activeGateway) {
    activeGateway.stop();
    activeGateway = null;
  }
  for (const home of cleanupHomes.splice(0)) {
    cleanupIsolatedTestHome(home);
  }
  for (const dir of cleanupDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function newIsolatedHome(): string {
  const home = realpathSync(createIsolatedTestHome());
  cleanupHomes.push(home);
  return home;
}

function newTempDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  cleanupDirs.push(dir);
  return dir;
}

function trustEnv(
  home: string,
  overrides: Record<string, string | undefined> = {},
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "0",
    ...overrides,
  };
}

async function waitForTrustScreen(session: TmuxSession): Promise<void> {
  await session.waitForPane(
    (pane) => pane.includes("Folder access") && pane.includes("❯ Yes, allow") && pane.includes("No, exit"),
    10_000,
  );
  const grid = await session.capturePaneGrid();
  await session.waitForStableGrid(grid);
}

function assertNoTrustedRecord(home: string, folder: string): void {
  const settingsPath = join(home, ".fx", "settings.json");
  if (!existsSync(settingsPath)) return;
  const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as {
    workspaces?: Record<string, { trusted?: unknown }>;
  };
  expect(settings.workspaces?.[folder]?.trusted).toBeUndefined();
}

function assertNoSessionFolder(home: string): void {
  const sessionsDir = join(home, ".fx", "sessions");
  if (!existsSync(sessionsDir)) return;
  const topEntries = readdirSync(sessionsDir).filter((name) => name !== "v2");
  expect(topEntries).toEqual([]);
  const v2Dir = join(sessionsDir, "v2");
  if (existsSync(v2Dir)) {
    expect(readdirSync(v2Dir)).toEqual([]);
  }
}

describe.skipIf(SKIP_TMUX)("tui: workspace trust", () => {
  test(
    "a new folder asks before the composer, and Yes saves it",
    async () => {
      const home = newIsolatedHome();
      const repo = newTempDir("fx-trust-new-");
      const stderrPath = join(repo, "stderr.log");
      execFileSync("git", ["init"], { cwd: repo, stdio: "pipe" });
      writeFileSync(join(repo, "AGENTS.md"), "# Project instructions\n");
      writeFileSync(stderrPath, "");

      activeSession = await TmuxSession.create({
        cwd: repo,
        env: trustEnv(home),
        stderrPath,
        width: 100,
        height: 30,
      });

      await activeSession.waitForPane(
        (pane) => pane.includes("Folder access") && pane.includes("AGENTS.md"),
        10_000,
      );
      const grid = await activeSession.capturePaneGrid();
      expect(grid.join("\n")).toContain("AGENTS.md");
      expect(grid.some((line) => line.trimStart().startsWith(QUESTION_START))).toBe(true);

      await activeSession.sendLiteralText("hello");
      await activeSession.sendKeys("Enter");

      const pane = await activeSession.waitForComposer(10_000);
      expect(composerContains(pane, "hello")).toBe(false);
      expect(pane).not.toContain("Folder access");

      const settings = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")) as {
        workspaces?: Record<string, { trusted?: unknown }>;
      };
      expect(settings.workspaces?.[repo]?.trusted).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "a trusted folder opens straight to the composer",
    async () => {
      const home = newIsolatedHome();
      const repo = newTempDir("fx-trust-pretrusted-");
      const stderrPath = join(repo, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({ workspaces: { [repo]: { trusted: true } } })}\n`,
      );
      writeFileSync(stderrPath, "");

      activeSession = await TmuxSession.create({
        cwd: repo,
        env: trustEnv(home),
        stderrPath,
        width: 100,
        height: 30,
      });

      await activeSession.waitForComposer(10_000);
      const grid = await activeSession.capturePaneGrid();
      expect(grid.join("\n")).not.toContain("Folder access");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "No, Esc and Ctrl+C each exit with code 0 and save nothing",
    async () => {
      for (const key of ["2", "Escape", "C-c"]) {
        const home = newIsolatedHome();
        const folder = newTempDir("fx-trust-decline-");
        const stderrPath = join(folder, "stderr.log");
        writeFileSync(stderrPath, "");

        activeSession = await TmuxSession.create({
          cwd: folder,
          env: trustEnv(home),
          stderrPath,
          remainOnExit: true,
          width: 100,
          height: 30,
        });

        await waitForTrustScreen(activeSession);
        await activeSession.sendKeys(key);
        await activeSession.waitForPane(() => activeSession!.recordedExitStatus() !== null, 10_000);
        expect(activeSession.recordedExitStatus()).toBe(0);
        assertNoTrustedRecord(home, folder);
        assertNoSessionFolder(home);
        expect(readFileSync(stderrPath, "utf8")).toBe("");

        await activeSession.kill();
        activeSession = null;
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a registered worktree uses its main repository's answer",
    async () => {
      const home = newIsolatedHome();
      const root = newTempDir("fx-trust-wt-root-");
      const mainRepo = join(root, "main");
      const wtDir = join(root, "wt");
      const fakeDir = join(root, "fake-wt");
      mkdirSync(mainRepo, { recursive: true });
      execFileSync("git", ["init"], { cwd: mainRepo, stdio: "pipe" });
      execFileSync("git", ["config", "user.name", "Test User"], { cwd: mainRepo, stdio: "pipe" });
      execFileSync("git", ["config", "user.email", "test@example.com"], { cwd: mainRepo, stdio: "pipe" });
      writeFileSync(join(mainRepo, "README.md"), "main\n");
      execFileSync("git", ["add", "README.md"], { cwd: mainRepo, stdio: "pipe" });
      execFileSync("git", ["commit", "-m", "initial"], { cwd: mainRepo, stdio: "pipe" });
      execFileSync("git", ["worktree", "add", wtDir], { cwd: mainRepo, stdio: "pipe" });

      const realMain = realpathSync(mainRepo);
      const realWt = realpathSync(wtDir);
      mkdirSync(join(home, ".fx"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({ workspaces: { [realMain]: { trusted: true } } })}\n`,
      );

      activeSession = await TmuxSession.create({
        cwd: realWt,
        env: trustEnv(home),
        width: 100,
        height: 30,
      });
      await activeSession.waitForComposer(10_000);
      expect((await activeSession.capturePaneGrid()).join("\n")).not.toContain("Folder access");
      await activeSession.kill();
      activeSession = null;

      mkdirSync(fakeDir, { recursive: true });
      const realFake = realpathSync(fakeDir);
      writeFileSync(join(realFake, ".git"), `gitdir: ${realMain}/.git/worktrees/wt\n`);

      activeSession = await TmuxSession.create({
        cwd: realFake,
        env: trustEnv(home),
        width: 100,
        height: 30,
      });
      await activeSession.waitForText("Folder access", 10_000);
    },
    TIMEOUT,
  );

  test(
    "the home folder asks every time and keeps no record",
    async () => {
      const home = newIsolatedHome();
      const logDir = newTempDir("fx-trust-home-log-");
      const stderrPath = join(logDir, "stderr.log");
      writeFileSync(stderrPath, "");

      activeSession = await TmuxSession.create({
        cwd: home,
        env: trustEnv(home),
        stderrPath,
        width: 100,
        height: 30,
      });
      await activeSession.waitForText("Folder access", 10_000);
      await activeSession.sendKeys("Enter");
      await activeSession.waitForComposer(10_000);
      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd(10_000)).toBe(true);
      await activeSession.kill();
      activeSession = null;

      activeSession = await TmuxSession.create({
        cwd: home,
        env: trustEnv(home),
        stderrPath,
        width: 100,
        height: 30,
      });
      await activeSession.waitForText("Folder access", 10_000);

      const settingsPath = join(home, ".fx", "settings.json");
      if (existsSync(settingsPath)) {
        const raw = readFileSync(settingsPath, "utf8");
        expect(raw).not.toContain("trusted");
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "MCP servers start only after Yes",
    async () => {
      const home = newIsolatedHome();
      const repo = newTempDir("fx-trust-mcp-");
      const pidPath = join(repo, "mcp.pid");
      const wireLogPath = join(repo, "mcp-wire.jsonl");
      const stderrPath = join(repo, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      writeFileSync(stderrPath, "");
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        `${JSON.stringify({
          mcp: {
            fixture: {
              type: "local",
              command: [process.execPath, MODERN_FIXTURE],
              enabled: true,
              environment: {
                FX_MCP_WIRE_LOG: wireLogPath,
                FX_MCP_PID_PATH: pidPath,
                FX_MCP_MODE: "normal",
              },
            },
          },
        })}\n`,
      );

      activeSession = await TmuxSession.create({
        cwd: repo,
        env: trustEnv(home),
        stderrPath,
        width: 100,
        height: 30,
      });

      await waitForTrustScreen(activeSession);
      expect(existsSync(pidPath)).toBe(false);
      expect(existsSync(wireLogPath)).toBe(false);

      await activeSession.sendKeys("Enter");
      await activeSession.waitForComposer(10_000);
      await activeSession.waitForPane(
        () =>
          existsSync(pidPath) &&
          existsSync(wireLogPath) &&
          readFileSync(wireLogPath, "utf8").includes("\"tools/list\""),
        10_000,
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "a launch prompt waits for the answer",
    async () => {
      const home = newIsolatedHome();
      const repo = newTempDir("fx-trust-launch-prompt-");
      const stderrPath = join(repo, "stderr.log");
      writeFileSync(stderrPath, "");
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("LAUNCH_TRUST_OK"));
      activeGateway = gateway;
      const quotedFx = `'${FX_BIN.replaceAll("'", "'\\''")}'`;

      activeSession = await TmuxSession.create({
        cmd: `${quotedFx} "say hi"`,
        cwd: repo,
        env: trustEnv(home, {
          AI_GATEWAY_API_KEY: "trust-launch-prompt-key",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        }),
        stderrPath,
        width: 100,
        height: 30,
      });

      await waitForTrustScreen(activeSession);
      expect(gateway.requestCount()).toBe(0);

      await activeSession.sendKeys("Enter");
      await activeSession.waitForPane(() => gateway.requestCount() === 1, 10_000);
      await activeSession.waitForText("LAUNCH_TRUST_OK", 10_000);
      expect(gateway.requestCount()).toBe(1);
      expect(gateway.requests[0]!.body).toContain("say hi");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
