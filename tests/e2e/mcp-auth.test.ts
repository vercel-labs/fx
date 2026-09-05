import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { spawnSync } from "node:child_process";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  startLegacyHttpSseFixture,
  startLegacyStreamableHttpFixture,
} from "./fixtures/mcp-legacy-remote";
import { startModernMcpHttpFixture } from "./fixtures/mcp-modern-http";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const ACCESS_INITIAL = "mcp-access-initial-secret";
const ACCESS_REFRESHED = "mcp-access-refreshed-secret";
const REFRESH_INITIAL = "mcp-refresh-initial-secret";
const REFRESH_ROTATED = "mcp-refresh-rotated-secret";
const REPO_ROOT = realpathSync(join(import.meta.dirname, "..", ".."));
const MCP_KEYCHAIN_SERVICE = "FX_MCP_OAUTH_CREDENTIALS_V1";
const inheritedKeychainDisable = process.env.FX_DISABLE_KEYCHAIN;
const MCP_KEYCHAIN_PROBE_SCRIPT = `
ObjC.import("Security");
ObjC.import("Foundation");
const object = (value) => ObjC.castRefToObject(value);
function query(account, service) {
  const value = $.NSMutableDictionary.alloc.init;
  value.setObjectForKey(object($.kSecClassGenericPassword), object($.kSecClass));
  value.setObjectForKey($(account), object($.kSecAttrAccount));
  value.setObjectForKey($(service), object($.kSecAttrService));
  return value;
}
function run(argv) {
  const value = query(argv[1], argv[2]);
  if (argv[0] === "load") {
    value.setObjectForKey($.NSNumber.numberWithBool(true), object($.kSecReturnData));
    value.setObjectForKey(object($.kSecMatchLimitOne), object($.kSecMatchLimit));
    const result = Ref();
    const status = $.SecItemCopyMatching(value, result);
    if (status !== 0) throw new Error("keychain status=" + status);
    $.NSFileHandle.fileHandleWithStandardOutput.writeData(
      ObjC.castRefToObject(result[0]),
    );
    return;
  }
  if (argv[0] === "delete") {
    const status = $.SecItemDelete(value);
    if (status !== 0 && status !== -25300) {
      throw new Error("keychain status=" + status);
    }
    return;
  }
  throw new Error("unsupported probe operation");
}
`;

type AuthFixture = ReturnType<typeof startAuthFixture>;

let cleanupRoot: string | null = null;
let upstream: ReturnType<typeof startModernMcpHttpFixture> | null = null;
let legacyStreamable:
  | ReturnType<typeof startLegacyStreamableHttpFixture>
  | null = null;
let legacySse: ReturnType<typeof startLegacyHttpSseFixture> | null = null;
let auth: AuthFixture | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let tui: TmuxSession | null = null;

function runMcpKeychainProbe(
  operation: "load" | "delete",
  account: string,
  service: string,
  home: string,
) {
  return spawnSync(
    "/usr/bin/osascript",
    [
      "-l",
      "JavaScript",
      "-e",
      MCP_KEYCHAIN_PROBE_SCRIPT,
      operation,
      account,
      service,
    ],
    {
      encoding: "utf8",
      env: { ...process.env, HOME: home, USER: account },
      timeout: 10_000,
    },
  );
}

beforeAll(() => {
  process.env.FX_DISABLE_KEYCHAIN = "1";
});

afterAll(() => {
  if (inheritedKeychainDisable === undefined) {
    delete process.env.FX_DISABLE_KEYCHAIN;
  } else {
    process.env.FX_DISABLE_KEYCHAIN = inheritedKeychainDisable;
  }
});

async function waitForFile(path: string, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return true;
    await Bun.sleep(10);
  }
  return existsSync(path);
}

async function waitForFileText(
  path: string,
  expected: string,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(expected)) {
      return true;
    }
    await Bun.sleep(10);
  }
  return existsSync(path) && readFileSync(path, "utf8").includes(expected);
}

function unusedCallbackPort(): number {
  const listener = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () => new Response("reserved"),
  });
  const port = listener.port;
  listener.stop(true);
  return port;
}

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeAuth = auth;
  const activeUpstream = upstream;
  const activeLegacyStreamable = legacyStreamable;
  const activeLegacySse = legacySse;
  const activeCleanupRoot = cleanupRoot;
  tui = null;
  gateway = null;
  auth = null;
  upstream = null;
  legacyStreamable = null;
  legacySse = null;
  cleanupRoot = null;

  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  activeAuth?.stop();
  activeUpstream?.stop();
  activeLegacyStreamable?.stop();
  activeLegacySse?.stop();
  if (activeCleanupRoot) {
    rmSync(activeCleanupRoot, { recursive: true, force: true });
  }
});

function startAuthFixture(
  upstreamUrl: string,
  options: {
    wrongState?: boolean;
    rejectRefresh?: boolean;
    authorizationMetadataContentType?: string;
    transport?: "http" | "sse";
    rejectToolAuth?: boolean;
    challengeMarkerPath?: string;
    refreshBarrierStartedPath?: string;
    refreshBarrierReleasePath?: string;
    stallRefresh?: boolean;
    subscriptionChallenge?: "unauthorized" | "scope";
    rotateOnSecondToolsPage?: boolean;
    rotateAuthorizationToken?: boolean;
    rotateOnResourceReadCall?: number;
    failFeatureRefreshAfterRotation?: boolean;
    rejectResourceTemplateAuth?: boolean;
    authorizationServerTrailingSlash?: boolean;
    authorizationResponseIssuer?: string;
    authorizationResponseTrailingSlash?: boolean;
    omitScopes?: boolean;
    rejectDiscoveryWithoutChallenge?: boolean;
    rejectDiscoveryWithRestAuthorizationDocument?: boolean;
  } = {},
) {
  const transport = options.transport ?? "http";
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    sessionId: string | null;
    lastEventId: string | null;
    body: string;
  }> = [];
  const validTokens = new Set([ACCESS_INITIAL, ACCESS_REFRESHED]);
  let authorizationRequests = 0;
  let tokenExchanges = 0;
  let refreshes = 0;
  let refreshCancellations = 0;
  let revocations = 0;
  let protectedToolCalls = 0;
  let proxyStreamCancellations = 0;
  let expectedChallenge = "";
  let expectedScope = "tools.read offline_access";
  let subscriptionRejections = 0;
  let paginationRejections = 0;
  let resourceReadRequests = 0;

  const server = Bun.serve({
    port: 0,
    idleTimeout: 30,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "GET" ? "" : await request.text();
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        sessionId: request.headers.get("mcp-session-id"),
        lastEventId: request.headers.get("last-event-id"),
        body,
      });
      const origin = `http://127.0.0.1:${server.port}`;
      const resourcePath = transport === "sse" ? "/sse" : "/mcp";
      const resource = `${origin}${resourcePath}`;
      const protectedRoute = url.pathname === resourcePath ||
        (transport === "sse" && url.pathname === "/messages");

      if (protectedRoute) {
        const bearer = request.headers.get("authorization");
        const token = bearer?.startsWith("Bearer ") ? bearer.slice(7) : "";
        if (!validTokens.has(token)) {
          return new Response("", {
            status: 401,
            headers: {
              "www-authenticate": options.omitScopes
                ? `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}"`
                : `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}", scope="tools.read"`,
            },
          });
        }
        const message = body === "" ? null : JSON.parse(body);
        if (
          message?.method === "server/discover" &&
          options.rejectDiscoveryWithoutChallenge
        ) {
          return new Response("", { status: 403 });
        }
        if (
          message?.method === "server/discover" &&
          options.rejectDiscoveryWithRestAuthorizationDocument
        ) {
          return Response.json(
            {
              error: 401,
              reason: "Unauthorized",
              detail: "You are not authorized for this resource.",
            },
            { status: 400 },
          );
        }
        if (message?.method === "resources/read") {
          resourceReadRequests += 1;
          if (
            token === ACCESS_INITIAL &&
            resourceReadRequests === options.rotateOnResourceReadCall
          ) {
            return new Response("", {
              status: 401,
              headers: {
                "www-authenticate":
                  `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}", scope="tools.read"`,
              },
            });
          }
        }
        if (
          token === ACCESS_REFRESHED &&
          options.failFeatureRefreshAfterRotation &&
          [
            "resources/list",
            "resources/templates/list",
            "prompts/list",
          ].includes(message?.method)
        ) {
          return Response.json(
            { error: "feature refresh failed after rotation" },
            { status: 503 },
          );
        }
        if (
          message?.method === "resources/templates/list" &&
          options.rejectResourceTemplateAuth
        ) {
          return new Response("", {
            status: 403,
            headers: {
              "www-authenticate":
                `Bearer error="insufficient_scope", scope="resources.read", resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}"`,
            },
          });
        }
        if (
          message?.method === "subscriptions/listen" &&
          options.subscriptionChallenge &&
          subscriptionRejections === 0
        ) {
          subscriptionRejections += 1;
          const scopeChallenge = options.subscriptionChallenge === "scope";
          return new Response("", {
            status: scopeChallenge ? 403 : 401,
            headers: {
              "www-authenticate": scopeChallenge
                ? `Bearer error="insufficient_scope", scope="tools.call", resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}"`
                : `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}", scope="tools.read"`,
            },
          });
        }
        if (
          message?.method === "tools/list" &&
          message.params?.cursor === "p2" &&
          token === ACCESS_INITIAL &&
          options.rotateOnSecondToolsPage &&
          paginationRejections === 0
        ) {
          paginationRejections += 1;
          return new Response("", {
            status: 401,
            headers: {
              "www-authenticate":
                `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}", scope="tools.read"`,
            },
          });
        }
        if (message?.method === "tools/call") {
          protectedToolCalls += 1;
          if (options.rejectToolAuth) {
            if (options.challengeMarkerPath) {
              writeFileSync(
                options.challengeMarkerPath,
                `${message.id}\n`,
              );
            }
            return new Response("", {
              status: 403,
              headers: {
                "www-authenticate":
                  `Bearer error="insufficient_scope", scope="tools.call", resource_metadata="${origin}/.well-known/oauth-protected-resource${resourcePath}"`,
              },
            });
          }
        }
        const target = transport === "sse" && url.pathname === "/messages"
          ? `${new URL(upstreamUrl).origin}/messages`
          : upstreamUrl;
        const upstreamHeaders = new Headers(request.headers);
        upstreamHeaders.set("connection", "close");
        const upstreamResponse = await fetch(target, {
          method: request.method,
          headers: upstreamHeaders,
          ...(body === "" ? {} : { body }),
        });
        if (
          transport === "sse" &&
          request.method === "GET" &&
          upstreamResponse.body
        ) {
          const reader = upstreamResponse.body.getReader();
          return new Response(
            new ReadableStream({
              async pull(controller) {
                const chunk = await reader.read();
                if (chunk.done) {
                  controller.close();
                } else {
                  controller.enqueue(chunk.value);
                }
              },
              async cancel(reason) {
                proxyStreamCancellations += 1;
                await reader.cancel(reason);
              },
            }),
            {
              status: upstreamResponse.status,
              headers: upstreamResponse.headers,
            },
          );
        }
        return upstreamResponse;
      }
      if (
        url.pathname ===
          `/.well-known/oauth-protected-resource${resourcePath}`
      ) {
        return Response.json({
          resource,
          authorization_servers: [
            options.authorizationServerTrailingSlash ? `${origin}/` : origin,
          ],
          ...(options.omitScopes
            ? {}
            : { scopes_supported: ["tools.read", "tools.call", "offline_access"] }),
        });
      }
      if (url.pathname === "/.well-known/oauth-authorization-server") {
        const metadata = {
          issuer: origin,
          authorization_endpoint: `${origin}/authorize`,
          token_endpoint: `${origin}/token`,
          revocation_endpoint: `${origin}/revoke`,
          ...(options.omitScopes
            ? {}
            : { scopes_supported: ["tools.read", "tools.call", "offline_access"] }),
          grant_types_supported: ["authorization_code", "refresh_token"],
          token_endpoint_auth_methods_supported: ["none"],
          code_challenge_methods_supported: ["S256"],
          authorization_response_iss_parameter_supported: true,
        };
        if (options.authorizationMetadataContentType) {
          return new Response(JSON.stringify(metadata), {
            headers: {
              "content-type": options.authorizationMetadataContentType,
            },
          });
        }
        return Response.json(metadata);
      }
      if (url.pathname === "/authorize") {
        authorizationRequests += 1;
        expect(url.searchParams.get("resource")).toBe(resource);
        expect(url.searchParams.get("code_challenge_method")).toBe("S256");
        expectedChallenge = url.searchParams.get("code_challenge") ?? "";
        expectedScope = url.searchParams.get("scope") ?? "";
        const redirect = new URL(url.searchParams.get("redirect_uri")!);
        redirect.searchParams.set("code", "fixture-code");
        redirect.searchParams.set(
          "state",
          options.wrongState ? "wrong-state" : url.searchParams.get("state")!,
        );
        redirect.searchParams.set(
          "iss",
          options.authorizationResponseIssuer ??
            (options.authorizationResponseTrailingSlash ? `${origin}/` : origin),
        );
        return Response.redirect(redirect, 302);
      }
      if (url.pathname === "/token") {
        const form = new URLSearchParams(body);
        expect(form.get("resource")).toBe(resource);
        if (form.get("grant_type") === "refresh_token") {
          refreshes += 1;
          expect(form.get("refresh_token")).toBe(REFRESH_INITIAL);
          if (
            refreshes === 1 &&
            options.refreshBarrierStartedPath &&
            options.refreshBarrierReleasePath
          ) {
            writeFileSync(options.refreshBarrierStartedPath, "refresh-started");
            if (!await waitForFile(options.refreshBarrierReleasePath, 10_000)) {
              return Response.json(
                { error: "refresh barrier timed out" },
                { status: 504 },
              );
            }
          }
          if (options.stallRefresh && refreshes === 1) {
            return new Response(
              new ReadableStream({
                cancel() {
                  refreshCancellations += 1;
                },
              }),
              { headers: { "content-type": "application/json" } },
            );
          }
          if (options.rejectRefresh) {
            return Response.json(
              { error: "invalid_grant" },
              { status: 400 },
            );
          }
          return Response.json({
            access_token: ACCESS_REFRESHED,
            refresh_token: REFRESH_ROTATED,
            token_type: "Bearer",
            scope: "tools.read offline_access",
            expires_in: 3600,
          });
        }
        tokenExchanges += 1;
        expect(form.get("grant_type")).toBe("authorization_code");
        expect(form.get("code")).toBe("fixture-code");
        const verifier = form.get("code_verifier") ?? "";
        const actualChallenge = createHash("sha256")
          .update(verifier)
          .digest("base64url");
        expect(actualChallenge).toBe(expectedChallenge);
        return Response.json({
          access_token: options.rotateAuthorizationToken
            ? ACCESS_REFRESHED
            : ACCESS_INITIAL,
          refresh_token: options.rotateAuthorizationToken
            ? REFRESH_ROTATED
            : REFRESH_INITIAL,
          token_type: "Bearer",
          ...(options.omitScopes ? {} : { scope: expectedScope }),
          expires_in: 3600,
        });
      }
      if (url.pathname === "/revoke") {
        revocations += 1;
        return new Response("", { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}${
      transport === "sse" ? "/sse" : "/mcp"
    }`,
    requests,
    get authorizationRequests() {
      return authorizationRequests;
    },
    get tokenExchanges() {
      return tokenExchanges;
    },
    get refreshes() {
      return refreshes;
    },
    get refreshCancellations() {
      return refreshCancellations;
    },
    get revocations() {
      return revocations;
    },
    get protectedToolCalls() {
      return protectedToolCalls;
    },
    get proxyStreamCancellations() {
      return proxyStreamCancellations;
    },
    get subscriptionRejections() {
      return subscriptionRejections;
    },
    get paginationRejections() {
      return paginationRejections;
    },
    stop() {
      server.stop(true);
    },
  };
}

function createRoot(
  activeAuth: AuthFixture,
  configureOauth = true,
  transport: "http" | "sse" = "http",
  serverUrl = activeAuth.url,
  followAuthorization = true,
) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-mcp-auth-")));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const bin = join(root, "bin");
  const trace = join(root, "trace.log");
  const openLog = join(root, "open.log");
  const callbackLog = join(root, "callback.html");
  const stderr = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(bin, { recursive: true });
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
          url: serverUrl,
          environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
          ...(configureOauth
            ? {
                oauth: {
                  client_id: "fx-mcp-auth-test",
                  scopes: ["tools.read"],
                },
              }
            : {}),
          startup_timeout_ms: 5_000,
          operation_timeout_ms: 5_000,
        },
      },
    }),
  );
  const follow = followAuthorization
    ? `nohup curl --location --silent --show-error "$1" > '${callbackLog}' 2>/dev/null &\n`
    : "";
  const opener =
    `#!/bin/sh\nprintf '%s\\n' "$1" > '${openLog}'\n${follow}exit 0\n`;
  for (const name of ["open", "xdg-open"]) {
    const path = join(bin, name);
    writeFileSync(path, opener);
    chmodSync(path, 0o700);
  }
  return { root, home, workspace, bin, trace, openLog, callbackLog, stderr };
}

function moveAuthFixtureToWorkspace(root: ReturnType<typeof createRoot>): void {
  const profilePath = join(root.home, ".fx", "mcp.json");
  const profile = JSON.parse(readFileSync(profilePath, "utf8"));
  writeFileSync(
    join(root.workspace, ".mcp.json"),
    JSON.stringify({ mcpServers: { fixture: profile.mcp.fixture } }),
  );
  writeFileSync(profilePath, JSON.stringify({ mcp: {} }));
}

function baseEnv(root: ReturnType<typeof createRoot>) {
  return {
    HOME: root.home,
    PATH: `${root.bin}${delimiter}${process.env.PATH ?? ""}`,
    AI_GATEWAY_API_KEY: "fake-mcp-auth-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_MCP_PROTOCOL_VERSION: "2026-07-28",
    FX_PERMISSION_MODE: "auto",
    FX_MODEL: MODEL,
    FX_TRACE_LOG: root.trace,
    FX_TRACE_SCOPES: "mcp,core",
  };
}

function seedExpiredCredentials(
  root: ReturnType<typeof createRoot>,
  activeAuth: AuthFixture,
  expiresAtMs = 0,
) {
  const endpoint = activeAuth.url;
  const origin = new URL(endpoint).origin;
  const directory = join(root.home, ".fx", "mcp-credentials");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, "credentials.json");
  writeFileSync(
    path,
    JSON.stringify({
      version: 1,
      credentials: [{
        server_identity: "fixture",
        endpoint,
        resource: endpoint,
        issuer: origin,
        client_id: "fx-mcp-auth-test",
        client_secret: null,
        access_token: ACCESS_INITIAL,
        refresh_token: REFRESH_INITIAL,
        scope: "tools.read offline_access",
        token_type: "Bearer",
        token_endpoint_auth_method: "none",
        expires_at_ms: expiresAtMs,
        authorization_endpoint: `${origin}/authorize`,
        token_endpoint: `${origin}/token`,
        revocation_endpoint: `${origin}/revoke`,
      }],
    }),
    { mode: 0o600 },
  );
  chmodSync(path, 0o600);
  return path;
}

function startToolGateway() {
  return startFakeGateway([
    fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
    fakeGatewayToolCall("call_mcp", TOOL_NAME, { text: "authenticated" }),
    fakeGatewayFinalText("Authenticated MCP call complete."),
  ], {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
}

function startDelayedToolGateway(delayMs: number, finalText: string) {
  return startFakeGateway([
    fakeGatewayToolCall("select_mcp", "mcp_select_tool", { name: TOOL_NAME }),
    async () => {
      await Bun.sleep(delayMs);
      return fakeGatewayToolCall("call_mcp", TOOL_NAME, {
        text: "authenticated",
      });
    },
    fakeGatewayFinalText(finalText),
  ], {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
}

function startRefreshRecoveryGateway(delayMs: number) {
  return startFakeGateway([
    fakeGatewayToolCall("select_cancel", "mcp_select_tool", {
      name: TOOL_NAME,
    }),
    async () => {
      await Bun.sleep(delayMs);
      return fakeGatewayToolCall("call_cancel", TOOL_NAME, {
        text: "cancelled",
      });
    },
    fakeGatewayToolCall("select_recovery", "mcp_select_tool", {
      name: TOOL_NAME,
    }),
    fakeGatewayToolCall("call_recovery", TOOL_NAME, {
      text: "recovered",
    }),
    fakeGatewayFinalText("Refresh recovery complete."),
  ], {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
}

function collectRegularFiles(root: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(root)) {
    const path = join(root, entry);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      files.push(...collectRegularFiles(path));
    } else if (stat.isFile()) {
      files.push(path);
    }
  }
  return files;
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

function preserveAuthFailure(
  label: string,
  root: ReturnType<typeof createRoot>,
  result: Awaited<ReturnType<typeof runFx>>,
  activeAuth: AuthFixture,
  activeUpstream: ReturnType<typeof startModernMcpHttpFixture>,
  activeGateway: ReturnType<typeof startFakeGateway>,
): void {
  if (result.code === 0) return;
  cleanupRoot = null;
  writeFileSync(join(root.root, "fx-stdout.log"), result.stdout);
  writeFileSync(join(root.root, "fx-stderr.log"), result.stderr);
  writeFileSync(
    join(root.root, "failure.json"),
    JSON.stringify({
      label,
      result,
      authRequests: activeAuth.requests.map((request) => ({
        ...request,
        authorization: request.authorization === `Bearer ${ACCESS_INITIAL}`
          ? "initial"
          : request.authorization === `Bearer ${ACCESS_REFRESHED}`
          ? "refreshed"
          : request.authorization === null
          ? null
          : "other",
      })),
      upstreamRequests: activeUpstream.requests.map((request) => ({
        message: request.message,
        receivedAtMs: request.receivedAtMs,
      })),
      gatewayRequests: activeGateway.requests.map((request) => request.body),
    }, null, 2),
  );
  throw new Error(`fx ${label} failed; retained artifacts: ${root.root}`);
}

async function preserveAuthTuiFailure(
  label: string,
  root: ReturnType<typeof createRoot>,
  error: unknown,
): Promise<never> {
  cleanupRoot = null;
  const activeTui = tui;
  writeFileSync(
    join(root.root, "tui-failure.json"),
    JSON.stringify({
      label,
      error: error instanceof Error ? error.stack ?? error.message : String(error),
      paneStatus: activeTui?.paneStatus() ?? null,
      pane: activeTui ? await activeTui.captureFullScrollback() : "",
      authRequests: auth?.requests.map((request) => ({
        method: request.method,
        path: request.path,
        body: request.body,
      })) ?? [],
      upstreamRequests: upstream?.requests.map((request) => request.message) ?? [],
      gatewayRequests: gateway?.requests.map((request) => request.body) ?? [],
    }, null, 2),
  );
  throw new Error(`fx ${label} failed; retained artifacts: ${root.root}`);
}

describe("MCP remote authentication lifecycle", () => {
  test("top-level MCP auth accepts a manual callback when browser launch fails", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth, true, "http", auth.url, false);
    for (const name of ["open", "xdg-open"]) {
      writeFileSync(join(root.bin, name),
        `#!/bin/sh\nprintf '%s\\n' "$1" > '${root.openLog}'\nexit 1\n`);
    }
    const authentication = Bun.spawn([FX_BIN, "mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env: { ...process.env, ...baseEnv(root), AI_GATEWAY_API_KEY: undefined, FX_NO_OPEN_BROWSER: undefined },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    let stdout = "";
    let authorizationUrl: string | undefined;
    let callback: Promise<Response | null> | undefined;
    const readStdout = (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of authentication.stdout) {
        stdout += decoder.decode(chunk, { stream: true });
        const match = stdout.match(/^(https?:\/\/[^\r\n]+)\r?\n/m);
        if (!authorizationUrl && match) {
          authorizationUrl = match[1];
          callback = fetch(authorizationUrl).catch(() => null);
        }
      }
    })();
    const timer = setTimeout(() => authentication.kill(), 10_000);
    let code: number;
    let stderr: string;
    try {
      [code, stderr] = await Promise.all([
        authentication.exited,
        new Response(authentication.stderr).text(),
        readStdout,
      ]);
    } finally {
      clearTimeout(timer);
    }
    expect(code).toBe(0);
    expect(authorizationUrl).toBeDefined();
    expect(stdout).toContain("Authenticated MCP server 'fixture'");
    expect(stderr).toBe("");
    const response = await callback;
    expect(response?.status).toBe(200);
    expect(auth.tokenExchanges).toBe(1);
    expect(existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json"))).toBe(true);
  }, 15_000);

  test("top-level MCP auth and logout complete without TUI or Gateway", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth);
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authenticated = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    if (authenticated.code !== 0) {
      throw new Error(JSON.stringify({
        authenticated,
        authorizationRequests: auth.authorizationRequests,
        tokenExchanges: auth.tokenExchanges,
        authRequests: auth.requests,
        trace: existsSync(root.trace) ? readFileSync(root.trace, "utf8") : "",
      }, null, 2));
    }
    expect(authenticated.code).toBe(0);
    expect(authenticated.stderr).toBe("");
    expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");
    expect(auth.authorizationRequests).toBe(1);
    expect(auth.tokenExchanges).toBe(1);
    expect(existsSync(root.openLog)).toBe(true);
    expect(
      await waitForFileText(root.callbackLog, "Authorization complete", 5_000),
    ).toBe(true);
    const callbackPage = readFileSync(root.callbackLog, "utf8");
    expect(callbackPage).toContain("<h1>Authorization complete</h1>");
    expect(callbackPage).toContain("prefers-color-scheme:dark");
    const credentialPath = join(
      root.home,
      ".fx",
      "mcp-credentials",
      "credentials.json",
    );
    expect(existsSync(credentialPath)).toBe(true);
    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    delete profile.mcp.fixture.oauth;
    writeFileSync(profilePath, JSON.stringify(profile));

    const requestCountBeforeList = auth.requests.length;
    const listed = await runFx(["mcp", "list"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stderr).toBe("");
    expect(listed.stdout).toMatch(/fixture[\s\S]{0,240}auth=authenticated/);
    expect(auth.requests).toHaveLength(requestCountBeforeList);

    const loggedOut = await runFx(["mcp", "logout", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(loggedOut.code).toBe(0);
    expect(loggedOut.stderr).toBe("");
    expect(loggedOut.stdout).toContain("Logged out of MCP server 'fixture'");
    expect(existsSync(credentialPath)).toBe(false);
    expect(auth.revocations).toBe(2);
  }, 30_000);

  test("pinned localhost callback reuses one port without aborting", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth, true, "http", auth.url, false);
    const callbackPort = unusedCallbackPort();
    const profilePath = join(root.home, ".fx", "mcp.json");
    const profile = JSON.parse(readFileSync(profilePath, "utf8"));
    profile.mcp.fixture.oauth.callback_port = callbackPort;
    writeFileSync(profilePath, JSON.stringify(profile));
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const attempts = 12;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      rmSync(root.openLog, { force: true });
      const authentication = runFx(["mcp", "auth", "fixture"], {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      });
      const opened = await waitForFileText(root.openLog, "http", 5_000);
      let callbackStatus: number | null = null;
      let callbackBody = "";
      let callbackError: unknown = null;
      if (opened) {
        try {
          const authorizationUrl = readFileSync(root.openLog, "utf8").trim();
          const authorizationResponse = await fetch(authorizationUrl, {
            redirect: "manual",
          });
          const callbackUrl = authorizationResponse.headers.get("location");
          if (!callbackUrl) throw new Error("authorization redirect is missing");
          const callbackResponse = await fetch(callbackUrl);
          callbackStatus = callbackResponse.status;
          callbackBody = await callbackResponse.text();
        } catch (error) {
          callbackError = error;
        }
      }
      const authenticated = await authentication;
      if (
        !opened ||
        callbackError !== null ||
        callbackStatus !== 200 ||
        authenticated.code !== 0 ||
        authenticated.stderr !== ""
      ) {
        throw new Error(JSON.stringify({
          attempt,
          callbackPort,
          opened,
          callbackStatus,
          callbackError: callbackError === null ? null : String(callbackError),
          authenticated,
        }, null, 2));
      }
      expect(callbackBody).toContain("Authorization complete");
      expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");

      const loggedOut = await runFx(["mcp", "logout", "fixture"], {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      });
      expect(loggedOut.code).toBe(0);
      expect(loggedOut.stderr).toBe("");
    }
    expect(auth.authorizationRequests).toBe(attempts);
    expect(auth.tokenExchanges).toBe(attempts);
  }, 90_000);

  test("rejected stored credentials report required auth without discovery fallback", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url, {
      rejectDiscoveryWithoutChallenge: true,
    });
    const root = createRoot(auth);
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authenticated = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(authenticated.code).toBe(0);
    expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");

    const listed = await runFx(["mcp", "list", "--connect"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stdout).toMatch(/fixture[\s\S]{0,240}auth=required/);
    expect(listed.stdout).not.toContain("auth=authenticated");
    expect(listed.stdout).toContain("Authentication is required");
    expect(listed.stdout).not.toContain("InvalidJsonResponse");
    for (const secret of [ACCESS_INITIAL, REFRESH_INITIAL]) {
      expect(listed.stdout).not.toContain(secret);
      expect(listed.stderr).not.toContain(secret);
      if (existsSync(root.trace)) {
        expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
      }
    }
    expect(auth.requests.some((request) =>
      request.body.includes('"method":"server/discover"')
    )).toBe(true);
    expect(auth.requests.some((request) =>
      request.body.includes('"method":"tools/list"')
    )).toBe(false);
    expect(upstream.requests).toHaveLength(0);
  }, 30_000);

  test("OAuth-authenticated MongoDB-like discovery reaches legacy tools", async () => {
    upstream = startModernMcpHttpFixture("legacy_session_required");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth);
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authenticated = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(authenticated.code).toBe(0);
    expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");

    const listed = await runFx(["mcp", "list", "--connect"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stderr).toBe("");
    expect(listed.stdout).toMatch(
      /fixture[\s\S]{0,240}state=ready auth=authenticated/,
    );
    expect(listed.stdout).toContain("protocol=2025-11-25");
    expect(listed.stdout).toContain(
      "negotiated_name=mongodb-managed-fixture negotiated_version=1.0.0",
    );
    expect(listed.stdout).toContain("tools=1");
    for (const secret of [ACCESS_INITIAL, REFRESH_INITIAL]) {
      expect(listed.stdout).not.toContain(secret);
      expect(listed.stderr).not.toContain(secret);
    }
    expect(upstream.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
    ]);
  }, 30_000);

  test("OAuth-authenticated MongoDB deployed session error reaches legacy tools", async () => {
    upstream = startModernMcpHttpFixture("legacy_mongodb_session_required");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth);
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authenticated = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(authenticated.code).toBe(0);
    expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");

    const listed = await runFx(["mcp", "list", "--connect"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stderr).toBe("");
    expect(listed.stdout).toMatch(
      /fixture[\s\S]{0,240}state=ready auth=authenticated/,
    );
    expect(listed.stdout).toContain("protocol=2025-11-25");
    expect(listed.stdout).toContain(
      "negotiated_name=mongodb-managed-fixture negotiated_version=1.0.0",
    );
    expect(listed.stdout).toContain("tools=1");
    expect(upstream.requests.map((entry) => entry.message.method)).toEqual([
      "server/discover",
      "initialize",
      "notifications/initialized",
      "tools/list",
    ]);
  }, 30_000);

  test("MongoDB-like REST authorization document rejects stored credentials", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url, {
      rejectDiscoveryWithRestAuthorizationDocument: true,
    });
    const root = createRoot(auth);
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authenticated = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(authenticated.code).toBe(0);
    expect(authenticated.stdout).toContain("Authenticated MCP server 'fixture'");

    const listed = await runFx(["mcp", "list", "--connect"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stdout).toMatch(/fixture[\s\S]{0,240}auth=required/);
    expect(listed.stdout).not.toContain("auth=authenticated");
    expect(listed.stdout).toContain("Authentication is required");
    expect(listed.stdout).not.toContain("InvalidJsonResponse");
    expect(upstream.requests).toHaveLength(0);
    for (const secret of [ACCESS_INITIAL, REFRESH_INITIAL]) {
      expect(listed.stdout).not.toContain(secret);
      expect(listed.stderr).not.toContain(secret);
      if (existsSync(root.trace)) {
        expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
      }
    }
  }, 30_000);

  test.skipIf(process.platform !== "darwin")(
    "MCP auth falls back to the private profile store when HOME has no Keychain",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const env = {
        ...baseEnv(root),
        AI_GATEWAY_API_KEY: undefined,
        FX_DISABLE_KEYCHAIN: undefined,
      };

      const authenticated = await runFx(["mcp", "auth", "fixture"], {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      });
      expect(authenticated.code).toBe(0);
      expect(authenticated.stderr).toBe("");
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      const credentialPath = join(
        root.home,
        ".fx",
        "mcp-credentials",
        "credentials.json",
      );
      expect(existsSync(credentialPath)).toBe(true);
      expect(statSync(credentialPath).mode & 0o777).toBe(0o600);

      const loggedOut = await runFx(["mcp", "logout", "fixture"], {
        cwd: root.workspace,
        env,
        timeoutMs: 20_000,
      });
      expect(loggedOut.code).toBe(0);
      expect(loggedOut.stderr).toBe("");
      expect(existsSync(credentialPath)).toBe(false);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "no-scope OAuth credentials survive reload and preserve an unrelated server",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      const canary = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, { omitScopes: true });
      const root = createRoot(auth);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      delete profile.mcp.fixture.oauth.scopes;
      profile.mcp.canary = {
        type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
        url: canary.url,
        startup_timeout_ms: 5_000,
        operation_timeout_ms: 5_000,
      };
      writeFileSync(profilePath, JSON.stringify(profile));
      const credentialDir = join(root.home, ".fx", "mcp-credentials");
      mkdirSync(credentialDir, { recursive: true, mode: 0o700 });
      const credentialPath = join(credentialDir, "credentials.json");
      writeFileSync(
        credentialPath,
        JSON.stringify({ version: 1, credentials: [{}] }),
        { mode: 0o600 },
      );
      chmodSync(credentialPath, 0o600);
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      try {
        const env = {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        };
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          env,
          width: 150,
          height: 38,
        });
        await tui.waitForComposer(15_000);

        await tui.sendText("/mcp auth fixture --open");
        const authenticated = await tui.waitForText(
          "Authenticated MCP server 'fixture'.",
          15_000,
        );
        expect(authenticated).toContain(
          "Removed 1 unreadable MCP credential entry.",
        );
        await tui.sendText("/mcp reload");
        await tui.waitForText("MCP configuration reloaded", 15_000);
        await tui.sendText("/mcp list");
        let pane = await tui.waitForText("MCP health (2 servers):", 10_000);
        expect(pane).toMatch(/fixture[\s\S]{0,240}state=ready/);
        expect(pane).toMatch(/canary[\s\S]{0,240}state=ready/);

        const stored = JSON.parse(readFileSync(credentialPath, "utf8"));
        expect(stored.credentials).toHaveLength(1);
        expect(stored.credentials[0].scope).toBe("");

        await tui.kill();
        tui = null;
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          env,
          width: 150,
          height: 38,
        });
        await tui.waitForComposer(15_000);
        await tui.sendText("/mcp list");
        pane = await tui.waitForText("MCP health (2 servers):", 10_000);
        expect(pane).toMatch(/fixture[\s\S]{0,240}state=ready/);
        expect(pane).toMatch(/canary[\s\S]{0,240}state=ready/);
      } finally {
        canary.stop();
      }
    },
    45_000,
  );

  test("required resource template authentication failure propagates before read", async () => {
    upstream = startModernMcpHttpFixture("features");
    auth = startAuthFixture(upstream.url, {
      rejectResourceTemplateAuth: true,
    });
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
    gateway = startFakeGateway([
      fakeGatewayToolCall("template_auth_read", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://project/src/main.zig",
      }),
      fakeGatewayFinalText("Template authentication failure observed."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Read an authenticated resource template."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 25_000,
      },
    );

    preserveAuthFailure(
      "resource-template-auth-required",
      root,
      result,
      auth,
      upstream,
      gateway,
    );
    expect(result.code).toBe(0);
    const finalBody = gateway.requests.at(-1)!.body;
    expect(toolResultText(finalBody, "template_auth_read", "error-text")).toContain(
      "McpAuthenticationRequired",
    );
    expect(toolResultText(finalBody, "template_auth_read", "error-text")).not.toContain(
      "McpResourceNotFound",
    );
    expect(auth.requests.filter((request) =>
      request.body.includes('"resources/templates/list"')
    )).toHaveLength(1);
    expect(upstream.requests.filter((request) =>
      request.message.method === "resources/templates/list"
    )).toHaveLength(0);
    expect(upstream.requests.filter((request) =>
      request.message.method === "resources/read"
    )).toHaveLength(0);
  }, 35_000);

  test("private feature catalogs rotate with authenticated identity without leaking credentials", async () => {
    upstream = startModernMcpHttpFixture("features");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 65_000);
    gateway = startFakeGateway([
      fakeGatewayToolCall("auth_resource_list_one", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      async () => {
        await Bun.sleep(6_000);
        return fakeGatewayToolCall("auth_resource_list_two", "mcp_features", {
          action: "resource_list",
          server: "fixture",
        });
      },
      async () => {
        await Bun.sleep(500);
        return fakeGatewayToolCall("auth_resource_read", "mcp_features", {
          action: "resource_read",
          server: "fixture",
          uri: "custom://alpha",
        });
      },
      fakeGatewayToolCall("auth_prompt_list", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("auth_prompt_get", "mcp_features", {
        action: "prompt_get",
        server: "fixture",
        prompt: "review",
        arguments: { tone: "brief" },
      }),
      fakeGatewayToolCall("auth_prompt_complete", "mcp_features", {
        action: "prompt_complete",
        server: "fixture",
        prompt: "review",
        argument: "tone",
        value: "b",
      }),
      fakeGatewayFinalText("Authenticated MCP features complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Use authenticated MCP features after rotation."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 25_000,
      },
    );

    expect(result.code).toBe(0);
    expect(auth.refreshes).toBe(1);
    const resourcePages = auth.requests.filter((request) =>
      request.body.includes('"resources/list"')
    );
    expect(resourcePages.map((request) => request.authorization)).toEqual([
      `Bearer ${ACCESS_INITIAL}`,
      `Bearer ${ACCESS_INITIAL}`,
      `Bearer ${ACCESS_REFRESHED}`,
      `Bearer ${ACCESS_REFRESHED}`,
    ]);
    const bodies = gateway.requests.map((request) => request.body).join("\n");
    expect(bodies).toContain("HTTP_RESOURCE_TEXT");
    expect(bodies).toContain("HTTP_PROMPT_TEXT");
    for (const secret of [ACCESS_INITIAL, ACCESS_REFRESHED]) {
      expect(result.stdout).not.toContain(secret);
      expect(result.stderr).not.toContain(secret);
      expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
      expect(bodies).not.toContain(secret);
    }
  }, 35_000);

  test("private feature catalogs fail closed when refresh after auth rotation fails", async () => {
    upstream = startModernMcpHttpFixture("features_stale_read");
    auth = startAuthFixture(upstream.url, {
      rotateAuthorizationToken: true,
      rotateOnResourceReadCall: 2,
      failFeatureRefreshAfterRotation: true,
    });
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
    gateway = startFakeGateway([
      fakeGatewayToolCall("private_resource_a", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_templates_a", "mcp_features", {
        action: "resource_templates",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_prompts_a", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_read_a", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      fakeGatewayToolCall("private_rotate", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      fakeGatewayToolCall("private_resource_b", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_templates_b", "mcp_features", {
        action: "resource_templates",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_prompts_b", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("private_read_b", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      fakeGatewayFinalText("Private feature rotation failure observed."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Check private MCP features after failed rotation."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_MCP_AUTH_AUTOMATE: "1",
        },
        timeoutMs: 25_000,
      },
    );

    preserveAuthFailure(
      "private-feature-auth-rotation",
      root,
      result,
      auth,
      upstream,
      gateway,
    );
    expect(result.code).toBe(0);
    expect(auth.refreshes).toBe(0);
    expect(auth.authorizationRequests).toBe(1);
    expect(auth.tokenExchanges).toBe(1);
    const finalBody = gateway.requests.at(-1)!.body;
    expect(toolResultText(finalBody, "private_resource_a")).toContain(
      "custom://alpha",
    );
    expect(toolResultText(finalBody, "private_templates_a")).toContain(
      "custom://project/{path}",
    );
    expect(toolResultText(finalBody, "private_prompts_a")).toContain(
      "review",
    );
    expect(toolResultText(finalBody, "private_read_a")).toContain(
      "HTTP_RESOURCE_TEXT",
    );
    expect(toolResultText(finalBody, "private_rotate", "error-text")).toContain(
      "tool_execution_failed",
    );
    for (const callId of [
      "private_resource_b",
      "private_templates_b",
      "private_prompts_b",
      "private_read_b",
    ]) {
      const output = toolResultText(finalBody, callId, "error-text");
      expect(output).not.toContain("custom://alpha");
      expect(output).not.toContain("custom://project/{path}");
      expect(output).not.toContain("review");
      expect(output).toContain("tool_execution_failed");
    }
    const featureRequests = auth.requests.filter((request) =>
      request.body.includes('"resources/list"') ||
      request.body.includes('"resources/templates/list"') ||
      request.body.includes('"prompts/list"')
    );
    expect(featureRequests.filter((request) =>
      request.authorization === `Bearer ${ACCESS_REFRESHED}`
    ).length).toBeGreaterThanOrEqual(3);
    expect(readFileSync(root.trace, "utf8")).toContain(
      "preserved_snapshot=false",
    );
    expect(auth.requests.filter((request) =>
      request.body.includes('"resources/read"')
    )).toHaveLength(2);
  }, 35_000);

  test("public feature and resource-read caches survive an unrelated auth rotation", async () => {
    upstream = startModernMcpHttpFixture("features_public");
    auth = startAuthFixture(upstream.url, {
      failFeatureRefreshAfterRotation: true,
    });
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 65_000);
    gateway = startFakeGateway([
      fakeGatewayToolCall("public_resource_a", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_templates_a", "mcp_features", {
        action: "resource_templates",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_prompts_a", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_read_a", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      fakeGatewayToolCall("public_select", "mcp_select_tool", {
        name: TOOL_NAME,
      }),
      async () => {
        await Bun.sleep(6_000);
        return fakeGatewayToolCall("public_rotate", TOOL_NAME, {
          text: "rotate",
        });
      },
      fakeGatewayToolCall("public_resource_b", "mcp_features", {
        action: "resource_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_templates_b", "mcp_features", {
        action: "resource_templates",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_prompts_b", "mcp_features", {
        action: "prompt_list",
        server: "fixture",
      }),
      fakeGatewayToolCall("public_read_b", "mcp_features", {
        action: "resource_read",
        server: "fixture",
        uri: "custom://alpha",
      }),
      fakeGatewayFinalText("Public feature rotation control complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Reuse public MCP state after auth rotation."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 30_000,
      },
    );

    expect(result.code).toBe(0);
    expect(auth.refreshes).toBe(1);
    const finalBody = gateway.requests.at(-1)!.body;
    for (const callId of ["public_resource_a", "public_resource_b"]) {
      expect(toolResultText(finalBody, callId)).toContain("custom://alpha");
    }
    for (const callId of ["public_templates_a", "public_templates_b"]) {
      expect(toolResultText(finalBody, callId)).toContain(
        "custom://project/{path}",
      );
    }
    for (const callId of ["public_prompts_a", "public_prompts_b"]) {
      expect(toolResultText(finalBody, callId)).toContain("review");
    }
    for (const callId of ["public_read_a", "public_read_b"]) {
      expect(toolResultText(finalBody, callId)).toContain("HTTP_RESOURCE_TEXT");
    }
    const resourceListRequests = auth.requests.filter((request) =>
      request.body.includes('"resources/list"')
    );
    const initialResourceLists = resourceListRequests.filter((request) =>
      request.authorization === `Bearer ${ACCESS_INITIAL}`
    );
    const refreshedResourceLists = resourceListRequests.filter((request) =>
      request.authorization === `Bearer ${ACCESS_REFRESHED}`
    );
    expect(initialResourceLists).toHaveLength(2);
    // A later resource read may cross the failed-refresh backoff and retry once.
    expect(refreshedResourceLists.length).toBeGreaterThanOrEqual(1);
    expect(refreshedResourceLists.length).toBeLessThanOrEqual(2);
    expect(new Set(resourceListRequests.map((request) =>
      (JSON.parse(request.body) as { id: number | string }).id
    )).size).toBe(resourceListRequests.length);
    expect(auth.requests.filter((request) =>
      request.body.includes('"resources/templates/list"')
    )).toHaveLength(2);
    expect(auth.requests.filter((request) =>
      request.body.includes('"prompts/list"')
    )).toHaveLength(2);
    expect(auth.requests.filter((request) =>
      request.body.includes('"resources/read"')
    )).toHaveLength(1);
    expect(auth.requests.filter((request) =>
      request.authorization === `Bearer ${ACCESS_REFRESHED}` &&
      (request.body.includes('"resources/list"') ||
        request.body.includes('"resources/templates/list"') ||
        request.body.includes('"prompts/list"'))
    ).length).toBe(2 + refreshedResourceLists.length);
  }, 40_000);

  for (
    const readCacheCase of [
      { mode: "features_public", publicCache: true },
      { mode: "features", publicCache: false },
    ] as const
  ) {
    test(`${readCacheCase.mode} resource cache orders public lookup before credential refresh`, async () => {
      upstream = startModernMcpHttpFixture(readCacheCase.mode);
      auth = startAuthFixture(upstream.url, { rejectRefresh: true });
      const root = createRoot(auth);
      seedExpiredCredentials(root, auth, Date.now() + 65_000);
      gateway = startFakeGateway([
        fakeGatewayToolCall("ordered_read_a", "mcp_features", {
          action: "resource_read",
          server: "fixture",
          uri: "custom://alpha",
        }),
        async () => {
          await Bun.sleep(6_000);
          return fakeGatewayToolCall("ordered_read_b", "mcp_features", {
            action: "resource_read",
            server: "fixture",
            uri: "custom://alpha",
          });
        },
        fakeGatewayFinalText("Resource cache ordering observed."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the same authenticated MCP resource twice."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 25_000,
        },
      );

      expect(result.code).toBe(0);
      const finalBody = gateway.requests.at(-1)!.body;
      expect(toolResultText(finalBody, "ordered_read_a")).toContain(
        "HTTP_RESOURCE_TEXT",
      );
      const second = toolResultText(
        finalBody,
        "ordered_read_b",
        readCacheCase.publicCache ? "text" : "error-text",
      );
      if (readCacheCase.publicCache) {
        expect(second).toContain("HTTP_RESOURCE_TEXT");
        expect(auth.refreshes).toBeGreaterThanOrEqual(1);
      } else {
        expect(second).not.toContain("HTTP_RESOURCE_TEXT");
        expect(second).toContain("McpRefreshRejected");
        expect(auth.refreshes).toBe(1);
      }
      expect(auth.requests.filter((request) =>
        request.body.includes('"resources/read"')
      )).toHaveLength(1);
    }, 35_000);
  }

  test("active subscription re-establishes with refreshed credentials", async () => {
    upstream = startModernMcpHttpFixture("cache_auth_subscription");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 62_000);
    gateway = startFakeGateway([
        fakeGatewayToolCall("search_initial", "capability_search", {
          query: "echo",
        }),
        async () => {
          await Bun.sleep(3_000);
          return fakeGatewayToolCall("search_refreshed", "capability_search", {
            query: "echo",
          });
        },
        async () => {
          expect(auth!.refreshes).toBe(1);
          upstream!.finishSubscription();
          const listenerDeadline = Date.now() + 10_000;
          while (
            !readFileSync(root.trace, "utf8").includes(
              "tool subscription closed connection_generation=",
            ) && Date.now() < listenerDeadline
          ) {
            await Bun.sleep(25);
          }
          expect(readFileSync(root.trace, "utf8")).toContain(
            "tool subscription closed connection_generation=",
          );
          return fakeGatewayToolCall(
            "search_reconnected",
            "capability_search",
            { query: "echo" },
          );
        },
        fakeGatewayFinalText("Refreshed subscription complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });
    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Refresh the active authenticated subscription."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 30_000,
      },
    );

    expect(result.code).toBe(0);
    expect(auth.refreshes).toBe(1);
    const listens = auth.requests.filter((request) =>
      request.body.includes('"subscriptions/listen"')
    );
    expect(listens).toHaveLength(2);
    expect(listens[0]?.authorization).toBe(`Bearer ${ACCESS_INITIAL}`);
    expect(listens[1]?.authorization).toBe(`Bearer ${ACCESS_REFRESHED}`);
    for (const secret of [ACCESS_INITIAL, ACCESS_REFRESHED]) {
      expect(result.stdout).not.toContain(secret);
      expect(result.stderr).not.toContain(secret);
      expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
    }
  }, 35_000);

  for (const challenge of ["unauthorized", "scope"] as const) {
    test(`subscription recovers from a ${challenge} authentication challenge`, async () => {
      upstream = startModernMcpHttpFixture("cache_invalidate_before_send");
      auth = startAuthFixture(upstream.url, {
        subscriptionChallenge: challenge,
        rotateAuthorizationToken: true,
      });
      const root = createRoot(auth);
      seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
      gateway = startFakeGateway([
        fakeGatewayToolCall("search_after_challenge", "capability_search", {
          query: "echo",
        }),
        async () => {
          const deadline = Date.now() + 10_000;
          while (
            auth!.requests.filter((request) =>
              request.body.includes('"subscriptions/listen"')
            ).length < 2 && Date.now() < deadline
          ) {
            await Bun.sleep(25);
          }
          return fakeGatewayFinalText("Subscription challenge recovered.");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Recover the subscription."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_E2E_MCP_AUTH_AUTOMATE: "1",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.subscriptionRejections).toBe(1);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      const listens = auth.requests.filter((request) =>
        request.body.includes('"subscriptions/listen"')
      );
      expect(listens).toHaveLength(2);
      expect(listens[1]?.authorization).toBe(`Bearer ${ACCESS_REFRESHED}`);
      for (const secret of [ACCESS_INITIAL, ACCESS_REFRESHED]) {
        expect(result.stdout).not.toContain(secret);
        expect(result.stderr).not.toContain(secret);
        expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
      }
    }, 30_000);
  }

  test("private pagination restarts from page one after auth rotation", async () => {
    upstream = startModernMcpHttpFixture("cache_private_pagination_rotation");
    auth = startAuthFixture(upstream.url, {
      rotateOnSecondToolsPage: true,
      rotateAuthorizationToken: true,
    });
    const root = createRoot(auth);
    seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
    gateway = startFakeGateway([
      fakeGatewayToolCall("search_rotated_catalog", "capability_search", {
        query: "fixture",
      }),
      fakeGatewayFinalText("Private pagination rotation complete."),
    ], {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    });

    const result = await runFx(
      ["ask", "--json", "--auto", "--no-save", "Load the rotated private catalog."],
      {
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_E2E_MCP_AUTH_AUTOMATE: "1",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        timeoutMs: 20_000,
      },
    );

    expect(result.code).toBe(0);
    expect(auth.paginationRejections).toBe(1);
    expect(auth.authorizationRequests).toBe(1);
    expect(upstream.toolsListCalls).toBe(4);
    const toolPages = auth.requests.filter((request) =>
      request.body.includes('"tools/list"')
    );
    expect(toolPages.map((request) => request.authorization)).toEqual([
      `Bearer ${ACCESS_INITIAL}`,
      `Bearer ${ACCESS_INITIAL}`,
      `Bearer ${ACCESS_REFRESHED}`,
      `Bearer ${ACCESS_REFRESHED}`,
      `Bearer ${ACCESS_REFRESHED}`,
    ]);
    expect(readFileSync(root.trace, "utf8")).toContain(
      "restarting paginated tool fetch after auth identity change",
    );
    for (const secret of [ACCESS_INITIAL, ACCESS_REFRESHED]) {
      expect(result.stdout).not.toContain(secret);
      expect(result.stderr).not.toContain(secret);
      expect(readFileSync(root.trace, "utf8")).not.toContain(secret);
    }
  }, 30_000);

  for (
    const cacheCase of [
      { mode: "cache_private_identity", expectedLists: 2 },
      { mode: "cache_public_identity", expectedLists: 1 },
    ] as const
  ) {
    test(`${cacheCase.mode} partitions or reuses the Tools snapshot after token rotation`, async () => {
      upstream = startModernMcpHttpFixture(cacheCase.mode);
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      seedExpiredCredentials(root, auth, Date.now() + 65_000);
      gateway = startFakeGateway([
        fakeGatewayToolCall("select_before_refresh", "mcp_select_tool", {
          name: TOOL_NAME,
        }),
        async () => {
          await Bun.sleep(6_000);
          return fakeGatewayToolCall("call_after_skew", TOOL_NAME, {
            text: "rotate",
          });
        },
        fakeGatewayToolCall("search_after_rotation", "capability_search", {
          query: "echo",
        }),
        fakeGatewayFinalText("Authentication cache partition observed."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Exercise the authenticated cache."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.refreshes).toBe(1);
      expect(upstream.toolsListCalls).toBe(cacheCase.expectedLists);
      expect(result.stdout).not.toContain(ACCESS_INITIAL);
      expect(result.stdout).not.toContain(ACCESS_REFRESHED);
      expect(result.stderr).not.toContain(ACCESS_INITIAL);
      expect(result.stderr).not.toContain(ACCESS_REFRESHED);
      expect(readFileSync(root.trace, "utf8")).not.toContain(ACCESS_INITIAL);
      expect(readFileSync(root.trace, "utf8")).not.toContain(ACCESS_REFRESHED);
    }, 30_000);
  }

  test(
    "fx ask isolates failed-server authentication from healthy tool search",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      writeFileSync(
        join(root.home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            linear: {
              type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
              url: upstream.url,
              startup_timeout_ms: 5_000,
              operation_timeout_ms: 5_000,
            },
            slack: {
              type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" },
              url: auth.url,
              oauth: {
                client_id: "fx-mcp-auth-test",
                scopes: ["tools.read"],
              },
              startup_timeout_ms: 5_000,
              operation_timeout_ms: 5_000,
            },
          },
        }),
      );
      gateway = startFakeGateway([
        fakeGatewayToolCall("search_exact", "capability_search", {
          query: "Please use mcp_linear_echo for this request",
        }),
        fakeGatewayToolCall("search_noisy", "capability_search", {
          query: "linear issue",
        }),
        fakeGatewayToolCall("search_auth_collision", "capability_search", {
          query: "slack data",
        }),
        fakeGatewayToolCall("search_targeted", "capability_search", {
          query: "authenticate slack now",
        }),
        fakeGatewayToolCall("search_healthy", "capability_search", {
          query: "linear echo",
        }),
        fakeGatewayFinalText("MCP search isolation observed."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Exercise mixed MCP search."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      const finalBody = gateway.requests.at(-1)?.body ?? "";
      const exact = toolResultText(finalBody, "search_exact");
      expect(exact).toContain("mcp_linear_echo");
      expect(exact).not.toContain("authentication_required");
      const noisy = toolResultText(finalBody, "search_noisy");
      expect(noisy).toContain("mcp_linear_echo");
      expect(noisy).not.toContain("authentication_required");
      const collision = toolResultText(finalBody, "search_auth_collision");
      expect(collision).toContain("authentication_required");
      expect(collision).toContain('\"server\":\"slack\"');
      expect(collision).not.toContain("mcp_linear_echo");
      const targeted = toolResultText(finalBody, "search_targeted");
      expect(targeted).toContain("authentication_required");
      expect(targeted).toContain('\"server\":\"slack\"');
      expect(toolResultText(finalBody, "search_healthy")).toContain(
        "mcp_linear_echo",
      );
      expect(auth.authorizationRequests).toBe(0);
    },
    30_000,
  );

  for (const targeted of [false, true]) test(
    `fx ask reports an actionable auth requirement for ${targeted ? "named" : "broad"} search without opening a browser`,
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth, false);
      gateway = startFakeGateway([
        fakeGatewayToolCall("search_auth", "capability_search", {
          query: "fixture",
          ...(targeted ? { server: "fixture" } : {}),
        }),
        fakeGatewayFinalText("MCP authentication is required."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Find the protected MCP tool."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.authorizationRequests).toBe(0);
      expect(
        auth.requests.filter((request) => request.path === "/mcp"),
      ).toHaveLength(1);
      expect(gateway.requests[1]?.body).toContain("authentication_required");
      expect(gateway.requests[1]?.body).toContain(
        "Run /mcp auth fixture --open in an interactive fx session.",
      );
      expect(
        existsSync(join(root.home, ".fx", "mcp-credentials")),
      ).toBe(false);
    },
    30_000,
  );

  test.skipIf(process.platform !== "darwin" || !tmuxAvailable())(
    "macOS migrates MCP credentials to Keychain and logout deletes them",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const account = `fx-mcp-auth-${process.pid}-${Date.now()}`;
      mkdirSync(join(root.home, "Library"), { recursive: true });
      symlinkSync(
        join(homedir(), "Library", "Keychains"),
        join(root.home, "Library", "Keychains"),
        "dir",
      );
      const credentialPath = seedExpiredCredentials(
        root,
        auth,
        Date.now() + 3_600_000,
      );
      const legacyStore = readFileSync(credentialPath, "utf8");
      const legacyDigest = createHash("sha256").update(legacyStore).digest("hex");
      const keychainEnv = {
        ...baseEnv(root),
        USER: account,
        FX_DISABLE_KEYCHAIN: undefined,
      };

      try {
        gateway = startToolGateway();
        const ask = await runFx(
          ["ask", "--json", "--auto", "--no-save", "Call the authenticated MCP fixture."],
          {
            cwd: root.workspace,
            env: {
              ...keychainEnv,
              FX_GATEWAY_BASE_URL: gateway.baseUrl,
              FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            },
            timeoutMs: 20_000,
          },
        );
        expect(ask.code).toBe(0);
        expect(JSON.parse(ask.stdout).output).toContain(
          "Authenticated MCP call complete.",
        );
        expect(existsSync(credentialPath)).toBe(false);

        const stored = runMcpKeychainProbe(
          "load",
          account,
          MCP_KEYCHAIN_SERVICE,
          root.home,
        );
        expect(stored.status, stored.stderr).toBe(0);
        const storedValue = stored.stdout.trimEnd();
        expect(storedValue.length).toBe(legacyStore.length);
        expect(
          createHash("sha256").update(storedValue).digest("hex"),
        ).toBe(legacyDigest);
        const persisted = JSON.parse(storedValue);
        expect(persisted.credentials[0].access_token).toBe(ACCESS_INITIAL);
        expect(persisted.credentials[0].refresh_token).toBe(REFRESH_INITIAL);

        const profilePath = join(root.home, ".fx", "mcp.json");
        const profile = JSON.parse(readFileSync(profilePath, "utf8"));
        delete profile.mcp.fixture.oauth;
        writeFileSync(profilePath, JSON.stringify(profile));
        const requestCountBeforeList = auth.requests.length;
        const listed = await runFx(["mcp", "list"], {
          cwd: root.workspace,
          env: keychainEnv,
          timeoutMs: 20_000,
        });
        expect(listed.code).toBe(0);
        expect(listed.stderr).toBe("");
        expect(listed.stdout).toMatch(/fixture[\s\S]{0,240}auth=authenticated/);
        expect(auth.requests).toHaveLength(requestCountBeforeList);

        gateway.stop();
        gateway = startFakeGateway([
          fakeGatewayFinalText("TUI idle."),
        ], {
          models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
        });
        tui = await TmuxSession.create({
          isolated: true,
          cwd: root.workspace,
          env: {
            ...keychainEnv,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          width: 110,
          height: 34,
        });
        await tui.waitForComposer(15_000);
        await tui.sendText("/mcp logout fixture");
        await tui.waitForText("Logged out of MCP server 'fixture'.", 10_000);

        const deleted = runMcpKeychainProbe(
          "load",
          account,
          MCP_KEYCHAIN_SERVICE,
          root.home,
        );
        expect(deleted.status).not.toBe(0);
        expect(existsSync(credentialPath)).toBe(false);
        expect(auth.revocations).toBe(2);
        for (const value of [ACCESS_INITIAL, REFRESH_INITIAL]) {
          expect(ask.stdout).not.toContain(value);
          expect(ask.stderr).not.toContain(value);
          expect(readFileSync(root.trace, "utf8")).not.toContain(value);
        }
      } finally {
        runMcpKeychainProbe(
          "delete",
          account,
          MCP_KEYCHAIN_SERVICE,
          root.home,
        );
      }
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "pending browser authentication keeps input responsive and cancels on exit",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth, true, "http", auth.url, false);
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
        stderrPath: root.stderr,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText(
        "Waiting for MCP authentication for 'fixture'.",
        5_000,
      );
      expect(await waitForFile(root.openLog, 5_000)).toBe(true);
      expect(auth.authorizationRequests).toBe(0);

      await tui.sendText("/mcp logout fixture");
      await tui.waitForText(
        "MCP authentication for 'fixture' is still in progress. Wait for it to finish before logging out.",
        5_000,
      );
      await tui.sendText("/mcp list");
      await tui.waitForText("auth=required", 5_000);

      await tui.sendText("/mcp reload");
      await tui.waitForText("MCP reconnection started.", 5_000);
      await tui.waitForText("MCP configuration reloaded", 10_000);
      expect(readFileSync(root.trace, "utf8")).toContain(
        "discarding pending authentication server=fixture reason=reload",
      );

      rmSync(root.openLog, { force: true });
      await tui.sendText("/mcp auth fixture --open");
      expect(await waitForFile(root.openLog, 5_000)).toBe(true);

      await tui.sendKeys("C-c");
      await tui.waitForText("press ctrl+c again to exit", 5_000);
      await tui.sendKeys("C-c");
      expect(await tui.waitForSessionEnd(10_000)).toBe(true);

      const trace = readFileSync(root.trace, "utf8");
      expect(trace).toContain(
        "discarding pending authentication server=fixture reason=shutdown",
      );
      for (const secretMarker of [
        "redirect_uri=",
        "code_verifier",
        "access_token",
        "refresh_token",
      ]) {
        expect(trace).not.toContain(secretMarker);
      }
      expect(
        existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json")),
      ).toBe(false);
      expect(readFileSync(root.stderr, "utf8")).toBe("");
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "pending workspace authentication is blocked and logout deletes local credentials only",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth, true, "http", auth.url, false);
      moveAuthFixtureToWorkspace(root);
      const credentialPath = seedExpiredCredentials(
        root,
        auth,
        Date.now() + 3_600_000,
      );
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 120,
        height: 34,
        stderrPath: root.stderr,
      });
      await tui.waitForComposer(15_000);
      await tui.waitForText(
        "Project MCP server 'fixture' is defined in .mcp.json",
        10_000,
      );
      await tui.sendKeys("Escape");
      await tui.waitForText(
        "Project MCP approval prompts dismissed for this process",
        10_000,
      );

      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText("McpWorkspaceApprovalRequired", 10_000);
      expect(existsSync(root.openLog)).toBe(false);
      expect(auth.authorizationRequests).toBe(0);
      expect(existsSync(credentialPath)).toBe(true);
      await Bun.sleep(250);
      const requestsBeforeLogout = auth.requests.length;

      await tui.sendText("/mcp logout fixture");
      await tui.waitForText("Logged out of MCP server 'fixture'", 10_000);
      await Bun.sleep(250);
      expect(existsSync(credentialPath)).toBe(false);
      expect(auth.revocations).toBe(0);
      expect(auth.requests).toHaveLength(requestsBeforeLogout);
    },
    35_000,
  );

  test("top-level pending workspace auth is blocked and logout stays local", async () => {
    upstream = startModernMcpHttpFixture("json");
    auth = startAuthFixture(upstream.url);
    const root = createRoot(auth, true, "http", auth.url, false);
    moveAuthFixtureToWorkspace(root);
    const credentialPath = seedExpiredCredentials(
      root,
      auth,
      Date.now() + 3_600_000,
    );
    const env = {
      ...baseEnv(root),
      AI_GATEWAY_API_KEY: undefined,
    };

    const authentication = await runFx(["mcp", "auth", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(authentication.code).not.toBe(0);
    expect(authentication.stderr).toContain("McpWorkspaceApprovalRequired");
    expect(existsSync(root.openLog)).toBe(false);
    expect(auth.authorizationRequests).toBe(0);
    expect(existsSync(credentialPath)).toBe(true);
    const requestsBeforeLogout = auth.requests.length;

    const logout = await runFx(["mcp", "logout", "fixture"], {
      cwd: root.workspace,
      env,
      timeoutMs: 20_000,
    });
    expect(logout.code).toBe(0);
    expect(logout.stdout).toContain("Logged out of MCP server 'fixture' locally");
    expect(existsSync(credentialPath)).toBe(false);
    expect(auth.revocations).toBe(0);
    expect(auth.requests).toHaveLength(requestsBeforeLogout);
  }, 30_000);

  test.skipIf(!tmuxAvailable())(
    "reauthentication replaces a modern HTTP connection with an active subscription",
    async () => {
      upstream = startModernMcpHttpFixture("features");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const initial = await runFx(["mcp", "auth", "fixture"], {
        cwd: root.workspace,
        env: baseEnv(root),
        timeoutMs: 20_000,
      });
      expect(initial.code).toBe(0);
      gateway = startToolGateway();
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
      });
      await tui.waitForComposer(15_000);
      await upstream.waitForSubscription();
      const subscriptions = () => upstream!.requests.filter((entry) =>
        entry.message.method === "subscriptions/listen"
      ).length;
      const before = subscriptions();
      expect(before).toBeGreaterThan(0);
      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText("Authenticated MCP server 'fixture'.", 15_000);
      const deadline = Date.now() + 8_000;
      while (subscriptions() === before && Date.now() < deadline) await Bun.sleep(25);
      expect(subscriptions()).toBe(before + 1);
      await tui.sendText("Call the authenticated MCP echo tool.");
      await tui.waitForText("Authenticated MCP call complete.", 15_000);
      expect(upstream.requests.filter((entry) => entry.message.method === "tools/call")).toHaveLength(1);
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "fresh TUI login persists, ask refreshes after restart, and logout revokes",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const profilePath = join(root.home, ".fx", "mcp.json");
      const profile = JSON.parse(readFileSync(profilePath, "utf8"));
      profile.mcp.healthy = { type: "http", environment: { FX_MCP_PROTOCOL_VERSION: "2026-07-28" }, url: upstream.url, headers: { "x-test-healthy": "1" }, startup_timeout_ms: 5_000 };
      writeFileSync(profilePath, JSON.stringify(profile));
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const tuiEnv = {
        ...baseEnv(root),
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      };
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: tuiEnv,
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);

      const healthyDeadline = Date.now() + 10_000;
      while (!upstream.requests.some((entry) => entry.headers["x-test-healthy"] === "1" && entry.message.method === "tools/list") && Date.now() < healthyDeadline) await Bun.sleep(25);
      const healthyRequests = () => upstream!.requests.filter((entry) => entry.headers["x-test-healthy"] === "1").length;
      const healthyBeforeAuth = healthyRequests();
      expect(healthyBeforeAuth).toBeGreaterThan(0);
      await tui.sendText("/mcp auth fixture");
      await tui.waitForText(
        "Run /mcp auth fixture --open to confirm opening your browser.",
        5_000,
      );
      expect(auth.authorizationRequests).toBe(0);
      await tui.waitForComposer(5_000);

      const beforeMenu = await tui.captureFullScrollback();
      await tui.sendText("/mcp");
      const menu = await tui.waitForText("Needs authentication", 10_000);
      expect(menu).toContain("fixture");
      await tui.sendKeys("Enter");
      await tui.waitForText("Profile · ~/.fx/mcp.json", 5_000);
      await tui.sendKeys("Enter");
      const authDeadline = Date.now() + 10_000;
      while (auth.authorizationRequests === 0 && Date.now() < authDeadline) {
        await Bun.sleep(25);
      }
      expect(auth.authorizationRequests).toBe(1);
      const tokenDeadline = Date.now() + 10_000;
      while (auth.tokenExchanges === 0 && Date.now() < tokenDeadline) {
        await Bun.sleep(25);
      }
      expect(auth.tokenExchanges).toBe(1);
      await tui.waitForText("Authenticated MCP server 'fixture'.", 15_000);
      expect(healthyRequests()).toBe(healthyBeforeAuth);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      const credentialPath = join(
        root.home,
        ".fx",
        "mcp-credentials",
        "credentials.json",
      );
      expect(existsSync(credentialPath)).toBe(true);
      let stored = JSON.parse(readFileSync(credentialPath, "utf8"));
      expect(stored.credentials[0].access_token).toBe(ACCESS_INITIAL);

      await tui.sendKeys("Escape");
      await tui.waitForText("Enter Inspect", 5_000);
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
      expect(await tui.captureFullScrollback()).toBe(beforeMenu);

      await tui.kill();
      tui = null;
      gateway.stop();
      gateway = startToolGateway();
      stored.credentials[0].expires_at_ms = 0;
      writeFileSync(credentialPath, JSON.stringify(stored), { mode: 0o600 });

      const ask = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the authenticated MCP fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );
      expect(ask.code).toBe(0);
      expect(JSON.parse(ask.stdout).output).toContain(
        "Authenticated MCP call complete.",
      );
      expect(auth.refreshes).toBe(1);
      const modernRequests = auth.requests.filter(
        (request) => request.path === "/mcp",
      );
      expect(modernRequests.length).toBeGreaterThan(0);
      for (const request of modernRequests) {
        expect(request.method).toBe("POST");
        expect(request.sessionId).toBeNull();
        expect(request.lastEventId).toBeNull();
      }
      stored = JSON.parse(readFileSync(credentialPath, "utf8"));
      expect(stored.credentials[0].access_token).toBe(ACCESS_REFRESHED);
      expect(stored.credentials[0].refresh_token).toBe(REFRESH_ROTATED);

      gateway.stop();
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);
      await tui.sendText("/mcp");
      const summary = await tui.waitForText("MCP 2", 5_000);
      expect(summary).toContain("fixture");
      expect(summary).toContain("Ready");
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
      await tui.sendText("/mcp list");
      const status = await tui.waitForText("auth=authenticated", 5_000);
      expect(status).not.toContain(ACCESS_REFRESHED);
      const beforeLogoutMenu = await tui.captureFullScrollback();
      await tui.sendText("/mcp");
      await tui.waitForText("[Servers]", 5_000);
      await tui.sendKeys("Enter");
      await tui.waitForText("Profile · ~/.fx/mcp.json", 5_000);
      await tui.sendKeys("L");
      await tui.waitForText("Log out of this MCP server?", 5_000);
      await tui.sendKeys("Enter");
      await tui.waitForText("Logged out of MCP server 'fixture'.", 15_000);
      expect(existsSync(credentialPath)).toBe(false);
      expect(auth.revocations).toBe(2);
      await tui.sendKeys("Escape");
      await tui.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
      expect(await tui.captureFullScrollback()).toBe(beforeLogoutMenu);
      await tui.kill();
      tui = null;

      const trace = readFileSync(root.trace, "utf8");
      for (
        const secret of [
          ACCESS_INITIAL,
          ACCESS_REFRESHED,
          REFRESH_INITIAL,
          REFRESH_ROTATED,
        ]
      ) {
        expect(trace).not.toContain(secret);
        expect(status).not.toContain(secret);
        expect(ask.stdout).not.toContain(secret);
        expect(ask.stderr).not.toContain(secret);
        for (const path of collectRegularFiles(root.root)) {
          expect(readFileSync(path).toString("utf8")).not.toContain(secret);
        }
      }
    },
    60_000,
  );

  test.skipIf(!tmuxAvailable())(
    "authorization metadata accepts a trailing-slash discrepancy",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, {
        authorizationServerTrailingSlash: true,
      });
      const root = createRoot(auth);
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 120,
        height: 34,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText("Authenticated MCP server 'fixture'.", 15_000);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      expect(existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json")))
        .toBe(true);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "authorization response issuer mismatch names the response and preserves the trust boundary",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, {
        authorizationResponseTrailingSlash: true,
      });
      const returnedIssuer = `${new URL(auth.url).origin}/`;
      const root = createRoot(auth);
      gateway = startFakeGateway([], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 140,
        height: 36,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp auth fixture --open");
      const mismatch = await tui.waitForText("was rejected", 15_000);
      const compactMismatch = mismatch.replace(/\s+/g, " ");
      expect(compactMismatch).toContain("authorization response returned issuer");
      expect(compactMismatch).toContain(returnedIssuer);
      expect(compactMismatch).toContain("stopped before token exchange");
      expect(compactMismatch).toContain("Contact the MCP server provider");
      expect(compactMismatch).not.toContain('Add "oauth":{"issuer":');
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(0);
      expect(existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json")))
        .toBe(false);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "state mismatch rejects the callback before token exchange or persistence",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, { wrongState: true });
      const root = createRoot(auth);
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);
      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText("OAuthStateMismatch", 15_000);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(0);
      expect(
        existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json")),
      ).toBe(false);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "non-JSON authorization metadata is rejected before browser authorization",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, {
        authorizationMetadataContentType: "text/plain",
      });
      const root = createRoot(auth);
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);
      await tui.sendText("/mcp auth fixture --open");
      await tui.waitForText("InvalidOAuthResponseContentType", 15_000);
      expect(auth.authorizationRequests).toBe(0);
      expect(auth.tokenExchanges).toBe(0);
      expect(
        existsSync(join(root.home, ".fx", "mcp-credentials", "credentials.json")),
      ).toBe(false);
    },
    30_000,
  );

  test(
    "scoped HTTP authentication effects fail closed across authority changes",
    async () => {
      for (const mode of ["expired", "challenge"] as const) {
        upstream = startModernMcpHttpFixture("json");
        const fixtureOptions: {
          rejectToolAuth?: boolean;
          challengeMarkerPath?: string;
        } = mode === "challenge"
          ? { rejectToolAuth: true, challengeMarkerPath: "" }
          : {};
        auth = startAuthFixture(upstream.url, fixtureOptions);
        const root = createRoot(auth);
        const markerPath = join(root.root, `${mode}-authority-revoked`);
        fixtureOptions.challengeMarkerPath = markerPath;
        const credentialPath = seedExpiredCredentials(
          root,
          auth,
          Date.now() + 3_600_000,
        );
        const storedBefore = readFileSync(credentialPath, "utf8");

        const proc = Bun.spawn(
          [
            "zig",
            "build",
            "run-mcp-stdio-dispatcher-e2e",
            "--",
            "runtime-scoped-http-auth",
            auth.url,
            markerPath,
            mode,
          ],
          {
            cwd: REPO_ROOT,
            env: {
              ...process.env,
              ...baseEnv(root),
              FX_E2E_MCP_AUTH_AUTOMATE: "1",
            },
            stdout: "pipe",
            stderr: "pipe",
          },
        );
        const [stdout, stderr, code] = await Promise.all([
          new Response(proc.stdout).text(),
          new Response(proc.stderr).text(),
          proc.exited,
        ]);
        expect(code, stderr).toBe(0);
        const result = JSON.parse(stdout.trim()) as {
          mode: string;
          error: string;
          auth_generation: number;
          challenge_present: boolean;
          resolutions: number;
        };
        expect(result.mode).toBe(mode);
        expect(result.error).toBe(
          mode === "expired"
            ? "McpAuthenticationRequired"
            : "McpAuthorityChanged",
        );
        expect(result.auth_generation).toBe(0);
        expect(result.challenge_present).toBe(false);
        expect(result.resolutions).toBeGreaterThan(0);
        expect(auth.refreshes).toBe(0);
        expect(auth.authorizationRequests).toBe(0);
        expect(auth.tokenExchanges).toBe(0);
        expect(readFileSync(credentialPath, "utf8")).toBe(storedBefore);

        if (mode === "expired") {
          expect(auth.protectedToolCalls).toBe(0);
          expect(existsSync(markerPath)).toBe(false);
        } else {
          expect(auth.protectedToolCalls).toBe(1);
          expect(existsSync(markerPath)).toBe(true);
          expect(
            upstream.requests.filter((request) =>
              request.message.method === "tools/call"
            ),
          ).toHaveLength(0);
        }

        const evidenceDir = process.env.FX_S11_EVIDENCE_DIR;
        if (evidenceDir) {
          mkdirSync(evidenceDir, { recursive: true });
          writeFileSync(
            join(evidenceDir, `http-auth-${mode}.json`),
            JSON.stringify({
              result,
              refreshes: auth.refreshes,
              authorizationRequests: auth.authorizationRequests,
              tokenExchanges: auth.tokenExchanges,
              protectedToolCalls: auth.protectedToolCalls,
              upstreamToolCalls: upstream.requests.filter((request) =>
                request.message.method === "tools/call"
              ).length,
              credentialStoreUnchanged:
                readFileSync(credentialPath, "utf8") === storedBefore,
            }, null, 2),
          );
        }

        auth.stop();
        auth = null;
        upstream.stop();
        upstream = null;
        rmSync(root.root, { recursive: true, force: true });
        cleanupRoot = null;
      }
    },
    60_000,
  );

  test(
    "scope escalation updates credentials without replaying a modern tool call",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, { rejectToolAuth: true });
      const root = createRoot(auth);
      seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
      gateway = startToolGateway();

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the protected MCP fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_MCP_AUTH_AUTOMATE: "1",
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.protectedToolCalls).toBe(1);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      expect(
        upstream.requests.filter((request) =>
          request.message.method === "tools/call"
        ),
      ).toHaveLength(0);
      expect(gateway.requests[2]?.body).toContain("McpAuthenticationUpdated");
    },
    30_000,
  );

  test(
    "legacy Streamable HTTP refreshes expired credentials before initialization",
    async () => {
      legacyStreamable = startLegacyStreamableHttpFixture("2025-11-25");
      auth = startAuthFixture(legacyStreamable.url);
      const root = createRoot(auth);
      seedExpiredCredentials(root, auth);
      gateway = startToolGateway();

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the protected legacy fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.refreshes).toBe(1);
      expect(legacyStreamable.initializeCalls).toBe(1);
      expect(legacyStreamable.toolCallCalls).toBe(1);
      for (
        const request of auth.requests.filter((entry) => entry.path === "/mcp")
      ) {
        expect(request.authorization).toBe(`Bearer ${ACCESS_REFRESHED}`);
      }
    },
    30_000,
  );

  test(
    "legacy HTTP+SSE refreshes expired credentials before endpoint discovery",
    async () => {
      legacySse = startLegacyHttpSseFixture();
      auth = startAuthFixture(legacySse.url, { transport: "sse" });
      const root = createRoot(auth, true, "sse");
      seedExpiredCredentials(root, auth);
      gateway = startToolGateway();

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the protected SSE fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.refreshes).toBe(1);
      expect(legacySse.discoveryGets).toBe(1);
      expect(
        legacySse.requests.filter((request) =>
          request.message?.method === "tools/call"
        ),
      ).toHaveLength(1);
      for (
        const request of auth.requests.filter((entry) =>
          entry.path === "/sse" || entry.path === "/messages"
        )
      ) {
        expect(request.authorization).toBe(`Bearer ${ACCESS_REFRESHED}`);
      }
    },
    30_000,
  );

  test(
    "legacy refresh network work releases auth and connection locks",
    async () => {
      legacyStreamable = startLegacyStreamableHttpFixture("2025-11-25");
      const fixtureOptions: {
        refreshBarrierStartedPath?: string;
        refreshBarrierReleasePath?: string;
      } = {};
      auth = startAuthFixture(legacyStreamable.url, fixtureOptions);
      const root = createRoot(auth);
      const refreshStartedPath = join(root.root, "refresh-started");
      const refreshReleasePath = join(root.root, "refresh-release");
      fixtureOptions.refreshBarrierStartedPath = refreshStartedPath;
      fixtureOptions.refreshBarrierReleasePath = refreshReleasePath;
      seedExpiredCredentials(root, auth, Date.now() + 3_600_000);

      const proc = Bun.spawn(
        [
          "zig",
          "build",
          "run-mcp-stdio-dispatcher-e2e",
          "--",
          "runtime-legacy-refresh-locks",
          auth.url,
          refreshStartedPath,
          refreshReleasePath,
        ],
        {
          cwd: REPO_ROOT,
          env: {
            ...process.env,
            ...baseEnv(root),
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(code, stderr).toBe(0);
      const result = JSON.parse(stdout.trim()) as {
        auth_lock_available: boolean;
        connection_lock_available: boolean;
        initial_auth_generation: number;
        final_auth_generation: number;
      };
      expect(result.auth_lock_available).toBe(true);
      expect(result.connection_lock_available).toBe(true);
      expect(result.final_auth_generation).toBe(
        result.initial_auth_generation + 1,
      );
      expect(existsSync(refreshStartedPath)).toBe(true);
      expect(existsSync(refreshReleasePath)).toBe(true);
      expect(auth.refreshes).toBe(1);
      expect(legacyStreamable.initializeCalls).toBe(2);
      expect(legacyStreamable.toolCallCalls).toBe(1);
    },
    30_000,
  );

  test(
    "logout cannot persist an in-flight legacy credential refresh",
    async () => {
      legacyStreamable = startLegacyStreamableHttpFixture("2025-11-25");
      const fixtureOptions: {
        refreshBarrierStartedPath?: string;
        refreshBarrierReleasePath?: string;
      } = {};
      auth = startAuthFixture(legacyStreamable.url, fixtureOptions);
      const root = createRoot(auth);
      const refreshStartedPath = join(root.root, "logout-refresh-started");
      const refreshReleasePath = join(root.root, "logout-refresh-release");
      fixtureOptions.refreshBarrierStartedPath = refreshStartedPath;
      fixtureOptions.refreshBarrierReleasePath = refreshReleasePath;
      seedExpiredCredentials(root, auth, Date.now() + 3_600_000);
      const credentialStorePath = join(
        root.home,
        ".fx",
        "mcp-credentials",
        "credentials.json",
      );

      const proc = Bun.spawn(
        [
          "zig",
          "build",
          "run-mcp-stdio-dispatcher-e2e",
          "--",
          "runtime-logout-refresh-race",
          auth.url,
          refreshStartedPath,
          refreshReleasePath,
          credentialStorePath,
        ],
        {
          cwd: REPO_ROOT,
          env: {
            ...process.env,
            ...baseEnv(root),
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(code, stderr).toBe(0);
      expect(JSON.parse(stdout.trim())).toEqual({
        logout_removed: true,
        store_present_while_auth_locked: true,
        credentials_reloaded_after_restart: false,
      });
      expect(existsSync(refreshStartedPath)).toBe(true);
      expect(existsSync(refreshReleasePath)).toBe(true);
      expect(auth.refreshes).toBe(1);
    },
    30_000,
  );

  test(
    "interactive browser work releases MCP auth and catalog locks",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const authStartedPath = join(root.root, "interactive-auth-started");
      const authReleasePath = join(root.root, "interactive-auth-release");

      const proc = Bun.spawn(
        [
          "zig",
          "build",
          "run-mcp-stdio-dispatcher-e2e",
          "--",
          "runtime-interactive-auth-locks",
          auth.url,
          authStartedPath,
          authReleasePath,
        ],
        {
          cwd: REPO_ROOT,
          env: {
            ...process.env,
            ...baseEnv(root),
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(code, stderr).toBe(0);
      expect(JSON.parse(stdout.trim())).toEqual({
        auth_lock_available: true,
        catalog_lock_available: true,
        credentials_published: false,
      });
      expect(existsSync(authStartedPath)).toBe(true);
      expect(existsSync(authReleasePath)).toBe(true);
      expect(auth.authorizationRequests).toBe(0);
      expect(auth.tokenExchanges).toBe(0);
    },
    30_000,
  );

  test(
    "runtime retirement cancels an interactive authorization callback wait",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth);
      const authStartedPath = join(root.root, "retiring-auth-started");

      const proc = Bun.spawn(
        [
          "zig",
          "build",
          "run-mcp-stdio-dispatcher-e2e",
          "--",
          "runtime-interactive-auth-retirement",
          auth.url,
          authStartedPath,
        ],
        {
          cwd: REPO_ROOT,
          env: {
            ...process.env,
            ...baseEnv(root),
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(code, stderr).toBe(0);
      const result = JSON.parse(stdout.trim()) as {
        error: string;
        elapsed_ms: number;
        credentials_published: boolean;
      };
      expect(result.error).toBe("Cancelled");
      expect(result.elapsed_ms).toBeLessThan(1_000);
      expect(result.credentials_published).toBe(false);
      expect(existsSync(authStartedPath)).toBe(true);
      expect(auth.authorizationRequests).toBe(0);
      expect(auth.tokenExchanges).toBe(0);
    },
    30_000,
  );

  for (
    const version of [
      "2025-11-25",
      "2025-06-18",
      "2025-03-26",
    ] as const
  ) {
    test(
      `legacy Streamable HTTP ${version} reconnects before a call when credentials enter refresh skew`,
      async () => {
        legacyStreamable = startLegacyStreamableHttpFixture(version);
        auth = startAuthFixture(legacyStreamable.url);
        const root = createRoot(auth);
        seedExpiredCredentials(root, auth, Date.now() + 65_000);
        gateway = startDelayedToolGateway(
          6_000,
          "Legacy HTTP refresh complete.",
        );

        const result = await runFx(
          ["ask", "--json", "--auto", "--no-save", "Call the protected legacy fixture."],
          {
            cwd: root.workspace,
            env: {
              ...baseEnv(root),
              FX_GATEWAY_BASE_URL: gateway.baseUrl,
              FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            },
            timeoutMs: 25_000,
          },
        );

        expect(result.code).toBe(0);
        expect(auth.refreshes).toBe(1);
        expect(legacyStreamable.initializeCalls).toBe(2);
        expect(legacyStreamable.toolCallCalls).toBe(1);
        const protectedRequests = auth.requests.filter((request) =>
          request.path === "/mcp"
        );
        expect(protectedRequests.some((request) =>
          request.authorization === `Bearer ${ACCESS_INITIAL}`
        )).toBe(true);
        expect(protectedRequests.at(-1)?.authorization).toBe(
          `Bearer ${ACCESS_REFRESHED}`,
        );
      },
      35_000,
    );
  }

  test(
    "legacy HTTP+SSE reconnects before a call when credentials enter refresh skew",
    async () => {
      legacySse = startLegacyHttpSseFixture();
      auth = startAuthFixture(legacySse.url, { transport: "sse" });
      const root = createRoot(auth, true, "sse");
      seedExpiredCredentials(root, auth, Date.now() + 65_000);
      gateway = startDelayedToolGateway(
        8_000,
        "Legacy SSE refresh complete.",
      );

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Call the protected SSE fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 25_000,
        },
      );

      expect(result.code).toBe(0);
      expect(auth.refreshes).toBe(1);
      expect(legacySse.discoveryGets).toBe(2);
      expect(
        legacySse.requests.filter((request) =>
          request.message?.method === "tools/call"
        ),
      ).toHaveLength(1);
      const protectedRequests = auth.requests.filter((request) =>
        request.path === "/sse" || request.path === "/messages"
      );
      expect(protectedRequests.some((request) =>
        request.authorization === `Bearer ${ACCESS_INITIAL}`
      )).toBe(true);
      expect(protectedRequests.at(-1)?.authorization).toBe(
        `Bearer ${ACCESS_REFRESHED}`,
      );
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "TUI cancellation interrupts an in-flight credential refresh before the MCP call",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, { stallRefresh: true });
      const root = createRoot(auth);
      const credentialPath = seedExpiredCredentials(
        root,
        auth,
        Date.now() + 65_000,
      );
      gateway = startRefreshRecoveryGateway(8_000);
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("Call the protected MCP fixture.");
      const refreshDeadline = Date.now() + 15_000;
      while (auth.refreshes === 0 && Date.now() < refreshDeadline) {
        await Bun.sleep(25);
      }
      expect(auth.refreshes).toBe(1);

      await tui.sendKeys("Escape");
      await tui.waitForText(`Cancelled ${TOOL_NAME}`, 10_000);
      const cancelDeadline = Date.now() + 5_000;
      while (
        auth.refreshCancellations === 0 &&
        Date.now() < cancelDeadline
      ) {
        await Bun.sleep(25);
      }

      expect(auth.refreshCancellations).toBe(1);
      expect(auth.protectedToolCalls).toBe(0);
      expect(upstream.requests).toHaveLength(2);
      const stored = readFileSync(credentialPath, "utf8");
      expect(stored).toContain(ACCESS_INITIAL);
      expect(stored).not.toContain(ACCESS_REFRESHED);
      await tui.waitForComposer(10_000);

      await tui.sendText("Retry the protected MCP fixture.");
      await tui.waitForText("Refresh recovery complete.", 15_000);
      expect(auth.refreshes).toBe(2);
      expect(auth.protectedToolCalls).toBe(1);
      expect(readFileSync(credentialPath, "utf8")).toContain(ACCESS_REFRESHED);
    },
    45_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy Streamable HTTP logout closes its session and permits sign-in from the inspector",
    async () => {
      legacyStreamable = startLegacyStreamableHttpFixture("2025-06-18");
      auth = startAuthFixture(legacyStreamable.url);
      const root = createRoot(auth);
      const credentialPath = seedExpiredCredentials(
        root,
        auth,
        Date.now() + 3_600_000,
      );
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp logout fixture");
      await tui.waitForText("Logged out of MCP server 'fixture'.", 10_000);

      expect(legacyStreamable.deleteCalls).toBe(1);
      const deleteRequest = auth.requests.find((request) =>
        request.method === "DELETE" && request.path === "/mcp"
      );
      expect(deleteRequest?.authorization).toBe(`Bearer ${ACCESS_INITIAL}`);
      expect(existsSync(credentialPath)).toBe(false);
      await tui.sendText("/mcp");
      await tui.waitForPane((pane) => /fixture\s+Disconnected/.test(pane), 5_000);
      expect(auth.authorizationRequests).toBe(0);
      await tui.sendKeys("Enter");
      await tui.waitForText("Enter Sign in", 5_000);
      expect(await tui.capturePane()).toMatch(/State\s+Disconnected/);

      await tui.sendKeys("Enter");
      await tui.waitForPane((pane) => /State\s+Ready/.test(pane), 15_000);
      expect(auth.authorizationRequests).toBe(1);
      expect(auth.tokenExchanges).toBe(1);
      expect(existsSync(credentialPath)).toBe(true);
      expect(gateway.requests).toHaveLength(0);
    },
    30_000,
  );

  test.skipIf(!tmuxAvailable())(
    "logout without stored credentials preserves the live server",
    async () => {
      upstream = startModernMcpHttpFixture("cache_auth_subscription");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth, false, "http", upstream.url);
      gateway = startToolGateway();
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
        stderrPath: join(root.root, "tui-stderr.log"),
        remainOnExit: true,
      });
      try {
        await tui.waitForComposer(15_000);
        const listenerDeadline = Date.now() + 10_000;
        while (
          upstream.requests.filter((request) =>
            request.message.method === "subscriptions/listen"
          ).length < 1 && Date.now() < listenerDeadline
        ) {
          await Bun.sleep(25);
        }
        expect(
          upstream.requests.filter((request) =>
            request.message.method === "subscriptions/listen"
          ),
        ).toHaveLength(1);

        await tui.sendText("/mcp logout fixture");
        await tui.waitForText(
          "No stored MCP credentials found for 'fixture'.",
          10_000,
        );
        expect(upstream.cancelledCalls).toBe(0);
        await tui.waitForComposer(10_000);
        await tui.sendText("Call the still-connected MCP fixture.");
        await tui.waitForText("Authenticated MCP call complete.", 15_000);
        expect(tui.paneStatus()).toEqual({ dead: false, status: null });

        expect(
          upstream.requests.filter((request) =>
            request.message.method === "tools/call"
          ),
        ).toHaveLength(1);
        upstream.finishSubscription();
      } catch (error) {
        await preserveAuthTuiFailure("logout-without-store", root, error);
      }
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "logout store failure preserves the live server",
    async () => {
      upstream = startModernMcpHttpFixture("cache_auth_subscription");
      auth = startAuthFixture(upstream.url);
      const root = createRoot(auth, false, "http", upstream.url);
      gateway = startToolGateway();
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
        stderrPath: join(root.root, "tui-stderr.log"),
        remainOnExit: true,
      });
      try {
        await tui.waitForComposer(15_000);
        const listenerDeadline = Date.now() + 10_000;
        while (
          upstream.requests.filter((request) =>
            request.message.method === "subscriptions/listen"
          ).length < 1 && Date.now() < listenerDeadline
        ) {
          await Bun.sleep(25);
        }
        expect(
          upstream.requests.filter((request) =>
            request.message.method === "subscriptions/listen"
          ),
        ).toHaveLength(1);

        const credentialDirectory = join(
          root.home,
          ".fx",
          "mcp-credentials",
        );
        mkdirSync(credentialDirectory, { recursive: true, mode: 0o700 });
        writeFileSync(
          join(credentialDirectory, "credentials.json"),
          "{",
          { mode: 0o600 },
        );
        await tui.sendText("/mcp logout fixture");
        await tui.waitForText("MCP logout for 'fixture' failed:", 10_000);
        await tui.waitForComposer(10_000);
        await tui.sendText("Call the still-connected MCP fixture.");
        await tui.waitForText("Authenticated MCP call complete.", 15_000);
        expect(tui.paneStatus()).toEqual({ dead: false, status: null });

        expect(
          upstream.requests.filter((request) =>
            request.message.method === "tools/call"
          ),
        ).toHaveLength(1);
        expect(upstream.cancelledCalls).toBe(0);
        upstream.finishSubscription();
      } catch (error) {
        await preserveAuthTuiFailure("logout-store-failure", root, error);
      }
    },
    35_000,
  );

  test.skipIf(!tmuxAvailable())(
    "legacy HTTP+SSE logout joins its reader and deletes stored credentials",
    async () => {
      legacySse = startLegacyHttpSseFixture();
      auth = startAuthFixture(legacySse.url, { transport: "sse" });
      const root = createRoot(auth, true, "sse");
      const credentialPath = seedExpiredCredentials(
        root,
        auth,
        Date.now() + 3_600_000,
      );
      gateway = startFakeGateway([
        fakeGatewayFinalText("TUI idle."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        env: {
          ...baseEnv(root),
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
        width: 110,
        height: 34,
      });
      await tui.waitForComposer(15_000);

      await tui.sendText("/mcp logout fixture");
      await tui.waitForText("Logged out of MCP server 'fixture'.", 10_000);
      const cancelDeadline = Date.now() + 5_000;
      while (
        auth.proxyStreamCancellations === 0 &&
        Date.now() < cancelDeadline
      ) {
        await Bun.sleep(25);
      }

      expect(auth.proxyStreamCancellations).toBe(1);
      expect(existsSync(credentialPath)).toBe(false);
    },
    30_000,
  );

  test(
    "expired refresh rejection does not send or replay an MCP operation",
    async () => {
      upstream = startModernMcpHttpFixture("json");
      auth = startAuthFixture(upstream.url, { rejectRefresh: true });
      const root = createRoot(auth);
      const credentialPath = seedExpiredCredentials(root, auth);
      gateway = startFakeGateway([
        fakeGatewayToolCall("inspect_refresh_rejection", "capability_search", {
          query: "echo",
        }),
        fakeGatewayFinalText("Refresh failure handled."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Check the MCP fixture."],
        {
          cwd: root.workspace,
          env: {
            ...baseEnv(root),
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          },
          timeoutMs: 20_000,
        },
      );
      expect(result.code).toBe(0);
      expect(auth.refreshes).toBe(1);
      expect(upstream.requests).toHaveLength(0);
      expect(readFileSync(credentialPath, "utf8")).toContain(REFRESH_INITIAL);
      expect(result.stdout).not.toContain(REFRESH_INITIAL);
      expect(result.stderr).not.toContain(REFRESH_INITIAL);
      expect(readFileSync(root.trace, "utf8")).not.toContain(REFRESH_INITIAL);
    },
    30_000,
  );
});
