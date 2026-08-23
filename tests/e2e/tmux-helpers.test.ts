import { expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  buildObservedCommand,
  heldFakeGatewayFinalText,
  isVolatileTokenStatusRow,
  paneExitMatches,
  parseSingleChildPid,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { XDG_ENV_KEYS } from "../test-support/profile-env";

const tmuxTest = test.skipIf(!tmuxAvailable());
const ISOLATED_KEYS = [
  "AI_GATEWAY_API_KEY",
  "VERCEL_OIDC_TOKEN",
  "FX_E2E_GATEWAY_CHAT_URL",
  "FX_E2E_GATEWAY_MODELS_URL",
  "FX_E2E_GATEWAY_CREDITS_URL",
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
    expect(observed.FX_E2E_GATEWAY_CHAT_URL).toBeNull();
    expect(observed.FX_E2E_GATEWAY_MODELS_URL).toBeNull();
    expect(observed.FX_E2E_GATEWAY_CREDITS_URL).toBeNull();

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

tmuxTest("tmux launch pins the XDG roots inside the pane HOME", async () => {
  const socketName = `fx-xdg-${process.pid}-${Date.now().toString(36)}`;
  const root = mkdtempSync(join(tmpdir(), "fx-tmux-xdg-isolation-"));
  const paneHome = join(root, "pane-home");
  const hostStateHome = join(root, "host-state");
  const probePath = join(root, "probe.mjs");
  const resultPath = join(root, "result.json");
  const staleValues = {
    XDG_CONFIG_HOME: join(root, "host-config"),
    XDG_STATE_HOME: hostStateHome,
    XDG_DATA_HOME: join(root, "host-data"),
  };
  for (const value of Object.values(staleValues)) mkdirSync(value, { recursive: true });
  mkdirSync(paneHome, { recursive: true });

  let session: TmuxSession | undefined;
  try {
    // A tmux server started from a shell that exports the XDG variables keeps them in its own
    // environment, which is exactly the developer machine the suite must be immune to.
    execFileSync(
      "tmux",
      ["-L", socketName, "new-session", "-d", "-s", "fx-xdg-seed", "sleep 60"],
      { env: { ...process.env, ...staleValues }, stdio: "pipe" },
    );

    writeFileSync(
      probePath,
      `await Bun.write(${JSON.stringify(resultPath)}, JSON.stringify({\n` +
        XDG_ENV_KEYS.map((key) =>
          `  ${JSON.stringify(key)}: process.env[${JSON.stringify(key)}] ?? null,\n`
        ).join("") +
        "}));\nawait Bun.sleep(5_000);\n",
    );
    session = await TmuxSession.create({
      cmd: `${process.execPath} ${probePath}`,
      socketName,
      startupWaitMs: 200,
      env: { HOME: paneHome },
    });

    const resultDeadline = Date.now() + 5_000;
    while (!existsSync(resultPath) && Date.now() < resultDeadline) {
      await Bun.sleep(25);
    }
    expect(existsSync(resultPath)).toBe(true);
    expect(JSON.parse(readFileSync(resultPath, "utf8"))).toEqual({
      XDG_CONFIG_HOME: join(paneHome, ".config"),
      XDG_STATE_HOME: join(paneHome, ".local", "state"),
      XDG_DATA_HOME: join(paneHome, ".local", "share"),
    });
    // The seeded host state root stays untouched: nothing the pane runs can reach it.
    expect(readdirSync(hostStateHome)).toEqual([]);
  } finally {
    await session?.kill();
    try {
      execFileSync("tmux", ["-L", socketName, "kill-server"], { stdio: "pipe" });
    } catch {}
    rmSync(root, { recursive: true, force: true });
  }
});
