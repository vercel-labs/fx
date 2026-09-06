import { describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  AUTO_EXA_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES,
  customProviderGuidanceState,
  findUnavailableCapabilityReferences,
  parseGatewayRequest,
  serializedToolNames,
  toolByName,
  toolShapesWithoutDescriptions,
  VERIFY_SERIALIZED_TOOL_NAMES,
  WEB_SEARCH_GUIDANCE,
  contentText,
} from "./conditional-guidance-oracle";
import { expectPermissionModeContext } from "./permission-mode-context";

const TIMEOUT = 15_000;
const SOURCE_URL = "https://ziglang.org/download/";
const OUTER_MODEL = "openai/gpt-5";
const PARALLEL_OUTER_MODEL = "xai/grok-4";

type GatewayRequest = {
  body: string;
  headers: Headers;
};

type PermissionAction = "allow" | "ask" | "deny" | null;

type ModelCatalogFixture = {
  id: string;
  type: "language";
  tags: string[];
  reasoning_options?: Array<{ type: string; values?: string[] }>;
  fast_options?: Array<{ type: string }>;
};

function sse(events: object[], done = true) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      (done ? "data: [DONE]\n\n" : ""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function hangingSseResponse() {
  let close!: () => void;
  const response = new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(": waiting\n\n"));
      close = () => {
        try {
          controller.close();
        } catch {}
      };
    },
  }), {
    headers: { "content-type": "text/event-stream" },
  });
  return { response, close };
}

function outerToolCalls(calls: Array<{ id: string; name: string; input: object }>) {
  return sse([
    ...calls.map((call) => ({
      type: "tool-call",
      toolCallId: call.id,
      toolName: call.name,
      input: call.input,
    })),
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function outerSerializedToolCall(
  id: string,
  name: string,
  input: string,
  assistantText?: string,
) {
  return sse([
    ...(assistantText
      ? [{ type: "text-delta", id: "answer_1", delta: assistantText }]
      : []),
    {
      type: "tool-call",
      toolCallId: id,
      toolName: name,
      input,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function duplicateAuthoritativeWriteCalls(path: string) {
  return sse([
    {
      type: "tool-call",
      toolCallId: "duplicate_write_1",
      toolName: "write_file",
      input: { path, content: "provider-owned write" },
      providerExecuted: true,
    },
    {
      type: "tool-call",
      toolCallId: "duplicate_write_1",
      toolName: "write_file",
      input: { path, content: "locally redispatched write" },
      providerExecuted: true,
    },
    {
      type: "tool-result",
      toolCallId: "duplicate_write_1",
      result: { status: "success" },
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function outerSearchCall(input: object = { query: "latest Zig release" }) {
  return outerToolCalls([{ id: "search_outer_1", name: "web_search", input }]);
}

function outerDirectProviderSearch(toolName = "exa_search", result: object = {
  results: [{ title: "Zig downloads", url: SOURCE_URL }],
}) {
  return sse([
    {
      type: "tool-call",
      toolCallId: "search_direct_1",
      toolName,
      input: {},
    },
    {
      type: "tool-result",
      toolCallId: "search_direct_1",
      result,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function malformedDirectProviderResult(toolName: string) {
  return sse([
    {
      type: "tool-call",
      toolCallId: "search_direct_1",
      toolName,
      input: {},
    },
    {
      type: "tool-result",
      result: {
        results: [{ title: "Zig downloads", url: SOURCE_URL }],
      },
    },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 5 },
        outputTokens: { total: 7 },
      },
    },
  ]);
}

function outerFinalAnswer() {
  return sse([
    {
      type: "text-delta",
      id: "answer_1",
      delta: `The current release information is listed on [Zig downloads](${SOURCE_URL}).`,
    },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 11 },
        outputTokens: { total: 13 },
      },
    },
  ]);
}

function outerText(text: string) {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 11 },
        outputTokens: { total: 13 },
      },
    },
  ]);
}

function malformedDirectProviderArguments(toolName: string) {
  return sse([
    {
      type: "tool-call",
      toolCallId: "search_direct_1",
      toolName,
      input: "{]",
    },
    {
      type: "tool-result",
      toolCallId: "search_direct_1",
      result: {
        results: [{ title: "Zig downloads", url: SOURCE_URL }],
      },
    },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
    },
  ]);
}

function startFakeGateway(
  responses: Array<Response | Promise<Response>> = [
    outerDirectProviderSearch(),
    outerFinalAnswer(),
  ],
  model: string | ModelCatalogFixture = OUTER_MODEL,
) {
  const requests: GatewayRequest[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: [typeof model === "string"
            ? { id: model, type: "language", tags: ["tool-use"] }
            : model],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      requests.push({ body: await req.text(), headers: req.headers });
      return await (responses.shift() ?? new Response("unexpected request", { status: 500 }));
    },
  });

  return {
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    baseUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot(
  webSearchPermission: PermissionAction = "allow",
  settings: Record<string, unknown> = {},
) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-web-search-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const permission: Record<string, Record<string, string>> = {};
  if (webSearchPermission) permission.web_search = { "*": webSearchPermission };
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ ...settings, permission }));
  return { root, home, workspace: realpathSync(workspace) };
}

function fakeGatewayEnv(
  root: ReturnType<typeof createIsolatedRoot>,
  gateway: ReturnType<typeof startFakeGateway>,
  extra: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_E2E_GATEWAY_CREDITS_URL: undefined,
    FX_MODEL: OUTER_MODEL,
    ...extra,
  };
}

function parseFxJson(result: Awaited<ReturnType<typeof runFx>>) {
  expect(result.code).toBe(0);
  return JSON.parse(result.stdout.trim()) as {
    output: string;
    tool_calls: Array<{
      name: string;
      status: string;
      web_search?: { searches: number; duration_ms: number };
    }>;
  };
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as {
    prompt: Array<{ content?: unknown }>;
  };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) =>
    part.type === "tool-result" && part.toolCallId === callId
  );
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return contentText(result.output);
}

class AcpClient {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private activeSessionId: string | null = null;

  private constructor(private proc: ChildProcess) {
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const parts = this.buffer.split("\n");
      this.buffer = parts.pop() ?? "";
      for (const line of parts) {
        if (!line.trim()) continue;
        const waiter = this.waiters.shift();
        if (waiter) waiter(line);
        else this.lines.push(line);
      }
    });
    proc.on("close", () => {
      this.closed = true;
    });
  }

  static create(cwd: string, env: Record<string, string | undefined>) {
    const definedEnv = Object.fromEntries(
      Object.entries({ ...process.env, NO_COLOR: "1", ...env }).filter(
        (entry): entry is [string, string] => entry[1] !== undefined,
      ),
    );
    return new AcpClient(nodeSpawn(FX_BIN, ["acp"], {
      cwd,
      env: definedEnv,
      stdio: ["pipe", "pipe", "pipe"],
    }));
  }

  send(message: object) {
    let outgoing = message as any;
    if (
      this.activeSessionId !== null &&
      [
        "session/prompt",
        "session/cancel",
        "session/set_mode",
        "session/set_config_option",
      ].includes(outgoing.method) &&
      outgoing.params?.sessionId === undefined
    ) {
      outgoing = {
        ...outgoing,
        params: { ...(outgoing.params ?? {}), sessionId: this.activeSessionId },
      };
    }
    this.proc.stdin!.write(`${JSON.stringify(outgoing)}\n`);
  }

  async readLine(timeoutMs = TIMEOUT): Promise<any> {
    const line = await new Promise<string>((resolve, reject) => {
      const buffered = this.lines.shift();
      if (buffered) {
        resolve(buffered);
        return;
      }
      const timer = setTimeout(() => reject(new Error("ACP read timeout")), timeoutMs);
      this.waiters.push((value) => {
        clearTimeout(timer);
        resolve(value);
      });
    });
    return JSON.parse(line);
  }

  async request(method: string, params: object, id: number) {
    this.send({ jsonrpc: "2.0", id, method, params });
    let response: any;
    do {
      response = await this.readLine();
    } while (response.id !== id);
    if (
      response.error === undefined &&
      method === "session/new" &&
      typeof response.result?.sessionId === "string"
    ) {
      this.activeSessionId = response.result.sessionId;
    }
    return response;
  }

  async close() {
    if (this.closed) return;
    this.proc.stdin!.end();
    this.proc.kill("SIGTERM");
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (!this.closed) this.proc.kill("SIGKILL");
  }
}

async function startAcpCodeSession(client: AcpClient) {
  await client.request("initialize", { protocolVersion: 1 }, 1);
  await client.request("session/new", { mcpServers: [] }, 2);
  await client.readLine();
  await client.request("session/set_mode", { modeId: "code" }, 3);
}

async function runAcpPrompt(client: AcpClient, text: string) {
  const id = 10;
  client.send({
    jsonrpc: "2.0",
    id,
    method: "session/prompt",
    params: { prompt: [{ type: "text", text }] },
  });
  const messages: any[] = [];
  while (true) {
    const message = await client.readLine();
    if (message.id === id && message.result) return messages;
    messages.push(message);
  }
}

async function waitFor(predicate: () => boolean, timeoutMs = TIMEOUT) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function readAcpResponse(client: AcpClient, id: number) {
  while (true) {
    const message = await client.readLine();
    if (message.id === id) return message;
  }
}

describe("web_search Gateway fixture", () => {
  test(
    "unadvertised native web_search cannot start a worker",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerSearchCall(),
        outerText("The native search call was rejected."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("native search call was rejected");
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0].body).toContain("gateway.exa_search");
        expect(gateway.requests[1].body).toContain(
          "web_search is unavailable: no local runtime with a configured Gateway transport policy is installed",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "default fx ask unadvertised native web_search cannot start a worker",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerSearchCall(),
        outerText("The native search call was rejected."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        expect(result.stdout).toContain("native search call was rejected");
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain(
          "web_search is unavailable: no local runtime with a configured Gateway transport policy is installed",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "no-rule default uses direct Exa search and returns a linked source",
    async () => {
      const root = createIsolatedRoot(null);
      const gateway = startFakeGateway();
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        const json = parseFxJson(result);
        expect(json.output).toContain("Zig downloads");
        expect(json.output).toContain(SOURCE_URL);
        expect(json.tool_calls).toHaveLength(0);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0].headers.get("ai-language-model-id")).toBe(OUTER_MODEL);
        expect(gateway.requests[0].body).not.toContain('"name":"web_search"');
        expect(gateway.requests[0].body).toContain("gateway.exa_search");
        expect(gateway.requests[0].body).toContain('"name":"exa_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"perplexity_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"parallel_search"');
        expect(gateway.requests[0].body).not.toContain("google/gemini-3-flash");
        expect(gateway.requests[1].headers.get("ai-language-model-id")).toBe(OUTER_MODEL);
        expect(gateway.requests[1].body).toContain(SOURCE_URL);
        expect(result.stderr).toContain("Searching web");
        const initial = parseGatewayRequest(gateway.requests[0]!.body);
        const continuing = parseGatewayRequest(gateway.requests[1]!.body);
        expect(serializedToolNames(initial)).toEqual(
          AUTO_EXA_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES,
        );
        expect(serializedToolNames(continuing)).toEqual(
          AUTO_EXA_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES,
        );
        expect(toolShapesWithoutDescriptions(continuing)).toEqual(
          toolShapesWithoutDescriptions(initial),
        );
        for (const request of [initial, continuing]) {
          expect(findUnavailableCapabilityReferences(request)).toEqual([]);
          expect(customProviderGuidanceState(request)).toEqual({
            providerToolIndices: [13],
            guidanceMessageIndices: [1],
          });
          expect(
            request.prompt?.filter((message) =>
              message.role === "system" && contentText(message.content) === WEB_SEARCH_GUIDANCE
            ),
          ).toHaveLength(1);
        }
        expect(toolByName(initial, "web_fetch")?.description).toContain(
          "broad or current web research",
        );
        expect(toolByName(initial, "web_fetch")?.description).not.toContain(
          "web_search",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "saved search replays restarted segments with their own metadata",
    async () => {
      const model = "anthropic/claude-opus-4.6";
      const root = createIsolatedRoot(null);
      const gateway = startFakeGateway([
        sse([
          { type: "reasoning-start", id: "0" },
          { type: "reasoning-delta", id: "0", delta: "" },
          { type: "reasoning-end", id: "0", providerMetadata: { anthropic: { signature: "before-search" } } },
          { type: "text-start", id: "1" },
          { type: "text-delta", id: "1", delta: "Checking sources. " },
          { type: "text-end", id: "1" },
          { type: "tool-input-start", id: "search-1", toolName: "exa_search" },
          { type: "tool-call", toolCallId: "search-1", toolName: "exa_search", input: { query: "Zig release" }, providerExecuted: true },
          { type: "tool-result", toolCallId: "search-1", result: { results: [{ title: "Zig downloads", url: SOURCE_URL }] } },
          { type: "reasoning-start", id: "0" },
          { type: "reasoning-delta", id: "0", delta: "" },
          { type: "reasoning-end", id: "0", providerMetadata: { anthropic: { signature: "after-search" } } },
          { type: "text-start", id: "1" },
          { type: "text-delta", id: "1", delta: "Found the release information." },
          { type: "text-end", id: "1" },
          { type: "finish", finishReason: { unified: "stop", raw: "end_turn" } },
        ]),
        outerText("The saved search context is available."),
      ], model);
      const env = fakeGatewayEnv(root, gateway, { FX_MODEL: model });
      try {
        const first = await runFx(
          ["ask", "--auto", "--json", "Search the web for the latest Zig release."],
          { cwd: root.workspace, env, timeoutMs: TIMEOUT },
        );
        expect(first.code).toBe(0);
        const saved = JSON.parse(first.stdout.trim());
        expect(saved.final_output).toBe("Checking sources. Found the release information.");
        expect(saved.session_id).toMatch(/^[A-Za-z0-9_-]{12}$/);
        expect(gateway.requests).toHaveLength(1);

        const resumed = await runFx(
          ["ask", "--auto", "--json", "--resume-id", saved.session_id, "Summarize the saved search."],
          { cwd: root.workspace, env, timeoutMs: TIMEOUT },
        );
        expect(resumed.code).toBe(0);
        expect(JSON.parse(resumed.stdout.trim()).final_output).toBe("The saved search context is available.");
        expect(resumed.stderr).toBe("");
        expect(gateway.requests).toHaveLength(2);
        const prompt = JSON.parse(gateway.requests[1]!.body).prompt as Array<{
          role: string;
          content: string | Array<Record<string, any>>;
        }>;
        const parts = prompt.flatMap((message) =>
          Array.isArray(message.content) ? message.content : []
        );
        const reasoning = parts.filter((part) => part.type === "reasoning");
        expect(reasoning.map((part) => part.providerOptions?.anthropic?.signature)).toEqual([
          "before-search",
          "after-search",
        ]);
        const calls = parts.filter((part) => part.type === "tool-call");
        expect(calls.map((part) => [part.toolCallId, part.toolName])).toEqual([
          ["search-1", "exa_search"],
        ]);
        const results = parts.filter((part) => part.type === "tool-result");
        expect(results.map((part) => part.toolCallId)).toEqual(["search-1"]);
        expect(contentText(results[0]!.output)).toContain(SOURCE_URL);
        const text = prompt
          .filter((message) => message.role === "assistant")
          .flatMap((message) => Array.isArray(message.content) ? message.content : [])
          .filter((part) => part.type === "text");
        expect(text.map((part) => part.text).join("")).toBe(
          "Checking sources. Found the release information.",
        );
        expect(first.stdout + resumed.stdout).not.toContain("before-search");
        expect(first.stdout + resumed.stdout).not.toContain("after-search");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "malformed direct provider result identity fails before synthesis",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        malformedDirectProviderResult("exa_search"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(1);
        expect(result.stdout).toContain('"error":"MalformedProviderResultIdentity"');
        expect(gateway.requests).toHaveLength(1);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "malformed direct provider arguments fail before synthesis",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        malformedDirectProviderArguments("exa_search"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(1);
        expect(result.stdout).toContain('"error":"MalformedProviderToolArguments"');
        expect(gateway.requests).toHaveLength(1);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "duplicate authoritative tool ids fail before local redispatch",
    async () => {
      const root = createIsolatedRoot();
      const sideEffectPath = "duplicate-id-side-effect.txt";
      const gateway = startFakeGateway([
        duplicateAuthoritativeWriteCalls(sideEffectPath),
      ]);
      const traceLog = join(root.root, "trace.log");
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Write the requested file."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, {
              FX_TRACE_LOG: traceLog,
              FX_TRACE_SCOPES: "agent,tool",
            }),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(1);
        expect(gateway.requests).toHaveLength(1);
        expect(existsSync(join(root.workspace, sideEffectPath))).toBe(false);
        const trace = readFileSync(traceLog, "utf8");
        expect(trace).toContain(
          "event=authoritative_tool_admission_rejected",
        );
        expect(trace).toContain("failure=ambiguous");
        expect(trace).not.toContain(
          "event=execution_start call_id=duplicate_write_1",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "default ask selects the direct Parallel provider backend",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerDirectProviderSearch("parallel_search"),
        outerFinalAnswer(),
      ], PARALLEL_OUTER_MODEL);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, {
              FX_MODEL: PARALLEL_OUTER_MODEL,
              FX_WEB_SEARCH_BACKEND: "ai_gateway_parallel_search",
            }),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        const json = parseFxJson(result);
        expect(json.tool_calls).toHaveLength(0);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0].headers.get("ai-language-model-id")).toBe(PARALLEL_OUTER_MODEL);
        expect(gateway.requests[0].body).not.toContain('"name":"web_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"exa_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"perplexity_search"');
        expect(gateway.requests[0].body).toContain("gateway.parallel_search");
        expect(gateway.requests[0].body).toContain('"name":"parallel_search"');
        expect(gateway.requests[0].body).not.toContain("gateway.perplexity_search");
        const request = parseGatewayRequest(gateway.requests[0]!.body);
        expect(serializedToolNames(request)).toEqual(
          AUTO_EXA_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES.map((name) =>
            name === "exa_search" ? "parallel_search" : name
          ),
        );
        expect(findUnavailableCapabilityReferences(request)).toEqual([]);
        expect(customProviderGuidanceState(request)).toEqual({
          providerToolIndices: [13],
          guidanceMessageIndices: [1],
        });
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "outer effort is preserved across direct provider search",
    async () => {
      const root = createIsolatedRoot("allow", { effort: "high" });
      const gateway = startFakeGateway(undefined, {
        id: "anthropic/claude-opus-4.6",
        type: "language",
        tags: ["tool-use"],
        reasoning_options: [{ type: "effort", values: ["high"] }],
      });
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, {
              FX_MODEL: "anthropic/claude-opus-4.6",
            }),
            timeoutMs: TIMEOUT,
          },
        );

        parseFxJson(result);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0].body).toContain('"name":"exa_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"perplexity_search"');
        expect(gateway.requests[0].body).not.toContain('"name":"parallel_search"');
        expect(JSON.parse(gateway.requests[0].body)).toMatchObject({ reasoning: "high" });
        expect(JSON.parse(gateway.requests[1].body)).toMatchObject({ reasoning: "high" });
        expect(gateway.requests[0].body).not.toContain('"thinking"');
        expect(gateway.requests[1].body).not.toContain('"thinking"');
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask preserves the exact GLM model while sending declared Fast",
    async () => {
      const root = createIsolatedRoot("allow", {
        model: "zai/glm-5.2",
        fast_mode: true,
      });
      const gateway = startFakeGateway([outerText("GLM fast selected")], {
        id: "zai/glm-5.2",
        type: "language",
        tags: ["tool-use"],
        fast_options: [{ type: "toggle" }],
      });
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Reply with a short confirmation."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, { FX_MODEL: undefined }),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.model).toBe("zai/glm-5.2");
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0].headers.get("ai-language-model-id")).toBe(
          "zai/glm-5.2",
        );
        const request = JSON.parse(gateway.requests[0].body);
        expect(request).not.toHaveProperty("fast");
        expect(request).toMatchObject({
          providerOptions: { gateway: { speed: "fast" } },
        });
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "stale persisted Anthropic efforts are filtered without mutating settings",
    async () => {
      const cases = [
        ...["none", "minimal", "xhigh"].map((effort) => ({ model: "anthropic/claude-opus-4.6", effort })),
        ...["none", "minimal", "xhigh"].map((effort) => ({ model: "anthropic/claude-sonnet-4.6", effort })),
        ...["none", "minimal"].map((effort) => ({ model: "anthropic/claude-opus-4.8", effort })),
        ...["none", "minimal"].map((effort) => ({ model: "anthropic/claude-opus-4.7", effort })),
      ];

      for (const testCase of cases) {
        const root = createIsolatedRoot("allow", {
          effort: testCase.effort,
          fast_mode: true,
        });
        const gateway = startFakeGateway([outerText("stale settings filtered")], testCase.model);
        try {
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", "Reply with a short confirmation."],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, {
                FX_MODEL: testCase.model,
              }),
              timeoutMs: TIMEOUT,
            },
          );

          parseFxJson(result);
          expect(gateway.requests).toHaveLength(1);
          const request = JSON.parse(gateway.requests[0].body);
          expect(request).not.toHaveProperty("reasoning");
          expect(request).not.toHaveProperty("fast");
          expect(request.providerOptions?.gateway).toEqual({ caching: "auto" });
          expect(gateway.requests[0].body).not.toContain('"thinking"');

          const stored = JSON.parse(
            readFileSync(join(root.home, ".fx", "settings.json"), "utf8"),
          );
          expect(stored.effort).toBe(testCase.effort);
          expect(stored.fast_mode).toBe(true);
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "unknown direct provider backend selector fails before a Gateway request",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway();
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search the web for the latest Zig release."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, {
              FX_WEB_SEARCH_BACKEND: "parallel_search",
            }),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(1);
        expect(gateway.requests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "explicit ask and deny omit direct provider search",
    async () => {
      for (const permission of ["ask", "deny"] as const) {
        const root = createIsolatedRoot(permission);
        const gateway = startFakeGateway([outerText("search capability unavailable")]);
        try {
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", "Search current Zig release information."],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway),
              timeoutMs: TIMEOUT,
            },
          );

          const json = parseFxJson(result);
          expect(json.output).toContain("search capability unavailable");
          expect(json.tool_calls).toHaveLength(0);
          expect(gateway.requests).toHaveLength(1);
          expect(gateway.requests[0].body).not.toContain("gateway.exa_search");
          expect(gateway.requests[0].body).not.toContain("gateway.perplexity_search");
          expect(gateway.requests[0].body).not.toContain("gateway.parallel_search");
          expect(gateway.requests[0].body).not.toContain('"name":"web_search"');
          const request = parseGatewayRequest(gateway.requests[0]!.body);
          expect(serializedToolNames(request)).toEqual(
            AUTO_EXA_WITHOUT_DURABLE_TOOLS_SERIALIZED_TOOL_NAMES.filter((name) =>
              name !== "exa_search"
            ),
          );
          expect(findUnavailableCapabilityReferences(request)).toEqual([]);
          expect(customProviderGuidanceState(request)).toEqual({
            providerToolIndices: [],
            guidanceMessageIndices: [],
          });
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "direct provider may return zero results without a worker retry",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerDirectProviderSearch("exa_search", { results: [] }),
        outerText("zero search handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Search only if needed."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.output).toContain("zero search handled");
        expect(json.tool_calls).toHaveLength(0);
        expect(gateway.requests).toHaveLength(2);
        expect(result.stderr).toContain("Searching web");
        expect(result.stderr).not.toContain("Found ");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "default fx ask applies environment model, permission, and step-limit overrides",
    async () => {
      const root = createIsolatedRoot(null, {
        model: OUTER_MODEL,
        permission_mode: "ask",
        max_agent_steps: 9,
      });
      const gateway = startFakeGateway([
        outerToolCalls([{
          id: "write_outer_1",
          name: "write_file",
          input: { path: "env-proof.txt", content: "environment overrides applied" },
        }]),
      ]);
      try {
        const result = await runFx(
          ["ask", "Write the environment override proof file."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, {
              FX_MODEL: PARALLEL_OUTER_MODEL,
              FX_PERMISSION_MODE: "auto",
              FX_MAX_AGENT_STEPS: "1",
            }),
            timeoutMs: TIMEOUT,
          },
        );

        expect(gateway.requests).toHaveLength(1);
        expect(result.code).toBe(1);
        expect(result.stdout).toBe("");
        expect(result.stderr).toContain("Agent step limit reached");
        expect(gateway.requests[0].headers.get("ai-language-model-id")).toBe(PARALLEL_OUTER_MODEL);
        expect(readFileSync(join(root.workspace, "env-proof.txt"), "utf8")).toBe(
          "environment overrides applied",
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP completes direct provider search without native progress events",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway();
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        await startAcpCodeSession(client);
        const messages = await runAcpPrompt(client, "Search the web for the latest Zig release.");
        const updates = JSON.stringify(messages);
        const toolUpdates = messages
          .filter((message: any) => message.params?.update?.toolCallId === "search_direct_1")
          .map((message: any) => message.params.update);

        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[0].body).toContain("gateway.exa_search");
        expect(gateway.requests[0].body).not.toContain('"name":"web_search"');
        const initial = parseGatewayRequest(gateway.requests[0]!.body);
        const continuing = parseGatewayRequest(gateway.requests[1]!.body);
        for (const request of [initial, continuing]) {
          expect(findUnavailableCapabilityReferences(request)).toEqual([]);
          expect(customProviderGuidanceState(request).guidanceMessageIndices).toEqual([1]);
        }
        expect(toolShapesWithoutDescriptions(continuing)).toEqual(
          toolShapesWithoutDescriptions(initial),
        );
        expect(updates).not.toContain("Searching latest Zig release");
        expect(updates).not.toContain("Found 1 result for latest Zig release");
        expect(toolUpdates).toHaveLength(2);
        expect(toolUpdates[0]).toEqual({
          sessionUpdate: "tool_call",
          toolCallId: "search_direct_1",
          name: "web_search",
          title: "Searching web",
          kind: "search",
          status: "pending",
          rawInput: {},
        });
        expect(toolUpdates[1]?.sessionUpdate).toBe("tool_call_update");
        expect(toolUpdates[1]?.status).toBe("completed");
        expect(updates).not.toContain("exa_search");
        expect(updates).not.toContain("perplexity_search");
        expect(updates).not.toContain("parallel_search");
        expect(updates).toContain(SOURCE_URL);
      } finally {
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP cancel interrupts an active direct provider stream and leaves the server usable",
    async () => {
      const root = createIsolatedRoot();
      const hanging = hangingSseResponse();
      const gateway = startFakeGateway([
        hanging.response,
      ]);
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        await startAcpCodeSession(client);
        client.send({
          jsonrpc: "2.0",
          id: 10,
          method: "session/prompt",
          params: { prompt: [{ type: "text", text: "Search the web for the latest Zig release." }] },
        });
        await waitFor(() => gateway.requests.length === 1);

        client.send({ jsonrpc: "2.0", method: "session/cancel", params: {} });
        const cancelled = await readAcpResponse(client, 10);
        expect(cancelled.result.stopReason).toBe("cancelled");

        client.send({ jsonrpc: "2.0", id: 11, method: "session/list", params: {} });
        const list = await readAcpResponse(client, 11);
        expect(Array.isArray(list.result.sessions)).toBe(true);
      } finally {
        hanging.close();
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP policy denial omits direct provider search",
    async () => {
      const root = createIsolatedRoot("deny");
      const gateway = startFakeGateway([
        outerText("ACP search denial handled"),
      ]);
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        await startAcpCodeSession(client);
        const messages = await runAcpPrompt(client, "Issue denied web search.");

        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0].body).not.toContain("gateway.exa_search");
        expect(gateway.requests[0].body).not.toContain("gateway.perplexity_search");
        expect(gateway.requests[0].body).not.toContain('"name":"web_search"');
        const request = parseGatewayRequest(gateway.requests[0]!.body);
        expect(findUnavailableCapabilityReferences(request)).toEqual([]);
        expect(customProviderGuidanceState(request)).toEqual({
          providerToolIndices: [],
          guidanceMessageIndices: [],
        });
        expect(JSON.stringify(messages)).not.toContain("Found 1 result");
      } finally {
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

});
