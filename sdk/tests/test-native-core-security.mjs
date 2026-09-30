#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

function fdCount() {
  try { return readdirSync("/dev/fd").length; } catch { return null; }
}

const beforeFds = fdCount();
for (let index = 0; index < 1000; index += 1) {
  assert.throws(() => addon.createCore({
    apiKey: "k".repeat(4096),
    model: 42,
    home: process.cwd(),
    workspaceRoot: process.cwd(),
  }));
}
const afterFds = fdCount();
if (beforeFds !== null && afterFds !== null) assert.ok(afterFds - beforeFds < 4, `fd leak: ${beforeFds} -> ${afterFds}`);

const customCore = {
  home: process.cwd(), workspaceRoot: process.cwd(), model: "local-model",
  providerJson: JSON.stringify({ local: {
    protocol: "openai-chat-completions", base_url: "http://127.0.0.1:11434/v1", auth: { type: "none" },
  } }),
};
for (const options of [
  { ...customCore, providerJson: "{}" },
  { ...customCore, providerJson: "not JSON" },
  { ...customCore, providerCredential: "unexpected-key" },
  { ...customCore, apiKey: "wrong-route-key" },
  { ...customCore, providerJson: JSON.stringify({ local: {
    protocol: "openai-chat-completions", base_url: "http://remote.example/v1", auth: { type: "none" },
  } }) },
]) {
  assert.throws(() => addon.createCore(options), (error) => error.code === "LIBFX_INVALID_ARGUMENT");
}
const isolated = addon.createCore(customCore);
addon.closeCore(isolated);
addon.destroyCore(isolated);

const runtimeLimitProbe = Array.from({ length: 64 }, () => addon.createCore({
  apiKey: "runtime-limit-key",
  home: process.cwd(),
  workspaceRoot: process.cwd(),
}));
assert.throws(
  () => addon.createCore({ apiKey: "runtime-limit-key", home: process.cwd(), workspaceRoot: process.cwd() }),
  (error) => error.code === "LIBFX_NATIVE_LIMIT",
);
for (const handle of runtimeLimitProbe) addon.closeCore(handle);
for (const handle of runtimeLimitProbe) addon.destroyCore(handle);

const core = addon.createCore({ apiKey: "security-test-key", home: process.cwd(), workspaceRoot: process.cwd() });
let nextId = 1;
function send(method, params) {
  const id = nextId++;
  addon.writeCore(core, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`));
  const deadline = Date.now() + 5000;
  let buffered = "";
  while (Date.now() < deadline) {
    buffered += addon.drainCore(core).toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === id) return message;
    }
  }
  throw new Error(`timed out waiting for ${method}`);
}

assert.ok(send("initialize", { protocolVersion: 1, clientCapabilities: {} }).result);
const response = send("session/new", {
  cwd: process.cwd(),
  mcpServers: [{ name: "blocked", command: "/bin/sh", args: ["-c", "exit 0"], env: [] }],
});
assert.equal(response.error?.code, -32602);
assert.match(response.error?.message ?? "", /MCP servers are unavailable/);

addon.closeCore(core);
addon.destroyCore(core);
console.log("native core security passed: malformed creation is stable and ACP stdio MCP is blocked");
