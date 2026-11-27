import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  runFx,
} from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  startDynamicFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const FINDING_TEXT = "Finding A: missing auth check in webhook.";
const WEBHOOK_MARKER = "WEBHOOK_UNAUTHENTICATED_HANDLER_MARKER";

const CYBER_POLICY_ERROR = {
  message:
    "This content was flagged for possible cybersecurity risk. If this seems wrong, try rephrasing your request. To get authorized for security work, join the Trusted Access for Cyber program: https://chatgpt.com/cyber",
  type: "invalid_request",
  param: null,
  code: "cyber_policy",
};

function stepOneToolCallResponse(): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "text_1", delta: FINDING_TEXT },
    {
      type: "tool-call",
      toolCallId: "read_1",
      toolName: "read_file",
      input: { path: "webhook.ts" },
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
      usage: { inputTokens: { total: 5 }, outputTokens: { total: 7 } },
    },
  ]);
}

function cyberPolicySseResponse(): Response {
  return fakeGatewaySse([
    { type: "error", error: CYBER_POLICY_ERROR },
    {
      type: "finish",
      finishReason: { unified: "error", raw: "provider_error" },
      usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } },
    },
  ]);
}

function cyberPolicyHttp400Response(): Response {
  return new Response(JSON.stringify({ error: CYBER_POLICY_ERROR }), {
    status: 400,
    headers: { "content-type": "application/json" },
  });
}

function makeEnv(
  home: string,
  gateway: ReturnType<typeof startDynamicFakeGateway>,
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "cyber-policy-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
}

function setupFixtureWorkspace() {
  const root = createIsolatedTestHome();
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  writeFileSync(
    join(workspace, "webhook.ts"),
    `export const handler = "${WEBHOOK_MARKER}";\n`,
  );
  return { root, home, workspace };
}

type AskJson = {
  output: string;
  final_output: string;
  exit_code: number;
  session_id: string;
  tool_calls: Array<{ name: string; status: string }>;
  error?: string;
  recovery?: {
    state?: string;
    attempt?: number;
    cause?: string;
    message?: string;
  };
};

describe("OpenAI cyber_policy block", () => {
  test("A: mid-stream SSE cyber_policy error after text + read_file resends 3 times then ends", async () => {
    const { root, home, workspace } = setupFixtureWorkspace();
    let step = 0;
    const gateway = startDynamicFakeGateway(() =>
      ++step === 1 ? stepOneToolCallResponse() : cyberPolicySseResponse(),
    );
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Audit webhook.ts for auth issues."],
        { cwd: workspace, env: makeEnv(home, gateway), timeoutMs: TIMEOUT },
      );
      const json: AskJson = JSON.parse(result.stdout.trim());

      expect(result.code).toBe(1);
      expect(json.exit_code).toBe(1);
      expect(json.output).toContain(FINDING_TEXT);
      expect(json.output).not.toContain("API request failed");
      expect(json.tool_calls).toEqual([{ name: "read_file", status: "success" }]);
      expect(json.recovery?.cause).toBe("cyber_policy");
      // 1 step-1 request + 1 initial step-2 block + 3 content-filter resends.
      expect(gateway.requestCount()).toBe(5);
    } finally {
      gateway.stop();
      cleanupIsolatedTestHome(root);
    }
  }, TIMEOUT);

  test("B: HTTP 400 cyber_policy JSON body on step 2 after text + read_file resends 3 times then ends", async () => {
    const { root, home, workspace } = setupFixtureWorkspace();
    let step = 0;
    const gateway = startDynamicFakeGateway(() =>
      ++step === 1 ? stepOneToolCallResponse() : cyberPolicyHttp400Response(),
    );
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Audit webhook.ts for auth issues."],
        { cwd: workspace, env: makeEnv(home, gateway), timeoutMs: TIMEOUT },
      );
      const json: AskJson = JSON.parse(result.stdout.trim());

      expect(result.code).toBe(1);
      expect(json.exit_code).toBe(1);
      expect(json.output).toContain(FINDING_TEXT);
      expect(json.output).not.toContain("API request failed");
      expect(json.tool_calls).toEqual([{ name: "read_file", status: "success" }]);
      expect(json.recovery?.cause).toBe("cyber_policy");
      expect(gateway.requestCount()).toBe(5);
    } finally {
      gateway.stop();
      cleanupIsolatedTestHome(root);
    }
  }, TIMEOUT);

  test("C: saved session keeps pre-block work and sends it on --resume", async () => {
    const { root, home, workspace } = setupFixtureWorkspace();
    let step = 0;
    const gateway = startDynamicFakeGateway(() =>
      ++step === 1 ? stepOneToolCallResponse() : cyberPolicySseResponse(),
    );
    let resumeGateway: ReturnType<typeof startDynamicFakeGateway> | undefined;
    try {
      const blocked = await runFx(
        ["ask", "--json", "--auto", "Audit webhook.ts for auth issues."],
        { cwd: workspace, env: makeEnv(home, gateway), timeoutMs: TIMEOUT },
      );
      const blockedJson: AskJson = JSON.parse(blocked.stdout.trim());

      let resumeCode: number | null = null;
      let resumeBody = "";
      if (blockedJson.session_id) {
        resumeGateway = startDynamicFakeGateway(() =>
          fakeGatewayFinalText("RESUMED_OK"),
        );
        const resumed = await runFx(
          ["ask", "--json", "--auto", "--resume", blockedJson.session_id, "continue"],
          { cwd: workspace, env: makeEnv(home, resumeGateway), timeoutMs: TIMEOUT },
        );
        resumeCode = resumed.code;
        resumeBody = resumeGateway.requests[0]?.body ?? "";
      }

      expect(blocked.code).toBe(1);
      expect(blockedJson.session_id).not.toBe("");
      expect(blockedJson.output).toContain(FINDING_TEXT);
      expect(blockedJson.output).not.toContain("API request failed");
      expect(blockedJson.recovery?.cause).toBe("cyber_policy");
      expect(gateway.requestCount()).toBe(5);
      expect(resumeCode).toBe(0);
      expect(resumeBody).toContain("Finding A");
      expect(resumeBody).toContain(WEBHOOK_MARKER);
    } finally {
      resumeGateway?.stop();
      gateway.stop();
      cleanupIsolatedTestHome(root);
    }
  }, TIMEOUT);

  test("D: step 2 blocked once, resend returns final text and finishes turn", async () => {
    const { root, home, workspace } = setupFixtureWorkspace();
    let step = 0;
    const gateway = startDynamicFakeGateway(() => {
      step += 1;
      if (step === 1) return stepOneToolCallResponse();
      if (step === 2) return cyberPolicySseResponse();
      return fakeGatewayFinalText("FINAL_ALLOWED_AFTER_BLOCK");
    });
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Audit webhook.ts for auth issues."],
        { cwd: workspace, env: makeEnv(home, gateway), timeoutMs: TIMEOUT },
      );
      const json: AskJson = JSON.parse(result.stdout.trim());

      expect(result.code).toBe(0);
      expect(json.exit_code).toBe(0);
      expect(json.error ?? null).toBeNull();
      expect(json.recovery).toEqual({
        state: "recovered",
        attempt: 2,
        cause: "content_filter",
      });
      expect(json.output).toContain(FINDING_TEXT);
      expect(json.output).toContain("FINAL_ALLOWED_AFTER_BLOCK");
      expect(json.output).not.toContain("API request failed");
      expect(gateway.requestCount()).toBe(3);
    } finally {
      gateway.stop();
      cleanupIsolatedTestHome(root);
    }
  }, TIMEOUT);
});
