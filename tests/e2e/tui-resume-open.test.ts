// Opening a saved session from the session picker (`fx -r`, `/resume`) runs
// off the UI thread: the selected row shows it opening, a second Enter opens
// nothing extra, Esc drops the open and keeps the picker, and other keys
// stay responsive (`tests/tla/session_picker/SessionOpen.tla`). The open
// is held with FX_TEST_SESSION_OPEN_HELD and FX_TEST_SESSION_OPEN_RELEASE
// (`src/core/app/session_open_test_controls.zig`), once the session is open
// and its writer lock is taken.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { copyV1Fixture, rootSessionIds } from "./saved-sessions";
import { FAKE_GATEWAY_MODEL, hasEmptyComposer, startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 30_000;
// `tests/fixtures/v1-sessions` "plain": the second is the newer, so it lists
// first and is selected when the picker opens.
const NEWER = "CONV_FIRST 2";
const OLDER = "CONV_FIRST 1";
const OPENING = "• Opening…";

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "");
}

function rowOf(pane: string, title: string): string {
  return stripAnsi(pane).split("\n").find((line) => line.includes(title)) ?? "";
}

async function waitForFile(path: string, timeout = TIMEOUT): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(10);
  }
  throw new Error(`Timed out waiting for ${path}`);
}

function setup() {
  const root = mkdtempSync(join(tmpdir(), "fx-resume-open-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(workspace, { recursive: true });
  mkdirSync(home, { recursive: true });
  copyV1Fixture(home, "plain", 2, workspace);
  const held = join(root, "held");
  const release = join(root, "release");
  const stderrPath = join(root, "stderr.log");
  writeFileSync(stderrPath, "");
  const gateway = startFakeGateway([]);
  const env = {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-tui-resume-open-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_TEST_SESSION_OPEN_HELD: held,
    FX_TEST_SESSION_OPEN_RELEASE: release,
  };
  return { root, home, workspace, held, release, stderrPath, gateway, env };
}

async function openPicker(fixture: ReturnType<typeof setup>): Promise<TmuxSession> {
  const active = await TmuxSession.create({
    cmd: `${FX_BIN} -r`,
    cwd: fixture.workspace,
    env: fixture.env,
    stderrPath: fixture.stderrPath,
    width: 100,
    height: 30,
  });
  await active.waitForPane((pane) => pane.includes("Sessions 2") && pane.includes(NEWER) && pane.includes(OLDER), TIMEOUT);
  return active;
}

async function waitForResumed(active: TmuxSession, title: string): Promise<string> {
  return active.waitForPane((pane) => {
    const text = stripAnsi(pane);
    return !text.includes("enter resume") && text.includes(title) && hasEmptyComposer(text);
  }, TIMEOUT);
}

test.skipIf(!tmuxAvailable())(
  "Enter on a slow session shows Opening… on its row, a second Enter opens nothing extra, and keys stay responsive",
  async () => {
    const fixture = setup();
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await openPicker(fixture);
      await active.sendKeys("Enter");
      // The worker holds the session open; the UI thread is free.
      await waitForFile(`${fixture.held}.1`);
      const opening = await active.waitForPane((pane) => rowOf(pane, NEWER).includes(OPENING), TIMEOUT);
      expect(rowOf(opening, OLDER)).not.toContain("Opening");
      expect(rowOf(opening, OLDER)).toMatch(/\bturns?\b/);

      await active.sendKeys("Enter");
      // Keys still reach the picker: the search filters the rows at once,
      // and the opening row keeps its mark when it shows again.
      await active.sendLiteral("1");
      await active.waitForPane((pane) => rowOf(pane, OLDER).length > 0 && rowOf(pane, NEWER).length === 0, TIMEOUT);
      await active.sendKeys("BSpace");
      await active.waitForPane((pane) => rowOf(pane, OLDER).length > 0 && rowOf(pane, NEWER).includes(OPENING), TIMEOUT);

      writeFileSync(fixture.release, "");
      await waitForResumed(active, NEWER);
      // The second Enter started no second open.
      expect(existsSync(`${fixture.held}.2`)).toBe(false);
      expect(rootSessionIds(fixture.home)).toHaveLength(1);

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (active) await active.kill();
      fixture.gateway.stop();
      if (passed) rmSync(fixture.root, { recursive: true, force: true });
      else console.error(`retained resume-open artifacts at ${fixture.root}`);
    }
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "Esc while a session opens drops the open and keeps the picker, which then opens it again",
  async () => {
    const fixture = setup();
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await openPicker(fixture);
      await active.sendKeys("Enter");
      await waitForFile(`${fixture.held}.1`);
      await active.waitForPane((pane) => rowOf(pane, NEWER).includes(OPENING), TIMEOUT);

      await active.sendKeys("Escape");
      const kept = await active.waitForPane((pane) => {
        const text = stripAnsi(pane);
        return text.includes("enter resume") && !text.includes("Opening") && rowOf(pane, NEWER).length > 0;
      }, TIMEOUT);
      expect(rowOf(kept, NEWER)).toMatch(/\bturns?\b/);

      // The dropped open let the session's writer lock go: a new open
      // takes it and reaches the hold again.
      await active.sendKeys("Enter");
      await waitForFile(`${fixture.held}.2`);
      await active.waitForPane((pane) => rowOf(pane, NEWER).includes(OPENING), TIMEOUT);
      writeFileSync(`${fixture.release}.2`, "");
      await waitForResumed(active, NEWER);

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      await active.kill();
      active = null;
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (active) await active.kill();
      fixture.gateway.stop();
      if (passed) rmSync(fixture.root, { recursive: true, force: true });
      else console.error(`retained resume-open artifacts at ${fixture.root}`);
    }
  },
  TIMEOUT * 3,
);

test.skipIf(!tmuxAvailable())(
  "quitting while a session opens exits at once and leaves the session to open again",
  async () => {
    const fixture = setup();
    let active: TmuxSession | null = null;
    let passed = false;
    try {
      active = await openPicker(fixture);
      await active.sendKeys("Enter");
      await waitForFile(`${fixture.held}.1`);
      await active.waitForPane((pane) => rowOf(pane, NEWER).includes(OPENING), TIMEOUT);
      // The open holds the session's lock; Ctrl+C twice still exits at once.
      await active.sendKeys("C-c");
      await active.waitForPane((pane) => pane.includes("press ctrl+c again to exit"), TIMEOUT);
      const quitAt = Date.now();
      await active.sendKeys("C-c");
      expect(await active.waitForSessionEnd(10_000)).toBe(true);
      expect(Date.now() - quitAt).toBeLessThan(5_000);
      await active.kill();
      active = null;
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

      // Nothing of the dropped open holds the session: the next fx opens it.
      rmSync(`${fixture.held}.1`, { force: true });
      writeFileSync(fixture.release, "");
      active = await openPicker(fixture);
      await active.sendKeys("Enter");
      await waitForResumed(active, NEWER);
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd()).toBe(true);
      passed = true;
    } finally {
      if (active) await active.kill();
      fixture.gateway.stop();
      if (passed) rmSync(fixture.root, { recursive: true, force: true });
      else console.error(`retained resume-open artifacts at ${fixture.root}`);
    }
  },
  TIMEOUT * 3,
);
