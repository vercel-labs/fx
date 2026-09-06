#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] ?? "native";
const root = fileURLToPath(new URL("../..", import.meta.url));
const nativeAddon = process.argv[3] ?? resolve(root, "zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(root, "zig-out/bin/fx-core.wasm")) : undefined;
const hash = (value) => createHash("sha256").update(value).digest("hex");
const delta = (text) => `data: ${JSON.stringify({ type: "text-delta", delta: text })}\n\n`;
const finish = 'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n';
const pause = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));
const catalogResponse = () => Response.json({ object: "list", data: [{ id: "fixture/output", type: "language" }] });
const deadline = setTimeout(() => { throw new Error("bounded output did not settle"); }, 25_000);
let agent;

async function start(fetch, onEvent, options = {}) {
  agent = await createFxAgent({
    backend, nativeAddon, wasm, apiKey: "output-pressure-fixture", model: "fixture/output",
    fetch: (url, init) => init.method === "GET" ? catalogResponse() : fetch(url, init),
    onEvent, ...options,
  });
  return agent;
}

async function collect(turn) {
  const digest = createHash("sha256");
  let bytes = 0;
  for await (const event of turn) if (event.type === "text_delta") {
    bytes += Buffer.byteLength(event.delta);
    digest.update(event.delta);
  }
  assert.equal((await turn.result).stopReason, "end_turn");
  return { bytes, hash: digest.digest("hex") };
}

try {
  // Identical text must survive both one oversized transport write and many writes.
  const source = "\u{1f600}界".repeat(1_200_000) + " tail\n";
  for (const fragmented of [false, true]) {
    console.log(`${backend}: large output fragmented=${fragmented}`);
    await start(async () => {
      const parts = fragmented ? source.match(/.{1,4096}/gsu) : [source];
      return new Response(parts.map(delta).join("") + finish);
    });
    assert.deepEqual(await collect(agent.prompt("large text")), {
      bytes: Buffer.byteLength(source), hash: hash(source),
    });
    await agent.close();
    agent = null;
  }

  // A fast producer cannot publish the entire response into an unread JS queue.
  let received = 0;
  let pressure;
  console.log(`${backend}: paused consumer`);
  const part = "x".repeat(16 * 1024);
  const total = 1024;
  await start(async () => new Response(delta(part).repeat(total) + finish), (event) => {
    if (event.type === "output.backpressure") pressure = event;
    if (event.type === "acp.receive" && event.message?.params?.update?.sessionUpdate === "agent_message_chunk") received++;
  });
  const slow = agent.prompt("pause the consumer");
  let settled = false;
  void slow.result.then(() => { settled = true; });
  while (!pressure) await pause(5);
  assert.ok(pressure.bufferedBytes <= 1024 * 1024);
  assert.ok(pressure.bufferedEvents <= 256);
  await pause(100);
  assert.ok(received < total, "unread SDK events did not backpressure the producer");
  assert.equal(settled, false, "completion overtook unread output");
  assert.deepEqual(await collect(slow), { bytes: part.length * total, hash: hash(part.repeat(total)) });
  await agent.close();
  agent = null;

  // Cancellation releases an output wait without requiring an iterator to resume.
  console.log(`${backend}: cancel and reuse`);
  received = 0;
  let aborted = false;
  let requests = 0;
  await start(async (_url, options) => {
    requests++;
    if (requests > 1) return new Response(delta("after cancel") + finish);
    return new Response(new ReadableStream({
      start(controller) {
        options.signal.addEventListener("abort", () => {
          aborted = true;
          controller.error(options.signal.reason);
        }, { once: true });
        controller.enqueue(new TextEncoder().encode(delta(part).repeat(256)));
      },
    }));
  }, (event) => {
    if (event.type === "acp.receive" && event.message?.params?.update?.sessionUpdate === "agent_message_chunk") received++;
  });
  const cancelled = agent.prompt("cancel with a full queue");
  while (!received) await pause(5);
  await pause(50);
  cancelled.cancel();
  assert.equal((await cancelled.result).stopReason, "cancelled");
  assert.equal(aborted, true);
  assert.deepEqual(await collect(agent.prompt("reuse after cancel")), {
    bytes: 12, hash: hash("after cancel"),
  });
  await agent.close();
  agent = null;
  console.log(`${backend}: close while backpressured and independent owner`);
  pressure = null;
  await start(async () => new Response(delta(part).repeat(256) + finish), (event) => {
    if (event.type === "output.backpressure") pressure = event;
  });
  const closing = agent.prompt("close while unread");
  while (!pressure) await pause(5);
  const independent = await createFxAgent({
    backend, nativeAddon, wasm, apiKey: "independent-fixture", model: "fixture/output",
    fetch: async (_url, init) => init.method === "GET" ? catalogResponse() : new Response(delta("independent") + finish),
  });
  try {
    assert.deepEqual(await collect(independent.prompt("separate owner")), {
      bytes: 11, hash: hash("independent"),
    });
  } finally { await independent.close(); }
  await agent.close();
  assert.equal((await closing.result).stopReason, "cancelled");
  agent = null;
  console.log(`${backend}: queued tool stays cancelled`);
  pressure = null;
  let effects = 0;
  const toolWire = 'data: {"type":"tool-call","toolCallId":"queued","toolName":"effect","input":{}}\n\n' +
    'data: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n';
  await start(async () => new Response(delta(part).repeat(128) + toolWire), (event) => {
    if (event.type === "output.backpressure") pressure = event;
  }, { tools: [{
    name: "effect", description: "Record one effect", inputSchema: { type: "object", properties: {} },
    execute() { effects++; return "effect"; },
  }] });
  const queuedTool = agent.prompt("cancel queued tool");
  while (!pressure) await pause(5);
  await pause(100);
  queuedTool.cancel();
  assert.equal((await queuedTool.result).stopReason, "cancelled");
  assert.equal(effects, 0, "a tool queued behind output executed after cancellation");
  await agent.close();
  agent = null;
  console.log(`${backend}: cancel from pressure notification`);
  let callbackTurn;
  await start(async () => new Response(delta(part).repeat(128) + finish), (event) => {
    if (event.type === "output.backpressure") callbackTurn.cancel();
  });
  callbackTurn = agent.prompt("cancel in the callback");
  assert.equal((await callbackTurn.result).stopReason, "cancelled");
  await agent.close();
  agent = null;
  console.log(`${backend}: iterator close interrupts a pending read`);
  for (const operation of ["return", "throw"]) {
    let fetchStarted = false;
    aborted = false;
    await start(async (_url, options) => {
      fetchStarted = true;
      return new Promise((_, reject) => options.signal.addEventListener("abort", () => {
        aborted = true;
        reject(options.signal.reason);
      }, { once: true }));
    });
    const unread = agent.prompt("close the pending iterator");
    const iterator = unread[Symbol.asyncIterator]();
    const next = iterator.next();
    while (!fetchStarted) await pause(5);
    const reason = new Error("stop consuming");
    const stopped = iterator[operation](reason);
    assert.equal(aborted, true, "iterator close did not abort the active fetch immediately");
    const closingResult = operation === "throw" ? assert.rejects(stopped, (error) => error === reason) : stopped;
    assert.equal((await unread.result).stopReason, "cancelled");
    assert.equal((await next).done, true);
    await closingResult;
    await agent.close();
    agent = null;
  }
  let earlyFetches = 0;
  await start(async () => { earlyFetches++; return new Response(delta("unexpected") + finish); });
  const neverRead = agent.prompt("close before the first read");
  await neverRead[Symbol.asyncIterator]().return();
  assert.equal((await neverRead.result).stopReason, "cancelled");
  assert.equal(earlyFetches, 0);
  await agent.close();
  agent = null;
  if (backend === "native") {
    const addon = createRequire(import.meta.url)(nativeAddon);
    let corrupt = false;
    await start(async () => new Response(delta("valid provider text") + finish), undefined, {
      nativeAddon: {
        ...addon,
        drainCore(core) {
          const chunk = addon.drainCore(core);
          if (corrupt && chunk.length) { corrupt = false; return Buffer.from("not-json\n"); }
          return chunk;
        },
      },
    });
    corrupt = true;
    const broken = agent.prompt("transport corruption");
    const next = broken[Symbol.asyncIterator]().next();
    await Promise.all([assert.rejects(broken.result, SyntaxError), assert.rejects(next, SyntaxError)]);
    await agent.close();
    agent = null;
  }
  console.log(`${backend} bounded output passed: large frames, slow consumer, cancellation and reuse`);
} finally {
  await agent?.close();
  clearTimeout(deadline);
}
