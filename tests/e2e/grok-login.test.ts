import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";

const TIMEOUT = 20_000;
const GROK_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";

function startFakeGrokIssuer(mode: "complete" | "pending") {
  const requests: Array<{ method: string; path: string; body: string }> = [];
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
      });
      const issuer = `http://127.0.0.1:${server.port}`;
      if (url.pathname === "/.well-known/openid-configuration") {
        return Response.json({
          issuer,
          device_authorization_endpoint: `${issuer}/oauth2/device/code`,
          token_endpoint: `${issuer}/oauth2/token`,
        });
      }
      if (url.pathname === "/oauth2/device/code") {
        const params = new URLSearchParams(body);
        if (params.get("client_id") !== GROK_CLIENT_ID) {
          return new Response("unexpected client", { status: 400 });
        }
        if (!params.get("scope")?.includes("grok-cli:access")) {
          return new Response("missing grok scope", { status: 400 });
        }
        return Response.json({
          device_code: "grok-device-code",
          user_code: "ABCD-EFGH",
          verification_uri: `${issuer}/device`,
          verification_uri_complete: `${issuer}/device?user_code=ABCD-EFGH`,
          expires_in: 600,
          interval: 1,
        });
      }
      if (url.pathname === "/oauth2/token") {
        const params = new URLSearchParams(body);
        if (params.get("grant_type") !== "urn:ietf:params:oauth:grant-type:device_code") {
          return new Response("unexpected grant", { status: 400 });
        }
        if (params.get("device_code") !== "grok-device-code") {
          return new Response("unexpected device code", { status: 400 });
        }
        if (mode === "pending") {
          return Response.json(
            { error: "authorization_pending" },
            { status: 400 },
          );
        }
        return Response.json({
          access_token: "grok-access-token",
          refresh_token: "grok-refresh-token",
          expires_in: 3600,
          token_type: "Bearer",
          scope: "openid offline_access grok-cli:access api:access",
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    issuerUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

async function waitForStdout(child: ReturnType<typeof spawn>, needle: string): Promise<string> {
  let stdout = "";
  const deadline = Date.now() + 8_000;
  return await new Promise((resolve, reject) => {
    const onData = (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.includes(needle)) {
        child.stdout?.off("data", onData);
        resolve(stdout);
      }
    };
    child.stdout?.on("data", onData);
    const timer = setInterval(() => {
      if (Date.now() > deadline) {
        clearInterval(timer);
        child.stdout?.off("data", onData);
        reject(new Error(`Timed out waiting for ${needle}\nstdout:\n${stdout}`));
      }
    }, 20);
  });
}

test(
  "fx login grok completes against a fake issuer and persists the session",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-grok-login-e2e-"));
    mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
    chmodSync(join(home, ".fx"), 0o700);
    const issuer = startFakeGrokIssuer("complete");
    try {
      const result = await runFx(["login", "grok"], {
        env: {
          HOME: home,
          NO_COLOR: "1",
          FX_NO_OPEN_BROWSER: "1",
          FX_E2E_GROK_ISSUER_URL: issuer.issuerUrl,
          FX_AUTO_UPGRADE: "0",
        },
        timeoutMs: 12_000,
      });
      expect(result.stderr).toBe("");
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Open ");
      expect(result.stdout).toContain("Code: ABCD-EFGH");
      expect(result.stdout).toContain("Waiting for Grok authorization");
      expect(result.stdout).toContain("Signed in to Grok.");

      const authPath = join(home, ".fx", "providers", "grok", "auth.json");
      expect(existsSync(authPath)).toBe(true);
      expect(statSync(authPath).mode & 0o777).toBe(0o600);
      const session = JSON.parse(readFileSync(authPath, "utf8"));
      expect(session.access_token).toBe("grok-access-token");
      expect(session.refresh_token).toBe("grok-refresh-token");
      expect(session.client_id).toBe(GROK_CLIENT_ID);
      expect(session.issuer).toBe(issuer.issuerUrl);

      const deviceRequest = issuer.requests.find((entry) => entry.path === "/oauth2/device/code");
      expect(deviceRequest).toBeDefined();
      expect(deviceRequest!.body).toContain(`client_id=${GROK_CLIENT_ID}`);
      expect(deviceRequest!.body).toContain("scope=");
      expect(deviceRequest!.body).toContain("grok-cli%3Aaccess");

      const tokenRequest = issuer.requests.find((entry) => entry.path === "/oauth2/token");
      expect(tokenRequest).toBeDefined();
      expect(tokenRequest!.body).toContain(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
      );
      expect(tokenRequest!.body).toContain("device_code=grok-device-code");

      const settings = JSON.parse(
        readFileSync(join(home, ".fx", "settings.json"), "utf8"),
      );
      expect(settings.provider).toBe("grok");

      const logout = await runFx(["logout", "grok"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(logout.code).toBe(0);
      expect(logout.stdout).toBe("Signed out of Grok.\n");
      expect(existsSync(authPath)).toBe(false);
    } finally {
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx login grok can be cancelled before the device is approved",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-grok-login-cancel-e2e-"));
    mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
    const issuer = startFakeGrokIssuer("pending");
    try {
      const child = spawn(FX_BIN, ["login", "grok"], {
        cwd: REPO_ROOT,
        env: {
          ...process.env,
          HOME: home,
          NO_COLOR: "1",
          FX_NO_OPEN_BROWSER: "1",
          FX_E2E_GROK_ISSUER_URL: issuer.issuerUrl,
          FX_AUTO_UPGRADE: "0",
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      await waitForStdout(child, "Waiting for Grok authorization");
      child.kill("SIGINT");
      const code = await new Promise<number | null>((resolve) => {
        child.on("close", (value) => resolve(value));
      });
      expect(code === 1 || code === 130 || code === null).toBe(true);
      expect(existsSync(join(home, ".fx", "providers", "grok", "auth.json"))).toBe(
        false,
      );
    } finally {
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "bare fx login still rejects extra unknown tokens and grok is an optional backend",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-grok-login-usage-e2e-"));
    try {
      const extra = await runFx(["login", "grok", "extra"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(extra.code).toBe(1);
      expect(extra.stderr).toContain("usage: fx login [vercel|chatgpt|grok]");

      const unknown = await runFx(["login", "openai"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(unknown.code).toBe(1);
      expect(unknown.stderr).toContain("usage: fx login [vercel|chatgpt|grok]");

      const cursor = await runFx(["login", "cursor"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(cursor.code).toBe(1);
      expect(cursor.stderr).toContain("not implemented yet");

      const logout = await runFx(["logout", "grok"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(logout.code).toBe(0);
      expect(logout.stdout).toBe("No Grok session found.\n");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
