import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

function responsesSse(events: object[]) {
  return new Response(
    events
      .map(
        (event) =>
          `event: ${(event as { type: string }).type}\ndata: ${JSON.stringify(event)}\n\n`,
      )
      .join(""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function responsesTextEvents(text: string) {
  return [
    { type: "response.output_text.delta", delta: text },
    { type: "response.completed", response: { status: "completed" } },
  ];
}

function responsesToolCallEvents(
  callId: string,
  name: string,
  args: Record<string, string>,
) {
  const argumentsJson = JSON.stringify(args);
  return [
    {
      type: "response.output_item.added",
      output_index: 0,
      item: {
        type: "function_call",
        call_id: callId,
        name,
        arguments: "",
      },
    },
    {
      type: "response.function_call_arguments.done",
      output_index: 0,
      name,
      arguments: argumentsJson,
    },
    { type: "response.completed", response: { status: "completed" } },
  ];
}

type FakeResponse = Response | ((body: string) => Response);

function startResponsesFake(responses: FakeResponse[]) {
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
      if (req.url.endsWith("/v1/responses")) {
        const next = queue.shift();
        if (!next) {
          return new Response("unexpected responses request", { status: 500 });
        }
        return typeof next === "function" ? next(body) : next;
      }
      if (req.url.endsWith("/v1/chat/completions")) {
        return new Response("chat completions not expected", { status: 404 });
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

describe("openai responses fake gateway", () => {
  test(
    "ask streams text from a Responses API server",
    async () => {
      const fake = startResponsesFake([
        responsesSse(responsesTextEvents("hello from responses fake")),
      ]);
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-openai-responses-"));
      try {
        const result = await runFx(["ask", "--json", "Say hello"], {
          cwd: root,
          env: {
            OPENAI_API_KEY: "test-openai-key",
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_OPENAI_BASE_URL: fake.baseUrl,
            FX_OPENAI_API_STYLE: "responses",
            FX_MODEL: "gpt-test",
            FX_SKIP_ONBOARDING: "1",
          },
          timeoutMs: 30_000,
        });
        expect(result.code).toBe(0);
        const payload = JSON.parse(result.stdout.trim());
        expect(payload.output).toContain("hello from responses fake");
        expect(fake.requests.some((r) => r.url.endsWith("/v1/responses"))).toBe(
          true,
        );
        expect(
          fake.requests.some((r) => r.url.endsWith("/v1/chat/completions")),
        ).toBe(false);
      } finally {
        fake.close();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "ask streams a tool call, executes it, and continues via function_call_output",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-openai-responses-tool-"));
      const filePath = join(root, "fixture.txt");
      writeFileSync(filePath, "RESPONSES_TOOL_OK\n");

      const fake = startResponsesFake([
        responsesSse(
          responsesToolCallEvents("call_read", "read_file", { path: filePath }),
        ),
        responsesSse(responsesTextEvents("READ_TOOL_DONE")),
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
              FX_OPENAI_API_STYLE: "responses",
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
          fake.requests.filter((r) => r.url.endsWith("/v1/responses")).length,
        ).toBe(2);
        const followUp = JSON.parse(fake.requests[1]?.body ?? "{}") as {
          input: Array<{ type: string; output?: string; call_id?: string }>;
        };
        const toolOutput = followUp.input.find(
          (item) => item.type === "function_call_output",
        );
        expect(toolOutput).toBeDefined();
        expect(toolOutput?.output).toContain("RESPONSES_TOOL_OK");
      } finally {
        fake.close();
        rmSync(root, { recursive: true, force: true });
      }
    },
    90_000,
  );

  test(
    "default chat style still hits chat completions when style unset",
    async () => {
      const requests: Array<{ url: string; body: string }> = [];
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
            return new Response(
              `data: ${JSON.stringify({
                choices: [
                  {
                    delta: { content: "hello from chat fake" },
                    finish_reason: "stop",
                  },
                ],
              })}\n\ndata: [DONE]\n\n`,
              { headers: { "content-type": "text/event-stream" } },
            );
          }
          return new Response("not found", { status: 404 });
        },
      });
      const baseUrl = `http://127.0.0.1:${server.port}/v1`;
      const root = mkdtempSync(join(tmpdir(), "fx-e2e-openai-chat-default-"));
      try {
        const result = await runFx(["ask", "--json", "Say hello"], {
          cwd: root,
          env: {
            OPENAI_API_KEY: "test-openai-key",
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_OPENAI_BASE_URL: baseUrl,
            FX_MODEL: "gpt-test",
            FX_SKIP_ONBOARDING: "1",
          },
          timeoutMs: 30_000,
        });
        expect(result.code).toBe(0);
        const payload = JSON.parse(result.stdout.trim());
        expect(payload.output).toContain("hello from chat fake");
        expect(
          requests.some((r) => r.url.endsWith("/v1/chat/completions")),
        ).toBe(true);
        expect(requests.some((r) => r.url.endsWith("/v1/responses"))).toBe(
          false,
        );
      } finally {
        server.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );
});
