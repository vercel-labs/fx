import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";

type SseEvent = [string, Record<string, unknown>];

function sse(events: SseEvent[]) {
  return new Response(events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

export function completion(model: string, text = "local reply", inputTokens = 12) {
  return sse([
    ["message_start", { type: "message_start", message: { id: "msg-local", model, usage: { input_tokens: inputTokens, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 3 } }],
    ["message_stop", { type: "message_stop" }],
  ]);
}

export function toolUseCompletion(model: string, name: string, args: unknown, callId = "toolu-local", thinking = "Inspect it first.", signature = "sig-1") {
  const input = JSON.stringify(args);
  return sse([
    ["message_start", { type: "message_start", message: { id: "msg-tool", model, usage: { input_tokens: 15, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["content_block_start", { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: callId, name } }],
    ["content_block_delta", { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: input } }],
    ["content_block_stop", { type: "content_block_stop", index: 1 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 7 } }],
    ["message_stop", { type: "message_stop" }],
  ]);
}

export function createAnthropicProviderFixture(respond?: (body: any) => Response | Promise<Response>) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  const requests: Array<{ path: string; headers: Record<string, string | null>; body: any }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({
        path,
        headers: {
          authorization: request.headers.get("authorization"),
          "x-api-key": request.headers.get("x-api-key"),
          "anthropic-version": request.headers.get("anthropic-version"),
        },
        body,
      });
      if (path !== "/v1/messages") return new Response("unexpected endpoint", { status: 500 });
      return respond ? respond(body) : completion((body as any).model);
    },
  });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = {
    provider: "claude", auto_upgrade: false, permission_mode: "ask",
    providers: {
      claude: { protocol: "anthropic-messages", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "x-api-key", env: "FX_TEST_PROVIDER_TOKEN" }, model_metadata: { "claude-test-model": { context_window: 200000, max_output_tokens: 8192, supports_tool_use: true } } },
    },
    models: { claude: "claude-test-model" },
  };
  const save = () => writeFileSync(settingsPath, JSON.stringify(settings), { mode: 0o600 });
  save();
  const env = {
    HOME: home, FX_PROVIDER: undefined, FX_MODEL: undefined, FX_AUTH_MODE: undefined,
    AI_GATEWAY_API_KEY: "unrelated-gateway-token", VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_GATEWAY_BASE_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_TEST_PROVIDER_TOKEN: "own-provider-token", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
  };
  return { home, workspace, requests, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
