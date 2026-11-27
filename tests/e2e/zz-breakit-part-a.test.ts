import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5";
const TOOL_NAME = "mcp_fixture_echo";
const TOOL_ROW = "Fixture to echo";
const MODERN_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const WAITING_CALL_TRACE = "waits for a shell call to follow its command";
const EXPECTED_NOTICE =
  "This command used fx mcp call and still runs. Its later fx mcp call commands wait until a shell call checks on it: call shell interact with this session_id within 2 minutes to let them run.";

type Root = {
  root: string;
  home: string;
  workspace: string;
  wireLogPath: string;
  traceLogPath: string;
};

let tui: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let cleanupRoot: string | null = null;

afterEach(async () => {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeCleanup = cleanupRoot;
  tui = null;
  gateway = null;
  cleanupRoot = null;
  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  if (activeCleanup) rmSync(activeCleanup, { recursive: true, force: true });
});

function createBridgeRoot(label: string): Root {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-breakit-${label}-`)));
  cleanupRoot = root;
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const wireLogPath = join(root, "mcp-wire.jsonl");
  const traceLogPath = join(root, "mcp-call-trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
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
            FX_MCP_RESULT_PAD_BYTES: String(4096),
            FX_MCP_RESULT_TEXT: "BRIDGE_TAIL",
            FX_MCP_EXPECT_ELICITATION: "both",
          },
        },
      },
    }),
  );
  return { root, home, workspace, wireLogPath, traceLogPath };
}

function bridgeEnv(root: Root, activeGateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-breakit-key",
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

function toolCalls(root: Root) {
  if (!existsSync(root.wireLogPath)) return [];
  return readFileSync(root.wireLogPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.message?.method === "tools/call");
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

describe("Part A break-it", () => {
  test.skipIf(!tmuxAvailable())(
    "A1: TUI in tmux, 5 mcp calls with pauses, steering after call 2, interact finishes all 5, FX_RECORD + replay, Ctrl+O, /quit, --resume last",
    async () => {
      const root = createBridgeRoot("a1-tui");
      const stderrPath = join(root.root, "stderr.log");
      const resumedStderrPath = join(root.root, "resumed-stderr.log");
      const tapePath = join(root.root, "a1.fxtape");
      const goldenPath = join(root.root, "a1-golden.txt");

      const command = [
        `for i in 1 2 3 4 5; do`,
        `  while [ ! -f "go_$i" ]; do sleep 0.05; done`,
        `  "${FX_BIN}" mcp call ${TOOL_NAME} "{\\"text\\":\\"call-$i\\"}" > "out_$i.json" 2> "err_$i.txt"`,
        `  echo "$?" > "exit_$i.txt"`,
        `done`,
        `echo "ALL_DONE"`,
      ].join("\n");

      let runResult: Record<string, unknown> = {};
      let interactResult: Record<string, unknown> = {};
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 60_000 }),
        async (body: string) => {
          runResult = JSON.parse(toolResultText(body, "run_call"));
          writeFileSync(join(root.workspace, "go_3"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 15_000);
          return fakeGatewayToolCall("interact_call", "shell", {
            action: "interact",
            session_id: runResult.session_id,
            yield_time_ms: 60_000,
          });
        },
        (body: string) => {
          interactResult = JSON.parse(toolResultText(body, "interact_call"));
          return fakeGatewayFinalText("A1_FIVE_CALLS_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const env = { ...bridgeEnv(root, activeGateway), FX_RECORD: tapePath };
      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 60,
        stderrPath,
        env,
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Run the 5 mcp calls.");

      writeFileSync(join(root.workspace, "go_1"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_1.txt"), 20_000)).toBe("0");

      writeFileSync(join(root.workspace, "go_2"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_2.txt"), 20_000)).toBe("0");

      // Steer after call 2 while run_call is waiting on its long yield_time_ms.
      await tui.sendText("Steer after call 2.");

      // Call 3 is triggered by gateway step 2; wait for it to finish, then release 4 and 5.
      expect(await waitForFilePresent(join(root.workspace, "exit_3.txt"), 20_000)).toBe("0");
      writeFileSync(join(root.workspace, "go_4"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_4.txt"), 20_000)).toBe("0");
      writeFileSync(join(root.workspace, "go_5"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_5.txt"), 20_000)).toBe("0");

      await tui.waitForPane((pane) => pane.includes("A1_FIVE_CALLS_DONE") && turnSettled(pane), 30_000);
      await tui.waitForComposer(10_000);

      expect(runResult.state).toBe("running");
      expect(typeof runResult.steering_notice).toBe("string");
      expect(runResult.mcp_call_notice).toBe(EXPECTED_NOTICE);
      expect(interactResult.state).toBe("completed");
      expect(interactResult.output_delta).toContain("ALL_DONE");
      expect(toolCalls(root)).toHaveLength(5);

      const liveEscapes = await tui.captureFullScrollbackEscapes();
      const livePlain = await tui.captureFullScrollback();
      expect(liveEscapes.length).toBeGreaterThan(0);
      expect(livePlain).toContain(`Used ${TOOL_ROW} ×2`);
      expect(livePlain).toContain(`Used ${TOOL_ROW} ×3`);
      expect(livePlain).toContain("Steer after call 2.");
      expect(livePlain).not.toContain(`Using ${TOOL_ROW}`);
      expect(livePlain).not.toContain("Running MCP");
      expect(livePlain).not.toContain("panic");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      // Ctrl+O full transcript view
      await tui.sendKeys("C-o");
      const fullView = await tui.waitForPane((pane) => pane.includes("esc close") && pane.split(`Ran MCP ${TOOL_NAME}`).length === 6, 10_000);
      expect(fullView.split(`Ran MCP ${TOOL_NAME}`)).toHaveLength(6);
      await tui.sendKeys("C-o");
      await tui.waitForComposer(10_000);

      // /quit
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(10_000)).toBe(true);
      tui = null;

      // Replay golden
      const replay = spawnSync(FX_BIN, ["replay", tapePath, "--golden", goldenPath], {
        encoding: "utf8",
      });
      expect(replay.status).toBe(0);
      const golden = readFileSync(goldenPath, "utf8");
      expect(golden).toContain("A1_FIVE_CALLS_DONE");

      // Resume last
      const resumeEnv = bridgeEnv(root, activeGateway);
      tui = await TmuxSession.create({
        cmd: `${JSON.stringify(FX_BIN)} --resume last`,
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 40,
        stderrPath: resumedStderrPath,
        env: resumeEnv,
      });
      await tui.waitForComposer(15_000);
      await tui.waitForText("A1_FIVE_CALLS_DONE", 15_000);
      const resumedScrollback = await tui.captureFullScrollbackEscapes();
      expect(resumedScrollback).toContain(`Used ${TOOL_ROW} ×2`);
      expect(resumedScrollback).toContain(`Used ${TOOL_ROW} ×3`);
      expect(readFileSync(resumedStderrPath, "utf8")).toBe("");
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(10_000)).toBe(true);
      tui = null;

      console.log("A1_EVIDENCE_START");
      console.log("runResult.steering_notice:", runResult.steering_notice);
      console.log("runResult.mcp_call_notice:", runResult.mcp_call_notice);
      console.log("livePlain:\n" + livePlain);
      console.log("golden_len:", golden.length);
      console.log("resumed_has_rows:", resumedScrollback.includes(`Used ${TOOL_ROW} ×2`) && resumedScrollback.includes(`Used ${TOOL_ROW} ×3`));
      console.log("A1_EVIDENCE_END");
    },
    120_000,
  );

  test(
    "A2: fx ask --json run returns at yield_time_ms, then interact; later call exits 0; check stdout JSON and tool result",
    async () => {
      const root = createBridgeRoot("a2-ask-json");
      const command = [
        `"${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"first"}' > first.json 2> first.err; echo "first_exit=$?"`,
        `while [ ! -f go ]; do sleep 0.05; done`,
        `"${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"second"}' > second.json 2> second.err; echo "second_exit=$?"`,
      ].join("; ");

      let runResult: Record<string, unknown> = {};
      let interactResult: Record<string, unknown> = {};
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 1000 }),
        async (body: string) => {
          runResult = JSON.parse(toolResultText(body, "run_call"));
          writeFileSync(join(root.workspace, "go"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          return fakeGatewayToolCall("interact_call", "shell", {
            action: "interact",
            session_id: runResult.session_id,
            yield_time_ms: 30_000,
          });
        },
        (body: string) => {
          interactResult = JSON.parse(toolResultText(body, "interact_call"));
          return fakeGatewayFinalText("A2_ASK_JSON_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["ask", "--json", "--full-access", "--no-save", "Run the command."], {
        cwd: root.workspace,
        env: bridgeEnv(root, activeGateway),
        timeoutMs: 60_000,
      });

      console.log("A2_STDOUT_JSON:", result.stdout);
      console.log("A2_RUN_RESULT:", JSON.stringify(runResult));
      console.log("A2_INTERACT_RESULT:", JSON.stringify(interactResult));

      expect(result.code).toBe(0);
      expect(runResult.state).toBe("running");
      expect(runResult.mcp_call_notice).toBe(EXPECTED_NOTICE);
      expect(interactResult.output_delta).toContain("second_exit=0");
      expect(toolCalls(root)).toHaveLength(2);
      const parsedStdout = JSON.parse(result.stdout);
      expect(parsedStdout.output).toContain("A2_ASK_JSON_DONE");
      // Check whether stdout JSON itself includes mcp_call_notice:
      console.log("A2_STDOUT_HAS_MCP_CALL_NOTICE:", result.stdout.includes("mcp_call_notice"));
    },
    60_000,
  );
});
