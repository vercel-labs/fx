import { expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  realpathSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  buildEvalProcessEnv,
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  DEFAULT_UNSET_ENV_KEYS,
  envWithoutFxHome,
  FX_BIN,
  fxChildEnv,
  needsProcessSnapshot,
  REPO_ROOT,
  runFx,
} from "../evals/eval-helpers";
import { savedSessionIds, storeRoot } from "./saved-sessions";
import {
  buildObservedCommand,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  isVolatileTokenStatusRow,
  localCreditsEnv,
  paneExitMatches,
  paneStatusFromTmux,
  parseSingleChildPid,
  startDynamicFakeGateway,
  TMUX_NO_CONFIG,
  TmuxSession,
  tmuxAvailable,
  tmuxReportsServerGone,
} from "./tmux-helpers";

const tmuxTest = test.skipIf(!tmuxAvailable());
const ISOLATED_KEYS = [
  "AI_GATEWAY_API_KEY",
  "VERCEL_OIDC_TOKEN",
  "VERCEL_TOKEN",
  "FX_TEST_GATEWAY_CHAT_URL",
  "FX_TEST_GATEWAY_MODELS_URL",
  "FX_TEST_GATEWAY_CREDITS_URL",
  // A developer's terminal recording and the bridge of the fx session that
  // started their tmux server must not reach a test's fx.
  "FX_DEBUG_RECORD",
  "FX_DEBUG_RECORD_SILENT_BANNER",
  "FX_RECORD",
  "FX_RECORD_INPUT",
  "FX_MCP_CALL_SOCKET",
  "FX_MCP_CALL_TOKEN",
  // A test hold left there would stop every test's fx at it.
  "FX_TEST_REPORT_DELIVERY_HELD",
  "FX_TEST_REPORT_DELIVERY_RELEASE",
  "FX_TEST_SESSION_WRITE_HELD",
  "FX_TEST_SESSION_WRITE_RELEASE",
  "FX_TEST_SHELL_YIELD_HELD",
  "FX_TEST_SHELL_YIELD_RELEASE",
  "FX_TEST_SUBAGENT_CLOSE_HELD",
  "FX_TEST_SUBAGENT_CLOSE_RELEASE",
  "FX_TEST_SUBAGENT_END_HELD",
  "FX_TEST_SUBAGENT_END_RELEASE",
  "FX_TEST_SUBAGENT_PUBLISH_HELD",
  "FX_TEST_SUBAGENT_PUBLISH_RELEASE",
  "FX_TEST_SUBAGENT_SETTLE_HELD",
  "FX_TEST_SUBAGENT_SETTLE_RELEASE",
  "FX_TEST_SUBAGENT_START_HELD",
  "FX_TEST_SUBAGENT_START_RELEASE",
  "FX_TEST_WORKSPACE_CAPTURE_START_HELD",
  "FX_TEST_WORKSPACE_CAPTURE_START_RELEASE",
  "FX_TEST_WEB_FETCH_DNS_READY",
  "FX_TEST_WEB_FETCH_DNS_RELEASE",
  "FX_TEST_GREP_RELEASE",
  "FX_TEST_ACP_PROMPT_TERMINAL_READY",
  "FX_TEST_ACP_PROMPT_REAP_READY",
  "FX_TEST_ACP_PROMPT_RELEASE",
  "FX_TEST_ACP_PERMISSION_READY",
  "FX_TEST_ACP_PERMISSION_RELEASE",
] as const;
const tmuxFxTest = test.skipIf(!tmuxAvailable() || !existsSync(FX_BIN));
const HELD_ENV_REPLY = "NO_HOLD_REACHED_FX";
const HELD_ENV_WAIT_MS = 15_000;
const HELD_ENV_TEST_TIMEOUT_MS = 60_000;

test("pane exit matching requires the expected observed status", () => {
  expect(paneExitMatches({ dead: false, status: null }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: null }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: 0 }, 0)).toBe(true);
  expect(paneExitMatches({ dead: true, status: 1 }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: 37 }, 37)).toBe(true);
});

test("only tmux's errors for a server that does not run count as a gone pane", () => {
  // The messages tmux prints when the server was killed and when its socket
  // was never made.
  expect(tmuxReportsServerGone("no server running on /tmp/tmux-1000/fx-e2e")).toBe(true);
  expect(tmuxReportsServerGone("error connecting to /tmp/tmux-1000/fx-e2e (No such file or directory)")).toBe(true);
  expect(tmuxReportsServerGone("error connecting to /tmp/tmux-1000/fx-e2e (Connection refused)")).toBe(true);
  expect(tmuxReportsServerGone("error connecting to /tmp/tmux-1000/fx-e2e (Permission denied)")).toBe(false);
  expect(tmuxReportsServerGone("directory /tmp/fx-e2e/tmux-1000 has unsafe permissions")).toBe(false);
  expect(tmuxReportsServerGone("protocol version mismatch (client 8, server 7)")).toBe(false);
  expect(tmuxReportsServerGone("")).toBe(false);
});

test("a pane's status reads tmux's answer, and a tmux error that is not a gone server throws", () => {
  const target = "fx-test-1:0.0";
  const recorded = () => 7;
  expect(paneStatusFromTmux(target, { output: "%3:0:\n" }, recorded)).toEqual({ dead: false, status: null });
  expect(paneStatusFromTmux(target, { output: "%3:1:0\n" }, recorded)).toEqual({ dead: true, status: 0 });
  // tmux marks the pane dead before it has the exit status.
  expect(paneStatusFromTmux(target, { output: "%3:1:\n" }, recorded)).toEqual({ dead: true, status: 7 });
  // The session is gone and the server still runs.
  expect(paneStatusFromTmux(target, { output: "::\n" }, recorded)).toEqual({ dead: true, status: 7 });
  expect(paneStatusFromTmux(target, { error: "no server running on /tmp/tmux-1000/fx" }, recorded))
    .toEqual({ dead: true, status: 7 });
  expect(() => paneStatusFromTmux(target, { error: "directory /tmp/fx/tmux-1000 has unsafe permissions" }, recorded))
    .toThrow(`tmux could not report pane ${target}: directory /tmp/fx/tmux-1000 has unsafe permissions`);
  expect(() => paneStatusFromTmux(target, { error: "spawnSync tmux ENOENT" }, recorded)).toThrow("spawnSync tmux ENOENT");
});

tmuxTest("a session that ended while its server still runs reads as dead with its exit status", async () => {
  const socketName = `fx-pane-gone-${process.pid}-${Date.now().toString(36)}`;
  const keeper = await TmuxSession.create({ cmd: "sleep 30", startupWaitMs: 0, socketName });
  const ended = await TmuxSession.create({ cmd: "sh -c 'exit 3'", startupWaitMs: 0, socketName });
  try {
    expect(await ended.waitForSessionEnd()).toBe(true);
    expect(keeper.isAlive()).toBe(true);
    expect(ended.paneStatus()).toEqual({ dead: true, status: 3 });
  } finally {
    await ended.kill();
    await keeper.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], { stdio: "pipe" });
    } catch {}
  }
});

test("launched process PID parsing requires one direct child", () => {
  expect(parseSingleChildPid("31415\n", 27182)).toBe(31415);
  expect(() => parseSingleChildPid("", 27182)).toThrow(
    "tmux pane process 27182 has 0 direct children",
  );
  expect(() => parseSingleChildPid("31415\n31416\n", 27182)).toThrow(
    "tmux pane process 27182 has 2 direct children",
  );
  expect(() => parseSingleChildPid("not-a-pid\n", 27182)).toThrow(
    "invalid child PID",
  );
});

tmuxTest("the launched process PID skips a shell that runs the pane command as a child", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-pane-shell-"));
  // tmux starts the pane through its default shell. This one runs the
  // command as a child instead of replacing itself, as bash does on Linux.
  const shell = join(dir, "child-shell");
  writeFileSync(shell, '#!/bin/sh\n/bin/sh -c "$2"\nexit $?\n', { mode: 0o755 });
  const savedShell = process.env.SHELL;
  process.env.SHELL = shell;
  let session: TmuxSession | undefined;
  try {
    session = await TmuxSession.create({ cmd: "sleep 30", startupWaitMs: 200, isolated: true });
  } finally {
    if (savedShell === undefined) delete process.env.SHELL;
    else process.env.SHELL = savedShell;
  }
  try {
    // The watcher starts the command just after the pane starts.
    let pid = 0;
    const deadline = Date.now() + 5_000;
    while (pid === 0) {
      try {
        pid = session.processPid();
      } catch (err) {
        if (Date.now() > deadline) throw err;
        await Bun.sleep(25);
      }
    }
    const name = execFileSync("ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8" }).trim();
    expect(name.split("/").at(-1)).toBe("sleep");
    // The pane's direct child is the watcher shell, not the command.
    const panePid = session.panePid();
    const paneChild = parseSingleChildPid(execFileSync("pgrep", ["-P", String(panePid)], { encoding: "utf8" }), panePid);
    expect(paneChild).not.toBe(pid);
  } finally {
    await session.kill();
    rmSync(dir, { recursive: true, force: true });
  }
});

tmuxTest("reading the remain-on-exit format throws when tmux has no such pane or no server", async () => {
  const socketName = `fx-roe-format-${process.pid}-${Date.now().toString(36)}`;
  const first = await TmuxSession.create({ cmd: "sleep 30", startupWaitMs: 0, socketName });
  const second = await TmuxSession.create({ cmd: "sleep 30", startupWaitMs: 0, socketName });
  try {
    expect(first.remainOnExitFormat().length).toBeGreaterThan(0);
    // The server still runs, and tmux exits 0 for a target it cannot find.
    await first.kill();
    expect(() => first.remainOnExitFormat()).toThrow(`tmux found no pane ${first.name}:0.0`);
    await second.kill();
    expect(() => second.remainOnExitFormat()).toThrow(/no server running|error connecting/);
  } finally {
    await second.kill();
    await first.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], { stdio: "pipe" });
    } catch {}
  }
});

test("held gateway response disposes before it is requested", async () => {
  const held = heldFakeGatewayFinalText();

  held.dispose();
  held.dispose();

  expect(await held.response.text()).toBe("");
});

test("unrequested held gateway response does not keep Bun alive", () => {
  const helperUrl = pathToFileURL(join(import.meta.dir, "tmux-helpers.ts")).href;
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `import { heldFakeGatewayFinalText } from ${JSON.stringify(helperUrl)}; ` +
      "const held = heldFakeGatewayFinalText(); held.dispose();",
    ],
    { encoding: "utf8", timeout: 1_000 },
  );

  expect(result.error).toBeUndefined();
  expect(result.status).toBe(0);
  expect(result.stderr).toBe("");
});

test("held gateway response disposes after its stream starts", async () => {
  const held = heldFakeGatewayFinalText();
  const reader = held.response.body!.getReader();

  expect((await reader.read()).done).toBe(false);
  held.dispose();
  held.dispose();

  expect((await reader.read()).done).toBe(true);
});

test("volatile token status rows stay narrowly classified", () => {
  expect(isVolatileTokenStatusRow("  (↑10 ↓5)")).toBe(true);
  expect(isVolatileTokenStatusRow("  0s (↑10 ↓5)")).toBe(true);
  expect(isVolatileTokenStatusRow("  1m 2s (↑1.2k ↓3k)")).toBe(true);
  expect(isVolatileTokenStatusRow("• Streaming (↑10 ↓5)")).toBe(false);
  expect(isVolatileTokenStatusRow("ordinary output (↑10 ↓5)")).toBe(false);
});

test("observed command keeps wrapper signal diagnostics out of captured stderr", () => {
  const root = mkdtempSync(join(tmpdir(), "fx-observed-command-"));
  const stderrPath = join(root, "fx.stderr");
  const exitStatusPath = join(root, "exit-status");

  try {
    for (const shellPath of ["/bin/sh", "/bin/dash"].filter(existsSync)) {
      const observedCommand = buildObservedCommand(
        `/bin/sh -c 'printf "fx stderr\\n" >&2; kill -TERM $$'`,
        stderrPath,
        exitStatusPath,
        root,
      ).replaceAll("/bin/sh", shellPath);
      const result = spawnSync(shellPath, ["-c", observedCommand], {
        encoding: "utf8",
      });

      expect(result.status).toBe(143);
      expect(readFileSync(stderrPath, "utf8")).toBe("fx stderr\n");
      expect(readFileSync(exitStatusPath, "utf8")).toBe("143\n");
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("observed command restores its requested cwd after inheriting a deleted directory", () => {
  const root = mkdtempSync(join(tmpdir(), "fx-observed-cwd-"));
  const dead = join(root, "dead");
  const live = join(root, "live's cwd");
  const status = join(root, "exit-status");
  mkdirSync(dead);
  mkdirSync(live);

  try {
    const observed = buildObservedCommand(
      "/bin/pwd -P",
      undefined,
      status,
      live,
    );
    const result = spawnSync("/bin/sh", [
      "-c",
      'cd -- "$1" && rmdir -- "$1" && eval "$2"',
      "deleted-cwd",
      dead,
      observed,
    ], { encoding: "utf8" });

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(realpathSync(live));
    expect(readFileSync(status, "utf8")).toBe("0\n");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("observed command records a failed cwd change without running the child", () => {
  const root = mkdtempSync(join(tmpdir(), "fx-observed-cwd-missing-"));
  const status = join(root, "exit-status");
  const missing = join(root, "missing");

  try {
    for (const stderrPath of [undefined, join(root, "stderr")]) {
      const observed = buildObservedCommand("printf ran", stderrPath, status, missing);
      const result = spawnSync("/bin/sh", ["-c", observed], { encoding: "utf8" });

      expect(result.status).toBe(125);
      expect(readFileSync(status, "utf8")).toBe("125\n");
      expect(result.stdout).toBe("");
      if (stderrPath) expect(readFileSync(stderrPath, "utf8")).toContain(missing);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

tmuxTest("tmux launch scrubs stale overrides without storing explicit credentials", async () => {
  const socketName = `fx-env-isolation-${process.pid}-${Date.now()}`;
  const root = mkdtempSync(join(tmpdir(), "fx-tmux-env-isolation-"));
  const probePath = join(root, "probe.mjs");
  const resultPath = join(root, "result.json");
  const originalValues = new Map(
    ISOLATED_KEYS.map((key) => [key, process.env[key]] as const),
  );
  const staleValues = Object.fromEntries(
    ISOLATED_KEYS.map((key) => [key, `stale-${key.toLowerCase()}`]),
  );
  const seedEnv = {
    ...process.env,
    ...staleValues,
  };

  let session: TmuxSession | undefined;
  try {
    execFileSync(
      "tmux",
      ["-L", socketName, ...TMUX_NO_CONFIG, "new-session", "-d", "-s", "fx-stale-env-seed", "sleep 60"],
      { env: seedEnv, stdio: "pipe" },
    );

    for (const key of ISOLATED_KEYS) delete process.env[key];

    const explicitCredential = "explicit-auth-sentinel";
    const explicitRecordInput = "explicit-record-input-sentinel";
    writeFileSync(
      probePath,
      `await Bun.write(${JSON.stringify(resultPath)}, JSON.stringify({\n` +
        ISOLATED_KEYS.map((key) =>
          `  ${JSON.stringify(key)}: process.env[${JSON.stringify(key)}] ?? null,\n`
        ).join("") +
        "}));\nawait Bun.sleep(5_000);\n",
    );
    session = await TmuxSession.create({
      cmd: `${process.execPath} ${probePath}`,
      startupWaitMs: 200,
      socketName,
      env: {
        AI_GATEWAY_API_KEY: explicitCredential,
        FX_RECORD_INPUT: explicitRecordInput,
      },
    });

    const resultDeadline = Date.now() + 5_000;
    while (!existsSync(resultPath) && Date.now() < resultDeadline) {
      await Bun.sleep(25);
    }
    expect(existsSync(resultPath)).toBe(true);
    const observed = JSON.parse(readFileSync(resultPath, "utf8"));
    expect(observed.AI_GATEWAY_API_KEY).toBe(explicitCredential);
    // A key the test sets itself is kept; every other stale one is gone. The
    // Token Pass check's credits URL is the harness's closed loopback port,
    // never a stale one.
    expect(observed.FX_RECORD_INPUT).toBe(explicitRecordInput);
    expect(observed.FX_TEST_GATEWAY_CREDITS_URL).toBe(localCreditsEnv({}).FX_TEST_GATEWAY_CREDITS_URL);
    for (const key of ISOLATED_KEYS) {
      if (key === "AI_GATEWAY_API_KEY" || key === "FX_RECORD_INPUT" || key === "FX_TEST_GATEWAY_CREDITS_URL") continue;
      expect(observed[key], `${key} reached the pane`).toBeNull();
    }

    const startCommand = execFileSync(
      "tmux",
      [
        "-L",
        socketName,
        "display-message",
        "-t",
        `${session.name}:0.0`,
        "-p",
        "#{pane_start_command}",
      ],
      { encoding: "utf8" },
    );
    expect(startCommand).not.toContain(explicitCredential);
    for (const value of Object.values(staleValues)) {
      expect(startCommand).not.toContain(value);
    }
    const sessionEnvironment = execFileSync(
      "tmux",
      ["-L", socketName, "show-environment", "-t", session.name],
      { encoding: "utf8" },
    );
    expect(sessionEnvironment).not.toContain("AI_GATEWAY_API_KEY=");
    expect(sessionEnvironment).not.toContain(explicitCredential);
  } finally {
    await session?.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], {
        stdio: "pipe",
      });
    } catch {}
    for (const [key, value] of originalValues) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(root, { recursive: true, force: true });
  }
});

test("every test hold fx reads is in the tmux launch's isolated keys", () => {
  const src = join(REPO_ROOT, "src");
  const holds = new Set<string>();
  for (const file of readdirSync(src, { recursive: true, encoding: "utf8" })) {
    if (!file.endsWith(".zig")) continue;
    const text = readFileSync(join(src, file), "utf8");
    for (const match of text.matchAll(/"(FX_TEST_[A-Z0-9_]+_(?:HELD|RELEASE))"/g)) holds.add(match[1]!);
  }
  expect(holds).toContain("FX_TEST_REPORT_DELIVERY_HELD");
  const isolated = new Set<string>(ISOLATED_KEYS);
  expect([...holds].filter((name) => !isolated.has(name))).toEqual([]);
});

/// The phases of the `workspace_capture` items that the profile's sessions
/// saved, from whole log lines only, so it can read a log fx still writes.
function savedCapturePhases(home: string): string[] {
  if (!existsSync(storeRoot(home))) return [];
  return savedSessionIds(home).flatMap((id) => {
    const log = join(storeRoot(home), id, "log.jsonl");
    if (!existsSync(log)) return [];
    return readFileSync(log, "utf8")
      .split("\n")
      .slice(0, -1)
      .map((line) => JSON.parse(line))
      .filter((line) => line.kind === "item" && line.type === "workspace_capture")
      .map((line) => (typeof line.data === "string" ? JSON.parse(line.data) : line.data).phase);
  });
}

// fx reads its holds in release builds. A start capture that sees its hold
// writes the marker, and a search that sees FX_TEST_GREP_RELEASE waits for a
// file that never comes, so the reply after it never shows.
tmuxFxTest("test holds in the tmux server's environment never reach fx", async () => {
  const socketName = `fx-held-env-${process.pid}-${Date.now().toString(36)}`;
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tmux-held-env-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "fx.stderr");
  const captureHeld = join(root, "capture-held");
  // A start capture that saw its hold goes on at once after its marker.
  const captureRelease = join(root, "capture-release");
  const grepRelease = join(root, "grep-release");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { workspace_capture: true } }));
  writeFileSync(join(workspace, "notes.txt"), "needle\n");
  writeFileSync(captureRelease, "");
  for (const args of [["init", "-q", "-b", "main"], ["add", "notes.txt"], ["commit", "-q", "-m", "first"]]) {
    execFileSync("git", ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", ...args], {
      cwd: workspace,
      env: { HOME: home, GIT_CONFIG_NOSYSTEM: "1", PATH: process.env.PATH ?? "/usr/bin:/bin" },
      stdio: "pipe",
    });
  }
  const gateway = startDynamicFakeGateway((body) =>
    body.includes("held-env-grep")
      ? fakeGatewayFinalText(HELD_ENV_REPLY)
      : fakeGatewayToolCall("held-env-grep", "grep_files", { pattern: "needle" })
  );

  let session: TmuxSession | undefined;
  try {
    execFileSync(
      "tmux",
      ["-L", socketName, ...TMUX_NO_CONFIG, "new-session", "-d", "-s", "fx-held-env-seed", "sleep 60"],
      {
        env: {
          ...process.env,
          FX_TEST_WORKSPACE_CAPTURE_START_HELD: captureHeld,
          FX_TEST_WORKSPACE_CAPTURE_START_RELEASE: captureRelease,
          FX_TEST_GREP_RELEASE: grepRelease,
        },
        stdio: "pipe",
      },
    );
    session = await TmuxSession.create({
      cwd: workspace,
      socketName,
      stderrPath,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-held-env-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
    });
    await session.waitForComposer();
    await session.sendText("Find the needle.");
    const replied = await session.waitForText(HELD_ENV_REPLY, HELD_ENV_WAIT_MS).then(() => true, () => false);
    // The saved start capture shows that the capture passed its hold point.
    await session.waitForPane(() => savedCapturePhases(home).includes("start"), HELD_ENV_WAIT_MS);
    expect(savedCapturePhases(home)).toContain("start");

    expect({ replied, captureHeld: existsSync(captureHeld) }).toEqual({ replied: true, captureHeld: false });
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    await session?.kill();
    gateway.stop();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], { stdio: "pipe" });
    } catch {}
    rmSync(root, { recursive: true, force: true });
  }
}, HELD_ENV_TEST_TIMEOUT_MS);

tmuxTest("pane environment does not poison a shared tmux server", async () => {
  const socketName = `fx-pe-${process.pid}-${Date.now().toString(36)}`;
  const root = mkdtempSync(join(tmpdir(), "fx-tmux-pane-env-isolation-"));
  const seededHome = join(root, "seeded-home");
  const probePath = join(root, "probe.mjs");
  const firstResultPath = join(root, "first.json");
  const secondResultPath = join(root, "second.json");
  const originalRecord = process.env.FX_RECORD;
  let first: TmuxSession | undefined;
  let second: TmuxSession | undefined;

  try {
    delete process.env.FX_RECORD;
    writeFileSync(
      probePath,
      `await Bun.write(process.argv[2], JSON.stringify({\n` +
        `  HOME: process.env.HOME ?? null,\n` +
        `  FX_RECORD: process.env.FX_RECORD ?? null,\n` +
        `}));\nawait Bun.sleep(5_000);\n`,
    );

    first = await TmuxSession.create({
      cmd: `${process.execPath} ${probePath} ${firstResultPath}`,
      socketName,
      startupWaitMs: 100,
      env: {
        HOME: seededHome,
        FX_RECORD: "stale-record-path",
      },
    });
    second = await TmuxSession.create({
      cmd: `${process.execPath} ${probePath} ${secondResultPath}`,
      socketName,
      startupWaitMs: 100,
    });

    const resultDeadline = Date.now() + 5_000;
    while (
      (!existsSync(firstResultPath) || !existsSync(secondResultPath)) &&
      Date.now() < resultDeadline
    ) {
      await Bun.sleep(25);
    }
    expect(existsSync(firstResultPath)).toBe(true);
    expect(existsSync(secondResultPath)).toBe(true);
    expect(JSON.parse(readFileSync(firstResultPath, "utf8"))).toEqual({
      HOME: seededHome,
      FX_RECORD: "stale-record-path",
    });
    expect(JSON.parse(readFileSync(secondResultPath, "utf8"))).toEqual({
      HOME: process.env.HOME ?? null,
      FX_RECORD: null,
    });
  } finally {
    await second?.kill();
    await first?.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], {
        stdio: "pipe",
      });
    } catch {}
    if (originalRecord === undefined) delete process.env.FX_RECORD;
    else process.env.FX_RECORD = originalRecord;
    rmSync(root, { recursive: true, force: true });
  }
});

tmuxTest("minimum history lines survive a fresh tmux server restart", async () => {
  const socketName = `fx-history-limit-${process.pid}-${Date.now()}`;
  let first: TmuxSession | undefined;
  let session: TmuxSession | undefined;
  try {
    first = await TmuxSession.create({
      cmd: "sleep 60",
      minimumHistoryLines: 100_000,
      socketName,
      startupWaitMs: 0,
    });
    expect(first.historyLimit()).toBe(100_000);
    await first.kill();
    first = undefined;

    session = await TmuxSession.create({
      cmd: "sleep 60",
      minimumHistoryLines: 100_000,
      socketName,
      startupWaitMs: 0,
    });
    expect(session.historyLimit()).toBe(100_000);
  } finally {
    await session?.kill();
    await first?.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], {
        stdio: "pipe",
      });
    } catch {}
  }
});

tmuxTest("a tmux server the harness starts ignores the developer's tmux config", async () => {
  const socketName = `fx-no-config-${process.pid}-${Date.now().toString(36)}`;
  const referenceSocket = `${socketName}-ref`;
  const home = mkdtempSync(join(tmpdir(), "fx-tmux-hostile-home-"));
  const hostileConfig = "set -g base-index 1\nset -g pane-base-index 1\nset -g remain-on-exit-format 'HOSTILE'\n";
  writeFileSync(join(home, ".tmux.conf"), hostileConfig);
  mkdirSync(join(home, ".config", "tmux"), { recursive: true });
  writeFileSync(join(home, ".config", "tmux", "tmux.conf"), hostileConfig);
  const savedHome = process.env.HOME;
  const savedConfigHome = process.env.XDG_CONFIG_HOME;
  const serverState = (socket: string, sessionName: string) => {
    const tmux = (...args: string[]) => execFileSync("tmux", ["-L", socket, ...args], { encoding: "utf8" }).trim();
    return {
      indexes: tmux("display-message", "-p", "-t", sessionName, "#{window_index}.#{pane_index}"),
      deadPaneFormat: tmux("show-options", "-gv", "remain-on-exit-format"),
    };
  };
  let session: TmuxSession | undefined;
  try {
    process.env.HOME = home;
    process.env.XDG_CONFIG_HOME = join(home, ".config");
    try {
      session = await TmuxSession.create({ cmd: "sleep 30", startupWaitMs: 0, socketName });
    } finally {
      if (savedHome === undefined) delete process.env.HOME;
      else process.env.HOME = savedHome;
      if (savedConfigHome === undefined) delete process.env.XDG_CONFIG_HOME;
      else process.env.XDG_CONFIG_HOME = savedConfigHome;
    }
    // tmux's defaults, from a server that loads no config at all.
    execFileSync("tmux", ["-L", referenceSocket, "-f", "/dev/null", "new-session", "-d", "-s", "reference", "sleep 30"]);
    expect(serverState(socketName, session.name)).toEqual(serverState(referenceSocket, "reference"));
  } finally {
    await session?.kill();
    for (const socket of [socketName, referenceSocket]) {
      try {
        execFileSync("tmux", ["-L", socket, "kill-server"], { stdio: "pipe" });
      } catch {}
    }
    rmSync(home, { recursive: true, force: true });
  }
});

tmuxTest("tmux launch drops an inherited FX_HOME unless the test passes one", async () => {
  const socketName = `fx-fx-home-${process.pid}-${Date.now()}`;
  const root = mkdtempSync(join(tmpdir(), "fx-tmux-fx-home-"));
  const previous = process.env.FX_HOME;
  const sessions: TmuxSession[] = [];
  const paneFxHome = async (name: string, env: Record<string, string>) => {
    const probePath = join(root, `${name}.mjs`);
    const resultPath = join(root, `${name}.json`);
    writeFileSync(
      probePath,
      `await Bun.write(${JSON.stringify(resultPath)}, JSON.stringify({ FX_HOME: process.env.FX_HOME ?? null }));\n` +
        "await Bun.sleep(5_000);\n",
    );
    sessions.push(await TmuxSession.create({
      cmd: `${process.execPath} ${probePath}`,
      startupWaitMs: 200,
      socketName,
      env,
    }));
    const deadline = Date.now() + 5_000;
    while (!existsSync(resultPath) && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(existsSync(resultPath)).toBe(true);
    return JSON.parse(readFileSync(resultPath, "utf8")).FX_HOME;
  };

  try {
    process.env.FX_HOME = join(root, "developer-profile");
    expect(await paneFxHome("inherited", {})).toBeNull();

    const explicit = join(root, "test-profile");
    expect(await paneFxHome("explicit", { FX_HOME: explicit })).toBe(explicit);
  } finally {
    for (const session of sessions) await session.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], {
        stdio: "pipe",
      });
    } catch {}
    if (previous === undefined) delete process.env.FX_HOME;
    else process.env.FX_HOME = previous;
    rmSync(root, { recursive: true, force: true });
  }
});

test("envWithoutFxHome drops FX_HOME and keeps the rest", () => {
  const env = { FX_HOME: "/Users/example/profile", HOME: "/Users/example", PATH: "/usr/bin" };

  expect(envWithoutFxHome(env)).toEqual({ HOME: "/Users/example", PATH: "/usr/bin" });
  expect(env.FX_HOME).toBe("/Users/example/profile");
});

test("fxChildEnv drops every name on the unset list and keeps the caller's own", () => {
  const inherited: Record<string, string> = { PATH: "/usr/bin" };
  for (const key of DEFAULT_UNSET_ENV_KEYS) inherited[key] = `stale-${key.toLowerCase()}`;

  expect(fxChildEnv({}, { inherited })).toEqual({ PATH: "/usr/bin" });
  expect(fxChildEnv({ HOME: "/Users/example", FX_HOME: "/Users/example/profile", NO_COLOR: undefined }, { inherited })).toEqual({
    PATH: "/usr/bin",
    HOME: "/Users/example",
    FX_HOME: "/Users/example/profile",
    NO_COLOR: undefined,
  });
  expect(fxChildEnv({}, { inherited, keepCredentials: true })).toEqual({
    PATH: "/usr/bin",
    AI_GATEWAY_API_KEY: "stale-ai_gateway_api_key",
    VERCEL_OIDC_TOKEN: "stale-vercel_oidc_token",
  });
  expect(inherited.FX_TEST_SHELL_YIELD_HELD).toBe("stale-fx_test_shell_yield_held");
});

test("buildEvalProcessEnv drops the inherited FX_HOME", () => {
  const previous = process.env.FX_HOME;
  process.env.FX_HOME = "/Users/example/profile";

  try {
    const env = buildEvalProcessEnv("/tmp/fx-eval-home-test", "selected/model");

    expect(env).not.toHaveProperty("FX_HOME");
    expect(env.HOME).toBe("/tmp/fx-eval-home-test");
  } finally {
    if (previous === undefined) delete process.env.FX_HOME;
    else process.env.FX_HOME = previous;
  }
});

test("runFx takes the process snapshot after a timeout or a signal", () => {
  expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: false })).toBe(false);
  expect(needsProcessSnapshot({ code: 2, signal: null, timedOut: false })).toBe(false);
  expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: true })).toBe(true);
  expect(needsProcessSnapshot({ code: null, signal: "SIGTERM", timedOut: false })).toBe(true);
});

test("runFx takes the process snapshot on a plain failure when asked", () => {
  expect(needsProcessSnapshot({ code: 2, signal: null, timedOut: false }, true)).toBe(true);
  expect(needsProcessSnapshot({ code: 0, signal: null, timedOut: false }, true)).toBe(false);
});

test.skipIf(!existsSync(FX_BIN))(
  "runFx passes FX_HOME to fx only when the test sets it",
  async () => {
    const previous = process.env.FX_HOME;
    const home = createIsolatedTestHome();
    const fxHome = createIsolatedTestHome();
    writeFileSync(join(fxHome, "settings.json"), '{"update_channel":"dev"}\n');
    process.env.FX_HOME = fxHome;
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
    };

    try {
      const inherited = await runFx(["status", "--json"], { env });
      expect(inherited.code).toBe(0);
      expect(JSON.parse(inherited.stdout).update_channel).toBe("stable");

      const passed = await runFx(["status", "--json"], { env: { ...env, FX_HOME: fxHome } });
      expect(passed.code).toBe(0);
      expect(JSON.parse(passed.stdout).update_channel).toBe("dev");
    } finally {
      if (previous === undefined) delete process.env.FX_HOME;
      else process.env.FX_HOME = previous;
      cleanupIsolatedTestHome(fxHome);
      cleanupIsolatedTestHome(home);
    }
  },
);
