// Scripted fake Streamable HTTP MCP server (U06, U07), like fakes/stdio.ts.
//
// Listens on 127.0.0.1 at a free port and prints {"listening": <port>} first.
// Every POST request is matched against the rules in order: the first rule
// whose method (and, if given, version, cursor, or tool name) matches and
// still has uses left answers it. An unmatched request gets 404 with -32601
// (the 2026 answer for an unknown method); notifications and replies get 202.
// Every request is logged with its headers to --log as JSONL, and so is every
// stream the client closes early.
//
// 2025 sessions (U07), with --session: initialize's answer assigns
// `Mcp-Session-Id: s<n>`. Later requests without it get 400, and with an
// ended or unknown one 404 with a JSON-RPC error and no id, as the TypeScript
// SDK answers. A rule's `endSession` ends the session after answering. SSE
// answers may carry event ids (`ids`), a `retry`, and `poll` closes the stream
// after its first events, keeping the answer: a GET with Last-Event-ID gets
// it. A GET without one is the listening stream (--listen 405|open|close).
// DELETE ends the session (--delete-status, 200 by default).
//
// OAuth (U09), with --auth <config.json>: see fakes/oauth.ts. Its endpoints are
// answered first, and the MCP endpoint's gate runs before any rule.
//
// Usage: bun tests/tla/drivers/mcp/fakes/http.ts --script <rules.json> [--log <file>]
//          [--session | --no-session-id] [--listen 405|open|close] [--delete-status <n>]
//          [--initialized-delay <ms>] [--auth <config.json>]

import { appendFileSync, readFileSync } from "node:fs";
import { createAuth, type AuthConfig } from "./oauth";

export interface HttpRule {
  method: string;
  times?: number;
  /** Match the 2026 `_meta` protocol version; null matches none sent. */
  version?: string | null;
  cursor?: string | null;
  /** Match `params.name` (tools/call). */
  name?: string;
  /** HTTP status, 200 by default. */
  status?: number;
  /** Answer as an SSE stream instead of a JSON body. */
  sse?: boolean;
  /** Messages sent before the answer (SSE only), such as progress notifications. */
  before?: unknown[];
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
  /** A raw body instead of a JSON-RPC answer, with this content type. */
  raw?: string;
  contentType?: string;
  /** Wait before answering, in milliseconds. */
  delayMs?: number;
  /** SSE: send the `before` messages, then break the stream without an answer. */
  drop?: boolean;
  /** SSE: send the `before` messages, then keep the stream open without an answer. */
  hang?: boolean;
  /** Extra response headers. */
  headers?: Record<string, string>;
  /** SSE: give every event an id (`<stream>-<n>`), starting with a priming event. */
  ids?: boolean;
  /** SSE: the `retry` field sent with the first event. */
  retry?: number;
  /** SSE: close the stream after the first events without the answer; a GET with Last-Event-ID resumes it. */
  poll?: boolean;
  /** 2025: end the session after answering. */
  endSession?: boolean;
  /** SSE messages sent `laterMs` (default 300) after `before`, on a stream left open (U10). */
  later?: unknown[];
  laterMs?: number;
  /** SSE (U11): after `before`, wait for the client's replies to the requests in it (at most `awaitMs`, default 5000). */
  awaitReply?: boolean;
  awaitMs?: number;
  /** Messages sent on the open listening GET stream `laterMs` after the rule fired (U11). */
  listenLater?: unknown[];
  /** SSE: send the answer, then leave the stream open, as some servers do. */
  keepOpen?: boolean;
}

interface Message {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: { _meta?: Record<string, unknown>; cursor?: string; name?: string };
}

const args = process.argv.slice(2);
const get = (flag: string) => {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
};
const rules = JSON.parse(readFileSync(get("--script") ?? "/dev/null", "utf8") || "[]") as HttpRule[];
const used = rules.map(() => 0);
const logPath = get("--log");
const sessions = args.includes("--session");
// Without --session, answers carry a fixed session id (2026 clients must ignore it) unless --no-session-id.
const noSessionId = args.includes("--no-session-id");
const listenMode = get("--listen") ?? "405";
const deleteStatus = Number(get("--delete-status") ?? "200");
// Holds the 202 to notifications/initialized this long, logging when it was answered.
const initializedDelay = Number(get("--initialized-delay") ?? "0");
// Holds the listening GET's head this long (U11).
const listenDelay = Number(get("--listen-delay") ?? "0");
const log = (entry: object) => {
  if (logPath) appendFileSync(logPath, JSON.stringify({ t: Date.now(), ...entry }) + "\n");
};

const authPath = get("--auth");
const auth = authPath ? createAuth(JSON.parse(readFileSync(authPath, "utf8")) as AuthConfig, () => `http://127.0.0.1:${server.port}`, log) : null;

// A rule's result and SSE messages may say "$id" for the request's id, as a
// listen's subscriptionId must (U10).
const withId = <T>(value: T, id: unknown): T => JSON.parse(JSON.stringify(value).replaceAll('"$id"', JSON.stringify(id ?? null)));

const encoder = new TextEncoder();
const sseEvent = (message: unknown, id?: string, retry?: number) =>
  encoder.encode(`${retry !== undefined ? `retry: ${retry}\n` : ""}${id !== undefined ? `id: ${id}\n` : ""}event: message\ndata: ${message === undefined ? "" : JSON.stringify(message)}\n\n`);

// 2025 sessions.
let sessionCount = 0;
let currentSession: string | null = null;
const ended = new Set<string>();
// Streams kept for a GET with Last-Event-ID: stream name -> the answer still to send.
const kept = new Map<string, { answer: unknown; next: number }>();
let streamCount = 0;
// The open listening GET stream, for `listenLater` (U11).
let listenController: ReadableStreamDefaultController | null = null;
// Replies to the server's requests that a rule waits for: JSON of the id -> resolve.
const replies = new Map<string, () => void>();

function sessionProblem(req: Request, initialize: boolean): Response | null {
  if (!sessions || initialize) return null;
  const id = req.headers.get("mcp-session-id");
  if (!id) return new Response("Bad Request: No valid session ID provided", { status: 400 });
  if (id !== currentSession || ended.has(id))
    return Response.json({ jsonrpc: "2.0", error: { code: -32001, message: "Session not found" }, id: null }, { status: 404 });
  return null;
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  async fetch(req) {
    const headers = Object.fromEntries(req.headers.entries());
    const routed = auth ? await auth.route(req) : null;
    if (routed) return routed;
    if (req.method === "DELETE") {
      log({ dir: "in", httpMethod: "DELETE", headers });
      const denied = auth?.check(req, "DELETE");
      if (denied) return denied;
      const problem = sessionProblem(req, false);
      if (problem) return problem;
      if (currentSession) ended.add(currentSession);
      return new Response(null, { status: deleteStatus });
    }
    if (req.method === "GET") {
      log({ dir: "in", httpMethod: "GET", headers });
      const deniedGet = auth?.check(req, "GET");
      if (deniedGet) return deniedGet;
      const problem = sessionProblem(req, false);
      if (problem) return problem;
      const last = req.headers.get("last-event-id");
      if (last) {
        const name = last.slice(0, last.lastIndexOf("-"));
        const stream = kept.get(name);
        if (!stream) return new Response("Unknown stream", { status: 400 });
        kept.delete(name);
        return new Response(sseEvent(stream.answer, `${name}-${stream.next}`), { headers: { "content-type": "text/event-stream" } });
      }
      if (listenMode === "405") return new Response("Method Not Allowed", { status: 405 });
      const name = `listen${++streamCount}`;
      const body = new ReadableStream({
        start(controller) {
          listenController = controller;
          controller.enqueue(sseEvent(undefined, `${name}-0`));
          if (listenMode === "close") controller.close();
        },
        cancel() {
          listenController = null;
          log({ dir: "closed", stream: name });
        },
      });
      if (listenDelay > 0) await Bun.sleep(listenDelay);
      log({ dir: "listen_open", stream: name });
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    }
    if (req.method !== "POST") {
      log({ dir: "in", httpMethod: req.method, headers });
      return new Response("Method Not Allowed", { status: 405 });
    }
    const text = await req.text();
    log({ dir: "in", httpMethod: "POST", headers, body: text });
    let message: Message;
    try {
      message = JSON.parse(text) as Message;
    } catch {
      return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
    }
    const denied = auth?.check(req, message.method);
    if (denied) return denied;
    const problem = sessionProblem(req, message.method === "initialize");
    if (problem) return problem;
    // Notifications and replies to server requests.
    if (message.id === undefined || message.method === undefined) {
        if (message.method === undefined && message.id !== undefined) replies.get(JSON.stringify(message.id))?.();
        if (message.method === "notifications/initialized" && initializedDelay > 0) {
            await Bun.sleep(initializedDelay);
            log({ dir: "answered", method: message.method });
        }
        return new Response(null, { status: 202 });
    }
    const version = message.params?._meta?.["io.modelcontextprotocol/protocolVersion"] ?? null;
    const index = rules.findIndex(
      (r, i) =>
        r.method === message.method &&
        (r.version === undefined || r.version === version) &&
        (r.cursor === undefined || r.cursor === (message.params?.cursor ?? null)) &&
        (r.name === undefined || r.name === message.params?.name) &&
        (r.times === undefined || used[i] < r.times),
    );
    if (index < 0) return Response.json({ jsonrpc: "2.0", id: message.id ?? null, error: { code: -32601, message: "Method not found" } }, { status: 404 });
    used[index] += 1;
    const rule = rules[index];
    if (rule.listenLater) {
      const messages = rule.listenLater;
      setTimeout(() => {
        for (const m of messages) listenController?.enqueue(sseEvent(m));
      }, rule.laterMs ?? 300);
    }
    if (rule.delayMs) await Bun.sleep(rule.delayMs);
    const status = rule.status ?? 200;
    const extra: Record<string, string> = { ...(rule.headers ?? {}) };
    if (sessions && message.method === "initialize" && status === 200 && !rule.error) {
      currentSession = `s${++sessionCount}`;
      extra["mcp-session-id"] = currentSession;
    } else if (!sessions && !noSessionId && !("mcp-session-id" in extra)) extra["mcp-session-id"] = "fake-session";
    if (rule.endSession && currentSession) ended.add(currentSession);
    if (rule.raw !== undefined) return new Response(rule.raw, { status, headers: { "content-type": rule.contentType ?? "text/plain", ...extra } });
    const answer = rule.error ? { jsonrpc: "2.0", id: message.id ?? null, error: rule.error } : { jsonrpc: "2.0", id: message.id ?? null, result: withId(rule.result ?? {}, message.id) };
    if (!rule.sse) return Response.json(answer, { status, headers: extra });
    const id = message.id;
    const name = `stream${++streamCount}`;
    let n = 0;
    const nextId = () => (rule.ids ? `${name}-${n++}` : undefined);
    const stream = new ReadableStream({
      async start(controller) {
        controller.enqueue(encoder.encode(": keep-alive\n\n"));
        if (rule.ids) controller.enqueue(sseEvent(undefined, nextId(), rule.retry));
        else if (rule.retry !== undefined) controller.enqueue(encoder.encode(`retry: ${rule.retry}\n\n`));
        const asked: Promise<void>[] = [];
        for (const m of rule.before ?? []) {
          const msg = withId(m, id) as Message;
          if (rule.awaitReply && msg.method !== undefined && msg.id !== undefined) {
            asked.push(new Promise<void>((resolve) => replies.set(JSON.stringify(msg.id), resolve)));
          }
          controller.enqueue(sseEvent(msg, nextId()));
        }
        if (asked.length > 0) {
          await Promise.race([Promise.all(asked), Bun.sleep(rule.awaitMs ?? 5000)]);
          log({ dir: "replied", id });
        }
        if (rule.later) {
          await Bun.sleep(rule.laterMs ?? 300);
          for (const m of rule.later) controller.enqueue(sseEvent(withId(m, id), nextId()));
        }
        if (rule.drop) {
          await Bun.sleep(20);
          controller.error(new Error("dropped by the fake server"));
          return;
        }
        if (rule.hang) return;
        if (rule.poll) {
          kept.set(name, { answer, next: n });
          await Bun.sleep(20);
          controller.close();
          return;
        }
        controller.enqueue(sseEvent(answer, nextId()));
        if (!rule.keepOpen) controller.close();
      },
      cancel() {
        log({ dir: "closed", id });
      },
    });
    req.signal.addEventListener("abort", () => log({ dir: "aborted", id }));
    return new Response(stream, { status, headers: { "content-type": "text/event-stream", "cache-control": "no-cache", ...extra } });
  },
});

console.log(JSON.stringify({ listening: server.port }));
process.on("SIGTERM", () => {
  server.stop(true);
  process.exit(0);
});
