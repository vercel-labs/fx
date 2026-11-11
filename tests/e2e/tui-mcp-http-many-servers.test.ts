// The TUI starts every configured MCP server when it opens. With many HTTP
// servers connecting at once, a connect that a signal interrupted was
// reported as failed although the kernel finished it: fx panicked with
// "programmer bug caused syscall error: ISCONN" in Debug builds and dropped
// the connection in release builds. `src/core/shared/net_connect.zig` owns
// the connect that fixes it.
import { afterEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
} from "../evals/eval-helpers";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SERVERS = 50;
const STARTS = 3;

type SilentServer = Awaited<ReturnType<typeof startSilentServer>>;

let tui: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let silent: SilentServer | null = null;
let home: string | null = null;

afterEach(async () => {
  await stopStart();
});

async function stopStart() {
  const activeTui = tui;
  const activeGateway = gateway;
  const activeSilent = silent;
  const activeHome = home;
  tui = null;
  gateway = null;
  silent = null;
  home = null;
  if (activeTui) await activeTui.kill();
  activeGateway?.stop();
  await activeSilent?.stop();
  if (activeHome) cleanupIsolatedTestHome(activeHome);
}

// Accepts every connection and never answers. Records the first request
// line of each connection, and counts the connections that close before
// sending one: fx closes a connect it took for failed.
async function startSilentServer() {
  const sockets = new Set<Socket>();
  const requests: string[] = [];
  let closedWithoutRequest = 0;
  const server = createServer((socket) => {
    sockets.add(socket);
    let requested = false;
    socket.once("data", (chunk) => {
      requested = true;
      requests.push(chunk.toString("latin1").split("\r\n", 1)[0] ?? "");
    });
    socket.on("error", () => {});
    socket.on("close", () => {
      sockets.delete(socket);
      if (!requested) closedWithoutRequest += 1;
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", 511, resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no port");
  return {
    port: address.port,
    requests,
    closedWithoutRequest: () => closedWithoutRequest,
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

async function waitUntil(done: () => boolean, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (!done() && Date.now() < deadline) await Bun.sleep(25);
  return done();
}

test.skipIf(!tmuxAvailable())(
  `the TUI connects all ${SERVERS} HTTP MCP servers it starts at once`,
  async () => {
    for (let start = 1; start <= STARTS; start++) {
      silent = await startSilentServer();
      home = createIsolatedTestHome();
      const workspace = join(home, "workspace");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
      const servers: Record<string, unknown> = {};
      for (let i = 1; i <= SERVERS; i++) {
        servers[`silent${i}`] = {
          type: "http",
          url: `http://127.0.0.1:${silent.port}/mcp/${i}`,
          startup_timeout_ms: 60_000,
        };
      }
      writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: servers }));
      gateway = startFakeGateway([]);
      const stderrPath = join(home, "stderr.log");
      tui = await TmuxSession.create({
        isolated: true,
        cwd: workspace,
        width: 110,
        height: 30,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-many-servers-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        },
      });
      const stderr = () => readFileSync(stderrPath, "utf8");
      // fx starts the servers with its first frame, so a crash can come
      // before the composer shows.
      await tui.waitForComposer(15_000).catch((err) => {
        throw new Error(`start ${start}: no composer; stderr: ${stderr().slice(0, 400)}`, {
          cause: err,
        });
      });

      // Each server sends its first request once its connect is done.
      const active = silent;
      const paths = () => new Set(active.requests.map((line) => line.split(" ")[1]));
      const allSent = await waitUntil(() => paths().size === SERVERS, 30_000);
      expect({ start, allSent, sent: paths().size }).toEqual({ start, allSent: true, sent: SERVERS });
      expect({ start, closedWithoutRequest: active.closedWithoutRequest() }).toEqual({
        start,
        closedWithoutRequest: 0,
      });
      expect(tui.isAlive()).toBe(true);
      expect(stderr()).not.toContain("programmer bug caused syscall error");
      const screen = await tui.capturePane();
      expect(screen).not.toContain("need attention");
      expect(screen).not.toContain("failed ·");

      await stopStart();
    }
  },
  180_000,
);
