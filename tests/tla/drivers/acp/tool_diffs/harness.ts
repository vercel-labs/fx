// Runtime bridge for the tool diffs driver: an fx acp process with a
// workspace of starting files, a fake Gateway that serves a plan's replies
// in order, and a client that keeps every message fx sends, in order, and
// answers each permission request as the plan says.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../../lib/context";

export class Client {
  private buffer = "";
  private nextId = 1;
  private readonly waiters = new Map<number, (message: any) => void>();
  stderr = "";
  readonly inbox: any[] = [];
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>, private readonly answer: (request: any) => "allow_once" | "reject_once") {
    this.exited = proc.exited;
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
    this.inbox.push(message);
    if ("method" in message && "id" in message) {
      if (message.method === "session/request_permission") {
        const optionId = this.answer(message.params);
        this.write({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "selected", optionId } } });
      } else {
        this.write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
      }
      return;
    }
    if ("id" in message) {
      this.waiters.get(message.id)?.(message);
      this.waiters.delete(message.id);
    }
  }

  private write(message: object) {
    (this.proc.stdin as any).write(`${JSON.stringify(message)}\n`);
    (this.proc.stdin as any).flush?.();
  }

  request(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<any> {
    const id = this.nextId++;
    const answer = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      this.waiters.set(id, (message) => { clearTimeout(timer); resolve(message); });
    });
    this.write({ jsonrpc: "2.0", id, method, params });
    return answer;
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

/// One tool call of a reply: its tool and arguments, with `path` relative to
/// the workspace.
export type ToolCall = { tool: "write_file" | "edit_file"; input: Record<string, string> };

export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  gateway: any = null;

  constructor(readonly files: Record<string, string>, readonly mode: "full-access" | "ask") {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-acp-tool-diffs-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, permission_mode: mode })}\n`, { mode: 0o600 });
    for (const [name, text] of Object.entries(files)) writeFileSync(join(this.workspace, name), text);
  }

  /// Each step is one model reply: its tool calls, or the final text.
  async start(steps: ToolCall[][], answer: (request: any) => "allow_once" | "reject_once"): Promise<Client> {
    const helpers = await targetHelpers();
    let n = 0;
    const replies = steps.map((calls) => helpers.fakeGatewaySse([
      ...calls.map((call) => ({ type: "tool-call", toolCallId: `diff_call_${++n}`, toolName: call.tool, input: call.input })),
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]));
    replies.push(helpers.fakeGatewaySse([
      { type: "text-delta", id: "answer_1", delta: "TOOL_DIFFS_DONE" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]));
    // A window big enough that a 1 MiB write never makes fx compact.
    this.gateway = helpers.startFakeGateway(replies, {
      models: [{ id: helpers.FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 4_000_000 }],
    });
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-tool-diffs-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
    const client = new Client(Bun.spawn([binary, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }), answer);
    const initialized = await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    if (initialized.error) throw new Error(`initialize failed: ${JSON.stringify(initialized.error)}`);
    return client;
  }

  /// A workspace file's text now, or null when it doesn't exist.
  read(name: string): string | null {
    const path = join(this.workspace, name);
    return existsSync(path) ? readFileSync(path, "utf8") : null;
  }

  dispose() {
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
