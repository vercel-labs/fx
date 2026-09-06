#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
let timeoutId;
let fetchCalls = 0;
let catalogCalls = 0;
const agent = await createFxAgent({
  nativeAddon: addon,
  backend: "native",
  fetch(_url, init) {
    if (init.method === "GET") {
      catalogCalls += 1;
      return Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] });
    }
    assert.equal(init.method, "POST");
    fetchCalls += 1;
    const error = new Error("host timeout");
    error.name = "AbortError";
    throw error;
  },
  apiKey: "native-core-fetch-failure-key",
  model: "native/test-model",
});

let closed = false;
try {
  const turn = agent.prompt("fail host fetch");
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error("native host-fetch failure hung")), 5000);
  });
  await assert.rejects(
    Promise.race([turn.result, timeout]),
    (error) => error.message !== "native host-fetch failure hung",
  );
  assert.equal(fetchCalls, 2, "an exhausted host transport must stop after one retry");
  assert.equal(catalogCalls, 1);
  assert.equal(await agent.close(), undefined);
  closed = true;
  console.log("native host-fetch failure passed: independent AbortError fails without hanging");
} finally {
  clearTimeout(timeoutId);
  if (!closed) await agent.close().catch(() => {});
}
