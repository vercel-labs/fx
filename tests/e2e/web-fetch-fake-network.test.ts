import { describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  watch,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { FX_BIN, fxChildEnv, runFx } from "../evals/eval-helpers";
import { LineQueue } from "./line-queue";
import { savedText } from "./saved-sessions";
import { fakeGatewayTitleDefault, TITLE_GENERATION_MARKER } from "./tmux-helpers";

const TIMEOUT = 20_000;
const FETCH_URL = "https://example.com/docs";
const OUTER_MODEL = "openai/gpt-5";
const PROVIDER_MODELS = [
  "anthropic/claude-sonnet-4.6",
  "openai/gpt-5",
  "google/gemini-3-pro",
  "xai/grok-4",
] as const;

type GatewayRequest = {
  body: string;
  headers: Headers;
};

type PermissionAction = "allow" | "deny" | null;

function sse(events: object[], done = true) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      (done ? "data: [DONE]\n\n" : ""),
    { headers: { "content-type": "text/event-stream" } },
  );
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

function outerWebFetchCall(input: object = { url: FETCH_URL }) {
  return outerToolCalls([{ id: "fetch_outer_1", name: "web_fetch", input }]);
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

function startFakeGateway(
  responses: Response[] = [outerText("schema advertised")],
  model = OUTER_MODEL,
) {
  const requests: GatewayRequest[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: PROVIDER_MODELS.map((id) => ({
            id,
            type: "language",
            tags: ["tool-use"],
          })),
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes(TITLE_GENERATION_MARKER)) return fakeGatewayTitleDefault();
      requests.push({ body, headers: req.headers });
      return responses.shift() ?? new Response("unexpected request", { status: 500 });
    },
  });

  return {
    chatUrl: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    baseUrl: `http://127.0.0.1:${server.port}`,
    model,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot(args: {
  webFetchPermission?: PermissionAction;
  permission?: Record<string, unknown>;
} = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-web-fetch-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });

  const permission: Record<string, Record<string, string>> = {};
  if (args.webFetchPermission) {
    permission.web_fetch = { "domain:example.com": args.webFetchPermission };
  }
  const settings = { permission: args.permission ?? permission };
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(settings));
  return { root, home, workspace: realpathSync(workspace) };
}

function fakeGatewayEnv(
  root: ReturnType<typeof createIsolatedRoot>,
  gateway: ReturnType<typeof startFakeGateway>,
  extra: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-web-fetch-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: gateway.model,
    ...extra,
  };
}

function parseFxJson(result: Awaited<ReturnType<typeof runFx>>) {
  expect(result.code).toBe(0);
  return JSON.parse(result.stdout.trim()) as {
    output: string;
    session_id: string;
    tool_calls: Array<{
      name: string;
      status: string;
      web_fetch?: {
        url: string;
        bytes: number;
        status: number;
        duration_ms: number;
        cache_hit: boolean;
        artifact: "none" | "stored" | "unavailable";
      };
    }>;
  };
}

function requestJson(request: GatewayRequest) {
  return JSON.parse(request.body) as {
    tools: Array<{
      type: string;
      name: string;
      description: string;
      inputSchema: {
        type: string;
        properties: Record<string, { type: string; description?: string }>;
        required?: string[];
        additionalProperties?: boolean;
      };
    }>;
  };
}

function toolSchema(body: ReturnType<typeof requestJson>, name: string) {
  return body.tools.find((tool) => tool.name === name);
}

function expectWebFetchSchema(request: GatewayRequest) {
  const schema = toolSchema(requestJson(request), "web_fetch");
  expect(schema).toBeDefined();
  expect(schema?.type).toBe("function");
  expect(schema?.inputSchema.type).toBe("object");
  expect(schema?.inputSchema.properties.url.type).toBe("string");
  expect(schema?.inputSchema.properties.prompt).toBeUndefined();
  expect(schema?.inputSchema.required).toEqual(["url"]);
  expect(schema?.inputSchema.additionalProperties).toBe(false);
}

function expectNoFetchProgress(text: string) {
  expect(text).not.toContain("Fetching ");
  expect(text).not.toContain("Converting ");
  expect(text).not.toContain("Extracting ");
}

class AcpClient {
  private buffer = "";
  private queue = new LineQueue();
  private closed = false;
  private activeSessionId: string | null = null;
  private stderrChunks: Buffer[] = [];

  private constructor(private proc: ChildProcess) {
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const parts = this.buffer.split("\n");
      this.buffer = parts.pop() ?? "";
      for (const line of parts) {
        if (!line.trim()) continue;
        this.queue.push(line);
      }
    });
    proc.stderr!.on("data", (chunk: Buffer) => {
      this.stderrChunks.push(chunk);
    });
    proc.on("close", () => {
      this.closed = true;
    });
  }

  get stderr(): string {
    return Buffer.concat(this.stderrChunks).toString("utf8");
  }

  endStdin() {
    this.proc.stdin!.end();
  }

  async waitForExit(timeoutMs = TIMEOUT): Promise<number | null> {
    if (this.proc.exitCode !== null) return this.proc.exitCode;
    return await new Promise<number | null>((resolve, reject) => {
      const signal = AbortSignal.timeout(timeoutMs);
      const onAbort = () => reject(new Error(`ACP process did not exit within ${timeoutMs}ms`));
      signal.addEventListener("abort", onAbort, { once: true });
      this.proc.once("close", (code) => {
        signal.removeEventListener("abort", onAbort);
        resolve(code);
      });
    });
  }

  static create(cwd: string, env: Record<string, string | undefined>) {
    const definedEnv = Object.fromEntries(
      Object.entries(fxChildEnv({ NO_COLOR: "1", ...env })).filter(
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
    const line = await this.queue.next(timeoutMs, () => new Error("ACP read timeout"));
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
  await client.request("session/set_mode", { modeId: "auto" }, 3);
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

describe("web_fetch Gateway fixture", () => {
  test(
    "representative providers receive the same strict public web_fetch schema",
    async () => {
      for (const model of PROVIDER_MODELS) {
        const root = createIsolatedRoot();
        const gateway = startFakeGateway([outerText(`schema ok for ${model}`)], model);
        try {
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", "Say schema ok."],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway),
              timeoutMs: TIMEOUT,
            },
          );

          parseFxJson(result);
          expect(gateway.requests).toHaveLength(1);
          expect(gateway.requests[0].headers.get("ai-language-model-id")).toBe(model);
          expectWebFetchSchema(gateway.requests[0]);
          expect(gateway.requests[0].body).toContain("gateway.exa_search");
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "invalid credentialed web_fetch persists the URL verbatim",
    async () => {
      const root = createIsolatedRoot({ webFetchPermission: "allow" });
      const gateway = startFakeGateway([
        outerWebFetchCall({
          url: "https://user:pass@example.com/docs",
        }),
        outerText("validation failure handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "Issue invalid credentialed web_fetch."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.tool_calls).toContainEqual({
          name: "web_fetch",
          status: "error",
        });
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("credential-bearing URLs");
        expectNoFetchProgress(result.stderr);

        const sessionEvents = savedText(root.home, json.session_id);
        expect(sessionEvents).toContain("web_fetch");
        expect(sessionEvents).toContain("https://user:pass@example.com/docs");
        expect(sessionEvents).not.toContain("[redacted]");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "default policy validates malformed web_fetch before transport",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerWebFetchCall({ url: FETCH_URL, prompt: "legacy" }),
        outerText("validation failure handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Issue malformed web_fetch."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(json.tool_calls).toContainEqual({ name: "web_fetch", status: "error" });
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("web_fetch field");
        expect(gateway.requests[1].body).toContain("prompt");
        expect(gateway.requests[1].body).not.toContain("permission_required");
        expectNoFetchProgress(result.stderr);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "default fx ask validates malformed web_fetch before transport",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerWebFetchCall({ url: FETCH_URL, prompt: "legacy" }),
        outerText("direct validation handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "Issue malformed web_fetch."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("web_fetch field");
        expect(gateway.requests[1].body).toContain("prompt");
        expect(gateway.requests[1].body).not.toContain("permission_required");
        expectNoFetchProgress(result.stderr);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "auto parallel invalid web_fetch does not suppress a valid read_file sibling",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(join(root.workspace, "fixture.txt"), "parallel sibling read");
      const gateway = startFakeGateway([
        outerToolCalls([
          { id: "fetch_outer_1", name: "web_fetch", input: { url: "https://example.com/docs", prompt: "legacy" } },
          { id: "read_outer_1", name: "read_file", input: { path: "fixture.txt" } },
        ]),
        outerText("parallel invalid handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Issue malformed web_fetch and a sibling read."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        parseFxJson(result);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("web_fetch field");
        expect(gateway.requests[1].body).toContain("prompt");
        expect(gateway.requests[1].body).toContain("not allowed");
        expect(gateway.requests[1].body).toContain("parallel sibling read");
        expectNoFetchProgress(result.stderr);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "parallel fallback reports invalid web_fetch once in Ask JSON",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(join(root.workspace, "fixture.txt"), "parallel fallback read");
      const repeatedRead = { name: "read_file", input: { path: "fixture.txt" } };
      const gateway = startFakeGateway([
        outerToolCalls([
          {
            id: "fetch_outer_1",
            name: "web_fetch",
            input: { url: "https://example.com/docs", prompt: "legacy" },
          },
          { id: "read_outer_1", ...repeatedRead },
          { id: "read_outer_2", ...repeatedRead },
          { id: "read_outer_3", ...repeatedRead },
        ]),
        outerText("parallel fallback handled"),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Issue invalid fetch and repeated reads."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        const json = parseFxJson(result);
        expect(
          json.tool_calls.filter((call) => call.name === "web_fetch"),
        ).toEqual([{ name: "web_fetch", status: "error" }]);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "parallel fallback emits one invalid web_fetch ACP lifecycle",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(join(root.workspace, "fixture.txt"), "parallel fallback read");
      const repeatedRead = { name: "read_file", input: { path: "fixture.txt" } };
      const gateway = startFakeGateway([
        outerToolCalls([
          {
            id: "fetch_outer_1",
            name: "web_fetch",
            input: { url: "https://example.com/docs", prompt: "legacy" },
          },
          { id: "read_outer_1", ...repeatedRead },
          { id: "read_outer_2", ...repeatedRead },
          { id: "read_outer_3", ...repeatedRead },
        ]),
        outerText("parallel fallback handled"),
      ]);
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        await startAcpCodeSession(client);
        const messages = await runAcpPrompt(
          client,
          "Issue invalid fetch and repeated reads.",
        );
        const fetchStarts = messages.filter(
          (message) =>
            message.method === "session/update" &&
            message.params?.update?.sessionUpdate === "tool_call" &&
            message.params.update.toolCallId === "fetch_outer_1",
        );

        expect(fetchStarts).toHaveLength(1);
        expect(fetchStarts[0]?.params.update).toEqual({
          sessionUpdate: "tool_call",
          toolCallId: "fetch_outer_1",
          name: "web_fetch",
          title: "Fetching",
          kind: "fetch",
          status: "pending",
          rawInput: {
            url: "https://example.com/docs",
            prompt: "legacy",
          },
          _meta: { fx: { toolCall: { internal: false } } },
        });
      } finally {
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP explicit deny emits no web_fetch progress or target request",
    async () => {
      const root = createIsolatedRoot({ webFetchPermission: "deny" });
      const gateway = startFakeGateway([
        outerWebFetchCall(),
        outerText("ACP fetch denial handled"),
      ]);
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        await startAcpCodeSession(client);
        const messages = await runAcpPrompt(client, "Issue denied web_fetch.");
        const updates = JSON.stringify(messages);

        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1].body).toContain("policy_denied");
        expect(updates).not.toContain("Fetching ");
        expect(updates).not.toContain("Converting ");
        expect(updates).not.toContain("Extracting ");
      } finally {
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  for (const [name, permission] of [
    ["ACP wildcard deny refuses web_fetch before any target request", { "*": "deny" }],
    ["ACP web_fetch deny refuses every host before any target request", { web_fetch: "deny" }],
  ] as const) {
    test(
      name,
      async () => {
        const root = createIsolatedRoot({ permission });
        const gateway = startFakeGateway([
          outerWebFetchCall(),
          outerText("ACP fetch denial handled"),
        ]);
        const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
        try {
          await startAcpCodeSession(client);
          const messages = await runAcpPrompt(client, "Issue denied web_fetch.");
          const updates = JSON.stringify(messages);

          expect(gateway.requests).toHaveLength(2);
          expect(gateway.requests[1].body).toContain("policy_denied");
          expect(updates).not.toContain("Fetching ");
          expect(updates).not.toContain("Converting ");
          expect(updates).not.toContain("Extracting ");
        } finally {
          await client.close();
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  }

  test(
    "fx ask SIGINT cancels web_fetch during a stalled DNS lookup within 1 s",
    async () => {
      const root = createIsolatedRoot({ webFetchPermission: "allow" });
      const boundary = createDnsBoundary(root.root);
      const gateway = startFakeGateway([
        outerWebFetchCall(),
        outerText("unexpected completion after SIGINT"),
      ]);
      const env = Object.fromEntries(
        Object.entries({
          ...process.env,
          ...fakeGatewayEnv(root, gateway, {
            FX_SOUND: "0",
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            ...boundary.env,
          }),
        }).filter((entry): entry is [string, string] => entry[1] !== undefined),
      );
      const proc = Bun.spawn([FX_BIN, "ask", "--auto", "--json", "--no-save", "Fetch docs."], {
        cwd: root.workspace,
        env,
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
      });
      const output = Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
      let forced = false;
      const watchdog = AbortSignal.timeout(1_000);
      const onWatchdog = () => {
        forced = true;
        proc.kill("SIGKILL");
      };
      try {
        await waitForMarkerFile(boundary.ready, 5_000);
        watchdog.addEventListener("abort", onWatchdog, { once: true });
        proc.kill("SIGINT");
        const exitCode = await proc.exited;
        watchdog.removeEventListener("abort", onWatchdog);
        await output;
        expect(forced).toBe(false);
        expect(exitCode).toBe(130);
      } finally {
        watchdog.removeEventListener("abort", onWatchdog);
        releaseDnsBoundary(boundary);
        if (proc.exitCode === null) proc.kill("SIGKILL");
        await proc.exited;
        await output;
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP session/cancel cancels web_fetch during a stalled DNS lookup within 1 s",
    async () => {
      const root = createIsolatedRoot({ webFetchPermission: "allow" });
      const boundary = createDnsBoundary(root.root);
      const gateway = startFakeGateway([
        outerWebFetchCall(),
        outerText("unexpected completion after session/cancel"),
      ]);
      const client = AcpClient.create(root.workspace, {
        ...fakeGatewayEnv(root, gateway),
        ...boundary.env,
      });
      try {
        await startAcpCodeSession(client);
        client.send({
          jsonrpc: "2.0",
          id: 10,
          method: "session/prompt",
          params: { prompt: [{ type: "text", text: "Fetch docs." }] },
        });
        await waitForMarkerFile(boundary.ready, 5_000);

        client.send({ jsonrpc: "2.0", id: 11, method: "session/cancel", params: {} });
        let promptResp: any = null;
        const deadline = Date.now() + 1_000;
        while (!promptResp) {
          const remaining = deadline - Date.now();
          if (remaining <= 0) throw new Error("ACP session/prompt did not cancel within 1000ms");
          const msg = await client.readLine(remaining);
          if (msg.id === 10) promptResp = msg;
        }
        expect(promptResp.result.stopReason).toBe("cancelled");

        client.endStdin();
        expect(await client.waitForExit(1_000)).toBe(0);
        expect(client.stderr).toBe("");
      } finally {
        releaseDnsBoundary(boundary);
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP EOF cancels web_fetch during a stalled DNS lookup within 1 s",
    async () => {
      const root = createIsolatedRoot({ webFetchPermission: "allow" });
      const boundary = createDnsBoundary(root.root);
      const gateway = startFakeGateway([
        outerWebFetchCall(),
        outerText("unexpected completion after EOF"),
      ]);
      const client = AcpClient.create(root.workspace, {
        ...fakeGatewayEnv(root, gateway),
        ...boundary.env,
      });
      try {
        await startAcpCodeSession(client);
        client.send({
          jsonrpc: "2.0",
          id: 10,
          method: "session/prompt",
          params: { prompt: [{ type: "text", text: "Fetch docs." }] },
        });
        await waitForMarkerFile(boundary.ready, 5_000);

        client.endStdin();
        expect(await client.waitForExit(1_000)).toBe(0);
        expect(client.stderr).toBe("");
      } finally {
        releaseDnsBoundary(boundary);
        await client.close();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

});

function createDnsBoundary(root: string) {
  const ready = join(root, "dns.ready");
  const release = join(root, "dns.release");
  return {
    ready,
    release,
    env: {
      FX_TEST_WEB_FETCH_DNS_READY: ready,
      FX_TEST_WEB_FETCH_DNS_RELEASE: release,
    },
  };
}

function releaseDnsBoundary(boundary: ReturnType<typeof createDnsBoundary>) {
  if (!existsSync(boundary.release)) writeFileSync(boundary.release, "release\n");
}

async function waitForMarkerFile(path: string, timeoutMs = 5_000): Promise<void> {
  if (existsSync(path)) return;
  const dir = dirname(path);
  const base = basename(path);
  await new Promise<void>((resolve, reject) => {
    const signal = AbortSignal.timeout(timeoutMs);
    const onAbort = () => {
      watcher.close();
      reject(new Error(`Timed out waiting for ${path}`));
    };
    const watcher = watch(dir, (_event, filename) => {
      if ((filename === null || filename === base) && existsSync(path)) {
        signal.removeEventListener("abort", onAbort);
        watcher.close();
        resolve();
      }
    });
    signal.addEventListener("abort", onAbort, { once: true });
    if (existsSync(path)) {
      signal.removeEventListener("abort", onAbort);
      watcher.close();
      resolve();
    }
  });
}

describe("the ACP test client's reader", () => {
  test("a read that timed out does not take the next line", async () => {
    // A stand-in for `fx acp`: no fx runs.
    const proc = Object.assign(new EventEmitter(), {
      stdout: new EventEmitter(),
      stderr: new EventEmitter(),
      stdin: { write() {} },
    });
    const client = new (AcpClient as any)(proc);
    await expect(client.readLine(30)).rejects.toThrow("ACP read timeout");
    proc.stdout.emit("data", Buffer.from(`${JSON.stringify({ id: 7, result: {} })}\n`));
    expect(await client.readLine(500)).toEqual({ id: 7, result: {} });
  });
});
