#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { createWriteStream } from "node:fs";
import { access, cp, mkdir, mkdtemp, readFile, realpath, rename, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { serializeError } from "./package-report.mjs";

const tarball = resolve(process.argv[2]);
const next15 = process.argv.includes("--next15");
const webpack = next15 || process.argv.includes("--webpack");
const bundlerArgs = webpack && !next15 ? ["--webpack"] : [];
const artifactRoot = process.env.LIBFX_TEST_ARTIFACT_ROOT || tmpdir();
await mkdir(artifactRoot, { recursive: true });
const root = await realpath(await mkdtemp(resolve(artifactRoot, "libfx-next-")));
const app = resolve(root, "app");
const fixture = fileURLToPath(new URL("./next/", import.meta.url));
const token = randomUUID();
const env = { ...process.env, NODE_OPTIONS: "", NODE_PATH: "", NEXT_TELEMETRY_DISABLED: "1", AI_GATEWAY_API_KEY: "",
  LIBFX_LIVE: "0", LIBFX_SMOKE_TOKEN: token, LIBFX_TEST_MODEL: "" };
const servers = new Set();
const results = [];
let failure;

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
  // Next 16 dev forwards flags through NODE_OPTIONS, which rejects the JSPI flag.
  const jspiArgs = name === "start" || (name === "dev" && next15) ? ["--experimental-wasm-jspi"] : [];
  const child = spawn(process.execPath, [...jspiArgs, "--no-experimental-require-module", ...args, ...(name === "standalone" ? [] : ["--hostname", "127.0.0.1", "--port", String(port)])], {
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
    for (const scenario of ["host", "mcp", "error", "known-error", "cancel", "resume"]) {
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
  // Next's standalone tracer excludes .wasm assets; native selection above must not rely on that fallback.
  if (stage === "start" || (stage === "dev" && next15)) {
    const response = await fetch(`${server.url}/api/fx?backend=wasm&scenario=startup`, {
      headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(60_000),
    });
    const result = await response.json();
    assert.equal(response.status, 200, JSON.stringify(result));
    assert.equal(result.ok, true);
    assert.equal(result.probe.backend, "wasm-jspi");
    assert.ok(result.checkpointBytes > 48);
    results.push({ stage, backend: "wasm", status: response.status, ...result });
    console.log(`${stage}/wasm/default asset startup passed`);
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

async function assertBundledNativeAssets(buildDir) {
  if (!webpack) return;
  const routeDir = resolve(buildDir, "server/app/api/fx");
  const trace = JSON.parse(await readFile(resolve(routeDir, "route.js.nft.json"), "utf8"));
  for (const platform of ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]) {
    const file = trace.files.find((path) => path.includes(`/static/media/libfx.${platform}.`) && path.endsWith(".node"));
    assert.ok(file, `webpack must trace the emitted ${platform} addon, not externalize libfx`);
    await access(resolve(routeDir, file));
  }
}

try {
  await cp(fixture, app, { recursive: true, filter: (path) => !["node_modules", ".next"].includes(path.split("/").at(-1)) });
  await cp(tarball, resolve(app, "libfx.tgz"));
  const manifest = JSON.parse(await readFile(resolve(app, "package.json"), "utf8"));
  manifest.dependencies.libfx = "file:./libfx.tgz";
  if (next15) manifest.dependencies.next = "15.5.25";
  await writeFile(resolve(app, "package.json"), JSON.stringify(manifest, null, 2));
  await run(process.env.PNPM_BIN || "pnpm", ["install", "--ignore-workspace", "--no-frozen-lockfile", "--ignore-scripts"], app, "install");
  const require = createRequire(resolve(app, "package.json"));
  if (!next15) {
    await run(process.execPath, [
      fileURLToPath(new URL("./test-node-tracing.mjs", import.meta.url)),
      dirname(require.resolve("libfx")),
      require.resolve("next/dist/compiled/@vercel/nft"),
    ], app, "node-tracing");
  }
  const next = resolve(app, "node_modules/next/dist/bin/next");
  const dev = await start(app, [next, "dev", ...bundlerArgs], "dev");
  await exercise(dev, "dev");
  await stop(dev);
  await run(process.execPath, ["--no-experimental-require-module", next, "build", ...bundlerArgs], app, "build");
  await assertBundledNativeAssets(resolve(app, ".next"));
  const production = await start(app, [next, "start"], "start");
  await exercise(production, "start");
  await stop(production);

  const distDir = "build-output";
  await writeFile(resolve(app, "next.config.mjs"), `export default ${JSON.stringify({
    output: "standalone", distDir, assetPrefix: "https://cdn.example.test/assets",
  })};\n`);
  await run(process.execPath, ["--no-experimental-require-module", next, "build", ...bundlerArgs], app, "standalone-build");
  await assertBundledNativeAssets(resolve(app, distDir));
  const isolated = resolve(root, "isolated");
  await cp(resolve(app, distDir, "standalone"), isolated, { recursive: true, verbatimSymlinks: true });
  await mkdir(resolve(isolated, distDir), { recursive: true });
  await cp(resolve(app, distDir, "static"), resolve(isolated, distDir, "static"), { recursive: true });
  await rename(app, resolve(root, "source-unavailable"));
  const standalone = await start(isolated, [resolve(isolated, "server.js")], "standalone");
  await exercise(standalone, "standalone");
  await stop(standalone);
} catch (error) {
  failure = error;
} finally {
  for (const server of servers) {
    try { await stop(server); }
    catch (error) { failure = failure ? new AggregateError([failure, error], "Verification and cleanup failed") : error; }
  }
  await writeFile(resolve(root, "results.json"), JSON.stringify({
    node: process.version, next15, bundler: webpack ? "webpack" : "turbopack", tarball, results,
    status: failure ? "failed" : "passed",
    error: serializeError(failure),
  }, null, 2));
  console.log(`Next package evidence: ${root}`);
}
if (failure) throw failure;
console.log(`Next package integration passed: ${root}`);
