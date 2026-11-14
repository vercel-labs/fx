// A client of the minimal ACP kernel that libfx runs in the native addon
// (zig-out/lib/libfx.node, built with `zig build libfx-napi
// -Dnapi-surface=core`). Only that kernel serves the libfx/* methods; plain
// `fx acp` answers them with -32601. It sends raw JSON-RPC lines, so a driver
// can name any session, and it reads the kernel's output with the SDK's own
// framing. It makes no model requests: a request for one fails the run.
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { join } from "node:path";
import { worktree } from "../../lib/context";

// The SDK's framing of the core's output (sdk/core-output.js).
const { CoreOutput } = await import(join(worktree, "sdk", "core-output.js"));

export const addonPath = join(worktree, "zig-out", "lib", "libfx.node");

export class Kernel {
  private readonly pending = new Map<number, (message: any) => void>();
  private nextId = 1;
  private settled = false;
  private draining = false;
  private failure: Error | null = null;
  private readonly socket: Socket;
  private readonly output: any;
  readonly exited: Promise<void>;
  private exitedResolve!: () => void;

  private constructor(private readonly addon: any, private readonly core: unknown, readyFd: number, private readonly log: (entry: object) => void) {
    this.exited = new Promise((resolve) => { this.exitedResolve = resolve; });
    this.output = new CoreOutput((message: any) => this.receive(message));
    this.socket = new Socket({ fd: readyFd, readable: true, writable: false });
    this.socket.on("data", () => this.drainReady());
    this.socket.on("end", () => { this.drainReady(); this.finish(null); });
    this.socket.on("error", (error) => this.finish(error));
    this.socket.on("close", () => this.finish(null));
    // As sdk/node.js does: a socket made from an fd may still need connecting.
    if (this.socket.pending) this.socket.connect({ fd: readyFd } as any);
  }

  /// Starts a kernel whose profile is `home` and whose workspace is `workspace`.
  static start(home: string, workspace: string, log: (entry: object) => void): Kernel {
    if (!existsSync(addonPath)) throw new Error(`missing ${addonPath}; run zig build libfx-napi -Dnapi-surface=core`);
    const addon = createRequire(import.meta.url)(addonPath);
    const core = addon.createCore({ apiKey: "acp-session-target-fake-key", home, workspaceRoot: workspace });
    return new Kernel(addon, core, addon.takeCoreReadyFd(core), log);
  }

  private receive(message: any) {
    if ("method" in message && "id" in message) {
      // The kernel asks its host for things such as journal flushes; this
      // client is not a host.
      this.log({ dir: "in-request", method: message.method });
      this.write({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
      return;
    }
    if (typeof message.id === "number") this.pending.get(message.id)?.(message);
  }

  private drainReady() {
    if (this.settled) return;
    try {
      if (this.addon.takeCoreFetch(this.core)) {
        this.finish(new Error("the kernel asked for a model request, which this client never serves"));
        return;
      }
      void this.drainOutput();
    } catch (error) {
      this.finish(error as Error);
    }
  }

  private async drainOutput() {
    if (this.draining || this.settled) return;
    this.draining = true;
    try {
      while (!this.settled) {
        const chunk = this.addon.drainCore(this.core);
        if (!chunk.length) break;
        const pending = this.output.write(chunk);
        if (pending) await pending;
      }
      if (!this.settled && this.addon.coreExited(this.core)) this.finish(null);
    } catch (error) {
      this.finish(error as Error);
    } finally {
      this.draining = false;
    }
  }

  private finish(error: Error | null) {
    if (this.settled) return;
    this.settled = true;
    this.failure = error;
    this.output.close();
    this.socket.destroy();
    for (const resolve of this.pending.values()) resolve({ error: { code: 0, message: `kernel ended: ${error?.message ?? "exit"}` } });
    this.pending.clear();
    this.exitedResolve();
  }

  private write(message: object) {
    this.addon.writeCore(this.core, Buffer.from(`${JSON.stringify(message)}\n`));
  }

  async call(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<any> {
    if (this.settled) throw new Error(`kernel ended: ${this.failure?.message ?? "exit"}`);
    const id = this.nextId++;
    this.log({ dir: "out", id, method, params });
    const answer = new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`kernel read timeout for ${method}`)); }, timeoutMs);
      this.pending.set(id, (message) => { clearTimeout(timer); this.pending.delete(id); resolve(message); });
    });
    this.write({ jsonrpc: "2.0", id, method, params });
    const message = await answer;
    this.log({ dir: "in", id, method, error: message.error ?? null, result: message.result ?? null });
    return message;
  }

  /// Ends the kernel's input and waits for it to stop, then frees it.
  async close(): Promise<{ exit: number; error: string | null }> {
    if (!this.settled) this.addon.closeCore(this.core);
    const timer = setTimeout(() => this.finish(new Error("the kernel did not stop within 5 s")), 5_000);
    await this.exited;
    clearTimeout(timer);
    const exit = this.addon.coreExited(this.core) ? Number(this.addon.coreExitCode(this.core)) : 1;
    try { this.addon.destroyCore(this.core); } catch {}
    return { exit: this.failure ? 1 : exit, error: this.failure?.message ?? null };
  }
}
