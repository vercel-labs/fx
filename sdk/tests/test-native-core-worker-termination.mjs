#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Worker } from "node:worker_threads";

let requestStartedResolve;
const requestStarted = new Promise((resolveStarted) => { requestStartedResolve = resolveStarted; });
const server = createServer((request) => {
  assert.equal(request.method, "POST");
  assert.equal(request.url, "/stall");
  request.resume();
  request.once("end", requestStartedResolve);
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const nodeModuleUrl = pathToFileURL(resolve(scriptDir, "../node.js")).href;

try {
  const worker = new Worker(`
    const { parentPort, workerData } = require("node:worker_threads");
    (async () => {
      const { createFxAgent } = await import(workerData.nodeModuleUrl);
      const agent = await createFxAgent({
        nativeAddon: workerData.addonPath,
        backend: "native",
        fetch(input, init) {
          if (init.method === "GET") {
            return Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] });
          }
          if (init.method !== "POST" || input !== workerData.gatewayUrl) throw new Error("unexpected worker fetch");
          return fetch(input, init);
        },
        apiKey: "worker-termination-key",
        gatewayChatUrl: workerData.gatewayUrl,
        model: "native/test-model",
      });
      agent.prompt("stall during worker termination");
      parentPort.postMessage("started");
    })().catch((error) => { throw error; });
  `, {
    eval: true,
    workerData: {
      addonPath,
      nodeModuleUrl,
      gatewayUrl: `http://127.0.0.1:${port}/stall`,
    },
  });
  await new Promise((resolveStarted, reject) => {
    worker.once("message", resolveStarted);
    worker.once("error", reject);
  });
  await Promise.race([
    requestStarted,
    new Promise((_, reject) => setTimeout(() => reject(new Error("worker did not reach the stalled POST")), 5000)),
  ]);
  const exitCode = await Promise.race([
    worker.terminate(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("worker termination hung in native finalizer")), 5000)),
  ]);
  assert.equal(typeof exitCode, "number");
  console.log("native worker termination passed: active stalled runtime finalized within 5s");
} finally {
  server.closeAllConnections();
  server.close();
}
