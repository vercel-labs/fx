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

function startFakeChatgptIssuer() {
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
      if (url.pathname === "/.well-known/openid-configuration") {
        const issuer = `http://127.0.0.1:${server.port}`;
        return Response.json({
          issuer,
          authorization_endpoint: `${issuer}/oauth/authorize`,
          token_endpoint: `${issuer}/oauth/token`,
        });
      }
      if (url.pathname === "/oauth/token") {
        const params = new URLSearchParams(body);
        if (params.get("grant_type") !== "authorization_code") {
          return new Response("unexpected grant", { status: 400 });
        }
        if (params.get("code") !== "test-code") {
          return new Response("unexpected code", { status: 400 });
        }
        if (!params.get("code_verifier")) {
          return new Response("missing verifier", { status: 400 });
        }
        return Response.json({
          access_token: "chatgpt-access-token",
          refresh_token: "chatgpt-refresh-token",
          expires_in: 3600,
          token_type: "Bearer",
          scope: "openid profile email offline_access",
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
  "fx login chatgpt completes against a fake issuer and persists the session",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-chatgpt-login-e2e-"));
    mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
    chmodSync(join(home, ".fx"), 0o700);
    const issuer = startFakeChatgptIssuer();
    try {
      const child = spawn(FX_BIN, ["login", "chatgpt"], {
        cwd: REPO_ROOT,
        env: {
          ...process.env,
          HOME: home,
          NO_COLOR: "1",
          FX_NO_OPEN_BROWSER: "1",
          FX_E2E_CHATGPT_ISSUER_URL: issuer.issuerUrl,
          FX_AUTO_UPGRADE: "0",
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      const stdout = await waitForStdout(child, "Waiting for ChatGPT authorization");
      const match = stdout.match(/Open (https?:\/\/[^\s]+)/);
      expect(match).not.toBeNull();
      const authorizeUrl = new URL(match![1]);
      const redirectUri = authorizeUrl.searchParams.get("redirect_uri");
      const state = authorizeUrl.searchParams.get("state");
      expect(redirectUri).toBeTruthy();
      expect(state).toBeTruthy();
      expect(authorizeUrl.searchParams.get("code_challenge_method")).toBe("S256");
      expect(authorizeUrl.searchParams.get("client_id")).toBe(
        "app_EMoamEEZ73f0CkXaXp7hrann",
      );

      const callback = new URL(redirectUri!);
      callback.searchParams.set("code", "test-code");
      callback.searchParams.set("state", state!);
      const callbackResponse = await fetch(callback);
      expect(callbackResponse.ok).toBe(true);

      const result = await new Promise<{
        code: number | null;
        stdout: string;
        stderr: string;
      }>((resolve) => {
        let rest = stdout;
        let stderr = "";
        child.stdout?.on("data", (chunk: Buffer) => {
          rest += chunk.toString();
        });
        child.stderr?.on("data", (chunk: Buffer) => {
          stderr += chunk.toString();
        });
        child.on("close", (code) => {
          resolve({ code, stdout: rest, stderr });
        });
      });
      expect(result.stderr).toBe("");
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Signed in to ChatGPT.");

      const authPath = join(home, ".fx", "providers", "chatgpt", "auth.json");
      expect(existsSync(authPath)).toBe(true);
      expect(statSync(authPath).mode & 0o777).toBe(0o600);
      const session = JSON.parse(readFileSync(authPath, "utf8"));
      expect(session.access_token).toBe("chatgpt-access-token");
      expect(session.refresh_token).toBe("chatgpt-refresh-token");
      expect(session.client_id).toBe("app_EMoamEEZ73f0CkXaXp7hrann");
      expect(session.issuer).toBe(issuer.issuerUrl);

      const tokenRequest = issuer.requests.find((entry) => entry.path === "/oauth/token");
      expect(tokenRequest).toBeDefined();
      expect(tokenRequest!.body).toContain("grant_type=authorization_code");
      expect(tokenRequest!.body).toContain("code=test-code");
      expect(tokenRequest!.body).toContain("code_verifier=");

      const settings = JSON.parse(
        readFileSync(join(home, ".fx", "settings.json"), "utf8"),
      );
      expect(settings.provider).toBe("chatgpt");
    } finally {
      issuer.stop();
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test(
  "fx login chatgpt can be cancelled before the callback",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-chatgpt-login-cancel-e2e-"));
    mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
    const issuer = startFakeChatgptIssuer();
    try {
      const child = spawn(FX_BIN, ["login", "chatgpt"], {
        cwd: REPO_ROOT,
        env: {
          ...process.env,
          HOME: home,
          NO_COLOR: "1",
          FX_NO_OPEN_BROWSER: "1",
          FX_E2E_CHATGPT_ISSUER_URL: issuer.issuerUrl,
          FX_AUTO_UPGRADE: "0",
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      await waitForStdout(child, "Waiting for ChatGPT authorization");
      child.kill("SIGINT");
      const code = await new Promise<number | null>((resolve) => {
        child.on("close", (value) => resolve(value));
      });
      expect(code === 1 || code === 130 || code === null).toBe(true);
      expect(existsSync(join(home, ".fx", "providers", "chatgpt", "auth.json"))).toBe(
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
  "bare fx login still rejects extra unknown tokens and chatgpt is the optional backend",
  async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-chatgpt-login-usage-e2e-"));
    try {
      const extra = await runFx(["login", "chatgpt", "extra"], {
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

      const logout = await runFx(["logout", "chatgpt"], {
        env: { HOME: home, FX_AUTO_UPGRADE: "0" },
        timeoutMs: 8_000,
      });
      expect(logout.code).toBe(0);
      expect(logout.stdout).toBe("No ChatGPT session found.\n");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
