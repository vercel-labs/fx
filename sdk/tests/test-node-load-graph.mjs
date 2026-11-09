#!/usr/bin/env node
// What Node.js loads from an installed libfx, recorded by a module hook. With
// this machine's platform package, import and require load the engine and
// the native loader and no WebAssembly host code. Without the native addon,
// the fallback loads the WebAssembly host and an agent completes a turn. With
// only another platform's package, as when node_modules comes from another
// machine, libfx names the package this machine needs, and uses the fallback
// only when the runtime supports JSPI.
//
//   node sdk/tests/test-node-load-graph.mjs <libfx.tgz> --native-dir <dir>
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { localNativePackage, localNativeTarball, nativeDirArgument, nativeTarballs } from "./native-package.mjs";

const tarball = resolve(process.argv[2]);
const nativeDir = nativeDirArgument();
assert.ok(nativeDir, "usage: test-node-load-graph.mjs <libfx.tgz> --native-dir <dir of platform package tarballs>");
const foreignPackage = Object.keys(nativeTarballs(nativeDir)).find((name) => name !== localNativePackage);
assert.ok(foreignPackage, `${nativeDir} needs a platform package for another machine`);
const recordLoads = fileURLToPath(new URL("./record-loads.mjs", import.meta.url));
const wasmHost = ["node-wasm.js", "wasm-runtime.js", "wasm-module.js", "wasm-terminal.js", "fx-sdk.js"];

// Runs in each consumer: one backend probe, then one engine turn against a
// local model server, or the error the engine rejects with.
const probe = `
import { createServer } from "node:http";
import { createRequire } from "node:module";
const [format, json] = process.argv.slice(2);
const options = JSON.parse(json);
// Node.js 24 always has JSPI. libfx detects it by these two functions, so
// without them it sees a runtime that lacks it.
if (process.env.LIBFX_LOAD_GRAPH_NO_JSPI) {
  delete WebAssembly.Suspending;
  delete WebAssembly.promising;
}
const { createFxEngine, getBackendInfo } = format === "require" ? createRequire(import.meta.url)("libfx") : await import("libfx");
const server = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[]}');
      return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"text-delta","delta":"loaded"}\\n\\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\\n\\ndata: [DONE]\\n\\n');
  });
});
await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
const origin = "http://127.0.0.1:" + server.address().port;
const report = { info: await getBackendInfo(options) };
try {
  const engine = await createFxEngine({
    ...options,
    apiKey: "load-graph-key",
    gatewayChatUrl: origin + "/chat",
    model: "load/graph",
    fetch: (input, init) => fetch(init?.method === "GET" ? origin + "/models" : String(input), init),
  });
  const turn = engine.prompt("hello");
  report.text = "";
  for await (const event of turn) if (event.type === "text_delta") report.text += event.delta;
  report.stopReason = (await turn.result).stopReason;
  await engine.close();
} catch (error) {
  report.error = { code: error.code, message: error.message };
} finally {
  server.closeAllConnections();
  server.close();
}
console.log(JSON.stringify(report));
`;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: 120_000, ...options });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

const temp = await mkdtemp(resolve(tmpdir(), "libfx-load-graph-"));
try {
  const consumers = {};
  for (const name of ["native", "foreign"]) {
    const dir = resolve(temp, name);
    await mkdir(dir);
    await writeFile(resolve(dir, "package.json"), '{"private":true,"type":"module"}\n');
    await writeFile(resolve(dir, "probe.mjs"), probe);
    run("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", tarball, ...(name === "native" ? [localNativeTarball(nativeDir)] : [])], { cwd: dir });
    consumers[name] = dir;
  }
  // npm installs no platform package that does not match the machine, so the
  // other machine's package is unpacked as a copied node_modules would carry it.
  const foreignDir = resolve(consumers.foreign, "node_modules", foreignPackage);
  await mkdir(foreignDir, { recursive: true });
  run("tar", ["-xzf", nativeTarballs(nativeDir)[foreignPackage], "-C", foreignDir, "--strip-components=1"]);

  const scenarios = [
    { name: "native import", consumer: "native", format: "import", options: {} },
    { name: "native require", consumer: "native", format: "require", options: {} },
    { name: "fallback import", consumer: "native", format: "import", options: { nativeAddon: false }, jspi: true },
    { name: "fallback require", consumer: "native", format: "require", options: { nativeAddon: false }, jspi: true },
    { name: "foreign native", consumer: "foreign", format: "import", options: { backend: "native" } },
    { name: "foreign without JSPI", consumer: "foreign", format: "import", options: {}, jspi: false },
    { name: "foreign fallback", consumer: "foreign", format: "require", options: {}, jspi: true },
  ];
  for (const scenario of scenarios) {
    const log = resolve(temp, `${scenario.name.replace(" ", "-")}.loads`);
    const output = run(process.execPath, [
      ...(scenario.jspi ? ["--experimental-wasm-jspi"] : []),
      "--import", recordLoads,
      "probe.mjs", scenario.format, JSON.stringify(scenario.options),
    ], { cwd: consumers[scenario.consumer], env: { ...process.env, LIBFX_LOAD_LOG: log, LIBFX_LOAD_GRAPH_NO_JSPI: scenario.jspi === false ? "1" : "", NODE_OPTIONS: "" } });
    const report = JSON.parse(output.trim().split("\n").at(-1));
    const urls = (await readFile(log, "utf8")).split("\n").filter((url) => url.startsWith("file:")).map((url) => fileURLToPath(url));
    const libfx = urls.map((path) => path.split("/node_modules/libfx/")[1]).filter(Boolean);
    const platform = urls.filter((path) => path.includes("/node_modules/@libfx/"));
    const host = wasmHost.filter((file) => libfx.includes(file));
    const where = `${scenario.name}: loaded ${libfx.join(", ")}`;

    assert.ok(libfx.includes("node.js") && libfx.includes("engine.js"), where);
    assert.equal(libfx.includes("node.cjs"), scenario.format === "require", where);
    if (scenario.consumer === "native" && !scenario.jspi) {
      assert.equal(report.info.backend, "native", JSON.stringify(report.info));
      assert.deepEqual(host, [], `${where}; the native addon needs no WebAssembly host code`);
      assert.ok(platform.some((path) => path.includes(`/${localNativePackage}/`)), `${scenario.name}: ${localNativePackage} did not load`);
    } else if (scenario.consumer === "native") {
      assert.equal(report.info.backend, "wasm-jspi", JSON.stringify(report.info));
      assert.deepEqual(host, ["node-wasm.js", "wasm-runtime.js", "wasm-module.js"], `${where}; an agent loads only the core's WebAssembly host`);
      assert.deepEqual(platform, [], `${scenario.name}: nativeAddon: false loaded a platform package`);
    } else {
      // The other machine's package is never loaded, and every error names
      // the one this machine needs.
      assert.deepEqual(platform, [], `${scenario.name}: loaded ${platform.join(", ")}`);
      const native = report.info.attempts.find((attempt) => attempt.backend === "native");
      assert.equal(native.reason.code, "LIBFX_NATIVE_ARTIFACT_MISSING", JSON.stringify(report.info));
      assert.match(native.reason.message, new RegExp(`${localNativePackage} for ${process.platform}-${process.arch} is not installed`));
      if (scenario.jspi) {
        assert.equal(report.info.backend, "wasm-jspi", JSON.stringify(report.info));
      } else {
        // Without JSPI the fallback is never tried, and the error says both
        // ways out.
        if (scenario.options.backend === "native") assert.equal(report.error?.code, "LIBFX_NATIVE_UNAVAILABLE", JSON.stringify(report));
        assert.ok(report.error, JSON.stringify(report));
        assert.match(report.error.message, new RegExp(`Install ${localNativePackage}`));
        if (scenario.jspi === false) assert.match(report.error.message, /--experimental-wasm-jspi/);
        assert.deepEqual(host, [], `${where}; without the native addon or JSPI, libfx loads no WebAssembly host`);
      }
    }
    if (!report.error) {
      assert.equal(report.text, "loaded", JSON.stringify(report));
      assert.equal(report.stopReason, "end_turn");
    }
    console.log(`${scenario.name} passed: ${report.info.backend}, WebAssembly host: ${host.join(", ") || "none"}`);
  }
  console.log(`Node load graph passed: native loads no WebAssembly host, the fallback loads it on demand, and ${foreignPackage} alone names ${localNativePackage}`);
} finally {
  await rm(temp, { recursive: true, force: true });
}
