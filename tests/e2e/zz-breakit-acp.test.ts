import { afterEach, describe, expect, test } from "bun:test";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, fxChildEnv, REPO_ROOT } from "../evals/eval-helpers";
import { LineQueue } from "./line-queue";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  localCreditsEnv,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MCP_STDIO_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const TOOL_NAME = "mcp_fixture_echo";
const WAITING_CALL_TRACE = "waits for a shell call to follow its command";

class AcpReadTimeoutError extends Error {
  constructor() {
    super("ACP readLine timeout");
  }
}

class AcpClient {
  private proc: ChildProcess;
  private buffer = "";
  private queue = new LineQueue();
  private _closed = false;
  private _stderrChunks: Buffer[] = [];
  private activeSessionId: string | null = null;
  private pendingNewSessions = new Set<number | string>();
  readonly rawLines: string[] = [];

  constructor(proc: ChildProcess) {
    this.proc = proc;
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const parts = this.buffer.split("\n");
      this.buffer = parts.pop() ?? "";
      for (const line of parts) {
        if (line.trim()) {
          this.rawLines.push(line);
          this.queue.push(line);
        }
      }
    });
    proc.stderr!.on("data", (chunk: Buffer) => {
      this._stderrChunks.push(chunk);
    });
    proc.on("close", () => {
      this._closed = true;
    });
  }

  static async create(opts: { cwd: string; env: Record<string, string | undefined> }): Promise<AcpClient> {
    const inheritedEnv: Record<string, string | undefined> = fxChildEnv({}, { keepCredentials: true });
    for (const [key, value] of Object.entries(opts.env)) {
      if (value === undefined) delete inheritedEnv[key];
      else inheritedEnv[key] = value;
    }
    const proc = nodeSpawn(FX_BIN, ["acp"], {
      env: localCreditsEnv({
        ...inheritedEnv,
        NO_COLOR: "1",
        PATH: inheritedEnv.PATH ?? "",
      }),
      cwd: opts.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return new AcpClient(proc);
  }

  get stderr(): string {
    return Buffer.concat(this._stderrChunks).toString();
  }

  send(msg: object): void {
    let outgoing = msg as any;
    if (outgoing.method === "session/new" && (typeof outgoing.id === "number" || typeof outgoing.id === "string")) {
      this.pendingNewSessions.add(outgoing.id);
    }
    if (
      this.activeSessionId !== null &&
      ["session/prompt", "session/cancel", "session/set_mode"].includes(outgoing.method) &&
      outgoing.params?.sessionId === undefined
    ) {
      outgoing = { ...outgoing, params: { ...(outgoing.params ?? {}), sessionId: this.activeSessionId } };
    }
    this.proc.stdin!.write(JSON.stringify(outgoing) + "\n");
  }

  async readLine(timeoutMs = 10_000): Promise<object> {
    const line = await this.queue.next(timeoutMs, () => new AcpReadTimeoutError());
    const message = JSON.parse(line) as any;
    if (typeof message.id === "number" || typeof message.id === "string") {
      if (this.pendingNewSessions.delete(message.id)) {
        if (message.error === undefined && typeof message.result?.sessionId === "string") {
          this.activeSessionId = message.result.sessionId;
        }
      }
    }
    if (message.method === "session/request_permission" && message.id !== undefined) {
      this.send({
        jsonrpc: "2.0",
        id: message.id,
        result: { outcome: { outcome: "selected", optionId: "allow_once" } },
      });
    }
    return message;
  }

  async request(method: string, params?: object, id?: number, timeoutMs?: number): Promise<any> {
    const reqId = id ?? Math.floor(Math.random() * 100000);
    this.send({ jsonrpc: "2.0", id: reqId, method, params: params ?? {} });
    let resp: any;
    do {
      resp = await this.readLine(timeoutMs);
    } while (resp.id !== reqId);
    return resp;
  }

  async close(): Promise<void> {
    if (!this._closed) {
      this.proc.stdin!.end();
      this.proc.kill("SIGTERM");
      await new Promise((r) => setTimeout(r, 200));
      if (!this._closed) this.proc.kill("SIGKILL");
    }
  }
}

function acpContentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(acpContentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [acpContentText(value.text), acpContentText(value.value), acpContentText(value.content)].join("");
  }
  return "";
}

function acpToolResultText(body: string, callId: string): string {
  const prompt = JSON.parse(body).prompt as Array<{ content?: unknown }>;
  const parts = prompt.flatMap((m) => (Array.isArray(m.content) ? m.content : [])) as Array<Record<string, unknown>>;
  const result = parts.find((p) => p.type === "tool-result" && p.toolCallId === callId);
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return acpContentText(result.output);
}

async function waitForFileText(path: string, text: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(text)) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for "${text}" in ${path}`);
}

describe("ACP fx mcp call across yield and interact", () => {
  let client: AcpClient | undefined;
  let gateway: ReturnType<typeof startFakeGateway> | undefined;
  let rootDir: string | undefined;

  afterEach(async () => {
    await client?.close();
    gateway?.stop();
    if (rootDir) rmSync(rootDir, { recursive: true, force: true });
    client = undefined;
    gateway = undefined;
    rootDir = undefined;
  });

  test("command with yield_time_ms: 1000 makes call after go file, then interact runs it with exit 0", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-mcp-call-")));
    rootDir = root;
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const wireLogPath = join(root, "mcp-wire.jsonl");
    const traceLogPath = join(root, "mcp-trace.log");
    const pidPath = join(root, "fixture.pid");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace, { recursive: true });

    const command = `while [ ! -f go ]; do sleep 0.05; done; "${FX_BIN}" mcp call ${TOOL_NAME} '{"text":"acp-after-yield"}' > out.json 2> err.txt; echo "later_exit=$?"`;
    let runResult: Record<string, unknown> = {};
    let interactResult: Record<string, unknown> = {};

    gateway = startFakeGateway([
      fakeGatewayToolCall("run_call", "shell", { action: "run", command, yield_time_ms: 1000 }),
      async (body: string) => {
        runResult = JSON.parse(acpToolResultText(body, "run_call"));
        writeFileSync(join(workspace, "go"), "");
        await waitForFileText(traceLogPath, WAITING_CALL_TRACE, 15_000);
        return fakeGatewayToolCall("interact_call", "shell", {
          action: "interact",
          session_id: runResult.session_id,
          yield_time_ms: 30_000,
        });
      },
      (body: string) => {
        interactResult = JSON.parse(acpToolResultText(body, "interact_call"));
        return fakeGatewayFinalText("ACP_BRIDGE_DONE");
      },
    ], {
      models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"] }],
    });

    client = await AcpClient.create({
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-acp-key",
        VERCEL_OIDC_TOKEN: "",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_TRACE_LOG: traceLogPath,
        FX_TRACE_SCOPES: "mcp-call",
      },
    });

    await client.request("initialize", { protocolVersion: 1 }, 1);
    const created = await client.request("session/new", {
      cwd: workspace,
      mcpServers: [{
        name: "fixture",
        command: process.execPath,
        args: [MCP_STDIO_FIXTURE],
        env: [
          { name: "FX_MCP_RESULT_TEXT", value: "ACP_BRIDGE_RESULT" },
          { name: "FX_MCP_PID_PATH", value: pidPath },
          { name: "FX_MCP_WIRE_LOG", value: wireLogPath },
          { name: "FX_MCP_MODE", value: "normal" },
        ],
      }],
    }, 2);
    expect(created.error).toBeUndefined();
    await client.readLine();
    await client.request("session/set_mode", { modeId: "full-access" }, 3);

    const promptId = 100;
    client.send({
      jsonrpc: "2.0",
      id: promptId,
      method: "session/prompt",
      params: { prompt: [{ type: "text", text: "Run command then interact." }] },
    });

    let promptResult: any = null;
    const deadline = Date.now() + TIMEOUT;
    while (Date.now() < deadline) {
      const msg = await client.readLine(Math.max(1000, deadline - Date.now())) as any;
      if (msg.id === promptId && (msg.result !== undefined || msg.error !== undefined)) {
        promptResult = msg;
        break;
      }
    }

    expect(promptResult?.result?.stopReason).toBe("end_turn");
    expect(runResult.state).toBe("running");
    expect(interactResult.state).toBe("completed");
    expect(interactResult.output_delta).toContain("later_exit=0");
    expect(readFileSync(join(workspace, "out.json"), "utf8")).toContain("ACP_BRIDGE_RESULT:acp-after-yield");
    expect(client.stderr).toBe("");

    const wireCalls = readFileSync(wireLogPath, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l))
      .filter((e) => e.message?.method === "tools/call");
    expect(wireCalls).toHaveLength(1);
    console.log("A3_ACP_INTERACT_OUTPUT:", interactResult.output_delta);
    console.log("A3_OUT_JSON:", readFileSync(join(workspace, "out.json"), "utf8"));
  }, 60_000);
});
