#!/usr/bin/env node
// fx acp WebSocket transport bridge — spec-compliant custom transport.
//
// Implements ACP's JSON-RPC message format and lifecycle over WebSocket,
// preserving the identical wire format as stdio. ACP officially defines stdio
// and a draft Streamable HTTP transport; this bridge is a custom transport
// that MUST preserve the JSON-RPC message format and lifecycle (ACP
// transports.md#custom-transports). Each WebSocket connection maps to one
// `fx acp` subprocess (one session at a time) because ServerState holds a
// single active session per process.
//
// Endpoint: GET /acp with Upgrade: websocket.
//   - GET /health → bridge status
//   - GET /acp without upgrade → 426 Upgrade Required
//   - POST /acp → 501 (Streamable HTTP not implemented)
//   - Upgrade: websocket → 101 with Acp-Connection-Id + full-duplex WS
//
// CWD handling (spec-compliant):
//   ACP carries `cwd` in session/new, session/load, session/resume (required
//   absolute path) and defines that cwd MUST be used regardless of where the
//   subprocess was spawned. fx now honors per-session cwd from the JSON-RPC
//   params directly (src/acp/sessions.zig). For backwards compatibility with
//   older fx binaries, this bridge also tries to spawn the subprocess in the
//   requested cwd when it is known before spawning. It buffers the first
//   messages for a short window so a session/new cwd arriving immediately
//   after initialize can be used as the spawn cwd, avoiding a fallback to
//   the bridge's own directory (fx/ws-bridge) that previously caused the bug.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { WebSocketServer } from "ws";

const PORT = Number.parseInt(process.env.PORT ?? "8787", 10);
const FX_PATH = process.env.FX_PATH ?? "fx";
const FX_ARGS = (process.env.FX_ARGS ?? "acp").split(/\s+/).filter(Boolean);
const HOST = process.env.HOST ?? "127.0.0.1";
const SPAWN_GRACE_MS = 50;

function fail(res, code, message, extraHeaders = {}) {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  res.writeHead(code, { "content-type": "application/json", ...extraHeaders });
  res.end(JSON.stringify({ error: message }));
}

function isAbsolutePath(p) {
  return typeof p === "string" && p.length > 0 && p.startsWith("/");
}

function extractCwd(msg) {
  if (Array.isArray(msg)) {
    for (const item of msg) {
      const c = extractCwd(item);
      if (c) return c;
    }
    return null;
  }
  const params = msg?.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) return null;
  const cwd = params.cwd;
  if (typeof cwd === "string" && cwd.length > 0) return cwd;
  return null;
}

// --- HTTP server: unified /acp endpoint ------------------------------------

const server = createServer((req, res) => {
  const urlPath = (req.url || "").split("?")[0];
  if (urlPath === "/" || urlPath === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", transport: "websocket", endpoint: "/acp" }));
    return;
  }
  if (urlPath !== "/acp") {
    return fail(res, 404, "not found");
  }
  if (req.method === "POST") {
    return fail(res, 501, "Streamable HTTP profile not implemented; use WebSocket");
  }
  if (req.method === "GET" && req.headers.upgrade?.toLowerCase() !== "websocket") {
    res.writeHead(426, {
      "content-type": "application/json",
      upgrade: "websocket",
    });
    res.end(JSON.stringify({ error: "upgrade required", transport: "websocket" }));
    return;
  }
  if (req.method !== "GET") {
    return fail(res, 405, "method not allowed");
  }
  // Upgrade requests are handled in the 'upgrade' event.
});

// --- WebSocket server on the same HTTP server ------------------------------

const wss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const urlPath = (req.url || "").split("?")[0];
  if (urlPath !== "/acp") {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  const connectionId = randomUUID();
  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.acpConnectionId = connectionId;
    wss.emit("connection", ws, req, connectionId);
  });
});

wss.on("connection", (ws, req, connectionId) => {
  const remote = req.socket.remoteAddress || "unknown";
  console.error(`[ws] connection ${connectionId} from ${remote}`);

  let child = null;
  let closed = false;
  const pending = [];
  let spawnTimer = null;
  let spawnCwd = null;
  const stdoutDecoder = new StringDecoder("utf8");
  let lineBuffer = "";

  // Delay advisory frame slightly to avoid race where client attaches handler after 'open'.
  setTimeout(() => {
    try {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/connection", params: { connectionId } }));
    } catch {}
  }, 15);


  function spawnFx(cwd) {
    if (child) return;
    if (spawnTimer) {
      clearTimeout(spawnTimer);
      spawnTimer = null;
    }
    let targetCwd = cwd;
    if (targetCwd && !isAbsolutePath(targetCwd)) {
      console.error(`[ws] connection ${connectionId} cwd is not absolute (${targetCwd}); falling back to bridge cwd`);
      targetCwd = process.cwd();
    }
    if (!targetCwd) targetCwd = process.cwd();
    spawnCwd = targetCwd;
    console.error(`[ws] connection ${connectionId} spawning fx in cwd=${targetCwd}`);

    try {
      child = spawn(FX_PATH, FX_ARGS, {
        stdio: ["pipe", "pipe", "pipe"],
        cwd: targetCwd,
        env: { ...process.env },
      });
    } catch (err) {
      console.error(`[ws] connection ${connectionId} spawn error: ${err.message}`);
      if (!closed && ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/error", params: { error: `fx spawn failed: ${err.message}` } }));
      }
      tryClose(ws);
      return;
    }

    child.stderr.on("data", (chunk) => {
      process.stderr.write(`[fx:${connectionId}] ${chunk}`);
    });

    child.stdout.on("data", (chunk) => {
      const text = stdoutDecoder.write(chunk);
      lineBuffer += text;
      for (;;) {
        const nl = lineBuffer.indexOf("\n");
        if (nl < 0) break;
        const line = lineBuffer.slice(0, nl).trim();
        lineBuffer = lineBuffer.slice(nl + 1);
        if (line.length === 0) continue;
        if (ws.readyState === ws.OPEN) ws.send(line);
      }
    });

    child.on("error", (err) => {
      console.error(`[ws] connection ${connectionId} spawn error: ${err.message}`);
      if (!closed && ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/error", params: { error: `fx spawn failed: ${err.message}` } }));
      }
      tryClose(ws);
    });

    child.on("exit", (code, signal) => {
      console.error(`[ws] connection ${connectionId} fx exited code=${code} signal=${signal}`);
      const tail = stdoutDecoder.end() + lineBuffer;
      lineBuffer = "";
      const trimmed = tail.trim();
      if (trimmed.length > 0 && ws.readyState === ws.OPEN) {
        try { JSON.parse(trimmed); ws.send(trimmed); } catch {}
      }
      if (!closed && ws.readyState === ws.OPEN) {
        try {
          ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/exit", params: { code, signal } }));
        } catch {}
      }
      tryClose(ws);
    });

    for (const text of pending) {
      if (child.stdin.writable) child.stdin.write(text + "\n");
    }
    pending.length = 0;

    child.stdin.on("error", (err) => {
      console.error(`[ws] connection ${connectionId} stdin error: ${err.message}`);
    });
  }

  function scheduleSpawnFallback() {
    if (child || spawnTimer) return;
    spawnTimer = setTimeout(() => {
      if (child || closed) return;
      console.error(`[ws] connection ${connectionId} no cwd within ${SPAWN_GRACE_MS}ms; spawning in bridge cwd=${process.cwd()}`);
      spawnFx(process.cwd());
    }, SPAWN_GRACE_MS);
    spawnTimer.unref?.();
  }

  ws.on("message", (data, isBinary) => {
    if (isBinary) return;
    const text = data.toString("utf8").trim();
    if (text.length === 0) return;

    let parsed = null;
    let parseError = false;
    try {
      parsed = JSON.parse(text);
    } catch {
      parseError = true;
    }

    let cwd = null;
    if (!parseError && parsed !== null) {
      cwd = extractCwd(parsed);
      const method = Array.isArray(parsed) ? `batch[${parsed.length}]` : parsed.method || "-";
      const id = Array.isArray(parsed) ? "-" : (parsed.id ?? "-");
      console.error(`[ws] connection ${connectionId} recv method=${method} id=${id}${cwd ? ` cwd=${cwd}` : ""}`);
    } else {
      console.error(`[ws] connection ${connectionId} recv (unparseable) ${text.slice(0, 200)}`);
    }

    if (!child) {
      pending.push(text);
      if (cwd && isAbsolutePath(cwd)) {
        spawnFx(cwd);
        return;
      }
      if (pending.length === 1) {
        scheduleSpawnFallback();
      }
      return;
    }

    if (cwd && spawnCwd && cwd !== spawnCwd) {
      console.error(`[ws] connection ${connectionId} session cwd ${cwd} differs from spawn cwd ${spawnCwd}; per-session cwd will be honored by fx`);
    }

    if (child.stdin.writable) {
      const ok = child.stdin.write(text + "\n");
      if (!ok) {
        child.stdin.once("drain", () => {});
      }
    }
  });

  ws.on("close", () => {
    console.error(`[ws] connection ${connectionId} closed`);
    closed = true;
    if (spawnTimer) {
      clearTimeout(spawnTimer);
      spawnTimer = null;
    }
    if (child) killChild(child);
  });

  ws.on("error", (err) => {
    console.error(`[ws] connection ${connectionId} socket error: ${err.message}`);
    closed = true;
    if (spawnTimer) {
      clearTimeout(spawnTimer);
      spawnTimer = null;
    }
    if (child) killChild(child);
  });

});

function tryClose(ws) {
  if (ws.readyState === ws.OPEN || ws.readyState === ws.CONNECTING) {
    try { ws.close(); } catch {}
  }
}

function killChild(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try { child.stdin?.end(); } catch {}
  try { child.kill("SIGTERM"); } catch {}
  setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try { child.kill("SIGKILL"); } catch {}
    }
  }, 1000).unref();
}

server.listen(PORT, HOST, () => {
  console.error(`[ws-bridge] listening on http://${HOST}:${PORT}/acp (ws)`);
  console.error(`[ws-bridge] fx: ${FX_PATH} ${FX_ARGS.join(" ")}`);
  console.error(`[ws-bridge] cwd handling: per-session cwd honored by fx core; spawn grace ${SPAWN_GRACE_MS}ms`);
});

server.on("error", (err) => {
  console.error(`[ws-bridge] server error: ${err.message}`);
  process.exit(1);
});
