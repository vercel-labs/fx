#!/usr/bin/env node
// ACP WebSocket transport bridge — universal daemon (custom transport).
//
// Implements ACP's JSON-RPC message format and lifecycle over WebSocket,
// preserving the identical wire format as stdio. ACP officially defines stdio
// and a draft Streamable HTTP transport; this bridge is a custom transport
// that MUST preserve the JSON-RPC message format and lifecycle (ACP
// transports.md#custom-transports). Each WebSocket connection maps to one
// ACP agent subprocess (one session at a time) because most ServerState
// implementations hold a single active session per process.
//
// Endpoint: GET /acp with Upgrade: websocket.
//   - GET /health → bridge status
//   - GET /acp without upgrade → 426 Upgrade Required
//   - POST /acp → 501 (Streamable HTTP not implemented)
//   - Upgrade: websocket → 101 with Acp-Connection-Id + full-duplex WS
//
// Agent selection:
//   - ?agent=<name> query param selects the agent from config.json
//   - Default agent is config.defaultAgent or "fx"
//   - Unknown agent → 400
//
// CWD handling (spec-compliant):
//   ACP carries `cwd` in session/new, session/load, session/resume (required
//   absolute path) and defines that cwd MUST be used regardless of where the
//   subprocess was spawned. fx now honors per-session cwd from the JSON-RPC
//   params directly (src/acp/sessions.zig). For backwards compatibility with
//   older binaries, this bridge also tries to spawn the subprocess in the
//   requested cwd when it is known before spawning. It buffers the first
//   messages for a short window so a session/new cwd arriving immediately
//   after initialize can be used as the spawn cwd, avoiding a fallback to
//   the bridge's own directory that previously caused the bug.
//   Additionally, ?cwd=/abs/path on the WebSocket URL is honored as an
//   immediate spawn cwd (eager spawn), so clients can pick the cwd in the
//   UI before any JSON-RPC message is sent.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { WebSocketServer } from "ws";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number.parseInt(process.env.PORT ?? "8787", 10);
const HOST = process.env.HOST ?? "127.0.0.1";
const SPAWN_GRACE_MS = 50;

// ---------------------------------------------------------------------------
// Agent registry
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

let fileConfig = {};
const configCandidates = [
  process.env.BRIDGE_CONFIG_PATH,
  join(__dirname, "config.json"),
].filter(Boolean);

for (const p of configCandidates) {
  if (p && existsSync(p)) {
    try {
      const raw = readFileSync(p, "utf8");
      fileConfig = JSON.parse(raw);
      console.error(`[ws-bridge] loaded config from ${p}`);
      break;
    } catch (e) {
      console.error(`[ws-bridge] failed to load config ${p}: ${e.message}`);
    }
  }
}

// Built-in defaults (used when config.json is missing or partial)
const DEFAULT_AGENTS = {
  fx: {
    command: process.env.FX_PATH ?? "fx",
    args: (process.env.FX_ARGS ?? "acp").split(/\s+/).filter(Boolean),
    env: {},
  },
  omp: {
    command: "omp",
    args: ["acp"],
    env: {},
  },
  pi: {
    command: "npx",
    args: ["-y", "pi-acp"],
    env: {},
  },
  opencode: {
    command: "opencode",
    args: ["acp"],
    env: {},
  },
};

let agents = { ...DEFAULT_AGENTS };
if (fileConfig.agents && typeof fileConfig.agents === "object" && !Array.isArray(fileConfig.agents)) {
  for (const [name, cfg] of Object.entries(fileConfig.agents)) {
    if (!cfg || typeof cfg !== "object") continue;
    const key = String(name).toLowerCase();
    const existing = agents[key] || {};
    let args;
    if (Array.isArray(cfg.args)) args = cfg.args;
    else if (typeof cfg.args === "string") args = cfg.args.split(/\s+/).filter(Boolean);
    else args = existing.args ?? [];
    agents[key] = {
      command: cfg.command ?? existing.command ?? key,
      args,
      env: cfg.env && typeof cfg.env === "object" && !Array.isArray(cfg.env) ? cfg.env : existing.env ?? {},
    };
  }
}

// FX_PATH / FX_ARGS override fx entry for backwards compat
if (process.env.FX_PATH || process.env.FX_ARGS) {
  agents.fx = {
    command: process.env.FX_PATH ?? agents.fx.command,
    args: process.env.FX_ARGS ? process.env.FX_ARGS.split(/\s+/).filter(Boolean) : agents.fx.args,
    env: agents.fx.env ?? {},
  };
}

const DEFAULT_AGENT = (process.env.DEFAULT_AGENT ?? fileConfig.defaultAgent ?? "fx").toLowerCase();

// allowCwdRoots: empty => allow any absolute path
let ALLOW_CWD_ROOTS = [];
if (Array.isArray(fileConfig.allowCwdRoots)) {
  ALLOW_CWD_ROOTS = fileConfig.allowCwdRoots.filter(v => typeof v === "string" && v.length > 0);
} else if (process.env.ALLOW_CWD_ROOTS) {
  ALLOW_CWD_ROOTS = process.env.ALLOW_CWD_ROOTS.split(",").map(s => s.trim()).filter(Boolean);
}

function isAllowedCwd(cwd) {
  if (ALLOW_CWD_ROOTS.length === 0) return true;
  for (const root of ALLOW_CWD_ROOTS) {
    if (cwd === root || cwd.startsWith(root.endsWith("/") ? root : root + "/")) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// HTTP server: unified /acp endpoint
// ---------------------------------------------------------------------------

const server = createServer((req, res) => {
  const host = req.headers.host || `${HOST}:${PORT}`;
  let url;
  try {
    url = new URL(req.url || "/", `http://${host}`);
  } catch {
    return fail(res, 400, "bad request");
  }
  const urlPath = url.pathname;

  if (urlPath === "/" || urlPath === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      status: "ok",
      transport: "websocket",
      endpoint: "/acp",
      agents: Object.keys(agents),
      defaultAgent: DEFAULT_AGENT,
    }));
    return;
  }
  if (urlPath === "/agents") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ agents: Object.keys(agents), defaultAgent: DEFAULT_AGENT }));
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

// ---------------------------------------------------------------------------
// WebSocket server on the same HTTP server
// ---------------------------------------------------------------------------

const wss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const host = req.headers.host || `${HOST}:${PORT}`;
  let url;
  try {
    url = new URL(req.url || "/acp", `http://${host}`);
  } catch {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.destroy();
    return;
  }
  const urlPath = url.pathname;
  if (urlPath !== "/acp") {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  const rawAgent = url.searchParams.get("agent");
  const agentName = (rawAgent ?? DEFAULT_AGENT).toLowerCase();
  const agentCfg = agents[agentName];
  if (!agentCfg) {
    const msg = JSON.stringify({ error: `unknown agent '${agentName}'`, available: Object.keys(agents) });
    socket.write(`HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(msg)}\r\n\r\n${msg}`);
    socket.destroy();
    return;
  }
  const cwdQuery = url.searchParams.get("cwd");
  if (cwdQuery !== null) {
    if (!isAbsolutePath(cwdQuery)) {
      const msg = JSON.stringify({ error: `cwd must be absolute: '${cwdQuery}'` });
      socket.write(`HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(msg)}\r\n\r\n${msg}`);
      socket.destroy();
      return;
    }
    if (!isAllowedCwd(cwdQuery)) {
      const msg = JSON.stringify({ error: `cwd not allowed: '${cwdQuery}'`, allowedRoots: ALLOW_CWD_ROOTS });
      socket.write(`HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(msg)}\r\n\r\n${msg}`);
      socket.destroy();
      return;
    }
  }
  const connectionId = randomUUID();
  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.agentName = agentName;
    ws.agentConfig = agentCfg;
    ws.requestedCwd = cwdQuery;
    ws.acpConnectionId = connectionId;
    wss.emit("connection", ws, req, connectionId);
  });
});

wss.on("connection", (ws, req, connectionId) => {
  const agentName = ws.agentName ?? DEFAULT_AGENT;
  const agentConfig = ws.agentConfig ?? agents[agentName] ?? agents[DEFAULT_AGENT];
  const queryCwd = ws.requestedCwd ?? null;
  const remote = req.socket.remoteAddress || "unknown";
  console.error(`[ws] connection ${connectionId} agent=${agentName} from ${remote}${queryCwd ? ` cwd=${queryCwd}` : ""}`);

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
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/connection", params: { connectionId, agent: agentName } }));
    } catch {}
  }, 15);

  // Eager spawn if ?cwd was provided on the URL
  if (queryCwd && isAbsolutePath(queryCwd)) {
    // Spawn on next tick to allow handlers to be attached and to log consistently
    setTimeout(() => {
      if (!child && !closed && isAllowedCwd(queryCwd)) {
        console.error(`[ws] connection ${connectionId} eager spawn from ?cwd=${queryCwd}`);
        spawnAgent(queryCwd);
      }
    }, 0);
  }

  function spawnAgent(cwd) {
    if (child) return;
    if (spawnTimer) {
      clearTimeout(spawnTimer);
      spawnTimer = null;
    }
    let targetCwd = cwd;
    if (targetCwd && !isAbsolutePath(targetCwd)) {
      console.error(`[ws:${agentName}:${connectionId}] cwd is not absolute (${targetCwd}); falling back to bridge cwd`);
      targetCwd = process.cwd();
    }
    if (targetCwd && !isAllowedCwd(targetCwd)) {
      console.error(`[ws:${agentName}:${connectionId}] cwd not allowed (${targetCwd}); falling back to bridge cwd`);
      targetCwd = process.cwd();
    }
    if (!targetCwd) targetCwd = queryCwd && isAbsolutePath(queryCwd) && isAllowedCwd(queryCwd) ? queryCwd : process.cwd();
    spawnCwd = targetCwd;
    console.error(`[ws:${agentName}:${connectionId}] spawning ${agentName} in cwd=${targetCwd} cmd=${agentConfig.command} ${agentConfig.args.join(" ")}`);

    let env = { ...process.env };
    if (agentConfig.env && typeof agentConfig.env === "object") {
      for (const [k, v] of Object.entries(agentConfig.env)) {
        if (typeof v === "string") env[k] = v;
      }
    }

    try {
      child = spawn(agentConfig.command, agentConfig.args, {
        stdio: ["pipe", "pipe", "pipe"],
        cwd: targetCwd,
        env,
      });
    } catch (err) {
      console.error(`[ws:${agentName}:${connectionId}] spawn error: ${err.message}`);
      if (!closed && ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/error", params: { error: `${agentName} spawn failed: ${err.message}`, agent: agentName } }));
      }
      tryClose(ws);
      return;
    }

    child.stderr.on("data", (chunk) => {
      process.stderr.write(`[${agentName}:${connectionId}] ${chunk}`);
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
      console.error(`[ws:${agentName}:${connectionId}] spawn error: ${err.message}`);
      if (!closed && ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/error", params: { error: `${agentName} spawn failed: ${err.message}`, agent: agentName } }));
      }
      tryClose(ws);
    });

    child.on("exit", (code, signal) => {
      console.error(`[ws:${agentName}:${connectionId}] ${agentName} exited code=${code} signal=${signal}`);
      const tail = stdoutDecoder.end() + lineBuffer;
      lineBuffer = "";
      const trimmed = tail.trim();
      if (trimmed.length > 0 && ws.readyState === ws.OPEN) {
        try { JSON.parse(trimmed); ws.send(trimmed); } catch {}
      }
      if (!closed && ws.readyState === ws.OPEN) {
        try {
          ws.send(JSON.stringify({ jsonrpc: "2.0", method: "transport/exit", params: { code, signal, agent: agentName } }));
        } catch {}
      }
      tryClose(ws);
    });

    for (const text of pending) {
      if (child.stdin.writable) child.stdin.write(text + "\n");
    }
    pending.length = 0;

    child.stdin.on("error", (err) => {
      console.error(`[ws:${agentName}:${connectionId}] stdin error: ${err.message}`);
    });
  }

  function scheduleSpawnFallback() {
    if (child || spawnTimer) return;
    spawnTimer = setTimeout(() => {
      if (child || closed) return;
      const fallbackCwd = queryCwd && isAbsolutePath(queryCwd) && isAllowedCwd(queryCwd) ? queryCwd : process.cwd();
      console.error(`[ws:${agentName}:${connectionId}] no cwd within ${SPAWN_GRACE_MS}ms; spawning in ${queryCwd ? `query cwd=${fallbackCwd}` : `bridge cwd=${fallbackCwd}`}`);
      spawnAgent(fallbackCwd);
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
      console.error(`[ws:${agentName}:${connectionId}] recv method=${method} id=${id}${cwd ? ` cwd=${cwd}` : ""}`);
    } else {
      console.error(`[ws:${agentName}:${connectionId}] recv (unparseable) ${text.slice(0, 200)}`);
    }

    // Validate cwd from JSON against allow list early
    if (cwd && !isAllowedCwd(cwd)) {
      console.error(`[ws:${agentName}:${connectionId}] cwd not allowed (${cwd}); rejecting message`);
      if (ws.readyState === ws.OPEN) {
        // Try to parse id for error response if possible
        let id = null;
        try { const p = JSON.parse(text); id = p.id ?? null; } catch {}
        if (id !== null) {
          ws.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32602, message: `cwd not allowed: ${cwd}` } }));
        }
      }
      return;
    }

    if (!child) {
      pending.push(text);
      if (cwd && isAbsolutePath(cwd) && isAllowedCwd(cwd)) {
        spawnAgent(cwd);
        return;
      }
      // If we have a queryCwd and pending is first message (initialize without cwd), spawn eagerly via queryCwd
      if (queryCwd && pending.length === 1 && isAbsolutePath(queryCwd) && isAllowedCwd(queryCwd)) {
        // Don't wait grace if we have a query cwd; spawn immediately
        spawnAgent(queryCwd);
        return;
      }
      if (pending.length === 1) {
        scheduleSpawnFallback();
      }
      return;
    }

    if (cwd && spawnCwd && cwd !== spawnCwd) {
      console.error(`[ws:${agentName}:${connectionId}] session cwd ${cwd} differs from spawn cwd ${spawnCwd}; per-session cwd will be honored by agent`);
    }

    if (child.stdin.writable) {
      const ok = child.stdin.write(text + "\n");
      if (!ok) {
        child.stdin.once("drain", () => {});
      }
    }
  });

  ws.on("close", () => {
    console.error(`[ws:${agentName}:${connectionId}] closed`);
    closed = true;
    if (spawnTimer) {
      clearTimeout(spawnTimer);
      spawnTimer = null;
    }
    if (child) killChild(child);
  });

  ws.on("error", (err) => {
    console.error(`[ws:${agentName}:${connectionId}] socket error: ${err.message}`);
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
  console.error(`[ws-bridge] agents: ${Object.entries(agents).map(([n,c]) => `${n}=${c.command} ${c.args.join(" ")}`).join(", ")}`);
  console.error(`[ws-bridge] defaultAgent=${DEFAULT_AGENT} allowCwdRoots=${ALLOW_CWD_ROOTS.length ? ALLOW_CWD_ROOTS.join(",") : "(any)"} spawnGrace=${SPAWN_GRACE_MS}ms`);
});

server.on("error", (err) => {
  console.error(`[ws-bridge] server error: ${err.message}`);
  process.exit(1);
});
