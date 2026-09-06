#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../sdk/node.js";

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const backend = value("--backend", "native");
const count = Number(value("--count", "25"));
if (!new Set(["native", "wasm"]).has(backend) || !Number.isInteger(count) || count < 1 || count > 64) {
  throw new Error("usage: bench-capacity.mjs --backend native|wasm --count 1..64");
}

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
let requestCount = 0;
let catalogRequests = 0;
let stall = false;
let stalledRequests = 0;
let stalledReady;
const server = createServer((request, response) => {
  if (request.method === "GET") {
    catalogRequests += 1;
    request.resume();
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ object: "list", data: [{ id: "capacity/model", type: "language" }] }));
    return;
  }
  requestCount++;
  request.resume();
  request.on("end", () => {
    if (stall) {
      if (++stalledRequests === count) stalledReady();
      return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"text-delta","delta":"ok"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

function countDirectory(path) {
  try { return readdirSync(path).length; } catch { return null; }
}

function threadCount() {
  const procCount = countDirectory("/proc/self/task");
  if (procCount !== null) return procCount;
  try {
    return execFileSync("ps", ["-M", "-p", String(process.pid)], { encoding: "utf8" }).trim().split("\n").length - 1;
  } catch {
    return null;
  }
}

function descriptorCount() {
  return countDirectory(process.platform === "linux" ? "/proc/self/fd" : "/dev/fd");
}

function collect(stage) {
  const memory = process.memoryUsage();
  return {
    stage,
    rss_bytes: memory.rss,
    heap_used_bytes: memory.heapUsed,
    external_bytes: memory.external,
    array_buffers_bytes: memory.arrayBuffers,
    thread_count: threadCount(),
    descriptor_count: descriptorCount(),
    active_handles: typeof process._getActiveHandles === "function" ? process._getActiveHandles().length : null,
  };
}

function forceGc() {
  if (typeof globalThis.gc === "function") globalThis.gc();
  if (typeof globalThis.Bun?.gc === "function") globalThis.Bun.gc(true);
}

async function quiesce() {
  forceGc();
  await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  forceGc();
}

const options = {
  backend,
  nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
  wasm: resolve(root, "zig-out/bin/fx-core.wasm"),
  fetch(input, init) {
    return fetch(init.method === "GET" ? `http://127.0.0.1:${server.address().port}/models` : input, init);
  },
  apiKey: "capacity-benchmark-key",
  gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  model: "capacity/model",
};
const snapshots = [];
const failures = [];
let agents = [];
let serverOpen = true;

async function exercise(agent, prompt) {
  const turn = agent.prompt(prompt);
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  const result = await turn.result;
  if (text !== "ok" || result.stopReason !== "end_turn") {
    throw new Error(`unexpected capacity result for ${prompt}: ${result.stopReason}, ${JSON.stringify(text)}`);
  }
}

async function cancelAndRecover() {
  const entered = new Promise((resolveEntered) => { stalledReady = resolveEntered; });
  stall = true;
  const turns = agents.map((agent) => agent.prompt("cancel an active request"));
  let timer;
  try {
    await Promise.race([
      entered,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("concurrent requests did not reach the server")), 5000); }),
    ]);
  } finally {
    clearTimeout(timer);
    stall = false;
    turns.forEach((turn) => turn.cancel());
  }
  const cancelled = await Promise.all(turns.map((turn) => turn.result));
  assert.ok(cancelled.every((result) => result.stopReason === "cancelled"));
  await Promise.all(agents.map((agent, index) => exercise(agent, `after active cancellation ${index}`)));
  assert.equal(requestCount, 1 + 4 * count);
}

try {
  const warmup = await createFxAgent(options);
  try {
    await exercise(warmup, "capacity warmup");
  } finally {
    await warmup.close();
  }
  await quiesce();
  snapshots.push(collect("baseline"));
  const created = await Promise.allSettled(Array.from({ length: count }, () => createFxAgent(options)));
  for (const [index, result] of created.entries()) {
    if (result.status === "fulfilled") agents.push(result.value);
    else failures.push({ index, error: String(result.reason) });
  }
  created.length = 0;
  await quiesce();
  snapshots.push(collect("created"));

  await Promise.all(agents.map(async (agent, index) => {
    try {
      await exercise(agent, `capacity ${index}`);
      const signal = new AbortController();
      signal.abort();
      const cancelled = agent.prompt("cancel before fetch", { signal: signal.signal });
      assert.equal((await cancelled.result).stopReason, "cancelled");
      await exercise(agent, `recovered ${index}`);
    } catch (error) {
      failures.push({ index, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) });
    }
  }));
  await quiesce();
  snapshots.push(collect("prompted"));
  assert.equal(requestCount, 1 + 2 * agents.length, "cancelled prompts must not call inference");

  if (agents.length === count) {
    await cancelAndRecover();
  }
  await quiesce();
  snapshots.push(collect("closing"));

  await Promise.all(agents.map((agent) => agent.close()));
  agents = [];
  await quiesce();
  snapshots.push(collect("closed"));

  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
  serverOpen = false;
  await quiesce();
  snapshots.push(collect("server_closed"));

  process.stdout.write(`${JSON.stringify({
    format_version: 1,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    backend,
    count,
    non_prompt_fetches: catalogRequests,
    failures,
    snapshots,
  }, null, 2)}\n`);
} finally {
  await Promise.all(agents.map((agent) => agent.close().catch(() => {})));
  if (serverOpen) {
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}
