#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);
const core = addon.createCore({ apiKey: "exit-code-test-key", home: "/tmp", workspaceRoot: "/tmp" });

try {
  addon.writeCore(core, Buffer.from("{}\n".repeat(180_000)));
  const deadline = Date.now() + 5000;
  while (!addon.coreExited(core) && Date.now() < deadline) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
  assert.equal(addon.coreExited(core), false, "queue pressure must pause output rather than stop the runtime");
  let count = 0;
  let buffered = "";
  const drainDeadline = Date.now() + 5000;
  while (count < 180_000 && Date.now() < drainDeadline) {
    const chunk = addon.drainCore(core);
    if (!chunk.length) { await new Promise((resolveWait) => setTimeout(resolveWait, 1)); continue; }
    buffered += chunk.toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      assert.equal(JSON.parse(line).error.code, -32600);
      count++;
    }
  }
  assert.equal(count, 180_000, "backpressured output lost replies");
  addon.closeCore(core);
  while (!addon.coreExited(core) && Date.now() < drainDeadline) {
    await new Promise((resolveWait) => setTimeout(resolveWait, 1));
  }
  assert.equal(addon.coreExited(core), true);
  assert.equal(addon.coreExitCode(core), 0);
} finally {
  addon.destroyCore(core);
}

const blocked = addon.createCore({ apiKey: "blocked-close-key", home: "/tmp", workspaceRoot: "/tmp" });
addon.writeCore(blocked, Buffer.from("{}\n".repeat(180_000)));
await new Promise((resolveWait) => setTimeout(resolveWait, 50));
addon.destroyCore(blocked);
console.log("native output passed: lossless backpressure, graceful drain and blocked destruction");
