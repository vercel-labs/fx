import { afterEach, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  terminalFixtureShell,
} from "./tmux-helpers";

const TIMEOUT = 45_000;
const TERMINAL_FIXTURE_SHELL = terminalFixtureShell();

type Fixture = {
  root: string;
  home: string;
  workspace: string;
  tracePath: string;
};

type Gateway = ReturnType<typeof startFakeGateway>;

const fixtures: Fixture[] = [];
const gateways: Gateway[] = [];

afterEach(async () => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const fixture of fixtures.splice(0)) {
    await cleanupTerminalHost(fixture.home);
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

function createFixture(label: string): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-shell-parity-${label}-`)));
  const home = join(root, "home");
  const workspacePath = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspacePath, { recursive: true });
  const workspace = realpathSync(workspacePath);
  writeFileSync(join(home, ".fx", "settings.json"), "{}\n");
  const fixture = {
    root,
    home,
    workspace,
    tracePath: join(root, "trace.log"),
  };
  fixtures.push(fixture);
  return fixture;
}

function gatewayEnv(
  fixture: Fixture,
  gateway: Gateway,
): Record<string, string | undefined> {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "shell-parity-fake-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "yolo",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TRACE_LOG: fixture.tracePath,
    FX_TRACE_SCOPES: "agent,core,gateway,stream,tool,permission,terminal",
    FX_TERMINAL_HOST_IDLE_MS: "200",
  };
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [value.text, value.value, value.content].map(contentText).join("");
  }
  return "";
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as {
    prompt: Array<{ content: unknown }>;
  };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) =>
    part.type === "tool-result" && part.toolCallId === callId
  );
  if (!result) throw new Error(`missing tool result for ${callId}`);
  return contentText(result.output);
}

function terminalRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot).flatMap((sessionId) => {
    const stateRoot = join(sessionsRoot, sessionId, "terminal", "state");
    if (!existsSync(stateRoot)) return [];
    return readdirSync(stateRoot).flatMap((name) =>
      name.startsWith("record-") && name.endsWith(".json")
        ? [JSON.parse(readFileSync(join(stateRoot, name), "utf8")) as Record<string, unknown>]
        : []
    );
  });
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function terminalHostPid(home: string): number | null {
  try {
    const identity = JSON.parse(
      readFileSync(join(home, ".fx", "terminal-host", "host.json"), "utf8"),
    ) as { pid?: unknown };
    const pid = Number(identity.pid);
    return Number.isSafeInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

async function cleanupTerminalHost(home: string): Promise<void> {
  const identityPath = join(home, ".fx", "terminal-host", "host.json");
  const naturalDeadline = Date.now() + 3_000;
  while (Date.now() < naturalDeadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }

  const pid = terminalHostPid(home);
  if (pid === null || !processExists(pid)) return;
  process.kill(pid, "SIGTERM");
  const termDeadline = Date.now() + 500;
  while (Date.now() < termDeadline) {
    if (!processExists(pid)) return;
    await Bun.sleep(25);
  }
  process.kill(pid, "SIGKILL");
  const killDeadline = Date.now() + 500;
  while (Date.now() < killDeadline) {
    if (!processExists(pid)) return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal host cleanup could not stop pid ${pid}`);
}

test("code mode preserves parallel captured command results", async () => {
  const fixture = createFixture("code");
  const alphaReady = join(fixture.workspace, "alpha.ready");
  const betaReady = join(fixture.workspace, "beta.ready");
  const alphaCommand =
    `: > ${JSON.stringify(alphaReady)}; ` +
    `i=0; while [ ! -e ${JSON.stringify(betaReady)} ] && [ "$i" -lt 100 ]; do sleep 0.01; i=$((i+1)); done; ` +
    `test -e ${JSON.stringify(betaReady)}; printf 'PARITY_ALPHA\\n'`;
  const betaCommand =
    `: > ${JSON.stringify(betaReady)}; ` +
    `i=0; while [ ! -e ${JSON.stringify(alphaReady)} ] && [ "$i" -lt 100 ]; do sleep 0.01; i=$((i+1)); done; ` +
    `test -e ${JSON.stringify(alphaReady)}; printf 'PARITY_BETA\\n'`;
  const source = [
    "const [alpha, beta] = await Promise.all([",
    `  tools.terminal({ action: 'exec', command: ${JSON.stringify(alphaCommand)}, cwd: ${JSON.stringify(fixture.workspace)}, profile: 'clean', timeout_ms: 30000 }),`,
    `  tools.terminal({ action: 'exec', command: ${JSON.stringify(betaCommand)}, cwd: ${JSON.stringify(fixture.workspace)}, profile: 'clean', timeout_ms: 30000 }),`,
    "]);",
    "return {",
    "  alpha_exit: alpha.command_result.exit_code,",
    "  alpha_output: alpha.output,",
    "  beta_exit: beta.command_result.exit_code,",
    "  beta_output: beta.output,",
    "};",
  ].join("\n");
  const gateway = startFakeGateway([
    fakeGatewayToolCall("shell_parity_code", "code", { source }),
    (body) => {
      const result = JSON.parse(toolResultText(body, "shell_parity_code")) as {
        result: {
          alpha_exit: number;
          alpha_output: string;
          beta_exit: number;
          beta_output: string;
        };
        calls: Array<{ id: number; tool: string; status: string }>;
      };
      expect(result.result.alpha_exit).toBe(0);
      expect(result.result.alpha_output).toContain("PARITY_ALPHA");
      expect(result.result.beta_exit).toBe(0);
      expect(result.result.beta_output).toContain("PARITY_BETA");
      expect(result.calls).toEqual([
        { id: 0, tool: "terminal", status: "success" },
        { id: 1, tool: "terminal", status: "success" },
      ]);
      return fakeGatewayFinalText("Shell parity captured flow complete.");
    },
  ]);
  gateways.push(gateway);

  const result = await runFx(
    ["ask", "--json", "--yolo", "--no-save", "Run the captured shell parity flow."],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );

  expect(result.code).toBe(0);
  const output = JSON.parse(result.stdout) as {
    final_output: string;
    tool_calls: Array<{ name: string; status: string }>;
  };
  expect(output.final_output).toBe("Shell parity captured flow complete.");
  expect(output.tool_calls.map(({ name, status }) => ({ name, status }))).toEqual([
    { name: "terminal", status: "success" },
    { name: "terminal", status: "success" },
    { name: "code", status: "success" },
  ]);
  expect(result.stderr).toContain("PARITY_ALPHA");
  expect(result.stderr).toContain("PARITY_BETA");
  expect(existsSync(alphaReady)).toBe(true);
  expect(existsSync(betaReady)).toBe(true);
  expect(terminalRecords(fixture.home)).toEqual([]);
  expect(gateway.requests).toHaveLength(2);
});

test("saved ask owns a background PTY from start through close", async () => {
  const fixture = createFixture("durable");
  const command =
    "printf 'PARITY_READY\\n'; " +
    "(sleep 0.1; printf 'PARITY_BACKGROUND\\n') & bg=$!; " +
    "IFS= read -r line; printf 'PARITY_ECHO:%s\\n' \"$line\"; " +
    "wait \"$bg\"; printf 'PARITY_DONE\\n'";
  let terminalSessionId = "";
  const gateway = startFakeGateway([
    fakeGatewayToolCall("shell_parity_start", "terminal", {
      request: {
        action: "start",
        cwd: fixture.workspace,
        command,
        profile: null,
        shell: {
          kind: "executable",
          path: TERMINAL_FIXTURE_SHELL,
          clean_start: true,
        },
        backend: "native",
        return_when: { kind: "match", pattern: "PARITY_READY" },
        wait_ceiling_ms: 20_000,
        dimensions: { rows: 24, columns: 80 },
        initial_monitors: null,
      },
    }),
    (body) => {
      const start = JSON.parse(toolResultText(body, "shell_parity_start")) as {
        success: { start: { session: { session_id: string } } };
      };
      terminalSessionId = start.success.start.session.session_id;
      expect(terminalSessionId.length).toBeGreaterThan(0);
      return fakeGatewayToolCall("shell_parity_write", "terminal", {
        request: {
          action: "write",
          session_id: terminalSessionId,
          input: { text: "violet comet\n" },
        },
      });
    },
    (body) => {
      const write = toolResultText(body, "shell_parity_write");
      expect(write).toContain('"accepted_bytes":13');
      expect(write).toContain('"write_lease":"none"');
      return fakeGatewayToolCall("shell_parity_wait", "terminal", {
        request: {
          action: "wait",
          session_id: terminalSessionId,
          return_when: { kind: "exit" },
          wait_ceiling_ms: 20_000,
        },
      });
    },
    (body) => {
      expect(toolResultText(body, "shell_parity_wait"))
        .toContain('"outcome":{"exited":0}');
      return fakeGatewayToolCall("shell_parity_read", "terminal", {
        request: {
          action: "read",
          session_id: terminalSessionId,
          cursor_segment: 1,
          cursor_offset: 0,
        },
      });
    },
    (body) => {
      const read = toolResultText(body, "shell_parity_read");
      expect(read).toContain("PARITY_READY");
      expect(read).toContain("PARITY_BACKGROUND");
      expect(read).toContain("PARITY_ECHO:violet comet");
      expect(read).toContain("PARITY_DONE");
      return fakeGatewayToolCall("shell_parity_close", "terminal", {
        request: {
          action: "close",
          session_id: terminalSessionId,
          close_policy: "force",
        },
      });
    },
    (body) => {
      const close = toolResultText(body, "shell_parity_close");
      expect(close).toContain(`"session_id":"${terminalSessionId}"`);
      expect(close).toContain('"lifecycle":"closed"');
      return fakeGatewayFinalText("Shell parity durable flow complete.");
    },
  ]);
  gateways.push(gateway);

  const result = await runFx(
    ["ask", "--json", "--yolo", "Run the persistent shell parity flow."],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );

  expect(result.code).toBe(0);
  const output = JSON.parse(result.stdout) as {
    final_output: string;
    tool_calls: Array<{ name: string; status: string }>;
  };
  expect(output.final_output).toBe("Shell parity durable flow complete.");
  expect(output.tool_calls).toEqual([
    { name: "terminal", status: "success" },
    { name: "terminal", status: "success" },
    { name: "terminal", status: "success" },
    { name: "terminal", status: "success" },
    { name: "terminal", status: "success" },
  ]);
  expect(gateway.requests).toHaveLength(6);
  const record = terminalRecords(fixture.home).find((candidate) =>
    candidate.session_id === terminalSessionId
  );
  expect(record?.lifecycle).toBe("closed");
  expect(result.stderr).not.toContain("failed");
});
