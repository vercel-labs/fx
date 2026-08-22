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
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { expectPermissionModeContext } from "./permission-mode-context";

const WARNING = "YOLO enabled: fx permission checks disabled";
const COMPACT_WARNING = "YOLO: unrestricted";
const QUIT_HINT = "press ctrl+c again to exit";
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

describe("yolo permission mode", () => {
  test(
    "headless mode warns once, bypasses configured denial, and keeps stdout clean",
    async () => {
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
        fakeGatewayToolCall("yolo_command", "terminal", {
          action: "exec",
          command: `printf 'YOLO_COMMAND_OK\\n' > ${JSON.stringify(markerPath)}`,
        }),
        fakeGatewayFinalText("YOLO_HEADLESS_DONE"),
      ]);
      gateway = fake;

      const result = await runFx(
        ["ask", "--yolo", "--json", "--no-save", "Run the fixture command exactly once."],
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
          (call) => call.name === "terminal" && call.status === "success",
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
        fakeGatewayToolCall("legacy_ps", "terminal", {
          action: "exec",
          command: `ps -p $$ -o pid= > ${JSON.stringify(psPath)}; printf x >> ${JSON.stringify(attemptsPath)}`,
        }),
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
      expect(warningPane).toContain("YOLO ·");

      await session.sendText("/settings");
      const settingsPane = await session.waitForText("←→ Change", TIMEOUT);
      expect(settingsPane).toContain("Permission mode");
      expect(settingsPane).not.toContain("Command sandbox");
      await Bun.sleep(4_300);
      expect(await session.capturePane()).toContain("←→ Change");

      await session.sendKeys("Escape");
      const resumedWarning = await session.waitForText(WARNING, TIMEOUT);
      expect(resumedWarning).toContain("YOLO ·");

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
