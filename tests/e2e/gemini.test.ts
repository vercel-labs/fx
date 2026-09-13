import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 30_000;
const MODEL = "gemini-3.8-flash";
const KEY = "gemini-fixture-key";
type RequestBody = { model: string; input: Array<Record<string, any>>; tools?: Array<Record<string, any>>; store: boolean; stream: boolean; generation_config?: Record<string, unknown> };
type Captured = { url: URL; headers: Headers; body?: RequestBody };

function stream(steps: Array<Record<string, any>>, status = "completed"): Response {
  const events: Array<Record<string, any>> = [{ event_type: "interaction.created", interaction: { id: "interaction_fixture" } }];
  steps.forEach((step, index) => {
    if (step.type === "model_output") {
      events.push({ event_type: "step.start", index, step: { type: "model_output" } });
      events.push({ event_type: "step.delta", index, delta: { type: "text", text: step.text } });
    } else if (step.type === "function_call") {
      events.push({ event_type: "step.start", index, step: { ...step, arguments: {} } });
      const args = JSON.stringify(step.arguments);
      const middle = Math.floor(args.length / 2);
      for (const part of [args.slice(0, middle), args.slice(middle)]) {
        events.push({ event_type: "step.delta", index, delta: { type: "arguments_delta", arguments: part } });
      }
    } else {
      events.push({ event_type: "step.start", index, step });
    }
    events.push({ event_type: "step.stop", index });
  });
  events.push({ event_type: "interaction.completed", interaction: {
    id: "interaction_fixture", status,
    usage: { total_input_tokens: 12, total_output_tokens: 8, total_thought_tokens: 2 },
  } });
  return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
}

function fixture(reply: (body: RequestBody) => Response = () => stream([{ type: "model_output", text: "GEMINI_DIRECT_OK" }])) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-gemini-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  const requests: Captured[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url);
    const captured: Captured = { url, headers: new Headers(request.headers) };
    requests.push(captured);
    if (url.pathname === "/gemini/models") {
      const secondPage = url.searchParams.get("pageToken") === "second page/+";
      return Response.json({
        models: [{ name: `models/${secondPage ? "gemini-3.1-pro-preview" : MODEL}`, inputTokenLimit: 1048576, outputTokenLimit: 65536, supportedGenerationMethods: ["generateContent"] }],
        ...(!secondPage && { nextPageToken: "second page/+" }),
      });
    }
    if (url.pathname === "/gemini/interactions") {
      captured.body = await request.json() as RequestBody;
      return reply(captured.body);
    }
    return new Response("Unexpected provider route", { status: 500 });
  } });
  const base = `http://127.0.0.1:${server.port}`;
  const env: Record<string, string | undefined> = {
    HOME: home, GEMINI_API_KEY: KEY, AI_GATEWAY_API_KEY: "gateway-fixture-key",
    VERCEL_OIDC_TOKEN: undefined, FX_AUTH_MODE: "local", FX_MODEL: undefined,
    FX_CREDENTIAL_SOURCE: undefined, FX_PERMISSION_MODE: "auto", FX_MAX_AGENT_STEPS: "4",
    FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_SOUND: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_E2E_GEMINI_MODELS_URL: `${base}/gemini/models`,
    FX_E2E_GEMINI_INTERACTIONS_URL: `${base}/gemini/interactions`,
    FX_E2E_GATEWAY_MODELS_URL: `${base}/gateway/models`,
    FX_E2E_GATEWAY_CHAT_URL: `${base}/gateway/responses`,
  };
  return {
    home, workspace, requests, env,
    run: (args: string[], overrides: Record<string, string | undefined> = {}) => runFx(args, { cwd: workspace, env: { ...env, ...overrides }, timeoutMs: TIMEOUT }),
    close() { server.stop(true); rmSync(root, { recursive: true, force: true }); },
  };
}

async function select(f: ReturnType<typeof fixture>) {
  const selected = await f.run(["provider", "gemini"]);
  expect(selected.code, selected.stderr).toBe(0);
  expect(selected.stderr).toBe("");
}

function directOnly(requests: Captured[], key: string | null = KEY) {
  expect(requests.length).toBeGreaterThan(0);
  for (const request of requests) {
    expect(request.url.pathname).toStartWith("/gemini/");
    expect(request.headers.get("x-goog-api-key")).toBe(key);
    expect(request.headers.get("authorization")).toBeNull();
    expect(request.headers.get("x-vercel-ai-gateway-team")).toBeNull();
  }
}

describe("direct Gemini provider", () => {
  test("selects Gemini, fetches paginated models, and sends only the Google key", async () => {
    const f = fixture();
    try {
      await select(f);
      const models = await f.run(["models", "--json"]);
      expect(models.code, models.stderr).toBe(0);
      expect(models.stdout).toContain(MODEL);
      expect(models.stdout).toContain("gemini-3.1-pro-preview");
      const asked = await f.run(["ask", "--json", "--no-save", "Reply once."]);
      expect(asked.code, asked.stderr + asked.stdout).toBe(0);
      expect(asked.stderr).toBe("");
      expect(JSON.parse(asked.stdout)).toMatchObject({ output: "GEMINI_DIRECT_OK", model: MODEL });
      const body = f.requests.find((request) => request.body)?.body!;
      expect(body).toMatchObject({ model: MODEL, stream: true, store: false });
      expect(body.input.some((step) => step.type === "user_input")).toBe(true);
      expect(body.tools?.some((tool) => tool.type === "function" && tool.name === "write_file")).toBe(true);
      directOnly(f.requests);
      expect(existsSync(join(f.home, ".fx", "auth.json"))).toBe(false);
    } finally { f.close(); }
  }, TIMEOUT);

  test("executes a fragmented tool call and retains signed history after resume", async () => {
    let calls = 0;
    const signature = "opaque-fixture-signature";
    const f = fixture(() => ++calls === 1 ? stream([
      { type: "thought", signature },
      { type: "function_call", id: "write_1", name: "write_file", arguments: { path: "gemini-result.txt", content: "GEMINI_TOOL_OK\n" } },
    ], "requires_action") : stream([{ type: "model_output", text: "GEMINI_TOOL_COMPLETE" }]));
    try {
      await select(f);
      const result = await f.run(["ask", "--json", "Create gemini-result.txt with GEMINI_TOOL_OK and report success."]);
      expect(result.code, result.stderr + result.stdout).toBe(0);
      expect(result.stderr).toBe("Writing gemini-result.txt\n");
      const output = JSON.parse(result.stdout);
      expect(output.output).toBe("GEMINI_TOOL_COMPLETE");
      expect(output.tool_calls).toContainEqual({ name: "write_file", status: "success" });
      expect(readFileSync(join(f.workspace, "gemini-result.txt"), "utf8")).toBe("GEMINI_TOOL_OK\n");
      const bodies = f.requests.flatMap((request) => request.body ? [request.body] : []);
      expect(bodies).toHaveLength(2);
      expect(bodies[1].input).toContainEqual({ type: "thought", signature });
      expect(bodies[1].input).toContainEqual({ type: "function_call", id: "write_1", name: "write_file", arguments: { path: "gemini-result.txt", content: "GEMINI_TOOL_OK\n" } });
      expect(bodies[1].input.some((step) => step.type === "function_result" && step.call_id === "write_1" && step.name === "write_file")).toBe(true);
      expect(result.stdout).not.toContain(signature);
      const resumed = await f.run(["ask", "--json", "--resume-id", output.session_id, "Confirm the previous result."]);
      expect(resumed.code, resumed.stderr + resumed.stdout).toBe(0);
      expect(resumed.stderr).toBe("");
      const resumedBody = f.requests.filter((request) => request.body).at(-1)!.body!;
      expect(resumedBody.input).toContainEqual({ type: "thought", signature });
      expect(resumedBody.input.some((step) => step.type === "function_result" && step.call_id === "write_1")).toBe(true);
      directOnly(f.requests);
    } finally { f.close(); }
  }, TIMEOUT);

  test("reviews an existing file edit with the direct Gemini reviewer", async () => {
    const reviews: RequestBody[] = [];
    let mainCalls = 0;
    const f = fixture((body) => {
      if (body.tools?.some((tool) => tool.name === "permission_decision")) {
        reviews.push(body);
        return stream([{ type: "function_call", id: "review_1", name: "permission_decision", arguments: {
          risk: "low", decision: "clear", rationale: "The exact edit contains no malicious action.",
        } }], "requires_action");
      }
      return ++mainCalls === 1 ? stream([
        { type: "thought", signature: "edit-fixture-signature" },
        { type: "function_call", id: "edit_1", name: "edit_file", arguments: {
          path: "../existing.txt", old_string: "before", new_string: "after",
        } },
      ], "requires_action") : stream([{ type: "model_output", text: "GEMINI_REVIEWED_EDIT_OK" }]);
    });
    try {
      writeFileSync(join(f.workspace, "../existing.txt"), "before\n");
      await select(f);
      const result = await f.run(["ask", "--json", "--no-save", "Change before to after in ../existing.txt."]);
      expect(result.code, result.stderr + result.stdout).toBe(0);
      expect(result.stderr).toBe(`Editing ${join(f.workspace, "../existing.txt")}\n`);
      expect(JSON.parse(result.stdout)).toMatchObject({ output: "GEMINI_REVIEWED_EDIT_OK", tool_calls: [{ name: "edit_file", status: "success" }] });
      expect(readFileSync(join(f.workspace, "../existing.txt"), "utf8")).toBe("after\n");
      expect(mainCalls).toBe(2);
      expect(reviews).toHaveLength(1);
      expect(reviews[0].model).toBe("gemini-3.5-flash-lite");
      expect(reviews[0].generation_config).toMatchObject({ tool_choice: "any", thinking_level: "low" });
      expect(reviews[0].tools).toHaveLength(1);
      expect(reviews[0].input).toHaveLength(1);
      expect(reviews[0].input[0].type).toBe("user_input");
      const evidence = JSON.parse(reviews[0].input[0].content[0].text);
      expect(Array.isArray(evidence)).toBe(true);
      expect(JSON.stringify(evidence)).toContain("../existing.txt");
      expect(JSON.stringify(evidence)).toContain("edit_file");
      expect(JSON.stringify(evidence)).toContain("before");
      expect(JSON.stringify(evidence)).toContain("after");
      directOnly(f.requests);
    } finally { f.close(); }
  }, TIMEOUT);

  test("does not execute a tool from an incomplete stream", async () => {
    let calls = 0;
    const f = fixture(() => ++calls === 1
      ? new Response([
        { event_type: "interaction.created", interaction: { id: "incomplete_fixture" } },
        { event_type: "step.start", index: 0, step: { type: "function_call", id: "uncommitted", name: "write_file", arguments: { path: "must-not-exist.txt", content: "unsafe partial" } } },
        { event_type: "step.stop", index: 0 },
      ].map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } })
      : stream([{ type: "model_output", text: "GEMINI_RECOVERED" }]));
    try {
      await select(f);
      const result = await f.run(["ask", "--json", "--no-save", "Create must-not-exist.txt."]);
      expect(result.code).toBe(1);
      expect(JSON.parse(result.stdout).error).toBe("GeminiStreamIncomplete");
      expect(JSON.parse(result.stdout).tool_calls).toEqual([]);
      expect(existsSync(join(f.workspace, "must-not-exist.txt"))).toBe(false);
      expect(calls).toBe(1);
      directOnly(f.requests);
    } finally { f.close(); }
  }, TIMEOUT);

  test("host-managed Gemini sends no local authentication headers", async () => {
    const f = fixture();
    try {
      f.env.FX_AUTH_MODE = "host-managed";
      f.env.GEMINI_API_KEY = undefined;
      await select(f);
      const result = await f.run(["ask", "--json", "--no-save", "Reply once."]);
      expect(result.code, result.stderr + result.stdout).toBe(0);
      expect(result.stderr).toBe("");
      expect(JSON.parse(result.stdout).output).toBe("GEMINI_DIRECT_OK");
      directOnly(f.requests, null);
    } finally { f.close(); }
  }, TIMEOUT);

  test("a missing Google key does not use an available Gateway key", async () => {
    const f = fixture();
    try {
      await select(f);
      const before = f.requests.length;
      const result = await f.run(["ask", "--json", "--no-save", "Reply once."], { GEMINI_API_KEY: undefined });
      expect(result.code).not.toBe(0);
      expect(result.stdout + result.stderr).toContain("GEMINI_API_KEY");
      expect(f.requests.length).toBe(before);
    } finally { f.close(); }
  }, TIMEOUT);

  test("retries a rate limit on the same direct provider", async () => {
    let calls = 0;
    const f = fixture(() => ++calls === 1
      ? Response.json({ error: { code: 429, message: "fixture rate limit" } }, { status: 429, headers: { "retry-after": "0" } })
      : stream([{ type: "model_output", text: "GEMINI_RETRY_OK" }]));
    try {
      await select(f);
      const result = await f.run(["ask", "--json", "--no-save", "Reply once."]);
      expect(result.code, result.stderr + result.stdout).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("GEMINI_RETRY_OK");
      expect(calls).toBe(2);
      directOnly(f.requests);
    } finally { f.close(); }
  }, TIMEOUT);

  test("HTTP 401 fails without a Gateway fallback or tool execution", async () => {
    const status = 401;
    const f = fixture(() => Response.json({ error: { code: status, message: "fixture rejection" } }, { status }));
    try {
      await select(f);
      const result = await f.run(["ask", "--json", "--no-save", "Create a file."]);
      expect(result.code).not.toBe(0);
      expect(result.stderr).not.toContain("panic");
      expect(result.stderr).not.toContain(KEY);
      const output = JSON.parse(result.stdout);
      expect(output.tool_calls).toEqual([]);
      directOnly(f.requests);
    } finally { f.close(); }
  }, TIMEOUT);
});
