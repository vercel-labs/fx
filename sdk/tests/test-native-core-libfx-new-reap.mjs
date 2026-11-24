#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../node.js";

// A host that drives the core directly can send libfx/new while a prompt waits
// on the model. The core must reap that prompt before it releases the session
// the prompt runs on, as session/new, session/load, and session/close do.
const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = require(resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node")));
const root = mkdtempSync(join(tmpdir(), "libfx-new-reap-"));
const home = join(root, "home");
mkdirSync(join(home, ".fx"), { recursive: true });

// The engine numbers its own requests from 1, so it never uses this id.
const libfxNewId = 2 ** 31 - 1;
const deadlineMs = 10_000;

let core;
let pendingOutput = "";
let answerLibfxNew;
const libfxNewAnswer = new Promise((resolveAnswer) => { answerLibfxNew = resolveAnswer; });
const watchedAddon = {
  ...addon,
  createCore(options) { return core = addon.createCore(options); },
  drainCore(handle) {
    const chunk = addon.drainCore(handle);
    pendingOutput += chunk.toString("utf8");
    const lines = pendingOutput.split("\n");
    pendingOutput = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id === libfxNewId) answerLibfxNew(message);
    }
    return chunk;
  },
};

let startModelRequest;
const modelRequestStarted = new Promise((resolveStart) => { startModelRequest = resolveStart; });
function fetch(_input, { signal, method }) {
  if (method === "GET") {
    return Promise.resolve(Response.json({
      object: "list",
      data: [{ id: "native/test-model", type: "language", tags: ["tool-use"] }],
    }));
  }
  // Headers arrive at once and the body never ends, so the prompt stays running.
  let stream;
  const body = new ReadableStream({ start(controller) { stream = controller; } });
  signal.addEventListener("abort", () => stream.error(signal.reason), { once: true });
  startModelRequest();
  return Promise.resolve(new Response(body, { headers: { "content-type": "text/event-stream" } }));
}

async function within(promise, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), deadlineMs); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

const agent = await createFxEngine({
  backend: "native",
  nativeAddon: watchedAddon,
  apiKey: "libfx-new-reap-key",
  model: "native/test-model",
  home,
  workspaceRoot: root,
  fetch,
});
try {
  const turn = agent.prompt("wait on the model");
  await within(modelRequestStarted, "the model request");
  addon.writeCore(core, Buffer.from(`${JSON.stringify({ jsonrpc: "2.0", id: libfxNewId, method: "libfx/new", params: {} })}\n`));
  const result = await within(turn.result, "the prompt to end after libfx/new");
  assert.equal(result.stopReason, "cancelled");
  const answer = await within(libfxNewAnswer, "the libfx/new answer");
  assert.equal(answer.error, undefined, `libfx/new failed: ${JSON.stringify(answer.error)}`);
  assert.equal(typeof answer.result?.sessionId, "string");
  console.log("native libfx/new reap passed: the running prompt was cancelled and libfx/new answered with a new session");
} finally {
  await agent.close();
  rmSync(root, { recursive: true, force: true });
}
