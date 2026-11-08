// A local HTTP CONNECT proxy for tests/e2e/net-proxy.test.ts. It logs each
// request head it receives, with the first byte the client sends into the
// tunnel and, for a TLS ClientHello, its server name. It answers CONNECT for
// the routes it knows and pipes the tunnel to 127.0.0.1:<port>; a CONNECT to
// 127.0.0.1 itself goes to that port. It never resolves a name or reaches
// past the machine. `status` makes it answer every CONNECT with that status,
// `garbage` with bytes that are not HTTP, and `silent` with nothing; `interim`
// sends an interim head with that status before the 200.
import net from "node:net";

export type ProxyEntry = {
  requestLine: string;
  authorization: string | null;
  /** The first byte the client sent into the tunnel: 0x16 for a TLS handshake. */
  firstClientByte: number | null;
  /** The server name in the client's TLS ClientHello, when it sent one. */
  sni: string | null;
};

export type ProxyOptions = {
  /** "host:port" the client asks for, to the 127.0.0.1 port that serves it. */
  routes?: Record<string, number>;
  status?: number;
  garbage?: boolean;
  silent?: boolean;
  /** Answers 200 and then sends bytes before the client speaks. */
  early?: boolean;
  /** Sends `HTTP/1.1 <interim> Processing` before the 200 (RFC 9110 section 15.2). */
  interim?: number;
};

/** The server name extension of a TLS ClientHello, or null. */
export function clientHelloServerName(data: Buffer): string | null {
  // Record header (5), handshake header (4), version (2), random (32).
  if (data.length < 43 || data[0] !== 0x16 || data[5] !== 0x01) return null;
  let at = 43;
  const skip = (lengthBytes: number) => {
    if (at + lengthBytes > data.length) return false;
    const length = lengthBytes === 1 ? data[at]! : data.readUInt16BE(at);
    at += lengthBytes + length;
    return at <= data.length;
  };
  if (!skip(1) || !skip(2) || !skip(1)) return null; // session id, cipher suites, compression
  if (at + 2 > data.length) return null;
  const end = Math.min(data.length, at + 2 + data.readUInt16BE(at));
  at += 2;
  while (at + 4 <= end) {
    const type = data.readUInt16BE(at);
    const length = data.readUInt16BE(at + 2);
    const body = at + 4;
    if (type === 0 && body + 5 <= end) {
      const nameLength = data.readUInt16BE(body + 3);
      return data.subarray(body + 5, body + 5 + nameLength).toString("latin1");
    }
    at = body + length;
  }
  return null;
}

export async function startConnectProxy(options: ProxyOptions = {}) {
  const log: ProxyEntry[] = [];
  /** Local ports of the sockets the proxy opened upstream. */
  const upstreamPorts = new Set<number>();
  const sockets = new Set<net.Socket>();
  const track = (socket: net.Socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => socket.destroy());
  };
  const server = net.createServer(client => {
    track(client);
    let head = Buffer.alloc(0);
    const onHead = (chunk: Buffer) => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf("\r\n\r\n");
      if (end < 0) {
        if (head.length > 65536) client.destroy();
        return;
      }
      client.off("data", onHead);
      const lines = head.subarray(0, end).toString("latin1").split("\r\n");
      const requestLine = lines[0]!;
      const auth = lines.slice(1).find(line => /^proxy-authorization:/i.test(line));
      const entry: ProxyEntry = {
        requestLine,
        authorization: auth ? auth.slice(auth.indexOf(":") + 1).trim() : null,
        firstClientByte: null,
        sni: null,
      };
      log.push(entry);
      const rest = head.subarray(end + 4);
      const match = /^CONNECT (\S+):(\d+) HTTP\/1\.[01]$/.exec(requestLine);
      if (!match) return void client.end("HTTP/1.1 400 Bad Request\r\n\r\n");
      if (options.silent) return;
      if (options.garbage) return void client.end("\x16\x03\x01\x00\x05hello");
      if (options.early) return void client.end("HTTP/1.1 200 Connection established\r\n\r\nearly");
      if (options.status !== undefined && options.status !== 200) {
        const reason = options.status === 407 ? "Proxy Authentication Required" : "Refused";
        return void client.end(`HTTP/1.1 ${options.status} ${reason}\r\nProxy-Authenticate: Basic realm="test"\r\n\r\n`);
      }
      const [, host, port] = match;
      const local = options.routes?.[`${host}:${port}`] ?? (host === "127.0.0.1" ? Number(port) : undefined);
      if (local === undefined) return void client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
      const upstream = net.connect(local, "127.0.0.1", () => {
        upstreamPorts.add(upstream.localPort!);
        if (options.interim !== undefined) client.write(`HTTP/1.1 ${options.interim} Processing\r\n\r\n`);
        client.write("HTTP/1.1 200 Connection established\r\n\r\n");
        let first = Buffer.alloc(0);
        const forward = (data: Buffer) => {
          if (data.length === 0) return;
          if (entry.firstClientByte === null) entry.firstClientByte = data[0]!;
          if (entry.sni === null && first.length < 16384) {
            first = Buffer.concat([first, data]);
            entry.sni = clientHelloServerName(first);
          }
          upstream.write(data);
        };
        forward(rest);
        client.on("data", forward);
        upstream.on("data", data => client.write(data));
        upstream.on("end", () => client.end());
        client.on("end", () => upstream.end());
      });
      track(upstream);
      upstream.on("close", () => client.destroy());
    };
    client.on("data", onHead);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as net.AddressInfo).port;
  return {
    port,
    log,
    upstreamPorts,
    /** The proxy URL, with Basic credentials when given (already percent-encoded). */
    url(userinfo?: string) {
      return `http://${userinfo ? `${userinfo}@` : ""}127.0.0.1:${port}`;
    },
    close() {
      for (const socket of sockets) socket.destroy();
      server.close();
    },
  };
}
