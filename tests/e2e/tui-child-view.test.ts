import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// The live view of the experimental subagents: Ctrl+T opens a picker of the
// main fx's children, a choice shows that child's own fx at full size with
// every key going to it, and Ctrl+T returns to main. The children are real
// fx processes answered by the same fake gateway as main.

const TIMEOUT = 30_000;
const MODEL = "fixture-model";
const LAUNCH_PROMPT = "LAUNCH_ONE_CHILD";
const CHILD_TASK = "CHILD_TASK_REPLY_READY";
const TYPED = "TYPED_INTO_CHILD_VIEW";
const LAUNCH_CALL = "launch_c1";
const STATUS_LINE = "c1 \u00b7 Ctrl+T returns to main";
const PICKER_HINT = "Enter view";

const roots: string[] = [];
const gateways: Array<ReturnType<typeof startDynamicFakeGateway>> = [];
let session: TmuxSession | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function lastUserText(body: string): string {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  const content = request.prompt?.findLast((message) => message.role === "user")?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => (typeof part?.text === "string" ? part.text : "")).join("");
}

function directChildren(pid: number): number[] {
  try {
    const out = execFileSync("pgrep", ["-P", String(pid)], { encoding: "utf8" });
    return out.trim().split(/\s+/).filter(Boolean).map(Number);
  } catch {
    return [];
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitUntilGone(pids: number[], timeoutMs: number): Promise<number[]> {
  const deadline = Date.now() + timeoutMs;
  while (pids.some(alive) && Date.now() < deadline) await Bun.sleep(100);
  return pids.filter(alive);
}

type Gateway = ReturnType<typeof startDynamicFakeGateway>;

// Starts main fx in tmux on a fresh home and workspace, answered by
// `gateway`. The session is also kept for cleanup.
async function startMain(
  gateway: Gateway,
  env: Record<string, string | undefined> = {},
): Promise<{ s: TmuxSession; stderrPath: string }> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-child-view-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  const stderrPath = join(root, "stderr.log");
  writeFileSync(stderrPath, "");
  const s = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-child-view-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_SUBAGENTS_V2: "1",
      NO_COLOR: "1",
      ...env,
    },
    stderrPath,
    width: 120,
    height: 40,
  });
  session = s;
  await s.waitForComposer(TIMEOUT);
  return { s, stderrPath };
}

async function quitCleanly(s: TmuxSession, stderrPath: string): Promise<void> {
  await s.sendText("/quit");
  expect(await s.waitForSessionEnd(10_000)).toBe(true);
  session = null;
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}

describe("subagent live view", () => {
  test.skipIf(!tmuxAvailable())(
    "Ctrl+T shows a child's own fx, types into it, and returns to main",
    async () => {
      let childSawSubagentTool = false;
      const gateway = startDynamicFakeGateway((body) => {
        const user = lastUserText(body);
        if (user.includes(CHILD_TASK) || user.includes(TYPED)) {
          childSawSubagentTool ||= body.includes('"name":"subagent"');
          return fakeGatewayFinalText(user.includes(TYPED) ? "CHILD_HEARD_YOU" : "CHILD_READY");
        }
        if (body.includes(`"toolCallId":"${LAUNCH_CALL}"`)) return fakeGatewayFinalText("PARENT_LAUNCHED");
        if (user.includes(LAUNCH_PROMPT)) {
          return fakeGatewayToolCall(LAUNCH_CALL, "subagent", { action: "launch", name: "c1", task: CHILD_TASK });
        }
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);

      const { s, stderrPath } = await startMain(gateway);
      await s.sendText(LAUNCH_PROMPT);
      await s.waitForText("PARENT_LAUNCHED", TIMEOUT);

      // The picker lists the child, then Enter shows its own fx.
      await s.sendKeys("C-t");
      await s.waitForText(/\u203a c1 +(idle|working|starting)/, TIMEOUT);
      await s.sendKeys("Enter");
      const view = await s.waitForText(STATUS_LINE, TIMEOUT);
      expect(view).not.toContain("PARENT_LAUNCHED");
      await s.waitForText("CHILD_READY", TIMEOUT);

      // Keys go to the child: its own composer takes the text and submits it.
      await s.sendText(TYPED);
      await s.waitForText("CHILD_HEARD_YOU", TIMEOUT);

      // Ctrl+T returns to main, whose screen comes back whole.
      await s.sendKeys("C-t");
      const main = await s.waitForText("PARENT_LAUNCHED", TIMEOUT);
      expect(main).not.toContain(STATUS_LINE);
      expect(main).not.toContain("CHILD_HEARD_YOU");
      expect(childSawSubagentTool).toBe(false);

      // Quitting main stops its child.
      const children = directChildren(s.processPid());
      expect(children.length).toBe(1);
      await s.sendText("/quit");
      expect(await s.waitForSessionEnd(10_000)).toBe(true);
      session = null;
      expect(await waitUntilGone(children, 5_000)).toEqual([]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    90_000,
  );

  test.skipIf(!tmuxAvailable())(
    "Ctrl+T over the full transcript leaves it alone",
    async () => {
      const gateway = startDynamicFakeGateway((body) => {
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);
      const { s, stderrPath } = await startMain(gateway);
      await s.sendKeys("C-o");
      await Bun.sleep(500);
      await s.sendKeys("C-t");
      await Bun.sleep(500);
      expect(await s.capturePane()).not.toContain(PICKER_HINT);
      await s.sendKeys("C-o");
      await s.waitForComposer(TIMEOUT);
      await quitCleanly(s, stderrPath);
    },
    60_000,
  );

  test.skipIf(!tmuxAvailable())(
    "Ctrl+T does nothing without the flag",
    async () => {
      const gateway = startDynamicFakeGateway((body) => {
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);
      const { s, stderrPath } = await startMain(gateway, { FX_SUBAGENTS_V2: undefined });
      await s.sendKeys("C-t");
      await Bun.sleep(500);
      expect(await s.capturePane()).not.toContain(PICKER_HINT);
      await s.waitForComposer(TIMEOUT);
      await quitCleanly(s, stderrPath);
    },
    60_000,
  );

  test.skipIf(!tmuxAvailable())(
    "main's own prompt waits on a view, which survives a resize, and main comes back whole",
    async () => {
      let mainAsked = false;
      const gateway = startDynamicFakeGateway(async (body) => {
        const user = lastUserText(body);
        if (user.includes(CHILD_TASK)) return fakeGatewayFinalText("CHILD_READY");
        if (body.includes('"toolCallId":"main_ask"')) return fakeGatewayFinalText("PARENT_DONE");
        if (body.includes(`"toolCallId":"${LAUNCH_CALL}"`)) {
          // Late enough that the test is in the child's view first.
          await Bun.sleep(3000);
          mainAsked = true;
          return fakeShellRun("main_ask", "printf MAIN_ASKED");
        }
        if (user.includes(LAUNCH_PROMPT)) {
          return fakeGatewayToolCall(LAUNCH_CALL, "subagent", { action: "launch", name: "c1", task: CHILD_TASK });
        }
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);
      const { s, stderrPath } = await startMain(gateway, { FX_PERMISSION_MODE: "ask" });
      await s.sendText(LAUNCH_PROMPT);

      await s.sendKeys("C-t");
      await s.waitForText(/\u203a c1 +(idle|working|starting)/, TIMEOUT);
      await s.sendKeys("Enter");
      await s.waitForText(STATUS_LINE, TIMEOUT);
      expect(mainAsked).toBe(false);

      // Main's approval waits while the view is open, and the status line
      // says so, also after a resize.
      await s.waitForText("c1 \u00b7 main needs you \u00b7 Ctrl+T returns to main", TIMEOUT);
      await s.resizeWindow(100, 32);
      await s.waitForText("c1 \u00b7 main needs you \u00b7 Ctrl+T returns to main", TIMEOUT);

      // Back on main the approval shows, and the transcript before it is
      // whole.
      await s.sendKeys("C-t");
      const main = await s.waitForText("printf MAIN_ASKED", TIMEOUT);
      expect(main).toContain(LAUNCH_PROMPT);
      expect(main).not.toContain(STATUS_LINE);
      await s.sendKeys("1");
      await s.waitForText("PARENT_DONE", TIMEOUT);
      await quitCleanly(s, stderrPath);
    },
    90_000,
  );

  test.skipIf(!tmuxAvailable())(
    "another child's prompt is counted on the view's status line and shows back on main",
    async () => {
      const gateway = startDynamicFakeGateway(async (body) => {
        const user = lastUserText(body);
        if (user.includes(CHILD_TASK)) return fakeGatewayFinalText("CHILD_READY");
        if (user.includes("CHILD_TWO_ASKS")) {
          if (body.includes('"toolCallId":"c2_ask"')) return fakeGatewayFinalText("C2_DONE");
          return fakeShellRun("c2_ask", "printf C2_ASKED");
        }
        if (body.includes('"toolCallId":"launch_c2"')) return fakeGatewayFinalText("PARENT_DONE");
        if (body.includes(`"toolCallId":"${LAUNCH_CALL}"`)) {
          // Late enough that the test is in c1's view first.
          await Bun.sleep(3000);
          return fakeGatewayToolCall("launch_c2", "subagent", { action: "launch", name: "c2", task: "CHILD_TWO_ASKS" });
        }
        if (user.includes(LAUNCH_PROMPT)) {
          return fakeGatewayToolCall(LAUNCH_CALL, "subagent", { action: "launch", name: "c1", task: CHILD_TASK });
        }
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);
      const { s, stderrPath } = await startMain(gateway, { FX_PERMISSION_MODE: "ask" });
      await s.sendText(LAUNCH_PROMPT);

      await s.sendKeys("C-t");
      await s.waitForText(/\u203a c1 +(idle|working|starting)/, TIMEOUT);
      await s.sendKeys("Enter");
      await s.waitForText(STATUS_LINE, TIMEOUT);

      // c2's approval cannot show over c1's screen, so the status line
      // counts it instead.
      await s.waitForText("c1 \u00b7 1 other child needs you \u00b7 Ctrl+T returns to main", TIMEOUT);

      await s.sendKeys("C-t");
      await s.waitForText("printf C2_ASKED", TIMEOUT);
      await s.sendKeys("1");
      await s.waitForText("PARENT_DONE", TIMEOUT);
      await quitCleanly(s, stderrPath);
    },
    90_000,
  );
});
