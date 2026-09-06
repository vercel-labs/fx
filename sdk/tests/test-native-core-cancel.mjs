#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

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
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
});
try {
  let aborted = false;
  const agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    fetch(input, init) {
      if (init.method === "GET") {
        return Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] });
      }
      assert.equal(init.method, "POST");
      assert.equal(input, `http://127.0.0.1:${port}/stall`);
      init.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
      return fetch(input, init);
    },
    apiKey: "native-core-cancel-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/stall`,
    model: "native/test-model",
  });
  const turn = agent.prompt("stall");
  await Promise.race([requestStarted, timeout("stalled gateway POST")]);
  turn.cancel();
  const result = await Promise.race([turn.result, timeout("native cancellation")]);
  assert.equal(result.stopReason, "cancelled");
  assert.equal(aborted, true, "turn cancellation must abort Node fetch");
  assert.equal(await agent.close(), undefined);
  console.log("native core cancellation passed: stalled request cancelled and runtime closed");
} finally {
  server.closeAllConnections();
  server.close();
}
