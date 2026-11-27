import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
  REPO_ROOT,
  runFx,
} from "../evals/eval-helpers";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
if (process.env.FX_REQUIRE_TMUX === "1" && !HAS_TMUX) {
  throw new Error("tmux is required for google-sign-in.test.ts");
}

const tmuxTest = test.skipIf(!HAS_TMUX);
const TIMEOUT = 30_000;
const CLIENT_ID = "test-google-client-id";
const CLIENT_SECRET = "test-google-client-secret";
const REQUIRED_SCOPE = "https://www.googleapis.com/auth/generative-language.peruserquota";

type AuthParams = {
  redirectUri: string;
  state: string;
  nonce: string;
  codeChallenge: string;
  codeChallengeMethod: string;
  code: string;
};

type TokenCheck = {
  grantType: string;
  code: string | null;
  codeVerifier: string | null;
  pkceValid: boolean;
  dpopHeaderPresent: boolean;
  dpopJti: string | null;
  dpopJtiMatchesCodeHash: boolean;
  dpopHtm: string | null;
  dpopHtu: string | null;
};

type RevokeCall = {
  token: string | null;
  dpopHeaderPresent: boolean;
  statusReturned: number;
};

function base64Url(input: Buffer | Uint8Array | string): string {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function sha256Base64Url(value: string): string {
  return base64Url(createHash("sha256").update(value, "utf8").digest());
}

function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const parts = jwt.split(".");
  if (parts.length !== 3) throw new Error(`Expected 3-part JWT, got ${parts.length}`);
  const padded = parts[1]!.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(Buffer.from(padded, "base64").toString("utf8")) as Record<string, unknown>;
}

function buildIdToken(params: {
  aud: string;
  nonce: string;
  sub: string;
  email: string;
}): string {
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const nowS = Math.floor(Date.now() / 1000);
  const payload = base64Url(
    JSON.stringify({
      iss: "https://accounts.google.com",
      aud: params.aud,
      iat: nowS,
      exp: nowS + 3600,
      nonce: params.nonce,
      sub: params.sub,
      email: params.email,
    }),
  );
  return `${header}.${payload}.fake-signature`;
}

function startFakeGoogleOAuth(options: {
  email?: string;
  sub?: string;
  accessDenied?: boolean;
  revokeStatus?: number;
} = {}) {
  let email = options.email ?? "ultra@example.com";
  let sub = options.sub ?? "google-sub-1";
  let accessDenied = options.accessDenied ?? false;
  let revokeStatus = options.revokeStatus ?? 200;
  let codeCounter = 0;

  const authByCode = new Map<string, AuthParams>();
  const tokenChecks: TokenCheck[] = [];
  const revokeCalls: RevokeCall[] = [];

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/o/oauth2/v2/auth") {
        const redirectUri = url.searchParams.get("redirect_uri") ?? "";
        const state = url.searchParams.get("state") ?? "";
        const nonce = url.searchParams.get("nonce") ?? "";
        const codeChallenge = url.searchParams.get("code_challenge") ?? "";
        const codeChallengeMethod = url.searchParams.get("code_challenge_method") ?? "";
        if (!redirectUri || !state) {
          return new Response("missing redirect_uri or state", { status: 400 });
        }
        const target = new URL(redirectUri);
        if (accessDenied) {
          target.searchParams.set("error", "access_denied");
          target.searchParams.set("state", state);
          return Response.redirect(target.toString(), 302);
        }
        codeCounter += 1;
        const code = `4/fake-code-${codeCounter}`;
        authByCode.set(code, {
          redirectUri,
          state,
          nonce,
          codeChallenge,
          codeChallengeMethod,
          code,
        });
        target.searchParams.set("code", code);
        target.searchParams.set("state", state);
        return Response.redirect(target.toString(), 302);
      }

      if (url.pathname === "/token") {
        const form = new URLSearchParams(await request.text());
        const grantType = form.get("grant_type") ?? "";
        const code = form.get("code");
        const codeVerifier = form.get("code_verifier");
        const dpop = request.headers.get("dpop");
        let dpopJti: string | null = null;
        let dpopHtm: string | null = null;
        let dpopHtu: string | null = null;
        if (dpop) {
          const payload = decodeJwtPayload(dpop);
          dpopJti = typeof payload.jti === "string" ? payload.jti : null;
          dpopHtm = typeof payload.htm === "string" ? payload.htm : null;
          dpopHtu = typeof payload.htu === "string" ? payload.htu : null;
        }
        if (grantType === "authorization_code" && code) {
          const auth = authByCode.get(code);
          if (!auth) {
            return Response.json({ error: "invalid_grant" }, { status: 400 });
          }
          const pkceValid =
            auth.codeChallengeMethod === "S256" &&
            codeVerifier !== null &&
            sha256Base64Url(codeVerifier) === auth.codeChallenge;
          const expectedJti = sha256Base64Url(code);
          const dpopJtiMatchesCodeHash = dpopJti === expectedJti;
          tokenChecks.push({
            grantType,
            code,
            codeVerifier,
            pkceValid,
            dpopHeaderPresent: dpop !== null,
            dpopJti,
            dpopJtiMatchesCodeHash,
            dpopHtm,
            dpopHtu,
          });
          if (!pkceValid || !dpopJtiMatchesCodeHash) {
            return Response.json({ error: "invalid_request" }, { status: 400 });
          }
          return Response.json({
            access_token: `ya29.fake-access-${codeCounter}`,
            refresh_token: `1//fake-refresh-${codeCounter}`,
            expires_in: 3599,
            refresh_token_expires_in: 604800,
            token_type: "Bearer",
            scope: `openid email ${REQUIRED_SCOPE}`,
            id_token: buildIdToken({
              aud: CLIENT_ID,
              nonce: auth.nonce,
              sub,
              email,
            }),
          });
        }
        return Response.json({ error: "unsupported_grant_type" }, { status: 400 });
      }

      if (url.pathname === "/revoke") {
        const form = new URLSearchParams(await request.text());
        const dpop = request.headers.get("dpop");
        const statusReturned = revokeStatus;
        revokeCalls.push({
          token: form.get("token"),
          dpopHeaderPresent: dpop !== null,
          statusReturned,
        });
        if (statusReturned >= 400) {
          return Response.json({ error: "server_error" }, { status: statusReturned });
        }
        return new Response("", { status: 200 });
      }

      return new Response("not found", { status: 404 });
    },
  });

  const baseUrl = `http://127.0.0.1:${server.port}`;
  const env: Record<string, string> = {
    FX_TEST_GOOGLE_AUTH_URL: `${baseUrl}/o/oauth2/v2/auth`,
    FX_TEST_GOOGLE_TOKEN_URL: `${baseUrl}/token`,
    FX_TEST_GOOGLE_REVOKE_URL: `${baseUrl}/revoke`,
    FX_TEST_GOOGLE_CLIENT_ID: CLIENT_ID,
    FX_TEST_GOOGLE_CLIENT_SECRET: CLIENT_SECRET,
    FX_NO_OPEN_BROWSER: "1",
    FX_DISABLE_KEYCHAIN: "1",
  };

  return {
    baseUrl,
    env,
    tokenChecks,
    revokeCalls,
    setAccessDenied(value: boolean) {
      accessDenied = value;
    },
    setRevokeStatus(status: number) {
      revokeStatus = status;
    },
    setAccount(nextEmail: string, nextSub: string) {
      email = nextEmail;
      sub = nextSub;
    },
    stop() {
      server.stop(true);
    },
  };
}

function spawnFxLoginGoogle(
  env: Record<string, string | undefined>,
  options: { pipeStdin?: boolean } = {},
) {
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) delete childEnv[k];
    else childEnv[k] = v;
  }
  const proc = nodeSpawn(FX_BIN, ["login", "google"], {
    cwd: REPO_ROOT,
    env: childEnv,
    stdio: [options.pipeStdin ? "pipe" : "ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let resolveUrl: ((url: string) => void) | undefined;
  let rejectUrl: ((err: Error) => void) | undefined;

  const urlPromise = new Promise<string>((resolve, reject) => {
    resolveUrl = resolve;
    rejectUrl = reject;
  });

  const timer = setTimeout(() => {
    proc.kill("SIGTERM");
    rejectUrl?.(new Error(`Timed out waiting for Google authorize URL. stdout=${stdout} stderr=${stderr}`));
  }, TIMEOUT);

  proc.stdout!.on("data", (chunk: Buffer) => {
    stdout += chunk.toString();
    const match = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/o\/oauth2\/v2\/auth\?\S+/);
    if (match && resolveUrl) {
      const cb = resolveUrl;
      resolveUrl = undefined;
      rejectUrl = undefined;
      cb(match[0]);
    }
  });
  proc.stderr!.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  proc.once("error", (err) => {
    clearTimeout(timer);
    rejectUrl?.(err);
  });
  const closePromise = new Promise<{ code: number; stdout: string; stderr: string }>((resolve) => {
    proc.once("close", (code) => {
      clearTimeout(timer);
      if (rejectUrl) {
        rejectUrl(new Error(`fx login google exited (${code}) before printing URL. stdout=${stdout} stderr=${stderr}`));
        resolveUrl = undefined;
        rejectUrl = undefined;
      }
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });

  return { proc, urlPromise, closePromise };
}

const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  while (cleanups.length > 0) {
    await cleanups.pop()!();
  }
});

test("fx login google completes via loopback callback, verifies PKCE and code-hash DPoP jti, and saves google-auth.json", async () => {
  const home = createIsolatedTestHome("fx-google-login-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth({ email: "ultra@example.com", sub: "sub-ultra-1" });
  cleanups.push(() => google.stop());

  const { urlPromise, closePromise } = spawnFxLoginGoogle({
    HOME: home,
    ...google.env,
  });
  const authUrl = await urlPromise;
  const callbackResponse = await fetch(authUrl, { redirect: "follow" });
  expect(callbackResponse.status).toBe(200);

  const result = await closePromise;
  expect(result.code).toBe(0);
  expect(result.stderr).toBe("");
  expect(result.stdout).toContain("Open this URL to sign in with Google:");
  expect(result.stdout).toContain("Paste the full callback URL and press enter");
  expect(result.stdout).toContain("Google AI Pro or Ultra plan connected (ultra@example.com).");
  expect(result.stdout).toContain("https://ai.google.dev/gemini-api/terms#unpaid-services");

  expect(google.tokenChecks).toHaveLength(1);
  expect(google.tokenChecks[0]!.pkceValid).toBe(true);
  expect(google.tokenChecks[0]!.dpopHeaderPresent).toBe(true);
  expect(google.tokenChecks[0]!.dpopJtiMatchesCodeHash).toBe(true);
  expect(google.tokenChecks[0]!.dpopHtm).toBe("POST");
  expect(google.tokenChecks[0]!.dpopHtu).toBe(`${google.baseUrl}/token`);

  const authPath = join(home, ".fx", "google-auth.json");
  expect(existsSync(authPath)).toBe(true);
  const savedAuth = JSON.parse(readFileSync(authPath, "utf8")) as {
    active_account_sub: string;
    accounts: Record<string, { subject: string; email: string; refresh_token: string }>;
  };
  expect(savedAuth.active_account_sub).toBe("sub-ultra-1");
  expect(Object.keys(savedAuth.accounts)).toEqual(["sub-ultra-1"]);
  expect(savedAuth.accounts["sub-ultra-1"]!.email).toBe("ultra@example.com");
  expect(savedAuth.accounts["sub-ultra-1"]!.refresh_token).toBe("1//fake-refresh-1");

  const settings = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8")) as {
    provider: string;
    models: { google: string };
  };
  expect(settings.provider).toBe("google");
  expect(settings.models.google).toBe("gemini-4-hydrogen");
}, TIMEOUT);

test("fx login google on access_denied prints Sign-in was canceled. and keeps an earlier account", async () => {
  const home = createIsolatedTestHome("fx-google-cancel-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth({ email: "existing@example.com", sub: "sub-existing" });
  cleanups.push(() => google.stop());

  const first = spawnFxLoginGoogle({ HOME: home, ...google.env });
  const firstUrl = await first.urlPromise;
  expect((await fetch(firstUrl, { redirect: "follow" })).status).toBe(200);
  expect((await first.closePromise).code).toBe(0);

  const authPath = join(home, ".fx", "google-auth.json");
  const savedBefore = readFileSync(authPath, "utf8");

  google.setAccessDenied(true);
  const second = spawnFxLoginGoogle({ HOME: home, ...google.env });
  const secondUrl = await second.urlPromise;
  await fetch(secondUrl, { redirect: "follow" });

  const result = await second.closePromise;
  expect(result.code).toBe(1);
  expect(result.stderr).toContain("Sign-in was canceled.");
  expect(readFileSync(authPath, "utf8")).toBe(savedBefore);
}, TIMEOUT);

test("fx login google refuses a callback with a mismatched state", async () => {
  const home = createIsolatedTestHome("fx-google-state-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth();
  cleanups.push(() => google.stop());

  const { proc, urlPromise, closePromise } = spawnFxLoginGoogle({
    HOME: home,
    ...google.env,
  });
  const authUrl = await urlPromise;
  const parsedAuth = new URL(authUrl);
  const redirectUri = parsedAuth.searchParams.get("redirect_uri")!;
  const badCallback = new URL(redirectUri);
  badCallback.searchParams.set("code", "4/tampered-code");
  badCallback.searchParams.set("state", "wrong-state-value");

  const badResponse = await fetch(badCallback.toString());
  expect(badResponse.status).toBe(400);

  proc.kill("SIGINT");
  const result = await closePromise;
  expect(result.code).not.toBe(0);
  expect(google.tokenChecks).toHaveLength(0);
  expect(existsSync(join(home, ".fx", "google-auth.json"))).toBe(false);
}, TIMEOUT);

test("fx login google accepts manual paste of the full callback URL on stdin", async () => {
  const home = createIsolatedTestHome("fx-google-manual-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth({ email: "ssh-user@example.com", sub: "sub-ssh-1" });
  cleanups.push(() => google.stop());

  const { proc, urlPromise, closePromise } = spawnFxLoginGoogle(
    { HOME: home, ...google.env },
    { pipeStdin: true },
  );
  const authUrl = await urlPromise;
  const redirectResponse = await fetch(authUrl, { redirect: "manual" });
  expect(redirectResponse.status).toBe(302);
  const callbackUrl = redirectResponse.headers.get("location")!;
  expect(callbackUrl).toContain("http://127.0.0.1:");

  proc.stdin!.write(`${callbackUrl}\n`);
  proc.stdin!.end();

  const result = await closePromise;
  expect(result.code).toBe(0);
  expect(result.stdout).toContain("Google AI Pro or Ultra plan connected (ssh-user@example.com).");
  expect(google.tokenChecks).toHaveLength(1);
  expect(google.tokenChecks[0]!.pkceValid).toBe(true);
  expect(google.tokenChecks[0]!.dpopJtiMatchesCodeHash).toBe(true);
}, TIMEOUT);

test("fx logout google --disconnect posts refresh token to /revoke with no DPoP header and queues failed revokes", async () => {
  const home = createIsolatedTestHome("fx-google-disconnect-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth({ email: "disconnect@example.com", sub: "sub-disconnect" });
  cleanups.push(() => google.stop());

  const login1 = spawnFxLoginGoogle({ HOME: home, ...google.env });
  expect((await fetch(await login1.urlPromise, { redirect: "follow" })).status).toBe(200);
  expect((await login1.closePromise).code).toBe(0);

  const authPath = join(home, ".fx", "google-auth.json");
  expect(existsSync(authPath)).toBe(true);

  const disconnectOk = await runFx(["logout", "google", "--disconnect"], {
    env: { HOME: home, ...google.env },
    timeoutMs: TIMEOUT,
  });
  expect(disconnectOk.code).toBe(0);
  expect(disconnectOk.stdout).toContain("Disconnected your Google Account.");
  expect(existsSync(authPath)).toBe(false);
  expect(google.revokeCalls).toHaveLength(1);
  expect(google.revokeCalls[0]!.token).toBe("1//fake-refresh-1");
  expect(google.revokeCalls[0]!.dpopHeaderPresent).toBe(false);

  const login2 = spawnFxLoginGoogle({ HOME: home, ...google.env });
  expect((await fetch(await login2.urlPromise, { redirect: "follow" })).status).toBe(200);
  expect((await login2.closePromise).code).toBe(0);

  google.setRevokeStatus(503);
  const disconnectQueued = await runFx(["logout", "google", "--disconnect"], {
    env: { HOME: home, ...google.env },
    timeoutMs: TIMEOUT,
  });
  expect(disconnectQueued.code).toBe(0);
  expect(disconnectQueued.stderr).toContain("https://myaccount.google.com/connections");
  expect(existsSync(authPath)).toBe(false);
  const revocationsPath = join(home, ".fx", "google-revocations.json");
  expect(existsSync(revocationsPath)).toBe(true);

  google.setRevokeStatus(200);
  const login3 = spawnFxLoginGoogle({ HOME: home, ...google.env });
  expect((await fetch(await login3.urlPromise, { redirect: "follow" })).status).toBe(200);
  expect((await login3.closePromise).code).toBe(0);
  expect(google.revokeCalls.length).toBeGreaterThanOrEqual(3);
  expect(google.revokeCalls[2]!.token).toBe("1//fake-refresh-2");
  expect(google.revokeCalls[2]!.dpopHeaderPresent).toBe(false);
  expect(existsSync(revocationsPath)).toBe(false);
}, TIMEOUT);

tmuxTest(
  "TUI /provider shows Sign in with Google (AI Pro or Ultra) before and Google AI Pro or Ultra plan with email after sign-in",
  async () => {
    const home = createIsolatedTestHome("fx-google-tui-");
    cleanups.push(() => cleanupIsolatedTestHome(home));
    const stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const gateway = startFakeGateway([]);
    cleanups.push(() => gateway.stop());
    const google = startFakeGoogleOAuth({ email: "tui-ultra@example.com", sub: "sub-tui-1" });
    cleanups.push(() => google.stop());

    const session = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "test-gateway-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_AUTO_UPGRADE: "0",
        ...google.env,
      },
      stderrPath,
      width: 110,
      height: 30,
    });
    cleanups.push(() => session.kill());

    await session.waitForComposer(TIMEOUT);

    await session.sendText("/provider");
    await session.waitForPane(
      (pane) => pane.includes("google · Google (AI Pro or Ultra plan, or Gemini API key)"),
      TIMEOUT,
    );
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");

    const beforePane = await session.waitForPane(
      (pane) =>
        pane.includes("plan    · Sign in with Google (AI Pro or Ultra)") &&
        pane.includes("api-key · Gemini API key"),
      TIMEOUT,
    );
    expect(beforePane.indexOf("plan    · Sign in with Google (AI Pro or Ultra)")).toBeLessThan(
      beforePane.indexOf("api-key · Gemini API key"),
    );

    await session.sendKeys("Enter");
    await session.waitForPane(
      (pane) =>
        pane.includes("Sign in with Google (AI Pro or Ultra)") &&
        pane.includes("Authorize with Google") &&
        pane.includes("Browser didn't return? press tab to paste the callback URL"),
      TIMEOUT,
    );

    const escapes = await session.capturePaneEscapes();
    const prefix = `${google.baseUrl}/o/oauth2/v2/auth?`;
    const urlStart = escapes.indexOf(prefix);
    const urlEnd = escapes.indexOf("\x1b\\", urlStart);
    expect(urlStart).toBeGreaterThanOrEqual(0);
    expect(urlEnd).toBeGreaterThan(urlStart);
    const authUrl = escapes.slice(urlStart, urlEnd);
    const callbackResponse = await fetch(authUrl, { redirect: "follow" });
    expect(callbackResponse.status).toBe(200);

    await session.waitForPane(
      (pane) =>
        pane.includes("Google AI Pro or Ultra plan connected (tui-ultra@example.com).") &&
        pane.includes("Switched to Google with gemini-4-hydrogen."),
      TIMEOUT,
    );
    await session.waitForComposer(TIMEOUT);
    // The terms line links its URL under the host, so a wrapped row never splits it (FXC-602).
    const connectedScrollback = await session.captureFullScrollback();
    expect(connectedScrollback.replace(/\s+/g, " ")).toContain("Unpaid Services Terms: ai.google.dev");
    expect(connectedScrollback).not.toContain("https://ai.google.dev");
    expect(await session.capturePaneEscapes()).toContain("\x1b]8;;https://ai.google.dev/gemini-api/terms#unpaid-services\x1b\\");

    await session.sendText("/provider");
    await session.waitForPane(
      (pane) => pane.includes("google · Google AI Pro or Ultra plan · current"),
      TIMEOUT,
    );
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Down");
    await session.sendKeys("Enter");
    const afterPane = await session.waitForPane(
      (pane) =>
        pane.includes("plan    · Google AI Pro or Ultra plan · tui-ultra@example.com · current") &&
        pane.includes("api-key · Gemini API key") &&
        pane.includes("Sign out on this device: /logout google") &&
        pane.includes("Disconnect Google Account: /logout google --disconnect") &&
        pane.includes("Manage access: https://myaccount.google.com/connections"),
      TIMEOUT,
    );
    expect(afterPane).toContain("plan    · Google AI Pro or Ultra plan · tui-ultra@example.com · current");
    expect(afterPane).toContain("Sign out on this device: /logout google");
    expect(afterPane).toContain("Disconnect Google Account: /logout google --disconnect");
    expect(afterPane).toContain("Manage access: https://myaccount.google.com/connections");
    await session.sendKeys("Escape");
    await session.sendKeys("C-u");
    await session.waitForPane((pane) => !pane.includes("plan    · Google AI Pro or Ultra plan"), TIMEOUT);

    await session.sendText("/model");
    await session.waitForPane(
      (pane) => pane.includes("Using your Google AI Pro or Ultra plan"),
      TIMEOUT,
    );
    await session.sendKeys("Escape");
    await session.waitForPane((pane) => !pane.includes("esc close"), TIMEOUT);

    await session.sendText("/logout google --disconnect");
    await session.waitForText("Disconnected your Google Account.", TIMEOUT);
    expect(existsSync(join(home, ".fx", "google-auth.json"))).toBe(false);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test("fx ask on Google plan route shows daily-limit CLI hints with fx login google --api-key and no upgrade link", async () => {
  const home = createIsolatedTestHome("fx-google-plan-daily-");
  cleanups.push(() => cleanupIsolatedTestHome(home));
  const google = startFakeGoogleOAuth({ email: "daily@example.com", sub: "sub-daily-1" });
  cleanups.push(() => google.stop());

  const geminiServer = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch() {
      return Response.json(
        {
          error: {
            code: "too_many_requests",
            message:
              "You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models.",
            details: [
              {
                "@type": "type.googleapis.com/google.rpc.RetryInfo",
                retryDelay: "19104s",
              },
            ],
          },
        },
        { status: 429 },
      );
    },
  });
  cleanups.push(() => geminiServer.stop(true));

  const login = spawnFxLoginGoogle({ HOME: home, ...google.env });
  expect((await fetch(await login.urlPromise, { redirect: "follow" })).status).toBe(200);
  expect((await login.closePromise).code).toBe(0);

  const result = await runFx(
    ["ask", "--provider", "google", "--no-save", "Trigger plan daily limit"],
    {
      cwd: REPO_ROOT,
      env: {
        HOME: home,
        FX_TEST_GEMINI_BASE_URL: `http://127.0.0.1:${geminiServer.port}`,
        ...google.env,
      },
      timeoutMs: TIMEOUT,
    },
  );

  expect(result.code).not.toBe(0);
  const combined = `${result.stderr}\n${result.stdout}`;
  expect(combined).toContain("Daily limit reached for gemini-4-hydrogen; resets in 5 h 18 min.");
  expect(combined).toContain("Or use a Gemini API key: fx login google --api-key.");
  expect(combined).not.toContain("one.google.com");
  expect(combined.toLowerCase()).not.toContain("upgrade");
}, TIMEOUT);

tmuxTest(
  "TUI daily limit on Google plan route prints one notice, shows daily-limit prompt without retry, and opens /provider google api-key",
  async () => {
    const home = createIsolatedTestHome("fx-google-tui-daily-");
    cleanups.push(() => cleanupIsolatedTestHome(home));
    const stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const gateway = startFakeGateway([]);
    cleanups.push(() => gateway.stop());
    const google = startFakeGoogleOAuth({ email: "tui-daily@example.com", sub: "sub-tui-daily-1" });
    cleanups.push(() => google.stop());

    const geminiServer = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch() {
        return Response.json(
          {
            error: {
              code: "too_many_requests",
              message:
                "You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models.",
              details: [
                {
                  "@type": "type.googleapis.com/google.rpc.RetryInfo",
                  retryDelay: "19104s",
                },
              ],
            },
          },
          { status: 429 },
        );
      },
    });
    cleanups.push(() => geminiServer.stop(true));

    const login = spawnFxLoginGoogle({ HOME: home, ...google.env });
    expect((await fetch(await login.urlPromise, { redirect: "follow" })).status).toBe(200);
    expect((await login.closePromise).code).toBe(0);

    const session = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "test-gateway-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TEST_GEMINI_BASE_URL: `http://127.0.0.1:${geminiServer.port}`,
        FX_AUTO_UPGRADE: "0",
        ...google.env,
      },
      stderrPath,
      width: 110,
      height: 30,
    });
    cleanups.push(() => session.kill());

    await session.waitForComposer(TIMEOUT);
    await session.sendText("Trigger TUI daily limit");
    const pane = await session.waitForPane(
      (value) =>
        value.includes("Daily limit reached for gemini-4-hydrogen. What should fx do?") &&
        value.includes("Use a Gemini API key"),
      TIMEOUT,
    );
    expect(pane).toContain("Switch to another model");
    expect(pane).toContain("Cancel this turn");
    expect(pane).not.toContain("Out of credits");
    expect(pane).not.toContain("I added credits, retry");

    const scrollback = await session.captureFullScrollback();
    const matches = scrollback.match(/! system: HTTP 429:/g) ?? [];
    expect(matches).toHaveLength(1);
    expect(scrollback).toContain("Switch models: /model");
    expect(scrollback).toContain("Use a Gemini API key: /provider google api-key");

    await session.sendKeys("2");
    const keyPane = await session.waitForPane(
      (value) => value.includes("/provider google api-key") && value.includes("enter save"),
      TIMEOUT,
    );
    expect(keyPane).toContain("Gemini API key");
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);

tmuxTest(
  "TUI plan 403 links Google's long upgrade URL under its host and never splits it",
  async () => {
    const home = createIsolatedTestHome("fx-google-tui-upgrade-");
    cleanups.push(() => cleanupIsolatedTestHome(home));
    const stderrPath = join(home, "stderr.log");
    writeFileSync(stderrPath, "");
    const gateway = startFakeGateway([]);
    cleanups.push(() => gateway.stop());
    const google = startFakeGoogleOAuth({ email: "tui-upgrade@example.com", sub: "sub-tui-upgrade-1" });
    cleanups.push(() => google.stop());

    const upgradeUrl =
      "https://one.google.com/settings?expand=upgrade&g1_last_touchpoint=64&g1_landing_page=75&utm_source=ai_studio&utm_campaign=ais_gemini_api_upsell&utm_medium=web";
    const geminiServer = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch() {
        return Response.json(
          {
            error: {
              message: `Using your Google AI plan in third-party apps requires an active Google AI Pro or Google AI Ultra subscription: ${upgradeUrl}`,
              code: "permission_denied",
            },
          },
          { status: 403 },
        );
      },
    });
    cleanups.push(() => geminiServer.stop(true));

    const login = spawnFxLoginGoogle({ HOME: home, ...google.env });
    expect((await fetch(await login.urlPromise, { redirect: "follow" })).status).toBe(200);
    expect((await login.closePromise).code).toBe(0);

    const session = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "test-gateway-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TEST_GEMINI_BASE_URL: `http://127.0.0.1:${geminiServer.port}`,
        FX_AUTO_UPGRADE: "0",
        ...google.env,
      },
      stderrPath,
      width: 80,
      height: 30,
    });
    cleanups.push(() => session.kill());

    await session.waitForComposer(TIMEOUT);
    await session.sendText("Trigger TUI plan upgrade");
    await session.waitForPane((value) => value.includes("Upgrade: one.google.com"), TIMEOUT);

    const scrollback = await session.captureFullScrollback();
    expect(scrollback.replace(/\s+/g, " ")).toContain(
      "Google AI Pro or Google AI Ultra subscription to use your plan in fx. Upgrade: one.google.com",
    );
    expect(scrollback).not.toContain("https://one.google.com");
    for (const row of scrollback.split("\n")) {
      expect(row.trimEnd().endsWith("https://")).toBe(false);
    }
    expect(await session.capturePaneEscapes()).toContain(`\x1b]8;;${upgradeUrl}\x1b\\`);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  },
  60_000,
);
