// Runs an HTTP server and a client together, as one command for the driver
// (U06). The server is started first, the client runs against it, and the
// server is stopped before this exits, with the client's exit code. Nothing
// outlives the run.
//
// Usage: bun tests/tla/drivers/mcp/with-server.ts [--env K=V ...] [--port <n>] -- <server argv...> -- <client argv...>
//
// The server either prints a JSON line {"listening": <port>} (the fake HTTP
// server does), or, when an argument is `{port}`, gets a free port there, or
// listens on the fixed `--port`; the last two are polled until they accept
// connections. Client arguments may contain `{port}`.

function freePort(): number {
  const server = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = server.port;
  server.stop(true);
  return port;
}

async function accepts(port: number): Promise<boolean> {
  try {
    const socket = await Bun.connect({ hostname: "127.0.0.1", port, socket: { data() {} } });
    socket.end();
    return true;
  } catch {
    return false;
  }
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  const env: Record<string, string> = {};
  let fixed = 0;
  while (args[0] === "--env" || args[0] === "--port") {
    if (args[0] === "--port") fixed = Number(args[1]);
    else {
      const [k, ...v] = args[1].split("=");
      env[k] = v.join("=");
    }
    args.splice(0, 2);
  }
  if (args[0] !== "--") throw new Error("usage: with-server.ts [--env K=V ...] -- <server argv...> -- <client argv...>");
  const split = args.indexOf("--", 1);
  let serverArgv = args.slice(1, split);
  let clientArgv = args.slice(split + 1);

  let port = fixed;
  const assigned = fixed !== 0 || serverArgv.some((a) => a.includes("{port}"));
  if (assigned && fixed === 0) {
    port = freePort();
    serverArgv = serverArgv.map((a) => a.replaceAll("{port}", String(port)));
  }
  const server = Bun.spawn(serverArgv, { stdout: "pipe", stderr: "inherit", env: process.env });
  try {
    const deadline = Date.now() + 30_000;
    if (assigned) {
      while (!(await accepts(port))) {
        if (Date.now() > deadline || server.exitCode !== null) throw new Error("server never accepted connections");
        await Bun.sleep(100);
      }
    } else {
      const reader = server.stdout.getReader();
      let text = "";
      while (port === 0) {
        const { value, done } = await reader.read();
        if (done) throw new Error("server exited before listening");
        text += new TextDecoder().decode(value);
        const match = text.match(/\{"listening":(\d+)\}/);
        if (match) port = Number(match[1]);
      }
      reader.releaseLock();
    }
    clientArgv = clientArgv.map((a) => a.replaceAll("{port}", String(port)));
    const client = Bun.spawn(clientArgv, { stdout: "inherit", stderr: "inherit", env: { ...process.env, ...env } });
    return await client.exited;
  } finally {
    server.kill("SIGTERM");
    const ended = await Promise.race([server.exited.then(() => true), Bun.sleep(3000).then(() => false)]);
    if (!ended) server.kill("SIGKILL");
  }
}

process.exit(await main());
