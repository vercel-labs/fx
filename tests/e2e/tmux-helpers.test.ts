import { expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
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
  envWithoutFxHome,
  FX_BIN,
  needsProcessSnapshot,
  runFx,
} from "../evals/eval-helpers";
import {
  buildObservedCommand,
  heldFakeGatewayFinalText,
  isVolatileTokenStatusRow,
  paneExitMatches,
  parseSingleChildPid,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const tmuxTest = test.skipIf(!tmuxAvailable());
const ISOLATED_KEYS = [
  "AI_GATEWAY_API_KEY",
  "VERCEL_OIDC_TOKEN",
  "FX_TEST_GATEWAY_CHAT_URL",
  "FX_TEST_GATEWAY_MODELS_URL",
  "FX_TEST_GATEWAY_CREDITS_URL",
] as const;

test("pane exit matching requires the expected observed status", () => {
  expect(paneExitMatches({ dead: false, status: null }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: null }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: 0 }, 0)).toBe(true);
  expect(paneExitMatches({ dead: true, status: 1 }, 0)).toBe(false);
  expect(paneExitMatches({ dead: true, status: 37 }, 37)).toBe(true);
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
      ["-L", socketName, "new-session", "-d", "-s", "fx-stale-env-seed", "sleep 60"],
      { env: seedEnv, stdio: "pipe" },
    );

    for (const key of ISOLATED_KEYS) delete process.env[key];

    const explicitCredential = "explicit-auth-sentinel";
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
      },
    });

    const resultDeadline = Date.now() + 5_000;
    while (!existsSync(resultPath) && Date.now() < resultDeadline) {
      await Bun.sleep(25);
    }
    expect(existsSync(resultPath)).toBe(true);
    const observed = JSON.parse(readFileSync(resultPath, "utf8"));
    expect(observed.AI_GATEWAY_API_KEY).toBe(explicitCredential);
    expect(observed.VERCEL_OIDC_TOKEN).toBeNull();
    expect(observed.FX_TEST_GATEWAY_CHAT_URL).toBeNull();
    expect(observed.FX_TEST_GATEWAY_MODELS_URL).toBeNull();
    expect(observed.FX_TEST_GATEWAY_CREDITS_URL).toBeNull();

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
