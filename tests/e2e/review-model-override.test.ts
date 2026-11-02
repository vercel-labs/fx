import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";
const EXECUTED_MARKER = "JEV_OVERRIDE_EXECUTED";
const JEV_MODEL_ID = "typesafeai/jev";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const jevServers: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const server of jevServers.splice(0)) server.stop();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(settings: Record<string, unknown> = {}): IsolatedRoot {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "fx-review-model-override-e2e-")),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission: {}, ...settings }),
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function jevResponse(decision: "clear" | "caution") {
  return {
    model: "jev-1.13.0",
    answers: {
      decision: {
        type: "choice",
        choice: decision,
        probabilities:
          decision === "clear"
            ? { clear: 0.99, caution: 0.01 }
            : { clear: 0.02, caution: 0.98 },
        confidence: 0.97,
      },
    },
    usage: { input_tokens: 100, output_tokens: 10 },
  };
}

function startJevStub(decision: "clear" | "caution" = "clear") {
  const requests: Array<{ body: string; headers: Headers }> = [];
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      requests.push({ body: await req.text(), headers: new Headers(req.headers) });
      return Response.json(jevResponse(decision));
    },
  });
  const stub = {
    requests,
    url: `http://127.0.0.1:${server.port}/v1/systemone`,
    stop() {
      server.stop(true);
    },
  };
  jevServers.push(stub);
  return stub;
}

function overrideEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  extra: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-review-model-override-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
    ...extra,
  };
}

describe("review model override", () => {
  test(
    "FX_REVIEW_MODEL=typesafeai/jev routes the review to the System One endpoint and executes a cleared action",
    async () => {
      const root = createIsolatedRoot();
      const jev = startJevStub("clear");
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Ran the command."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: JEV_MODEL_ID,
            TYPESAFE_API_KEY: "e2e-typesafe-key",
            TYPESAFE_BASE_URL: jev.url,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(EXECUTED_MARKER);
      expect(jev.requests).toHaveLength(1);
      expect(gateway.classifierRequests).toHaveLength(0);
      const review = JSON.parse(jev.requests[0].body);
      expect(review.model).toBe("jev-latest");
      expect(typeof review.state.review_policy).toBe("string");
      expect(review.state.review_policy.length).toBeGreaterThan(100);
      expect(review.state.pending_action_tool).toBe("shell");
      expect(review.state.pending_action_arguments).toContain(EXECUTED_MARKER);
      expect(review.questions.decision.type).toBe("choice");
      expect(Object.keys(review.questions.decision.criteria)).toEqual([
        "clear",
        "caution",
      ]);
      expect(jev.requests[0].headers.get("authorization")).toBe(
        "Bearer e2e-typesafe-key",
      );
    },
    TIMEOUT,
  );

  test(
    "a Jev caution holds the action and the loop continues",
    async () => {
      const root = createIsolatedRoot();
      const jev = startJevStub("caution");
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Understood, leaving it unexecuted."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: JEV_MODEL_ID,
            TYPESAFE_API_KEY: "e2e-typesafe-key",
            TYPESAFE_BASE_URL: jev.url,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).not.toContain(EXECUTED_MARKER);
      expect(result.stdout).toContain("Understood, leaving it unexecuted.");
      expect(jev.requests).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "review_model in settings.json selects the Jev reviewer without the env var",
    async () => {
      const root = createIsolatedRoot({ review_model: JEV_MODEL_ID });
      const jev = startJevStub("clear");
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Ran the command."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: undefined,
            TYPESAFE_API_KEY: "e2e-typesafe-key",
            TYPESAFE_BASE_URL: jev.url,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(EXECUTED_MARKER);
      expect(jev.requests).toHaveLength(1);
      expect(gateway.classifierRequests).toHaveLength(0);
    },
    TIMEOUT,
  );

  test(
    "review_model set to another gateway chat model keeps the gateway path with that model id",
    async () => {
      const root = createIsolatedRoot({ review_model: "openai/gpt-5-alt" });
      const jev = startJevStub("clear");
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Ran the command."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: undefined,
            TYPESAFE_API_KEY: "e2e-typesafe-key",
            TYPESAFE_BASE_URL: jev.url,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(EXECUTED_MARKER);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(
        gateway.classifierRequests[0].headers.get("ai-language-model-id"),
      ).toBe("openai/gpt-5-alt");
      expect(jev.requests).toHaveLength(0);
    },
    TIMEOUT,
  );

  test(
    "without FX_REVIEW_MODEL the default gateway reviewer is used even when TypeSafe credentials exist",
    async () => {
      const root = createIsolatedRoot();
      const jev = startJevStub("clear");
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Ran the command."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: undefined,
            TYPESAFE_API_KEY: "e2e-typesafe-key",
            TYPESAFE_BASE_URL: jev.url,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(EXECUTED_MARKER);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(
        gateway.classifierRequests[0].headers.get("ai-language-model-id"),
      ).toBe("openai/gpt-5.6-luna");
      expect(jev.requests).toHaveLength(0);
    },
    TIMEOUT,
  );

  test(
    "without TYPESAFE_API_KEY the Jev review goes through the gateway evaluation endpoint",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
        fakeGatewayFinalText("Ran the command."),
      ]);
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: JEV_MODEL_ID,
            TYPESAFE_API_KEY: undefined,
            TYPESAFE_BASE_URL: undefined,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).toContain(EXECUTED_MARKER);
      expect(gateway.evaluationRequests).toHaveLength(1);
      expect(gateway.classifierRequests).toHaveLength(0);
      const review = JSON.parse(gateway.evaluationRequests[0].body);
      expect(review.model).toBe("typesafe-ai/jev");
      expect(review.questions.decision.type).toBe("choice");
      expect(
        gateway.evaluationRequests[0].headers.get("authorization"),
      ).toBe("Bearer fake-review-model-override-key");
      expect(
        gateway.evaluationRequests[0].headers.get("ai-language-model-id"),
      ).toBe("typesafe-ai/jev");
    },
    TIMEOUT,
  );

  test(
    "a failing Jev evaluation endpoint holds the action instead of executing unreviewed",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway(
        [
          fakeShellRun("cmd_1", `printf '%s' "${EXECUTED_MARKER}"`),
          fakeGatewayFinalText("Review unavailable, holding."),
        ],
        {
          evaluationResponse: new Response("upstream unavailable", {
            status: 500,
          }),
        },
      );
      gateways.push(gateway);
      const result = await runFx(
        ["ask", "--auto", "--quiet", "--json", "Print the marker."],
        {
          cwd: root.workspace,
          env: overrideEnv(root, gateway, {
            FX_REVIEW_MODEL: JEV_MODEL_ID,
            TYPESAFE_API_KEY: undefined,
            TYPESAFE_BASE_URL: undefined,
          }),
          timeoutMs: TIMEOUT,
        },
      );
      expect(result.code).toBe(0);
      expect(result.stdout).not.toContain(EXECUTED_MARKER);
      expect(gateway.evaluationRequests.length).toBeGreaterThan(0);
      expect(gateway.classifierRequests).toHaveLength(0);
    },
    TIMEOUT,
  );
});
