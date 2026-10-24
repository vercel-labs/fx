// A 2025-11-25 stdio MCP server for the mcp-v2-model case. It logs every
// lifecycle event to FIXTURE_LOG as JSONL ({t, name, pid, ev, ...}):
//   start, listed (answered tools/list), eof (stdin ended, as it exits),
//   sigterm, recv, sent; stdin_end when FIXTURE_EXIT_DELAY_MS holds the exit.
// Env:
//   FIXTURE_NAME          the server's name in its log lines
//   FIXTURE_LOG           the JSONL log (appended synchronously)
//   FIXTURE_INIT_DELAY_MS hold initialize's answer this long (a slow server)
//   FIXTURE_EXIT_DELAY_MS once stdin ends, exit only this much later (a slow stop)
//   FIXTURE_CONTROL       a folder; the elicit tool waits for "go" in it
// Tools: echo (answers at once), elicit (2025 elicitations, see below).
import { appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const name = process.env.FIXTURE_NAME ?? "fixture";
const logPath = process.env.FIXTURE_LOG;
const initDelay = Number(process.env.FIXTURE_INIT_DELAY_MS ?? "0");
const exitDelay = Number(process.env.FIXTURE_EXIT_DELAY_MS ?? "0");
const control = process.env.FIXTURE_CONTROL;
const log = (ev: string, extra: object = {}) => {
  if (logPath) appendFileSync(logPath, JSON.stringify({ t: Date.now(), name, pid: process.pid, ev, ...extra }) + "\n");
};
const send = (message: object) => {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
  log("sent", { message });
};
log("start");
process.on("SIGTERM", () => {
  log("sigterm");
  process.exit(0);
});

const tools = [
  { name: "echo", description: "Echo text back", inputSchema: { type: "object", properties: { text: { type: "string" } } } },
  { name: "elicit", description: "Ask the user two questions, withdrawing the first", inputSchema: { type: "object" } },
];
const form = (n: number) => ({
  mode: "form",
  message: `Question ${n}`,
  requestedSchema: { type: "object", properties: { answer: { type: "string", title: `Answer ${n}`, description: `What do you say to question ${n}?` } }, required: ["answer"] },
});
const waiters = new Map<string, (message: { result?: { action?: string; content?: { answer?: string } } }) => void>();

async function elicit(callId: unknown) {
  // Question 1, then (once the harness says go) its withdrawal and question 2,
  // which the client's slot table puts where question 1 was.
  const answers: Record<string, unknown> = {};
  const answered = (id: string) => new Promise<void>((resolve) => waiters.set(id, (m) => { answers[id] = m.result ?? null; resolve(); }));
  const first = answered("e1");
  send({ id: "e1", method: "elicitation/create", params: form(1) });
  log("ask", { q: 1, id: "e1" });
  const go = control ? join(control, "go") : null;
  const deadline = Date.now() + 60_000;
  let firstDone = false;
  first.then(() => { firstDone = true; });
  while (go && !existsSync(go) && !firstDone && Date.now() < deadline) await Bun.sleep(25);
  if (!firstDone) {
    send({ method: "notifications/cancelled", params: { requestId: "e1", reason: "withdrawn by the fixture" } });
    log("withdraw", { q: 1, id: "e1" });
    const second = answered("e2");
    send({ id: "e2", method: "elicitation/create", params: form(2) });
    log("ask", { q: 2, id: "e2" });
    await Promise.race([second, Bun.sleep(30_000)]);
    // Long enough for fx to show what it holds next.
    await Bun.sleep(Number(process.env.FIXTURE_AFTER_MS ?? "2500"));
  }
  send({ id: callId, result: { content: [{ type: "text", text: `ELICIT_DONE ${JSON.stringify(answers)}` }] } });
  log("call_end", { answers });
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
process.stdin.on("end", () => {
  if (exitDelay === 0) {
    log("eof");
    process.exit(0);
  }
  log("stdin_end");
  setTimeout(() => {
    log("eof");
    process.exit(0);
  }, exitDelay);
});

async function handle(m: { id?: unknown; method?: string; params?: { name?: string }; result?: unknown; error?: unknown }) {
  log("recv", { message: m });
  if (m.method === undefined) {
    const waiter = waiters.get(String(m.id));
    if (waiter) {
      waiters.delete(String(m.id));
      log("answered", { id: m.id, result: m.result ?? null, error: m.error ?? null });
      waiter(m as never);
    }
    return;
  }
  if (m.id === undefined) return; // a notification
  switch (m.method) {
    case "initialize":
      if (initDelay > 0) await Bun.sleep(initDelay);
      return send({ id: m.id, result: { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name, version: "1.0.0" } } });
    case "tools/list":
      send({ id: m.id, result: { tools } });
      return log("listed");
    case "tools/call":
      if (m.params?.name === "elicit") return elicit(m.id);
      return send({ id: m.id, result: { content: [{ type: "text", text: `ECHO ${name}` }] } });
    case "ping":
      return send({ id: m.id, result: {} });
    default:
      return send({ id: m.id, error: { code: -32601, message: "Method not found" } });
  }
}
