#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { once } from "node:events";
import { closeSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

let wake;
let pendingReady = false;
function notify() {
  pendingReady = true;
  wake?.();
}
async function waitReady() {
  if (pendingReady) { pendingReady = false; return; }
  let timer;
  try {
    await new Promise((resolveReady, reject) => {
      wake = resolveReady;
      timer = setTimeout(() => reject(new Error("native core did not notify JavaScript that work was ready")), 5000);
    });
    pendingReady = false;
  } finally {
    wake = null;
    clearTimeout(timer);
  }
}
const core = addon.createCore({
  apiKey: "ready-test-key",
  home: process.cwd(),
  workspaceRoot: process.cwd(),
});
const reader = addon.takeCoreReadyFd(core);
assert.throws(() => addon.takeCoreReadyFd(core), /already transferred/);
const socket = new Socket({ fd: reader, readable: true, writable: false });
socket.on("data", notify);
socket.on("end", notify);
if (socket.pending) socket.connect({ fd: reader });
const socketClosed = once(socket, "close");

try {
  addon.writeCore(core, Buffer.from(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: 1, clientCapabilities: {} },
  })}\n`));

  let buffered = "";
  async function responses(count) {
    const messages = [];
    while (messages.length < count) {
      await waitReady();
      for (;;) {
        const chunk = addon.drainCore(core);
        if (!chunk.length) break;
        buffered += chunk.toString("utf8");
        for (;;) {
          const end = buffered.indexOf("\n");
          if (end < 0) break;
          messages.push(JSON.parse(buffered.slice(0, end)));
          buffered = buffered.slice(end + 1);
        }
      }
    }
    return messages;
  }
  const initialized = await responses(1);
  assert.equal(initialized[0].id, 1);
  assert.ok(initialized[0].result);

  // Burst writes coalesce, and the next burst races against the previous drain.
  for (let batch = 0; batch < 20; batch++) {
    const ids = Array.from({ length: 50 }, (_, index) => 2 + batch * 50 + index);
    addon.writeCore(core, Buffer.from(ids.map((id) =>
      JSON.stringify({ jsonrpc: "2.0", id, method: "unknown-readiness-method" }) + "\n",
    ).join("")));
    const received = await responses(ids.length);
    assert.deepEqual(received.map((message) => message.id), ids);
    assert.ok(received.every((message) => message.error?.code === -32601));
  }
  addon.closeCore(core);
  while (!addon.coreExited(core)) await waitReady();
  assert.equal(addon.coreExitCode(core), 0);
} finally {
  addon.closeCore(core);
  addon.destroyCore(core);
  socket.destroy();
  await socketClosed;
}

const beforeFds = readdirSync("/dev/fd").length;
// Unclaimed readers and pending exit wakes are released with their runtime.
for (let index = 0; index < 32; index++) {
  const closing = addon.createCore({ apiKey: "ready-close-key", home: "/tmp", workspaceRoot: "/tmp" });
  if (index % 2 === 0) closeSync(addon.takeCoreReadyFd(closing));
  addon.closeCore(closing);
  addon.destroyCore(closing);
}
await new Promise((resolveReady) => setImmediate(resolveReady));
assert.equal(readdirSync("/dev/fd").length, beforeFds);

console.log("native core readiness notification passed");
