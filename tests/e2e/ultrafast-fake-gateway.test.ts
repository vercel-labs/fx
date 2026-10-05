import { describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewaySse,
  fakeGatewayToolCall,
  composerContains,
  hasEmptyComposer,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const ULTRA_MODEL = "openai/gpt-6-astra";
const SOL_MODEL = "openai/gpt-5.6-sol";
const TMUX_SKIP = !tmuxAvailable();

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

type Gateway = ReturnType<typeof startFakeGateway>;

function ultrafastCatalogModel() {
  return {
    id: ULTRA_MODEL,
    type: "language" as const,
    owned_by: "openai",
    tags: ["tool-use", "reasoning"],
    reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
    pricing: {
      input_cache_read: "0.000001",
      service_tiers: {
        priority: {
          input: "0.00003",
          output: "0.00015",
          input_cache_read: "0.000003",
        },
        ultrafast: {
          input: "0.00006",
          output: "0.0003",
          input_cache_read: "0.000006",
        },
      },
    },
  };
}

function solCatalogModel() {
  return {
    id: SOL_MODEL,
    type: "language" as const,
    owned_by: "openai",
    tags: ["tool-use", "ultrafast"],
    pricing: {
      service_tiers: {
        priority: { input: "0.00006", output: "0.0003" },
      },
    },
  };
}

function writeProfileSettings(root: IsolatedRoot, settings: Record<string, unknown>) {
  writeFileSync(
    join(root.home, ".fx", "settings.json"),
    `${JSON.stringify({ session_titles: false, ...settings })}\n`,
    { mode: 0o600 },
  );
}

function createIsolatedRoot(settings: Record<string, unknown> = {}): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-ultrafast-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true, mode: 0o700 });
  const isolated = { root, home, workspace: realpathSync(workspace) };
  writeProfileSettings(isolated, settings);
  return isolated;
}

function fakeGatewayEnv(
  root: IsolatedRoot,
  gateway: Gateway,
  extra: Record<string, string | undefined> = {},
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "ultrafast-fake-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_PROVIDER: "gateway",
    FX_MODEL: ULTRA_MODEL,
    FX_FAST: undefined,
    FX_ULTRAFAST: undefined,
    FX_SESSIONS_V2: undefined,
    FX_PERMISSION_MODE: undefined,
    FX_FIRST_CALL_TOOL_CHOICE: undefined,
    ...extra,
  };
}

function expectUltrafastRequest(body: string) {
  const request = JSON.parse(body) as {
    providerOptions?: {
      gateway?: { only?: string[]; speed?: string };
      openai?: { serviceTier?: string };
    };
  };
  expect(request.providerOptions).toMatchObject({
    gateway: { only: ["openai"] },
    openai: { serviceTier: "ultrafast" },
  });
  expect(request.providerOptions?.gateway?.speed).toBeUndefined();
}

function expectStandardRequest(body: string) {
  const request = JSON.parse(body) as {
    providerOptions?: {
      gateway?: { only?: string[]; speed?: string };
      openai?: { serviceTier?: string };
    };
  };
  expect(request.providerOptions?.gateway?.only).not.toEqual(["openai"]);
  expect(request.providerOptions?.openai?.serviceTier).toBeUndefined();
}

function expectAskJsonError(result: Awaited<ReturnType<typeof runFx>>) {
  expect(result.code).toBe(1);
  expect(result.stderr).toBe("");
  const payload = JSON.parse(result.stdout) as { error?: string };
  expect(payload.error).toMatch(/ultrafast|ultra|openai/i);
}

function normalizeTerminalWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function finishWithServiceTier(text: string, serviceTier: string) {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 3 },
        outputTokens: { total: 5 },
      },
      providerMetadata: {
        gateway: { serviceTier },
      },
    },
  ]);
}

async function waitForGatewayModelCatalog(gateway: Gateway): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (gateway.modelRequests.length > 0) return;
    await Bun.sleep(25);
  }
  throw new Error("Timed out waiting for the fake Gateway model catalog");
}

class AcpClient {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private stderr = "";
  private readonly exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  private constructor(private readonly proc: ChildProcess) {
    this.exited = new Promise((resolve) => {
      proc.on("close", (code, signal) => {
        this.closed = true;
        resolve({ code, signal });
      });
    });
    proc.stderr!.on("data", (chunk: Buffer) => {
      this.stderr += chunk.toString();
    });
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const lines = this.buffer.split("\n");
      this.buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        const waiter = this.waiters.shift();
        if (waiter) waiter(line);
        else this.lines.push(line);
      }
    });
  }

  static create(
    cwd: string,
    env: Record<string, string | undefined>,
    args: string[] = [],
  ) {
    const processEnv = Object.fromEntries(
      Object.entries({ ...process.env, NO_COLOR: "1", ...env }).filter(
        (entry): entry is [string, string] => entry[1] !== undefined,
      ),
    );
    return new AcpClient(nodeSpawn(FX_BIN, ["acp", ...args], {
      cwd,
      env: processEnv,
      stdio: ["pipe", "pipe", "pipe"],
    }));
  }

  async request(method: string, params: object, id: number): Promise<any> {
    this.proc.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    while (true) {
      const message = await this.readLine();
      if (message.id === id) return message;
    }
  }

  async prompt(sessionId: string, text: string, id: number): Promise<any[]> {
    this.proc.stdin!.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "session/prompt",
      params: {
        sessionId,
        prompt: [{ type: "text", text }],
      },
    })}\n`);
    const messages: any[] = [];
    while (true) {
      const message = await this.readLine();
      if (message.id === id) {
        expect(message.error, JSON.stringify(message)).toBeUndefined();
        expect(message.result?.stopReason).toBe("end_turn");
        return messages;
      }
      messages.push(message);
    }
  }

  async readLine(timeoutMs = TIMEOUT): Promise<any> {
    const line = await new Promise<string>((resolve, reject) => {
      const buffered = this.lines.shift();
      if (buffered) {
        resolve(buffered);
        return;
      }
      if (this.closed) {
        reject(new Error(`ACP exited before a response: ${this.stderr}`));
        return;
      }
      const waiter = (value: string) => {
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index !== -1) this.waiters.splice(index, 1);
        reject(new Error(`ACP read timeout: ${this.stderr}`));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
    return JSON.parse(line);
  }

  async close() {
    if (!this.closed) this.proc.stdin!.end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 2_000);
    try {
      const status = await this.exited;
      expect(status, this.stderr).toEqual({ code: 0, signal: null });
      expect(this.stderr).toBe("");
    } finally {
      clearTimeout(timer);
    }
  }
}

async function startAcpSession(client: AcpClient): Promise<string> {
  const initialized = await client.request("initialize", { protocolVersion: 1 }, 1);
  expect(initialized.error).toBeUndefined();
  const created = await client.request("session/new", { mcpServers: [] }, 2);
  expect(created.error).toBeUndefined();
  expect(typeof created.result?.sessionId).toBe("string");
  return created.result.sessionId as string;
}

describe("ultrafast fake Gateway", () => {
  test(
    "defaults off and honors profile, environment, and CLI overrides without contacting a real Gateway",
    async () => {
      const cases = [
        { name: "default", settings: {}, extraEnv: {}, args: [], ultrafast: false },
        {
          name: "profile setting",
          settings: { ultrafast_mode: true },
          extraEnv: {},
          args: [],
          ultrafast: true,
        },
        { name: "environment on", settings: {}, extraEnv: { FX_ULTRAFAST: "1" }, args: [], ultrafast: true },
        {
          name: "environment off",
          settings: { ultrafast_mode: true },
          extraEnv: { FX_ULTRAFAST: "0" },
          args: [],
          ultrafast: false,
        },
        {
          name: "CLI on overrides environment off",
          settings: { ultrafast_mode: false },
          extraEnv: { FX_ULTRAFAST: "0" },
          args: ["--ultrafast"],
          ultrafast: true,
        },
        {
          name: "CLI off overrides environment and profile on",
          settings: { ultrafast_mode: true },
          extraEnv: { FX_ULTRAFAST: "1" },
          args: ["--no-ultrafast"],
          ultrafast: false,
        },
        { name: "workspace on", settings: { ultrafast_mode: false }, workspace: true, extraEnv: {}, args: [], ultrafast: true },
        { name: "workspace off", settings: { ultrafast_mode: true }, workspace: false, extraEnv: {}, args: [], ultrafast: false },
        { name: "environment overrides workspace", settings: { ultrafast_mode: false }, workspace: true, extraEnv: { FX_ULTRAFAST: "0" }, args: [], ultrafast: false },
      ];

      for (const scenario of cases) {
        const root = createIsolatedRoot(scenario.settings);
        if ("workspace" in scenario) {
          writeProfileSettings(root, {
            ...scenario.settings,
            workspaces: { [root.workspace]: { ultrafast_mode: scenario.workspace } },
          });
        }
        const settingsPath = join(root.home, ".fx", "settings.json");
        const settingsBefore = readFileSync(settingsPath, "utf8");
        const gateway = startFakeGateway(
          [finishWithServiceTier(`response for ${scenario.name}`, scenario.ultrafast ? "ultrafast" : "standard")],
          { models: [ultrafastCatalogModel()] },
        );
        try {
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", ...scenario.args, `Test ${scenario.name}.`],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, scenario.extraEnv),
              timeoutMs: TIMEOUT,
            },
          );
          expect(result.code, `${scenario.name}: ${result.stderr}`).toBe(0);
          if (!("workspace" in scenario)) expect(result.stderr).toBe("");
          expect(JSON.parse(result.stdout).output).toBe(`response for ${scenario.name}`);
          expect(gateway.requests).toHaveLength(1);
          if (scenario.ultrafast) expectUltrafastRequest(gateway.requests[0]!.body);
          else expectStandardRequest(gateway.requests[0]!.body);
          expect(readFileSync(settingsPath, "utf8")).toBe(settingsBefore);
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "ask rejects conflicting Ultrafast flags before any POST",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([], { models: [ultrafastCatalogModel()] });
      try {
        const result = await runFx(
          ["ask", "--auto", "--no-save", "--ultrafast", "--no-ultrafast", "Conflicting flags must not spend."],
          { cwd: root.workspace, env: fakeGatewayEnv(root, gateway), timeoutMs: TIMEOUT },
        );
        expect(result.code, result.stderr).toBe(1);
        expect(result.stdout).toBe("");
        expect(result.stderr).toMatch(/ultrafast/i);
        expect(result.stderr).not.toMatch(/panic|segmentation fault|aborted/i);
        expect(gateway.requests).toEqual([]);
        expect(gateway.classifierRequests).toEqual([]);
        expect(gateway.evaluationRequests).toEqual([]);
        expect(gateway.titleRequests).toEqual([]);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "rejects an invalid FX_ULTRAFAST value before any completion POST",
    async () => {
      const root = createIsolatedRoot({ ultrafast_mode: true });
      const gateway = startFakeGateway([], { models: [ultrafastCatalogModel()] });
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Invalid overrides must not spend."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, { FX_ULTRAFAST: "paid" }),
            timeoutMs: TIMEOUT,
          },
        );
        expectAskJsonError(result);
        expect(gateway.requests).toEqual([]);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ignores project ultrafast defaults and preserves the Fast request path",
    async () => {
      const root = createIsolatedRoot();
      writeFileSync(
        join(root.workspace, ".fx.json"),
        `${JSON.stringify({ ultrafast_mode: true })}\n`,
        { mode: 0o600 },
      );
      const gateway = startFakeGateway(
        [fakeGatewayFinalText("project default ignored"), fakeGatewayFinalText("Fast remains available")],
        { models: [ultrafastCatalogModel()] },
      );
      try {
        const env = fakeGatewayEnv(root, gateway);
        const defaultResult = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Project defaults must not enable Ultra."],
          { cwd: root.workspace, env, timeoutMs: TIMEOUT },
        );
        expect(defaultResult.code, defaultResult.stderr).toBe(0);
        expect(gateway.requests).toHaveLength(1);
        expectStandardRequest(gateway.requests[0]!.body);

        const fastResult = await runFx(
          ["ask", "--auto", "--json", "--no-save", "--fast", "Fast remains independent."],
          { cwd: root.workspace, env, timeoutMs: TIMEOUT },
        );
        expect(fastResult.code, fastResult.stderr).toBe(0);
        expect(gateway.requests).toHaveLength(2);
        const request = JSON.parse(gateway.requests[1]!.body) as {
          providerOptions?: { gateway?: { only?: string[]; speed?: string }; openai?: { serviceTier?: string } };
        };
        expect(request.providerOptions?.gateway).toMatchObject({ speed: "fast" });
        expect(request.providerOptions?.gateway?.only).toBeUndefined();
        expect(request.providerOptions?.openai?.serviceTier).toBeUndefined();
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  for (const backend of ["0", "1"]) {
    test(
      `a saved session retains Ultrafast until an explicit CLI disable with FX_SESSIONS_V2=${backend}`,
      async () => {
        const root = createIsolatedRoot({ ultrafast_mode: true, models: { gateway: ULTRA_MODEL } });
        const gateway = startFakeGateway(
          [
            finishWithServiceTier("paid preference saved", "ultrafast"),
            finishWithServiceTier("durable paid preference resumed", "ultrafast"),
            fakeGatewayFinalText("resumed without the paid tier"),
          ],
          { models: [ultrafastCatalogModel()] },
        );
        try {
          const env = fakeGatewayEnv(root, gateway, { FX_MODEL: undefined, FX_SESSIONS_V2: backend });
          const saved = await runFx(
            ["ask", "--auto", "--json", "Save the paid-tier preference."],
            { cwd: root.workspace, env, timeoutMs: TIMEOUT },
          );
          expect(saved.code, saved.stderr).toBe(0);
          expect(saved.stderr).toBe("");
          expect(gateway.requests).toHaveLength(1);
          const sessionId = JSON.parse(saved.stdout).session_id as string;
          expect(sessionId).toBeTruthy();
          expectUltrafastRequest(gateway.requests[0]!.body);

          writeProfileSettings(root, {
            ultrafast_mode: false,
            models: { gateway: ULTRA_MODEL },
          });
          const durableResume = await runFx(
            ["ask", "--auto", "--json", "--resume", sessionId, "Resume the saved paid preference."],
            { cwd: root.workspace, env, timeoutMs: TIMEOUT },
          );
          expect(durableResume.code, durableResume.stderr).toBe(0);
          expect(durableResume.stderr).toBe("");
          expect(gateway.requests).toHaveLength(2);
          expectUltrafastRequest(gateway.requests[1]!.body);

          const disabledResume = await runFx(
            ["ask", "--auto", "--json", "--resume", sessionId, "--no-ultrafast", "Resume without the paid tier."],
            { cwd: root.workspace, env, timeoutMs: TIMEOUT },
          );
          expect(disabledResume.code, disabledResume.stderr).toBe(0);
          expect(disabledResume.stderr).toBe("");
          expect(gateway.requests).toHaveLength(3);
          expectStandardRequest(gateway.requests[2]!.body);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: false, models: { gateway: ULTRA_MODEL } });
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  }

  test(
    "process-only Ultrafast overrides do not revive paid routing on a later resume",
    async () => {
      for (const scenario of [
        { name: "CLI", args: ["--ultrafast"], env: {} },
        { name: "environment", args: [], env: { FX_ULTRAFAST: "1" } },
      ]) {
        const root = createIsolatedRoot({
          ultrafast_mode: false,
          models: { gateway: ULTRA_MODEL },
        });
        const gateway = startFakeGateway(
          [
            finishWithServiceTier(`${scenario.name} process override`, "ultrafast"),
            fakeGatewayFinalText(`${scenario.name} resume uses the default tier`),
          ],
          { models: [ultrafastCatalogModel()] },
        );
        try {
          const initial = await runFx(
            ["ask", "--auto", "--json", ...scenario.args, "Use a process-only Ultra override."],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, { FX_MODEL: undefined, ...scenario.env }),
              timeoutMs: TIMEOUT,
            },
          );
          expect(initial.code, initial.stderr).toBe(0);
          expect(initial.stderr).toBe("");
          expect(gateway.requests).toHaveLength(1);
          const sessionId = JSON.parse(initial.stdout).session_id as string;
          expectUltrafastRequest(gateway.requests[0]!.body);

          const resumed = await runFx(
            ["ask", "--auto", "--json", "--resume", sessionId, "Resume without process overrides."],
            {
              cwd: root.workspace,
              env: fakeGatewayEnv(root, gateway, { FX_MODEL: undefined }),
              timeoutMs: TIMEOUT,
            },
          );
          expect(resumed.code, resumed.stderr).toBe(0);
          expect(resumed.stderr).toBe("");
          expect(gateway.requests).toHaveLength(2);
          expectStandardRequest(gateway.requests[1]!.body);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: false, models: { gateway: ULTRA_MODEL } });
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "a selected Sol with Ultrafast prices serializes the paid tier",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway(
        [finishWithServiceTier("eligible Sol response", "ultrafast")],
        { models: [{ ...ultrafastCatalogModel(), id: SOL_MODEL }] },
      );
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "--ultrafast", "Use eligible Sol."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway, { FX_MODEL: SOL_MODEL }),
            timeoutMs: TIMEOUT,
          },
        );
        expect(result.code, result.stderr).toBe(0);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout)).toMatchObject({ model: SOL_MODEL, output: "eligible Sol response" });
        expect(gateway.modelRequests.length).toBeGreaterThan(0);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(SOL_MODEL);
        expectUltrafastRequest(gateway.requests[0]!.body);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "blocks unsupported and unknown catalogs before a paid-tier completion POST",
    async () => {
      for (const scenario of [
        {
          name: "Sol without an ultrafast price",
          model: SOL_MODEL,
          models: [solCatalogModel()],
        },
        {
          name: "catalog unavailable",
          model: ULTRA_MODEL,
          models: () => new Response("unavailable", { status: 503 }),
        },
      ]) {
        const root = createIsolatedRoot();
        const gateway = startFakeGateway([], { models: scenario.models });
        try {
          const env = fakeGatewayEnv(root, gateway, { FX_MODEL: scenario.model });
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", "--ultrafast", "Attempt premium routing."],
            { cwd: root.workspace, env, timeoutMs: TIMEOUT },
          );
          expectAskJsonError(result);
          if (scenario.model === SOL_MODEL) {
            expect(JSON.parse(result.stdout).error).toBe("UltrafastUnavailable");
          }
          expect(gateway.modelRequests.length).toBeGreaterThan(0);
          expect(gateway.requests).toEqual([]);
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "rejects strict provider routing that excludes OpenAI before a completion POST",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([], { models: [ultrafastCatalogModel()] });
      try {
        const result = await runFx(
          [
            "ask",
            "--auto",
            "--json",
            "--no-save",
            "--ultrafast",
            "--provider-order",
            "anthropic",
            "--provider-strict",
            "Do not permit OpenAI routing.",
          ],
          { cwd: root.workspace, env: fakeGatewayEnv(root, gateway), timeoutMs: TIMEOUT },
        );
        expectAskJsonError(result);
        expect(gateway.requests).toEqual([]);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "ACP rejects Ultrafast on selected Sol without prices and does not POST",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([], { models: [solCatalogModel()] });
      const client = AcpClient.create(
        root.workspace,
        fakeGatewayEnv(root, gateway, { FX_MODEL: SOL_MODEL }),
      );
      try {
        const sessionId = await startAcpSession(client);
        const rejected = await client.request(
          "session/set_config_option",
          { sessionId, configId: "ultrafast", value: "true" },
          3,
        );
        expect(rejected.error).toMatchObject({
          code: -32602,
          data: {
            code: "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST",
            model: SOL_MODEL,
            capability: "ultrafast",
          },
        });
        expect(gateway.requests).toEqual([]);
      } finally {
        try {
          await client.close();
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "ACP rejects nonboolean Ultrafast values without POST or changing the next prompt",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway(
        [fakeGatewayFinalText("ACP remains standard")],
        { models: [ultrafastCatalogModel()] },
      );
      const client = AcpClient.create(root.workspace, fakeGatewayEnv(root, gateway));
      try {
        const sessionId = await startAcpSession(client);
        for (const [index, value] of ["toggle", true].entries()) {
          const rejected = await client.request(
            "session/set_config_option",
            { sessionId, configId: "ultrafast", value },
            3 + index,
          );
          expect(rejected.error, JSON.stringify(rejected)).toMatchObject({ code: -32602 });
          expect(gateway.requests).toEqual([]);
        }
        const updates = await client.prompt(sessionId, "Invalid options must leave Ultra off.", 5);
        expect(JSON.stringify(updates)).toContain("ACP remains standard");
        expect(gateway.requests).toHaveLength(1);
        expectStandardRequest(gateway.requests[0]!.body);
      } finally {
        try {
          await client.close();
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );

  test(
    "ACP launch flags override environment and profile Ultrafast settings",
    async () => {
      for (const scenario of [
        { name: "profile", settings: { ultrafast_mode: true }, env: {}, args: [], ultrafast: true },
        { name: "environment", settings: { ultrafast_mode: false }, env: { FX_ULTRAFAST: "1" }, args: [], ultrafast: true },
        { name: "CLI enable", settings: { ultrafast_mode: false }, env: { FX_ULTRAFAST: "0" }, args: ["--ultrafast"], ultrafast: true },
        { name: "CLI disable", settings: { ultrafast_mode: true }, env: { FX_ULTRAFAST: "1" }, args: ["--no-ultrafast"], ultrafast: false },
      ]) {
        const root = createIsolatedRoot(scenario.settings);
        const gateway = startFakeGateway(
          [finishWithServiceTier(`ACP ${scenario.name}`, scenario.ultrafast ? "ultrafast" : "standard")],
          { models: [ultrafastCatalogModel()] },
        );
        const client = AcpClient.create(
          root.workspace,
          fakeGatewayEnv(root, gateway, scenario.env),
          scenario.args,
        );
        try {
          const sessionId = await startAcpSession(client);
          expect(gateway.requests).toEqual([]);
          const updates = await client.prompt(sessionId, "Use the launch setting.", 3);
          expect(JSON.stringify(updates)).toContain(`ACP ${scenario.name}`);
          expect(gateway.requests).toHaveLength(1);
          if (scenario.ultrafast) expectUltrafastRequest(gateway.requests[0]!.body);
          else expectStandardRequest(gateway.requests[0]!.body);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject(scenario.settings);
        } finally {
          try {
            await client.close();
          } finally {
            gateway.stop();
            rmSync(root.root, { recursive: true, force: true });
          }
        }
      }
    },
    TIMEOUT,
  );

  for (const backend of ["0", "1"]) {
    test(
      `ACP saves Ultrafast enable and disable across load and resume with FX_SESSIONS_V2=${backend}`,
      async () => {
        const root = createIsolatedRoot({ ultrafast_mode: false, models: { gateway: ULTRA_MODEL } });
        const gateway = startFakeGateway(
          [
            finishWithServiceTier("ACP saved Ultra", "ultrafast"),
            finishWithServiceTier("ACP loaded Ultra", "ultrafast"),
            fakeGatewayFinalText("ACP resumed standard"),
          ],
          { models: [ultrafastCatalogModel()] },
        );
        const env = fakeGatewayEnv(root, gateway, { FX_MODEL: undefined, FX_SESSIONS_V2: backend });
        let client = AcpClient.create(root.workspace, env);
        try {
          const sessionId = await startAcpSession(client);
          const enabled = await client.request(
            "session/set_config_option", { sessionId, configId: "ultrafast", value: "true" }, 3,
          );
          expect(enabled.error).toBeUndefined();
          const saved = await client.prompt(sessionId, "Persist Ultra in this session.", 4);
          expect(JSON.stringify(saved)).toContain("ACP saved Ultra");
          expect(gateway.requests).toHaveLength(1);
          expectUltrafastRequest(gateway.requests[0]!.body);
          await client.close();

          client = AcpClient.create(root.workspace, env);
          expect((await client.request("initialize", { protocolVersion: 1 }, 1)).error).toBeUndefined();
          const loaded = await client.request("session/load", { sessionId, mcpServers: [] }, 2);
          expect(loaded.error, JSON.stringify(loaded)).toBeUndefined();
          expect(loaded.result?.configOptions).toContainEqual(expect.objectContaining({
            id: "ultrafast", currentValue: "true",
          }));
          expect(gateway.requests).toHaveLength(1);
          const continued = await client.prompt(sessionId, "Continue the saved Ultra session.", 3);
          expect(JSON.stringify(continued)).toContain("ACP loaded Ultra");
          expect(gateway.requests).toHaveLength(2);
          expectUltrafastRequest(gateway.requests[1]!.body);
          expect(gateway.requests[1]!.body).toContain("ACP saved Ultra");
          const disabled = await client.request(
            "session/set_config_option", { sessionId, configId: "ultrafast", value: "false" }, 4,
          );
          expect(disabled.error).toBeUndefined();
          await client.close();

          writeProfileSettings(root, { ultrafast_mode: true, models: { gateway: ULTRA_MODEL } });
          client = AcpClient.create(root.workspace, env);
          expect((await client.request("initialize", { protocolVersion: 1 }, 1)).error).toBeUndefined();
          const resumed = await client.request("session/resume", { sessionId, mcpServers: [] }, 2);
          expect(resumed.error, JSON.stringify(resumed)).toBeUndefined();
          expect(resumed.result?.configOptions).toContainEqual(expect.objectContaining({
            id: "ultrafast", currentValue: "false",
          }));
          expect(gateway.requests).toHaveLength(2);
          const standard = await client.prompt(sessionId, "Resume the durable disable.", 3);
          expect(JSON.stringify(standard)).toContain("ACP resumed standard");
          expect(gateway.requests).toHaveLength(3);
          expectStandardRequest(gateway.requests[2]!.body);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: true });
        } finally {
          try {
            await client.close();
          } finally {
            gateway.stop();
            rmSync(root.root, { recursive: true, force: true });
          }
        }
      },
      TIMEOUT,
    );
  }

  test(
    "an allowed subagent child inherits ultrafast routing",
    async () => {
      const root = createIsolatedRoot();
      let turn = 0;
      const gateway = startDynamicFakeGateway(() => {
        turn += 1;
        if (turn === 1) {
          return fakeGatewayToolCall(
            "subagent_1",
            "subagent",
            { request: { action: "run", task: "ultrafast-child-marker" } },
          );
        }
        if (turn === 2) return finishWithServiceTier("child completed", "ultrafast");
        return finishWithServiceTier("parent observed the child", "ultrafast");
      }, { models: [ultrafastCatalogModel()] });
      try {
        const result = await runFx(
          ["ask", "--full-access", "--json", "--ultrafast", "Delegate one task."],
          { cwd: root.workspace, env: fakeGatewayEnv(root, gateway), timeoutMs: TIMEOUT },
        );
        expect(result.code, result.stderr).toBe(0);
        expect(JSON.parse(result.stdout).output).toBe("parent observed the child");
        expect(gateway.requests).toHaveLength(3);
        expect(gateway.requests[1]!.body).toContain("ultrafast-child-marker");
        for (const { body } of gateway.requests) expectUltrafastRequest(body);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a named v2 subagent continues its history but cannot bypass the parent's Ultrafast disable",
    async () => {
      const root = createIsolatedRoot({ ultrafast_mode: true, models: { gateway: ULTRA_MODEL } });
      const childBodies: string[] = [];
      let parentRequests = 0;
      const gateway = startDynamicFakeGateway((body) => {
        if (!body.includes('"name":"subagent"')) {
          childBodies.push(body);
          return finishWithServiceTier(
            `ULTRA_CHILD_${childBodies.length}`,
            childBodies.length < 3 ? "ultrafast" : "standard",
          );
        }
        parentRequests += 1;
        const round = Math.ceil(parentRequests / 2);
        if (parentRequests > 6) return new Response("unexpected parent turn", { status: 500 });
        if (parentRequests % 2 === 1) {
          return fakeGatewayToolCall(`named-ultra-${round}`, "subagent", {
            request: {
              action: "message",
              agent: "reviewer",
              message: `ultrafast named review round ${round}`,
              ...(round === 1 ? { instructions: "Follow ULTRA_REVIEWER_RULES." } : {}),
            },
          });
        }
        return finishWithServiceTier(`ULTRA_PARENT_${round}`, round < 3 ? "ultrafast" : "standard");
      }, { models: [ultrafastCatalogModel()] });
      try {
        const env = fakeGatewayEnv(root, gateway, { FX_MODEL: undefined, FX_SESSIONS_V2: "1" });
        let sessionId: string | undefined;
        for (const round of [1, 2, 3]) {
          const result = await runFx(
            [
              "ask", "--full-access", "--json",
              ...(sessionId ? ["--resume", sessionId] : []),
              ...(round === 3 ? ["--no-ultrafast"] : []),
              `Ask the named reviewer for round ${round}.`,
            ],
            { cwd: root.workspace, env, timeoutMs: TIMEOUT },
          );
          expect(result.code, result.stderr).toBe(0);
          const payload = JSON.parse(result.stdout);
          expect(payload.output).toBe(`ULTRA_PARENT_${round}`);
          if (sessionId) expect(payload.session_id).toBe(sessionId);
          sessionId = payload.session_id;
          expect(gateway.requests).toHaveLength(round * 3);
          expect(childBodies).toHaveLength(round);
          for (const { body } of gateway.requests.slice((round - 1) * 3)) {
            if (round < 3) expectUltrafastRequest(body);
            else expectStandardRequest(body);
          }
        }
        expect(childBodies[0]).toContain("ULTRA_REVIEWER_RULES");
        for (const body of childBodies.slice(1)) {
          expect(body).toContain("ULTRA_REVIEWER_RULES");
          expect(body).toContain("ultrafast named review round 1");
          expect(body).toContain("ULTRA_CHILD_1");
        }
        expect(childBodies[2]).toContain("ULTRA_CHILD_2");
        const log = readFileSync(join(root.home, ".fx", "sessions", "v2", sessionId!, "log.jsonl"), "utf8")
          .trimEnd().split("\n").map((line) => JSON.parse(line));
        const spawned = log.filter((line) => line.kind === "child_spawned");
        expect(spawned).toHaveLength(3);
        expect(new Set(spawned.map((line) => line.child)).size).toBe(1);
        expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
          .toMatchObject({ ultrafast_mode: true });
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  describe.skipIf(TMUX_SKIP)("interactive /ultrafast", () => {
    test(
      "interactive launch flags override environment and profile without persisting the override",
      async () => {
        for (const scenario of [
          { flag: "--ultrafast", profile: false, env: "0", ultrafast: true },
          { flag: "--no-ultrafast", profile: true, env: "1", ultrafast: false },
        ]) {
          const root = createIsolatedRoot({ ultrafast_mode: scenario.profile });
          const gateway = startFakeGateway(
            [finishWithServiceTier("interactive launch response", scenario.ultrafast ? "ultrafast" : "standard")],
            { models: [ultrafastCatalogModel()] },
          );
          const stderrPath = join(root.root, "stderr.txt");
          let session: TmuxSession | null = null;
          try {
            session = await TmuxSession.create({
              cmd: `"${FX_BIN}" ${scenario.flag}`,
              cwd: root.workspace,
              isolated: true,
              stderrPath,
              env: fakeGatewayEnv(root, gateway, { FX_ULTRAFAST: scenario.env, COLORTERM: "truecolor" }),
            });
            await session.waitForComposer(TIMEOUT);
            await waitForGatewayModelCatalog(gateway);
            await session.sendText("/ultrafast status");
            await session.waitForText(`requested: ${scenario.ultrafast ? "on" : "off"}`, TIMEOUT);
            expect(gateway.requests).toEqual([]);
            await session.sendText("Return the interactive launch response.");
            await session.waitForText("interactive launch response", TIMEOUT);
            await session.waitForStableComposer(TIMEOUT);
            expect((await session.capturePaneEscapes()).includes("\x1b[38;2;255;204;0m⚡︎")).toBe(scenario.ultrafast);
            expect(await session.captureFullScrollback()).toContain("interactive launch response");
            expect(gateway.requests).toHaveLength(1);
            if (scenario.ultrafast) expectUltrafastRequest(gateway.requests[0]!.body);
            else expectStandardRequest(gateway.requests[0]!.body);
            expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
              .toMatchObject({ ultrafast_mode: scenario.profile });
            expect(session.paneStatus()).toEqual({ dead: false, status: null });
            await session.sendText("/quit");
            await session.waitForSessionEnd(TIMEOUT);
            expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
            expect(readFileSync(stderrPath, "utf8")).toBe("");
          } finally {
            if (session) await session.kill();
            gateway.stop();
            rmSync(root.root, { recursive: true, force: true });
          }
        }
      },
      TIMEOUT,
    );

    test(
      "the Settings Ultra row persists across restart and serializes the next prompt",
      async () => {
        const root = createIsolatedRoot({ ultrafast_mode: false, models: { gateway: ULTRA_MODEL } });
        const gateway = startFakeGateway(
          [
            finishWithServiceTier("Settings enabled Ultra", "ultrafast"),
            finishWithServiceTier("Settings restored Ultra", "ultrafast"),
            fakeGatewayFinalText("Settings disabled Ultra"),
          ],
          { models: [ultrafastCatalogModel()] },
        );
        const stderrPath = join(root.root, "stderr.txt");
        const env = fakeGatewayEnv(root, gateway, { FX_MODEL: undefined, FX_SESSIONS_V2: "1" });
        let session: TmuxSession | null = null;
        try {
          session = await TmuxSession.create({ cwd: root.workspace, isolated: true, stderrPath, env });
          await session.waitForComposer(TIMEOUT);
          await waitForGatewayModelCatalog(gateway);
          await session.sendText("/settings");
          await session.waitForText("←→ change", TIMEOUT);
          await session.sendLiteral("ultra");
          await session.waitForPane((pane) => /Ultra mode\s+off\s+on/.test(pane), TIMEOUT);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: false });
          expect(gateway.requests).toEqual([]);
          await session.sendKeys("Right");
          await session.waitForPane(
            (pane) => /Ultra mode\s+off\s+on/.test(pane) && pane.includes("* ultrafast: requested on"),
            TIMEOUT,
          );
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: true });
          await session.sendKeys("Escape");
          await session.waitForPane((pane) => hasEmptyComposer(pane) && !pane.includes("←→ change"), TIMEOUT);
          await session.sendText("Return the Settings enabled marker.");
          await session.waitForText("Settings enabled Ultra", TIMEOUT);
          await session.waitForStableComposer(TIMEOUT);
          expect(gateway.requests).toHaveLength(1);
          expectUltrafastRequest(gateway.requests[0]!.body);
          expect(await session.captureFullScrollback()).toContain("Settings enabled Ultra");
          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
          expect(readFileSync(stderrPath, "utf8")).toBe("");
          await session.kill();
          session = null;

          session = await TmuxSession.create({ cwd: root.workspace, isolated: true, stderrPath, env });
          await session.waitForComposer(TIMEOUT);
          await session.sendText("Return the Settings restored marker.");
          await session.waitForText("Settings restored Ultra", TIMEOUT);
          await session.waitForStableComposer(TIMEOUT);
          expect(gateway.requests).toHaveLength(2);
          expectUltrafastRequest(gateway.requests[1]!.body);
          await session.sendText("/settings");
          await session.waitForText("←→ change", TIMEOUT);
          await session.sendLiteral("ultra");
          await session.waitForPane((pane) => /Ultra mode\s+off\s+on/.test(pane), TIMEOUT);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: true });
          await session.sendKeys("Left");
          await session.waitForPane(
            (pane) => /Ultra mode\s+off\s+on/.test(pane) && pane.includes("* ultrafast: requested off"),
            TIMEOUT,
          );
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: false });
          await session.sendKeys("Escape");
          await session.waitForPane((pane) => hasEmptyComposer(pane) && !pane.includes("←→ change"), TIMEOUT);
          await session.sendText("Return the Settings disabled marker.");
          await session.waitForText("Settings disabled Ultra", TIMEOUT);
          const settled = await session.waitForStableComposer(TIMEOUT);
          expect(settled).not.toContain("⚡︎");
          expect(await session.captureFullScrollback()).toContain("Settings disabled Ultra");
          expect(gateway.requests).toHaveLength(3);
          expectStandardRequest(gateway.requests[2]!.body);
          expect(session.paneStatus()).toEqual({ dead: false, status: null });
          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          if (session) await session.kill();
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );

    test.each(["dark", "light"] as const)(
      "the actual model picker selects Ultrafast, persists it, and shows vivid yellow in %s mode",
      async (theme) => {
        const root = createIsolatedRoot();
        const gateway = startFakeGateway(
          [finishWithServiceTier("marker selection response", "ultrafast")],
          { models: [ultrafastCatalogModel()] },
        );
        const stderrPath = join(root.root, "stderr.txt");
        let session: TmuxSession | null = null;
        try {
          session = await TmuxSession.create({
            cwd: root.workspace,
            isolated: true,
            stderrPath,
            env: fakeGatewayEnv(root, gateway, { FX_THEME: theme, COLORTERM: "truecolor" }),
          });
          await session.waitForComposer(TIMEOUT);
          await waitForGatewayModelCatalog(gateway);
          await session.sendKeys("C-p");
          const catalog = await session.waitForText("tab provider", TIMEOUT);
          expect(catalog).toContain(ULTRA_MODEL);
          expect(catalog).toContain("Ultra");
          await session.sendKeys("Enter");
          await session.waitForPane(
            (pane) => composerContains(pane, `/model ${ULTRA_MODEL}`) && pane.includes("xhigh"),
            TIMEOUT,
          );
          await session.sendLiteral("xhigh");
          await session.sendKeys("Enter");
          await session.waitForPane(
            (pane) => composerContains(pane, `/model ${ULTRA_MODEL} xhigh`) && pane.includes("ultrafast"),
            TIMEOUT,
          );
          await session.sendLiteral("ultrafast");
          await session.sendKeys("Enter");
          const switched = `Switched to ${ULTRA_MODEL} (effort: xhigh, speed: ultrafast)`;
          await session.waitForText(switched, TIMEOUT);
          await session.waitForText("gpt-6-astra · xhigh · ⚡︎", TIMEOUT);
          expect(await session.capturePaneEscapes()).toContain("\x1b[38;2;255;204;0m⚡︎");
          expect((await session.captureFullScrollback()).replace(/\s+/g, " ")).toContain(switched);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: true, models: { gateway: ULTRA_MODEL }, effort: "xhigh" });
          expect(gateway.requests).toEqual([]);
          await session.sendText("Return the marker selection response.");
          await session.waitForText("marker selection response", TIMEOUT);
          expect(gateway.requests).toHaveLength(1);
          expectUltrafastRequest(gateway.requests[0]!.body);
          await session.sendText("/ultrafast off");
          await session.waitForText("requested off", TIMEOUT);
          expect(await session.capturePane()).not.toContain("⚡︎");
          await session.sendText(`/model ${ULTRA_MODEL} high fast`);
          await session.waitForText(`Switched to ${ULTRA_MODEL} (effort: high, speed: fast)`, TIMEOUT);
          const pane = await session.capturePane();
          expect(pane).toContain("gpt-6-astra · high · ⚡︎");
          expect(await session.capturePaneEscapes()).not.toContain("\x1b[38;2;255;204;0m⚡︎");
          expect(session.paneStatus()).toEqual({ dead: false, status: null });
          expect(gateway.requests).toHaveLength(1);
          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          if (session) await session.kill();
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );

    test(
      "on, off, and status use the live slash command and persist the request",
      async () => {
        const root = createIsolatedRoot();
        const gateway = startFakeGateway([], { models: [ultrafastCatalogModel()] });
        const stderrPath = join(root.root, "stderr.txt");
        let session: TmuxSession | null = null;
        try {
          session = await TmuxSession.create({
            cwd: root.workspace,
            isolated: true,
            stderrPath,
            env: fakeGatewayEnv(root, gateway),
          });
          await session.waitForComposer(TIMEOUT);
          await waitForGatewayModelCatalog(gateway);

          await session.sendText("/ultrafast");
          await session.waitForText("requested: off", TIMEOUT);
          await session.sendText("/ultrafast on");
          await session.waitForText("requested on", TIMEOUT);
          await session.sendText("/ultrafast status");
          await session.waitForText("requested: on", TIMEOUT);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: true });

          await session.sendText("/ultrafast off");
          await session.waitForText("requested off", TIMEOUT);
          expect(JSON.parse(readFileSync(join(root.home, ".fx", "settings.json"), "utf8")))
            .toMatchObject({ ultrafast_mode: false });
          expect(session.paneStatus()).toEqual({ dead: false, status: null });
          expect(gateway.requests).toEqual([]);
          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          if (session) await session.kill();
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );

    test(
      "a provider response that does not confirm Ultrafast uses the exact operational notice",
      async () => {
        const root = createIsolatedRoot();
        const gateway = startFakeGateway(
          [finishWithServiceTier("downgraded answer", "standard")],
          { models: [ultrafastCatalogModel()] },
        );
        const stderrPath = join(root.root, "stderr.txt");
        let session: TmuxSession | null = null;
        try {
          session = await TmuxSession.create({
            cwd: root.workspace,
            isolated: true,
            width: 40,
            height: 20,
            minimumHistoryLines: 320,
            stderrPath,
            env: fakeGatewayEnv(root, gateway, { FX_ULTRAFAST: "1" }),
          });
          await session.waitForComposer(TIMEOUT);
          await waitForGatewayModelCatalog(gateway);
          await session.sendText("Return the downgrade sentinel.");
          await session.waitForText("downgraded answer", TIMEOUT);
          const scrollback = normalizeTerminalWhitespace(
            await session.captureFullScrollback(),
          );
          expect(scrollback).toContain(
            "Ultrafast was requested, but Gateway did not confirm it was served; this response may have used a standard or lower tier.",
          );
          await session.sendText("/ultrafast status");
          await session.waitForText("requested: on", TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: false, status: null });
          expect(gateway.requests).toHaveLength(1);
          expectUltrafastRequest(gateway.requests[0]!.body);
          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          if (session) await session.kill();
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  });
});
