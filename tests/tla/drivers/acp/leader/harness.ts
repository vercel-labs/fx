// Runtime bridge for the leader driver: one plan's isolated home and workspace,
// its fake Gateway, the fx acp processes the plan starts, and a client for a
// leader socket. Each process that can listen gets its own TMPDIR, a new folder
// under the plan's root, so its socket folder goes with the root. A process the
// plan starts with canListen false gets a TMPDIR that does not exist, so its
// socket cannot start. The stdio client is the disconnect driver's Acp.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import { testEnvironment } from "../../lib/context";
import { Acp } from "../disconnect/harness";

export { Acp };

/// The TMPDIR of a process that must not be able to start its socket.
export const NO_SOCKET_TMPDIR = "/nonexistent-fx-leader";

export class LeaderFixture {
  readonly root: string;
  readonly home: string;
  readonly workspace: string;
  private tmpdirs = 0;
  gateway: any = null;

  constructor(private readonly fxBin: string, private readonly model: string) {
    this.root = realpathSync(mkdtempSync(join("/tmp", "fx-leader-")));
    this.home = join(this.root, "home");
    this.workspace = join(this.root, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
  }

  init(gateway: unknown) {
    this.gateway = gateway;
  }

  /// Starts an fx acp process with `TMPDIR` set for its socket.
  spawn(canListen: boolean): { acp: Acp; tmpdir: string } {
    const tmpdir = canListen ? this.newTmpdir() : NO_SOCKET_TMPDIR;
    const env = testEnvironment({
      NO_COLOR: "1",
      HOME: this.home,
      AI_GATEWAY_API_KEY: "acp-leader-fake-key",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_MODEL: this.model,
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      TMPDIR: tmpdir,
    });
    const proc = Bun.spawn([this.fxBin, "acp"], { cwd: this.workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    return { acp: new Acp(proc), tmpdir };
  }

  private newTmpdir(): string {
    this.tmpdirs += 1;
    const dir = join(this.root, `tmp-${this.tmpdirs}`);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    return dir;
  }

  dispose() {
    this.gateway?.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}

export type SocketAnswer = { connected: boolean; reply: any | null };

/// Connects to a leader socket and sends one request. `connected` is false when
/// the connection is refused or the socket file is gone: the socket is stale.
/// Once connected, the answer is the reply line, and a close before it is an error.
export function askSocket(socketPath: string, request: object, timeoutMs = 10_000): Promise<SocketAnswer> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path: socketPath });
    let connected = false;
    let text = "";
    let done = false;
    const finish = (settle: () => void) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      socket.destroy();
      settle();
    };
    const timer = setTimeout(() => finish(() => reject(new Error(`no reply from ${socketPath}`))), timeoutMs);
    socket.setEncoding("utf8");
    socket.on("connect", () => {
      connected = true;
      socket.write(`${JSON.stringify(request)}\n`);
    });
    socket.on("data", (chunk: string) => {
      text += chunk;
      const end = text.indexOf("\n");
      if (end === -1) return;
      finish(() => resolve({ connected: true, reply: JSON.parse(text.slice(0, end)) }));
    });
    socket.on("error", () =>
      finish(() => (connected ? reject(new Error(`${socketPath} failed after it connected`)) : resolve({ connected: false, reply: null }))),
    );
    socket.on("close", () =>
      finish(() => (connected ? reject(new Error(`${socketPath} closed before it replied`)) : resolve({ connected: false, reply: null }))),
    );
  });
}
