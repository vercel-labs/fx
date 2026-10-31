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
import { startIdleDropProxy, type IdleDrop } from "./fixtures/idle-drop-proxy";
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
let proxy: Awaited<ReturnType<typeof startIdleDropProxy>> | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeFixture = fixture;
  const activeContentLengthFixture = contentLengthFixture;
  const activeProxy = proxy;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  fixture = null;
  contentLengthFixture = null;
  proxy = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  activeProxy?.stop();
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
          type: "http",
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
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: activeGateway.baseUrl,
    FX_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: activeGateway.chatUrl,
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
  // The listen for list changes is its own request, so it may land before
  // or after tools/list.
  const methods = activeFixture.requests.map((entry) => entry.message.method);
  expect(methods.filter((method) => method !== "subscriptions/listen")).toEqual([
    "server/discover",
    "tools/list",
    "tools/call",
  ]);
  expect(methods[0]).toBe("server/discover");
  expect(methods.filter((method) => method === "subscriptions/listen")).toHaveLength(1);
  expect(activeFixture.httpMethods).toEqual(methods.map(() => "POST"));
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
  const call = activeFixture.requests.find((entry) => entry.message.method === "tools/call")!;
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
          type: "http",
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
          FX_TEST_SKIP_ONBOARDING: "1",
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
      ["mcp", "show", "fixture"],
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
    expect(result.stdout).toContain("status     ready, 1 tool");
    expect(result.stdout).toContain("version    2025-11-25");
    expect(result.stdout).toContain("echo  MongoDB managed compatibility fixture");
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
      ["mcp", "show", "fixture"],
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
    expect(result.stdout).toContain("status     ready, 1 tool");
    expect(result.stdout).toContain("version    2025-03-26");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
    ]);
  }, 25_000);

  test("a plain-text discovery rejection fails closed without aborting fx", async () => {
    fixture = startModernMcpHttpFixture("legacy_plaintext_auth_rejection");
    const root = createRoot("plaintext-auth-rejection", fixture);

    const result = await runFx(
      ["mcp", "show", "fixture"],
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

    // A 400 with a body that isn't JSON-RPC means a 2025 server (VER-04), so
    // fx tries initialize; that fails too, and the server is left unusable.
    // With no WWW-Authenticate challenge there is no sign-in to offer.
    expect(result.code).toBe(1);
    expect(result.stdout).toContain("status     retrying");
    expect(result.stdout).toContain("error      it refused or never answered fx's initialize request");
    expect(result.stdout + result.stderr).not.toContain("InvalidJsonResponse");
    expect(result.stderr).not.toContain("panic");
    expect(fixture.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
    ]);
  }, 25_000);

  test("top-level mcp add persists HTTP and a later ask calls it", async () => {
    fixture = startModernMcpHttpFixture("json");
    const root = createEmptyRoot("top-level-add");
    const added = await runFx(
      ["mcp", "add", "fixture", fixture.url],
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
    expect(added.stdout).toContain("Added fixture to ~/.fx/mcp.json.");
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
    expect(fixture.requests.map((entry) => entry.message.method).filter((method) => method !== "subscriptions/listen")).toEqual([
      "server/discover",
      "tools/list",
      "tools/call",
    ]);
  }, 25_000);

  for (
    const responseType of ["json", "sse"] as const satisfies readonly ContentLengthResponseType[]
  ) {
    test(`fixed-length ${responseType} responses complete without waiting for the connection to close`, async () => {
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
      // The connection stays open, so each answer ends at its Content-Length;
      // the listen gets the -32601 of a server without subscriptions.
      expect(
        contentLengthFixture.requests.map((entry) => entry.message.method)
          .filter((method) => method !== "subscriptions/listen"),
      ).toEqual(["server/discover", "tools/list", "tools/call"]);
    }, 30_000);
  }

  // A load balancer drops a keep-alive connection once it sits idle, by
  // resetting it or by closing it. fx keeps connections for the next request,
  // so each later call must find its connection gone and go out on a new one,
  // once, instead of failing until fx restarts.
  for (const drop of ["reset", "close"] as const satisfies readonly IdleDrop[]) {
    test(`tool calls after the server ${drop === "reset" ? "reset" : "closed"} an idle connection go through, each once`, async () => {
      contentLengthFixture = await startContentLengthMcpHttpFixture("json");
      proxy = await startIdleDropProxy(contentLengthFixture.url, drop);
      const root = createRoot(`idle-${drop}`, proxy);
      // Each call comes after the proxy dropped every connection fx kept.
      const later = (id: string, text: string) => async () => {
        await Bun.sleep(600);
        return fakeGatewayToolCall(id, TOOL_NAME, { text });
      };
      gateway = startFakeGateway([
        fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
        later("call_one", "one"),
        later("call_two", "two"),
        later("call_three", "three"),
        fakeGatewayFinalText("Idle connections replaced."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the echo tool three times."],
        { cwd: root.workspace, env: fixtureEnv(root, gateway), timeoutMs: 30_000 },
      );

      expect(result.code).toBe(0);
      const last = gateway.requests.at(-1)?.body ?? "";
      for (const [id, text] of [["call_one", "one"], ["call_two", "two"], ["call_three", "three"]]) {
        expect(toolResultText(last, id)).toContain(`${MODERN_HTTP_TOOL_RESULT}:${text}`);
      }
      // None was sent twice.
      expect(
        contentLengthFixture.requests
          .filter((entry) => entry.message.method === "tools/call")
          .map((entry) => entry.message.params?.arguments?.text),
      ).toEqual(["one", "two", "three"]);
      expect(proxy.dropped).toBeGreaterThanOrEqual(3);
    }, 40_000);
  }

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
    const cancellationDeadline = Date.now() + 5_000;
    while (fixture.cancelledListens === 0 && Date.now() < cancellationDeadline) {
      await Bun.sleep(25);
    }
    expect(fixture.cancelledListens).toBe(1);
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
    // A stale list is listed again on each next need (CAT-05), never more:
    // two searches, the select and the call are four needs.
    expect(toolsListRequests.length).toBeGreaterThanOrEqual(2);
    expect(toolsListRequests.length).toBeLessThanOrEqual(4);
    expect(new Set(toolsListRequests.map((entry) => entry.message.id)).size)
      .toBe(toolsListRequests.length);
    // The failed refreshes leave the last good list in use.
    expect(toolResultText(gateway.requests[4]!.body, "call_stale")).toContain(
      `${MODERN_HTTP_TOOL_RESULT}:stale`,
    );
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
    expect(fixture.cancelledListens).toBe(1);
  }, 30_000);

  test("server subscription cancellation falls back to TTL", async () => {
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
    expect(fixture.cancelledListens).toBe(1);
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
    expect(fixture.cancelledListens).toBe(1);
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
    // After list_changed the old tool is gone: fx re-fetches before the
    // call and refuses it unsent (CAT-05). Waits for N31.
    expect(calls.map((entry) => entry.message.params?.name)).toEqual(["fresh"]);
    expect(fixture.toolsListCalls).toBe(2);
    expect(() => toolResultText(gateway.requests[2]!.body, "call_old", "error-text")).not.toThrow();
    expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
      .toBe(true);
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
        // Servers start when first needed, so the first search loads the
        // list; the second shows whether it was kept.
        async () => {
          await Bun.sleep(cacheCase.delayMs);
          return fakeGatewayToolCall("search_cache", "capability_search", {
            query: "echo",
          });
        },
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
    }, 30_000);
  }

  test("delayed pagination preserves the first page absolute expiry", async () => {
    fixture = startModernMcpHttpFixture("cache_delayed_pagination");
    const root = createRoot("cache-delayed-pagination", fixture);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_delayed_catalog", "capability_search", {
        query: "second",
      }),
      // Right after the first list: fresh only if its expiry ran from the
      // last page, not the first (D42).
      fakeGatewayToolCall("search_again", "capability_search", {
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
    expect(fixture.requests.find((entry) => entry.message.method === "tools/call")?.message.params?.arguments).toEqual({
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
      await tui.waitForText("Current values:", 20_000);
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
      expect(calls[1]?.message.params?.requestState).toBe("http-opaque");
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
            type: "http",
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
    // Every request carries the headers, the listen for list changes too.
    expect(fixture.requests.map((entry) => entry.message.method).filter((method) => method !== "subscriptions/listen")).toEqual([
      "server/discover",
      "tools/list",
      "tools/call",
    ]);
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
            type: "http",
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
      ["mcp", "approve", "fixture"],
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
    // Every request carries the headers, the listen for list changes too.
    expect(fixture.requests.map((entry) => entry.message.method).filter((method) => method !== "subscriptions/listen")).toEqual([
      "server/discover",
      "tools/list",
      "tools/call",
    ]);
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
    expect(fixture.requests.map((entry) => entry.message.method).filter((method) => method !== "subscriptions/listen")).toEqual([
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

  test("fx closes a held-open SSE response once its answer arrives", async () => {
    const heldOpen = startModernMcpHttpFixture("held_open_final");
    fixture = heldOpen;
    const root = createRoot("held-open-final-v2", heldOpen, 1_000);
    // While the model answers, fx still runs and holds the tool's result: the
    // stream the server never ended must be closed by then, not at exit.
    let closedWhileRunning = -1;
    gateway = startFakeGateway([
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
      async () => {
        await Bun.sleep(300);
        closedWhileRunning = heldOpen.cancelledCalls;
        return fakeGatewayFinalText("Held-open SSE complete.");
      },
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Call the held-open HTTP fixture."],
      {
        cwd: root.workspace,
        env: { ...fixtureEnv(root, gateway) },
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain("Held-open SSE complete.");
    expect(heldOpen.requests.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
    expect(closedWhileRunning).toBe(1);
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

      await tui.sendInterruptEscapePair(10_000);
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
