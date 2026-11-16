// Runtime bridge for the turn events driver: an fx acp process in full
// access that compacts at 20 percent, a fake Gateway that serves each turn's
// replies in order, and a client that keeps every message fx sends, in the
// order it read them.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../../lib/context";

/// An fx acp process and every message it sent, in order.
export class Client {
  private buffer = "";
  private nextId = 1;
  private readonly waiters = new Map<number, (message: any) => void>();
  stderr = "";
  readonly inbox: any[] = [];
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>) {
    this.exited = proc.exited;
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) {
          if (!line.trim()) continue;
          const message = JSON.parse(line);
          this.inbox.push(message);
          if ("id" in message && !("method" in message)) {
            this.waiters.get(message.id)?.(message);
            this.waiters.delete(message.id);
          }
        }
      }
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  /// Sends a request; resolves with its answer and the inbox position after it.
  request(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<{ answer: any; id: number }> {
    const id = this.nextId++;
    const answer = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      this.waiters.set(id, (message) => { clearTimeout(timer); resolve(message); });
    });
    (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    (this.proc.stdin as any).flush?.();
    return answer.then((value) => ({ answer: value, id }));
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

/// The third turn's shell call. Its ACP tool call id is the model's call id.
export const SHELL_CALL_ID = "turn_events_shell_1";
export const SHELL_COMMAND = "cat note.txt";

/// A large reply: past 20 percent of the fake model's 128,000-token window,
/// so the next turn compacts first, with no model call.
const LARGE = "TURN_EVENTS_LARGE\n" + "historical reference line, not new completed work.\n".repeat(2_400);

export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  gateway: any = null;

  constructor() {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-acp-turn-events-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, permission_mode: "full-access" })}\n`, { mode: 0o600 });
    writeFileSync(join(this.workspace, "note.txt"), "TURN_EVENTS_NOTE\n");
  }

  /// Turn 1: the large reply. Turn 2: compaction, then a reply. Turn 3: a
  /// shell call, then a reply.
  async start(capabilities: object): Promise<Client> {
    const helpers = await targetHelpers();
    const reply = (text: string, usage: boolean) => helpers.fakeGatewaySse([
      { type: "text-delta", id: "answer_1", delta: text },
      {
        type: "finish",
        finishReason: { unified: "stop", raw: "stop" },
        ...(usage ? { usage: { inputTokens: { total: 900, noCache: 900, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 12, text: 12, reasoning: 0 } } } : {}),
      },
    ]);
    // The large reply reports no usage, so fx sizes the conversation by its
    // own estimate and compacts before the next turn.
    this.gateway = helpers.startFakeGateway(
      [reply(LARGE, false), reply("TURN_EVENTS_SECOND", true), helpers.fakeGatewayToolCall(SHELL_CALL_ID, "shell", { request: { action: "run", command: SHELL_COMMAND, yield_time_ms: 30_000 } }), reply("TURN_EVENTS_THIRD", true)],
      { models: [{ id: helpers.FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128_000 }] },
    );
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-turn-events-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_COMPACT_PERCENT: "20",
      // The fake model, whose 128,000-token window sets the 20 percent.
      FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
    const client = new Client(Bun.spawn([binary, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    const { answer } = await client.request("initialize", { protocolVersion: 1, clientCapabilities: capabilities });
    if (answer.error) throw new Error(`initialize failed: ${JSON.stringify(answer.error)}`);
    return client;
  }

  get requests(): Array<{ body: string }> {
    return this.gateway?.requests ?? [];
  }

  dispose() {
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
