#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../node.js";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

const waitDeadlineMs = 10_000;
const invalidParamsCode = -32602;
const gatewayChatUrl = "http://127.0.0.1:9/chat";
// A slow peer's input: the headers arrive after five 50 ms pulses. This is not a wait for state.
const slow_host_header_delay_ms = 250;
const chatSseBody = 'data: {"type":"text-delta","delta":"recovered"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n';

function slowHostResponse(signal) {
  return new Promise((resolveResponse, rejectResponse) => {
    if (signal.aborted) {
      rejectResponse(signal.reason);
      return;
    }
    const timer = setTimeout(() => {
      resolveResponse(new Response(chatSseBody, { headers: { "content-type": "text/event-stream" } }));
    }, slow_host_header_delay_ms);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      rejectResponse(signal.reason);
    }, { once: true });
  });
}

async function runSlowHostHeaders() {
  const home = mkdtempSync(join(tmpdir(), "fx-slow-home-"));
  const workspaceRoot = mkdtempSync(join(tmpdir(), "fx-slow-workspace-"));
  let agent;
  try {
    let hostPosts = 0;
    agent = await createFxEngine({
      backend: "native",
      nativeAddon: addon,
      apiKey: "slow-host-headers-key",
      model: "native/test-model",
      home,
      workspaceRoot,
      fetch(_input, { signal, method }) {
        if (method === "GET") {
          return Promise.resolve(Response.json({
            object: "list",
            data: [{ id: "native/test-model", type: "language", tags: ["tool-use"] }],
          }));
        }
        hostPosts++;
        return slowHostResponse(signal);
      },
    });
    const turn = agent.prompt("slow host headers");
    let text = "";
    for await (const event of turn) {
      if (event.type === "text_delta") text += event.delta;
    }
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.equal(text, "recovered");
    assert.equal(hostPosts, 1, "the slow host response must be the turn's only chat request");
  } finally {
    await agent?.close();
    rmSync(home, { recursive: true, force: true });
    rmSync(workspaceRoot, { recursive: true, force: true });
  }
}

function withDeadline(task, what) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), waitDeadlineMs);
  });
  return Promise.race([task, deadline]).finally(() => clearTimeout(timer));
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function openCore({ home, workspaceRoot }) {
  const core = addon.createCore({
    apiKey: "session-switch-key",
    model: "native/test-model",
    home,
    workspaceRoot,
    gatewayChatUrl,
  });
  const readySocket = new Socket({ fd: addon.takeCoreReadyFd(core), readable: true, writable: false });
  const fetchTaken = deferred();
  const waiters = new Map();
  let nextId = 1;
  let buffered = "";
  let closed = false;

  function write(message) {
    addon.writeCore(core, Buffer.from(`${JSON.stringify(message)}\n`));
  }

  function dispatch(message) {
    const waiter = waiters.get(message.id);
    if (waiter === undefined) return;
    waiters.delete(message.id);
    waiter(message);
  }

  function onReadable() {
    if (closed) return;
    for (let chunk = addon.drainCore(core); chunk.length > 0; chunk = addon.drainCore(core)) {
      buffered += chunk.toString("utf8");
      const lines = buffered.split("\n");
      buffered = lines.pop();
      for (const line of lines) {
        if (line) dispatch(JSON.parse(line));
      }
    }
    const fetch = addon.takeCoreFetch(core);
    if (fetch) fetchTaken.resolve(fetch);
  }

  readySocket.on("data", onReadable);

  return {
    core,
    request(method, params = {}) {
      const id = nextId++;
      const answer = withDeadline(new Promise((resolveAnswer) => waiters.set(id, resolveAnswer)), `${method} response`);
      answer.catch(() => {});
      write({ jsonrpc: "2.0", id, method, params });
      return answer;
    },
    notify(method, params) {
      write({ jsonrpc: "2.0", method, params });
    },
    waitForFetch() {
      return withDeadline(fetchTaken.promise, "the host fetch");
    },
    abortFetch() {
      addon.abortCoreFetch(core);
    },
    close() {
      if (closed) return;
      closed = true;
      addon.closeCore(core);
      addon.destroyCore(core);
      readySocket.destroy();
    },
  };
}

async function startPromptDuringHeaderWait(client) {
  const initialized = await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
  assert.ok(initialized.result, JSON.stringify(initialized));
  const created = await client.request("session/new", {});
  const sessionId = created.result?.sessionId;
  assert.equal(typeof sessionId, "string", JSON.stringify(created));
  const turn = { sessionId, answered: false, prompt: null };
  turn.prompt = client.request("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: "wait for the host" }],
  });
  turn.prompt.then(() => { turn.answered = true; }, () => {});
  await client.waitForFetch();
  return turn;
}

async function expectCancelled(turn) {
  const answer = await turn.prompt;
  assert.equal(answer.result?.stopReason, "cancelled", JSON.stringify(answer));
}

async function runCase(run) {
  const home = mkdtempSync(join(tmpdir(), "fx-switch-home-"));
  const workspaceRoot = mkdtempSync(join(tmpdir(), "fx-switch-workspace-"));
  let client;
  try {
    client = openCore({ home, workspaceRoot });
    await run(client);
  } finally {
    client?.close();
    rmSync(home, { recursive: true, force: true });
    rmSync(workspaceRoot, { recursive: true, force: true });
  }
}

await runCase(async (client) => {
  const turn = await startPromptDuringHeaderWait(client);
  const second = await client.request("session/new", {});
  assert.equal(typeof second.result?.sessionId, "string", JSON.stringify(second));
  await expectCancelled(turn);
});
console.log("native session switch during a header wait passed: session/new answered and the prompt was cancelled");

await runCase(async (client) => {
  const turn = await startPromptDuringHeaderWait(client);
  client.notify("session/cancel", { sessionId: turn.sessionId });
  await expectCancelled(turn);
});
console.log("native session cancel during a header wait passed: session/cancel alone ended the prompt");

await runCase(async (client) => {
  const turn = await startPromptDuringHeaderWait(client);
  const invalid = await client.request("libfx/new", { sessionId: 5 });
  assert.equal(invalid.error?.code, invalidParamsCode, JSON.stringify(invalid));
  assert.equal(turn.answered, false, "the prompt answered after an invalid libfx/new");
  client.notify("session/cancel", { sessionId: turn.sessionId });
  client.abortFetch();
  await expectCancelled(turn);
});
console.log("native invalid libfx/new during a header wait passed: the prompt kept running until it was cancelled");

await withDeadline(runSlowHostHeaders(), "the slow host turn");
console.log("native slow host headers passed: headers after five pulses completed the turn");
