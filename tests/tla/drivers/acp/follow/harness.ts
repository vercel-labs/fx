// Runtime bridge for the follow driver: an fx acp process and its stdio, a
// client that keeps the notifications each call read, and an isolated home,
// workspace and fake Gateway for one plan.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, testEnvironment } from "../../lib/context";

/// One fx acp process and its stdio. A call returns fx's answer together
/// with the notifications the client read before it, which is where a load's
/// replayed messages are.
export class Acp {
  private buffer = "";
  private lines: string[] = [];
  private waiters: Array<(line: string) => void> = [];
  private closed = false;
  private nextId = 1;
  stderr = "";
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>) {
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
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } })}\n`);
    return true;
  }

  async call(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<{ response: any; notifications: any[] }> {
    const id = this.nextId++;
    this.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    const notifications: any[] = [];
    while (true) {
      const message = await this.readMessage(timeoutMs);
      if (this.answerAgentRequest(message)) continue;
      if (message.id === id) return { response: message, notifications };
      notifications.push(message);
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

/// An isolated fx home, workspace, and fake Gateway for one plan. Every
/// prompt's reply comes from the plan's queue.
export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  acp: Acp | null = null;
  private gateway: any = null;

  constructor(private readonly fxBin: string = binary) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-follow-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
    writeFileSync(join(this.workspace, "note.txt"), "FOLLOW_IDS_NOTE\n", { mode: 0o600 });
  }

  init(gateway: unknown) {
    this.gateway = gateway;
  }

  private env(): Record<string, string> {
    return testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-follow-fake-key",
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
    if (this.acp) await this.close();
    this.acp = new Acp(Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    const { response } = await this.acp.call("initialize", { protocolVersion: 1 });
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
