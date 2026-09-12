import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { WebSocketServer, WebSocket } from "ws";

export async function startBroker({ host = "127.0.0.1", port = 0, origin, token, sessionId, cwd, command, args = [], env = {}, python = "python3", replayBytes = 4 * 1024 * 1024 }) {
  if (!origin || !/^[a-zA-Z0-9_-]{32,}$/.test(token) || !sessionId || !cwd || !command) {
    throw new TypeError("A trusted origin, random token, session, directory, and executable are required");
  }
  let writer;
  let writerView;
  let writerId = 0;
  let nativePid;
  let cursor = 0;
  let retainedBytes = 0;
  let exitCode;
  let snapshot;
  const replay = [];
  const child = spawn(python, [fileURLToPath(new URL("native-pty.py", import.meta.url))], { stdio: ["pipe", "pipe", "pipe"] });
  child.stderr.resume();
  const send = (socket, message) => {
    if (socket.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > replayBytes) return socket.close(1013, "Consumer is too slow");
    socket.send(JSON.stringify(message));
  };
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.type === "started") {
      nativePid = message.pid;
    } else if (message.type === "input_rejected") {
      if (writer && message.writerId === writerId) {
        send(writer, { type: "error", message: message.message });
        writer.close(1008, message.message);
      }
    } else if (message.type === "output") {
      const event = { type: "output", cursor: ++cursor, data: message.data };
      replay.push(event);
      retainedBytes += Buffer.byteLength(event.data);
      while (retainedBytes > replayBytes && replay.length > 1) retainedBytes -= Buffer.byteLength(replay.shift().data);
      if (writer && writerView !== "html") send(writer, event);
    } else if (message.type === "interaction") {
      snapshot = message.snapshot;
      if (writer) send(writer, { type: "interaction", snapshot });
    } else if (message.type === "exit") {
      exitCode = message.code;
      if (writer) send(writer, { type: "exit", code: exitCode });
    }
  });
  const childExited = new Promise((resolve) => {
    child.on("error", () => {
      exitCode = 1;
      if (writer) send(writer, { type: "error", message: "Native terminal could not start" });
      resolve();
    });
    child.on("close", (code) => {
      if (exitCode === undefined) {
        exitCode = code ?? 1;
        if (writer) send(writer, { type: "exit", code: exitCode });
      }
      resolve();
    });
  });
  const stopChild = async () => {
    child.stdin.end(JSON.stringify({ type: "close" }) + "\n");
    let timer;
    await Promise.race([childExited, new Promise((resolve) => {
      timer = setTimeout(() => {
        if (nativePid) {
          try { process.kill(-nativePid, "SIGKILL"); } catch {}
        }
        child.kill("SIGKILL");
        resolve();
      }, 2000);
    })]);
    clearTimeout(timer);
  };
  child.stdin.on("error", () => {});
  child.stdin.write(JSON.stringify({ cwd, command, args, env }) + "\n");
  const server = createServer((request, response) => {
    response.writeHead(request.url === `/${token}/health` ? (nativePid && exitCode === undefined ? 200 : 503) : 404, { "cache-control": "no-store" });
    response.end();
  });
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 1048576 });
  server.on("upgrade", (request, socket, head) => {
    if (request.url !== `/${token}` || request.headers.origin !== origin) {
      socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
      return;
    }
    sockets.handleUpgrade(request, socket, head, (connection) => sockets.emit("connection", connection));
  });
  sockets.on("connection", (socket) => {
    let attached = false;
    let rejected = false;
    const timeout = setTimeout(() => socket.close(1008, "Attach required"), 5000);
    const reject = (message) => {
      rejected = true;
      send(socket, { type: "error", message });
      socket.close(1008, message);
    };
    socket.on("message", (data, binary) => {
      if (rejected || socket.readyState !== WebSocket.OPEN) return;
      if (binary) return reject("JSON messages required");
      let message;
      try { message = JSON.parse(data.toString()); } catch { return reject("Invalid JSON"); }
      if (!message || typeof message !== "object") return reject("Invalid message");
      if (!attached) {
        const position = message.cursor ?? 0;
        if (message.type !== "attach" || message.version !== 1 || message.sessionId !== sessionId) return reject("Invalid session attachment");
        if (message.view !== undefined && message.view !== "html" && message.view !== "terminal") return reject("Invalid view");
        const html = message.view === "html";
        if (html && position !== 0) return reject("HTML cursor must be zero");
        if (!html && (!Number.isSafeInteger(position) || position < 0 || position > cursor || position < (replay[0]?.cursor ?? 1) - 1)) return reject("Replay cursor unavailable");
        if (writer && writer.readyState === WebSocket.OPEN) return reject("Session already has a writer");
        attached = true;
        writer = socket;
        writerView = message.view;
        writerId++;
        clearTimeout(timeout);
        send(socket, { type: "ready", version: 1, sessionId, cursor: position });
        if (!html) for (const event of replay) if (event.cursor > position) send(socket, event);
        if (snapshot) send(socket, { type: "interaction", snapshot });
        if (exitCode !== undefined) send(socket, { type: "exit", code: exitCode });
        return;
      }
      if (exitCode !== undefined) return reject("Native process has exited");
      if (message.type === "input") {
        if (typeof message.data !== "string") return reject("Invalid input");
        if (message.encoding !== undefined && message.encoding !== "base64") return reject("Invalid input encoding");
        const bytes = message.encoding === "base64" ? Buffer.from(message.data, "base64") : Buffer.from(message.data);
        if (message.encoding === "base64" && bytes.toString("base64") !== message.data) return reject("Invalid base64 input");
        if (bytes.length > 65536) return reject("Input exceeds limit");
      } else if (message.type === "resize") {
        if (![message.cols, message.rows].every((size) => Number.isInteger(size) && size >= 1 && size <= 1000)) return reject("Invalid terminal dimensions");
      } else if (message.type === "interaction") {
        if (!message.action || typeof message.action !== "object" || Array.isArray(message.action)) return reject("Invalid interaction action");
      } else if (message.type !== "interrupt") return reject("Unknown terminal message");
      if (child.stdin.writableLength > 65536) return reject("Native input is busy");
      child.stdin.write(JSON.stringify({ ...message, writerId }) + "\n");
    });
    socket.on("error", () => {});
    socket.on("close", () => {
      clearTimeout(timeout);
      if (writer === socket) writer = undefined;
    });
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, host, resolve);
    });
  } catch (error) {
    await stopChild();
    throw error;
  }
  const address = server.address();
  return {
    port: address.port,
    async close() {
      for (const socket of sockets.clients) socket.terminate();
      sockets.close();
      await new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); });
      await stopChild();
      lines.close();
    },
  };
}
