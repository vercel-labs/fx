import { afterEach, describe, expect, test } from "bun:test";
import {
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
import {
  startContentLengthMcpHttpFixture,
  type ContentLengthResponseType,
} from "./fixtures/mcp-content-length-http";
import {
  MODERN_HTTP_TOOL_RESULT,
  MODERN_MCP_VERSION,
  startModernMcpHttpFixture,
  type ModernHttpMode,
} from "./fixtures/mcp-modern-http";
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

let cleanupRoot: string | null = null;
let fixture: ReturnType<typeof startModernMcpHttpFixture> | null = null;
let contentLengthFixture: Awaited<
  ReturnType<typeof startContentLengthMcpHttpFixture>
> | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeFixture = fixture;
  const activeContentLengthFixture = contentLengthFixture;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  fixture = null;
  contentLengthFixture = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  activeFixture?.stop();
  if (activeContentLengthFixture) await activeContentLengthFixture.stop();
  if (activeCleanupRoot) {
    rmSync(activeCleanupRoot, { recursive: true, force: true });
  }
});

function createRoot(
  label: string,
  activeFixture: { url: string },
  operationTimeoutMs = 5_000,
  required = false,
) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-mcp-http-${label}-`)));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
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
          type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
          url: activeFixture.url,
          headers: { "X-Workspace": "one" },
          ...(required ? { required: true } : {}),
          startup_timeout_ms: 5_000,
          operation_timeout_ms: operationTimeoutMs,
        },
      },
    }),
  );
  return { root, home, workspace, traceLogPath: join(root, "fx-trace.log") };
}

function createEmptyRoot(label: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-mcp-http-${label}-`)));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: {} }));
  return { root, home, workspace, traceLogPath: join(root, "fx-trace.log") };
}

function fixtureEnv(
  root: ReturnType<typeof createRoot>,
  activeGateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-mcp-http-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_MCP_PROTOCOL_VERSION: "2026-07-28",
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

function toolResultText(
  body: string,
  toolCallId: string,
  outputType: "text" | "error-text" = "text",
): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) =>
      part.type === "tool-result" && part.toolCallId === toolCallId
    );
  if (!result) throw new Error(`Missing tool result for ${toolCallId}`);
  const output = result.output as Record<string, unknown>;
  if (output.type !== outputType || typeof output.value !== "string") {
    throw new Error(`Invalid tool result for ${toolCallId}`);
  }
  return output.value;
}

function preserveHttpFailure(
  label: string,
  root: ReturnType<typeof createRoot>,
  result: Awaited<ReturnType<typeof runFx>>,
  activeFixture: ReturnType<typeof startModernMcpHttpFixture>,
  activeGateway: ReturnType<typeof startFakeGateway>,
  force = false,
): void {
  if (result.code === 0 && !force) return;
  cleanupRoot = null;
  writeFileSync(join(root.root, "fx-stdout.log"), result.stdout);
  writeFileSync(join(root.root, "fx-stderr.log"), result.stderr);
  writeFileSync(
    join(root.root, "failure.json"),
    JSON.stringify({
      label,
      result,
      fixtureRequests: activeFixture.requests,
      gatewayRequests: activeGateway.requests.map((request) => request.body),
    }, null, 2),
  );
  throw new Error(`fx ${label} failed; retained artifacts: ${root.root}`);
}

function assertModernWire(
  activeFixture: ReturnType<typeof startModernMcpHttpFixture>,
) {
  expect(activeFixture.requests.map((entry) => entry.message.method)).toEqual([
    "server/discover",
    "tools/list",
    "tools/call",
  ]);
  expect(activeFixture.httpMethods).toEqual(["POST", "POST", "POST"]);
  for (const entry of activeFixture.requests) {
    const meta = entry.message.params?._meta;
    expect(meta?.["io.modelcontextprotocol/protocolVersion"]).toBe(
      MODERN_MCP_VERSION,
    );
    expect(meta?.["io.modelcontextprotocol/clientCapabilities"]).toEqual({});
    expect(entry.headers.accept).toBe(
      "application/json, text/event-stream",
    );
    expect(entry.headers["mcp-protocol-version"]).toBe(MODERN_MCP_VERSION);
    expect(entry.headers["mcp-method"]).toBe(entry.message.method);
    expect(entry.headers["x-workspace"]).toBe("one");
    expect(entry.headers["mcp-session-id"]).toBeUndefined();
    expect(entry.headers["last-event-id"]).toBeUndefined();
  }
  const call = activeFixture.requests[2]!;
  expect(call.headers["mcp-name"]).toBe("echo");
  expect(call.headers["mcp-param-text"]).toBe("hello");
}

describe("modern MCP Streamable HTTP", () => {
  test("an OAuth-configured server failure does not invent an authentication challenge", async () => {
    let hits = 0;
    const failing = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch() {
        hits += 1;
        return new Response("server unavailable", { status: 500 });
      },
    });
    const root = createRoot("oauth-server-failure", { url: `http://127.0.0.1:${failing.port}/mcp` });
    writeFileSync(join(root.home, ".fx", "mcp.json"), JSON.stringify({
      mcp: {
        fixture: {
          type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
          url: `http://127.0.0.1:${failing.port}/mcp`,
          oauth: { client_id: "fixture-client" },
          startup_timeout_ms: 1_000,
        },
      },
    }));
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_fixture", "capability_search", { query: "fixture", server: "fixture" }),
      fakeGatewayFinalText("Server failure observed."),
    ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
    try {
      const result = await runFx(["ask", "--json", "--auto", "--no-save", "Find the fixture tools"], {
        cwd: root.workspace,
        env: {
          HOME: root.home,
          FX_DISABLE_KEYCHAIN: "1",
          FX_AUTO_UPGRADE: "0",
          FX_SKIP_ONBOARDING: "1",
          FX_SOUND: "0",
          AI_GATEWAY_API_KEY: "local-fixture-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_MODEL: MODEL,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 15_000,
      });
      expect(result.code).toBe(0);
      expect(hits).toBeGreaterThan(0);
      expect(gateway.requests.length).toBe(2);
      expect(gateway.requests[1]!.body).not.toContain("authentication_required");
    } finally {
      failing.stop(true);
    }
  }, 20_000);

  test("MongoDB-like session-required discovery falls back to legacy initialize", async () => {
    fixture = startModernMcpHttpFixture("legacy_session_required");
    const root = createRoot("mongodb-legacy-fallback", fixture);

    const result = await runFx(
      ["mcp", "list", "--connect"],
      {
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
      },
    );

    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    expect(result.stdout).toMatch(/fixture[\s\S]{0,240}state=ready/);
    expect(result.stdout).toContain("protocol=2025-11-25");
    expect(result.stdout).toContain(
      "negotiated_name=mongodb-managed-fixture negotiated_version=1.0.0",
    );
    expect(result.stdout).toContain("tools=1");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
    ]);
  }, 25_000);

  test("GitMCP-like plain-text discovery error falls back to legacy initialize", async () => {
    fixture = startModernMcpHttpFixture("legacy_plaintext_session_required");
    const root = createRoot("gitmcp-legacy-fallback", fixture);

    const result = await runFx(
      ["mcp", "list", "--connect"],
      {
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
      },
    );

    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    expect(result.stdout).toMatch(/fixture[\s\S]{0,240}state=ready/);
    expect(result.stdout).toContain("protocol=2025-03-26");
    expect(result.stdout).toContain(
      "negotiated_name=gitmcp-fixture negotiated_version=1.0.0",
    );
    expect(result.stdout).toContain("tools=1");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
    ]);
  }, 25_000);

  test("plain-text discovery auth rejection fails closed without aborting fx", async () => {
    fixture = startModernMcpHttpFixture("legacy_plaintext_auth_rejection");
    const root = createRoot("plaintext-auth-rejection", fixture);

    const result = await runFx(
      ["mcp", "list", "--connect"],
      {
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
      },
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toMatch(/fixture[\s\S]{0,240}auth=required/);
    expect(result.stdout).not.toContain("InvalidJsonResponse");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
    ]);
  }, 25_000);

  test("top-level mcp add persists HTTP and a later ask calls it", async () => {
    fixture = startModernMcpHttpFixture("json");
    const root = createEmptyRoot("top-level-add");
    const added = await runFx(
      ["mcp", "add", "--transport", "http", "fixture", fixture.url],
      {
        cwd: root.workspace,
        env: {
          HOME: root.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
        },
      },
    );
    expect(added.code).toBe(0);
    expect(added.stdout).toContain("Saved MCP server 'fixture'");
    expect(fixture.requests).toHaveLength(0);

    gateway = startFakeGateway([
      fakeGatewayToolCall("top_level_select", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("top_level_call", TOOL_NAME, { text: "hello" }),
      fakeGatewayFinalText("TOP_LEVEL_HTTP_MCP_READY"),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the HTTP MCP echo tool."],
      { cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 20_000 },
    );
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("TOP_LEVEL_HTTP_MCP_READY");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "tools/list",
      "tools/call",
    ]);
  }, 25_000);

  for (
    const responseType of ["json", "sse"] as const satisfies readonly ContentLengthResponseType[]
  ) {
    test(`fixed-length ${responseType} responses complete on one-shot connections`, async () => {
      contentLengthFixture = await startContentLengthMcpHttpFixture(responseType);
      const root = createRoot(`content-length-${responseType}`, contentLengthFixture);
      gateway = startToolGateway(`Fixed-length ${responseType} complete.`);

      const result = await runFx(
        [
          "ask",
          "--json",
          "--auto",
          "--no-save",
          `Call the fixed-length ${responseType} fixture.`,
        ],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, gateway),
          timeoutMs: 20_000,
        },
      );

      if (result.code !== 0) {
        const signal = result.signal ?? "none";
        throw new Error(
          `fixed-length ${responseType} failed signal=${signal} ` +
            `stderr=${JSON.stringify(result.stderr)}`,
        );
      }
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain(
        `Fixed-length ${responseType} complete.`,
      );
      expect(contentLengthFixture.failure).toBeUndefined();
      expect(
        contentLengthFixture.requests.map((entry) => entry.message.method),
      ).toEqual(["server/discover", "tools/list", "tools/call"]);
      for (const request of contentLengthFixture.requests) {
        expect(request.headers.connection).toBe("close");
      }
    }, 30_000);
  }

  test.skipIf(!tmuxAvailable())(
    "/mcp add --transport http persists and reloads a remote server",
    async () => {
      fixture = startModernMcpHttpFixture("json");
      const root = createEmptyRoot("add-command");
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 150,
        height: 36,
        stderrPath,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText(
        `/mcp add --transport http prisma ${fixture.url}`,
      );
      const saved = await tui.waitForText("Saved MCP server 'prisma'.", 10_000);
      expect(saved).toContain("MCP reconnection started");
      await tui.waitForText("MCP configuration reloaded successfully.", 15_000);
      await tui.sendText("/mcp list");
      const health = await tui.waitForText("MCP health (1 server):", 10_000);
      expect(health).toMatch(/prisma[\s\S]{0,240}transport=http state=ready/);
      expect(health).toContain(
        "negotiated_name=modern-http-fixture negotiated_version=unavailable protocol=2026-07-28",
      );

      const profile = JSON.parse(
        readFileSync(join(root.home, ".fx", "mcp.json"), "utf8"),
      );
      expect(profile.mcp.prisma).toMatchObject({
        type: "http",
        url: fixture.url,
        enabled: true,
      });
      expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
        "server/discover",
        "tools/list",
      ]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    30_000,
  );

  test("resource list-change storms coalesce to one complete refresh", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("feature-update-storm", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("storm_resource_list_initial", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await fixture!.waitForSubscription();
        fixture!.stormResourceListChanges(25);
        await Bun.sleep(50);
        return fakeGatewayToolCall("storm_resource_list_refreshed", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      fakeGatewayFinalText("Resource storm coalesced."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Refresh after the MCP resource update storm."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    expect(fixture.resourcesListCalls).toBe(4);
  }, 30_000);

  test("failed feature refresh retains stale snapshot and retries with a bound", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("feature-failed-refresh", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("failed_resource_list_initial", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await fixture!.waitForSubscription();
        fixture!.failNextResourceRefresh();
        await Bun.sleep(25);
        return fakeGatewayToolCall("failed_resource_list_stale", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      fakeGatewayToolCall("failed_resource_list_bounded", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await Bun.sleep(250);
        return fakeGatewayToolCall("failed_resource_list_recovered", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      fakeGatewayFinalText("Feature refresh recovered."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Recover the failed MCP resource refresh."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    expect(fixture.resourcesListCalls).toBe(5);
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies.match(/custom:\/\/alpha/g)?.length).toBeGreaterThanOrEqual(4);
    const trace = readFileSync(root.traceLogPath, "utf8");
    expect(trace).toContain("feature cache refresh failed server=fixture feature=resources");
    expect(trace).toContain("feature cache snapshot replaced server=fixture feature=resources");
  }, 30_000);

  test("feature catalog TTL expiry refreshes the complete paginated snapshot", async () => {
    fixture = startModernMcpHttpFixture("features_ttl_expiry");
    const root = createRoot("feature-ttl-expiry", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("ttl_resource_list_one", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await Bun.sleep(50);
        return fakeGatewayToolCall("ttl_resource_list_two", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      fakeGatewayFinalText("Feature TTL refresh complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Refresh the expired MCP resource catalog."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    const pages = fixture.requests.filter((entry) =>
      entry.message.method === "resources/list"
    );
    expect(pages).toHaveLength(4);
    expect(pages.map((entry) => entry.message.params?.cursor)).toEqual([
      undefined,
      "",
      undefined,
      "",
    ]);
  }, 30_000);

  test("removed resource and prompt identities fail before transport send", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("removed-feature-identities", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("removed_resource_list", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("removed_prompt_list", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("removed_resource_seed", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      async () => {
        fixture!.removeFeatureIdentities();
        await Bun.sleep(50);
        return fakeGatewayToolCall("removed_resource_read", "mcp_features", {
          action: "resource_read",
          server: "fixture",
          uri: "custom://alpha",
        });
      },
      fakeGatewayToolCall("removed_prompt_get", "mcp_features", {
        action: "prompt_get",
        server: "fixture",
        prompt: "review",
        arguments: { tone: "brief" },
      }),
      fakeGatewayFinalText("Removed identities rejected."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Try the removed MCP identities."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies).toContain("McpResourceNotFound");
    expect(bodies).toContain("McpPromptNotFound");
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "resources/read"
    )).toHaveLength(1);
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "prompts/get"
    )).toHaveLength(0);
  }, 30_000);

  test("RFC 6570 matches reach resource reads and near misses are rejected before send", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("resource-template-near-miss", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("template_catalog", "mcp_features", {
        action: "resource_templates",
        server: "fixture",
      }),
      fakeGatewayToolCall("template_match", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "db:///users/records/7",
      }),
      fakeGatewayToolCall("template_near_miss", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "db:///anything",
      }),
      fakeGatewayFinalText("Template near miss rejected."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Reject the invalid MCP resource template match."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    preserveHttpFailure("resource-template-near-miss", root, result, fixture, gateway);
    expect(result.code).toBe(0);
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies).toContain("db:///{table}/records/{id}");
    expect(bodies).toContain("HTTP_RESOURCE_TEXT");
    expect(bodies).toContain("McpResourceNotFound");
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "resources/read"
    ).map((entry) => entry.message.params?.uri)).toEqual([
      "db:///users/records/7",
    ]);
  }, 30_000);

  test("deep feature metadata is rejected without crashing the fresh binary", async () => {
    fixture = startModernMcpHttpFixture("features_deep_nesting");
    const root = createRoot("feature-deep-nesting", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("deep_resource_list", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayFinalText("Deep feature metadata rejected."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Read the deeply nested MCP catalog."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests.map((request) => request.body).join("\n")).toContain(
      "JsonDepthLimitExceeded",
    );
    expect(fixture.resourcesListCalls).toBe(1);
  }, 30_000);

  test("private resource caches isolate servers and URIs with identical credentials", async () => {
    fixture = startModernMcpHttpFixture("features", "FIRST_SERVER_RESOURCE");
    const second = startModernMcpHttpFixture("features", "SECOND_SERVER_RESOURCE");
    try {
      const root = createRoot("private-server-isolation", fixture);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      profile.mcp.fixture.bearer_token_env = "FX_TEST_SHARED_MCP_TOKEN";
      profile.mcp.second = { ...profile.mcp.fixture, url: second.url };
      writeFileSync(profilePath, JSON.stringify(profile));
      const calls = [
        ["first_read", "fixture", "FIRST_SERVER_RESOURCE", "custom://alpha"],
        ["second_read", "second", "SECOND_SERVER_RESOURCE", "custom://alpha"],
        ["first_beta", "fixture", "FIRST_SERVER_RESOURCE", "custom://beta"],
        ["second_beta", "second", "SECOND_SERVER_RESOURCE", "custom://beta"],
        ["first_cached", "fixture", "FIRST_SERVER_RESOURCE", "custom://alpha"],
        ["second_cached", "second", "SECOND_SERVER_RESOURCE", "custom://alpha"],
        ["first_beta_cached", "fixture", "FIRST_SERVER_RESOURCE", "custom://beta"],
        ["second_beta_cached", "second", "SECOND_SERVER_RESOURCE", "custom://beta"],
      ];
      gateway = startFakeGateway([
        ...calls.map(([id, server, , uri]) => fakeGatewayToolCall(id, "mcp_features", {
          action: "resource_read", server, uri,
        })),
        fakeGatewayFinalText("Private resource caches stayed separate."),
      ], { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the same resource on both configured servers twice."],
        { cwd: root.workspace, env: { ...fixtureEnv(root, gateway), FX_TEST_SHARED_MCP_TOKEN: "shared-fixture-token" }, timeoutMs: 25_000 },
      );
      preserveHttpFailure("private-server-isolation", root, result, fixture, gateway);
      expect(result.code).toBe(0);
      expect(gateway.requests).toHaveLength(calls.length + 1);
      const finalRequest = gateway.requests.at(-1)!.body;
      for (const [id, , expected, uri] of calls) {
        const text = toolResultText(finalRequest, id);
        expect(text).toContain(expected);
        expect(JSON.parse(text).contents[0].uri).toBe(uri);
        expect(text).not.toContain(expected === "FIRST_SERVER_RESOURCE" ? "SECOND_SERVER_RESOURCE" : "FIRST_SERVER_RESOURCE");
      }
      for (const source of [fixture, second]) {
        const reads = source.requests.filter((entry) => entry.message.method === "resources/read");
        // Watching beta replaces the subscription and expires alpha; the final beta read stays cached.
        expect(reads.map((entry) => entry.message.params?.uri)).toEqual(["custom://alpha", "custom://beta", "custom://alpha"]);
        expect(reads[0].headers.authorization).toBe("Bearer shared-fixture-token");
      }
    } finally {
      second.stop();
    }
  }, 30_000);

  test("typed Resources Prompts Completion and resource updates use modern HTTP", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("features", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("http_resource_list", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("http_resource_read_one", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      async () => {
        const deadline = Date.now() + 5_000;
        while (!fixture!.subscriptionActive && Date.now() < deadline) {
          await Bun.sleep(5);
        }
        fixture!.invalidateResource("custom://alpha");
        await Bun.sleep(50);
        return fakeGatewayToolCall("http_resource_read_two", "mcp_features", {
          action: "resource_read",
          server: "fixture",
          uri: "custom://alpha",
        });
      },
      fakeGatewayToolCall("http_prompt_list", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("http_prompt_get", "mcp_features", {
        action: "prompt_get",
        server: "fixture",
        prompt: "review",
        arguments: { tone: "brief" },
      }),
      fakeGatewayToolCall("http_prompt_complete", "mcp_features", {
        action: "prompt_complete",
        server: "fixture",
        prompt: "review",
        argument: "tone",
        value: "b",
      }),
      fakeGatewayFinalText("Modern HTTP MCP features complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the modern HTTP MCP resource and prompt features."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Modern HTTP MCP features complete.",
    );
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies).toContain('\\"trust\\":\\"untrusted_external\\"');
    expect(bodies).toContain("HTTP_RESOURCE_TEXT");
    expect(bodies).toContain("HTTP_PROMPT_TEXT");
    const resourceReads = fixture.requests.filter((entry) =>
      entry.message.method === "resources/read"
    );
    expect(resourceReads).toHaveLength(2);
    for (const entry of resourceReads) {
      expect(entry.headers["mcp-name"]).toBe("custom://alpha");
    }
    const promptGet = fixture.requests.find((entry) =>
      entry.message.method === "prompts/get"
    );
    expect(promptGet?.headers["mcp-name"]).toBe("review");
    for (const entry of fixture.requests.filter((request) =>
      ["resources/list", "prompts/list"].includes(request.message.method)
    )) {
      expect(entry.headers["mcp-name"]).toBeUndefined();
    }
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "completion/complete"
    )).toHaveLength(1);
    const listen = fixture.requests.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    );
    expect(listen.length).toBeGreaterThanOrEqual(2);
    expect(listen.at(-1)?.message.params?.notifications).toMatchObject({
      toolsListChanged: true,
      resourcesListChanged: true,
      promptsListChanged: true,
      resourceSubscriptions: ["custom://alpha"],
    });
    expect(readFileSync(root.traceLogPath, "utf8")).toContain(
      "resource read cache invalidated server=fixture",
    );
  }, 30_000);

  test("stale HTTP resource data never masks a cancelled refresh", async () => {
    fixture = startModernMcpHttpFixture("features_stale_read");
    const root = createRoot("feature-cancel", fixture, 200);
    gateway = startFakeGateway([
      fakeGatewayToolCall("http_resource_stale_seed", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://stall",
      }),
      fakeGatewayToolCall("http_resource_stall", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://stall",
      }),
      fakeGatewayFinalText("Modern HTTP resource cancellation complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Read the stalled HTTP MCP resource."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Modern HTTP resource cancellation complete.",
    );
    expect(fixture.cancelledCalls).toBeGreaterThanOrEqual(1);
    expect(fixture.requests.some((entry) =>
      entry.message.method === "resources/read" &&
      entry.message.params?.uri === "custom://stall"
    )).toBe(true);
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "resources/read" &&
      entry.message.params?.uri === "custom://stall"
    )).toHaveLength(2);
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies).toContain("HTTP_RESOURCE_TEXT");
    const cancelled = toolResultText(
      gateway.requests.at(-1)!.body,
      "http_resource_stall",
      "error-text",
    );
    expect(cancelled).toContain("tool_execution_failed");
    expect(cancelled).not.toContain("HTTP_RESOURCE_TEXT");
  }, 30_000);

  test("stalled HTTP completion is deadline-cancelled", async () => {
    fixture = startModernMcpHttpFixture("features");
    const root = createRoot("completion-cancel", fixture, 200);
    gateway = startFakeGateway([
      fakeGatewayToolCall("http_completion_stall", "mcp_features", {
        action: "prompt_complete",
        server: "fixture",
        prompt: "review",
        argument: "tone",
        value: "stall",
      }),
      fakeGatewayFinalText("Modern HTTP completion cancellation complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Complete the stalled HTTP MCP prompt argument."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );
    expect(result.code).toBe(0);
    expect(fixture.cancelledCalls).toBeGreaterThanOrEqual(1);
    expect(fixture.requests.some((entry) =>
      entry.message.method === "completion/complete" &&
      entry.message.params?.argument?.value === "stall"
    )).toBe(true);
  }, 30_000);

  test("live Tools subscription coalesces a storm and atomically exposes the changed tool", async () => {
    fixture = startModernMcpHttpFixture("cache_subscription");
    const root = createRoot("cache-subscription", fixture);
    const freshTool = "mcp_fixture_fresh";
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_subscription", "capability_search", {
        query: "echo",
      }),
      async () => {
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_fresh", "capability_search", {
          query: "fresh",
        });
      },
      fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
        name: freshTool,
      }),
      fakeGatewayToolCall("call_fresh", freshTool, { text: "changed" }),
      fakeGatewayFinalText("Live cache refresh complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the live MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Live cache refresh complete.",
    );
    expect(fixture.currentToolName).toBe("fresh");
    expect(fixture.toolsListCalls).toBe(2);
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    )).toHaveLength(1);
    const toolCalls = fixture.requests.filter((entry) =>
      entry.message.method === "tools/call"
    );
    expect(toolCalls).toHaveLength(1);
    expect(toolCalls[0]?.message.params?.name).toBe("fresh");
    expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
      .toBe(true);
    const trace = readFileSync(root.traceLogPath, "utf8");
    expect(trace).toContain(
      "tool cache snapshot replaced server=fixture catalog_generation=2 tools=1 notifications_seen=10 notifications_coalesced=9",
    );
    const cancellationDeadline = Date.now() + 5_000;
    while (fixture.cancelledCalls === 0 && Date.now() < cancellationDeadline) {
      await Bun.sleep(25);
    }
    expect(fixture.cancelledCalls).toBe(1);
  }, 30_000);

  test("failed subscription refresh retains the last valid stale snapshot", async () => {
    fixture = startModernMcpHttpFixture("cache_failed_refresh");
    const root = createRoot("cache-failed-refresh", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_failed_refresh", "capability_search", {
        query: "echo",
      }),
      async () => {
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_stale", "capability_search", {
          query: "echo",
        });
      },
      fakeGatewayToolCall("select_stale", "mcp_select_tool", {
        name: TOOL_NAME,
      }),
      fakeGatewayToolCall("call_stale", TOOL_NAME, { text: "stale" }),
      fakeGatewayFinalText("Stale cache fallback complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use the stale MCP tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Stale cache fallback complete.",
    );
    const toolsListRequests = fixture.requests.filter((entry) =>
      entry.message.method === "tools/list"
    );
    expect(toolsListRequests.length).toBeGreaterThanOrEqual(2);
    expect(toolsListRequests.length).toBeLessThanOrEqual(3);
    expect(new Set(toolsListRequests.map((entry) => entry.message.id)).size)
      .toBe(toolsListRequests.length);
    expect(gateway.requests.some((entry) => entry.body.includes(TOOL_NAME)))
      .toBe(true);
    const trace = readFileSync(root.traceLogPath, "utf8");
    expect(trace).toContain(
      "tool cache refresh failed server=fixture freshness=failed_refresh",
    );
    expect(trace.match(
      /tool cache refresh failed server=fixture freshness=failed_refresh/g,
    )?.length ?? 0).toBe(toolsListRequests.length - 1);
    expect(result.stderr).not.toContain("Bearer");
  }, 30_000);

  test("partial subscription acknowledgement closes the listener and falls back to TTL", async () => {
    fixture = startModernMcpHttpFixture("cache_partial_ack");
    const root = createRoot("cache-partial-ack", fixture);
    let callsAfterFirstSearch = 0;
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_partial_ack", "capability_search", {
        query: "echo",
      }),
      async () => {
        callsAfterFirstSearch = fixture!.toolsListCalls;
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_after_ttl", "capability_search", {
          query: "echo",
        });
      },
      fakeGatewayFinalText("TTL fallback complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use TTL after the unsupported filter."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(callsAfterFirstSearch).toBeGreaterThanOrEqual(1);
    expect(fixture.toolsListCalls).toBe(callsAfterFirstSearch + 1);
    expect(fixture.cancelledCalls).toBe(1);
    expect(readFileSync(root.traceLogPath, "utf8")).toContain(
      "tool subscription filter unsupported",
    );
  }, 30_000);

  test("server subscription cancellation is traced before TTL fallback", async () => {
    fixture = startModernMcpHttpFixture("cache_server_cancel");
    const root = createRoot("cache-server-cancel", fixture);
    let callsAfterFirstSearch = 0;
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_server_cancel", "capability_search", {
        query: "echo",
      }),
      async () => {
        callsAfterFirstSearch = fixture!.toolsListCalls;
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_after_server_cancel", "capability_search", {
          query: "echo",
        });
      },
      fakeGatewayFinalText("Server cancellation TTL fallback complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use TTL after server cancellation."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(callsAfterFirstSearch).toBeGreaterThanOrEqual(1);
    expect(fixture.toolsListCalls).toBe(callsAfterFirstSearch + 1);
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    )).toHaveLength(1);
    expect(fixture.cancelledCalls).toBe(1);
    expect(readFileSync(root.traceLogPath, "utf8")).toContain(
      "tool subscription cancelled by server",
    );
  }, 30_000);

  test("unexpected subscription acknowledgement filter closes once and falls back to TTL", async () => {
    fixture = startModernMcpHttpFixture("cache_unexpected_ack");
    const root = createRoot("cache-unexpected-ack", fixture);
    let callsAfterFirstSearch = 0;
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_unexpected_ack", "capability_search", {
        query: "echo",
      }),
      async () => {
        callsAfterFirstSearch = fixture!.toolsListCalls;
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_after_unexpected_ack", "capability_search", {
          query: "echo",
        });
      },
      fakeGatewayFinalText("Unexpected acknowledgement TTL fallback complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use TTL after the unexpected filter."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(callsAfterFirstSearch).toBeGreaterThanOrEqual(1);
    expect(fixture.toolsListCalls).toBe(callsAfterFirstSearch + 1);
    expect(fixture.requests.filter((entry) =>
      entry.message.method === "subscriptions/listen"
    )).toHaveLength(1);
    expect(fixture.cancelledCalls).toBe(1);
    expect(readFileSync(root.traceLogPath, "utf8")).toContain(
      "tool subscription filter unsupported",
    );
  }, 30_000);

  test("list invalidation before send rejects the frozen old tool", async () => {
    fixture = startModernMcpHttpFixture("cache_invalidate_before_send");
    const root = createRoot("cache-invalidate-before-send", fixture);
    const freshTool = "mcp_fixture_fresh";
    gateway = startFakeGateway([
      fakeGatewayToolCall("select_old", "mcp_select_tool", {
        name: TOOL_NAME,
      }),
      async () => {
        await fixture!.waitForSubscription();
        fixture!.invalidateTools();
        await Bun.sleep(100);
        return fakeGatewayToolCall("call_old", TOOL_NAME, { text: "old" });
      },
      fakeGatewayToolCall("search_fresh", "capability_search", {
        query: "fresh",
      }),
      fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
        name: freshTool,
      }),
      fakeGatewayToolCall("call_fresh", freshTool, { text: "new" }),
      fakeGatewayFinalText("Pre-send invalidation complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Do not send the invalidated tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const calls = fixture.requests.filter((entry) =>
      entry.message.method === "tools/call"
    );
    expect(calls).toHaveLength(1);
    expect(calls[0]?.message.params?.name).toBe("fresh");
    expect(fixture.toolsListCalls).toBe(2);
    expect(toolResultText(gateway.requests[2]!.body, "call_old", "error-text")).toContain("before execution");
    expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
      .toBe(true);
    const trace = readFileSync(root.traceLogPath, "utf8");
    expect(
      trace.match(/tool cache snapshot replaced server=fixture/g) ?? [],
    ).toHaveLength(1);
  }, 30_000);

  for (
    const cacheCase of [
      { mode: "cache_fresh", delayMs: 0, expectedLists: 1 },
      { mode: "cache_ttl_zero", delayMs: 0, expectedLists: 2 },
      { mode: "cache_ttl_negative", delayMs: 0, expectedLists: 2 },
      { mode: "cache_ttl_expiry", delayMs: 100, expectedLists: 2 },
    ] as const
  ) {
    test(`${cacheCase.mode} uses the expected Tools cache snapshot`, async () => {
      fixture = startModernMcpHttpFixture(cacheCase.mode);
      const root = createRoot(cacheCase.mode, fixture);
      gateway = startFakeGateway([
        fakeGatewayToolCall("activate_cache", "capability_search", {
          query: "echo",
        }),
        ...(cacheCase.delayMs > 0
          ? [async () => {
              await Bun.sleep(cacheCase.delayMs);
              return fakeGatewayToolCall("search_cache", "capability_search", {
                query: "echo",
              });
            }]
          : []),
        fakeGatewayFinalText("Cache timing observed."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Search the MCP cache."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, gateway),
          timeoutMs: 20_000,
        },
      );

      preserveHttpFailure(
        cacheCase.mode,
        root,
        result,
        fixture,
        gateway,
        fixture.toolsListCalls !== cacheCase.expectedLists,
      );
      expect(result.code).toBe(0);
      expect(fixture.toolsListCalls).toBe(cacheCase.expectedLists);
      const trace = readFileSync(root.traceLogPath, "utf8");
      expect(trace).toContain(
        cacheCase.mode === "cache_fresh"
          ? "tool cache decision server=fixture action=hit freshness=fresh catalog_generation=1"
          : "tool cache refreshed without schema change server=fixture catalog_generation=1",
      );
    }, 30_000);
  }

  test("delayed pagination preserves the first page absolute expiry", async () => {
    fixture = startModernMcpHttpFixture("cache_delayed_pagination");
    const root = createRoot("cache-delayed-pagination", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_delayed_catalog", "capability_search", {
        query: "second",
      }),
      fakeGatewayFinalText("Delayed pagination expiry observed."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Search the delayed MCP catalog."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(fixture.toolsListCalls).toBe(4);
    expect(fixture.toolPageResponses.map((page) => page.cursor)).toEqual([
      undefined,
      "p2",
      undefined,
      "p2",
    ]);
    expect(
      fixture.toolPageResponses[1]!.sentAtMs -
        fixture.toolPageResponses[0]!.sentAtMs,
    ).toBeGreaterThanOrEqual(200);
    expect(
      fixture.toolPageResponses[3]!.sentAtMs -
        fixture.toolPageResponses[2]!.sentAtMs,
    ).toBeGreaterThanOrEqual(200);
    const trace = readFileSync(root.traceLogPath, "utf8");
    const timing = trace.match(
      /tool cache refreshed without schema change server=fixture catalog_generation=1 fetched_at_ms=(\d+) expiry_ms=(\d+)/,
    );
    expect(timing).not.toBeNull();
    expect(Number(timing![2]) - Number(timing![1])).toBe(100);
  }, 30_000);

  test("empty nextCursor is transmitted unchanged and completes pagination", async () => {
    fixture = startModernMcpHttpFixture("cache_empty_cursor");
    const root = createRoot("cache-empty-cursor", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_empty_cursor_catalog", "capability_search", {
        query: "second",
      }),
      fakeGatewayFinalText("Empty cursor pagination complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Search the empty-cursor MCP catalog."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    const pages = fixture.requests.filter((entry) =>
      entry.message.method === "tools/list"
    );
    expect(pages).toHaveLength(2);
    expect(pages[0]?.message.params?.cursor).toBeUndefined();
    expect(pages[1]?.message.params?.cursor).toBe("");
  }, 30_000);

  for (const mode of ["json", "sse"] as ModernHttpMode[]) {
    test(`fresh fx ask calls the request-scoped ${mode.toUpperCase()} fixture`, async () => {
      fixture = startModernMcpHttpFixture(mode);
      const root = createRoot(`ask-${mode}`, fixture);
      gateway = startToolGateway(`${mode} MCP HTTP complete.`);

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", `Call the ${mode} HTTP fixture.`],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, gateway),
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain(
        `${mode} MCP HTTP complete.`,
      );
      expect(gateway.requests[2]?.body).toContain(
        `${MODERN_HTTP_TOOL_RESULT}:hello`,
      );
      assertModernWire(fixture);
    }, 30_000);
  }

  test("fresh fx ask delegates unsupported input and output schema assertions", async () => {
    fixture = startModernMcpHttpFixture("server_authoritative_schema");
    const root = createRoot("server-authoritative-schema", fixture, 5_000, true);
    gateway = startToolGateway("Server-authoritative schema complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the schema fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    preserveHttpFailure(
      "server-authoritative-schema",
      root,
      result,
      fixture,
      gateway,
    );
    expect(JSON.parse(result.stdout).output).toContain(
      "Server-authoritative schema complete.",
    );
    expect(gateway.requests[2]?.body).toContain(
      `${MODERN_HTTP_TOOL_RESULT}:hello`,
    );
    expect(gateway.requests.some((request) =>
      request.body.includes('"pattern":"^(?!blocked$).+$"')
    )).toBe(true);
    expect(fixture.requests[2]?.message.params?.arguments).toEqual({
      text: "hello",
    });
    expect(readFileSync(root.traceLogPath, "utf8")).not.toContain(
      "connection failed for server fixture: InvalidSchema",
    );
    assertModernWire(fixture);
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "the TUI resumes a modern HTTP operation after validated form elicitation",
    async () => {
      fixture = startModernMcpHttpFixture("mrtr_form");
      const root = createRoot("tui-mrtr-form", fixture);
      gateway = startToolGateway("HTTP form elicitation complete.");
      const stderrPath = join(root.root, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 110,
        height: 32,
        stderrPath,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the HTTP MCP fixture.");
      await tui.waitForText("MCP server fixture requests confirmed", 20_000);
      await tui.sendKeys("1");
      await tui.waitForText(
        "Review the completed form requested by MCP server fixture",
        20_000,
      );
      await tui.sendKeys("1");
      await tui.waitForText("HTTP form elicitation complete.", 20_000);

      const calls = fixture.requests.filter((entry) =>
        entry.message.method === "tools/call"
      );
      expect(calls).toHaveLength(2);
      expect(calls[1]?.message.id).not.toBe(calls[0]?.message.id);
      expect(calls[1]?.message.params?.name).toBe(calls[0]?.message.params?.name);
      expect(calls[1]?.message.params?.arguments).toEqual(
        calls[0]?.message.params?.arguments,
      );
      expect(calls[1]?.message.params?.inputResponses).toEqual({
        confirm: { action: "accept", content: { confirmed: true } },
      });
      expect(calls[1]?.message.params?.requestState).toEqual({
        transport: "http",
        opaque: true,
      });
      expect(calls[0]?.message.params?._meta?.[
        "io.modelcontextprotocol/clientCapabilities"
      ]).toEqual({ elicitation: { form: {}, url: {} } });
      expect(calls[1]?.message.params?._meta?.[
        "io.modelcontextprotocol/clientCapabilities"
      ]).toEqual({ elicitation: { form: {}, url: {} } });
      expect(gateway.requests[2]?.body).toContain(
        "HTTP continued after elicitation",
      );
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    30_000,
  );

  test("mixed SSE delimiters complete across chunks without waiting for EOF", async () => {
    fixture = startModernMcpHttpFixture("sse_mixed_delimiters");
    const root = createRoot("mixed-sse-delimiters", fixture, 1_000);
    gateway = startToolGateway("Mixed SSE delimiters complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the mixed SSE fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Mixed SSE delimiters complete.",
    );
    expect(gateway.requests[2]?.body).toContain(
      `${MODERN_HTTP_TOOL_RESULT}:hello`,
    );
    const deadline = Date.now() + 5_000;
    while (fixture.cancelledCalls === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(fixture.cancelledCalls).toBe(1);
  }, 30_000);

  test("environment-backed headers and bearer references reach modern HTTP", async () => {
    fixture = startModernMcpHttpFixture("json");
    const root = createRoot("environment-headers", fixture);
    writeFileSync(
      join(root.home, ".fx", "mcp.json"),
      JSON.stringify({
        mcp: {
          fixture: {
            type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
            url: fixture.url,
            header_env: { "X-Workspace": "MCP_WORKSPACE" },
            bearer_token_env: "MCP_BEARER_TOKEN",
          },
        },
      }),
    );
    gateway = startToolGateway("Environment-backed MCP complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the environment-backed fixture."],
      {
        cwd: root.workspace,
        env: {
          ...fixtureEnv(root, gateway),
          MCP_WORKSPACE: "environment-workspace",
          MCP_BEARER_TOKEN: "environment-bearer-secret",
        },
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(fixture.requests).toHaveLength(3);
    for (const request of fixture.requests) {
      expect(request.headers["x-workspace"]).toBe("environment-workspace");
      expect(request.headers.authorization).toBe(
        "Bearer environment-bearer-secret",
      );
    }
    expect(result.stdout).not.toContain("environment-bearer-secret");
    expect(result.stderr).not.toContain("environment-bearer-secret");
    expect(readFileSync(join(root.home, ".fx", "mcp.json"), "utf8")).not
      .toContain("environment-bearer-secret");
  }, 30_000);

  test("workspace MCP expands static HTTP headers without changing profile syntax", async () => {
    fixture = startModernMcpHttpFixture("json");
    const root = createRoot("workspace-expanded-headers", fixture);
    writeFileSync(
      join(root.home, ".fx", "mcp.json"),
      JSON.stringify({ mcp: {} }),
    );
    writeFileSync(
      join(root.workspace, ".mcp.json"),
      JSON.stringify({
        mcpServers: {
          fixture: {
            type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
            url: fixture.url,
            headers: {
              Authorization: "Bearer ${WORKSPACE_HTTP_TOKEN}",
              "X-Workspace": "${WORKSPACE_HTTP_NAME:-project-default}",
            },
          },
        },
      }),
    );
    gateway = startToolGateway("Workspace-expanded HTTP MCP complete.");
    const env = {
      ...fixtureEnv(root, gateway),
      WORKSPACE_HTTP_TOKEN: "workspace-http-secret",
    };
    const trusted = await runFx(
      ["mcp", "trust", "approve", "fixture"],
      { cwd: root.workspace, env },
    );
    expect(trusted.code).toBe(0);

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the workspace HTTP fixture."],
      {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(fixture.requests).toHaveLength(3);
    for (const request of fixture.requests) {
      expect(request.headers.authorization).toBe("Bearer workspace-http-secret");
      expect(request.headers["x-workspace"]).toBe("project-default");
    }
    expect(result.stdout).not.toContain("workspace-http-secret");
    expect(result.stderr).not.toContain("workspace-http-secret");
  }, 30_000);

  test("modern HTTP excludes tools with invalid header projection schemas", async () => {
    fixture = startModernMcpHttpFixture("invalid_header_schema");
    const root = createRoot("invalid-header-schema", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("inspect_invalid_schema", "capability_search", {
        query: "echo",
      }),
      fakeGatewayFinalText("Invalid modern schema isolated."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Do not call the invalid tool."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests.every((request) => !request.body.includes(TOOL_NAME)))
      .toBe(true);
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "tools/list",
    ]);
  }, 30_000);

  test("matching final SSE response closes a held-open response body", async () => {
    fixture = startModernMcpHttpFixture("held_open_final");
    const root = createRoot("held-open-final", fixture, 1_000);
    gateway = startToolGateway("Held-open SSE complete.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the held-open HTTP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Held-open SSE complete.",
    );
    expect(gateway.requests[2]?.body).toContain(
      `${MODERN_HTTP_TOOL_RESULT}:hello`,
    );
    assertModernWire(fixture);
    const deadline = Date.now() + 5_000;
    while (fixture.cancelledCalls === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(fixture.cancelledCalls).toBe(1);
  }, 30_000);

  test("operation timeout closes a stalled request-scoped SSE response", async () => {
    fixture = startModernMcpHttpFixture("stall_call");
    const root = createRoot("timeout", fixture, 100);
    gateway = startToolGateway("HTTP timeout recovered.");

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the stalled HTTP fixture."],
      {
        cwd: root.workspace,
        env: fixtureEnv(root, gateway),
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain("McpRequestTimedOut");
    const deadline = Date.now() + 5_000;
    while (fixture.cancelledCalls === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(fixture.cancelledCalls).toBe(1);
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "TUI cancellation closes the in-flight HTTP response",
    async () => {
      fixture = startModernMcpHttpFixture("stall_call");
      const root = createRoot("cancel", fixture, 30_000);
      gateway = startToolGateway("Cancelled HTTP MCP complete.");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the stalled HTTP fixture.");
      const callDeadline = Date.now() + 15_000;
      while (
        !fixture.requests.some((entry) => entry.message.method === "tools/call") &&
        Date.now() < callDeadline
      ) {
        await Bun.sleep(25);
      }
      expect(
        fixture.requests.some((entry) => entry.message.method === "tools/call"),
      ).toBe(true);

      await tui.sendKeys("Escape");
      await tui.waitForText(`Cancelled ${TOOL_NAME}`, 10_000);
      const cancelDeadline = Date.now() + 5_000;
      while (fixture.cancelledCalls === 0 && Date.now() < cancelDeadline) {
        await Bun.sleep(25);
      }
      expect(fixture.cancelledCalls).toBe(1);
    },
    40_000,
  );

});
