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
import { runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import { pngPixelSize, solidPng } from "./fixtures/image-encoding";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const MODERN_RESULT = "MODERN_MCP_TOOL_RESULT";
const LEGACY_RESULT = "LEGACY_MCP_TOOL_RESULT";
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const LEGACY_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-legacy-stdio.mjs");
const REPO_ROOT = realpathSync(join(import.meta.dirname, "..", ".."));

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
  wireLogPath: string;
  launchLogPath: string;
  traceLogPath: string;
  invalidationReleasePath: string;
  environmentCapturePath: string;
};

type WireEntry = {
  pid: number;
  sequence?: number;
  message: {
    method?: string;
    id?: number | string;
    result?: Record<string, unknown>;
    error?: Record<string, unknown>;
    params?: Record<string, unknown>;
  };
};

let tui: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let cleanupRoot: string | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  if (activeCleanupRoot) {
    rmSync(activeCleanupRoot, { recursive: true, force: true });
  }
});

type RootOptions = {
  /** The 2025 fixture accepts any client the spec allows, not only v1's wire choices. */
  mode?:
    | "normal"
    | "progress"
    | "stall_operation"
    | "stall_startup"
    | "tool_failure"
    | "image_result"
    | "response_missing_jsonrpc"
    | "response_wrong_jsonrpc"
    | "response_missing_payload"
    | "response_ambiguous_payload"
    | "mrtr_input_required"
    | "mrtr_url_required"
    | "mrtr_full_form"
    | "mrtr_collision_form"
    | "mrtr_unsafe_form"
    | "direct_form"
    | "url_required_error"
    | "url_required_multiple"
    | "url_required_malformed_completion"
    | "block_then_stall_recovery"
    | "subscription_cache"
    | "features"
    | "features_no_tools"
    | "feature_protocol_error"
    | "draft7_schema"
    | "list_changed"
    | "crash_once"
    | "crash_always"
    | "startup_exit"
    | "startup_exit_after_delay"
    | "startup_garbage"
    | "exit_after_result";
  startupTimeoutMs?: number;
  protocolErrorMessage?: string;
  operationTimeoutMs?: number;
  restartLimit?: number;
  recoveredToolName?: string;
  expectedElicitation?: "form" | "url" | "both";
  elicitationUrl?: string;
  compactField?: Record<string, unknown>;
  legacyVersion?: "2025-06-18" | "2025-11-25";
  legacyDiscoveryVersions?: readonly ["2024-11-05", "2025-06-18", "2025-11-25"];
  legacyDiscoveryMethodNotFound?: boolean;
  legacyDiscoveryInvalidParams?: boolean;
  legacyRejectNewerInitialize?: boolean;
  draft7Pattern?: string;
  urlRequiredOperation?: "tools" | "resources" | "prompts";
  recordLaunchAttempts?: boolean;
  required?: boolean;
  resourcesSubscribe?: boolean;
  resourceTtlMs?: number;
  captureEnvironment?: boolean;
  image?: Buffer;
};

function createRoot(
  label: string,
  scriptPath: string,
  options: RootOptions = {},
): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-mcp-${label}-`)));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const wireLogPath = join(root, "mcp-wire.jsonl");
  const launchLogPath = join(root, "mcp-launches.txt");
  const invalidationReleasePath = join(root, "mcp-invalidation-release");
  const environmentCapturePath = join(root, "mcp-environment.json");
  const imagePath = join(root, "mcp-image.png");
  if (options.image) writeFileSync(imagePath, options.image);
  const command = options.recordLaunchAttempts
    ? [
      "/bin/sh",
      "-c",
      `printf '%s\\n' "$$" >> "$FX_MCP_LAUNCH_LOG"; exec "$FX_MCP_FIXTURE_RUNTIME" "$FX_MCP_FIXTURE_PATH"`,
    ]
    : [process.execPath, scriptPath];
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({}),
  );
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command,
          enabled: true,
          required: options.required,
          environment: {
            FX_MCP_WIRE_LOG: wireLogPath,
            FX_MCP_LAUNCH_LOG: options.recordLaunchAttempts
              ? launchLogPath
              : undefined,
            FX_MCP_FIXTURE_RUNTIME: options.recordLaunchAttempts
              ? process.execPath
              : undefined,
            FX_MCP_FIXTURE_PATH: options.recordLaunchAttempts
              ? scriptPath
              : undefined,
            FX_MCP_PID_PATH: join(root, "mcp.pid"),
            FX_MCP_MODE: options.mode ?? "normal",
            FX_MCP_IMAGE_PATH: options.image ? imagePath : undefined,
            FX_MCP_PROTOCOL_ERROR_MESSAGE: options.protocolErrorMessage,
            FX_MCP_CRASH_MARKER: join(root, "mcp-crashed"),
            FX_MCP_RECOVERY_READY_PATH: join(root, "mcp-recovery-ready"),
            FX_MCP_INVALIDATION_RELEASE_PATH: invalidationReleasePath,
            FX_MCP_RECOVERED_TOOL_NAME: options.recoveredToolName,
            FX_MCP_EXPECT_ELICITATION: options.expectedElicitation,
            FX_MCP_ELICITATION_URL: options.elicitationUrl,
            FX_MCP_COMPACT_FIELD: options.compactField ? JSON.stringify(options.compactField) : undefined,
            FX_MCP_RESOURCES_SUBSCRIBE: options.resourcesSubscribe === false
              ? "0"
              : undefined,
            FX_MCP_RESOURCE_TTL_MS: options.resourceTtlMs?.toString(),
            FX_MCP_LEGACY_VERSION: options.legacyVersion,
            FX_MCP_LEGACY_DISCOVERY_VERSIONS:
              options.legacyDiscoveryVersions?.join(","),
            FX_MCP_LEGACY_DISCOVERY_METHOD_NOT_FOUND:
              options.legacyDiscoveryMethodNotFound ? "1" : undefined,
            FX_MCP_LEGACY_DISCOVERY_INVALID_PARAMS:
              options.legacyDiscoveryInvalidParams ? "1" : undefined,
            FX_MCP_LEGACY_REJECT_NEWER_INITIALIZE:
              options.legacyRejectNewerInitialize ? "1" : undefined,
            FX_MCP_DRAFT7_PATTERN: options.draft7Pattern,
            FX_MCP_URL_REQUIRED_OPERATION: options.urlRequiredOperation,
            FX_MCP_ENV_CAPTURE: options.captureEnvironment
              ? environmentCapturePath
              : undefined,
            FX_MCP_ENV_SENTINEL: options.captureEnvironment
              ? "configured"
              : undefined,
          },
          startup_timeout_ms: options.startupTimeoutMs,
          operation_timeout_ms: options.operationTimeoutMs,
          restart_limit: options.restartLimit,
        },
      },
    }),
  );
  return {
    root,
    home,
    workspace,
    wireLogPath,
    launchLogPath,
    traceLogPath: join(root, "fx-trace.log"),
    invalidationReleasePath,
    environmentCapturePath,
  };
}

function moveProfileFixtureToWorkspace(root: FixtureRoot): void {
  const profilePath = join(root.home, ".fx", "mcp.json");
  const profile = JSON.parse(readFileSync(profilePath, "utf8"));
  const fixture = profile.mcp.fixture;
  if (Array.isArray(fixture.command)) {
    fixture.args = fixture.command.slice(1);
    fixture.command = fixture.command[0];
  }
  writeFileSync(
    join(root.workspace, ".mcp.json"),
    JSON.stringify({ mcpServers: { fixture } }),
  );
  writeFileSync(profilePath, JSON.stringify({ mcp: {} }));
}

/** The text fx sent the model as one tool call's result. */
function toolResultText(body: string, callId: string): string {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
  const part = prompt
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []) as Array<Record<string, unknown>>)
    .find((item) => item.type === "tool-result" && item.toolCallId === callId);
  if (!part) throw new Error(`missing the tool result for ${callId}`);
  return contentText(part.output);
}

function fixtureEnv(root: FixtureRoot, activeGateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-mcp-stdio-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: activeGateway.baseUrl,
    FX_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_MODEL: MODEL,
    FX_TRACE_LOG: root.traceLogPath,
    FX_TRACE_SCOPES: "mcp",
  };
}

function startToolGateway(finalText: string) {
  return startFakeGateway([
    fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
    fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
    fakeGatewayFinalText(finalText),
  ], {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
}

function writeFakeUrlOpeners(directory: string, script: string): void {
  for (const name of ["open", "xdg-open"]) {
    writeFileSync(join(directory, name), script, { mode: 0o755 });
  }
}

function readWire(path: string): WireEntry[] {
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as WireEntry);
}

function readAttemptedPids(path: string): number[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map(Number);
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function expectFixtureProcessesExited(wire: WireEntry[], timeoutMs = 5_000) {
  return expectProcessesExited(wire.map((entry) => entry.pid), timeoutMs);
}

async function expectProcessesExited(pids: Iterable<number>, timeoutMs = 5_000) {
  const uniquePids = new Set(pids);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if ([...uniquePids].every((pid) => !isProcessAlive(pid))) return;
    await Bun.sleep(25);
  }
  const live = [...uniquePids].filter(isProcessAlive);
  throw new Error(`MCP fixture processes did not exit: ${live.join(", ")}`);
}

async function waitForTtyAskExit(
  session: TmuxSession,
  expectedStatus: number | null,
  timeoutMs = 10_000,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const status = session.paneStatus();
    if (status.dead) {
      expect(status.status).toBe(expectedStatus);
      return;
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for terminal fx ask to exit.\n${await session.captureFullScrollback()}`,
  );
}

describe("modern MCP stdio compatibility", () => {
  test.skipIf(!tmuxAvailable())(
    "the TUI shows exact dynamic MCP arguments before human approval",
    async () => {
      // The shell can ask, so it says so in every request's capabilities.
      const root = createRoot("tui-human-approval-arguments", MODERN_FIXTURE, {
        expectedElicitation: "both",
      });
      const stderrPath = join(root.root, "stderr.log");
      const expectedArguments = '{"text":"mcp-live-human-active"}';
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("call_mcp", TOOL_NAME, {
          text: "mcp-live-human-active",
        }),
        fakeGatewayFinalText("MCP approval denied without transport."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 40,
        stderrPath,
        env: {
          ...fixtureEnv(root, activeGateway),
          FX_PERMISSION_MODE: "ask",
        },
      });

      await tui.waitForComposer(15_000);
      await tui.sendText(
        "Call the MCP fixture only after I approve its exact arguments.",
      );
      const approval = await tui.waitForText(
        `Arguments for this request: ${expectedArguments}`,
        20_000,
      );
      expect(approval).toContain("Allow this MCP tool call?");
      expect(approval).toContain(TOOL_NAME);
      expect(approval).toContain(
        "This MCP tool needs approval before fx can send the request.",
      );
      expect(approval).toContain("3. Deny");
      expect(
        readWire(root.wireLogPath).some(
          (entry) => entry.message.method === "tools/call",
        ),
      ).toBe(false);

      await tui.sendKeys("3");
      await tui.waitForText("MCP approval denied without transport.", 10_000);
      expect(
        readWire(root.wireLogPath).some(
          (entry) => entry.message.method === "tools/call",
        ),
      ).toBe(false);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    40_000,
  );

  test("repository-local MCP configuration never launches a process or network request", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mcp-project-trust-")));
    cleanupRoot = root;
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const marker = join(root, "project-mcp-launched");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(join(workspace, ".fx"), { recursive: true });
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
    writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: {} }));

    let projectRequestCount = 0;
    const projectEndpoint = Bun.serve({
      port: 0,
      fetch() {
        projectRequestCount += 1;
        return new Response("project MCP must remain unreachable", { status: 500 });
      },
    });
    const hostile = JSON.stringify({
      mcpServers: {
        local: {
          type: "local",
          command: "/bin/sh",
          args: ["-c", `printf launched > ${marker}`],
          enabled: true,
          required: true,
        },
        remote: {
          type: "http",
          url: `http://127.0.0.1:${projectEndpoint.port}/mcp`,
          headers: { Authorization: "Bearer ${PROJECT_MCP_SECRET}" },
          enabled: true,
          required: true,
        },
      },
    });
    writeFileSync(join(workspace, ".mcp.json"), hostile);
    writeFileSync(join(workspace, ".fx", "mcp.json"), hostile);

    gateway = startFakeGateway([fakeGatewayFinalText("Project MCP stayed inert.")], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Confirm the workspace is available."],
        {
          cwd: workspace,
          env: {
            ...fixtureEnv({
              root,
              home,
              workspace,
              wireLogPath: join(root, "wire.jsonl"),
              launchLogPath: join(root, "launches.txt"),
              traceLogPath: join(root, "trace.log"),
              invalidationReleasePath: join(root, "release"),
            }, gateway),
            PROJECT_MCP_SECRET: "must-not-leave-the-process",
          },
          timeoutMs: 15_000,
        },
      );
      expect(result.code).toBe(0);
      expect(gateway.requests).toHaveLength(1);
      expect(existsSync(marker)).toBe(false);
      expect(projectRequestCount).toBe(0);
    } finally {
      projectEndpoint.stop(true);
    }
  }, 20_000);

  test("fx ask skips pending workspace MCP and uses it after explicit trust", async () => {
    const root = createRoot("workspace-ask", MODERN_FIXTURE);
    moveProfileFixtureToWorkspace(root);
    const projectPath = join(root.workspace, ".mcp.json");
    const project = JSON.parse(readFileSync(projectPath, "utf8"));
    project.mcpServers.fixture.command = "${WORKSPACE_MCP_COMMAND}";
    project.mcpServers.fixture.args = ["${WORKSPACE_MCP_FIXTURE}"];
    project.mcpServers.fixture.env = {
      FX_MCP_RESULT_TEXT: "${WORKSPACE_MCP_RESULT:-MODERN_MCP_TOOL_RESULT}",
      FX_MCP_WIRE_LOG: "${WORKSPACE_MCP_WIRE_LOG}",
      FX_MCP_PID_PATH: "${WORKSPACE_MCP_PID_PATH}",
      FX_MCP_MODE: "${WORKSPACE_MCP_MODE:-normal}",
    };
    delete project.mcpServers.fixture.environment;
    writeFileSync(projectPath, JSON.stringify(project));
    gateway = startFakeGateway([
      fakeGatewayFinalText("WORKSPACE_MCP_SKIPPED"),
      fakeGatewayToolCall("workspace_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("workspace_call", TOOL_NAME, { text: "workspace" }),
      fakeGatewayFinalText("WORKSPACE_MCP_READY"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const env = {
      ...fixtureEnv(root, gateway),
      WORKSPACE_MCP_COMMAND: process.execPath,
      WORKSPACE_MCP_FIXTURE: MODERN_FIXTURE,
      WORKSPACE_MCP_WIRE_LOG: root.wireLogPath,
      WORKSPACE_MCP_PID_PATH: join(root.root, "mcp.pid"),
    };
    const skipped = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the workspace MCP."],
      {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      },
    );
    expect(skipped.code).toBe(0);
    expect(skipped.stdout).toContain("WORKSPACE_MCP_SKIPPED");
    expect(skipped.stderr).toContain(
      "skipped unapproved project MCP servers: fixture",
    );
    expect(existsSync(root.wireLogPath)).toBe(false);
    let settings = readFileSync(join(root.home, ".fx", "settings.json"), "utf8");
    expect(settings).not.toContain("enabledMcpjsonServers");
    expect(settings).not.toContain("enableAllProjectMcpServers");

    const trusted = await runFx(
      ["mcp", "approve", "fixture"],
      { cwd: root.workspace, env },
    );
    expect(trusted.code).toBe(0);
    // It says what the approved server runs, as the file writes it.
    expect(trusted.stdout).toBe("Approved fixture, which runs: '${WORKSPACE_MCP_COMMAND}' '${WORKSPACE_MCP_FIXTURE}'\n");
    settings = readFileSync(join(root.home, ".fx", "settings.json"), "utf8");
    expect(settings).toContain("enabledMcpjsonServers");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the workspace MCP."],
      { cwd: root.workspace, env, timeoutMs: 20_000 },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("WORKSPACE_MCP_READY");
    expect(result.stderr).not.toContain("skipped unapproved project MCP servers");
    expect(readWire(root.wireLogPath).some((entry) =>
      entry.message.method === "tools/call"
    )).toBe(true);
    await expectFixtureProcessesExited(readWire(root.wireLogPath));
  }, 35_000);

  test("fx ask reports rejected workspace MCP entries on stderr", async () => {
    const root = createRoot("workspace-invalid-entry", MODERN_FIXTURE);
    moveProfileFixtureToWorkspace(root);
    const projectPath = join(root.workspace, ".mcp.json");
    const project = JSON.parse(readFileSync(projectPath, "utf8"));
    project.mcpServers.broken = {
      type: "http",
      url: "not a url",
    };
    writeFileSync(projectPath, JSON.stringify(project));
    gateway = startFakeGateway([fakeGatewayFinalText("WORKSPACE_PARSE_CONTINUED")], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Confirm the workspace is available."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("WORKSPACE_PARSE_CONTINUED");
    expect(result.stdout).not.toContain("broken");
    expect(result.stderr).toContain("skipped unapproved project MCP servers: fixture");
    expect(result.stderr).toContain(
      ".mcp.json server 'broken' was skipped: its \"url\" isn't valid.",
    );
    expect(existsSync(root.wireLogPath)).toBe(false);
  }, 25_000);

  // One text item over 1 MiB used to fail the whole result. Now a
  // saved session keeps the whole result behind a handle, and without one it
  // is cut to the model's limit like any big result.
  describe("big MCP results", () => {
    const bigResultRoot = (label: string) => {
      const root = createRoot(label, MODERN_FIXTURE);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      profile.mcp.fixture.environment.FX_MCP_RESULT_PAD_BYTES = String(1536 * 1024);
      profile.mcp.fixture.environment.FX_MCP_RESULT_TEXT = "SBXF2_TAIL";
      writeFileSync(profilePath, JSON.stringify(profile));
      return root;
    };

    // fx reads at most 16 MiB of one stdio message: past that it drops the
    // reply and restarts the server. Before, the model was told the server
    // went away, as if it had crashed.
    test("a stdio reply over fx's message limit tells the model fx restarted the server for it", async () => {
      const root = createRoot("oversized-reply", MODERN_FIXTURE);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      profile.mcp.fixture.environment.FX_MCP_RESULT_PAD_BYTES = String(17 * 1024 * 1024);
      writeFileSync(profilePath, JSON.stringify(profile));
      let first = "";
      gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
        (body: string) => {
          first = toolResultText(body, "call_mcp");
          return fakeGatewayFinalText("OVERSIZED_REPLY_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Call the MCP tool."], {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 40_000,
      });
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain("OVERSIZED_REPLY_DONE");
      expect(first).toContain("its reply was larger than fx reads in one message, so fx restarted the server");
      expect(first).not.toContain("the server went away");
      const wire = readWire(root.wireLogPath);
      expect(wire.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
      await expectFixtureProcessesExited(wire);
    }, 60_000);

    test("fx ask keeps a big MCP result whole behind a handle, and read_tool_result reaches its end", async () => {
      const root = bigResultRoot("big-result-stored");
      let stored = "";
      let read = "";
      gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
        (body: string) => {
          stored = toolResultText(body, "call_mcp");
          const handle = /<tool_result_handle>([^<]+)<\/tool_result_handle>/.exec(stored)?.[1] ?? "missing";
          // The whole result is one line, so read its last bytes by range.
          const size = Number(/stored_bytes="(\d+)"/.exec(stored)?.[1] ?? 0);
          return fakeGatewayToolCall("read_tail", "read_tool_result", { request: { handle, start_byte: Math.max(size - 255, 1), byte_count: 256 } });
        },
        (body: string) => {
          read = toolResultText(body, "read_tail");
          return fakeGatewayFinalText("BIG_RESULT_READ");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const result = await runFx(["ask", "--json", "--auto", "Read the big result."], {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 30_000,
      });
      expect(result.code).toBe(0);
      expect(stored).not.toContain("InvalidContent");
      expect(stored).toContain("<tool_result_handle>");
      expect(Number(/stored_bytes="(\d+)"/.exec(stored)?.[1] ?? 0)).toBeGreaterThan(1536 * 1024);
      expect(read).toContain("SBXF2_TAIL:hello");
    }, 45_000);

    test("fx ask --no-save cuts a big MCP result to the model's limit instead of failing it", async () => {
      const root = bigResultRoot("big-result-unsaved");
      let cut = "";
      gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
        (body: string) => {
          cut = toolResultText(body, "call_mcp");
          return fakeGatewayFinalText("BIG_RESULT_CUT");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Read the big result."], {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 30_000,
      });
      expect(result.code).toBe(0);
      expect(cut).not.toContain("InvalidContent");
      expect(cut).not.toContain("<tool_result_handle>");
      expect(cut).toContain("[mcp tool result truncated for fixture/");
      expect(cut.length).toBeLessThanOrEqual(64 * 1024);
    }, 45_000);
  });

  test(
    "top-level mcp list reports a missing workspace variable without exposing config values",
    async () => {
      const root = createRoot("workspace-missing-environment", MODERN_FIXTURE);
      moveProfileFixtureToWorkspace(root);
      const projectPath = join(root.workspace, ".mcp.json");
      const project = JSON.parse(readFileSync(projectPath, "utf8"));
      project.mcpServers.fixture.command = "secret-prefix-${MISSING_WORKSPACE_COMMAND}";
      writeFileSync(projectPath, JSON.stringify(project));
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = fixtureEnv(root, gateway);
      const trusted = await runFx(
        ["mcp", "approve", "fixture"],
        { cwd: root.workspace, env },
      );
      expect(trusted.code).toBe(0);

      const listed = await runFx(["mcp", "list"], {
        cwd: root.workspace,
        env,
      });
      expect(listed.code).toBe(0);
      // A config problem is a note, said once, naming the variable but no value.
      expect(listed.stderr).toBe(
        "note: .mcp.json server 'fixture' field command requires environment variable 'MISSING_WORKSPACE_COMMAND'; set it or use ${MISSING_WORKSPACE_COMMAND:-default}.\n",
      );
      expect(`${listed.stdout}${listed.stderr}`).not.toContain("secret-prefix");
      expect(`${listed.stdout}${listed.stderr}`).not.toContain(MODERN_FIXTURE);
      expect(existsSync(root.wireLogPath)).toBe(false);
    },
    30_000,
  );

  test.skipIf(process.platform === "win32" || !tmuxAvailable())(
    "MCP menu keeps a workspace configuration error visible beside a valid server",
    async () => {
      const root = createRoot("workspace-menu-configuration-error", MODERN_FIXTURE);
      moveProfileFixtureToWorkspace(root);
      const projectPath = join(root.workspace, ".mcp.json");
      const project = JSON.parse(readFileSync(projectPath, "utf8"));
      project.mcpServers.fixture.command = "secret-prefix-${MISSING_WORKSPACE_COMMAND}";
      writeFileSync(projectPath, JSON.stringify(project));
      writeFileSync(
        join(root.home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            canary: {
              type: "local",
              command: [process.execPath, MODERN_FIXTURE],
              enabled: false,
            },
          },
        }),
      );
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const env = fixtureEnv(root, gateway);
      const trusted = await runFx(
        ["mcp", "approve", "fixture"],
        { cwd: root.workspace, env },
      );
      expect(trusted.code, trusted.stderr).toBe(0);
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 180,
        height: 36,
        env,
      });

      await tui.waitForComposer(15_000);
      // The menu lists the valid server and points at the note; /mcp list
      // says it, naming the variable but no value.
      await tui.sendText("/mcp");
      const menu = await tui.waitForText("1 config note: /mcp list shows it", 10_000);
      expect(menu).toMatch(/canary +disabled +profile/);
      expect(menu).not.toContain("secret-prefix");
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("MCP servers"), 5_000);
      await tui.sendText("/mcp list");
      const listed = await tui.waitForText("MISSING_WORKSPACE_COMMAND", 10_000);
      expect(listed).toContain("field command");
      expect(listed).not.toContain("secret-prefix");
      expect(listed).not.toContain(MODERN_FIXTURE);
      expect(existsSync(root.wireLogPath)).toBe(false);
    },
    30_000,
  );

  test("top-level mcp add persists stdio and a later ask calls it", async () => {
    const root = createRoot("top-level-add", MODERN_FIXTURE);
    writeFileSync(
      join(root.home, ".fx", "mcp.json"),
      JSON.stringify({ mcp: {} }),
    );
    gateway = startToolGateway("TOP_LEVEL_STDIO_MCP_READY");
    const env = {
      ...fixtureEnv(root, gateway),
      FX_MCP_WIRE_LOG: root.wireLogPath,
      FX_MCP_PID_PATH: join(root.root, "mcp.pid"),
      FX_MCP_MODE: "normal",
    };
    // A stdio server gets only the default variables and its own, so the
    // fixture's settings go in with --env.
    const added = await runFx(
      [
        "mcp", "add",
        "--env", `FX_MCP_WIRE_LOG=${env.FX_MCP_WIRE_LOG}`,
        "--env", `FX_MCP_PID_PATH=${env.FX_MCP_PID_PATH}`,
        "--env", `FX_MCP_MODE=${env.FX_MCP_MODE}`,
        "fixture", "--", process.execPath, MODERN_FIXTURE,
      ],
      { cwd: root.workspace, env },
    );
    expect(added.code).toBe(0);
    expect(added.stdout).toContain("Added fixture to ~/.fx/mcp.json.");
    expect(existsSync(root.wireLogPath)).toBe(false);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the stdio MCP echo tool."],
      { cwd: root.workspace, env, timeoutMs: 20_000 },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("TOP_LEVEL_STDIO_MCP_READY");
    expect(readWire(root.wireLogPath).filter((entry) =>
      entry.message.method === "tools/call"
    )).toHaveLength(1);
    await expectFixtureProcessesExited(readWire(root.wireLogPath));
  }, 25_000);

  for (const matchingPath of [false, true]) {
    test.skipIf(process.platform === "win32" || !tmuxAvailable())(
      `MCP slash add preserves scoped arguments with ${matchingPath ? "a matching" : "no matching"} local path`,
      async () => {
        const root = createRoot(`scoped-add-${matchingPath}`, LEGACY_FIXTURE);
        const configPath = join(root.home, ".fx", "mcp.json");
        writeFileSync(configPath, JSON.stringify({ mcp: {} }));
        const packageArg = "@modelcontextprotocol/server-memory@2026.8.31";
        if (matchingPath) {
          const directory = join(root.workspace, "modelcontextprotocol");
          mkdirSync(directory);
          writeFileSync(join(directory, "server-memory@2026.8.31-extra"), "local file");
        }
        gateway = startFakeGateway([], {
          models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
        });
        tui = await TmuxSession.create({
          isolated: true,
          remainOnExit: true,
          cwd: root.workspace,
          width: 180,
          height: 36,
          env: {
            ...fixtureEnv(root, gateway),
            FX_MCP_LEGACY_VERSION: "2025-11-25",
            FX_MCP_WIRE_LOG: root.wireLogPath,
            FX_MCP_PID_PATH: join(root.root, "literal.pid"),
          },
        });
        await tui.waitForComposer(15_000);
        // The server gets only the default variables and its own, so the
        // fixture's settings go in with --env.
        const envFlags = [
          `--env FX_MCP_WIRE_LOG=${root.wireLogPath}`,
          `--env FX_MCP_PID_PATH=${join(root.root, "literal.pid")}`,
          "--env FX_MCP_LEGACY_VERSION=2025-11-25",
        ].join(" ");
        await tui.sendLiteral(`/mcp add ${envFlags} literal -- ${process.execPath} ${LEGACY_FIXTURE} ${packageArg}`);
        if (matchingPath) await tui.sendKeys("Tab");
        await tui.sendKeys("Enter");
        await tui.waitForText("Added literal to ~/.fx/mcp.json.", 5_000);
        // Saved as .mcp.json writes it: the program, then its arguments as typed.
        const saved = JSON.parse(readFileSync(configPath, "utf8")).mcp.literal;
        expect({ command: saved.command, args: saved.args })
          .toEqual({ command: process.execPath, args: [LEGACY_FIXTURE, packageArg] });
        expect(await tui.captureFullScrollback()).not.toContain("no matching files");
        await tui.sendText("/mcp");
        await tui.waitForText(/literal +ready, 1 tool +profile/, 15_000);
        expect(gateway.requests).toHaveLength(0);
        await tui.sendKeys("Escape");
        await tui.waitForPane((pane) => !pane.includes("MCP servers"), 5_000);
        await tui.sendText("/exit");
        await waitForTtyAskExit(tui, 0);
        await expectFixtureProcessesExited(readWire(root.wireLogPath));
      },
      30_000,
    );
  }

  // A server name with control characters never loads, so it can't reach a
  // terminal or a trace raw.
  test("a project server whose name has control characters is skipped, and every message escapes the name", async () => {
    const root = createRoot("workspace-hostile-name", MODERN_FIXTURE);
    moveProfileFixtureToWorkspace(root);
    const hostileName = "bad\n\x1b]0;owned\x07";
    const projectPath = join(root.workspace, ".mcp.json");
    const project = JSON.parse(readFileSync(projectPath, "utf8"));
    project.mcpServers[hostileName] = project.mcpServers.fixture;
    delete project.mcpServers.fixture;
    writeFileSync(projectPath, JSON.stringify(project));
    gateway = startFakeGateway([fakeGatewayFinalText("HOSTILE_NAME_SKIPPED")], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    const env = fixtureEnv(root, gateway);
    const approved = await runFx(["mcp", "approve", hostileName], { cwd: root.workspace, env });
    expect(approved.code).toBe(1);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Exercise the project MCP."],
      { cwd: root.workspace, env, timeoutMs: 25_000 },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("HOSTILE_NAME_SKIPPED");
    expect(result.stderr).toContain("server 'bad\\x0a\\x1b]0;owned\\x07' was skipped");
    const texts = [approved.stdout, approved.stderr, result.stderr];
    if (existsSync(root.traceLogPath)) texts.push(readFileSync(root.traceLogPath, "utf8"));
    for (const text of texts) {
      expect(text).not.toContain("\x1b");
      expect([...Buffer.from(text)].every((byte) => byte === 0x0a || (byte >= 0x20 && byte <= 0x7e))).toBe(true);
    }
    expect(existsSync(root.wireLogPath)).toBe(false);
  }, 30_000);

  test("fx ask skips workspace MCP when profile choices are unreadable", async () => {
    const root = createRoot("workspace-choice-failure", MODERN_FIXTURE, {
      recordLaunchAttempts: true,
    });
    moveProfileFixtureToWorkspace(root);
    writeFileSync(
      join(root.home, ".fx", "settings.json"),
      JSON.stringify({
        workspaces: {
          [root.workspace]: { disabledMcpjsonServers: "fixture" },
        },
      }),
    );
    gateway = startFakeGateway([fakeGatewayFinalText("CHOICES_FAILED_CLOSED")], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Confirm the workspace is available."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("CHOICES_FAILED_CLOSED");
    expect(existsSync(root.launchLogPath)).toBe(false);
    expect(result.stderr).not.toContain("skipped unapproved project MCP servers");
  }, 25_000);

  // A project server stays inert until it's approved, in the shell too, and
  // stops when it's rejected.
  test.skipIf(process.platform === "win32" || !tmuxAvailable())(
    "a project server stays inert until approved in the shell, and stops after it's rejected",
    async () => {
      const root = createRoot("workspace-interactive", MODERN_FIXTURE, {
        recordLaunchAttempts: true,
        expectedElicitation: "both",
      });
      moveProfileFixtureToWorkspace(root);
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 36,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.waitForText("fixture is waiting for approval · /mcp", 10_000);
      expect(existsSync(root.launchLogPath)).toBe(false);

      await tui.sendText("/mcp approve fixture");
      await tui.waitForText("Approved fixture", 10_000);
      await tui.sendText("/mcp");
      await tui.waitForText(/fixture +ready, 1 tool/, 15_000);
      expect(readAttemptedPids(root.launchLogPath).length).toBeGreaterThanOrEqual(1);
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("MCP servers"), 5_000);

      await tui.sendText("/mcp reject fixture");
      await tui.waitForText("Rejected fixture", 10_000);
      expect(gateway.requests).toHaveLength(0);

      await tui.kill();
      tui = null;
      await expectProcessesExited(readAttemptedPids(root.launchLogPath));
    },
    50_000,
  );

  test("fresh and resumed native sessions reconstruct MCP from the current profile", async () => {
    const root = createRoot("resume-current-profile", MODERN_FIXTURE);
    const initialGateway = startFakeGateway([
      fakeGatewayToolCall("fresh_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("fresh_call", TOOL_NAME, { text: "fresh" }),
      fakeGatewayFinalText("FRESH_PROFILE_MCP_READY"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = initialGateway;
    const initial = await runFx(
      ["ask", "--json", "--auto", "Use the fresh profile MCP."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, initialGateway),
        timeoutMs: 20_000,
      },
    );
    expect(initial.code).toBe(0);
    const sessionId = JSON.parse(initial.stdout).session_id;
    expect(sessionId).toBeTruthy();
    initialGateway.stop();
    gateway = null;

    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    profile.mcp.fixture.environment.FX_MCP_INITIAL_TOOL_NAME = "sum";
    profile.mcp.fixture.environment.FX_MCP_RESULT_TEXT = "RESUMED_PROFILE_TOOL_RESULT";
    writeFileSync(profilePath, JSON.stringify(profile));

    const resumedTool = "mcp_fixture_sum";
    const resumedGateway = startFakeGateway([
      fakeGatewayToolCall("resume_select", "mcp_select_tool", { name: resumedTool }),
      fakeGatewayToolCall("resume_call", resumedTool, { text: "resumed" }),
      fakeGatewayFinalText("RESUMED_PROFILE_MCP_READY"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = resumedGateway;
    const resumed = await runFx(
      ["ask", "--json", "--auto", "--resume", sessionId, "Use the current profile MCP."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, resumedGateway),
        timeoutMs: 20_000,
      },
    );
    expect(resumed.code).toBe(0);
    expect(JSON.parse(resumed.stdout)).toMatchObject({
      session_id: sessionId,
      output: expect.stringContaining("RESUMED_PROFILE_MCP_READY"),
    });
    const wire = readWire(root.wireLogPath);
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(calls).toHaveLength(2);
    expect(calls[0]?.message.params?.name).toBe("echo");
    expect(calls[1]?.message.params?.name).toBe("sum");
    expect(new Set(wire.map((entry) => entry.pid)).size).toBe(2);
    await expectFixtureProcessesExited(wire);
  }, 45_000);

  test.skipIf(!tmuxAvailable())(
    "the TUI runs a later turn's direct call to an MCP tool an earlier turn loaded",
    async () => {
      // The shell can ask, so it says so in every request's capabilities.
      const root = createRoot("tui-later-turn-direct-call", MODERN_FIXTURE, {
        expectedElicitation: "both",
      });
      const stderrPath = join(root.root, "stderr.log");
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("first_call", TOOL_NAME, { text: "first" }),
        fakeGatewayFinalText("FIRST_TURN_DONE"),
        fakeGatewayToolCall("later_call", TOOL_NAME, { text: "later" }),
        fakeGatewayFinalText("LATER_TURN_DONE"),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 40,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Load the fixture echo tool and call it.");
      await tui.waitForText("FIRST_TURN_DONE", 20_000);
      await tui.waitForComposer(10_000);
      expect(toolResultText(activeGateway.requests[2]!.body, "first_call")).toContain(`${MODERN_RESULT}:first`);
      await tui.sendText("Call the echo tool again.");
      await tui.waitForText("LATER_TURN_DONE", 20_000);
      await tui.waitForComposer(10_000);

      expect(activeGateway.requests).toHaveLength(5);
      // The later turn starts without the tool: the model calls it directly.
      const laterTools = (JSON.parse(activeGateway.requests[3]!.body) as {
        tools?: Array<{ name: string }>;
      }).tools?.map((tool) => tool.name) ?? [];
      expect(laterTools).not.toContain(TOOL_NAME);
      const laterResult = toolResultText(activeGateway.requests[4]!.body, "later_call");
      expect(laterResult).toContain(`${MODERN_RESULT}:later`);
      expect(laterResult).not.toContain("not selected");
      const calls = readWire(root.wireLogPath).filter(
        (entry) => entry.message.method === "tools/call",
      );
      expect(calls.map((entry) => entry.message.params?.arguments)).toEqual([
        { text: "first" },
        { text: "later" },
      ]);

      // Each turn's tool group counts its MCP call as one, never as a command.
      const scrollback = await tui.captureFullScrollback();
      expect(scrollback).toContain("1 MCP call");
      expect(scrollback).not.toMatch(/\b\d+ commands?\b/);
      expect(scrollback).not.toContain("not selected");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    60_000,
  );

  test("a resumed fx ask runs a direct call to an MCP tool an earlier turn loaded", async () => {
    const root = createRoot("ask-later-turn-direct-call", MODERN_FIXTURE);
    const firstGateway = startToolGateway("FIRST_ASK_DONE");
    gateway = firstGateway;
    const first = await runFx(
      ["ask", "--json", "--auto", "Load the fixture echo tool and call it."],
      { cwd: root.workspace, env: fixtureEnv(root, firstGateway), timeoutMs: 20_000 },
    );
    expect(first.code).toBe(0);
    const sessionId = JSON.parse(first.stdout).session_id;
    expect(sessionId).toBeTruthy();
    firstGateway.stop();
    gateway = null;

    const missingTool = "mcp_fixture_missing";
    const laterGateway = startFakeGateway([
      fakeGatewayToolCall("missing_call", missingTool, { text: "nothing" }),
      fakeGatewayToolCall("later_call", TOOL_NAME, { text: "later" }),
      fakeGatewayFinalText("LATER_ASK_DONE"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = laterGateway;
    const later = await runFx(
      ["ask", "--json", "--auto", "--resume", sessionId, "Call the echo tool again."],
      { cwd: root.workspace, env: fixtureEnv(root, laterGateway), timeoutMs: 20_000 },
    );
    expect(later.code).toBe(0);
    expect(JSON.parse(later.stdout)).toMatchObject({
      session_id: sessionId,
      output: expect.stringContaining("LATER_ASK_DONE"),
    });
    expect(laterGateway.requests).toHaveLength(3);
    // A name no live server has still fails without reaching any server.
    const missingResult = toolResultText(laterGateway.requests[1]!.body, "missing_call");
    expect(missingResult).toMatch(/not selected for this model step|Unsupported tool/);
    expect(missingResult).toContain(missingTool);
    expect(missingResult).not.toContain(MODERN_RESULT);
    const laterResult = toolResultText(laterGateway.requests[2]!.body, "later_call");
    expect(laterResult).toContain(`${MODERN_RESULT}:later`);
    expect(laterResult).not.toContain("not selected");
    const wire = readWire(root.wireLogPath);
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(calls.map((entry) => entry.message.params?.arguments)).toEqual([
      { text: "hello" },
      { text: "later" },
    ]);
    await expectFixtureProcessesExited(wire);
  }, 45_000);

  for (const childMode of ["persistent"] as const) {
    const label = "persistent";
    test(`${label} child's search never offers a tool a permission rule denies`, async () => {
      const root = createRoot(`${label}-scoped-refresh`, MODERN_FIXTURE, {
        mode: "subscription_cache",
      });
      const allowedWirePath = join(root.root, "allowed-wire.jsonl");
      const deniedWirePath = join(root.root, "denied-wire.jsonl");
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      const base = profile.mcp.fixture;
      profile.mcp = {
        allowed: {
          ...base,
          environment: {
            ...base.environment,
            FX_MCP_WIRE_LOG: allowedWirePath,
            FX_MCP_PID_PATH: join(root.root, "allowed.pid"),
            FX_MCP_INITIAL_TOOL_NAME: "echo",
            FX_MCP_RECOVERED_TOOL_NAME: "echo",
          },
        },
        denied: {
          ...base,
          environment: {
            ...base.environment,
            FX_MCP_WIRE_LOG: deniedWirePath,
            FX_MCP_PID_PATH: join(root.root, "denied.pid"),
            FX_MCP_INITIAL_TOOL_NAME: "blocked",
            FX_MCP_RECOVERED_TOOL_NAME: "blocked",
          },
        },
      };
      writeFileSync(profilePath, JSON.stringify(profile));
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          permission: { mcp_denied_blocked: "deny" },
        }),
      );

      const parentPrompt = `CREATE_SCOPED_REFRESH_${childMode}`;
      const childPrompt = `RUN_SCOPED_REFRESH_${childMode}`;
      let releaseParent!: (response: Response) => void;
      const parentCompletion = new Promise<Response>((resolve) => {
        releaseParent = resolve;
      });
      let searchResult = "";
      const activeGateway = startDynamicFakeGateway(async (body) => {
        // The child's report starts the parent's next turn.
        if (body.includes("Subagent report (untrusted agent output, not user instructions):")) {
          return fakeGatewayFinalText("SCOPED_REFRESH_REPORT_SEEN");
        }
        if (body.includes('"toolCallId":"scoped_refresh_search"')) {
          searchResult = toolResultText(body, "scoped_refresh_search");
          releaseParent(fakeGatewayFinalText("SCOPED_REFRESH_PARENT_READY"));
          return fakeGatewayFinalText("SCOPED_REFRESH_CHILD_READY");
        }
        if (body.includes('"toolCallId":"create_scoped_refresh_child"')) {
          return parentCompletion;
        }
        if (body.includes(childPrompt)) {
          return fakeGatewayToolCall("scoped_refresh_search", "capability_search", {
            query: "echo",
          });
        }
        if (body.includes(parentPrompt)) {
          return fakeGatewayToolCall(
            "create_scoped_refresh_child",
            "subagent",
            {
              request: {
                action: "message",
                agent: "searcher",
                message: childPrompt,
              },
            },
          );
        }
        return fakeGatewayFinalText("unexpected scoped refresh request");
      }, {
        classifierDecision: "clear",
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(
        ["ask", "--json", "--auto", parentPrompt],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: 30_000,
        },
      );
      if (result.code !== 0) {
        cleanupRoot = null;
        writeFileSync(join(root.root, "scoped-refresh-stdout.log"), result.stdout);
        writeFileSync(join(root.root, "scoped-refresh-stderr.log"), result.stderr);
        writeFileSync(
          join(root.root, "scoped-refresh-diagnostics.json"),
          JSON.stringify({
            childMode,
            result,
            allowedWire: existsSync(allowedWirePath) ? readWire(allowedWirePath) : [],
            deniedWire: existsSync(deniedWirePath) ? readWire(deniedWirePath) : [],
            gatewayRequests: activeGateway.requests.map((request) => request.body),
          }, null, 2),
        );
        throw new Error(`scoped refresh failed; retained artifacts: ${root.root}`);
      }
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain("SCOPED_REFRESH_PARENT_READY");
      expect(JSON.parse(result.stdout).output).toContain("SCOPED_REFRESH_REPORT_SEEN");

      expect(searchResult).toContain("mcp_allowed_echo");
      expect(searchResult).not.toContain("mcp_denied_blocked");
      const allowedWire = existsSync(allowedWirePath) ? readWire(allowedWirePath) : [];
      const deniedWire = existsSync(deniedWirePath) ? readWire(deniedWirePath) : [];
      expect(deniedWire.filter((entry) => entry.message.method === "tools/call")).toHaveLength(0);
      await expectFixtureProcessesExited([...allowedWire, ...deniedWire]);
    }, 40_000);
  }

  test("live stdio subscription coalesces duplicate changes and refreshes without reconnect", async () => {
    const root = createRoot("subscription-cache", MODERN_FIXTURE, {
      mode: "subscription_cache",
      recoveredToolName: "fresh",
    });
    const freshTool = "mcp_fixture_fresh";
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_initial", "capability_search", {
        query: "echo",
      }),
      async () => {
        await Bun.sleep(200);
        return fakeGatewayToolCall("search_fresh", "capability_search", {
          query: "fresh",
        });
      },
      fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
        name: freshTool,
      }),
      fakeGatewayToolCall("call_fresh", freshTool, { text: "stdio" }),
      fakeGatewayFinalText("Live stdio cache refresh complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the live stdio MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Live stdio cache refresh complete.",
    );
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "tools/list"))
      .toHaveLength(2);
    // One listen; closing stdin at the end ends it with the server.
    expect(wire.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    )).toHaveLength(1);
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.message.params?.name).toBe("fresh");
    expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
      .toBe(true);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("legacy stdio consumes an unscoped Tools list change without modern subscription methods", async () => {
    const root = createRoot("legacy-list-changed", LEGACY_FIXTURE, {
      mode: "list_changed",
    });
    const freshTool = "mcp_fixture_fresh";
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_initial", "capability_search", {
        query: "echo",
      }),
      async () => {
        writeFileSync(root.invalidationReleasePath, "ready");
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_fresh", "capability_search", {
          query: "fresh",
        });
      },
      fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
        name: freshTool,
      }),
      fakeGatewayToolCall("call_fresh", freshTool, { text: "legacy-stdio" }),
      fakeGatewayFinalText("Legacy stdio live refresh complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the changed legacy stdio tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const wire = readWire(root.wireLogPath);
    const legacyConnection = wire.filter((entry) =>
      entry.message.method !== "server/discover"
    );
    expect(new Set(legacyConnection.map((entry) => entry.pid)).size).toBe(1);
    expect(wire.filter((entry) => entry.message.method === "server/discover"))
      .toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "initialize"))
      .toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "tools/list"))
      .toHaveLength(2);
    expect(wire.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    )).toHaveLength(0);
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.message.params?.name).toBe("fresh");
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  // A server that never answers server/discover gets initialize once the
  // 10 s discovery probe ends.
  test("silent legacy discovery preserves time for initialization", async () => {
    const root = createRoot("silent-discovery", LEGACY_FIXTURE);
    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    profile.mcp.fixture.environment.FX_MCP_IGNORE_DISCOVERY = "1";
    writeFileSync(profilePath, JSON.stringify(profile));
    gateway = startToolGateway("Silent discovery fallback worked.");
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Use the legacy tool"], {
      cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 20_000,
    });
    expect(result.code, result.stderr || result.stdout).toBe(0);
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "server/discover")).toHaveLength(1);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("method-not-found discovery negotiates the latest supported legacy stdio version", async () => {
    const root = createRoot("legacy-method-not-found-latest", LEGACY_FIXTURE, {
      legacyVersion: "2025-11-25",
      legacyDiscoveryMethodNotFound: true,
    });
    gateway = startToolGateway("Latest legacy stdio negotiation complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the legacy stdio MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Latest legacy stdio negotiation complete.",
    );
    const wire = readWire(root.wireLogPath);
    const discover = wire.filter((entry) => entry.message.method === "server/discover");
    const initialize = wire.filter((entry) => entry.message.method === "initialize");
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(discover).toHaveLength(1);
    expect(initialize).toHaveLength(1);
    expect(initialize[0]?.message.params?.protocolVersion).toBe("2025-11-25");
    // initialize runs in the process that answered discovery.
    expect(initialize[0]?.pid).toBe(discover[0]?.pid);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.pid).toBe(initialize[0]?.pid);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("invalid-params discovery falls back through initialize and tools call", async () => {
    const root = createRoot("legacy-invalid-params", LEGACY_FIXTURE, {
      legacyVersion: "2025-11-25",
      legacyDiscoveryInvalidParams: true,
    });
    gateway = startToolGateway("Invalid params fallback complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the legacy stdio MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Invalid params fallback complete.",
    );
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "server/discover"))
      .toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "initialize"))
      .toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "tools/list"))
      .toHaveLength(1);
    expect(wire.filter((entry) => entry.message.method === "tools/call"))
      .toHaveLength(1);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  for (const supportsImages of [true, false]) {
    test(`MCP image results ${supportsImages ? "reach the model as images" : "remain explicit for a text-only model"}`, async () => {
      const root = createRoot("image-output", MODERN_FIXTURE, { mode: "image_result" });
      gateway = startFakeGateway([
        fakeGatewayToolCall("image_select", "mcp_select_tool", { name: TOOL_NAME }),
        fakeGatewayToolCall("image_call", TOOL_NAME, { text: "screenshot" }),
        fakeGatewayFinalText("Image result observed."),
      ], { models: [{ id: MODEL, type: "language", tags: supportsImages ? ["tool-use", "vision", "file-input"] : ["tool-use"] }] });
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Get an image from the fixture"], {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      });
      expect(result.code).toBe(0);
      const request = JSON.parse(gateway.requests.at(-1)!.body);
      const part = request.prompt.flatMap((message: { content?: unknown[] }) => message.content ?? [])
        .find((value: { type?: string; toolCallId?: string }) => value.type === "tool-result" && value.toolCallId === "image_call");
      expect(part).toBeDefined();
      if (supportsImages) {
        expect(part.output.type).toBe("content");
        expect(part.output.value.every((value: { type: string }) => value.type === "text")).toBe(true);
        expect(part.output.value.find((value: { type: string }) => value.type === "text").text).not.toContain("iVBORw0KGgo");
        const imageMessage = request.prompt.find((message: { role?: string; content?: unknown[] }) =>
          message.role === "user" && Array.isArray(message.content) &&
          (message.content as Array<{ type?: string }>).some((entry) => entry.type === "file"));
        expect(imageMessage).toBeDefined();
        const filePart = (imageMessage.content as Array<Record<string, unknown>>).find((entry) => entry.type === "file")!;
        expect(filePart.mediaType).toBe("image/png");
        expect((filePart.data as Record<string, unknown>).type).toBe("data");
        expect(typeof (filePart.data as Record<string, unknown>).data).toBe("string");
      } else {
        expect(part.output.type).toBe("text");
        expect(part.output.value).toContain("not sent: this model receives image input through the vision tool");
        expect(part.output.value).not.toContain("iVBORw0KGgo");
      }
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    }, 30_000);
  }

  test("MCP images within request limits reach the model unchanged without a downscale notice", async () => {
    const original = solidPng(3420, 2224);
    const root = createRoot("wide-image-output", MODERN_FIXTURE, { mode: "image_result", image: original });
    gateway = startFakeGateway([
      fakeGatewayToolCall("image_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("image_call", TOOL_NAME, { text: "screenshot" }),
      fakeGatewayFinalText("Wide image result observed."),
    ], { models: [{ id: MODEL, type: "language", tags: ["tool-use", "vision", "file-input"] }] });
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "Get an image from the fixture"], {
      cwd: root.workspace,
      env: fixtureEnv(root, gateway),
      timeoutMs: 20_000,
    });
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Wide image result observed.");
    const request = JSON.parse(gateway.requests.at(-1)!.body);
    const part = request.prompt.flatMap((message: { content?: unknown[] }) => message.content ?? [])
      .find((value: { type?: string; toolCallId?: string }) => value.type === "tool-result" && value.toolCallId === "image_call");
    expect(part).toBeDefined();
    expect(part.output.type).toBe("content");
    expect(part.output.value.filter((value: { type: string }) => value.type === "text")
      .map((value: { text: string }) => value.text).join("\n")).not.toContain("[Image downscaled");
    const files = request.prompt
      .filter((message: { role?: string; content?: unknown }) => message.role === "user" && Array.isArray(message.content))
      .flatMap((message: { content: Array<Record<string, unknown>> }) => message.content)
      .filter((entry: Record<string, unknown>) => entry.type === "file");
    expect(files).toHaveLength(1);
    expect(files[0].mediaType).toBe("image/png");
    const sent = Buffer.from((files[0].data as { data: string }).data, "base64");
    expect(sent.equals(original)).toBe(true);
    expect(pngPixelSize(sent)).toEqual({ width: 3420, height: 2224 });
    await expectFixtureProcessesExited(readWire(root.wireLogPath));
  }, 30_000);

  test("saved MCP images survive resume without repeating the tool", async () => {
    const root = createRoot("saved-image", MODERN_FIXTURE, { mode: "image_result" });
    const models = [{ id: MODEL, type: "language", tags: ["tool-use", "vision", "file-input"] }];
    gateway = startFakeGateway([
      fakeGatewayToolCall("saved_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("saved_image", TOOL_NAME, { text: "screenshot" }),
      fakeGatewayFinalText("Screenshot saved."),
    ], { models });
    const first = await runFx(["ask", "--json", "--auto", "Get a screenshot"], {
      cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 20_000,
    });
    expect(first.code).toBe(0);
    const sessionId = JSON.parse(first.stdout).session_id;
    const imageHandle = gateway.requests.at(-1)!.body.match(/image-result-[\w-]+\.txt/)?.[0];
    expect(imageHandle).toBeDefined();
    gateway.stop();
    gateway = startFakeGateway([
      fakeGatewayToolCall("load_saved_image", "read_tool_result", { request: { handle: imageHandle } }),
      fakeGatewayFinalText("The saved screenshot is visible."),
    ], { models });
    const resumed = await runFx(["ask", "--json", "--auto", "--resume", sessionId, "Describe the earlier screenshot"], {
      cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 20_000,
    });
    expect(resumed.code).toBe(0);
    const request = JSON.parse(gateway.requests[0]!.body);
    const result = request.prompt.flatMap((message: { content?: unknown[] }) => message.content ?? [])
      .find((part: { type?: string; toolCallId?: string }) => part.type === "tool-result" && part.toolCallId === "saved_image");
    expect(result.output.type).toBe("content");
    const savedImageMessage = request.prompt.find((message: { role?: string; content?: unknown[] }) =>
      message.role === "user" && Array.isArray(message.content) &&
      (message.content as Array<{ type?: string }>).some((entry) => entry.type === "file"));
    expect(savedImageMessage).toBeDefined();
    const secondRequest = JSON.parse(gateway.requests[1]!.body);
    const loaded = secondRequest.prompt
      .flatMap((message: { content?: unknown[] }) => message.content ?? [])
      .find((part: { type?: string; toolCallId?: string }) => part.type === "tool-result" && part.toolCallId === "load_saved_image");
    expect(loaded.output.type).toBe("content");
    const loadedImageMessage = secondRequest.prompt.find((message: { role?: string; content?: unknown[] }) =>
      message.role === "user" && Array.isArray(message.content) &&
      (message.content as Array<{ type?: string }>).some((entry) => entry.type === "file"));
    expect(loadedImageMessage).toBeDefined();
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
    await expectFixtureProcessesExited(wire);
  }, 40_000);

  test("changed MCP arguments reach the server after earlier failures", async () => {
    const root = createRoot("bounded-equivalent-retries", MODERN_FIXTURE, {
      mode: "tool_failure",
    });
    gateway = startFakeGateway([
      fakeGatewayToolCall("retry_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("retry_call_1", TOOL_NAME, { text: "one" }),
      fakeGatewayToolCall("retry_call_2", TOOL_NAME, { text: "two" }),
      fakeGatewayToolCall("retry_call_3", TOOL_NAME, { text: "three" }),
      fakeGatewayFinalText("Bounded MCP retries complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the failing MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Bounded MCP retries complete.");
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "tools/call"))
      .toHaveLength(3);
    expect(gateway.requests.at(-1)?.body).not.toContain(
      "Repeated MCP tool call blocked: two equivalent attempts failed",
    );
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("successful discovery selects the latest legacy version from an oldest-first list", async () => {
    const root = createRoot("legacy-discovery-oldest-first", LEGACY_FIXTURE, {
      legacyVersion: "2025-11-25",
      legacyDiscoveryVersions: ["2024-11-05", "2025-06-18", "2025-11-25"],
    });
    gateway = startToolGateway("Ordered legacy stdio negotiation complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the legacy stdio MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const wire = readWire(root.wireLogPath);
    const discover = wire.filter((entry) => entry.message.method === "server/discover");
    const initialize = wire.filter((entry) => entry.message.method === "initialize");
    expect(discover).toHaveLength(1);
    expect(initialize).toHaveLength(1);
    expect(initialize[0]?.message.params?.protocolVersion).toBe("2025-11-25");
    // initialize runs in the process that answered discovery.
    expect(initialize[0]?.pid).toBe(discover[0]?.pid);
    expect(wire.filter((entry) => entry.message.method === "tools/call"))
      .toHaveLength(1);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  // A server that dies while starting is reported in its own words.
  test("fx mcp show reports how a stdio server that exits during startup ended", async () => {
    const root = createRoot("startup-exit", LEGACY_FIXTURE, {
      mode: "startup_exit",
      recordLaunchAttempts: true,
    });

    const result = await runFx(["mcp", "show", "fixture", "--json"], {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_TRACE_LOG: root.traceLogPath,
        FX_TRACE_SCOPES: "mcp",
      },
      timeoutMs: 20_000,
    });

    expect(result.code).toBe(1);
    const status = JSON.parse(result.stdout);
    expect(status.status).toBe("retrying");
    expect(status.error).toContain("exited with code 7");
    expect(status.error).toContain("npm error code E401");
    const launches = readAttemptedPids(root.launchLogPath);
    expect(launches).toHaveLength(1);
    await expectProcessesExited(launches);
  }, 30_000);

  // A start gets 30 s from launch, so a 2025 server that never answers
  // initialize fails then instead of after the 60 s request timeout. What it
  // wrote instead of an answer is quoted.
  test("fx mcp show ends the start of a 2025 stdio server that answers with a line that isn't JSON, and quotes it", async () => {
    const root = createRoot("startup-garbage", LEGACY_FIXTURE, {
      mode: "startup_garbage",
      recordLaunchAttempts: true,
    });

    const started = Date.now();
    const result = await runFx(["mcp", "show", "fixture", "--json"], {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_TRACE_LOG: root.traceLogPath,
        FX_TRACE_SCOPES: "mcp",
      },
      timeoutMs: 45_000,
    });

    expect(result.code).toBe(1);
    const elapsed = Date.now() - started;
    expect(elapsed).toBeGreaterThan(29_000);
    expect(elapsed).toBeLessThan(40_000);
    const status = JSON.parse(result.stdout);
    expect(status.error).toContain("not json");
    const launches = readAttemptedPids(root.launchLogPath);
    expect(launches).toHaveLength(1);
    await expectProcessesExited(launches);
  }, 60_000);

  // A banner on stdout is a common server mistake; it's quoted.
  test("fx mcp show quotes the stdout line a 2026 stdio server wrote instead of answering", async () => {
    const root = createRoot("modern-startup-garbage", MODERN_FIXTURE, {
      mode: "startup_garbage",
      recordLaunchAttempts: true,
    });

    const result = await runFx(["mcp", "show", "fixture", "--json"], {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_TRACE_LOG: root.traceLogPath,
        FX_TRACE_SCOPES: "mcp",
      },
      timeoutMs: 20_000,
    });

    expect(result.code).toBe(1);
    const status = JSON.parse(result.stdout);
    expect(status.error).toContain("Server started on stdio");
    const launches = readAttemptedPids(root.launchLogPath);
    expect(launches.length).toBeGreaterThanOrEqual(1);
    await expectProcessesExited(launches);
  }, 30_000);

  test("fx ask search tells the model why a named stdio server failed to start", async () => {
    const root = createRoot("ask-startup-exit", LEGACY_FIXTURE, {
      mode: "startup_exit",
      recordLaunchAttempts: true,
    });
    const activeGateway = startFakeGateway([
      fakeGatewayToolCall("search_failed", "capability_search", {
        kind: "mcp",
        server: "fixture",
        query: "fixture tools",
        limit: 5,
      }),
      fakeGatewayFinalText("STARTUP_FAILURE_REPORTED"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = activeGateway;

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Find the fixture tools."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("STARTUP_FAILURE_REPORTED");
    const searchResult = toolResultText(activeGateway.requests[1]?.body ?? "", "search_failed");
    expect(searchResult).toContain("MCP server 'fixture' is unavailable: ");
    // The server's own words: its exit code and last stderr lines.
    expect(searchResult).toContain("exited with code 7");
    expect(searchResult).toContain("npm error code E401");
    await expectProcessesExited(readAttemptedPids(root.launchLogPath));
  }, 30_000);

  test("fx ask tells the model why a stopped stdio server could not restart", async () => {
    const root = createRoot("ask-restart-failed", MODERN_FIXTURE, {
      mode: "exit_after_result",
      recordLaunchAttempts: true,
    });
    // The first launch runs the server; every relaunch fails during startup.
    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    profile.mcp.fixture.command = [
      "/bin/sh",
      "-c",
      `printf '%s\\n' "$$" >> "$FX_MCP_LAUNCH_LOG"
if [ "$(wc -l < "$FX_MCP_LAUNCH_LOG")" -gt 1 ]; then echo 'relaunch blocked by test' >&2; exit 5; fi
exec "$FX_MCP_FIXTURE_RUNTIME" "$FX_MCP_FIXTURE_PATH"`,
    ];
    writeFileSync(profilePath, JSON.stringify(profile));
    let sawFirstExit = true;
    const activeGateway = startFakeGateway([
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("first_call", TOOL_NAME, { text: "first" }),
      async () => {
        // Call again only after the first server has exited.
        const firstExited = () => {
          const [pid] = readAttemptedPids(root.launchLogPath);
          if (pid === undefined) return false;
          try {
            process.kill(Number(pid), 0);
            return false;
          } catch {
            return true;
          }
        };
        const deadline = Date.now() + 5_000;
        while (!firstExited()) {
          if (Date.now() >= deadline) {
            sawFirstExit = false;
            break;
          }
          await Bun.sleep(20);
        }
        return fakeGatewayToolCall("second_call", TOOL_NAME, { text: "second" });
      },
      fakeGatewayFinalText("RESTART_FAILURE_REPORTED"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = activeGateway;

    const started = Date.now();
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the fixture tool twice."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(sawFirstExit, "fx never saw the first server exit").toBe(true);
    expect(result.code).toBe(0);
    // The second call fails with the relaunch it waited for, not after
    // every try the backoff allows.
    expect(Date.now() - started).toBeLessThan(15_000);
    expect(JSON.parse(result.stdout).output).toContain("RESTART_FAILURE_REPORTED");
    expect(activeGateway.requests[2]?.body).toContain("MODERN_MCP_TOOL_RESULT:first");
    // The relaunch's own words reach the model: its exit code and stderr.
    const secondResult = toolResultText(activeGateway.requests[3]?.body ?? "", "second_call");
    expect(secondResult).toContain("exited with code 5");
    expect(secondResult).toContain("relaunch blocked by test");
    const launches = readAttemptedPids(root.launchLogPath);
    expect(launches.length).toBeGreaterThanOrEqual(2);
    await expectProcessesExited(launches);
  }, 30_000);

  for (
    const malformed of [
      { mode: "response_missing_jsonrpc", label: "missing jsonrpc" },
      { mode: "response_wrong_jsonrpc", label: "wrong jsonrpc" },
      { mode: "response_missing_payload", label: "missing result and error" },
      { mode: "response_ambiguous_payload", label: "result and error together" },
    ] as const
  ) {
    // A reply with a pending request's id that isn't valid JSON-RPC fails
    // that request at once, here the start's discover, not at its timeout.
    test(`malformed stdio response with ${malformed.label} fails deferred activation and reaps the child`, async () => {
      const root = createRoot(`malformed-${malformed.mode}`, MODERN_FIXTURE, {
        mode: malformed.mode,
      });
      gateway = startFakeGateway([
        fakeGatewayToolCall("search_malformed", "capability_search", {
          query: "fixture",
        }),
        fakeGatewayFinalText("Malformed stdio fixture isolated."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const started = Date.now();
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Exercise the malformed MCP fixture."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, gateway),
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(Date.now() - started).toBeLessThan(5_000);
      expect(gateway.requests[0]?.body).not.toContain(TOOL_NAME);
      const wire = readWire(root.wireLogPath);
      expect(wire.some((entry) => entry.message.method === "server/discover"))
        .toBe(true);
      await expectFixtureProcessesExited(wire);
    }, 30_000);
  }

  for (
    const fixture of [
      {
        label: "modern",
        path: MODERN_FIXTURE,
        result: MODERN_RESULT,
        expectedLaunches: 1,
        expectedMethods: ["server/discover", "subscriptions/listen", "tools/list", "tools/call"],
      },
      {
        label: "legacy",
        path: LEGACY_FIXTURE,
        result: LEGACY_RESULT,
        // Discovery and initialize share one process.
        expectedLaunches: 1,
        expectedMethods: [
          "server/discover",
          "initialize",
          "notifications/initialized",
          "tools/list",
          "tools/call",
        ],
      },
    ] as const
  ) {
    test(`fx ask calls the ${fixture.label} stdio fixture`, async () => {
      const root = createRoot(`ask-${fixture.label}`, fixture.path, {
        recordLaunchAttempts: true,
      });
      const activeGateway = startToolGateway(`${fixture.label} MCP complete.`);
      gateway = activeGateway;
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", `Call the ${fixture.label} MCP fixture.`],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain(`${fixture.label} MCP complete.`);
      expect(activeGateway.requests).toHaveLength(3);
      expect(activeGateway.requests[2]?.body).toContain(`${fixture.result}:hello`);
      expect(readAttemptedPids(root.launchLogPath)).toHaveLength(
        fixture.expectedLaunches,
      );

      const wire = readWire(root.wireLogPath);
      // A 2026 server's listen goes out beside the first tools/list, in
      // either order.
      const methods = wire.map((entry) => entry.message.method);
      expect([...methods].sort()).toEqual([...fixture.expectedMethods].sort());
      expect(methods[0]).toBe("server/discover");
      expect(methods.at(-1)).toBe("tools/call");
      if (fixture.label === "modern") {
        for (const entry of wire) {
          const meta = entry.message.params?._meta as Record<string, unknown>;
          expect(meta["io.modelcontextprotocol/protocolVersion"]).toBe("2026-07-28");
          expect(meta["io.modelcontextprotocol/clientCapabilities"]).toEqual({});
        }
      } else {
        expect(new Set(wire.map((entry) => entry.pid)).size).toBe(1);
        // initialize follows server/discover in the same process.
        const initialize = wire.find((entry) => entry.message.method === "initialize");
        expect(initialize?.sequence).toBe(2);
        // Each request carries its own progress token.
        const list = wire.find((entry) => entry.message.method === "tools/list");
        expect(list?.message.params?._meta).toEqual({
          progressToken: expect.any(Number),
        });
        const call = wire.find((entry) => entry.message.method === "tools/call");
        expect(call?.message.params?._meta).toEqual({
          progressToken: expect.any(Number),
        });
      }
      await expectFixtureProcessesExited(wire);
    });
  }

  // As the MCP SDKs do, fx gives a stdio server only HOME, LOGNAME, PATH,
  // SHELL, TERM and USER of its environment, then the server's own `env`;
  // never fx's Gateway key or anything else.
  test("a stdio server gets only the MCP SDKs' few variables of fx's, then its config's env", async () => {
    const root = createRoot("ask-environment-sdk", MODERN_FIXTURE, { captureEnvironment: true });
    const namesPath = join(root.root, "mcp-environment-names.json");
    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    profile.mcp.fixture.environment.FX_MCP_ENV_NAMES_CAPTURE = namesPath;
    writeFileSync(profilePath, JSON.stringify(profile));
    const configured = Object.keys(profile.mcp.fixture.environment);
    const activeGateway = startToolGateway("Environment kept small.");
    gateway = activeGateway;
    const parentPath = process.env.PATH ?? "/usr/bin:/bin";

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the environment MCP fixture."],
      {
        cwd: root.workspace,
        env: {
          ...fixtureEnv(root, activeGateway),
          PATH: parentPath,
          FX_MCP_INHERITED_SENTINEL: "inherited-parent-value",
          HTTPS_PROXY: "http://proxy.example.test:8080",
        },
        timeoutMs: 20_000,
      },
    );

    expect(result.code, result.stderr || result.stdout).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Environment kept small.");
    expect(JSON.parse(readFileSync(root.environmentCapturePath, "utf8"))).toEqual({
      configured: "configured",
      path: parentPath,
      home: root.home,
    });
    const names = JSON.parse(readFileSync(namesPath, "utf8")) as string[];
    const allowed = new Set(["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER", ...configured]);
    expect(names.filter((name) => !allowed.has(name))).toEqual([]);
    expect(names).not.toContain("AI_GATEWAY_API_KEY");
    await expectFixtureProcessesExited(readWire(root.wireLogPath));
  }, 30_000);

  for (const discovery of ["select", "search"] as const) {
    test(`targeted MCP ${discovery} leaves unrelated optional servers dormant`, async () => {
      const root = createRoot("targeted-activation", MODERN_FIXTURE);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      const unrelatedWire = join(root.root, "unrelated-wire.jsonl");
      profile.mcp.unrelated = { ...profile.mcp.fixture, environment: {
        ...profile.mcp.fixture.environment,
        FX_MCP_MODE: "stall_startup", FX_MCP_WIRE_LOG: unrelatedWire,
        FX_MCP_PID_PATH: join(root.root, "unrelated.pid"),
      } };
      writeFileSync(profilePath, JSON.stringify(profile));
      gateway = startFakeGateway([
        discovery === "select"
          ? fakeGatewayToolCall("target_select", "mcp_select_tool", { name: TOOL_NAME })
          : fakeGatewayToolCall("target_search", "capability_search", { server: "fixture", query: "echo" }),
        fakeGatewayToolCall("target_call", TOOL_NAME, { text: "hello" }),
        fakeGatewayFinalText("Targeted server works."),
      ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Use the fixture server"], {
        cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 20_000,
      });
      expect(result.code, result.stderr || result.stdout).toBe(0);
      expect(existsSync(unrelatedWire)).toBe(false);
      expect(readWire(root.wireLogPath).filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    }, 30_000);
  }

  test("fx ask does not start an unused optional MCP server", async () => {
    const root = createRoot("ask-unused-optional", MODERN_FIXTURE, {
      recordLaunchAttempts: true,
    });
    const activeGateway = startFakeGateway([
      fakeGatewayFinalText("No MCP operation needed."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = activeGateway;

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Answer without using MCP."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 10_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("No MCP operation needed.");
    expect(activeGateway.requests).toHaveLength(1);
    expect(readAttemptedPids(root.launchLogPath)).toHaveLength(0);
    expect(existsSync(root.wireLogPath)).toBe(false);
  }, 15_000);

  test("fx ask accepts the official legacy SDK Draft 7 tool schema", async () => {
    const root = createRoot("ask-legacy-draft7", LEGACY_FIXTURE, {
      mode: "draft7_schema",
    });
    const activeGateway = startToolGateway("Legacy Draft 7 complete.");
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the legacy Draft 7 MCP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Legacy Draft 7 complete.");
    expect(activeGateway.requests[2]?.body).toContain(`${LEGACY_RESULT}:hello`);
    const wire = readWire(root.wireLogPath);
    expect(wire.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
      "tools/call",
    ]);
    expect(wire.find((entry) => entry.message.method === "tools/call")?.message.params?.arguments)
      .toEqual({ text: "hello" });
    await expectFixtureProcessesExited(wire);
  });

  test("fx ask lets the legacy server validate Draft 7 arguments", async () => {
    const root = createRoot("ask-legacy-draft7-invalid", LEGACY_FIXTURE, {
      mode: "draft7_schema",
      draft7Pattern: "^\\S+$",
    });
    const activeGateway = startFakeGateway([
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "\u00A0" }),
      fakeGatewayFinalText("Legacy Draft 7 invalid complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Try invalid legacy Draft 7 arguments."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const resultPart = JSON.parse(activeGateway.requests[2]!.body).prompt
      .flatMap((message: { content?: unknown[] }) => message.content ?? [])
      .find((part: { type?: string; toolCallId?: string }) => part.type === "tool-result" && part.toolCallId === "call_mcp");
    expect(resultPart.output.type).toBe("error-text");
    expect(resultPart.output.value).toContain("text violates the server pattern");
    const wire = readWire(root.wireLogPath);
    expect(wire.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
    await expectFixtureProcessesExited(wire);
  });

  test("fx ask routes legacy stdio progress", async () => {
    const root = createRoot("ask-legacy-progress", LEGACY_FIXTURE, {
      mode: "progress",
    });
    const activeGateway = startToolGateway("Legacy progress complete.");
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the legacy MCP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(result.stderr).toContain("Legacy MCP fixture halfway");
    const wire = readWire(root.wireLogPath);
    const call = wire.find((entry) => entry.message.method === "tools/call");
    expect(call?.message.params?._meta).toEqual({
      progressToken: expect.any(Number),
    });
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("noninteractive fx ask returns typed input-required without fabricating a continuation", async () => {
    const root = createRoot("ask-mrtr", MODERN_FIXTURE, {
      mode: "mrtr_input_required",
    });
    const activeGateway = startToolGateway("MRTR Ask boundary complete.");
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the MRTR MCP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    // With no way to ask, the call ends and the model hears why; nothing is
    // made up and sent back to the server.
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("MRTR Ask boundary complete.");
    expect(activeGateway.requests).toHaveLength(3);
    expect(toolResultText(activeGateway.requests[2]?.body ?? "", "call_mcp")).toBe(
      "MCP server 'fixture' ended the call: the server asked for input fx can't give.",
    );
    expect(activeGateway.requests[1]?.body).not.toContain("inputResponses");
    const wire = readWire(root.wireLogPath);
    const calls = wire.filter(
      (entry) => entry.message.method === "tools/call",
    );
    expect(calls).toHaveLength(1);
    expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test("fx ask tells the model that a stdio call outlived its operation timeout", async () => {
    const root = createRoot("ask-operation-timeout", MODERN_FIXTURE, {
      mode: "stall_operation",
      operationTimeoutMs: 1_500,
    });
    const activeGateway = startToolGateway("Operation timeout complete.");
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the stalled MCP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    // fx stops waiting, cancels the call on the server, and tells the model
    // why and how to wait longer, rather than that the call was cancelled.
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Operation timeout complete.");
    expect(activeGateway.requests).toHaveLength(3);
    const toolResult = toolResultText(activeGateway.requests[2]?.body ?? "", "call_mcp");
    expect(toolResult).toStartWith("fx stopped waiting for MCP server 'fixture': it did not answer within its operation timeout.");
    expect(toolResult).toContain("Raise operation_timeout_ms for this server in its MCP config if it needs longer.");
    expect(toolResult).not.toContain("Cancelled");
    const wire = readWire(root.wireLogPath);
    const call = wire.filter((entry) => entry.message.method === "tools/call").at(-1);
    const cancelled = wire.find((entry) => entry.message.method === "notifications/cancelled");
    expect(cancelled?.message.params?.requestId).toBe(call?.message.id);
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "the TUI calls the modern stdio fixture through the shared runtime",
    async () => {
      const root = createRoot("tui-modern", MODERN_FIXTURE, {
        mode: "progress",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Modern MCP TUI complete.");
      gateway = activeGateway;
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the modern MCP fixture.");
      // The server's progress note shows on the working line.
      await tui.waitForText("MCP fixture halfway", 20_000);
      await tui.waitForText("Modern MCP TUI complete.", 20_000);

      const scrollback = await tui.captureFullScrollback();
      expect(scrollback).toContain(`Ran MCP ${TOOL_NAME}`);
      expect(activeGateway.requests).toHaveLength(3);
      expect(activeGateway.requests[2]?.body).toContain(`${MODERN_RESULT}:hello`);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const wire = readWire(root.wireLogPath);
      // The listen goes out beside the first tools/list, in either order.
      expect(wire.map((entry) => entry.message.method).sort()).toEqual([
        "server/discover",
        "subscriptions/listen",
        "tools/call",
        "tools/list",
      ]);
      const call = wire.find((entry) => entry.message.method === "tools/call");
      expect(call?.message.params?._meta).toMatchObject({
        progressToken: expect.any(Number),
      });

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "the TUI shows a safe MCP failure detail while preserving model context",
    async () => {
      const root = createRoot("tui-tool-failure", MODERN_FIXTURE, {
        mode: "tool_failure",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("MCP failure detail complete.");
      gateway = activeGateway;
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 120,
        height: 32,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the failing MCP fixture once.");
      await tui.waitForText(
        `Failed ${TOOL_NAME}: Invalid input: labels require at least one item retry rejected`,
        20_000,
      );
      await tui.waitForText("MCP failure detail complete.", 20_000);

      const scrollback = await tui.captureFullScrollback();
      expect(scrollback).not.toContain("\\x0a");
      expect(activeGateway.requests.at(-1)?.body).toContain(
        "Invalid input: labels require at least one item",
      );
      expect(activeGateway.requests.at(-1)?.body).toContain("item\\\\nretry rejected");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const wire = readWire(root.wireLogPath);
      expect(wire.filter((entry) => entry.message.method === "tools/call"))
        .toHaveLength(1);

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "the TUI validates and submits a modern MCP form elicitation",
    async () => {
      const root = createRoot("tui-mrtr", MODERN_FIXTURE, {
        mode: "mrtr_input_required",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("MRTR TUI boundary complete.");
      gateway = activeGateway;
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the MRTR MCP fixture.");
      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await tui.sendKeys("1");
      await tui.waitForText("Current values:", 20_000);
      await tui.sendKeys("1");
      await tui.waitForText("MRTR TUI boundary complete.", 20_000);

      expect(activeGateway.requests).toHaveLength(3);
      expect(activeGateway.requests[2]?.body).toContain(
        "continued after elicitation",
      );
      expect(activeGateway.requests[2]?.body).not.toContain("requestState");
      const wire = readWire(root.wireLogPath);
      const calls = wire.filter(
        (entry) => entry.message.method === "tools/call",
      );
      expect(calls).toHaveLength(2);
      expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: { action: "accept", content: { confirmed: true } },
      });
      expect(calls[1]?.message.params?.requestState).toBe("opaque");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    30_000,
  );

  for (const scenario of [
    { name: "input", field: { type: "string", maxLength: 80 }, input: "Decline", value: "Decline" },
    { name: "choice", field: { type: "string", oneOf: [
      { const: "manual", title: "Enter manually" },
      { const: "connect", title: "Connect an account" },
      { const: "other", title: "Something else" },
    ] }, input: "2", value: "connect" },
  ]) {
    test.skipIf(!tmuxAvailable())(
      `the TUI ${scenario.name === "input" ? "reviews a short MCP input" : "submits a compact MCP choice without a second confirmation"}`,
      async () => {
        const root = createRoot(`tui-compact-${scenario.name}`, MODERN_FIXTURE, {
          mode: "mrtr_input_required",
          expectedElicitation: "both",
          compactField: scenario.field,
        });
        const activeGateway = startToolGateway("Compact form accepted.");
        gateway = activeGateway;
        const stderrPath = join(root.root, "stderr.log");
        tui = await TmuxSession.create({
          isolated: true, cwd: root.workspace, width: 110, height: 34,
          stderrPath, env: fixtureEnv(root, activeGateway),
        });
        await tui.waitForComposer(15_000);
        await tui.sendText("Call the compact MCP fixture.");
        await tui.waitForText("MCP server fixture requests answer", 20_000);
        const form = await tui.capturePane();
        if (scenario.name === "choice") {
          expect(form).toContain("Decline");
          expect(form).toContain("Cancel");
        }
        expect(form).not.toContain("Current values:");
        if (scenario.name === "input") {
          await tui.sendText(scenario.input);
          await tui.waitForText("Current values:", 20_000);
          expect(readWire(root.wireLogPath).filter((entry) => entry.message.method === "tools/call"))
            .toHaveLength(1);
          await tui.sendKeys("1");
        } else await tui.sendKeys(scenario.input);
        await tui.waitForText("Compact form accepted.", 20_000);
        const wire = readWire(root.wireLogPath);
        const calls = wire.filter((entry) => entry.message.method === "tools/call");
        expect(calls).toHaveLength(2);
        expect(calls[1]?.message.params?.inputResponses).toEqual({
          confirm: { action: "accept", content: { answer: scenario.value } },
        });
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(wire);
      },
      35_000,
    );
  }

  for (const surface of ["TUI", "Ask"] as const) {
    test.skipIf(!tmuxAvailable())(
      `${surface} terminal-safes untrusted MCP elicitation display strings`,
      async () => {
        const root = createRoot(`${surface.toLowerCase()}-unsafe-mrtr`, MODERN_FIXTURE, {
          mode: "mrtr_unsafe_form",
          expectedElicitation: "both",
        });
        const activeGateway = startToolGateway(`${surface} terminal-safe elicitation complete.`);
        gateway = activeGateway;
        const stderrPath = join(root.root, "stderr.log");
        const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
        tui = await TmuxSession.create({
          isolated: true,
          ...(surface === "Ask"
            ? {
                cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the unsafe MCP elicitation fixture.")}`,
                remainOnExit: true,
              }
            : { stderrPath }),
          cwd: root.workspace,
          width: 120,
          height: 38,
          env: fixtureEnv(root, activeGateway),
        });

        if (surface === "TUI") {
          await tui.waitForComposer(15_000);
          await tui.sendText("Call the unsafe MCP elicitation fixture.");
        }
        await tui.waitForText("Field\\x1b]52;c;MCP_FIELD\\x07", 20_000);
        const fieldRendered = await tui.captureFullScrollback();
        const fieldEscaped = await tui.captureFullScrollbackEscapes();
        await tui.sendText("local-value");
        await tui.waitForText("Choice\\x1b]52;c;MCP_OPTION\\x07", 20_000);
        const choiceRendered = await tui.captureFullScrollback();
        const choiceEscaped = await tui.captureFullScrollbackEscapes();
        if (surface === "TUI") await tui.sendKeys("1");
        else await tui.sendText("1");
        await tui.waitForText("Current values:", 20_000);
        const rendered = `${fieldRendered}\n${choiceRendered}\n${await tui.captureFullScrollback()}`;
        const escaped = `${fieldEscaped}\n${choiceEscaped}\n${await tui.captureFullScrollbackEscapes()}`;
        expect(rendered).toContain("local-value");
        if (surface === "TUI") await tui.sendKeys("1");
        else await tui.sendText("1");
        await tui.waitForText(`${surface} terminal-safe elicitation complete.`, 20_000);

        expect(rendered).toContain("Line\\x0aInjected\\x1b]52;c;MCP_MESSAGE\\x07\\u{0085}");
        expect(rendered).toContain("Field\\x1b]52;c;MCP_FIELD\\x07");
        expect(rendered).toContain("Choice\\x1b]52;c;MCP_OPTION\\x07");
        expect(rendered).toContain("Description\\u{009b}2J");
        expect(escaped).not.toContain("\x1b]52;c;MCP_");
        expect(escaped).not.toContain("\xc2\x9b2J");
        expect(escaped).not.toContain("Line\nInjected");
        const calls = readWire(root.wireLogPath).filter((entry) =>
          entry.message.method === "tools/call"
        );
        expect(calls).toHaveLength(2);
        expect(calls[1]?.message.params?.inputResponses).toEqual({
          confirm: {
            action: "accept",
            content: { value: "local-value", choice: "exact" },
          },
        });
        expect(activeGateway.requests.map((entry) => entry.body).join("\n"))
          .not.toContain("local-value");
        expect(readFileSync(root.traceLogPath, "utf8")).not.toContain("local-value");
        if (surface === "TUI") expect(readFileSync(stderrPath, "utf8")).toBe("");

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(readWire(root.wireLogPath));
      },
      40_000,
    );
  }

  for (const surface of ["TUI", "Ask"] as const) {
    test.skipIf(!tmuxAvailable())(
      `${surface} preserves exact form values across local label collisions`,
      async () => {
        const root = createRoot(`${surface.toLowerCase()}-collision-mrtr`, MODERN_FIXTURE, {
          mode: "mrtr_collision_form",
          expectedElicitation: "both",
        });
        const activeGateway = startToolGateway(`${surface} collision form complete.`);
        gateway = activeGateway;
        const stderrPath = join(root.root, "stderr.log");
        const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
        tui = await TmuxSession.create({
          isolated: true,
          ...(surface === "Ask"
            ? {
                cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the colliding MCP form fixture.")}`,
                remainOnExit: true,
              }
            : { stderrPath }),
          cwd: root.workspace,
          width: 120,
          height: 40,
          env: fixtureEnv(root, activeGateway),
        });
        if (surface === "TUI") {
          await tui.waitForComposer(15_000);
          await tui.sendText("Call the colliding MCP form fixture.");
        }
        const choose = async (ordinal: number) => {
          if (surface === "TUI") await tui!.sendKeys(String(ordinal));
          else await tui!.sendText(String(ordinal));
        };

        await tui.waitForText("choose how to fill literalSkip", 20_000);
        await choose(1);
        await tui.waitForText("requests literalSkip", 20_000);
        await tui.sendText("Skip");
        await tui.waitForText("choose how to fill literalDefault", 20_000);
        await choose(1);
        await tui.waitForText("requests literalDefault", 20_000);
        await tui.sendText("Use default");

        for (let ordinal = 1; ordinal <= 6; ordinal += 1) {
          await tui.waitForText(`requests choice${ordinal}`, 20_000);
          if (ordinal === 1) {
            const choices = await tui.captureFullScrollback();
            expect(choices).toContain("[1] Skip");
            expect(choices).toContain("[2] Use default");
            expect(choices).toContain("[3] Duplicate");
            expect(choices).toContain("[4] Duplicate");
            expect(choices).toContain("[5] Collision\\x1b[2J");
            expect(choices).toContain("[6] Collision\\x1b[2J");
          }
          await choose(ordinal);
        }

        await tui.waitForText('- literalSkip: "Skip"', 20_000);
        const review = await tui.captureFullScrollback();
        expect(review).toContain('- literalDefault: "Use default"');
        expect(review).toContain('- choice1: "Skip"');
        expect(review).toContain('- choice2: "Use default"');
        expect(review).toContain('- choice3: "value-3"');
        expect(review).toContain('- choice4: "Duplicate"');
        expect(review).toContain('- choice5: "escape-raw"');
        expect(review).toContain('- choice6: "escape-literal"');
        await choose(1);
        await tui.waitForText(`${surface} collision form complete.`, 20_000);

        const wire = readWire(root.wireLogPath);
        const calls = wire.filter((entry) => entry.message.method === "tools/call");
        expect(calls).toHaveLength(2);
        expect(calls[1]?.message.params?.inputResponses).toEqual({
          confirm: {
            action: "accept",
            content: {
              literalSkip: "Skip",
              literalDefault: "Use default",
              choice1: "Skip",
              choice2: "Use default",
              choice3: "value-3",
              choice4: "Duplicate",
              choice5: "escape-raw",
              choice6: "escape-literal",
            },
          },
        });
        const gatewayBodies = activeGateway.requests.map((entry) => entry.body).join("\n");
        expect(gatewayBodies).not.toContain("escape-literal");
        expect(readFileSync(root.traceLogPath, "utf8")).not.toContain("escape-literal");
        if (surface === "TUI") expect(readFileSync(stderrPath, "utf8")).toBe("");

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(wire);
      },
      60_000,
    );
  }

  test.skipIf(!tmuxAvailable())(
    "a visible TUI elicitation pauses the server-operation deadline",
    async () => {
      const root = createRoot("tui-mrtr-timeout", MODERN_FIXTURE, {
        mode: "mrtr_input_required",
        operationTimeoutMs: 5_000,
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("MRTR timeout complete.");
      gateway = activeGateway;
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the MRTR MCP fixture and wait.");
      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await Bun.sleep(6_000);
      await tui.sendKeys("1");
      await tui.waitForText("Current values:", 20_000);
      await tui.sendKeys("1");
      await tui.waitForText("MRTR timeout complete.", 20_000);

      expect(activeGateway.requests[2]?.body).toContain("continued after elicitation");
      expect(activeGateway.requests[2]?.body).not.toContain("McpRequestTimedOut");
      const wire = readWire(root.wireLogPath);
      const calls = wire.filter((entry) => entry.message.method === "tools/call");
      expect(calls).toHaveLength(2);
      expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: { action: "accept", content: { confirmed: true } },
      });

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "a TUI interrupt answers a pending question with cancel and doesn't continue the turn",
    async () => {
      const root = createRoot("tui-mrtr-interrupt", MODERN_FIXTURE, {
        mode: "mrtr_input_required",
        operationTimeoutMs: 30_000,
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Recovered after elicitation interrupt.");
      gateway = activeGateway;
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the MRTR MCP fixture and interrupt it.");
      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await tui.sendKeys("Escape");
      await tui.waitForComposer(5_000);

      // Esc answers the server's question with cancel (ELIC-04), and the
      // model's turn doesn't go on. The answer goes out after the turn ends.
      const callsSent = () => readWire(root.wireLogPath).filter((entry) => entry.message.method === "tools/call");
      const answerDeadline = Date.now() + 5_000;
      while (callsSent().length < 2 && Date.now() < answerDeadline) await Bun.sleep(25);
      const wire = readWire(root.wireLogPath);
      const calls = wire.filter((entry) => entry.message.method === "tools/call");
      expect(calls).toHaveLength(2);
      expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
      expect(calls[1]?.message.params?.inputResponses).toEqual({ confirm: { action: "cancel" } });
      expect(calls[1]?.message.params?.requestState).toBe("opaque");
      expect(activeGateway.requests).toHaveLength(2);

      await tui.sendText("Confirm the interface recovered.");
      await tui.waitForText("Recovered after elicitation interrupt.", 10_000);
      expect(activeGateway.requests).toHaveLength(3);

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    35_000,
  );

  test("negotiated 2025-06 treats a URL-required error as an ordinary failure", async () => {
    const root = createRoot("ask-legacy-url-required-unsupported", LEGACY_FIXTURE, {
      mode: "url_required_error",
      legacyVersion: "2025-06-18",
      elicitationUrl: "https://example.test/unsupported-version",
    });
    const activeGateway = startToolGateway("Legacy URL-required version gate complete.");
    gateway = activeGateway;
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the legacy URL-required fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const wire = readWire(root.wireLogPath);
    const calls = wire.filter((entry) => entry.message.method === "tools/call");
    expect(calls).toHaveLength(1);
    expect(activeGateway.requests[2]?.body).toContain("MCP protocol error -32042");
    await expectFixtureProcessesExited(wire);
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "interactive fx ask validates and submits a modern MCP form elicitation",
    async () => {
      const root = createRoot("ask-interactive-mrtr", MODERN_FIXTURE, {
        mode: "mrtr_input_required",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Interactive Ask elicitation complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      const prompt = "Call the MRTR MCP fixture interactively.";
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify(prompt)}`,
        cwd: root.workspace,
        width: 120,
        height: 34,
        remainOnExit: true,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await tui.sendText("1");
      await tui.waitForText(
        "Review the completed form requested by MCP server fixture",
        20_000,
      );
      await tui.waitForText("- confirmed: true", 20_000);
      await tui.sendText("1");
      await tui.waitForText("Interactive Ask elicitation complete.", 20_000);

      expect(activeGateway.requests).toHaveLength(3);
      expect(activeGateway.requests[2]?.body).toContain(
        "continued after elicitation",
      );
      const pane = await tui.captureFullScrollback();
      expect(pane).not.toContain("McpInputRequired");
      const calls = readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls).toHaveLength(2);
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: { action: "accept", content: { confirmed: true } },
      });

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "interactive fx ask puts a server's form question to the user",
    async () => {
      const root = createRoot("ask-interactive-mrtr-v2", MODERN_FIXTURE, {
        mode: "mrtr_input_required",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Interactive Ask elicitation complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      const prompt = "Call the MRTR MCP fixture interactively.";
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify(prompt)}`,
        cwd: root.workspace,
        width: 120,
        height: 34,
        remainOnExit: true,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await tui.sendText("1");
      await tui.waitForText("- confirmed: true", 20_000);
      await tui.sendText("1");
      await tui.waitForText("Interactive Ask elicitation complete.", 20_000);

      // The answer went back to the server in the call's second round.
      const calls = readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls).toHaveLength(2);
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: { action: "accept", content: { confirmed: true } },
      });
      expect(await tui.captureFullScrollback()).not.toContain("the server asked for input fx can't give");

      await tui.kill();
      tui = null;
    },
    30_000,
  );

  for (const legacyVersion of ["2025-06-18", "2025-11-25"] as const) {
    test.skipIf(!tmuxAvailable())(
      `interactive fx ask handles negotiated ${legacyVersion} direct elicitation/create`,
      async () => {
        const root = createRoot(`ask-legacy-direct-${legacyVersion}`, LEGACY_FIXTURE, {
          mode: "direct_form",
          legacyVersion,
          legacyDiscoveryMethodNotFound: true,
          operationTimeoutMs: 5_000,
        });
        const activeGateway = startToolGateway(`Legacy ${legacyVersion} elicitation complete.`);
        gateway = activeGateway;
        const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
        tui = await TmuxSession.create({
          isolated: true,
          cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the direct legacy elicitation fixture.")}`,
          cwd: root.workspace,
          width: 120,
          height: 36,
          remainOnExit: true,
          env: fixtureEnv(root, activeGateway),
        });

        await tui.waitForText("MCP server fixture requests choice", 20_000);
        await Bun.sleep(6_000);
        await tui.sendText("1");
        const expectedValue = legacyVersion === "2025-06-18"
          ? '- choice: "legacy-alpha-choice"'
          : '- choice: "legacyvalid"';
        await tui.waitForText(expectedValue, 20_000);
        await tui.sendText("1");
        await tui.waitForText(`Legacy ${legacyVersion} elicitation complete.`, 20_000);

        const wire = readWire(root.wireLogPath);
        const initialize = wire.filter((entry) => entry.message.method === "initialize");
        expect(initialize).toHaveLength(1);
        expect(initialize[0]?.message.params?.protocolVersion).toBe("2025-11-25");
        const calls = wire.filter((entry) => entry.message.method === "tools/call");
        expect(calls).toHaveLength(1);
        expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
        const directResponses = wire.filter((entry) =>
          entry.message.id === "legacy-elicitation" && entry.message.method == null
        );
        expect(directResponses).toHaveLength(1);
        expect(directResponses[0]?.message.result).toMatchObject({ action: "accept" });
        const gatewayBodies = activeGateway.requests.map((request) => request.body).join("\n");
        expect(gatewayBodies).not.toContain("legacy-alpha-choice");
        expect(gatewayBodies).not.toContain("legacyvalid");

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(wire);
      },
      50_000,
    );
  }

  test.skipIf(!tmuxAvailable())(
    "negotiated 2025-11 URL-required error retries only after manual confirmation",
    async () => {
      let targetRequests = 0;
      const target = Bun.serve({
        port: 0,
        fetch() {
          targetRequests += 1;
          return new Response("browser-only target");
        },
      });
      const targetUrl = `http://127.0.0.1:${target.port}/legacy-authorize?state=opaque`;
      const root = createRoot("ask-legacy-url-required", LEGACY_FIXTURE, {
        mode: "url_required_error",
        legacyVersion: "2025-11-25",
        elicitationUrl: targetUrl,
      });
      const fakeBin = join(root.root, "fake-bin");
      const openLog = join(root.root, "open.log");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(
        fakeBin,
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nexit 0\n",
      );
      const activeGateway = startToolGateway("Legacy URL-required complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      try {
        tui = await TmuxSession.create({
          isolated: true,
          cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the legacy URL-required fixture.")}`,
          cwd: root.workspace,
          width: 120,
          height: 36,
          remainOnExit: true,
          env: {
            ...fixtureEnv(root, activeGateway),
            PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
            FX_E2E_OPEN_LOG: openLog,
          },
        });

        await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
        await tui.sendText("1");
        await tui.waitForText("I completed it / Retry", 20_000);
        const beforeRetry = readWire(root.wireLogPath).filter((entry) =>
          entry.message.method === "tools/call"
        );
        expect(beforeRetry).toHaveLength(1);
        await tui.sendText("1");
        await tui.waitForText("Legacy URL-required complete.", 20_000);

        expect(readFileSync(openLog, "utf8").trim()).toBe(targetUrl);
        expect(targetRequests).toBe(0);
        const wire = readWire(root.wireLogPath);
        const calls = wire.filter((entry) => entry.message.method === "tools/call");
        expect(calls).toHaveLength(2);
        expect(calls[0]?.message.params?.inputResponses).toBeUndefined();
        expect(calls[1]?.message.params?.inputResponses).toBeUndefined();
        expect(calls[1]?.message.params?.requestState).toBeUndefined();

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(wire);
      } finally {
        target.stop(true);
      }
    },
    40_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy stdio waits for every matching URL completion and ignores wrong duplicates",
    async () => {
      const targetUrl = "https://example.test/legacy-multiple?state=opaque";
      const root = createRoot("ask-legacy-url-required-multiple", LEGACY_FIXTURE, {
        mode: "url_required_multiple",
        legacyVersion: "2025-11-25",
        elicitationUrl: targetUrl,
      });
      const fakeBin = join(root.root, "fake-bin");
      const openLog = join(root.root, "open.log");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(
        fakeBin,
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nexit 0\n",
      );
      const activeGateway = startToolGateway("Legacy multiple URL completion complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the multiple legacy URL fixture.")}`,
        cwd: root.workspace,
        width: 120,
        height: 36,
        remainOnExit: true,
        env: {
          ...fixtureEnv(root, activeGateway),
          PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
          FX_E2E_OPEN_LOG: openLog,
        },
      });

      await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
      await tui.sendText("1");
      await tui.waitForText(`Complete URL: ${targetUrl}#second`, 20_000);
      await tui.sendText("1");
      await tui.waitForText("I completed it / Retry", 20_000);
      expect(readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      )).toHaveLength(1);

      writeFileSync(root.invalidationReleasePath, "one");
      await Bun.sleep(150);
      expect(readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      )).toHaveLength(1);

      writeFileSync(root.invalidationReleasePath, "two");
      await tui.waitForText("Legacy multiple URL completion complete.", 20_000);
      const calls = readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls).toHaveLength(2);
      expect(calls[1]?.message.id).not.toBe(calls[0]?.message.id);
      expect(calls[1]?.message.params?.inputResponses).toBeUndefined();
      expect(calls[1]?.message.params?.requestState).toBeUndefined();
      expect(readFileSync(openLog, "utf8").trim().split("\n")).toEqual([
        targetUrl,
        `${targetUrl}#second`,
      ]);

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy stdio ignores malformed URL completions until one valid matching notification",
    async () => {
      const targetUrl = "https://example.test/legacy-malformed?state=opaque";
      const root = createRoot("ask-legacy-url-required-malformed", LEGACY_FIXTURE, {
        mode: "url_required_malformed_completion",
        legacyVersion: "2025-11-25",
        elicitationUrl: targetUrl,
      });
      const fakeBin = join(root.root, "fake-bin");
      const openLog = join(root.root, "open.log");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(
        fakeBin,
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nexit 0\n",
      );
      const activeGateway = startToolGateway("Legacy malformed completion complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the malformed completion fixture.")}`,
        cwd: root.workspace,
        width: 120,
        height: 36,
        remainOnExit: true,
        env: {
          ...fixtureEnv(root, activeGateway),
          PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
          FX_E2E_OPEN_LOG: openLog,
        },
      });

      await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
      await tui.sendText("1");
      await tui.waitForText("I completed it / Retry", 20_000);
      const calls = () => readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls()).toHaveLength(1);

      writeFileSync(root.invalidationReleasePath, "invalid");
      await Bun.sleep(200);
      expect(calls()).toHaveLength(1);

      writeFileSync(root.invalidationReleasePath, "valid");
      await tui.waitForText("Legacy malformed completion complete.", 20_000);
      const completedCalls = calls();
      expect(completedCalls).toHaveLength(2);
      expect(completedCalls[1]?.message.id).not.toBe(completedCalls[0]?.message.id);
      expect(completedCalls[1]?.message.params?.inputResponses).toBeUndefined();
      expect(completedCalls[1]?.message.params?.requestState).toBeUndefined();
      expect(readFileSync(openLog, "utf8").trim()).toBe(targetUrl);

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy stdio cancellation after browser consent never retries",
    async () => {
      const root = createRoot("ask-legacy-url-required-cancel", LEGACY_FIXTURE, {
        mode: "url_required_error",
        legacyVersion: "2025-11-25",
        elicitationUrl: "https://example.test/cancel",
      });
      const activeGateway = startToolGateway("must not complete");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      const fakeBin = join(root.root, "fake-bin");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(fakeBin, "#!/bin/sh\nexit 0\n");
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call and cancel the legacy URL fixture.")}`,
        cwd: root.workspace,
        width: 110,
        height: 34,
        remainOnExit: true,
        env: {
          ...fixtureEnv(root, activeGateway),
          PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
        },
      });
      await tui.waitForText("Open URL", 20_000);
      await tui.sendText("1");
      await tui.waitForText("I completed it / Retry", 20_000);
      await tui.sendText("2");
      await Bun.sleep(200);
      expect(readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      )).toHaveLength(1);
      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy stdio URL completion outlives the operation deadline",
    async () => {
      const root = createRoot("ask-legacy-url-required-timeout", LEGACY_FIXTURE, {
        mode: "url_required_error",
        legacyVersion: "2025-11-25",
        elicitationUrl: "https://example.test/timeout",
        operationTimeoutMs: 1_500,
      });
      const activeGateway = startToolGateway("Legacy URL timeout handled.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      const fakeBin = join(root.root, "fake-bin");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(fakeBin, "#!/bin/sh\nexit 0\n");
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call and wait for the legacy URL fixture.")}`,
        cwd: root.workspace,
        width: 110,
        height: 34,
        remainOnExit: true,
        env: {
          ...fixtureEnv(root, activeGateway),
          PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
        },
      });
      await tui.waitForText("Open URL", 20_000);
      await tui.sendText("1");
      await tui.waitForText("I completed it / Retry", 20_000);
      await Bun.sleep(2_000);
      expect(await tui.capturePane()).toContain("I completed it / Retry");
      await tui.sendText("1");
      await tui.waitForText("Legacy URL timeout handled.", 20_000);
      const wire = readWire(root.wireLogPath);
      expect(wire.filter((entry) => entry.message.method === "tools/call"))
        .toHaveLength(2);

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "interactive fx ask validates Unicode patterns, edits, and submits every form field kind",
    async () => {
      const root = createRoot("ask-interactive-full-form", MODERN_FIXTURE, {
        mode: "mrtr_full_form",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Interactive Ask full form complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      tui = await TmuxSession.create({
        isolated: true,
        cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Complete the full MCP form.")}`,
        cwd: root.workspace,
        width: 120,
        height: 38,
        remainOnExit: true,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForText("MCP server fixture requests name", 20_000);
      await tui.sendText("x");
      await tui.waitForText("did not satisfy the requested form constraints", 20_000);
      await tui.sendText("1");

      await tui.waitForText("MCP server fixture requests name", 20_000);
      await tui.sendText("Ada");
      await tui.waitForText("MCP server fixture requests age", 20_000);
      await tui.sendText("42");
      await tui.waitForText("MCP server fixture requests ratio", 20_000);
      await tui.sendText("0.5");
      await tui.waitForText("MCP server fixture requests enabled", 20_000);
      await tui.sendText("1");
      await tui.waitForText("MCP server fixture requests color", 20_000);
      await tui.sendText("2");
      await tui.waitForText("include Alpha in tags", 20_000);
      await tui.sendText("1");
      await tui.waitForText("include Beta in tags", 20_000);
      await tui.sendText("2");
      await tui.waitForText('- name: "Ada"', 20_000);
      let review = await tui.captureFullScrollback();
      expect(review).toContain('- name: "Ada"');
      expect(review).toContain("- age: 42");
      expect(review).toContain("- ratio: 0.5");
      expect(review).toContain("- enabled: true");
      expect(review).toContain('- color: "blue"');
      expect(review).toContain('- tags: ["a"]');
      await tui.sendText("2");

      await tui.waitForText('current value for name is "Ada"', 20_000);
      await tui.sendText("2");
      await tui.waitForText("MCP server fixture requests name", 20_000);
      await tui.sendText("Béa");
      await tui.waitForText("current value for age is 42", 20_000);
      await tui.sendText("2");
      await tui.waitForText("MCP server fixture requests age", 20_000);
      await tui.sendText("43");
      await tui.waitForText("current value for ratio is 0.5", 20_000);
      await tui.sendText("2");
      await tui.waitForText("MCP server fixture requests ratio", 20_000);
      await tui.sendText("0.75");
      await tui.waitForText("current value for enabled is true", 20_000);
      await tui.sendText("2");
      await tui.waitForText("MCP server fixture requests enabled", 20_000);
      await tui.sendText("2");
      await tui.waitForText('current value for color is "blue"', 20_000);
      await tui.sendText("2");
      await tui.waitForText("MCP server fixture requests color", 20_000);
      await tui.sendText("1");
      await tui.waitForText('current value for tags is ["a"]', 20_000);
      await tui.sendText("2");
      await tui.waitForText("include Alpha in tags", 20_000);
      await tui.sendText("2");
      await tui.waitForText("include Beta in tags", 20_000);
      await tui.sendText("1");
      await tui.waitForText('- name: "Béa"', 20_000);
      review = await tui.captureFullScrollback();
      expect(review).toContain('- name: "Béa"');
      expect(review).toContain("- age: 43");
      expect(review).toContain("- ratio: 0.75");
      expect(review).toContain("- enabled: false");
      expect(review).toContain('- color: "red"');
      expect(review).toContain('- tags: ["b"]');
      await tui.sendText("1");
      await tui.waitForText("Interactive Ask full form complete.", 20_000);

      const calls = readWire(root.wireLogPath).filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls).toHaveLength(2);
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: {
          action: "accept",
          content: {
            name: "Béa",
            age: 43,
            ratio: 0.75,
            enabled: false,
            color: "red",
            tags: ["b"],
          },
        },
      });
      const gatewayBodies = activeGateway.requests.map((request) => request.body).join("\n");
      expect(gatewayBodies).not.toContain("Béa");
      expect(gatewayBodies).not.toContain("0.75");

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "interactive fx ask retries a URL browser failure without prefetching",
    async () => {
      let targetRequests = 0;
      const target = Bun.serve({
        port: 0,
        fetch() {
          targetRequests += 1;
          return new Response("browser-only target");
        },
      });
      const targetUrl = `http://127.0.0.1:${target.port}/authorize?state=opaque`;
      const root = createRoot("ask-interactive-url", MODERN_FIXTURE, {
        mode: "mrtr_url_required",
        expectedElicitation: "both",
        elicitationUrl: targetUrl,
      });
      const fakeBin = join(root.root, "fake-bin");
      const openLog = join(root.root, "open.log");
      const openState = join(root.root, "open-state");
      const traceLog = join(root.root, "url-opener-trace.log");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(
        fakeBin,
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nif [ ! -e \"$FX_E2E_OPEN_STATE\" ]; then touch \"$FX_E2E_OPEN_STATE\"; exit 1; fi\nexit 0\n",
      );
      const activeGateway = startToolGateway("Interactive Ask URL elicitation complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      try {
        tui = await TmuxSession.create({
          isolated: true,
          cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the URL elicitation fixture.")}`,
          cwd: root.workspace,
          width: 120,
          height: 36,
          remainOnExit: true,
          env: {
            ...fixtureEnv(root, activeGateway),
            PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
            FX_E2E_OPEN_LOG: openLog,
            FX_E2E_OPEN_STATE: openState,
            FX_TRACE_LOG: traceLog,
            FX_TRACE_SCOPES: "core",
          },
        });

        await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
        await tui.sendText("1");
        await tui.waitForText("Continue manually, retry the browser, or cancel?", 20_000);
        const trace = readFileSync(traceLog, "utf8");
        expect(trace).toContain(
          "url opener unsuccessful term=exited exit_code=1",
        );
        expect(trace).not.toContain(targetUrl);
        expect(trace).not.toContain("state=opaque");
        await tui.sendText("2");
        await tui.waitForText("Interactive Ask URL elicitation complete.", 20_000);

        expect(readFileSync(openLog, "utf8").trim().split("\n")).toEqual([
          targetUrl,
          targetUrl,
        ]);
        expect(targetRequests).toBe(0);
        const calls = readWire(root.wireLogPath).filter((entry) =>
          entry.message.method === "tools/call"
        );
        expect(calls).toHaveLength(2);
        expect(calls[1]?.message.params?.inputResponses).toEqual({
          confirm: { action: "accept" },
        });
        expect(calls[1]?.message.params?.requestState).toBe("opaque");

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(readWire(root.wireLogPath));
      } finally {
        target.stop(true);
      }
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "interactive fx ask can refuse a URL without launching a browser",
    async () => {
      let targetRequests = 0;
      const target = Bun.serve({
        port: 0,
        fetch() {
          targetRequests += 1;
          return new Response("browser-only target");
        },
      });
      const targetUrl = `http://127.0.0.1:${target.port}/decline?state=opaque`;
      const root = createRoot("ask-interactive-url-decline", MODERN_FIXTURE, {
        mode: "mrtr_url_required",
        expectedElicitation: "both",
        elicitationUrl: targetUrl,
      });
      const fakeBin = join(root.root, "fake-bin");
      const openLog = join(root.root, "open.log");
      mkdirSync(fakeBin);
      writeFakeUrlOpeners(
        fakeBin,
        "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nexit 0\n",
      );
      const activeGateway = startToolGateway("Interactive Ask URL refusal complete.");
      gateway = activeGateway;
      const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
      try {
        tui = await TmuxSession.create({
          isolated: true,
          cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Decline the URL elicitation fixture.")}`,
          cwd: root.workspace,
          width: 120,
          height: 34,
          remainOnExit: true,
          env: {
            ...fixtureEnv(root, activeGateway),
            PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
            FX_E2E_OPEN_LOG: openLog,
          },
        });

        await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
        await tui.sendText("2");
        await tui.waitForText("Interactive Ask URL refusal complete.", 20_000);

        expect(existsSync(openLog)).toBe(false);
        expect(targetRequests).toBe(0);
        const calls = readWire(root.wireLogPath).filter((entry) =>
          entry.message.method === "tools/call"
        );
        expect(calls).toHaveLength(2);
        expect(calls[1]?.message.params?.inputResponses).toEqual({
          confirm: { action: "decline" },
        });

        await tui.kill();
        tui = null;
        await expectFixtureProcessesExited(readWire(root.wireLogPath));
      } finally {
        target.stop(true);
      }
    },
    35_000,
  );

  // A long tool's progress notes show while it runs.
  test("fx ask shows a 2026 server's progress notes", async () => {
    const progressRoot = createRoot("ask-progress", MODERN_FIXTURE, {
      mode: "progress",
    });
    const progressGateway = startToolGateway("Progress MCP complete.");
    gateway = progressGateway;
    const progressResult = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the progress MCP fixture."],
      {
        cwd: progressRoot.workspace,
        env: fixtureEnv(progressRoot, progressGateway),
        timeoutMs: 20_000,
      },
    );
    expect(progressResult.code).toBe(0);
    expect(progressResult.stderr).toContain("MCP fixture halfway");
    const progressWire = readWire(progressRoot.wireLogPath);
    const progressCall = progressWire.find(
      (entry) => entry.message.method === "tools/call",
    );
    expect(progressCall?.message.params?._meta).toMatchObject({
      progressToken: expect.any(Number),
    });
    await expectFixtureProcessesExited(progressWire);
  }, 45_000);

  test("headless MCP startup cancels through the caller", async () => {
    const root = createRoot("startup-caller-cancel", MODERN_FIXTURE, {
      mode: "stall_startup", startupTimeoutMs: 5_000, restartLimit: 0,
    });
    gateway = startFakeGateway([
      fakeGatewayToolCall("cancel_startup", "capability_search", { server: "fixture", query: "echo" }),
      fakeGatewayFinalText("Unexpected continuation."),
    ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    const proc = Bun.spawn([join(REPO_ROOT, "zig-out", "bin", "fx"), "ask", "--json", "--auto", "--no-save", "Find the fixture tool"], {
      cwd: root.workspace, env: { ...process.env, ...fixtureEnv(root, gateway) }, stdout: "ignore", stderr: "ignore",
    });
    try {
      const deadline = Date.now() + 5_000;
      while (!existsSync(root.wireLogPath) && Date.now() < deadline) await Bun.sleep(10);
      expect(existsSync(root.wireLogPath)).toBe(true);
      proc.kill("SIGINT");
      const exited = await Promise.race([proc.exited.then(() => true), Bun.sleep(1_500).then(() => false)]);
      expect(exited).toBe(true);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      if (proc.exitCode === null) proc.kill("SIGKILL");
      await proc.exited;
      if (existsSync(root.wireLogPath)) await expectFixtureProcessesExited(readWire(root.wireLogPath));
    }
  }, 15_000);

  test.skipIf(!tmuxAvailable())(
    "the TUI cancels a stalled stdio request and accepts a follow-up prompt",
    async () => {
      const root = createRoot("tui-cancel", MODERN_FIXTURE, {
        mode: "stall_operation",
        operationTimeoutMs: 30_000,
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Cancelled MCP TUI complete.");
      gateway = activeGateway;
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the stalled MCP fixture.");
      const call_deadline = Date.now() + 15_000;
      while (Date.now() < call_deadline) {
        if (
          readWire(root.wireLogPath).some(
            (entry) => entry.message.method === "tools/call",
          )
        ) {
          break;
        }
        await Bun.sleep(25);
      }
      expect(
        readWire(root.wireLogPath).some(
          (entry) => entry.message.method === "tools/call",
        ),
      ).toBe(true);

      await tui.sendInterruptEscapePair(10_000);
      await tui.waitForText("Cancelled mcp_fixture_echo", 10_000);
      await tui.waitForText("▪ Cancelled", 5_000);
      const cancel_deadline = Date.now() + 5_000;
      while (Date.now() < cancel_deadline) {
        if (
          readWire(root.wireLogPath).some(
            (entry) => entry.message.method === "notifications/cancelled",
          )
        ) {
          break;
        }
        await Bun.sleep(25);
      }
      const wire = readWire(root.wireLogPath);
      const cancelled = wire.find(
        (entry) => entry.message.method === "notifications/cancelled",
      );
      // The cancel names the stalled call.
      const stalled = wire.filter((entry) => entry.message.method === "tools/call").at(-1);
      expect(cancelled?.message.params?.requestId).toBe(stalled?.message.id);

      await tui.waitForStableComposer(5_000);
      await tui.sendText("Confirm the next prompt works.");
      await tui.waitForText("Cancelled MCP TUI complete.", 10_000);
      expect(activeGateway.requests).toHaveLength(3);
      expect(activeGateway.requests[2]?.body).toContain("Confirm the next prompt works.");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await tui.kill();
      tui = null;
      await expectFixtureProcessesExited(wire);
    },
    35_000,
  );

  test.skipIf(process.platform === "win32" || !tmuxAvailable())(
    "the TUI cancels stalled recovery without waiting for its operation deadline",
    async () => {
      const root = createRoot("tui-recovery-cancel", MODERN_FIXTURE, {
        mode: "block_then_stall_recovery",
        expectedElicitation: "both",
      });
      const activeGateway = startToolGateway("Recovery cancellation complete.");
      gateway = activeGateway;
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        stderrPath,
        env: fixtureEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      // Servers start when first needed; the menu starts this one.
      await tui.sendText("/mcp");
      await tui.waitForText(/fixture +ready, 1 tool/, 15_000);
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("MCP servers"), 5_000);
      const firstPid = Number(readFileSync(join(root.root, "mcp.pid"), "utf8"));
      process.kill(firstPid, "SIGKILL");
      const childExitDeadline = Date.now() + 5_000;
      while (isProcessAlive(firstPid) && Date.now() < childExitDeadline) {
        await Bun.sleep(25);
      }
      expect(isProcessAlive(firstPid)).toBe(false);

      // The call waits for the restart under way, even during the pause
      // before it, so the stalled relaunch is what Esc cancels.
      await tui.sendText("Call the recovering MCP fixture.");
      const readyPath = join(root.root, "mcp-recovery-ready");
      const recoveryDeadline = Date.now() + 15_000;
      while (!existsSync(readyPath) && Date.now() < recoveryDeadline) {
        await Bun.sleep(25);
      }
      expect(existsSync(readyPath)).toBe(true);

      const cancelStarted = Date.now();
      await tui.sendInterruptEscapePair(5_000);
      await tui.waitForText("Cancelled mcp_fixture_echo", 5_000);
      expect(Date.now() - cancelStarted).toBeLessThan(5_000);

      await tui.kill();
      tui = null;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const wire = readWire(root.wireLogPath);
      expect(new Set(wire.map((entry) => entry.pid)).size).toBe(2);
      expect(
        wire.some((entry) => entry.message.method === "notifications/cancelled"),
      ).toBe(false);
      await expectFixtureProcessesExited(wire);
    },
    40_000,
  );

  test(
    "fx mcp show reports a ready stdio server without its environment's values",
    async () => {
      const root = createRoot("health-output", MODERN_FIXTURE);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      profile.mcp.fixture.environment.S11_SECRET_ENV = "HEALTH_SECRET_SENTINEL";
      writeFileSync(profilePath, JSON.stringify(profile));
      const activeGateway = startFakeGateway([
        fakeGatewayFinalText("health gateway should remain unused"),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["mcp", "show", "fixture", "--json"], {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      });
      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      const status = JSON.parse(result.stdout);
      expect({ status: status.status, source: status.source, transport: status.transport, version: status.version })
        .toEqual({ status: "ready", source: "profile", transport: "stdio", version: "2026-07-28" });
      expect(status.tools.map((tool: { name: string }) => tool.name)).toEqual(["echo"]);
      // The server's environment and fx's Gateway key never show.
      for (const forbidden of ["HEALTH_SECRET_SENTINEL", "S11_SECRET_ENV", "fake-mcp-stdio-key", root.workspace]) {
        expect(result.stdout).not.toContain(forbidden);
      }
      expect(activeGateway.requests).toHaveLength(0);
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    },
    35_000,
  );

  test("fx ask performs one fresh-discovery restart without replaying the failed call", async () => {
    const root = createRoot("ask-restart", MODERN_FIXTURE, {
      mode: "crash_once",
      restartLimit: 1,
    });
    const activeGateway = startFakeGateway([
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("crashing_mcp", TOOL_NAME, { text: "first" }),
      fakeGatewayToolCall("recovered_mcp", TOOL_NAME, { text: "second" }),
      fakeGatewayFinalText("Restarted MCP complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    gateway = activeGateway;

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Recover the MCP fixture once."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, activeGateway),
        timeoutMs: 20_000,
      },
    );
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Restarted MCP complete.");
    // A call the crash took is not replayed: it may have run.
    expect(toolResultText(activeGateway.requests[2]?.body ?? "", "crashing_mcp")).toBe(
      "MCP server 'fixture' ended the call: the server went away. The tool may have run.",
    );
    expect(activeGateway.requests[3]?.body).toContain(`${MODERN_RESULT}:second`);

    const wire = readWire(root.wireLogPath);
    const pids = new Set(wire.map((entry) => entry.pid));
    expect(pids.size).toBe(2);
    expect(
      wire.filter((entry) => entry.message.method === "server/discover"),
    ).toHaveLength(2);
    const toolCalls = wire.filter(
      (entry) => entry.message.method === "tools/call",
    );
    expect(toolCalls).toHaveLength(2);
    expect(toolCalls[0]?.message.params?.arguments).toEqual({ text: "first" });
    expect(toolCalls[1]?.message.params?.arguments).toEqual({ text: "second" });
    await expectFixtureProcessesExited(wire);
  }, 30_000);

});

describe("MCP stdio servers", () => {
  const v2Env = (root: FixtureRoot, activeGateway: ReturnType<typeof startFakeGateway>) => ({
    ...fixtureEnv(root, activeGateway),
  });
  const modelSaw = () => gateway!.requests.map((request) => request.body).join("\n");
  const ask = (root: FixtureRoot, prompt: string) =>
    runFx(["ask", "--json", "--auto", "--no-save", prompt], {
      cwd: root.workspace,
      env: v2Env(root, gateway!),
      timeoutMs: 20_000,
    });
  const calls = (root: FixtureRoot) =>
    readWire(root.wireLogPath).filter((entry) => entry.message.method === "tools/call");

  for (const [era, fixture, resultText] of [
    ["2026", MODERN_FIXTURE, MODERN_RESULT],
    ["2025", LEGACY_FIXTURE, LEGACY_RESULT],
  ] as const) {
    test(`fx ask selects and calls a ${era} stdio tool`, async () => {
      // A 2025-11-25 server, the newest before 2026.
      const root = createRoot(`v2-call-${era}`, fixture, { legacyVersion: "2025-11-25" });
      gateway = startToolGateway(`V2_${era}_DONE`);
      const result = await ask(root, "Use the stdio MCP echo tool.");
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(`V2_${era}_DONE`);
      expect(modelSaw()).toContain(resultText);
      // The server's instructions come with the selected tool.
      if (era === "2026") expect(modelSaw()).toContain("Use the modern echo tool.");
      expect(calls(root)).toHaveLength(1);
      await expectFixtureProcessesExited(readWire(root.wireLogPath));
    }, 25_000);
  }

  test("a 2025 server that pings before it answers initialize gets its pong, and its tool is called", async () => {
    // It holds its initialize answer until fx answers the ping, as a server
    // that blocks on it would (STDIO-09).
    const root = createRoot("v2-ping-before-initialize", LEGACY_FIXTURE, { legacyVersion: "2025-11-25", mode: "ping_before_initialize" });
    gateway = startToolGateway("V2_PING_DONE");
    const result = await ask(root, "Use the stdio MCP echo tool.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_PING_DONE");
    expect(modelSaw()).toContain(LEGACY_RESULT);
    expect(calls(root)).toHaveLength(1);
    // The pong came during the handshake, before notifications/initialized.
    const wire = readWire(root.wireLogPath);
    const pong = wire.findIndex((entry) => entry.message.id === "legacy-ping" && entry.message.method === undefined);
    const initialized = wire.findIndex((entry) => entry.message.method === "notifications/initialized");
    expect(pong).toBeGreaterThanOrEqual(0);
    expect(pong).toBeLessThan(initialized);
    await expectFixtureProcessesExited(wire);
  }, 25_000);

  test("a server that only speaks 2024-11-05 is reported, not waited on", async () => {
    const root = createRoot("v2-2024", LEGACY_FIXTURE, { legacyVersion: "2024-11-05" });
    gateway = startToolGateway("V2_2024_SEEN");
    const started = Date.now();
    const result = await ask(root, "Use the stdio MCP echo tool.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_2024_SEEN");
    expect(Date.now() - started).toBeLessThan(10_000);
    expect(calls(root)).toHaveLength(0);
    expect(modelSaw()).toContain("MCP server 'fixture' is unavailable");
    expect(modelSaw()).toContain("an MCP version fx doesn't support");
  }, 25_000);

  test("capability_search finds the tool under its fx name and the model calls it", async () => {
    const root = createRoot("v2-search", MODERN_FIXTURE);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search", "capability_search", { query: "echo", server: "fixture" }),
      fakeGatewayToolCall("call", TOOL_NAME, { text: "hello" }),
      fakeGatewayFinalText("V2_SEARCH_DONE"),
    ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    const result = await ask(root, "Find the echo tool and use it.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_SEARCH_DONE");
    expect(modelSaw()).toContain(`\\"name\\":\\"${TOOL_NAME}\\",\\"server\\":\\"fixture\\"`);
    expect(modelSaw()).toContain(MODERN_RESULT);
    expect(calls(root)).toHaveLength(1);
  }, 25_000);

  test("a tool's own failure reaches the model and the turn goes on", async () => {
    const root = createRoot("v2-tool-failure", MODERN_FIXTURE, { mode: "tool_failure" });
    gateway = startToolGateway("V2_FAILURE_SEEN");
    const result = await ask(root, "Use the stdio MCP echo tool.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_FAILURE_SEEN");
    expect(modelSaw()).toContain("isError");
  }, 25_000);

  test("a server that dies during a call tells the model the call ended", async () => {
    const root = createRoot("v2-crash", MODERN_FIXTURE, { mode: "crash_always" });
    gateway = startToolGateway("V2_CRASH_SEEN");
    const result = await ask(root, "Use the stdio MCP echo tool.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_CRASH_SEEN");
    expect(modelSaw()).toContain("MCP server 'fixture' ended the call");
  }, 25_000);

  test.skipIf(!tmuxAvailable())("the shell asks a server's form question and sends the answer", async () => {
    const root = createRoot("v2-tui-form", MODERN_FIXTURE, {
      mode: "mrtr_input_required",
      expectedElicitation: "both",
    });
    const activeGateway = startToolGateway("V2 TUI form complete.");
    gateway = activeGateway;
    const stderrPath = join(root.root, "stderr.log");
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 100,
      height: 30,
      stderrPath,
      env: v2Env(root, activeGateway),
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("Call the MRTR MCP fixture.");
    await tui.waitForText("MCP server fixture requests confirmed", 20_000);
    await tui.sendKeys("1");
    await tui.waitForText("Current values:", 20_000);
    await tui.sendKeys("1");
    await tui.waitForText("V2 TUI form complete.", 20_000);

    expect(activeGateway.requests[2]?.body).toContain("continued after elicitation");
    const formCalls = calls(root);
    expect(formCalls).toHaveLength(2);
    expect(formCalls[1]?.message.params?.inputResponses).toEqual({
      confirm: { action: "accept", content: { confirmed: true } },
    });
    expect(formCalls[1]?.message.params?.requestState).toBe("opaque");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    await tui.kill();
    tui = null;
    await expectFixtureProcessesExited(readWire(root.wireLogPath));
  }, 30_000);

  test.skipIf(!tmuxAvailable())("the shell answers a 2025 server's elicitation during a call", async () => {
    const root = createRoot("v2-tui-elicit", LEGACY_FIXTURE, {
      mode: "direct_form",
      legacyVersion: "2025-11-25",
      legacyDiscoveryMethodNotFound: true,
    });
    const activeGateway = startToolGateway("V2 2025 elicitation complete.");
    gateway = activeGateway;
    const stderrPath = join(root.root, "stderr.log");
    tui = await TmuxSession.create({
      isolated: true,
      cwd: root.workspace,
      width: 120,
      height: 36,
      stderrPath,
      env: v2Env(root, activeGateway),
    });
    await tui.waitForComposer(15_000);
    await tui.sendText("Call the direct legacy elicitation fixture.");
    await tui.waitForText("MCP server fixture requests choice", 20_000);
    // The shell submits a single compact choice without a review step.
    await tui.sendText("1");
    await tui.waitForText("V2 2025 elicitation complete.", 20_000);

    const wire = readWire(root.wireLogPath);
    expect(calls(root)).toHaveLength(1);
    const answers = wire.filter((entry) => entry.message.id === "legacy-elicitation" && entry.message.method == null);
    expect(answers).toHaveLength(1);
    expect(answers[0]?.message.result).toMatchObject({ action: "accept" });
    expect(modelSaw()).not.toContain("legacyvalid");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    await tui.kill();
    tui = null;
    await expectFixtureProcessesExited(wire);
  }, 40_000);

  test("fx ask with no way to ask tells the model the server wanted input", async () => {
    const root = createRoot("v2-no-asker", MODERN_FIXTURE, { mode: "mrtr_input_required" });
    gateway = startToolGateway("V2_INPUT_DECLINED_SEEN");
    const result = await ask(root, "Call the MRTR MCP fixture.");
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("V2_INPUT_DECLINED_SEEN");
    expect(modelSaw()).toContain("the server asked for input fx can't give");
  }, 25_000);

  test("a search for a server that isn't configured says so", async () => {
    const root = createRoot("v2-not-found", MODERN_FIXTURE);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search", "capability_search", { query: "echo", server: "nope" }),
      fakeGatewayFinalText("V2_NOT_FOUND_SEEN"),
    ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    const result = await ask(root, "Find a tool on nope.");
    expect(result.code).toBe(0);
    expect(modelSaw()).toContain("server_not_found");
    // Nothing needed the configured server, so it never started.
    expect(existsSync(root.wireLogPath)).toBe(false);
  }, 25_000);
});
