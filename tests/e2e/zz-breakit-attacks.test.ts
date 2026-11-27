import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, fxChildEnv, runFx } from "../evals/eval-helpers";
import { contentText } from "./conditional-guidance-oracle";
import { processAlive } from "./process-alive";
import { savedSessionIds, savedText } from "./saved-sessions";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
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

type AttackRoot = {
  root: string;
  home: string;
  workspace: string;
  tmpDir: string;
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

function attackRoot(label: string, mode = "normal", extra: Record<string, unknown> = {}): AttackRoot {
  // Keep path short so Unix socket path (< 104 bytes) fits inside TMPDIR.
  const root = realpathSync(mkdtempSync(join(tmpdir(), `b-${label}-`)));
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
            FX_MCP_RESULT_TEXT: "ATTACK_TAIL",
            FX_MCP_EXPECT_ELICITATION: "both",
            FX_MCP_MODE: mode,
            ...extra,
          },
        },
      },
    }),
  );
  return { root, home, workspace, tmpDir, wireLogPath, traceLogPath };
}

function attackEnv(root: AttackRoot, activeGateway: ReturnType<typeof startFakeGateway>, extra: Record<string, string> = {}) {
  return {
    HOME: root.home,
    TMPDIR: root.tmpDir,
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

function toolCalls(root: AttackRoot) {
  if (!existsSync(root.wireLogPath)) return [];
  return readFileSync(root.wireLogPath, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.message?.method === "tools/call");
}

function traceLines(root: AttackRoot): string[] {
  if (!existsSync(root.traceLogPath)) return [];
  return readFileSync(root.traceLogPath, "utf8").trim().split("\n").filter(Boolean);
}

function socketDirsLeft(root: AttackRoot): string[] {
  if (!existsSync(root.tmpDir)) return [];
  return readdirSync(root.tmpDir).filter((name) => name.startsWith("fx-mcp-"));
}

function matchingProcesses(needle: string): string[] {
  const out = execFileSync("ps", ["-eo", "pid=,ppid=,args="], { encoding: "utf8" });
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.includes(needle) && !l.includes("ps -eo"));
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

async function waitForFileCount(path: string, needle: string, count: number, timeoutMs = 15_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const contents = readFileSync(path, "utf8");
      if (contents.split(needle).length - 1 >= count) return contents;
    }
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${count}x "${needle}" in ${path}`);
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

async function waitForCondition(label: string, pred: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${label}`);
}

describe("Part B attacks", () => {
  test.skipIf(!tmuxAvailable())(
    "B1: Steering twice during the loop",
    async () => {
      const root = attackRoot("b1");
      const stderrPath = join(root.root, "stderr.log");
      const command = [
        `for i in 1 2 3 4; do`,
        `  while [ ! -f "go_$i" ]; do sleep 0.05; done`,
        `  "${FX_BIN}" mcp call ${TOOL_NAME} "{\\"text\\":\\"b1-$i\\"}" > "out_$i.json" 2> "err_$i.txt"`,
        `  echo "$?" > "exit_$i.txt"`,
        `done`,
        `echo "B1_CMD_DONE"`,
      ].join("\n");

      let runResult: Record<string, unknown> = {};
      let interact1Result: Record<string, unknown> = {};
      let interact2Result: Record<string, unknown> = {};
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 60_000 }),
        async (body: string) => {
          runResult = JSON.parse(toolResultText(body, "run_call"));
          writeFileSync(join(root.workspace, "go_2"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 15_000);
          return fakeGatewayToolCall("interact_1", "shell", {
            action: "interact",
            session_id: runResult.session_id,
            yield_time_ms: 60_000,
          });
        },
        async (body: string) => {
          interact1Result = JSON.parse(toolResultText(body, "interact_1"));
          writeFileSync(join(root.workspace, "go_3"), "");
          await waitForFileCount(root.traceLogPath, WAITING_CALL_TRACE, 2, 15_000);
          return fakeGatewayToolCall("interact_2", "shell", {
            action: "interact",
            session_id: runResult.session_id,
            yield_time_ms: 60_000,
          });
        },
        (body: string) => {
          interact2Result = JSON.parse(toolResultText(body, "interact_2"));
          return fakeGatewayFinalText("B1_TWICE_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 45,
        stderrPath,
        env: attackEnv(root, activeGateway),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Run B1 loop.");

      writeFileSync(join(root.workspace, "go_1"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_1.txt"), 20_000)).toBe("0");
      await tui.sendText("Steer one.");

      expect(await waitForFilePresent(join(root.workspace, "exit_2.txt"), 20_000)).toBe("0");
      await tui.sendText("Steer two.");

      expect(await waitForFilePresent(join(root.workspace, "exit_3.txt"), 20_000)).toBe("0");
      writeFileSync(join(root.workspace, "go_4"), "");
      expect(await waitForFilePresent(join(root.workspace, "exit_4.txt"), 20_000)).toBe("0");

      await tui.waitForPane((pane) => pane.includes("B1_TWICE_DONE") && turnSettled(pane), 30_000);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(10_000)).toBe(true);
      tui = null;

      const calls = toolCalls(root).map((c) => c.message.params?.arguments?.text);
      const traces = traceLines(root);
      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);

      console.log("B1_EVIDENCE", JSON.stringify({
        runState: runResult.state,
        interact1State: interact1Result.state,
        interact2State: interact2Result.state,
        calls,
        waitTraces: traces.filter((l) => l.includes(WAITING_CALL_TRACE)),
        leftSockets,
        leftProcs,
        sessions,
        stderr: readFileSync(stderrPath, "utf8"),
      }));

      expect(calls).toEqual(["b1-1", "b1-2", "b1-3", "b1-4"]);
      expect(interact1Result.state).toBe("running");
      expect(typeof interact1Result.steering_notice).toBe("string");
      expect(typeof interact1Result.mcp_call_notice).toBe("string");
      expect(interact2Result.state).toBe("completed");
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBe(1);
      expect(savedText(root.home, sessions[0]!)).toContain("B1_TWICE_DONE");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    120_000,
  );

  test(
    "B2: interact on a different session while this command's call waits; waiting call must not run and exits 3 at limit",
    async () => {
      const root = attackRoot("b2");
      const cmdA = `while [ ! -f go_a ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"from-A"}' > a.json 2> a.err; echo $? > a.code`;
      const cmdB = `while [ ! -f go_b ]; do sleep 0.05; done; echo "B_DONE"`;
      let runAResult: Record<string, unknown> = {};
      let runBResult: Record<string, unknown> = {};
      let interactBResult: Record<string, unknown> = {};
      let aCode = "";

      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_a", "shell", { action: "run", command: cmdA, yield_time_ms: 1000 }),
        (body: string) => {
          runAResult = JSON.parse(toolResultText(body, "run_a"));
          return fakeGatewayToolCall("run_b", "shell", { action: "run", command: cmdB, yield_time_ms: 1000 });
        },
        async (body: string) => {
          runBResult = JSON.parse(toolResultText(body, "run_b"));
          writeFileSync(join(root.workspace, "go_a"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          return fakeGatewayToolCall("interact_b", "shell", {
            action: "interact",
            session_id: runBResult.session_id,
            yield_time_ms: 10_000,
          });
        },
        (body: string) => {
          interactBResult = JSON.parse(toolResultText(body, "interact_b"));
          return fakeGatewayFinalText("B2_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      // Release go_b only after a.code is written (so interact on B stays open while A times out at 2000ms).
      const watcher = (async () => {
        aCode = await waitForFilePresent(join(root.workspace, "a.code"), 15_000);
        writeFileSync(join(root.workspace, "go_b"), "");
      })();

      const result = await runFx(["ask", "--json", "--full-access", "Run B2."], {
        cwd: root.workspace,
        env: attackEnv(root, activeGateway, { FX_TEST_MCP_CALL_FOLLOW_WAIT_MS: "2000" }),
        timeoutMs: 60_000,
      });
      await watcher;

      const calls = toolCalls(root);
      const traces = traceLines(root);
      const aErr = readFileSync(join(root.workspace, "a.err"), "utf8");
      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);

      console.log("B2_EVIDENCE", JSON.stringify({
        fxExit: result.code,
        aCode,
        aErr: aErr.trim(),
        interactBState: interactBResult.state,
        callsCount: calls.length,
        traces: traces.filter((l) => l.includes("waits for") || l.includes("not_followed")),
        leftSockets,
        leftProcs,
        sessions,
      }));

      expect(result.code).toBe(0);
      expect(aCode).toBe("3");
      expect(aErr).toContain("interact");
      expect(calls).toHaveLength(0);
      expect(interactBResult.output_delta).toContain("B_DONE");
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBe(1);
    },
    60_000,
  );

  test(
    "B3: Two commands, each with a waiting call: each interact runs only its own command's call",
    async () => {
      const root = attackRoot("b3");
      const cmdA = `while [ ! -f go_a ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"from-A"}' > a.json 2> a.err; echo $? > a.code`;
      const cmdB = `while [ ! -f go_b ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"from-B"}' > b.json 2> b.err; echo $? > b.code`;
      let runAResult: Record<string, unknown> = {};
      let runBResult: Record<string, unknown> = {};
      let callsAfterB: string[] = [];
      let aCodeBeforeBInteract = false;

      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_a", "shell", { action: "run", command: cmdA, yield_time_ms: 1000 }),
        (body: string) => {
          runAResult = JSON.parse(toolResultText(body, "run_a"));
          return fakeGatewayToolCall("run_b", "shell", { action: "run", command: cmdB, yield_time_ms: 1000 });
        },
        async (body: string) => {
          runBResult = JSON.parse(toolResultText(body, "run_b"));
          writeFileSync(join(root.workspace, "go_a"), "");
          writeFileSync(join(root.workspace, "go_b"), "");
          await waitForFileCount(root.traceLogPath, WAITING_CALL_TRACE, 2, 10_000);
          return fakeGatewayToolCall("interact_b", "shell", {
            action: "interact",
            session_id: runBResult.session_id,
            yield_time_ms: 30_000,
          });
        },
        () => {
          callsAfterB = toolCalls(root).map((c) => c.message.params?.arguments?.text);
          aCodeBeforeBInteract = existsSync(join(root.workspace, "a.code"));
          return fakeGatewayToolCall("interact_a", "shell", {
            action: "interact",
            session_id: runAResult.session_id,
            yield_time_ms: 30_000,
          });
        },
        () => fakeGatewayFinalText("B3_DONE"),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["ask", "--json", "--full-access", "Run B3."], {
        cwd: root.workspace,
        env: attackEnv(root, activeGateway),
        timeoutMs: 60_000,
      });

      const allCalls = toolCalls(root).map((c) => c.message.params?.arguments?.text);
      const traces = traceLines(root);
      const aCode = readFileSync(join(root.workspace, "a.code"), "utf8").trim();
      const bCode = readFileSync(join(root.workspace, "b.code"), "utf8").trim();
      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);

      console.log("B3_EVIDENCE", JSON.stringify({
        fxExit: result.code,
        callsAfterB,
        aCodeBeforeBInteract,
        allCalls,
        aCode,
        bCode,
        waitTraces: traces.filter((l) => l.includes(WAITING_CALL_TRACE)),
        leftSockets,
        leftProcs,
        sessions,
      }));

      expect(result.code).toBe(0);
      expect(callsAfterB).toEqual(["from-B"]);
      expect(aCodeBeforeBInteract).toBe(false);
      expect(allCalls).toEqual(["from-B", "from-A"]);
      expect(aCode).toBe("0");
      expect(bCode).toBe("0");
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBe(1);
    },
    60_000,
  );

  test(
    "B4: kill -9 fx while a call waits; check leftover processes, socket dir, and --resume last",
    async () => {
      const root = attackRoot("b4");
      // Command writes its own PID, waits for go, starts fx mcp call in foreground (so cmd waits on it),
      // then writes call.code and stays alive briefly in sleep so we can see if command process dies with fx.
      const command = [
        `echo $$ > cmd.pid`,
        `while [ ! -f go ]; do sleep 0.05; done`,
        `"${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b4"}' > out.json 2> err.txt &`,
        `echo $! > client.pid`,
        `wait $!; echo $? > call.code`,
        `while [ ! -f release_cmd ]; do sleep 0.1; done`,
      ].join("\n");

      let releaseSecondGateway!: () => void;
      const holdSecondGateway = new Promise<void>((r) => { releaseSecondGateway = r; });
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 1000 }),
        async () => {
          writeFileSync(join(root.workspace, "go"), "");
          await holdSecondGateway;
          return fakeGatewayFinalText("B4_SHOULD_NOT_FINISH");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const env = fxChildEnv(attackEnv(root, activeGateway));
      const proc = spawn(FX_BIN, ["ask", "--json", "--full-access", "Run B4."], {
        cwd: root.workspace,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });

      const cmdPid = Number(await waitForFilePresent(join(root.workspace, "cmd.pid"), 15_000));
      await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 15_000);
      const clientPid = Number(await waitForFilePresent(join(root.workspace, "client.pid"), 10_000));

      expect(toolCalls(root)).toHaveLength(0);
      expect(processAlive(cmdPid)).toBe(true);
      expect(processAlive(clientPid)).toBe(true);

      // SIGKILL fx while call is waiting!
      proc.kill("SIGKILL");
      releaseSecondGateway();
      const killStatus = await new Promise<{ code: number | null; signal: string | null }>((resolve) => {
        proc.on("close", (code, signal) => resolve({ code, signal }));
      });

      // Wait for client.pid to notice closed socket (EOF).
      await waitForCondition("client.pid to exit after fx SIGKILL", () => !processAlive(clientPid), 5_000);
      const callCode = await waitForFilePresent(join(root.workspace, "call.code"), 5_000);
      // Give kernel/process group a brief moment to see whether cmdPid stayed alive or died.
      await Bun.sleep(200);
      const cmdStillAliveAfterKill = processAlive(cmdPid);
      if (cmdStillAliveAfterKill) {
        writeFileSync(join(root.workspace, "release_cmd"), "");
        await waitForCondition("cmd.pid cleanup", () => !processAlive(cmdPid), 5_000).catch(() => {
          try { process.kill(cmdPid, "SIGKILL"); } catch {}
        });
      }

      const socketsAfterKill = socketDirsLeft(root);
      const sessionsBeforeResume = savedSessionIds(root.home);

      // Resume the session with --resume last
      const resumeGateway = startFakeGateway([
        fakeGatewayFinalText("B4_RESUMED_OK"),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      const resumeResult = await runFx(["ask", "--json", "--full-access", "--resume", "last", "Resume check."], {
        cwd: root.workspace,
        env: attackEnv(root, resumeGateway),
        timeoutMs: 30_000,
      });

      const callsAfterResume = toolCalls(root);
      const callErr = readFileSync(join(root.workspace, "err.txt"), "utf8");

      console.log("B4_EVIDENCE", JSON.stringify({
        killStatus,
        callCode,
        callErr: callErr.trim(),
        clientAliveAfterFxKill: processAlive(clientPid),
        cmdStillAliveAfterKill,
        socketsAfterKill,
        sessionsBeforeResume,
        resumeExit: resumeResult.code,
        resumeStdout: resumeResult.stdout.trim(),
        callsAfterResumeCount: callsAfterResume.length,
        waitTraces: traceLines(root).filter((l) => l.includes(WAITING_CALL_TRACE)),
      }));

      expect(killStatus.signal).toBe("SIGKILL");
      expect(callsAfterResume).toHaveLength(0);
      expect(processAlive(clientPid)).toBe(false);
      expect(sessionsBeforeResume.length).toBe(1);
      expect(resumeResult.code).toBe(0);
      expect(JSON.parse(resumeResult.stdout).output).toContain("B4_RESUMED_OK");
    },
    60_000,
  );

  test(
    "B5: shell stop on the command while its call waits: the call never runs",
    async () => {
      const root = attackRoot("b5");
      const command = `echo $$ > cmd.pid; while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b5"}' > out.json 2> err.txt; echo $? > call.code`;
      let runResult: Record<string, unknown> = {};
      let stopResult: Record<string, unknown> = {};

      const activeGateway = startFakeGateway([
        fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 1000 }),
        async (body: string) => {
          runResult = JSON.parse(toolResultText(body, "run_call"));
          writeFileSync(join(root.workspace, "go"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          return fakeGatewayToolCall("stop_call", "shell", {
            action: "stop",
            session_id: runResult.session_id,
          });
        },
        (body: string) => {
          stopResult = JSON.parse(toolResultText(body, "stop_call"));
          return fakeGatewayFinalText("B5_STOPPED_DONE");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const result = await runFx(["ask", "--json", "--full-access", "Run B5."], {
        cwd: root.workspace,
        env: attackEnv(root, activeGateway),
        timeoutMs: 60_000,
      });

      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);
      const traces = traceLines(root);

      console.log("B5_EVIDENCE", JSON.stringify({
        fxExit: result.code,
        stopState: stopResult.state,
        callsCount: toolCalls(root).length,
        callCodeExists: existsSync(join(root.workspace, "call.code")),
        callErr: existsSync(join(root.workspace, "err.txt")) ? readFileSync(join(root.workspace, "err.txt"), "utf8").trim() : "",
        traces: traces.filter((l) => l.includes("waits for") || l.includes("refused") || l.includes("closed")),
        leftSockets,
        leftProcs,
        sessions,
      }));

      expect(result.code).toBe(0);
      expect(stopResult.state).toBe("stopped");
      expect(toolCalls(root)).toHaveLength(0);
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBe(1);
    },
    60_000,
  );

  test(
    "B6: a subagent's command waits; the subagent ends: the call never runs",
    async () => {
      const root = attackRoot("b6");
      const childCommand = `echo $$ > cmd.pid; while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b6"}' > out.json 2> err.txt & echo $! > client.pid; wait $!; echo $? > call.code`;
      let childRunResult: Record<string, unknown> = {};
      let cmdPid = 0;
      let clientPid = 0;

      const activeGateway = startDynamicFakeGateway(async (body) => {
        if (body.includes("Subagent report")) {
          // Check right when subagent has ended (and before parent finishes):
          // Is the subagent's command still alive and the bridge still open?
          const cmdAliveAtReport = cmdPid > 0 ? processAlive(cmdPid) : null;
          const tracesAtReport = traceLines(root);
          const callCode = await waitForFilePresent(join(root.workspace, "call.code"), 10_000);
          console.log("B6_AT_REPORT", JSON.stringify({ cmdAliveAtReport, tracesAtReport, callCode }));
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
          // Subagent ends its turn without calling interact!
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
        env: attackEnv(root, activeGateway, { FX_TEST_MCP_CALL_FOLLOW_WAIT_MS: "2000" }),
        timeoutMs: 60_000,
      });

      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);
      const traces = traceLines(root);

      console.log("B6_EVIDENCE", JSON.stringify({
        fxExit: result.code,
        childRunState: childRunResult.state,
        cmdPidAlive: cmdPid > 0 ? processAlive(cmdPid) : null,
        clientPidAlive: clientPid > 0 ? processAlive(clientPid) : null,
        callCodeExists: existsSync(join(root.workspace, "call.code")),
        callCode: existsSync(join(root.workspace, "call.code")) ? readFileSync(join(root.workspace, "call.code"), "utf8").trim() : null,
        callErr: existsSync(join(root.workspace, "err.txt")) ? readFileSync(join(root.workspace, "err.txt"), "utf8").trim() : "",
        callsCount: toolCalls(root).length,
        traces,
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
    "B6b repro: parent calling interact on ended subagent's shell-1 can run subagent's waiting call with parent's authority",
    async () => {
      const root = attackRoot("b6b");
      mkdirSync(join(root.home, ".fx", "agents", "limited"), { recursive: true });
      writeFileSync(
        join(root.home, ".fx", "agents", "limited", "profile.json"),
        JSON.stringify({ description: "No MCP servers", mcp_servers: [] }),
      );
      const childCommand = `while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"escalated"}' > out.json 2> err.txt; echo $? > call.code`;
      let childSessionId = "";
      let interactOut = "";

      const activeGateway = startDynamicFakeGateway(async (body) => {
        if (body.includes('"toolCallId":"parent_interact"')) {
          interactOut = JSON.parse(toolResultText(body, "parent_interact")).output_delta;
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
        env: attackEnv(root, activeGateway),
        timeoutMs: 60_000,
      });

      const calls = toolCalls(root).map((c) => c.message.params?.arguments?.text);
      const callCode = existsSync(join(root.workspace, "call.code")) ? readFileSync(join(root.workspace, "call.code"), "utf8").trim() : null;
      console.log("B6B_REPRO_EVIDENCE", JSON.stringify({ fxExit: result.code, childSessionId, callCode, interactOut, calls }));
      expect(result.code).toBe(0);
    },
    60_000,
  );

  test.skipIf(!tmuxAvailable())(
    "B7: Esc while a call waits and no shell call follows: call must not run until interact, and exits 3 at limit",
    async () => {
      const root = attackRoot("b7");
      const stderrPath = join(root.root, "stderr.log");
      const command = [
        `echo $$ > cmd.pid`,
        `while [ ! -f go ]; do sleep 0.05; done`,
        `"${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b7"}' > out.json 2> err.txt`,
        `echo $? > call.code`,
        `echo "AFTER_LIMIT" > after.txt`,
      ].join("\n");

      let releaseModelThink!: () => void;
      const modelThinkHeld = new Promise<void>((r) => { releaseModelThink = r; });

      const activeGateway = startDynamicFakeGateway(async (body) => {
        if (body.includes('"toolCallId":"run_call"')) {
          writeFileSync(join(root.workspace, "go"), "");
          await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 10_000);
          // Hold the model response open while the call waits and no shell call follows,
          // so the user can press Esc right then!
          await modelThinkHeld;
          return fakeGatewayFinalText("B7_DONE");
        }
        return fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 1000 });
      }, {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      tui = await TmuxSession.create({
        isolated: true,
        cwd: root.workspace,
        width: 140,
        height: 40,
        stderrPath,
        env: attackEnv(root, activeGateway, { FX_TEST_MCP_CALL_FOLLOW_WAIT_MS: "2000" }),
      });

      await tui.waitForComposer(15_000);
      await tui.sendText("Run B7.");
      await waitForFileText(root.traceLogPath, WAITING_CALL_TRACE, 15_000);
      const cmdPid = Number(await waitForFilePresent(join(root.workspace, "cmd.pid"), 10_000));

      // Press Esc while call waits and no shell call follows.
      await tui.sendInterruptEscapePair(10_000);
      await tui.waitForStableComposer(10_000);
      releaseModelThink();

      const cmdAliveRightAfterEsc = processAlive(cmdPid);
      const callCode = await waitForFilePresent(join(root.workspace, "call.code"), 10_000);
      const afterTxt = await waitForFilePresent(join(root.workspace, "after.txt"), 10_000);
      const callErr = readFileSync(join(root.workspace, "err.txt"), "utf8");

      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(10_000)).toBe(true);
      tui = null;

      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);
      const traces = traceLines(root);

      console.log("B7_EVIDENCE", JSON.stringify({
        cmdAliveRightAfterEsc,
        callCode,
        afterTxt,
        callErr: callErr.trim(),
        callsCount: toolCalls(root).length,
        traces: traces.filter((l) => l.includes("waits for") || l.includes("not_followed")),
        leftSockets,
        leftProcs,
        sessions,
        stderr: readFileSync(stderrPath, "utf8"),
      }));

      expect(callCode).toBe("3");
      expect(callErr).toContain("interact");
      expect(afterTxt).toBe("AFTER_LIMIT");
      expect(toolCalls(root)).toHaveLength(0);
      expect(leftSockets).toEqual([]);
      expect(leftProcs).toEqual([]);
      expect(sessions.length).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    60_000,
  );

  test(
    "B8: a call that is running (served by an interact) when fx exits: clean exit, stderr has no panic or leak",
    async () => {
      const root = attackRoot("b8", "stall_operation", { FX_MCP_OPERATION_TIMEOUT_MS: "30000" });
      const command = `echo $$ > cmd.pid; while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"b8"}' > out.json 2> err.txt; echo $? > call.code`;
      let runResult: Record<string, unknown> = {};

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
        () => fakeGatewayFinalText("B8_UNREACHED"),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      gateway = activeGateway;

      const env = fxChildEnv(attackEnv(root, activeGateway));
      const proc = spawn(FX_BIN, ["ask", "--json", "--full-access", "Run B8."], {
        cwd: root.workspace,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stderr = "";
      proc.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });

      // Wait until the call is actively running at the MCP server (served by interact!).
      await waitForCondition("MCP tools/call reached server", () => toolCalls(root).length === 1, 20_000);

      // Send SIGTERM so fx exits cleanly while interact is serving the active call!
      proc.kill("SIGTERM");
      const exitInfo = await new Promise<{ code: number | null; signal: string | null }>((resolve) => {
        proc.on("close", (code, signal) => resolve({ code, signal }));
      });

      await waitForCondition("processes cleanup", () => matchingProcesses(root.workspace).length === 0, 5_000);
      const leftSockets = socketDirsLeft(root);
      const leftProcs = matchingProcesses(root.workspace);
      const sessions = savedSessionIds(root.home);
      const traces = traceLines(root);

      console.log("B8_EVIDENCE", JSON.stringify({
        exitInfo,
        stderr: stderr.trim(),
        callsCount: toolCalls(root).length,
        traces,
        leftSockets,
        leftProcs,
        sessions,
      }));

      expect(toolCalls(root)).toHaveLength(1);
      expect(stderr).not.toMatch(/panic|leak|error\./i);
      expect(leftProcs).toEqual([]);
      expect(leftSockets).toEqual([]);
      expect(sessions.length).toBe(1);
    },
    60_000,
  );
});
