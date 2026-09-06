import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, TmuxSession } from "./tmux-helpers";

const TIMEOUT = 30_000;

type CapturedRequest = {
  path: string;
  method: string;
  headers: Headers;
};

describe("host-managed authentication", () => {
  let root = "";
  let home = "";
  let workspace = "";
  let requests: CapturedRequest[] = [];
  let server: ReturnType<typeof Bun.serve>;
  let baseUrl = "";
  let codexUnauthorizedResponses = 0;

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), "fx-host-managed-auth-"));
    home = join(root, "home");
    workspace = join(root, "workspace");
    mkdirSync(home, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const path = new URL(request.url).pathname;
        requests.push({
          path,
          method: request.method,
          headers: new Headers(request.headers),
        });
        if (path === "/gateway/models") {
          return Response.json({
            data: [{ id: "test/gateway-model", type: "language", tags: ["tool-use"] }],
          });
        }
        if (path === "/gateway/responses") {
          return fakeGatewayFinalText("GATEWAY_HOST_MANAGED_OK");
        }
        if (path === "/codex/models") {
          return Response.json({ models: [{
            slug: "gpt-5.4-mini",
            visibility: "list",
            supported_in_api: true,
            priority: 1,
            supported_reasoning_levels: [{ effort: "low" }],
            additional_speed_tiers: [],
            input_modalities: ["text"],
            context_window: 272000,
          }, {
            slug: "gpt-5.6-luna",
            visibility: "list",
            supported_in_api: true,
            priority: 2,
            supported_reasoning_levels: [{ effort: "medium" }],
            additional_speed_tiers: [],
            input_modalities: ["text"],
            context_window: 272000,
          }] });
        }
        if (path === "/codex/responses") {
          if (codexUnauthorizedResponses > 0) {
            codexUnauthorizedResponses -= 1;
            return Response.json({ error: { message: "host rejected request" } }, { status: 401 });
          }
          return new Response(
            'data: {"type":"response.output_text.delta","delta":"CODEX_HOST_MANAGED_OK"}\n\n' +
              'data: {"type":"response.completed","response":{"id":"resp_codex_host","status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        if (path === "/grok/models") {
          return Response.json({ data: [{
            id: "grok-4.20",
            model: "grok-4.20",
            api_backend: "responses",
            context_window: 1000000,
            supports_reasoning_effort: false,
            reasoning_efforts: [],
          }] });
        }
        if (path === "/grok/modalities") {
          return Response.json({ models: [{
            id: "grok-4.20",
            input_modalities: ["text"],
            output_modalities: ["text"],
          }] });
        }
        if (path === "/grok/responses") {
          return new Response(
            'data: {"type":"response.output_text.delta","delta":"GROK_HOST_MANAGED_OK"}\n\n' +
              'data: {"type":"response.completed","response":{"id":"resp_grok_host","status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return new Response("not found", { status: 404 });
      },
    });
    baseUrl = `http://127.0.0.1:${server.port}`;
  });

  afterAll(() => {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  });

  function env(): Record<string, string | undefined> {
    return {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTH_MODE: "host-managed",
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_SOUND: "0",
      FX_E2E_GATEWAY_MODELS_URL: `${baseUrl}/gateway/models`,
      FX_E2E_GATEWAY_CHAT_URL: `${baseUrl}/gateway/responses`,
      FX_E2E_OPENAI_CODEX_MODELS_URL: `${baseUrl}/codex/models`,
      FX_E2E_OPENAI_CODEX_RESPONSES_URL: `${baseUrl}/codex/responses`,
      FX_E2E_XAI_GROK_MODELS_URL: `${baseUrl}/grok/models`,
      FX_E2E_XAI_GROK_MODALITIES_URL: `${baseUrl}/grok/modalities`,
      FX_E2E_XAI_GROK_RESPONSES_URL: `${baseUrl}/grok/responses`,
    };
  }

  test("runs Gateway Codex and Grok without local authentication headers", async () => {
    const childEnv = env();
    const status = await runFx(["status", "--json"], { cwd: workspace, env: childEnv });
    expect(status.code).toBe(0);
    expect(status.stderr).toBe("");
    expect(JSON.parse(status.stdout).auth).toBe("host managed");

    for (const command of [["login"], ["logout"], ["setup"], ["teams"]]) {
      const result = await runFx(command, { cwd: workspace, env: childEnv });
      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      expect(result.stdout).toBe("Authentication is managed by the host.\n");
    }
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);

    for (const [provider, marker] of [
      ["gateway", "GATEWAY_HOST_MANAGED_OK"],
      ["codex", "CODEX_HOST_MANAGED_OK"],
      ["grok", "GROK_HOST_MANAGED_OK"],
    ] as const) {
      const selected = await runFx(["provider", provider], {
        cwd: workspace,
        env: childEnv,
        timeoutMs: TIMEOUT,
      });
      expect(selected.code).toBe(0);
      expect(selected.stderr).toBe("");

      const models = await runFx(["models", "--json"], {
        cwd: workspace,
        env: childEnv,
        timeoutMs: TIMEOUT,
      });
      expect(models.code).toBe(0);
      expect(models.stderr).toBe("");

      const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
        cwd: workspace,
        env: childEnv,
        timeoutMs: TIMEOUT,
      });
      expect(asked.code).toBe(0);
      expect(asked.stderr).toBe("");
      expect(asked.stdout).toContain(marker);
    }

    expect(requests.length).toBeGreaterThan(0);
    for (const request of requests) {
      expect(request.headers.get("authorization"), request.path).toBeNull();
      expect(request.headers.get("x-vercel-ai-gateway-team"), request.path).toBeNull();
      expect(request.headers.get("chatgpt-account-id"), request.path).toBeNull();
      expect(request.headers.get("x-xai-token-auth"), request.path).toBeNull();
      expect(request.headers.get("x-authenticateresponse"), request.path).toBeNull();
      expect(request.headers.get("x-grok-user-id"), request.path).toBeNull();
      expect(request.headers.get("x-userid"), request.path).toBeNull();
    }
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  }, TIMEOUT);

  test("rejects malformed auth mode before provider I/O", async () => {
    const before = requests.length;
    const result = await runFx(["ask", "--json", "--no-save", "Do nothing."], {
      cwd: workspace,
      env: { ...env(), FX_AUTH_MODE: "host_managed" },
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("FX_AUTH_MODE must be local or host-managed");
    expect(requests.length).toBe(before);
  }, TIMEOUT);

  test("final provider 401 does not enter local refresh or replay", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "codex"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    const before = requests.filter((request) => request.path === "/codex/responses").length;
    codexUnauthorizedResponses = 1;
    const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(asked.code).toBe(1);
    const after = requests.filter((request) => request.path === "/codex/responses").length;
    expect(after - before).toBe(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  }, TIMEOUT);

  test("interactive host-managed session streams through the same authority", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "gateway"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    const stderrPath = join(root, "tui.stderr");
    const tracePath = join(root, "tui.trace");
    const before = requests.length;
    const session = await TmuxSession.create({
      cwd: workspace,
      env: {
        ...childEnv,
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "auth,session,worker,gateway",
      },
      stderrPath,
      isolated: true,
    });
    try {
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Reply once.");
      const pane = await session.waitForText("GATEWAY_HOST_MANAGED_OK", TIMEOUT);
      expect(pane).toContain("GATEWAY_HOST_MANAGED_OK");
    } catch (error) {
      const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "<no trace>";
      throw new Error(`${String(error)}\ntrace:\n${trace}`);
    } finally {
      await session.kill();
    }

    expect(readFileSync(stderrPath, "utf8")).toBe("");
    expect(requests.length).toBeGreaterThan(before);
    for (const request of requests.slice(before)) {
      expect(request.headers.get("authorization"), request.path).toBeNull();
      expect(request.headers.get("x-vercel-ai-gateway-team"), request.path).toBeNull();
    }
  }, TIMEOUT * 2);
});
