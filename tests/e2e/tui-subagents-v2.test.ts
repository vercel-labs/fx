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

// The experimental subagent tool: the main fx launches a child fx in a hidden
// terminal, the child's permission prompt shows on main, and the answer given
// there reaches the child. The children are real fx processes answered by the
// same fake gateway as main.

const TIMEOUT = 30_000;
const MODEL = "fixture-model";
const LAUNCH_PROMPT = "LAUNCH_ONE_CHILD";
const READ_PROMPT = "READ_THE_CHILD";
const CHILD_TASK = "CHILD_TASK_RUN_A_COMMAND";
const CHILD_COMMAND = "printf CHILD_RAN";
const PERMISSION_LABEL = "Subagent c1 needs permission";

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

function hasToolResult(body: string, callId: string): boolean {
  return body.includes(`"toolCallId":"${callId}"`);
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

describe("subagents v2", () => {
  test.skipIf(!tmuxAvailable())(
    "a child's permission prompt shows on main and its answer reaches the child",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-subagents-v2-e2e-")));
      roots.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
      const stderrPath = join(root, "stderr.log");
      writeFileSync(stderrPath, "");

      let childSawSubagentTool = false;
      const gateway = startDynamicFakeGateway((body) => {
        const user = lastUserText(body);
        if (user.includes(CHILD_TASK)) {
          childSawSubagentTool ||= body.includes('"name":"subagent"');
          if (hasToolResult(body, "child_command")) {
            return fakeGatewayFinalText(body.includes("CHILD_RAN") ? "CHILD_DONE" : "CHILD_COMMAND_MISSING");
          }
          return fakeShellRun("child_command", CHILD_COMMAND);
        }
        if (user.includes(READ_PROMPT)) {
          if (hasToolResult(body, "read_c1")) {
            return fakeGatewayFinalText(body.includes("CHILD_DONE") ? "PARENT_READ_CHILD_DONE" : "PARENT_READ_NOTHING");
          }
          if (hasToolResult(body, "wait_c1")) {
            return fakeGatewayToolCall("read_c1", "subagent", { action: "read", name: "c1", what: "final" });
          }
          return fakeGatewayToolCall("wait_c1", "subagent", { action: "wait", names: ["c1"], timeout_ms: 20_000 });
        }
        if (user.includes(LAUNCH_PROMPT)) {
          if (hasToolResult(body, "launch_c1")) return fakeGatewayFinalText("PARENT_LAUNCHED");
          return fakeGatewayToolCall("launch_c1", "subagent", { action: "launch", name: "c1", task: CHILD_TASK });
        }
        throw new Error(`unexpected request: ${body.slice(0, 400)}`);
      });
      gateways.push(gateway);

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-subagents-v2-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: MODEL,
          FX_PERMISSION_MODE: "ask",
          FX_AUTO_UPGRADE: "0",
          FX_SUBAGENTS_V2: "1",
          NO_COLOR: "1",
        },
        stderrPath,
        width: 120,
        height: 40,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText(LAUNCH_PROMPT);

      // The child's command needs approval, and the prompt shows on main. It
      // may come before main's own reply, which waits while a prompt is open.
      const prompt = await session.waitForText(PERMISSION_LABEL, TIMEOUT);
      expect(prompt).toContain(CHILD_COMMAND);
      await session.sendKeys("1");
      await session.waitForText("PARENT_LAUNCHED", TIMEOUT);

      // Main waits for the child and reads the reply it gave after the command ran.
      await session.waitForComposer(TIMEOUT);
      await session.sendText(READ_PROMPT);
      await session.waitForText("PARENT_READ_CHILD_DONE", TIMEOUT);
      expect(childSawSubagentTool).toBe(false);

      // Quitting main stops its child.
      const children = directChildren(session.processPid());
      expect(children.length).toBe(1);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(10_000)).toBe(true);
      session = null;
      expect(await waitUntilGone(children, 5_000)).toEqual([]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    90_000,
  );
});
