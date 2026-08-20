import { afterEach, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
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

let session: TmuxSession | null = null;
let home: string | null = null;
let stderrPath: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let oauth: ReturnType<typeof startFakeOAuth> | null = null;
let creditsGateway: ReturnType<typeof startFakeCreditsGateway> | null = null;
let catcher: ReturnType<typeof startRequestCatcher> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  oauth?.stop();
  oauth = null;
  creditsGateway?.stop();
  creditsGateway = null;
  catcher?.stop();
  catcher = null;
  if (home) rmSync(home, { recursive: true, force: true });
  home = null;
  stderrPath = null;
});

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
    await session.sendText("/setup");
    const root = await session.waitForPane(
      (pane) =>
        pane.includes("Setup") &&
        pane.includes("Sign in with Vercel") &&
        pane.includes("API key") &&
        pane.includes("Change team") &&
        pane.includes("Switch credential"),
      TIMEOUT,
    );
    expect(root).not.toContain("AI_GATEWAY_API_KEY");
    expect(root).not.toContain("fx login");

    await session.sendKeys("Enter");
    await session.waitForText("Enter reopens browser · Esc cancels", TIMEOUT);
    await session.sendKeys("Escape");
    await session.waitForText("Switch credential", TIMEOUT);

    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const apiKey = await session.waitForText("Paste your AI Gateway API key", TIMEOUT);
    expect(apiKey).toContain("Saves to");
    await session.sendKeys("Escape");
    await session.waitForText("Switch credential", TIMEOUT);

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

tmuxTest(
  "invalid credential reference stays visible and normal auth still works",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-invalid-credential-reference-"));
    stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([fakeGatewayFinalText(ENV_RESPONSE)]);
    const fxDir = join(home, ".fx");
    mkdirSync(fxDir, { recursive: true, mode: 0o700 });
    const settingsPath = join(fxDir, "settings.json");
    const settings = {
      connections: {
        selected: "vercel",
        profiles: [{
          id: "vercel",
          display_name: "Vercel AI Gateway",
          adapter_id: "vercel_ai_gateway",
          endpoint: gateway.chatUrl,
          protocol: "vercel_ai_gateway",
          credential_ref: "invalid_reference",
          remembered_model: FAKE_GATEWAY_MODEL,
          permission_review_model: "openai/gpt-5.4",
        }],
      },
    };
    writeFileSync(settingsPath, JSON.stringify(settings) + "\n", { mode: 0o600 });

    const env = {
      HOME: home,
      AI_GATEWAY_API_KEY: ENV_TOKEN,
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };
    const status = await runFx(["status", "--json"], { env, timeoutMs: TIMEOUT });
    expect(status.code).toBe(0);
    expect(JSON.parse(status.stdout)).toMatchObject({
      auth: "invalid_configuration",
      auth_refreshable: false,
    });
    expect(status.stdout).not.toContain(ENV_TOKEN);

    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=invalid_configuration", TIMEOUT);
    expect(gateway.requests).toHaveLength(0);

    await session.kill();
    settings.connections.profiles[0]!.credential_ref = "automatic";
    writeFileSync(settingsPath, JSON.stringify(settings) + "\n", { mode: 0o600 });
    session = await startFx(home, stderrPath, gateway);
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/status");
    await session.waitForText("auth=AI_GATEWAY_API_KEY", TIMEOUT);
    await session.sendText("use normal auth after fixing the reference");
    await session.waitForText(ENV_RESPONSE, TIMEOUT);
    expect(gateway.requests).toHaveLength(1);
    expect(gateway.requests[0]!.headers.get("authorization")).toBe(`Bearer ${ENV_TOKEN}`);
    expect(await session.captureFullScrollback()).not.toContain(ENV_TOKEN);
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
  for (let index = 0; index < 3; index += 1) {
    await pickerSession.sendKeys("Down");
  }
  await pickerSession.sendKeys("Enter");
  await pickerSession.waitForText("Use this credential", TIMEOUT);
}

async function openSwitchCredential(pickerSession: TmuxSession): Promise<void> {
  await pickerSession.sendText("/setup");
  await pickerSession.waitForText("Switch credential", TIMEOUT);
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
    await session.waitForText("Change team", TIMEOUT);
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
        pane.includes("API key") &&
        pane.includes("Switch credential"),
      TIMEOUT,
    );
    expect(inventory).not.toMatch(/^\s+fx login\s+/m);
    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => !pane.includes("Switch credential"),
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
        pane.includes("Switch credential"),
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
  "initial expired login refresh failure is visible before any model request",
  async () => {
    home = mkdtempSync(join(tmpdir(), "fx-tui-auth-initial-refresh-failure-"));
    stderrPath = join(home, "stderr.log");
    const tracePath = join(home, "trace.log");
    writeFileSync(stderrPath, "");
    gateway = startFakeGateway([]);
    oauth = startFakeOAuth(null);
    writeSeededFxLogin(home, Date.now() - 60_000, oauth.issuerUrl);
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({ credential_source: "fx_login" }) + "\n",
      { mode: 0o600 },
    );

    session = await startFx(home, stderrPath, gateway, oauth.issuerUrl, tracePath);
    await session.waitForComposer(TIMEOUT);
    const prompt = "stop before the initial model request";
    await session.sendText(prompt);
    const failed = await session.waitForPane(
      (pane) =>
        pane.includes(prompt) &&
        pane.includes("fx login credential refresh failed.") &&
        pane.includes("Choose another source below"),
      TIMEOUT,
    );

    expect(gateway.requests).toHaveLength(0);
    expect(gateway.classifierRequests).toHaveLength(0);
    expect(oauth.requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /.well-known/openid-configuration",
      "POST /oauth/token",
    ]);
    const trace = readFileSync(tracePath, "utf8");
    for (const secret of [LOGIN_TOKEN, ENV_TOKEN, "seeded-refresh-token", oauth.providerDetail]) {
      expect(failed).not.toContain(secret);
      expect(trace).not.toContain(secret);
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");

    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
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
        pane.includes("Switch credential"),
      TIMEOUT,
    );
    expect(gateway.requests).toHaveLength(0);

    await session.sendKeys("Escape");
    await session.waitForPane(
      (pane) => pane.includes(blockedPrompt) && !pane.includes("Switch credential"),
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
        pane.includes("Switch credential"),
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
      (pane) => pane.includes(firstPrompt) && !pane.includes("Switch credential"),
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
        pane.includes("Switch credential"),
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
