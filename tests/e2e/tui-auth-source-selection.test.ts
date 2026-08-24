import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
if (process.env.FX_REQUIRE_TMUX === "1" && !HAS_TMUX) {
  throw new Error("tmux is required for tui-auth-source-selection.test.ts");
}

const tmuxTest = test.skipIf(!HAS_TMUX);
const profileStoredKeyTmuxTest = test.skipIf(!HAS_TMUX || process.platform === "darwin");
const TIMEOUT = 30_000;
const ENV_TOKEN = "env-api-key-token";
const LOGIN_TOKEN = "fx-login-token";
const STORED_TOKEN = "stored-api-key-token";
const LOGIN_RESPONSE = "LOGIN_SOURCE_RESPONSE";
const STORED_RESPONSE = "STORED_SOURCE_RESPONSE";
const ENV_RESPONSE = "ENV_SOURCE_RESPONSE";
const RESTART_RESPONSE = "RESTART_SOURCE_RESPONSE";
const DIRECT_LOGIN_RESPONSE = "DIRECT_LOGIN_RESPONSE";
const LOGOUT_FALLBACK_RESPONSE = "LOGOUT_FALLBACK_RESPONSE";
const REFRESH_RECOVERY_RESPONSE = "REFRESH_RECOVERY_RESPONSE";
const ACQUIRED_LOGIN_TOKEN = "acquired-login-token";

function grokSubscriptionModel(id: string, contextWindow: number, efforts: string[] = []) {
  return {
    id,
    model: id,
    api_backend: "responses",
    context_window: contextWindow,
    supports_reasoning_effort: efforts.length > 0,
    reasoning_efforts: efforts.map((value) => ({ value })),
  };
}

function grokModalityModel(id: string, vision: boolean) {
  return {
    id,
    input_modalities: vision ? ["text", "image"] : ["text"],
    output_modalities: ["text"],
  };
}

let session: TmuxSession | null = null;
let home: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let oauth: ReturnType<typeof startFakeOAuth> | null = null;
let chatgptOauth: ReturnType<typeof startFakeChatGptOAuth> | null = null;
let creditsGateway: ReturnType<typeof startFakeCreditsGateway> | null = null;
let catcher: ReturnType<typeof startRequestCatcher> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  oauth?.stop();
  oauth = null;
  chatgptOauth?.stop();
  chatgptOauth = null;
  creditsGateway?.stop();
  creditsGateway = null;
  catcher?.stop();
  catcher = null;
  if (home) rmSync(home, { recursive: true, force: true });
  home = null;
  stderrPath = null;
});

function writeSeededChatGptLogin(testHome: string, accessToken = chatgptAccessToken()): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "chatgpt-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "chatgpt-refresh",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: "acct_e2e",
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function writeSeededGrokLogin(testHome: string, accessToken: string, accountId = "acct_grok_e2e"): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "grok-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "grok-refresh",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: accountId,
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function readSingleUsageSnapshot(testHome: string): {
  billing: string;
  next_sequence: number;
  settled_through_sequence: number;
  pending: unknown[];
} {
  const sessionsDir = join(testHome, ".fx", "sessions");
  const usagePaths = readdirSync(sessionsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(sessionsDir, entry.name, "usage-v2.json"))
    .filter((path) => existsSync(path));
  expect(usagePaths).toHaveLength(1);
  return (JSON.parse(readFileSync(usagePaths[0]!, "utf8")) as {
    snapshot: {
      billing: string;
      next_sequence: number;
      settled_through_sequence: number;
      pending: unknown[];
    };
  }).snapshot;
}

function writeSeededFxLogin(
  testHome: string,
  expiresAtMs = Date.now() + 60 * 60 * 1000,
  issuer = "https://vercel.com",
  teamId?: string,
): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "auth.json");
  const auth: Record<string, string | number> = {
    version: 1,
    issuer,
    client_id: "test-client",
    access_token: LOGIN_TOKEN,
    refresh_token: "seeded-refresh-token",
    expires_at_ms: expiresAtMs,
    scope: "openid",
    token_type: "Bearer",
  };
  if (teamId) {
    auth.team_id = teamId;
    auth.team_slug = "example-internal-team";
  }
  writeFileSync(authPath, JSON.stringify(auth) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

async function startFx(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  oauthIssuerUrl?: string,
  tracePath?: string,
  envOverrides: Record<string, string | undefined> = {},
  cwd?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: FX_BIN,
    cwd,
    env: {
      HOME: testHome,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${fakeGateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_OAUTH_CLIENT_ID: "test-client",
      FX_E2E_OAUTH_ISSUER_URL: oauthIssuerUrl,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: tracePath ? "auth,prompt" : undefined,
      ...envOverrides,
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

function startRequestCatcher() {
  const requests: Array<{ method: string; path: string }> = [];
  const server = Bun.serve({
    hostname: "0.0.0.0",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      requests.push({ method: request.method, path: url.pathname });
      return Response.json({ revoked: true });
    },
  });
  return {
    endpoint: `http://localhost.:${server.port}/oauth/revoke`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function startFakeCreditsGateway() {
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      requests.push({
        method: request.method,
        path: new URL(request.url).pathname,
        authorization: request.headers.get("authorization"),
      });
      return Response.json({ balance: "42", used: "7", plan: "pro" });
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}/v1/credits`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function startFakeOAuth(
  accessToken: string | null,
  revocationEndpoint?: string,
  tokenExpiresIn = 3600,
  successfulTokenResponses = Number.POSITIVE_INFINITY,
  options: {
    deviceError?: string;
    rejectAllDeviceClients?: boolean;
    tokenDelayMs?: number;
    teams?: Array<{ id: string; slug: string; name: string }>;
  } = {},
) {
  const providerDetail = `provider rejected ${LOGIN_TOKEN}, ${ENV_TOKEN}, and seeded-refresh-token`;
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    clientId?: string;
    revocation?: { tokenTypeHint: string; validForm: boolean };
  }> = [];
  let tokenResponseCount = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
      });
      const recordedRequest = requests[requests.length - 1];
      const baseUrl = `http://127.0.0.1:${server.port}`;
      switch (url.pathname) {
        case "/.well-known/openid-configuration":
          return Response.json({
            issuer: baseUrl,
            device_authorization_endpoint: `${baseUrl}/oauth/device`,
            token_endpoint: `${baseUrl}/oauth/token`,
            revocation_endpoint:
              revocationEndpoint ?? `${baseUrl}/oauth/revoke`,
          });
        case "/oauth/device": {
          const form = await request.formData();
          const clientId = form.get("client_id");
          recordedRequest.clientId = typeof clientId === "string" ? clientId : undefined;
          if (
            options.deviceError &&
            (options.rejectAllDeviceClients || clientId === "test-client")
          ) {
            return Response.json({
              error: options.deviceError,
              error_description: providerDetail,
            }, { status: 400 });
          }
          return Response.json({
            device_code: "device-code",
            user_code: "TEST-CODE",
            verification_uri: `${baseUrl}/verify`,
            verification_uri_complete: `${baseUrl}/verify?code=TEST-CODE`,
            expires_in: 60,
            interval: 0,
          });
        }
        case "/oauth/token": {
          if (options.tokenDelayMs) await Bun.sleep(options.tokenDelayMs);
          const form = await request.formData();
          const clientId = form.get("client_id");
          recordedRequest.clientId = typeof clientId === "string" ? clientId : undefined;
          tokenResponseCount += 1;
          if (
            accessToken === null ||
            tokenResponseCount > successfulTokenResponses
          ) {
            return Response.json({
              error: "invalid_grant",
              error_description: `rejected ${LOGIN_TOKEN} while ${ENV_TOKEN} was available`,
            }, { status: 400 });
          }
          return Response.json({
            access_token: accessToken,
            refresh_token: "acquired-refresh-token",
            expires_in: tokenExpiresIn,
            scope: "openid offline_access use:ai-gateway",
            token_type: "Bearer",
          });
        }
        case "/v2/teams":
          return Response.json({ teams: options.teams ?? [] });
        case "/oauth/revoke": {
          const form = await request.formData();
          const tokenTypeHint = form.get("token_type_hint");
          const token = form.get("token");
          const tokenMatchesHint =
            (tokenTypeHint === "refresh_token" &&
              (token === "seeded-refresh-token" ||
                token === "acquired-refresh-token")) ||
            (tokenTypeHint === "access_token" &&
              (token === LOGIN_TOKEN || token === accessToken));
          const validForm =
            form.get("client_id") === "test-client" && tokenMatchesHint;
          recordedRequest.revocation = {
            tokenTypeHint:
              typeof tokenTypeHint === "string" ? tokenTypeHint : "missing",
            validForm,
          };
          return Response.json(
            !validForm ? { error: providerDetail } : { revoked: true },
            { status: !validForm ? 400 : 200 },
          );
        }
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });
  return {
    issuerUrl: `http://127.0.0.1:${server.port}`,
    providerDetail,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function chatgptAccessToken(accountId = "acct_e2e"): string {
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  return `header.${payload}.signature`;
}

function startFakeChatGptOAuth(
  options: {
    tokenDelayMs?: number;
    responseDelayMs?: number;
    unauthorizedResponses?: number;
  } = {},
) {
  const accessToken = chatgptAccessToken();
  let responseCount = 0;
  let models = [
    { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "max" }, { effort: "high" }], additional_speed_tiers: ["fast"], input_modalities: ["text", "image"], context_window: 272000 },
    { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
  ];
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    body: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = url.pathname === "/chatgpt/responses" || url.pathname === "/chatgpt/token"
        ? await request.text()
        : null;
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
      });
      if (url.pathname === "/oauth/authorize") {
        const redirectUri = url.searchParams.get("redirect_uri");
        const state = url.searchParams.get("state");
        if (!redirectUri || !state) return new Response("invalid authorize request", { status: 400 });
        const callback = new URL(redirectUri.replace("localhost", "127.0.0.1"));
        callback.searchParams.set("code", "chatgpt-code");
        callback.searchParams.set("state", state);
        return Response.redirect(callback.toString(), 302);
      }
      if (url.pathname === "/chatgpt/token") {
        if (options.tokenDelayMs) await Bun.sleep(options.tokenDelayMs);
        return Response.json({
          access_token: accessToken,
          refresh_token: "chatgpt-refresh",
          expires_in: 3600,
        });
      }
      if (url.pathname === "/chatgpt/models") {
        return Response.json({ models });
      }
      if (url.pathname === "/chatgpt/responses") {
        responseCount += 1;
        if (responseCount <= (options.unauthorizedResponses ?? 0)) {
          return Response.json(
            { error: { message: "expired ChatGPT token" } },
            { status: 401 },
          );
        }
        if (options.responseDelayMs) await Bun.sleep(options.responseDelayMs);
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"CHATGPT_DIRECT_RESPONSE"}\n\n' +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    accessToken,
    requests,
    env: {
      FX_E2E_CHATGPT_ISSUER_URL: baseUrl,
      FX_E2E_CHATGPT_TOKEN_URL: `${baseUrl}/chatgpt/token`,
      FX_E2E_OPENAI_CODEX_MODELS_URL: `${baseUrl}/chatgpt/models`,
      FX_E2E_OPENAI_CODEX_RESPONSES_URL: `${baseUrl}/chatgpt/responses`,
    },
    baseUrl,
    setModels(next: typeof models) {
      models = next;
    },
    stop() {
      server.stop(true);
    },
  };
}

function startFakeGrokOAuth(options: {
  unauthorizedResponses?: number;
  revokeStatus?: number;
  userinfoSub?: string;
} = {}) {
  const initialAccessToken = "grok-initial-access-token";
  const refreshedAccessToken = "grok-refreshed-access-token";
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    body: string | null;
    conversationId: string | null;
    tokenAuth: string | null;
    authenticateResponse: string | null;
    clientIdentifier: string | null;
    clientVersion: string | null;
    modelOverride: string | null;
    grokUserId: string | null;
    userId: string | null;
    query: string;
  }> = [];
  let tokenCalls = 0;
  let responseCalls = 0;
  let models = [
    { id: "grok-4.20", object: "model", input_modalities: ["text", "image"], output_modalities: ["text"] },
    { id: "grok-4.6", object: "model", input_modalities: ["text", "image"], output_modalities: ["text"] },
    { id: "grok-image-only", object: "model", input_modalities: ["text"], output_modalities: ["image"] },
  ];
  const allSubscriptionModels = [
    grokSubscriptionModel("grok-4.20", 1_000_000),
    grokSubscriptionModel("grok-4.6", 500_000, ["xhigh", "high", "medium", "low"]),
  ];
  let subscriptionModels = allSubscriptionModels;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : null;
      requests.push({
        method: request.method,
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
        conversationId: request.headers.get("x-grok-conv-id"),
        tokenAuth: request.headers.get("x-xai-token-auth"),
        authenticateResponse: request.headers.get("x-authenticateresponse"),
        clientIdentifier: request.headers.get("x-grok-client-identifier"),
        clientVersion: request.headers.get("x-grok-client-version"),
        modelOverride: request.headers.get("x-grok-model-override"),
        grokUserId: request.headers.get("x-grok-user-id"),
        userId: request.headers.get("x-userid"),
        query: url.search,
      });
      if (url.pathname === "/oauth2/authorize") {
        const redirectUri = url.searchParams.get("redirect_uri");
        const state = url.searchParams.get("state");
        if (!redirectUri || !state || url.searchParams.get("nonce")) {
          return new Response("invalid authorize request", { status: 400 });
        }
        if (url.searchParams.get("referrer") !== "fx") {
          return new Response("missing fx referrer", { status: 400 });
        }
        const callback = new URL(redirectUri);
        callback.searchParams.set("code", "grok-code");
        callback.searchParams.set("state", state);
        return Response.redirect(callback.toString(), 302);
      }
      if (url.pathname === "/oauth2/token") {
        tokenCalls += 1;
        const form = new URLSearchParams(body ?? "");
        const refresh = form.get("grant_type") === "refresh_token";
        return Response.json({
          access_token: refresh ? refreshedAccessToken : initialAccessToken,
          refresh_token: refresh ? "grok-refresh-next" : "grok-refresh",
          expires_in: 3600,
        });
      }
      if (url.pathname === "/oauth2/userinfo") {
        if (!request.headers.get("authorization")?.startsWith("Bearer grok-")) {
          return Response.json({ error: "unauthorized" }, { status: 401 });
        }
        return Response.json({ sub: options.userinfoSub ?? "acct_grok_e2e" });
      }
      if (url.pathname === "/oauth2/revoke") {
        const form = new URLSearchParams(body ?? "");
        const valid = form.get("client_id") === "b1a00492-073a-47ea-816f-4c329264a828" &&
          (form.get("token") === "grok-refresh-next" || form.get("token") === "grok-refresh");
        if (valid && options.revokeStatus && options.revokeStatus !== 200) {
          return Response.json({ error: "revocation unavailable" }, { status: options.revokeStatus });
        }
        return Response.json(valid ? { revoked: true } : { error: "invalid" }, {
          status: valid ? 200 : 400,
        });
      }
      if (url.pathname === "/v1/language-models") {
        return Response.json({ models });
      }
      if (url.pathname === "/v1/models") {
        return Response.json({ data: subscriptionModels });
      }
      if (url.pathname === "/v1/responses") {
        responseCalls += 1;
        if (responseCalls <= (options.unauthorizedResponses ?? 0)) {
          return Response.json({ error: { message: "expired" } }, { status: 401 });
        }
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"GROK_DIRECT_RESPONSE"}\n\n' +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    initialAccessToken,
    refreshedAccessToken,
    requests,
    tokenCalls: () => tokenCalls,
    baseUrl,
    env: {
      FX_E2E_GROK_ISSUER_URL: baseUrl,
      FX_E2E_GROK_TOKEN_URL: `${baseUrl}/oauth2/token`,
      FX_E2E_GROK_USERINFO_URL: `${baseUrl}/oauth2/userinfo`,
      FX_E2E_GROK_REVOKE_URL: `${baseUrl}/oauth2/revoke`,
      FX_E2E_XAI_GROK_MODELS_URL: `${baseUrl}/v1/models`,
      FX_E2E_XAI_GROK_MODALITIES_URL: `${baseUrl}/v1/language-models`,
      FX_E2E_XAI_GROK_RESPONSES_URL: `${baseUrl}/v1/responses`,
    },
    setModels(next: typeof models) {
      models = next;
      const visibleIds = new Set(next.map((model) => model.id));
      subscriptionModels = allSubscriptionModels.filter((model) => visibleIds.has(model.id));
    },
    stop() { server.stop(true); },
  };
}

function startFakeOpenCode() {
  const apiKey = "opencode-e2e-api-key";
  const requests: Array<{
    path: string;
    authorization: string | null;
    body: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : null;
      requests.push({
        path: url.pathname,
        authorization: request.headers.get("authorization"),
        body,
      });
      if (url.pathname === "/zen/models") {
        return Response.json({ data: [
          { id: "gpt-5.6-sol", object: "model" },
          { id: "big-pickle", object: "model" },
        ] });
      }
      if (url.pathname === "/go/models") {
        return Response.json({ data: [
          { id: "minimax-m3", object: "model" },
          { id: "kimi-k3", object: "model" },
        ] });
      }
      if (url.pathname === "/chat") {
        return new Response(
          'data: {"id":"opencode-generation","choices":[{"delta":{"content":"OPENCODE_DIRECT_RESPONSE"},"finish_reason":null}]}\n\n' +
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}\n\n' +
            "data: [DONE]\n\n",
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response("not found", { status: 404 });
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    apiKey,
    requests,
    env: {
      FX_E2E_OPENCODE_ZEN_MODELS_URL: `${baseUrl}/zen/models`,
      FX_E2E_OPENCODE_GO_MODELS_URL: `${baseUrl}/go/models`,
      FX_E2E_OPENCODE_CHAT_URL: `${baseUrl}/chat`,
    },
    stop() { server.stop(true); },
  };
}

async function runGrokLoginWithBrowser(env: Record<string, string | undefined>) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "grok"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
  proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
  const deadline = Date.now() + TIMEOUT;
  let authorizationUrl: string | undefined;
  while (Date.now() < deadline) {
    authorizationUrl = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/oauth2\/authorize\?\S+/)?.[0];
    if (authorizationUrl) break;
    await Bun.sleep(20);
  }
  if (!authorizationUrl) {
    proc.kill("SIGTERM");
    throw new Error(`Grok login did not print an authorization URL: ${stdout}\n${stderr}`);
  }
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
  const code = await new Promise<number>((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (value) => resolve(value ?? 1));
  });
  return { code, stdout, stderr };
}

async function completeDisplayedGrokLogin(
  activeSession: TmuxSession,
  fixture: ReturnType<typeof startFakeGrokOAuth>,
) {
  await activeSession.resizeWindow(500, 20);
  const pane = await activeSession.waitForPane(
    (value) => value.includes(`${fixture.baseUrl}/oauth2/authorize?`),
    TIMEOUT,
  );
  const authorizationUrl = pane
    .split(/\s+/)
    .find((value) => value.startsWith(`${fixture.baseUrl}/oauth2/authorize?`));
  if (!authorizationUrl) throw new Error("Grok authorization URL was not rendered");
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
  await activeSession.resizeWindow(100, 30);
}

async function completeDisplayedCodexLogin(
  activeSession: TmuxSession,
  fixture: ReturnType<typeof startFakeChatGptOAuth>,
) {
  await activeSession.waitForText("Authorize with Codex", TIMEOUT);
  const escapes = await activeSession.capturePaneEscapes();
  const urlStart = escapes.indexOf(`${fixture.baseUrl}/oauth/authorize?`);
  const linkStart = escapes.lastIndexOf("\x1b]8;", urlStart);
  const urlEnd = escapes.indexOf("\x1b\\", urlStart);
  if (urlStart < 0 || linkStart < 0 || urlEnd < 0) {
    throw new Error("Codex authorization hyperlink was not rendered");
  }
  const authorizationUrl = escapes.slice(urlStart, urlEnd);
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
}

async function runCodexLoginWithBrowser(
  env: Record<string, string | undefined>,
) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "codex"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
  proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
  const deadline = Date.now() + TIMEOUT;
  let authorizationUrl: string | undefined;
  while (Date.now() < deadline) {
    authorizationUrl = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/oauth\/authorize\?\S+/)?.[0];
    if (authorizationUrl) break;
    await Bun.sleep(20);
  }
  if (!authorizationUrl) {
    proc.kill("SIGTERM");
    throw new Error(`Codex login did not print an authorization URL: ${stdout}\n${stderr}`);
  }
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(200);
  const code = await new Promise<number>((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (value) => resolve(value ?? 1));
  });
  return { code, stdout, stderr };
}

function startFakeCodexToolLoop(options: {
  toolName?: string;
  toolArguments?: object;
  finalText?: string;
} = {}) {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_tool_loop");
  const toolName = options.toolName ?? "read_file";
  const toolArguments = options.toolArguments ?? { path: "README.md" };
  const finalText = options.finalText ?? "CODEX_TOOL_LOOP_OK";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
        ] });
      }
      bodies.push(await request.text());
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: "call_tool", name: toolName } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 1, arguments: JSON.stringify(toolArguments) })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: finalText })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeCodexCapacityLoop() {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_capacity_loop");
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
        ] });
      }
      bodies.push(await request.text());
      const call = bodies.length;
      if (call <= 64) {
        return new Response(
          `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 0, item: { type: "function_call", call_id: `call_capacity_${call}`, name: "read_file" } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 0, arguments: JSON.stringify({ path: "README.md", start_line: call, line_count: 1 }) })}\n\n` +
            `data: ${JSON.stringify({ type: "response.completed", response: { id: `resp_capacity_${call}`, status: "completed", usage: { input_tokens: 5, output_tokens: 2 } } })}\n\n`,
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const text = call === 65 ? "CODEX_CAPACITY_65_OK" : "CODEX_CAPACITY_NEXT_OK";
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
          `data: ${JSON.stringify({ type: "response.completed", response: { id: `resp_capacity_${call}`, status: "completed", usage: { input_tokens: 7, output_tokens: 3 } } })}\n\n`,
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokToolLoop(options: {
  toolName?: string;
  toolArguments?: object;
  finalText?: string;
} = {}) {
  const bodies: string[] = [];
  const accessToken = "grok-tool-loop-token";
  const toolName = options.toolName ?? "read_file";
  const toolArguments = options.toolArguments ?? { path: "README.md" };
  const finalText = options.finalText ?? "GROK_TOOL_LOOP_OK";
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 1_000_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", true)] });
      }
      bodies.push(await request.text());
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-grok-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: "call_tool", name: toolName } })}\n\n` +
            `data: ${JSON.stringify({ type: "response.function_call_arguments.done", output_index: 1, arguments: JSON.stringify(toolArguments) })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: finalText })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeCodexAutoReview() {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_auto_review");
  let mainRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
        ] });
      }
      const body = await request.text();
      bodies.push(body);
      const model = (JSON.parse(body) as { model?: string }).model;
      if (model === "gpt-5.4-mini") {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_permission","name":"permission_decision"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"risk\\":\\"low\\",\\"decision\\":\\"clear\\",\\"rationale\\":\\"The user requested this harmless command.\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_review","status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      mainRequests += 1;
      if (mainRequests === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_terminal","name":"terminal"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"action\\":\\"exec\\",\\"command\\":\\"pwd\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_main_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"CODEX_AUTO_REVIEW_OK"}\n\n' +
          'data: {"type":"response.completed","response":{"id":"gen_main_2","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokAutoReview() {
  const bodies: string[] = [];
  const headers: Array<{
    tokenAuth: string | null;
    authenticateResponse: string | null;
    clientIdentifier: string | null;
    clientVersion: string | null;
    modelOverride: string | null;
    grokUserId: string | null;
  }> = [];
  const accessToken = "grok-auto-review-token";
  let mainRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 500_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", false)] });
      }
      headers.push({
        tokenAuth: request.headers.get("x-xai-token-auth"),
        authenticateResponse: request.headers.get("x-authenticateresponse"),
        clientIdentifier: request.headers.get("x-grok-client-identifier"),
        clientVersion: request.headers.get("x-grok-client-version"),
        modelOverride: request.headers.get("x-grok-model-override"),
        grokUserId: request.headers.get("x-grok-user-id"),
      });
      const body = await request.text();
      bodies.push(body);
      if (body.includes('"name":"permission_decision"')) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_permission","name":"permission_decision"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"risk\\":\\"low\\",\\"decision\\":\\"clear\\",\\"rationale\\":\\"The user requested this harmless command.\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_review","status":"completed","usage":{"input_tokens":8,"output_tokens":3}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      mainRequests += 1;
      if (mainRequests === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_terminal","name":"terminal"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"action\\":\\"exec\\",\\"command\\":\\"pwd\\"}"}\n\n' +
            'data: {"type":"response.completed","response":{"id":"gen_main_1","status":"completed","usage":{"input_tokens":5,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      return new Response(
        'data: {"type":"response.output_text.delta","delta":"GROK_AUTO_REVIEW_OK"}\n\n' +
          'data: {"type":"response.completed","response":{"id":"gen_main_2","status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    headers,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeGrokResourceRecovery() {
  const accessToken = "grok-resource-limit-token";
  const bodies: string[] = [];
  let responseCalls = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json({ data: [grokSubscriptionModel("grok-4.20", 500_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel("grok-4.20", false)] });
      }
      bodies.push(await request.text());
      responseCalls += 1;
      if (responseCalls === 1) {
        return new Response(
          'data: {"type":"response.output_text.delta","delta":"' +
            "x".repeat(1024 * 1024) +
            '"}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      const text = responseCalls === 2 ? "GROK_LIMIT_RECOVERED" : "GROK_AFTER_LIMIT_OK";
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

tmuxTest(
  "inline sign-in renders the device flow and Ctrl+C cancels without a session",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-inline-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, {
      tokenDelayMs: 5_000,
    });

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    const signInScreen = await session.waitForPane(
      (pane) =>
        pane.includes("Sign in with Vercel") &&
        pane.includes("TEST-CODE") &&
        pane.includes("/verify") &&
        pane.includes("Waiting for authorization") &&
        pane.includes("Enter reopens browser · Esc cancels"),
      TIMEOUT,
    );
    expect(signInScreen).not.toContain("Starting Vercel sign-in");

    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(await session.captureFullScrollback()).not.toContain("Signed in to Vercel.");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "Codex sign-in renders browser OAuth without a device code and cancels cleanly",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-cancel-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      undefined,
      chatgptOauth.env,
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const signInScreen = await session.waitForPane(
      (pane) =>
        pane.includes("Sign in with Codex") &&
        pane.includes("Authorize with Codex") &&
        pane.includes("Waiting for authorization") &&
        pane.includes("Enter reopens browser · Esc cancels"),
      TIMEOUT,
    );
    expect(signInScreen).not.toContain("Code   ");
    expect(signInScreen).not.toContain(`${chatgptOauth.baseUrl}/oauth/authorize?`);
    const signInEscapes = await session.capturePaneEscapes();
    expect(signInEscapes).toContain(`\x1b]8;;${chatgptOauth.baseUrl}/oauth/authorize?`);
    expect(signInEscapes).toContain("\x1b]8;;\x1b\\");
    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);
    expect(await session.captureFullScrollback()).not.toContain("Signed in with Codex.");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "setup provider switch reauthenticates current Codex and replaces an unavailable model",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-success-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models() {
        return [{ id: "openai/gpt-5.6-sol", type: "language", tags: ["tool-use"] }];
      },
    });
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/model openai/gpt-5.6-sol");
    await session.waitForText("Switched to openai/gpt-5.6-sol", TIMEOUT);
    await openProviderPicker(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.6-sol.", TIMEOUT);

    const authPath = join(home, ".fx", "chatgpt-auth.json");
    expect(existsSync(authPath)).toBe(true);
    expect(statSync(authPath).mode & 0o077).toBe(0);

    await session.sendText("/status");
    await session.waitForText(
      "model_source=Codex subscription",
      TIMEOUT,
    );
    await session.sendText("/model");
    const picker = await session.waitForPane(
      (pane) =>
        pane.includes("gpt-5.6-sol") &&
        pane.includes("gpt-5.4-mini"),
      TIMEOUT,
    );
    const pickerRows = picker.split("\n").filter((line) => /^\s+gpt-/.test(line));
    expect(pickerRows.join("\n")).not.toContain("openai/gpt-5.6-sol");
    await session.sendKeys("Escape");
    await session.sendKeys("C-c");
    await session.waitForComposer(TIMEOUT);
    await session.sendLiteralText("/model gpt-5.6-sol");
    await session.sendKeys("Space");
    await session.sendLiteralText("max");
    await session.sendKeys("Space");
    await session.sendLiteralText("fast");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to gpt-5.6-sol", TIMEOUT);
    await session.sendText("/fast");
    await session.waitForText("Fast: off", TIMEOUT);
    await session.sendText("/fast");
    await session.waitForText("Fast: on", TIMEOUT);
    await session.sendText("Use the Codex subscription directly.");
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", TIMEOUT);
    const directRequest = chatgptOauth.requests.find(
      (request) => request.path === "/chatgpt/responses",
    );
    expect(directRequest?.authorization).toBe(`Bearer ${chatgptOauth.accessToken}`);
    const directBody = JSON.parse(directRequest?.body ?? "{}") as {
      model?: string;
      service_tier?: string;
      max_output_tokens?: number;
      reasoning?: { effort?: string };
    };
    expect(directBody.model).toBe("gpt-5.6-sol");
    expect(directBody.service_tier).toBe("priority");
    expect(directBody.max_output_tokens).toBeUndefined();
    expect(directBody.reasoning?.effort).toBe("max");
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toBe(
        `Bearer ${chatgptOauth.accessToken}`,
      );
    }
    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes("Models") &&
        pane.includes("gpt-5.6-sol") &&
        pane.includes("gpt-5.4-mini") &&
        !pane.includes("openai/gpt-5.6-sol"),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("Esc Close"), TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    const authorizeRequestsBeforeRoundTrip = chatgptOauth.requests.filter(
      (request) => request.path === "/oauth/authorize",
    ).length;
    const settingsPath = join(home, ".fx", "settings.json");
    const gatewayModelBefore = JSON.parse(readFileSync(settingsPath, "utf8")).models.gateway;
    expect(typeof gatewayModelBefore).toBe("string");
    const savedCodex = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(savedCodex.models.gateway).toBe(gatewayModelBefore);
    expect(savedCodex.models.codex).toBe("gpt-5.6-sol");
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("model=gpt-5.6-sol", TIMEOUT);
    await openProviderPicker(session);
    await session.sendKeys("Up");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to Vercel AI Gateway", TIMEOUT);
    const savedGateway = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(savedGateway.provider).toBe("gateway");
    expect(savedGateway.models.gateway).toBe(gatewayModelBefore);
    expect(savedGateway.models.codex).toBe("gpt-5.6-sol");
    await openProviderPicker(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to Codex subscription", TIMEOUT);
    const restoredCodex = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(restoredCodex.provider).toBe("codex");
    expect(restoredCodex.models.gateway).toBe(gatewayModelBefore);
    expect(restoredCodex.models.codex).toBe("gpt-5.6-sol");
    expect(chatgptOauth.requests.filter((request) => request.path === "/oauth/authorize"))
      .toHaveLength(authorizeRequestsBeforeRoundTrip);
    await session.sendText("/logout codex");
    await session.waitForText("Signed out of Codex.", TIMEOUT);
    expect(existsSync(authPath)).toBe(false);
    await session.sendText("/status");
    await session.waitForText("model_source=Codex subscription", TIMEOUT);
    chatgptOauth.setModels([
      { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
    ]);
    await openProviderPicker(session);
    await session.sendKeys("Enter");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.4-mini.", TIMEOUT);
    const reauthenticated = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(reauthenticated.provider).toBe("codex");
    expect(reauthenticated.models.codex).toBe("gpt-5.4-mini");
    expect(chatgptOauth.requests.filter((request) => request.path === "/oauth/authorize"))
      .toHaveLength(authorizeRequestsBeforeRoundTrip + 1);
    await session.sendKeys("C-c");

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "interactive Codex login activates a Codex catalog model",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-login-activation-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      undefined,
      { ...chatgptOauth.env, FX_MODEL: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await completeDisplayedCodexLogin(session, chatgptOauth);
    await session.waitForText("Switched to Codex subscription with gpt-5.6-sol.", TIMEOUT);

    const selected = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
    expect(selected.provider).toBe("codex");
    expect(selected.models.codex).toBe("gpt-5.6-sol");
    await session.sendText("/status");
    await session.waitForText("model_source=Codex subscription", TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "ChatGPT response transport cancels blocked HTTP without stopping the shell",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-response-cancel-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ responseDelayMs: 10_000 });
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
      { mode: 0o600 },
    );

    session = await startFx(
      home,
      stderrPath,
      gateway,
      undefined,
      undefined,
      {
        ...chatgptOauth.env,
        FX_MODEL: undefined,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Cancel the blocked Codex response.");
    await Bun.sleep(300);
    const cancelStarted = Date.now();
    await session.sendKeys("C-c");
    await session.waitForText("System: cancelled", TIMEOUT);
    await session.waitForComposer(TIMEOUT);
    expect(Date.now() - cancelStarted).toBeLessThan(3_000);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "setup hub exposes each child screen and Escape returns to the hub",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-setup-hub-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, {
      tokenDelayMs: 5_000,
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.resizeWindow(100, 36);
    await session.sendText("/setup");
    const root = await session.waitForPane(
      (pane) =>
        pane.includes("Setup") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("Sign in with Codex") &&
        pane.includes("Sign in with Grok") &&
        pane.includes("Sign in with OpenCode") &&
        pane.includes("API key") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(root).not.toContain("AI_GATEWAY_API_KEY");
    expect(root).not.toContain("fx login");

    await session.sendKeys("Enter");
    await session.waitForText("Enter reopens browser · Esc cancels", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForText("Setup", TIMEOUT);

    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const apiKey = await session.waitForText("Paste your AI Gateway API key", TIMEOUT);
    expect(apiKey).toContain("Saves to");
    await session.sendKeys("Escape");
    await session.waitForText("Setup", TIMEOUT);

    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Switch provider", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForText("Setup", TIMEOUT);

    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Choose a Vercel team", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForText("Switch credential", TIMEOUT);

    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const sources = await session.waitForText("Use this credential", TIMEOUT);
    expect(sources).toContain("AI_GATEWAY_API_KEY");
    expect(sources).toContain("fx login");
    await session.sendKeys("Escape");
    await session.sendKeys("Escape");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

async function startFxWithoutAuth(
  testHome: string,
  testStderrPath: string,
  fakeGateway: ReturnType<typeof startFakeGateway>,
  cwd?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: FX_BIN,
    cwd,
    env: {
      HOME: testHome,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_OAUTH_CLIENT_ID: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: fakeGateway.baseUrl,
      FX_GATEWAY_CHAT_URL: fakeGateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${fakeGateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
    },
    stderrPath: testStderrPath,
    width: 100,
    height: 30,
  });
}

async function waitForModelRequestCount(
  fakeGateway: ReturnType<typeof startFakeGateway>,
  count: number,
): Promise<void> {
  const started = Date.now();
  while (fakeGateway.modelRequests.length < count) {
    if (Date.now() - started >= TIMEOUT) {
      throw new Error(
        `Timed out waiting for ${count} model requests; saw ${fakeGateway.modelRequests.length}`,
      );
    }
    await Bun.sleep(25);
  }
}

async function waitForTrace(tracePath: string, needle: string): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    if (existsSync(tracePath) && readFileSync(tracePath, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for trace: ${needle}`);
}

async function enterSwitchCredential(pickerSession: TmuxSession): Promise<void> {
  for (let index = 0; index < 7; index += 1) {
    await pickerSession.sendKeys("Down");
  }
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForText("Use this credential", TIMEOUT);
}

async function openProviderPicker(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/setup");
  await pickerSession.waitForText("Setup", TIMEOUT);
  for (let index = 0; index < 5; index += 1) {
    await pickerSession.sendKeys("Down");
  }
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForText("Switch provider", TIMEOUT);
}

async function openSwitchCredential(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/setup");
  await pickerSession.waitForText("Setup", TIMEOUT);
  await enterSwitchCredential(pickerSession);
}

function savedCredentialSource(testHome: string): string | undefined {
  const settingsPath = join(testHome, ".fx", "settings.json");
  if (!existsSync(settingsPath)) return undefined;
  return (JSON.parse(readFileSync(settingsPath, "utf8")) as { credential_source?: string })
    .credential_source;
}

profileStoredKeyTmuxTest(
  "stored-key setup persists ahead of the environment",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-stored-key-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(STORED_RESPONSE)]);

    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      FX_DISABLE_KEYCHAIN: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);

    await session.sendText("/setup");
    await session.waitForText("API key", TIMEOUT);
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Paste your AI Gateway API key", TIMEOUT);
    await session.sendLiteralText(STORED_TOKEN);
    await session.sendKeys("Enter");
    await session.waitForText("Saved the API key to profile file and made it active", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=stored API key (profile file)", TIMEOUT);
    expect(savedCredentialSource(home)).toBe("stored_key");

    const keyPath = join(home, ".fx", "api-key");
    expect(readFileSync(keyPath, "utf8")).toBe(STORED_TOKEN);
    expect(statSync(keyPath).mode & 0o777).toBe(0o600);

    await session.kill();
    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      FX_DISABLE_KEYCHAIN: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=stored API key (profile file)", TIMEOUT);
    await session.sendText("use the stored key after restart");
    await session.waitForText(STORED_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${STORED_TOKEN}`);

    const output = await session.captureFullScrollback();
    expect(output).not.toContain(STORED_TOKEN);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "direct login persists ahead of the environment until Automatic is selected",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-direct-login-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(ENV_RESPONSE),
    ]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);

    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Signed in to Vercel", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    expect(savedCredentialSource(home)).toBe("fx_login");
    await session.sendText("use the direct login credential");
    await session.waitForText(DIRECT_LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    await session.sendText("use the remembered direct login credential");
    await session.waitForText(RESTART_RESPONSE, TIMEOUT);
    expect(gateway.requests[1].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );

    await openSwitchCredential(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Using automatic credential precedence again", TIMEOUT);
    expect(savedCredentialSource(home)).toBeUndefined();
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await session.sendText("use automatic precedence after restart");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "Change team activates and persists fx login ahead of the environment",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-team-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(LOGIN_RESPONSE)]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);

    await session.sendText("/setup");
    await session.waitForText("Setup", TIMEOUT);
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Choose a Vercel team", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    expect(savedCredentialSource(home)).toBe("fx_login");

    const savedAuth = JSON.parse(readFileSync(join(home, ".fx", "auth.json"), "utf8")) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(savedAuth.team_id).toBe("team_123");
    expect(savedAuth.team_slug).toBe("vercel-labs");

    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    await session.sendText("use the selected team after restart");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "API key and fx login coexist through selection, restart, login, and logout",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-lifecycle-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    gateway = startFakeGateway([
      fakeGatewayFinalText(ENV_RESPONSE),
      fakeGatewayFinalText(LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(LOGOUT_FALLBACK_RESPONSE),
    ]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    const initial = await session.waitForComposer(TIMEOUT);
    expect(initial).not.toContain("Sign in with Vercel");
    expect(initial).not.toContain("Switch credential");

    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await session.sendText("use normal startup precedence");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);

    await openSwitchCredential(session);
    const inventory = await session.waitForPane(
      (pane) => pane.includes("AI_GATEWAY_API_KEY") && pane.includes("fx login"),
      TIMEOUT,
    );
    expect(inventory).not.toContain("VERCEL_OIDC_TOKEN");
    expect(inventory).not.toMatch(/^\s+stored API key\b/m);

    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
    await session.sendText("use the selected login credential");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);

    const firstRunOutput = await session.captureFullScrollback();
    const firstRunStderr = readFileSync(stderrPath, "utf8");
    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    // The switch above is remembered, so the restart keeps fx login rather than
    // letting AI_GATEWAY_API_KEY reclaim it through precedence.
    await session.waitForText("auth=fx login", TIMEOUT);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
    await session.sendText("use the remembered credential after restart");
    await session.waitForText(RESTART_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    const loginCompleted = await session.waitForText("Signed in to Vercel", TIMEOUT);
    expect(loginCompleted).not.toContain("Setup");
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/token",
      "GET /v2/teams",
    ]);
    expect(oauth.requests[3].authorization).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(oauth.requests[1].clientId).toBe("test-client");
    expect(oauth.requests[2].clientId).toBe("test-client");
    const acquiredAuth = JSON.parse(readFileSync(authPath, "utf8")) as {
      issuer: string;
      client_id: string;
      access_token: string;
      refresh_token: string;
    };
    expect(acquiredAuth.issuer).toBe(oauth.issuerUrl);
    expect(acquiredAuth.client_id).toBe("test-client");
    expect(acquiredAuth.access_token).toBe(ACQUIRED_LOGIN_TOKEN);
    expect(acquiredAuth.refresh_token).toBe("acquired-refresh-token");
    expect(statSync(authPath).mode & 0o777).toBe(0o600);
    expect(
      (await session.captureFullScrollback()).match(/Signed in to Vercel\./g) ?? [],
    ).toHaveLength(1);

    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    await session.sendText("direct login prompt");
    await session.waitForText(DIRECT_LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(4);
    expect(gateway.requests[3].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);

    await session.sendText("/logout");
    const loggedOut = await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(loggedOut).not.toContain("remote session could not be revoked");
    expect(existsSync(authPath)).toBe(false);
    expect(
      oauth.requests
        .filter((request) => request.path === "/oauth/revoke")
        .map((request) => request.revocation),
    ).toEqual([
      { tokenTypeHint: "refresh_token", validForm: true },
      { tokenTypeHint: "access_token", validForm: true },
    ]);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await session.sendText("use the API key after logout");
    await session.waitForText(LOGOUT_FALLBACK_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(5);
    expect(gateway.requests[4].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    const output = `${firstRunOutput}\n${await session.captureFullScrollback()}`;
    const stderr = `${firstRunStderr}${readFileSync(stderrPath, "utf8")}`;
    for (const secret of [
      ENV_TOKEN,
      LOGIN_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(output).not.toContain(secret);
      expect(stderr).not.toContain(secret);
    }
    expect(stderr).toBe("");
  },
  60_000,
);

tmuxTest(
  "searched Vercel login team stays open and loads private models",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-team-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${ACQUIRED_LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [
          { id: "team_456", slug: "other-team", name: "Other Team" },
          { id: "team_123", slug: "example-internal-team", name: "Example Internal Team" },
        ],
      },
    );

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();

    await session.sendText("/login");
    await session.waitForText("Sign in with Codex", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Choose a Vercel team", TIMEOUT);
    await session.resizeWindow(80, 5);
    await session.sendLiteralText("example");
    await session.waitForPane((pane) => pane.includes("Search: example"), TIMEOUT);
    const compactTeamPickerGrid = await session.capturePaneGrid();
    const compactSearchRow = compactTeamPickerGrid.findIndex((row) =>
      row.includes("Search: example"),
    );
    expect(compactSearchRow).toBeGreaterThanOrEqual(0);
    const compactSearchEnd =
      compactTeamPickerGrid[compactSearchRow]!.indexOf("Search: example") +
      "Search: example".length;
    expect(session.cursorPosition()).toEqual({ row: compactSearchRow, col: compactSearchEnd });

    await session.resizeWindow(80, 24);
    await session.waitForPane(
      (pane) =>
        pane.includes("Choose a Vercel team") &&
        pane.includes("Search: example") &&
        pane.includes("Example Internal Team") &&
        !pane.includes("Other Team"),
      TIMEOUT,
    );
    const teamPickerGrid = await session.capturePaneGrid();
    const searchRow = teamPickerGrid.findIndex((row) => row.includes("Search: example"));
    expect(searchRow).toBeGreaterThanOrEqual(0);
    const searchEnd =
      teamPickerGrid[searchRow]!.indexOf("Search: example") + "Search: example".length;
    expect(session.cursorPosition()).toEqual({ row: searchRow, col: searchEnd });
    await session.sendKeys("Enter");
    await session.waitForText("Signed in to Vercel", TIMEOUT);
    await waitForModelRequestCount(gateway, 3);

    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes("private/blue-hornbill") &&
        !pane.includes("Authenticated model catalog loaded."),
      TIMEOUT,
    );

    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    const authenticatedRequest = gateway.modelRequests[2];
    expect(authenticatedRequest.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(authenticatedRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(new URL(authenticatedRequest.url).searchParams.get("teamId")).toBe("team_123");
    expect(gateway.modelRequests).toHaveLength(3);
    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents.at(-1)).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    for (const secret of [ACQUIRED_LOGIN_TOKEN, "team_123", "example-internal-team"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "model catalog warmup follows auth source changes exactly once",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-catalog-lifecycle-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);

    await openSwitchCredential(session);
    await session.waitForPane(
      (pane) => pane.includes("AI_GATEWAY_API_KEY") && pane.includes("fx login"),
      TIMEOUT,
    );
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await waitForModelRequestCount(gateway, 2);
    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    await waitForModelRequestCount(gateway, 3);
    expect(gateway.modelRequests).toHaveLength(3);
    expect(gateway.modelRequests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test(
  "fx login falls back once when a custom OAuth client is invalid",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-fallback-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { deviceError: "invalid_client" },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Signed in to Vercel.");
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/device",
      "POST /oauth/token",
      "GET /v2/teams",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(2);
    expect(deviceRequests[0].clientId).toBe("test-client");
    const fallbackClientId = deviceRequests[1].clientId;
    expect(fallbackClientId).toBeDefined();
    expect(fallbackClientId).not.toBe("test-client");
    const tokenRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/token",
    );
    expect(tokenRequests).toHaveLength(1);
    expect(tokenRequests[0].clientId).toBe(fallbackClientId);

    const persisted = JSON.parse(readFileSync(authPath, "utf8")) as {
      client_id: string;
      access_token: string;
    };
    expect(persisted.client_id).toBe(fallbackClientId);
    expect(persisted.access_token).toBe(ACQUIRED_LOGIN_TOKEN);
    expect(statSync(authPath).mode & 0o777).toBe(0o600);
    expect(result.stdout.match(/Code: TEST-CODE/g) ?? []).toHaveLength(1);
    expect(result.stdout).not.toContain(oauth.providerDetail);
    expect(result.stderr).toBe("");
  },
  60_000,
);

test(
  "Codex CLI browser login fetches raw models and replays one 401 without Gateway leakage",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-cli-login-"));
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ unauthorizedResponses: 1 });
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      ...chatgptOauth.env,
    };

    const login = await runCodexLoginWithBrowser(env);
    expect(login.code, `stdout: ${login.stdout}\nstderr: ${login.stderr}`).toBe(0);
    expect(login.stdout).toContain("Signed in with Codex.");
    expect(login.stdout).not.toContain("Code:");
    expect(login.stderr).toBe("");

    const authPath = join(home, ".fx", "chatgpt-auth.json");
    expect(existsSync(authPath)).toBe(true);
    expect(statSync(authPath).mode & 0o077).toBe(0);
    const settingsPath = join(home, ".fx", "settings.json");
    const selected = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(selected.provider).toBe("codex");
    expect(selected.models.codex).toBe("gpt-5.6-sol");

    const models = await runFx(["models", "--json"], { env, timeoutMs: TIMEOUT });
    const modelIds = (JSON.parse(models.stdout) as { models: Array<{ id: string }> }).models
      .map((model) => model.id);
    expect(modelIds).toContain("gpt-5.6-sol");
    expect(modelIds).toContain("gpt-5.4-mini");
    expect(modelIds.some((id) => id.includes("openai-codex/"))).toBe(false);

    const ask = await runFx(["ask", "--json", "--auto", "--no-save", "Answer directly."], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
    expect(ask.stdout).toContain("CHATGPT_DIRECT_RESPONSE");
    const responses = chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses");
    expect(responses).toHaveLength(2);
    expect(responses[0]!.body).toBe(responses[1]!.body);
    expect(responses[0]!.authorization).toBe(`Bearer ${chatgptOauth.accessToken}`);
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toBe(`Bearer ${chatgptOauth.accessToken}`);
    }

    const gatewayRequestsBeforeImage = gateway.requests.length;
    const gatewayModelRequestsBeforeImage = gateway.modelRequests.length;
    const imageAsk = await runFx([
      "ask",
      "--json",
      "--auto",
      "--no-save",
      "--image",
      join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"),
      "Read the attached image directly.",
    ], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(imageAsk.code, `stdout: ${imageAsk.stdout}\nstderr: ${imageAsk.stderr}`).toBe(0);
    expect(imageAsk.stdout).toContain("CHATGPT_DIRECT_RESPONSE");
    const imageResponses = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/responses",
    );
    expect(imageResponses).toHaveLength(3);
    const imageBody = imageResponses[2]!.body ?? "";
    expect(imageBody.match(/"type":"input_image"/g)).toHaveLength(1);
    expect(imageBody).toContain("data:image/png;base64,");
    expect(imageBody).not.toContain('"name":"vision"');
    expect(gateway.requests).toHaveLength(gatewayRequestsBeforeImage);
    expect(gateway.modelRequests).toHaveLength(gatewayModelRequestsBeforeImage);

    const tokenRequestsBeforeRoundTrip = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/token",
    ).length;
    expect((await runFx(["provider", "gateway"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
    expect((await runFx(["provider", "codex"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
    expect(chatgptOauth.requests.filter((request) => request.path === "/chatgpt/token"))
      .toHaveLength(tokenRequestsBeforeRoundTrip);

    const logout = await runFx(["logout", "codex"], { env, timeoutMs: TIMEOUT });
    expect(logout.code).toBe(0);
    expect(logout.stdout).toContain("Signed out of Codex.");
    expect(existsSync(authPath)).toBe(false);
  },
  60_000,
);

test(
  "Grok CLI browser login fetches subscription models and replays one account-stable 401",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-cli-login-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth({ unauthorizedResponses: 1 });
    try {
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        ...grok.env,
      };

      const login = await runGrokLoginWithBrowser(env);
      expect(login.code, `stdout: ${login.stdout}\nstderr: ${login.stderr}`).toBe(0);
      expect(login.stdout).toContain("Signed in with Grok.");
      expect(login.stderr).toBe("");

      const authPath = join(home, ".fx", "grok-auth.json");
      expect(existsSync(authPath)).toBe(true);
      expect(statSync(authPath).mode & 0o077).toBe(0);
      const settings = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
      expect(settings.provider).toBe("grok");
      expect(settings.models.grok).toBe("grok-4.20");

      const models = await runFx(["models", "--json"], { env, timeoutMs: TIMEOUT });
      const modelIds = (JSON.parse(models.stdout) as { models: Array<{ id: string }> }).models
        .map((model) => model.id);
      expect(modelIds).toEqual(["grok-4.20", "grok-4.6"]);
      const subscriptionCatalogRequests = grok.requests.filter((request) => request.path === "/v1/models");
      expect(subscriptionCatalogRequests.length).toBeGreaterThan(0);
      for (const request of subscriptionCatalogRequests) {
        expect(request.tokenAuth).toBe("xai-grok-cli");
        expect(request.userId).toBe("acct_grok_e2e");
      }
      const modalityRequests = grok.requests.filter((request) => request.path === "/v1/language-models");
      expect(modalityRequests.length).toBeGreaterThan(0);
      for (const request of modalityRequests) {
        expect(request.tokenAuth).toBeNull();
        expect(request.userId).toBeNull();
      }

      const ask = await runFx(["ask", "--json", "--auto", "Answer directly."], {
        env,
        timeoutMs: TIMEOUT,
      });
      expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
      expect(ask.stdout).toContain("GROK_DIRECT_RESPONSE");
      const responses = grok.requests.filter((request) => request.path === "/v1/responses");
      expect(responses).toHaveLength(2);
      expect(responses[0]!.body).toBe(responses[1]!.body);
      expect(responses[0]!.conversationId).toBeTruthy();
      expect(responses[0]!.conversationId).toBe(responses[1]!.conversationId);
      expect(responses[0]!.authorization).toBe(`Bearer ${grok.initialAccessToken}`);
      expect(responses[1]!.authorization).toBe(`Bearer ${grok.refreshedAccessToken}`);
      for (const request of responses) {
        expect(request.tokenAuth).toBe("xai-grok-cli");
        expect(request.authenticateResponse).toBe("authenticate-response");
        expect(request.clientIdentifier).toBe("fx");
        expect(request.clientVersion).toBe("1.0.6");
        expect(request.modelOverride).toBe("grok-4.20");
        expect(request.grokUserId).toBe("acct_grok_e2e");
        expect(request.userId).toBeNull();
      }
      expect(grok.tokenCalls()).toBe(2);
      const userinfo = grok.requests.filter((request) => request.path === "/oauth2/userinfo");
      expect(userinfo).toHaveLength(2);
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toContain("grok-");
      }

      expect((await runFx(["provider", "gateway"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
      expect((await runFx(["provider", "grok"], { env, timeoutMs: TIMEOUT })).code).toBe(0);
      expect(grok.tokenCalls()).toBe(2);

      const logout = await runFx(["logout", "grok"], { env, timeoutMs: TIMEOUT });
      expect(logout.code, `stdout: ${logout.stdout}\nstderr: ${logout.stderr}`).toBe(0);
      expect(logout.stdout).toContain("Signed out of Grok.");
      expect(grok.requests.some((request) => request.path === "/oauth2/revoke")).toBe(true);
      expect(existsSync(authPath)).toBe(false);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test("OpenCode CLI login filters protocols, routes its key directly, and logs out locally", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-opencode-cli-login-"));
  gateway = startFakeGateway([]);
  const opencode = startFakeOpenCode();
  try {
    const commonEnv = {
      HOME: home,
      AI_GATEWAY_API_KEY: "gateway-opencode-sentinel",
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_MODEL: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      ...opencode.env,
    };
    const loginEnv = { ...commonEnv, OPENCODE_API_KEY: opencode.apiKey };
    const login = await runFx(["login", "opencode"], {
      env: loginEnv,
      timeoutMs: TIMEOUT,
    });
    expect(login.code, `stdout: ${login.stdout}\nstderr: ${login.stderr}`).toBe(0);
    expect(login.stdout).toContain("Signed in with OpenCode.");

    const authPath = join(home, ".fx", "opencode-auth.json");
    expect(existsSync(authPath)).toBe(true);
    expect(statSync(authPath).mode & 0o077).toBe(0);
    const settingsPath = join(home, ".fx", "settings.json");
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    expect(settings.provider).toBe("opencode");
    expect(settings.models.opencode).toBe("big-pickle");

    const storedEnv = { ...commonEnv, OPENCODE_API_KEY: undefined };
    const models = await runFx(["models", "--json"], { env: storedEnv, timeoutMs: TIMEOUT });
    expect(models.code, `stdout: ${models.stdout}\nstderr: ${models.stderr}`).toBe(0);
    const modelIds = (JSON.parse(models.stdout) as { models: Array<{ id: string }> }).models
      .map((model) => model.id);
    expect(modelIds).toEqual(["big-pickle", "go/kimi-k3"]);

    const ask = await runFx(["ask", "--json", "--auto", "--no-save", "Answer directly."], {
      env: storedEnv,
      timeoutMs: TIMEOUT,
    });
    expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
    expect(ask.stdout).toContain("OPENCODE_DIRECT_RESPONSE");
    const chatRequests = opencode.requests.filter((request) => request.path === "/chat");
    expect(chatRequests).toHaveLength(1);
    expect(chatRequests[0]!.authorization).toBe(`Bearer ${opencode.apiKey}`);
    expect(JSON.parse(chatRequests[0]!.body ?? "{}").model).toBe("big-pickle");
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toBe(`Bearer ${opencode.apiKey}`);
    }

    const logout = await runFx(["logout", "opencode"], { env: loginEnv, timeoutMs: TIMEOUT });
    expect(logout.code, `stdout: ${logout.stdout}\nstderr: ${logout.stderr}`).toBe(0);
    expect(logout.stdout).toContain("Signed out of OpenCode.");
    expect(existsSync(authPath)).toBe(false);

    const missing = await runFx(["ask", "--json", "--no-save", "Still OpenCode?"], {
      env: loginEnv,
      timeoutMs: TIMEOUT,
    });
    expect(missing.code).toBe(1);
    expect(missing.stderr).toContain("fx login opencode");
  } finally {
    opencode.stop();
  }
});

test("Grok logout removes local credentials when remote revocation fails", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-logout-revoke-failure-"));
  const grok = startFakeGrokOAuth({ revokeStatus: 503 });
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const authPath = join(home, ".fx", "grok-auth.json");
    const result = await runFx(["logout", "grok"], {
      env: {
        HOME: home,
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_E2E_GROK_REVOKE_URL: grok.env.FX_E2E_GROK_REVOKE_URL,
      },
      timeoutMs: TIMEOUT,
    });
    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Signed out of Grok.");
    expect(result.stderr).toContain("remote revocation could not be confirmed");
    expect(existsSync(authPath)).toBe(false);
    expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider)
      .toBe("grok");
    const ask = await runFx(["ask", "--json", "--no-save", "Still Grok?"], {
      env: { HOME: home, FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0" },
      timeoutMs: TIMEOUT,
    });
    expect(ask.code).toBe(1);
    expect(ask.stderr).toContain("fx login grok");
  } finally {
    grok.stop();
  }
});

test("Grok 401 replay refuses a different account before the second provider send", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-account-mismatch-"));
  gateway = startFakeGateway([]);
  const grok = startFakeGrokOAuth({ unauthorizedResponses: 1, userinfoSub: "acct_other" });
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      ...grok.env,
    };
    const ask = await runFx(["ask", "--json", "--auto", "--no-save", "Answer."], {
      env,
      timeoutMs: TIMEOUT,
    });
    expect(ask.code).toBe(1);
    expect(grok.requests.filter((request) => request.path === "/v1/responses")).toHaveLength(1);
    const saved = JSON.parse(readFileSync(join(home, ".fx", "grok-auth.json"), "utf8")) as {
      access_token: string;
      account_id: string;
    };
    expect(saved.access_token).toBe(grok.initialAccessToken);
    expect(saved.account_id).toBe("acct_grok_e2e");
    for (const request of [...gateway.requests, ...gateway.modelRequests]) {
      expect(request.headers.get("authorization")).not.toContain("grok-");
    }
  } finally {
    grok.stop();
  }
});

test("Grok CLI sends verified images directly without advertising the vision fallback", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-native-image-"));
  gateway = startFakeGateway([]);
  const grok = startFakeGrokOAuth();
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );
    const imagePath = join(home, "attachment.png");
    writeFileSync(imagePath, Buffer.from("89504e470d0a1a0a72657374", "hex"));
    const ask = await runFx([
      "ask",
      "--json",
      "--auto",
      "--no-save",
      "--image",
      imagePath,
      "Describe the image.",
    ], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        ...grok.env,
      },
      timeoutMs: TIMEOUT,
    });
    expect(ask.code, `stdout: ${ask.stdout}\nstderr: ${ask.stderr}`).toBe(0);
    const responses = grok.requests.filter((request) => request.path === "/v1/responses");
    expect(responses).toHaveLength(1);
    expect(responses[0]!.body).toContain('"type":"input_image"');
    expect(responses[0]!.body).not.toContain('"name":"vision"');
    expect(gateway.requests).toHaveLength(0);
  } finally {
    grok.stop();
  }
});

tmuxTest(
  "interactive Grok login activates Grok and setup round-trips without reauthentication",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-tui-switch-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_AFTER_GROK")]);
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        FX_MODEL: undefined,
        ...grok.env,
      });
      await session.waitForText("auto ·", TIMEOUT);

      await session.sendText("/login");
      await session.waitForText("Sign in with Grok", TIMEOUT);
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await completeDisplayedGrokLogin(session, grok);
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      await session.sendText("Answer from Grok.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);

      const tokenCallsAfterLogin = grok.tokenCalls();
      await openProviderPicker(session);
      await session.sendKeys("Up");
      await session.sendKeys("Up");
      await session.sendKeys("Enter");
      await session.waitForText("Switched to Vercel AI Gateway", TIMEOUT);
      await openProviderPicker(session);
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      const settingsPath = join(home, ".fx", "settings.json");
      const persistenceDeadline = Date.now() + TIMEOUT;
      let saved: { provider: string; models: { grok: string } } | undefined;
      while (Date.now() < persistenceDeadline) {
        saved = JSON.parse(readFileSync(settingsPath, "utf8")) as {
          provider: string;
          models: { grok: string };
        };
        if (saved.provider === "grok") break;
        await Bun.sleep(25);
      }
      expect(saved).toBeDefined();
      expect(grok.tokenCalls()).toBe(tokenCallsAfterLogin);
      expect(saved!.provider).toBe("grok");
      expect(saved!.models.grok).toBe("grok-4.20");
      const responses = grok.requests.filter((request) => request.path === "/v1/responses");
      expect(responses).toHaveLength(1);
      expect(responses[0]!.conversationId).toBeTruthy();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok model selection uses provider-advertised context and effort metadata",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-effort-selection-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    try {
      writeSeededGrokLogin(home, grok.initialAccessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20", statusLine: { context: true } }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        FX_MODEL: undefined,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      const catalogDeadline = Date.now() + TIMEOUT;
      while (!grok.requests.some((request) => request.path === "/v1/language-models")) {
        if (Date.now() >= catalogDeadline) throw new Error("Grok catalog did not load");
        await Bun.sleep(25);
      }
      await session.sendText("/model grok-4.6 xhigh");
      await session.waitForText("Switched to grok-4.6", TIMEOUT);
      await session.sendText("Use the selected effort.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);

      const response = grok.requests.find((request) => request.path === "/v1/responses");
      expect(response).toBeDefined();
      const body = JSON.parse(response!.body ?? "{}") as {
        model?: string;
        reasoning?: { effort?: string };
      };
      expect(body.model).toBe("grok-4.6");
      expect(body.reasoning?.effort).toBe("xhigh");
      expect(await session.capturePane()).toContain("/500k");
      expect(readFileSync(join(home, ".fx", "settings.json"), "utf8")).toContain('"effort":"xhigh"');
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Grok resource exhaustion stays on-provider and leaves later input usable",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-resource-recovery-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokResourceRecovery();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_resource_limit");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        FX_MODEL: undefined,
        FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
        FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
      });
      await session.waitForComposer(TIMEOUT);
      const failureVisible = session.waitForText("request failed: XaiGrokSseEventTooLarge", TIMEOUT);
      await session.sendText("Recover from a bounded Grok response.");
      await failureVisible;
      await session.sendText("Accept another prompt after recovery.");
      await session.waitForText("GROK_LIMIT_RECOVERED", TIMEOUT);
      await session.sendText("Accept one more prompt after recovery.");
      await session.waitForText("GROK_AFTER_LIMIT_OK", TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("XaiGrokSseEventTooLarge");
      expect(grok.bodies).toHaveLength(3);
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "ChatGPT tool loops round-trip encrypted reasoning without Gateway leakage",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-chatgpt-tool-loop-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexToolLoop();
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the README, then finish."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-tool-loop-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_TOOL_LOOP_OK");
      expect(codex.bodies).toHaveLength(2);
      expect(codex.bodies[1]).toContain('"encrypted_content":"opaque-tool-loop"');
      expect(codex.bodies[1]).toContain('"type":"function_call_output"');
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toBe(`Bearer ${codex.accessToken}`);
      }
    } finally {
      codex.stop();
    }
  },
  60_000,
);

tmuxTest(
  "Codex remains usable beyond Gateway observation capacity in one process",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-capacity-loop-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    const codex = startFakeCodexCapacityLoop();
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        FX_MODEL: undefined,
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
        FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Read enough lines to complete the capacity loop.");
      await session.waitForText("CODEX_CAPACITY_65_OK", 120_000);
      expect(codex.bodies).toHaveLength(65);

      await session.sendText("Confirm the same process remains usable.");
      await session.waitForText("CODEX_CAPACITY_NEXT_OK", TIMEOUT);
      expect(codex.bodies).toHaveLength(66);
      expect(await session.captureFullScrollback()).not.toContain("UsageCapacityExceeded");
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      codex.stop();
    }
  },
  150_000,
);

test(
  "Grok tool loops round-trip encrypted reasoning without Gateway leakage",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-tool-loop-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokToolLoop();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_tool_loop");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the README, then finish."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-grok-tool-loop-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_TOOL_LOOP_OK");
      expect(grok.bodies).toHaveLength(2);
      expect(grok.bodies[1]).toContain('"encrypted_content":"opaque-grok-tool-loop"');
      expect(grok.bodies[1]).toContain('"type":"function_call_output"');
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toContain("grok-tool-loop-token");
      }
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex CLI login preserves durable auth but does not claim success when activation fails",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-cli-activation-failure-"));
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();
    chatgptOauth.setModels([]);
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      ...chatgptOauth.env,
    };

    const login = await runCodexLoginWithBrowser(env);
    expect(login.code).toBe(1);
    expect(login.stdout).not.toContain("Signed in with Codex.");
    expect(login.stderr).toContain("fx login: could not load the target model catalog (malformed_response)");
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(true);
    const settingsPath = join(home, ".fx", "settings.json");
    expect(existsSync(settingsPath)).toBe(false);
  },
  60_000,
);

test(
  "Grok CLI login preserves durable auth but does not claim success when activation fails",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-cli-activation-failure-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    grok.setModels([]);
    try {
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        ...grok.env,
      };

      const login = await runGrokLoginWithBrowser(env);
      expect(login.code).toBe(1);
      expect(login.stdout).not.toContain("Signed in with Grok.");
      expect(login.stderr).toContain("fx login: target model catalog is empty");
      expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
      expect(existsSync(join(home, ".fx", "settings.json"))).toBe(false);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex rejects the vision fallback without another provider request",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-vision-disabled-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexToolLoop({
      toolName: "vision",
      toolArguments: { image_ids: [1], focus: "Inspect the image." },
      finalText: "CODEX_VISION_DISABLED_OK",
    });
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Answer without using a vision fallback."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-vision-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_VISION_DISABLED_OK");
      expect(codex.bodies).toHaveLength(2);
      expect(codex.bodies[0]).not.toContain('"name":"vision"');
      const continuation = JSON.parse(codex.bodies[1]) as {
        input: Array<{ type?: string; output?: string }>;
      };
      const toolResult = continuation.input.find(
        (item) => item.type === "function_call_output",
      );
      expect(toolResult?.output).toContain("Vision is unavailable for this request.");
      expect(toolResult?.output).toContain("native image input");
      for (const request of [...gateway.requests, ...gateway.modelRequests]) {
        expect(request.headers.get("authorization")).not.toBe(`Bearer ${codex.accessToken}`);
      }
    } finally {
      codex.stop();
    }
  },
  60_000,
);

test(
  "Grok rejects the vision fallback because native image input owns OCR",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-vision-disabled-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokToolLoop({
      toolName: "vision",
      toolArguments: { image_ids: [1], focus: "Inspect the image." },
      finalText: "GROK_VISION_DISABLED_OK",
    });
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_vision");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Answer without a vision fallback."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-grok-vision-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_VISION_DISABLED_OK");
      expect(grok.bodies).toHaveLength(2);
      expect(grok.bodies[0]).not.toContain('"name":"vision"');
      const continuation = JSON.parse(grok.bodies[1]) as {
        input: Array<{ type?: string; output?: string }>;
      };
      const toolResult = continuation.input.find((item) => item.type === "function_call_output");
      expect(toolResult?.output).toContain("Vision is unavailable for this request.");
      expect(gateway.requests).toHaveLength(0);
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex automatic review uses gpt-5.4-mini while Gateway review stays untouched",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-auto-review-"));
    gateway = startFakeGateway([]);
    const codex = startFakeCodexAutoReview();
    try {
      writeSeededChatGptLogin(home, codex.accessToken);
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "Run pwd, then finish."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-auto-review-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
            FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("CODEX_AUTO_REVIEW_OK");
      expect(codex.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["gpt-5.6-sol", "gpt-5.4-mini", "gpt-5.6-sol"]);
      expect(codex.bodies[1]).toContain('"name":"permission_decision"');
      expect(codex.bodies[2]).toContain('"type":"function_call_output"');
      expect(codex.bodies[2]).toContain("exit_code=0");
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 1,
        settled_through_sequence: 0,
        pending: [],
      });
    } finally {
      codex.stop();
    }
  },
  60_000,
);

test(
  "Grok automatic review reuses the admitted Grok model and never reaches Gateway",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-auto-review-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokAutoReview();
    try {
      writeSeededGrokLogin(home, grok.accessToken, "acct_auto_review");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
        { mode: 0o600 },
      );
      const result = await runFx(
        ["ask", "--json", "--auto", "Run pwd, then finish."],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: "gateway-grok-auto-review-sentinel",
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
            FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("GROK_AUTO_REVIEW_OK");
      expect(grok.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["grok-4.20", "grok-4.20", "grok-4.20"]);
      expect(grok.bodies[1]).toContain('"name":"permission_decision"');
      expect(grok.bodies[2]).toContain('"type":"function_call_output"');
      expect(grok.bodies[2]).toContain("exit_code=0");
      expect(grok.headers).toHaveLength(3);
      for (const headers of grok.headers) {
        expect(headers.tokenAuth).toBe("xai-grok-cli");
        expect(headers.authenticateResponse).toBe("authenticate-response");
        expect(headers.clientIdentifier).toBe("fx");
        expect(headers.clientVersion).toBe("1.0.6");
        expect(headers.modelOverride).toBe("grok-4.20");
        expect(headers.grokUserId).toBe("acct_auto_review");
      }
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 1,
        settled_through_sequence: 0,
        pending: [],
      });
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test(
  "fx login bounds invalid OAuth client fallback to two device requests",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-fallback-failure-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { deviceError: "invalid_client", rejectAllDeviceClients: true },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/device",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(2);
    expect(deviceRequests[0].clientId).toBe("test-client");
    expect(deviceRequests[1].clientId).toBeDefined();
    expect(deviceRequests[1].clientId).not.toBe("test-client");
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("fx login: failed to sign in\n");
    expect(result.stderr).not.toContain(oauth.providerDetail);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
  },
  60_000,
);

test(
  "fx login does not fall back for another OAuth device error",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-login-client-no-fallback-"));
    writeSeededFxLogin(home);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { deviceError: "invalid_request" },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
    ]);
    const deviceRequests = oauth.requests.filter(
      (request) => request.path === "/oauth/device",
    );
    expect(deviceRequests).toHaveLength(1);
    expect(deviceRequests[0].clientId).toBe("test-client");
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("fx login: failed to sign in\n");
    expect(result.stderr).not.toContain(oauth.providerDetail);
    expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
  },
  60_000,
);

tmuxTest(
  "missing auth after deferred onboarding preserves the complete prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-preflight-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const imagePath = join(home, "attachment.png");
    writeFileSync(imagePath, Buffer.from("89504e470d0a1a0a72657374", "hex"));
    gateway = startFakeGateway([], {
      models: [{
        id: FAKE_GATEWAY_MODEL,
        tags: ["vision", "file-input", "tool-use"],
      }],
    });

    session = await startFxWithoutAuth(home, stderrPath, gateway);
    const initial = await session.waitForComposer(TIMEOUT);
    expect(initial).not.toContain("Sign in with Vercel");
    expect(initial).not.toContain("Switch credential");

    await session.sendText(`/image ${imagePath}`);
    await session.waitForText("attached image: attachment.png", TIMEOUT);
    await session.sendText(" preserve this exact prompt");
    const blocked = await session.waitForPane(
      (pane) =>
        pane.includes("Fx needs access to Vercel AI Gateway") &&
        pane.includes("preserve this exact prompt") &&
        pane.includes("Image 1"),
      TIMEOUT,
    );
    expect(blocked).not.toContain("Welcome to fx");
    expect(blocked).not.toContain("Switch credential");
    expect(gateway.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout rejects an invalid revocation endpoint and removes the active login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-active-login-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    const tapePath = join(home, "logout.fxtape");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText(LOGIN_RESPONSE),
      fakeGatewayFinalText(ENV_RESPONSE),
    ]);
    catcher = startRequestCatcher();
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, catcher.endpoint);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await openSwitchCredential(session);
    await session.waitForPane(
      (pane) => pane.includes("AI_GATEWAY_API_KEY") && pane.includes("fx login"),
      TIMEOUT,
    );
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.sendText("prove fx login is active before logout");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    await session.sendText("/logout");
    const loggedOut = await session.waitForPane(
      (pane) =>
        pane.includes("Signed out of fx.") &&
        pane.includes("remote session could not be revoked"),
      TIMEOUT,
    );
    expect(loggedOut).not.toContain(oauth.providerDetail);
    expect(
      loggedOut.match(/remote session could not be revoked/g) ?? [],
    ).toHaveLength(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);

    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await openSwitchCredential(session);
    const inventory = await session.waitForPane(
      (pane) => pane.includes("AI_GATEWAY_API_KEY") && pane.includes("Use this credential"),
      TIMEOUT,
    );
    expect(inventory).not.toMatch(/^\s+fx login\s+(?:current|available)\s*$/m);
    await session.sendKeys("Escape");

    await session.sendText("prove environment auth remains active");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
    ]);
    expect(catcher.requests).toEqual([]);

    const pane = await session.capturePane();
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    session = null;
    expect(existsSync(tracePath)).toBe(true);
    expect(existsSync(tapePath)).toBe(true);
    const trace = readFileSync(tracePath, "utf8");
    const tape = readFileSync(tapePath);
    for (const secret of [
      LOGIN_TOKEN,
      ENV_TOKEN,
      "seeded-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(pane).not.toContain(secret);
      expect(readFileSync(stderrPath, "utf8")).not.toContain(secret);
      expect(trace).not.toContain(secret);
      expect(tape.includes(Buffer.from(secret))).toBe(false);
    }
  },
  60_000,
);

tmuxTest(
  "logout preserves an active API key when fx login is inactive",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-inactive-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(ENV_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);

    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await session.sendText("prove the active API key was unchanged");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout removes an fx login rejected for unsafe permissions",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-rejected-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);
    const authPath = join(home, ".fx", "auth.json");
    chmodSync(authPath, 0o644);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    const loggedOut = await session.waitForText("Signed out of fx.", TIMEOUT);
    expect(existsSync(authPath)).toBe(false);

    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    for (const secret of [
      LOGIN_TOKEN,
      "seeded-refresh-token",
      oauth.providerDetail,
    ]) {
      expect(loggedOut).not.toContain(secret);
    }
  },
  60_000,
);

tmuxTest(
  "logout recalculates auth when local cleanup cannot be completed",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-delete-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(LOGIN_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);
    const fxDir = join(home, ".fx");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    const authPath = join(fxDir, "auth.json");
    rmSync(authPath);
    mkdirSync(authPath, { mode: 0o700 });

    await session.sendText("/logout");
    const failed = await session.waitForText(
      "Could not confirm durable fx logout. The active source was recalculated.",
      TIMEOUT,
    );
    expect(failed).not.toContain("Signed out of fx.");
    expect(failed).toContain(
      "Warning: signed out locally, but the remote session could not be revoked.",
    );
    expect(existsSync(authPath)).toBe(true);

    await session.sendText("/status");
    await session.waitForText("auth=missing", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "logout with the only credential keeps the shell open and reopens onboarding on the next prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-logout-only-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_SKIP_ONBOARDING: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=missing", TIMEOUT);

    await session.sendText("/setup");
    const inventory = await session.waitForPane(
      (pane) =>
        pane.includes("Setup") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("Sign in with Grok") &&
        pane.includes("API key") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(inventory).not.toMatch(/^\s+fx login\s+/m);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("   Setup"),
      TIMEOUT,
    );

    const prompt = "prompt waits for auth after logout";
    await session.sendText(prompt);
    const picker = await session.waitForPane(
      (pane) =>
        pane.includes(prompt) &&
        pane.includes("Welcome to fx") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("Add an API key") &&
        pane.includes("Esc to set up later"),
      TIMEOUT,
    );
    expect(picker).not.toMatch(/^\s+fx login\s+/m);
    expect(picker).not.toContain("Switch credential");
    expect(picker).not.toContain("Skip for now");
    expect(gateway.requests).toHaveLength(0);
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "HTTP auth failure names the selected source and suppresses provider detail",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-http-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const providerDetail = `rejected ${ENV_TOKEN} in provider response`;
    gateway = startFakeGateway([
      new Response(JSON.stringify({ error: { message: providerDetail } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("exercise interactive auth failure");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("AI_GATEWAY_API_KEY authentication failed · HTTP 401") &&
        pane.includes("Run /setup to choose another source."),
      TIMEOUT,
    );

    expect(failed).not.toContain(ENV_TOKEN);
    expect(failed).not.toContain(providerDetail);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

tmuxTest(
  "expired selected login preserves the prompt and avoids Gateway before explicit recovery",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-source-failure-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(null);
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath);
    await session.waitForComposer(TIMEOUT);
    await openSwitchCredential(session);
    await session.waitForPane(
      (pane) => pane.includes("AI_GATEWAY_API_KEY") && pane.includes("fx login"),
      TIMEOUT,
    );
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    const promptHead = "PRESERVE_CURSOR_";
    const promptTail = "AFTER_SELECTED_LOGIN_REFRESH_FAILURE";
    await session.sendLiteral(`${promptHead}${promptTail}`);
    for (let index = 0; index < promptTail.length; index += 1) {
      await session.sendKeys("Left");
    }
    await session.sendKeys("Enter");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Choose another source below") &&
        pane.includes("Setup") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(failed).toContain(`${promptHead}${promptTail}`);
    expect(failed).not.toContain(LOGIN_TOKEN);
    expect(failed).not.toContain(ENV_TOKEN);
    expect(gateway.requests).toHaveLength(0);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);

    await enterSwitchCredential(session);
    await session.sendKeys("Up");
    await session.sendKeys("Enter");
    const preserved = await session.waitForPane(
      (pane) =>
        pane.includes(`${promptHead}${promptTail}`) &&
        !pane.includes("current: fx login"),
      TIMEOUT,
    );
    expect(preserved).toContain(`${promptHead}${promptTail}`);
    await session.sendKeys("Enter");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);

    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(gateway.requests[0].body).toContain(`${promptHead}${promptTail}`);

    const trace = readFileSync(tracePath, "utf8");
    for (const secret of [LOGIN_TOKEN, ENV_TOKEN, "seeded-refresh-token", "invalid_grant", "rejected"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "prompt refresh replaces an expired public catalog with the selected team catalog",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-refresh-team-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${ACQUIRED_LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();

    await session.sendText("refresh login and answer");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    await waitForModelRequestCount(gateway, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(gateway.requests[0].headers.get("x-vercel-ai-gateway-team")).toBe("team_123");

    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes("private/blue-hornbill") &&
        !pane.includes("Authenticated model catalog loaded."),
      TIMEOUT,
    );
    const refreshedCatalogRequest = gateway.modelRequests[1];
    expect(refreshedCatalogRequest.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(refreshedCatalogRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(new URL(refreshedCatalogRequest.url).searchParams.get("teamId")).toBe("team_123");
    expect(gateway.modelRequests).toHaveLength(2);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(2);
    expect(catalogEvents[0]).toContain("public_only_reason=fx_login_refresh_required");
    expect(catalogEvents[1]).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    for (const secret of [
      LOGIN_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      "team_123",
      "example-internal-team",
    ]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired saved login discovers models without refreshing prompt credentials",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-models-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      { AI_GATEWAY_API_KEY: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(oauth.requests).toEqual([]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in must refresh before team-private models can load.") &&
        pane.includes("Esc Close"),
      TIMEOUT,
    );

    expect(oauth.requests).toEqual([]);
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "ready team catalog downgrades after Fx login expiry and refresh failure",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-ready-catalog-expiry-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        const teamId = new URL(request.url).searchParams.get("teamId");
        const authenticated =
          request.headers.get("authorization") === `Bearer ${LOGIN_TOKEN}` &&
          teamId === "team_123";
        return [
          { id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] },
          ...(authenticated
            ? [{ id: "private/blue-hornbill", type: "language", tags: ["tool-use"] }]
            : []),
        ];
      },
    });
    oauth = startFakeOAuth(null);
    writeSeededFxLogin(home, Date.now() + 65_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_MODELS_URL: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(new URL(gateway.modelRequests[0].url).searchParams.get("teamId")).toBe("team_123");

    await Bun.sleep(6_000);
    await session.sendText("/models");
    await waitForModelRequestCount(gateway, 2);
    const expiredPane = await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in must refresh before team-private models can load.") &&
        !pane.includes("private/blue-hornbill"),
      TIMEOUT,
    );
    expect(expiredPane).not.toContain("private/blue-hornbill");
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Models ") && !pane.includes("Esc Close"),
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    const blockedPrompt = "refresh the expired team login";
    await session.sendText(blockedPrompt);
    await session.waitForPane(
      (pane) =>
        pane.includes(blockedPrompt) &&
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(gateway.requests).toHaveLength(0);

    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => pane.includes(blockedPrompt) && !pane.includes("   Setup"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendText("/models");
    const failedPane = await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in refresh failed; using the public model catalog.") &&
        !pane.includes("private/blue-hornbill"),
      TIMEOUT,
    );
    expect(failedPane).not.toContain("private/blue-hornbill");
    expect(gateway.modelRequests).toHaveLength(2);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(2);
    expect(catalogEvents[0]).toContain(
      "requested_access=authenticated credential_source=fx_login effective_access=authenticated",
    );
    expect(catalogEvents[1]).toContain("public_only_reason=fx_login_refresh_required");
    for (const secret of [LOGIN_TOKEN, "seeded-refresh-token", "team_123"]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "immediately expired refresh keeps model discovery anonymous and later prompts blocked",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-refresh-models-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 0);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      tracePath,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_TRACE_SCOPES: "auth,prompt,catalog",
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    const firstPrompt = "prompt blocked by an immediately expired refresh";
    await session.sendText(firstPrompt);
    const firstFailure = await session.waitForPane(
      (pane) =>
        pane.includes(firstPrompt) &&
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(firstFailure).toContain("Choose another source below.");
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);

    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => pane.includes(firstPrompt) && !pane.includes("   Setup"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendText("/models");
    await session.waitForPane(
      (pane) =>
        pane.includes("Vercel sign-in refresh failed; using the public model catalog.") &&
        pane.includes("Esc Close"),
      TIMEOUT,
    );
    expect(gateway.modelRequests).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("Esc Close"), TIMEOUT);
    await session.waitForComposer(TIMEOUT);

    const secondPrompt = "a subsequent prompt remains blocked";
    await session.sendText(secondPrompt);
    await session.waitForPane(
      (pane) =>
        pane.includes(secondPrompt) &&
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Switch provider"),
      TIMEOUT,
    );
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(oauth.requests.every((request) => request.authorization === null)).toBe(true);

    const trace = readFileSync(tracePath, "utf8");
    const catalogEvents = trace.split("\n").filter((line) =>
      line.includes("[catalog] event=model_catalog_load ")
    );
    expect(catalogEvents).toHaveLength(1);
    expect(catalogEvents[0]).toContain(
      "requested_access=public_only credential_source=fx_login effective_access=public_only public_only_reason=fx_login_refresh_required anonymous_fallback=false outcome=loaded failure_category=none http_status=none retryable=none",
    );
    for (const secret of [
      LOGIN_TOKEN,
      ENV_TOKEN,
      ACQUIRED_LOGIN_TOKEN,
      "seeded-refresh-token",
      "acquired-refresh-token",
      oauth.providerDetail,
      "team_123",
      "vercel-labs",
    ]) {
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired saved login refreshes for credits without restarting model warmup",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-credits-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    creditsGateway = startFakeCreditsGateway();
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_CREDITS_URL: creditsGateway.url,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(oauth.requests).toEqual([]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(creditsGateway.requests).toEqual([]);

    await session.sendText("/credits");
    await session.waitForText("● Credits: balance=42", TIMEOUT);

    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(creditsGateway.requests).toEqual([{
      method: "GET",
      path: "/v1/credits",
      authorization: `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    }]);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "expired login refresh failure keeps one anonymous catalog request and blocks credits",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-startup-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(null);
    creditsGateway = startFakeCreditsGateway();
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_CREDITS_URL: creditsGateway.url,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    expect(oauth.requests).toEqual([]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(creditsGateway.requests).toEqual([]);

    await session.sendText("/credits");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Choose another source below") &&
        pane.includes("/credits"),
      TIMEOUT,
    );

    expect(failed).toContain("/credits");
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(creditsGateway.requests).toHaveLength(0);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "model discovery remains available before login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-models-before-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      { AI_GATEWAY_API_KEY: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);

    await session.sendText("/models");
    const pane = await session.waitForPane(
      (text) =>
        text.includes(FAKE_GATEWAY_MODEL) &&
        text.includes("Using the public model catalog; sign in or use an API key for team-private models."),
      TIMEOUT,
    );
    expect(pane).toContain(FAKE_GATEWAY_MODEL);
    expect(pane).toContain("Using the public model catalog; sign in or use an API key for team-private models.");

    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(oauth.requests).toEqual([]);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "rejected catalog credential renders the degraded public fallback notice",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-populated-catalog-fallback-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], {
      models(request) {
        if (request.headers.get("authorization")) {
          return new Response("rejected catalog credential", { status: 401 });
        }
        return [{ id: FAKE_GATEWAY_MODEL, tags: ["tool-use"] }];
      },
    });

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 2);

    await session.sendText("/models");
    const pane = await session.waitForPane(
      (text) =>
        text.includes(FAKE_GATEWAY_MODEL) &&
        text.includes("Your Gateway credential was rejected; using the public model catalog."),
      TIMEOUT,
    );
    expect(pane).toContain(FAKE_GATEWAY_MODEL);
    expect(pane).toContain("Your Gateway credential was rejected; using the public model catalog.");

    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(gateway.modelRequests[1].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

for (const scenario of [
  {
    name: "ordinary public empty catalog",
    authenticated: false,
    status: "Using the public model catalog; sign in or use an API key for team-private models.",
  },
  {
    name: "rejected credential empty fallback catalog",
    authenticated: true,
    status: "Your Gateway credential was rejected; using the public model catalog.",
  },
]) {
  tmuxTest(
    `empty model menu renders the ${scenario.name} status`,
    async () => {
      home = mkdtempSync(join(tmpdir(), "fx-tui-auth-empty-catalog-"));
      stderrPath = join(home, "stderr.log");
      writeFileSync(stderrPath, "");
      gateway = startFakeGateway([], {
        models(request) {
          if (scenario.authenticated && request.headers.get("authorization")) {
            return new Response("rejected catalog credential", { status: 401 });
          }
          return [];
        },
      });

      session = await startFx(
        home,
        stderrPath,
        gateway,
        undefined,
        undefined,
        scenario.authenticated ? {} : { AI_GATEWAY_API_KEY: undefined },
      );
      await session.waitForComposer(TIMEOUT);
      await waitForModelRequestCount(gateway, scenario.authenticated ? 2 : 1);

      await session.sendText("/models");
      const pane = await session.waitForPane(
        (text) => text.includes("No models available.") && text.includes(scenario.status),
        TIMEOUT,
      );
      expect(pane).toContain("No models available.");
      expect(pane).toContain(scenario.status);

      expect(gateway.modelRequests).toHaveLength(scenario.authenticated ? 2 : 1);
      if (scenario.authenticated) {
        expect(gateway.modelRequests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
      }
      const publicRequest = gateway.modelRequests.at(-1)!;
      expect(publicRequest.headers.get("authorization")).toBeNull();
      expect(publicRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    60_000,
  );
}
