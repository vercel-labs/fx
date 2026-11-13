import { expect, test } from "bun:test";
import {
  chmodSync,
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
import {
  FAKE_GATEWAY_MODEL,
  TITLE_GENERATION_MARKER,
  fakeGatewayFinalText,
  fakeResponsesTitleDefault,
  startDynamicFakeGateway,
  startFakeGateway,
} from "./tmux-helpers";
import {
  bearer,
  rotateFxLogin,
  signInFxLoginToTeam,
  startFakeIssuer,
  storedFxLoginToken,
  unauthorized,
  writeFxLogin as writeSharedFxLogin,
} from "./fx-login-fakes";
import { logLines, savedSessionIds } from "./saved-sessions";
import {
  authPath,
  barrier,
  refreshTokenFor,
  savedGeneration,
  seededRandom,
  sharedAskAnswer,
  sharedRefresh,
  spawnSharedAsk,
  startSharedLoginWorld,
  type SharedLoginWorld,
  type SharedProvider,
} from "./shared-login-fakes";

const TIMEOUT = 30_000;
const EXPIRED_REFRESH_TOKEN = "expired-refresh-token";
const RETRY_REFRESH_TOKEN = "retry-refresh-token";
const SELECTED_API_KEY = "selected-api-key";
const ISSUER_A_ACCESS_TOKEN = "issuer-a-access-token";

function writeFxLogin(
  home: string,
  issuer = "https://vercel.com",
  expiresAtMs = Date.now() - 60_000,
): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "auth.json");
  writeFileSync(
    authPath,
    JSON.stringify({
      version: 1,
      issuer,
      client_id: "test-client",
      access_token: "expired-access-token",
      refresh_token: "seeded-refresh-token",
      expires_at_ms: expiresAtMs,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
      team_id: "team_1",
      team_slug: "example-team",
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);
}

function startFakeOAuth(
  tokens: string[],
  issuerPath = "",
  beforeTokenResponse?: () => Promise<void>,
  refreshTokens: string[] = [],
) {
  const requests: Array<{
    method: string;
    path: string;
    body: string;
    authorization: string | null;
  }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = await request.text();
      requests.push({
        method: request.method,
        path: url.pathname,
        body,
        authorization: request.headers.get("authorization"),
      });
      const issuer = `http://127.0.0.1:${server.port}${issuerPath}`;
      if (url.pathname === `${issuerPath}/.well-known/openid-configuration`) {
        return Response.json({
          issuer,
          device_authorization_endpoint: `${issuer}/oauth/device`,
          token_endpoint: `${issuer}/oauth/token`,
          revocation_endpoint: `${issuer}/oauth/revoke`,
        });
      }
      if (url.pathname === `${issuerPath}/oauth/token`) {
        await beforeTokenResponse?.();
        const accessToken = tokens.shift();
        if (!accessToken) return new Response("unexpected refresh", { status: 500 });
        return Response.json({
          access_token: accessToken,
          refresh_token: refreshTokens.shift() ?? "rotated-refresh-token",
          expires_in: 3600,
          scope: "openid offline_access use:ai-gateway",
          token_type: "Bearer",
        });
      }
      if (url.pathname === `${issuerPath}/v2/teams`) {
        return Response.json({
          teams: [{ id: "team_1", slug: "vercel-labs", name: "Vercel Labs" }],
        });
      }
      if (url.pathname === `${issuerPath}/oauth/revoke`) {
        return Response.json({ revoked: true });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    issuerUrl: `http://127.0.0.1:${server.port}${issuerPath}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

async function waitForFileText(path: string, text: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(text)) return;
    await Bun.sleep(10);
  }
  throw new Error(`Timed out waiting for ${text} in ${path}`);
}

// Two fx whose login expired together: the second waits while the first is
// still refreshing it, however slowly, and uses the login it saved.
test(
  "a second fx waits for another's slow login refresh and uses its login",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-refresh-slow-holder-e2e-"));
    let markRefreshStarted = () => {};
    const refreshStarted = new Promise<void>((resolve) => {
      markRefreshStarted = resolve;
    });
    let tokenRequestCount = 0;
    // Answered 5 s late: longer than fx used to wait for the lock.
    const oauth = startFakeOAuth([ISSUER_A_ACCESS_TOKEN], "", async () => {
      tokenRequestCount += 1;
      markRefreshStarted();
      await Bun.sleep(5_000);
    });
    writeFxLogin(home, oauth.issuerUrl);
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_ASK_DONE"),
      fakeGatewayFinalText("SECOND_ASK_DONE"),
    ]);
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const first = runFx(["ask", "--json", "--no-save", "first"], { env, timeoutMs: TIMEOUT });
      await refreshStarted;
      const second = runFx(["ask", "--json", "--no-save", "second"], { env, timeoutMs: TIMEOUT });
      const [firstResult, secondResult] = await Promise.all([first, second]);
      expect(firstResult.code, `stdout: ${firstResult.stdout}\nstderr: ${firstResult.stderr}`).toBe(0);
      expect(secondResult.code, `stdout: ${secondResult.stdout}\nstderr: ${secondResult.stderr}`).toBe(0);
      expect(tokenRequestCount).toBe(1);
      expect(gateway.requests).toHaveLength(2);
      for (const request of gateway.requests) {
        expect(request.headers.get("authorization")).toBe(`Bearer ${ISSUER_A_ACCESS_TOKEN}`);
      }
    } finally {
      gateway.stop();
      oauth.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

type Subscription = "codex" | "grok";
const SUBSCRIPTION_ACCOUNT = "acct_refresh_e2e";

function subscriptionAccessToken(provider: Subscription, signature: string): string {
  if (provider === "grok") return `grok-${signature}`;
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: SUBSCRIPTION_ACCOUNT },
  })).toString("base64url");
  return `header.${payload}.${signature}`;
}

function writeExpiredSubscriptionLogin(
  home: string,
  provider: Subscription,
  accessToken: string,
  expiresAtMs = Date.now() - 60_000,
): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: `${provider}-refresh`,
    expires_at_ms: expiresAtMs,
    account_id: SUBSCRIPTION_ACCOUNT,
  }) + "\n", { mode: 0o600 });
  chmodSync(authPath, 0o600);
}

/**
 * Codex's or Grok's sign-in and model endpoints, answering refreshes after
 * `beforeTokenResponse`. `respond`, when given, answers model requests in
 * place of the default reply.
 */
function startFakeSubscription(
  provider: Subscription,
  refreshedAccessToken: string,
  beforeTokenResponse: () => Promise<void>,
  respond?: (request: Request) => Response,
) {
  const tokenRequests: string[] = [];
  /** Each model request's headers. */
  const modelRequests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/models") {
        return Response.json(provider === "codex"
          ? { models: [{ slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 }] }
          : { data: [{ id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [{ id: "grok-4.20", input_modalities: ["text"], output_modalities: ["text"] }] });
      }
      if (path === "/token") {
        tokenRequests.push(path);
        await beforeTokenResponse();
        return Response.json({ access_token: refreshedAccessToken, refresh_token: `${provider}-refresh-next`, expires_in: 3600 });
      }
      if (path === "/userinfo") return Response.json({ sub: SUBSCRIPTION_ACCOUNT });
      const body = await request.text();
      if (body.includes(TITLE_GENERATION_MARKER)) return fakeResponsesTitleDefault();
      modelRequests.push(JSON.stringify([...request.headers.entries()]));
      if (respond) return respond(request);
      return new Response(
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "SUBSCRIPTION_ASK_DONE" })}\n\n` +
          'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
        { headers: { "content-type": "text/event-stream" } },
      );
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  const env: Record<string, string> = provider === "codex"
    ? {
      FX_PROVIDER: "codex",
      FX_MODEL: "gpt-5.4-mini",
      FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${base}/responses`,
      FX_TEST_OPENAI_CODEX_MODELS_URL: `${base}/models`,
      FX_TEST_CHATGPT_TOKEN_URL: `${base}/token`,
    }
    : {
      FX_PROVIDER: "grok",
      FX_MODEL: "grok-4.20",
      FX_TEST_XAI_GROK_RESPONSES_URL: `${base}/responses`,
      FX_TEST_XAI_GROK_MODELS_URL: `${base}/models`,
      FX_TEST_XAI_GROK_MODALITIES_URL: `${base}/modalities`,
      FX_TEST_GROK_TOKEN_URL: `${base}/token`,
      FX_TEST_GROK_USERINFO_URL: `${base}/userinfo`,
    };
  return { tokenRequests, modelRequests, env, stop() { server.stop(true); } };
}

// The Codex and Grok subscriptions refresh under a lock of their own, and a
// second fx waits for it the same way.
for (const provider of ["codex", "grok"] as const) {
  test(
    `a second fx waits for another's slow ${provider} login refresh and uses its login`,
    async () => {
      const home = mkdtempSync(join(tmpdir(), `fx-auth-refresh-slow-${provider}-e2e-`));
      let markRefreshStarted = () => {};
      const refreshStarted = new Promise<void>((resolve) => {
        markRefreshStarted = resolve;
      });
      const stale = subscriptionAccessToken(provider, "stale");
      const fresh = subscriptionAccessToken(provider, "fresh");
      // Answered 5 s late: longer than fx used to wait for the lock.
      const fake = startFakeSubscription(provider, fresh, async () => {
        markRefreshStarted();
        await Bun.sleep(5_000);
      });
      writeExpiredSubscriptionLogin(home, provider, stale);
      // Unused: keeps fx away from the real gateway.
      const gateway = startFakeGateway([]);
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        ...fake.env,
      };

      try {
        const first = runFx(["ask", "--json", "--no-save", "first"], { env, timeoutMs: TIMEOUT });
        await refreshStarted;
        const second = runFx(["ask", "--json", "--no-save", "second"], { env, timeoutMs: TIMEOUT });
        const [firstResult, secondResult] = await Promise.all([first, second]);
        expect(firstResult.code, `stdout: ${firstResult.stdout}\nstderr: ${firstResult.stderr}`).toBe(0);
        expect(secondResult.code, `stdout: ${secondResult.stdout}\nstderr: ${secondResult.stderr}`).toBe(0);
        expect(fake.tokenRequests).toHaveLength(1);
        expect(fake.modelRequests).toHaveLength(2);
        for (const headers of fake.modelRequests) {
          expect(headers).toContain(fresh);
          expect(headers).not.toContain(stale);
        }
      } finally {
        gateway.stop();
        fake.stop();
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
}

// A Codex or Grok subscription's title request rejected with 401 is sent once
// more with the login another fx process stored, as an fx login's is, and
// never refreshes the subscription itself
// (tests/tla/session_title/SessionTitle.tla TitleGivesUpOnlyWhenUnrecoverable).
for (const provider of ["codex", "grok"] as const) {
  test(
    `a ${provider} title the subscription rejects is sent once more with the login another fx stored`,
    async () => {
      const home = mkdtempSync(join(tmpdir(), `fx-auth-refresh-title-${provider}-e2e-`));
      const stale = subscriptionAccessToken(provider, "stale");
      const fresh = subscriptionAccessToken(provider, "fresh");
      const titleAuthorizations: string[] = [];
      let tokenRequests = 0;
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          const path = new URL(request.url).pathname;
          if (path === "/models") {
            return Response.json(provider === "codex"
              ? { models: [{ slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 }] }
              : { data: [{ id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
          }
          if (path === "/modalities") {
            return Response.json({ models: [{ id: "grok-4.20", input_modalities: ["text"], output_modalities: ["text"] }] });
          }
          if (path === "/token") {
            tokenRequests += 1;
            return Response.json({ access_token: fresh, refresh_token: `${provider}-refresh-next`, expires_in: 3600 });
          }
          if (path === "/userinfo") return Response.json({ sub: SUBSCRIPTION_ACCOUNT });
          const body = await request.text();
          const authorization = request.headers.get("authorization") ?? "";
          const text = (delta: string) => new Response(
            `data: ${JSON.stringify({ type: "response.output_text.delta", delta })}\n\n` +
              'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
            { headers: { "content-type": "text/event-stream" } },
          );
          if (body.includes(TITLE_GENERATION_MARKER)) {
            titleAuthorizations.push(authorization);
            if (authorization.includes(stale)) {
              // Another fx refreshed the subscription after this one read it.
              writeExpiredSubscriptionLogin(home, provider, fresh, Date.now() + 60 * 60 * 1000);
              return Response.json({ error: { message: "token expired" } }, { status: 401 });
            }
            return text("Renderer Loop Refactor");
          }
          return text("SUBSCRIPTION_ASK_DONE");
        },
      });
      const base = `http://127.0.0.1:${server.port}`;
      writeExpiredSubscriptionLogin(home, provider, stale, Date.now() + 60 * 60 * 1000);
      // Unused: keeps fx away from the real gateway.
      const gateway = startFakeGateway([]);
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        ...(provider === "codex"
          ? {
            FX_PROVIDER: "codex",
            FX_MODEL: "gpt-5.4-mini",
            FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${base}/responses`,
            FX_TEST_OPENAI_CODEX_MODELS_URL: `${base}/models`,
            FX_TEST_CHATGPT_TOKEN_URL: `${base}/token`,
          }
          : {
            FX_PROVIDER: "grok",
            FX_MODEL: "grok-4.20",
            FX_TEST_XAI_GROK_RESPONSES_URL: `${base}/responses`,
            FX_TEST_XAI_GROK_MODELS_URL: `${base}/models`,
            FX_TEST_XAI_GROK_MODALITIES_URL: `${base}/modalities`,
            FX_TEST_GROK_TOKEN_URL: `${base}/token`,
            FX_TEST_GROK_USERINFO_URL: `${base}/userinfo`,
          }),
      };
      try {
        const result = await runFx(["ask", "refactor the renderer loop to fix the crash"], { env, timeoutMs: TIMEOUT });
        expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
        expect(result.stdout).toContain("SUBSCRIPTION_ASK_DONE");
        expect(titleAuthorizations).toHaveLength(2);
        expect(titleAuthorizations[0]).toContain(stale);
        expect(titleAuthorizations[1]).toContain(fresh);
        expect(tokenRequests).toBe(0);
        const titles = savedSessionIds(home).flatMap((id) =>
          (logLines(home, id) as any[]).filter((line) => line.kind === "set" && line.key === "title").map((line) => line.value)
        );
        expect(titles.at(-1)).toBe("Renderer Loop Refactor");
      } finally {
        gateway.stop();
        server.stop(true);
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
}

// A provider's error can quote the token it refused, and fx shows the error,
// so the token must not come with it.
for (const provider of ["codex", "grok"] as const) {
  test(
    `a ${provider} error that quotes the token fx sent shows without the token`,
    async () => {
      const home = mkdtempSync(join(tmpdir(), `fx-auth-error-mask-${provider}-e2e-`));
      const stale = subscriptionAccessToken(provider, "stale");
      const fresh = subscriptionAccessToken(provider, "fresh");
      const fake = startFakeSubscription(provider, fresh, async () => {}, (request) => {
        const token = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "");
        return Response.json({ error: { message: `token ${token} is not allowed here` } }, { status: 400 });
      });
      writeExpiredSubscriptionLogin(home, provider, stale);
      // Unused: keeps fx away from the real gateway.
      const gateway = startFakeGateway([]);
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        ...fake.env,
      };

      try {
        const result = await runFx(["ask", "--json", "--no-save", "hello"], { env, timeoutMs: TIMEOUT });
        const output = `${result.stdout}\n${result.stderr}`;
        expect(result.code, output).not.toBe(0);
        // fx sent the refreshed token, and the provider quoted it back.
        expect(fake.modelRequests.some((headers) => headers.includes(fresh))).toBe(true);
        expect(output).toContain("is not allowed here");
        expect(output).not.toContain(fresh);
      } finally {
        gateway.stop();
        fake.stop();
        rmSync(home, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
}

test(
  "logout cannot be undone by an in-flight login refresh",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-refresh-logout-race-e2e-"));
    const contentionPath = join(home, ".fx", "auth-lock-contention");
    let releaseRefresh = () => {};
    const refreshMayFinish = new Promise<void>((resolve) => {
      releaseRefresh = resolve;
    });
    let markRefreshStarted = () => {};
    const refreshStarted = new Promise<void>((resolve) => {
      markRefreshStarted = resolve;
    });
    let tokenRequestCount = 0;
    const oauth = startFakeOAuth(
      [EXPIRED_REFRESH_TOKEN],
      "",
      async () => {
        tokenRequestCount += 1;
        markRefreshStarted();
        await refreshMayFinish;
      },
    );
    writeFxLogin(home, oauth.issuerUrl);
    const gateway = startFakeGateway([
      fakeGatewayFinalText("REFRESH_COMPLETED_BEFORE_LOGOUT"),
    ]);
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const ask = runFx(
        ["ask", "--json", "--no-save", "refresh while logout waits"],
        { env, timeoutMs: TIMEOUT },
      );
      await refreshStarted;
      const logout = runFx(["logout"], {
        env: {
          ...env,
          FX_TEST_AUTH_LOCK_CONTENTION: "1",
        },
        timeoutMs: TIMEOUT,
      });
      await waitForFileText(contentionPath, "contended");
      releaseRefresh();

      const [askResult, logoutResult] = await Promise.all([ask, logout]);
      // The ask reads the login again for its turn. It either reads it before
      // the logout deletes it, or after, and then it's signed out: never a
      // store it can't read.
      if (askResult.code !== 0) {
        expect(
          JSON.parse(askResult.stdout).error,
          `stdout: ${askResult.stdout}\nstderr: ${askResult.stderr}`,
        ).toBe("MissingCredentials");
      }
      expect(
        logoutResult.code,
        `stdout: ${logoutResult.stdout}\nstderr: ${logoutResult.stderr}`,
      ).toBe(0);
      expect(logoutResult.stdout).toBe("Signed out of fx.\n");
      expect(tokenRequestCount).toBe(1);
      expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
      const revocations = oauth.requests.filter(
        (request) => request.path === "/oauth/revoke",
      );
      expect(revocations).toHaveLength(2);
      expect(revocations[0].body).toContain("token=rotated-refresh-token");
      expect(revocations[1].body).toContain(
        `token=${EXPIRED_REFRESH_TOKEN}`,
      );
    } finally {
      releaseRefresh();
      gateway.stop();
      oauth.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx ask refreshes an expired login then forces one refresh and retry after 401",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-refresh-e2e-"));
    const oauth = startFakeOAuth(
      [EXPIRED_REFRESH_TOKEN, RETRY_REFRESH_TOKEN],
      "",
      undefined,
      ["first-rotated-refresh-token", "second-rotated-refresh-token"],
    );
    writeFxLogin(home, oauth.issuerUrl);
    const gateway = startFakeGateway([
      new Response(JSON.stringify({ error: { message: "expired" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
      fakeGatewayFinalText("REFRESHED_LOGIN_RESPONSE"),
    ]);

    try {
      const result = await runFx(
        ["ask", "--json", "--no-save", "exercise the refreshed login"],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_TEST_SKIP_ONBOARDING: "1",
            FX_AUTO_UPGRADE: "0",
            FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(
        result.code,
        `stdout: ${result.stdout}\nstderr: ${result.stderr}`,
      ).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain("REFRESHED_LOGIN_RESPONSE");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[0].headers.get("authorization")).toBe(
        `Bearer ${EXPIRED_REFRESH_TOKEN}`,
      );
      expect(gateway.requests[1].headers.get("authorization")).toBe(
        `Bearer ${RETRY_REFRESH_TOKEN}`,
      );
      expect(
        oauth.requests.map((request) => `${request.method} ${request.path}`),
      ).toEqual([
        "GET /.well-known/openid-configuration",
        "POST /oauth/token",
        "GET /.well-known/openid-configuration",
        "POST /oauth/token",
      ]);
      expect(oauth.requests[1].body).toContain("client_id=test-client");
      expect(oauth.requests[1].body).toContain("refresh_token=seeded-refresh-token");
      expect(oauth.requests[3].body).toContain("client_id=test-client");
      expect(oauth.requests[3].body).toContain("refresh_token=first-rotated-refresh-token");

      const persisted = JSON.parse(
        readFileSync(join(home, ".fx", "auth.json"), "utf8"),
      );
      expect(persisted.access_token).toBe(RETRY_REFRESH_TOKEN);
      expect(persisted.refresh_token).toBe("second-rotated-refresh-token");
      expect(result.stdout).not.toContain(EXPIRED_REFRESH_TOKEN);
      expect(result.stdout).not.toContain(RETRY_REFRESH_TOKEN);
      expect(result.stderr).not.toContain(EXPIRED_REFRESH_TOKEN);
      expect(result.stderr).not.toContain(RETRY_REFRESH_TOKEN);
    } finally {
      gateway.stop();
      oauth.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx ask replays a rejected request with the login another fx already renewed, without refreshing",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-renewed-elsewhere-"));
    const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
    writeSharedFxLogin(home, issuer.issuerUrl, "launch-token");
    let mainRequests = 0;
    // Another fx renews the shared login after this one read it, so the
    // gateway rejects the copy this one sends first.
    const gateway = startDynamicFakeGateway(() => {
      mainRequests += 1;
      if (mainRequests > 1) return fakeGatewayFinalText("RENEWED_ELSEWHERE_RESPONSE");
      rotateFxLogin(home, "other-fx-token");
      return unauthorized();
    });

    try {
      const result = await runFx(["ask", "--json", "--no-save", "exercise the shared login"], {
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_DISABLE_KEYCHAIN: "1",
          FX_TEST_SKIP_ONBOARDING: "1",
          FX_AUTO_UPGRADE: "0",
          FX_NO_OPEN_BROWSER: "1",
          FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(JSON.parse(result.stdout).output).toContain("RENEWED_ELSEWHERE_RESPONSE");
      expect(gateway.requests.map((request) => bearer(request.headers))).toEqual(["launch-token", "other-fx-token"]);
      expect(issuer.refreshes).toHaveLength(0);
      expect(storedFxLoginToken(home)).toBe("other-fx-token");
    } finally {
      gateway.stop();
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx ask does not refresh the login another fx signed in to another team when its request is rejected",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-other-team-"));
    const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
    writeSharedFxLogin(home, issuer.issuerUrl, "launch-token");
    let mainRequests = 0;
    // Another fx signs the shared login in to another team, and the gateway
    // rejects the token this one sends.
    const gateway = startDynamicFakeGateway(() => {
      mainRequests += 1;
      if (mainRequests === 1) signInFxLoginToTeam(home, "other-team-token", "team_other");
      return unauthorized();
    });

    try {
      const result = await runFx(["ask", "--json", "--no-save", "exercise the shared login"], {
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_DISABLE_KEYCHAIN: "1",
          FX_TEST_SKIP_ONBOARDING: "1",
          FX_AUTO_UPGRADE: "0",
          FX_NO_OPEN_BROWSER: "1",
          FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).not.toBe(0);
      expect(gateway.requests.map((request) => bearer(request.headers))).toEqual(["launch-token"]);
      expect(issuer.refreshes).toHaveLength(0);
      expect(storedFxLoginToken(home)).toBe("other-team-token");
    } finally {
      gateway.stop();
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "status and doctor report an expired login instead of refreshing it",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-expired-report-e2e-"));
    const oauth = startFakeOAuth([EXPIRED_REFRESH_TOKEN]);
    writeFxLogin(home, oauth.issuerUrl);
    const authPath = join(home, ".fx", "auth.json");
    const seededAuthFile = readFileSync(authPath, "utf8");
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_TEST_OAUTH_ISSUER_URL: oauth.issuerUrl,
    };

    try {
      const status = await runFx(["status", "--json"], { env, timeoutMs: TIMEOUT });
      expect(
        status.code,
        `stdout: ${status.stdout}\nstderr: ${status.stderr}`,
      ).toBe(0);
      const statusJson = JSON.parse(status.stdout);
      expect(statusJson.auth).toBe("fx login");
      expect(statusJson.auth_expired).toBe(true);
      expect(statusJson.auth_refreshable).toBe(true);

      const doctor = await runFx(["doctor", "--json"], { env, timeoutMs: TIMEOUT });
      expect(doctor.code).toBe(0);
      const doctorJson = JSON.parse(doctor.stdout);
      expect(doctorJson.auth).toBe("fx login");
      expect(doctorJson.auth_expired).toBe(true);
      const authCheck = doctorJson.checks.find(
        (check: { name: string }) => check.name === "auth",
      );
      expect(authCheck.status).toBe("warn");
      expect(authCheck.detail).toContain("session expired");

      // A read-only diagnostic must neither contact the issuer nor rewrite the session.
      expect(oauth.requests).toEqual([]);
      expect(readFileSync(authPath, "utf8")).toBe(seededAuthFile);
      expect(status.stdout).not.toContain("expired-access-token");
      expect(doctor.stdout).not.toContain("expired-access-token");
    } finally {
      oauth.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx ask keeps a failed API key selected when login also exists",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-source-failure-e2e-"));
    const tracePath = join(home, "trace.log");
    writeFileSync(tracePath, "");
    writeFxLogin(home);
    const gateway = startFakeGateway([
      new Response(JSON.stringify({
        error: {
          message: `rejected ${SELECTED_API_KEY} while ${EXPIRED_REFRESH_TOKEN} exists`,
        },
      }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    try {
      const result = await runFx(
        ["ask", "--json", "--no-save", "keep the selected API key"],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: SELECTED_API_KEY,
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_TEST_SKIP_ONBOARDING: "1",
            FX_AUTO_UPGRADE: "0",
            FX_TRACE_LOG: tracePath,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        "AI_GATEWAY_API_KEY authentication failed · HTTP 401",
      );
      const output = JSON.parse(result.stdout);
      expect(output.exit_code).toBe(1);
      expect(output.output).toBe(
        "AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
      );
      expect(output.auth_failure).toEqual({
        source: "AI_GATEWAY_API_KEY",
        reason: "http_unauthorized",
        http_status: 401,
      });
      expect(gateway.requests).toHaveLength(1);
      expect(gateway.requests[0].headers.get("authorization")).toBe(
        `Bearer ${SELECTED_API_KEY}`,
      );
      expect(result.stdout).not.toContain(SELECTED_API_KEY);
      expect(result.stdout).not.toContain(EXPIRED_REFRESH_TOKEN);
      expect(result.stderr).not.toContain(SELECTED_API_KEY);
      expect(result.stderr).not.toContain(EXPIRED_REFRESH_TOKEN);
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).not.toContain(SELECTED_API_KEY);
      expect(trace).not.toContain(EXPIRED_REFRESH_TOKEN);
    } finally {
      gateway.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "saved API-key 401 keeps the rejected prompt as a new session, which resume last opens",
  async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-auth-empty-session-e2e-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home);
    mkdirSync(workspace);
    const gateway = startFakeGateway([
      fakeGatewayFinalText("SEED_SESSION_RESPONSE"),
      new Response(JSON.stringify({ error: { message: "rejected" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
      fakeGatewayFinalText("RESUMED_SESSION_RESPONSE"),
    ]);
    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: SELECTED_API_KEY,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const seed = await runFx(
        ["ask", "--json", "--auto", "Persist the seed session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(
        seed.code,
        `stdout: ${seed.stdout}\nstderr: ${seed.stderr}`,
      ).toBe(0);
      expect(seed.stderr).toBe("");
      const seedJson = JSON.parse(seed.stdout);
      expect(seedJson.output).toContain("SEED_SESSION_RESPONSE");
      expect(seedJson.session_id.length).toBeGreaterThan(0);
      const seedSessionId = seedJson.session_id as string;
      expect(savedSessionIds(home)).toEqual([seedSessionId]);

      const rejected = await runFx(
        ["ask", "--json", "--auto", "Reject this new saved session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(rejected.code).toBe(1);
      expect(rejected.stderr).toBe(
        "fx ask: AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
      );
      const rejectedJson = JSON.parse(rejected.stdout);
      expect(rejectedJson).toMatchObject({ exit_code: 1, steps: 0, tool_calls: [] });
      expect(rejectedJson.error).toBeUndefined();
      // The rejected prompt is kept, as any interrupted turn is (D1).
      const rejectedSessionId = rejectedJson.session_id as string;
      expect(rejectedSessionId.length).toBeGreaterThan(0);
      expect(rejectedSessionId).not.toBe(seedSessionId);
      expect(savedSessionIds(home).sort()).toEqual([seedSessionId, rejectedSessionId].sort());
      expect(gateway.requests).toHaveLength(2);

      const sessionsResult = await runFx(
        ["sessions", "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(sessionsResult.code).toBe(0);
      expect(sessionsResult.stderr).toBe("");
      const sessions = JSON.parse(sessionsResult.stdout);
      expect(sessions.sessions.map((session: { id: string }) => session.id)).toEqual([rejectedSessionId, seedSessionId]);
      expect(sessions.sessions[1].history_len).toBe(1);
      expect(gateway.requests).toHaveLength(2);

      const resumed = await runFx(
        ["ask", "--json", "--auto", "--resume", "last", "Continue after the rejected request."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(
        resumed.code,
        `stdout: ${resumed.stdout}\nstderr: ${resumed.stderr}`,
      ).toBe(0);
      expect(resumed.stderr).toBe("");
      const resumedJson = JSON.parse(resumed.stdout);
      expect(resumedJson.session_id).toBe(rejectedSessionId);
      expect(resumedJson.output).toContain("RESUMED_SESSION_RESPONSE");
      expect(gateway.requests).toHaveLength(3);

      const detail = await runFx(
        ["session", "--id", seedSessionId, "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(detail.code).toBe(0);
      expect(detail.stderr).toBe("");
      expect(JSON.parse(detail.stdout).history_len).toBe(1);

      expect(gateway.requests[0].body).toContain("Persist the seed session.");
      expect(gateway.requests[1].body).toContain("Reject this new saved session.");
      expect(gateway.requests[1].body).not.toContain("SEED_SESSION_RESPONSE");
      expect(gateway.requests[2].body).toContain("Continue after the rejected request.");
      expect(gateway.requests[2].body).not.toContain("SEED_SESSION_RESPONSE");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "OAuth sessions keep using their saved issuer when configuration changes",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-saved-issuer-e2e-"));
    const issuerA = startFakeOAuth([ISSUER_A_ACCESS_TOKEN]);
    const issuerB = startFakeOAuth(["issuer-b-access-token"]);
    const gateway = startFakeGateway([]);
    writeFxLogin(home, issuerA.issuerUrl);

    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_TEST_OAUTH_ISSUER_URL: issuerB.issuerUrl,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const teams = await runFx(["teams"], { env, timeoutMs: TIMEOUT });
      expect(
        teams.code,
        `stdout: ${teams.stdout}\nstderr: ${teams.stderr}`,
      ).toBe(0);
      expect(teams.stdout).toBe(
        "Selected Vercel team: Vercel Labs (vercel-labs).\n",
      );
      expect(teams.stderr).toBe("");

      const persisted = JSON.parse(
        readFileSync(join(home, ".fx", "auth.json"), "utf8"),
      );
      expect(persisted).toMatchObject({
        issuer: issuerA.issuerUrl,
        access_token: ISSUER_A_ACCESS_TOKEN,
        refresh_token: "rotated-refresh-token",
        team_id: "team_1",
        team_slug: "vercel-labs",
      });

      const logout = await runFx(["logout"], { env, timeoutMs: TIMEOUT });
      expect(logout.code).toBe(0);
      expect(logout.stdout).toBe("Signed out of fx.\n");
      expect(logout.stderr).toBe("");

      expect(
        issuerA.requests.map((request) => `${request.method} ${request.path}`),
      ).toEqual([
        "GET /.well-known/openid-configuration",
        "POST /oauth/token",
        "GET /v2/teams",
        "GET /.well-known/openid-configuration",
        "POST /oauth/revoke",
        "POST /oauth/revoke",
      ]);
      expect(issuerA.requests[1].body).toContain(
        "refresh_token=seeded-refresh-token",
      );
      expect(issuerA.requests[2].authorization).toBe(
        `Bearer ${ISSUER_A_ACCESS_TOKEN}`,
      );
      expect(issuerA.requests[4].body).toContain(
        "token=rotated-refresh-token",
      );
      expect(issuerA.requests[5].body).toContain(
        `token=${ISSUER_A_ACCESS_TOKEN}`,
      );
      expect(issuerB.requests).toEqual([]);

      for (const output of [
        teams.stdout,
        teams.stderr,
        logout.stdout,
        logout.stderr,
      ]) {
        expect(output).not.toContain(ISSUER_A_ACCESS_TOKEN);
        expect(output).not.toContain("seeded-refresh-token");
        expect(output).not.toContain("rotated-refresh-token");
      }
    } finally {
      gateway.stop();
      issuerA.stop();
      issuerB.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "invalid saved OAuth issuers receive no access or refresh token",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-invalid-issuer-e2e-"));
    const invalidIssuer = startFakeOAuth([], "/tenant");
    writeFxLogin(
      home,
      invalidIssuer.issuerUrl,
      Date.now() + 60 * 60 * 1000,
    );

    try {
      const logout = await runFx(["logout"], {
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_DISABLE_KEYCHAIN: "1",
        },
        timeoutMs: TIMEOUT,
      });

      expect(logout.code).toBe(0);
      expect(logout.stdout).toBe("Signed out of fx.\n");
      expect(logout.stderr).toBe("");
      expect(invalidIssuer.requests).toEqual([]);
      expect(logout.stdout).not.toContain("expired-access-token");
      expect(logout.stdout).not.toContain("seeded-refresh-token");
      expect(logout.stderr).not.toContain("expired-access-token");
      expect(logout.stderr).not.toContain("seeded-refresh-token");
    } finally {
      invalidIssuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

// fx processes that share one saved fx login (tests/e2e/shared-login-fakes.ts).
// The fake issuer rotates the refresh token on every refresh and the gateway
// then takes only the newest access token, so one process's refresh leaves
// the others holding a token the gateway rejects. A 401 rotates the login
// only when the saved token is the one the gateway rejected, or is past its
// refresh deadline; otherwise fx retries with the login another process
// saved (`tests/tla/auth/SharedLoginRefresh.tla` NoRedundantRotation).

const SHARED_TIMEOUT = 60_000;

type SharedHold = (label: string, attempt: number) => Promise<void> | void;

async function inSharedLogin(
  name: string,
  issuer: Parameters<typeof startSharedLoginWorld>[0]["issuer"],
  run: (world: SharedLoginWorld, hooks: { hold?: SharedHold }) => Promise<void>,
  provider: SharedProvider = "fx",
): Promise<void> {
  const home = mkdtempSync(join(tmpdir(), `fx-shared-login-${name}-`));
  const hooks: { hold?: SharedHold } = {};
  const world = startSharedLoginWorld({ home, provider, issuer, hold: (label, attempt) => hooks.hold?.(label, attempt) });
  try {
    await run(world, hooks);
  } finally {
    world.stop();
    rmSync(home, { recursive: true, force: true });
  }
}

function described(result: { code: number | null; stdout: string; stderr: string }): string {
  return `exit ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`;
}

/** The token generations each process sent, or that the gateway accepted. */
function tokensBy(world: SharedLoginWorld, kind: "send" | "accepted"): Record<string, number[]> {
  const by: Record<string, number[]> = {};
  for (const e of world.events) {
    if (kind === "send" && e.event === "send") (by[e.data.p] ??= []).push(e.data.tok);
    if (kind === "accepted" && e.event === "answer" && e.data.ok) (by[e.data.p] ??= []).push(e.data.tok);
  }
  return by;
}

async function waitUntil(what: string, condition: () => boolean, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(10);
  }
}

/**
 * `count` processes holding generation 0, which the gateway no longer takes,
 * all get their 401 at once. Each must exit 0 on generation 1, the one
 * refresh between them.
 */
async function expectOneSharedRefresh(
  name: string,
  count: number,
  opts: { issuerDelayMs?: () => number; answerDelayMs?: () => number; provider?: SharedProvider } = {},
): Promise<void> {
  const provider = opts.provider ?? "fx";
  const allSent = barrier(count);
  await inSharedLogin(
    name,
    { beforeAnswer: async () => { if (opts.issuerDelayMs) await Bun.sleep(opts.issuerDelayMs()); } },
    async (world, hooks) => {
      hooks.hold = async (_label, attempt) => {
        if (attempt !== 0) return;
        await allSent();
        if (opts.answerDelayMs) await Bun.sleep(opts.answerDelayMs());
      };
      world.revoke(0);
      const labels = Array.from({ length: count }, (_, i) => `p${i + 1}`);
      const asks = labels.map((label) => spawnSharedAsk(world, label));
      const results = await Promise.all(asks.map((ask) => ask.done));
      for (const [i, result] of results.entries()) {
        expect(result.code, described(result)).toBe(0);
        expect(JSON.parse(result.stdout).output).toContain(sharedAskAnswer(labels[i]!));
      }
      expect(world.tokenRequests).toEqual([refreshTokenFor(provider, 0)]);
      expect(tokensBy(world, "accepted")).toEqual(Object.fromEntries(labels.map((label) => [label, [1]])));
      expect(savedGeneration(world.home, provider)).toBe(1);
    },
    provider,
  );
}

test(
  "two fx processes that get a 401 together share one refresh of their login",
  () => expectOneSharedRefresh("together", 2),
  SHARED_TIMEOUT,
);

test(
  "an fx whose token another fx replaced uses the login another fx saved after a 401",
  () =>
    inSharedLogin("replaced", {}, async (world, hooks) => {
      hooks.hold = (_label, attempt) => {
        if (attempt === 0) world.replaceOutside();
      };
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).toBe(0);
      expect(world.tokenRequests).toEqual([]);
      expect(tokensBy(world, "send")).toEqual({ p1: [0, 1] });
      expect(tokensBy(world, "accepted")).toEqual({ p1: [1] });
      expect(savedGeneration(world.home)).toBe(1);
    }),
  SHARED_TIMEOUT,
);

// The saved login's refresh deadline is a minute before expires_at_ms
// (src/core/auth/oauth_session.zig expiry_skew_ms). These two put it half a
// minute to either side of now instead of waiting for it.
test(
  "a 401 rotates a login another fx saved once it is past its refresh deadline",
  () =>
    inSharedLogin("past-deadline", {}, async (world, hooks) => {
      hooks.hold = (_label, attempt) => {
        if (attempt === 0) world.replaceOutside(Date.now() + 30_000);
      };
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).toBe(0);
      expect(world.tokenRequests).toEqual([sharedRefresh(1)]);
      expect(tokensBy(world, "accepted")).toEqual({ p1: [2] });
      expect(savedGeneration(world.home)).toBe(2);
    }),
  SHARED_TIMEOUT,
);

test(
  "a 401 uses a login another fx saved just before its refresh deadline",
  () =>
    inSharedLogin("before-deadline", {}, async (world, hooks) => {
      hooks.hold = (_label, attempt) => {
        if (attempt === 0) world.replaceOutside(Date.now() + 90_000);
      };
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).toBe(0);
      expect(world.tokenRequests).toEqual([]);
      expect(tokensBy(world, "accepted")).toEqual({ p1: [1] });
    }),
  SHARED_TIMEOUT,
);

test(
  "a saved login the gateway rejects too ends the ask without another refresh or retry",
  () =>
    inSharedLogin("both-rejected", {}, async (world, hooks) => {
      hooks.hold = (_label, attempt) => {
        if (attempt !== 0) return;
        world.replaceOutside();
        world.revoke(1);
      };
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).not.toBe(0);
      expect(world.tokenRequests).toEqual([]);
      expect(tokensBy(world, "send")).toEqual({ p1: [0, 1] });
      expect(tokensBy(world, "accepted")).toEqual({});
      expect(savedGeneration(world.home)).toBe(1);
    }),
  SHARED_TIMEOUT,
);

test(
  "a 401 after the saved login was signed out refreshes nothing and asks to sign in",
  () =>
    inSharedLogin("signed-out", {}, async (world, hooks) => {
      hooks.hold = (_label, attempt) => {
        if (attempt !== 0) return;
        // Signing out elsewhere deletes the saved login and its tokens stop working.
        world.removeSaved();
        world.revoke(0);
      };
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).not.toBe(0);
      expect(world.tokenRequests).toEqual([]);
      expect(tokensBy(world, "send")).toEqual({ p1: [0] });
      expect(existsSync(authPath(world.home))).toBe(false);
    }),
  SHARED_TIMEOUT,
);

test(
  "a refused refresh of the rejected login retires it",
  () =>
    inSharedLogin("refused", { refuseAll: true }, async (world) => {
      world.revoke(0);
      const result = await spawnSharedAsk(world, "p1").done;
      expect(result.code, described(result)).not.toBe(0);
      expect(world.tokenRequests).toEqual([sharedRefresh(0)]);
      expect(existsSync(authPath(world.home))).toBe(false);
    }),
  SHARED_TIMEOUT,
);

test(
  "a second fx waits for a slow refresh another fx started and uses its login",
  () => expectOneSharedRefresh("slow-issuer", 2, { issuerDelayMs: () => 2_000 }),
  SHARED_TIMEOUT,
);

test(
  "when the first refresh fails, the next fx holding the rejected login refreshes it",
  () =>
    inSharedLogin("issuer-500", { failWith: (index) => (index === 0 ? 500 : null) }, async (world, hooks) => {
      const bothSent = barrier(2);
      hooks.hold = async (_label, attempt) => {
        if (attempt === 0) await bothSent();
      };
      world.revoke(0);
      const results = await Promise.all(["p1", "p2"].map((label) => spawnSharedAsk(world, label).done));
      expect(results.filter((result) => result.code === 0), results.map(described).join("\n")).toHaveLength(1);
      expect(world.tokenRequests).toEqual([sharedRefresh(0), sharedRefresh(0)]);
      expect(savedGeneration(world.home)).toBe(1);
    }),
  SHARED_TIMEOUT,
);

test(
  "an fx killed after it saved a refreshed login leaves it to the next fx, which refreshes nothing",
  () =>
    inSharedLogin("killed-after-save", {}, async (world, hooks) => {
      const bothSent = barrier(2);
      let markKilled = () => {};
      const killed = new Promise<void>((resolve) => {
        markKilled = resolve;
      });
      hooks.hold = async (label, attempt) => {
        if (attempt === 0) {
          await bothSent();
          if (label === "p2") await killed;
        } else if (label === "p1") {
          // p1's retry, sent after it saved the refreshed login, never gets an answer.
          await killed;
          throw new Error("p1 was killed");
        }
      };
      world.revoke(0);
      const p1 = spawnSharedAsk(world, "p1");
      const p2 = spawnSharedAsk(world, "p2");
      await waitUntil("p1's retry", () => world.events.some((e) => e.event === "send" && e.data.p === "p1" && e.data.tok === 1));
      expect(savedGeneration(world.home)).toBe(1);
      p1.kill();
      world.noteKill("p1");
      await p1.done;
      markKilled();
      const result = await p2.done;
      expect(result.code, described(result)).toBe(0);
      expect(world.tokenRequests).toEqual([sharedRefresh(0)]);
      expect(tokensBy(world, "accepted")).toEqual({ p2: [1] });
      expect(savedGeneration(world.home)).toBe(1);
    }),
  SHARED_TIMEOUT,
);

test(
  "an fx killed while its refresh is in flight leaves the saved login whole for the next fx",
  async () => {
    let markKilled = () => {};
    const killed = new Promise<void>((resolve) => {
      markKilled = resolve;
    });
    await inSharedLogin(
      "killed-mid-refresh",
      { reuseGrace: true, beforeAnswer: async (index) => { if (index === 0) await killed; } },
      async (world, hooks) => {
        const bothSent = barrier(2);
        hooks.hold = async (label, attempt) => {
          if (attempt !== 0) return;
          await bothSent();
          if (label === "p2") await killed;
        };
        world.revoke(0);
        const p1 = spawnSharedAsk(world, "p1");
        const p2 = spawnSharedAsk(world, "p2");
        await waitUntil("p1's refresh", () => world.tokenRequests.length === 1);
        p1.kill();
        world.noteKill("p1");
        await p1.done;
        expect(savedGeneration(world.home)).toBe(0);
        markKilled();
        const result = await p2.done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([sharedRefresh(0), sharedRefresh(0)]);
        expect(tokensBy(world, "accepted")).toEqual({ p2: [2] });
        expect(savedGeneration(world.home)).toBe(2);
      },
    );
  },
  SHARED_TIMEOUT,
);

// FX_AUTH_REFRESH_RACE_ROUNDS and FX_AUTH_REFRESH_RACE_SEED replay a run; the
// seed is printed so a failing interleaving can be run again.
test(
  "fx processes that get a 401 together share one refresh however their requests interleave",
  async () => {
    const rounds = Number(process.env.FX_AUTH_REFRESH_RACE_ROUNDS ?? "3");
    const seed = Number(process.env.FX_AUTH_REFRESH_RACE_SEED ?? String(Date.now() % 2_147_483_647));
    console.log(`shared login race: seed=${seed} rounds=${rounds}`);
    const random = seededRandom(seed);
    for (let round = 0; round < rounds; round += 1) {
      await expectOneSharedRefresh(`race-${round}`, 3, {
        answerDelayMs: () => Math.floor(random() * 80),
        issuerDelayMs: () => Math.floor(random() * 150),
      });
    }
  },
  SHARED_TIMEOUT * 4,
);

// FX_AUTH_REFRESH_STRESS sets how many processes share the login.
test(
  "many fx processes that get a 401 together share one refresh of their login",
  async () => {
    const count = Number(process.env.FX_AUTH_REFRESH_STRESS ?? "8");
    const started = Date.now();
    await expectOneSharedRefresh(`stress-${count}`, count);
    console.log(`shared login stress: ${count} processes in ${Date.now() - started} ms`);
  },
  SHARED_TIMEOUT * 4,
);

// The same rules for a Codex or Grok subscription login, which fx refreshes
// at OpenAI or xAI under its own lock.
for (const provider of ["codex", "grok"] as const) {
  test(
    `two fx processes on one ${provider} login that get a 401 together share one refresh`,
    () => expectOneSharedRefresh(`${provider}-together`, 2, { provider }),
    SHARED_TIMEOUT,
  );

  test(
    `a ${provider} fx whose token another fx replaced uses the subscription login another fx saved after a 401`,
    () =>
      inSharedLogin(`${provider}-replaced`, {}, async (world, hooks) => {
        hooks.hold = (_label, attempt) => {
          if (attempt === 0) world.replaceOutside();
        };
        const result = await spawnSharedAsk(world, "p1").done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([]);
        expect(tokensBy(world, "send")).toEqual({ p1: [0, 1] });
        expect(tokensBy(world, "accepted")).toEqual({ p1: [1] });
        expect(savedGeneration(world.home, provider)).toBe(1);
      }, provider),
    SHARED_TIMEOUT,
  );

  // A subscription login's refresh deadline is also a minute before
  // expires_at_ms (src/core/auth/subscription_session.zig expiry_skew_ms).
  test(
    `a ${provider} 401 rotates a login another fx saved once it is past its refresh deadline`,
    () =>
      inSharedLogin(`${provider}-past-deadline`, {}, async (world, hooks) => {
        hooks.hold = (_label, attempt) => {
          if (attempt === 0) world.replaceOutside(Date.now() + 30_000);
        };
        const result = await spawnSharedAsk(world, "p1").done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([refreshTokenFor(provider, 1)]);
        expect(tokensBy(world, "accepted")).toEqual({ p1: [2] });
        expect(savedGeneration(world.home, provider)).toBe(2);
      }, provider),
    SHARED_TIMEOUT,
  );

  test(
    `a ${provider} 401 uses a login another fx saved just before its refresh deadline`,
    () =>
      inSharedLogin(`${provider}-before-deadline`, {}, async (world, hooks) => {
        hooks.hold = (_label, attempt) => {
          if (attempt === 0) world.replaceOutside(Date.now() + 90_000);
        };
        const result = await spawnSharedAsk(world, "p1").done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([]);
        expect(tokensBy(world, "accepted")).toEqual({ p1: [1] });
      }, provider),
    SHARED_TIMEOUT,
  );

  test(
    `a lone ${provider} fx whose saved token is the rejected one refreshes it once after a 401`,
    () =>
      inSharedLogin(`${provider}-lone`, {}, async (world) => {
        world.revoke(0);
        const result = await spawnSharedAsk(world, "p1").done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([refreshTokenFor(provider, 0)]);
        expect(tokensBy(world, "send")).toEqual({ p1: [0, 1] });
        expect(tokensBy(world, "accepted")).toEqual({ p1: [1] });
        expect(savedGeneration(world.home, provider)).toBe(1);
      }, provider),
    SHARED_TIMEOUT,
  );

  test(
    `a refused ${provider} refresh of the rejected login retires it`,
    () =>
      inSharedLogin(`${provider}-refused`, { refuseAll: true }, async (world) => {
        world.revoke(0);
        const result = await spawnSharedAsk(world, "p1").done;
        expect(result.code, described(result)).not.toBe(0);
        expect(world.tokenRequests).toEqual([refreshTokenFor(provider, 0)]);
        expect(existsSync(authPath(world.home, provider))).toBe(false);
      }, provider),
    SHARED_TIMEOUT,
  );

  test(
    `a ${provider} fx killed after it saved a refreshed login leaves it to the next fx, which refreshes nothing`,
    () =>
      inSharedLogin(`${provider}-killed-after-save`, {}, async (world, hooks) => {
        const bothSent = barrier(2);
        let markKilled = () => {};
        const killed = new Promise<void>((resolve) => {
          markKilled = resolve;
        });
        hooks.hold = async (label, attempt) => {
          if (attempt === 0) {
            await bothSent();
            if (label === "p2") await killed;
          } else if (label === "p1") {
            await killed;
            throw new Error("p1 was killed");
          }
        };
        world.revoke(0);
        const p1 = spawnSharedAsk(world, "p1");
        const p2 = spawnSharedAsk(world, "p2");
        await waitUntil("p1's retry", () => world.events.some((e) => e.event === "send" && e.data.p === "p1" && e.data.tok === 1));
        expect(savedGeneration(world.home, provider)).toBe(1);
        p1.kill();
        world.noteKill("p1");
        await p1.done;
        markKilled();
        const result = await p2.done;
        expect(result.code, described(result)).toBe(0);
        expect(world.tokenRequests).toEqual([refreshTokenFor(provider, 0)]);
        expect(tokensBy(world, "accepted")).toEqual({ p2: [1] });
      }, provider),
    SHARED_TIMEOUT,
  );

  test(
    `${provider} fx processes that get a 401 together share one refresh however their requests interleave`,
    async () => {
      const rounds = Number(process.env.FX_AUTH_REFRESH_RACE_ROUNDS ?? "2");
      const seed = Number(process.env.FX_AUTH_REFRESH_RACE_SEED ?? String(Date.now() % 2_147_483_647));
      console.log(`shared ${provider} login race: seed=${seed} rounds=${rounds}`);
      const random = seededRandom(seed);
      for (let round = 0; round < rounds; round += 1) {
        await expectOneSharedRefresh(`${provider}-race-${round}`, 3, {
          provider,
          answerDelayMs: () => Math.floor(random() * 80),
          issuerDelayMs: () => Math.floor(random() * 150),
        });
      }
    },
    SHARED_TIMEOUT * 4,
  );

  test(
    `many fx processes on one ${provider} login that get a 401 together share one refresh`,
    async () => {
      const count = Number(process.env.FX_AUTH_REFRESH_STRESS ?? "6");
      const started = Date.now();
      await expectOneSharedRefresh(`${provider}-stress-${count}`, count, { provider });
      console.log(`shared ${provider} login stress: ${count} processes in ${Date.now() - started} ms`);
    },
    SHARED_TIMEOUT * 4,
  );
}

test(
  "a Codex refresh that keeps its refresh token still lets the next fx use the saved login",
  () =>
    inSharedLogin("codex-kept-refresh", { keepRefreshToken: true }, async (world, hooks) => {
      const bothSent = barrier(2);
      hooks.hold = async (_label, attempt) => {
        if (attempt === 0) await bothSent();
      };
      world.revoke(0);
      const results = await Promise.all(["p1", "p2"].map((label) => spawnSharedAsk(world, label).done));
      for (const result of results) expect(result.code, described(result)).toBe(0);
      expect(world.tokenRequests).toEqual([refreshTokenFor("codex", 0)]);
      expect(tokensBy(world, "accepted")).toEqual({ p1: [1], p2: [1] });
      expect(savedGeneration(world.home, "codex")).toBe(1);
    }, "codex"),
  SHARED_TIMEOUT,
);
