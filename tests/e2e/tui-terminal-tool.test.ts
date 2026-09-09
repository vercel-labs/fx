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
  statSync,
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
const helperCleanups: Array<{
  pidPath: string;
  scriptPath: string;
  helper?: HelperProcessIdentity;
  supervisor?: HelperProcessIdentity;
}> = [];

afterEach(async () => {
  const cleanups = helperCleanups.splice(0);
  // Rescue only after the test has recorded its outcome, never to satisfy /quit.
  for (const cleanup of cleanups) {
    try {
      if (cleanup.supervisor) signalHelperProcess(cleanup.supervisor, "SIGCONT", true);
    } catch (error) {
      console.error("Supervisor teardown resume failed:", error);
    }
  }
  for (const session of sessions.splice(0)) await session.kill();
  for (const cleanup of cleanups) {
    try {
      // An early assertion can fail before the test reads the helper PID.
      const identity = cleanup.helper ?? captureSessionHelper(cleanup);
      if (identity) signalHelperProcess(identity, "SIGKILL");
    } catch (error) {
      console.error("Session helper teardown failed:", error);
    }
  }
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

function createSessionHelper(fixture: ReturnType<typeof createFixture>) {
  const scriptPath = join(fixture.workspace, "helper.py");
  const pidPath = join(fixture.workspace, "helper.pid");
  const cleanup: (typeof helperCleanups)[number] = { pidPath, scriptPath };
  helperCleanups.push(cleanup);
  writeFileSync(scriptPath, `import os
import pathlib
import signal
import socket
import subprocess
import sys
import time

root = pathlib.Path(__file__).parent
pid_path = root / "helper.pid"
socket_path = str(root / "helper.sock")
mode = sys.argv[1]
signal.alarm(60)
if mode == "serve":
    assert os.getsid(0) == os.getpid()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(socket_path)
        server.listen(4)
        pending = root / "helper.pid.tmp"
        pending.write_text(str(os.getpid()))
        pending.replace(pid_path)
        while True:
            connection, _ = server.accept()
            with connection:
                connection.sendall(("HELPER_REPLY:" + str(os.getpid())).encode())
elif mode == "probe":
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(socket_path)
        reply = client.recv(128).decode()
    assert reply == "HELPER_REPLY:" + pid_path.read_text(), reply
    print(reply, flush=True)
else:
    subprocess.Popen(
        [sys.executable, __file__, "serve"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while not pid_path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("helper did not become ready")
        time.sleep(0.01)
    print("HELPER_STARTED:" + pid_path.read_text(), flush=True)
    if mode == "hold":
        signal.pause()
`);
  return {
    pidPath,
    cleanup,
    command: (mode: "start" | "probe" | "hold") =>
      `python3 ${JSON.stringify(scriptPath)} ${mode}`,
  };
}

function helperPid(path: string): number {
  const pid = Number(readFileSync(path, "utf8"));
  expect(Number.isSafeInteger(pid) && pid > 0).toBe(true);
  const cleanup = helperCleanups.find((entry) => entry.pidPath === path);
  if (cleanup && !cleanup.helper) cleanup.helper = captureSessionHelper(cleanup);
  return pid;
}

async function expectHelperExited(pid: number, pidPath: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      expect((error as NodeJS.ErrnoException).code).toBe("ESRCH");
      return;
    }
    await Bun.sleep(25);
  }
  throw new Error(`Session helper ${pid} (${pidPath}) survived cleanup`);
}

type HelperProcessIdentity = {
  pid: number;
  ppid: number;
  start: string;
  state: string;
  command: string;
  supervisorRootPid?: number;
};

function helperProcessSnapshot(pid?: number): HelperProcessIdentity[] {
  let output: string;
  try {
    output = execFileSync("ps", [
      "-ww",
      ...(pid === undefined ? ["-A"] : ["-p", String(pid)]),
      "-o", "pid=,ppid=,lstart=,stat=,command=",
    ], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
      timeout: 1_000,
      maxBuffer: 16 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    const failure = error as { status?: number; stdout?: string; stderr?: string };
    if (pid !== undefined && failure.status === 1 &&
        !failure.stdout?.trim() && !failure.stderr?.trim()) return [];
    throw error;
  }
  return output.split("\n").filter((line) => line.trim()).map((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\S+\s+\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!match) throw new Error(`Unrecognized helper process identity: ${line}`);
    return {
      pid: Number(match[1]),
      ppid: Number(match[2]),
      start: match[3]!.replace(/\s+/g, " "),
      state: match[4]!,
      command: match[5]!,
    };
  });
}

function captureSessionHelper(
  cleanup: (typeof helperCleanups)[number],
): HelperProcessIdentity | undefined {
  if (!existsSync(cleanup.pidPath)) return undefined;
  const pid = Number(readFileSync(cleanup.pidPath, "utf8"));
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    throw new Error(`Invalid session helper PID in ${cleanup.pidPath}`);
  }
  const identity = helperProcessSnapshot(pid)[0];
  if (!identity || identity.state.includes("Z")) return undefined;
  // Prove this fixture's serve process before adopting a PID-file candidate.
  const command = /^(?:\S*\/)?[Pp]ython(?:\d+(?:\.\d+)*)? (.+) serve$/.exec(identity.command);
  if (command?.[1] !== cleanup.scriptPath) {
    throw new Error(`Refusing unowned session helper PID ${pid} from ${cleanup.pidPath}`);
  }
  return identity;
}

function sameHelperProcess(identity: HelperProcessIdentity): HelperProcessIdentity | undefined {
  const current = helperProcessSnapshot(identity.pid)[0];
  return current?.pid === identity.pid && current.start === identity.start &&
      current.command === identity.command
    ? current
    : undefined;
}

function isHelperSupervisor(identity: HelperProcessIdentity, rootPid: number): boolean {
  if (identity.ppid !== rootPid) return false;
  const privateCommand = " __fx_helper_session__ ";
  if (!identity.command.startsWith(`${FX_BIN}${privateCommand}`) &&
      !(process.platform === "linux" &&
        identity.command.startsWith(`/proc/self/exe${privateCommand}`))) return false;
  if (process.platform !== "linux") return true;
  // argv[0] is spoofable; procfs must identify this checkout's actual executable.
  try {
    const actual = statSync(`/proc/${identity.pid}/exe`, { bigint: true });
    const expected = statSync(FX_BIN, { bigint: true });
    return actual.dev === expected.dev && actual.ino === expected.ino;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function signalHelperProcess(
  identity: HelperProcessIdentity,
  signal: "SIGKILL" | "SIGSTOP" | "SIGCONT",
  stoppedOnly = false,
): boolean {
  // Re-read PID, start time and full command immediately before each signal.
  const current = sameHelperProcess(identity);
  if (!current || current.state.includes("Z") ||
      (stoppedOnly && !current.state.includes("T"))) return false;
  if (identity.supervisorRootPid !== undefined &&
      !isHelperSupervisor(current, identity.supervisorRootPid)) return false;
  process.kill(current.pid, signal);
  return true;
}

async function waitForHelperSupervisor(
  identity: HelperProcessIdentity,
  stopped: boolean,
): Promise<void> {
  const deadline = performance.now() + 5_000;
  while (performance.now() < deadline) {
    const current = sameHelperProcess(identity);
    if (stopped ? current?.state.includes("T") : !current) return;
    await Bun.sleep(25);
  }
  throw new Error(`Supervisor ${identity.pid} did not become ${stopped ? "stopped" : "absent"}`);
}

for (const signal of ["SIGKILL", "SIGSTOP"] as const) {
  test.skipIf(!tmuxAvailable())(
    `captured shell retained supervisor ${signal} settles without harness rescue`,
    async () => {
      const fixture = createFixture(`fx-shell-supervisor-${signal.toLowerCase()}-`);
      const helper = createSessionHelper(fixture);
      const { cleanup } = helper;
      const fxPidPath = join(fixture.workspace, "fx.pid");
      const wrapperPath = join(fixture.workspace, "launch-fx.sh");
      writeFileSync(wrapperPath, 'printf "%s" "$$" > "$1"\nexec "$2"\n');
      const gateway = startFakeGateway([
        fakeGatewayToolCall("helper_before_supervisor_fault", "shell", {
          request: {
            action: "run",
            command: helper.command("start"),
            profile: "clean",
            yield_time_ms: 30_000,
          },
        }),
        () => {
          helperPid(helper.pidPath);
          const identity = cleanup.helper;
          expect(identity?.command).toEndWith(`${join(fixture.workspace, "helper.py")} serve`);
          return fakeGatewayFinalText("SESSION_HELPER_FAULT_BOUNDARY");
        },
        fakeGatewayToolCall("shell_after_supervisor_fault", "shell", {
          request: {
            action: "run",
            command: "printf SHELL_AFTER_SUPERVISOR_FAULT",
            profile: "clean",
            yield_time_ms: 30_000,
          },
        }),
        fakeGatewayFinalText("SESSION_HELPER_FAULT_FOLLOW_UP_OK"),
      ]);
      gateways.push(gateway);
      const active = await launch(
        fixture,
        gateway,
        `/bin/sh ${[wrapperPath, fxPidPath, FX_BIN].map((path) => JSON.stringify(path)).join(" ")}`,
      );
      await active.sendText("Start the redirected helper and finish the shell call.");
      await active.waitForText("SESSION_HELPER_FAULT_BOUNDARY", TIMEOUT);
      await active.waitForComposer(TIMEOUT);
      expect(gateway.requests).toHaveLength(2);
      const pid = helperPid(helper.pidPath);
      const started = toolResultEnvelope(gateway.requests[1]!.body, "helper_before_supervisor_fault");
      expect(started).toContain('\\"state\\":\\"completed\\"');
      expect(started).toContain('\\"exit_code\\":0');
      expect(started).toContain(`HELPER_STARTED:${pid}`);
      expect(cleanup.helper?.pid).toBe(pid);
      expect(cleanup.helper?.command).toEndWith(`${join(fixture.workspace, "helper.py")} serve`);
      expect(sameHelperProcess(cleanup.helper!)).toBeDefined();

      const fx = helperProcessSnapshot(helperPid(fxPidPath))[0]!;
      expect(fx).toBeDefined();
      expect(fx.command).toBe(FX_BIN);
      const supervisors = helperProcessSnapshot().filter((candidate) =>
        isHelperSupervisor(candidate, fx.pid)
      );
      expect(supervisors).toHaveLength(1);
      const supervisor = { ...supervisors[0]!, supervisorRootPid: fx.pid };
      cleanup.supervisor = supervisor;
      expect(supervisor.pid).not.toBe(pid);
      expect(supervisor.pid).not.toBe(fx.pid);
      expect(sameHelperProcess(fx)).toBeDefined();
      expect(sameHelperProcess(supervisor)?.ppid).toBe(fx.pid);
      expect(signalHelperProcess(supervisor, signal)).toBe(true);
      await waitForHelperSupervisor(supervisor, signal === "SIGSTOP");

      if (signal === "SIGKILL") {
        // Only after supervisor death: the same fx must execute a later tool call.
        expect(sameHelperProcess(fx)).toBeDefined();
        await active.sendText("Run a fresh shell command after the supervisor fault.");
        await active.waitForText("SESSION_HELPER_FAULT_FOLLOW_UP_OK", TIMEOUT);
        await active.waitForComposer(TIMEOUT);
        expect(gateway.requests).toHaveLength(4);
        const result = toolResultEnvelope(gateway.requests[3]!.body, "shell_after_supervisor_fault");
        expect(result).toContain('\\"state\\":\\"completed\\"');
        expect(result).toContain('\\"exit_code\\":0');
        expect(result).toContain("SHELL_AFTER_SUPERVISOR_FAULT");
        expect(toolResultEnvelope(gateway.requests[3]!.body, "helper_before_supervisor_fault")).toBe(started);
        expect(await active.captureFullScrollback()).toContain("SESSION_HELPER_FAULT_FOLLOW_UP_OK");
        expect(sameHelperProcess(fx)).toBeDefined();
      } else {
        expect(sameHelperProcess(supervisor)?.state).toContain("T");
        expect(sameHelperProcess(cleanup.helper!)).toBeDefined();
      }

      // No fixture signal or tmux kill may contribute to these success oracles.
      await active.sendLiteral("/quit");
      const quitStarted = performance.now();
      await active.sendKeys("Enter");
      expect(await active.waitForSessionEnd(Math.max(1, 5_000 - (performance.now() - quitStarted)))).toBe(true);
      expect(performance.now() - quitStarted).toBeLessThan(5_000);
      expect(active.paneStatus()).toEqual({ dead: true, status: 0 });
      await expectHelperExited(pid, helper.pidPath);
      expect(sameHelperProcess(supervisor)).toBeUndefined();
      expect(sameHelperProcess(fx)).toBeUndefined();
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
}

test.skipIf(!tmuxAvailable())(
  "captured shell session helper survives natural exit across turns and dies on quit",
  async () => {
    const fixture = createFixture("fx-shell-helper-");
    const helper = createSessionHelper(fixture);
    const gateway = startFakeGateway([
      fakeGatewayToolCall("helper_start", "shell", {
        request: {
          action: "run",
          command: helper.command("start"),
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_STARTED"),
      fakeGatewayToolCall("helper_probe", "shell", {
        request: {
          action: "run",
          command: helper.command("probe"),
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_RESPONDED"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Start the redirected session helper and finish this turn.");
    await active.waitForText("SESSION_HELPER_STARTED", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    const pid = helperPid(helper.pidPath);
    const started = toolResultEnvelope(gateway.requests[1]!.body, "helper_start");
    expect(started).toContain('\\"state\\":\\"completed\\"');
    expect(started).toContain('\\"exit_code\\":0');
    expect(started).toContain(`HELPER_STARTED:${pid}`);
    process.kill(pid, 0);

    await active.sendText("Ask the same helper to respond from a new captured shell call.");
    await active.waitForText("SESSION_HELPER_RESPONDED", TIMEOUT);
    expect(gateway.requests).toHaveLength(4);
    const probed = toolResultEnvelope(gateway.requests[3]!.body, "helper_probe");
    expect(probed).toContain('\\"state\\":\\"completed\\"');
    expect(probed).toContain('\\"exit_code\\":0');
    expect(probed).toContain(`HELPER_REPLY:${pid}`);
    expect(helperPid(helper.pidPath)).toBe(pid);
    process.kill(pid, 0);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("SESSION_HELPER_STARTED");
    expect(scrollback).toContain("SESSION_HELPER_RESPONDED");

    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    await expectHelperExited(pid, helper.pidPath);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "captured shell session helper dies on clear and the replacement session runs shell work",
  async () => {
    const fixture = createFixture("fx-shell-helper-clear-");
    const helper = createSessionHelper(fixture);
    const gateway = startFakeGateway([
      fakeGatewayToolCall("helper_before_clear", "shell", {
        request: {
          action: "run",
          command: helper.command("start"),
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_BEFORE_CLEAR"),
      fakeGatewayToolCall("helper_after_clear", "shell", {
        request: {
          action: "run",
          command: "printf SHELL_AFTER_SESSION_CLEAR",
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_CLEAR_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Start a redirected helper in this session.");
    await active.waitForText("SESSION_HELPER_BEFORE_CLEAR", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    const pid = helperPid(helper.pidPath);
    const started = toolResultEnvelope(gateway.requests[1]!.body, "helper_before_clear");
    expect(started).toContain('\\"state\\":\\"completed\\"');
    expect(started).toContain('\\"exit_code\\":0');
    expect(started).toContain(`HELPER_STARTED:${pid}`);
    process.kill(pid, 0);

    await active.sendText("/clear");
    await expectHelperExited(pid, helper.pidPath);
    await active.waitForComposer(TIMEOUT);
    expect(active.isPaneAlive()).toBe(true);
    await active.sendText("Run a fresh shell command in the replacement session.");
    await active.waitForText("SESSION_HELPER_CLEAR_OK", TIMEOUT);
    expect(gateway.requests).toHaveLength(4);
    expect(gateway.requests[2]!.body).not.toContain("SESSION_HELPER_BEFORE_CLEAR");
    const result = toolResultEnvelope(gateway.requests[3]!.body, "helper_after_clear");
    expect(result).toContain('\\"state\\":\\"completed\\"');
    expect(result).toContain('\\"exit_code\\":0');
    expect(result).toContain("SHELL_AFTER_SESSION_CLEAR");
    expect(await active.captureFullScrollback()).toContain("SESSION_HELPER_CLEAR_OK");
    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "captured shell session helper dies after unexpected fx process death",
  async () => {
    const fixture = createFixture("fx-shell-helper-death-");
    const helper = createSessionHelper(fixture);
    const fxPidPath = join(fixture.workspace, "fx.pid");
    const wrapperPath = join(fixture.workspace, "launch-fx.sh");
    writeFileSync(wrapperPath, 'printf "%s" "$$" > "$1"\nexec "$2"\n');
    const gateway = startFakeGateway([
      fakeGatewayToolCall("helper_before_death", "shell", {
        request: {
          action: "run",
          command: helper.command("start"),
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_BEFORE_DEATH"),
    ]);
    gateways.push(gateway);
    const active = await launch(
      fixture,
      gateway,
      `/bin/sh ${[wrapperPath, fxPidPath, FX_BIN].map((path) => JSON.stringify(path)).join(" ")}`,
    );
    await active.sendText("Start a redirected helper and finish the shell call.");
    await active.waitForText("SESSION_HELPER_BEFORE_DEATH", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    const pid = helperPid(helper.pidPath);
    const fxPid = helperPid(fxPidPath);
    expect(fxPid).not.toBe(pid);
    const started = toolResultEnvelope(gateway.requests[1]!.body, "helper_before_death");
    expect(started).toContain('\\"state\\":\\"completed\\"');
    expect(started).toContain('\\"exit_code\\":0');
    expect(started).toContain(`HELPER_STARTED:${pid}`);
    process.kill(pid, 0);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");

    // Kill only fx, not its process group or tmux host, before any fixture cleanup.
    process.kill(fxPid, "SIGKILL");
    await expectHelperExited(pid, helper.pidPath);
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    expect(() => process.kill(fxPid, 0)).toThrow();
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "captured shell session helper is cleaned when Ctrl-C cancels the initial run",
  async () => {
    const fixture = createFixture("fx-shell-helper-cancel-");
    const helper = createSessionHelper(fixture);
    const gateway = startFakeGateway([
      fakeGatewayToolCall("helper_cancel_run", "shell", {
        request: {
          action: "run",
          command: helper.command("hold"),
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayToolCall("helper_after_cancel", "shell", {
        request: {
          action: "run",
          command: "printf SHELL_AFTER_CTRL_C",
          profile: "clean",
          yield_time_ms: 30_000,
        },
      }),
      fakeGatewayFinalText("SESSION_HELPER_CTRL_C_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Start the helper and wait for the captured command.");
    await waitForFile(helper.pidPath);
    const pid = helperPid(helper.pidPath);
    process.kill(pid, 0);
    await active.waitForComposer(TIMEOUT);
    expect(gateway.requests).toHaveLength(1);

    await active.sendKeys("C-c");
    await active.waitForText("What can fx do differently?", TIMEOUT);
    await expectHelperExited(pid, helper.pidPath);
    expect(active.isPaneAlive()).toBe(true);
    expect(gateway.requests).toHaveLength(1);
    await active.sendText("Run a fresh shell command after cancellation.");
    await active.waitForText("SESSION_HELPER_CTRL_C_OK", TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[1]!.body).toContain("<turn_aborted>");
    const result = toolResultEnvelope(gateway.requests[2]!.body, "helper_after_cancel");
    expect(result).toContain('\\"state\\":\\"completed\\"');
    expect(result).toContain('\\"exit_code\\":0');
    expect(result).toContain("SHELL_AFTER_CTRL_C");
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("What can fx do differently?");
    expect(scrollback).toContain("SESSION_HELPER_CTRL_C_OK");
    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

for (const ending of ["timeout", "stop"] as const) {
  test.skipIf(!tmuxAvailable())(
    `captured shell session helper is cleaned on ${ending} before later work`,
    async () => {
      const fixture = createFixture(`fx-shell-helper-${ending}-`);
      const helper = createSessionHelper(fixture);
      let pid = 0;
      const gateway = startFakeGateway([
        fakeGatewayToolCall("helper_hold", "shell", {
          request: {
            action: "run",
            command: helper.command("hold"),
            profile: "clean",
            yield_time_ms: 0,
            ...(ending === "timeout" ? { timeout_ms: 8_000 } : {}),
          },
        }),
        async (body) => {
          const sessionId = findSessionId(JSON.parse(body));
          if (!sessionId) return new Response("missing session id", { status: 500 });
          await waitForFile(helper.pidPath);
          pid = helperPid(helper.pidPath);
          process.kill(pid, 0);
          return fakeGatewayToolCall("helper_end", "shell", {
            request: ending === "timeout"
              ? { action: "interact", session_id: sessionId, yield_time_ms: 30_000 }
              : { action: "stop", session_id: sessionId, force: true },
          });
        },
        async () => {
          await expectHelperExited(pid, helper.pidPath);
          return fakeGatewayToolCall("helper_follow_up", "shell", {
            request: {
              action: "run",
              command: "printf HELPER_CLEANUP_FOLLOW_UP",
              profile: "clean",
              yield_time_ms: 30_000,
            },
          });
        },
        fakeGatewayFinalText("SESSION_HELPER_CLEANUP_OK"),
      ]);
      gateways.push(gateway);
      const active = await launch(fixture, gateway);
      await active.sendText(`Start the helper, ${ending} its captured command, then run later work.`);
      await active.waitForText("SESSION_HELPER_CLEANUP_OK", TIMEOUT);
      expect(gateway.requests).toHaveLength(4);
      const ended = toolResultEnvelope(gateway.requests[2]!.body, "helper_end");
      expect(ended).toContain('\\"termination_indeterminate\\":false');
      if (ending === "timeout") {
        expect(ended).toContain('\\"error\\":\\"TimeoutExpired\\"');
      } else {
        expect(ended).toContain('\\"state\\":\\"stopped\\"');
      }
      const followUp = toolResultEnvelope(gateway.requests[3]!.body, "helper_follow_up");
      expect(followUp).toContain('\\"exit_code\\":0');
      expect(followUp).toContain("HELPER_CLEANUP_FOLLOW_UP");
      expect(active.isPaneAlive()).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
}

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
