import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const sessions: TmuxSession[] = [];
const roots: string[] = [];
const gateways: Array<ReturnType<typeof startFakeGateway>> = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createFixture(prefix: string) {
  const root = realpathSync(mkdtempSync(join("/tmp", prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "yolo",
      sandbox: "os",
      yolo_acknowledged: true,
      permission: {},
    }) + "\n",
  );
  writeFileSync(tracePath, "");
  writeFileSync(stderrPath, "");
  roots.push(root);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tracePath,
    stderrPath,
  };
}

async function launch(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  cmd = FX_BIN,
) {
  const session = await TmuxSession.create({
    isolated: true,
    cmd,
    cwd: fixture.workspace,
    env: {
      HOME: fixture.home,
      SHELL: terminalFixtureShell(),
      AI_GATEWAY_API_KEY: "fake-shell-tool-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: "yolo",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TRACE_LOG: fixture.tracePath,
      FX_TRACE_SCOPES: "shell,terminal,terminal_client,terminal_host,tool,agent",
    },
    width: 120,
    height: 32,
    stderrPath: fixture.stderrPath,
  });
  sessions.push(session);
  await session.waitForComposer(TIMEOUT);
  return session;
}

function findSessionId(value: unknown): string | null {
  if (typeof value === "string") {
    if (!value.includes("session_id")) return null;
    try {
      return findSessionId(JSON.parse(value));
    } catch {
      return null;
    }
  }
  if (Array.isArray(value)) {
    for (let index = value.length - 1; index >= 0; index -= 1) {
      const found = findSessionId(value[index]);
      if (found) return found;
    }
    return null;
  }
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (typeof object.session_id === "string" && object.session_id.length > 0) {
      return object.session_id;
    }
    return findSessionId(Object.values(object));
  }
  return null;
}

function toolResultEnvelope(body: string, toolCallId: string): string {
  const matches: string[] = [];
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item);
      return;
    }
    if (!value || typeof value !== "object") return;
    const object = value as Record<string, unknown>;
    const id = object.toolCallId ?? object.tool_call_id;
    if (id === toolCallId) matches.push(JSON.stringify(object));
    for (const child of Object.values(object)) visit(child);
  };
  visit(JSON.parse(body));
  return matches.join("\n");
}

function schemaFromRequest(body: string): Record<string, unknown> {
  const parsed = JSON.parse(body) as Record<string, unknown>;
  const tools = parsed.tools as Array<Record<string, unknown>>;
  const shell = tools.find((tool) => tool.name === "shell");
  if (!shell) throw new Error("missing shell schema");
  return shell.inputSchema as Record<string, unknown>;
}

/// Set when this run exercises sessions v2, whose sessions are folders under
/// `sessions/v2` and whose terminal state lives under `~/.fx/terminal`.
const SESSIONS_V2 = process.env.FX_SESSIONS_V2 === "1";

function terminalRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", SESSIONS_V2 ? "terminal" : "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot).flatMap((sessionId) => {
    const terminalRoot = join(sessionsRoot, sessionId, "terminal", "state");
    if (!existsSync(terminalRoot)) return [];
    return readdirSync(terminalRoot).flatMap((name) =>
      name.startsWith("record-") && name.endsWith(".json")
        ? [JSON.parse(readFileSync(join(terminalRoot, name), "utf8"))]
        : []
    );
  });
}

function askEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
): Record<string, string | undefined> {
  return {
    HOME: fixture.home,
    SHELL: terminalFixtureShell(),
    AI_GATEWAY_API_KEY: "fake-shell-tool-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "yolo",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TRACE_LOG: fixture.tracePath,
    FX_TRACE_SCOPES: "shell,terminal,terminal_client,terminal_host,terminal_store,shutdown",
  };
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Pids of processes whose command line contains `fragment`. */
function processesMatching(fragment: string, options: { exact?: boolean } = {}): number[] {
  const listing = execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" });
  return listing.split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(.*)$/);
    if (!match) return [];
    const command = match[2]!.trim();
    const matches = options.exact ? command === fragment : command.includes(fragment);
    return matches ? [Number(match[1])] : [];
  });
}

async function waitUntilGone(pids: number[], timeoutMs: number): Promise<number> {
  const started = Date.now();
  while (pids.some(processAlive)) {
    if (Date.now() - started > timeoutMs) {
      throw new Error(`processes still running after ${timeoutMs}ms: ${pids.filter(processAlive)}`);
    }
    await Bun.sleep(10);
  }
  return Date.now() - started;
}

function expectNoTerminalHostDaemon(fixture: ReturnType<typeof createFixture>): void {
  expect(processesMatching(`${FX_BIN} --fx-internal-terminal-host`)).toEqual([]);
  expect(existsSync(join(fixture.home, ".fx", "terminal-host-v7"))).toBe(false);
}

function terminalRecord(home: string, sessionId: string): Record<string, unknown> {
  const record = terminalRecords(home).find((candidate) => candidate.session_id === sessionId);
  if (!record) throw new Error(`missing terminal record ${sessionId}`);
  return record;
}

/** The shell pid in a terminal record, or null before its launcher reports it. */
function recordedPid(home: string, sessionId: string): number | null {
  const pid = Number(terminalRecord(home, sessionId).pid);
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

/** A running handle can return before the launcher records the shell pid. */
async function waitForRecordedPid(home: string, sessionId: string): Promise<number> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    const pid = recordedPid(home, sessionId);
    if (pid !== null) return pid;
    await Bun.sleep(10);
  }
  throw new Error(`terminal ${sessionId} never recorded its shell pid`);
}

function ttyRun(id: string, command: string, extra: Record<string, unknown> = {}) {
  return fakeGatewayToolCall(id, "shell", {
    request: { action: "run", command, profile: "clean", tty: true, ...extra },
  });
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${path}`);
}

test.skipIf(!tmuxAvailable())(
  "shell captured empty observation floors short waits without respawn",
  async () => {
    const fixture = createFixture("fx-shell-captured-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_run", "shell", {
        request: {
          action: "run",
          command: "sleep 2; printf CAPTURED_DONE",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_interact", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            yield_time_ms: 1_000,
          },
        });
      },
      fakeGatewayFinalText("SHELL_CAPTURED_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the captured managed shell flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_CAPTURED_OK", TIMEOUT);

    expect(sessionId.length).toBeGreaterThan(0);
    expect(gateway.requests).toHaveLength(3);
    const schema = schemaFromRequest(gateway.requests[0]!.body);
    expect(Object.keys(schema.properties as Record<string, unknown>)).toEqual([
      "command",
      "shell",
      "cwd",
      "interactive",
      "timeout",
      "wait",
      "session_id",
      "input",
      "stop",
    ]);
    expect(gateway.requests[0]!.body).not.toContain('"name":"terminal"');
    const runResult = toolResultEnvelope(
      gateway.requests[1]!.body,
      "shell_run",
    );
    const interactResult = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_interact",
    );
    expect(runResult).not.toContain('\\"next_action\\"');
    expect(runResult).toContain(`\\"session_id\\":\\"${sessionId}\\"`);
    expect(interactResult).toContain('\\"state\\":\\"completed\\"');
    expect(interactResult).toContain("CAPTURED_DONE");
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Ran sleep 2; printf CAPTURED_DONE");
    expect(scrollback).toContain("Observed sleep 2; printf CAPTURED_DONE");
    expect(scrollback).not.toContain(`Observed session ${sessionId}`);
    expect(scrollback).not.toContain("Using terminal");
    expect(scrollback).not.toContain("Used terminal");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "running shell survives a model-completed turn without handoff policy",
  async () => {
    const fixture = createFixture("fx-shell-cross-turn-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_cross_turn_run", "shell", {
        request: {
          action: "run",
          command: "printf HANDOFF_READY; sleep 30",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayFinalText("PHASE_ONE_READY");
      },
      (body) => {
        return fakeGatewayToolCall("shell_cross_turn_stop", "shell", {
          request: {
            action: "stop",
            session_id: sessionId,
            force: true,
          },
        });
      },
      fakeGatewayFinalText("PHASE_TWO_READY"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Start the command and return control while it remains active.");
    await active.sendKeys("Enter");
    await active.waitForText("PHASE_ONE_READY", TIMEOUT);
    expect(sessionId.length).toBeGreaterThan(0);
    expect(toolResultEnvelope(
      gateway.requests[1]!.body,
      "shell_cross_turn_run",
    )).not.toContain('\\"next_action\\"');

    await active.sendText("Stop the exact retained command now.");
    await active.sendKeys("Enter");
    await active.waitForText("PHASE_TWO_READY", TIMEOUT);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Stopped printf HANDOFF_READY; sleep 30");
    expect(scrollback).not.toContain(`Stopped session ${sessionId}`);
    expect(toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_cross_turn_stop",
    )).toContain('\\"state\\":\\"stopped\\"');
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "force stop settles a stubborn captured command and permits later work",
  async () => {
    const fixture = createFixture("fx-shell-force-stop-");
    const pidPath = join(fixture.workspace, "stubborn.pid");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_stubborn_run", "shell", {
        request: {
          action: "run",
          command: `printf '%s' "$$" > ${JSON.stringify(pidPath)}; trap '' TERM; while :; do sleep 1; done`,
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_stubborn_stop", "shell", {
          request: {
            action: "stop",
            session_id: sessionId,
            force: true,
          },
        });
      },
      fakeGatewayToolCall("shell_after_stop", "shell", {
        request: {
          action: "run",
          command: "printf AFTER_STOP",
          profile: "clean",
        },
      }),
      fakeGatewayFinalText("SHELL_FORCE_STOP_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Force-stop the stubborn command, then run the follow-up command.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_FORCE_STOP_OK", TIMEOUT);

    expect(sessionId.length).toBeGreaterThan(0);
    const stopResult = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_stubborn_stop",
    );
    expect(stopResult).toContain('\\"state\\":\\"stopped\\"');
    expect(stopResult).toContain('\\"termination_indeterminate\\":false');
    expect(toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_after_stop",
    )).toContain("AFTER_STOP");
    await waitForFile(pidPath);
    const pid = Number(readFileSync(pidPath, "utf8"));
    expect(Number.isSafeInteger(pid) && pid > 0).toBe(true);
    const deadline = Date.now() + 3_000;
    while (Date.now() < deadline) {
      try {
        process.kill(pid, 0);
      } catch {
        break;
      }
      await Bun.sleep(25);
    }
    expect(() => process.kill(pid, 0)).toThrow();
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "reused provider call ids start distinct captured commands",
  async () => {
    const fixture = createFixture("fx-shell-reused-call-id-");
    const firstMarker = join(fixture.workspace, "first-command.txt");
    const secondMarker = join(fixture.workspace, "second-command.txt");
    const gateway = startFakeGateway([
      fakeGatewayToolCall("reused_shell_call", "shell", {
        request: {
          action: "run",
          command: `printf first > ${JSON.stringify(firstMarker)}; sleep 30`,
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      fakeGatewayFinalText("FIRST_REUSED_CALL_DONE"),
      fakeGatewayToolCall("reused_shell_call", "shell", {
        request: {
          action: "run",
          command: `printf second > ${JSON.stringify(secondMarker)}; sleep 30`,
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      fakeGatewayFinalText("SECOND_REUSED_CALL_DONE"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Run the first captured command.");
    await active.sendKeys("Enter");
    await active.waitForText("FIRST_REUSED_CALL_DONE", TIMEOUT);
    await active.sendText("Run the second captured command.");
    await active.sendKeys("Enter");
    await active.waitForText("SECOND_REUSED_CALL_DONE", TIMEOUT);

    const firstSessionId = findSessionId(JSON.parse(gateway.requests[1]!.body));
    const secondSessionId = findSessionId(JSON.parse(gateway.requests[3]!.body));
    expect(firstSessionId).not.toBeNull();
    expect(secondSessionId).not.toBeNull();
    expect(firstSessionId).not.toBe(secondSessionId);
    await Promise.all([waitForFile(firstMarker), waitForFile(secondMarker)]);
    expect(readFileSync(firstMarker, "utf8")).toBe("first");
    expect(readFileSync(secondMarker, "utf8")).toBe("second");

    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "overlapping captured shell handles keep lifecycle output isolated",
  async () => {
    const fixture = createFixture("fx-shell-overlap-");
    let firstSessionId = "";
    let secondSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_overlap_first", "shell", {
        request: {
          action: "run",
          command: "sleep 0.4; printf FIRST_OVERLAP",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        firstSessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayToolCall("shell_overlap_second", "shell", {
          request: {
            action: "run",
            command: "sleep 0.2; printf SECOND_OVERLAP",
            profile: "clean",
            yield_time_ms: 0,
          },
        });
      },
      (body) => {
        secondSessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayToolCall("shell_overlap_wait_first", "shell", {
          request: {
            action: "interact",
            session_id: firstSessionId,
            yield_time_ms: 5_000,
          },
        });
      },
      () => fakeGatewayToolCall("shell_overlap_wait_second", "shell", {
        request: {
          action: "interact",
          session_id: secondSessionId,
          yield_time_ms: 5_000,
        },
      }),
      fakeGatewayFinalText("SHELL_OVERLAP_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run both overlapping managed shell commands.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_OVERLAP_OK", TIMEOUT);

    expect(firstSessionId.length).toBeGreaterThan(0);
    expect(secondSessionId.length).toBeGreaterThan(0);
    expect(secondSessionId).not.toBe(firstSessionId);
    const firstResult = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_overlap_wait_first",
    );
    const secondResult = toolResultEnvelope(
      gateway.requests[4]!.body,
      "shell_overlap_wait_second",
    );
    expect(firstResult).toContain("FIRST_OVERLAP");
    expect(firstResult).not.toContain("SECOND_OVERLAP");
    expect(secondResult).toContain("SECOND_OVERLAP");
    expect(secondResult).not.toContain("FIRST_OVERLAP");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "shell TTY execution writes atomically drains final output and closes host state",
  async () => {
    const fixture = createFixture("fx-shell-tty-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_run", "shell", {
        request: {
          action: "run",
          command:
            "printf 'TTY_READY\\n'; IFS= read -r line; printf 'TTY_ECHO:%s\\n' \"$line\"",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_tty_interact", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            chars: "violet comet\n",
          },
        });
      },
      fakeGatewayFinalText("SHELL_TTY_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the interactive managed shell flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_OK", TIMEOUT);

    expect(sessionId).toMatch(/^shell-[A-Za-z0-9_-]{22}$/);
    const writeResult = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_interact",
    );
    expect(writeResult).toContain("TTY_ECHO:violet comet");
    expect(writeResult).toContain('\\"state\\":\\"completed\\"');
    expect(writeResult).toContain('\\"exit_code\\":0');
    const records = terminalRecords(fixture.home);
    expect(records.some((record) =>
      record.session_id === sessionId && record.lifecycle === "closed"
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "session command statuses reclip to the live width instead of the activity cap",
  async () => {
    const fixture = createFixture("fx-shell-session-width-");
    const launchCommand = `echo ${"f".repeat(100)} >/dev/null; sleep 60`;
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_width_run", "shell", {
        request: {
          action: "run",
          command: launchCommand,
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_width_observe", "shell", {
          request: { action: "interact", session_id: sessionId, chars: "" },
        });
      },
      (body) => {
        const id = sessionId || findSessionId(JSON.parse(body)) || "";
        return fakeGatewayToolCall("shell_width_stop", "shell", {
          request: { action: "stop", session_id: id },
        });
      },
      fakeGatewayFinalText("WIDTH_FLOW_DONE"),
    ]);
    gateways.push(gateway);
    const session = await TmuxSession.create({
      isolated: true,
      cwd: fixture.workspace,
      env: {
        HOME: fixture.home,
        SHELL: terminalFixtureShell(),
        AI_GATEWAY_API_KEY: "fake-shell-tool-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "yolo",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TRACE_LOG: fixture.tracePath,
        FX_TRACE_SCOPES: "shell,terminal,terminal_client,terminal_host,tool,agent",
      },
      width: 160,
      height: 32,
      stderrPath: fixture.stderrPath,
    });
    sessions.push(session);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Run and observe the session.");
    await session.waitForText("WIDTH_FLOW_DONE", TIMEOUT);
    await Bun.sleep(300);

    // The 126-column activity cap used to freeze these phrases with trailing
    // marks; at 160 columns the full launch command fits and must render
    // without an ellipsis for captured runs, tty runs, and session actions.
    const grid = await session.capturePaneGrid();
    const row = (prefix: string) =>
      grid.map((line) => line.trimEnd()).find((line) => line.startsWith(prefix));
    expect(row("├ Ran ")).toBe(`├ Ran ${launchCommand}`);
    expect(row("├ Observed ")).toBe(`├ Observed ${launchCommand}`);
    expect(row("└ Stopped ")).toBe(`└ Stopped ${launchCommand}`);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "resumed session rows reclip to the live width from recorded launch commands",
  async () => {
    const fixture = createFixture("fx-shell-resume-width-");
    const launchCommand = `echo ${"r".repeat(100)} >/dev/null; sleep 60`;
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_resume_run", "shell", {
        request: {
          action: "run",
          command: launchCommand,
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_resume_observe", "shell", {
          request: { action: "interact", session_id: sessionId, chars: "" },
        });
      },
      (body) => {
        const id = sessionId || findSessionId(JSON.parse(body)) || "";
        return fakeGatewayToolCall("shell_resume_stop", "shell", {
          request: { action: "stop", session_id: id },
        });
      },
      fakeGatewayFinalText("RESUME_WIDTH_DONE"),
    ]);
    gateways.push(gateway);
    const session = await TmuxSession.create({
      isolated: true,
      cmd: "/bin/sh -i",
      cwd: fixture.workspace,
      env: {
        HOME: fixture.home,
        SHELL: terminalFixtureShell(),
        AI_GATEWAY_API_KEY: "fake-shell-tool-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "yolo",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TRACE_LOG: fixture.tracePath,
        FX_TRACE_SCOPES: "shell,terminal,terminal_client,terminal_host,tool,agent",
        PS1: "RESUME_SHELL> ",
      },
      width: 160,
      height: 36,
    });
    sessions.push(session);
    await session.waitForText("RESUME_SHELL>", TIMEOUT);
    await session.sendText(`${FX_BIN} 2>${fixture.stderrPath}`);
    await session.waitForStableComposer(TIMEOUT);
    await session.sendText("Run and observe the session.");
    await session.waitForText("RESUME_WIDTH_DONE", TIMEOUT);
    await session.sendText("/quit");
    await session.waitForText("RESUME_SHELL>", TIMEOUT);

    const sessionsRoot = join(fixture.home, ".fx", "sessions", ...(SESSIONS_V2 ? ["v2"] : []));
    const fxSessionIds = readdirSync(sessionsRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && entry.name !== "latest" && entry.name !== "v2" && !entry.name.startsWith("."))
      .map((entry) => entry.name);
    expect(fxSessionIds).toHaveLength(1);

    await session.sendText(`${FX_BIN} --resume ${fxSessionIds[0]} 2>>${fixture.stderrPath}`);
    await session.waitForText("session resumed", TIMEOUT);
    await session.waitForStableComposer(TIMEOUT);

    // The resumed transcript must rebuild full-width rows: the 120-column
    // activity cap would leave trailing marks, and an unrecorded tty session
    // would fall back to the raw session id.
    const grid = await session.capturePaneGrid();
    const row = (prefix: string) =>
      grid.map((line) => line.trimEnd()).find((line) => line.startsWith(prefix));
    expect(row("├ Observed ")).toBe(`├ Observed ${launchCommand}`);
    expect(row("├ Ran ")).toBe(`├ Ran ${launchCommand}`);
    expect(row("└ Stopped ")).toBe(`└ Stopped ${launchCommand}`);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "shell TTY writes advance one runtime-owned cursor without duplicate output",
  async () => {
    const fixture = createFixture("fx-shell-tty-cursor-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_cursor_run", "shell", {
        request: {
          action: "run",
          command:
            "printf 'CURSOR_READY\\n'; IFS= read -r _; printf 'CURSOR_FIRST\\n'; IFS= read -r _; printf 'CURSOR_SECOND\\n'",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_tty_cursor_interact", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            chars: "continue\n",
            yield_time_ms: 0,
          },
        });
      },
      () => fakeGatewayToolCall("shell_tty_cursor_interact_two", "shell", {
        request: {
          action: "interact",
          session_id: sessionId,
          chars: "next\n",
        },
      }),
      fakeGatewayFinalText("SHELL_TTY_CURSOR_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the TTY cursor flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_CURSOR_OK", TIMEOUT);

    const first = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_cursor_interact",
    );
    const second = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_tty_cursor_interact_two",
    );
    expect(first).toContain("CURSOR_FIRST");
    expect(first).not.toContain("CURSOR_SECOND");
    expect(second).toContain("CURSOR_SECOND");
    expect(second).not.toContain("CURSOR_FIRST");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "shell interact sends exact control characters",
  async () => {
    const fixture = createFixture("fx-shell-tty-control-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_control_run", "shell", {
        request: {
          action: "run",
          command:
            "python3 -u -c 'import signal,sys; signal.signal(signal.SIGINT, lambda *_: (print(\"TTY_INTERRUPT_SEEN\", flush=True), sys.exit(0))); print(\"TTY_INTERRUPT_READY\", flush=True); signal.pause()'",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_tty_control_ready", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            yield_time_ms: 5_000,
          },
        });
      },
      () => {
        return fakeGatewayToolCall("shell_tty_control_interact", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            chars: "\u0003",
            yield_time_ms: 5_000,
          },
        });
      },
      fakeGatewayFinalText("SHELL_TTY_CONTROL_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Interrupt the exact managed TTY through Shell input.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_CONTROL_OK", TIMEOUT);

    const ready = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_control_ready",
    );
    expect(ready).toContain("TTY_INTERRUPT_READY");
    const result = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_tty_control_interact",
    );
    expect(result).toContain("TTY_INTERRUPT_SEEN");
    expect(result).toContain('\\"state\\":\\"completed\\"');
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "shell TTY timeout stops the owned process and reports the deadline",
  async () => {
    const fixture = createFixture("fx-shell-tty-timeout-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_timeout_run", "shell", {
        request: {
          action: "run",
          command: "printf 'TTY_TIMEOUT_READY\\n'; sleep 30",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
          timeout_ms: 250,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayToolCall("shell_tty_timeout_wait", "shell", {
          request: {
            action: "interact",
            session_id: sessionId,
            yield_time_ms: 5_000,
          },
        });
      },
      fakeGatewayFinalText("SHELL_TTY_TIMEOUT_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the managed TTY timeout flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_TIMEOUT_OK", TIMEOUT);

    expect(sessionId.length).toBeGreaterThan(0);
    const waitResult = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_timeout_wait",
    );
    expect(waitResult).toContain('\\"state\\":\\"completed\\"');
    expect(waitResult).toContain('\\"error\\":\\"TimeoutExpired\\"');
    expect(waitResult).toContain('\\"termination_indeterminate\\":false');
    const record = terminalRecords(fixture.home).find((candidate) =>
      candidate.session_id === sessionId
    );
    expect(record?.timed_out).toBe(true);
    expect(record?.lifecycle).toBe("closed");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "quit ends a managed TTY and resume reports it as ended",
  async () => {
    const fixture = createFixture("fx-shell-tty-resume-");
    let sessionId = "";
    const gateway = startFakeGateway([
      ttyRun(
        "shell_tty_resume_run",
        "printf 'TTY_RESUME_READY\\n'; sleep 37.25",
        { yield_time_ms: 0 },
      ),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayFinalText("SHELL_TTY_RESUME_STARTED");
      },
      () => fakeGatewayToolCall("shell_tty_resume_interact", "shell", {
        request: { action: "interact", session_id: sessionId, chars: "x" },
      }),
      () => fakeGatewayToolCall("shell_tty_resume_stop", "shell", {
        request: { action: "stop", session_id: sessionId, force: true },
      }),
      fakeGatewayFinalText("SHELL_TTY_RESUME_OK"),
    ]);
    gateways.push(gateway);

    const first = await launch(fixture, gateway);
    await first.sendText("Start the managed TTY.");
    await first.waitForText("SHELL_TTY_RESUME_STARTED", TIMEOUT);
    expect(sessionId).toMatch(/^shell-[A-Za-z0-9_-]{22}$/);
    const shellPid = await waitForRecordedPid(fixture.home, sessionId);
    expect(processAlive(shellPid)).toBe(true);
    await first.sendText("/quit");
    expect(await first.waitForSessionEnd(TIMEOUT)).toBe(true);

    // The terminal belonged to the fx process and ended with it, with no prompt.
    await waitUntilGone([shellPid, ...processesMatching("sleep 37.25")], 1_000);
    expect(terminalRecord(fixture.home, sessionId).lifecycle).toBe("lost");
    expectNoTerminalHostDaemon(fixture);

    const resumed = await launch(
      fixture,
      gateway,
      `${FX_BIN} --resume-last`,
    );
    await resumed.sendText("Use the earlier managed TTY.");
    await resumed.waitForText("SHELL_TTY_RESUME_OK", TIMEOUT);

    // Neither interact nor stop reattaches; both tell the agent to start anew.
    for (const [index, id] of [
      [3, "shell_tty_resume_interact"],
      [4, "shell_tty_resume_stop"],
    ] as const) {
      const result = toolResultEnvelope(gateway.requests[index]!.body, id);
      expect(result).toContain("TerminalEnded");
      expect(result).toContain("ended when the fx process that started it exited");
      expect(result).toContain("Start a new terminal");
    }
    // The transcript shows why the terminal is gone.
    expect(await resumed.captureFullScrollback()).toContain("ended when fx exited");
    expect(terminalRecord(fixture.home, sessionId).lifecycle).toBe("lost");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test("fx ask exit ends its TTY terminal within one second", async () => {
  const fixture = createFixture("fx-shell-tty-ask-exit-");
  let sessionId = "";
  const gateway = startFakeGateway([
    ttyRun("shell_tty_ask_run", "sleep 37.25", { yield_time_ms: 0 }),
    (body) => {
      sessionId = findSessionId(JSON.parse(body)) ?? "";
      return fakeGatewayFinalText("ASK_TTY_STARTED");
    },
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Start a long TTY."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  const exitedAt = Date.now();
  expect(result.code).toBe(0);
  expect(JSON.parse(result.stdout).output).toBe("ASK_TTY_STARTED");
  expect(sessionId).toMatch(/^shell-[A-Za-z0-9_-]{22}$/);

  // fx may exit before the launcher records the shell pid.
  const shellPid = recordedPid(fixture.home, sessionId);
  // Match the exact command line of a duration nothing else uses, so other
  // processes that merely mention it do not count.
  const sleepers = processesMatching("sleep 37.25", { exact: true });
  for (const pid of [...(shellPid === null ? [] : [shellPid]), ...sleepers]) {
    if (!processAlive(pid)) continue;
    await waitUntilGone([pid], Math.max(0, 1_000 - (Date.now() - exitedAt)));
  }
  expect(processAlive(shellPid)).toBe(false);
  expect(terminalRecord(fixture.home, sessionId).lifecycle).toBe("lost");
  expectNoTerminalHostDaemon(fixture);
  expect(readFileSync(fixture.tracePath, "utf8")).toContain(
    "ended 1 terminal(s) for process exit",
  );
}, TIMEOUT);

test("TTY runs in the requested cwd on a real PTY and reports the exact exit", async () => {
  const fixture = createFixture("fx-shell-tty-pty-");
  const nested = join(fixture.workspace, "nested");
  mkdirSync(nested);
  const gateway = startFakeGateway([
    ttyRun(
      "shell_tty_pty_run",
      "printf 'CWD:%s\\n' \"$PWD\"; " +
        "if [ -t 0 ] && [ -t 1 ]; then printf 'PTY:yes\\n'; fi; " +
        "printf 'SIZE:%s\\n' \"$(stty size)\"; exit 7",
      { cwd: nested, yield_time_ms: 30_000 },
    ),
    fakeGatewayFinalText("PTY_DONE"),
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Probe the PTY."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  const envelope = toolResultEnvelope(gateway.requests[1]!.body, "shell_tty_pty_run");
  expect(envelope).toContain(`CWD:${nested}`);
  expect(envelope).toContain("PTY:yes");
  expect(envelope).toContain("SIZE:24 80");
  expect(envelope).toContain('\\"exit_code\\":7');
  expect(envelope).toContain('\\"backend\\":\\"tty\\"');
}, TIMEOUT);

test.skipIf(!tmuxAvailable())(
  "another fx process can neither drive nor end a running owner's terminal",
  async () => {
    const fixture = createFixture("fx-shell-tty-owner-");
    let ownerTerminal = "";
    const ownerGateway = startFakeGateway([
      ttyRun("shell_tty_owner_run", "sleep 41.5", { yield_time_ms: 0 }),
      (body) => {
        ownerTerminal = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayFinalText("OWNER_TTY_STARTED");
      },
    ]);
    gateways.push(ownerGateway);
    const owner = await launch(fixture, ownerGateway);
    await owner.sendText("Start the owned TTY.");
    await owner.waitForText("OWNER_TTY_STARTED", TIMEOUT);
    const shellPid = await waitForRecordedPid(fixture.home, ownerTerminal);

    const intruderGateway = startFakeGateway([
      () => fakeGatewayToolCall("intruder_interact", "shell", {
        request: { action: "interact", session_id: ownerTerminal, chars: "exit\n" },
      }),
      () => fakeGatewayToolCall("intruder_stop", "shell", {
        request: { action: "stop", session_id: ownerTerminal, force: true },
      }),
      fakeGatewayFinalText("INTRUDER_DONE"),
    ]);
    gateways.push(intruderGateway);
    const intruder = await runFx(["ask", "--json", "Touch the other terminal."], {
      cwd: fixture.workspace,
      env: askEnv(fixture, intruderGateway),
      timeoutMs: TIMEOUT,
    });
    expect(intruder.code).toBe(0);
    const intrusion = JSON.parse(intruder.stdout) as {
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(intrusion.tool_calls.map(({ status }) => status)).toEqual(["error", "error"]);

    // The other process exited, but this terminal is still owned and running.
    await Bun.sleep(300);
    expect(processAlive(shellPid)).toBe(true);
    expect(terminalRecord(fixture.home, ownerTerminal).lifecycle).toBe("running");

    await owner.sendText("/quit");
    expect(await owner.waitForSessionEnd(TIMEOUT)).toBe(true);
    await waitUntilGone([shellPid], 1_000);
    expect(terminalRecord(fixture.home, ownerTerminal).lifecycle).toBe("lost");
  },
  60_000,
);

test("TTY stop reaches a background job the terminal started", async () => {
  const fixture = createFixture("fx-shell-tty-signal-");
  const pidFile = join(fixture.root, "background.pid");
  let sessionId = "";
  const gateway = startFakeGateway([
    ttyRun(
      "shell_tty_signal_run",
      `sleep 43.5 & printf '%s' "$!" > ${JSON.stringify(pidFile)}; printf 'BG_READY\\n'; wait`,
      { yield_time_ms: 0 },
    ),
    async (body) => {
      sessionId = findSessionId(JSON.parse(body)) ?? "";
      await waitForFile(pidFile);
      return fakeGatewayToolCall("shell_tty_signal_stop", "shell", {
        request: { action: "stop", session_id: sessionId, force: true },
      });
    },
    fakeGatewayFinalText("SIGNAL_DONE"),
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Stop the background job."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  const stopResult = toolResultEnvelope(gateway.requests[2]!.body, "shell_tty_signal_stop");
  expect(stopResult).toContain('\\"state\\":\\"stopped\\"');
  const backgroundPid = Number(readFileSync(pidFile, "utf8"));
  await waitUntilGone([backgroundPid], 1_000);
  expect(terminalRecord(fixture.home, sessionId).lifecycle).toBe("closed");
}, TIMEOUT);

test("the full terminal budget starts, refuses one more, and ends together at exit", async () => {
  const fixture = createFixture("fx-shell-tty-capacity-");
  const budget = 64;
  const responses: Parameters<typeof startFakeGateway>[0] = [];
  for (let index = 0; index <= budget; index += 1) {
    responses.push(ttyRun(`shell_tty_capacity_${index}`, "sleep 45.75", { yield_time_ms: 0 }));
  }
  responses.push(fakeGatewayFinalText("CAPACITY_DONE"));
  const gateway = startFakeGateway(responses);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Fill the terminal budget."], {
    cwd: fixture.workspace,
    env: { ...askEnv(fixture, gateway), FX_MAX_AGENT_STEPS: "100" },
    timeoutMs: 120_000,
  });
  const exitedAt = Date.now();
  expect(result.code).toBe(0);
  const statuses = (JSON.parse(result.stdout) as {
    tool_calls: Array<{ status: string }>;
  }).tool_calls.map(({ status }) => status);
  expect(statuses.slice(0, budget).every((status) => status === "success")).toBe(true);
  expect(statuses[budget]).toBe("error");
  expect(toolResultEnvelope(gateway.requests[budget + 1]!.body, `shell_tty_capacity_${budget}`))
    .toContain("Capacity");

  const records = terminalRecords(fixture.home);
  expect(records).toHaveLength(budget);
  const shellPids = records.map((record) => Number(record.pid));
  await waitUntilGone(
    [...shellPids, ...processesMatching("sleep 45.75")],
    Math.max(0, 1_500 - (Date.now() - exitedAt)),
  );
  expect(records.every((record) => record.lifecycle === "lost")).toBe(true);
}, 150_000);
