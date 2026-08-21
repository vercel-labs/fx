import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

function openAiSse(events: object[]) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function openAiTextEvents(text: string) {
  return [
    { choices: [{ delta: { content: text }, finish_reason: null }] },
    { choices: [{ delta: {}, finish_reason: "stop" }] },
  ];
}

function openAiToolCallEvents(
  id: string,
  name: string,
  args: Record<string, string>,
) {
  return [
    {
      choices: [
        {
          delta: {
            tool_calls: [
              {
                index: 0,
                id,
                function: {
                  name,
                  arguments: JSON.stringify(args),
                },
              },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    },
  ];
}

type FakeResponse = Response | ((body: string) => Response);

function startOpenAiFake(responses: FakeResponse[]) {
  const requests: Array<{ url: string; body: string }> = [];
  const queue = [...responses];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const body = await req.text();
      requests.push({ url: req.url, body });
      if (req.url.endsWith("/v1/models")) {
        return Response.json({
          data: [{ id: "gpt-test", object: "model" }],
        });
      }
      if (req.url.endsWith("/v1/chat/completions")) {
        const next = queue.shift();
        if (!next) {
          return new Response("unexpected chat request", { status: 500 });
        }
        return typeof next === "function" ? next(body) : next;
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}/v1`,
    requests,
    close: () => server.stop(),
  };
}

describe("openai-compatible fake gateway", () => {
  test(
    "ask streams text from an OpenAI-compatible server",
    async () => {
      const fake = startOpenAiFake([
        openAiSse(openAiTextEvents("hello from openai fake")),
      ]);
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-openai-fake-"));
      try {
        const result = await runFx(
          ["ask", "--json", "Say hello"],
          {
            cwd: root,
            env: {
              OPENAI_API_KEY: "test-openai-key",
              AI_GATEWAY_API_KEY: undefined,
              VERCEL_OIDC_TOKEN: undefined,
              FX_OPENAI_BASE_URL: fake.baseUrl,
              FX_MODEL: "gpt-test",
              FX_SKIP_ONBOARDING: "1",
            },
            timeoutMs: 30_000,
          },
        );
        expect(result.code).toBe(0);
        const payload = JSON.parse(result.stdout.trim());
        expect(payload.output).toContain("hello from openai fake");
        expect(fake.requests.some((r) => r.url.endsWith("/v1/chat/completions"))).toBe(
          true,
        );
      } finally {
        fake.close();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "ask streams a tool call, executes it, and continues",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-openai-tool-"));
      const filePath = join(root, "fixture.txt");
      writeFileSync(filePath, "TOOL_FILE_OK\n");

      const fake = startOpenAiFake([
        openAiSse(openAiToolCallEvents("call_read", "read_file", { path: filePath })),
        openAiSse(openAiTextEvents("READ_TOOL_DONE")),
      ]);

      try {
        const result = await runFx(
          ["ask", "--yolo", "--json", "--no-save", "Read the fixture file once."],
          {
            cwd: root,
            env: {
              OPENAI_API_KEY: "test-openai-key",
              AI_GATEWAY_API_KEY: undefined,
              VERCEL_OIDC_TOKEN: undefined,
              FX_OPENAI_BASE_URL: fake.baseUrl,
              FX_MODEL: "gpt-test",
              FX_SKIP_ONBOARDING: "1",
            },
            timeoutMs: 60_000,
          },
        );

        expect(result.code).toBe(0);
        const payload = JSON.parse(result.stdout.trim()) as {
          output: string;
          tool_calls: Array<{ name: string; status: string }>;
        };
        expect(payload.output).toContain("READ_TOOL_DONE");
        expect(
          payload.tool_calls.some(
            (call) => call.name === "read_file" && call.status === "success",
          ),
        ).toBe(true);
        expect(
          fake.requests.filter((r) => r.url.endsWith("/v1/chat/completions")).length,
        ).toBe(2);
        const followUp = fake.requests[1]?.body ?? "";
        expect(followUp).toContain("TOOL_FILE_OK");
      } finally {
        fake.close();
        rmSync(root, { recursive: true, force: true });
      }
    },
    90_000,
  );
});
