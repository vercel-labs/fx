import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";

export function responsesCompletion(model: string, text = "spark reply") {
  const chunks = [
    { type: "response.output_text.delta", output_index: 0, delta: text },
    { type: "response.completed", response: { status: "completed", usage: { input_tokens: 10, output_tokens: 4 } } },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

export function responsesToolCall(model: string, name: string, args: unknown, callId = "call-spark") {
  const chunks = [
    { type: "response.output_item.added", output_index: 0, item: { type: "reasoning" } },
    { type: "response.output_item.done", output_index: 0, item: { id: "rs_1", type: "reasoning", summary: [], encrypted_content: "opaque-reasoning" } },
    { type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: callId, name } },
    { type: "response.function_call_arguments.delta", output_index: 1, delta: JSON.stringify(args) },
    { type: "response.completed", response: { status: "completed", usage: { input_tokens: 10, output_tokens: 4 } } },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

export function createResponsesProviderFixture(respond?: (body: any) => Response | Promise<Response>) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  const requests: Array<{ path: string; authorization: string | null; body: any }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({ path, authorization: request.headers.get("authorization"), body });
      if (path !== "/v1/responses") return new Response("unexpected endpoint", { status: 500 });
      return respond ? respond(body) : responsesCompletion((body as any).model);
    },
  });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = {
    provider: "spark", auto_upgrade: false, permission_mode: "ask",
    providers: {
      spark: { protocol: "openai-responses", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "bearer", env: "MODEL_API_KEY" }, model_metadata: { "muse-spark-1.3": { context_window: 1048576, max_output_tokens: 131072, supports_tool_use: true, supports_vision: true } } },
    },
    models: { spark: "muse-spark-1.3" },
  };
  const save = () => writeFileSync(settingsPath, JSON.stringify(settings), { mode: 0o600 });
  save();
  const env = {
    HOME: home, FX_PROVIDER: undefined, FX_MODEL: undefined, FX_AUTH_MODE: undefined,
    AI_GATEWAY_API_KEY: "unrelated-gateway-token", VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_GATEWAY_BASE_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    MODEL_API_KEY: "meta-test-key", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
  };
  return { home, workspace, requests, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
