// Runtime bridge for the many-sessions driver: an fx acp process in full
// access with two workspaces, and a fake Gateway that holds every model
// request until the driver ends it, with a file write or with final text.
// Each request is matched to the prompt it answers by the "turn A 1" marker
// of its last user message.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../../lib/context";
import { Acp } from "../prompt_delivery/harness";

export { Acp };

export type Label = "A" | "B";
export type Ws = "W1" | "W2";

/// One model request the fake Gateway holds for prompt `label n`.
export type Hold = {
  label: Label;
  n: number;
  end(kind: "write" | "final"): void;
  aborted: boolean;
  ended: boolean;
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

/// The marker a prompt's text carries, and the files and text it produces.
export const marker = (label: Label, n: number) => `turn ${label} ${n}`;
export const writtenFile = (label: Label, n: number) => `write-${label}-${n}.txt`;
export const finalTextOf = (label: Label, n: number) => `TEXT_${label}_${n}`;

/// The prompt a request answers: the last "turn A 1" marker in its body.
function promptOf(body: string): { label: Label; n: number } | null {
  const matches = [...body.matchAll(/turn ([AB]) (\d+)/g)];
  const last = matches.at(-1);
  return last ? { label: last[1] as Label, n: Number(last[2]) } : null;
}

export class Fixture {
  readonly root: string;
  readonly home: string;
  readonly launch: string;
  readonly workspaces: Record<Ws, string>;
  readonly acpLog: object[] = [];
  readonly holds: Hold[] = [];
  readonly processes: Array<{ exit: number; stderr: string }> = [];
  acp: Acp | null = null;
  private gateway: any = null;

  constructor(private readonly fxBin: string = binary) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), "fx-acp-sessions-")));
    this.home = join(this.root, "home");
    this.launch = join(this.root, "launch");
    this.workspaces = { W1: join(this.root, "w1"), W2: join(this.root, "w2") };
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    for (const dir of [this.launch, this.workspaces.W1, this.workspaces.W2]) mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, permission_mode: "full-access" })}\n`, { mode: 0o600 });
  }

  async init() {
    const helpers = await targetHelpers();
    this.gateway = helpers.startDynamicFakeGateway((body: string) => {
      const prompt = promptOf(body);
      let controller!: ReadableStreamDefaultController<Uint8Array>;
      const hold: Hold = {
        label: prompt?.label ?? "A",
        n: prompt?.n ?? 0,
        aborted: false,
        ended: false,
        end: (kind) => {
          if (hold.aborted || hold.ended) return;
          hold.ended = true;
          if (kind === "write") {
            controller.enqueue(sse({
              type: "tool-call", toolCallId: `call_${hold.label}_${hold.n}`, toolName: "write_file",
              input: { path: writtenFile(hold.label, hold.n), content: marker(hold.label, hold.n) },
            }));
            controller.enqueue(sse({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } }));
          } else {
            controller.enqueue(sse({ type: "text-delta", id: "answer_1", delta: finalTextOf(hold.label, hold.n) }));
            controller.enqueue(sse({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } } }));
          }
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        },
      };
      const stream = new ReadableStream<Uint8Array>({
        start(c) { controller = c; },
        cancel() { hold.aborted = true; },
      });
      this.holds.push(hold);
      return new Response(stream, { headers: { "content-type": "text/event-stream" } });
    }, {});
  }

  /// The open hold of prompt `label n`, if the model was asked for it.
  openHold(label: Label, n: number): Hold | undefined {
    return this.holds.find((hold) => hold.label === label && hold.n === n && !hold.ended && !hold.aborted);
  }

  /// Which workspace a write of prompt `label n` landed in.
  writeLocation(label: Label, n: number): Ws | "launch" | "none" {
    const name = writtenFile(label, n);
    for (const ws of ["W1", "W2"] as const) if (existsSync(join(this.workspaces[ws], name))) return ws;
    return existsSync(join(this.launch, name)) ? "launch" : "none";
  }

  async start(): Promise<Acp> {
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-sessions-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    });
    this.acp = new Acp(
      Bun.spawn([this.fxBin, "acp"], { cwd: this.launch, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" }),
      (entry) => this.acpLog.push(entry),
    );
    const initialized = await this.acp.request("initialize", { protocolVersion: 1 });
    if (initialized.error) throw new Error(`initialize failed: ${JSON.stringify(initialized.error)}`);
    return this.acp;
  }

  async dispose() {
    for (const hold of this.holds) hold.end("final");
    if (this.acp) this.processes.push(await this.acp.close());
    this.acp = null;
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}
