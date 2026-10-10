import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";
const FINAL_TEXT = "PERMISSION_HOOK_FIXTURE_DONE";
const DENY_REASON = "Denied from phone by the fixture";

type Fixture = {
  root: string;
  home: string;
  workspace: string;
  settingsPath: string;
  markerPath: string;
  hookInputPath: string;
  hookPidPath: string;
};

type HookInput = {
  version: number;
  event: string;
  request_id: number;
  session_id: string | null;
  workspace_root: string;
  origin: string;
  tool: { name: string; call_id: string; arguments: Record<string, unknown> };
  prompt: {
    label: string;
    command: string | null;
    explanation: string | null;
    tool_arguments_preview: string | null;
    file: unknown;
  };
  choices: string[];
};

let session: TmuxSession | null = null;
const gateways: Array<{ stop(): void }> = [];
const roots: string[] = [];
const hookPids: number[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const pid of hookPids.splice(0)) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
  }
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createFixture(prefix: string): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  roots.push(root);
  const realWorkspace = realpathSync(workspace);
  return {
    root,
    home,
    workspace: realWorkspace,
    settingsPath: join(home, ".fx", "settings.json"),
    markerPath: join(realWorkspace, "hook-marker.txt"),
    hookInputPath: join(root, "hook-input.json"),
    hookPidPath: join(root, "hook.pid"),
  };
}

function writeHook(fixture: Fixture, body: string): string {
  const path = join(fixture.root, "permission-hook.sh");
  writeFileSync(
    path,
    [
      `cat > ${JSON.stringify(fixture.hookInputPath)}`,
      `echo $$ > ${JSON.stringify(fixture.hookPidPath)}`,
      body,
      "",
    ].join("\n"),
  );
  return path;
}

function writeSettings(
  fixture: Fixture,
  settings: Record<string, unknown>,
) {
  writeFileSync(
    fixture.settingsPath,
    JSON.stringify({ sandbox: "none", permission_mode: "ask", ...settings }) + "\n",
  );
}

function hookSetting(script: string, timeoutMs = 10_000) {
  return { command: ["/bin/sh", script], timeout_ms: timeoutMs };
}

function startCommandGateway(fixture: Fixture) {
  const gateway = startFakeGateway([
    fakeShellRun(
      "hook_command",
      `touch ${JSON.stringify(fixture.markerPath)} && printf 'HOOK_COMMAND_RAN\\n'`,
      { timeout_ms: 600_000 },
    ),
    fakeGatewayFinalText(FINAL_TEXT),
  ]);
  gateways.push(gateway);
  return gateway;
}

function gatewayEnv(fixture: Fixture, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "fake-permission-hook-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_PERMISSION_MODE: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

async function startInteractive(fixture: Fixture, gateway: ReturnType<typeof startFakeGateway>) {
  const stderrPath = join(fixture.root, "stderr.log");
  writeFileSync(stderrPath, "");
  session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: fixture.workspace,
    env: gatewayEnv(fixture, gateway),
    stderrPath,
    width: 110,
    height: 32,
  });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("Run the permission hook fixture command.");
  return { session, stderrPath };
}

async function waitFor(condition: () => boolean, label: string, timeoutMs = TIMEOUT) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function readHookPid(fixture: Fixture): number {
  const pid = Number(readFileSync(fixture.hookPidPath, "utf8").trim());
  expect(Number.isSafeInteger(pid)).toBe(true);
  expect(pid).toBeGreaterThan(1);
  hookPids.push(pid);
  return pid;
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readHookInput(fixture: Fixture): HookInput {
  return JSON.parse(readFileSync(fixture.hookInputPath, "utf8")) as HookInput;
}

describe("permission hook", () => {
  test.skipIf(!tmuxAvailable())(
    "an allow runs the exact command without a keypress and receives the prompt fx shows",
    async () => {
      const fixture = createFixture("fx-permission-hook-allow-");
      const hook = writeHook(fixture, `printf '{"decision":"allow"}'`);
      writeSettings(fixture, { permission_hook: hookSetting(hook) });
      const gateway = startCommandGateway(fixture);
      const { session: active, stderrPath } = await startInteractive(fixture, gateway);

      await active.waitForText(FINAL_TEXT, TIMEOUT);

      expect(existsSync(fixture.markerPath)).toBe(true);
      const input = readHookInput(fixture);
      expect(input.version).toBe(1);
      expect(input.event).toBe("permission_request");
      expect(Number.isSafeInteger(input.request_id)).toBe(true);
      expect(input.workspace_root).toBe(fixture.workspace);
      expect(input.session_id === null || typeof input.session_id === "string").toBe(true);
      expect(input.origin).toBe("session");
      expect(input.tool.name).toBe("shell");
      expect(input.tool.call_id).toBe("hook_command");
      expect(JSON.stringify(input.tool.arguments)).toContain("hook-marker.txt");
      expect(input.prompt.command).toContain("hook-marker.txt");
      expect(input.prompt.file).toBeNull();
      expect(input.choices).toEqual(["allow", "deny"]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "a deny blocks the command and gives the model the reason",
    async () => {
      const fixture = createFixture("fx-permission-hook-deny-");
      const hook = writeHook(
        fixture,
        `printf '{"decision":"deny","reason":"${DENY_REASON}"}'`,
      );
      writeSettings(fixture, { permission_hook: hookSetting(hook) });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(FINAL_TEXT, TIMEOUT);

      expect(existsSync(fixture.markerPath)).toBe(false);
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain(DENY_REASON);
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "no opinion leaves the prompt with the human",
    async () => {
      const fixture = createFixture("fx-permission-hook-none-");
      const hook = writeHook(fixture, `printf '{"decision":"allow"}'\nexit 1`);
      writeSettings(fixture, { permission_hook: hookSetting(hook) });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
      await waitFor(() => existsSync(fixture.hookPidPath), "hook start");
      const pid = readHookPid(fixture);
      await waitFor(() => !processAlive(pid), "hook exit");
      await Bun.sleep(300);
      expect(await active.capturePane()).toContain(COMMAND_APPROVAL_PROMPT);
      expect(existsSync(fixture.markerPath)).toBe(false);

      await active.sendKeys("1");
      await active.waitForText(FINAL_TEXT, TIMEOUT);
      expect(existsSync(fixture.markerPath)).toBe(true);
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "a hook past its timeout is stopped and the human still decides",
    async () => {
      const fixture = createFixture("fx-permission-hook-timeout-");
      const hook = writeHook(fixture, "exec sleep 30");
      writeSettings(fixture, { permission_hook: hookSetting(hook, 1_000) });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
      await waitFor(() => existsSync(fixture.hookPidPath), "hook start");
      const pid = readHookPid(fixture);
      await waitFor(() => !processAlive(pid), "hook stopped by its timeout", 10_000);
      expect(await active.capturePane()).toContain(COMMAND_APPROVAL_PROMPT);

      await active.sendKeys("1");
      await active.waitForText(FINAL_TEXT, TIMEOUT);
      expect(existsSync(fixture.markerPath)).toBe(true);
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "a human answer first stops the running hook",
    async () => {
      const fixture = createFixture("fx-permission-hook-human-");
      const hook = writeHook(fixture, "sleep 30 >/dev/null &\nexec >&-\nwait");
      writeSettings(fixture, { permission_hook: hookSetting(hook, 60_000) });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
      await waitFor(() => existsSync(fixture.hookPidPath), "hook start");
      const pid = readHookPid(fixture);
      expect(processAlive(pid)).toBe(true);

      await active.sendKeys("1");
      await active.waitForText(FINAL_TEXT, TIMEOUT);
      expect(existsSync(fixture.markerPath)).toBe(true);
      await waitFor(() => !processAlive(pid), "hook stopped after the human answer", 5_000);
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "a configured deny wins before the hook is asked",
    async () => {
      const fixture = createFixture("fx-permission-hook-rule-");
      const hook = writeHook(fixture, `printf '{"decision":"allow"}'`);
      writeSettings(fixture, {
        permission: { bash: "deny" },
        permission_hook: hookSetting(hook),
      });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(FINAL_TEXT, TIMEOUT);

      expect(existsSync(fixture.markerPath)).toBe(false);
      expect(existsSync(fixture.hookInputPath)).toBe(false);
    },
    TIMEOUT * 2,
  );

  test.skipIf(!tmuxAvailable())(
    "a project .fx.json cannot install a hook",
    async () => {
      const fixture = createFixture("fx-permission-hook-project-");
      const hook = writeHook(fixture, `printf '{"decision":"allow"}'`);
      writeSettings(fixture, {});
      writeFileSync(
        join(fixture.workspace, ".fx.json"),
        JSON.stringify({ permission_hook: hookSetting(hook) }) + "\n",
      );
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
      expect(existsSync(fixture.hookInputPath)).toBe(false);
      await active.sendKeys("1");
      await active.waitForText(FINAL_TEXT, TIMEOUT);
      expect(existsSync(fixture.markerPath)).toBe(true);
      expect(existsSync(fixture.hookInputPath)).toBe(false);
    },
    TIMEOUT * 2,
  );

  test(
    "headless fx ask never asks the hook",
    async () => {
      const fixture = createFixture("fx-permission-hook-headless-");
      const hook = writeHook(fixture, `printf '{"decision":"allow"}'`);
      writeSettings(fixture, { permission_hook: hookSetting(hook) });
      const gateway = startCommandGateway(fixture);

      const result = await runFx(
        ["ask", "--json", "--no-save", "Run the permission hook fixture command."],
        {
          cwd: fixture.workspace,
          env: gatewayEnv(fixture, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(JSON.parse(result.stdout.trim()).error).toBe("NonInteractivePermissionRequired");
      expect(existsSync(fixture.markerPath)).toBe(false);
      expect(existsSync(fixture.hookInputPath)).toBe(false);
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "interactive full access runs without asking the hook",
    async () => {
      const fixture = createFixture("fx-permission-hook-full-access-");
      const hook = writeHook(fixture, `printf '{"decision":"deny"}'`);
      writeSettings(fixture, {
        permission_mode: "yolo",
        yolo_acknowledged: true,
        permission_hook: hookSetting(hook),
      });
      const gateway = startCommandGateway(fixture);
      const { session: active } = await startInteractive(fixture, gateway);

      await active.waitForText(FINAL_TEXT, TIMEOUT);

      expect(await active.capturePane()).not.toContain(COMMAND_APPROVAL_PROMPT);
      expect(existsSync(fixture.markerPath)).toBe(true);
      expect(existsSync(fixture.hookInputPath)).toBe(false);
    },
    TIMEOUT * 2,
  );
});
