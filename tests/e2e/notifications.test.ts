import { expect, test } from "bun:test";
import {
  chmodSync,
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
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";

function createNotificationRoot(
  notifications = { turn_end: true, attention_required: true },
) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-notifications-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const profile = join(home, ".fx");
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  chmodSync(profile, 0o700);
  const settingsPath = join(profile, "settings.json");
  writeFileSync(
    settingsPath,
    JSON.stringify({
      permission_mode: "ask",
      notifications,
    }),
    { mode: 0o600 },
  );
  chmodSync(settingsPath, 0o600);
  return { root, home, workspace: realpathSync(workspace) };
}

function notificationEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
  tracePath: string,
) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-notification-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    // Sound behavior under test: skip the harness-wide FX_SOUND=0 default so
    // the fixture settings and platform default stay authoritative.
    FX_SOUND: undefined,
    FX_TRACE_LOG: tracePath,
    FX_TRACE_SCOPES: "hooks,notifications",
    NO_COLOR: "1",
  };
}

async function waitForTrace(
  path: string,
  predicate: (trace: string) => boolean,
  timeoutMs = TIMEOUT,
) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const trace = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (predicate(trace)) return trace;
    await Bun.sleep(50);
  }
  const trace = existsSync(path) ? readFileSync(path, "utf8") : "";
  throw new Error(`Timed out waiting for notification trace.\n${trace}`);
}

function bellCount(path: string) {
  if (!existsSync(path)) return 0;
  return [...readFileSync(path)].filter((byte) => byte === 0x07).length;
}

async function waitForBellCount(path: string, expected: number) {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    if (bellCount(path) === expected) return;
    await Bun.sleep(50);
  }
  throw new Error(
    `Timed out waiting for ${expected} terminal bell(s); received ${bellCount(path)}.`,
  );
}

function handlerStartCount(trace: string, lifecycleEvent: string) {
  return trace
    .split("\n")
    .filter((line) =>
      line.includes("[hooks] event=handler_start") &&
      line.includes(`lifecycle_event=${lifecycleEvent}`)
    )
    .length;
}

function handlerTurnId(trace: string, lifecycleEvent: string) {
  const line = trace
    .split("\n")
    .find((candidate) =>
      candidate.includes("[hooks] event=handler_start") &&
      candidate.includes(`lifecycle_event=${lifecycleEvent}`)
    );
  const match = line?.match(/\bturn_id=(\d+)\b/);
  if (!match) throw new Error(`Missing ${lifecycleEvent} turn ID.\n${trace}`);
  return Number(match[1]);
}

test.skipIf(!tmuxAvailable())(
  "/sound toggles both events immediately and persists the profile",
  async () => {
    const fixture = createNotificationRoot({
      turn_end: false,
      attention_required: false,
    });
    const gateway = startFakeGateway([
      fakeGatewayFinalText("NOTIFICATION_COMMAND_COMPLETE"),
    ]);
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    const settingsPath = join(fixture.home, ".fx", "settings.json");
    writeFileSync(stderrPath, "");
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: notificationEnv(fixture.home, gateway, tracePath),
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/sound");
      await session.waitForText("● Sound: on", TIMEOUT);
      expect(await session.captureFullScrollback()).not.toContain(
        "saved to user settings",
      );

      let settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(settings.notifications).toEqual({
        turn_end: true,
        attention_required: true,
        max: false,
      });

      await session.sendText("/sound off");
      await session.waitForText("● Sound: off", TIMEOUT);
      settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(settings.notifications).toEqual({
        turn_end: false,
        attention_required: false,
        max: false,
      });

      await session.sendText("/sound on");
      await session.waitForPane(
        (pane) => (pane.match(/● Sound: on/g)?.length ?? 0) >= 2,
        TIMEOUT,
      );
      settings = JSON.parse(readFileSync(settingsPath, "utf8"));
      expect(settings.notifications).toEqual({
        turn_end: true,
        attention_required: true,
        max: false,
      });

      await session.sendText("Finish this command-enabled notification fixture.");
      await session.waitForText("NOTIFICATION_COMMAND_COMPLETE", TIMEOUT);
      const trace = await waitForTrace(
        tracePath,
        (value) => handlerStartCount(value, "PostTurnEnd") === 1,
      );

      expect(handlerStartCount(trace, "PostTurnEnd")).toBe(1);
      expect(trace).toContain("handler=fx.sound.turn_end");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "/trace plays the model-switch click only on success with sound enabled",
  async () => {
    const fixture = createNotificationRoot({
      turn_end: false,
      attention_required: false,
    });
    const gateway = startFakeGateway([]);
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    const clipboardPath = join(fixture.root, "clipboard-path.txt");
    const bin = join(fixture.root, "bin");
    mkdirSync(bin);
    const clipboardCommand = join(bin, "osascript");
    writeFileSync(
      clipboardCommand,
      '#!/bin/sh\nfor arg in "$@"; do last="$arg"; done\nprintf "%s" "$last" > "$FX_TRACE_CLIPBOARD_OUTPUT"\n',
      { mode: 0o755 },
    );
    writeFileSync(stderrPath, "");
    let session: TmuxSession | null = null;
    const click = "sound play cue=click trigger=direct";
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          ...notificationEnv(fixture.home, gateway, tracePath),
          PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          TMPDIR: fixture.root,
          FX_TRACE_CLIPBOARD_OUTPUT: clipboardPath,
        },
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      const success = process.platform === "darwin"
        ? "Trace copied to clipboard"
        : "Trace saved at";
      for (const enabled of [false, true]) {
        await session.sendText(`/sound ${enabled ? "on" : "off"}`);
        await session.waitForText(`● Sound: ${enabled ? "on" : "off"}`, TIMEOUT);
        await session.sendText("/trace");
        await session.waitForPane(
          (pane) => pane.split(success).length - 1 === (enabled ? 2 : 1),
          TIMEOUT,
        );
        await session.waitForStableComposer(TIMEOUT);
        if (enabled) await waitForTrace(tracePath, (trace) => trace.includes(click));
        const trace = readFileSync(tracePath, "utf8");
        expect(trace.split(click).length - 1).toBe(enabled ? 1 : 0);
        const reports = readdirSync(fixture.root).filter((name) => name.startsWith("fx-trace-") && name.endsWith(".md"));
        expect(reports).toHaveLength(enabled ? 2 : 1);
        for (const report of reports) {
          expect(readFileSync(join(fixture.root, report), "utf8")).toContain("# fx trace");
        }
        if (process.platform === "darwin") {
          expect(reports.map((name) => join(fixture.root, name))).toContain(readFileSync(clipboardPath, "utf8"));
        }
      }
      if (process.platform === "darwin") {
        writeFileSync(clipboardCommand, "#!/bin/sh\nexit 1\n");
        await session.sendText("/trace");
        await session.waitForText("Clipboard copy failed", TIMEOUT);
        await session.waitForStableComposer(TIMEOUT);
        expect(readFileSync(tracePath, "utf8").split(click).length - 1).toBe(1);
      }
      expect(await session.captureFullScrollback()).toContain(success);
      expect(gateway.requests).toHaveLength(0);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "copy undo and feedback play their assigned cues only in max mode on success",
  async () => {
    const fixture = createNotificationRoot({ turn_end: false, attention_required: false });
    const modes = ["off", "on", "max"] as const;
    const gateway = startFakeGateway(modes.flatMap((mode) => [
      fakeGatewayToolCall(`write_${mode}`, "write_file", { path: "tracked.txt", content: mode }),
      fakeGatewayFinalText(`COMMAND_SOUND_${mode}`),
    ]));
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    const clipboardPath = join(fixture.root, "clipboard.txt");
    const openedUrlPath = join(fixture.root, "opened-url.txt");
    const failurePath = join(fixture.root, "host-failure");
    const trackedPath = join(fixture.workspace, "tracked.txt");
    const bin = join(fixture.root, "bin");
    mkdirSync(bin);
    const failIfRequested = 'if [ -e "$FX_SOUND_HOST_FAILURE" ]; then exit 1; fi\n';
    for (const command of ["pbcopy", "xclip"]) {
      writeFileSync(join(bin, command), '#!/bin/sh\n' + failIfRequested + 'cat > "$FX_SOUND_CLIPBOARD"\n', { mode: 0o755 });
    }
    for (const command of ["open", "xdg-open"]) {
      writeFileSync(join(bin, command), '#!/bin/sh\n' + failIfRequested + 'printf "%s" "$1" > "$FX_SOUND_OPENED_URL"\n', { mode: 0o755 });
    }
    writeFileSync(trackedPath, "original");
    writeFileSync(stderrPath, "");
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          ...notificationEnv(fixture.home, gateway, tracePath),
          FX_PERMISSION_MODE: "full-access",
          PATH: `${bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
          FX_SOUND_CLIPBOARD: clipboardPath,
          FX_SOUND_OPENED_URL: openedUrlPath,
          FX_SOUND_HOST_FAILURE: failurePath,
        },
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      const expectedCues: string[] = [];
      async function runCommand(command: string, notice: string, cue?: "click" | "release") {
        const before = (await session!.captureFullScrollback()).split(notice).length;
        await session!.sendText(command);
        await session!.waitForStableScrollback((text) => text.split(notice).length > before, TIMEOUT);
        await session!.waitForStableComposer(TIMEOUT);
        if (cue) expectedCues.push(cue);
        const cues = readFileSync(tracePath, "utf8").split("\n").flatMap((line) => {
          const match = line.match(/sound play cue=(click|release) trigger=max/);
          return match ? [match[1]!] : [];
        });
        expect(cues).toEqual(expectedCues);
      }
      await runCommand("/sound max", "● Sound: max");
      await runCommand("/copy", "No assistant reply to copy.");
      await runCommand("/undo", "Nothing to undo.");
      for (const mode of modes) {
        await runCommand(`/sound ${mode}`, `● Sound: ${mode}`);
        await session.sendText(`Write the ${mode} fixture.`);
        await session.waitForText(`COMMAND_SOUND_${mode}`, TIMEOUT);
        await session.waitForStableComposer(TIMEOUT);
        expect(readFileSync(trackedPath, "utf8")).toBe(mode);
        await runCommand("/copy", "Copied to clipboard.", mode === "max" ? "release" : undefined);
        expect(readFileSync(clipboardPath, "utf8")).toContain(`COMMAND_SOUND_${mode}`);
        await runCommand("/undo", "Restored ", mode === "max" ? "release" : undefined);
        expect(readFileSync(trackedPath, "utf8")).toBe("original");
        await runCommand("/feedback", "Opened https://fx.sh/feedback.", mode === "max" ? "click" : undefined);
        expect(readFileSync(openedUrlPath, "utf8")).toBe("https://fx.sh/feedback");
      }
      writeFileSync(failurePath, "fail");
      await runCommand("/copy", "Failed to copy to clipboard.");
      await runCommand("/feedback", "Could not open https://fx.sh/feedback.");
      await runCommand("/undo", "Nothing to undo.");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "notifications sound handler runs after a real interactive turn",
  async () => {
    const fixture = createNotificationRoot();
    const gateway = startFakeGateway([
      fakeGatewayFinalText("NOTIFICATION_TURN_COMPLETE"),
    ]);
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    writeFileSync(stderrPath, "");
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: notificationEnv(fixture.home, gateway, tracePath),
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Finish this notification fixture.");
      await session.waitForText("NOTIFICATION_TURN_COMPLETE", TIMEOUT);
      const trace = await waitForTrace(
        tracePath,
        (value) => handlerStartCount(value, "PostTurnEnd") === 1,
      );

      expect(handlerStartCount(trace, "PostTurnEnd")).toBe(1);
      expect(trace).toContain("handler=fx.sound.turn_end");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx ask keeps redirected stdout JSON and stderr byte-clean with notifications enabled",
  async () => {
    const fixture = createNotificationRoot();
    const gateway = startFakeGateway([
      fakeGatewayFinalText("NOTIFICATION_ASK_COMPLETE"),
    ]);
    const tracePath = join(fixture.root, "trace.log");
    try {
      const result = await runFx(
        ["ask", "--json", "--no-save", "Finish the ask notification fixture."],
        {
          cwd: fixture.workspace,
          env: notificationEnv(fixture.home, gateway, tracePath),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output.trim()).toBe("NOTIFICATION_ASK_COMPLETE");
      expect(result.stderr).toBe("");
      const trace = await waitForTrace(
        tracePath,
        (value) => handlerStartCount(value, "PostTurnEnd") === 1,
      );
      expect(trace).toContain("scope=ask");
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "fx ask correlates permission attention and turn-end notifications",
  async () => {
    const fixture = createNotificationRoot();
    const marker = join(fixture.workspace, "ask-permission-marker.txt");
    const gateway = startFakeGateway([
      fakeShellRun("ask_permission_1", "touch ask-permission-marker.txt", {
        timeout_ms: 600_000,
      }),
      fakeGatewayFinalText("NOTIFICATION_ASK_PERMISSION_COMPLETE"),
    ]);
    const tracePath = join(fixture.root, "trace.log");
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: `${FX_BIN} ask --no-save "Try the prepared command."`,
        cwd: fixture.workspace,
        env: notificationEnv(fixture.home, gateway, tracePath),
        remainOnExit: true,
      });
      await session.waitForText("Approve? [y/N]", TIMEOUT);
      expect(existsSync(marker)).toBe(false);
      await session.sendText("n");
      await session.waitForText("NOTIFICATION_ASK_PERMISSION_COMPLETE", TIMEOUT);

      const trace = await waitForTrace(
        tracePath,
        (value) =>
          handlerStartCount(value, "AttentionRequired") === 1 &&
          handlerStartCount(value, "PostTurnEnd") === 1,
      );
      const attentionTurnId = handlerTurnId(trace, "AttentionRequired");
      expect(attentionTurnId).toBeGreaterThan(0);
      expect(handlerTurnId(trace, "PostTurnEnd")).toBe(attentionTurnId);
      expect(trace).toContain("sound play kind=attention_required");
      expect(trace).toContain("sound play kind=turn_end");
      expect(existsSync(marker)).toBe(false);
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "notifications sound handler runs once when a real permission blocks",
  async () => {
    // Keep direct interaction sounds off so the raw pane capture isolates the
    // attention-required transition.
    const fixture = createNotificationRoot({
      turn_end: false,
      attention_required: true,
    });
    const marker = join(fixture.workspace, "permission-marker.txt");
    const gateway = startFakeGateway([
      fakeShellRun("permission_1", "touch permission-marker.txt", {
        timeout_ms: 600_000,
      }),
      fakeGatewayFinalText("NOTIFICATION_PERMISSION_COMPLETE"),
    ]);
    const tracePath = join(fixture.root, "trace.log");
    const stderrPath = join(fixture.root, "stderr.log");
    const paneOutputPath = join(fixture.root, "pane-output.bin");
    writeFileSync(stderrPath, "");
    writeFileSync(paneOutputPath, "");
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: notificationEnv(fixture.home, gateway, tracePath),
        stderrPath,
      });
      await session.waitForComposer(TIMEOUT);
      session.startPaneOutputCapture(paneOutputPath);
      await session.sendText("Try the prepared command.");
      await session.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
      const waitingTrace = await waitForTrace(
        tracePath,
        (value) => handlerStartCount(value, "AttentionRequired") === 1,
      );

      expect(handlerStartCount(waitingTrace, "AttentionRequired")).toBe(1);
      expect(waitingTrace).toContain("handler=fx.sound.attention_required");
      expect(existsSync(marker)).toBe(false);
      await waitForBellCount(paneOutputPath, 1);
      await Bun.sleep(250);
      expect(bellCount(paneOutputPath)).toBe(1);

      await session.sendKeys("3");
      await session.waitForText("NOTIFICATION_PERMISSION_COMPLETE", TIMEOUT);
      expect(existsSync(marker)).toBe(false);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
