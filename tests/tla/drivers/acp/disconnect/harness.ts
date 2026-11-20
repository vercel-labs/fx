// Runtime bridge for the disconnect driver: an fx acp process and its stdio, a
// client that keeps the notifications and answers it reads, and an isolated
// home, workspace and fake Gateway for one plan. It is config_turn/harness.ts
// with four changes: the client's capabilities are a parameter, so a plan can
// list sh.fx/keepTurnOnDisconnect or not; the client can close its input, after
// which nothing it writes reaches fx and fx's requests to it get no answer; the
// driver can wait for fx's exit with a time limit; and a plan can start a fresh
// process to load the session.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { testEnvironment } from "../../lib/context";

/// The extensions the E2E tests send by default (tests/e2e/acp.test.ts, FX_EXTENSIONS).
const DEFAULT_EXTENSIONS = [
  "sh.fx/promptDelivery",
  "sh.fx/hooks",
  "sh.fx/toolCall",
  "sh.fx/permissionMode",
  "sh.fx/modelResponseRecovery",
];

/// The client's capabilities at initialize: the default extensions, and
/// sh.fx/keepTurnOnDisconnect when `keep` is set.
export function clientCapabilities(keep: boolean): Record<string, unknown> {
  const names = keep ? [...DEFAULT_EXTENSIONS, "sh.fx/keepTurnOnDisconnect"] : DEFAULT_EXTENSIONS;
  return { _meta: Object.fromEntries(names.map((name) => [name, {}])) };
}

/// One fx acp process and its stdio. `call` sends a request and waits for its
/// answer. `send` and `collect` split that: a request can be sent, and its
/// answer collected later. An answer to another request that arrives first is
/// kept for that request's `collect`.
export class Acp {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private inputEnded = false;
  private nextId = 1;
  private parked = new Map<number, any>();
  stderr = "";
  readonly exited: Promise<number>;
  /// Resolves once fx's stdout has ended, after its last line was read.
  readonly readerDone: Promise<void>;
  /// Set by `listen`: each message fx writes goes here, in arrival order.
  private listener: ((message: any) => void) | null = null;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      for (const waiter of this.waiters.splice(0)) waiter("");
      return code;
    })();
    this.readerDone = (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) {
          if (!line.trim()) continue;
          if (this.listener) {
            this.listener(JSON.parse(line));
            continue;
          }
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
    // Once the client has closed its input, nothing it writes reaches fx, and
    // a request from fx to it has no answer to write.
    if (this.inputEnded) return;
    (this.proc.stdin as any).write(text);
    (this.proc.stdin as any).flush?.();
  }

  /// Answers a request fx sends the client, and reports whether `message` was one.
  private answerAgentRequest(message: any): boolean {
    if (!("method" in message && "id" in message)) return false;
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } })}\n`);
    return true;
  }

  /// Writes a request and returns its id, without waiting for the answer.
  send(method: string, params: Record<string, unknown>): number {
    const id = this.nextId++;
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return id;
  }

  /// Reads until fx answers `id`. It returns the notifications read before that
  /// answer, and the answer to any other request is kept for its own `collect`.
  async collect(id: number, timeoutMs = 60_000): Promise<{ response: any; notifications: any[] }> {
    const parked = this.parked.get(id);
    if (parked) {
      this.parked.delete(id);
      return { response: parked, notifications: [] };
    }
    const notifications: any[] = [];
    while (true) {
      const message = await this.readMessage(timeoutMs);
      if (this.answerAgentRequest(message)) continue;
      if (message.id === id) return { response: message, notifications };
      if ("id" in message) this.parked.set(message.id, message);
      else notifications.push(message);
    }
  }

  async call(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<{ response: any; notifications: any[] }> {
    return this.collect(this.send(method, params), timeoutMs);
  }

  /// Hands each message fx writes to `listener`, in arrival order, from now on.
  /// Messages already read and not yet collected go to it first, in order.
  listen(listener: (message: any) => void): void {
    this.listener = listener;
    for (const message of this.parked.values()) listener(message);
    this.parked.clear();
    for (const line of this.lines.splice(0)) listener(JSON.parse(line));
  }

  /// Closes the client's input, as a client that goes away does. fx reads the
  /// end of input and stops taking requests from this client.
  disconnect(): void {
    if (this.inputEnded) return;
    this.inputEnded = true;
    (this.proc.stdin as any).end();
  }

  /// Waits for fx to exit. It reports whether fx exited within `timeoutMs`, and
  /// its exit code when it did. Once fx has exited, every message it wrote has
  /// been read, and handed to the listener, before this returns.
  async waitForExit(timeoutMs: number): Promise<{ exited: boolean; code: number | null }> {
    const outcome = await Promise.race([
      this.exited.then((code) => ({ exited: true, code })),
      Bun.sleep(timeoutMs).then(() => ({ exited: false, code: null })),
    ]);
    if (outcome.exited) await this.readerDone;
    return outcome;
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed && !this.inputEnded) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

/// An isolated fx home, workspace, and fake Gateway for one plan. fx starts on
/// `initialModel`, and every prompt's reply comes from the plan's queue.
export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  acp: Acp | null = null;
  /// The fake Gateway this plan's fx talks to. `requests` lists each model
  /// request in order, with its headers.
  gateway: any = null;

  constructor(private readonly fxBin: string, private readonly initialModel: string) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-disconnect-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
    writeFileSync(join(this.workspace, "note.txt"), "DISCONNECT_NOTE\n", { mode: 0o600 });
  }

  init(gateway: unknown) {
    this.gateway = gateway;
  }

  private env(): Record<string, string> {
    return testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-disconnect-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: this.initialModel,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
  }

  /// Starts a new fx acp process and initializes it with the client's
  /// capabilities. Returns the answer to `initialize`.
  async start(capabilities: Record<string, unknown>): Promise<any> {
    if (this.acp) await this.close();
    this.acp = new Acp(Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    const { response } = await this.acp.call("initialize", { protocolVersion: 1, clientCapabilities: capabilities });
    return response;
  }

  /// Closes the open process, as a client that goes away does.
  async close(): Promise<void> {
    if (!this.acp) return;
    this.processes.push(await this.acp.close());
    this.acp = null;
  }

  dispose() {
    this.acp = null;
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
