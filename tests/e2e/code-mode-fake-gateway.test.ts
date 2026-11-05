import { describe, expect, test } from "bun:test";
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, runFx } from "../evals/eval-helpers";
import { contentText, parseGatewayRequest, serializedToolNames } from "./conditional-guidance-oracle";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

// The `execute` tool runs a model-written program in the code-mode sandbox,
// and each `tools.<name>()` call the program makes comes back to fx.

const TIMEOUT = 30_000;

function isolatedRoot(settings: Record<string, unknown>) {
  const root = createIsolatedTestHome();
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify(settings));
  writeFileSync(join(workspace, "notes.txt"), "alpha\nneedle\nomega\n");
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function env(home: string, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "code-mode-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
  };
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content?: unknown }> };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) => part.type === "tool-result" && part.toolCallId === callId);
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return contentText(result.output);
}

describe("code mode", () => {
  test(
    "fx ask doesn't offer execute while experimental.code_mode is off",
    async () => {
      const root = isolatedRoot({});
      const gateway = startFakeGateway([fakeGatewayFinalText("ok")]);
      try {
        const result = await runFx(["ask", "--auto", "--json", "--no-save", "Say ok."], {
          cwd: root.workspace,
          env: env(root.home, gateway),
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
        expect(gateway.requests).toHaveLength(1);
        expect(serializedToolNames(parseGatewayRequest(gateway.requests[0]!.body))).not.toContain("execute");
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(root.root);
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask refuses an execute call while experimental.code_mode is off",
    async () => {
      const root = isolatedRoot({});
      // The model can name a tool fx didn't offer.
      const gateway = startFakeGateway([
        fakeGatewayToolCall("exec-1", "execute", { code: "return await tools.read_file({ path: 'notes.txt' });" }),
        fakeGatewayFinalText("Code mode is off."),
      ]);
      try {
        const result = await runFx(["ask", "--auto", "--json", "--no-save", "Read notes.txt."], {
          cwd: root.workspace,
          env: env(root.home, gateway),
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
        expect(gateway.requests).toHaveLength(2);
        expect(serializedToolNames(parseGatewayRequest(gateway.requests[0]!.body))).not.toContain("execute");
        const output = toolResultText(gateway.requests[1]!.body, "exec-1");
        expect(output).toContain("Code mode isn't available here.");
        expect(output).not.toContain("needle");
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(root.root);
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask runs an execute program whose tool calls go through fx",
    async () => {
      const root = isolatedRoot({ experimental: { code_mode: true } });
      const program = [
        "const text = await tools.read_file({ path: 'notes.txt' });",
        "console.log('read', text.includes('alpha'));",
        "try { await tools.subagent({ message: 'hi' }); } catch (e) { console.log(e.message); }",
        "return text.includes('needle');",
      ].join("\n");
      const gateway = startFakeGateway([
        fakeGatewayToolCall("exec-1", "execute", { code: program }),
        fakeGatewayFinalText("The program found the needle."),
      ]);
      try {
        const result = await runFx(["ask", "--auto", "--json", "--no-save", "Check notes.txt for a needle."], {
          cwd: root.workspace,
          env: env(root.home, gateway),
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
        const json = JSON.parse(result.stdout.trim()) as { tool_calls: Array<{ name: string; status: string }> };
        expect(json.tool_calls).toEqual([{ name: "execute", status: "success" }]);

        expect(gateway.requests).toHaveLength(2);
        expect(serializedToolNames(parseGatewayRequest(gateway.requests[0]!.body))).toContain("execute");
        const output = toolResultText(gateway.requests[1]!.body, "exec-1");
        expect(output).toContain("result: true");
        expect(output).toContain("logs:\nread true\nsubagent can't be called from a program. Call it directly instead.\n");
        expect(output).toContain("tool calls: 2\n  read_file ok\n  subagent failed\n");
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(root.root);
      }
    },
    TIMEOUT,
  );
});
