import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const FREE_MODEL = "z-ai/glm-5.2:free";
const PAID_MODEL = "qwen/qwen3.8-flash";

/// Mirrors the shape of a real `GET /api/v1/models?supported_parameters=tools`
/// response: two free models, one paid, and one that cannot call tools.
const CATALOG = {
  data: [
    {
      id: PAID_MODEL,
      created: 1787773060,
      context_length: 1000000,
      architecture: { input_modalities: ["text", "image"], output_modalities: ["text"] },
      pricing: { prompt: "0.00000015", completion: "0.00000047" },
      top_provider: { max_completion_tokens: 131072 },
      supported_parameters: ["max_tokens", "tool_choice", "tools"],
    },
    {
      id: FREE_MODEL,
      created: 1781631930,
      context_length: 1048576,
      architecture: { input_modalities: ["text"], output_modalities: ["text"] },
      pricing: { prompt: "0", completion: "0" },
      top_provider: { max_completion_tokens: 230400 },
      supported_parameters: ["max_tokens", "reasoning", "tool_choice", "tools"],
      reasoning: { supported_efforts: ["high"] },
    },
    {
      id: "nvidia/nemotron-3.5-lightning:free",
      created: 1781631000,
      context_length: 1000000,
      architecture: { input_modalities: ["text"], output_modalities: ["text"] },
      pricing: { prompt: "0", completion: "0" },
      supported_parameters: ["max_tokens", "tools"],
    },
    {
      id: "vendor/no-tools",
      created: 1,
      context_length: 128000,
      architecture: { input_modalities: ["text"], output_modalities: ["text"] },
      pricing: { prompt: "0", completion: "0" },
      supported_parameters: ["max_tokens"],
    },
  ],
  total_count: 4,
};

function sse(lines: string[]): Response {
  return new Response(lines.join("\n\n") + "\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
}

type FakeMode = "text" | "tool" | "402" | "429";

function startFakeOpenRouter(mode: FakeMode = "text") {
  const chatRequests: string[] = [];
  let chatCalls = 0;
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === "/api/v1/models") return Response.json(CATALOG);
      if (url.pathname !== "/api/v1/chat/completions") {
        return new Response("not found", { status: 404 });
      }
      chatRequests.push(await request.text());
      chatCalls += 1;

      if (mode === "402") {
        return Response.json(
          { error: { code: 402, message: "Insufficient credits" } },
          { status: 402 },
        );
      }
      // Throttle once, then succeed: fx retries rate limits with backoff, so
      // failing forever would only measure the retry ceiling.
      if (mode === "429" && chatCalls === 1) {
        return Response.json(
          { error: { code: 429, message: "Rate limit exceeded" } },
          { status: 429, headers: { "retry-after": "1" } },
        );
      }
      if (mode === "tool" && chatCalls === 1) {
        // Tool call arguments arrive split across chunks and correlated by
        // `index`, exactly as a real provider streams them.
        return sse([
          ": OPENROUTER PROCESSING",
          `data: {"id":"gen-1","model":"${FREE_MODEL}","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"list_files","arguments":"{\\"pa"}}]}}]}`,
          `data: {"id":"gen-1","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\".\\"}"}}]}}]}`,
          `data: {"id":"gen-1","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":8,"cost":0}}`,
          "data: [DONE]",
        ]);
      }
      return sse([
        ": OPENROUTER PROCESSING",
        `data: {"id":"gen-2","model":"${FREE_MODEL}","choices":[{"delta":{"content":"OPENROUTER_"}}]}`,
        ": OPENROUTER PROCESSING",
        `data: {"id":"gen-2","choices":[{"delta":{"content":"DIRECT_RESPONSE"}}]}`,
        `data: {"id":"gen-2","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":4,"cost":0}}`,
        "data: [DONE]",
      ]);
    },
  });
  const baseUrl = `http://127.0.0.1:${server.port}`;
  return {
    chatRequests,
    stop: () => server.stop(true),
    env: {
      OPENROUTER_API_KEY: "sk-or-e2e-key",
      FX_E2E_OPENROUTER_MODELS_URL: `${baseUrl}/api/v1/models`,
      FX_E2E_OPENROUTER_CHAT_URL: `${baseUrl}/api/v1/chat/completions`,
      FX_DISABLE_KEYCHAIN: "1",
    },
  };
}

function workspace(): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "fx-openrouter-"));
  writeFileSync(join(dir, "alpha.txt"), "alpha\n");
  writeFileSync(join(dir, "beta.txt"), "beta\n");
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function envFor(fake: ReturnType<typeof startFakeOpenRouter>, home: string, model?: string) {
  return {
    ...fake.env,
    HOME: home,
    ...(model ? { FX_MODEL: model } : {}),
  };
}

describe("openrouter provider", () => {
  test("lists tool-capable models with free ones first and marked", async () => {
    const fake = startFakeOpenRouter();
    const ws = workspace();
    try {
      const selected = await runFx(["provider", "openrouter"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir),
      });
      expect(selected.stdout).toContain("Provider set to OpenRouter.");

      const listed = await runFx(["models"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const lines = listed.stdout.split("\n").filter((line) => line.startsWith(" - "));

      // The model that cannot call tools never reaches an agentic client.
      expect(listed.stdout).not.toContain("vendor/no-tools");
      expect(lines).toHaveLength(3);
      // Free models lead, and carry a visible marker.
      expect(lines[0]).toContain(FREE_MODEL);
      expect(lines[0]).toContain("free");
      expect(lines[1]).toContain("free");
      expect(lines[2]).toContain(PAID_MODEL);
      expect(lines[2]).not.toContain("· free");
    } finally {
      ws.cleanup();
      fake.stop();
    }
  });

  test("--free narrows the listing and reports it in JSON", async () => {
    const fake = startFakeOpenRouter();
    const ws = workspace();
    try {
      await runFx(["provider", "openrouter"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const listed = await runFx(["models", "--json", "--free"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir),
      });
      const payload = JSON.parse(listed.stdout);

      expect(payload.count).toBe(2);
      expect(payload.free_only).toBe(true);
      expect(payload.ids).toEqual([FREE_MODEL, "nvidia/nemotron-3.5-lightning:free"]);
      for (const model of payload.models) expect(model.free).toBe(true);

      // The unfiltered payload keeps its existing shape and marks paid models.
      const all = JSON.parse(
        (await runFx(["models", "--json"], { cwd: ws.dir, env: envFor(fake, ws.dir) })).stdout,
      );
      expect(all.free_only).toBeUndefined();
      expect(all.models.find((m: { id: string }) => m.id === PAID_MODEL).free).toBe(false);
    } finally {
      ws.cleanup();
      fake.stop();
    }
  });

  test("streams a completion and survives keep-alive comments", async () => {
    const fake = startFakeOpenRouter("text");
    const ws = workspace();
    try {
      await runFx(["provider", "openrouter"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const asked = await runFx(["ask", "--no-save", "say hi"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir, FREE_MODEL),
      });
      expect(asked.stdout).toContain("OPENROUTER_DIRECT_RESPONSE");

      const sent = JSON.parse(fake.chatRequests.at(-1)!);
      expect(sent.model).toBe(FREE_MODEL);
      expect(sent.stream).toBe(true);
      // Exact usage requires the inline usage block.
      expect(sent.usage).toEqual({ include: true });
      expect(sent.messages.at(-1)).toEqual({ role: "user", content: "say hi" });
      expect(sent.tools[0].type).toBe("function");
      expect(typeof sent.tools[0].function.name).toBe("string");
    } finally {
      ws.cleanup();
      fake.stop();
    }
  });

  test("round-trips a streamed tool call", async () => {
    const fake = startFakeOpenRouter("tool");
    const ws = workspace();
    try {
      await runFx(["provider", "openrouter"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const asked = await runFx(["ask", "--no-save", "--yolo", "list the files here"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir, FREE_MODEL),
      });
      expect(asked.stdout).toContain("OPENROUTER_DIRECT_RESPONSE");

      // The replayed turn must carry the assistant tool call and its result in
      // Chat Completions shape.
      const replayed = JSON.parse(fake.chatRequests.at(-1)!);
      const assistant = replayed.messages.find(
        (m: { role: string; tool_calls?: unknown }) => m.role === "assistant" && m.tool_calls,
      );
      expect(assistant.tool_calls[0]).toMatchObject({
        id: "call_1",
        type: "function",
        function: { name: "list_files", arguments: '{"path":"."}' },
      });
      const result = replayed.messages.find((m: { role: string }) => m.role === "tool");
      expect(result.tool_call_id).toBe("call_1");
      expect(result.content).toContain("alpha.txt");
    } finally {
      ws.cleanup();
      fake.stop();
    }
  });

  test("explains a negative credit balance without retrying it", async () => {
    const fake = startFakeOpenRouter("402");
    const ws = workspace();
    try {
      await runFx(["provider", "openrouter"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const asked = await runFx(["ask", "--no-save", "say hi"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir, FREE_MODEL),
      });
      const output = `${asked.stdout}${asked.stderr}`;
      expect(output).toContain("402");
      expect(output).toContain("credit balance is negative");
      // A payment failure is terminal, so it must not be retried.
      expect(fake.chatRequests).toHaveLength(1);
    } finally {
      ws.cleanup();
      fake.stop();
    }
  });

  test("reports the free-tier rate limit when throttled", async () => {
    const fake = startFakeOpenRouter("429");
    const ws = workspace();
    try {
      await runFx(["provider", "openrouter"], { cwd: ws.dir, env: envFor(fake, ws.dir) });
      const asked = await runFx(["ask", "--no-save", "say hi"], {
        cwd: ws.dir,
        env: envFor(fake, ws.dir, FREE_MODEL),
      });
      const output = `${asked.stdout}${asked.stderr}`;
      expect(output).toContain("429");
      // The notice must explain the free-tier caps, not just echo the status.
      expect(output).toContain("50 per day");
      // The retry succeeded, so the turn still completes.
      expect(output).toContain("OPENROUTER_DIRECT_RESPONSE");
      expect(fake.chatRequests.length).toBeGreaterThan(1);
    } finally {
      ws.cleanup();
      fake.stop();
    }
  }, 30_000);
});
