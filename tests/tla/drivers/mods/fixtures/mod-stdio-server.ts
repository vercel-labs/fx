// Fixture stdio MCP server for `tests/tla/drivers/mods/driver.ts` (`serve-walk`).
//
// Logs JSONL events to `FIXTURE_LOG` (appended synchronously):
//   start, listed, call_start, call_end, read_ok, read_err, stdin_end, eof, sigterm
// Each event carries `{ t, name, pid, ppid, cwd, ev, ... }`.
//
// Env:
//   FIXTURE_NAME             Server name in logs (default: "fixture")
//   FIXTURE_LOG              Path to JSONL event log
//   FIXTURE_CONTROL          Directory holding optional hold files
//   FIXTURE_MARKER           Relative marker file in cwd (default: "version.txt")
//   FIXTURE_HOLD_CALL_FILE   Control filename inside FIXTURE_CONTROL; `slow` waits while it exists
//   FIXTURE_HOLD_EXIT_FILE   Control filename inside FIXTURE_CONTROL; stdin EOF waits while it exists
//   FIXTURE_EXIT_DELAY_MS    Fixed delay after stdin EOF before exiting (default: 0)
//   FIXTURE_MAX_HOLD_MS      Cap for hold-file waits (default: 900 ms, well under stdio_conn's 1500 ms SIGTERM grace)
//   FIXTURE_KILL_PATH        If "1", disables max-hold cap and ignores SIGTERM so Engine's 3500 ms kill path fires
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const name = process.env.FIXTURE_NAME ?? "fixture";
const logPath = process.env.FIXTURE_LOG;
const controlDir = process.env.FIXTURE_CONTROL ?? "";
const markerName = process.env.FIXTURE_MARKER ?? "version.txt";
const holdCallFile = process.env.FIXTURE_HOLD_CALL_FILE ?? "";
const holdExitFile = process.env.FIXTURE_HOLD_EXIT_FILE ?? "";
const exitDelayMs = Number(process.env.FIXTURE_EXIT_DELAY_MS ?? "0");
const maxHoldMs = Number(process.env.FIXTURE_MAX_HOLD_MS ?? "900");
const killPath = process.env.FIXTURE_KILL_PATH === "1";

const cwd = process.cwd();

function log(ev: string, extra: Record<string, unknown> = {}) {
  if (!logPath) return;
  const line = JSON.stringify({
    t: Date.now(),
    name,
    pid: process.pid,
    ppid: process.ppid,
    cwd,
    ev,
    ...extra,
  });
  appendFileSync(logPath, `${line}\n`);
}

function readMarker(phase: string): string | null {
  try {
    const marker = readFileSync(join(cwd, markerName), "utf8").trim();
    log("read_ok", { phase, marker });
    return marker;
  } catch (err: any) {
    log("read_err", { phase, code: err?.code ?? String(err) });
    return null;
  }
}

function send(message: Record<string, unknown>) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
}

async function waitWhileControlFileExists(fileName: string) {
  if (!controlDir || !fileName) return;
  const full = join(controlDir, fileName);
  const started = Date.now();
  while (existsSync(full)) {
    if (!killPath && Date.now() - started >= maxHoldMs) break;
    await Bun.sleep(20);
  }
}

log("start");
readMarker("start");

process.on("SIGTERM", () => {
  if (killPath) {
    log("sigterm_ignored");
    return;
  }
  readMarker("sigterm");
  log("sigterm");
  process.exit(0);
});

const tools = [
  { name: "echo", description: "Read marker at once", inputSchema: { type: "object", properties: { text: { type: "string" } } } },
  { name: "slow", description: "Hold until control file is removed, then read marker", inputSchema: { type: "object" } },
];

let activeCalls = 0;

async function handle(m: { id?: unknown; method?: string; params?: { name?: string } }) {
  if (m.id === undefined || m.method === undefined) return;
  switch (m.method) {
    case "initialize":
      return send({
        id: m.id,
        result: {
          protocolVersion: "2025-11-25",
          capabilities: { tools: {} },
          serverInfo: { name, version: "1.0.0" },
        },
      });
    case "tools/list":
      send({ id: m.id, result: { tools } });
      log("listed");
      return;
    case "tools/call": {
      const tool = m.params?.name ?? "";
      activeCalls += 1;
      try {
        log("call_start", { id: m.id, tool });
        readMarker("call_start");
        if (tool === "slow") {
          await waitWhileControlFileExists(holdCallFile);
        }
        const marker = readMarker("call_end");
        log("call_end", { id: m.id, tool, marker });
        return send({
          id: m.id,
          result: { content: [{ type: "text", text: `${tool.toUpperCase()} ${name} ${marker ?? "MISSING"}` }] },
        });
      } finally {
        activeCalls -= 1;
      }
    }
    case "ping":
      return send({ id: m.id, result: {} });
    default:
      return send({ id: m.id, error: { code: -32601, message: "Method not found" } });
  }
}

let buffer = "";
process.stdin.on("data", (chunk) => {
  buffer += chunk.toString();
  for (let at = buffer.indexOf("\n"); at >= 0; at = buffer.indexOf("\n")) {
    const line = buffer.slice(0, at).trim();
    buffer = buffer.slice(at + 1);
    if (line) void handle(JSON.parse(line));
  }
});

process.stdin.on("end", async () => {
  log("stdin_end");
  const started = Date.now();
  while (activeCalls > 0) {
    if (!killPath && Date.now() - started >= maxHoldMs) break;
    await Bun.sleep(15);
  }
  if (holdExitFile) {
    await waitWhileControlFileExists(holdExitFile);
  }
  if (exitDelayMs > 0) {
    const bounded = killPath ? exitDelayMs : Math.min(exitDelayMs, maxHoldMs);
    await Bun.sleep(bounded);
  }
  readMarker("eof");
  log("eof");
  process.exit(0);
});
