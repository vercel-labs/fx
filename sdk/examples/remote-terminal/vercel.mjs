import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";

let bundled;

async function bundleServer() {
  bundled ??= Bun.build({ entrypoints: [new URL("server.mjs", import.meta.url).pathname], target: "node", format: "esm" }).then(async (result) => {
    if (!result.success) throw new Error("Could not bundle native terminal backend");
    return Buffer.from(await result.outputs[0].arrayBuffer());
  });
  return bundled;
}

/** Start once for an authenticated application session using its existing Sandbox handle. */
export async function startVercelTerminal({ sandbox, cwd, origin, sessionId, fxPath, env = {}, port = 7681, existingPorts = [] }) {
  const token = randomBytes(32).toString("hex");
  const directory = `/tmp/fx-terminal-${token}`;
  const config = { host: "0.0.0.0", port, token, origin, sessionId, cwd, command: fxPath, env };
  const check = await sandbox.runCommand({ cmd: "python3", args: ["-c", "import pty, selectors, socket"], cwd });
  if (check.exitCode !== 0) throw new Error("The sandbox must have Python 3 and a native fx binary installed at startup");
  await sandbox.writeFiles([
    { path: `${directory}/server.mjs`, content: await bundleServer() },
    { path: `${directory}/native-pty.py`, content: await readFile(new URL("native-pty.py", import.meta.url)) },
  ]);
  await sandbox.update({ ports: [...new Set([...existingPorts, port])] });
  const process = await sandbox.runCommand({ cmd: "node", args: [`${directory}/server.mjs`], cwd, env: { FX_TERMINAL_CONFIG: JSON.stringify(config) }, detached: true });
  const base = sandbox.domain(port);
  try {
    const deadline = Date.now() + 15000;
    let healthy = false;
    while (Date.now() < deadline) {
      try {
        const response = await fetch(`${base}/${token}/health`, { signal: AbortSignal.timeout(1000) });
        if (response.ok) { healthy = true; break; }
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!healthy) throw new Error("Native terminal backend did not become reachable");
    return {
      url: `${base.replace(/^http/, "ws")}/${token}`,
      sessionId,
      async close() { await process.kill("SIGTERM"); await process.wait(); },
    };
  } catch (error) {
    await process.kill("SIGTERM");
    await process.wait();
    throw error;
  }
}
