// Spec-to-code driver for tests/tla/acp_eof/AcpEof.tla (design-a.cfg).
//
// Runs TLC on design-a.cfg with `-dump dot,actionlabels graph`, extracts every
// reachable close/cancel/outbound transition class from graph.dot, drives the
// built `zig-out/bin/fx acp` binary along every reachable path using a fake
// gateway and the FX_TEST_ACP_PERMISSION_* seam, and fails if any model
// transition class is neither executed nor listed in OUT_OF_REACH.
import { expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  watch,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { parseValue } from "../graph.mjs";
import { artifacts, binary, targetHelpers, testEnvironment } from "../lib/context";
import { runTlc, TLA_ROOT } from "../lib/tlc";

const SPEC_DIR = join(TLA_ROOT, "acp_eof");
const EXIT_DEADLINE_MS = 5_000;
const STEP_TIMEOUT_MS = 10_000;

const helpers = await targetHelpers();

type AcpProc = {
  proc: ChildProcess;
  send: (msg: object) => void;
  endStdin: () => void;
  rawLines: any[];
  waitLine: (pred: (msg: any) => boolean, timeoutMs?: number) => Promise<any>;
  waitExit: (timeoutMs?: number) => Promise<{ code: number | null; signal: string | null }>;
  stderr: () => string;
  kill: () => void;
};

function spawnAcp(cwd: string, env: Record<string, string>): AcpProc {
  const proc = spawn(binary, ["acp"], {
    cwd,
    env: testEnvironment(env),
    stdio: ["pipe", "pipe", "pipe"],
  });
  let buf = "";
  const rawLines: any[] = [];
  const waiters: Array<{ pred: (msg: any) => boolean; resolve: (msg: any) => void; reject: (err: Error) => void }> = [];
  const stderrChunks: Buffer[] = [];
  let exitInfo: { code: number | null; signal: string | null } | null = null;
  const exitWaiters: Array<(info: { code: number | null; signal: string | null }) => void> = [];

  proc.stdout!.on("data", (chunk: Buffer) => {
    buf += chunk.toString("utf8");
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const part of parts) {
      if (!part.trim()) continue;
      const parsed = JSON.parse(part);
      rawLines.push(parsed);
      for (let i = waiters.length - 1; i >= 0; i -= 1) {
        if (waiters[i]!.pred(parsed)) {
          const waiter = waiters.splice(i, 1)[0]!;
          waiter.resolve(parsed);
        }
      }
    }
  });
  proc.stderr!.on("data", (chunk: Buffer) => stderrChunks.push(chunk));
  proc.on("close", (code, signal) => {
    exitInfo = { code, signal };
    for (const waiter of exitWaiters.splice(0)) waiter(exitInfo);
    for (const waiter of waiters.splice(0)) {
      waiter.reject(new Error(`fx acp closed before matching line (code=${code}, signal=${signal})`));
    }
  });

  return {
    proc,
    rawLines,
    send(msg: object) {
      proc.stdin!.write(`${JSON.stringify(msg)}\n`);
    },
    endStdin() {
      proc.stdin!.end();
    },
    waitLine(pred, timeoutMs = STEP_TIMEOUT_MS) {
      const existing = rawLines.find(pred);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const signal = AbortSignal.timeout(timeoutMs);
        const onAbort = () => {
          const idx = waiters.findIndex((w) => w.resolve === onMatch);
          if (idx >= 0) waiters.splice(idx, 1);
          reject(new Error(`Timed out waiting for ACP message after ${timeoutMs}ms`));
        };
        const onMatch = (msg: any) => {
          signal.removeEventListener("abort", onAbort);
          resolve(msg);
        };
        const onFail = (err: Error) => {
          signal.removeEventListener("abort", onAbort);
          reject(err);
        };
        signal.addEventListener("abort", onAbort, { once: true });
        waiters.push({ pred, resolve: onMatch, reject: onFail });
      });
    },
    waitExit(timeoutMs = EXIT_DEADLINE_MS) {
      if (exitInfo) return Promise.resolve(exitInfo);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          proc.kill("SIGKILL");
          reject(new Error(`fx acp did not exit within ${timeoutMs}ms`));
        }, timeoutMs);
        exitWaiters.push((info) => {
          clearTimeout(timer);
          resolve(info);
        });
      });
    },
    stderr() {
      return Buffer.concat(stderrChunks).toString("utf8");
    },
    kill() {
      if (!exitInfo) proc.kill("SIGKILL");
    },
  };
}

async function waitForFile(path: string, timeoutMs = STEP_TIMEOUT_MS): Promise<void> {
  if (existsSync(path)) return;
  const dir = dirname(path);
  const base = basename(path);
  await new Promise<void>((resolve, reject) => {
    const signal = AbortSignal.timeout(timeoutMs);
    const onAbort = () => {
      watcher.close();
      reject(new Error(`Timed out waiting for marker ${path}`));
    };
    const watcher = watch(dir, (_event, filename) => {
      if ((filename === null || filename === base) && existsSync(path)) {
        signal.removeEventListener("abort", onAbort);
        watcher.close();
        resolve();
      }
    });
    signal.addEventListener("abort", onAbort, { once: true });
    if (existsSync(path)) {
      signal.removeEventListener("abort", onAbort);
      watcher.close();
      resolve();
    }
  });
}

function makeGatewayEnv(
  home: string,
  gateway: { baseUrl: string; chatUrl: string },
  extra: Record<string, string> = {},
): Record<string, string> {
  return helpers.localCreditsEnv({
    HOME: home,
    AI_GATEWAY_API_KEY: "synthetic-acp-eof-driver",
    VERCEL_OIDC_TOKEN: "",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
    NO_COLOR: "1",
    ...extra,
  });
}

async function startAskSession(acp: AcpProc, cwd: string): Promise<string> {
  acp.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
  await acp.waitLine((m) => m.id === 1);
  acp.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd, mcpServers: [] } });
  const created = await acp.waitLine((m) => m.id === 2);
  const sessionId = created.result.sessionId as string;
  acp.send({ jsonrpc: "2.0", id: 3, method: "session/set_mode", params: { sessionId, modeId: "ask" } });
  await acp.waitLine((m) => m.id === 3);
  return sessionId;
}

type ScenarioId =
  | "eof_idle"
  | "eof_before_ask"
  | "eof_decide_to_insert"
  | "eof_while_waiting"
  | "eof_after_finished_done"
  | "eof_after_finished_cancelled"
  | "close_idle"
  | "close_before_ask"
  | "close_decide_to_insert"
  | "close_while_waiting"
  | "cancel_before_ask_then_prompt"
  | "cancel_decide_to_insert_then_prompt"
  | "cancel_while_waiting_then_prompt";

const SCENARIO_FOR_KEY: Record<string, ScenarioId> = {
  "CleanShutdown|reading|idle|none|none|->|eof_cancelling|idle|none|closed=false|cancel=false": "eof_idle",
  "EofReadLoop|reading|idle|none|none|->|eof_cancelling|idle|none|closed=false|cancel=false": "eof_idle",
  "EofReadLoop|reading|running|none|none|->|eof_cancelling|running|none|closed=false|cancel=false": "eof_before_ask",
  "EofReadLoop|reading|decided_to_ask|permission|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=false": "eof_decide_to_insert",
  "BeginOutbound|eof_reaping|decided_to_ask|permission|none|->|eof_reaping|finished_cancelled|none|closed=true|cancel=true": "eof_decide_to_insert",
  "EofReadLoop|reading|waiting|permission|open|->|eof_cancelling|waiting|open|closed=false|cancel=false": "eof_while_waiting",
  "ClientAnswer|reading|waiting|permission|open|->|reading|waiting|answered|closed=false|cancel=false": "eof_after_finished_done",
  "BeginOutbound|reading|decided_to_ask|permission|none|->|reading|waiting|open|closed=false|cancel=false": "eof_after_finished_done",
  "CleanShutdown|reading|finished_done|none|none|->|eof_cancelling|finished_done|none|closed=false|cancel=false": "eof_after_finished_done",
  "EofReadLoop|reading|finished_done|none|none|->|eof_cancelling|finished_done|none|closed=false|cancel=false": "eof_after_finished_done",
  "CleanShutdown|reading|finished_cancelled|none|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=false": "eof_after_finished_cancelled",
  "EofReadLoop|reading|finished_cancelled|none|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=false": "eof_after_finished_cancelled",
  "SessionCloseOrLoadStart|reading|idle|none|none|->|close_reap|idle|none|closed=false|cancel=false": "close_idle",
  "SessionCloseOrLoadStart|reading|finished_done|none|none|->|close_reap|finished_done|none|closed=false|cancel=false": "close_idle",
  "SessionCloseOrLoadStart|reading|finished_cancelled|none|none|->|close_reap|finished_cancelled|none|closed=false|cancel=false": "close_idle",
  "SessionCloseOrLoadStart|reading|running|none|none|->|close_reap|running|none|closed=false|cancel=true": "close_before_ask",
  "SessionCloseOrLoadStart|reading|decided_to_ask|permission|none|->|close_reap|decided_to_ask|none|closed=false|cancel=true": "close_decide_to_insert",
  "BeginOutbound|close_reap|decided_to_ask|permission|none|->|close_reap|finished_cancelled|none|closed=false|cancel=true": "close_decide_to_insert",
  "SessionCloseOrLoadStart|reading|waiting|permission|open|->|close_reap|waiting|cancelled|closed=false|cancel=true": "close_while_waiting",
  "SessionCancel|reading|running|none|none|->|reading|running|none|closed=false|cancel=true": "cancel_before_ask_then_prompt",
  "SessionCancel|reading|decided_to_ask|permission|none|->|reading|decided_to_ask|none|closed=false|cancel=true": "cancel_decide_to_insert_then_prompt",
  "BeginOutbound|reading|decided_to_ask|permission|none|->|reading|finished_cancelled|none|closed=false|cancel=true": "cancel_decide_to_insert_then_prompt",
  "SessionCancel|reading|waiting|permission|open|->|reading|waiting|cancelled|closed=false|cancel=true": "cancel_while_waiting_then_prompt",
};

const OUT_OF_REACH: Record<string, string> = {
  // libfx outbound kinds (host_tool, journal) only run in libfx hosts; native `fx acp` rejects libfx methods (`server.zig:1673`)
  // and are pinned by `callHostTool` (`prompt.zig:923`), `flushJournal` (`prompt.zig:3335`), and `server.zig` unit tests.
  "BeginOutbound|close_reap|decided_to_ask|host_tool|none|->|close_reap|finished_cancelled|none|closed=false|cancel=true": "libfx host_tool only runs under libfx; pinned by callHostTool + server.zig unit tests",
  "BeginOutbound|close_reap|decided_to_ask|journal|none|->|close_reap|finished_cancelled|none|closed=false|cancel=true": "libfx journal only runs under libfx; pinned by flushJournal + server.zig unit tests",
  "BeginOutbound|eof_cancelling|decided_to_ask|host_tool|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=true": "libfx host_tool + single-thread readLine->closeOutboundOnEof gap",
  "BeginOutbound|eof_cancelling|decided_to_ask|host_tool|none|->|eof_cancelling|waiting|open|closed=false|cancel=false": "libfx host_tool + single-thread readLine->closeOutboundOnEof gap",
  "BeginOutbound|eof_cancelling|decided_to_ask|journal|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=true": "libfx journal + single-thread readLine->closeOutboundOnEof gap",
  "BeginOutbound|eof_cancelling|decided_to_ask|journal|none|->|eof_cancelling|waiting|open|closed=false|cancel=false": "libfx journal + single-thread readLine->closeOutboundOnEof gap",
  "BeginOutbound|eof_reaping|decided_to_ask|host_tool|none|->|eof_reaping|finished_cancelled|none|closed=true|cancel=true": "libfx host_tool only runs under libfx; pinned by callHostTool + server.zig unit tests",
  "BeginOutbound|eof_reaping|decided_to_ask|journal|none|->|eof_reaping|finished_cancelled|none|closed=true|cancel=true": "libfx journal only runs under libfx; pinned by flushJournal + server.zig unit tests",
  "BeginOutbound|reading|decided_to_ask|host_tool|none|->|reading|finished_cancelled|none|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "BeginOutbound|reading|decided_to_ask|host_tool|none|->|reading|waiting|open|closed=false|cancel=false": "libfx host_tool only runs under libfx",
  "BeginOutbound|reading|decided_to_ask|journal|none|->|reading|finished_cancelled|none|closed=false|cancel=true": "libfx journal only runs under libfx",
  "BeginOutbound|reading|decided_to_ask|journal|none|->|reading|waiting|open|closed=false|cancel=false": "libfx journal only runs under libfx",
  "ClientAnswer|reading|waiting|host_tool|open|->|reading|waiting|answered|closed=false|cancel=false": "libfx host_tool only runs under libfx",
  "ClientAnswer|reading|waiting|journal|open|->|reading|waiting|answered|closed=false|cancel=false": "libfx journal only runs under libfx",
  "EofReadLoop|reading|decided_to_ask|host_tool|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=false": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|decided_to_ask|host_tool|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|decided_to_ask|journal|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=false": "libfx journal only runs under libfx",
  "EofReadLoop|reading|decided_to_ask|journal|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=true": "libfx journal only runs under libfx",
  "EofReadLoop|reading|waiting|host_tool|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=false": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|waiting|host_tool|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|waiting|host_tool|cancelled|->|eof_cancelling|waiting|cancelled|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|waiting|host_tool|open|->|eof_cancelling|waiting|open|closed=false|cancel=false": "libfx host_tool only runs under libfx",
  "EofReadLoop|reading|waiting|journal|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=false": "libfx journal only runs under libfx",
  "EofReadLoop|reading|waiting|journal|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=true": "libfx journal only runs under libfx",
  "EofReadLoop|reading|waiting|journal|cancelled|->|eof_cancelling|waiting|cancelled|closed=false|cancel=true": "libfx journal only runs under libfx",
  "EofReadLoop|reading|waiting|journal|open|->|eof_cancelling|waiting|open|closed=false|cancel=false": "libfx journal only runs under libfx",
  "SessionCancel|reading|decided_to_ask|host_tool|none|->|reading|decided_to_ask|none|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCancel|reading|decided_to_ask|journal|none|->|reading|decided_to_ask|none|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCancel|reading|waiting|host_tool|answered|->|reading|waiting|answered|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCancel|reading|waiting|host_tool|cancelled|->|reading|waiting|cancelled|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCancel|reading|waiting|host_tool|open|->|reading|waiting|cancelled|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCancel|reading|waiting|journal|answered|->|reading|waiting|answered|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCancel|reading|waiting|journal|cancelled|->|reading|waiting|cancelled|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCancel|reading|waiting|journal|open|->|reading|waiting|cancelled|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCloseOrLoadStart|reading|decided_to_ask|host_tool|none|->|close_reap|decided_to_ask|none|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCloseOrLoadStart|reading|decided_to_ask|journal|none|->|close_reap|decided_to_ask|none|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|host_tool|answered|->|close_reap|waiting|answered|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|host_tool|cancelled|->|close_reap|waiting|cancelled|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|host_tool|open|->|close_reap|waiting|cancelled|closed=false|cancel=true": "libfx host_tool only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|journal|answered|->|close_reap|waiting|answered|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|journal|cancelled|->|close_reap|waiting|cancelled|closed=false|cancel=true": "libfx journal only runs under libfx",
  "SessionCloseOrLoadStart|reading|waiting|journal|open|->|close_reap|waiting|cancelled|closed=false|cancel=true": "libfx journal only runs under libfx",

  // Transient single-thread / wakeup-window interleavings with no product seam (and no need for one):
  "BeginOutbound|eof_cancelling|decided_to_ask|permission|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=true": "two-instruction window between readLine EOF and closeOutboundOnEof on the main thread",
  "BeginOutbound|eof_cancelling|decided_to_ask|permission|none|->|eof_cancelling|waiting|open|closed=false|cancel=false": "two-instruction window between readLine EOF and closeOutboundOnEof on the main thread",
  "CleanShutdown|reading|finished_cancelled|none|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=true": "session/cancel already finished the prompt before EOF arrived (covered by eof_after_finished_cancelled)",
  "EofReadLoop|reading|decided_to_ask|permission|none|->|eof_cancelling|decided_to_ask|none|closed=false|cancel=true": "EOF arriving immediately after session/cancel while thread is still held",
  "EofReadLoop|reading|finished_cancelled|none|none|->|eof_cancelling|finished_cancelled|none|closed=false|cancel=true": "EOF arriving immediately after session/cancel on a finished turn",
  "EofReadLoop|reading|running|none|none|->|eof_cancelling|running|none|closed=false|cancel=true": "EOF arriving immediately after session/cancel while running",
  "EofReadLoop|reading|waiting|permission|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=false": "transient window between handleClientResponse waking outbound_cond and awaitOutboundResponse returning",
  "EofReadLoop|reading|waiting|permission|answered|->|eof_cancelling|waiting|answered|closed=false|cancel=true": "transient window after handleClientResponse + session/cancel before awaitOutboundResponse returns",
  "EofReadLoop|reading|waiting|permission|cancelled|->|eof_cancelling|waiting|cancelled|closed=false|cancel=true": "transient window after session/cancel before awaitOutboundResponse returns",
  "SessionCancel|reading|finished_cancelled|none|none|->|reading|finished_cancelled|none|closed=false|cancel=false": "no-op session/cancel on an already finished turn (covered by acp.test.ts)",
  "SessionCancel|reading|finished_done|none|none|->|reading|finished_done|none|closed=false|cancel=false": "no-op session/cancel on an already finished turn (covered by acp.test.ts)",
  "SessionCancel|reading|idle|none|none|->|reading|idle|none|closed=false|cancel=false": "no-op session/cancel while idle (covered by acp.test.ts)",
  "SessionCancel|reading|waiting|permission|answered|->|reading|waiting|answered|closed=false|cancel=true": "transient window between client answer and awaitOutboundResponse wakeup",
  "SessionCancel|reading|waiting|permission|cancelled|->|reading|waiting|cancelled|closed=false|cancel=true": "duplicate session/cancel while awaitOutboundResponse wakes",
  "SessionCloseOrLoadStart|reading|waiting|permission|answered|->|close_reap|waiting|answered|closed=false|cancel=true": "transient window between client answer and awaitOutboundResponse wakeup",
  "SessionCloseOrLoadStart|reading|waiting|permission|cancelled|->|close_reap|waiting|cancelled|closed=false|cancel=true": "session/close after session/cancel before awaitOutboundResponse returns",
};

async function runScenario(scenario: ScenarioId): Promise<void> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-tla-acp-eof-${scenario}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");

  const permissionReady = join(root, "permission.ready");
  const reapReady = join(root, "permission-reap.ready");
  const release = join(root, "permission.release");
  const releaseNow = () => {
    if (!existsSync(release)) writeFileSync(release, "release\n");
  };

  let gatewaySignalResolve: (() => void) | null = null;
  const gatewayHit = new Promise<void>((resolve) => {
    gatewaySignalResolve = resolve;
  });

  const targetBefore = join(workspace, "before.txt");
  const targetAfter = join(workspace, "after.txt");

  const gateway = helpers.startDynamicFakeGateway((body: string) => {
    if (body.includes("SERVE_AFTER")) {
      if (!body.includes("after_perm")) {
        return helpers.fakeGatewayToolCall("after_perm", "write_file", { path: targetAfter, content: "AFTER\n" });
      }
      return helpers.fakeGatewayFinalText("served after");
    }
    if (body.includes("HOLD_BEFORE_ASK")) {
      gatewaySignalResolve?.();
      return new Promise<Response>(() => {});
    }
    if (body.includes("ASK_FILE")) {
      if (body.includes("before_perm")) {
        return helpers.fakeGatewayFinalText("done before");
      }
      return helpers.fakeGatewayToolCall("before_perm", "write_file", { path: targetBefore, content: "BEFORE\n" });
    }
    return helpers.fakeGatewayFinalText("ok");
  });

  const useSeam =
    scenario === "eof_decide_to_insert" ||
    scenario === "close_decide_to_insert" ||
    scenario === "cancel_decide_to_insert_then_prompt";
  const seamEnv = useSeam
    ? {
        FX_TEST_ACP_PERMISSION_READY: permissionReady,
        FX_TEST_ACP_PROMPT_REAP_READY: reapReady,
        FX_TEST_ACP_PERMISSION_RELEASE: release,
      }
    : {};

  const acp = spawnAcp(workspace, makeGatewayEnv(home, gateway, seamEnv));
  try {
    const sid = await startAskSession(acp, workspace);

    switch (scenario) {
      case "eof_idle": {
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
      case "eof_before_ask": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "HOLD_BEFORE_ASK" }] } });
        await gatewayHit;
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        expect(acp.rawLines.some((m) => m.method === "session/request_permission")).toBe(false);
        break;
      }
      case "eof_decide_to_insert": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "ASK_FILE" }] } });
        await waitForFile(permissionReady);
        acp.endStdin();
        await waitForFile(reapReady);
        releaseNow();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        expect(acp.rawLines.some((m) => m.method === "session/request_permission")).toBe(false);
        expect(existsSync(targetBefore)).toBe(false);
        break;
      }
      case "eof_while_waiting": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "ASK_FILE" }] } });
        await acp.waitLine((m) => m.method === "session/request_permission");
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        expect(existsSync(targetBefore)).toBe(false);
        break;
      }
      case "eof_after_finished_done": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "ASK_FILE" }] } });
        const perm = await acp.waitLine((m) => m.method === "session/request_permission");
        acp.send({ jsonrpc: "2.0", id: perm.id, result: { outcome: { outcome: "selected", optionId: "allow_once" } } });
        const resp = await acp.waitLine((m) => m.id === 10);
        expect(resp.result.stopReason).toBe("end_turn");
        expect(readFileSync(targetBefore, "utf8")).toBe("BEFORE\n");
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
      case "eof_after_finished_cancelled": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "HOLD_BEFORE_ASK" }] } });
        await gatewayHit;
        acp.send({ jsonrpc: "2.0", id: 11, method: "session/cancel", params: { sessionId: sid } });
        await acp.waitLine((m) => m.id === 11);
        const cancelled = await acp.waitLine((m) => m.id === 10);
        expect(cancelled.result.stopReason).toBe("cancelled");
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
      case "close_idle": {
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/close", params: { sessionId: sid } });
        const closeResp = await acp.waitLine((m) => m.id === 10);
        expect(closeResp.error).toBeUndefined();
        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
      case "close_before_ask":
      case "close_decide_to_insert":
      case "close_while_waiting": {
        const text = scenario === "close_before_ask" ? "HOLD_BEFORE_ASK" : "ASK_FILE";
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text }] } });
        if (scenario === "close_before_ask") await gatewayHit;
        if (scenario === "close_decide_to_insert") await waitForFile(permissionReady);
        if (scenario === "close_while_waiting") await acp.waitLine((m) => m.method === "session/request_permission");
        acp.send({ jsonrpc: "2.0", id: 11, method: "session/close", params: { sessionId: sid } });
        if (scenario === "close_decide_to_insert") {
          await waitForFile(reapReady);
          releaseNow();
        }
        const closeResp = await acp.waitLine((m) => m.id === 11, EXIT_DEADLINE_MS);
        expect(closeResp.error).toBeUndefined();
        if (scenario !== "close_while_waiting") {
          expect(acp.rawLines.some((m) => m.method === "session/request_permission")).toBe(false);
        }
        expect(existsSync(targetBefore)).toBe(false);

        acp.send({ jsonrpc: "2.0", id: 12, method: "session/new", params: { cwd: workspace, mcpServers: [] } });
        const nextCreated = await acp.waitLine((m) => m.id === 12);
        const nextSid = nextCreated.result.sessionId as string;
        acp.send({ jsonrpc: "2.0", id: 13, method: "session/set_mode", params: { sessionId: nextSid, modeId: "ask" } });
        await acp.waitLine((m) => m.id === 13);
        acp.send({ jsonrpc: "2.0", id: 14, method: "session/prompt", params: { sessionId: nextSid, prompt: [{ type: "text", text: "SERVE_AFTER" }] } });
        const permAfter = await acp.waitLine((m) => m.method === "session/request_permission" && m.params?.toolCall?.rawInput?.path === targetAfter);
        acp.send({ jsonrpc: "2.0", id: permAfter.id, result: { outcome: { outcome: "selected", optionId: "allow_once" } } });
        const afterResp = await acp.waitLine((m) => m.id === 14);
        expect(afterResp.result.stopReason).toBe("end_turn");
        expect(readFileSync(targetAfter, "utf8")).toBe("AFTER\n");

        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
      case "cancel_before_ask_then_prompt":
      case "cancel_decide_to_insert_then_prompt":
      case "cancel_while_waiting_then_prompt": {
        const text = scenario === "cancel_before_ask_then_prompt" ? "HOLD_BEFORE_ASK" : "ASK_FILE";
        acp.send({ jsonrpc: "2.0", id: 10, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text }] } });
        if (scenario === "cancel_before_ask_then_prompt") await gatewayHit;
        if (scenario === "cancel_decide_to_insert_then_prompt") await waitForFile(permissionReady);
        if (scenario === "cancel_while_waiting_then_prompt") await acp.waitLine((m) => m.method === "session/request_permission");
        acp.send({ jsonrpc: "2.0", id: 11, method: "session/cancel", params: { sessionId: sid } });
        await acp.waitLine((m) => m.id === 11);
        if (scenario === "cancel_decide_to_insert_then_prompt") {
          releaseNow();
        }
        const cancelResp = await acp.waitLine((m) => m.id === 10, EXIT_DEADLINE_MS);
        expect(cancelResp.result.stopReason).toBe("cancelled");
        if (scenario !== "cancel_while_waiting_then_prompt") {
          expect(acp.rawLines.some((m) => m.method === "session/request_permission")).toBe(false);
        }

        acp.send({ jsonrpc: "2.0", id: 12, method: "session/prompt", params: { sessionId: sid, prompt: [{ type: "text", text: "SERVE_AFTER" }] } });
        const permAfter = await acp.waitLine((m) => m.method === "session/request_permission" && m.params?.toolCall?.rawInput?.path === targetAfter);
        acp.send({ jsonrpc: "2.0", id: permAfter.id, result: { outcome: { outcome: "selected", optionId: "allow_once" } } });
        const afterResp = await acp.waitLine((m) => m.id === 12);
        expect(afterResp.result.stopReason).toBe("end_turn");
        expect(readFileSync(targetAfter, "utf8")).toBe("AFTER\n");

        acp.endStdin();
        const exited = await acp.waitExit();
        expect(exited.code).toBe(0);
        expect(acp.stderr()).toBe("");
        break;
      }
    }
  } finally {
    releaseNow();
    acp.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

test(
  "fx acp matches every reachable transition of AcpEof design-a.cfg",
  async () => {
    const graphDir = join(artifacts, "acp-eof-graph");
    const tlcRun = await runTlc(
      graphDir,
      "AcpEof",
      "design-a.cfg",
      ["AcpEof.tla", "design-a.cfg"],
      SPEC_DIR,
      ["-dump", "dot,actionlabels", "graph"],
    );
    expect(tlcRun.exitCode).toBe(0);

    const dot = readFileSync(join(graphDir, "graph.dot"), "utf8");
    const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
    const states = new Map<string, Record<string, any>>();
    for (const line of dot.split("\n")) {
      const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
      if (!node) continue;
      const parsed: Record<string, any> = {};
      for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
        const match = /^\s*(?:\/\\)?\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([\s\S]+)$/.exec(entry);
        if (match) parsed[match[1]!] = parseValue(match[2]!.trim());
      }
      states.set(node[1]!, parsed);
    }

    const trackedActions = new Set([
      "EofReadLoop",
      "CleanShutdown",
      "SessionCloseOrLoadStart",
      "SessionCancel",
      "BeginOutbound",
      "ClientAnswer",
    ]);
    const modelKeys = new Set<string>();
    for (const line of dot.split("\n")) {
      const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
      if (!edge || !trackedActions.has(edge[3]!)) continue;
      const from = states.get(edge[1]!)!;
      const to = states.get(edge[2]!)!;
      modelKeys.add(
        [
          edge[3]!,
          from.readerPhase,
          from.promptPhase,
          from.reqKind,
          from.reqStatus,
          "->",
          to.readerPhase,
          to.promptPhase,
          to.reqStatus,
          `closed=${to.outboundClosed}`,
          `cancel=${to.cancelFlag}`,
        ].join("|"),
      );
    }

    const unmapped = [...modelKeys].filter((k) => !(k in SCENARIO_FOR_KEY) && !(k in OUT_OF_REACH));
    expect(unmapped).toEqual([]);
    const stale = [...Object.keys(SCENARIO_FOR_KEY), ...Object.keys(OUT_OF_REACH)].filter((k) => !modelKeys.has(k));
    expect(stale).toEqual([]);

    const scenarios = [...new Set(Object.values(SCENARIO_FOR_KEY))];
    for (const scenario of scenarios) {
      await runScenario(scenario);
    }
  },
  60_000,
);
