import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";

const TIMEOUT = 30_000;
const MODEL = "gemini-4-hydrogen";
const TITLE_MODEL = "gemini-3.5-flash-lite";
const TEST_API_KEY = "AIza-fake-gemini-key-for-e2e-tests";

type SseEvent = readonly [name: string, data: string | Record<string, unknown>];

type RecordedRequest = {
  method: string;
  path: string;
  query: string;
  headers: Headers;
  rawBody: string;
  body: any;
};

type FakeGeminiHandler = (
  request: RecordedRequest,
  conversationIndex: number,
) => Response | Promise<Response>;

function formatSse(events: readonly SseEvent[]): string {
  return events
    .map(([name, data]) => `event: ${name}\ndata: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`)
    .join("");
}

function sseResponse(events: readonly SseEvent[]): Response {
  return new Response(formatSse(events), {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

function textTurnResponse(
  text: string,
  options: {
    interactionId?: string;
    thought?: { signature: string; summary: string };
  } = {},
): Response {
  const id = options.interactionId ?? "int_text_1";
  const events: SseEvent[] = [
    ["interaction.created", {
      event_type: "interaction.created",
      interaction: { id, status: "in_progress", object: "interaction", model: MODEL },
    }],
  ];
  let index = 0;
  if (options.thought) {
    events.push(
      ["step.start", { event_type: "step.start", index, step: { type: "thought" } }],
      ["step.delta", {
        event_type: "step.delta",
        index,
        delta: { type: "thought_summary", content: { type: "text", text: options.thought.summary } },
      }],
      ["step.delta", {
        event_type: "step.delta",
        index,
        delta: { type: "thought_signature", signature: options.thought.signature },
      }],
      ["step.stop", { event_type: "step.stop", index }],
    );
    index += 1;
  }
  events.push(
    ["step.start", { event_type: "step.start", index, step: { type: "model_output" } }],
    ["step.delta", { event_type: "step.delta", index, delta: { type: "text", text } }],
    ["step.stop", { event_type: "step.stop", index }],
    ["interaction.completed", {
      event_type: "interaction.completed",
      interaction: { id, status: "completed", usage: { total_input_tokens: 12, total_output_tokens: 6 } },
    }],
    ["done", "[DONE]"],
  );
  return sseResponse(events);
}

function thoughtAndToolCallResponse(params: {
  interactionId?: string;
  thoughtSignature: string;
  thoughtSummary: string;
  callId: string;
  toolName: string;
  args: Record<string, unknown>;
}): Response {
  const id = params.interactionId ?? "int_tool_1";
  return sseResponse([
    ["interaction.created", {
      event_type: "interaction.created",
      interaction: { id, status: "in_progress", object: "interaction", model: MODEL },
    }],
    ["step.start", { event_type: "step.start", index: 0, step: { type: "thought" } }],
    ["step.delta", {
      event_type: "step.delta",
      index: 0,
      delta: { type: "thought_summary", content: { type: "text", text: params.thoughtSummary } },
    }],
    ["step.delta", {
      event_type: "step.delta",
      index: 0,
      delta: { type: "thought_signature", signature: params.thoughtSignature },
    }],
    ["step.stop", { event_type: "step.stop", index: 0 }],
    ["step.start", {
      event_type: "step.start",
      index: 1,
      step: { type: "function_call", id: params.callId, name: params.toolName, arguments: params.args },
    }],
    ["step.stop", { event_type: "step.stop", index: 1 }],
    ["interaction.completed", {
      event_type: "interaction.completed",
      interaction: { id, status: "requires_action", usage: { total_input_tokens: 18, total_output_tokens: 11 } },
    }],
    ["done", "[DONE]"],
  ]);
}

function isTitleGenerationRequest(body: any): boolean {
  return (
    body?.model === TITLE_MODEL &&
    typeof body?.system_instruction === "string" &&
    body.system_instruction.includes("Generate a short title")
  );
}

const roots: string[] = [];
const servers: Array<{ stop(closeActiveConnections?: boolean): void }> = [];

afterEach(() => {
  for (const server of servers.splice(0)) server.stop(true);
  for (const root of roots.splice(0)) cleanupIsolatedTestHome(root);
});

function createGeminiFixture(handler: FakeGeminiHandler) {
  const root = realpathSync(createIsolatedTestHome());
  roots.push(root);
  const home = join(root, "home");
  const fxHome = join(root, "fx-home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(fxHome, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), "{}\n");

  const requests: RecordedRequest[] = [];
  const titleRequests: RecordedRequest[] = [];
  const allRequests: RecordedRequest[] = [];

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const rawBody = await request.text();
      let body: any = null;
      if (rawBody.length > 0) {
        try {
          body = JSON.parse(rawBody);
        } catch {
          body = rawBody;
        }
      }
      const recorded: RecordedRequest = {
        method: request.method,
        path: url.pathname,
        query: url.search,
        headers: new Headers(request.headers),
        rawBody,
        body,
      };
      allRequests.push(recorded);
      if (isTitleGenerationRequest(body)) {
        titleRequests.push(recorded);
        return textTurnResponse("Saved Gemini Session", { interactionId: `int_title_${titleRequests.length}` });
      }
      const index = requests.length;
      requests.push(recorded);
      return handler(recorded, index);
    },
  });
  servers.push(server);

  const baseUrl = `http://127.0.0.1:${server.port}`;
  const env: Record<string, string | undefined> = {
    HOME: home,
    FX_HOME: fxHome,
    GEMINI_API_KEY: TEST_API_KEY,
    FX_TEST_GEMINI_BASE_URL: baseUrl,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_MODEL: undefined,
    FX_PROVIDER: undefined,
    FX_GATEWAY_BASE_URL: undefined,
    FX_GATEWAY_CHAT_URL: undefined,
  };

  return { root, home, fxHome, workspace, baseUrl, env, requests, titleRequests, allRequests };
}

function collectFilesRecursively(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...collectFilesRecursively(full));
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

describe("Google provider (Gemini API key)", () => {
  test("streams text to stdout with required /v1beta/interactions headers and body shape", async () => {
    const f = createGeminiFixture(() => textTurnResponse("Hello from fake Gemini!"));

    const result = await runFx(
      ["ask", "--provider", "google", "--no-save", "Say hello"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    expect(result.stdout).toContain("Hello from fake Gemini!");
    expect(f.requests).toHaveLength(1);

    const req = f.requests[0]!;
    expect(req.method).toBe("POST");
    expect(req.path).toBe("/v1beta/interactions");
    expect(req.query).toBe("");
    expect(req.headers.get("x-goog-api-key")).toBe(TEST_API_KEY);
    expect(req.headers.get("authorization")).toBeNull();
    expect(req.headers.get("dpop")).toBeNull();
    expect(req.headers.get("x-goog-user-project")).toBeNull();
    expect(req.headers.get("user-agent")?.startsWith("fx/")).toBe(true);

    expect(req.body.model).toBe(MODEL);
    expect(req.body.store).toBe(false);
    expect(req.body.stream).toBe(true);
    expect(req.body.max_output_tokens).toBeUndefined();
    expect(req.body.generation_config?.max_output_tokens).toBeUndefined();
  }, TIMEOUT);

  test("replays signed thought step in order across a read_file tool call", async () => {
    const f = createGeminiFixture((_req, index) => {
      if (index === 0) {
        return thoughtAndToolCallResponse({
          interactionId: "int_tool_1",
          thoughtSignature: "sig-1",
          thoughtSummary: "Inspecting note.txt first.",
          callId: "call_read_1",
          toolName: "read_file",
          args: { path: "note.txt" },
        });
      }
      return textTurnResponse("Read note.txt successfully.", { interactionId: "int_tool_2" });
    });

    writeFileSync(join(f.workspace, "note.txt"), "gemini-tool-note-contents\n");

    const result = await runFx(
      ["ask", "--provider", "google", "--no-save", "Read note.txt"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Read note.txt successfully.");
    expect(f.requests).toHaveLength(2);

    const input = f.requests[1]!.body.input;
    expect(Array.isArray(input)).toBe(true);
    expect(input).toHaveLength(4);

    expect(input[0].type).toBe("user_input");
    expect(JSON.stringify(input[0].content)).toContain("Read note.txt");

    expect(input[1]).toEqual({
      type: "thought",
      signature: "sig-1",
      summary: [{ type: "text", text: "Inspecting note.txt first." }],
    });

    expect(input[2].type).toBe("function_call");
    expect(input[2].id).toBe("call_read_1");
    expect(input[2].name).toBe("read_file");

    expect(input[3].type).toBe("function_result");
    expect(input[3].call_id).toBe("call_read_1");
    expect(input[3].name).toBe("read_file");
    expect(input[3].is_error).toBe(false);
    expect(JSON.stringify(input[3].result)).toContain("gemini-tool-note-contents");
  }, TIMEOUT);

  test("replays signed thought step after resuming a saved session without leaking the API key", async () => {
    const f = createGeminiFixture((_req, index) => {
      if (index === 0) {
        return textTurnResponse("First saved answer.", {
          interactionId: "int_save_1",
          thought: { signature: "sig-2", summary: "Reasoning on first saved turn." },
        });
      }
      return textTurnResponse("Resumed answer.", { interactionId: "int_save_2" });
    });

    const first = await runFx(
      ["ask", "--provider", "google", "--json", "First saved prompt"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );
    expect(first.code).toBe(0);
    const saved = JSON.parse(first.stdout);
    expect(saved.final_output).toBe("First saved answer.");
    expect(typeof saved.session_id).toBe("string");
    expect(saved.session_id.length).toBeGreaterThan(0);

    const resumed = await runFx(
      ["ask", "--provider", "google", "--resume", saved.session_id, "Follow-up after resume"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );
    expect(resumed.code).toBe(0);
    expect(resumed.stdout).toContain("Resumed answer.");
    expect(f.requests).toHaveLength(2);

    const resumedInput = f.requests[1]!.body.input;
    expect(resumedInput.map((step: any) => step.type)).toEqual([
      "user_input",
      "thought",
      "model_output",
      "user_input",
    ]);
    expect(resumedInput[1]).toEqual({
      type: "thought",
      signature: "sig-2",
      summary: [{ type: "text", text: "Reasoning on first saved turn." }],
    });
    expect(JSON.stringify(resumedInput[2].content)).toContain("First saved answer.");
    expect(JSON.stringify(resumedInput[3].content)).toContain("Follow-up after resume");

    const fxHomeFiles = collectFilesRecursively(f.fxHome);
    const sessionFiles = fxHomeFiles.filter((file) => file.includes("/sessions/"));
    expect(sessionFiles.length).toBeGreaterThan(0);
    for (const file of fxHomeFiles) {
      expect(readFileSync(file, "utf8")).not.toContain(TEST_API_KEY);
    }
  }, TIMEOUT);

  test("429 daily-limit reply with RetryInfo exits non-zero, names model and resets in, with no upgrade link", async () => {
    const f = createGeminiFixture(() =>
      Response.json(
        {
          error: {
            code: "too_many_requests",
            message:
              "You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models.",
            details: [
              {
                "@type": "type.googleapis.com/google.rpc.RetryInfo",
                retryDelay: "19104s",
              },
            ],
          },
        },
        { status: 429 },
      ),
    );

    const result = await runFx(
      ["ask", "--provider", "google", "--no-save", "Trigger daily limit"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );

    expect(result.code).not.toBe(0);
    expect(f.requests).toHaveLength(1);
    const combined = `${result.stderr}\n${result.stdout}`;
    expect(combined).toContain(MODEL);
    expect(combined).toContain("resets in");
    expect(combined).not.toContain("one.google.com");
    expect(combined.toLowerCase()).not.toContain("upgrade");
  }, TIMEOUT);

  test("stream closing before interaction.completed fails without returning partial text as a final answer", async () => {
    const partialText = "PARTIAL_STREAM_TEXT_NOT_FINAL";
    const f = createGeminiFixture(() =>
      sseResponse([
        ["interaction.created", {
          event_type: "interaction.created",
          interaction: { id: "int_cut_1", status: "in_progress", object: "interaction", model: MODEL },
        }],
        ["step.start", { event_type: "step.start", index: 0, step: { type: "model_output" } }],
        ["step.delta", { event_type: "step.delta", index: 0, delta: { type: "text", text: partialText } }],
      ]),
    );

    const result = await runFx(
      ["ask", "--provider", "google", "--json", "--no-save", "Cut the stream early"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );

    expect(result.code).not.toBe(0);
    expect(f.requests).toHaveLength(1);
    const parsed = JSON.parse(result.stdout);
    expect(parsed.exit_code).not.toBe(0);
    expect(parsed.final_output).toBe("");
    expect(parsed.error).toBe("IncompleteStream");
  }, TIMEOUT);

  test("unsupported --effort minimal on gemini-4-hydrogen never sends thinking_level minimal", async () => {
    const f = createGeminiFixture(() => textTurnResponse("Effort fallback answer."));

    const result = await runFx(
      ["ask", "--provider", "google", "--model", MODEL, "--effort", "minimal", "--no-save", "Check effort"],
      { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Effort fallback answer.");
    expect(result.stderr).toContain("Effort minimal is not available for gemini-4-hydrogen, so it is not sent.");
    expect(f.requests).toHaveLength(1);
    for (const req of f.allRequests) {
      expect(req.body?.generation_config?.thinking_level).not.toBe("minimal");
    }
    expect(f.requests[0]!.body.generation_config?.thinking_level).toBeUndefined();
  }, TIMEOUT);
});
