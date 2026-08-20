import { expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

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
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);
}

function startFakeOAuth(
  tokens: string[],
  issuerPath = "",
  beforeTokenResponse?: () => Promise<void>,
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
          refresh_token: "rotated-refresh-token",
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

function sessionIdsFromHome(home: string): string[] {
  return readdirSync(join(home, ".fx", "sessions"), {
    withFileTypes: true,
  })
    .filter((entry) => entry.isDirectory() && entry.name !== "latest")
    .map((entry) => entry.name)
    .sort();
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
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
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
          FX_E2E_AUTH_LOCK_CONTENTION: "1",
        },
        timeoutMs: TIMEOUT,
      });
      await waitForFileText(contentionPath, "contended");
      releaseRefresh();

      const [askResult, logoutResult] = await Promise.all([ask, logout]);
      expect(
        askResult.code,
        `stdout: ${askResult.stdout}\nstderr: ${askResult.stderr}`,
      ).toBe(0);
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
    const oauth = startFakeOAuth([EXPIRED_REFRESH_TOKEN, RETRY_REFRESH_TOKEN]);
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
            FX_SKIP_ONBOARDING: "1",
            FX_AUTO_UPGRADE: "0",
            FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
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
      expect(oauth.requests[3].body).toContain("refresh_token=rotated-refresh-token");

      const persisted = JSON.parse(
        readFileSync(join(home, ".fx", "auth.json"), "utf8"),
      );
      expect(persisted.access_token).toBe(RETRY_REFRESH_TOKEN);
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
  "fx ask stops after a normalized forced-refresh failure",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-auth-forced-refresh-failure-e2e-"));
    const tracePath = join(home, "trace.log");
    writeFileSync(tracePath, "");
    const oauth = startFakeOAuth([EXPIRED_REFRESH_TOKEN]);
    writeFxLogin(home, oauth.issuerUrl);
    const gateway = startFakeGateway([
      new Response(JSON.stringify({ error: { message: "expired" } }), {
        status: 401,
        headers: { "content-type": "application/json" },
      }),
    ]);

    try {
      const result = await runFx(
        ["ask", "--json", "--no-save", "stop after the failed forced refresh"],
        {
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_AUTO_UPGRADE: "0",
            FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "gateway",
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(1);
      expect(gateway.requests).toHaveLength(1);
      expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
        "GET /.well-known/openid-configuration",
        "POST /oauth/token",
        "GET /.well-known/openid-configuration",
        "POST /oauth/token",
      ]);
      const trace = readFileSync(tracePath, "utf8");
      const refreshFailure = trace.split("\n").find((line) =>
        line.includes("event=credential_refresh_failed ")
      );
      expect(refreshFailure).toContain("source=fx_login mode=force err=CredentialRefreshFailed");
      for (const secretValue of [EXPIRED_REFRESH_TOKEN, "seeded-refresh-token"]) {
        expect(result.stdout).not.toContain(secretValue);
        expect(result.stderr).not.toContain(secretValue);
        expect(trace).not.toContain(secretValue);
      }
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
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_OAUTH_ISSUER_URL: oauth.issuerUrl,
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
            FX_SKIP_ONBOARDING: "1",
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
  "saved API-key 401 discards only the new empty session and preserves resume last",
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
      FX_SKIP_ONBOARDING: "1",
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
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);

      const rejected = await runFx(
        ["ask", "--json", "--auto", "Reject this new saved session."],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(rejected.code).toBe(1);
      expect(rejected.stderr).toBe(
        "fx ask: AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
      );
      const rejectedJson = JSON.parse(rejected.stdout);
      expect(rejectedJson).toMatchObject({
        exit_code: 1,
        session_id: "",
        steps: 0,
        tool_calls: [],
      });
      expect(rejectedJson.error).toBeUndefined();
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);
      expect(gateway.requests).toHaveLength(2);

      const sessionsResult = await runFx(
        ["sessions", "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(sessionsResult.code).toBe(0);
      expect(sessionsResult.stderr).toBe("");
      const sessions = JSON.parse(sessionsResult.stdout);
      expect(sessions.count).toBe(1);
      expect(sessions.sessions).toHaveLength(1);
      expect(sessions.sessions[0].id).toBe(seedSessionId);
      expect(sessions.sessions[0].history_len).toBe(1);
      expect(gateway.requests).toHaveLength(2);

      const resumed = await runFx(
        [
          "ask",
          "--json",
          "--auto",
          "--resume",
          "last",
          "Resume the seed session.",
        ],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(
        resumed.code,
        `stdout: ${resumed.stdout}\nstderr: ${resumed.stderr}`,
      ).toBe(0);
      expect(resumed.stderr).toBe("");
      const resumedJson = JSON.parse(resumed.stdout);
      expect(resumedJson.session_id).toBe(seedSessionId);
      expect(resumedJson.output).toContain("RESUMED_SESSION_RESPONSE");
      expect(sessionIdsFromHome(home)).toEqual([seedSessionId]);
      expect(gateway.requests).toHaveLength(3);

      const detail = await runFx(
        ["session", "--id", seedSessionId, "--json"],
        { cwd: workspace, env, timeoutMs: TIMEOUT },
      );
      expect(detail.code).toBe(0);
      expect(detail.stderr).toBe("");
      expect(JSON.parse(detail.stdout).history_len).toBe(2);

      expect(gateway.requests[0].body).toContain("Persist the seed session.");
      expect(gateway.requests[1].body).toContain("Reject this new saved session.");
      expect(gateway.requests[1].body).not.toContain("SEED_SESSION_RESPONSE");
      expect(gateway.requests[2].body).toContain("SEED_SESSION_RESPONSE");
      expect(gateway.requests[2].body).toContain("Resume the seed session.");
      expect(gateway.requests[2].body).not.toContain("Reject this new saved session.");
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
    writeFxLogin(home, issuerA.issuerUrl);

    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_E2E_OAUTH_ISSUER_URL: issuerB.issuerUrl,
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
