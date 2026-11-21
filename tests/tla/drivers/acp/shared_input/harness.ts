// Runtime bridge for the shared-input driver: one plan's isolated home, workspace,
// and fake Gateway; the owner's fx acp process on stdio; the follower's connection
// to the session's leader socket; and fx's trace log, which the driver reads to
// know when fx queued or held a prompt, or withdrew a follower's input. Frames are
// what fx wrote. The driver never writes text for fx to echo.
import { mkdirSync, mkdtempSync, existsSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { targetHelpers, testEnvironment } from "../../lib/context";
import { Acp, clientCapabilities } from "../disconnect/harness";

export { Acp, clientCapabilities };

export const WAIT_MS = 30_000;

/// The frames a connection received, in arrival order, with waits on them.
export class FrameStream {
  readonly frames: any[] = [];
  closed = false;
  private waiters: Array<() => void> = [];

  push(frame: any) {
    this.frames.push(frame);
    this.wake();
  }

  end() {
    this.closed = true;
    this.wake();
  }

  async until(predicate: (frames: any[]) => boolean, label: string, timeoutMs = WAIT_MS): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!predicate(this.frames)) {
      if (this.closed) throw new Error(`the connection closed before ${label}`);
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out waiting for ${label}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(remaining, 200));
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  private wake() {
    for (const wakeWaiter of this.waiters.splice(0)) wakeWaiter();
  }
}

/// A JSON-RPC client over a leader socket that stays connected. `request` waits
/// for the answer to its id; `notify` sends a notification; every frame the socket
/// sends goes to `stream`.
export class SocketClient {
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

  static connect(socketPath: string): Promise<SocketClient> {
    return new Promise((resolve, reject) => {
      const socket = createConnection({ path: socketPath });
      socket.once("error", reject);
      socket.once("connect", () => {
        socket.removeListener("error", reject);
        resolve(new SocketClient(socket));
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

  /// Sends one request and waits for its answer. It returns the answer and its
  /// index among the frames received, so the caller can take what came before it.
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

export function isAnswer(frame: any): boolean {
  return frame !== undefined && frame !== null && "id" in frame && ("result" in frame || "error" in frame);
}

/// The text of a user message chunk fx wrote, or null for any other frame.
export function userChunkText(frame: any): string | null {
  if (frame?.method !== "session/update" || frame.params?.update?.sessionUpdate !== "user_message_chunk") return null;
  return String(frame.params.update.content?.text ?? "");
}

/// Waits until `predicate` holds for up to `ms`. It returns whether it did; it
/// never throws, so a missing frame is an observation the caller records.
export async function settle(predicate: () => boolean, ms: number): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await Bun.sleep(10);
  }
  return predicate();
}

/// One model request the fake Gateway received. Its reply has streamed one text
/// piece and waits until the driver ends it, or until fx aborts it.
export type Hold = {
  body: string;
  end(kind: "final"): void;
  aborted: boolean;
};

const encoder = new TextEncoder();
const sse = (event: object) => encoder.encode(`data: ${JSON.stringify(event)}\n\n`);

/// One plan's fixture: an isolated fx home and workspace, a fake Gateway whose
/// every reply the driver holds, and the trace log that fx's own trace lines go to.
export class SharedFixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly traceLog: string;
  readonly holds: Hold[] = [];
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  model = "";
  private gateway: any = null;
  private tmpdirs = 0;

  constructor(private readonly fxBin: string) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-shared-input-")));
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
    this.gateway = helpers.startDynamicFakeGateway((body: string) => {
      let controller!: ReadableStreamDefaultController<Uint8Array>;
      let ended = false;
      const hold: Hold = {
        body,
        aborted: false,
        end: (kind) => {
          if (hold.aborted || ended) return;
          ended = true;
          controller.enqueue(sse({ type: "text-delta", id: "answer_1", delta: " done" }));
          controller.enqueue(sse({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } } }));
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      };
      const stream = new ReadableStream<Uint8Array>({
        start(c) {
          controller = c;
          c.enqueue(sse({ type: "text-delta", id: "answer_1", delta: "working" }));
        },
        cancel() {
          hold.aborted = true;
        },
      });
      this.holds.push(hold);
      return new Response(stream, { headers: { "content-type": "text/event-stream" } });
    }, {});
  }

  /// Starts an fx acp process on stdio. Its socket folder is a new TMPDIR under
  /// the plan's root, so it goes with the root. Its trace lines go to traceLog.
  spawn(): Acp {
    this.tmpdirs += 1;
    const tmpdir = join(this.root, `tmp-${this.tmpdirs}`);
    mkdirSync(tmpdir, { recursive: true, mode: 0o700 });
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-shared-input-fake-key",
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

  /// Whether fx's trace log has a line with `needle`.
  traceHas(needle: string): boolean {
    return this.traceCount(needle) > 0;
  }

  dispose() {
    for (const hold of this.holds) hold.end("final");
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
