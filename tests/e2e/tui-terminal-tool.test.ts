import { afterEach, expect, test } from "bun:test";
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
import { FX_BIN } from "../evals/eval-helpers";
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
const homes: string[] = [];
const gateways: Array<ReturnType<typeof startFakeGateway>> = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const home of homes.splice(0)) await cleanupTerminalHost(home);
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
  homes.push(home);
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
      FX_TERMINAL_HOST_IDLE_MS: "500",
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

function terminalRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", "sessions");
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

async function cleanupTerminalHost(home: string): Promise<void> {
  const identityPath = join(home, ".fx", "terminal-host-v7", "host.json");
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }
  try {
    const identity = JSON.parse(readFileSync(identityPath, "utf8"));
    const pid = Number(identity.pid);
    if (Number.isSafeInteger(pid) && pid > 0) process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
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
    const request = (schema.properties as Record<string, any>).request;
    const actions = request.oneOf.map(
      (branch: any) => branch.properties.action.enum[0],
    );
    expect(actions).toEqual(["run", "run", "interact", "stop"]);
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
  "resumed fx reindexes and stops its durable managed TTY",
  async () => {
    const fixture = createFixture("fx-shell-tty-resume-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_resume_run", "shell", {
        request: {
          action: "run",
          command:
            "printf 'TTY_RESUME_READY\\n'; while IFS= read -r line; do printf 'TTY_RESUME_ECHO:%s\\n' \"$line\"; done",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayFinalText("SHELL_TTY_RESUME_STARTED");
      },
      () => fakeGatewayToolCall("shell_tty_resume_stop", "shell", {
          request: {
            action: "stop",
            session_id: sessionId,
            force: true,
          },
        }),
      fakeGatewayFinalText("SHELL_TTY_RESUME_OK"),
    ]);
    gateways.push(gateway);

    const first = await launch(fixture, gateway);
    await first.sendText("Start the durable managed TTY.");
    await first.waitForText("SHELL_TTY_RESUME_STARTED", TIMEOUT);
    expect(sessionId).toMatch(/^shell-[A-Za-z0-9_-]{22}$/);
    await first.sendText("/quit");
    expect(await first.waitForSessionEnd(TIMEOUT)).toBe(true);

    const resumed = await launch(
      fixture,
      gateway,
      `${FX_BIN} --resume-last`,
    );
    await resumed.sendText("Force-stop the exact retained managed TTY.");
    await resumed.waitForText("SHELL_TTY_RESUME_OK", TIMEOUT);

    const stopResult = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_tty_resume_stop",
    );
    expect(stopResult).toContain('\\"state\\":\\"stopped\\"');
    const scrollback = await resumed.captureFullScrollback();
    expect(scrollback).toContain(`Stopped session ${sessionId}`);
    expect(scrollback).not.toContain("Exited 143");
    const record = terminalRecords(fixture.home).find((candidate) =>
      candidate.session_id === sessionId
    );
    expect(record?.lifecycle).toBe("closed");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  60_000,
);
