import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx, providerVersionTestEnv } from "../evals/eval-helpers";
import { readTapeFrames } from "./render-lab/tape";
import { equivalentPngEncodings } from "./fixtures/image-encoding";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
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

function startFakeDirectUsageProvider(
  provider: "codex" | "grok",
  model: string,
  responseId: string,
  inputTokens: number,
  outputTokens: number,
) {
  let responses = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return provider === "codex"
          ? Response.json({ models: [{
            slug: model,
            visibility: "list",
            supported_in_api: true,
            supported_reasoning_levels: [{ effort: "high" }],
            additional_speed_tiers: [],
            input_modalities: ["text"],
            context_window: 272000,
          }] })
          : Response.json({ data: [grokSubscriptionModel(model, 500_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel(model, false)] });
      }
      responses += 1;
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: `${provider.toUpperCase()}_USAGE_OK` })}\n\n` +
          `data: ${JSON.stringify({ type: "response.completed", response: { id: responseId, status: "completed", usage: { input_tokens: inputTokens, output_tokens: outputTokens } } })}\n\n`,
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    get responses() { return responses; },
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
  };
}

function startFakeProviderCompaction(provider: "codex" | "grok") {
  const workingModel = provider === "codex" ? "gpt-5.6-sol" : "grok-4.6";
  const accessToken = provider === "codex"
    ? chatgptAccessToken()
    : "grok-compaction-token";
  const bodies: string[] = [];
  const urls: string[] = [];
  const authorizations: Array<string | null> = [];
  const modelOverrides: Array<string | null> = [];
  let workingRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      urls.push(request.url);
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return provider === "codex"
          ? Response.json({ models: [
            { slug: workingModel, visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 1_050_000 },
            { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272_000 },
            { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128_000 },
          ] })
          : Response.json({ data: [
            grokSubscriptionModel(workingModel, 1_050_000),
          ] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [
          grokModalityModel(workingModel, false),
        ] });
      }
      const body = await request.text();
      bodies.push(body);
      authorizations.push(request.headers.get("authorization"));
      modelOverrides.push(request.headers.get("x-grok-model-override"));
      const parsed = JSON.parse(body) as { tools?: unknown[] };
      const compacting = (parsed.tools?.length ?? 0) === 0;
      if (!compacting) workingRequests += 1;
      if (!compacting && workingRequests === 2) {
        return Response.json({ error: { code: "context_length_exceeded", message: "maximum context length exceeded" } }, { status: 400 });
      }
      const text = compacting
        ? "The earlier request established the saved facts."
        : workingRequests === 1 ? "SAVED_PROVIDER_FACTS" : `${provider.toUpperCase()}_COMPACTION_CONTINUED`;
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
          `data: ${JSON.stringify({ type: "response.completed", response: { id: `response-${bodies.length}`, status: "completed", usage: { input_tokens: 7, output_tokens: 3 } } })}\n\n`,
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  return {
    accessToken,
    bodies,
    authorizations,
    modelOverrides,
    workingModel,
    urls,
    responsesUrl: `http://127.0.0.1:${server.port}/responses`,
    modelsUrl: `http://127.0.0.1:${server.port}/models`,
    modalitiesUrl: `http://127.0.0.1:${server.port}/modalities`,
    stop() { server.stop(true); },
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

function writeSeededChatGptLogin(
  testHome: string,
  accessToken = chatgptAccessToken(),
  expiresAtMs = Date.now() + 60 * 60 * 1000,
): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "chatgpt-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "chatgpt-refresh",
    expires_at_ms: expiresAtMs,
    account_id: "acct_e2e",
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function writeSeededGrokLogin(
  testHome: string,
  accessToken: string,
  accountId = "acct_grok_e2e",
  expiresAtMs = Date.now() + 60 * 60 * 1000,
): void {
  const fxDir = join(testHome, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "grok-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: "grok-refresh",
    expires_at_ms: expiresAtMs,
    account_id: accountId,
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

function readSingleUsageSnapshot(testHome: string): {
  billing: string;
  next_sequence: number;
  settled_through_sequence: number;
  input_tokens: number;
  output_tokens: number;
  request_count: number | null;
  models: Array<{ model: string; request_count: number | null }>;
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
      input_tokens: number;
      output_tokens: number;
      request_count: number | null;
      models: Array<{ model: string; request_count: number | null }>;
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
  resumeId?: string,
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: resumeId ? `${FX_BIN} --resume '${resumeId}'` : FX_BIN,
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
    rejectRefreshGrant?: boolean;
    beforeRefreshResponse?: () => void | Promise<void>;
    teams?: Array<{ id: string; slug: string; name: string }>;
  } = {},
) {
  const providerDetail = `provider rejected ${LOGIN_TOKEN}, ${ENV_TOKEN}, and seeded-refresh-token`;
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    clientId?: string;
    grantType?: string;
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
          const grantType = form.get("grant_type");
          recordedRequest.grantType = typeof grantType === "string" ? grantType : undefined;
          if (grantType === "refresh_token") {
            await options.beforeRefreshResponse?.();
          }
          tokenResponseCount += 1;
          if (
            (options.rejectRefreshGrant && grantType === "refresh_token") ||
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
    rejectRefresh?: boolean;
    beforeRefreshResponse?: () => void | Promise<void>;
    modelsResponse?: () => Promise<Response | void>;
  } = {},
) {
  const accessToken = chatgptAccessToken();
  let responseCount = 0;
  let models = [
    { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "max" }, { effort: "high" }], additional_speed_tiers: ["fast"], input_modalities: ["text", "image"], context_window: 272000 },
    { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
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
        const refresh = body?.includes('"grant_type":"refresh_token"') ?? false;
        if (refresh) await options.beforeRefreshResponse?.();
        if (options.rejectRefresh && refresh) {
          return Response.json({ error: { code: "refresh_token_reused" } }, { status: 401 });
        }
        return Response.json({
          access_token: accessToken,
          refresh_token: "chatgpt-refresh",
          expires_in: 3600,
        });
      }
      if (url.pathname === "/chatgpt/models") {
        const overridden = await options.modelsResponse?.();
        return overridden ?? Response.json({ models });
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
  rejectRefresh?: boolean;
  beforeRefreshResponse?: () => void | Promise<void>;
  revokeStatus?: number;
  userinfoSub?: string;
  modelsResponse?: () => Promise<Response | void>;
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
        if (refresh) await options.beforeRefreshResponse?.();
        if (refresh && options.rejectRefresh) {
          return Response.json({ error: "invalid_grant" }, { status: 400 });
        }
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
        const overridden = await options.modelsResponse?.();
        return overridden ?? Response.json({ data: subscriptionModels });
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

async function runGrokLoginWithBrowser(
  env: Record<string, string | undefined>,
  authorizationCode?: string,
) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "grok"], {
    cwd: REPO_ROOT,
    env: providerVersionTestEnv(childEnv),
    stdio: [authorizationCode ? "pipe" : "ignore", "pipe", "pipe"],
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
  if (authorizationCode) {
    proc.stdin!.end(`${authorizationCode}\n`);
  } else {
    const response = await fetch(authorizationUrl, { redirect: "follow" });
    expect(response.status).toBe(200);
  }
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
  await completeDisplayedSubscriptionLogin(
    activeSession,
    "Authorize with Grok",
    `${fixture.baseUrl}/oauth2/authorize?`,
  );
}

async function completeDisplayedCodexLogin(
  activeSession: TmuxSession,
  fixture: ReturnType<typeof startFakeChatGptOAuth>,
) {
  await completeDisplayedSubscriptionLogin(
    activeSession,
    "Authorize with Codex",
    `${fixture.baseUrl}/oauth/authorize?`,
  );
}

async function completeDisplayedSubscriptionLogin(
  activeSession: TmuxSession,
  label: string,
  authorizationUrlPrefix: string,
  expectedStatus = 200,
) {
  await activeSession.waitForText(label, TIMEOUT);
  const escapes = await activeSession.capturePaneEscapes();
  const urlStart = escapes.indexOf(authorizationUrlPrefix);
  const linkStart = escapes.lastIndexOf("\x1b]8;", urlStart);
  const urlEnd = escapes.indexOf("\x1b\\", urlStart);
  if (urlStart < 0 || linkStart < 0 || urlEnd < 0) {
    throw new Error(`${label} hyperlink was not rendered`);
  }
  const authorizationUrl = escapes.slice(urlStart, urlEnd);
  const response = await fetch(authorizationUrl, { redirect: "follow" });
  expect(response.status).toBe(expectedStatus);
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
    env: providerVersionTestEnv(childEnv),
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
  responses?: Response[];
  model?: string;
  toolCallId?: string;
  toolName?: string;
  toolArguments?: object;
  finalText?: string;
  inputModalities?: string[];
} = {}) {
  const bodies: string[] = [];
  const accessToken = chatgptAccessToken("acct_tool_loop");
  const toolName = options.toolName ?? "read_file";
  const toolArguments = options.toolArguments ?? { path: "README.md" };
  const finalText = options.finalText ?? "CODEX_TOOL_LOOP_OK";
  const inputModalities = options.inputModalities ?? ["text"];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname === "/models") {
        return Response.json({ models: [
          { slug: "gpt-5.6-sol", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "high" }], additional_speed_tiers: [], input_modalities: inputModalities, context_window: 272000 },
          { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
        ].map((model, index) => index === 0 && options.model ? { ...model, slug: options.model } : model) });
      }
      bodies.push(await request.text());
      if (options.responses) return options.responses.shift() ?? new Response("unexpected request", { status: 400 });
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: options.toolCallId ?? "call_tool", name: toolName } })}\n\n` +
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
          { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
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
  responses?: Response[];
  model?: string;
  toolCallId?: string;
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
        return Response.json({ data: [grokSubscriptionModel(options.model ?? "grok-4.20", 1_000_000)] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [grokModalityModel(options.model ?? "grok-4.20", true)] });
      }
      bodies.push(await request.text());
      if (options.responses) return options.responses.shift() ?? new Response("unexpected request", { status: 400 });
      if (bodies.length === 1) {
        return new Response(
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning"}}\n\n' +
            'data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_tool","type":"reasoning","summary":[],"encrypted_content":"opaque-grok-tool-loop"}}\n\n' +
            `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: options.toolCallId ?? "call_tool", name: toolName } })}\n\n` +
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
          { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
        ] });
      }
      const body = await request.text();
      bodies.push(body);
      const model = (JSON.parse(body) as { model?: string }).model;
      if (model === "gpt-5.6-luna") {
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
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_shell","name":"shell"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"request\\":{\\"action\\":\\"run\\",\\"command\\":\\"printf reviewed > provider-review-existing.txt\\",\\"yield_time_ms\\":30000,\\"timeout_ms\\":600000}}"}\n\n' +
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
          'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_shell","name":"shell"}}\n\n' +
            'data: {"type":"response.function_call_arguments.done","output_index":0,"arguments":"{\\"request\\":{\\"action\\":\\"run\\",\\"command\\":\\"printf reviewed > provider-review-existing.txt\\",\\"yield_time_ms\\":30000,\\"timeout_ms\\":600000}}"}\n\n' +
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

for (const provider of ["gateway", "codex", "grok"] as const) {
  tmuxTest(`pending ${provider} prompt retries repaired credential storage without changing accounts`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-prompt-storage-retry-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_STORAGE_RECOVERED")]);
    oauth = startFakeOAuth("unused-token");
    chatgptOauth = startFakeChatGptOAuth({ unauthorizedResponses: 0 });
    const grok = startFakeGrokOAuth({ unauthorizedResponses: 0 });
    try {
      writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
      writeSeededChatGptLogin(home);
      writeSeededGrokLogin(home, grok.initialAccessToken);
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
        provider,
        credential_source: "fx_login",
        models: { gateway: FAKE_GATEWAY_MODEL, codex: "gpt-5.6-sol", grok: "grok-4.20" },
      }));
      const name = provider === "gateway" ? "auth.json" : provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json";
      const alias = join(home, "auth.alias");
      linkSync(join(home, ".fx", name), alias);
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
        FX_MODEL: undefined,
        ...chatgptOauth.env,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      const prompt = `STORAGE_RETRY_${provider}`;
      await session.sendText(prompt);
      await session.waitForPane((pane) => pane.includes(prompt) && pane.slice(pane.lastIndexOf(prompt) + prompt.length).includes("Auth:"), TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback.slice(scrollback.lastIndexOf(prompt) + prompt.length)).toContain("Saved credential storage is unavailable");
      expect(gateway.requests).toHaveLength(0);
      expect(oauth.requests).toHaveLength(0);
      expect(chatgptOauth.requests).toHaveLength(0);
      expect(grok.requests).toHaveLength(0);

      unlinkSync(alias);
      await session.sendKeys("Enter");
      await session.waitForText(provider === "gateway" ? "GATEWAY_STORAGE_RECOVERED" : provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE", TIMEOUT);
      const requests = provider === "gateway" ? gateway.requests : provider === "codex"
        ? chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses")
        : grok.requests.filter((request) => request.path === "/v1/responses");
      expect(requests).toHaveLength(1);
      expect(JSON.stringify(requests[0]!.body)).toContain(prompt);
      if (provider === "gateway") {
        expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
      } else {
        expect(gateway.requests).toHaveLength(0);
      }
      expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe(provider);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  }, TIMEOUT);
}


for (const provider of ["codex", "grok"] as const) {
  tmuxTest(`provider recovery switches from ${provider} after logout and preserves the fallback on restart`, async () => {
    home = mkdtempSync(join(tmpdir(), `fx-logout-fallback-${provider}-`));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText("LOGOUT_GATEWAY_RESPONSE")]);
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      writeSeededChatGptLogin(home, chatgptOauth.accessToken);
      writeSeededGrokLogin(home, grok.initialAccessToken);
      const settingsPath = join(home, ".fx", "settings.json");
      writeFileSync(settingsPath, JSON.stringify({
        provider, models: { gateway: FAKE_GATEWAY_MODEL, codex: "gpt-5.6-sol", grok: "grok-4.6" },
      }), { mode: 0o600 });
      const env = { ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined };
      session = await startFx(home, stderrPath, gateway, undefined, undefined, env);
      await session.waitForComposer(TIMEOUT);
      const inactive = provider === "codex" ? "grok" : "codex";
      await session.sendText(`/logout ${inactive}`);
      await session.waitForText(`Signed out of ${inactive === "codex" ? "Codex" : "Grok"}.`, TIMEOUT);
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe(provider);
      await session.sendText("/logout");
      await session.waitForText(`Signed out of ${provider === "codex" ? "Codex" : "Grok"}.`, TIMEOUT);
      await openProviderPicker(session);
      expect(await session.capturePane()).toContain("vercel · current");
      expect(existsSync(join(home, ".fx", provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json"))).toBe(false);
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
      await session.sendKeys("Escape");
      await session.sendKeys("C-u");
      await session.sendText("Use the remaining provider.");
      await session.waitForText("LOGOUT_GATEWAY_RESPONSE", TIMEOUT);
      expect(gateway.requests).toHaveLength(1);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TIMEOUT);
      session = null;
      session = await startFx(home, stderrPath, gateway, undefined, undefined, env);
      await session.waitForComposer(TIMEOUT);
      await openProviderPicker(session);
      expect(await session.capturePane()).toContain("vercel · current");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  }, 60_000);

  tmuxTest(`provider recovery activates ${provider} sign-in after a cancelled turn`, async () => {
    home = mkdtempSync(join(tmpdir(), `fx-cancel-login-${provider}-`));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    gateway = startFakeGateway([async () => {
      await held;
      return fakeGatewayFinalText("CANCELLED_GATEWAY_RESPONSE");
    }]);
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Hold this request until cancelled.");
      const deadline = Date.now() + TIMEOUT;
      while (gateway.requests.length === 0) {
        if (Date.now() > deadline) throw new Error("Gateway request did not start");
        await Bun.sleep(20);
      }
      await session.sendKeys("C-c");
      await session.waitForText("What can fx do differently?", TIMEOUT);
      release();
      await openProviderPicker(session);
      await session.sendKeys("Down");
      if (provider === "grok") await session.sendKeys("Down");
      await session.sendKeys("Enter");
      if (provider === "codex") await completeDisplayedCodexLogin(session, chatgptOauth);
      else await completeDisplayedGrokLogin(session, grok);
      const label = provider === "codex" ? "Codex" : "Grok";
      const outcome = await session.waitForPane(
        (pane) => pane.includes(`Switched to ${label} subscription`) ||
          pane.includes("Subscription sign-in completed, but"),
        TIMEOUT,
      );
      expect(outcome).toContain(`Switched to ${label} subscription`);
      await session.sendText("Use the subscription immediately after sign-in.");
      await session.waitForText(provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE", TIMEOUT);
      expect(gateway.requests).toHaveLength(1);
      expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe(provider);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      release();
      grok.stop();
    }
  }, 60_000);
}

for (const gatewayState of ["absent", "rejected"] as const) {
  tmuxTest(`provider recovery uses the remaining subscription when Gateway is ${gatewayState}`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-logout-other-subscription-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([], { models: () => [] });
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      writeSeededChatGptLogin(home, chatgptOauth.accessToken);
      writeSeededGrokLogin(home, grok.initialAccessToken);
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
        provider: "codex", models: { codex: "gpt-5.6-sol", grok: "grok-4.6" },
      }), { mode: 0o600 });
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined,
        AI_GATEWAY_API_KEY: gatewayState === "absent" ? undefined : ENV_TOKEN,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/logout");
      await session.waitForText("Signed out of Codex.", TIMEOUT);
      await openProviderPicker(session);
      expect(await session.capturePane()).toContain("grok · current");
      await session.sendKeys("Escape");
      await session.sendKeys("C-u");
      await session.sendText("Use the remaining subscription.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);
      expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe("grok");
      expect(grok.requests.filter((request) => request.path === "/oauth2/token")).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  }, 60_000);
}

for (const otherProvider of ["codex", "grok"] as const) {
  tmuxTest(`default logout preserves ${otherProvider} when active fx login becomes unreadable`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-logout-active-unreadable-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth("unused-token");
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
    if (otherProvider === "codex") writeSeededChatGptLogin(home);
    else writeSeededGrokLogin(home, "other-grok-token");
    const otherPath = join(home, ".fx", otherProvider === "codex" ? "chatgpt-auth.json" : "grok-auth.json");
    const otherCredential = readFileSync(otherPath, "utf8");
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "gateway", credential_source: "fx_login" }));
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    const authPath = join(home, ".fx", "auth.json");
    linkSync(authPath, join(home, "login.alias"));
    await session.sendText("/logout");
    const result = await session.waitForPane(
      (pane) => pane.includes("Signed out of fx.") || pane.includes(`Signed out of ${otherProvider === "codex" ? "Codex" : "Grok"}.`),
      TIMEOUT,
    );
    expect(result).toContain("Signed out of fx.");
    expect(readFileSync(otherPath, "utf8")).toBe(otherCredential);
    expect(existsSync(authPath)).toBe(false);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);
}

tmuxTest("provider recovery stays signed out when no replacement is connected", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-logout-no-provider-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  gateway = startFakeGateway([]);
  chatgptOauth = startFakeChatGptOAuth();
  writeSeededChatGptLogin(home, chatgptOauth.accessToken);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "codex", models: { codex: "gpt-5.6-sol" },
  }), { mode: 0o600 });
  session = await startFx(home, stderrPath, gateway, undefined, undefined, {
    ...chatgptOauth.env, FX_MODEL: undefined, AI_GATEWAY_API_KEY: undefined,
  });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("/logout");
  await session.waitForText("Signed out of Codex.", TIMEOUT);
  await openProviderPicker(session);
  const pane = await session.capturePane();
  expect(pane).not.toContain("codex · current");
  expect(pane).not.toContain("vercel · current");
  expect(pane).not.toContain("grok · current");
  expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);
  expect(gateway.requests).toHaveLength(0);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, 60_000);

tmuxTest("provider recovery refuses active logout before deleting a busy subscription", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-logout-busy-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  gateway = startFakeGateway([]);
  chatgptOauth = startFakeChatGptOAuth({ responseDelayMs: 10_000 });
  writeSeededChatGptLogin(home, chatgptOauth.accessToken);
  const authPath = join(home, ".fx", "chatgpt-auth.json");
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "codex", models: { codex: "gpt-5.6-sol" },
  }), { mode: 0o600 });
  session = await startFx(home, stderrPath, gateway, undefined, undefined, {
    ...chatgptOauth.env, FX_MODEL: undefined,
  });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("Keep this response open.");
  const deadline = Date.now() + TIMEOUT;
  while (!chatgptOauth.requests.some((request) => request.path === "/chatgpt/responses")) {
    if (Date.now() > deadline) throw new Error("Codex request did not start");
    await Bun.sleep(20);
  }
  await session.sendText("/logout");
  const outcome = await session.waitForPane(
    (pane) => pane.includes("Sign out is unavailable until active and queued work finishes.") ||
      pane.includes("Signed out of Codex."),
    TIMEOUT,
  );
  expect(outcome).toContain("Sign out is unavailable until active and queued work finishes.");
  expect(existsSync(authPath)).toBe(true);
  await session.sendKeys("C-c");
  await session.waitForText("What can fx do differently?", TIMEOUT);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, 60_000);

tmuxTest("provider recovery validates a Gateway team after a cancelled turn", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cancel-team-selection-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  gateway = startFakeGateway([
    async () => { await held; return fakeGatewayFinalText("CANCELLED_TEAM_RESPONSE"); },
    fakeGatewayFinalText("TEAM_AFTER_CANCEL_RESPONSE"),
  ]);
  oauth = startFakeOAuth(LOGIN_TOKEN, undefined, 3600, Infinity, {
    teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
  });
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
  try {
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Hold this request until cancelled.");
    const deadline = Date.now() + TIMEOUT;
    while (gateway.requests.length === 0) {
      if (Date.now() > deadline) throw new Error("Gateway request did not start");
      await Bun.sleep(20);
    }
    await session.sendKeys("C-c");
    await session.waitForText("What can fx do differently?", TIMEOUT);
    release();
    await selectFxLoginCredential(session);
    expect(gateway.modelRequests.some((request) =>
      request.headers.get("authorization") === `Bearer ${LOGIN_TOKEN}`)).toBe(true);
    await session.sendText("Use the selected Vercel team.");
    await session.waitForText("TEAM_AFTER_CANCEL_RESPONSE", TIMEOUT);
    expect(gateway.requests.at(-1)?.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    release();
  }
}, 60_000);

tmuxTest("pending Gateway prompt waits for valid saved preferences and a repaired login", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-prompt-preference-retry-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = JSON.stringify({ provider: "gateway", credential_source: "fx_login", models: { gateway: FAKE_GATEWAY_MODEL } });
  writeFileSync(settingsPath, settings);
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([fakeGatewayFinalText("PREFERENCE_REPAIRED")]);
  oauth = startFakeOAuth("unused-token");
  session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, { FX_MODEL: undefined });
  await session.waitForComposer(TIMEOUT);
  writeFileSync(settingsPath, "not-json");
  await session.sendText("PREFERENCE_RETRY_PROMPT");
  await session.waitForText("Could not load authentication settings", TIMEOUT);
  expect(gateway.requests).toHaveLength(0);

  writeFileSync(settingsPath, settings);
  await session.sendKeys("Enter");
  await session.waitForPane(
    (pane) => pane.lastIndexOf("fx needs access to Vercel AI Gateway") > pane.lastIndexOf("Could not load authentication settings"),
    TIMEOUT,
  );
  expect(gateway.requests).toHaveLength(0);
  writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
  await session.sendKeys("Enter");
  await session.waitForText("PREFERENCE_REPAIRED", TIMEOUT);
  expect(gateway.requests).toHaveLength(1);
  expect(JSON.stringify(gateway.requests[0]!.body)).toContain("PREFERENCE_RETRY_PROMPT");
  expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
  expect(oauth.requests).toHaveLength(0);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

test("Vercel CLI keeps an issuer authorization denial distinct from persistence failure", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-vercel-authorization-denied-"));
  oauth = startFakeOAuth("unused-token", undefined, 3600, Number.POSITIVE_INFINITY, {
    deviceError: "access_denied",
    rejectAllDeviceClients: true,
  });
  const result = await runFx(["login", "vercel"], { env: {
    HOME: home,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_NO_OPEN_BROWSER: "1",
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
  }, timeoutMs: TIMEOUT });
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("authorization denied");
  expect(result.stderr).not.toContain("Credential could not be saved");
  expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
}, TIMEOUT);

test("Vercel CLI reports a post-authorization save failure without claiming authorization was denied", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-vercel-save-failure-"));
  gateway = startFakeGateway([]);
  oauth = startFakeOAuth("new-token", undefined, 3600, Number.POSITIVE_INFINITY, {
    tokenDelayMs: 300,
    teams: [{ id: "team_fixture", slug: "fixture", name: "Fixture" }],
  });
  writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
  const authPath = join(home, ".fx", "auth.json");
  const previous = readFileSync(authPath, "utf8");
  const login = runFx(["login", "vercel"], { env: {
    HOME: home,
    AI_GATEWAY_API_KEY: ENV_TOKEN,
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_NO_OPEN_BROWSER: "1",
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  }, timeoutMs: TIMEOUT });
  const deadline = Date.now() + 10_000;
  while (!oauth.requests.some((request) => request.path === "/oauth/token") && Date.now() < deadline) await Bun.sleep(5);
  expect(oauth.requests.some((request) => request.path === "/oauth/token")).toBe(true);
  chmodSync(authPath, 0o400);
  const result = await login;
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("Credential could not be saved");
  expect(result.stderr).not.toContain("authorization denied");
  expect(result.stdout).not.toContain("Signed in");
  expect(readFileSync(authPath, "utf8")).toBe(previous);
  expect(gateway.requests).toHaveLength(0);
}, TIMEOUT);

tmuxTest(
  "malformed sessions and read-only locks never become missing authentication",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-storage-error-kinds-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth("unused-token");
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      for (const damage of ["malformed", "lock"]) {
        writeSeededFxLogin(home, damage === "lock" ? 0 : Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
        writeSeededChatGptLogin(home);
        writeSeededGrokLogin(home, grok.initialAccessToken);
        if (damage === "malformed") {
          for (const name of ["auth.json", "chatgpt-auth.json", "grok-auth.json"]) {
            writeFileSync(join(home, ".fx", name), "not-json", { mode: 0o600 });
          }
        } else {
          for (const name of ["auth.lock", "chatgpt-auth.lock", "grok-auth.lock"]) {
            writeFileSync(join(home, ".fx", name), "");
            chmodSync(join(home, ".fx", name), 0o400);
          }
        }
        session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
          ...chatgptOauth.env,
          ...grok.env,
        });
        await session.waitForComposer(TIMEOUT);
        for (const [provider, label] of [["vercel", "Vercel AI Gateway"], ["codex", "Codex subscription"], ["grok", "Grok subscription"]]) {
          await session.sendKeys("Escape");
          await session.sendKeys("C-u");
          await openProviderPicker(session);
          await session.sendText(provider);
          if (provider === "vercel") {
            await session.waitForPane((pane) => pane.includes("oauth") && pane.includes("api-key"), TIMEOUT);
            await session.sendKeys("Enter");
          }
          await session.waitForText(`${label}: Saved credential storage is unavailable`, 10_000);
          expect(await session.captureFullScrollback()).not.toContain("Waiting for authorization");
        }
        expect(oauth.requests).toHaveLength(0);
        expect(chatgptOauth.requests).toHaveLength(0);
        expect(grok.requests).toHaveLength(0);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.kill();
        session = null;
      }
    } finally {
      grok.stop();
    }
  },
  60_000,
);

for (const command of ["/provider", "/login", "/setup"]) {
  tmuxTest(`provider picker retains type-ahead after ${command} Enter`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-provider-typeahead-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);

    await session.sendLiteral(`${command}\rcodex`);
    const prefix = command === "/login" ? "/login" : "/provider";
    await session.waitForPane(
      (pane) => pane.split("\n").some((line) => line.trim() === `┃ ${prefix} codex`) && /^\s+codex\s*$/m.test(pane),
      TIMEOUT,
    );
    await session.sendKeys("BSpace");
    await session.waitForPane(
      (pane) => pane.split("\n").some((line) => line.trim() === `┃ ${prefix} code`),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await session.sendLiteral("retained draft");
    await session.waitForText("retained draft", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);
    expect(await session.captureFullScrollback()).not.toContain("Authorize with Codex");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT * 2);
}

tmuxTest("provider picker consumes selection keys while inventory is pending", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-provider-pending-"));
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([]);
  chatgptOauth = startFakeChatGptOAuth();
  session = await startFx(home, stderrPath, gateway, undefined, undefined, chatgptOauth.env);
  await session.waitForComposer(TIMEOUT);

  await session.sendLiteral("/provider\rco\t\r");
  await session.waitForPane(
    (pane) => pane.split("\n").some((line) => line.trim() === "┃ /provider co") && /^\s+codex\s*$/m.test(pane),
    TIMEOUT,
  );
  expect(gateway.requests).toHaveLength(0);
  expect(chatgptOauth.requests).toHaveLength(0);
  await session.sendKeys("Tab");
  await session.waitForText("/provider codex", TIMEOUT);
  await session.sendKeys("Escape");
  await session.sendKeys("C-u");
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT * 2);

for (const scenario of [
  { name: "bare provider", command: "/provider" },
  { name: "setup alias", command: "/setup" },
  { name: "login alias", command: "/login" },
  { name: "typed provider query", command: "/provider " },
]) {
  tmuxTest(`first Enter reports busy provider flow for ${scenario.name}`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-provider-picker-busy-"));
    stderrPath = join(home, "stderr.log");
    let cancelled = false;
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    const encoder = new TextEncoder();
    gateway = startFakeGateway([() => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode('data: {"type":"text-delta","delta":"The response remains active.\\n\\n"}\n\n'));
        heartbeat = setInterval(() => controller.enqueue(encoder.encode(": keep-alive\n\n")), 100);
      },
      cancel() {
        cancelled = true;
        clearInterval(heartbeat);
      },
    }), { headers: { "content-type": "text/event-stream" } })]);
    try {
      session = await startFx(home, stderrPath, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Keep the response active while I inspect provider settings.");
      await session.waitForText("Generating", TIMEOUT);

      await session.sendText(scenario.command);
      const notice = "Provider switching is unavailable until active and queued work finishes.";
      await session.waitForText(notice, TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback.split(notice)).toHaveLength(2);
      expect(cancelled).toBe(false);
      expect(gateway.requests).toHaveLength(1);

      await session.sendKeys("C-u");
      await session.sendKeys("Escape");
      await session.waitForText("What can fx do differently?", TIMEOUT);
      await session.sendText(scenario.command.trim());
      await session.waitForPane(
        (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
        TIMEOUT,
      );
      expect(cancelled).toBe(true);
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      clearInterval(heartbeat);
    }
  }, TIMEOUT * 2);
}

tmuxTest(
  "unavailable configured credentials remain recoverable in TUI ask and ACP",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-startup-failure-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([
      fakeGatewayFinalText("GATEWAY_RECOVERED_gateway"),
      fakeGatewayFinalText("GATEWAY_RECOVERED_codex"),
      fakeGatewayFinalText("GATEWAY_RECOVERED_grok"),
    ]);
    oauth = startFakeOAuth("unused-token");
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
    writeSeededChatGptLogin(home);
    writeSeededGrokLogin(home, grok.initialAccessToken);
    for (const name of ["auth.json", "chatgpt-auth.json", "grok-auth.json"]) {
      linkSync(join(home, ".fx", name), join(home, `${name}.alias`));
    }
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_MODEL: undefined,
      FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
      ...chatgptOauth.env,
      ...grok.env,
    };
    try {
      for (const provider of ["gateway", "codex", "grok"]) {
        writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
          provider,
          credential_source: "fx_login",
          models: { gateway: FAKE_GATEWAY_MODEL, codex: "gpt-5.6-sol", grok: "grok-4.20" },
        }));
        const status = await runFx(["status", "--json"], { env });
        expect(status.code).toBe(0);
        expect(JSON.parse(status.stdout).auth_help).toContain("Saved credential storage is unavailable");
        const doctor = await runFx(["doctor", "--json"], { env });
        expect(doctor.timedOut).toBe(false);
        expect(doctor.stdout).toContain("Saved credential storage is unavailable");
        const ask = await runFx(["ask", "--json", "--no-save", "do not use another account"], { env });
        expect(ask.code).toBe(1);
        expect(JSON.parse(ask.stdout).error).toBe("CredentialStorageUnavailable");
        const acp = await runFx(["acp"], {
          env,
          stdin: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }) + "\n",
        });
        expect(acp.code).toBe(0);
        const response = acp.stdout.trim().split("\n").map((line) => JSON.parse(line)).find((message) => message.id === 1);
        expect(response.error.code).toBe(-32600);
        expect(response.error.message).toContain("Saved credential storage is unavailable");
        session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, env);
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/status");
        await session.waitForText("auth_help=", TIMEOUT);
        expect(await session.captureFullScrollback()).toContain(
          "auth_help=Saved credential storage is unavailable",
        );
        await selectEnvKeyCredential(session);
        await session.sendText("Use the working Gateway account.");
        await session.waitForText(`GATEWAY_RECOVERED_${provider}`, TIMEOUT);
        await session.sendText("/status");
        await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
        const scrollback = await session.captureFullScrollback();
        const recoveredStatus = scrollback.slice(scrollback.lastIndexOf("● Status:"));
        expect(recoveredStatus).toContain("auth=AI_GATEWAY_API_KEY");
        expect(recoveredStatus).not.toContain("auth_help=");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.kill();
        session = null;
      }
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "browser authorization reports a failed save without activating the provider",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-callback-save-failure-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_AFTER_FAILED_SIGNIN")]);
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        ...chatgptOauth.env,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      for (const [provider, label] of [["codex", "Codex"], ["grok", "Grok"]]) {
        await openProviderPicker(session);
        await session.sendText(provider);
        await session.waitForText(`Authorize with ${label}`, TIMEOUT);
        if (provider === "codex") writeSeededChatGptLogin(home);
        else writeSeededGrokLogin(home, grok.initialAccessToken);
        const name = provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json";
        const original = join(home, ".fx", name);
        linkSync(original, join(home, `${name}.alias`));
        await completeDisplayedSubscriptionLogin(
          session,
          `Authorize with ${label}`,
          provider === "codex" ? `${chatgptOauth.baseUrl}/oauth/authorize?` : `${grok.baseUrl}/oauth2/authorize?`,
          400,
        );
        await session.waitForText(`${label} subscription: Credential could not be saved`, TIMEOUT);
        expect(await session.captureFullScrollback()).not.toContain(`Switched to ${label}`);
        expect(statSync(original).nlink).toBe(2);
        expect(readFileSync(original, "utf8")).toBe(readFileSync(join(home, `${name}.alias`), "utf8"));
        await session.waitForComposer(TIMEOUT);
      }
      await session.sendText("Use the original Gateway credential.");
      await session.waitForText("GATEWAY_AFTER_FAILED_SIGNIN", TIMEOUT);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

tmuxTest(
  "all provider sign-in entries reject unavailable storage before OAuth",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-storage-admission-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth("unused-token");
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_fixture");
    writeSeededChatGptLogin(home);
    writeSeededGrokLogin(home, grok.initialAccessToken);
    for (const name of ["auth.json", "chatgpt-auth.json", "grok-auth.json"]) {
      linkSync(join(home, ".fx", name), join(home, `${name}.alias`));
    }
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_NO_OPEN_BROWSER: "1",
      FX_OAUTH_CLIENT_ID: "test-client",
      FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
      ...chatgptOauth.env,
      ...grok.env,
    };
    try {
      for (const provider of ["vercel", "codex", "grok"]) {
        const result = await runFx(["login", provider], { env, timeoutMs: 3000 });
        expect(result.timedOut).toBe(false);
        expect(result.code).toBe(1);
        expect(result.stderr).toContain("Saved credential storage is unavailable");
        expect(result.stdout).not.toContain("http");
      }
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, env);
      await session.waitForComposer(TIMEOUT);
      await openProviderPicker(session);
      await session.sendKeys("Enter");
      await session.waitForPane((pane) => pane.includes("oauth") && pane.includes("api-key"), TIMEOUT);
      await session.sendKeys("Enter");
      await session.waitForText("Saved credential storage is unavailable", TIMEOUT);
      expect(await session.captureFullScrollback()).not.toContain("Sign in with Vercel");
      for (const name of ["auth.json", "chatgpt-auth.json", "grok-auth.json"]) {
        unlinkSync(join(home, `${name}.alias`));
        chmodSync(join(home, ".fx", name), 0o400);
      }
      for (const provider of ["vercel", "codex", "grok"]) {
        const result = await runFx(["login", provider], { env, timeoutMs: 3000 });
        expect(result.timedOut).toBe(false);
        expect(result.code).toBe(1);
        expect(result.stderr).toContain("Saved credential storage is unavailable");
        expect(result.stdout).not.toContain("http");
      }
      expect(oauth.requests).toHaveLength(0);
      expect(chatgptOauth.requests).toHaveLength(0);
      expect(grok.requests).toHaveLength(0);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  30_000,
);

tmuxTest(
  "unavailable saved subscriptions keep login and provider selection usable",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-unavailable-subscriptions-"));
    stderrPath = join(home, "stderr.log");
    writeSeededChatGptLogin(home);
    writeSeededGrokLogin(home, "grok-initial-access-token");
    for (const name of ["chatgpt-auth.json", "grok-auth.json"]) {
      linkSync(join(home, ".fx", name), join(home, `${name}.alias`));
    }
    gateway = startFakeGateway([fakeGatewayFinalText("GATEWAY_WITH_UNAVAILABLE_SUBSCRIPTIONS")]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      10_000,
    );
    const scrollback = await session.captureFullScrollback();
    expect(scrollback).toContain("Codex subscription is unavailable");
    expect(scrollback).toContain("Grok subscription is unavailable");
    expect(scrollback).not.toContain("picker was not opened with stale data");
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await selectEnvKeyCredential(session);
    await session.sendText("Keep using the working Gateway credential.");
    await session.waitForText("GATEWAY_WITH_UNAVAILABLE_SUBSCRIPTIONS", TIMEOUT);
    for (const name of ["chatgpt-auth.json", "grok-auth.json"]) {
      expect(statSync(join(home, ".fx", name)).nlink).toBe(2);
    }
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

tmuxTest(
  "unavailable saved subscription reports storage failure and recovers after repair",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-auth-unavailable-signin-"));
    stderrPath = join(home, "stderr.log");
    writeSeededChatGptLogin(home);
    writeSeededGrokLogin(home, "grok-initial-access-token");
    for (const name of ["chatgpt-auth.json", "grok-auth.json"]) {
      linkSync(join(home, ".fx", name), join(home, `${name}.alias`));
    }
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth();
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        ...chatgptOauth.env,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      for (const [provider, label] of [["codex", "Codex"], ["grok", "Grok"]]) {
        await openProviderPicker(session);
        await session.sendText(provider);
        await session.waitForText(`${label} subscription: Saved credential storage is unavailable`, 10_000);
        const blocked = await session.captureFullScrollback();
        expect(blocked).not.toContain(`Authorize with ${label}`);
        expect(blocked).not.toContain(`Switched to ${label}`);
        await session.waitForComposer(TIMEOUT);

        const name = provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json";
        const original = join(home, ".fx", name);
        expect(statSync(original).nlink).toBe(2);
        expect(readFileSync(original, "utf8")).toBe(readFileSync(join(home, `${name}.alias`), "utf8"));
        unlinkSync(join(home, `${name}.alias`));
        await openProviderPicker(session);
        await session.sendText(provider);
        await session.waitForText(`Switched to ${label} subscription`, TIMEOUT);
        await session.sendText(`Use the saved ${label} credential.`);
        await session.waitForText(provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE", TIMEOUT);
      }
      for (const name of ["chatgpt-auth.json", "grok-auth.json"]) {
        expect(statSync(join(home, ".fx", name)).nlink).toBe(1);
      }
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

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
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
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
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
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
    expect(signInScreen).toMatch(/^Sign in with Codex\s+Waiting for authorization…$/m);
    expect(signInScreen).toMatch(/^  Open\s+Authorize with Codex$/m);
    expect(signInScreen).toMatch(/^Enter reopens browser · Esc cancels$/m);
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

for (const [provider, previousProvider] of [
  ["codex", "gateway"],
  ["grok", "gateway"],
  ["gateway", "codex"],
  ["gateway", "grok"],
] as const) {
  for (const resumeMode of ["startup", "picker"] as const) {
    tmuxTest(
      `${provider} ${resumeMode} resume authenticates the model catalog before the first prompt from ${previousProvider}`,
      async () => {
        home = mkdtempSync(join(tmpdir(), "fx-auth-resume-"));
        stderrPath = join(home, "stderr.log");
        gateway = startFakeGateway(provider === "gateway" ? [
          fakeGatewayFinalText("GATEWAY_RESUME_SEED"),
          fakeGatewayFinalText("GATEWAY_RESUME_REPLY"),
        ] : []);
        oauth = startFakeOAuth(null);
        chatgptOauth = startFakeChatGptOAuth();
        const grok = startFakeGrokOAuth();
        try {
          writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
          writeSeededChatGptLogin(home, chatgptOauth.accessToken);
          writeSeededGrokLogin(home, grok.initialAccessToken);
          const models = { gateway: FAKE_GATEWAY_MODEL, codex: "gpt-5.6-sol", grok: "grok-4.20" };
          const model = models[provider];
          const otherModel = provider === "codex" ? "gpt-5.4-mini" : provider === "grok" ? "grok-4.6" : model;
          const settingsPath = join(home, ".fx", "settings.json");
          writeFileSync(settingsPath, JSON.stringify({ provider, credential_source: "fx_login", models }) + "\n", { mode: 0o600 });
          const env = {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_MODEL: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
            ...chatgptOauth.env,
            ...grok.env,
          };
          const seeded = await runFx(["ask", "--json", "--auto", "Save the provider resume fixture."], {
            env,
            timeoutMs: TIMEOUT,
          });
          expect(seeded.code, `stdout: ${seeded.stdout}\nstderr: ${seeded.stderr}`).toBe(0);
          const saved = JSON.parse(seeded.stdout) as { session_id: string; output: string };
          expect(saved.session_id).toMatch(/^[a-zA-Z0-9_-]+$/);
          expect(saved.output).toContain(provider === "gateway" ? "GATEWAY_RESUME_SEED" : provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE");
          const preferences = { provider: previousProvider, credential_source: "fx_login", models };
          writeFileSync(settingsPath, JSON.stringify(preferences) + "\n", { mode: 0o600 });
          chatgptOauth.requests.length = 0;
          grok.requests.length = 0;
          gateway.requests.length = 0;
          gateway.modelRequests.length = 0;

          session = await startFx(
            home,
            stderrPath,
            gateway,
            oauth.issuerUrl,
            undefined,
            env,
            undefined,
            resumeMode === "startup" ? saved.session_id : undefined,
          );
          await session.waitForComposer(TIMEOUT);
          if (resumeMode === "picker") {
            await session.sendText("/resume");
            await session.waitForPane((pane) => pane.includes("Sessions") && /\bturns?\b/.test(pane), TIMEOUT);
            await session.sendKeys("Enter");
            await session.waitForText("● Session resumed:", TIMEOUT);
          }
          await session.sendText("/model");
          const catalog = await session.waitForPane(
            (pane) => pane.includes("Models") && pane.includes(model) && pane.includes(otherModel),
            10_000,
          );
          if (provider !== "gateway") expect(catalog).not.toContain(FAKE_GATEWAY_MODEL);
          const direct = provider === "codex" ? chatgptOauth : grok;
          const catalogPath = provider === "codex" ? "/chatgpt/models" : "/v1/models";
          const responsePath = provider === "codex" ? "/chatgpt/responses" : "/v1/responses";
          const token = provider === "gateway" ? LOGIN_TOKEN : provider === "codex" ? chatgptOauth.accessToken : grok.initialAccessToken;
          const catalogAuthorizations = provider === "gateway"
            ? gateway.modelRequests.map((request) => request.headers.get("authorization"))
            : direct.requests.filter((request) => request.path === catalogPath).map((request) => request.authorization);
          const responses = () => provider === "gateway"
            ? gateway!.requests.map((request) => ({ authorization: request.headers.get("authorization"), body: request.body }))
            : direct.requests.filter((request) => request.path === responsePath);
          expect(catalogAuthorizations.length).toBeGreaterThan(0);
          const catalogSources = catalogAuthorizations.map((authorization) =>
            authorization === `Bearer ${LOGIN_TOKEN}` ? "fx_login"
              : authorization === `Bearer ${chatgptOauth!.accessToken}` ? "codex"
                : authorization === `Bearer ${grok.initialAccessToken}` ? "grok"
                  : authorization === null ? "public" : "other");
          expect(catalogSources).toEqual(Array(catalogSources.length).fill(provider === "gateway" ? "fx_login" : provider));
          expect(gateway.requests).toHaveLength(0);
          expect(chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses")).toHaveLength(0);
          expect(grok.requests.filter((request) => request.path === "/v1/responses")).toHaveLength(0);
          expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toEqual(preferences);
          await session.sendKeys("Escape");
          await session.waitForPane((pane) => !pane.includes("Esc Close"), TIMEOUT);
          await session.sendKeys("C-u");
          await session.waitForComposer(TIMEOUT);
          await session.sendText("Continue the restored provider session.");
          await session.waitForPane(() => responses().length > 0, 10_000);
          expect(responses()).toHaveLength(1);
          expect(responses()[0]!.authorization).toBe(`Bearer ${token}`);
          expect(responses()[0]!.body).toContain("Continue the restored provider session.");
          if (provider === "gateway") await session.waitForText("GATEWAY_RESUME_REPLY", TIMEOUT);
          if (provider !== "gateway") expect(gateway.requests).toHaveLength(0);
          if (provider !== "codex") expect(chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses")).toHaveLength(0);
          if (provider !== "grok") expect(grok.requests.filter((request) => request.path === "/v1/responses")).toHaveLength(0);
          for (const [authorizations, expected] of [
            [[...gateway.requests, ...gateway.modelRequests].map((request) => request.headers.get("authorization")), LOGIN_TOKEN],
            [chatgptOauth.requests.map((request) => request.authorization), chatgptOauth.accessToken],
            [grok.requests.map((request) => request.authorization), grok.initialAccessToken],
          ] as const) {
            for (const authorization of authorizations) {
              if (authorization !== null) expect(authorization).toBe(`Bearer ${expected}`);
            }
          }
          expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toEqual(preferences);
          const scrollback = await session.captureFullScrollback();
          expect(scrollback).not.toContain(token);
          expect(readFileSync(stderrPath, "utf8")).toBe("");
          await session.sendText("/quit");
          await session.waitForSessionEnd();
        } finally {
          grok.stop();
        }
      },
      60_000,
    );
  }
}

tmuxTest(
  "provider switch before the first prompt discards the previous credential prewarm",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-prewarm-provider-switch-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(null);
    chatgptOauth = startFakeChatGptOAuth();
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ credential_source: "fx_login" }) + "\n",
      { mode: 0o600 },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      ...chatgptOauth.env,
      FX_MODEL: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await waitForTrace(tracePath, "prompt credential prewarm start outcome=started");
    await openProviderPicker(session);
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    await session.waitForText("Switched to Codex subscription", TIMEOUT);

    await session.sendText("Use the selected subscription for the first prompt.");
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", 10_000);
    const responses = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/responses",
    );
    expect(responses).toHaveLength(1);
    expect(responses[0]!.authorization).toBe(`Bearer ${chatgptOauth.accessToken}`);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "provider switch reauthenticates current Codex and replaces an unavailable model",
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
    await session.sendLiteralText("/model");
    await session.sendKeys("Tab");
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
    await session.sendText("/model");
    const codexCatalog = await session.waitForPane(
      (pane) =>
        pane.includes("Models") &&
        pane.includes("gpt-5.6-sol") &&
        pane.includes("gpt-5.4-mini") &&
        !pane.includes("openai/gpt-5.6-sol"),
      TIMEOUT,
    );
    expect(codexCatalog).toContain("[All]");
    for (const vendor of ["Anthropic", "OpenAI", "xAI", "Z.AI", "Others"]) {
      expect(codexCatalog).not.toContain(vendor);
    }
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
    await selectEnvKeyCredential(session);
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
    await session.waitForText(`model=${gatewayModelBefore}`, TIMEOUT);
    expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
    chatgptOauth.setModels([
      { slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 },
      { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
    ]);
    await openProviderPicker(session);
    await session.sendKeys("Down");
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
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
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
    const cancelledPane = await session.waitForText(
      "What can fx do differently?",
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    expect(Date.now() - cancelStarted).toBeLessThan(500);
    expect(cancelledPane).toContain("■ Cancelled");
    expect(cancelledPane).not.toContain("System: cancelled");
    expect(cancelledPane).not.toContain("Cancelling");
    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a rejected Codex refresh retires the session without using Gateway credentials",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-chatgpt-rejected-refresh-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    chatgptOauth = startFakeChatGptOAuth({ rejectRefresh: true });
    writeSeededChatGptLogin(home, chatgptOauth.accessToken, Date.now() - 60_000);
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
      { ...chatgptOauth.env, FX_MODEL: undefined },
    );
    await session.waitForComposer(TIMEOUT);
    await session.sendText("retire the rejected Codex login");
    await session.waitForPane(
      (pane) =>
        pane.includes("Codex subscription sign-in expired.") &&
        pane.includes("Press Enter to sign in again."),
      TIMEOUT,
    );

    const refreshRequests = chatgptOauth.requests.filter(
      (request) => request.path === "/chatgpt/token" && request.body?.includes('"grant_type":"refresh_token"'),
    );
    expect(refreshRequests).toHaveLength(1);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a rejected Grok refresh retires the session without using Gateway credentials",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-grok-rejected-refresh-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth({ rejectRefresh: true });
    writeSeededGrokLogin(home, grok.initialAccessToken, "acct_grok_e2e", Date.now() - 60_000);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
      { mode: 0o600 },
    );

    try {
      session = await startFx(
        home,
        stderrPath,
        gateway,
        undefined,
        undefined,
        { ...grok.env, FX_MODEL: undefined },
      );
      await session.waitForComposer(TIMEOUT);
      await session.sendText("retire the rejected Grok login");
      await session.waitForPane(
        (pane) =>
          pane.includes("Grok subscription sign-in expired.") &&
          pane.includes("Press Enter to sign in again."),
        TIMEOUT,
      );

      expect(grok.requests.filter(
        (request) => request.path === "/oauth2/token" && request.body?.includes("grant_type=refresh_token"),
      )).toHaveLength(1);
      expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(false);
      expect(gateway.requests).toHaveLength(0);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      grok.stop();
    }
  },
  60_000,
);

test("Codex refresh save failure retires the consumed session", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-chatgpt-refresh-save-failure-"));
  gateway = startFakeGateway([]);
  const authPath = join(home, ".fx", "chatgpt-auth.json");
  chatgptOauth = startFakeChatGptOAuth({
    beforeRefreshResponse() {
      chmodSync(authPath, 0o400);
    },
  });
  writeSeededChatGptLogin(home, chatgptOauth.accessToken, Date.now() - 60_000);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ provider: "codex", codex_model: "gpt-5.6-sol" }) + "\n",
    { mode: 0o600 },
  );

  const result = await runFx(["ask", "--json", "--no-save", "do not use another credential"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      ...chatgptOauth.env,
    },
    timeoutMs: TIMEOUT,
  });

  expect(
    result.code,
    `signal: ${result.signal}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
  ).toBe(1);
  expect(existsSync(authPath)).toBe(false);
  expect(gateway.requests).toHaveLength(0);
});

test("Grok refresh save failure retires the consumed session", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-refresh-save-failure-"));
  gateway = startFakeGateway([]);
  const authPath = join(home, ".fx", "grok-auth.json");
  const grok = startFakeGrokOAuth({
    beforeRefreshResponse() {
      chmodSync(authPath, 0o400);
    },
  });
  writeSeededGrokLogin(home, grok.initialAccessToken, "acct_grok_e2e", Date.now() - 60_000);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ provider: "grok", grok_model: "grok-4.20" }) + "\n",
    { mode: 0o600 },
  );

  try {
    const result = await runFx(["ask", "--json", "--no-save", "do not use another credential"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        ...grok.env,
      },
      timeoutMs: TIMEOUT,
    });

    expect(
      result.code,
      `signal: ${result.signal}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
    ).toBe(1);
    expect(existsSync(authPath)).toBe(false);
    expect(gateway.requests).toHaveLength(0);
  } finally {
    grok.stop();
  }
});

tmuxTest(
  "provider picker walks every column and Left steps back",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-setup-hub-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, 1, {
      teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
    });
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.resizeWindow(100, 36);
    await session.sendText("/provider");
    const root = await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    expect(root).toContain("vercel · current");
    expect(root).not.toContain("Connections");

    // Right acts as Enter on the highlighted row: into the method column.
    await session.sendKeys("Right");
    const methods = await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    expect(methods).toContain("api-key · current");

    // oauth with a live session opens the team column; the env key is doing
    // inference, so no team is marked current.
    await session.sendKeys("Right");
    const teams = await session.waitForText("vercel-labs", TIMEOUT);
    expect(teams).not.toContain("vercel-labs · current");

    // Left reopens the previous column with the old choice highlighted.
    await session.sendKeys("Left");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );

    await session.sendKeys("Down");
    await session.sendKeys("Right");
    const keySources = await session.waitForPane(
      (pane) => pane.includes("env · AI_GATEWAY_API_KEY · current") && pane.includes("new · paste a key"),
      TIMEOUT,
    );
    expect(keySources).not.toContain("saved · saved by fx");

    await session.sendKeys("Down");
    await session.sendKeys("Right");
    const keyField = await session.waitForText("Paste or type a key", TIMEOUT);
    expect(keyField).toContain("Enter saves");
    await session.sendKeys("Escape");
    await session.waitForComposer(TIMEOUT);

    expect(session.isAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "first-run Vercel team Escape continues into the setup hub",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-onboarding-team-back-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_SKIP_ONBOARDING: "0",
    });
    await session.waitForText("Welcome to fx", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Escape");
    const setup = await session.waitForPane(
      (pane) => pane.includes("Setup") && /Connections\s+connected/.test(pane),
      TIMEOUT,
    );
    expect(setup).toMatch(/^› Vercel team\s+choose a team$/m);
    expect(setup).not.toContain("Welcome to fx");
    expect(setup).not.toContain("sign in to manage");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

for (const [provider, help] of [
  ["gateway", "fx needs access to Vercel AI Gateway."],
  ["codex", "Codex needs a subscription login."],
  ["grok", "Grok needs a subscription login."],
] as const) {
  tmuxTest(`/status keeps ${provider} authentication requirements without credentials`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-status-provider-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    mkdirSync(join(home, ".fx"));
    const settingsPath = join(home, ".fx", "settings.json");
    const settings = JSON.stringify({ provider, models: { [provider]: "test-model" } });
    writeFileSync(settingsPath, settings);
    gateway = startFakeGateway([]);
    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_MODEL: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth_help=", TIMEOUT);
    const scrollback = await session.captureFullScrollback();
    expect(scrollback).toContain(`auth_help=${help}`);
    if (provider !== "gateway") {
      expect(scrollback).toContain(`model_source=${provider === "codex" ? "Codex" : "Grok"} subscription`);
      expect(scrollback).not.toContain("auth_help=fx needs access to Vercel AI Gateway");
    }
    expect(scrollback).toContain("auth=missing");
    expect(scrollback).toContain("auth_refreshable=false");
    expect(await session.captureFullScrollbackEscapes()).toContain(help);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(settingsPath, "utf8")).toBe(settings);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);
}

for (const [source, help] of [
  ["vercel_oidc_token", "VERCEL_OIDC_TOKEN is selected but unavailable."],
  ["stored_key", "A stored API key is selected but unavailable."],
] as const) {
  tmuxTest(`/status retains ${source} until another credential is selected`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-status-explicit-key-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    mkdirSync(join(home, ".fx"));
    const settingsPath = join(home, ".fx", "settings.json");
    const settings = JSON.stringify({ provider: "gateway", credential_source: source });
    writeFileSync(settingsPath, settings);
    gateway = startFakeGateway([fakeGatewayFinalText("EXPLICIT_KEY_RECOVERED")]);
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth_help=", TIMEOUT);
    const missing = await session.captureFullScrollback();
    expect(missing).toContain(`auth_help=${help}`);
    expect(missing).not.toContain("set AI_GATEWAY_API_KEY");
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(settingsPath, "utf8")).toBe(settings);

    await selectEnvKeyCredential(session);
    await session.sendText("Verify the account with a greeting.");
    await session.waitForText("EXPLICIT_KEY_RECOVERED", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    const scrollback = await session.captureFullScrollback();
    expect(scrollback.slice(scrollback.lastIndexOf("● Status:"))).not.toContain("auth_help=");
    expect(JSON.parse(readFileSync(settingsPath, "utf8")).credential_source).toBe("ai_gateway_api_key");
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);
}

tmuxTest("/status preserves a missing selected login through explicit key recovery", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-status-selected-login-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  mkdirSync(join(home, ".fx"));
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = JSON.stringify({
    provider: "gateway",
    models: { gateway: FAKE_GATEWAY_MODEL },
    credential_source: "fx_login",
  });
  writeFileSync(settingsPath, settings);
  gateway = startFakeGateway([fakeGatewayFinalText("SELECTED_KEY_RECOVERED")]);
  session = await startFx(home, stderrPath, gateway);
  await session.waitForComposer(TIMEOUT);
  await session.sendText("/status");
  await session.waitForText("auth_help=", TIMEOUT);
  const missing = await session.captureFullScrollback();
  expect(missing).toContain("auth_help=fx login is selected but unavailable.");
  expect(missing).toContain("Run /login to reconnect");
  expect(missing).not.toContain("or set AI_GATEWAY_API_KEY");
  expect(await session.captureFullScrollbackEscapes()).toContain("fx login is selected but unavailable.");
  expect(gateway.requests).toHaveLength(0);
  expect(readFileSync(settingsPath, "utf8")).toBe(settings);

  writeFileSync(settingsPath, "{broken");
  await session.sendText("/status");
  await session.waitForText("Failed to load settings:", TIMEOUT);
  expect(gateway.requests).toHaveLength(0);
  writeFileSync(settingsPath, settings);

  await selectEnvKeyCredential(session);
  await session.sendText("Verify the selected account with a greeting.");
  await session.waitForText("SELECTED_KEY_RECOVERED", TIMEOUT);
  expect(JSON.parse(readFileSync(settingsPath, "utf8")).credential_source).toBe("ai_gateway_api_key");
  writeFileSync(settingsPath, "{broken");
  await session.sendText("/status");
  await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
  const scrollback = await session.captureFullScrollback();
  const recovered = scrollback.slice(scrollback.lastIndexOf("● Status:"));
  expect(recovered).not.toContain("auth_help=");
  expect(readFileSync(settingsPath, "utf8")).toBe("{broken");
  expect(gateway.requests).toHaveLength(1);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);

for (const provider of ["codex", "grok"] as const) {
  tmuxTest(`/status retains ${provider} storage failure after unrelated logout`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-status-logout-storage-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    if (provider === "codex") writeSeededChatGptLogin(home);
    else writeSeededGrokLogin(home, "unreadable-grok-token");
    const credentialPath = join(home, ".fx", provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json");
    linkSync(credentialPath, join(home, "credential.alias"));
    const settingsPath = join(home, ".fx", "settings.json");
    const settings = JSON.stringify({ provider, models: { [provider]: "test-model" } });
    writeFileSync(settingsPath, settings);
    gateway = startFakeGateway([]);
    session = await startFx(home, stderrPath, gateway, undefined, undefined, {
      AI_GATEWAY_API_KEY: undefined,
      FX_MODEL: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout vercel");
    await session.waitForText("No fx login session found.", TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth_help=", TIMEOUT);
    expect(await session.captureFullScrollback()).toContain("auth_help=Saved credential storage is unavailable");
    expect(existsSync(credentialPath)).toBe(true);
    expect(readFileSync(settingsPath, "utf8")).toBe(settings);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT);
}

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

async function waitForOAuthRequestCount(
  fakeOAuth: ReturnType<typeof startFakeOAuth>,
  count: number,
): Promise<void> {
  const started = Date.now();
  while (fakeOAuth.requests.length < count) {
    if (Date.now() - started >= TIMEOUT) {
      throw new Error(
        `Timed out waiting for ${count} OAuth requests; saw ${fakeOAuth.requests.length}`,
      );
    }
    await Bun.sleep(25);
  }
}

async function waitForTrace(
  tracePath: string,
  needle: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(tracePath) && readFileSync(tracePath, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for trace: ${needle}`);
}

async function enterSwitchCredential(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendKeys("Up");
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("Credential source") && pane.includes("Automatic"),
    TIMEOUT,
  );
}

async function openProviderPicker(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/provider");
  await pickerSession.waitForPane(
    (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
    TIMEOUT,
  );
}

// The inline picker replaced the hub's Credential source screen. Selecting the
// fx login now goes through the oauth method; with no teams to refine it, the
// choice commits the credential directly.
async function selectFxLoginCredential(pickerSession: TmuxSession): Promise<void> {
  await openProviderPicker(pickerSession);
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("oauth") && pane.includes("api-key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Enter");
  const outcome = await pickerSession.waitForPane(
    (pane) => pane.includes("Switched credential to fx login") || pane.includes("vercel-labs"),
    TIMEOUT,
  );
  if (!outcome.includes("Switched credential to fx login")) {
    await pickerSession.sendKeys("Enter");
    await pickerSession.waitForText("Changed Vercel team", TIMEOUT);
  }
}

// Selecting the environment key goes through the api-key method's which-key
// column, which lists it as `env`.
async function selectEnvKeyCredential(pickerSession: TmuxSession): Promise<void> {
  await openProviderPicker(pickerSession);
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("oauth") && pane.includes("api-key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Down");
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForPane(
    (pane) => pane.includes("env · AI_GATEWAY_API_KEY") && pane.includes("new · paste a key"),
    TIMEOUT,
  );
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForText("Switched credential to AI_GATEWAY_API_KEY", TIMEOUT);
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

    // Typing the full path exercises both space-advance columns: the space
    // after "vercel" opens the methods, the space after "api-key" opens the
    // which-key column, and Enter on "new" opens the masked field.
    await session.sendText("/provider vercel api-key new");
    await session.waitForText("Paste or type a key", TIMEOUT);
    await session.sendLiteralText(STORED_TOKEN);
    await session.sendKeys("Enter");
    await session.waitForText("Saved the API key to profile file and made it active", TIMEOUT);
    await session.sendText("/provider vercel api-key");
    const keyColumn = await session.waitForPane(
      (pane) => pane.includes("saved · saved by fx · current"),
      TIMEOUT,
    );
    expect(keyColumn).toContain("env · AI_GATEWAY_API_KEY");
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
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
  "direct login persists ahead of the environment until the env key is selected",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-direct-login-preference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(ENV_RESPONSE),
    ]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);

    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Signed in to Vercel", TIMEOUT);
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
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

    await selectEnvKeyCredential(session);
    expect(savedCredentialSource(home)).toBe("ai_gateway_api_key");
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

    await openProviderPicker(session);
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("vercel-labs", TIMEOUT);
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
    const authPath = join(home, ".fx", "auth.json");
    gateway = startFakeGateway([
      fakeGatewayFinalText(ENV_RESPONSE),
      fakeGatewayFinalText(LOGIN_RESPONSE),
      fakeGatewayFinalText(RESTART_RESPONSE),
      fakeGatewayFinalText(DIRECT_LOGIN_RESPONSE),
      fakeGatewayFinalText(LOGOUT_FALLBACK_RESPONSE),
    ]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
    const seededAuthFile = readFileSync(authPath, "utf8");

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

    await selectFxLoginCredential(session);
    await session.sendText("/status");
    await session.waitForText("auth=fx login", TIMEOUT);
    const selectedAuth = JSON.parse(readFileSync(authPath, "utf8")) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(selectedAuth.team_id).toBe("team_123");
    expect(selectedAuth.team_slug).toBe("vercel-labs");
    await session.sendText("use the selected login credential");
    await session.waitForText(LOGIN_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(JSON.parse(readFileSync(authPath, "utf8")).team_slug).toBe("vercel-labs");

    const firstRunOutput = await session.captureFullScrollback();
    const firstRunStderr = readFileSync(stderrPath, "utf8");
    await session.kill();
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    // The switch above is remembered, so the restart keeps fx login rather than
    // letting AI_GATEWAY_API_KEY reclaim it through precedence.
    await session.waitForText("auth=fx login", TIMEOUT);
    expect(JSON.parse(readFileSync(authPath, "utf8")).team_slug).toBe("vercel-labs");
    await session.sendText("use the remembered credential after restart");
    await session.waitForText(RESTART_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);

    // Acquiring a fresh login needs a signed-out state first; the remembered
    // seeded login would otherwise resolve straight into the team column.
    await session.sendText("/logout");
    await session.waitForText("Signed out of fx.", TIMEOUT);
    const oauthBase = oauth.requests.length;
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    const loginCompleted = await session.waitForText("Signed in to Vercel", TIMEOUT);
    expect(loginCompleted).not.toContain("Connections");
    expect(loginCompleted).toContain("Vercel team · Search:");
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Vercel Labs", TIMEOUT);
    const acquisition = oauth.requests
      .slice(oauthBase)
      .map((request) => `${request.method} ${request.path}`);
    expect(acquisition).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/device",
      "POST /oauth/token",
      "GET /v2/teams",
    ]);
    expect(oauth.requests[oauthBase + 3].authorization).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(oauth.requests[oauthBase + 1].clientId).toBe("test-client");
    expect(oauth.requests[oauthBase + 2].clientId).toBe("test-client");
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
        .map((request) => request.revocation)
        .slice(-2),
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
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
    await session.sendKeys("Escape");
    const setupAfterSignIn = await session.waitForPane(
      (pane) => pane.includes("Setup") && /Connections\s+connected/.test(pane),
      TIMEOUT,
    );
    expect(setupAfterSignIn).toMatch(/^› Vercel team\s+choose a team$/m);
    expect(setupAfterSignIn).not.toContain("sign in to manage");
    await session.sendKeys("Enter");
    await session.waitForText("Vercel team · Search:", TIMEOUT);
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
        pane.includes("Vercel team · Search:") &&
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
    await session.waitForText("Changed Vercel team to Example Internal Team", TIMEOUT);
    await waitForModelRequestCount(gateway, 3);

    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes("private/blue-hornbill") &&
        !pane.includes("Authenticated model catalog loaded."),
      TIMEOUT,
    );

    for (const authenticatedRequest of gateway.modelRequests.slice(1)) {
      expect(authenticatedRequest.headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
      expect(authenticatedRequest.headers.get("x-vercel-ai-gateway-team")).toBeNull();
      expect(new URL(authenticatedRequest.url).searchParams.get("teamId")).toBe("team_123");
    }
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

    await selectFxLoginCredential(session);
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
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      {
        deviceError: "invalid_client",
        teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }],
      },
    );

    const result = await runFx(["login"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_NO_OPEN_BROWSER: "1",
        FX_OAUTH_CLIENT_ID: "test-client",
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
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
      team_id?: string;
      team_slug?: string;
    };
    expect(persisted.client_id).toBe(fallbackClientId);
    expect(persisted.access_token).toBe(ACQUIRED_LOGIN_TOKEN);
    expect(persisted.team_id).toBe("team_123");
    expect(persisted.team_slug).toBe("vercel-labs");
    expect(statSync(authPath).mode & 0o777).toBe(0o600);
    expect(savedCredentialSource(home)).toBe("fx_login");
    expect(gateway.modelRequests).toHaveLength(1);
    expect(gateway.modelRequests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.modelRequests[0]!.headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(new URL(gateway.modelRequests[0]!.url).searchParams.get("teamId")).toBe("team_123");
    expect(result.stdout.match(/Code: TEST-CODE/g) ?? []).toHaveLength(1);
    expect(result.stdout).not.toContain(oauth.providerDetail);
    expect(result.stderr).toBe("");
  },
  60_000,
);

test(
  "fx teams validates Gateway before committing and persists fx login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-cli-teams-validation-"));
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_old");

    const result = await runFx(["teams"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
    expect(result.stdout).toContain("Selected Vercel team: Vercel Labs (vercel-labs).");
    expect(savedCredentialSource(home)).toBe("fx_login");
    const persisted = JSON.parse(
      readFileSync(join(home, ".fx", "auth.json"), "utf8"),
    ) as {
      team_id?: string;
      team_slug?: string;
    };
    expect(persisted.team_id).toBe("team_123");
    expect(persisted.team_slug).toBe("vercel-labs");
    expect(gateway.modelRequests).toHaveLength(2);
    for (const request of gateway.modelRequests) {
      expect(request.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
      expect(new URL(request.url).searchParams.get("teamId")).toBe("team_123");
    }
  },
  60_000,
);

test(
  "fx teams preserves the previous team when Gateway rejects the candidate",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-cli-teams-rejected-"));
    gateway = startFakeGateway([], {
      models: () => new Response("rejected", { status: 401 }),
    });
    oauth = startFakeOAuth(
      ACQUIRED_LOGIN_TOKEN,
      undefined,
      3600,
      Number.POSITIVE_INFINITY,
      { teams: [{ id: "team_123", slug: "vercel-labs", name: "Vercel Labs" }] },
    );
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_old");

    const result = await runFx(["teams"], {
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: ENV_TOKEN,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
      timeoutMs: TIMEOUT,
    });

    expect(result.code).toBe(1);
    expect(result.stdout).not.toContain("Selected Vercel team");
    expect(result.stderr).toContain("selected team could not access AI Gateway");
    expect(savedCredentialSource(home)).toBeUndefined();
    const persisted = JSON.parse(
      readFileSync(join(home, ".fx", "auth.json"), "utf8"),
    ) as {
      team_id?: string;
    };
    expect(persisted.team_id).toBe("team_old");
  },
  60_000,
);

test("fx logout clears a remembered fx login source", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-logout-preference-"));
  oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );

  const result = await runFx(["logout"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
  expect(result.stdout).toContain("Signed out of fx.");
  expect(savedCredentialSource(home)).toBeUndefined();
  expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
});

test("fx models does not retry anonymously for an explicit credential", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-models-explicit-auth-"));
  writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, "https://vercel.com", "team_123");
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );
  let calls = 0;
  gateway = startFakeGateway([], {
    models: () => {
      calls += 1;
      if (calls === 1) return new Response("rejected", { status: 401 });
      return [{ id: "public/fallback", type: "language", tags: ["tool-use"] }];
    },
  });

  const result = await runFx(["models", "--json"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code).toBe(1);
  expect(calls).toBe(1);
  expect(result.stdout).not.toContain("public/fallback");
  expect(result.stdout).toContain("AuthenticationRejected");
});

test("status never substitutes an environment key for a missing explicit login", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-cli-status-strict-source-"));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ credential_source: "fx_login" }) + "\n",
    { mode: 0o600 },
  );

  const result = await runFx(["status", "--json"], {
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
    },
    timeoutMs: TIMEOUT,
  });

  expect(result.code).toBe(0);
  const status = JSON.parse(result.stdout) as { auth: string };
  expect(status.auth).toBe("missing");
  expect(result.stdout).not.toContain("AI_GATEWAY_API_KEY");
});

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
    expect(modelIds).toContain("gpt-5.6-luna");
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

test(
  "Grok CLI accepts an authorization code copied from the browser",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-cli-code-"));
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    try {
      const result = await runGrokLoginWithBrowser({
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
      }, "grok-code");

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("Signed in with Grok.");
      expect(result.stdout).not.toContain("grok-code");
      expect(result.stderr).toBe("");
      expect(grok.tokenCalls()).toBe(1);
      expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
    } finally {
      grok.stop();
    }
  },
  15_000,
);

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

test("Grok logout removes malformed and unsafe local credentials", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-logout-unreadable-"));
  const grok = startFakeGrokOAuth();
  try {
    const authPath = join(home, ".fx", "grok-auth.json");
    for (const failure of ["malformed", "unsafe"]) {
      writeSeededGrokLogin(home, grok.initialAccessToken);
      if (failure === "malformed") writeFileSync(authPath, "{invalid-json");
      else chmodSync(authPath, 0o644);

      const result = await runFx(["logout", "grok"], {
        env: {
          HOME: home,
          FX_DISABLE_KEYCHAIN: "1",
          FX_AUTO_UPGRADE: "0",
          FX_E2E_GROK_REVOKE_URL: grok.env.FX_E2E_GROK_REVOKE_URL,
        },
        timeoutMs: TIMEOUT,
      });
      expect(result.code, result.stderr).toBe(0);
      expect(result.stdout).toContain("Signed out of Grok.");
      expect(result.stderr).toContain("remote revocation could not be confirmed");
      expect(existsSync(authPath)).toBe(false);
      expect(grok.requests).toHaveLength(0);
      expect(result.stderr).not.toContain(grok.initialAccessToken);
    }
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
    expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(false);
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
      await session.waitForPane(
        (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
        TIMEOUT,
      );
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      const collapsed = await session.waitForPane(
        (pane) =>
          pane.includes("Authorize with Grok") &&
          pane.includes("Browser didn't return? Press Tab to enter a code") &&
          pane.includes("Enter reopens browser · Tab enters code · Esc cancels"),
        TIMEOUT,
      );
      expect(collapsed).toMatch(/^Sign in with Grok\s+Waiting for authorization…$/m);
      expect(collapsed).toMatch(/^  Open\s+Authorize with Grok$/m);
      expect(collapsed).not.toContain("Paste or type the code");
      expect(collapsed).not.toContain(`${grok.baseUrl}/oauth2/authorize?`);
      await completeDisplayedGrokLogin(session, grok);
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      await session.sendText("Answer from Grok.");
      await session.waitForText("GROK_DIRECT_RESPONSE", TIMEOUT);

      const tokenCallsAfterLogin = grok.tokenCalls();
      await selectEnvKeyCredential(session);
      await session.waitForText("Switched to Vercel AI Gateway", TIMEOUT);
      await openProviderPicker(session);
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);
      await session.sendText("/model");
      const grokCatalog = await session.waitForPane(
        (pane) => pane.includes("Models") && pane.includes("grok-4.20"),
        TIMEOUT,
      );
      expect(grokCatalog).toContain("[All]");
      for (const vendor of ["Anthropic", "OpenAI", "xAI", "Z.AI", "Others"]) {
        expect(grokCatalog).not.toContain(vendor);
      }
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
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
  "interactive Grok login auto-expands for a bracketed-paste authorization code",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-tui-code-"));
    stderrPath = join(home, "stderr.log");
    gateway = startFakeGateway([]);
    const grok = startFakeGrokOAuth();
    try {
      session = await startFx(home, stderrPath, gateway, undefined, undefined, {
        FX_MODEL: undefined,
        ...grok.env,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/login");
      await session.waitForPane(
        (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
        TIMEOUT,
      );
      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Browser didn't return? Press Tab to enter a code", TIMEOUT);
      await session.pasteText("grok-code");
      await session.waitForPane(
        (pane) => pane.includes("•••••••••") && pane.includes("Enter submits"),
        TIMEOUT,
      );
      const expanded = await session.capturePane();
      expect(expanded).toMatch(/^  Open\s+Authorize with Grok\n\s*\n  Paste the code shown by xAI$/m);
      await session.resizeWindow(80, 5);
      const compactEntry = await session.waitForPane(
        (pane) =>
          pane.includes("•••••••••") &&
          pane.includes("Enter submits") &&
          pane.includes("Esc cancels"),
        TIMEOUT,
      );
      expect(compactEntry).not.toContain("Paste the code shown by xAI");
      await session.sendKeys("Tab");
      const collapsedWithDraft = await session.waitForText("Tab enters code", TIMEOUT);
      expect(collapsedWithDraft).not.toContain("•••••••••");
      await session.sendKeys("Tab");
      await session.waitForPane(
        (pane) => pane.includes("•••••••••") && pane.includes("Enter submits"),
        TIMEOUT,
      );
      await session.sendKeys("Enter");
      await session.waitForText("Switched to Grok subscription with grok-4.20.", TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).not.toContain("grok-code");
      expect(grok.tokenCalls()).toBe(1);
      expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
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

for (const scenario of ["replace", "conflict", "invalid-index"] as const) {
  test("direct Responses final records " + scenario, async () => {
    const conflict = scenario !== "replace";
    for (const provider of ["codex", "grok"] as const) {
      const profile = mkdtempSync(join(tmpdir(), "fx-" + provider + "-final-record-"));
      const testGateway = startFakeGateway([]);
      const completed = { type: "response.completed", response: { status: "completed" } };
      const item = (id: string, path: string) => ({
        type: "function_call", id: "fc_" + id, call_id: id, name: "write_file",
        arguments: JSON.stringify({ path, content: "saved" }),
      });
      const prior = item("prior", "prior.txt");
      const pending = item("pending", "preview.txt");
      const sibling = item("sibling", "sibling.txt");
      const final = item("pending", "final.txt");
      const responses: Response[] = [];
      if (conflict) responses.push(fakeGatewaySse([
        { type: "response.output_item.added", output_index: 0, item: { ...prior, arguments: "" } },
        { type: "response.function_call_arguments.done", output_index: 0, arguments: prior.arguments },
        { type: "response.output_item.done", output_index: 0, item: prior },
        completed,
      ]));
      const events: object[] = [
        { type: "response.output_item.added", output_index: 0, item: { ...pending, arguments: "" } },
        { type: "response.function_call_arguments.delta", output_index: 0, item_id: pending.id, delta: pending.arguments },
      ];
      if (conflict) events.push(
        { type: "response.function_call_arguments.done", output_index: 0, arguments: pending.arguments },
        { type: "response.output_item.added", output_index: 1, item: { ...sibling, arguments: "" } },
        { type: "response.function_call_arguments.done", output_index: 1, arguments: sibling.arguments },
      );
      events.push(
        { type: "response.output_item.done", output_index: scenario === "invalid-index" ? "0" : 0, item: final },
        scenario === "invalid-index" ? completed : { type: "response.completed", response: { status: "completed", output: conflict ? [final, sibling] : [final] } },
      );
      responses.push(fakeGatewaySse(events), fakeGatewaySse([
        { type: "response.output_text.delta", delta: "FINAL_RECORD_OK" }, completed,
      ]));
      const model = "fixture-model";
      const direct = provider === "codex" ? startFakeCodexToolLoop({ responses, model }) : startFakeGrokToolLoop({ responses, model });
      try {
        if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
        else writeSeededGrokLogin(profile, direct.accessToken);
        writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
        const env = {
          HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
          FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
          FX_GATEWAY_BASE_URL: testGateway.baseUrl,
          FX_E2E_GATEWAY_MODELS_URL: testGateway.baseUrl + "/coding-agent/v1/models",
          FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl,
          FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
          FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl,
          FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
          FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
        };
        const result = await runFx(["ask", "--json", "--auto", "Create the requested files containing saved."], { cwd: profile, env, timeoutMs: TIMEOUT });
        expect(result.code, provider + ": " + result.stdout + "\n" + result.stderr).toBe(conflict ? 1 : 0);
        expect(result.signal).toBeNull();
        expect(direct.bodies).toHaveLength(2);
        expect(existsSync(join(profile, "preview.txt"))).toBe(false);
        expect(existsSync(join(profile, "sibling.txt"))).toBe(false);
        expect(existsSync(join(profile, "prior.txt"))).toBe(conflict);
        expect(existsSync(join(profile, "final.txt"))).toBe(!conflict);
        expect(readFileSync(join(profile, conflict ? "prior.txt" : "final.txt"), "utf8")).toBe("saved");
        const resultJson = JSON.parse(result.stdout);
        if (conflict) expect(resultJson.error).toBe(scenario === "invalid-index" ? (provider === "codex" ? "InvalidOpenAICodexSseEvent" : "InvalidXaiGrokSseEvent") : "ResponsesToolCallConflict");
        else {
          expect(resultJson.output).toBe("FINAL_RECORD_OK");
          expect(result.stderr).toBe("Writing final.txt\n");
        }
        const detail = await runFx(["session", "--json", "--id", resultJson.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        const history = JSON.parse(detail.stdout).history;
        expect(history).toHaveLength(1);
        const steps = history[0].execution.tool_steps;
        expect(steps).toHaveLength(1);
        expect(steps[0].tool_calls).toHaveLength(1);
        expect(steps[0].tool_calls[0].id).toBe(conflict ? "prior" : "pending");
        expect(steps[0].tool_calls[0].arguments_json).toBe(conflict ? prior.arguments : final.arguments);
        if (conflict) {
          const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", resultJson.session_id, "Report the completed work without writing more files."], { cwd: profile, env, timeoutMs: TIMEOUT });
          expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
          expect(resumed.stderr).toBe("");
          expect(JSON.parse(resumed.stdout).output).toBe("FINAL_RECORD_OK");
          expect(direct.bodies).toHaveLength(3);
          const input = JSON.parse(direct.bodies[2]).input;
          expect(input.filter((entry: { type?: string }) => entry.type === "function_call").map((entry: { call_id: string }) => entry.call_id)).toEqual(["prior"]);
          expect(input.filter((entry: { type?: string }) => entry.type === "function_call_output").map((entry: { call_id: string }) => entry.call_id)).toEqual(["prior"]);
        }
        expect(testGateway.requests).toHaveLength(0);
      } finally {
        direct.stop(); testGateway.stop();
        rmSync(profile, { recursive: true, force: true });
      }
    }
  }, 60_000);
}

test("native assistant messages keep their boundaries and phases through tools and resume", async () => {
  for (const provider of ["codex", "grok"] as const) {
    const profile = mkdtempSync(join(tmpdir(), "fx-message-replay-"));
    const testGateway = startFakeGateway([]);
    const model = "fixture-model";
    const message = (id: string, phase: string, text: string) => ({ type: "message", id, role: "assistant", status: "completed", phase, content: [{ type: "output_text", text, annotations: [] }] });
    const progress = message("msg_progress", "commentary", "Checking the file.");
    const progressTwo = message("msg_progress_two", "commentary", "Reading its contents.");
    const answer = message("msg_answer", "final_answer", "The value is 42.");
    const reasoning = { type: "reasoning", id: "rs_messages", summary: [], encrypted_content: "MESSAGE_REPLAY_CONTEXT" };
    const call = { type: "function_call", id: "fc_messages", call_id: "call_messages", name: "read_file", arguments: JSON.stringify({ path: "notes.txt" }) };
    const responses = [fakeGatewaySse([
      { type: "response.output_item.added", output_index: 0, item: { ...progress, content: [] } },
      { type: "response.output_text.delta", output_index: 0, content_index: 0, item_id: progress.id, delta: "Checking " },
      { type: "response.output_text.delta", output_index: 0, content_index: 0, item_id: progress.id, delta: "the file." },
      { type: "response.output_item.done", output_index: 0, item: progress },
      { type: "response.output_item.added", output_index: 3, item: { ...call, arguments: "" } },
      { type: "response.completed", response: { status: "completed", output: [progress, reasoning, progressTwo, call] } },
    ]), fakeGatewaySse([
      { type: "response.completed", response: { status: "completed", output: [message("msg_result", "commentary", "Read complete."), answer] } },
    ]), fakeGatewaySse([
      { type: "response.completed", response: { status: "completed", output: [message("msg_resume", "final_answer", "Still 42.")] } },
    ])];
    const direct = provider === "codex" ? startFakeCodexToolLoop({ responses, model }) : startFakeGrokToolLoop({ responses, model });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      writeFileSync(join(profile, "notes.txt"), "42\n");
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: testGateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: testGateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Read notes.txt and report the value."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(first.code, first.stdout + first.stderr).toBe(0);
      const result = JSON.parse(first.stdout);
      expect(result.output).toBe("Checking the file.\n\nReading its contents.\n\nRead complete.\n\nThe value is 42.");
      expect(direct.bodies).toHaveLength(2);
      const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", result.session_id, "What was the value?"], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(JSON.parse(resumed.stdout).output).toBe("Still 42.");
      expect(direct.bodies).toHaveLength(3);
      for (const [index, body] of direct.bodies.slice(1).entries()) {
        const input = JSON.parse(body).input;
        const messages = input.filter((item: { role?: string }) => item.role === "assistant");
        expect(messages.map((item: { phase?: string; content: Array<{ text: string }> }) => ({ phase: item.phase, text: item.content.map((part) => part.text).join("") }))).toEqual([
          { phase: "commentary", text: "Checking the file." },
          { phase: "commentary", text: "Reading its contents." },
          ...(index === 1 ? [{ phase: "commentary", text: "Read complete." }, { phase: "final_answer", text: "The value is 42." }] : []),
        ]);
        expect(input.filter((item: { type?: string }) => item.type === "reasoning")).toEqual([reasoning]);
        const calls = input.filter((item: { type?: string }) => item.type === "function_call");
        const outputs = input.filter((item: { type?: string }) => item.type === "function_call_output");
        expect(calls.map((item: { call_id: string }) => item.call_id)).toEqual(["call_messages"]);
        expect(outputs.map((item: { call_id: string }) => item.call_id)).toEqual(["call_messages"]);
        expect(outputs[0].output).toContain("42");
      }
      expect(testGateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); testGateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("native reasoning snapshots survive tools and saved resume exactly once", async () => {
  for (const provider of ["codex", "grok"] as const) for (const shape of ["both", "terminal-only", "enriched", "conflict", "identity-conflict"] as const) {
    const conflict = shape === "conflict" || shape === "identity-conflict";
    const profile = mkdtempSync(join(tmpdir(), "fx-reasoning-snapshot-"));
    const testGateway = startFakeGateway([]);
    const model = "fixture-model";
    const signature = "REASONING_SNAPSHOT_CONTEXT";
    const reasoning = { id: "rs_snapshot", type: "reasoning", summary: [], encrypted_content: signature };
    const call = { id: "fc_snapshot", type: "function_call", call_id: "call_snapshot", name: "read_file", arguments: JSON.stringify({ path: "notes.txt" }) };
    const events: object[] = [{ type: "response.output_item.added", output_index: 0, item: { id: reasoning.id, type: reasoning.type, summary: [] } }];
    if (shape !== "terminal-only") events.push({ type: "response.output_item.done", output_index: 0, item: shape === "enriched" || shape === "identity-conflict" ? { id: reasoning.id, type: reasoning.type, summary: [] } : reasoning });
    events.push(
      { type: "response.output_item.added", output_index: 1, item: { ...call, arguments: "" } },
      { type: "response.function_call_arguments.done", output_index: 1, item_id: call.id, arguments: call.arguments },
      { type: "response.completed", response: { status: "completed", output: [{ ...reasoning, id: shape === "identity-conflict" ? "rs_replacement" : reasoning.id, encrypted_content: shape === "conflict" ? "CONFLICTING_CONTEXT" : signature }, call] } },
    );
    const answer = () => fakeGatewaySse([
      { type: "response.output_text.delta", delta: "REASONING_SNAPSHOT_OK" },
      { type: "response.completed", response: { status: "completed" } },
    ]);
    const responses = [fakeGatewaySse(events), answer(), answer()];
    const direct = provider === "codex" ? startFakeCodexToolLoop({ responses, model }) : startFakeGrokToolLoop({ responses, model });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      writeFileSync(join(profile, "notes.txt"), "SETTLED_READ_RESULT\n");
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: testGateway.baseUrl,
        FX_E2E_GATEWAY_MODELS_URL: testGateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Read notes.txt and summarize it."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(first.code, provider + "/" + shape + ": " + first.stdout + first.stderr).toBe(conflict ? 1 : 0);
      expect(first.signal).toBeNull();
      const result = JSON.parse(first.stdout);
      if (conflict) {
        expect(result.error).toBe("ResponsesReasoningConflict");
        expect(result.tool_calls).toEqual([]);
        expect(direct.bodies).toHaveLength(1);
        continue;
      }
      expect(result.output).toBe("REASONING_SNAPSHOT_OK");
      expect(first.stderr).toMatch(/^(?:● Reading\x1b\[0m\n)?Reading notes\.txt\n$/);
      expect(direct.bodies).toHaveLength(2);
      const saved = readFileSync(join(profile, ".fx", "sessions", result.session_id, "events.jsonl"), "utf8");
      expect(saved).toContain(signature);
      const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", result.session_id, "Continue without tools."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(direct.bodies).toHaveLength(3);
      for (const body of direct.bodies.slice(1)) {
        const input = JSON.parse(body).input as Array<{ type: string; encrypted_content?: string; call_id?: string; output?: string }>;
        expect(input.filter((item) => item.type === "reasoning").map((item) => item.encrypted_content)).toEqual([signature]);
        const results = input.filter((item) => item.type === "function_call_output");
        expect(results).toHaveLength(1);
        expect(results[0].call_id).toBe(call.call_id);
        expect(results[0].output).toContain("SETTLED_READ_RESULT");
      }
      expect(testGateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); testGateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("native final snapshots preserve completed items and reject conflicting kinds", async () => {
  for (const provider of ["codex", "grok"] as const) for (const shape of ["null", "empty", "kind-at-item", "kind-at-terminal"] as const) {
    const conflict = shape.startsWith("kind-");
    const profile = mkdtempSync(join(tmpdir(), "fx-output-consistency-"));
    const gateway = startFakeGateway([]);
    const model = "fixture-model";
    const reasoning = { type: "reasoning", id: "rs_snapshot", summary: [], encrypted_content: "SNAPSHOT_REASONING" };
    const message = (id: string, text: string, phase: string) => ({ type: "message", id, role: "assistant", status: "completed", phase, content: [{ type: "output_text", text, annotations: [] }] });
    const progress = message("msg_progress", "Inspecting.", "commentary");
    const call = { type: "function_call", id: "fc_snapshot", call_id: "call_snapshot", name: "read_file", arguments: JSON.stringify({ path: "notes.txt" }) };
    const replacement = message("msg_replacement", "CONFLICTING_TEXT", "final_answer");
    const events: object[] = [
      { type: "response.output_item.done", output_index: 0, item: reasoning },
      { type: "response.output_item.done", output_index: 1, item: progress },
      { type: "response.output_item.added", output_index: 2, item: { ...call, arguments: "" } },
      { type: "response.function_call_arguments.done", output_index: 2, item_id: call.id, arguments: call.arguments },
      { type: "response.output_item.done", output_index: 2, item: shape === "kind-at-item" ? replacement : call },
      { type: "response.completed", response: { status: "completed", output: shape === "kind-at-terminal" ? [reasoning, progress, replacement] : shape === "empty" ? [] : null } },
    ];
    const answer = (text: string) => fakeGatewaySse([
      { type: "response.output_item.done", output_index: 0, item: message("msg_answer", text, "final_answer") },
      { type: "response.completed", response: { status: "completed", output: null } },
    ]);
    const responses = [fakeGatewaySse(events), answer("SNAPSHOT_OK"), answer("RESUMED_OK")];
    const direct = provider === "codex" ? startFakeCodexToolLoop({ model, responses }) : startFakeGrokToolLoop({ model, responses });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      writeFileSync(join(profile, "notes.txt"), "SNAPSHOT_READ_RESULT\n");
      const tracePath = join(profile, "trace.log");
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "agent,gateway,tool",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Read notes.txt and report the result."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(first.code, provider + "/" + shape + ": " + first.stdout + first.stderr).toBe(conflict ? 1 : 0);
      expect(first.signal).toBeNull();
      const result = JSON.parse(first.stdout);
      expect(direct.bodies).toHaveLength(conflict ? 1 : 2);
      const trace = readFileSync(tracePath, "utf8");
      if (conflict) {
        expect(result.error).toBe("ResponsesOutputItemConflict");
        expect(result.tool_calls).toEqual([]);
        expect(trace).not.toContain("after_tool_execution");
        expect(result.output).not.toContain("CONFLICTING_TEXT");
      } else {
        expect(result.output).toBe("Inspecting.\n\nSNAPSHOT_OK");
        expect(result.tool_calls).toEqual([{ name: "read_file", status: "success" }]);
        expect(trace).toContain("after_tool_execution");
      }
      const detail = await runFx(["session", "--json", "--id", result.session_id], { cwd: profile, env });
      expect(detail.code).toBe(0);
      const history = JSON.parse(detail.stdout).history;
      expect(history).toHaveLength(1);
      expect(history[0].kind).toBe(conflict ? "interrupted" : "assistant");
      expect(history[0].execution?.tool_steps ?? []).toHaveLength(conflict ? 0 : 1);
      const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", result.session_id, "Continue without tools."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).output).toBe(conflict ? "SNAPSHOT_OK" : "RESUMED_OK");
      expect(direct.bodies).toHaveLength(conflict ? 2 : 3);
      for (const body of direct.bodies.slice(1)) {
        const input = JSON.parse(body).input;
        const calls = input.filter((item: { type?: string }) => item.type === "function_call");
        const outputs = input.filter((item: { type?: string }) => item.type === "function_call_output");
        expect(calls.map((item: { call_id: string }) => item.call_id)).toEqual(conflict ? [] : ["call_snapshot"]);
        expect(outputs).toHaveLength(conflict ? 0 : 1);
        if (!conflict) {
          expect(outputs[0].output).toContain("SNAPSHOT_READ_RESULT");
          expect(input.filter((item: { type?: string }) => item.type === "reasoning")).toEqual([reasoning]);
          expect(input.find((item: { phase?: string }) => item.phase === "commentary").content[0].text).toBe("Inspecting.");
        }
      }
      expect(gateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("native discarded prose keeps tool continuation and saved resume valid", async () => {
  for (const provider of ["codex", "grok"] as const) for (const mismatch of [false, true]) for (const multiple of [false, true]) {
    const profile = mkdtempSync(join(tmpdir(), "fx-discarded-prose-"));
    const gateway = startFakeGateway([]);
    const model = "fixture-model";
    const prose = mismatch ? "我会先检查锁文件和依赖清单。" : "I will read the notes next.";
    const reasoning = { type: "reasoning", id: "rs_filtered", summary: [], encrypted_content: "RETAINED_REASONING" };
    const message = (id: string, text: string, phase?: string) => ({ type: "message", id, role: "assistant", status: "completed", ...(phase ? { phase } : {}), content: [{ type: "output_text", text, annotations: [] }] });
    const messages = multiple ? [message("msg_first", prose), message("msg_second", prose)] : [message("msg_first", prose, "commentary")];
    const call = { type: "function_call", id: "fc_filtered", call_id: "call_filtered", name: "read_file", arguments: JSON.stringify({ path: "notes.txt" }) };
    const toolIndex = messages.length + 1;
    const answer = (text: string) => fakeGatewaySse([
      { type: "response.output_item.done", output_index: 0, item: message("msg_answer", text) },
      { type: "response.completed", response: { status: "completed", output: null } },
    ]);
    const responses = [fakeGatewaySse([
      { type: "response.output_item.done", output_index: 0, item: reasoning },
      ...messages.map((item, index) => ({ type: "response.output_item.done", output_index: index + 1, item })),
      { type: "response.output_item.added", output_index: toolIndex, item: { ...call, arguments: "" } },
      { type: "response.function_call_arguments.done", output_index: toolIndex, item_id: call.id, arguments: call.arguments },
      { type: "response.output_item.done", output_index: toolIndex, item: call },
      { type: "response.completed", response: { status: "completed", output: [reasoning, ...messages, call] } },
    ]), answer("The notes were checked."), answer("The saved session remains usable.")];
    const direct = provider === "codex" ? startFakeCodexToolLoop({ model, responses }) : startFakeGrokToolLoop({ model, responses });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      writeFileSync(join(profile, "notes.txt"), "FILTERED_READ_RESULT\n");
      const tracePath = join(profile, "trace.log");
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "agent,gateway,tool",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Please read the notes.txt file and explain the result."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(first.code, provider + "/" + mismatch + "/" + multiple + ": " + first.stdout + first.stderr).toBe(0);
      expect(first.signal).toBeNull();
      const result = JSON.parse(first.stdout);
      expect(result.tool_calls).toEqual([{ name: "read_file", status: "success" }]);
      expect(result.output).toBe(mismatch ? "The notes were checked." : messages.map(() => prose).join("\n\n") + "\n\nThe notes were checked.");
      expect(direct.bodies).toHaveLength(2);
      const trace = readFileSync(tracePath, "utf8");
      expect(trace.includes("prose_discarded=true")).toBe(mismatch);
      const detail = await runFx(["session", "--json", "--id", result.session_id], { cwd: profile, env });
      expect(detail.code).toBe(0);
      expect(JSON.parse(detail.stdout).history).toHaveLength(1);
      const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", result.session_id, "Please confirm the saved result without tools."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).tool_calls).toEqual([]);
      expect(JSON.parse(resumed.stdout).output).toBe("The saved session remains usable.");
      expect(direct.bodies).toHaveLength(3);
      for (const body of direct.bodies.slice(1)) {
        const input = JSON.parse(body).input;
        expect(input.filter((item: { type?: string }) => item.type === "reasoning")).toEqual([reasoning]);
        expect(input.filter((item: { type?: string }) => item.type === "function_call").map((item: { call_id: string }) => item.call_id)).toEqual([call.call_id]);
        expect(input.filter((item: { type?: string }) => item.type === "function_call_output")).toHaveLength(1);
        expect(body).toContain("FILTERED_READ_RESULT");
        if (mismatch) expect(body).not.toContain(prose);
      }
      expect(gateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("native terminal outcomes preserve recovery and incomplete warnings", async () => {
  for (const provider of ["gateway", "codex", "grok"] as const) for (const mode of ["transient", "partial", "tool", "rejected", "rejected-partial", "length", "length-with-status"]) {
    const native = provider !== "gateway";
    if (!native && mode !== "transient") continue;
    const profile = mkdtempSync(join(tmpdir(), "fx-native-outcomes-"));
    const model = native ? "fixture-model" : FAKE_GATEWAY_MODEL;
    const limited = mode.startsWith("length");
    const rejected = mode.startsWith("rejected");
    const event = (text: string) => native
      ? { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: text }
      : { type: "text-delta", id: "answer", delta: text };
    const terminal = native
      ? { type: "response.completed", response: { id: "resp_ok", status: "completed", output: [], usage: { input_tokens: 1, output_tokens: 1 } } }
      : { type: "finish", finishReason: { unified: "stop" } };
    const events: object[] = [];
    if (mode === "partial") events.push(event("DISCARDED_PREVIEW"));
    if (mode === "rejected-partial") events.push(event("REJECTED_PARTIAL"));
    if (limited) events.push(event("LIMITED_ANSWER"));
    if (mode === "tool" || rejected) {
      writeFileSync(join(profile, "read-me.txt"), "must not be read by the failed attempt");
      events.push({ type: "response.output_item.added", output_index: 1, item: { type: "function_call", id: "fc_failed", call_id: "failed", name: "read_file", arguments: JSON.stringify({ path: "read-me.txt" }) } });
    }
    const failure = { code: rejected ? "invalid_prompt" : "server_error", message: rejected ? "OUTCOME_REJECTED" : "OUTCOME_RETRY" };
    if (limited) events.push({ type: "response.incomplete", response: { id: "resp_limited", ...(mode === "length-with-status" ? { status: "incomplete" } : {}), output: [], incomplete_details: { reason: "max_output_tokens" } } });
    else if (native) events.push({ type: "response.failed", response: { id: "resp_failed", status: "failed", error: failure, output: [], usage: null } });
    else events.push({ type: "error", error: failure }, { type: "finish", finishReason: { unified: "error" } });
    const replies = [fakeGatewaySse(events), fakeGatewaySse([event("RECOVERED_OK"), terminal])];
    const gateway = startFakeGateway(native ? [] : replies);
    const direct = provider === "codex" ? startFakeCodexToolLoop({ model, responses: replies })
      : provider === "grok" ? startFakeGrokToolLoop({ model, responses: replies }) : null;
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct!.accessToken);
      else if (provider === "grok") writeSeededGrokLogin(profile, direct!.accessToken);
      mkdirSync(join(profile, ".fx"), { recursive: true });
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [native ? provider + "_model" : "model"]: model }));
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: native ? undefined : model,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct?.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct?.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct?.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct?.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: direct && "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const result = await runFx(["ask", "--json", "--auto", "Report the supplied answer without using tools."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(result.signal).toBeNull();
      expect(result.code, result.stdout + result.stderr).toBe(rejected ? 1 : 0);
      expect(direct ? direct.bodies.length : gateway.requests.length).toBe(rejected || limited ? 1 : 2);
      const output = JSON.parse(result.stdout);
      expect(output.tool_calls).toEqual([]);
      if (native && !limited) {
        const usage = JSON.parse(readFileSync(join(profile, ".fx", "sessions", output.session_id, "usage-v2.json"), "utf8"));
        expect(usage.snapshot.billing).toBe("incomplete");
      }
      if (rejected) {
        expect(result.stderr).toContain("invalid_prompt: OUTCOME_REJECTED");
        expect(result.stderr).not.toContain("retrying");
        if (mode === "rejected-partial") {
          const detail = await runFx(["session", "--json", "--id", output.session_id], { cwd: profile, env });
          expect(detail.code).toBe(0);
          const history = JSON.parse(detail.stdout).history;
          expect(history).toHaveLength(1);
          expect(history[0].kind).toBe("interrupted");
          expect(history[0].assistant).toBe("REJECTED_PARTIAL");
          expect(history[0].execution?.tool_steps ?? []).toEqual([]);
          expect(history[0].tool_call).toBeNull();
          expect(history[0].completed_tool_names).toEqual([]);
          const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", output.session_id, "Continue from the saved partial answer without using tools."], { cwd: profile, env, timeoutMs: TIMEOUT });
          expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
          expect(JSON.parse(resumed.stdout).output).toBe("RECOVERED_OK");
          expect(direct!.bodies).toHaveLength(2);
          const input = JSON.parse(direct!.bodies[1]).input;
          expect(JSON.stringify(input)).toContain("REJECTED_PARTIAL");
          expect(input.filter((item: { type?: string }) => item.type === "function_call")).toEqual([]);
        }
      } else {
        expect(output.output).toBe(limited ? "LIMITED_ANSWER" : "RECOVERED_OK");
        expect(result.stderr).toContain(limited ? "response hit provider length limit" : "OUTCOME_RETRY");
        const detail = await runFx(["session", "--json", "--id", output.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        const history = JSON.parse(detail.stdout).history;
        expect(history).toHaveLength(1);
        expect(history[0].assistant).toBe(limited ? "LIMITED_ANSWER" : "RECOVERED_OK");
        expect(history[0].execution.tool_steps).toEqual([]);
        if (mode === "partial") expect(direct!.bodies[1]).not.toContain("DISCARDED_PREVIEW");
      }
      if (native) expect(gateway.requests).toHaveLength(0);
    } finally {
      direct?.stop();
      gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("provider SSE framing preserves saved and resumed answers", async () => {
  const prefix = "CONTROL_PREFIX\n", answer = "EXPECTED_FINAL";
  for (const provider of ["gateway", "codex", "grok"] as const) for (const mode of ["no-space", "multiline", "invalid"]) {
    const profile = mkdtempSync(join(tmpdir(), "fx-sse-framing-"));
    const native = provider !== "gateway";
    const model = native ? "fixture-model" : FAKE_GATEWAY_MODEL;
    const event = (text: string) => native
      ? { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: text }
      : { type: "text-delta", id: "answer", delta: text };
    const terminal = native
      ? { type: "response.completed", response: { status: "completed" } }
      : { type: "finish", finishReason: { unified: mode === "invalid" ? "tool-calls" : "stop" } };
    const frame = (value: object) => "data: " + JSON.stringify(value) + "\n\n";
    let wire = frame(event(prefix));
    if (mode === "invalid") {
      const input = { path: "read-me.txt" };
      writeFileSync(join(profile, "read-me.txt"), "not admitted");
      if (native) {
        const item = { type: "function_call", id: "fc_read", call_id: "read", name: "read_file", arguments: JSON.stringify(input) };
        wire += frame({ type: "response.output_item.added", output_index: 1, item });
        wire += frame({ type: "response.output_item.done", output_index: 1, item });
      } else wire += frame({ type: "tool-call", toolCallId: "read", toolName: "read_file", input });
      wire += "data: {invalid-json}\n\n";
    } else if (mode === "no-space") wire += "data:" + JSON.stringify(event(answer)) + "\n\n";
    else wire += JSON.stringify(event(answer), null, 2).split("\n").map(line => "data: " + line).join("\n") + "\n\n";
    wire += frame(terminal);
    if (mode === "multiline") wire = "\ufeff" + wire.replaceAll("\n", "\r\n");
    const replies = [new Response(wire, { headers: { "content-type": "text/event-stream" } }), native
      ? fakeGatewaySse([event("RESUME_OK"), { type: "response.completed", response: { status: "completed" } }])
      : fakeGatewayFinalText("RESUME_OK")];
    const gateway = startFakeGateway(native ? [] : replies);
    const direct = provider === "codex" ? startFakeCodexToolLoop({ model, responses: replies })
      : provider === "grok" ? startFakeGrokToolLoop({ model, responses: replies }) : null;
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct!.accessToken);
      else if (provider === "grok") writeSeededGrokLogin(profile, direct!.accessToken);
      mkdirSync(join(profile, ".fx"), { recursive: true });
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [native ? provider + "_model" : "model"]: model }));
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: native ? undefined : model,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct?.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct?.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct?.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct?.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: direct && "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Report the supplied answer."], { cwd: profile, env, timeoutMs: TIMEOUT });
      const output = JSON.parse(first.stdout);
      expect(first.signal).toBeNull();
      expect(direct ? direct.bodies.length : gateway.requests.length).toBe(1);
      if (mode === "invalid") {
        expect(first.code, first.stdout + first.stderr).toBe(1);
        expect(output.error).toBe(provider === "gateway" ? "InvalidGatewaySseEvent" : provider === "codex" ? "InvalidOpenAICodexSseEvent" : "InvalidXaiGrokSseEvent");
        expect(output.tool_calls).toEqual([]);
      } else {
        expect(first.code, first.stdout + first.stderr).toBe(0);
        expect(first.stderr).toBe("");
        expect(output.output).toBe(prefix + answer);
        const detail = await runFx(["session", "--json", "--id", output.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        expect(JSON.parse(detail.stdout).history[0].assistant).toBe(prefix + answer);
        const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", output.session_id, "Recall the prior answer."], { cwd: profile, env, timeoutMs: TIMEOUT });
        expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(direct ? direct.bodies.length : gateway.requests.length).toBe(2);
        const replay = direct ? direct.bodies[1] : gateway.requests[1].body;
        expect(replay).toContain(JSON.stringify(prefix + answer));
      }
      if (native) expect(gateway.requests).toHaveLength(0);
    } finally {
      direct?.stop(); gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("direct providers reconcile final text before saving or releasing tools", async () => {
  const prefix = "COMMENTARY_ITEM\n", answer = "FINAL_ANSWER_ITEM";
  const display = prefix + "\n\n" + answer;
  for (const provider of ["codex", "grok"] as const) for (const mode of ["streamed", "final-only", "mixed", "terminal-only", "conflict"]) {
    const profile = mkdtempSync(join(tmpdir(), "fx-response-text-"));
    const model = "fixture-model";
    const gateway = startFakeGateway([]);
    const events: object[] = [], items: object[] = [];
    for (const [index, text] of [prefix, answer].entries()) {
      const id = "msg_" + index;
      const part = { type: "output_text", text, annotations: [] };
      const item = { id, type: "message", role: "assistant", status: "completed", content: [part] };
      items.push(item);
      events.push({ type: "response.output_item.added", output_index: index, item: { ...item, status: "in_progress", content: [] } });
      if (mode === "streamed" || (index === 0 && (mode === "mixed" || mode === "conflict"))) {
        events.push({ type: "response.output_text.delta", output_index: index, content_index: 0, item_id: id, delta: text });
      }
      if (mode === "conflict" && index === 0) {
        events.push({ type: "response.output_item.added", output_index: 2, item: { type: "function_call", id: "fc_write", call_id: "write", name: "write_file", arguments: JSON.stringify({ path: "must-not-exist.txt", content: "not admitted" }) } });
        events.push({ type: "response.output_text.done", output_index: 0, content_index: 0, item_id: id, text: "CONFLICTING_FINAL" });
        break;
      }
      if (mode !== "terminal-only") events.push(
        { type: "response.output_text.done", output_index: index, content_index: 0, item_id: id, text },
        { type: "response.content_part.done", output_index: index, content_index: 0, item_id: id, part },
        { type: "response.output_item.done", output_index: index, item },
      );
    }
    events.push({ type: "response.completed", response: { status: "completed", output: items } });
    const responses = [fakeGatewaySse(events), fakeGatewaySse([
      { type: "response.output_text.delta", delta: "RESUME_OK" },
      { type: "response.completed", response: { status: "completed" } },
    ])];
    const direct = provider === "codex" ? startFakeCodexToolLoop({ model, responses }) : startFakeGrokToolLoop({ model, responses });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
      };
      const first = await runFx(["ask", "--json", "--auto", "Report both response items."], { cwd: profile, env, timeoutMs: TIMEOUT });
      const output = JSON.parse(first.stdout);
      expect(first.signal).toBeNull();
      expect(direct.bodies).toHaveLength(1);
      expect(existsSync(join(profile, "must-not-exist.txt"))).toBe(false);
      if (mode === "conflict") {
        expect(first.code, first.stdout + first.stderr).toBe(1);
        expect(output.error).toBe("ResponsesTextConflict");
        expect(output.tool_calls).toEqual([]);
      } else {
        expect(first.code, first.stdout + first.stderr).toBe(0);
        expect(first.stderr).toBe("");
        expect(output.output).toBe(display);
        expect(output.final_output).toBe(display);
        const detail = await runFx(["session", "--json", "--id", output.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        expect(JSON.parse(detail.stdout).history[0].assistant).toBe(display);
        const resumed = await runFx(["ask", "--json", "--auto", "--resume-id", output.session_id, "Recall the prior answer."], { cwd: profile, env, timeoutMs: TIMEOUT });
        expect(resumed.code, resumed.stdout + resumed.stderr).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(direct.bodies).toHaveLength(2);
        const replay = JSON.parse(direct.bodies[1]).input.filter((entry: { role?: string }) => entry.role === "assistant");
        expect(replay.map((entry: { content: Array<{ text?: string }> }) => entry.content.map(part => part.text).join(""))).toEqual([prefix, answer]);
      }
      expect(gateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); gateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("direct providers keep images with their users through tools and resume", async () => {
  for (const provider of ["codex", "grok"] as const) {
    const profile = mkdtempSync(join(tmpdir(), "fx-native-image-history-"));
    const model = "fixture-model";
    const testGateway = startFakeGateway([]);
    const terminal = { type: "response.completed", response: { status: "completed", usage: { input_tokens: 50_000, output_tokens: 10 } } };
    const responses = [
      fakeGatewaySse([
        { type: "response.output_item.added", output_index: 0, item: { type: "function_call", call_id: "read_1", name: "read_file", arguments: "" } },
        { type: "response.function_call_arguments.done", output_index: 0, arguments: JSON.stringify({ path: "fixture.txt" }) },
        terminal,
      ]),
      ...Array.from({ length: 3 }, () => fakeGatewaySse([
        { type: "response.output_text.delta", delta: "IMAGE_HISTORY_OK" }, terminal,
      ])),
    ];
    const direct = provider === "codex"
      ? startFakeCodexToolLoop({ responses, model, inputModalities: ["text", "image"] })
      : startFakeGrokToolLoop({ responses, model });
    try {
      if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
      else writeSeededGrokLogin(profile, direct.accessToken);
      writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
      writeFileSync(join(profile, "fixture.txt"), "fixture text");
      const firstImage = readFileSync(join(REPO_ROOT, "tests/e2e/fixtures/favicon.png"));
      const secondImage = readFileSync(join(REPO_ROOT, "tests/e2e/fixtures/placeholder-logo.png"));
      const firstPath = join(profile, "first.png"), secondPath = join(profile, "second.png");
      writeFileSync(firstPath, firstImage); writeFileSync(secondPath, secondImage);
      const firstUrl = "data:image/png;base64," + firstImage.toString("base64");
      const secondUrl = "data:image/png;base64," + secondImage.toString("base64");
      const env = {
        HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: testGateway.baseUrl,
        FX_E2E_GATEWAY_MODELS_URL: testGateway.baseUrl + "/coding-agent/v1/models",
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl,
        FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl,
        FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
        FX_TRACE_LOG: join(profile, "trace.log"), FX_TRACE_SCOPES: "context_compaction",
      };
      const firstPrompt = "Read fixture.txt, then describe the attached image.";
      const secondPrompt = "Compare the earlier image with this new image.";
      const imageOwners = (raw: string): Array<{ text: string; images: string[] }> => JSON.parse(raw).input
        .filter((entry: { role?: string }) => entry.role === "user")
        .map((entry: { content: Array<{ type: string; text?: string; image_url?: string }> }) => ({
          text: entry.content.filter(part => part.type === "input_text").map(part => part.text).join(""),
          images: entry.content.filter(part => part.type === "input_image").map(part => part.image_url!),
        }))
        .filter((entry: { images: string[] }) => entry.images.length > 0);
      const firstOwner = { text: firstPrompt, images: [firstUrl] };
      const secondOwner = { text: secondPrompt, images: [secondUrl] };
      const first = await runFx(["ask", "--json", "--auto", "--image", firstPath, firstPrompt], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(first.code, first.stdout + first.stderr).toBe(0);
      expect(first.signal).toBeNull();
      const sessionId = JSON.parse(first.stdout).session_id;
      expect(JSON.parse(first.stdout).tool_calls).toEqual([{ name: "read_file", status: "success" }]);
      expect(direct.bodies).toHaveLength(2);
      expect(imageOwners(direct.bodies[0])).toEqual([firstOwner]);
      expect(imageOwners(direct.bodies[1])).toEqual([firstOwner]);
      expect(readFileSync(join(profile, "trace.log"), "utf8")).toContain("has_images=true image_baseline=true");
      unlinkSync(firstPath);
      const second = await runFx(["ask", "--json", "--auto", "--resume-id", sessionId, "--image", secondPath, secondPrompt], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(second.code, second.stdout + second.stderr).toBe(0);
      expect(second.signal).toBeNull();
      expect(second.stderr).toBe("");
      expect(direct.bodies).toHaveLength(3);
      expect(imageOwners(direct.bodies[2])).toEqual([firstOwner, secondOwner]);
      const third = await runFx(["ask", "--json", "--auto", "--resume-id", sessionId, "Look again at both earlier images."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(third.code, third.stdout + third.stderr).toBe(0);
      expect(third.signal).toBeNull();
      expect(third.stderr).toBe("");
      expect(direct.bodies).toHaveLength(4);
      expect(imageOwners(direct.bodies[3])).toEqual([firstOwner, secondOwner]);
      const detail = await runFx(["session", "--json", "--id", sessionId], { cwd: profile, env });
      expect(detail.code).toBe(0);
      const history = JSON.parse(detail.stdout).history;
      expect(history).toHaveLength(3);
      expect(history.map((turn: { user: { images?: unknown[] } }) => turn.user.images?.length ?? 0)).toEqual([1, 1, 0]);
      const imageDir = join(profile, ".fx", "sessions", sessionId, "images");
      const snapshotName = readdirSync(imageDir).find(name => name.endsWith(".bin") && readFileSync(join(imageDir, name)).equals(firstImage));
      expect(snapshotName).toBeDefined();
      writeFileSync(join(imageDir, snapshotName!), secondImage);
      const rejected = await runFx(["ask", "--json", "--auto", "--resume-id", sessionId, "Inspect the earlier images again."], { cwd: profile, env, timeoutMs: TIMEOUT });
      expect(rejected.code, rejected.stdout + rejected.stderr).toBe(1);
      expect(rejected.signal).toBeNull();
      expect(rejected.stdout + rejected.stderr).toContain("ImageSnapshotCorrupt");
      expect(direct.bodies).toHaveLength(4);
      const retained = await runFx(["session", "--json", "--id", sessionId], { cwd: profile, env });
      expect(retained.code).toBe(0);
      expect(JSON.parse(retained.stdout).history).toEqual(history);
      expect(testGateway.requests).toHaveLength(0);
    } finally {
      direct.stop(); testGateway.stop();
      rmSync(profile, { recursive: true, force: true });
    }
  }
}, 60_000);

test("provider context accounting is independent of image encoding size", async () => {
  const encodings = equivalentPngEncodings();
  for (const provider of ["gateway", "codex", "grok"] as const) {
    const estimates: number[] = [];
    for (const bytes of encodings) {
      const profile = mkdtempSync(join(tmpdir(), "fx-image-context-"));
      const model = provider === "gateway" ? "fixture/image" : "fixture-model";
      const gateway = startFakeGateway([fakeGatewayFinalText("IMAGE_CONTEXT_OK")], {
        models: [{ id: model, type: "language", tags: ["vision", "file-input", "tool-use"], context_window: 1_000_000 }],
      });
      const responses = [fakeGatewaySse([
        { type: "response.output_text.delta", delta: "IMAGE_CONTEXT_OK" },
        { type: "response.completed", response: { status: "completed" } },
      ])];
      const direct = provider === "codex" ? startFakeCodexToolLoop({ responses, model, inputModalities: ["text", "image"] })
        : provider === "grok" ? startFakeGrokToolLoop({ responses, model }) : null;
      try {
        mkdirSync(join(profile, ".fx"), { recursive: true });
        if (provider === "codex") writeSeededChatGptLogin(profile, direct!.accessToken);
        if (provider === "grok") writeSeededGrokLogin(profile, direct!.accessToken);
        writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [provider + "_model"]: model }), { mode: 0o600 });
        const path = join(profile, "image.png"), trace = join(profile, "trace.log");
        writeFileSync(path, bytes);
        const result = await runFx(["ask", "--json", "--auto", "--no-save", "--image", path, "Describe the attached image."], {
          cwd: profile, timeoutMs: TIMEOUT,
          env: {
            HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined,
            FX_MODEL: provider === "gateway" ? model : undefined, FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
            FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_MODELS_URL: gateway.baseUrl + "/coding-agent/v1/models",
            FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct?.responsesUrl, FX_E2E_OPENAI_CODEX_MODELS_URL: direct?.modelsUrl,
            FX_E2E_XAI_GROK_RESPONSES_URL: direct?.responsesUrl, FX_E2E_XAI_GROK_MODELS_URL: direct?.modelsUrl,
            FX_E2E_XAI_GROK_MODALITIES_URL: direct && "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
            FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "context_compaction",
          },
        });
        expect(result.code, provider + ": " + result.stdout + result.stderr).toBe(0);
        expect(result.signal).toBeNull();
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout).output).toBe("IMAGE_CONTEXT_OK");
        const bodies = direct?.bodies ?? gateway.requests;
        expect(bodies).toHaveLength(1);
        const request = JSON.parse(typeof bodies[0] === "string" ? bodies[0] : bodies[0].body);
        const parts = (request.input ?? request.prompt).flatMap((message: { content: unknown }) => Array.isArray(message.content) ? message.content : []);
        const image = parts.find((part: { type?: string }) => part.type === (provider === "gateway" ? "file" : "input_image"));
        expect(image).toBeDefined();
        expect(provider === "gateway" ? image.data : image.image_url).toBe((provider === "gateway" ? "" : "data:image/png;base64,") + bytes.toString("base64"));
        const decision = readFileSync(trace, "utf8");
        expect(decision).toContain("decision=no_op");
        expect(decision).toContain("has_images=true image_baseline=false");
        estimates.push(Number(decision.match(/estimated_tokens=(\d+)/)![1]));
        if (direct) expect(gateway.requests).toHaveLength(0);
      } finally {
        direct?.stop(); gateway.stop();
        rmSync(profile, { recursive: true, force: true });
      }
    }
    expect(estimates[0]).toBe(estimates[1]);
  }
}, 60_000);

test("direct provider tool identities obey the session boundary before execution", async () => {
  for (const provider of ["codex", "grok"] as const) {
    for (const bytes of [256, 257]) {
      const profile = mkdtempSync(join(tmpdir(), `fx-${provider}-identity-`));
      const testGateway = startFakeGateway([]);
      const options = { toolCallId: "i".repeat(bytes), toolName: "write_file", toolArguments: { path: "result.txt", content: "saved" } };
      const direct = provider === "codex" ? startFakeCodexToolLoop(options) : startFakeGrokToolLoop(options);
      try {
        if (provider === "codex") writeSeededChatGptLogin(profile, direct.accessToken);
        else writeSeededGrokLogin(profile, direct.accessToken);
        const catalog = await (await fetch(direct.modelsUrl)).json();
        const model = provider === "codex" ? catalog.models[0].slug : catalog.data[0].id;
        writeFileSync(join(profile, ".fx", "settings.json"), JSON.stringify({ provider, [`${provider}_model`]: model }), { mode: 0o600 });
        const env = {
          HOME: profile, AI_GATEWAY_API_KEY: "fixture", VERCEL_OIDC_TOKEN: undefined, FX_MODEL: undefined,
          FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0",
          FX_GATEWAY_BASE_URL: testGateway.baseUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${testGateway.baseUrl}/coding-agent/v1/models`,
          FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl,
          FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
          FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl,
          FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
          FX_E2E_XAI_GROK_MODALITIES_URL: "modalitiesUrl" in direct ? direct.modalitiesUrl : undefined,
        };
        const result = await runFx(["ask", "--json", "--auto", "Create result.txt containing saved."], { cwd: profile, env, timeoutMs: TIMEOUT });
        const accepted = bytes === 256;
        expect(result.code, `${provider}/${bytes}: ${result.stdout}\n${result.stderr}`).toBe(accepted ? 0 : 1);
        expect(result.signal).toBeNull();
        expect(existsSync(join(profile, "result.txt"))).toBe(accepted);
        expect(direct.bodies).toHaveLength(accepted ? 2 : 1);
        expect(testGateway.requests).toHaveLength(0);
        const json = JSON.parse(result.stdout);
        expect(json.tool_calls).toEqual(accepted ? [{ name: "write_file", status: "success" }] : []);
        if (!accepted) expect(json.error).toBe("MalformedAuthoritativeToolIdentity");
        const detail = await runFx(["session", "--json", "--id", json.session_id], { cwd: profile, env });
        expect(detail.code).toBe(0);
        const history = JSON.parse(detail.stdout).history;
        expect(history).toHaveLength(accepted ? 1 : 0);
        if (accepted) expect(history[0].execution.tool_steps[0].tool_calls[0].id).toBe(options.toolCallId);
      } finally {
        direct.stop(); testGateway.stop();
        rmSync(profile, { recursive: true, force: true });
      }
    }
  }
}, 60_000);

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
      inputModalities: ["text", "image"],
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
  "saved provider switching publishes Gateway, Codex, and Grok usage to one profile ledger",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-provider-usage-ledger-"));
    const workspace = join(home, "workspace");
    mkdirSync(workspace, { recursive: true });
    gateway = startFakeGateway([
      fakeGatewaySse([
        {
          type: "response-metadata",
          modelId: FAKE_GATEWAY_MODEL,
          timestamp: new Date().toISOString(),
        },
        {
          type: "text-start",
          id: "gateway_answer",
          providerMetadata: {
            gateway: { generationId: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV" },
          },
        },
        { type: "text-delta", id: "gateway_answer", delta: "GATEWAY_USAGE_OK" },
        { type: "text-end", id: "gateway_answer" },
        {
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
          usage: {
            inputTokens: { total: 13 },
            outputTokens: { total: 4 },
          },
          providerMetadata: {
            gateway: {
              generationId: "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
              cost: "0.01",
              routing: { canonicalSlug: FAKE_GATEWAY_MODEL },
            },
          },
        },
      ]),
    ]);
    const codex = startFakeDirectUsageProvider(
      "codex",
      "gpt-5.6-sol",
      "response-codex-profile",
      17,
      7,
    );
    const grok = startFakeDirectUsageProvider(
      "grok",
      "grok-4.20",
      "response-grok-profile",
      19,
      5,
    );
    try {
      writeSeededChatGptLogin(home, chatgptAccessToken("acct_usage"));
      writeSeededGrokLogin(home, "grok-usage-token", "acct_usage");
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "gateway-usage-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_E2E_OPENAI_CODEX_RESPONSES_URL: codex.responsesUrl,
        FX_E2E_OPENAI_CODEX_MODELS_URL: codex.modelsUrl,
        FX_E2E_XAI_GROK_RESPONSES_URL: grok.responsesUrl,
        FX_E2E_XAI_GROK_MODELS_URL: grok.modelsUrl,
        FX_E2E_XAI_GROK_MODALITIES_URL: grok.modalitiesUrl,
      };
      const settingsPath = join(home, ".fx", "settings.json");
      const routes = [
        { settings: { provider: "gateway", model: FAKE_GATEWAY_MODEL }, text: "GATEWAY_USAGE_OK" },
        { settings: { provider: "codex", codex_model: "gpt-5.6-sol" }, text: "CODEX_USAGE_OK" },
        { settings: { provider: "grok", grok_model: "grok-4.20" }, text: "GROK_USAGE_OK" },
      ];
      for (const route of routes) {
        writeFileSync(settingsPath, JSON.stringify(route.settings) + "\n", { mode: 0o600 });
        const result = await runFx(
          ["ask", "--json", `Return ${route.text}.`],
          { cwd: workspace, env, timeoutMs: TIMEOUT },
        );
        expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
        expect(result.stdout).toContain(route.text);
      }

      const usage = await runFx(
        ["usage", "--json", "--period", "24h"],
        { cwd: workspace, env: { HOME: home }, timeoutMs: TIMEOUT },
      );
      expect(usage.code, usage.stderr).toBe(0);
      const report = JSON.parse(usage.stdout) as {
        completeness: string;
        totals: { input_tokens: number; output_tokens: number; request_count: number };
        models: Array<{ model: string; totals: { request_count: number } }>;
      };
      expect(report.completeness).toBe("complete");
      expect(report.totals).toMatchObject({
        input_tokens: 49,
        output_tokens: 16,
        request_count: 3,
      });
      expect(Object.fromEntries(
        report.models.map((model) => [model.model, model.totals.request_count]),
      )).toEqual({
        [FAKE_GATEWAY_MODEL]: 1,
        "codex/gpt-5.6-sol": 1,
        "grok/grok-4.20": 1,
      });
      expect(gateway.requests).toHaveLength(1);
      expect(codex.responses).toBe(1);
      expect(grok.responses).toBe(1);
    } finally {
      codex.stop();
      grok.stop();
    }
  },
  60_000,
);

test(
  "Codex automatic review uses gpt-5.6-luna while Gateway review stays untouched",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-codex-auto-review-"));
    writeFileSync(join(home, "provider-review-existing.txt"), "before\n");
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
        [
          "ask",
          "--json",
          "--auto",
          "Update provider-review-existing.txt, then finish.",
        ],
        {
          cwd: home,
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
      expect(readFileSync(join(home, "provider-review-existing.txt"), "utf8")).toBe("reviewed");
      expect(codex.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-sol"]);
      expect(codex.bodies[1]).toContain('"name":"permission_decision"');
      expect(codex.bodies[2]).toContain('"type":"function_call_output"');
      expect(codex.bodies[2]).toContain('\\"exit_code\\":0');
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 4,
        settled_through_sequence: 3,
        input_tokens: 20,
        output_tokens: 8,
        request_count: 3,
        models: [
          { model: "codex/gpt-5.6-sol", request_count: 2 },
          { model: "codex/gpt-5.6-luna", request_count: 1 },
        ],
        pending: [],
      });
    } finally {
      codex.stop();
    }
  },
  60_000,
);

test(
  "provider-local automatic compaction never reaches Gateway",
  async () => {
    for (const provider of ["codex", "grok"] as const) {
      const testHome = mkdtempSync(join(tmpdir(), `fx-${provider}-compaction-`));
      const testGateway = startFakeGateway([]);
      const direct = startFakeProviderCompaction(provider);
      try {
        if (provider === "codex") {
          writeSeededChatGptLogin(testHome, direct.accessToken);
        } else {
          writeSeededGrokLogin(testHome, direct.accessToken);
        }
        writeFileSync(
          join(testHome, ".fx", "settings.json"),
          JSON.stringify(provider === "codex"
            ? { provider, codex_model: direct.workingModel }
            : { provider, grok_model: direct.workingModel }) + "\n",
          { mode: 0o600 },
        );
        const options = {
            cwd: testHome,
            env: {
              HOME: testHome,
              AI_GATEWAY_API_KEY: "gateway-compaction-sentinel",
              VERCEL_OIDC_TOKEN: undefined,
              FX_DISABLE_KEYCHAIN: "1",
              FX_AUTO_UPGRADE: "0",
              FX_GATEWAY_BASE_URL: testGateway.baseUrl,
              FX_TRACE_LOG: join(testHome, "compaction.log"),
              FX_TRACE_SCOPES: "agent,core,gateway,stream,context_compaction,session",
              FX_E2E_GATEWAY_MODELS_URL: `${testGateway.baseUrl}/coding-agent/v1/models`,
              FX_E2E_OPENAI_CODEX_RESPONSES_URL: direct.responsesUrl,
              FX_E2E_OPENAI_CODEX_MODELS_URL: direct.modelsUrl,
              FX_E2E_XAI_GROK_RESPONSES_URL: direct.responsesUrl,
              FX_E2E_XAI_GROK_MODELS_URL: direct.modelsUrl,
              FX_E2E_XAI_GROK_MODALITIES_URL: direct.modalitiesUrl,
            },
            timeoutMs: 60_000,
          };
        const catalog = await runFx(["models", "--json"], options);
        expect(catalog.code, `${catalog.stdout}\n${catalog.stderr}\n${JSON.stringify(direct.urls)}`).toBe(0);
        const seeded = await runFx(["ask", "--json", "--yolo", "Keep these provider facts."], options);
        expect(seeded.code).toBe(0);
        const result = await runFx(["ask", "--json", "--yolo", "--resume-id", JSON.parse(seeded.stdout).session_id, "Continue from those facts."], options);

        expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}\nrequests=${direct.bodies.length}\n${readFileSync(join(testHome, "compaction.log"), "utf8").split("\n").filter((line) => line.includes("context_compaction")).join("\n")}`).toBe(0);
        expect(JSON.parse(result.stdout).output).toContain(`${provider.toUpperCase()}_COMPACTION_CONTINUED`);
        expect(
          direct.bodies.map((body) => (JSON.parse(body) as { model: string }).model),
          JSON.stringify({
            body_lengths: direct.bodies.map((body) => body.length),
          }),
        )
          .toEqual(Array(4).fill(direct.workingModel));
        expect(direct.authorizations).toEqual(Array(4).fill(`Bearer ${direct.accessToken}`));
        if (provider === "grok") {
          expect(direct.modelOverrides).toEqual(Array(4).fill(direct.workingModel));
        }
        expect(testGateway.requests).toHaveLength(0);
      } finally {
        direct.stop();
        testGateway.stop();
        rmSync(testHome, { recursive: true, force: true });
      }
    }
  },
  120_000,
);

test(
  "Grok automatic review uses grok-4.5 and never reaches Gateway",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-grok-auto-review-"));
    writeFileSync(join(home, "provider-review-existing.txt"), "before\n");
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
        [
          "ask",
          "--json",
          "--auto",
          "Update provider-review-existing.txt, then finish.",
        ],
        {
          cwd: home,
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
      expect(readFileSync(join(home, "provider-review-existing.txt"), "utf8")).toBe("reviewed");
      expect(grok.bodies.map((body) => (JSON.parse(body) as { model: string }).model))
        .toEqual(["grok-4.20", "grok-4.5", "grok-4.20"]);
      expect(grok.bodies[1]).toContain('"name":"permission_decision"');
      expect(grok.bodies[2]).toContain('"type":"function_call_output"');
      expect(grok.bodies[2]).toContain('\\"exit_code\\":0');
      expect(grok.headers).toHaveLength(3);
      for (const [index, headers] of grok.headers.entries()) {
        expect(headers.tokenAuth).toBe("xai-grok-cli");
        expect(headers.authenticateResponse).toBe("authenticate-response");
        expect(headers.clientIdentifier).toBe("fx");
        expect(headers.clientVersion).toBe("1.0.6");
        expect(headers.modelOverride).toBe(index === 1 ? "grok-4.5" : "grok-4.20");
        expect(headers.grokUserId).toBe("acct_auto_review");
      }
      for (const request of gateway.requests) {
        expect(request.body).not.toContain("permission_decision");
      }
      expect(readSingleUsageSnapshot(home)).toMatchObject({
        billing: "complete",
        api_duration_complete: true,
        next_sequence: 4,
        settled_through_sequence: 3,
        input_tokens: 20,
        output_tokens: 8,
        request_count: 3,
        models: [
          { model: "grok/grok-4.20", request_count: 2 },
          { model: "grok/grok-4.5", request_count: 1 },
        ],
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
        pane.includes("fx needs access to Vercel AI Gateway") &&
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
    writeSeededFxLogin(home, Date.now() + 60 * 60 * 1000, oauth.issuerUrl, "team_123");

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await selectFxLoginCredential(session);
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

    await session.sendText("prove environment auth remains active");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests[1].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    // The invalid revocation endpoint must never be called, and logout must
    // not attempt a token refresh on its way out.
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toEqual([]);
    expect(oauth.requests.filter((request) => request.path === "/oauth/revoke")).toEqual([]);
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
    const picker = await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    expect(picker).not.toContain("Connections");
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("codex"), TIMEOUT);
    await session.sendKeys("C-u");

    const prompt = "prompt waits for auth after logout";
    await session.sendText(prompt);
    const onboarding = await session.waitForPane(
      (pane) =>
        pane.includes(prompt) &&
        pane.includes("Welcome to fx") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("Add an API key") &&
        pane.includes("Esc to set up later"),
      TIMEOUT,
    );
    expect(onboarding).not.toMatch(/^\s+fx login\s+/m);
    expect(onboarding).not.toContain("Switch credential");
    expect(onboarding).not.toContain("Skip for now");
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
        pane.includes("Run /provider to repair this source."),
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
  "manual compaction refreshes the selected login without losing the draft",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-compact-auth-refresh-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText("COMPACT_AUTH_FIRST_REPLY"),
      fakeGatewayFinalText("COMPACT_AUTH_SECOND_REPLY"),
      fakeGatewayFinalText("The conversation established COMPACT_AUTH_FIRST and COMPACT_AUTH_SECOND."),
      fakeGatewayFinalText("COMPACT_AUTH_CONTINUED"),
    ]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, { tokenDelayMs: 2_000 });
    const expiresAt = Date.now() + 80_000;
    writeSeededFxLogin(home, expiresAt, oauth.issuerUrl, "team_123");
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TRACE_SCOPES: "auth,input,worker,context_compaction,session",
    }, home);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Remember COMPACT_AUTH_FIRST.");
    await session.waitForText("COMPACT_AUTH_FIRST_REPLY", TIMEOUT);
    await session.sendText("Remember COMPACT_AUTH_SECOND.");
    await session.waitForText("COMPACT_AUTH_SECOND_REPLY", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
    await Bun.sleep(Math.max(0, expiresAt - 60_000 + 100 - Date.now()));
    await session.sendText("/status");
    await session.waitForText("auth_expired=true", TIMEOUT);
    await session.sendText("/compact");
    await waitForTrace(tracePath, "manual_compaction_auth_pending", TIMEOUT);
    expect(gateway.requests).toHaveLength(2);
    await session.sendText("/compact");
    await session.sendLiteral("PRESERVE_COMPACTION_DRAFT");
    await session.waitForText("PRESERVE_COMPACTION_DRAFT", 1_000);
    await session.waitForText("Context compacted.", TIMEOUT);
    expect(await session.captureFullScrollback()).toContain("PRESERVE_COMPACTION_DRAFT");
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${ACQUIRED_LOGIN_TOKEN}`);
    expect(JSON.parse(gateway.requests[2].body).tools ?? []).toHaveLength(0);
    const sessionIds = readdirSync(join(home, ".fx", "sessions")).filter((id) => existsSync(join(home!, ".fx", "sessions", id, "session.json")));
    expect(sessionIds).toHaveLength(1);
    const historyPath = join(home, ".fx", "sessions", sessionIds[0], "events.jsonl");
    const records = readFileSync(historyPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    expect(records.filter((record) => record.event.context_checkpoint)).toHaveLength(1);
    await session.sendKeys("C-u");
    await session.sendText("Continue after the manual compaction.");
    await session.waitForText("COMPACT_AUTH_CONTINUED", TIMEOUT);
    expect(gateway.requests).toHaveLength(4);
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    for (const secret of [LOGIN_TOKEN, ACQUIRED_LOGIN_TOKEN, "seeded-refresh-token", "acquired-refresh-token"]) expect(trace).not.toContain(secret);
  },
  90_000,
);

for (const outcome of ["failure", "cancel"] as const) {
  tmuxTest(`manual compaction auth ${outcome} preserves the session and accepts a later prompt`, async () => {
    home = mkdtempSync(join(tmpdir(), `fx-compact-auth-${outcome}-`));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([
      fakeGatewayFinalText("AUTH_BOUNDARY_FIRST_REPLY"),
      fakeGatewayFinalText("AUTH_BOUNDARY_SECOND_REPLY"),
      fakeGatewayFinalText("AUTH_BOUNDARY_RECOVERED"),
    ]);
    oauth = startFakeOAuth(outcome === "failure" ? null : ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      tokenDelayMs: outcome === "cancel" ? 10_000 : 1_000,
    });
    const expiresAt = Date.now() + 80_000;
    writeSeededFxLogin(home, expiresAt, oauth.issuerUrl, "team_123");
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ credential_source: "fx_login" }));
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      FX_TRACE_SCOPES: "auth,input,worker,context_compaction,session",
    }, home);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Remember AUTH_BOUNDARY_FIRST.");
    await session.waitForText("AUTH_BOUNDARY_FIRST_REPLY", TIMEOUT);
    await session.sendText("Remember AUTH_BOUNDARY_SECOND.");
    await session.waitForText("AUTH_BOUNDARY_SECOND_REPLY", TIMEOUT);
    const sessionIds = readdirSync(join(home, ".fx", "sessions")).filter((id) => existsSync(join(home!, ".fx", "sessions", id, "session.json")));
    expect(sessionIds).toHaveLength(1);
    const historyPath = join(home, ".fx", "sessions", sessionIds[0], "events.jsonl");
    const before = readFileSync(historyPath, "utf8");
    expect(gateway.requests).toHaveLength(2);
    expect(gateway.requests[0].headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
    expect(oauth.requests.filter((request) => request.path === "/oauth/token")).toHaveLength(0);
    await Bun.sleep(Math.max(0, expiresAt - 60_000 + 100 - Date.now()));
    await session.sendText("/compact");
    await waitForTrace(tracePath, "manual_compaction_auth_pending", TIMEOUT);
    await session.sendLiteral("DRAFT_DURING_AUTH_BOUNDARY");
    await session.waitForText("DRAFT_DURING_AUTH_BOUNDARY", 1_000);
    if (outcome === "cancel") {
      await session.sendKeys("C-c");
      await session.waitForText("Context compaction cancelled.", 3_000);
    } else {
      await session.waitForText("Your conversation is unchanged.", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("/compact again");
      expect(scrollback).not.toContain("Your prompt is saved.");
    }
    expect(await session.captureFullScrollback()).toContain("DRAFT_DURING_AUTH_BOUNDARY");
    expect(readFileSync(historyPath, "utf8")).toBe(before);
    expect(gateway.requests).toHaveLength(2);
    await session.sendKeys("C-u");
    await selectEnvKeyCredential(session);
    expect(gateway.requests).toHaveLength(2);
    await session.sendText("Continue the original conversation without tools.");
    await session.waitForText("AUTH_BOUNDARY_RECOVERED", TIMEOUT);
    expect(gateway.requests).toHaveLength(3);
    expect(gateway.requests[2].headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(readFileSync(historyPath, "utf8")).not.toContain('"context_checkpoint"');
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    expect(trace).not.toContain("context_compaction_enqueue");
    for (const secret of [LOGIN_TOKEN, ACQUIRED_LOGIN_TOKEN, ENV_TOKEN, "seeded-refresh-token", "acquired-refresh-token"]) expect(trace).not.toContain(secret);
  }, 90_000);
}

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
    await selectFxLoginCredential(session);
    const oauthBaseline = oauth.requests.length;
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
        pane.includes("fx login sign-in expired.") &&
        pane.includes("Press Enter to sign in again.") &&
        !pane.includes("Setup"),
      TIMEOUT,
    );
    expect(failed).toContain(`${promptHead}${promptTail}`);
    expect(failed).not.toContain(LOGIN_TOKEN);
    expect(failed).not.toContain(ENV_TOKEN);
    expect(gateway.requests).toHaveLength(0);
    expect(
      oauth.requests.slice(oauthBaseline).map((request) => `${request.method} ${request.path}`),
    ).toEqual(["GET /.well-known/openid-configuration", "POST /oauth/token"]);

    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await selectEnvKeyCredential(session);
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
  "permanent fx login failure enters repair without retrying or losing the prompt",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-repair-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    const tapePath = join(home, "pending-activity.fxtape");
    const replayPath = join(home, "pending-activity-replay");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath, {
      AI_GATEWAY_API_KEY: undefined,
      FX_TRACE_SCOPES: "auth,input",
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
    });
    await session.waitForComposer(TIMEOUT);
    await waitForTrace(tracePath, "prompt credential prewarm start outcome=started", 1_000);
    const prompt = "PRESERVE_DURING_LOGIN_REPAIR";
    await session.sendText(prompt);
    await waitForTrace(tracePath, "event=pending_prompt_frame_committed", 1_000);
    await session.waitForPane(
      (pane) => pane.includes(prompt) && pane.includes("Thinking"),
      1_000,
    );
    const responsiveDraft = "TERMINAL_RESPONSIVE_DURING_CREDENTIAL_REFRESH";
    await session.sendLiteral(responsiveDraft);
    await session.waitForPane(
      (pane) => pane.includes(responsiveDraft),
      1_000,
    );
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await session.waitForPane(
      (pane) => pane.includes("fx login sign-in expired.") && !pane.includes("Thinking"),
      TIMEOUT,
    );
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    const frames = readTapeFrames(tapePath);
    const promptInput = frames.findIndex((frame) => frame.kind === 2 && frame.payload.includes(prompt));
    expect(promptInput).toBeGreaterThanOrEqual(0);
    const enter = frames.findIndex((frame, index) =>
      index > promptInput && frame.kind === 2 && frame.payload.equals(Buffer.from("\r"))
    );
    expect(enter).toBeGreaterThan(promptInput);
    const firstOutput = frames.slice(enter + 1).find((frame) => frame.kind === 1);
    expect(firstOutput).toBeDefined();
    expect(firstOutput!.payload.includes(prompt)).toBe(true);
    expect(firstOutput!.payload.includes("Thinking")).toBe(true);

    const replay = await runFx(["replay", tapePath, "--frames-dir", replayPath]);
    expect(replay.code).toBe(0);
    const grids = readdirSync(join(replayPath, "frames"))
      .filter((name) => name.endsWith(".grid.txt"))
      .sort()
      .map((name) => readFileSync(join(replayPath, "frames", name), "utf8"));
    const thinkingGrids = grids.filter((grid) => grid.includes("Thinking"));
    expect(thinkingGrids.length).toBeGreaterThan(0);
    for (const grid of thinkingGrids) {
      const rows = grid.split("\n");
      const promptRow = rows.findIndex((row) => row.includes(prompt));
      expect(promptRow).toBeGreaterThanOrEqual(0);
      expect(rows.findIndex((row) => row.includes("Thinking"))).toBe(promptRow + 2);
    }

    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    const full = await session.captureFullScrollback();
    expect(full.match(/fx login sign-in expired\./g)).toHaveLength(1);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.body).toContain(prompt);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "cancelled fx login repair allows a later explicit login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-cancelled-repair-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);
    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, {
      AI_GATEWAY_API_KEY: undefined,
    });
    await session.waitForComposer(TIMEOUT);
    const prompt = "DO_NOT_REPLAY_AFTER_CANCELLED_REPAIR";
    await session.sendText(prompt);
    await session.waitForText("fx login sign-in expired.", TIMEOUT);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);

    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => pane.includes(prompt) && !pane.includes("Waiting for authorization"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendKeys("C-k");
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(2);
    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Team Harness", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);

    await session.sendText("use the repaired fx login");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.requests[0]!.body).not.toContain(prompt);
    expect(savedCredentialSource(home)).toBe("fx_login");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "refresh save failure retires the session and starts a fresh sign-in",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-refresh-save-failure-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    const authPath = join(home, ".fx", "auth.json");
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      tokenDelayMs: 5_000,
      beforeRefreshResponse() {
        chmodSync(authPath, 0o400);
      },
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    expect(existsSync(authPath)).toBe(false);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "a rejected saved session is retired before a later explicit login",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-rejected-session-login-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(REFRESH_RECOVERY_RESPONSE)]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      rejectRefreshGrant: true,
      tokenDelayMs: 5_000,
      teams: [{ id: "team_123", slug: "team-harness", name: "Team Harness" }],
    });
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(1);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Waiting for authorization"),
      TIMEOUT,
    );
    await session.sendKeys("C-u");
    await session.sendText("/login");
    await session.waitForPane(
      (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) => pane.includes("oauth") && pane.includes("api-key"),
      TIMEOUT,
    );
    await session.sendKeys("Enter");
    await session.waitForText("Waiting for authorization", TIMEOUT);

    expect(oauth.requests.filter((request) => request.grantType === "refresh_token")).toHaveLength(1);
    expect(oauth.requests.filter((request) => request.path === "/oauth/device")).toHaveLength(2);
    await session.waitForText("Team Harness", TIMEOUT);
    await session.sendKeys("Enter");
    await session.waitForText("Changed Vercel team to Team Harness", TIMEOUT);
    expect(savedCredentialSource(home)).toBe("fx_login");

    await session.sendText("use the repaired login after retiring the rejected token");
    await session.waitForText(REFRESH_RECOVERY_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(gateway.requests[0]!.headers.get("authorization")).not.toBe(
      `Bearer ${ENV_TOKEN}`,
    );
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

    await session.sendText("/model");
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
  "expired saved login prewarms credentials while model discovery stays anonymous",
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
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();

    await session.sendText("/model");
    await session.waitForPane(
      (pane) =>
        pane.includes(FAKE_GATEWAY_MODEL) &&
        pane.includes("Vercel sign-in must refresh before team-private models can load.") &&
        pane.includes("Esc Close"),
      TIMEOUT,
    );

    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "ready team catalog downgrades after fx login expiry and refresh failure",
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
    await session.sendText("/model");
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
        pane.includes("fx login sign-in expired.") &&
        pane.includes("Press Enter to sign in again.") &&
        !pane.includes("Model provider"),
      TIMEOUT,
    );
    expect(gateway.requests).toHaveLength(0);

    await session.sendKeys("C-u");
    await session.sendText("/model");
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
  "an immediately expired prewarm retires the login and keeps model discovery anonymous",
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
        pane.includes("fx login sign-in expired.") &&
        pane.includes("Press Enter to sign in again.") &&
        !pane.includes("Model provider"),
      TIMEOUT,
    );
    expect(firstFailure).not.toContain("Choose another source");
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);

    await session.sendKeys("C-u");
    await session.sendText("/model");
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
    expect(gateway.requests).toHaveLength(0);
    expect(gateway.modelRequests).toHaveLength(1);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
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
  "expired saved login refreshes credits and the selected team catalog",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-expired-credits-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN);
    creditsGateway = startFakeCreditsGateway();
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl, "team_123");

    session = await startFx(
      home,
      stderrPath,
      gateway,
      oauth.issuerUrl,
      undefined,
      {
        AI_GATEWAY_API_KEY: undefined,
        FX_E2E_GATEWAY_MODELS_URL: undefined,
        FX_E2E_GATEWAY_CREDITS_URL: creditsGateway.url,
      },
    );
    await session.waitForComposer(TIMEOUT);
    await waitForModelRequestCount(gateway, 1);
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
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
    await waitForModelRequestCount(gateway, 2);
    expect(gateway.modelRequests).toHaveLength(2);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[1].headers.get("authorization")).toBe(
      `Bearer ${ACQUIRED_LOGIN_TOKEN}`,
    );
    expect(new URL(gateway.modelRequests[1].url).searchParams.get("teamId")).toBe("team_123");
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
    await waitForOAuthRequestCount(oauth, 2);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    expect(gateway.modelRequests[0].headers.get("authorization")).toBeNull();
    expect(gateway.modelRequests[0].headers.get("x-vercel-ai-gateway-team")).toBeNull();
    expect(creditsGateway.requests).toEqual([]);

    await session.sendText("/credits");
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes("fx login sign-in expired.") &&
        pane.includes("Press Enter to sign in again.") &&
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

    await session.sendText("/model");
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

    await session.sendText("/model");
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

      await session.sendText("/model");
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

for (const provider of ["codex", "grok"] as const) {
  test.skipIf(process.platform === "win32")(`${provider} model discovery ignores a FIFO version cache without a writer`, async () => {
    home = mkdtempSync(join(tmpdir(), `fx-${provider}-version-fifo-`));
    const chatgpt = provider === "codex" ? startFakeChatGptOAuth() : undefined;
    const grok = provider === "grok" ? startFakeGrokOAuth() : undefined;
    const model = provider === "codex" ? "gpt-5.6-luna" : "grok-4.20";
    const version = "1.999.1";
    let releaseRequests = 0;
    const releases = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch() {
        releaseRequests++;
        return provider === "codex" ? Response.json({ version }) : new Response(version);
      },
    });
    try {
      if (chatgpt) writeSeededChatGptLogin(home);
      else writeSeededGrokLogin(home, grok!.initialAccessToken);
      writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
        provider, models: { [provider]: model },
      }), { mode: 0o600 });
      mkdirSync(join(home, ".fx/provider-versions"), { mode: 0o700 });
      const cachePath = join(home, ".fx/provider-versions", `${provider}.json`);
      expect(spawnSync("mkfifo", ["-m", "600", cachePath]).status).toBe(0);
      const env = {
        HOME: home,
        PATH: "/usr/bin:/bin",
        FX_MODEL: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        ...(chatgpt?.env ?? grok!.env),
        FX_E2E_CODEX_CLIENT_VERSION: undefined,
        FX_E2E_GROK_CLIENT_VERSION: undefined,
        [provider === "codex" ? "FX_E2E_CODEX_VERSION_URL" : "FX_E2E_GROK_VERSION_URL"]:
          `http://127.0.0.1:${releases.port}/version`,
      };

      const listed = await runFx(["models", "--json"], { env, timeoutMs: 8000 });
      expect(listed.timedOut).toBe(false);
      expect(listed.code, listed.stderr).toBe(0);
      expect(JSON.parse(listed.stdout).models.map((entry: { id: string }) => entry.id)).toContain(model);
      expect(listed.stderr).toBe("");
      expect(releaseRequests).toBe(1);
      expect(statSync(cachePath).isFIFO()).toBe(true);

      const asked = await runFx(["ask", "--json", "--auto", "--no-save", "Reply briefly."], { env, timeoutMs: 8000 });
      expect(asked.timedOut).toBe(false);
      expect(asked.code, asked.stderr).toBe(0);
      expect(asked.stdout).toContain(provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE");
      const beforeRepair = releaseRequests;
      expect(beforeRepair).toBeGreaterThan(1);
      unlinkSync(cachePath);
      const repaired = await runFx(["models", "--json"], { env, timeoutMs: 8000 });
      expect(repaired.code, repaired.stderr).toBe(0);
      expect(releaseRequests).toBe(beforeRepair + 1);
      expect(JSON.parse(readFileSync(cachePath, "utf8")).version).toBe(version);
      const cached = await runFx(["models", "--json"], { env, timeoutMs: 8000 });
      expect(cached.code, cached.stderr).toBe(0);
      expect(cached.stdout).toBe(repaired.stdout);
      expect(releaseRequests).toBe(beforeRepair + 1);
    } finally {
      chatgpt?.stop();
      grok?.stop();
      releases.stop(true);
    }
  }, 30_000);
}

tmuxTest("Codex discovers upstream versions and refreshes models in an open session without a CLI", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-codex-catalog-version-"));
  stderrPath = join(home, "stderr.log");
  gateway = startFakeGateway([]);
  writeSeededChatGptLogin(home);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "codex",
    models: { codex: "gpt-5.6-luna" },
  }) + "\n", { mode: 0o600 });
  const versions: Array<string | null> = [];
  const releaseHeaders: Headers[] = [];
  let latest = "0.999.1";
  const catalog = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === "/version") {
        releaseHeaders.push(request.headers);
        return Response.json({ version: latest });
      }
      const version = new URL(request.url).searchParams.get("client_version");
      versions.push(version);
      const ids = ["gpt-5.6-luna"];
      if (version === latest) ids.push("gpt-6-astra");
      if (version === "1.0.0") ids.push("future-release");
      return Response.json({ models: ids.map((slug) => ({
        slug,
        visibility: "list",
        supported_in_api: true,
        supported_reasoning_levels: [{ effort: "high" }, { effort: "ultra" }],
        input_modalities: ["text", "image"],
        context_window: 272000,
      })) });
    },
  });
  try {
    const env = {
      HOME: home,
      PATH: "/usr/bin:/bin",
      FX_MODEL: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      FX_E2E_OPENAI_CODEX_MODELS_URL: `http://127.0.0.1:${catalog.port}/models`,
      FX_E2E_CODEX_VERSION_URL: `http://127.0.0.1:${catalog.port}/version`,
      FX_E2E_CODEX_CLIENT_VERSION: undefined,
    };
    const listed = await runFx(["models", "--json"], { env, timeoutMs: TIMEOUT });
    expect(listed.code, listed.stderr).toBe(0);
    const ids = JSON.parse(listed.stdout).models.map((model: { id: string }) => model.id);
    expect(ids).toContain("gpt-6-astra");
    expect(listed.stderr).toBe("");

    session = await startFx(home, stderrPath, gateway, undefined, undefined, env);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/model");
    await session.waitForText("gpt-6-astra", TIMEOUT);
    expect(releaseHeaders).toHaveLength(1);
    await session.sendKeys("Escape");
    latest = "1.0.0";
    await Bun.sleep(61_000);
    await session.sendText("/model");
    await session.waitForText("future-release", TIMEOUT);
    expect(releaseHeaders).toHaveLength(2);
    expect(versions.at(-1)).toBe("1.0.0");
    for (const headers of releaseHeaders) {
      for (const name of ["authorization", "cookie", "chatgpt-account-id"]) {
        expect(headers.get(name)).toBeNull();
      }
    }
    expect(versions.length).toBeGreaterThanOrEqual(2);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    catalog.stop(true);
  }
}, 120_000);

test("Grok refreshes upstream versions for catalogs and responses and survives lookup failures", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-grok-version-discovery-"));
  const grok = startFakeGrokOAuth();
  let latest = "1.999.1";
  let failure: "none" | "unavailable" | "malformed" | "slow" = "none";
  const releaseHeaders: Headers[] = [];
  const releases = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      releaseHeaders.push(request.headers);
      if (failure === "slow") await Bun.sleep(5000);
      if (failure === "unavailable") return new Response("unavailable", { status: 503 });
      return new Response(failure === "malformed" ? "1.2.3\r\nInjected: bad" : latest);
    },
  });
  try {
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      provider: "grok", models: { grok: "grok-4.20" },
    }) + "\n", { mode: 0o600 });
    const env = {
      HOME: home,
      PATH: "/usr/bin:/bin",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      ...grok.env,
      FX_E2E_GROK_VERSION_URL: `http://127.0.0.1:${releases.port}/stable`,
      FX_E2E_GROK_CLIENT_VERSION: undefined,
    };
    const cachePath = join(home, ".fx", "provider-versions", "grok.json");
    const expireCache = () => {
      const cached = JSON.parse(readFileSync(cachePath, "utf8"));
      cached.checked_at_ms = 0;
      writeFileSync(cachePath, JSON.stringify(cached));
    };
    const first = await runFx(["models", "--json"], { env });
    expect(first.code, first.stderr).toBe(0);
    expect(releaseHeaders).toHaveLength(1);
    expect(grok.requests.find((request) => request.path === "/v1/models")?.clientVersion).toBe(latest);
    expect(grok.requests.find((request) => request.path === "/v1/language-models")?.clientVersion).toBeNull();

    latest = "2.0.0";
    expireCache();
    const asked = await runFx(["ask", "--json", "--auto", "--no-save", "Reply briefly."], { env });
    expect(asked.code, asked.stderr).toBe(0);
    expect(asked.stdout).toContain("GROK_DIRECT_RESPONSE");
    expect(grok.requests.find((request) => request.path === "/v1/responses")?.clientVersion).toBe(latest);
    expect(releaseHeaders).toHaveLength(2);

    for (const mode of ["unavailable", "malformed"] as const) {
      failure = mode;
      expireCache();
      const result = await runFx(["models", "--json"], { env });
      expect(result.code, result.stderr).toBe(0);
      expect(JSON.parse(readFileSync(cachePath, "utf8")).version).toBe("2.0.0");
    }
    rmSync(cachePath);
    const malformed = await runFx(["models", "--json"], { env });
    expect(malformed.code).toBe(1);
    expect(existsSync(cachePath)).toBe(false);
    expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
    failure = "slow";
    const started = Date.now();
    const timedOut = await runFx(["models", "--json"], { env, timeoutMs: 8000 });
    expect(timedOut.code).toBe(1);
    expect(Date.now() - started).toBeLessThan(6500);
    for (const headers of releaseHeaders) {
      for (const name of ["authorization", "cookie", "x-userid", "x-xai-token-auth"]) {
        expect(headers.get(name)).toBeNull();
      }
    }
  } finally {
    grok.stop();
    releases.stop(true);
  }
}, 30_000);

for (const provider of ["codex", "grok"] as const) {
  for (const outcome of ["success", "failure", "cancel"] as const) {
    tmuxTest(`provider preparation keeps input responsive through ${provider} ${outcome}`, async () => {
      home = mkdtempSync(join(tmpdir(), "fx-provider-preparation-"));
      stderrPath = join(home, "stderr.log");
      writeFileSync(stderrPath, "");
      gateway = startFakeGateway([fakeGatewayFinalText("PREPARATION_GATEWAY_RECOVERY")]);
      let entered = 0;
      let release!: () => void;
      const held = new Promise<void>((resolve) => { release = resolve; });
      const modelsResponse = async () => {
        entered++;
        if (entered !== 1) return;
        await held;
        if (outcome === "failure") return new Response("unavailable", { status: 503 });
      };
      chatgptOauth = startFakeChatGptOAuth({ modelsResponse });
      const grok = startFakeGrokOAuth({ modelsResponse });
      try {
        writeSeededChatGptLogin(home, chatgptOauth.accessToken);
        writeSeededGrokLogin(home, grok.initialAccessToken);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(settingsPath, JSON.stringify({ provider: "gateway", models: { gateway: FAKE_GATEWAY_MODEL } }));
        session = await startFx(home, stderrPath, gateway, undefined, join(home, "trace.log"), {
          ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined, FX_SOUND: "0", FX_TRACE_SCOPES: "auth,prompt,input,provider",
        });
        await session.waitForComposer(TIMEOUT);
        await openProviderPicker(session);
        await session.sendLiteral(provider);
        await session.sendKeys("Enter");
        await session.waitForPane(() => entered === 1, 5000);
        await session.sendLiteral("retained café 日本語");
        await session.waitForText("retained café 日本語", 1500);
        await session.resizeWindow(88, 24);
        expect(await session.capturePane()).toContain("retained café 日本語");
        expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
        const direct = provider === "codex" ? chatgptOauth : grok;
        const responsePath = provider === "codex" ? "/chatgpt/responses" : "/v1/responses";
        const responses = () => direct.requests.filter((request) => request.path === responsePath);
        if (outcome === "cancel") {
          await session.sendKeys("C-c");
          await session.waitForText("Provider preparation cancelled.", 1500);
          expect(await session.capturePane()).toContain("retained café 日本語");
          release();
          await Bun.sleep(100);
          expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
          expect(responses()).toHaveLength(0);
          await session.sendKeys("C-u");
          await openProviderPicker(session);
          await session.sendLiteral(provider);
          await session.sendKeys("Enter");
          await session.waitForText(`Switched to ${provider === "codex" ? "Codex" : "Grok"} subscription`, TIMEOUT);
        } else {
          await session.sendKeys("Enter");
          await session.waitForPane(() => readFileSync(join(home!, "trace.log"), "utf8").includes("pending_prompt_adopted"), 3000);
          expect(gateway.requests).toHaveLength(0);
          expect(responses()).toHaveLength(0);
          release();
          if (outcome === "success") {
            await session.waitForText(provider === "codex" ? "CHATGPT_DIRECT_RESPONSE" : "GROK_DIRECT_RESPONSE", TIMEOUT);
            expect(responses()).toHaveLength(1);
            expect(responses()[0]!.body).toContain("retained café 日本語");
            expect(gateway.requests).toHaveLength(0);
            expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe(provider);
          } else {
            await session.waitForText("The target provider catalog could not be validated.", TIMEOUT);
            expect(gateway.requests).toHaveLength(0);
            expect(responses()).toHaveLength(0);
            expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
            await session.sendKeys("Enter");
            await session.waitForText("PREPARATION_GATEWAY_RECOVERY", TIMEOUT);
            expect(gateway.requests).toHaveLength(1);
            expect(JSON.stringify(gateway.requests[0]!.body)).toContain("retained café 日本語");
          }
        }
        const scrollback = await session.captureFullScrollbackEscapes();
        expect(scrollback).not.toContain(chatgptOauth.accessToken);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
        await session.sendText("/quit");
        await session.waitForSessionEnd(3000);
        session = null;
      } finally {
        release();
        grok.stop();
      }
    }, TIMEOUT);
  }
}

tmuxTest("provider preparation does not delay double Ctrl+C shutdown", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-provider-preparation-exit-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  gateway = startFakeGateway([]);
  let entered = false;
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  chatgptOauth = startFakeChatGptOAuth({ modelsResponse: async () => { entered = true; await held; } });
  try {
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    session = await startFx(home, stderrPath, gateway, undefined, undefined, { ...chatgptOauth.env, FX_SOUND: "0" });
    await session.waitForComposer(TIMEOUT);
    await openProviderPicker(session);
    await session.sendLiteral("codex");
    await session.sendKeys("Enter");
    await session.waitForPane(() => entered, 5000);
    await session.sendKeys("C-c");
    await session.sendKeys("C-c");
    await session.waitForSessionEnd(1500);
    session = null;
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally {
    release();
  }
}, TIMEOUT);

for (const outcome of ["cancel", "failure"] as const) {
  tmuxTest(`provider preparation validates Vercel team before saving through ${outcome}`, async () => {
    home = mkdtempSync(join(tmpdir(), "fx-team-preparation-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    let entered = 0;
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    gateway = startFakeGateway([fakeGatewayFinalText("TEAM_PREPARATION_OK")], { models: async () => {
      entered++;
      if (entered === 1) {
        await held;
        if (outcome === "failure") return new Response("unavailable", { status: 503 });
      }
      return [FAKE_GATEWAY_MODEL, "openai/gpt-5.6-sol"].map((id) => ({ id, type: "language", tags: ["tool-use"] }));
    } });
    oauth = startFakeOAuth(ACQUIRED_LOGIN_TOKEN, undefined, 3600, Number.POSITIVE_INFINITY, {
      teams: [{ id: "team_next", slug: "next-team", name: "Next Team" }],
    });
    chatgptOauth = startFakeChatGptOAuth();
    writeSeededFxLogin(home, Date.now() + 3_600_000, oauth.issuerUrl, "team_previous");
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    const settingsPath = join(home, ".fx", "settings.json");
    const authPath = join(home, ".fx", "auth.json");
    writeFileSync(settingsPath, JSON.stringify({ provider: "codex", models: { codex: "gpt-5.6-sol", gateway: "openai/gpt-5.6-sol" } }));
    const beforeAuth = readFileSync(authPath, "utf8");
    try {
      session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, undefined, { ...chatgptOauth.env, FX_MODEL: undefined, FX_SOUND: "0" });
      await session.waitForComposer(TIMEOUT);
      const chooseTeam = async () => {
        await session!.sendKeys("C-u");
        await openProviderPicker(session!);
        await session!.sendLiteral("vercel");
        await session!.sendKeys("Enter");
        await session!.waitForText("oauth", TIMEOUT);
        await session!.sendKeys("Enter");
        await session!.waitForText("next-team", TIMEOUT);
        await session!.sendKeys("Enter");
      };
      await chooseTeam();
      await session.waitForPane(() => entered === 1, 5000);
      await session.sendLiteral("team draft");
      await session.waitForText("team draft", 1500);
      expect(readFileSync(authPath, "utf8")).toBe(beforeAuth);
      if (outcome === "cancel") {
        await session.sendKeys("C-c");
        await session.waitForText("Provider preparation cancelled.", 1500);
        release();
      } else {
        release();
        await session.waitForText("could not be validated for AI Gateway", TIMEOUT);
      }
      expect(readFileSync(authPath, "utf8")).toBe(beforeAuth);
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("codex");
      await chooseTeam();
      await session.waitForText("Changed Vercel team to Next Team", TIMEOUT);
      expect(JSON.parse(readFileSync(authPath, "utf8")).team_id).toBe("team_next");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).provider).toBe("gateway");
      expect(JSON.parse(readFileSync(settingsPath, "utf8")).models.gateway).toBe("openai/gpt-5.6-sol");
      await session.sendText("Use the validated team.");
      await session.waitForText("TEAM_PREPARATION_OK", TIMEOUT);
      expect(gateway.requests).toHaveLength(1);
      expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${LOGIN_TOKEN}`);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      await session.captureFullScrollbackEscapes();
      await session.sendText("/quit");
      await session.waitForSessionEnd(3000);
      session = null;
    } finally { release(); }
  }, TIMEOUT);
}

tmuxTest("provider preparation cancellation stops logout fallback", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-logout-preparation-cancel-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  let entered = false;
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  gateway = startFakeGateway([], { models: async () => {
    entered = true;
    await held;
    return new Response("unavailable", { status: 503 });
  } });
  chatgptOauth = startFakeChatGptOAuth();
  const grok = startFakeGrokOAuth();
  try {
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "codex", models: { codex: "gpt-5.6-sol" } }));
    session = await startFx(home, stderrPath, gateway, undefined, undefined, { ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined, FX_SOUND: "0" });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForPane(() => entered, 5000);
    await session.sendKeys("C-c");
    await session.waitForText("Provider preparation cancelled.", 1500);
    release();
    await Bun.sleep(100);
    expect(grok.requests.filter((request) => request.path === "/v1/models")).toHaveLength(0);
    expect(existsSync(join(home, ".fx", "chatgpt-auth.json"))).toBe(false);
    expect(existsSync(join(home, ".fx", "grok-auth.json"))).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    await session.sendText("/quit");
    await session.waitForSessionEnd(3000);
    session = null;
  } finally { release(); grok.stop(); }
}, TIMEOUT);

tmuxTest("provider recovery continues after a held prompt and failed catalog", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-provider-fallback-prompt-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  let entered = false;
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  gateway = startFakeGateway([], { models: async () => {
    entered = true;
    await held;
    return new Response("unavailable", { status: 503 });
  } });
  chatgptOauth = startFakeChatGptOAuth();
  const grok = startFakeGrokOAuth();
  try {
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    writeSeededGrokLogin(home, grok.initialAccessToken);
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "codex", models: { codex: "gpt-5.6-sol" } }));
    const trace = join(home, "trace.log");
    session = await startFx(home, stderrPath, gateway, undefined, trace, { ...chatgptOauth.env, ...grok.env, FX_MODEL: undefined, FX_SOUND: "0", FX_TRACE_SCOPES: "auth,provider,input,prompt" });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/logout");
    await session.waitForPane(() => entered, 5000);
    await session.sendText("Use the remaining subscription after recovery.");
    await waitForTrace(trace, "pending_prompt_adopted", 3000);
    release();
    await session.waitForText("GROK_DIRECT_RESPONSE", 5000);
    expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe("grok");
    expect(grok.requests.filter((request) => request.path === "/v1/responses")).toHaveLength(1);
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally { release(); grok.stop(); }
}, TIMEOUT);


tmuxTest("provider preparation resumes a held prompt after explicit provider retry", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-preparation-explicit-retry-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  let entered = 0;
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  gateway = startFakeGateway([]);
  chatgptOauth = startFakeChatGptOAuth({ modelsResponse: async () => {
    entered++;
    if (entered === 1) {
      await held;
      return new Response("unavailable", { status: 503 });
    }
  } });
  try {
    writeSeededChatGptLogin(home, chatgptOauth.accessToken);
    const trace = join(home, "trace.log");
    session = await startFx(home, stderrPath, gateway, undefined, trace, { ...chatgptOauth.env, FX_MODEL: undefined, FX_SOUND: "0", FX_TRACE_SCOPES: "auth,provider,input,prompt" });
    await session.waitForComposer(TIMEOUT);
    await openProviderPicker(session);
    await session.sendLiteral("codex");
    await session.sendKeys("Enter");
    await session.waitForPane(() => entered === 1, 5000);
    await session.sendText("Retain this prompt across the explicit provider retry.");
    await waitForTrace(trace, "pending_prompt_adopted", 3000);
    release();
    await session.waitForText("The target provider catalog could not be validated.", TIMEOUT);
    await openProviderPicker(session);
    await session.sendLiteral("codex");
    await session.sendKeys("Enter");
    await session.waitForText("CHATGPT_DIRECT_RESPONSE", 5000);
    const requests = chatgptOauth.requests.filter((request) => request.path === "/chatgpt/responses");
    expect(requests).toHaveLength(1);
    expect(requests[0]!.body).toContain("Retain this prompt across the explicit provider retry.");
    expect(gateway.requests).toHaveLength(0);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  } finally { release(); }
}, TIMEOUT);

tmuxTest("provider preparation completes existing-key recovery for a held prompt", async () => {
  home = mkdtempSync(join(tmpdir(), "fx-preparation-key-recovery-"));
  stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  gateway = startFakeGateway([fakeGatewayFinalText("KEY_RECOVERY_OK")]);
  chatgptOauth = startFakeChatGptOAuth();
  writeSeededChatGptLogin(home, chatgptOauth.accessToken);
  linkSync(join(home, ".fx", "chatgpt-auth.json"), join(home, "auth-alias"));
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "codex", models: { codex: "gpt-5.6-sol" } }));
  const trace = join(home, "trace.log");
  session = await startFx(home, stderrPath, gateway, undefined, trace, { ...chatgptOauth.env, FX_MODEL: undefined, FX_SOUND: "0", FX_TRACE_SCOPES: "auth,provider,input,prompt" });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("Use the Gateway after repair.");
  await waitForTrace(trace, "pending_prompt_awaiting_auth", 5000);
  await openProviderPicker(session);
  await session.sendLiteral("vercel");
  await session.sendKeys("Enter");
  await session.waitForText("api-key", TIMEOUT);
  await session.sendLiteral("api-key");
  await session.sendKeys("Enter");
  await session.waitForText("env", TIMEOUT);
  await session.sendLiteral("env");
  await session.sendKeys("Enter");
  await session.waitForText("KEY_RECOVERY_OK", 5000);
  expect(JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")).provider).toBe("gateway");
  expect(gateway.requests).toHaveLength(1);
  expect(JSON.stringify(gateway.requests[0]!.body)).toContain("Use the Gateway after repair.");
  expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}, TIMEOUT);
