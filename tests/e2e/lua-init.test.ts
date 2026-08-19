import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function launchWithInit(initLua: string): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "fx-lua-init-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "init.lua"), initLua);
  writeFileSync(stderrPath, "");
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
  return { terminal, stderrPath };
}

describe.skipIf(SKIP)("tui: Lua init.lua", () => {
  test(
    "broken init.lua does not crash startup",
    async () => {
      const launched = await launchWithInit("this is not lua [[[\n");
      session = launched.terminal;
      const pane = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(pane)).toBe(true);
      expect(pane.toLowerCase()).toContain("lua");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/hello from init.lua registers and runs",
    async () => {
      const launched = await launchWithInit(
        'fx.command("hello", function()\n  fx.notify("hello from lua")\nend)\n',
      );
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendText("/hello");
      const pane = await session.waitForText("hello from lua", 5_000);
      expect(pane).toContain("hello from lua");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
