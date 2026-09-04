import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, fakeGatewayPermissionDecision, fakeGatewaySse, fakeGatewayToolCall, fakeShellRun, TmuxSession } from "./tmux-helpers";

const TIMEOUT = 30_000;

type CapturedRequest = {
  path: string;
  search: string;
  headers: Headers;
};

const BROKER_TOKEN = "broker-test-token";
const GATEWAY_TOKEN = "gateway-provider-token";
const CODEX_TOKEN = "codex-provider-token";
const CODEX_ACCOUNT = "account-test-codex";
const GROK_TOKEN = "grok-provider-token";
const GROK_ACCOUNT = "account-test-grok";
const GENERATION_ID = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV";

describe("host-managed authentication", () => {
  let root = "";
  let home = "";
  let workspace = "";
  let brokerRequests: CapturedRequest[] = [];
  let upstreamRequests: CapturedRequest[] = [];
  let brokerServer: ReturnType<typeof Bun.serve>;
  let upstreamServer: ReturnType<typeof Bun.serve>;
  let brokerBaseUrl = "";
  let upstreamBaseUrl = "";
  let codexUnauthorizedResponses = 0;
  let brokerFailureStatus: number | null = null;
  let rejectDiscoveryStatus: number | null = null;
  let gatewayPermissionScenario = false;
  let gatewayPermissionReviews = 0;
  let reviewFailureStatus: number | null = null;
  let heldBrokerRoute: string | null = null;
  let brokerGatewayHoldStarted = 0;
  let brokerGatewayCancellationCount = 0;
  let brokerTruncatedText: string | null = null;
  let visionScenario: "empty" | "partial" | null = null;
  let visionRequested = false;
  let visionBodies: string[] = [];
  let visionFailureStatus: number | null = null;
  let compactionFailureStatus: number | null = null;
  let compactionRequests = 0;
  let gatewayResponseText = "GATEWAY_HOST_MANAGED_OK";
  const heldRequests = new Map<string, { controller: AbortController; settled: Promise<void> }>();
  let cancelRequestCount = 0;
  let rejectCancellation = false;
  let stallCancellation = false;

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), "fx-host-managed-auth-"));
    home = join(root, "home");
    workspace = join(root, "workspace");
    mkdirSync(home, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    upstreamServer = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const path = new URL(request.url).pathname;
        const headers = new Headers(request.headers);
        upstreamRequests.push({
          path,
          search: new URL(request.url).search,
          headers,
        });
        if (path === "/gateway/held") {
          const encoder = new TextEncoder();
          let timer: ReturnType<typeof setInterval>;
          request.signal.addEventListener("abort", () => { brokerGatewayCancellationCount += 1; }, { once: true });
          return new Response(new ReadableStream({
            start(controller) {
              controller.enqueue(encoder.encode(": upstream-active\n\n"));
              timer = setInterval(() => controller.enqueue(encoder.encode(": upstream-active\n\n")), 50);
            },
            cancel() { clearInterval(timer); },
          }), { headers: { "content-type": "text/event-stream" } });
        }
        if (path === "/gateway/models") {
          if (headers.get("authorization") !== `Bearer ${GATEWAY_TOKEN}`) {
            return Response.json({ error: { message: "missing gateway authentication" } }, { status: 401 });
          }
          return Response.json({
            data: [
              { id: "test/gateway-model", type: "language", tags: ["tool-use"] },
              { id: "zai/glm-5.2-fast", type: "language", tags: ["tool-use"], context_window: 65536, max_tokens: 2048 },
              { id: "google/gemini-2.5-flash", type: "language", tags: ["tool-use", "vision", "file-input"] },
              { id: "openai/gpt-5.6-luna", type: "language", tags: ["tool-use"], context_window: 65536, max_tokens: 2048 },
            ],
          });
        }
        if (path === "/gateway/responses") {
          if (headers.get("authorization") !== `Bearer ${GATEWAY_TOKEN}`) {
            return Response.json({ error: { message: "missing gateway authentication" } }, { status: 401 });
          }
          const body = await request.text();
          if (compactionFailureStatus !== null && body.includes("Summarize only what this excerpt establishes")) {
            compactionRequests += 1;
            return Response.json({ error: { message: "host compaction rejected" } }, { status: compactionFailureStatus });
          }
          if (visionScenario !== null) {
            if (headers.get("ai-language-model-id") === "google/gemini-2.5-flash") {
              visionBodies.push(body);
              if (visionFailureStatus !== null) return Response.json({ error: { message: "host vision rejected" } }, { status: visionFailureStatus });
              return new Response(visionScenario === "empty" ? "" :
                'data: {"type":"text-delta","id":"vision","delta":"{\\\"images\\\":["}\n\n', {
                  headers: { "content-type": "text/event-stream" },
                });
            }
            if (!visionRequested) {
              visionRequested = true;
              return fakeGatewayToolCall("broker_vision", "vision", { image_ids: [1], focus: "Inspect the image." });
            }
            return fakeGatewayFinalText("VISION_FINISHED_WITHOUT_REPLAY");
          }
          if (body.includes("permission_decision")) {
            gatewayPermissionReviews += 1;
            if (reviewFailureStatus !== null) return Response.json({ error: { message: "host review rejected" } }, { status: reviewFailureStatus });
            return fakeGatewayPermissionDecision("clear");
          }
          if (gatewayPermissionScenario) {
            gatewayPermissionScenario = false;
            return fakeShellRun(
              "broker_permission_shell",
              reviewFailureStatus === null ? "printf BROKER_PERMISSION_TOOL_OK > broker-permission.txt" :
                "printf SHOULD_NOT_RUN > broker-denied-permission.txt",
            );
          }
          if (body.includes("broker permission route")) {
            return fakeGatewayFinalText("BROKER_PERMISSION_REVIEW_OK");
          }
          return fakeGatewaySse([
            {
              type: "text-start",
              id: "answer_1",
              providerMetadata: { gateway: { generationId: GENERATION_ID } },
            },
            { type: "text-delta", id: "answer_1", delta: gatewayResponseText },
            { type: "text-end", id: "answer_1" },
            {
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
              providerMetadata: { gateway: { generationId: GENERATION_ID } },
            },
          ]);
        }
        if (path === "/gateway/credits") {
          if (headers.get("authorization") !== `Bearer ${GATEWAY_TOKEN}`) {
            return Response.json({ error: { message: "missing gateway authentication" } }, { status: 401 });
          }
          return Response.json({ balance: "10", used: "2", plan: "pro" });
        }
        if (path === "/gateway/generation") {
          if (headers.get("authorization") !== `Bearer ${GATEWAY_TOKEN}`) {
            return Response.json({ error: { message: "missing gateway authentication" } }, { status: 401 });
          }
          return Response.json({
            data: {
              id: GENERATION_ID,
              created_at: "2026-09-03T00:00:00.000Z",
              model: "test/gateway-model",
              total_cost: 0.001,
              native_tokens_prompt: 3,
              native_tokens_completion: 5,
              native_tokens_cached: 0,
              native_tokens_cache_creation: 0,
              billable_web_search_calls: 0,
            },
          });
        }
        if (path === "/codex/models") {
          if (
            headers.get("authorization") !== `Bearer ${CODEX_TOKEN}` ||
            headers.get("chatgpt-account-id") !== CODEX_ACCOUNT
          ) {
            return Response.json({ error: { message: "missing Codex authentication" } }, { status: 401 });
          }
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
          if (
            headers.get("authorization") !== `Bearer ${CODEX_TOKEN}` ||
            headers.get("chatgpt-account-id") !== CODEX_ACCOUNT
          ) {
            return Response.json({ error: { message: "missing Codex authentication" } }, { status: 401 });
          }
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
          if (
            headers.get("authorization") !== `Bearer ${GROK_TOKEN}` ||
            headers.get("x-xai-token-auth") !== "xai-grok-cli" ||
            headers.get("x-userid") !== GROK_ACCOUNT
          ) {
            return Response.json({ error: { message: "missing Grok authentication" } }, { status: 401 });
          }
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
          if (headers.get("authorization") !== `Bearer ${GROK_TOKEN}`) {
            return Response.json({ error: { message: "missing Grok authentication" } }, { status: 401 });
          }
          return Response.json({ models: [{
            id: "grok-4.20",
            input_modalities: ["text"],
            output_modalities: ["text"],
          }] });
        }
        if (path === "/grok/responses") {
          if (
            headers.get("authorization") !== `Bearer ${GROK_TOKEN}` ||
            headers.get("x-xai-token-auth") !== "xai-grok-cli" ||
            headers.get("x-authenticateresponse") !== "authenticate-response" ||
            headers.get("x-grok-user-id") !== GROK_ACCOUNT
          ) {
            return Response.json({ error: { message: "missing Grok authentication" } }, { status: 401 });
          }
          return new Response(
            'data: {"type":"response.output_text.delta","delta":"GROK_HOST_MANAGED_OK"}\n\n' +
              'data: {"type":"response.completed","response":{"id":"resp_grok_host","status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
            { headers: { "content-type": "text/event-stream" } },
          );
        }
        return new Response("not found", { status: 404 });
      },
    });
    upstreamBaseUrl = `http://127.0.0.1:${upstreamServer.port}`;

    brokerServer = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const url = new URL(request.url);
        const path = url.pathname;
        const headers = new Headers(request.headers);
        brokerRequests.push({ path, search: url.search, headers });
        if (
          headers.get("authorization") !== `Bearer ${BROKER_TOKEN}` ||
          headers.get("x-fx-host-protocol") !== "1"
        ) {
          return Response.json({ error: { message: "invalid broker capability" } }, { status: 401 });
        }
        if (path === "/fx/v1/cancel") {
          cancelRequestCount += 1;
          if (stallCancellation) {
            return await new Promise<Response>((resolve) => {
              request.signal.addEventListener("abort", () => resolve(new Response(null, { status: 499 })), { once: true });
            });
          }
          if (rejectCancellation) return new Response(null, { status: 503 });
          const input = await request.json() as { request_id: string };
          const held = heldRequests.get(input.request_id);
          held?.controller.abort();
          await held?.settled;
          return new Response(null, { status: 204 });
        }

        const routes: Record<string, string> = {
          "/fx/v1/gateway/models": "/gateway/models",
          "/fx/v1/gateway/chat": "/gateway/responses",
          "/fx/v1/gateway/credits": "/gateway/credits",
          "/fx/v1/gateway/generation": "/gateway/generation",
          "/fx/v1/codex/models": "/codex/models",
          "/fx/v1/codex/responses": "/codex/responses",
          "/fx/v1/grok/models": "/grok/models",
          "/fx/v1/grok/modalities": "/grok/modalities",
          "/fx/v1/grok/responses": "/grok/responses",
        };
        const upstreamPath = routes[path];
        if (!upstreamPath) return new Response("unknown broker route", { status: 404 });
        if (rejectDiscoveryStatus !== null && !path.endsWith("/chat") && !path.endsWith("/responses")) {
          return Response.json({ error: { message: "host discovery rejected" } }, { status: rejectDiscoveryStatus });
        }
        if (brokerTruncatedText !== null && path === "/fx/v1/gateway/chat") {
          const text = brokerTruncatedText;
          brokerTruncatedText = null;
          return new Response(text.length === 0 ? "" :
            `data: ${JSON.stringify({ type: "text-delta", id: "truncated", delta: text })}\n\n`, {
            headers: { "content-type": "text/event-stream" },
          });
        }
        if (brokerFailureStatus !== null && path === "/fx/v1/codex/responses") {
          return Response.json(
            { error: { message: "host transport failure" } },
            { status: brokerFailureStatus },
          );
        }
        if (heldBrokerRoute === path) {
          heldBrokerRoute = null;
          const id = headers.get("x-fx-request-id") ?? "missing-id";
          const controller = new AbortController();
          const upstream = await fetch(`${upstreamBaseUrl}/gateway/held`, { signal: controller.signal });
          let output: ReadableStreamDefaultController<Uint8Array>;
          let disconnected = false;
          const responseBody = new ReadableStream<Uint8Array>({
            start(value) { output = value; },
            cancel() { disconnected = true; },
          });
          const settled = (async () => {
            try {
              for await (const chunk of upstream.body!) {
                if (!disconnected) output.enqueue(chunk);
              }
            } catch (error) {
              if (!controller.signal.aborted) throw error;
            } finally {
              if (!disconnected) output.close();
              heldRequests.delete(id);
            }
          })();
          heldRequests.set(id, { controller, settled });
          brokerGatewayHoldStarted += 1;
          return new Response(responseBody, { headers: { "content-type": "text/event-stream" } });
        }

        const upstreamHeaders = new Headers(headers);
        upstreamHeaders.delete("authorization");
        upstreamHeaders.delete("x-fx-host-protocol");
        if (path.includes("/gateway/")) {
          upstreamHeaders.set("authorization", `Bearer ${GATEWAY_TOKEN}`);
        } else if (path.includes("/codex/")) {
          upstreamHeaders.set("authorization", `Bearer ${CODEX_TOKEN}`);
          upstreamHeaders.set("chatgpt-account-id", CODEX_ACCOUNT);
        } else {
          upstreamHeaders.set("authorization", `Bearer ${GROK_TOKEN}`);
          if (path.endsWith("/models")) {
            upstreamHeaders.set("x-xai-token-auth", "xai-grok-cli");
            upstreamHeaders.set("x-userid", GROK_ACCOUNT);
          } else if (path.endsWith("/responses")) {
            upstreamHeaders.set("x-xai-token-auth", "xai-grok-cli");
            upstreamHeaders.set("x-authenticateresponse", "authenticate-response");
            upstreamHeaders.set("x-grok-user-id", GROK_ACCOUNT);
          }
        }
        const upstream = await fetch(`${upstreamBaseUrl}${upstreamPath}${url.search}`, {
          method: request.method,
          headers: upstreamHeaders,
          body: request.body,
          redirect: "manual",
        });
        return new Response(upstream.body, {
          status: upstream.status,
          headers: upstream.headers,
        });
      },
    });
    brokerBaseUrl = `http://127.0.0.1:${brokerServer.port}/fx`;
  });

  afterAll(() => {
    for (const held of heldRequests.values()) held.controller.abort();
    brokerServer.stop(true);
    upstreamServer.stop(true);
    rmSync(root, { recursive: true, force: true });
  });

  function env(): Record<string, string | undefined> {
    return {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTH_MODE: "host-managed",
      FX_HOST_BROKER_URL: brokerBaseUrl,
      FX_HOST_BROKER_TOKEN: BROKER_TOKEN,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_SOUND: "0",
      FX_E2E_GATEWAY_MODELS_URL: `${upstreamBaseUrl}/gateway/models`,
      FX_E2E_GATEWAY_CHAT_URL: `${upstreamBaseUrl}/gateway/responses`,
      FX_E2E_GATEWAY_CREDITS_URL: `${upstreamBaseUrl}/gateway/credits`,
      FX_E2E_OPENAI_CODEX_MODELS_URL: `${upstreamBaseUrl}/codex/models`,
      FX_E2E_OPENAI_CODEX_RESPONSES_URL: `${upstreamBaseUrl}/codex/responses`,
      FX_E2E_XAI_GROK_MODELS_URL: `${upstreamBaseUrl}/grok/models`,
      FX_E2E_XAI_GROK_MODALITIES_URL: `${upstreamBaseUrl}/grok/modalities`,
      FX_E2E_XAI_GROK_RESPONSES_URL: `${upstreamBaseUrl}/grok/responses`,
    };
  }

  test("runs Gateway Codex and Grok without local authentication headers", async () => {
    const childEnv = {
      ...env(),
      FX_E2E_CODEX_CLIENT_VERSION: "invalid-host-owned-version",
      FX_E2E_GROK_CLIENT_VERSION: "invalid-host-owned-version",
    };
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
      if (provider === "gateway") {
        const credits = await runFx(["credits", "--json"], {
          cwd: workspace,
          env: childEnv,
          timeoutMs: TIMEOUT,
        });
        expect(credits.code).toBe(0);
        expect(credits.stderr).toBe("");
        expect(JSON.parse(credits.stdout)).toMatchObject({
          kind: "credits",
          balance: "10",
          used: "2",
          plan: "pro",
        });
      }
    }

    expect(brokerRequests.length).toBeGreaterThan(0);
    expect(upstreamRequests.length).toBeGreaterThan(0);
    for (const route of [
      "/fx/v1/gateway/chat",
      "/fx/v1/gateway/models",
      "/fx/v1/gateway/credits",
      "/fx/v1/gateway/generation",
      "/fx/v1/codex/responses",
      "/fx/v1/codex/models",
      "/fx/v1/grok/responses",
      "/fx/v1/grok/models",
      "/fx/v1/grok/modalities",
    ]) {
      expect(brokerRequests.some((request) => request.path === route), route).toBe(true);
    }
    for (const request of brokerRequests) {
      expect(request.headers.get("authorization"), request.path).toBe(`Bearer ${BROKER_TOKEN}`);
      expect(request.headers.get("x-fx-host-protocol"), request.path).toBe("1");
      expect(request.headers.get("x-fx-request-id"), request.path).toMatch(/^[a-f0-9]{32}$/);
      expect(request.headers.get("x-vercel-ai-gateway-team"), request.path).toBeNull();
      expect(request.headers.get("chatgpt-account-id"), request.path).toBeNull();
      expect(request.headers.get("x-xai-token-auth"), request.path).toBeNull();
      expect(request.headers.get("x-authenticateresponse"), request.path).toBeNull();
      expect(request.headers.get("x-grok-user-id"), request.path).toBeNull();
      expect(request.headers.get("x-userid"), request.path).toBeNull();
      expect(request.headers.get("x-grok-client-version"), request.path).toBeNull();
    }
    for (const request of upstreamRequests) {
      expect(request.headers.get("authorization"), request.path).not.toBe(`Bearer ${BROKER_TOKEN}`);
      expect(request.headers.get("x-fx-host-protocol"), request.path).toBeNull();
    }
    const codexModels = brokerRequests.find((request) => request.path === "/fx/v1/codex/models");
    expect(codexModels?.search).toBe("");
    expect(existsSync(join(home, ".fx", "provider-versions"))).toBe(false);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  }, TIMEOUT);

  test("rejects malformed auth mode before provider I/O", async () => {
    const brokerBefore = brokerRequests.length;
    const upstreamBefore = upstreamRequests.length;
    const result = await runFx(["ask", "--json", "--no-save", "Do nothing."], {
      cwd: workspace,
      env: { ...env(), FX_AUTH_MODE: "host_managed" },
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(1);
    expect(result.stderr).toContain("FX_AUTH_MODE must be local or host-managed");
    expect(brokerRequests.length).toBe(brokerBefore);
    expect(upstreamRequests.length).toBe(upstreamBefore);
  }, TIMEOUT);

  test("routes host-managed permission review through the same broker", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "gateway"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    const reviewsBefore = gatewayPermissionReviews;
    const brokerCallsBefore = brokerRequests.filter((request) => request.path === "/fx/v1/gateway/chat").length;
    gatewayPermissionScenario = true;
    const asked = await runFx(["ask", "--json", "--no-save", "Exercise the broker permission route."], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(asked.code).toBe(0);
    expect(asked.stderr).toContain("Running printf BROKER_PERMISSION_TOOL_OK");
    expect(asked.stderr).not.toContain("authentication failed");
    expect(asked.stdout).toContain("BROKER_PERMISSION_REVIEW_OK");
    expect(readFileSync(join(workspace, "broker-permission.txt"), "utf8")).toBe("BROKER_PERMISSION_TOOL_OK");
    expect(gatewayPermissionReviews - reviewsBefore).toBe(1);
    const brokerCallsAfter = brokerRequests.filter((request) => request.path === "/fx/v1/gateway/chat").length;
    expect(brokerCallsAfter - brokerCallsBefore).toBe(3);
  }, TIMEOUT);

  test("rejects partial broker configuration before provider I/O", async () => {
    const brokerBefore = brokerRequests.length;
    const upstreamBefore = upstreamRequests.length;
    const childEnv = env();
    childEnv.FX_HOST_BROKER_TOKEN = undefined;
    const result = await runFx(["status", "--json"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("FX_HOST_BROKER_URL and FX_HOST_BROKER_TOKEN must be set together");
    expect(brokerRequests.length).toBe(brokerBefore);
    expect(upstreamRequests.length).toBe(upstreamBefore);
  }, TIMEOUT);

  test("final provider 401 does not enter local refresh or replay", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "codex"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    const before = upstreamRequests.filter((request) => request.path === "/codex/responses").length;
    codexUnauthorizedResponses = 1;
    const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(asked.code).toBe(1);
    expect(asked.stderr).toContain("Host authentication failed · HTTP 401");
    expect(asked.stderr).toContain("Reconnect this provider in the host application.");
    expect(asked.stderr).not.toContain("/login");
    expect(asked.stderr).not.toContain("API key");
    const after = upstreamRequests.filter((request) => request.path === "/codex/responses").length;
    expect(after - before).toBe(1);
    expect(existsSync(join(home, ".fx", "auth.json"))).toBe(false);
  }, TIMEOUT);

  test("host-managed context overflow does not start compaction or replay", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "codex"], { cwd: workspace, env: childEnv });
    expect(selected.code).toBe(0);
    const session = await TmuxSession.create({ cwd: workspace, env: childEnv, isolated: true });
    try {
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Remember this context for the next turn.");
      await session.waitForText("CODEX_HOST_MANAGED_OK", TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      const before = brokerRequests.filter((request) => request.path === "/fx/v1/codex/responses").length;
      brokerFailureStatus = 413;
      await session.sendText("Continue from the earlier context.");
      const pane = await session.waitForText("HTTP 413", TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      expect(brokerRequests.filter((request) => request.path === "/fx/v1/codex/responses").length - before).toBe(1);
      expect(pane).not.toContain("Run /login");
    } finally {
      brokerFailureStatus = null;
      await session.kill();
    }
  }, TIMEOUT * 2);

  test("host authorization and availability failures give host-owned recovery", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "codex"], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    for (const scenario of [
      {
        status: 403,
        message: "Host authorization denied · HTTP 403",
        recovery: "Request access in the host application.",
      },
      {
        status: 503,
        message: "Host authentication service unavailable · HTTP 503",
        recovery: "Try again shortly or check the host application.",
      },
    ]) {
      const brokerBefore = brokerRequests.filter((request) => request.path === "/fx/v1/codex/responses").length;
      const upstreamBefore = upstreamRequests.filter((request) => request.path === "/codex/responses").length;
      brokerFailureStatus = scenario.status;
      try {
        const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
          cwd: workspace,
          env: childEnv,
          timeoutMs: TIMEOUT,
        });
        expect(asked.code).toBe(1);
        expect(asked.stderr).toContain(scenario.message);
        expect(asked.stderr).toContain(scenario.recovery);
        expect(asked.stderr).not.toContain("/login");
        expect(asked.stderr).not.toContain("API key");
      } finally {
        brokerFailureStatus = null;
      }
      const brokerAfter = brokerRequests.filter((request) => request.path === "/fx/v1/codex/responses").length;
      const upstreamAfter = upstreamRequests.filter((request) => request.path === "/codex/responses").length;
      expect(brokerAfter - brokerBefore).toBe(1);
      expect(upstreamAfter).toBe(upstreamBefore);
    }
  }, TIMEOUT);

  test("preserves the observed broker HTTP status instead of reconstructing an outage", async () => {
    const childEnv = env();
    expect((await runFx(["provider", "codex"], { cwd: workspace, env: childEnv })).code).toBe(0);
    try {
      for (const status of [402, 404, 422]) {
        brokerFailureStatus = status;
        const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], { cwd: workspace, env: childEnv });
        expect(asked.code).toBe(1);
        expect(asked.stderr).toContain(`HTTP ${status}`);
        expect(asked.stderr).not.toContain("HTTP 502");
        expect(asked.stderr).not.toContain("Try again shortly");
      }
    } finally { brokerFailureStatus = null; }
  }, TIMEOUT);

  test("discovery activation and credits preserve host recovery", async () => {
    const childEnv = env();
    expect((await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv })).code).toBe(0);
    try {
      for (const [status, recovery] of [
        [401, "Reconnect this provider in the host application."],
        [403, "Request access in the host application."],
        [503, "Try again shortly or check the host application."],
      ] as const) {
        rejectDiscoveryStatus = status;
        for (const args of [["models", "--json"], ["credits", "--json"], ["provider", "codex"]]) {
          const result = await runFx(args, { cwd: workspace, env: childEnv });
          expect(result.code).toBe(1);
          expect(result.stdout + result.stderr).toContain(`HTTP ${status}`);
          expect(result.stdout + result.stderr).toContain(recovery);
          expect(result.stdout + result.stderr).not.toContain("Run /login");
        }
      }
    } finally { rejectDiscoveryStatus = null; }
  }, TIMEOUT);

  test("Vision does not replay an incompletely delivered host-managed response", async () => {
    const childEnv = { ...env(), FX_MODEL: "zai/glm-5.2-fast" };
    expect((await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv })).code).toBe(0);
    try {
      for (const scenario of ["empty", "partial"] as const) {
        visionScenario = scenario;
        visionRequested = false;
        visionBodies = [];
        const asked = await runFx(["ask", "--json", "--auto", "--no-save", "--image",
          join(import.meta.dirname, "fixtures", "placeholder-logo.png"), "Inspect the attached image."], {
          cwd: workspace, env: childEnv, timeoutMs: TIMEOUT,
        });
        expect(asked.code, asked.stderr).toBe(0);
        expect(asked.stdout).toContain("VISION_FINISHED_WITHOUT_REPLAY");
        expect(visionBodies).toHaveLength(1);
      }
    } finally { visionScenario = null; }
  }, TIMEOUT);

  test("secondary Vision and permission failures reach the parent with host recovery", async () => {
    const childEnv = { ...env(), FX_MODEL: "zai/glm-5.2-fast" };
    expect((await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv })).code).toBe(0);
    try {
      for (const status of [401, 403, 503]) {
        visionScenario = "empty";
        visionFailureStatus = status;
        visionRequested = false;
        visionBodies = [];
        const vision = await runFx(["ask", "--json", "--auto", "--no-save", "--image",
          join(import.meta.dirname, "fixtures", "placeholder-logo.png"), "Inspect the image."], {
          cwd: workspace, env: childEnv, timeoutMs: TIMEOUT,
        });
        expect(vision.code).toBe(1);
        expect(vision.stderr).toContain(`HTTP ${status}`);
        expect(vision.stderr.match(/HTTP /g)).toHaveLength(1);
        expect(vision.stderr).not.toContain("/login");
        expect(vision.stderr).not.toContain("switch model");
        expect(visionBodies).toHaveLength(1);
        visionScenario = null;
        visionFailureStatus = null;

        reviewFailureStatus = status;
        gatewayPermissionScenario = true;
        const reviewsBefore = gatewayPermissionReviews;
        const review = await runFx(["ask", "--json", "--auto", "--no-save", "Exercise broker permission route."], {
          cwd: workspace, env: childEnv, timeoutMs: TIMEOUT,
        });
        expect(review.code).toBe(1);
        expect(review.stderr).toContain(`HTTP ${status}`);
        expect(review.stderr).not.toContain("/login");
        expect(gatewayPermissionReviews - reviewsBefore).toBe(1);
        expect(existsSync(join(workspace, "broker-denied-permission.txt"))).toBe(false);
        reviewFailureStatus = null;
      }
    } finally {
      visionScenario = null;
      visionFailureStatus = null;
      reviewFailureStatus = null;
      gatewayPermissionScenario = false;
    }
  }, TIMEOUT);

  test("manual compaction preserves host rejection and leaves the session usable", async () => {
    const childEnv = { ...env(), FX_MODEL: "zai/glm-5.2-fast" };
    await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv });
    for (const status of [401, 403, 503]) {
      const session = await TmuxSession.create({ cwd: workspace, env: childEnv, isolated: true });
      try {
        await session.waitForComposer(TIMEOUT);
        for (const [index, prompt] of ["Remember the first context fact.", "Remember the second context fact.", "Remember the third context fact."].entries()) {
          gatewayResponseText = `HOST_CONTEXT_${status}_${index}`;
          await session.sendText(prompt);
          await session.waitForText(gatewayResponseText, TIMEOUT);
          await session.waitForStableComposer(TIMEOUT);
        }
        compactionFailureStatus = status;
        const before = compactionRequests;
        await session.sendText("/compact");
        const pane = await session.waitForText(`HTTP ${status}`, TIMEOUT);
        expect(compactionRequests - before).toBe(1);
        expect(pane).toContain("Host");
        expect(pane).not.toContain("Run /login");
        compactionFailureStatus = null;
        await session.waitForStableComposer(TIMEOUT);
        gatewayResponseText = `HOST_CONTEXT_RECOVERED_${status}`;
        await session.sendText("Continue after the compaction rejection.");
        await session.waitForText(gatewayResponseText, TIMEOUT);
        await session.waitForStableComposer(TIMEOUT);
      } finally {
        compactionFailureStatus = null;
        gatewayResponseText = "GATEWAY_HOST_MANAGED_OK";
        await session.kill();
      }
    }
  }, TIMEOUT * 4);


  test("host catalog preserves non-auth HTTP statuses in CLI consumers", async () => {
    const childEnv = env();
    try {
      for (const status of [402, 404, 422, 429, 500]) {
        rejectDiscoveryStatus = status;
        for (const args of [["models", "--json"], ["provider", "codex"]]) {
          const result = await runFx(args, { cwd: workspace, env: childEnv });
          expect(result.code).toBe(1);
          expect(result.stdout + result.stderr).toContain(`HTTP ${status}`);
          expect(result.stdout + result.stderr).not.toContain("HTTP 502");
        }
      }
    } finally { rejectDiscoveryStatus = null; }
  }, TIMEOUT);

  test("interrupted catalog and credit GETs preserve unconfirmed scoped cleanup", async () => {
    const childEnv = env();
    await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv });
    const requested = new Set<string>();
    const cancelled: string[] = [];
    const droppingBroker = createServer((request, response) => {
      if (request.url === "/fx/v1/cancel") {
        let body = "";
        request.on("data", (chunk) => { body += chunk; });
        request.on("end", () => {
          cancelled.push(JSON.parse(body).request_id);
          response.writeHead(503);
          response.end();
        });
        return;
      }
      requested.add(String(request.headers["x-fx-request-id"]));
      request.resume();
      setTimeout(() => request.socket.destroy(), 5);
    });
    await new Promise<void>((resolve) => droppingBroker.listen(0, "127.0.0.1", resolve));
    const address = droppingBroker.address();
    if (!address || typeof address === "string") throw new Error("broker address missing");
    try {
      for (const command of ["models", "credits"]) {
        const result = await runFx([command, "--json"], { cwd: workspace, env: {
          ...childEnv, FX_HOST_BROKER_URL: `http://127.0.0.1:${address.port}/fx`,
        } });
        expect(result.code).toBe(1);
        expect(result.stdout + result.stderr).toContain("Host could not confirm upstream cancellation");
      }
      expect(requested.size).toBe(2);
      expect(cancelled).toHaveLength(2);
      for (const id of cancelled) expect(requested.has(id)).toBe(true);
    } finally {
      droppingBroker.closeAllConnections();
      await new Promise<void>((resolve) => droppingBroker.close(() => resolve()));
    }
  }, TIMEOUT);


  test("does not replay a host-managed request after the broker drops a delivered body", async () => {
    let delivered = 0;
    let cancelled = 0;
    const droppingBroker = createServer((request, response) => {
      if (request.url === "/fx/v1/gateway/models") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ data: [{ id: "test/gateway-model", type: "language", tags: ["tool-use"] }] }));
        return;
      }
      if (request.url === "/fx/v1/cancel") {
        cancelled += 1;
        request.resume();
        response.writeHead(204);
        response.end();
        return;
      }
      request.resume();
      request.on("end", () => {
        delivered += 1;
        request.socket.destroy();
      });
    });
    await new Promise<void>((resolve) => droppingBroker.listen(0, "127.0.0.1", resolve));
    const address = droppingBroker.address();
    if (!address || typeof address === "string") throw new Error("broker address missing");
    const childEnv = { ...env(), FX_HOST_BROKER_URL: `http://127.0.0.1:${address.port}/fx` };
    try {
      const selected = await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv });
      expect(selected.code).toBe(0);
      const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
        cwd: workspace,
        env: childEnv,
        timeoutMs: 10_000,
      });
      expect(asked.code).toBe(1);
      expect(delivered).toBe(1);
      expect(cancelled).toBe(1);
      expect(asked.stderr).not.toContain("retrying request");
    } finally {
      droppingBroker.closeAllConnections();
      await new Promise<void>((resolve) => droppingBroker.close(() => resolve()));
    }
  }, TIMEOUT);

  test("does not regenerate host-managed responses after empty or partial stream EOF", async () => {
    const childEnv = env();
    const selected = await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv });
    expect(selected.code).toBe(0);
    for (const partial of ["", "PARTIAL_HOST_RESPONSE"]) {
      const before = brokerRequests.filter((request) => request.path === "/fx/v1/gateway/chat").length;
      brokerTruncatedText = partial;
      try {
        const asked = await runFx(["ask", "--json", "--no-save", "Reply once."], {
          cwd: workspace,
          env: childEnv,
          timeoutMs: 10_000,
        });
        expect(asked.code).toBe(1);
        const after = brokerRequests.filter((request) => request.path === "/fx/v1/gateway/chat").length;
        expect(after - before).toBe(1);
        expect(asked.stderr).not.toContain("retrying request");
        expect(asked.stdout).not.toContain("GATEWAY_HOST_MANAGED_OK");
      } finally {
        brokerTruncatedText = null;
      }
    }
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
    const before = brokerRequests.length;
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
    expect(brokerRequests.length).toBeGreaterThan(before);
    for (const request of brokerRequests.slice(before)) {
      expect(request.headers.get("authorization"), request.path).toBe(`Bearer ${BROKER_TOKEN}`);
      expect(request.headers.get("x-vercel-ai-gateway-team"), request.path).toBeNull();
    }
  }, TIMEOUT * 2);

  for (const [provider, route, marker] of [
    ["gateway", "/fx/v1/gateway/chat", "GATEWAY_HOST_MANAGED_OK"],
    ["codex", "/fx/v1/codex/responses", "CODEX_HOST_MANAGED_OK"],
    ["grok", "/fx/v1/grok/responses", "GROK_HOST_MANAGED_OK"],
  ] as const) {
  test(`${provider} interactive cancellation reaches active upstream even when the proxy retains disconnected work`, async () => {
    const childEnv = env();
    const selected = await runFx(["provider", provider], {
      cwd: workspace,
      env: childEnv,
      timeoutMs: TIMEOUT,
    });
    expect(selected.code).toBe(0);

    const stderrPath = join(root, "tui-cancel.stderr");
    const session = await TmuxSession.create({
      cwd: workspace,
      env: childEnv,
      stderrPath,
      isolated: true,
    });
    try {
      await session.waitForComposer(TIMEOUT);
      const startedBefore = brokerGatewayHoldStarted;
      const cancelledBefore = brokerGatewayCancellationCount;
      const cancelRequestsBefore = cancelRequestCount;
      heldBrokerRoute = route;
      await session.sendText("Wait for the host broker.");
      const requestDeadline = Date.now() + TIMEOUT;
      while (brokerGatewayHoldStarted === startedBefore && Date.now() < requestDeadline) {
        await Bun.sleep(25);
      }
      expect(brokerGatewayHoldStarted - startedBefore).toBe(1);
      await session.sendKeys("Escape");
      const cancelDeadline = Date.now() + 5_000;
      while (brokerGatewayCancellationCount === cancelledBefore && Date.now() < cancelDeadline) {
        await Bun.sleep(25);
      }
      expect(brokerGatewayCancellationCount - cancelledBefore).toBe(1);
      expect(cancelRequestCount - cancelRequestsBefore).toBe(1);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Reply after cancellation.");
      const pane = await session.waitForText(marker, TIMEOUT);
      expect(pane).toContain(marker);
    } finally {
      heldBrokerRoute = null;
      await session.kill();
    }
    expect(readFileSync(stderrPath, "utf8")).toBe("");
  }, TIMEOUT * 2);
  }

  for (const unavailable of ["rejected", "unresponsive"] as const) {
  test(`${unavailable} upstream cancellation is visible and leaves the session usable`, async () => {
    const childEnv = env();
    await runFx(["provider", "gateway"], { cwd: workspace, env: childEnv });
    const session = await TmuxSession.create({ cwd: workspace, env: childEnv, isolated: true });
    try {
      await session.waitForComposer(TIMEOUT);
      const startedBefore = brokerGatewayHoldStarted;
      const cancelledBefore = brokerGatewayCancellationCount;
      heldBrokerRoute = "/fx/v1/gateway/chat";
      rejectCancellation = true;
      stallCancellation = unavailable === "unresponsive";
      await session.sendText("Hold until cancelled.");
      const deadline = Date.now() + TIMEOUT;
      while (brokerGatewayHoldStarted === startedBefore && Date.now() < deadline) await Bun.sleep(25);
      expect(brokerGatewayHoldStarted - startedBefore).toBe(1);
      const cancelStartedAt = Date.now();
      await session.sendKeys("Escape");
      await session.waitForText("Host could not confirm upstream cancellation", 5_000);
      expect(Date.now() - cancelStartedAt).toBeLessThan(3_500);
      expect(brokerGatewayCancellationCount).toBe(cancelledBefore);
      rejectCancellation = false;
      stallCancellation = false;
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Reply after unconfirmed cancellation.");
      await session.waitForText("GATEWAY_HOST_MANAGED_OK", TIMEOUT);
    } finally {
      rejectCancellation = false;
      stallCancellation = false;
      heldBrokerRoute = null;
      for (const held of heldRequests.values()) held.controller.abort();
      await session.kill();
    }
  }, TIMEOUT * 2);
  }
});
