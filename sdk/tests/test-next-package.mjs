#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { createWriteStream } from "node:fs";
import { cp, mkdir, mkdtemp, readFile, rename, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const tarball = resolve(process.argv[2]);
const artifactRoot = process.env.LIBFX_TEST_ARTIFACT_ROOT || tmpdir();
await mkdir(artifactRoot, { recursive: true });
const root = await mkdtemp(resolve(artifactRoot, "libfx-next-"));
const app = resolve(root, "app");
const fixture = fileURLToPath(new URL("./next/", import.meta.url));
const token = randomUUID();
const env = { ...process.env, NODE_OPTIONS: "", NODE_PATH: "", NEXT_TELEMETRY_DISABLED: "1", AI_GATEWAY_API_KEY: "",
  LIBFX_LIVE: "0", LIBFX_SMOKE_TOKEN: token, LIBFX_TEST_MODEL: "" };
const servers = new Set();
const results = [];

async function run(command, args, cwd, name) {
  const log = createWriteStream(resolve(root, `${name}.log`));
  const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  const timer = setTimeout(() => child.kill("SIGKILL"), 180_000);
  try {
    const [code, signal] = await once(child, "close");
    assert.equal(code, 0, `${name} exited ${code} (${signal}); see ${root}/${name}.log`);
  } finally { clearTimeout(timer); log.end(); }
}

async function start(cwd, args, name) {
  const reservation = createServer();
  await new Promise((resolveListen) => reservation.listen(0, "127.0.0.1", resolveListen));
  const port = reservation.address().port;
  await new Promise((resolveClose) => reservation.close(resolveClose));
  const log = createWriteStream(resolve(root, `${name}.log`));
  const child = spawn(process.execPath, ["--no-experimental-require-module", ...args, ...(name === "standalone" ? [] : ["--hostname", "127.0.0.1", "--port", String(port)])], {
    cwd, env: { ...env, HOSTNAME: "127.0.0.1", PORT: String(port) }, detached: true, stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  const closed = once(child, "close");
  const server = { child, closed, log, url: `http://127.0.0.1:${port}` };
  servers.add(server);
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    assert.equal(child.exitCode, null, `${name} exited during startup; see ${root}/${name}.log`);
    try {
      const response = await fetch(server.url, { signal: AbortSignal.timeout(1000) });
      await response.arrayBuffer();
      if (response.ok) return server;
    } catch {}
    await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  }
  throw new Error(`${name} did not become ready; see ${root}/${name}.log`);
}

async function stop(server) {
  try { process.kill(-server.child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  const timer = setTimeout(() => { try { process.kill(-server.child.pid, "SIGKILL"); } catch {} }, 5000);
  try { await server.closed; } finally { clearTimeout(timer); server.log.end(); servers.delete(server); }
}

async function exercise(server, stage) {
  const unauthorized = await fetch(`${server.url}/api/fx`);
  assert.equal(unauthorized.status, 401);
  for (const backend of ["native", "auto"]) {
    for (const scenario of ["host", "mcp", "error", "cancel", "resume"]) {
      const response = await fetch(`${server.url}/api/fx?backend=${backend}&scenario=${scenario}`, {
        headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(60_000),
      });
      const result = await response.json();
      assert.equal(response.status, 200, `${stage}/${backend}/${scenario}: ${JSON.stringify(result)}`);
      assert.equal(result.ok, true);
      assert.equal(result.probe.backend, "native");
      assert.equal(result.toolCalls, 1);
      assert.ok(result.checkpointBytes > 48);
      if (scenario === "mcp") assert.equal(result.closedMcp, true);
      results.push({ stage, backend, scenario, status: response.status, ...result });
      console.log(`${stage}/${backend}/${scenario} passed`);
    }
  }
  const concurrent = await Promise.all(Array.from({ length: 8 }, async () => {
    const response = await fetch(`${server.url}/api/fx?backend=native`, {
      headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(60_000),
    });
    const result = await response.json();
    assert.equal(response.status, 200, JSON.stringify(result));
    return result;
  }));
  assert.ok(concurrent.every((result) => result.toolCalls === 1 && result.ok));
  console.log(`${stage}/eight concurrent tool turns passed`);
}

try {
  await cp(fixture, app, { recursive: true, filter: (path) => !["node_modules", ".next"].includes(path.split("/").at(-1)) });
  await cp(tarball, resolve(app, "libfx.tgz"));
  const manifest = JSON.parse(await readFile(resolve(app, "package.json"), "utf8"));
  manifest.dependencies.libfx = "file:./libfx.tgz";
  await writeFile(resolve(app, "package.json"), JSON.stringify(manifest, null, 2));
  await run(process.env.PNPM_BIN || "pnpm", ["install", "--no-frozen-lockfile", "--ignore-scripts"], app, "install");
  const next = resolve(app, "node_modules/next/dist/bin/next");
  const dev = await start(app, [next, "dev"], "dev");
  await exercise(dev, "dev");
  await stop(dev);
  await run(process.execPath, ["--no-experimental-require-module", next, "build"], app, "build");
  const production = await start(app, [next, "start"], "start");
  await exercise(production, "start");
  await stop(production);

  await writeFile(resolve(app, "next.config.mjs"), 'export default { output: "standalone" };\n');
  await run(process.execPath, ["--no-experimental-require-module", next, "build"], app, "standalone-build");
  const isolated = resolve(root, "isolated");
  await cp(resolve(app, ".next/standalone"), isolated, { recursive: true, verbatimSymlinks: true });
  await mkdir(resolve(isolated, ".next"), { recursive: true });
  await cp(resolve(app, ".next/static"), resolve(isolated, ".next/static"), { recursive: true });
  await rename(app, resolve(root, "source-unavailable"));
  const standalone = await start(isolated, [resolve(isolated, "server.js")], "standalone");
  await exercise(standalone, "standalone");
  await stop(standalone);
  await writeFile(resolve(root, "results.json"), JSON.stringify({ node: process.version, tarball, results }, null, 2));
  console.log(`Next package integration passed: ${root}`);
} finally {
  for (const server of servers) await stop(server);
  console.log(`Next package evidence: ${root}`);
}
