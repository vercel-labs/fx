import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { expectPermissionModeContext } from "./permission-mode-context";

const WARNING = "Full access enabled: fx permission checks disabled";
const COMPACT_WARNING = "Full access";
const QUIT_HINT = "press ctrl+c again to exit";
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";
const TIMEOUT = 30_000;
const CONFIGURED_SANDBOX = process.platform === "darwin" ? "os" : "none";

let session: TmuxSession | null = null;
let gateway: { stop(): void } | null = null;
const tempRoots: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  for (const root of tempRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createFixture(prefix: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  tempRoots.push(root);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    settingsPath: join(home, ".fx", "settings.json"),
  };
}

async function waitForGatewayRequestCount(
  fake: { requestCount(): number },
  expected: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (fake.requestCount() >= expected) return;
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for ${expected} Gateway request(s); received ${fake.requestCount()}`,
  );
}

describe("yolo permission mode", () => {
  test.each(["--full-access", "--yolo"])(
    "%s warns once, bypasses configured denial, and keeps stdout clean",
    async (flag) => {
      const fixture = createFixture("fx-yolo-headless-");
      const markerPath = join(fixture.workspace, "yolo-command.txt");
      const tracePath = join(fixture.root, "permission-trace.log");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "ask",
          sandbox: CONFIGURED_SANDBOX,
          permission: { bash: "deny" },
          future_setting: { preserved: true },
        }) + "\n",
      );

      const fake = startFakeGateway([
        fakeShellRun(
          "yolo_command",
          `printf 'YOLO_COMMAND_OK\\n' > ${JSON.stringify(markerPath)}`,
          { timeout_ms: 600_000 },
        ),
        fakeGatewayFinalText("YOLO_HEADLESS_DONE"),
      ]);
      gateway = fake;

      const result = await runFx(
        ["ask", flag, "--json", "--no-save", "Run the fixture command exactly once."],
        {
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fake-yolo-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: fake.baseUrl,
            FX_GATEWAY_CHAT_URL: fake.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_TRACE_LOG: tracePath,
            FX_TRACE_SCOPES: "permission",
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr.startsWith(`${WARNING}\n`)).toBe(true);
      expect(result.stderr.match(new RegExp(WARNING, "g"))).toHaveLength(1);
      expect(result.stdout).not.toContain(WARNING);
      const output = JSON.parse(result.stdout.trim()) as {
        output: string;
        tool_calls: Array<{ name: string; status: string }>;
      };
      expect(output.output).toContain("YOLO_HEADLESS_DONE");
      expect(
        output.tool_calls.some(
          (call) => call.name === "shell" && call.status === "success",
        ),
      ).toBe(true);
      expect(readFileSync(markerPath, "utf8")).toBe("YOLO_COMMAND_OK\n");
      expect(fake.classifierRequests).toHaveLength(0);
      expectPermissionModeContext(fake.requests[0]!.body, "yolo");
      expect(existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "")
        .not.toContain("event=auto_review_start");

      const stored = JSON.parse(readFileSync(fixture.settingsPath, "utf8"));
      expect(stored).toMatchObject({
        permission_mode: "ask",
        sandbox: CONFIGURED_SANDBOX,
        yolo_acknowledged: true,
        future_setting: { preserved: true },
      });
    },
    TIMEOUT,
  );

  test.each(["full-access", "full access", "yolo"])(
    "status accepts %s in settings and environment without changing JSON",
    async (mode) => {
      const fixture = createFixture("fx-full-access-status-");
      writeFileSync(fixture.settingsPath, JSON.stringify({ permission_mode: mode }));
      const env = {
        HOME: fixture.home,
        FX_PERMISSION_MODE: undefined,
        FX_AUTO_UPGRADE: "0",
      };
      const configured = await runFx(["status", "--json"], { cwd: fixture.workspace, env });
      expect(configured.code).toBe(0);
      expect(configured.stderr).toBe("");
      expect(JSON.parse(configured.stdout).permission_mode).toBe("yolo");
      const fake = startFakeGateway([fakeGatewayFinalText("ALIAS_WRITE_DONE")]);
      gateway = fake;
      const request = await runFx(["ask", "--no-save", "--json", "Reply once."], {
        cwd: fixture.workspace,
        env: {
          ...env,
          AI_GATEWAY_API_KEY: "fake-alias-key",
          FX_GATEWAY_BASE_URL: fake.baseUrl,
          FX_GATEWAY_CHAT_URL: fake.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
        timeoutMs: TIMEOUT,
      });
      expect(request.code).toBe(0);
      expect(request.stderr).toBe(`${WARNING}\n`);
      expect(JSON.parse(request.stdout).output).toContain("ALIAS_WRITE_DONE");
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8"))).toMatchObject({
        permission_mode: mode,
        yolo_acknowledged: true,
      });
      writeFileSync(fixture.settingsPath, JSON.stringify({ permission_mode: "ask" }));
      const overridden = await runFx(["status", "--json"], {
        cwd: fixture.workspace,
        env: { ...env, FX_PERMISSION_MODE: mode },
      });
      expect(overridden.code).toBe(0);
      expect(JSON.parse(overridden.stdout).permission_mode).toBe("yolo");
      const text = await runFx(["permissions"], {
        cwd: fixture.workspace,
        env: { ...env, FX_PERMISSION_MODE: mode },
      });
      expect(text.code).toBe(0);
      expect(text.stdout).toContain("mode=full access");
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8")).permission_mode).toBe("ask");
    },
    TIMEOUT,
  );

  test(
    "status omits sandbox while preserving the legacy configured value",
    async () => {
      const fixture = createFixture("fx-yolo-status-");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "yolo",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: true,
        }) + "\n",
      );

      const result = await runFx(["status", "--json"], {
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_PERMISSION_MODE: undefined,
        },
      });

      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout.trim());
      expect(status).toMatchObject({ permission_mode: "yolo" });
      expect(status).not.toHaveProperty("sandbox");
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8")).sandbox).toBe(
        CONFIGURED_SANDBOX,
      );
    },
    TIMEOUT,
  );

  test(
    "legacy sandbox config is inert and ps executes once",
    async () => {
      const fixture = createFixture("fx-legacy-sandbox-ps-");
      const psPath = join(fixture.workspace, "ps.txt");
      const attemptsPath = join(fixture.workspace, "attempts.txt");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "yolo",
          sandbox: "os",
          yolo_acknowledged: true,
        }) + "\n",
      );

      const fake = startFakeGateway([
        fakeShellRun(
          "legacy_ps",
          `ps -p $$ -o pid= > ${JSON.stringify(psPath)}; printf x >> ${JSON.stringify(attemptsPath)}`,
          { timeout_ms: 600_000 },
        ),
        fakeGatewayFinalText("LEGACY_PS_DONE"),
      ]);
      gateway = fake;

      const result = await runFx(
        ["ask", "--yolo", "--json", "--no-save", "Run the ps fixture once."],
        {
          cwd: fixture.workspace,
          env: {
            HOME: fixture.home,
            AI_GATEWAY_API_KEY: "fake-yolo-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_GATEWAY_BASE_URL: fake.baseUrl,
            FX_GATEWAY_CHAT_URL: fake.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(readFileSync(psPath, "utf8").trim()).toMatch(/^\d+$/);
      expect(readFileSync(attemptsPath, "utf8")).toBe("x");
      expect(fake.classifierRequests).toHaveLength(0);
      expect(fake.requests).toHaveLength(2);
    },
    TIMEOUT,
  );
});

describe.skipIf(!tmuxAvailable())("yolo interactive mode", () => {
  test(
    "Shift+Tab cycles through yolo and warning time pauses behind menus",
    async () => {
      const fixture = createFixture("fx-yolo-tui-");
      const stderrPath = join(fixture.root, "stderr.log");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "ask",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: false,
        }) + "\n",
      );
      writeFileSync(stderrPath, "");

      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: undefined,
        },
      });

      await session.waitForText("ask ·", TIMEOUT);
      await session.sendKeys("BTab");
      await session.waitForText("auto ·", TIMEOUT);
      await session.sendKeys("BTab");
      const warningPane = await session.waitForText(WARNING, TIMEOUT);
      expect(warningPane).toContain("full access ·");

      await session.sendText("/settings");
      const settingsPane = await session.waitForText("←→ Change", TIMEOUT);
      expect(settingsPane).toContain("Permission mode");
      expect(settingsPane).not.toContain("Command sandbox");
      await Bun.sleep(4_300);
      expect(await session.capturePane()).toContain("←→ Change");

      await session.sendKeys("Escape");
      const resumedWarning = await session.waitForText(WARNING, TIMEOUT);
      expect(resumedWarning).toContain("full access ·");

      await Bun.sleep(1_500);
      expect(await session.capturePane()).toContain(WARNING);
      await session.waitForPane((pane) => !pane.includes(WARNING), 3_500);

      const stored = JSON.parse(readFileSync(fixture.settingsPath, "utf8"));
      expect(stored).toMatchObject({
        permission_mode: "yolo",
        sandbox: CONFIGURED_SANDBOX,
        yolo_acknowledged: true,
      });

      await session.sendKeys("BTab");
      await session.waitForText("ask ·", TIMEOUT);
      await session.sendText("/status");
      const statusPane = await session.waitForText("agent_step_limit=", TIMEOUT);
      expect(statusPane).toContain("permission_mode=ask");
      expect(statusPane).not.toContain("sandbox=");
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).not.toContain("YOLO ·");
      expect(scrollback).not.toContain("YOLO enabled:");
      for (const mode of ["full-access", "yolo", "full access"]) {
        await session.sendText(`/permissions ${mode}`);
        await session.waitForText("mode set to full access", TIMEOUT);
        await session.waitForText("full access ·", TIMEOUT);
        expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8")).permission_mode).toBe("yolo");
        await session.sendKeys("BTab");
        await session.waitForText("ask ·", TIMEOUT);
      }
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    45_000,
  );

  test(
    "Shift+Tab applies auto to a later tool call in the active turn",
    async () => {
      const fixture = createFixture("fx-live-permission-auto-");
      const markerPath = join(fixture.workspace, "auto-marker.txt");
      const stderrPath = join(fixture.root, "stderr.log");
      const tracePath = join(fixture.root, "trace.log");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "ask",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: true,
        }) + "\n",
      );
      writeFileSync(stderrPath, "");

      let releaseToolCall: (() => void) | undefined;
      const toolCallGate = new Promise<void>((resolve) => {
        releaseToolCall = resolve;
      });
      const fake = startFakeGateway([
        async () => {
          await toolCallGate;
          return fakeShellRun(
            "live_auto_command",
            `printf 'LIVE_AUTO_OK\\n' > ${JSON.stringify(markerPath)}`,
            { timeout_ms: 600_000 },
          );
        },
        fakeGatewayFinalText("LIVE_AUTO_DONE"),
      ]);
      gateway = fake;

      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-live-permission-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fake.baseUrl,
          FX_GATEWAY_CHAT_URL: fake.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_PERMISSION_MODE: undefined,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "permission",
        },
      });

      await session.waitForText("ask ·", TIMEOUT);
      await session.sendText("Run the requested marker command.");
      await waitForGatewayRequestCount(fake, 1);
      await session.sendKeys("BTab");
      await session.waitForText("auto ·", TIMEOUT);
      releaseToolCall?.();

      const settledPane = await session.waitForPane(
        (pane) => pane.includes("LIVE_AUTO_DONE") || pane.includes(COMMAND_APPROVAL_PROMPT),
        TIMEOUT,
      );
      expect(settledPane).toContain("LIVE_AUTO_DONE");
      expect(settledPane).not.toContain(COMMAND_APPROVAL_PROMPT);
      expect(readFileSync(markerPath, "utf8")).toBe("LIVE_AUTO_OK\n");
      expect(fake.classifierRequests).toHaveLength(1);
      expect(readFileSync(tracePath, "utf8")).toContain(
        "tool_name=shell permission_mode=auto",
      );
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8"))).toMatchObject({
        permission_mode: "auto",
      });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    45_000,
  );

  test(
    "Shift+Tab tightening to ask gates a later tool call in the active turn",
    async () => {
      const fixture = createFixture("fx-live-permission-ask-");
      const markerPath = join(fixture.workspace, "ask-marker.txt");
      const stderrPath = join(fixture.root, "stderr.log");
      const tracePath = join(fixture.root, "trace.log");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "auto",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: true,
        }) + "\n",
      );
      writeFileSync(stderrPath, "");

      let releaseToolCall: (() => void) | undefined;
      const toolCallGate = new Promise<void>((resolve) => {
        releaseToolCall = resolve;
      });
      const fake = startFakeGateway([
        async () => {
          await toolCallGate;
          return fakeShellRun(
            "live_ask_command",
            `printf 'LIVE_ASK_WRONG\\n' > ${JSON.stringify(markerPath)}`,
            { timeout_ms: 600_000 },
          );
        },
        fakeGatewayFinalText("LIVE_ASK_DONE"),
      ]);
      gateway = fake;

      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath,
        width: 120,
        height: 40,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-live-permission-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: fake.baseUrl,
          FX_GATEWAY_CHAT_URL: fake.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_PERMISSION_MODE: undefined,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "permission",
        },
      });

      await session.waitForText("auto ·", TIMEOUT);
      await session.sendText("Run the requested marker command.");
      await waitForGatewayRequestCount(fake, 1);
      await session.sendKeys("BTab");
      await session.waitForText("full access ·", TIMEOUT);
      await session.sendKeys("BTab");
      await session.waitForText("ask ·", TIMEOUT);
      releaseToolCall?.();

      const settledPane = await session.waitForPane(
        (pane) => pane.includes(COMMAND_APPROVAL_PROMPT) || pane.includes("LIVE_ASK_DONE"),
        TIMEOUT,
      );
      expect(settledPane).toContain(COMMAND_APPROVAL_PROMPT);
      expect(settledPane).not.toContain("LIVE_ASK_DONE");
      expect(existsSync(markerPath)).toBe(false);
      expect(fake.classifierRequests).toHaveLength(0);
      expect(readFileSync(tracePath, "utf8")).toContain(
        "tool_name=shell permission_mode=ask",
      );

      await session.sendKeys("3");
      await session.waitForText("LIVE_ASK_DONE", TIMEOUT);
      expect(existsSync(markerPath)).toBe(false);
      expect(JSON.parse(readFileSync(fixture.settingsPath, "utf8"))).toMatchObject({
        permission_mode: "ask",
      });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    45_000,
  );

  test(
    "a pending ctrl+c keeps its quit hint intact and pauses the warning at 60 columns",
    async () => {
      const fixture = createFixture("fx-yolo-ctrl-c-");
      const stderrPath = join(fixture.root, "stderr.log");
      writeFileSync(
        fixture.settingsPath,
        JSON.stringify({
          permission_mode: "yolo",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: false,
        }) + "\n",
      );
      writeFileSync(stderrPath, "");

      session = await TmuxSession.create({
        cwd: fixture.workspace,
        stderrPath,
        width: 60,
        height: 24,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_PERMISSION_MODE: undefined,
        },
      });

      await session.waitForText(WARNING, TIMEOUT);

      await session.sendKeys("C-c");
      const quitPane = await session.waitForText(QUIT_HINT, TIMEOUT);
      expect(quitPane).not.toContain(WARNING);
      expect(quitPane).not.toContain(COMPACT_WARNING);

      // The quit arm lapses after 3s. The warning only survives that long
      // because its visible budget paused while the hint owned the footer.
      const resumedPane = await session.waitForText(WARNING, TIMEOUT);
      expect(resumedPane).not.toContain(QUIT_HINT);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    45_000,
  );
});
