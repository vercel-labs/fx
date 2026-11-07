// Runtime bridge for the prompt-delivery driver: an ACP stdio client that
// keeps several requests open at once, a fake Gateway whose replies the
// driver holds and releases, a shell tool call that waits until the driver
// lets it end, and fx's trace log, which shows when fx queued a steer.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../../lib/context";

// -------------------------------------------------------------- ACP client --

/// An ACP client over stdio that routes each answer to its request by id, so
/// a turn's prompt and the steers sent during it can all be open at once.
export class Acp {
  private buffer = "";
  private nextId = 1;
  private readonly waiters = new Map<number, (message: any) => void>();
  private closed = false;
  stderr = "";
  /// Every notification fx sent, in order.
  readonly notifications: Array<{ method: string; params: any }> = [];
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly log: (entry: object) => void) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      for (const resolve of this.waiters.values()) resolve({ error: { code: 0, message: "fx acp exited" } });
      this.waiters.clear();
      return code;
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) if (line.trim()) this.receive(JSON.parse(line));
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  private receive(message: any) {
    if ("method" in message && "id" in message) {
      this.log({ dir: "in-request", method: message.method });
      this.write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
      return;
    }
    if ("method" in message && !("id" in message)) {
      this.log({ dir: "in-notification", method: message.method });
      this.notifications.push({ method: message.method, params: message.params });
      return;
    }
    if ("id" in message && typeof message.id === "number") {
      this.log({ dir: "in", id: message.id, error: message.error ?? null, result: message.result ?? null });
      const resolve = this.waiters.get(message.id);
      this.waiters.delete(message.id);
      resolve?.(message);
    }
  }

  private write(message: object) {
    (this.proc.stdin as any).write(`${JSON.stringify(message)}\n`);
    (this.proc.stdin as any).flush?.();
  }

  /// Sends a request and returns its answer when it comes.
  request(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.closed) return Promise.resolve({ error: { code: 0, message: "fx acp exited" } });
    const id = this.nextId++;
    this.log({ dir: "out", id, method, params });
    const answer = new Promise<any>((resolve) => this.waiters.set(id, resolve));
    this.write({ jsonrpc: "2.0", id, method, params });
    return answer;
  }

  notify(method: string, params: Record<string, unknown>) {
    this.log({ dir: "out", method, params });
    this.write({ jsonrpc: "2.0", method, params });
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

// ---------------------------------------------------------- held replies --

/// One model request the fake Gateway received. Its reply has streamed one
/// text piece and waits until the driver ends it.
export type Hold = {
  body: string;
  /// Ends the reply: with a shell tool call that waits for the driver, or
  /// with final text.
  end(kind: "tool" | "final"): void;
  aborted: boolean;
};

const encoder = new TextEncoder();
const sse = (event: object) => encoder.encode(`data: ${JSON.stringify(event)}\n\n`);

export async function waitFor<T>(what: string, probe: () => T | null | undefined | false, timeoutMs = 30_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = probe();
    if (value) return value;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for ${what}`);
}

// -------------------------------------------------------------- fx fixture --

/// An isolated fx home in full-access mode (the tool runs without asking),
/// a workspace, and a fake Gateway whose every reply the driver holds.
export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly traceLog: string;
  readonly acpLog: object[] = [];
  readonly holds: Hold[] = [];
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  acp: Acp | null = null;
  private gateway: any = null;
  private tools = 0;

  constructor(private readonly fxBin: string = binary) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-prompt-delivery-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    this.traceLog = join(this.root, "fx-trace.log");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, permission_mode: "full-access" })}\n`, { mode: 0o600 });
  }

  async init() {
    const helpers = await targetHelpers();
    this.gateway = helpers.startDynamicFakeGateway((body: string) => {
      let controller!: ReadableStreamDefaultController<Uint8Array>;
      let ended = false;
      const hold: Hold = {
        body,
        aborted: false,
        end: (kind) => {
          if (hold.aborted || ended) return;
          ended = true;
          if (kind === "tool") {
            this.tools += 1;
            const started = join(this.root, `tool-${this.tools}.started`);
            const go = join(this.root, `tool-${this.tools}.go`);
            controller.enqueue(sse({
              type: "tool-call", toolCallId: `call_${this.tools}`, toolName: "shell",
              input: { request: { yield_time_ms: 30_000, action: "run", command: `touch ${JSON.stringify(started)}; while [ ! -f ${JSON.stringify(go)} ]; do sleep 0.05; done; echo tool-done` } },
            }));
            controller.enqueue(sse({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } }));
          } else {
            controller.enqueue(sse({ type: "text-delta", id: "answer_1", delta: " done" }));
            controller.enqueue(sse({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } } }));
          }
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      };
      const stream = new ReadableStream<Uint8Array>({
        start(c) {
          controller = c;
          c.enqueue(sse({ type: "text-delta", id: "answer_1", delta: "working" }));
        },
        cancel() { hold.aborted = true; },
      });
      this.holds.push(hold);
      return new Response(stream, { headers: { "content-type": "text/event-stream" } });
    }, {});
  }

  /// The files of tool call `n`: created when it starts, and the one that lets it end.
  toolFiles(n: number) {
    return { started: join(this.root, `tool-${n}.started`), go: join(this.root, `tool-${n}.go`) };
  }

  get toolCount() { return this.tools; }

  /// How many steers fx has queued so far, from its trace log.
  queuedSteers(): number {
    if (!existsSync(this.traceLog)) return 0;
    return readFileSync(this.traceLog, "utf8").split("\n").filter((line) => line.includes("queued steering prompt")).length;
  }

  async start(init: Record<string, unknown> = { protocolVersion: 1 }): Promise<Acp> {
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-prompt-delivery-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TRACE_LOG: this.traceLog,
      FX_TRACE_SCOPES: "acp",
    });
    this.acp = new Acp(
      Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }),
      (entry) => this.acpLog.push(entry),
    );
    const initialized = await this.acp.request("initialize", init);
    if (initialized.error) throw new Error(`initialize failed: ${JSON.stringify(initialized.error)}`);
    return this.acp;
  }

  async dispose() {
    // Let any tool still waiting end, so fx can stop.
    for (let n = 1; n <= this.tools; n += 1) writeFileSync(this.toolFiles(n).go, "");
    for (const hold of this.holds) hold.end("final");
    if (this.acp) this.processes.push(await this.acp.close());
    this.acp = null;
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
