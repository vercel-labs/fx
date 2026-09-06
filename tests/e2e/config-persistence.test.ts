import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const NO_AUTH = {
  AI_GATEWAY_API_KEY: "",
  VERCEL_OIDC_TOKEN: "",
  FX_MODEL: undefined,
  NO_COLOR: "1",
};

const serialTest = test.serial;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";

function selectedModelStageRow(paneEscapes: string, label: string): string | null {
  return paneEscapes.split("\n").find((line) => {
    const visible = line.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").trim();
    return line.includes(SELECTED_COMPLETION_SGR) && visible === label;
  }) ?? null;
}

async function waitForSelectedModelStage(
  active: TmuxSession,
  label: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last: string | null = null;
  while (Date.now() < deadline) {
    last = selectedModelStageRow(await active.capturePaneEscapes(), label);
    if (last !== null) return last;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for selected model option ${label}; last=${last}`);
}

async function disablePromptHistory(
  session: TmuxSession,
  settingsPath: string,
): Promise<void> {
  await session.sendText("/settings");
  await session.waitForText("←→ Change", TIMEOUT);
  await session.sendLiteral("prompt history");
  await session.waitForPane(
    (pane) => pane.includes("Prompt history") && !pane.includes("Startup scrollback"),
    TIMEOUT,
  );
  await session.sendKeys("Left");
  const deadline = Date.now() + TIMEOUT;
  let enabled: unknown;
  while (Date.now() < deadline) {
    if (existsSync(settingsPath)) {
      enabled = JSON.parse(readFileSync(settingsPath, "utf8")).prompt_history?.enabled;
      if (enabled === false) break;
    }
    await Bun.sleep(25);
  }
  if (enabled !== false) throw new Error("Timed out disabling prompt history");
  await session.sendKeys("Escape");
  await session.waitForPane(
    (pane) => hasEmptyComposer(pane) && !pane.includes("←→ Change"),
    TIMEOUT,
  );
}

function tree(root: string, relative = ""): string[] {
  const path = relative ? join(root, relative) : root;
  const entries = readdirSync(path, { withFileTypes: true });
  const result: string[] = [];
  for (const entry of entries) {
    const child = relative ? join(relative, entry.name) : entry.name;
    result.push(child);
    if (entry.isDirectory()) result.push(...tree(root, child));
  }
  return result.sort();
}

function migrationSnapshotPath(home: string, field: string): string {
  const backups = join(home, ".fx", "backups");
  const name = `settings.json.preference-migration.${field}.json`;
  expect(readdirSync(backups)).toContain(name);
  return join(backups, name);
}

function clearedPaneWithoutAllowlistRules(pane: string): boolean {
  return (
    hasEmptyComposer(pane) &&
    !pane.includes("● Allowlist:") &&
    !pane.includes("user *")
  );
}

describe.skipIf(!tmuxAvailable())("config persistence", () => {
  let session: TmuxSession | null = null;
  let secondSession: TmuxSession | null = null;

  afterEach(async () => {
    await session?.kill();
    await secondSession?.kill();
    session = null;
    secondSession = null;
  });

  serialTest(
    "user preferences migrate globally and load in another project",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-persistence-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "anthropic/claude-opus-4.7",
          type: "language",
          tags: ["tool-use"],
          reasoning_options: [{ type: "effort", values: ["high"] }],
          fast_options: [{ type: "toggle" }],
        }],
      });
      try {
        const home = join(root, "home");
        const workspaceA = join(root, "workspace-a");
        const workspaceB = join(root, "workspace-b");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspaceA);
        mkdirSync(workspaceB);
        const workspaceARoot = realpathSync(workspaceA);
        const workspaceBRoot = realpathSync(workspaceB);
        const projectABytes = "{\"project_future\":{\"name\":\"a\"}}\n";
        const projectBBytes = "{\"project_future\":{\"name\":\"b\"}}\n";
        writeFileSync(join(workspaceA, ".fx.json"), projectABytes);
        writeFileSync(join(workspaceB, ".fx.json"), projectBBytes);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            future_global: { nested: "preserve-me" },
            workspaces: {
              [workspaceARoot]: {
                model: "legacy/project-a",
                permission_mode: "ask",
                effort: "low",
                fast_mode: false,
                startup_scrollback: true,
                prompt_history: { enabled: true, future: "keep-a-history" },
                statusLine: {
                  sandbox: false,
                  context: false,
                  session: false,
                  workspace: false,
                  future: "keep-a-status",
                },
                future_workspace: { nested: "a" },
              },
              [workspaceBRoot]: {
                model: "legacy/project-b",
                permission_mode: "ask",
                effort: "high",
                fast_mode: false,
                startup_scrollback: true,
                prompt_history: { enabled: true, future: "keep-b-history" },
                statusLine: {
                  sandbox: false,
                  context: false,
                  session: false,
                  workspace: false,
                  future: "keep-b-status",
                },
                future_workspace: { nested: "b" },
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const catalogEnv = {
          ...NO_AUTH,
          HOME: home,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        };

        session = await TmuxSession.create({
          cwd: workspaceARoot,
          env: catalogEnv,
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendKeys("BTab");
        await session.waitForText("auto ·", TIMEOUT);
        await session.pasteText("/model anthropic/claude-opus-4.7 auto normal");
        const beforeModelCommit = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(beforeModelCommit).not.toHaveProperty("model");
        await session.sendKeys("Enter");
        await session.waitForText("● Switched to anthropic/claude-opus-4.7", TIMEOUT);
        await session.sendText("/fast");
        await session.waitForText("● Fast: on", TIMEOUT);
        await session.sendText("/statusline context");
        await session.waitForText("● Statusline: context:", TIMEOUT);
        await session.sendText("/statusline session");
        await session.waitForText("● Statusline: session:", TIMEOUT);
        await session.sendText("/statusline workspace");
        await session.waitForText("● Statusline: workspace:", TIMEOUT);
        await session.sendText("/settings startup-scrollback off");
        await session.waitForText("startup_scrollback: off", TIMEOUT);
        await disablePromptHistory(session, join(home, ".fx", "settings.json"));
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored.models.gateway).toBe("anthropic/claude-opus-4.7");
        expect(stored.permission_mode).toBe("auto");
        expect(stored.effort).toBe("auto");
        expect(stored.fast_mode).toBe(true);
        expect(stored.fast_mode_model_bound).toBe(true);
        expect(stored.startup_scrollback).toBe(false);
        expect(stored.prompt_history).toMatchObject({ enabled: false });
        expect(stored.statusLine).toMatchObject({
          context: true,
          session: true,
          workspace: true,
        });
        expect(stored.future_global).toEqual({ nested: "preserve-me" });
        for (const [workspaceRoot, futureWorkspace, historyFuture, statusFuture] of [
          [workspaceARoot, "a", "keep-a-history", "keep-a-status"],
          [workspaceBRoot, "b", "keep-b-history", "keep-b-status"],
        ] as const) {
          const override = stored.workspaces[workspaceRoot];
          expect(override).not.toHaveProperty("model");
          expect(override).not.toHaveProperty("permission_mode");
          expect(override).not.toHaveProperty("effort");
          expect(override).not.toHaveProperty("fast_mode");
          expect(override).not.toHaveProperty("startup_scrollback");
          expect(override.prompt_history).toEqual({ future: historyFuture });
          expect(override.statusLine).toEqual({ sandbox: false, workspace: false, future: statusFuture });
          expect(override.future_workspace).toEqual({ nested: futureWorkspace });
        }
        expect(readFileSync(join(workspaceA, ".fx.json"), "utf8")).toBe(projectABytes);
        expect(readFileSync(join(workspaceB, ".fx.json"), "utf8")).toBe(projectBBytes);

        const migrationSnapshots = [
          "model",
          "permission_mode",
          "effort",
          "fast_mode",
          "startup_scrollback",
          "prompt_history_enabled",
          "statusline_context",
          "statusline_session",
        ].map((field) => migrationSnapshotPath(home, field));
        for (const snapshotPath of migrationSnapshots) {
          expect(statSync(snapshotPath).mode & 0o777).toBe(0o600);
        }

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: catalogEnv,
          stderrPath: stderrBPath,
        });
        const startup = await session.waitForText(
          "auto · opus 4.7 · ⚡︎",
          TIMEOUT,
        );
        expect(startup).toContain("auto · opus 4.7 · ⚡︎");
        expect(startup).not.toContain("adaptive");
        expect(startup).not.toContain("⚡︎ fast");
        await session.sendText("/settings");
        const pane = await session.waitForText("←→ Change", TIMEOUT);
        expect(pane).toContain("anthropic/claude-opus-4.7");
        expect(pane).toContain("Startup scrollback");
        expect(pane).toContain("Prompt history");
        await session.sendKeys("Escape");
        await session.waitForPane(
          (current) =>
            hasEmptyComposer(current) && !current.includes("←→ Change"),
          TIMEOUT,
        );
        await session.sendText("/statusline");
        const statusline = await session.waitForText("Context  ", TIMEOUT);
        expect(statusline).toContain("Status line");
        expect(statusline).not.toContain("Sandbox");
        expect(statusline).toContain("Context");
        expect(statusline).toContain("Session");
        expect(statusline).toContain("off  on");
        await session.sendKeys("Escape");
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: {
            ...catalogEnv,
            FX_MODEL: "openai/gpt-5",
          },
          stderrPath: stderrBPath,
        });
        await session.waitForText("gpt-5", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterOverride = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterOverride.models.gateway).toBe("anthropic/claude-opus-4.7");
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    120_000,
  );

  serialTest(
    "unscoped allowlist stays local while explicit user rules cross projects",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-permission-scopes-"));
      try {
        const home = join(root, "home");
        const workspaceA = join(root, "workspace-a");
        const workspaceB = join(root, "workspace-b");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspaceA);
        mkdirSync(workspaceB);
        const workspaceARoot = realpathSync(workspaceA);
        const workspaceBRoot = realpathSync(workspaceB);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            permission: {
              " bash ": {
                " padded * ": "allow",
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceARoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText('/allowlist add command "local-a *"');
        await session.waitForText("(scope=local)", TIMEOUT);
        await session.sendText('/allowlist user add command "user *"');
        await session.waitForText("(scope=user)", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterA = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterA.permission.bash["user *"]).toBe("allow");
        expect(afterA.workspaces[workspaceARoot].permission.bash["local-a *"]).toBe(
          "allow",
        );
        expect(afterA.workspaces).not.toHaveProperty(workspaceBRoot);

        session = await TmuxSession.create({
          cwd: workspaceBRoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath: stderrBPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/allowlist view local");
        await session.waitForText(
          "● Allowlist: local persistent allow rules: (none)",
          TIMEOUT,
        );
        await session.sendText("/allowlist view user");
        await session.waitForText("user *", TIMEOUT);
        await session.sendText('/allowlist user remove command "padded *"');
        await session.waitForText("● Allowlist: removed command", TIMEOUT);
        await session.sendText("/clear");
        await session.waitForPane(
          clearedPaneWithoutAllowlistRules,
          TIMEOUT,
        );
        await session.sendText("/allowlist view effective");
        const inherited = await session.waitForText("user *", TIMEOUT);
        expect(inherited).toContain("● Allowlist: effective persistent allow rules:");

        await session.sendText('/allowlist add command "local-b *"');
        await session.waitForText("(scope=local)", TIMEOUT);
        await session.sendText("/allowlist view user");
        const shadowed = await session.waitForText(
          "user rules are shadowed by local settings",
          TIMEOUT,
        );
        expect(shadowed).toContain("user *");
        await session.sendText("/clear");
        await session.waitForPane(
          clearedPaneWithoutAllowlistRules,
          TIMEOUT,
        );
        await session.sendText("/allowlist view effective");
        const localEffective = await session.waitForText("local-b *", TIMEOUT);
        expect(localEffective).not.toContain("user *");

        await session.sendText('/allowlist user remove command "user *"');
        await session.waitForText("● Allowlist: removed command", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const afterB = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(afterB.permission).toEqual({});
        expect(afterB.workspaces[workspaceARoot].permission.bash["local-a *"]).toBe(
          "allow",
        );
        expect(afterB.workspaces[workspaceBRoot].permission.bash["local-b *"]).toBe(
          "allow",
        );
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    90_000,
  );

  serialTest(
    "legacy output settings remain inert and output text follows prompt admission",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-output-shadow-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const projectBytes =
          "{\"output_level\":{\"legacy\":true},\"future\":{\"keep\":true}}\n";
        writeFileSync(join(workspace, ".fx.json"), projectBytes);
        const unrelatedWorkspace = join(root, "unrelated-workspace");
        const settingsBytes =
          JSON.stringify({
            output_level: { legacy: true },
            startup_scrollback: true,
            workspaces: {
              [workspaceRoot]: {
                output_level: ["quiet", 7],
                future_workspace: { keep: true },
              },
              [unrelatedWorkspace]: {
                model: 123,
                future_workspace: { preserve: true },
              },
            },
          }) + "\n";
        writeFileSync(
          join(home, ".fx", "settings.json"),
          settingsBytes,
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: { ...NO_AUTH, HOME: home },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/output quiet");
        await session.waitForText("fx needs access to Vercel AI Gateway", TIMEOUT);
        expect(composerContains(await session.capturePane(), "/output quiet")).toBe(
          true,
        );
        await session.sendKeys("C-u");
        await session.waitForPane(hasEmptyComposer, TIMEOUT);
        await session.sendText("/settings startup-scrollback off");
        await session.waitForText(
          "startup_scrollback: off (applies on next launch)",
          TIMEOUT,
        );
        await session.waitForStableComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(stored.output_level).toEqual({ legacy: true });
        expect(stored.startup_scrollback).toBe(false);
        expect(stored.workspaces[workspaceRoot]).toEqual({
          output_level: ["quiet", 7],
          future_workspace: { keep: true },
        });
        expect(stored.workspaces[unrelatedWorkspace]).toEqual({
          model: 123,
          future_workspace: { preserve: true },
        });
        expect(readFileSync(join(workspace, ".fx.json"), "utf8")).toBe(projectBytes);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );


  serialTest(
    "Escape keeps the model picker dismissed until the model trigger restarts",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-model-picker-dismissal-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "xai/grok-build-1",
          type: "language",
          released: 1,
          tags: ["tool-use"],
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({ model: "openai/gpt-5" }) + "\n",
        );

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            HOME: home,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model");
        await session.sendKeys("Tab");
        await session.waitForText("xai/grok-build-1", TIMEOUT);

        await session.sendKeys("Escape");
        await session.waitForPane(
          (pane) =>
            composerContains(pane, "/model") &&
            !pane.includes("xai/grok-build-1"),
          TIMEOUT,
        );
        await session.sendLiteral("x");
        await session.waitForPane(
          (pane) =>
            composerContains(pane, "/model x") &&
            !pane.includes("xai/grok-build-1"),
          TIMEOUT,
        );

        await session.sendKeys("C-u");
        await session.sendLiteral("/model");
        await session.sendKeys("Tab");
        await session.waitForText("xai/grok-build-1", TIMEOUT);

        await session.sendKeys("C-u");
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "Fast indicator remains stable while model catalog resolves",
    async () => {
      const cases = [
        {
          label: "normal",
          model: "moonshotai/kimi-k3",
          fastMode: false,
          modelBound: true,
          supportsFastMode: true,
          expectedFastIndicator: false,
        },
        {
          label: "toggle",
          model: "moonshotai/kimi-k3",
          fastMode: true,
          modelBound: true,
          supportsFastMode: true,
          expectedFastIndicator: true,
        },
        {
          label: "intrinsic",
          model: "moonshotai/kimi-k3-fast",
          fastMode: false,
          modelBound: true,
          supportsFastMode: false,
          expectedFastIndicator: true,
        },
        {
          label: "legacy-unbound",
          model: "zai/glm-5.3",
          fastMode: true,
          modelBound: false,
          supportsFastMode: false,
          expectedFastIndicator: false,
        },
      ] as const;

      for (const testCase of cases) {
        const root = mkdtempSync(join(tmpdir(), `fx-startup-fast-${testCase.label}-`));
        let releaseCatalog: (() => void) | null = null;
        const catalogRelease = new Promise<void>((resolve) => {
          releaseCatalog = resolve;
        });
        const gateway = startFakeGateway([], {
          models: async () => {
            await catalogRelease;
            return [{
              id: testCase.model,
              type: "language",
              released: 1,
              tags: ["reasoning", "tool-use"],
              pricing: testCase.supportsFastMode
                ? { fast: { input: "0.1", output: "0.2" } }
                : undefined,
            }];
          },
        });
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          const stderrPath = join(root, "stderr.log");
          mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
          mkdirSync(workspace);
          writeFileSync(
            join(home, ".fx", "settings.json"),
            JSON.stringify({
              model: testCase.model,
              permission_mode: "auto",
              fast_mode: testCase.fastMode,
              fast_mode_model_bound: testCase.modelBound,
            }) + "\n",
            { mode: 0o600 },
          );

          session = await TmuxSession.create({
            cwd: realpathSync(workspace),
            env: {
              ...NO_AUTH,
              HOME: home,
              FX_AUTO_UPGRADE: "0",
              FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
            },
            stderrPath,
          });
          const modelLabel = testCase.model.split("/").at(-1)!;
          const before = await session.waitForText(`auto · ${modelLabel}`, TIMEOUT);
          expect(before.includes("⚡︎")).toBe(testCase.expectedFastIndicator);
          releaseCatalog?.();
          releaseCatalog = null;

          await session.sendText("/model");
          await session.waitForText(testCase.model, TIMEOUT);
          await session.sendKeys("Escape");
          const settled = await session.waitForStableComposer(TIMEOUT);
          expect(settled.includes("⚡︎")).toBe(testCase.expectedFastIndicator);

          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          session = null;
          expect(readFileSync(stderrPath, "utf8")).toBe("");
        } finally {
          releaseCatalog?.();
          gateway.stop();
          rmSync(root, { recursive: true, force: true });
        }
      }
    },
    60_000,
  );

  test(
    "Fast command rejects an intrinsic Fast alias",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fast-unsupported-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "anthropic/claude-opus-4.8-fast",
          type: "language",
          released: 1,
          tags: ["reasoning", "tool-use"],
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const settingsPath = join(home, ".fx", "settings.json");
        const initialSettings = JSON.stringify({
          model: "anthropic/claude-opus-4.8-fast",
          fast_mode: false,
        }) + "\n";
        writeFileSync(settingsPath, initialSettings, { mode: 0o600 });

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            AI_GATEWAY_API_KEY: "fake-standard-key",
            HOME: home,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/fast");
        const pane = await session.waitForText(
          "This model does not come with a fast mode.",
          TIMEOUT,
        );
        expect(pane).toContain("⚡︎");
        expect(gateway.requests).toHaveLength(0);
        expect(readFileSync(settingsPath, "utf8")).toBe(initialSettings);

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "settings reasoning effort changes without mutating the selected model",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-settings-effort-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "zai/glm-5.2",
          type: "language",
          released: 1,
          tags: ["reasoning", "tool-use"],
          reasoning_options: [{ type: "effort", values: ["low", "medium"] }],
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        const settingsPath = join(home, ".fx", "settings.json");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          settingsPath,
          JSON.stringify({ model: "zai/glm-5.2", effort: "low" }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: {
            ...NO_AUTH,
            HOME: home,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/settings");
        await session.waitForText("←→ Change", TIMEOUT);
        await session.sendLiteral("reason");
        const effortSetting = await session.waitForText("Reasoning effort", TIMEOUT);
        expect(effortSetting).toContain("low");
        await session.sendKeys("Right");

        let stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        const persistenceDeadline = Date.now() + TIMEOUT;
        while (stored.effort !== "medium" && Date.now() < persistenceDeadline) {
          await Bun.sleep(25);
          stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        }
        expect(stored).toMatchObject({
          model: "zai/glm-5.2",
          effort: "medium",
        });
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(await session.capturePane()).toContain("medium");

        await session.sendKeys("Escape");
        await session.waitForComposer(TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
        expect(gateway.requests).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "Opus 4.8 Fast pricing drives picker request and persistence",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-anthropic-capabilities-"));
      const gateway = startFakeGateway(
        [fakeGatewayFinalText("Opus fast complete")],
        {
          models: [
            {
              id: "openai/gpt-5",
              type: "language",
              released: 1,
              tags: ["tool-use"],
            },
            {
              id: "anthropic/claude-opus-4.8",
              type: "language",
              released: 1,
              tags: ["fast", "tool-use"],
              reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
              pricing: {
                fast: { input: "0.1", output: "0.2" },
              },
            },
          ],
        },
      );
      try {
        const home = join(root, "home");
        const opusWorkspace = join(root, "opus-workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(opusWorkspace);
        const opusRoot = realpathSync(opusWorkspace);
        const settingsPath = join(home, ".fx", "settings.json");
        const initialSettings = JSON.stringify({
          model: "anthropic/claude-opus-4.8",
          effort: "high",
          fast_mode: false,
          credential_source: "fx_login",
        }) + "\n";
        writeFileSync(
          settingsPath,
          initialSettings,
          { mode: 0o600 },
        );
        writeFileSync(
          join(home, ".fx", "auth.json"),
          JSON.stringify({
            version: 1,
            issuer: "https://vercel.com",
            client_id: "test-client",
            access_token: "fake-fx-login-token",
            refresh_token: "fake-fx-login-refresh-token",
            expires_at_ms: Date.now() + 60 * 60 * 1000,
            scope: "openid",
            token_type: "Bearer",
            team_id: "team_fast_test",
            team_slug: "fast-test-team",
          }) + "\n",
          { mode: 0o600 },
        );
        const gatewayEnv = {
          ...NO_AUTH,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_DISABLE_KEYCHAIN: "1",
          HOME: home,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        };

        session = await TmuxSession.create({
          cwd: opusRoot,
          env: gatewayEnv,
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model openai");
        await session.waitForText("openai/gpt-5", TIMEOUT);
        await session.sendKeys("C-u");
        await session.waitForPane(
          (pane) =>
            hasEmptyComposer(pane) &&
            !pane.includes("openai/gpt-5"),
          TIMEOUT,
        );
        await session.sendLiteral("/model");
        await session.sendKeys("Tab");
        await session.waitForText("anthropic/claude-opus-4.8", TIMEOUT);
        expect(readFileSync(settingsPath, "utf8")).toBe(initialSettings);
        await session.sendKeys("Enter");
        // Gateway order is preserved after fx's default sentinel.
        await session.waitForText("default", TIMEOUT);
        for (let i = 0; i < 2; i += 1) await session.sendKeys("Down");
        await session.waitForText("xhigh", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("normal", TIMEOUT);
        await session.sendLiteral("fast");
        await session.waitForText("/model anthropic/claude-opus-4.8 xhigh fast", TIMEOUT);
        await session.sendKeys("Enter");
        const selectedFastStatus = await session.waitForText("opus 4.8 · xhigh · ⚡︎", TIMEOUT);
        expect(selectedFastStatus).not.toContain("⚡︎ fast");
        await session.sendText("Use fast.");
        await session.waitForText("Opus fast complete", TIMEOUT);
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
          "anthropic/claude-opus-4.8",
        );
        expect(gateway.requests[0]!.headers.get("authorization")).toBe(
          "Bearer fake-fx-login-token",
        );
        expect(gateway.requests[0]!.headers.get("x-vercel-ai-gateway-team")).toBe(
          "team_fast_test",
        );
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty("fast");
        expect(JSON.parse(gateway.requests[0]!.body)).toMatchObject({
          providerOptions: { gateway: { speed: "fast" } },
        });
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(stored).toMatchObject({
          models: { gateway: "anthropic/claude-opus-4.8" },
          effort: "xhigh",
          fast_mode: true,
        });

        session = await TmuxSession.create({
          cwd: opusRoot,
          env: gatewayEnv,
          stderrPath,
        });
        const restoredFastStatus = await session.waitForText("opus 4.8 · xhigh · ⚡︎", TIMEOUT);
        expect(restoredFastStatus).not.toContain("⚡︎ fast");
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "GPT 5.6 Sol priority pricing drives the Fast request",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-openai-capabilities-"));
      const gateway = startFakeGateway(
        [
          fakeGatewayFinalText("GPT 5.6 stale effort filtered"),
          fakeGatewayFinalText("GPT 5.6 max fast complete"),
        ],
        {
          models: [{
            id: "openai/gpt-5.6-sol",
            type: "language",
            owned_by: "openai",
            released: 1,
            tags: ["reasoning", "tool-use"],
            reasoning_options: [{
              type: "effort",
              values: ["future-tier", "max"],
            }],
            context_window: 1_050_000,
            max_tokens: 128_000,
            pricing: {
              service_tiers: {
                priority: { input: "0.1", output: "0.2" },
              },
            },
          }],
        },
      );
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            model: "openai/gpt-5.6-sol",
            effort: "minimal",
            fast_mode: true,
          }) + "\n",
          { mode: 0o600 },
        );
        const gatewayEnv = {
          ...NO_AUTH,
          AI_GATEWAY_API_KEY: "fake-capability-key",
          HOME: home,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        };

        const staleResult = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Use stale minimal fast."],
          {
            cwd: workspaceRoot,
            env: gatewayEnv,
            timeoutMs: TIMEOUT,
          },
        );
        expect(staleResult.code).toBe(0);
        expect(gateway.requests).toHaveLength(1);
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty(
          "reasoning",
        );
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty("fast");
        expect(JSON.parse(gateway.requests[0]!.body)).toMatchObject({
          providerOptions: { gateway: { speed: "fast" } },
        });
        expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toMatchObject({
          model: "openai/gpt-5.6-sol",
          effort: "minimal",
          fast_mode: true,
        });

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: gatewayEnv,
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model sol");
        await session.waitForText("openai/gpt-5.6-sol", TIMEOUT);
        await session.sendKeys("Enter");
        const efforts = await session.waitForText("default", TIMEOUT);
        expect(efforts).not.toContain("minimal");
        for (let i = 0; i < 2; i += 1) await session.sendKeys("Down");
        await session.waitForText("max", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("normal", TIMEOUT);
        await session.sendLiteral("fast");
        await session.waitForText("/model openai/gpt-5.6-sol max fast", TIMEOUT);
        await session.sendKeys("Enter");
        const selected = await session.waitForText("gpt-5.6-sol · max · ⚡︎", TIMEOUT);
        expect(selected).not.toContain("⚡︎ fast");
        await session.waitForComposer(TIMEOUT);

        const stored = JSON.parse(
          readFileSync(settingsPath, "utf8"),
        );
        expect(stored).toMatchObject({
          models: { gateway: "openai/gpt-5.6-sol" },
          effort: "max",
          fast_mode: true,
        });

        await session.sendText("Use max fast.");
        await session.waitForText("GPT 5.6 max fast complete", TIMEOUT);
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1]!.headers.get("ai-language-model-id")).toBe(
          "openai/gpt-5.6-sol",
        );
        expect(gateway.requests[1]!.headers.get("authorization")).toBe(
          "Bearer fake-capability-key",
        );
        expect(JSON.parse(gateway.requests[1]!.body)).toMatchObject({
          reasoning: "max",
          providerOptions: { gateway: { speed: "fast" } },
        });
        expect(JSON.parse(gateway.requests[1]!.body)).not.toHaveProperty("fast");

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "Fable 5 xhigh picker selection persists without fast mode",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-fable-capabilities-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "anthropic/claude-fable-5",
          type: "language",
          released: 1,
            tags: ["reasoning", "tool-use"],
            reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
            context_window: 1_000_000,
          max_tokens: 128_000,
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendLiteral("/model fable");
        await session.waitForText("anthropic/claude-fable-5", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("default", TIMEOUT);
        for (let i = 0; i < 2; i += 1) await session.sendKeys("Down");
        await session.waitForText("xhigh", TIMEOUT);
        await session.sendKeys("Enter");
        const selected = await session.waitForText("fable-5 · xhigh", TIMEOUT);
        expect(selected).not.toContain("⚡︎");
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored).toMatchObject({
          models: { gateway: "anthropic/claude-fable-5" },
          effort: "xhigh",
        });
        expect(stored.fast_mode).toBe(false);
        expect(stored.fast_mode_model_bound).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "model picker selection persists when a matching skill exists",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-model-picker-skill-"));
      const gateway = startFakeGateway([], {
        models: [{
          id: "xai/grok-build-1",
          type: "language",
          released: 1,
          tags: ["tool-use"],
        }],
      });
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        const skillRoot = join(home, ".fx", "skills", "model-helper");
        mkdirSync(skillRoot, { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(
          join(skillRoot, "SKILL.md"),
          "---\nname: model-helper\ndescription: model helper skill\n---\n\nModel helper body\n",
        );
        const workspaceRoot = realpathSync(workspace);

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForComposer(TIMEOUT);
        await session.sendLiteral("/model");
        await session.sendKeys("Tab");
        const pickerPane = await session.waitForText("xai/grok-build-1", TIMEOUT);
        expect(pickerPane).toContain("xai/grok-build-1");
        await session.sendKeys("Enter");
        await session.waitForText("● Switched to xai/grok-build-1", TIMEOUT);
        await session.waitForPane(
          (pane) =>
            hasEmptyComposer(pane) &&
            !pane.includes("model-helper"),
          TIMEOUT,
        );
        expect(await session.capturePane()).not.toContain("saved to user settings");

        const stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored.models.gateway).toBe("xai/grok-build-1");
        expect(stored).not.toHaveProperty("effort");
        expect(stored.fast_mode).toBe(false);
        expect(stored.fast_mode_model_bound).toBe(true);

        const scrollback = await session.captureFullScrollbackEscapes();
        expect(scrollback).toContain("grok-build-1");
        expect(scrollback).toContain("● Switched to xai/grok-build-1");
        expect(gateway.requests).toHaveLength(0);

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  test(
    "Gateway catalog reasoning drives portable effort requests and persistence",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-gateway-capabilities-"));
      const gateway = startFakeGateway(
        [
          fakeGatewayFinalText("portable auto complete"),
          fakeGatewayFinalText("portable future complete"),
        ],
        {
          models: [{
            id: "provider/new-reasoning-model",
            type: "language",
            released: 99,
            tags: ["reasoning", "tool-use"],
            reasoning_options: [{
              type: "effort",
              values: ["future-tier", "high"],
            }],
            context_window: 750_000,
            max_tokens: 32_000,
          }],
        },
      );
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            AI_GATEWAY_API_KEY: "fake-capability-key",
            VERCEL_OIDC_TOKEN: undefined,
            HOME: home,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/statusline context");
        await session.waitForText("● Statusline: context: on", TIMEOUT);
        await session.sendLiteral("/model new-reasoning");
        await session.waitForText("provider/new-reasoning-model", TIMEOUT);
        await session.sendKeys("Enter");
        const autoEffortPicker = await session.waitForText("default", TIMEOUT);
        expect(autoEffortPicker).toContain("future-tier");
        expect(autoEffortPicker).toContain("high");
        await session.sendKeys("Enter");
        await session.waitForText("● Switched to provider/new-reasoning-model", TIMEOUT);

        let stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored.models.gateway).toBe("provider/new-reasoning-model");
        expect(stored.fast_mode).toBe(false);
        expect(stored.fast_mode_model_bound).toBe(true);

        await session.sendText("Use portable auto.");
        await session.waitForText("portable auto complete", TIMEOUT);
        const footer = await session.waitForText("Context: 0k/750k 0%", TIMEOUT);
        expect(footer).toContain("new-reasoning-model");
        expect(gateway.requests).toHaveLength(1);
        expect(gateway.requests[0]!.headers.get("ai-language-model-id")).toBe(
          "provider/new-reasoning-model",
        );
        expect(
          gateway.requests[0]!.headers.get(
            "ai-language-model-specification-version",
          ),
        ).toBe("4");
        expect(JSON.parse(gateway.requests[0]!.body)).not.toHaveProperty("reasoning");

        await session.sendLiteral("/model new-reasoning");
        await session.waitForText("provider/new-reasoning-model", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("default", TIMEOUT);
        await session.sendKeys("Down");
        await session.waitForText("future-tier", TIMEOUT);
        await session.sendKeys("Enter");
        await session.waitForText("· future-tier", TIMEOUT);

        stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        const persistenceDeadline = Date.now() + TIMEOUT;
        while (stored.effort !== "future-tier" && Date.now() < persistenceDeadline) {
          await Bun.sleep(25);
          stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        }
        expect(stored).toMatchObject({
          models: { gateway: "provider/new-reasoning-model" },
          effort: "future-tier",
        });

        await session.sendText("Use portable future.");
        await session.waitForText("portable future complete", TIMEOUT);
        expect(gateway.requests).toHaveLength(2);
        expect(
          gateway.requests[1]!.headers.get(
            "ai-language-model-specification-version",
          ),
        ).toBe("4");
        expect(JSON.parse(gateway.requests[1]!.body)).toMatchObject({
          reasoning: "future-tier",
        });
        expect(JSON.parse(gateway.requests[1]!.body).providerOptions).toEqual({
          gateway: { caching: "auto" },
        });

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        stored = JSON.parse(readFileSync(join(home, ".fx", "settings.json"), "utf8"));
        expect(stored).toMatchObject({
          models: { gateway: "provider/new-reasoning-model" },
          effort: "future-tier",
        });
        expect(stored.fast_mode).toBe(false);
        expect(stored.fast_mode_model_bound).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "settings persistence remains available when session storage is unavailable",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-first-write-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        writeFileSync(join(home, ".fx", "sessions"), "blocked\n", {
          mode: 0o600,
        });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText("/settings startup-scrollback off");
        await session.waitForText("startup_scrollback: off", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(tree(home)).toEqual([
          ".fx",
          ".fx/history.jsonl",
          ".fx/history.lock",
          ".fx/sessions",
          ".fx/settings.json",
          ".fx/settings.lock",
        ]);
        expect(statSync(join(home, ".fx")).mode & 0o777).toBe(0o700);
        expect(statSync(join(home, ".fx", "history.jsonl")).mode & 0o777).toBe(0o600);
        expect(statSync(join(home, ".fx", "history.lock")).mode & 0o777).toBe(0o600);
        expect(statSync(join(home, ".fx", "settings.json")).mode & 0o777).toBe(0o600);
        expect(statSync(join(home, ".fx", "settings.lock")).mode & 0o777).toBe(0o600);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  serialTest(
    "workspace statusline stays active when user settings cannot be saved",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-statusline-write-failure-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace-write-failure-visible");
        const settingsPath = join(home, ".fx", "settings.json");
        const externalSettings = join(root, "external-settings.json");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        writeFileSync(settingsPath, '{"statusLine":{"workspace":false}}\n', { mode: 0o600 });
        writeFileSync(externalSettings, '{"statusLine":{"workspace":false}}\n', { mode: 0o600 });

        session = await TmuxSession.create({
          cwd: realpathSync(workspace),
          env: { ...NO_AUTH, HOME: home },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        expect(await session.capturePane()).not.toContain("workspace-write-failure-visible");

        rmSync(settingsPath);
        symlinkSync(externalSettings, settingsPath);
        await session.sendText("/statusline workspace");
        await session.waitForText("active for this process but not saved to user settings", TIMEOUT);
        await session.waitForPane(
          (pane) => pane.includes("workspace-write-failure-visible"),
          TIMEOUT,
        );
        expect(JSON.parse(readFileSync(externalSettings, "utf8")).statusLine.workspace).toBe(false);

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  serialTest("config diagnostics preserve invalid, oversized, and unsafe primaries", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-config-diagnostics-"));
    try {
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
      mkdirSync(workspace);
      const workspaceRoot = realpathSync(workspace);
      const settingsPath = join(home, ".fx", "settings.json");

      const malformed = "{bad\n";
      writeFileSync(settingsPath, malformed, { mode: 0o600 });
      const malformedStatus = await runFx(["status", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(malformedStatus.code).toBe(0);
      expect(malformedStatus.stderr).toContain("malformed_settings");
      expect(readFileSync(settingsPath, "utf8")).toBe(malformed);

      const malformedStatusLine = "{\"statusLine\":{\"context\":1}}\n";
      writeFileSync(settingsPath, malformedStatusLine, { mode: 0o600 });
      const malformedStatusLineStatus = await runFx(["status", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(malformedStatusLineStatus.code).toBe(0);
      expect(malformedStatusLineStatus.stderr).toContain("malformed_settings");
      expect(readFileSync(settingsPath, "utf8")).toBe(malformedStatusLine);

      const inertOutputSettings =
        JSON.stringify({
          output_level: { legacy: true },
          workspaces: {
            [workspaceRoot]: {
              output_level: ["quiet", 7],
            },
          },
        }) + "\n";
      writeFileSync(settingsPath, inertOutputSettings, { mode: 0o600 });
      const inertStatus = await runFx(["status", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(inertStatus.code).toBe(0);
      expect(inertStatus.stderr).not.toContain("legacy_workspace_preferences");
      const inertDoctor = await runFx(["doctor", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(inertDoctor.code).toBe(0);
      expect(inertDoctor.stdout).not.toContain("legacy_workspace_preferences");

      session = await TmuxSession.create({
        cwd: workspaceRoot,
        env: { ...NO_AUTH, HOME: home },
      });
      await session.waitForText("Run /help", TIMEOUT);
      expect(await session.capturePane()).not.toContain(
        "legacy_workspace_preferences",
      );
      await session.kill();
      session = null;

      expect(readFileSync(settingsPath, "utf8")).toBe(inertOutputSettings);

      const oversized = JSON.stringify({ padding: "x".repeat(65 * 1024) }) + "\n";
      writeFileSync(settingsPath, oversized, { mode: 0o600 });
      const oversizedDoctor = await runFx(["doctor", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(oversizedDoctor.code).toBe(0);
      expect(oversizedDoctor.stdout).toContain("settings_too_large");
      expect(readFileSync(settingsPath, "utf8")).toBe(oversized);

      const external = join(root, "external-settings.json");
      writeFileSync(external, "{\"model\":\"external\"}\n", { mode: 0o600 });
      rmSync(settingsPath);
      symlinkSync(external, settingsPath);
      const unsafeStatus = await runFx(["status", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(unsafeStatus.code).toBe(0);
      expect(unsafeStatus.stderr).toContain("durable_path_unsafe");
      expect(readFileSync(external, "utf8")).toBe("{\"model\":\"external\"}\n");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  serialTest(
    "concurrent global mutations preserve both values and unknown keys",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-config-concurrent-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            future_global: { nested: "keep-global" },
            workspaces: {
              [workspaceRoot]: {
                future_workspace: {
                  nested: { keep: true },
                },
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        writeFileSync(join(home, ".fx", "sessions"), "blocked\n", {
          mode: 0o600,
        });
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        [session, secondSession] = await Promise.all([
          TmuxSession.create({ cwd: workspaceRoot, env }),
          TmuxSession.create({ cwd: workspaceRoot, env }),
        ]);
        await Promise.all([
          session.waitForText("Run /help", TIMEOUT),
          secondSession.waitForText("Run /help", TIMEOUT),
        ]);
        await Promise.all([
          session.sendText("/settings startup-scrollback off"),
          secondSession.sendText("/statusline context"),
        ]);
        await Promise.all([
          session.waitForText("startup_scrollback: off", TIMEOUT),
          secondSession.waitForText("● Statusline: context:", TIMEOUT),
        ]);
        await Promise.all([
          session.sendText("/quit"),
          secondSession.sendText("/quit"),
        ]);
        await Promise.all([
          session.waitForSessionEnd(TIMEOUT),
          secondSession.waitForSessionEnd(TIMEOUT),
        ]);
        session = null;
        secondSession = null;

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(stored.future_global).toEqual({ nested: "keep-global" });
        expect(stored.startup_scrollback).toBe(false);
        expect(stored.statusLine).toMatchObject({ context: true });
        expect(stored.workspaces[workspaceRoot]).toMatchObject({
          future_workspace: {
            nested: { keep: true },
          },
        });
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "stale workspace mutations preserve an ordered remove and add",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-concurrent-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const added = join(root, "added");
        const launch = join(root, "launch");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(added);
        mkdirSync(launch);
        const workspaceRoot = realpathSync(workspace);
        const addedRoot = realpathSync(added);
        const launchRoot = realpathSync(launch);
        const savedRoots = Array.from({ length: 15 }, (_, index) => {
          const path = join(root, `saved-${index}`);
          mkdirSync(path);
          return realpathSync(path);
        });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: savedRoots,
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        writeFileSync(join(home, ".fx", "sessions"), "blocked\n", {
          mode: 0o600,
        });
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        [session, secondSession] = await Promise.all([
          TmuxSession.create({
            cwd: workspaceRoot,
            env,
            stderrPath: stderrAPath,
          }),
          TmuxSession.create({
            cmd: `${FX_BIN} --add-dir ${launchRoot}`,
            cwd: workspaceRoot,
            env,
            stderrPath: stderrBPath,
          }),
        ]);
        await Promise.all([
          session.waitForText("Run /help", TIMEOUT),
          secondSession.waitForText("Run /help", TIMEOUT),
        ]);

        await session.sendText(`/workspace remove ${savedRoots[0]}`);
        await session.waitForText("remove ", TIMEOUT);
        await session.waitForText("saved-14 saved=true", TIMEOUT);
        await secondSession.sendText(`/workspace add ${addedRoot}`);
        await secondSession.waitForText("add ", TIMEOUT);
        await secondSession.waitForText("launch saved=false", TIMEOUT);

        await Promise.all([
          session.sendText("/quit"),
          secondSession.sendText("/quit"),
        ]);
        await Promise.all([
          session.waitForSessionEnd(TIMEOUT),
          secondSession.waitForSessionEnd(TIMEOUT),
        ]);
        session = null;
        secondSession = null;

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(
          stored.workspaces[workspaceRoot].additional_directories,
        ).toEqual([...savedRoots.slice(1), addedRoot]);
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace add rejects effective capacity without changing settings",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-capacity-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const added = join(root, "added");
        const launch = join(root, "launch");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(added);
        mkdirSync(launch);
        const workspaceRoot = realpathSync(workspace);
        const addedRoot = realpathSync(added);
        const launchRoot = realpathSync(launch);
        const savedRoots = Array.from({ length: 15 }, (_, index) => {
          const path = join(root, `saved-${index}`);
          mkdirSync(path);
          return realpathSync(path);
        });
        const settingsPath = join(home, ".fx", "settings.json");
        const originalSettings =
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: savedRoots,
              },
            },
          }) + "\n";
        writeFileSync(settingsPath, originalSettings, { mode: 0o600 });
        writeFileSync(join(home, ".fx", "sessions"), "blocked\n", {
          mode: 0o600,
        });

        session = await TmuxSession.create({
          cmd: `${FX_BIN} --add-dir ${launchRoot}`,
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText(`/workspace add ${addedRoot}`);
        await session.waitForText(
          "Workspace settings were not changed: additional directory limit reached",
          TIMEOUT,
        );
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(settingsPath, "utf8")).toBe(originalSettings);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "workspace removal persists after an observed source disappears",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-source-disappears-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared");
        const savedLink = join(root, "saved-link");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(shared);
        symlinkSync(shared, savedLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: { additional_directories: [savedLink] },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        rmSync(savedLink);
        await session.sendText(`/workspace remove ${savedLink}`);
        await session.waitForText("additional directories: (none)", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(
          stored.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "workspace removal persists after an observed source retargets",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-source-moves-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const first = join(root, "first");
        const second = join(root, "second");
        const savedLink = join(root, "saved-link");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(first);
        mkdirSync(second);
        symlinkSync(first, savedLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const firstRoot = realpathSync(first);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: { additional_directories: [savedLink] },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        rmSync(savedLink);
        symlinkSync(second, savedLink, "dir");
        await session.sendText(`/workspace remove ${firstRoot}`);
        await session.waitForText("additional directories: (none)", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(
          stored.workspaces?.[workspaceRoot]?.additional_directories,
        ).toBeUndefined();
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "workspace removal consumes a concurrent exact canonical replacement",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-target-replaced-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const target = join(root, "target");
        const unseenBefore = join(root, "unseen-before");
        const unseenAfter = join(root, "unseen-after");
        const targetLink = join(root, "target-link");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(target);
        mkdirSync(unseenBefore);
        mkdirSync(unseenAfter);
        symlinkSync(target, targetLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const targetRoot = realpathSync(target);
        const unseenBeforeRoot = realpathSync(unseenBefore);
        const unseenAfterRoot = realpathSync(unseenAfter);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: { additional_directories: [targetLink] },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [
                  unseenBeforeRoot,
                  targetRoot,
                  unseenAfterRoot,
                ],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        await session.sendText(`/workspace remove ${targetRoot}`);
        await session.waitForText("runtime_changed=true", TIMEOUT);
        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          unseenBeforeRoot,
          unseenAfterRoot,
        ]);

        await session.sendText("/clear");
        await session.waitForPane(
          (pane) => hasEmptyComposer(pane) && !pane.includes(targetRoot),
          TIMEOUT,
        );
        await session.sendText("/workspace list");
        await session.waitForText(unseenBeforeRoot, TIMEOUT);
        await session.waitForText(unseenAfterRoot, TIMEOUT);
        const pane = await session.capturePaneGrid();
        expect(pane).not.toContain(targetRoot);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "workspace removal prefers a concurrent canonical survivor before restart",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-survivor-moves-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const removed = join(root, "removed");
        const survivor = join(root, "survivor");
        const retarget = join(root, "retarget");
        const unseenBefore = join(root, "unseen-before");
        const unseenAfter = join(root, "unseen-after");
        const removedLink = join(root, "removed-link");
        const survivorLinkA = join(root, "survivor-link-a");
        const survivorLinkB = join(root, "survivor-link-b");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(removed);
        mkdirSync(survivor);
        mkdirSync(retarget);
        mkdirSync(unseenBefore);
        mkdirSync(unseenAfter);
        symlinkSync(removed, removedLink, "dir");
        symlinkSync(survivor, survivorLinkA, "dir");
        symlinkSync(survivor, survivorLinkB, "dir");
        const workspaceRoot = realpathSync(workspace);
        const removedRoot = realpathSync(removed);
        const survivorRoot = realpathSync(survivor);
        const retargetRoot = realpathSync(retarget);
        const unseenBeforeRoot = realpathSync(unseenBefore);
        const unseenAfterRoot = realpathSync(unseenAfter);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [removedLink, survivorLinkA, survivorLinkB],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [
                  unseenBeforeRoot,
                  removedLink,
                  survivorLinkA,
                  survivorRoot,
                  survivorLinkB,
                  unseenAfterRoot,
                ],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        rmSync(survivorLinkA);
        rmSync(survivorLinkB);
        symlinkSync(retarget, survivorLinkA, "dir");
        symlinkSync(retarget, survivorLinkB, "dir");
        await session.sendText(`/workspace remove ${removedRoot}`);
        await session.waitForText("runtime_changed=true", TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          unseenBeforeRoot,
          survivorRoot,
          unseenAfterRoot,
        ]);
        rmSync(survivorLinkA);
        rmSync(survivorLinkB);

        secondSession = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrBPath,
        });
        await secondSession.waitForText("Run /help", TIMEOUT);
        await secondSession.sendText("/workspace list");
        await secondSession.waitForText(unseenBeforeRoot, TIMEOUT);
        await secondSession.waitForText(survivorRoot, TIMEOUT);
        await secondSession.waitForText(unseenAfterRoot, TIMEOUT);
        const pane = await secondSession.capturePaneGrid();
        expect(pane).not.toContain(retargetRoot);
        await secondSession.sendText("/quit");
        await secondSession.waitForSessionEnd(TIMEOUT);
        secondSession = null;

        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace removal uses observed identity and preserves an unseen source",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-source-retarget-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const first = join(root, "first");
        const second = join(root, "second");
        const savedLink = join(root, "saved-link");
        const unseenLink = join(root, "unseen-link");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(first);
        mkdirSync(second);
        symlinkSync(first, savedLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const firstRoot = realpathSync(first);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: { additional_directories: [savedLink] },
            },
          }) + "\n",
          { mode: 0o600 },
        );

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env: {
            ...NO_AUTH,
            HOME: home,
          },
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);

        symlinkSync(first, unseenLink, "dir");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [savedLink, unseenLink],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        rmSync(savedLink);
        symlinkSync(second, savedLink, "dir");

        await session.sendText(`/workspace remove ${savedLink}`);
        await session.waitForText(firstRoot, TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          unseenLink,
        ]);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );

  serialTest(
    "workspace add canonicalizes observed aliases before restart",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-source-restart-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const first = join(root, "first");
        const second = join(root, "second");
        const added = join(root, "added");
        const savedLink = join(root, "saved-link");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(first);
        mkdirSync(second);
        mkdirSync(added);
        symlinkSync(first, savedLink, "dir");
        const workspaceRoot = realpathSync(workspace);
        const firstRoot = realpathSync(first);
        const secondRoot = realpathSync(second);
        const addedRoot = realpathSync(added);
        const settingsPath = join(home, ".fx", "settings.json");
        writeFileSync(
          settingsPath,
          JSON.stringify({
            workspaces: {
              [workspaceRoot]: {
                additional_directories: [savedLink, firstRoot],
              },
            },
          }) + "\n",
          { mode: 0o600 },
        );
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        rmSync(savedLink);
        symlinkSync(second, savedLink, "dir");
        await session.sendText(`/workspace add ${addedRoot}`);
        await session.waitForText(addedRoot, TIMEOUT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          firstRoot,
          addedRoot,
        ]);
        rmSync(savedLink);

        secondSession = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrBPath,
        });
        await secondSession.waitForText("Run /help", TIMEOUT);
        await secondSession.sendText("/workspace list");
        await secondSession.waitForText(firstRoot, TIMEOUT);
        await secondSession.waitForText(addedRoot, TIMEOUT);
        const pane = await secondSession.capturePaneGrid();
        expect(pane).not.toContain(secondRoot);
        await secondSession.sendText("/quit");
        await secondSession.waitForSessionEnd(TIMEOUT);
        secondSession = null;

        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace slash mutations persist across restart and remove cleanly",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-slash-persistence-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared project");
        const stderrAPath = join(root, "stderr-a.log");
        const stderrBPath = join(root, "stderr-b.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(shared);
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrAPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText(`/workspace add ${sharedRoot}`);
        await session.waitForPane(
          (pane) =>
            pane.replace(/\s+/g, "").includes(
              "saved_changed=trueruntime_changed=true",
            ),
          TIMEOUT,
        );
        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const stored = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(stored.workspaces[workspaceRoot].additional_directories).toEqual([
          sharedRoot,
        ]);

        secondSession = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath: stderrBPath,
        });
        await secondSession.waitForText("Run /help", TIMEOUT);
        await secondSession.sendText("/workspace list");
        await secondSession.waitForText(sharedRoot, TIMEOUT);
        await secondSession.waitForPane(
          (pane) => pane.replaceAll("\n", "").includes("active=true"),
          TIMEOUT,
        );
        await secondSession.sendText(`/workspace remove ${sharedRoot}`);
        await secondSession.waitForText("additional directories: (none)", TIMEOUT);
        await secondSession.sendText("/quit");
        await secondSession.waitForSessionEnd(TIMEOUT);
        secondSession = null;

        const cleared = JSON.parse(
          readFileSync(join(home, ".fx", "settings.json"), "utf8"),
        );
        expect(cleared.workspaces?.[workspaceRoot]?.additional_directories).toBeUndefined();
        expect(readFileSync(stderrAPath, "utf8")).toBe("");
        expect(readFileSync(stderrBPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace list marks a directory deleted during the session unavailable",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-live-availability-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(shared);
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        session = await TmuxSession.create({
          cwd: workspaceRoot,
          env,
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText(`/workspace add ${sharedRoot}`);
        await session.waitForPane(
          (pane) =>
            pane.replace(/\s+/g, "").includes(
              `${sharedRoot}saved=truecommand_line=falseavailable=trueactive=true`,
            ),
          TIMEOUT,
        );

        rmSync(sharedRoot, { recursive: true });
        await session.sendText("/workspace list");
        await session.waitForPane(
          (pane) =>
            pane.replace(/\s+/g, "").includes(
              `${sharedRoot}saved=truecommand_line=falseavailable=falseactive=false`,
            ),
          TIMEOUT,
        );
        const scrollback = await session.captureFullScrollback();
        expect(scrollback.replace(/\s+/g, "")).toContain(
          `${sharedRoot}saved=truecommand_line=falseavailable=falseactive=false`,
        );

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace list restores canonical access through a new symlinked ancestor",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-restored-canonical-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const realParent = join(root, "real-parent");
        const shared = join(realParent, "shared");
        const parentLink = join(root, "parent-link");
        const source = join(parentLink, "shared");
        const stderrPath = join(root, "stderr.log");
        const fixture = "RESTORED_CANONICAL_ROOT_FIXTURE";
        const instructionSentinel = "RESTORED_ROOT_AGENTS_MUST_NOT_LOAD";
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(shared, { recursive: true });
        writeFileSync(join(shared, "fixture.txt"), `${fixture}\n`);
        writeFileSync(join(shared, "AGENTS.md"), `${instructionSentinel}\n`);
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({
            sandbox: "none",
            permission_mode: "auto",
            permission: {},
            workspaces: {
              [workspaceRoot]: { additional_directories: [source] },
            },
          }),
        );

        const gateway = startFakeGateway([
          fakeGatewayToolCall("restored-root-read", "read_file", {
            path: join(source, "fixture.txt"),
            line_count: 10,
          }),
          fakeGatewayFinalText("RESTORED_CANONICAL_ROOT_COMPLETE"),
        ]);
        try {
          session = await TmuxSession.create({
            cwd: workspaceRoot,
            env: {
              HOME: home,
              AI_GATEWAY_API_KEY: "fake-restored-root-key",
              VERCEL_OIDC_TOKEN: undefined,
              FX_AUTO_UPGRADE: "0",
              FX_GATEWAY_BASE_URL: gateway.baseUrl,
              FX_GATEWAY_CHAT_URL: gateway.chatUrl,
              FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
              FX_MODEL: FAKE_GATEWAY_MODEL,
            },
            stderrPath,
          });
          await session.waitForText("Run /help", TIMEOUT);

          symlinkSync(realParent, parentLink, "dir");
          await session.sendText("/workspace list");
          await session.waitForPane(
            (pane) =>
              pane.replace(/\s+/g, "").includes(
                `${sharedRoot}saved=truecommand_line=falseavailable=trueactive=true`,
              ),
            TIMEOUT,
          );

          await session.sendText("Read the restored workspace fixture once.");
          await session.waitForText("RESTORED_CANONICAL_ROOT_COMPLETE", TIMEOUT);
          expect(gateway.requests).toHaveLength(2);
          for (const request of gateway.requests) {
            expect(request.body).not.toContain(instructionSentinel);
            expect(request.body).not.toContain("target outside workspace");
            expect(request.body).not.toContain("Not executed");
          }
          expect(gateway.requests[1]!.body).toContain(fixture);
          expect(readFileSync(stderrPath, "utf8")).toBe("");
          expect(session.isAlive()).toBe(true);
          expect(session.isPaneAlive()).toBe(true);

          await session.sendText("/quit");
          await session.waitForSessionEnd(TIMEOUT);
          session = null;
        } finally {
          gateway.stop();
        }
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  serialTest(
    "workspace slash removal explains launch restoration and uses friendly errors",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-workspace-launch-removal-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const shared = join(root, "shared");
        const unknown = join(root, "unknown");
        const stderrPath = join(root, "stderr.log");
        mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
        mkdirSync(workspace);
        mkdirSync(shared);
        mkdirSync(unknown);
        const workspaceRoot = realpathSync(workspace);
        const sharedRoot = realpathSync(shared);
        const unknownRoot = realpathSync(unknown);
        const env = {
          ...NO_AUTH,
          HOME: home,
        };

        session = await TmuxSession.create({
          cmd: `${FX_BIN} --add-dir ${sharedRoot}`,
          cwd: workspaceRoot,
          env,
          stderrPath,
        });
        await session.waitForText("Run /help", TIMEOUT);
        await session.sendText(`/workspace remove ${unknownRoot}`);
        await session.waitForText(
          "Workspace update rejected: directory is not configured as an additional workspace",
          TIMEOUT,
        );
        await session.sendText(`/workspace remove ${workspaceRoot}`);
        await session.waitForText(
          "the primary workspace cannot be added or removed",
          TIMEOUT,
        );
        let pane = await session.capturePaneGrid();
        expect(pane).not.toContain("PrimaryDirectory");

        await session.sendText(`/workspace remove ${sharedRoot}`);
        await session.waitForPane(
          (pane) =>
            pane.replaceAll("\n", "").includes("launch_flag_can_restore=true"),
          TIMEOUT,
        );
        await session.waitForText(
          "warning: repeating --add-dir can restore removed access on the next launch",
          TIMEOUT,
        );
        await session.waitForText("additional directories: (none)", TIMEOUT);
        pane = await session.capturePaneGrid();
        expect(pane).not.toContain("PrimaryDirectory");

        await session.sendText("/quit");
        await session.waitForSessionEnd(TIMEOUT);
        session = null;

        const settingsPath = join(home, ".fx", "settings.json");
        if (statSync(settingsPath, { throwIfNoEntry: false })) {
          const stored = JSON.parse(readFileSync(settingsPath, "utf8"));
          expect(
            stored.workspaces?.[workspaceRoot]?.additional_directories,
          ).toBeUndefined();
        }
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    45_000,
  );
});
