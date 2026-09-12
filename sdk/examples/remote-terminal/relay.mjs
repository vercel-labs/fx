import { WebSocket, WebSocketServer } from "ws";

/** Relay an authenticated app connection to a server-owned native terminal session. */
export function createTerminalRelay({ origin, resolveSession, path = "/api/fx", maxPayloadBytes = 1048576, maxBufferedBytes = 4194304 }) {
  if (new URL(origin).origin !== origin || typeof resolveSession !== "function") {
    throw new TypeError("An exact app origin and session resolver are required");
  }
  if (![maxPayloadBytes, maxBufferedBytes].every((value) => Number.isSafeInteger(value) && value > 0)) {
    throw new TypeError("Relay limits must be positive safe integers");
  }
  const server = new WebSocketServer({ noServer: true, maxPayload: maxPayloadBytes, perMessageDeflate: false });
  const upstreams = new Set();
  let closed = false;
  const reject = (socket, status = 403) => socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);

  async function upgrade(request, socket, head) {
    try {
      const key = request.headers["sec-websocket-key"];
      if (closed || request.headers.origin !== origin || new URL(request.url, origin).pathname !== path ||
          request.method !== "GET" || request.headers.upgrade?.toLowerCase() !== "websocket" ||
          request.headers["sec-websocket-version"] !== "13" || typeof key !== "string" ||
          !/^[+/0-9A-Za-z]{22}==$/.test(key)) return reject(socket);
    } catch { return reject(socket); }
    const deadline = setTimeout(() => socket.destroy(), 10000);
    let connection;
    try {
      connection = await resolveSession(request);
      if (!connection) { clearTimeout(deadline); return reject(socket); }
      const target = new URL(connection.url);
      if (!["ws:", "wss:"].includes(target.protocol) || target.username || target.password || target.hash || typeof connection.sessionId !== "string" || !connection.sessionId) throw new Error("Invalid session");
      if (closed || socket.destroyed) { clearTimeout(deadline); return; }
      const upstream = new WebSocket(target, { origin: connection.origin ?? origin, maxPayload: maxPayloadBytes, perMessageDeflate: false, handshakeTimeout: 10000, followRedirects: false });
      upstreams.add(upstream);
      upstream.on("error", () => {});
      const abandon = () => upstream.terminate();
      socket.once("close", abandon);
      upstream.once("close", () => upstreams.delete(upstream));
      const startupError = () => {
        clearTimeout(deadline);
        if (!socket.destroyed) reject(socket, 502);
      };
      upstream.once("error", startupError);
      upstream.once("open", () => {
        clearTimeout(deadline);
        upstream.removeListener("error", startupError);
        if (closed || socket.destroyed) return upstream.terminate();
        try {
          server.handleUpgrade(request, socket, head, (browser) => {
            let attached = false;
            const fail = () => {
              browser.close(1011, "Native connection unavailable");
              upstream.close(1011, "Relay connection unavailable");
            };
            const forward = (source, destination, data, binary) => {
              if (destination.readyState !== WebSocket.OPEN || destination.bufferedAmount + data.length > maxBufferedBytes) return fail();
              source.pause();
              destination.send(data, { binary }, (error) => {
                if (error) fail();
                else if (source.readyState === WebSocket.OPEN) source.resume();
              });
            };
            browser.on("message", (data, binary) => {
              if (!attached) {
                let message;
                try { message = JSON.parse(data.toString()); } catch { return fail(); }
                if (binary || message?.type !== "attach" || message.sessionId !== connection.sessionId) return fail();
                attached = true;
              }
              forward(browser, upstream, data, binary);
            });
            upstream.on("message", (data, binary) => forward(upstream, browser, data, binary));
            browser.on("error", fail);
            upstream.on("error", fail);
            browser.once("close", () => upstream.close(1000, "View detached"));
            upstream.once("close", (code) => browser.close(code === 1000 ? 1000 : 1011, "Native connection closed"));
          });
        } catch {
          upstream.terminate();
          if (!socket.destroyed) reject(socket, 502);
        }
      });
    } catch {
      clearTimeout(deadline);
      if (!socket.destroyed) reject(socket, 502);
    }
  }

  return {
    upgrade,
    close() {
      closed = true;
      for (const socket of server.clients) socket.terminate();
      for (const socket of upstreams) socket.terminate();
      server.close();
    },
  };
}
