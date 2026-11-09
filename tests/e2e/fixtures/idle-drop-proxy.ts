import type { Socket } from "bun";

/**
 * How the proxy drops a connection that sat idle: `reset` aborts it, so the
 * client's next send on it fails at once, and `close` closes it cleanly, so
 * the send goes out and only the answer is missing.
 */
export type IdleDrop = "reset" | "close";

type Link = {
  upstream: Socket<undefined> | null;
  /** What the client sent before the upstream connection opened. */
  early: Uint8Array[];
  /** What each side's socket hasn't taken yet. */
  toClient: Uint8Array[];
  toUpstream: Uint8Array[];
  timer: ReturnType<typeof setTimeout> | null;
  dropped: boolean;
};

/**
 * A TCP proxy to `target`'s host and port that drops each client connection
 * once it has carried nothing either way for `idleMs`, as a load balancer
 * drops an idle keep-alive connection. `url` is `target` through the proxy.
 */
export async function startIdleDropProxy(target: string, drop: IdleDrop, idleMs = 150) {
  const upstreamUrl = new URL(target);
  let connections = 0;
  let dropped = 0;
  const clients = new Set<Socket<Link>>();

  const send = (socket: Socket<any>, queue: Uint8Array[], chunk: Uint8Array) => {
    if (queue.length > 0) {
      queue.push(chunk);
      return;
    }
    const written = socket.write(chunk);
    if (written < chunk.length) queue.push(chunk.subarray(Math.max(written, 0)));
  };
  const flush = (socket: Socket<any>, queue: Uint8Array[]) => {
    while (queue.length > 0) {
      const chunk = queue[0]!;
      const written = socket.write(chunk);
      if (written < chunk.length) {
        queue[0] = chunk.subarray(Math.max(written, 0));
        return;
      }
      queue.shift();
    }
  };
  const quiet = (client: Socket<Link>) => {
    const link = client.data;
    if (link.timer) clearTimeout(link.timer);
    link.timer = setTimeout(() => {
      link.dropped = true;
      dropped += 1;
      if (drop === "reset") client.terminate();
      else client.end();
      link.upstream?.end();
    }, idleMs);
  };

  const server = Bun.listen<Link>({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      open(client) {
        connections += 1;
        clients.add(client);
        client.data = { upstream: null, early: [], toClient: [], toUpstream: [], timer: null, dropped: false };
        quiet(client);
        Bun.connect({
          hostname: upstreamUrl.hostname,
          port: Number(upstreamUrl.port),
          socket: {
            open(upstream) {
              client.data.upstream = upstream;
              for (const chunk of client.data.early) send(upstream, client.data.toUpstream, chunk);
              client.data.early = [];
            },
            data(_upstream, chunk) {
              if (client.data.dropped) return;
              send(client, client.data.toClient, chunk);
              quiet(client);
            },
            drain(upstream) {
              flush(upstream, client.data.toUpstream);
            },
            close() {
              if (!client.data.dropped) client.end();
            },
            error() {
              if (!client.data.dropped) client.end();
            },
          },
        }).catch(() => client.end());
      },
      data(client, chunk) {
        if (client.data.dropped) return;
        const upstream = client.data.upstream;
        if (upstream) send(upstream, client.data.toUpstream, chunk);
        else client.data.early.push(chunk);
        quiet(client);
      },
      drain(client) {
        flush(client, client.data.toClient);
      },
      close(client) {
        clients.delete(client);
        if (client.data.timer) clearTimeout(client.data.timer);
        client.data.upstream?.end();
      },
      error() {},
    },
  });

  const origin = `http://127.0.0.1:${server.port}`;
  return {
    origin,
    url: `${origin}${upstreamUrl.pathname}${upstreamUrl.search}`,
    /** Client connections accepted so far. */
    get connections() {
      return connections;
    },
    /** Client connections dropped for sitting idle. */
    get dropped() {
      return dropped;
    },
    stop() {
      for (const client of clients) client.terminate();
      server.stop(true);
    },
  };
}
