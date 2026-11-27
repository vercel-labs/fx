// FXC-1392 repro: a subagent's shell command runs on the parent's
// managed-execution runtime and outlives the subagent's turn.
//
// Taken from tests B6 and B6b of the fx#2480 break-it run
// (tests/e2e/zz-breakit-attacks.test.ts, not committed). It needs the fx#2480
// change, which adds FX_TEST_MCP_CALL_FOLLOW_WAIT_MS and the
// "waits for a shell call to follow its command" trace line. It uses a fake
// gateway only, so it makes no model calls.
//
// Run from the repository root:
//   zig build && cd tests/e2e && FX_SOUND=0 bun test ./zz-fxc1392-repro.test.ts
// The evidence is in the FXC1392_B6_* and FXC1392_B6B_* lines it prints.
import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import { processAlive } from "./process-alive";
import { savedSessionIds } from "./saved-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall, startDynamicFakeGateway } from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const WAITING_CALL_TRACE = "waits for a shell call to follow its command";

type Gateway = ReturnType<typeof startDynamicFakeGateway>;

type ReproRoot = {
  root: string;
  home: string;
  workspace: string;
  tmpDir: string;
  wireLogPath: string;
  traceLogPath: string;
};

let gateway: Gateway | null = null;
let cleanupRoot: string | null = null;

afterEach(() => {
  gateway?.stop();
  gateway = null;
  if (cleanupRoot) rmSync(cleanupRoot, { recursive: true, force: true });
  cleanupRoot = null;
});

function reproRoot(label: string): ReproRoot {
  // A short path keeps the bridge's Unix socket path under 104 bytes.
  const root = realpathSync(mkdtempSync(join(tmpdir(), `r-${label}-`)));
  cleanupRoot = root;
  const home = join(root, "h");
  const workspace = join(root, "w");
  const tmpDir = join(root, "t");
  const wireLogPath = join(root, "wire.jsonl");
  const traceLogPath = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(tmpDir, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, MODERN_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_WIRE_LOG: wireLogPath,
            FX_MCP_RESULT_PAD_BYTES: String(2048),
            FX_MCP_RESULT_TEXT: "REPRO_TAIL",
            FX_MCP_EXPECT_ELICITATION: "both",
            FX_MCP_MODE: "normal",
          },
        },
      },
    }),
  );
  return { root, home, workspace, tmpDir, wireLogPath, traceLogPath };
}

function reproEnv(root: ReproRoot, activeGateway: Gateway, extra: Record<string, string> = {}) {
  return {
    HOME: root.home,
    TMPDIR: root.tmpDir,
    AI_GATEWAY_API_KEY: "fake-repro-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: activeGateway.baseUrl,
    FX_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_MODEL: MODEL,
    FX_TRACE_LOG: root.traceLogPath,
    FX_TRACE_SCOPES: "mcp-call",
    ...extra,
  };
}

function toolResultText(body: string, callId: string): string {
  const prompt = (JSON.parse(body) as { prompt: Array<{ content?: unknown }> }).prompt;
  const part = prompt
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []) as Array<Record<string, unknown>>)
    .find((item) => item.type === "tool-result" && item.toolCallId === callId);
  if (!part) throw new Error(`missing tool result for ${callId}`);
  return contentText(part.output);
}

function toolCalls(root: ReproRoot) {
  if (!existsSync(root.wireLogPath)) return [];
  return readFileSync(root.wireLogPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.message?.method === "tools/call");
}

function traceLines(root: ReproRoot): string[] {
  if (!existsSync(root.traceLogPath)) return [];
  return readFileSync(root.traceLogPath, "utf8").trim().split("\n").filter(Boolean);
}

function socketDirsLeft(root: ReproRoot): string[] {
  if (!existsSync(root.tmpDir)) return [];
  return readdirSync(root.tmpDir).filter((name) => name.startsWith("fx-mcp-"));
}

function matchingProcesses(needle: string): string[] {
  const out = execFileSync("ps", ["-eo", "pid=,ppid=,args="], { encoding: "utf8" });
  return out
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.includes(needle) && !line.includes("ps -eo"));
}

async function waitForFileText(path: string, text: string, timeoutMs = 15_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const contents = readFileSync(path, "utf8");
      if (contents.includes(text)) return contents;
    }
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for "${text}" in ${path}`);
}

async function waitForFilePresent(path: string, timeoutMs = 15_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const contents = readFileSync(path, "utf8").trim();
      if (contents !== "") return contents;
    }
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for non-empty ${path}`);
}

describe("FXC-1392", () => {
  test(
    "B6: a subagent's command is still running when the subagent's turn has ended",
    async () => {
      const root = reproRoot("b6");
      const childCommand = `echo $$ > cmd.pid; while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b6"}' > out.json 2> err.txt & echo $! > client.pid; wait $!; echo $? > call.code`;
      let childRunResult: Record<string, unknown> = {};
      let cmdPid = 0;
      let clientPid = 0;

      const activeGateway = startDynamicFakeGateway(async (body) => {
        if (body.includes("Subagent report")) {
          // The subagent's turn has ended. Is its command still alive?
          const cmdAliveAtReport = cmdPid > 0 ? processAlive(cmdPid) : null;
          const tracesAtReport = traceLines(root);
          const callCode = await waitForFilePresent(join(root.workspace, "call.code"), 10_000);
          console.log("FXC1392_B6_AT_REPORT", JSON.stringify({ cmdAliveAtReport, tracesAtReport, callCode }));
          return fakeGatewayFinalText("B6_PARENT_DONE");
        }
        if (body.includes('"toolCallId":"create_child"')) {
          return fakeGatewayFinalText("B6_PARENT_WAITING_OR_DONE");
        }
        if (body.includes('"toolCallId":"child_run"')) {
          childRunResult = JSON.parse(toolResultText(body, "child_run"));
          cmdPid = Number(await waitForFilePresent(join(root.workspace, "cmd.pid"), 10_000));
          writeFileSync(join(root.workspace, "go"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          clientPid = Number(await waitForFilePresent(join(root.workspace, "client.pid"), 10_000));
          // The subagent ends its turn without calling interact.
          return fakeGatewayFinalText("B6_CHILD_ENDED");
        }
        if (body.includes("B6_CHILD_TASK")) {
          return fakeGatewayToolCall("child_run", "shell", { action: "run", command: childCommand, yield_time_ms: 1000 });
        }
        if (body.includes("B6_PARENT_TASK")) {
          return fakeGatewayToolCall("create_child", "subagent", {
            request: { action: "message", agent: "helper", message: "B6_CHILD_TASK" },
          });
        }
        return fakeGatewayFinalText("unexpected");
      }, {
        classifierDecision: "clear",
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["ask", "--json", "--full-access", "B6_PARENT_TASK"], {
        cwd: root.workspace,
        env: reproEnv(root, activeGateway, { FX_TEST_MCP_CALL_FOLLOW_WAIT_MS: "2000" }),
        timeoutMs: 60_000,
      });

      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);
      console.log("FXC1392_B6_AFTER_FX_EXIT", JSON.stringify({
        fxExit: result.code,
        childRunState: childRunResult.state,
        childSessionId: childRunResult.session_id,
        cmdPidAlive: cmdPid > 0 ? processAlive(cmdPid) : null,
        clientPidAlive: clientPid > 0 ? processAlive(clientPid) : null,
        callCode: existsSync(join(root.workspace, "call.code")) ? readFileSync(join(root.workspace, "call.code"), "utf8").trim() : null,
        callErr: existsSync(join(root.workspace, "err.txt")) ? readFileSync(join(root.workspace, "err.txt"), "utf8").trim() : "",
        callsCount: toolCalls(root).length,
        traces: traceLines(root),
        leftSockets,
        leftProcs,
        sessions,
      }));

      expect(result.code).toBe(0);
      expect(toolCalls(root)).toHaveLength(0);
      expect(processAlive(cmdPid)).toBe(false);
      expect(processAlive(clientPid)).toBe(false);
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBeGreaterThanOrEqual(1);
    },
    60_000,
  );

  test(
    "B6b: the parent reaches an ended subagent's command with shell interact by its session id",
    async () => {
      const root = reproRoot("b6b");
      mkdirSync(join(root.home, ".fx", "agents", "limited"), { recursive: true });
      writeFileSync(
        join(root.home, ".fx", "agents", "limited", "profile.json"),
        JSON.stringify({ description: "No MCP servers", mcp_servers: [] }),
      );
      const childCommand = `while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"escalated"}' > out.json 2> err.txt; echo $? > call.code`;
      let childSessionId = "";
      let interactResult: Record<string, unknown> = {};

      const activeGateway = startDynamicFakeGateway(async (body) => {
        if (body.includes('"toolCallId":"parent_interact"')) {
          interactResult = JSON.parse(toolResultText(body, "parent_interact"));
          return fakeGatewayFinalText("B6B_PARENT_DONE");
        }
        if (body.includes("Subagent report")) {
          writeFileSync(join(root.workspace, "go"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          return fakeGatewayToolCall("parent_interact", "shell", {
            action: "interact",
            session_id: childSessionId,
            yield_time_ms: 30_000,
          });
        }
        if (body.includes('"toolCallId":"create_child"')) {
          return fakeGatewayFinalText("B6B_PARENT_WAIT");
        }
        if (body.includes('"toolCallId":"child_run"')) {
          childSessionId = JSON.parse(toolResultText(body, "child_run")).session_id;
          return fakeGatewayFinalText("B6B_CHILD_ENDED");
        }
        if (body.includes("B6B_CHILD_TASK")) {
          return fakeGatewayToolCall("child_run", "shell", { action: "run", command: childCommand, yield_time_ms: 1000 });
        }
        if (body.includes("B6B_PARENT_TASK")) {
          return fakeGatewayToolCall("create_child", "subagent", {
            request: { action: "message", agent: "limited", message: "B6B_CHILD_TASK" },
          });
        }
        return fakeGatewayFinalText("unexpected");
      }, {
        classifierDecision: "clear",
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["ask", "--json", "--full-access", "B6B_PARENT_TASK"], {
        cwd: root.workspace,
        env: reproEnv(root, activeGateway),
        timeoutMs: 60_000,
      });

      const calls = toolCalls(root).map((call) => call.message.params?.arguments?.text);
      const callCode = existsSync(join(root.workspace, "call.code")) ? readFileSync(join(root.workspace, "call.code"), "utf8").trim() : null;
      console.log("FXC1392_B6B_EVIDENCE", JSON.stringify({
        fxExit: result.code,
        childSessionId,
        interactSessionId: interactResult.session_id,
        interactState: interactResult.state,
        interactError: interactResult.error,
        interactOutput: interactResult.output_delta,
        callCode,
        calls,
        traces: traceLines(root),
      }));
      expect(result.code).toBe(0);
    },
    60_000,
  );
});
