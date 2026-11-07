// Runtime bridge for the session-target driver: an ACP stdio client that can
// also send a raw frame over the size limit, an isolated fx home and fake
// Gateway, and the client's view of each answer as an observation of
// tests/tla/acp/AcpSessionTarget.tla.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../../lib/context";

/// One step as the model's `Obs` record describes it.
export type Observation = {
  op: string;
  arg: string;
  ok: boolean;
  code: number;
  dataSid: boolean;
  result: string;
  detail?: unknown;
};

/// The size limit of one request frame in src/acp/jsonrpc.zig
/// (`frame_resource_byte_limit`).
export const FRAME_LIMIT = 8 * 1024 * 1024;

/// How the client summarizes a successful answer, in the model's terms.
export function resultKind(result: unknown): string {
  if (result === null || result === undefined) return "null";
  if (typeof result === "object" && !Array.isArray(result)) {
    const record = result as Record<string, unknown>;
    if (typeof record.stopReason === "string") return record.stopReason;
    return Object.keys(record).length === 0 ? "empty" : "object";
  }
  return "other";
}

/// The observation for one JSON-RPC answer. `sent` is the sessionId the
/// request carried, if it carried a string.
export function observe(op: string, arg: string, response: any, sent: unknown): Observation {
  const error = response?.error ?? null;
  return {
    op,
    arg,
    ok: error === null,
    code: error === null ? 0 : Number(error.code),
    dataSid: error !== null && typeof sent === "string" && error?.data?.sessionId === sent,
    result: error === null ? resultKind(response.result) : "none",
    detail: error === null ? undefined : { error },
  };
}

// -------------------------------------------------------------- ACP client --

export class Acp {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private nextId = 1;
  stderr = "";
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly log: (entry: object) => void) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      for (const waiter of this.waiters.splice(0)) waiter("");
      return code;
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) {
          if (!line.trim()) continue;
          const waiter = this.waiters.shift();
          if (waiter) waiter(line);
          else this.lines.push(line);
        }
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  private async readMessage(timeoutMs: number): Promise<any> {
    const buffered = this.lines.shift();
    if (buffered) return JSON.parse(buffered);
    if (this.closed) throw new Error(`fx acp exited: ${this.stderr.slice(-400)}`);
    const line = await new Promise<string>((resolveLine, reject) => {
      const timer = setTimeout(() => reject(new Error(`fx acp read timeout: ${this.stderr.slice(-400)}`)), timeoutMs);
      this.waiters.push((value) => {
        clearTimeout(timer);
        resolveLine(value);
      });
    });
    if (!line) throw new Error(`fx acp exited: ${this.stderr.slice(-400)}`);
    return JSON.parse(line);
  }

  private write(text: string) {
    (this.proc.stdin as any).write(text);
    (this.proc.stdin as any).flush?.();
  }

  /// Answers a request fx sends the client, and reports whether `message` was one.
  private answerAgentRequest(message: any): boolean {
    if (!("method" in message && "id" in message)) return false;
    this.log({ dir: "in-request", method: message.method });
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } })}\n`);
    return true;
  }

  async call(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<any> {
    const id = this.nextId++;
    this.log({ dir: "out", id, method, params });
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    while (true) {
      const message = await this.readMessage(timeoutMs);
      if (this.answerAgentRequest(message)) continue;
      if (message.id === id) {
        this.log({ dir: "in", id, method, error: message.error ?? null, result: message.result ?? null });
        return message;
      }
    }
  }

  /// Sends one frame of FRAME_LIMIT + 1 bytes and returns fx's answer, which
  /// carries a null id because fx could not read the frame's id.
  async oversize(): Promise<any> {
    this.log({ dir: "out", frame: "oversize", bytes: FRAME_LIMIT + 1 });
    this.write(`${"x".repeat(FRAME_LIMIT + 1)}\n`);
    while (true) {
      const message = await this.readMessage(120_000);
      if (this.answerAgentRequest(message)) continue;
      if ("id" in message && message.id === null) {
        this.log({ dir: "in", frame: "oversize", error: message.error ?? null });
        return message;
      }
    }
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

// -------------------------------------------------------------- fx fixture --

/// An isolated fx home, workspace, and fake Gateway for one run. Every
/// prompt's model reply is the final text "done", so no model is called.
/// `gatewayBodies` keeps each model request's body, in order.
export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly acpLog: object[] = [];
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  readonly gatewayBodies: string[] = [];
  acp: Acp | null = null;
  private gateway: any = null;

  constructor(private readonly fxBin: string = binary) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-session-target-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
  }

  async init() {
    const helpers = await targetHelpers();
    this.gateway = helpers.startDynamicFakeGateway((body: string) => {
      this.gatewayBodies.push(body);
      return helpers.fakeGatewayFinalText("done");
    }, {});
  }

  private env(): Record<string, string> {
    return testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-session-target-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
  }

  /// Starts a new fx acp process and initializes it. Returns the answer to
  /// `initialize`.
  async start(): Promise<any> {
    if (this.acp) this.processes.push(await this.acp.close());
    const processNumber = this.processes.length + 1;
    this.acp = new Acp(
      Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }),
      (entry) => this.acpLog.push({ process: processNumber, ...entry }),
    );
    return await this.acp.call("initialize", { protocolVersion: 1 });
  }

  async dispose() {
    if (this.acp) this.processes.push(await this.acp.close());
    this.acp = null;
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
