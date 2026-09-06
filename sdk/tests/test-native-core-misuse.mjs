#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const ambientTraceChild = process.env.LIBFX_AMBIENT_TRACE_CHILD === "1";
if (!ambientTraceChild) {
  delete process.env.FX_TRACE;
  delete process.env.FX_TRACE_LOG;
  delete process.env.FX_TRACE_SCOPES;
  delete process.env.FX_TRACE_STDERR;
}
const addon = require(addonPath);

if (ambientTraceChild) {
  const traceCore = addon.createCore({
    apiKey: "trace-test-key",
    home: "/tmp",
    workspaceRoot: "/tmp",
  });
  try {
    assert.equal(addon.pushCoreFetchResponse(traceCore, 17, Buffer.from("secret-response-payload")), 0);
  } finally {
    addon.closeCore(traceCore);
    addon.destroyCore(traceCore);
  }
  process.exit(0);
}

for (const [name, args] of [
  ["createCore", []],
  ["takeCoreReadyFd", []],
  ["writeCore", []],
  ["writeCore", [{}]],
  ["closeCore", []],
  ["drainCore", []],
  ["takeCoreFetch", []],
  ["coreFetchActive", []],
  ["startCoreFetchResponse", []],
  ["pushCoreFetchResponse", []],
  ["finishCoreFetch", []],
  ["failCoreFetch", []],
  ["coreExited", []],
  ["coreExitCode", []],
  ["destroyCore", []],
]) {
  assert.throws(() => addon[name](...args), {
    name: "TypeError",
    code: "LIBFX_INVALID_ARGUMENT",
    message: "missing required argument",
  });
}

const getterError = new Error("host getter failed");
assert.throws(
  () => addon.createCore(Object.defineProperty({}, "apiKey", { get() { throw getterError; } })),
  (error) => error === getterError,
);
assert.throws(
  () => addon.createCore(new Proxy({}, { has() { throw getterError; } })),
  (error) => error === getterError,
);

for (const [options, message] of [
  [{ apiKey: "x".repeat(64 * 1024 + 1), home: "/tmp", workspaceRoot: "/tmp" }, /apiKey/],
  [{ apiKey: "key", model: "x".repeat(1025), home: "/tmp", workspaceRoot: "/tmp" }, /model/],
  [{ apiKey: "key", home: "x".repeat(16 * 1024 + 1), workspaceRoot: "/tmp" }, /home/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "http://attacker.example/chat" }, /gatewayChatUrl/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "https://user:pass@example.com/chat" }, /gatewayChatUrl/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "https://example.com/chat" }, /gatewayChatUrl/],
]) {
  assert.throws(() => addon.createCore(options), message);
}

for (const fakeHandle of [null, undefined, {}, Buffer.alloc(0), 0, "handle"]) {
  assert.throws(
    () => addon.coreExited(fakeHandle),
    (error) => error instanceof TypeError || error.code === "LIBFX_INVALID_ARGUMENT" || error.code === "LIBFX_NAPI",
  );
}

const core = addon.createCore({ apiKey: "misuse-test-key", home: "/tmp", workspaceRoot: "/tmp" });
assert.throws(
  () => addon.writeCore(core, Buffer.alloc(8 * 1024 * 1024 + 1)),
  (error) => error.code === "LIBFX_NATIVE_BACKPRESSURE",
);
addon.writeCore(core, Buffer.alloc(0));
addon.closeCore(core);
addon.destroyCore(core);
assert.throws(
  () => addon.coreExited(core),
  (error) => error.code === "LIBFX_NATIVE_CLOSED",
);

const lifecycleCore = addon.createCore({
  apiKey: "lifecycle-test-key",
  model: "native/test-model",
  home: "/tmp",
  workspaceRoot: "/tmp",
  gatewayChatUrl: "http://127.0.0.1:31337/chat",
});
let nextId = 1;
let buffered = "";
const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
  timer.unref();
});
const send = (method, params = {}) => {
  const id = nextId++;
  addon.writeCore(lifecycleCore, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`));
  return id;
};
const waitForResponse = async (id) => {
  for (;;) {
    buffered += addon.drainCore(lifecycleCore).toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === id) return message;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 2));
  }
};
const request = async (method, params = {}) => {
  const id = send(method, params);
  return Promise.race([waitForResponse(id), timeout(method)]);
};
const takeFetch = async () => {
  for (;;) {
    const bytes = addon.takeCoreFetch(lifecycleCore);
    if (bytes) return JSON.parse(bytes.toString("utf8"));
    await new Promise((resolveWait) => setTimeout(resolveWait, 2));
  }
};
const responseBytes = (text) => Buffer.from([
  `data: ${JSON.stringify({ type: "text-delta", delta: text })}\n\n`,
  'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n',
  "data: [DONE]\n\n",
].join(""));
const sendPrompt = (sessionId, text) => send("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text }],
});

try {
  assert.ok((await request("initialize", { protocolVersion: 1, clientCapabilities: {} })).result);
  const created = await request("session/new");
  const sessionId = created.result.sessionId;

  const firstPrompt = sendPrompt(sessionId, "first low-level prompt");
  const catalogFetch = await Promise.race([takeFetch(), timeout("model catalog fetch")]);
  assert.equal(catalogFetch.method, "GET");
  assert.equal(catalogFetch.url, "https://ai-gateway.vercel.sh/coding-agent/v1/models");
  assert.equal(addon.startCoreFetchResponse(lifecycleCore, catalogFetch.handle, 200), 1);
  assert.equal(addon.pushCoreFetchResponse(lifecycleCore, catalogFetch.handle, Buffer.from(JSON.stringify({
    object: "list", data: [{ id: "native/test-model", type: "language" }],
  }))), 1);
  assert.equal(addon.finishCoreFetch(lifecycleCore, catalogFetch.handle), 1);
  const firstFetch = await Promise.race([takeFetch(), timeout("first host fetch")]);
  assert.equal(firstFetch.method, "POST");
  assert.equal(firstFetch.url, "http://127.0.0.1:31337/chat");
  assert.ok(Number.isInteger(firstFetch.handle) && firstFetch.handle > 0, "fetch request must carry a positive handle");
  const firstHandle = firstFetch.handle;
  const futureHandle = firstHandle + 1;
  assert.equal(addon.coreFetchActive(lifecycleCore, firstHandle), true);
  assert.equal(addon.coreFetchActive(lifecycleCore, futureHandle), false);
  assert.equal(addon.startCoreFetchResponse(lifecycleCore, futureHandle, 200), 0);
  assert.equal(addon.coreFetchActive(lifecycleCore, firstHandle), true, "stale start must not mutate the active handle");
  assert.equal(addon.startCoreFetchResponse(lifecycleCore, firstHandle, 200), 1);
  assert.equal(addon.pushCoreFetchResponse(lifecycleCore, firstHandle, Buffer.alloc(8 * 1024 * 1024 + 1)), 2);
  assert.equal(addon.pushCoreFetchResponse(lifecycleCore, firstHandle, responseBytes("first")), 1);
  assert.equal(addon.finishCoreFetch(lifecycleCore, firstHandle), 1);
  assert.equal((await Promise.race([waitForResponse(firstPrompt), timeout("first prompt result")])).result.stopReason, "end_turn");

  const secondPrompt = sendPrompt(sessionId, "second low-level prompt");
  const secondFetch = await Promise.race([takeFetch(), timeout("second host fetch")]);
  assert.equal(secondFetch.method, "POST");
  assert.notEqual(secondFetch.handle, firstHandle, "sequential fetches must use unique handles");
  const secondHandle = secondFetch.handle;
  assert.equal(addon.startCoreFetchResponse(lifecycleCore, firstHandle, 200), 0);
  assert.equal(addon.pushCoreFetchResponse(lifecycleCore, firstHandle, Buffer.from("stale")), 0);
  assert.equal(addon.finishCoreFetch(lifecycleCore, firstHandle), 0);
  assert.equal(addon.failCoreFetch(lifecycleCore, firstHandle), 0);
  assert.equal(addon.coreFetchActive(lifecycleCore, secondHandle), true, "stale operations must not mutate the newer handle");
  assert.equal(addon.startCoreFetchResponse(lifecycleCore, secondHandle, 200), 1);
  assert.equal(addon.pushCoreFetchResponse(lifecycleCore, secondHandle, responseBytes("second")), 1);
  assert.equal(addon.finishCoreFetch(lifecycleCore, secondHandle), 1);
  assert.equal((await Promise.race([waitForResponse(secondPrompt), timeout("second prompt result")])).result.stopReason, "end_turn");

  for (const [name, args] of [
    ["coreFetchActive", [lifecycleCore, 0]],
    ["startCoreFetchResponse", [lifecycleCore, 0, 200]],
    ["pushCoreFetchResponse", [lifecycleCore, 0, Buffer.alloc(0)]],
    ["finishCoreFetch", [lifecycleCore, 0]],
    ["failCoreFetch", [lifecycleCore, 0]],
  ]) {
    assert.throws(() => addon[name](...args), {
      name: "TypeError",
      code: "LIBFX_INVALID_ARGUMENT",
    });
  }
} finally {
  addon.closeCore(lifecycleCore);
  addon.destroyCore(lifecycleCore);
}

const traceDir = mkdtempSync(resolve(tmpdir(), "libfx-ambient-trace-"));
const traceLog = resolve(traceDir, "trace.log");
try {
  const isolated = spawnSync(process.execPath, [fileURLToPath(import.meta.url), addonPath], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: {
      ...process.env,
      LIBFX_AMBIENT_TRACE_CHILD: "1",
      FX_TRACE: "1",
      FX_TRACE_LOG: traceLog,
      FX_TRACE_SCOPES: "napi,acp,interrupt",
      FX_TRACE_STDERR: "1",
    },
  });
  assert.equal(isolated.status, 0, isolated.stderr || isolated.stdout);
  assert.equal(isolated.stdout, "", "ambient fx tracing must not change libfx stdout");
  assert.equal(isolated.stderr, "", "ambient fx tracing must not change libfx stderr");
  assert.equal(existsSync(traceLog), false, "ambient fx tracing must not create a libfx trace file");
} finally {
  rmSync(traceDir, { recursive: true, force: true });
}

console.log("native core misuse passed: argument, handle, stale, ambient trace isolation, backpressure, and closed-handle checks are enforced");
