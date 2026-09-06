#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);
const core = addon.createCore({
  apiKey: "cancel-before-fetch-key",
  model: "native/test-model",
  home: "/tmp",
  workspaceRoot: "/tmp",
  gatewayChatUrl: "http://127.0.0.1:31337/chat",
});

let nextId = 1;
let buffered = "";
async function request(method, params = {}) {
  const id = nextId++;
  addon.writeCore(core, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`));
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    buffered += addon.drainCore(core).toString("utf8");
    const lines = buffered.split("\n");
    buffered = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === id) return message;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 2));
  }
  throw new Error(`timed out waiting for ${method}`);
}

try {
  assert.ok((await request("initialize", { protocolVersion: 1, clientCapabilities: {} })).result);
  const created = await request("session/new");
  const promptId = nextId++;
  addon.writeCore(core, Buffer.from(`${JSON.stringify({
    jsonrpc: "2.0",
    id: promptId,
    method: "session/prompt",
    params: { sessionId: created.result.sessionId, prompt: [{ type: "text", text: "cancel before host fetch" }] },
  })}\n`));
  await new Promise((resolveWait) => setTimeout(resolveWait, 100));
  addon.writeCore(core, Buffer.from(`${JSON.stringify({
    jsonrpc: "2.0",
    method: "session/cancel",
    params: { sessionId: created.result.sessionId },
  })}\n`));
  addon.abortCoreFetch(core);
  await new Promise((resolveWait) => setTimeout(resolveWait, 10));
  assert.equal(addon.takeCoreFetch(core), null, "cancelled native request remained available to the Node fetch poller");
  console.log("native pre-fetch cancellation passed: no stale request survives abort");
} finally {
  addon.closeCore(core);
  addon.destroyCore(core);
}

// Delay native publication until after the first abort and ACP cancellation
// until after publication, making the cancelled-turn race deterministic.
let delayedPrompt;
let delayedCancel;
let lateCore;
let latePublications = 0;
let hostFetches = 0;
let catalogFetches = 0;
let delayPublication = true;
let followingUp = false;
const delayedAddon = {
  ...addon,
  createCore(options) { return lateCore = addon.createCore(options); },
  writeCore(handle, bytes) {
    const message = JSON.parse(bytes.toString());
    if (delayPublication && message.method === "session/prompt") delayedPrompt = bytes;
    else if (delayPublication && message.method === "session/cancel") delayedCancel = bytes;
    else addon.writeCore(handle, bytes);
  },
  abortCoreFetch(handle) {
    const result = addon.abortCoreFetch(handle);
    if (delayedPrompt) {
      addon.writeCore(handle, delayedPrompt);
      delayedPrompt = null;
    }
    return result;
  },
  takeCoreFetch(handle) {
    const request = addon.takeCoreFetch(handle);
    if (request && delayedCancel) {
      latePublications++;
      delayPublication = false;
      addon.writeCore(handle, delayedCancel);
      delayedCancel = null;
    }
    return request;
  },
};
const agent = await createFxAgent({
  backend: "native",
  nativeAddon: delayedAddon,
  apiKey: "late-cancel-key",
  model: "native/test-model",
  fetch(_input, { signal, method }) {
    if (method === "GET") {
      catalogFetches++;
      return Promise.resolve(Response.json({
        object: "list",
        data: [{ id: "native/test-model", type: "language", tags: ["tool-use"] }],
      }));
    }
    hostFetches++;
    if (!followingUp) {
      return new Promise((_, reject) => {
        if (signal.aborted) reject(signal.reason);
        else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      });
    }
    return Promise.resolve(new Response('data: {"type":"text-delta","delta":"recovered"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
      headers: { "content-type": "text/event-stream" },
    }));
  },
});
let timer;
try {
  const turn = agent.prompt("cancel before native fetch publication");
  turn.cancel();
  const result = await Promise.race([
    turn.result,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("late native fetch did not observe cancellation")), 2000);
    }),
  ]);
  clearTimeout(timer);
  assert.equal(result.stopReason, "cancelled");
  assert.equal(latePublications, 1, "the fetch must publish after the idle abort");
  assert.equal(hostFetches, 0, "a cancelled turn must not start a late host request");
  assert.equal(catalogFetches, 0, "a cancelled turn must not start a late catalog request");
  followingUp = true;
  const followup = agent.prompt("continue after cancellation");
  let text = "";
  for await (const event of followup) if (event.type === "text_delta") text += event.delta;
  assert.equal((await followup.result).stopReason, "end_turn");
  assert.equal(text, "recovered");
  assert.equal(hostFetches, 1);
  assert.equal(catalogFetches, 1);
  console.log("native late-publication cancellation passed: cancelled before host fetch and follow-up recovered");
} finally {
  clearTimeout(timer);
  addon.abortCoreFetch(lateCore);
  await agent.close();
}
