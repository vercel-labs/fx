import { expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 30_000;

function writeGrokAuth(home: string, token = "grok-access-token"): string {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const path = join(fxDir, "grok-auth.json");
  writeFileSync(
    path,
    JSON.stringify({
      version: 1,
      issuer: "https://auth.x.ai",
      client_id: "test-client",
      access_token: token,
      refresh_token: "grok-refresh-token",
      expires_at_ms: Date.now() + 60 * 60 * 1000,
      scope: "openid profile email offline_access grok-cli:access api:access",
      token_type: "Bearer",
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(path, 0o600);
  writeFileSync(
    join(fxDir, "settings.json"),
    JSON.stringify({ credential_source: "grok_oauth", model: "xai/grok-4.6" }) + "\n",
    { mode: 0o600 },
  );
  return path;
}

function startFakeXaiChat(text: string) {
  const requests: Array<{
    method: string;
    path: string;
    authorization: string | null;
    userAgent: string | null;
    body: string;
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
        authorization: request.headers.get("authorization"),
        userAgent: request.headers.get("user-agent"),
        body,
      });
      if (request.method === "POST" && url.pathname.endsWith("/v1/chat/completions")) {
        const sse =
          `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\n` +
          `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n` +
          "data: [DONE]\n\n";
        return new Response(sse, {
          headers: { "content-type": "text/event-stream" },
        });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    chatUrl: `http://127.0.0.1:${server.port}/v1/chat/completions`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

test("fx logout grok reports a missing session", async () => {
  const home = mkdtempSync(join(tmpdir(), "fx-e2e-grok-logout-missing-"));
  try {
    const result = await runFx(["logout", "grok"], {
      env: {
        HOME: realpathSync(home),
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
      },
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toBe("No Grok OAuth session found.\n");
    expect(result.stderr).toBe("");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test(
  "fx ask with Grok OAuth sends the token to api.x.ai chat completions",
  async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-e2e-grok-ask-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(workspace);
    const token = "grok-e2e-access-token";
    writeGrokAuth(home, token);
    const xai = startFakeXaiChat("grok oauth ok");
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Say exactly: grok oauth ok"],
        {
          cwd: realpathSync(workspace),
          env: {
            HOME: realpathSync(home),
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
            FX_SKIP_ONBOARDING: "1",
            FX_MODEL: "xai/grok-4.6",
            FX_E2E_XAI_CHAT_URL: xai.chatUrl,
          },
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.stderr).toBe("");
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("grok oauth ok");
      expect(xai.requests.length).toBeGreaterThan(0);
      expect(xai.requests[0].method).toBe("POST");
      expect(xai.requests[0].authorization).toBe(`Bearer ${token}`);
      expect(xai.requests[0].userAgent).toStartWith("fx/");
      expect(xai.requests[0].userAgent).not.toContain("xai-grok-cli");
      expect(xai.requests[0].body).toContain("\"model\":\"grok-4.6\"");
      expect(xai.requests[0].body).toContain("\"messages\":[");
      expect(xai.requests[0].body.startsWith("{\"model\":\"grok-4.6\"")).toBe(true);
    } finally {
      xai.stop();
      rmSync(root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
