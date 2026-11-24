// Runtime bridge for the approvals driver: one plan's isolated home, workspace, and
// fake Gateway; the opener's fx acp process on stdio; the follower's connection to the
// session's leader socket, which can answer the requests it receives; and fx's trace
// log, which the driver reads as a fence. Frames are what fx wrote. The Gateway's first
// reply is a write_file tool call, so each turn asks for a permission; its next reply
// is final text. No model calls.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { targetHelpers, testEnvironment } from "../../lib/context";
import { Acp, FrameStream, WAIT_MS, clientCapabilities, isAnswer, settle } from "../shared_input/harness";

export { Acp, FrameStream, WAIT_MS, clientCapabilities, isAnswer, settle };

/// A JSON-RPC client on the session's leader socket. `request` waits for its answer;
/// `respond` answers a request that fx sent it; every frame fx sends goes to `stream`.
export class Follower {
  readonly stream = new FrameStream();
  private buffer = "";
  private nextId = 1;

  private constructor(private readonly socket: ReturnType<typeof createConnection>) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.buffer += chunk;
      let end = this.buffer.indexOf("\n");
      while (end !== -1) {
        const line = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        if (line.trim()) this.stream.push(JSON.parse(line));
        end = this.buffer.indexOf("\n");
      }
    });
    socket.on("close", () => this.stream.end());
    socket.on("error", () => this.stream.end());
  }

  static connect(socketPath: string): Promise<Follower> {
    return new Promise((resolve, reject) => {
      const socket = createConnection({ path: socketPath });
      socket.once("error", reject);
      socket.once("connect", () => {
        socket.removeListener("error", reject);
        resolve(new Follower(socket));
      });
    });
  }

  /// Writes one request and returns its id, without waiting.
  send(method: string, params: object): number {
    const id = this.nextId++;
    this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return id;
  }

  /// Writes one notification: no id, no answer.
  notify(method: string, params: object): void {
    this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  /// Answers a request that fx sent this connection.
  respond(id: number, result: object): void {
    this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  }

  /// Sends one request and waits for its answer. It returns the answer and its index
  /// among the frames received, so the caller can take what came before it.
  async request(method: string, params: object): Promise<{ id: number; answer: any; index: number }> {
    const id = this.send(method, params);
    const answered = (frames: any[]) => frames.some((frame) => isAnswer(frame) && frame.id === id);
    await this.stream.until(answered, `the answer to ${method}`);
    const index = this.stream.frames.findIndex((frame) => isAnswer(frame) && frame.id === id);
    return { id, answer: this.stream.frames[index], index };
  }

  close() {
    this.socket.destroy();
  }
}

/// Answers a request that fx sent the opener on stdio.
export function respondOnStdio(acp: Acp, id: number, result: object): void {
  (acp.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  (acp.proc.stdin as any).flush?.();
}

/// One plan's fixture: an isolated fx home and workspace, a fake Gateway whose reply to
/// the question turn (its second model call) is a write_file tool call to `target`, and
/// the trace log fx's trace lines go to. The first call is a warm-up turn with no tool.
export class ApprovalsFixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly traceLog: string;
  /// The file the turn's write_file call writes, relative to the workspace.
  target = "approved.txt";
  model = "";
  private calls = 0;
  private gateway: any = null;
  private tmpdirs = 0;
  private openGate!: () => void;
  private readonly gate = new Promise<void>((resolve) => {
    this.openGate = resolve;
  });

  constructor(private readonly fxBin: string) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-approvals-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    this.traceLog = join(this.root, "fx-trace.log");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
  }

  async init() {
    const helpers = await targetHelpers();
    this.model = helpers.FAKE_GATEWAY_MODEL;
    this.gateway = helpers.startDynamicFakeGateway(async () => {
      const call = this.calls;
      this.calls += 1;
      if (call !== 1) return helpers.fakeGatewayFinalText("DONE");
      await this.gate;
      return helpers.fakeGatewayToolCall("call_approval", "write_file", { path: this.target, content: "APPROVED\n" });
    }, {});
  }

  /// Lets the question turn's model call go on. Until then the turn asks nothing, so
  /// the driver can join a client while the turn waits.
  release() {
    this.openGate();
  }

  /// Starts an fx acp process on stdio. Its socket folder is a new TMPDIR under the
  /// plan's root, so it goes with the root. Its trace lines go to traceLog.
  spawn(): Acp {
    this.tmpdirs += 1;
    const tmpdir = join(this.root, `tmp-${this.tmpdirs}`);
    mkdirSync(tmpdir, { recursive: true, mode: 0o700 });
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-approvals-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: this.model,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TRACE_LOG: this.traceLog,
      FX_TRACE_SCOPES: "acp",
      TMPDIR: tmpdir,
    });
    return new Acp(Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
  }

  /// How many lines of fx's trace log contain `needle`.
  traceCount(needle: string): number {
    if (!existsSync(this.traceLog)) return 0;
    return readFileSync(this.traceLog, "utf8").split("\n").filter((line) => line.includes(needle)).length;
  }

  /// Whether the workspace file the turn writes exists.
  wrote(): boolean {
    return existsSync(join(this.workspace, this.target));
  }

  dispose() {
    this.release();
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
