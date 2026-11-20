// Hooks on the real interactive screen. Each test drives fx through tmux against a
// fake gateway, checks what the person sees on the pane, and checks what really
// happened on disk, or in the gateway's log of requests.
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import { processAlive, processGroupAlive } from "./process-alive";
import {
  type FakeGatewayResponse,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 60_000;
const TEST_TIMEOUT = 150_000;
const MODEL = "acme/thinker";
const WAITING_NOTICE = "1 hook waits for trust and does not run. Run /hook list to review it.";
// The hook's own reason, which the model is sent as the call's result.
const DENY_REASON = "no rm";

// The model catalog of tui-effort-menu.test.ts: MODEL has the effort levels.
const catalog = [
  {
    id: MODEL,
    type: "language",
    released: 200,
    tags: ["reasoning", "tool-use"],
    reasoning_options: [{ type: "effort", values: ["low", "medium", "high", "xhigh"] }],
    context_window: 1_000_000,
    max_tokens: 32_000,
  },
];

type Fixture = { home: string; workspace: string; root: string };
type Shell = {
  session: TmuxSession;
  gateway: ReturnType<typeof startFakeGateway>;
  fixture: Fixture;
};

let shell: Shell | null = null;
const fixtures: Fixture[] = [];

afterEach(async () => {
  if (shell) {
    await shell.session.kill();
    shell.gateway.stop();
    shell = null;
  }
  for (const fixture of fixtures.splice(0)) {
    cleanupIsolatedTestHome(fixture.home);
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

// An isolated profile with hooks on, and an empty workspace. The test writes its hook files.
function makeFixture(): Fixture {
  const home = createIsolatedTestHome();
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ experimental: { hooks: true } }));
  const root = mkdtempSync(join(tmpdir(), "fx-tui-hooks-"));
  const workspace = join(root, "workspace");
  mkdirSync(workspace, { recursive: true });
  const fixture = { home, workspace: realpathSync(workspace), root };
  fixtures.push(fixture);
  return fixture;
}

function writeProjectHooks(fixture: Fixture, hooks: object): void {
  mkdirSync(join(fixture.workspace, ".fx"), { recursive: true });
  writeFileSync(join(fixture.workspace, ".fx", "hooks.json"), JSON.stringify(hooks));
}

// A PreToolUse hook on shell calls. It leaves a mark, then denies the call.
function guardHooks(workspace: string) {
  const mark = join(workspace, "hook-ran");
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: "shell",
          hooks: [{ type: "command", id: "guard", command: `touch '${mark}'; echo 'no rm' >&2; exit 2` }],
        },
      ],
    },
  };
}

// A ConfigChange hook that fails: fx keeps the change and shows a warning.
function failingConfigChangeHooks() {
  return {
    hooks: {
      ConfigChange: [{ hooks: [{ type: "command", id: "cfg-fail", command: "echo oops >&2; exit 1" }] }],
    },
  };
}

async function trust(fixture: Fixture, id: string): Promise<void> {
  const result = await runFx(["hook", "trust", id], {
    cwd: fixture.workspace,
    env: { HOME: fixture.home, AI_AGENT: undefined },
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
}

async function launch(fixture: Fixture, responses: FakeGatewayResponse[]): Promise<Shell> {
  return launchGateway(fixture, startFakeGateway(responses, { models: () => catalog }));
}

// Starts fx on the screen against a gateway the test built, so a test can answer by request body. `extraEnv` adds
// variables for one test, such as FX_TRACE_LOG, so the test can wait on a line fx writes.
async function launchGateway(
  fixture: Fixture,
  gateway: ReturnType<typeof startFakeGateway>,
  extraEnv: Record<string, string> = {},
): Promise<Shell> {
  const session = await TmuxSession.create({
    cwd: fixture.workspace,
    stderrPath: join(fixture.root, "stderr.log"),
    isolated: true,
    width: 120,
    height: 40,
    env: {
      HOME: fixture.home,
      AI_GATEWAY_API_KEY: "tui-hooks-key",
      VERCEL_OIDC_TOKEN: undefined,
      AI_AGENT: undefined,
      FX_MODEL: MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: "yolo",
      ...extraEnv,
    },
  });
  shell = { session, gateway, fixture };
  await session.waitForComposer(TIMEOUT);
  return shell;
}

function savedEffort(fixture: Fixture): string | undefined {
  const path = join(fixture.home, ".fx", "settings.json");
  if (!existsSync(path)) return undefined;
  return (JSON.parse(readFileSync(path, "utf8")) as { effort?: string }).effort;
}

function count(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

test.skipIf(!tmuxAvailable())(
  "/hook list shows the hooks of the workspace on the screen",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, guardHooks(fixture.workspace));
    const current = await launch(fixture, []);

    await current.session.sendText("/hook list");
    await current.session.waitForText(/guard.*waiting/, TIMEOUT);
    await current.session.waitForComposer(TIMEOUT);

    // Listing a hook never runs it.
    expect(existsSync(join(fixture.workspace, "hook-ran"))).toBe(false);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a waiting hook is told once and does not run",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, guardHooks(fixture.workspace));
    const marker = join(fixture.workspace, "ran-marker");
    const current = await launch(fixture, [
      fakeShellRun("shell_waiting_1", `touch '${marker}'`),
      fakeGatewayFinalText("FIRST_ANSWER"),
      fakeGatewayFinalText("SECOND_ANSWER"),
    ]);
    const { session, gateway } = current;

    await session.sendText("Create the marker.");
    await session.waitForText(WAITING_NOTICE, TIMEOUT);
    await session.waitForText("FIRST_ANSWER", TIMEOUT);
    await session.waitForComposer(TIMEOUT);

    // The shell call ran, and the waiting hook did not.
    expect(existsSync(marker)).toBe(true);
    expect(existsSync(join(fixture.workspace, "hook-ran"))).toBe(false);

    await session.sendText("Say hello again.");
    await session.waitForText("SECOND_ANSWER", TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    expect(gateway.requests.some((request) => request.body.includes("Say hello again."))).toBe(true);

    // The notice is shown once per session, not once per turn.
    const scrollback = await session.captureFullScrollback();
    expect(count(scrollback, WAITING_NOTICE)).toBe(1);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a trusted hook stops a shell call",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, guardHooks(fixture.workspace));
    await trust(fixture, "guard");
    const marker = join(fixture.workspace, "ran-marker");
    const current = await launch(fixture, [
      fakeShellRun("shell_denied_1", `touch '${marker}'`),
      fakeGatewayFinalText("DENIED_ANSWER"),
    ]);
    const { session, gateway } = current;

    await session.sendText("Create the marker.");
    // The screen shows the rejected call as failed; the hook's reason reaches the model.
    await session.waitForText("Failed touch './ran-marker'", TIMEOUT);
    // The hook, the tool it stopped, and its reason, as a warning on the screen.
    await session.waitForText("Hook guard blocked shell: no rm", TIMEOUT);
    await session.waitForText("DENIED_ANSWER", TIMEOUT);
    await session.waitForComposer(TIMEOUT);

    // The hook ran before the call, and the call did not run.
    expect(existsSync(join(fixture.workspace, "hook-ran"))).toBe(true);
    expect(existsSync(marker)).toBe(false);
    // The model was told why the call was denied.
    expect(gateway.requests.some((request) => request.body.includes(DENY_REASON))).toBe(true);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a failing ConfigChange hook is shown as a warning, and the setting still changes",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, failingConfigChangeHooks());
    await trust(fixture, "cfg-fail");
    const current = await launch(fixture, []);
    const { session } = current;

    await session.sendText("/effort high");
    await session.waitForText(/!\s+hooks:\s+Hook cfg-fail failed: exited with code 1: oops/, TIMEOUT);
    await session.waitForText("Reasoning effort set to high for acme/thinker", TIMEOUT);
    await session.waitForComposer(TIMEOUT);

    // A failing hook does not refuse the change, so the setting is saved.
    expect(savedEffort(fixture)).toBe("high");
  },
  TEST_TIMEOUT,
);

// The stop the interrupt test makes: Escape arms it, a second Escape stops the turn.
async function stopTurn(session: TmuxSession): Promise<void> {
  await session.sendKeys("Escape");
  await session.waitForText("esc again to interrupt", TIMEOUT);
  await session.sendKeys("Escape");
  await session.waitForText("What can fx do differently?", TIMEOUT);
  await session.waitForComposer(TIMEOUT);
}

// Polls until `condition` holds; fails with `label` at the deadline.
async function waitUntil(label: string, condition: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await Bun.sleep(20);
  }
  throw new Error(`timed out waiting for ${label}`);
}

// A subagent's requests carry none of the text the person typed to main, and the parent's always
// do, so the two tell apart (as sessions.test.ts does for the app).
function isAppChildRequest(body: string, typed: string[]): boolean {
  return !typed.some((text) => body.includes(text));
}

// A parent turn that a subagent's report started: the report is its latest user message.
function isReportTurn(body: string): boolean {
  const latest = JSON.stringify(JSON.parse(body).prompt?.filter((item: any) => item.role === "user").at(-1)?.content ?? "");
  return latest.includes("Subagent report (untrusted agent output, not user instructions):");
}

test.skipIf(!tmuxAvailable())(
  "an Interrupt hook runs when the person stops a turn",
  async () => {
    const fixture = makeFixture();
    const log = join(fixture.workspace, "interrupt.log");
    writeProjectHooks(fixture, {
      hooks: { Interrupt: [{ hooks: [{ type: "command", id: "stop-log", command: `echo stopped >> '${log}'` }] }] },
    });
    await trust(fixture, "stop-log");
    const current = await launch(fixture, [
      fakeShellRun("shell_slow_1", "sleep 20"),
      fakeGatewayFinalText("NEVER_SHOWN"),
    ]);
    const { session } = current;

    await session.sendText("Run the slow check.");
    await session.waitForText("Running sleep 20", TIMEOUT);
    await stopTurn(session);

    // The Interrupt hook runs once, after the stop, and its line lands in the workspace.
    await waitUntil("the Interrupt hook's line", () => existsSync(log), TIMEOUT);
    expect(readFileSync(log, "utf8").split("\n").filter((line) => line.length > 0)).toHaveLength(1);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a stop in the TUI ends a running hook and its child",
  async () => {
    const fixture = makeFixture();
    const pidFile = join(fixture.workspace, "hook.pid");
    const childPidFile = join(fixture.workspace, "child.pid");
    const marker = join(fixture.workspace, "tui-stop-marker");
    // The hook starts a background child, then waits for it: the stop must end both.
    writeProjectHooks(fixture, {
      hooks: {
        PreToolUse: [
          {
            matcher: "shell",
            hooks: [
              {
                type: "command",
                id: "tree",
                command: `sleep 30 & echo $! > '${childPidFile}'; echo $$ > '${pidFile}'; wait`,
                timeout: 60,
              },
            ],
          },
        ],
      },
    });
    await trust(fixture, "tree");
    const current = await launch(fixture, [
      fakeShellRun("shell_tree_1", `touch '${marker}'`),
      fakeGatewayFinalText("NEVER_SHOWN"),
    ]);
    const { session } = current;

    await session.sendText("Run the guarded command.");
    // The hook writes the child's pid, then its own, before it waits: wait for its own file.
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    const childPid = Number(readFileSync(childPidFile, "utf8").trim());
    expect(processAlive(pid)).toBe(true);
    expect(processAlive(childPid)).toBe(true);

    await stopTurn(session);
    await waitUntil("the stopped hook to end", () => !processAlive(pid), 5_000);
    await waitUntil("the hook's child to end", () => !processAlive(childPid), 5_000);
    // The call the hook guarded never ran.
    expect(existsSync(marker)).toBe(false);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a SIGTERM to the TUI ends a running hook and its process group",
  async () => {
    const fixture = makeFixture();
    const pidFile = join(fixture.workspace, "hook.pid");
    const marker = join(fixture.workspace, "tui-signal-marker");
    // The hook writes its pid before it sleeps: the pid file is the signal that the hook runs.
    writeProjectHooks(fixture, {
      hooks: {
        PreToolUse: [
          {
            matcher: "shell",
            hooks: [{ type: "command", id: "sleepy", command: `echo $$ > '${pidFile}'; exec sleep 30`, timeout: 60 }],
          },
        ],
      },
    });
    await trust(fixture, "sleepy");
    const current = await launch(fixture, [
      fakeShellRun("shell_signal_1", `touch '${marker}'`),
      fakeGatewayFinalText("NEVER_SHOWN"),
    ]);
    const { session } = current;

    await session.sendText("Run the guarded command.");
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(processGroupAlive(pid)).toBe(true);

    // The signal goes to the fx process itself. Its close path stops the hook group before fx ends (R3.9).
    process.kill(session.processPid(), "SIGTERM");
    await waitUntil("the hook's process group to end", () => !processGroupAlive(pid), 5_000);
    // The call the hook guarded never ran.
    expect(existsSync(marker)).toBe(false);
  },
  TEST_TIMEOUT,
);

// A trusted hook that writes its pid, then sleeps: `/hook test` runs it and waits, so the TUI can be tried while it runs.
function sleepingHookFixture(): { fixture: Fixture; pidFile: string } {
  const fixture = makeFixture();
  const pidFile = join(fixture.workspace, "hook.pid");
  writeProjectHooks(fixture, {
    hooks: {
      PreToolUse: [
        {
          matcher: "shell",
          hooks: [{ type: "command", id: "sleepy", command: `echo $$ > '${pidFile}'; exec sleep 30`, timeout: 60 }],
        },
      ],
    },
  });
  return { fixture, pidFile };
}

test.skipIf(!tmuxAvailable())(
  "typing still shows in the composer while a /hook test runs its hook",
  async () => {
    const { fixture, pidFile } = sleepingHookFixture();
    await trust(fixture, "sleepy");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);

    await session.sendText("/hook test PreToolUse --match shell");
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    await session.waitForText("Running /hook test", 5_000);

    // The verbs run off the UI thread, so a typed letter shows at once (R2.1).
    await session.sendLiteralText("typed while the hook runs");
    await session.waitForText("typed while the hook runs", 3_000);
    expect(processGroupAlive(pid)).toBe(true);

    // Stop the job, so no hook outlives the test.
    await session.sendKeys("Escape");
    await session.waitForText("esc again to interrupt", 5_000);
    await session.sendKeys("Escape");
    await waitUntil("the hook's process group to end", () => !processGroupAlive(pid), 5_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Esc twice stops a running /hook test: its hook group ends and the transcript says it was cancelled",
  async () => {
    const { fixture, pidFile } = sleepingHookFixture();
    await trust(fixture, "sleepy");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);

    await session.sendText("/hook test PreToolUse --match shell");
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(processGroupAlive(pid)).toBe(true);

    // Esc arms and a second Esc confirms, as it does for an active turn.
    await session.sendKeys("Escape");
    await session.waitForText("esc again to interrupt", 5_000);
    await session.sendKeys("Escape");
    await waitUntil("the hook's process group to end", () => !processGroupAlive(pid), 5_000);
    await session.waitForText("/hook test was cancelled", 5_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a fast /hook list still prints its table now that the verbs run off the UI thread",
  async () => {
    const { fixture } = sleepingHookFixture();
    await trust(fixture, "sleepy");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);

    await session.sendText("/hook list");
    await session.waitForText("sleepy", 10_000);
    await session.waitForComposer(TIMEOUT);
  },
  TEST_TIMEOUT,
);

// A trusted ConfigChange hook with one id. Shift+Tab changes the permission mode through it.
function configChangeHooks(id: string, command: string) {
  return { hooks: { ConfigChange: [{ hooks: [{ type: "command", id, command, timeout: 60 }] }] } };
}

test.skipIf(!tmuxAvailable())(
  "Shift+Tab waits for a ConfigChange hook: the working line shows, typing still works, and the mode changes when the hook allows",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "gate-open");
    writeProjectHooks(fixture, configChangeHooks("waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "waiter");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendKeys("BTab");
    await session.waitForText("Checking hooks for the permission mode", 5_000);
    // The UI thread keeps reading keys while the hook waits (R2.1).
    await session.sendLiteralText("typed while the check runs");
    await session.waitForText("typed while the check runs", 3_000);
    expect(await session.capturePane()).toContain("full access ·");

    // The hook allows the change once its gate file exists.
    writeFileSync(gate, "");
    await session.waitForText("ask ·", 10_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Esc twice stops a Shift+Tab check: its hook group ends, the mode keeps its value, and the notice says it was cancelled",
  async () => {
    const fixture = makeFixture();
    const pidFile = join(fixture.workspace, "config-hook.pid");
    writeProjectHooks(fixture, configChangeHooks("sleepy", `echo $$ > '${pidFile}'; exec sleep 30`));
    await trust(fixture, "sleepy");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendKeys("BTab");
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(processGroupAlive(pid)).toBe(true);

    // Esc arms and a second Esc confirms, as it does for an active turn.
    await session.sendKeys("Escape");
    await session.waitForText("esc again to interrupt", 5_000);
    await session.sendKeys("Escape");
    await waitUntil("the hook's process group to end", () => !processGroupAlive(pid), 5_000);
    await session.waitForText("The permission mode change was cancelled", 5_000);
    expect(await session.capturePane()).toContain("full access ·");
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a ConfigChange hook that refuses keeps the permission mode and shows its refusal",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, configChangeHooks("refuser", "echo 'no mode change' >&2; exit 2"));
    await trust(fixture, "refuser");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendKeys("BTab");
    await session.waitForText("A hook refused this setting change: no mode change", TIMEOUT);
    expect(await session.capturePane()).toContain("full access ·");
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a second Shift+Tab while a hook check waits is refused with a notice, and starts nothing",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "gate-never");
    writeProjectHooks(fixture, configChangeHooks("waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "waiter");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendKeys("BTab");
    await session.waitForText("Checking hooks for the permission mode", 5_000);
    await session.sendKeys("BTab");
    await session.waitForText("A hook check is still running. Press Esc twice to stop it.", 5_000);

    // Esc twice stops the first check, so the test ends with no hook left running.
    await session.sendKeys("Escape");
    await session.waitForText("esc again to interrupt", 5_000);
    await session.sendKeys("Escape");
    await session.waitForText("The permission mode change was cancelled", 5_000);
    expect(await session.capturePane()).toContain("full access ·");
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a ConfigChange refusal whose reason holds an ESC sequence shows the sequence as text, with no color from it",
  async () => {
    const fixture = makeFixture();
    // printf writes an ESC sequence to stderr, and that is the hook's refusal reason.
    writeProjectHooks(fixture, configChangeHooks("colored", "printf '\\033[31mred alert\\033[0m' >&2; exit 2"));
    await trust(fixture, "colored");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendKeys("BTab");
    await session.waitForText("A hook refused this setting change: \\x1b[31mred alert\\x1b[0m", TIMEOUT);
    // The hook's sequence is text on the screen. No raw escape from the hook reaches the terminal as a color (R4.6).
    expect(await session.capturePaneEscapes()).not.toContain("\x1b[31mred alert");
    expect(await session.capturePane()).toContain("full access ·");
  },
  TEST_TIMEOUT,
);

// A second model for the switch tests. MODEL keeps its effort levels, and this one has none.
const SWITCH_MODEL = "acme/other";
const switchCatalog = [
  ...catalog,
  { id: SWITCH_MODEL, type: "language", released: 200, tags: ["tool-use"], context_window: 1_000_000, max_tokens: 32_000 },
];

// A hook on one event, with its id and command.
function eventHooks(event: string, id: string, command: string) {
  return { hooks: { [event]: [{ hooks: [{ type: "command", id, command }] }] } };
}

// Starts fx on a gateway that lists the second model, so /model can switch to it.
async function launchSwitchable(fixture: Fixture, responses: FakeGatewayResponse[]): Promise<Shell> {
  return launchGateway(fixture, startFakeGateway(responses, { models: () => switchCatalog }));
}

// Runs a /model line for the second model. sendText types the line and presses Enter, as the other TUI tests do.
async function runModelSwitch(session: TmuxSession): Promise<void> {
  await session.sendText(`/model ${SWITCH_MODEL}`);
}

test.skipIf(!tmuxAvailable())(
  "a PreModelSwitch hook that waits holds /model: the working line shows, typing still works, and the model changes when the hook allows",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "model-gate-open");
    writeProjectHooks(fixture, eventHooks("PreModelSwitch", "model-waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "model-waiter");
    const { session } = await launchSwitchable(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await runModelSwitch(session);
    await session.waitForText("Checking hooks for the model change", 5_000);
    // The UI thread keeps reading keys while the hook waits (R2.1).
    await session.sendLiteralText("typed while the check runs");
    await session.waitForText("typed while the check runs", 3_000);
    expect(await session.capturePane()).not.toContain(`Switched to ${SWITCH_MODEL}`);

    // The hook allows the change once its gate file exists.
    writeFileSync(gate, "");
    await session.waitForText(`Switched to ${SWITCH_MODEL}`, 10_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Esc twice stops a /model check: the model keeps its value, the hook's process group ends, and the notice says it was cancelled",
  async () => {
    const fixture = makeFixture();
    const pidFile = join(fixture.workspace, "model-hook.pid");
    writeProjectHooks(fixture, eventHooks("PreModelSwitch", "model-sleepy", `echo $$ > '${pidFile}'; exec sleep 30`));
    await trust(fixture, "model-sleepy");
    const { session } = await launchSwitchable(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await runModelSwitch(session);
    await waitUntil("the hook's pid file", () => existsSync(pidFile), TIMEOUT);
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(processGroupAlive(pid)).toBe(true);

    // Esc arms and a second Esc confirms, as it does for an active turn.
    await session.sendKeys("Escape");
    await session.waitForText("esc again to interrupt", 5_000);
    await session.sendKeys("Escape");
    await waitUntil("the hook's process group to end", () => !processGroupAlive(pid), 5_000);
    await session.waitForText("The model change was cancelled. Its hooks were stopped.", 5_000);
    expect(await session.capturePane()).not.toContain(`Switched to ${SWITCH_MODEL}`);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a PreModelSwitch hook that refuses keeps the model and shows its refusal",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, eventHooks("PreModelSwitch", "model-no", "echo no model >&2; exit 2"));
    await trust(fixture, "model-no");
    const { session } = await launchSwitchable(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await runModelSwitch(session);
    await session.waitForText("A hook refused the model change: no model", TIMEOUT);
    expect(await session.capturePane()).not.toContain(`Switched to ${SWITCH_MODEL}`);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a PostModelSwitch hook that waits does not hold typing: the switch applies at once, and the hook's notice shows when it allows",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "post-gate-open");
    const command = `while [ ! -f '${gate}' ]; do sleep 0.05; done; printf '%s' '{"systemMessage":"switch noted"}'`;
    writeProjectHooks(fixture, eventHooks("PostModelSwitch", "post-waiter", command));
    await trust(fixture, "post-waiter");
    const { session } = await launchSwitchable(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    // No PreModelSwitch hook runs, so the model applies at once.
    await runModelSwitch(session);
    await session.waitForText(`Switched to ${SWITCH_MODEL}`, 5_000);
    await session.waitForText("Running the model switch hooks", 5_000);
    await session.sendLiteralText("typed while the switch hooks run");
    await session.waitForText("typed while the switch hooks run", 3_000);

    writeFileSync(gate, "");
    await session.waitForText("Hook post-waiter: switch noted", 10_000);
  },
  TEST_TIMEOUT,
);

// Whether the profile saves prompt history as off.
function promptHistoryDisabled(fixture: Fixture): boolean {
  const path = join(fixture.home, ".fx", "settings.json");
  if (!existsSync(path)) return false;
  return (JSON.parse(readFileSync(path, "utf8")) as { prompt_history?: { enabled?: boolean } }).prompt_history?.enabled === false;
}

// Whether the profile saves fast mode as on, or undefined when it saves no value.
function savedFastMode(fixture: Fixture): boolean | undefined {
  const path = join(fixture.home, ".fx", "settings.json");
  if (!existsSync(path)) return undefined;
  return (JSON.parse(readFileSync(path, "utf8")) as { fast_mode?: boolean }).fast_mode;
}

// The startup scrollback the profile saves, or undefined when it saves no value.
function savedStartupScrollback(fixture: Fixture): boolean | undefined {
  const path = join(fixture.home, ".fx", "settings.json");
  if (!existsSync(path)) return undefined;
  return (JSON.parse(readFileSync(path, "utf8")) as { startup_scrollback?: boolean }).startup_scrollback;
}

test.skipIf(!tmuxAvailable())(
  "a settings-menu change waits for a ConfigChange hook: the working line shows, the screen stays live, the setting keeps its value until the hook allows, then it is saved",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "settings-gate-open");
    writeProjectHooks(fixture, configChangeHooks("settings-waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "settings-waiter");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    // The same catalog path as the settings menu's prompt history row (prompt-history.test.ts opens it the same way).
    await session.sendText("/settings");
    await session.waitForText("←→ change", TIMEOUT);
    await session.sendLiteral("prompt history");
    await session.waitForPane((pane) => pane.includes("Prompt history") && !pane.includes("Startup scrollback"), TIMEOUT);
    await session.sendKeys("Left");
    // The open menu replaces the footer, so the working line shows once the menu closes.
    await session.sendKeys("Escape");
    await session.waitForText("Checking hooks for the setting change", 5_000);
    // The UI thread keeps reading keys while the hook waits (R2.1). The marker is text no screen already shows.
    await session.sendLiteral("zq");
    await session.waitForPane((pane) => pane.includes("zq"), 3_000);
    expect(promptHistoryDisabled(fixture)).toBe(false);

    // The hook allows the change once its gate file exists.
    writeFileSync(gate, "");
    await waitUntil("the prompt history setting to be saved", () => promptHistoryDisabled(fixture), 10_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "/effort with a refusing ConfigChange hook keeps the effort and shows the refusal",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, configChangeHooks("effort-no", "echo no effort >&2; exit 2"));
    await trust(fixture, "effort-no");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/effort high");
    await session.waitForText("A hook refused this setting change: no effort", TIMEOUT);
    expect(await session.capturePane()).not.toContain("Reasoning effort set to high");
    expect(savedEffort(fixture)).not.toBe("high");
  },
  TEST_TIMEOUT,
);

// The catalog of this file with MODEL offering fast mode, so /fast can turn it on.
const fastCatalog = catalog.map((model) => ({ ...model, fast_options: [{ type: "toggle" }] }));

// Starts fx on a gateway whose model offers fast mode.
async function launchFastCapable(
  fixture: Fixture,
  responses: FakeGatewayResponse[],
  extraEnv: Record<string, string> = {},
): Promise<Shell> {
  return launchGateway(fixture, startFakeGateway(responses, { models: () => fastCatalog }), extraEnv);
}

// The speed a chat request asks the gateway for, or undefined when it asks for none.
function requestSpeed(body: string): string | undefined {
  return (JSON.parse(body) as { providerOptions?: { gateway?: { speed?: string } } }).providerOptions?.gateway?.speed;
}

// Waits until a file exists. The hook writes it, so the file is the signal.
async function waitForFile(path: string, timeoutMs = TIMEOUT): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for file: ${path}`);
}

// Waits until fx has written a trace line that contains `needle`. The trace is the signal, so the test does not sleep.
async function waitForTraceLine(tracePath: string, needle: string, timeoutMs = TIMEOUT): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(tracePath) && readFileSync(tracePath, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for trace line: ${needle}`);
}

test.skipIf(!tmuxAvailable())(
  "/fast with a refusing ConfigChange hook keeps fast mode off and shows the refusal",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, configChangeHooks("fast-no", "echo no fast >&2; exit 2"));
    await trust(fixture, "fast-no");
    const { session } = await launchFastCapable(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/fast");
    await session.waitForText("A hook refused this setting change: no fast", TIMEOUT);
    expect(await session.capturePane()).not.toContain("* fast: on");
    expect(savedFastMode(fixture)).not.toBe(true);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "/settings startup-scrollback with a refusing ConfigChange hook keeps the saved value and shows the refusal",
  async () => {
    const fixture = makeFixture();
    writeProjectHooks(fixture, configChangeHooks("scrollback-no", "echo no scrollback >&2; exit 2"));
    await trust(fixture, "scrollback-no");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/settings startup-scrollback off");
    await session.waitForText("A hook refused this setting change: no scrollback", TIMEOUT);
    expect(await session.capturePane()).not.toContain("startup_scrollback: off");
    expect(savedStartupScrollback(fixture)).not.toBe(false);
  },
  TEST_TIMEOUT,
);

// A prompt submitted while a /fast check waits is held with the check (R2.1): nothing reaches the gateway until the
// check is applied, and then it is sent once, with the setting the check allowed. The fake gateway's request body
// shows the speed, so the test checks what the model actually receives.
test.skipIf(!tmuxAvailable())(
  "a prompt submitted while a /fast hook check waits is sent once the check allows it, with fast mode on",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "fast-prompt-gate-open");
    const trace = join(fixture.root, "fx-trace.log");
    writeProjectHooks(fixture, configChangeHooks("fast-waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "fast-waiter");
    const { session, gateway } = await launchFastCapable(fixture, [fakeGatewayFinalText("held answer")], {
      FX_TRACE_LOG: trace,
    });
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/fast");
    await session.waitForText("Checking hooks for the setting change", 5_000);
    await session.sendText("held prompt waits for the check");
    await waitForTraceLine(trace, "pending_prompt_awaiting_hook_check");
    // The prompt stays on screen and nothing reaches the gateway while the check waits.
    expect(await session.capturePane()).toContain("held prompt waits for the check");
    // A second submit while one is held stays in the composer, as a held credential submit keeps its text (R2.1).
    await session.sendText("second prompt");
    await session.waitForText("second prompt", 3_000);
    expect(gateway.requestCount()).toBe(0);

    writeFileSync(gate, "");
    await session.waitForText("held answer", TIMEOUT);
    expect(gateway.requestCount()).toBe(1);
    expect(requestSpeed(gateway.requests[0]!.body)).toBe("fast");
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a prompt held for a /fast hook check that refuses is sent with fast mode still off",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "fast-refuse-gate-open");
    const trace = join(fixture.root, "fx-trace.log");
    writeProjectHooks(
      fixture,
      configChangeHooks("fast-refuser", `while [ ! -f '${gate}' ]; do sleep 0.05; done; echo no fast >&2; exit 2`),
    );
    await trust(fixture, "fast-refuser");
    const { session, gateway } = await launchFastCapable(fixture, [fakeGatewayFinalText("held answer")], {
      FX_TRACE_LOG: trace,
    });
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/fast");
    await session.waitForText("Checking hooks for the setting change", 5_000);
    await session.sendText("held prompt is sent without fast");
    await waitForTraceLine(trace, "pending_prompt_awaiting_hook_check");
    expect(gateway.requestCount()).toBe(0);

    writeFileSync(gate, "");
    await session.waitForText("A hook refused this setting change: no fast", TIMEOUT);
    await session.waitForText("held answer", TIMEOUT);
    expect(gateway.requestCount()).toBe(1);
    expect(requestSpeed(gateway.requests[0]!.body)).not.toBe("fast");
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Esc twice stops a /fast hook check that holds a prompt: the change is cancelled and the prompt is sent with fast mode off",
  async () => {
    const fixture = makeFixture();
    // The gate file never appears, so only Esc ends the check.
    const gate = join(fixture.workspace, "fast-esc-gate-never");
    const trace = join(fixture.root, "fx-trace.log");
    writeProjectHooks(fixture, configChangeHooks("fast-stuck", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "fast-stuck");
    const { session, gateway } = await launchFastCapable(fixture, [fakeGatewayFinalText("held answer")], {
      FX_TRACE_LOG: trace,
    });
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/fast");
    await session.waitForText("Checking hooks for the setting change", 5_000);
    await session.sendText("held prompt is sent after Esc");
    await waitForTraceLine(trace, "pending_prompt_awaiting_hook_check");
    expect(gateway.requestCount()).toBe(0);

    // Stopping active work takes two Esc presses inside the gesture window: the first arms, the second stops (the same
    // policy as a running turn). The prompt is not dropped: it is sent with the setting as it was.
    await session.sendKeys("Escape");
    await waitForTraceLine(trace, "esc_interrupt_armed");
    await session.sendKeys("Escape");
    await session.waitForText("The setting change was cancelled. Its hooks were stopped.", TIMEOUT);
    await session.waitForText("held answer", TIMEOUT);
    expect(gateway.requestCount()).toBe(1);
    expect(requestSpeed(gateway.requests[0]!.body)).not.toBe("fast");
  },
  TEST_TIMEOUT,
);

// A switch's SessionEnd hooks run in the background (R2.1): /new returns at once, so the person can type while a
// SessionEnd hook waits, and the hook finishes when its gate file appears.
test.skipIf(!tmuxAvailable())(
  "/new with a SessionEnd hook that waits: typing stays live right after /new, and the hook's marker appears after the gate file",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "session-end-gate-open");
    const marker = join(fixture.workspace, "session-end-marker");
    writeProjectHooks(
      fixture,
      eventHooks("SessionEnd", "end-waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done; echo ended > '${marker}'`),
    );
    await trust(fixture, "end-waiter");
    const { session } = await launch(fixture, [fakeGatewayFinalText("first answer")]);
    await session.waitForText("full access ·", TIMEOUT);
    // SessionEnd covers a session that had a turn in this process, so the test sends one first.
    await session.sendText("first turn");
    await session.waitForText("first answer", TIMEOUT);

    await session.sendText("/new");
    await session.sendLiteralText("typed right after new");
    await session.waitForText("typed right after new", 3_000);
    expect(existsSync(marker)).toBe(false);

    writeFileSync(gate, "");
    await waitForFile(marker);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "/statusline waits for a ConfigChange hook: the working line shows, typing still works, and the item changes when the hook allows",
  async () => {
    const fixture = makeFixture();
    const gate = join(fixture.workspace, "statusline-gate-open");
    writeProjectHooks(fixture, configChangeHooks("statusline-waiter", `while [ ! -f '${gate}' ]; do sleep 0.05; done`));
    await trust(fixture, "statusline-waiter");
    const { session } = await launch(fixture, [fakeGatewayFinalText("unused")]);
    await session.waitForText("full access ·", TIMEOUT);

    await session.sendText("/statusline session");
    await session.waitForText("Checking hooks for the setting change", 5_000);
    await session.sendLiteralText("typed while the statusline check runs");
    await session.waitForText("typed while the statusline check runs", 3_000);
    expect(await session.capturePane()).not.toContain("* statusline: session:");

    // The hook allows the change once its gate file exists, and the item then reports its new value.
    writeFileSync(gate, "");
    await session.waitForText("* statusline: session:", 10_000);
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a subagent in the TUI runs only trusted hooks",
  async () => {
    const fixture = makeFixture();
    const hookRan = join(fixture.workspace, "child-hook-ran");
    const childMarker = join(fixture.workspace, "tui-child-marker");
    writeProjectHooks(fixture, {
      hooks: {
        PreToolUse: [
          {
            matcher: "shell",
            hooks: [
              {
                type: "command",
                id: "child-guard",
                command: `touch '${hookRan}'; echo 'no shell in tui children' >&2; exit 2`,
              },
            ],
          },
        ],
      },
    });
    const typed = "Delegate the child marker in the TUI.";
    const childGateway = () =>
      startDynamicFakeGateway(
        (body) => {
          if (isAppChildRequest(body, [typed])) {
            if (body.includes("tui-child-shell")) return fakeGatewayFinalText("TUI_CHILD_DONE");
            return fakeShellRun("tui-child-shell", `touch '${childMarker}'`);
          }
          if (isReportTurn(body)) return fakeGatewayFinalText("TUI_PARENT_DONE");
          if (body.includes("tui-delegate")) return fakeGatewayFinalText("TUI_PARENT_SENT");
          return fakeGatewayToolCall("tui-delegate", "subagent", {
            request: { action: "message", agent: "marker", message: "Create the child marker." },
          });
        },
        { models: () => catalog },
      );

    // First run: the child's hook is not trusted, so it waits and does not run.
    const first = await launchGateway(fixture, childGateway());
    await first.session.sendText(typed);
    await first.session.waitForText("TUI_PARENT_DONE", TEST_TIMEOUT);
    await first.session.waitForComposer(TIMEOUT);
    expect(existsSync(hookRan)).toBe(false);
    expect(existsSync(childMarker)).toBe(true);

    // Second run, a new session after the hook is trusted: the child's call is refused.
    await first.session.kill();
    first.gateway.stop();
    shell = null;
    await trust(fixture, "child-guard");
    rmSync(childMarker, { force: true });
    const second = await launchGateway(fixture, childGateway());
    await second.session.sendText(typed);
    await second.session.waitForText("TUI_PARENT_DONE", TEST_TIMEOUT);
    await second.session.waitForComposer(TIMEOUT);
    expect(existsSync(hookRan)).toBe(true);
    expect(existsSync(childMarker)).toBe(false);
    expect(second.gateway.requests.some((request) => request.body.includes("no shell in tui children"))).toBe(true);
  },
  TEST_TIMEOUT * 2,
);
