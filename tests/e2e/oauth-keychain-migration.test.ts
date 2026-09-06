import { expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const OAUTH_SERVICE = "FX_OAUTH_SESSION_V1";
const TEST_ACCOUNT_PREFIX = "fx-e2e-oauth-";
const activeCleanups = new Set<() => void>();
const KEYCHAIN_PROBE_SCRIPT = `
ObjC.import("Security");
ObjC.import("Foundation");
const object = (value) => ObjC.castRefToObject(value);
function run(argv) {
  const query = $.NSMutableDictionary.alloc.init;
  query.setObjectForKey(object($.kSecClassGenericPassword), object($.kSecClass));
  query.setObjectForKey($(argv[0]), object($.kSecAttrAccount));
  query.setObjectForKey($(argv[1]), object($.kSecAttrService));
  query.setObjectForKey($.NSNumber.numberWithBool(true), object($.kSecReturnData));
  query.setObjectForKey(object($.kSecMatchLimitOne), object($.kSecMatchLimit));
  const result = Ref();
  const status = $.SecItemCopyMatching(query, result);
  if (status !== 0) throw new Error("keychain status=" + status);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(
    ObjC.castRefToObject(result[0]),
  );
}
`;

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    for (const cleanup of activeCleanups) {
      try {
        cleanup();
      } catch {}
    }
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
  });
}

function isolatedAccount(): string {
  const account = `${TEST_ACCOUNT_PREFIX}${process.pid}-${randomUUID()}`;
  if (!account.startsWith(TEST_ACCOUNT_PREFIX) || account.length > 200) {
    throw new Error("failed to establish an isolated OAuth Keychain account");
  }
  return account;
}

function deleteKeychainItem(account: string): void {
  if (!account.startsWith(TEST_ACCOUNT_PREFIX)) {
    throw new Error("refusing to delete a non-test OAuth Keychain account");
  }
  const result = spawnSync(
    "/usr/bin/security",
    ["delete-generic-password", "-a", account, "-s", OAUTH_SERVICE],
    { encoding: "utf8" },
  );
  if (result.status === 0 || result.stderr.includes("could not be found")) return;
  throw new Error(`isolated OAuth Keychain cleanup failed: ${result.stderr.trim()}`);
}

function loadKeychainItem(account: string, home: string): string | null {
  if (!account.startsWith(TEST_ACCOUNT_PREFIX)) {
    throw new Error("refusing to read a non-test OAuth Keychain account");
  }
  const result = spawnSync(
    "/usr/bin/osascript",
    ["-l", "JavaScript", "-e", KEYCHAIN_PROBE_SCRIPT, account, OAUTH_SERVICE],
    {
      encoding: "utf8",
      env: { ...process.env, HOME: home, USER: account },
    },
  );
  if (result.status === 0) return result.stdout.trim();
  if (result.stderr.includes("keychain status=-25300")) return null;
  throw new Error(`isolated OAuth Keychain lookup failed: ${result.stderr.trim()}`);
}

function productionMetadata(): string | null {
  const result = spawnSync(
    "/usr/bin/security",
    ["find-generic-password", "-a", userInfo().username, "-s", OAUTH_SERVICE],
    { encoding: "utf8" },
  );
  if (result.status === 0) return `${result.stdout}\n${result.stderr}`;
  if (result.stderr.includes("could not be found")) return null;
  throw new Error(`production OAuth Keychain metadata lookup failed: ${result.stderr.trim()}`);
}

function startOAuthIssuer() {
  const requests: Array<{ method: string; path: string }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      requests.push({ method: request.method, path: url.pathname });
      const issuer = `http://127.0.0.1:${server.port}`;
      if (url.pathname === "/.well-known/openid-configuration") {
        return Response.json({
          issuer,
          device_authorization_endpoint: `${issuer}/oauth/device`,
          token_endpoint: `${issuer}/oauth/token`,
          revocation_endpoint: `${issuer}/oauth/revoke`,
        });
      }
      if (url.pathname === "/oauth/token") {
        return Response.json({
          access_token: "keychain-refreshed-access",
          refresh_token: "keychain-rotated-refresh",
          expires_in: 3600,
          scope: "openid offline_access",
          token_type: "Bearer",
        });
      }
      if (url.pathname === "/oauth/revoke") return Response.json({ revoked: true });
      return new Response("not found", { status: 404 });
    },
  });
  return {
    issuer: `http://127.0.0.1:${server.port}`,
    requests,
    stop: () => server.stop(true),
  };
}

function writeLogin(home: string, issuer: string, tokenSuffix: string): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, "auth.json");
  writeFileSync(
    authPath,
    JSON.stringify({
      version: 1,
      issuer,
      client_id: "keychain-e2e-client",
      access_token: `keychain-access-${tokenSuffix}`,
      refresh_token: `keychain-refresh-${tokenSuffix}`,
      expires_at_ms: Date.now() - 60_000,
      scope: "openid offline_access",
      token_type: "Bearer",
      team_id: "team_keychain_e2e",
      team_slug: "example-team",
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);
}

function attachSystemKeychain(home: string): void {
  mkdirSync(join(home, "Library"), { recursive: true });
  symlinkSync(
    join(homedir(), "Library", "Keychains"),
    join(home, "Library", "Keychains"),
    "dir",
  );
}

function keychainEnv(home: string, account: string, issuer: string) {
  if (!account.startsWith(TEST_ACCOUNT_PREFIX)) {
    throw new Error("OAuth Keychain E2E requires a unique test USER");
  }
  return {
    HOME: home,
    USER: account,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: undefined,
    FX_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_OAUTH_ISSUER_URL: issuer,
    FX_TRACE_LOG: join(home, "oauth-keychain-trace.log"),
    FX_TRACE_SCOPES: "auth,keychain",
  };
}

const keychainTest = test.skipIf(process.platform !== "darwin");

keychainTest(
  "Vercel sign-in checks a read-only legacy file before OAuth with Keychain enabled",
  async () => {
    const account = isolatedAccount();
    const home = mkdtempSync(join(tmpdir(), "fx-oauth-keychain-readonly-"));
    attachSystemKeychain(home);
    const issuer = startOAuthIssuer();
    const cleanup = () => deleteKeychainItem(account);
    activeCleanups.add(cleanup);
    cleanup();
    writeLogin(home, issuer.issuer, account);
    const path = join(home, ".fx", "auth.json");
    const original = readFileSync(path, "utf8");
    chmodSync(path, 0o400);
    try {
      const result = await runFx(["login"], {
        env: { ...keychainEnv(home, account, issuer.issuer), FX_NO_OPEN_BROWSER: "1", FX_SOUND: "0" },
        timeoutMs: 3000,
      });
      expect(result.timedOut).toBe(false);
      expect(result.code).toBe(1);
      expect(result.stderr).toContain("Saved credential storage is unavailable");
      expect(issuer.requests).toHaveLength(0);
      expect(readFileSync(path, "utf8")).toBe(original);
    } finally {
      cleanup();
      activeCleanups.delete(cleanup);
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

keychainTest(
  "OAuth file migration survives restart and logout in an isolated Keychain account",
  async () => {
    const account = isolatedAccount();
    const before = productionMetadata();
    const home = mkdtempSync(join(tmpdir(), "fx-oauth-keychain-migration-"));
    attachSystemKeychain(home);
    const issuer = startOAuthIssuer();
    const gateway = startFakeGateway([
      fakeGatewayFinalText("Keychain refresh complete"),
    ]);
    const cleanup = () => deleteKeychainItem(account);
    activeCleanups.add(cleanup);
    cleanup();
    writeLogin(home, issuer.issuer, account);
    const env = {
      ...keychainEnv(home, account, issuer.issuer),
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    };

    try {
      const first = await runFx(["status", "--json"], { env, timeoutMs: TIMEOUT });
      expect(first.code, `stdout: ${first.stdout}\nstderr: ${first.stderr}`).toBe(0);
      expect(JSON.parse(first.stdout).auth).toBe("fx login");
      expect(
        existsSync(join(home, ".fx", "auth.json")),
        readFileSync(join(home, "oauth-keychain-trace.log"), "utf8"),
      ).toBe(false);

      const stored = loadKeychainItem(account, home);
      expect(stored).not.toBeNull();
      expect(JSON.parse(stored!).access_token).toBe(`keychain-access-${account}`);

      const refreshed = await runFx(
        ["ask", "--json", "--no-save", "Refresh the saved login."],
        { env, timeoutMs: TIMEOUT },
      );
      expect(
        refreshed.code,
        `stdout: ${refreshed.stdout}\nstderr: ${refreshed.stderr}`,
      ).toBe(0);
      expect(JSON.parse(refreshed.stdout).output).toContain(
        "Keychain refresh complete",
      );
      expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
      expect(JSON.parse(loadKeychainItem(account, home)!).access_token).toBe(
        "keychain-refreshed-access",
      );
      expect(
        issuer.requests.filter((request) => request.path === "/oauth/token"),
      ).toHaveLength(1);

      rmSync(join(home, ".fx"), { recursive: true, force: true });
      const restarted = await runFx(["status", "--json"], { env, timeoutMs: TIMEOUT });
      expect(restarted.code).toBe(0);
      expect(JSON.parse(restarted.stdout).auth).toBe("fx login");
      expect(existsSync(join(home, ".fx"))).toBe(false);

      const logout = await runFx(["logout"], { env, timeoutMs: TIMEOUT });
      expect(logout.code, `stdout: ${logout.stdout}\nstderr: ${logout.stderr}`).toBe(0);
      expect(logout.stdout).toBe("Signed out of fx.\n");
      expect(loadKeychainItem(account, home)).toBeNull();
      expect(issuer.requests.filter((request) => request.path === "/oauth/revoke")).toHaveLength(2);
    } finally {
      cleanup();
      activeCleanups.delete(cleanup);
      gateway.stop();
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }

    expect(productionMetadata()).toBe(before);
  },
  TIMEOUT,
);

keychainTest(
  "OAuth Keychain cleanup survives a failure after migration",
  async () => {
    const account = isolatedAccount();
    const before = productionMetadata();
    const home = mkdtempSync(join(tmpdir(), "fx-oauth-keychain-failure-"));
    attachSystemKeychain(home);
    const issuer = startOAuthIssuer();
    const cleanup = () => deleteKeychainItem(account);
    activeCleanups.add(cleanup);
    cleanup();
    writeLogin(home, issuer.issuer, account);

    let injectedFailureObserved = false;
    try {
      const status = await runFx(["status", "--json"], {
        env: keychainEnv(home, account, issuer.issuer),
        timeoutMs: TIMEOUT,
      });
      expect(status.code).toBe(0);
      expect(loadKeychainItem(account, home)).not.toBeNull();
      throw new Error("injected failure after OAuth Keychain seeding");
    } catch (error) {
      expect((error as Error).message).toBe("injected failure after OAuth Keychain seeding");
      injectedFailureObserved = true;
    } finally {
      cleanup();
      activeCleanups.delete(cleanup);
      issuer.stop();
    }

    try {
      expect(injectedFailureObserved).toBe(true);
      expect(loadKeychainItem(account, home)).toBeNull();
      expect(productionMetadata()).toBe(before);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
