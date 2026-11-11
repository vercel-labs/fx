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
  startFakeGateway,
} from "./tmux-helpers";
import { savedSessionIds } from "./saved-sessions";

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

function writeExpiredSubscriptionLogin(home: string, provider: Subscription, accessToken: string): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json");
  writeFileSync(authPath, JSON.stringify({
    version: 1,
    access_token: accessToken,
    refresh_token: `${provider}-refresh`,
    expires_at_ms: Date.now() - 60_000,
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
