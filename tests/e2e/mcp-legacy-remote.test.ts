import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
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
  LEGACY_REMOTE_TOOL_RESULT,
  LEGACY_SSE_TOOL_RESULT,
  startLegacyHttpSseFixture,
  startLegacyStreamableHttpFixture,
  type LegacyStreamableVersion,
} from "./fixtures/mcp-legacy-remote";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const REPO_ROOT = realpathSync(join(import.meta.dirname, "..", ".."));
const VERSIONS: LegacyStreamableVersion[] = [
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
];

let cleanupRoot: string | null = null;
let streamable: ReturnType<typeof startLegacyStreamableHttpFixture> | null = null;
let legacySse: ReturnType<typeof startLegacyHttpSseFixture> | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeStreamable = streamable;
  const activeLegacySse = legacySse;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  streamable = null;
  legacySse = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  activeStreamable?.stop();
  activeLegacySse?.stop();
  if (activeCleanupRoot) {
    rmSync(activeCleanupRoot, { recursive: true, force: true });
  }
});

function createRoot(
  label: string,
  transport: "http" | "sse",
  url: string,
  operationTimeoutMs = 5_000,
  remoteOverrides: Record<string, unknown> = {},
) {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), `fx-mcp-legacy-${label}-`)),
  );
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
          type: transport,
          url,
          headers: { "X-Workspace": "legacy" },
          startup_timeout_ms: 5_000,
          operation_timeout_ms: operationTimeoutMs,
          ...remoteOverrides,
        },
      },
    }),
  );
  return { root, home, workspace, traceLogPath: join(root, "fx-trace.log") };
}

function fixtureEnv(
  root: ReturnType<typeof createRoot>,
  activeGateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-mcp-legacy-key",
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

async function runAsk(
  root: ReturnType<typeof createRoot>,
  activeGateway: ReturnType<typeof startFakeGateway>,
  prompt: string,
  extraEnv: Record<string, string> = {},
) {
  return runFx(
    ["ask", "--json", "--auto", "--no-save", prompt],
    {
      cwd: root.workspace,
      env: {
        ...fixtureEnv(root, activeGateway),
        ...extraEnv,
      },
      timeoutMs: 20_000,
    },
  );
}

function preserveLegacyFailure(
  label: string,
  root: ReturnType<typeof createRoot>,
  result: Awaited<ReturnType<typeof runAsk>>,
  activeFixture: ReturnType<typeof startLegacyHttpSseFixture>,
  activeGateway: ReturnType<typeof startFakeGateway>,
): void {
  cleanupRoot = null;
  writeFileSync(join(root.root, "fx-stdout.log"), result.stdout);
  writeFileSync(join(root.root, "fx-stderr.log"), result.stderr);
  writeFileSync(
    join(root.root, "failure.json"),
    JSON.stringify({
      label,
      result,
      fixtureRequests: activeFixture.requests,
      discoveryGets: activeFixture.discoveryGets,
      toolsListCalls: activeFixture.toolsListCalls,
      streamCancelled: activeFixture.streamCancelled,
      gatewayRequests: activeGateway.requests.map((request) => request.body),
    }, null, 2),
  );
  throw new Error(`fx ${label} failed; retained artifacts: ${root.root}`);
}

describe("version-scoped legacy MCP remote transports", () => {
  for (const sdkDiscoveryError of [
    "uninitialized",
    "unsupported-version",
  ] as const) {
    test(`stock SDK ${sdkDiscoveryError} discovery error falls back to Streamable HTTP initialization`, async () => {
      streamable = startLegacyStreamableHttpFixture("2025-11-25", {
        sdkDiscoveryError,
      });
      const root = createRoot(`sdk-discovery-${sdkDiscoveryError}`, "http", streamable.url);
      gateway = startToolGateway("Stock SDK fallback complete.");

      const result = await runAsk(root, gateway, "Use the legacy MCP tool.");

      expect(result.code).toBe(0);
      expect(streamable.initializeCalls).toBe(1);
      expect(streamable.toolsListCalls).toBe(1);
      expect(streamable.toolCallCalls).toBe(1);
      const discovery = streamable.requests.find((entry) =>
        entry.message?.method === "server/discover"
      );
      expect(discovery).toBeDefined();
      expect(discovery?.headers["mcp-protocol-version"]).toBe("2026-07-28");
      const initialize = streamable.requests.find((entry) =>
        entry.message?.method === "initialize"
      );
      expect(initialize?.message?.params?.protocolVersion).toBe("2025-11-25");
    }, 30_000);
  }

  test.skipIf(!tmuxAvailable())(
    "legacy list-change health reports an installed listener and lazy feature counts truthfully",
    async () => {
      streamable = startLegacyStreamableHttpFixture("2025-11-25", {
        listChanged: true,
        features: true,
        sdkDiscoveryError: "uninitialized",
      });
      const root = createRoot("legacy-health", "http", streamable.url);
      gateway = startFakeGateway([fakeGatewayFinalText("unused")], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 160,
        height: 34,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("/mcp list");
      const pane = await tui.waitForText("MCP health (1 server)", 10_000);
      expect(pane).toContain("protocol=2025-11-25");
      expect(pane).toContain(
        "tools=1 resources=unknown templates=unknown prompts=unknown",
      );
      expect(pane).toContain("subscription=active");
      expect(gateway.requests).toHaveLength(0);
    },
    30_000,
  );

  test("legacy Streamable HTTP uses typed feature flows and existing list-change listener", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      listChanged: true,
      features: true,
    });
    const root = createRoot("features", "http", streamable.url);
    gateway = startFakeGateway([
      fakeGatewayToolCall("legacy_resource_list_one", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await Bun.sleep(200);
        return fakeGatewayToolCall("legacy_resource_list_two", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      fakeGatewayToolCall("legacy_resource_read", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "legacy://alpha",
      }),
      fakeGatewayToolCall("legacy_prompt_list", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("legacy_prompt_get", "mcp_features", {
        action: "prompt_get",
        server: "fixture",
        prompt: "review",
        arguments: { tone: "brief" },
      }),
      fakeGatewayToolCall("legacy_prompt_complete", "mcp_features", {
        action: "prompt_complete",
        server: "fixture",
        prompt: "review",
        argument: "tone",
        value: "b",
      }),
      fakeGatewayFinalText("Legacy MCP features complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runAsk(root, gateway, "Use the legacy MCP features.");

    expect(result.code).toBe(0);
    expect(streamable.resourcesListCalls).toBe(2);
    expect(streamable.requests.some((entry) =>
      entry.message?.method === "subscriptions/listen"
    )).toBe(false);
    const bodies = gateway.requests.map((entry) => entry.body).join("\n");
    expect(bodies).toContain("legacy-alpha-fresh");
    expect(bodies).toContain("LEGACY_RESOURCE_TEXT");
    expect(bodies).toContain("LEGACY_PROMPT_TEXT");
    expect(bodies).toContain('\\"trust\\":\\"untrusted_external\\"');
    expect(streamable.requests.filter((entry) =>
      entry.message?.method === "resources/read"
    )).toHaveLength(1);
    expect(streamable.requests.filter((entry) =>
      entry.message?.method === "completion/complete"
    )).toHaveLength(1);
  }, 30_000);

  for (const version of VERSIONS) {
    test(`Streamable HTTP ${version} refreshes Tools from its GET listener without reconnect`, async () => {
      streamable = startLegacyStreamableHttpFixture(version, {
        listChanged: true,
      });
      const root = createRoot(`list-changed-${version}`, "http", streamable.url);
      const freshTool = "mcp_fixture_fresh";
      gateway = startFakeGateway([
        fakeGatewayToolCall("activate_listener", "mcp_search_tools", {
          query: "echo",
        }),
        async () => {
          await Bun.sleep(100);
          return fakeGatewayToolCall("search_fresh", "mcp_search_tools", {
            query: "fresh",
          });
        },
        fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
          name: freshTool,
        }),
        fakeGatewayToolCall("call_fresh", freshTool, { text: "changed" }),
        fakeGatewayFinalText(`${version} live refresh complete.`),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runAsk(root, gateway, "Use the changed legacy tool.");

      expect(result.code).toBe(0);
      expect(streamable.currentToolName).toBe("fresh");
      expect(streamable.toolsListCalls).toBe(2);
      expect(streamable.initializeCalls).toBe(1);
      expect(streamable.resumeCalls).toBe(1);
      expect(streamable.requests.some((entry) =>
        entry.message?.method === "subscriptions/listen"
      )).toBe(false);
      const toolCalls = streamable.requests.filter((entry) =>
        entry.message?.method === "tools/call"
      );
      expect(toolCalls).toHaveLength(1);
      expect(toolCalls[0]?.message?.params?.name).toBe("fresh");
      expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
        .toBe(true);
      const listener = streamable.requests.find((entry) =>
        entry.httpMethod === "GET"
      )!;
      expect(listener.headers["mcp-session-id"]).toBe(`session-${version}`);
      expect(listener.headers.accept).toBe("text/event-stream");
      if (version === "2025-03-26") {
        expect(listener.headers["mcp-protocol-version"]).toBeUndefined();
      } else {
        expect(listener.headers["mcp-protocol-version"]).toBe(version);
      }
      const deadline = Date.now() + 5_000;
      while (
        streamable.listenerCancellations === 0 && Date.now() < deadline
      ) {
        await Bun.sleep(25);
      }
      expect(streamable.listenerCancellations).toBe(1);
      expect(streamable.deleteCalls).toBe(1);
    }, 30_000);
  }

  test("deprecated HTTP+SSE routes live Tools changes through its existing reader", async () => {
    legacySse = startLegacyHttpSseFixture({ listChanged: true });
    const root = createRoot("sse-list-changed", "sse", legacySse.url);
    const freshTool = "mcp_fixture_fresh";
    gateway = startFakeGateway([
      fakeGatewayToolCall("activate_sse_reader", "mcp_search_tools", {
        query: "echo",
      }),
      async () => {
        await Bun.sleep(100);
        return fakeGatewayToolCall("search_fresh", "mcp_search_tools", {
          query: "fresh",
        });
      },
      fakeGatewayToolCall("select_fresh", "mcp_select_tool", {
        name: freshTool,
      }),
      fakeGatewayToolCall("call_fresh", freshTool, { text: "changed" }),
      fakeGatewayFinalText("HTTP+SSE live refresh complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runAsk(root, gateway, "Use the changed SSE tool.");

    expect(result.code).toBe(0);
    expect(legacySse.currentToolName).toBe("fresh");
    expect(legacySse.toolsListCalls).toBe(2);
    expect(legacySse.discoveryGets).toBe(1);
    expect(legacySse.requests.some((entry) =>
      entry.message?.method === "subscriptions/listen"
    )).toBe(false);
    const toolCalls = legacySse.requests.filter((entry) =>
      entry.message?.method === "tools/call"
    );
    expect(toolCalls).toHaveLength(1);
    expect(toolCalls[0]?.message?.params?.name).toBe("fresh");
    expect(gateway.requests.some((entry) => entry.body.includes(freshTool)))
      .toBe(true);
    const deadline = Date.now() + 5_000;
    while (legacySse.streamCancelled === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(legacySse.streamCancelled).toBe(1);
  }, 30_000);

  for (const version of VERSIONS) {
    test(`fresh fx ask calls Streamable HTTP ${version} with its lifecycle headers`, async () => {
      streamable = startLegacyStreamableHttpFixture(version);
      const root = createRoot(`ask-${version}`, "http", streamable.url);
      gateway = startToolGateway(`${version} complete.`);

      const result = await runAsk(root, gateway, `Call the ${version} fixture.`);

      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain(`${version} complete.`);
      expect(gateway.requests[2]?.body).toContain(
        `${LEGACY_REMOTE_TOOL_RESULT}:hello`,
      );
      const messages = streamable.requests
        .filter((entry) => entry.message)
        .map((entry) => entry.message!.method);
      expect(messages).toEqual([
        "server/discover",
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/call",
      ]);
      const initialize = streamable.requests.find(
        (entry) => entry.message?.method === "initialize",
      )!;
      expect(initialize.headers["mcp-protocol-version"]).toBeUndefined();
      expect(initialize.headers["mcp-session-id"]).toBeUndefined();
      for (
        const entry of streamable.requests.filter((candidate) =>
          candidate.message &&
          candidate.message.method !== "server/discover" &&
          candidate.message.method !== "initialize"
        )
      ) {
        expect(entry.headers["mcp-session-id"]).toBe(`session-${version}`);
        if (version === "2025-03-26") {
          expect(entry.headers["mcp-protocol-version"]).toBeUndefined();
        } else {
          expect(entry.headers["mcp-protocol-version"]).toBe(version);
        }
        expect(entry.headers["x-workspace"]).toBe("legacy");
      }
      expect(streamable.deleteCalls).toBe(1);
    }, 30_000);

    test(`Streamable HTTP ${version} resumes by GET without replaying tools/call`, async () => {
      streamable = startLegacyStreamableHttpFixture(version, { mode: "resume" });
      const root = createRoot(`resume-${version}`, "http", streamable.url);
      gateway = startToolGateway(`${version} resumed.`);

      const result = await runAsk(root, gateway, `Resume the ${version} fixture.`);

      expect(result.code).toBe(0);
      expect(gateway.requests[2]?.body).toContain(
        `${LEGACY_REMOTE_TOOL_RESULT}:resumed`,
      );
      expect(
        streamable.requests.filter(
          (entry) => entry.message?.method === "tools/call",
        ),
      ).toHaveLength(1);
      const resumed = streamable.requests.find(
        (entry) => entry.httpMethod === "GET",
      )!;
      expect(resumed.headers["last-event-id"]).toBe("call-event-1");
      expect(resumed.headers["mcp-session-id"]).toBe(`session-${version}`);
      if (version === "2025-03-26") {
        expect(resumed.headers["mcp-protocol-version"]).toBeUndefined();
      } else {
        expect(resumed.headers["mcp-protocol-version"]).toBe(version);
      }
      expect(streamable.resumeCalls).toBe(1);
    }, 30_000);
  }

  test("Streamable HTTP accepts an omitted session and skips DELETE", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      session: false,
    });
    const root = createRoot("no-session", "http", streamable.url);
    gateway = startToolGateway("No session complete.");

    const result = await runAsk(root, gateway, "Call the no-session fixture.");

    expect(result.code).toBe(0);
    expect(streamable.deleteCalls).toBe(0);
    for (const entry of streamable.requests) {
      expect(entry.headers["mcp-session-id"]).toBeUndefined();
    }
  }, 30_000);

  test("legacy Streamable HTTP completes mixed delimiters without waiting for EOF", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      mode: "mixed_delimiters",
    });
    const root = createRoot("legacy-mixed-delimiters", "http", streamable.url, 1_000);
    gateway = startToolGateway("Legacy mixed delimiters complete.");

    const result = await runAsk(root, gateway, "Call the mixed delimiter fixture.");

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain(
      `${LEGACY_REMOTE_TOOL_RESULT}:hello`,
    );
    const deadline = Date.now() + 5_000;
    while (streamable.cancelledCalls === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(streamable.cancelledCalls).toBe(1);
  }, 30_000);

  test("legacy Streamable HTTP rejects unsafe resumption IDs before GET", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      mode: "unsafe_resume_id",
    });
    const root = createRoot("unsafe-resume-id", "http", streamable.url);
    gateway = startToolGateway("Unsafe resumption ID rejected.");

    const result = await runAsk(root, gateway, "Call the unsafe resumption fixture.");

    expect(result.code).toBe(0);
    expect(streamable.toolCallCalls).toBe(1);
    expect(streamable.resumeCalls).toBe(0);
    expect(gateway.requests[2]?.body).toContain("InvalidHeaderValue");
  }, 30_000);

  test("Streamable HTTP releases local session state when DELETE is unsupported", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      deleteStatus: 405,
    });
    const root = createRoot("delete-unsupported", "http", streamable.url);
    gateway = startToolGateway("DELETE unsupported complete.");

    const result = await runAsk(root, gateway, "Call the DELETE fixture.");

    expect(result.code).toBe(0);
    expect(streamable.deleteCalls).toBe(1);
  }, 30_000);

  test("Streamable HTTP 2025-11-25 polling resumes after an empty priming event", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-11-25", {
      mode: "poll",
    });
    const root = createRoot("poll", "http", streamable.url);
    gateway = startToolGateway("Polling complete.");

    const result = await runAsk(root, gateway, "Call the polling fixture.");

    expect(result.code).toBe(0);
    expect(streamable.resumeCalls).toBe(1);
    const resumed = streamable.requests.find(
      (entry) => entry.httpMethod === "GET",
    )!;
    expect(resumed.headers["last-event-id"]).toBe("");
  }, 30_000);

  for (const operation of ["tools", "resources", "prompts"] as const) {
    test.skipIf(!tmuxAvailable())(
      `Streamable HTTP 2025-11-25 ${operation} retries only after the matching URL completion`,
      async () => {
        let targetRequests = 0;
        const target = Bun.serve({
          port: 0,
          fetch() {
            targetRequests += 1;
            return new Response("browser-only target");
          },
        });
        try {
          const targetUrl = `http://127.0.0.1:${target.port}/authorize?state=legacy-http`;
          streamable = startLegacyStreamableHttpFixture("2025-11-25", {
            mode: "url_required_error",
            elicitationUrl: targetUrl,
            urlRequiredOperation: operation,
            features: operation !== "tools",
          });
          const root = createRoot(`url-required-${operation}`, "http", streamable.url);
          const fakeBin = join(root.root, "fake-bin");
          const openLog = join(root.root, "open.log");
          mkdirSync(fakeBin);
          for (const name of ["open", "xdg-open"]) {
            const openPath = join(fakeBin, name);
            writeFileSync(
              openPath,
              "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FX_E2E_OPEN_LOG\"\nexit 0\n",
            );
            chmodSync(openPath, 0o755);
          }
          gateway = startFakeGateway([
            ...(operation === "tools"
              ? [
                  fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
                  fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
                ]
              : operation === "resources"
              ? [
                  fakeGatewayToolCall("legacy_resource_list", "mcp_features", {
                    action: "resource_list",
                    server: "fixture",
                  }),
                  fakeGatewayToolCall("legacy_resource_read", "mcp_features", {
                    action: "resource_read",
                    server: "fixture",
                    uri: "legacy://alpha",
                  }),
                ]
              : [
                  fakeGatewayToolCall("legacy_prompt_list", "mcp_features", {
                    action: "prompt_list",
                    server: "fixture",
                  }),
                  fakeGatewayToolCall("legacy_prompt_get", "mcp_features", {
                    action: "prompt_get",
                    server: "fixture",
                    prompt: "review",
                    arguments: { tone: "brief" },
                  }),
                ]),
            fakeGatewayFinalText(`Legacy HTTP ${operation} URL-required complete.`),
          ], {
            models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
          });
          const binary = join(REPO_ROOT, "zig-out", "bin", "fx");
          tui = await TmuxSession.create({
            isolated: true,
            cwd: root.workspace,
            width: 110,
            height: 34,
            cmd: `${JSON.stringify(binary)} ask --auto --no-save ${JSON.stringify("Call the legacy HTTP URL-required fixture.")}`,
            remainOnExit: true,
            env: {
              ...fixtureEnv(root, gateway),
              PATH: `${fakeBin}:${process.env.PATH ?? ""}`,
              FX_E2E_OPEN_LOG: openLog,
            },
          });

          await tui.waitForText(`Complete URL: ${targetUrl}`, 20_000);
          await tui.sendText("1");
          await tui.waitForText("I completed it / Retry", 20_000);
          const method = operation === "tools"
            ? "tools/call"
            : operation === "resources"
            ? "resources/read"
            : "prompts/get";
          const operationCalls = () => streamable!.requests.filter(
            (entry) => entry.message?.method === method,
          );
          expect(operationCalls()).toHaveLength(1);
          if (operation === "tools") {
            const malformed = [
              {
                method: "notifications/elicitation/complete",
                params: { elicitationId: "legacy-url-required-1" },
              },
              {
                jsonrpc: "1.0",
                method: "notifications/elicitation/complete",
                params: { elicitationId: "legacy-url-required-1" },
              },
              {
                jsonrpc: 2,
                method: "notifications/elicitation/complete",
                params: { elicitationId: "legacy-url-required-1" },
              },
              {
                jsonrpc: "2.0",
                method: "notifications/elicitation/completed",
                params: { elicitationId: "legacy-url-required-1" },
              },
              {
                jsonrpc: "2.0",
                method: "notifications/elicitation/complete",
                params: [],
              },
              {
                jsonrpc: "2.0",
                method: "notifications/elicitation/complete",
                params: { elicitationId: false },
              },
              {
                jsonrpc: "2.0",
                method: "notifications/elicitation/complete",
                params: { elicitationId: "" },
              },
              {
                jsonrpc: "2.0",
                method: "notifications/elicitation/complete",
                params: { elicitationId: "x".repeat(257) },
              },
            ];
            for (const notification of malformed) {
              streamable.sendUrlCompletionFrame(notification);
            }
          }
          streamable.sendUrlCompletion("wrong-url-id");
          await Bun.sleep(100);
          expect(operationCalls()).toHaveLength(1);
          streamable.sendUrlCompletion("legacy-url-required-1");
          streamable.sendUrlCompletion("legacy-url-required-1");
          await tui.waitForText(`Legacy HTTP ${operation} URL-required complete.`, 20_000);
          expect(readFileSync(openLog, "utf8").trim()).toBe(targetUrl);
          expect(targetRequests).toBe(0);
          const calls = streamable.requests.filter(
            (entry) => entry.message?.method === method,
          );
          expect(calls).toHaveLength(2);
          expect(calls[1]?.message?.id).not.toBe(calls[0]?.message?.id);
          expect(calls[1]?.message?.params?.inputResponses).toBeUndefined();
          expect(calls[1]?.message?.params?.requestState).toBeUndefined();
        } finally {
          target.stop(true);
        }
      },
      30_000,
    );
  }

  test("Streamable HTTP 2025-06-18 does not interpret the 2025-11 URL-required error", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      mode: "url_required_error",
      elicitationUrl: "https://example.test/unsupported-version",
    });
    const root = createRoot("url-required-version-gate", "http", streamable.url);
    gateway = startToolGateway("Legacy HTTP URL-required version gate complete.");

    const result = await runAsk(root, gateway, "Call the version-gated legacy fixture.");

    expect(result.code).toBe(0);
    expect(streamable.toolCallCalls).toBe(1);
    expect(gateway.requests[2]?.body).toContain("MCP protocol error -32042");
  }, 30_000);

  test("Streamable HTTP completes a final POST event without waiting for stream EOF", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      mode: "hold_open_call",
    });
    const root = createRoot("held-open-post", "http", streamable.url, 1_000);
    gateway = startToolGateway("Held-open POST complete.");

    const result = await runAsk(root, gateway, "Call the held-open fixture.");

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain(
      `${LEGACY_REMOTE_TOOL_RESULT}:hello`,
    );
    expect(streamable.toolCallCalls).toBe(1);
    const deadline = Date.now() + 5_000;
    while (streamable.cancelledCalls === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(streamable.cancelledCalls).toBe(1);
  }, 30_000);

  test("Streamable HTTP reinitializes an expired session without replaying the failed call", async () => {
    const version = "2025-06-18";
    streamable = startLegacyStreamableHttpFixture(version, {
      mode: "expire_session",
    });
    const root = createRoot(
      "expired-session",
      "http",
      streamable.url,
      5_000,
      {
        headers: {},
        header_env: { "X-Workspace": "MCP_LEGACY_WORKSPACE" },
        bearer_token_env: "MCP_LEGACY_BEARER",
      },
    );
    gateway = startFakeGateway([
      fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
      fakeGatewayToolCall("expired_call", TOOL_NAME, { text: "expired" }),
      fakeGatewayToolCall("recovered_call", TOOL_NAME, { text: "recovered" }),
      fakeGatewayFinalText("Session recovery complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runAsk(
      root,
      gateway,
      "Recover the expired session.",
      {
        MCP_LEGACY_WORKSPACE: "legacy-recovery-environment",
        MCP_LEGACY_BEARER: "legacy-recovery-secret",
      },
    );

    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toContain(
      "Session recovery complete.",
    );
    expect(gateway.requests[2]?.body).toContain("tool_execution_failed");
    expect(gateway.requests[3]?.body).toContain(
      `${LEGACY_REMOTE_TOOL_RESULT}:recovered`,
    );
    expect(streamable.initializeCalls).toBe(2);
    expect(streamable.toolCallCalls).toBe(2);
    const calls = streamable.requests.filter(
      (entry) => entry.message?.method === "tools/call",
    );
    expect(calls).toHaveLength(2);
    expect(calls[0]?.headers["mcp-session-id"]).toBe(
      `session-${version}-1`,
    );
    expect(calls[1]?.headers["mcp-session-id"]).toBe(
      `session-${version}-2`,
    );
    const reinitialize = streamable.requests.filter(
      (entry) => entry.message?.method === "initialize",
    )[1]!;
    expect(reinitialize.headers["mcp-session-id"]).toBeUndefined();
    for (const request of streamable.requests) {
      expect(request.headers["x-workspace"]).toBe(
        "legacy-recovery-environment",
      );
      expect(request.headers.authorization).toBe(
        "Bearer legacy-recovery-secret",
      );
    }
    expect(result.stdout).not.toContain("legacy-recovery-secret");
    expect(result.stderr).not.toContain("legacy-recovery-secret");
    expect(streamable.deleteCalls).toBe(1);
  }, 30_000);

  test("legacy Streamable HTTP keeps tools rejected by modern header projection", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      invalidModernHeaderSchema: true,
    });
    const root = createRoot("legacy-schema-isolation", "http", streamable.url);
    gateway = startToolGateway("Legacy schema isolation complete.");

    const result = await runAsk(
      root,
      gateway,
      "Call the legacy schema isolation fixture.",
    );

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain(
      `${LEGACY_REMOTE_TOOL_RESULT}:hello`,
    );
    expect(streamable.toolCallCalls).toBe(1);
  }, 30_000);

  test("legacy Streamable HTTP captures scope challenges without replaying a tool call", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", {
      rejectToolAuth: true,
    });
    const root = createRoot(
      "legacy-auth-rejection",
      "http",
      streamable.url,
      5_000,
      { oauth: { resource: streamable.url } },
    );
    gateway = startToolGateway("Legacy authentication required.");

    const result = await runAsk(
      root,
      gateway,
      "Call the protected legacy fixture.",
    );

    expect(result.code).toBe(0);
    expect(streamable.toolCallCalls).toBe(1);
    expect(gateway.requests[2]?.body).toContain("tool_execution_failed");
    expect(gateway.requests[2]?.body).toContain("McpAuthenticationRequired");
  }, 30_000);

  test("fresh fx ask uses explicit HTTP+SSE endpoint discovery and message routing", async () => {
    legacySse = startLegacyHttpSseFixture();
    const root = createRoot(
      "sse-ask",
      "sse",
      legacySse.url,
      5_000,
      {
        headers: {},
        header_env: { "X-Workspace": "MCP_SSE_WORKSPACE" },
        bearer_token_env: "MCP_SSE_BEARER",
      },
    );
    gateway = startToolGateway("HTTP+SSE complete.");

    const result = await runAsk(
      root,
      gateway,
      "Call the explicit SSE fixture.",
      {
        MCP_SSE_WORKSPACE: "sse-environment",
        MCP_SSE_BEARER: "sse-bearer-secret",
      },
    );

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain(
      `${LEGACY_SSE_TOOL_RESULT}:hello`,
    );
    expect(legacySse.discoveryGets).toBe(1);
    expect(
      legacySse.requests.filter((entry) => entry.httpMethod === "POST")
        .map((entry) => entry.path),
    ).toEqual(["/messages", "/messages", "/messages", "/messages"]);
    expect(
      legacySse.requests.filter((entry) => entry.message)
        .map((entry) => entry.message!.method),
    ).toEqual([
      "initialize",
      "notifications/initialized",
      "tools/list",
      "tools/call",
    ]);
    for (const request of legacySse.requests) {
      expect(request.headers["x-workspace"]).toBe("sse-environment");
      expect(request.headers.authorization).toBe("Bearer sse-bearer-secret");
    }
    expect(result.stdout).not.toContain("sse-bearer-secret");
    expect(result.stderr).not.toContain("sse-bearer-secret");
    const deadline = Date.now() + 5_000;
    while (legacySse.streamCancelled === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(legacySse.streamCancelled).toBe(1);
  }, 30_000);

  test("HTTP+SSE captures scope challenges without replaying a tool call", async () => {
    legacySse = startLegacyHttpSseFixture({ rejectToolAuth: true });
    const root = createRoot(
      "sse-auth-rejection",
      "sse",
      legacySse.url,
      5_000,
      { oauth: { resource: legacySse.url } },
    );
    gateway = startToolGateway("HTTP+SSE authentication required.");

    const result = await runAsk(
      root,
      gateway,
      "Call the protected explicit SSE fixture.",
    );

    expect(result.code).toBe(0);
    expect(
      legacySse.requests.filter(
        (request) => request.message?.method === "tools/call",
      ),
    ).toHaveLength(1);
    expect(gateway.requests[2]?.body).toContain("tool_execution_failed");
    expect(gateway.requests[2]?.body).toContain("McpAuthenticationRequired");
  }, 30_000);

  test("HTTP+SSE routes bare-CR events without waiting for LF", async () => {
    legacySse = startLegacyHttpSseFixture({ bareCr: true });
    const root = createRoot("sse-bare-cr", "sse", legacySse.url, 1_000);
    gateway = startToolGateway("HTTP+SSE bare CR complete.");

    const result = await runAsk(root, gateway, "Call the bare-CR SSE fixture.");

    if (
      result.code !== 0 ||
      !gateway.requests[2]?.body.includes(`${LEGACY_SSE_TOOL_RESULT}:hello`)
    ) {
      preserveLegacyFailure("legacy-sse-bare-cr", root, result, legacySse, gateway);
    }

    expect(result.code).toBe(0);
    expect(gateway.requests[2]?.body).toContain(
      `${LEGACY_SSE_TOOL_RESULT}:hello`,
    );
    expect(legacySse.discoveryGets).toBe(1);
    const deadline = Date.now() + 5_000;
    while (legacySse.streamCancelled === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(legacySse.streamCancelled).toBe(1);
  }, 30_000);

  for (const selectedVersion of [null, "2025-03-26"] as const) {
    const label = selectedVersion ?? "missing";
    test(`HTTP+SSE rejects ${label} initialize version and closes discovery`, async () => {
      legacySse = startLegacyHttpSseFixture({
        protocolVersion: selectedVersion,
      });
      const root = createRoot(`sse-version-${label}`, "sse", legacySse.url);
      gateway = startFakeGateway([
        fakeGatewayToolCall("inspect_invalid_sse", "mcp_search_tools", {
          query: "echo",
        }),
        fakeGatewayFinalText("Invalid SSE version isolated."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runAsk(
        root,
        gateway,
        "Do not use the invalid SSE fixture.",
      );

      expect(result.code).toBe(0);
      expect(gateway.requests.every((request) => !request.body.includes(TOOL_NAME)))
        .toBe(true);
      expect(
        legacySse.requests.filter((entry) => entry.message)
          .map((entry) => entry.message!.method),
      ).toEqual(["initialize"]);
      const deadline = Date.now() + 5_000;
      while (legacySse.streamCancelled === 0 && Date.now() < deadline) {
        await Bun.sleep(25);
      }
      expect(legacySse.streamCancelled).toBe(1);
    }, 30_000);
  }

  test("HTTP+SSE cleans up when discovery is followed by a malformed message", async () => {
    legacySse = startLegacyHttpSseFixture({ malformedAfterEndpoint: true });
    const root = createRoot(
      "sse-malformed-after-endpoint",
      "sse",
      legacySse.url,
    );
    gateway = startFakeGateway([
      fakeGatewayToolCall("inspect_malformed_sse", "mcp_search_tools", {
        query: "echo",
      }),
      fakeGatewayFinalText("Malformed SSE startup isolated."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runAsk(
      root,
      gateway,
      "Do not use the malformed SSE fixture.",
    );

    expect(result.code).toBe(0);
    expect(gateway.requests.every((request) => !request.body.includes(TOOL_NAME)))
      .toBe(true);
    const deadline = Date.now() + 5_000;
    while (legacySse.streamCancelled === 0 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(legacySse.streamCancelled).toBe(1);
  }, 30_000);

  for (const version of VERSIONS) {
    test.skipIf(!tmuxAvailable())(
      `TUI cancellation sends ${version} cancellation headers and cleans up`,
      async () => {
        streamable = startLegacyStreamableHttpFixture(version, {
          mode: "stall_call",
        });
        const root = createRoot(
          `cancel-http-${version}`,
          "http",
          streamable.url,
          30_000,
        );
        gateway = startToolGateway("Cancelled legacy HTTP complete.");
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          width: 100,
          height: 30,
          env: fixtureEnv(root, gateway),
        });

        await tui.waitForComposer(15_000);
        await tui.sendText("Call the stalled legacy HTTP fixture.");
        const callDeadline = Date.now() + 15_000;
        while (
          !streamable.requests.some(
            (entry) => entry.message?.method === "tools/call",
          ) &&
          Date.now() < callDeadline
        ) {
          await Bun.sleep(25);
        }
        expect(
          streamable.requests.some(
            (entry) => entry.message?.method === "tools/call",
          ),
        ).toBe(true);

        await tui.sendKeys("Escape");
        await tui.waitForText(`Cancelled ${TOOL_NAME}`, 10_000);
        const cancelDeadline = Date.now() + 5_000;
        while (
          (streamable.cancellationNotifications === 0 ||
            streamable.cancelledCalls === 0) &&
          Date.now() < cancelDeadline
        ) {
          await Bun.sleep(25);
        }
        const cancellation = streamable.requests.find(
          (entry) => entry.message?.method === "notifications/cancelled",
        )!;
        expect(cancellation.headers["mcp-session-id"]).toBe(
          `session-${version}`,
        );
        if (version === "2025-03-26") {
          expect(cancellation.headers["mcp-protocol-version"]).toBeUndefined();
        } else {
          expect(cancellation.headers["mcp-protocol-version"]).toBe(version);
        }
        expect(streamable.cancellationNotifications).toBe(1);
        expect(streamable.cancelledCalls).toBe(1);

        await tui.waitForComposer(10_000);
        await tui.sendText("/quit");
        await tui.waitForSessionEnd(10_000);
        tui = null;
        expect(streamable.deleteCalls).toBe(1);
      },
      40_000,
    );
  }

  test.skipIf(!tmuxAvailable())(
    "TUI cancellation routes HTTP+SSE cancellation to the discovered message endpoint",
    async () => {
      legacySse = startLegacyHttpSseFixture({ stallCall: true });
      const root = createRoot("cancel-sse", "sse", legacySse.url, 30_000);
      gateway = startToolGateway("Cancelled HTTP+SSE complete.");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        env: fixtureEnv(root, gateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Call the stalled explicit SSE fixture.");
      const callDeadline = Date.now() + 15_000;
      while (
        !legacySse.requests.some(
          (entry) => entry.message?.method === "tools/call",
        ) &&
        Date.now() < callDeadline
      ) {
        await Bun.sleep(25);
      }
      await tui.sendKeys("Escape");
      await tui.waitForText(`Cancelled ${TOOL_NAME}`, 10_000);
      const cancelDeadline = Date.now() + 5_000;
      while (
        legacySse.cancellationNotifications === 0 &&
        Date.now() < cancelDeadline
      ) {
        await Bun.sleep(25);
      }
      expect(legacySse.cancellationNotifications).toBe(1);
      expect(
        legacySse.requests.find(
          (entry) => entry.message?.method === "notifications/cancelled",
        )?.path,
      ).toBe("/messages");
    },
    40_000,
  );
});
