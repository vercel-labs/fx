import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

describe("custom OpenAI-compatible provider", () => {
  test("sends an OpenAI request and renders the response", async () => {
    let receivedModel = "";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const body = (await request.json()) as { model?: string };
        receivedModel = body.model ?? "";
        return Response.json({
          id: "mock-completion",
          choices: [
            {
              finish_reason: "stop",
              message: { role: "assistant", content: "custom provider works" },
            },
          ],
          usage: { prompt_tokens: 2, completion_tokens: 3 },
        });
      },
    });

    const home = mkdtempSync(join(tmpdir(), "fx-custom-provider-home-"));
    const workspace = mkdtempSync(join(tmpdir(), "fx-custom-provider-work-"));
    mkdirSync(join(home, ".fx"), { recursive: true });
    writeFileSync(
      join(home, ".fx", "settings.json"),
      JSON.stringify({
        provider: "custom",
        custom_provider: {
          base_url: `http://127.0.0.1:${server.port}/v1`,
          api_key_env: "OPENROUTER_API_KEY",
        },
        custom_model: "deepseek-chat",
      }),
    );

    try {
      const result = await runFx(["ask", "hello", "--json"], {
        cwd: workspace,
        env: {
          HOME: home,
          OPENROUTER_API_KEY: "test-key",
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
        },
      });
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("custom provider works");
      expect(receivedModel).toBe("deepseek-chat");
    } finally {
      server.stop(true);
      rmSync(home, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  }, 30_000);
});
