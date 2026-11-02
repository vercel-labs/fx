import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { composerContains, FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeShellRun, startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const tmuxTest = test.skipIf(!tmuxAvailable());
const PASTE_START = ["1b", "5b", "32", "30", "30", "7e"] as const;
const PASTE_END = ["1b", "5b", "32", "30", "31", "7e"] as const;
let session: TmuxSession | null = null;
const temp_dirs: string[] = [];

afterEach(async () => {
  await session?.kill();
  session = null;
  for (const dir of temp_dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function waitForTrace(path: string, text: string, timeout_ms = 5_000): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeout_ms) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(text)) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for trace ${JSON.stringify(text)}`);
}

function clearPaneTerminal(active: TmuxSession): void {
  const tty = execFileSync(
    "tmux",
    ["display-message", "-t", active.name, "-p", "#{pane_tty}"],
    { encoding: "utf-8" },
  ).trim();
  writeFileSync(tty, "\x1b[3J\x1b[2J\x1b[H");
}

function textHex(text: string): string[] {
  return Array.from(new TextEncoder().encode(text), (byte) =>
    byte.toString(16).padStart(2, "0")
  );
}

tmuxTest("direct native-clear recovery resets the view and replays the held draft", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  const old_marker = "PRE_NATIVE_CLEAR_MARKER_8213";

  session = await TmuxSession.create({
    cmd: `sh -c "printf '${old_marker}\\n'; exec '${FX_BIN}'"`,
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear,frame_schedule",
    },
  });
  await session.waitForComposer(10_000);

  clearPaneTerminal(session);
  await session.sendLiteral("abc");
  await waitForTrace(trace_path, "native_clear_probe requested");

  await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);
  const history = await session.captureFullScrollback();
  expect(history).not.toContain(old_marker);
  expect(history).toContain("𝒇x v");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("native-clear recovery after a tool call keeps fx running and the tool in full history", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-tool-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  mkdirSync(join(dir, ".fx"), { recursive: true });
  writeFileSync(join(dir, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  const gateway = startFakeGateway([
    fakeShellRun("native_clear_tool", "echo TOOL_BEFORE_CLEAR"),
    fakeGatewayFinalText("TOOL_TURN_DONE"),
  ]);

  session = await TmuxSession.create({
    cwd: dir,
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      HOME: dir,
      AI_GATEWAY_API_KEY: "fake-native-clear-tool-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: "yolo",
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  try {
    await session.waitForComposer(10_000);
    await session.sendLiteral("run the check");
    await session.sendKeys("Enter");
    await session.waitForText("TOOL_TURN_DONE", 10_000);

    clearPaneTerminal(session);
    await session.sendLiteral("abc");
    await waitForTrace(trace_path, "native_clear_recovery_requested");
    await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);

    const history = await session.captureFullScrollback();
    expect(history).not.toContain("TOOL_TURN_DONE");
    expect(history).toContain("𝒇x v");

    await session.sendKeys("C-o");
    await session.waitForText("echo TOOL_BEFORE_CLEAR", 10_000);
    await session.sendKeys("C-o");
    await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderr_path, "utf8")).toBe("");
  } finally {
    gateway.stop();
  }
}, 30_000);

tmuxTest("direct healthy screens retain an ordinary burst without resetting", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-match-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  const old_marker = "PRE_NATIVE_MATCH_MARKER_4051";

  session = await TmuxSession.create({
    cmd: `sh -c "printf '${old_marker}\\n'; exec '${FX_BIN}'"`,
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  await session.waitForComposer(10_000);

  await session.sendLiteral("abc");
  await waitForTrace(trace_path, "native_clear_probe match");
  await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);

  const history = await session.captureFullScrollback();
  expect(history).toContain(old_marker);
  expect(readFileSync(trace_path, "utf8")).not.toContain("native_clear_recovery_requested");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("native-clear replay settles a complete paste before the next key", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-paste-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");

  session = await TmuxSession.create({
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear,input",
    },
  });
  await session.waitForComposer(10_000);

  session.sendLiteralImmediate("a");
  await waitForTrace(trace_path, "native_clear_probe requested");
  await session.sendHexBytes([
    ...PASTE_START,
    ...textHex("x"),
    ...PASTE_END,
  ]);
  await waitForTrace(trace_path, "paste end owner=composer bytes=1");

  await session.sendLiteralText("Z");
  await session.waitForPane((pane) => composerContains(pane, "axZ"), 10_000);
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("tmux leaves native-clear probing disabled and preserves ordinary input", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-tmux-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");

  session = await TmuxSession.create({
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  await session.waitForComposer(10_000);
  await session.sendLiteral("a");
  await session.waitForPane((pane) => composerContains(pane, "a"), 10_000);

  const trace = existsSync(trace_path) ? readFileSync(trace_path, "utf8") : "";
  expect(trace).not.toContain("native_clear_probe requested");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("typing inside the ctrl+o full transcript never starts the native-clear probe", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-ctrl-o-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  mkdirSync(join(dir, ".fx"), { recursive: true });
  writeFileSync(join(dir, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  const gateway = startFakeGateway([fakeGatewayFinalText("ctrl-o probe target")]);

  session = await TmuxSession.create({
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      HOME: dir,
      AI_GATEWAY_API_KEY: "fake-native-clear-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  try {
    await session.waitForComposer(10_000);

    // One completed turn so the full transcript has content to open.
    await session.sendLiteral("hello");
    await session.sendKeys("Enter");
    await session.waitForText("ctrl-o probe target", 10_000);

    // Control: a printable byte in the main view starts and settles the probe.
    await session.sendLiteral("a");
    await waitForTrace(trace_path, "native_clear_probe requested");
    await session.waitForPane((pane) => composerContains(pane, "a"), 10_000);
    const baseline_requests = readFileSync(trace_path, "utf8")
      .split("native_clear_probe requested").length - 1;

    // While the full transcript owns the alternate screen, the terminal cursor
    // no longer reflects the main-grid footer row, so the probe must not begin.
    await session.sendKeys("C-o");
    await session.waitForText("ctrl+o close", 10_000);
    await session.sendLiteral("j");

    // The typed byte still reaches the composer through the modal fallthrough.
    // Waiting for it first proves the byte traversed the input path while the
    // transcript owned the screen, so the no-probe assertion needs no sleep.
    await session.sendKeys("C-o");
    await session.waitForPane((pane) => composerContains(pane, "aj"), 10_000);

    const trace = readFileSync(trace_path, "utf8");
    const requests = trace.split("native_clear_probe requested").length - 1;
    expect(requests).toBe(baseline_requests);
    expect(trace).not.toContain("native_clear_probe mismatch");
    expect(trace).not.toContain("native_clear_recovery_requested");
    expect(readFileSync(stderr_path, "utf8")).toBe("");
  } finally {
    gateway.stop();
  }
}, 30_000);
