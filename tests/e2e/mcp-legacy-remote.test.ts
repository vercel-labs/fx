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
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeStreamable = streamable;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  streamable = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  activeStreamable?.stop();
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

// The result the model got for call `callId`, as JSON text.
function toolResultText(body: string, callId: string): string {
  for (const message of JSON.parse(body).prompt as Array<{ content: unknown }>) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && part.toolCallId === callId) return JSON.stringify(part.output);
    }
  }
  throw new Error(`Missing tool result for ${callId}`);
}

// GETs that resume a stream; the listener is a GET with no event id.
function resumes(fixture: ReturnType<typeof startLegacyStreamableHttpFixture>) {
  return fixture.requests.filter((entry) =>
    entry.httpMethod === "GET" && entry.headers["last-event-id"] !== undefined
  );
}

describe("version-scoped legacy MCP remote transports", () => {
  for (const sdkDiscoveryError of [
    "uninitialized",
    "unsupported-version",
    "unsupported-version-string-id",
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

  for (const version of VERSIONS) {
    test(`Streamable HTTP ${version} refreshes Tools from its GET listener without reconnect`, async () => {
      streamable = startLegacyStreamableHttpFixture(version, {
        listChanged: true,
      });
      const root = createRoot(`list-changed-${version}`, "http", streamable.url);
      const freshTool = "mcp_fixture_fresh";
      gateway = startFakeGateway([
        fakeGatewayToolCall("activate_listener", "capability_search", {
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
      expect(listener.headers["mcp-protocol-version"]).toBe(version);
      const deadline = Date.now() + 5_000;
      while (
        streamable.listenerCancellations === 0 && Date.now() < deadline
      ) {
        await Bun.sleep(25);
      }
      expect(streamable.listenerCancellations).toBe(1);
      // The session's DELETE is skipped at exit (replace-v1 decision 11).
      expect(streamable.deleteCalls).toBe(0);
    }, 30_000);
  }

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
      // fx asks for the 2026 discovery first, then initializes the 2025 way.
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
        // Every later request names the agreed version, 2025-03-26 too.
        expect(entry.headers["mcp-protocol-version"]).toBe(version);
        expect(entry.headers["x-workspace"]).toBe("legacy");
      }
      // fx exits without waiting on servers, so the session's DELETE is
      // skipped at exit (replace-v1 decision 11).
      expect(streamable.deleteCalls).toBe(0);
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
      // The listener is a GET too; the resume is the one naming an event.
      const resumed = streamable.requests.find(
        (entry) => entry.httpMethod === "GET" && entry.headers["last-event-id"] !== undefined,
      )!;
      expect(resumed.headers["last-event-id"]).toBe("call-event-1");
      expect(resumed.headers["mcp-session-id"]).toBe(`session-${version}`);
      expect(resumed.headers["mcp-protocol-version"]).toBe(version);
      expect(streamable.requests.filter((entry) =>
        entry.httpMethod === "GET" && entry.headers["last-event-id"] !== undefined
      )).toHaveLength(1);
    }, 30_000);
  }

  // fx reads at most 16 MiB of one message. Before, an answer over that was
  // treated as a broken stream: fx resumed it twice, getting the same answer
  // each time, then told the model the server went away.
  test("Streamable HTTP ends a call whose answer is over fx's message limit at once, without resuming it", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-06-18", { mode: "oversized_resumable" });
    const root = createRoot("oversized-answer", "http", streamable.url);
    gateway = startToolGateway("Oversized answer handled.");

    const result = await runAsk(root, gateway, "Call the oversized fixture.");

    expect(result.code).toBe(0);
    // What the model was told: the call's error text.
    const told = /MCP server 'fixture' ended the call[^"\\]*/.exec(gateway.requests[2]?.body ?? "")?.[0] ?? "";
    expect(told).toContain("its reply was larger than fx reads in one message, so fx dropped it");
    expect(told).not.toContain("the server went away");
    expect(streamable.requests.filter((entry) => entry.message?.method === "tools/call")).toHaveLength(1);
    expect(streamable.requests.filter((entry) =>
      entry.httpMethod === "GET" && entry.headers["last-event-id"] !== undefined
    )).toHaveLength(0);
  }, 60_000);

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

  test("Clerk-like SSE initialization without a session remains searchable", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-11-25", {
      initializeSse: true,
      sdkDiscoveryError: "unsupported-version",
      session: false,
    });
    const root = createRoot("clerk-like-sse-no-session", "http", streamable.url);
    gateway = startToolGateway("Clerk-like search complete.");

    const result = await runAsk(
      root,
      gateway,
      "Find and call the legacy MCP tool.",
    );

    expect(result.code).toBe(0);
    expect(streamable.initializeCalls).toBe(1);
    expect(streamable.toolsListCalls).toBe(1);
    expect(streamable.toolCallCalls).toBe(1);
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
    expect(toolResultText(gateway.requests[2]!.body, "call_mcp")).toContain(
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
    // The id can't go in a header, so there is no resume, and the call is
    // lost after the server got it.
    expect(resumes(streamable)).toHaveLength(0);
    expect(toolResultText(gateway.requests[2]!.body, "call_mcp")).toContain(
      "MCP server 'fixture' ended the call: the server went away. The tool may have run.",
    );
  }, 30_000);

  test("Streamable HTTP 2025-11-25 can't resume a call whose priming event has no id", async () => {
    streamable = startLegacyStreamableHttpFixture("2025-11-25", {
      mode: "poll",
    });
    const root = createRoot("poll", "http", streamable.url);
    gateway = startToolGateway("Polling complete.");

    const result = await runAsk(root, gateway, "Call the polling fixture.");

    expect(result.code).toBe(0);
    // An empty id leaves nothing to resume from (the SSE standard sends no
    // Last-Event-ID for it), and the answer may only come on the call's own
    // stream, so the call is lost and the model hears it may have run.
    expect(resumes(streamable)).toHaveLength(0);
    expect(toolResultText(gateway.requests[2]!.body, "call_mcp")).toContain(
      "MCP server 'fixture' ended the call: the server went away. The tool may have run.",
    );
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "Streamable HTTP 2025-11-25 tools retries only after the matching URL completion",
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
          urlRequiredOperation: "tools",
        });
        const root = createRoot("url-required-tools", "http", streamable.url);
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
          fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
          fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "hello" }),
          fakeGatewayFinalText("Legacy HTTP tools URL-required complete."),
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
        const method = "tools/call";
        const operationCalls = () => streamable!.requests.filter(
          (entry) => entry.message?.method === method,
        );
        expect(operationCalls()).toHaveLength(1);
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
        streamable.sendUrlCompletion("wrong-url-id");
        await Bun.sleep(100);
        expect(operationCalls()).toHaveLength(1);
        streamable.sendUrlCompletion("legacy-url-required-1");
        streamable.sendUrlCompletion("legacy-url-required-1");
        await tui.waitForText("Legacy HTTP tools URL-required complete.", 20_000);
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

  test("Streamable HTTP reinitializes an expired session and retries the call it refused", async () => {
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
    const calls = streamable.requests.filter(
      (entry) => entry.message?.method === "tools/call",
    );
    expect({
      expired: toolResultText(gateway.requests[2]!.body, "expired_call").includes(`${LEGACY_REMOTE_TOOL_RESULT}:expired`),
      recovered: toolResultText(gateway.requests[3]!.body, "recovered_call").includes(`${LEGACY_REMOTE_TOOL_RESULT}:recovered`),
      initializeCalls: streamable.initializeCalls,
      calls: calls.map((entry) => [entry.message?.params?.arguments?.text, entry.headers["mcp-session-id"], entry.message?.id]),
    }).toEqual({
      expired: true,
      recovered: true,
      initializeCalls: 2,
      // A 404 means the server didn't take the call, so it goes again in the
      // new session (LHTTP-02); the next call uses that session too, after
      // the new session's tools are listed again (id 6, CAT-05).
      calls: [
        ["expired", `session-${version}-1`, 4],
        ["expired", `session-${version}-2`, 4],
        ["recovered", `session-${version}-2`, 7],
      ],
    });
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
    // The session's DELETE is skipped at exit (replace-v1 decision 11).
    expect(streamable.deleteCalls).toBe(0);
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
    // Header projection is a 2026 feature: a 2025 server's tools keep it.
    expect(toolResultText(gateway.requests[2]!.body, "call_mcp")).toContain(
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
    expect(toolResultText(gateway.requests[2]!.body, "call_mcp")).toContain(
      "MCP server 'fixture' needs a login. Ask the user to run fx mcp login fixture in a terminal, then try again.",
    );
  }, 30_000);

  for (const version of VERSIONS) {
    test.skipIf(!tmuxAvailable())(
      `TUI cancellation sends ${version} cancellation headers and quits without a session DELETE`,
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

        await tui.sendInterruptEscapePair(10_000);
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
        // Every later request names the agreed version, 2025-03-26 too.
        expect(cancellation.headers["mcp-protocol-version"]).toBe(version);
        expect(streamable.cancellationNotifications).toBe(1);
        expect(streamable.cancelledCalls).toBe(1);

        await tui.waitForComposer(10_000);
        await tui.sendText("/quit");
        await tui.waitForSessionEnd(10_000);
        tui = null;
        // Exit leaves the session for the server to expire rather than
        // holding the prompt for a DELETE round trip.
        expect(streamable.deleteCalls).toBe(0);
      },
      40_000,
    );
  }

  test.skipIf(!tmuxAvailable())(
    "/mcp remove ends a 2025 session with a DELETE, and fx keeps running",
    async () => {
      // The removal reloads fx's MCP host, which closes the old host's
      // servers; a 2025 session waits there for its DELETE.
      const version = "2025-06-18";
      streamable = startLegacyStreamableHttpFixture(version);
      const root = createRoot("remove-http", "http", streamable.url);
      gateway = startFakeGateway([]);
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 100,
        height: 30,
        env: { ...fixtureEnv(root, gateway) },
      });

      await tui.waitForComposer(15_000);
      const listDeadline = Date.now() + 15_000;
      while (
        !streamable.requests.some(
          (entry) => entry.message?.method === "tools/list",
        ) &&
        Date.now() < listDeadline
      ) {
        await Bun.sleep(25);
      }
      expect(
        streamable.requests.some(
          (entry) => entry.message?.method === "tools/list",
        ),
      ).toBe(true);

      await tui.sendText("/mcp remove fixture");
      await tui.waitForText("Removed fixture from ~/.fx/mcp.json.", 10_000);
      const deleteDeadline = Date.now() + 10_000;
      while (streamable.deleteCalls === 0 && Date.now() < deleteDeadline) {
        await Bun.sleep(25);
      }
      expect(streamable.deleteCalls).toBe(1);
      const deleted = streamable.requests.find(
        (entry) => entry.httpMethod === "DELETE",
      )!;
      expect(deleted.headers["mcp-session-id"]).toBe(`session-${version}`);

      // fx is still running: the next command answers.
      await tui.waitForComposer(10_000);
      await tui.sendText("/mcp list");
      await tui.waitForText("No MCP servers configured.", 10_000);
    },
    40_000,
  );

  // The server's own 5 s startup timeout ends the wait.
  test(
    "a 2025 server that never answers initialize fails after its timeout instead of hanging",
    async () => {
      const fixture = startLegacyStreamableHttpFixture("2025-11-25", { mode: "hold_initialize" });
      streamable = fixture;
      const root = createRoot("hold-initialize-v2", "http", fixture.url);
      const started = Date.now();
      const result = await runFx(["mcp", "show", "fixture", "--json"], {
        cwd: root.workspace,
        env: { HOME: root.home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 90_000,
      });
      expect(result.signal).toBeNull();
      expect(Date.now() - started).toBeLessThan(85_000);
      expect(result.code).toBe(1);
      expect(JSON.parse(result.stdout).error).toContain("initialize");
      expect(fixture.initializeCalls).toBe(1);
    },
    120_000,
  );

  test(
    "a 2025 server that never answers notifications/initialized fails with the reason instead of looking ready with no tools",
    async () => {
      const fixture = startLegacyStreamableHttpFixture("2025-11-25", { mode: "hold_initialized" });
      streamable = fixture;
      const root = createRoot("hold-initialized-v2", "http", fixture.url);
      const started = Date.now();
      const result = await runFx(["mcp", "show", "fixture", "--json"], {
        cwd: root.workspace,
        env: { HOME: root.home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 90_000,
      });
      expect(result.signal).toBeNull();
      expect(Date.now() - started).toBeLessThan(85_000);
      expect(result.code).toBe(1);
      expect(JSON.parse(result.stdout).error).toBe("it never answered fx's initialized notification");
      // Everything after initialized waits for its answer.
      expect(fixture.toolsListCalls).toBe(0);
    },
    120_000,
  );
});
