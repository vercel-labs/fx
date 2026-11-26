#!/usr/bin/env node
// SIGTERM to a process running a durable turn: `createFxAgent()` hands the
// turn off at its next safe point, or cuts it off after its bound, then the
// process exits as Node.js would have; the next process continues the turn.
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { local } from "../durable/local.mjs";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
// Every wait fails its test with a message after this long.
const guardMs = 20_000;
const sessionPrefix = "session ";

// The model asks for the wait tool once, then answers with its result.
const requests = [];
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "journal/model", type: "language" }] }));
      return;
    }
    const { prompt } = JSON.parse(body);
    requests.push(prompt);
    const frames = toolResults(prompt).length === 0
      ? [
        { type: "tool-call", toolCallId: "call-1", toolName: "wait", input: {} },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ]
      : [
        { type: "text-delta", id: "answer", delta: "done" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
      ];
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const gatewayChatUrl = `http://127.0.0.1:${port}/chat`;
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  const method = String(init?.method ?? input?.method ?? "GET").toUpperCase();
  if (url.hostname === "ai-gateway.vercel.sh" && method === "GET") {
    return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  }
  return fetch(input, init);
};

// The wait tool as this process sees it: the test only reads its journal, so
// the tool returns at once.
const instantWait = {
  name: "wait",
  description: "Waits for the test",
  idempotent: false,
  inputSchema: { type: "object", properties: {} },
  execute: async () => "waited",
};

// Fails with `what` unless the promise settles within guardMs.
function guarded(promise, what) {
  let timer;
  const expired = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not happen within ${guardMs} ms`)), guardMs);
  });
  return Promise.race([promise, expired]).finally(() => clearTimeout(timer));
}

// Starts a child for `mode` on the journal in `dir`. `line(prefix)` resolves
// with the first line the child prints that starts with `prefix`.
function startChild(mode, dir) {
  const child = spawn(process.execPath, [resolve(scriptDir, "sigterm-agent.mjs"), mode, dir, String(port), addon], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  const printed = [];
  const waiters = new Set();
  let partial = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    partial += chunk;
    const lines = partial.split("\n");
    partial = lines.pop();
    printed.push(...lines);
    for (const waiter of waiters) waiter();
  });
  const exited = new Promise((resolveExit) => {
    child.once("exit", (code, signal) => resolveExit({ code, signal }));
  });
  const line = (prefix) => guarded(new Promise((resolveLine) => {
    const check = () => {
      const found = printed.find((text) => text.startsWith(prefix));
      if (found !== undefined) {
        waiters.delete(check);
        resolveLine(found);
      }
    };
    waiters.add(check);
    check();
  }), `the child printing a line that starts with "${prefix}"`);
  return { child, line, exited };
}

// Waits until the child's turn is inside the wait tool, and returns its
// session id.
async function waitInTool(line) {
  const sessionId = (await line(sessionPrefix)).slice(sessionPrefix.length);
  await line("tool-started");
  return sessionId;
}

// Stops a child the test left running, so a failed test leaks no process.
function killIfRunning(child) {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
}

// Reads a session's journal through a new agent that does not listen for
// SIGTERM. The caller closes the agent.
async function logOf(dir, sessionId) {
  const agent = createFxAgent({
    durability: local({ dir }),
    handOffOnSigterm: false,
    backend: "native",
    nativeAddon: addon,
    fetch: loopbackFetch,
    apiKey: "sigterm-key",
    gatewayChatUrl,
    model: "journal/model",
    tools: [instantWait],
  });
  const log = await agent[Symbol.for("libfx.durableInternals")].openLog(sessionId);
  const entries = (await log.read()).map(({ entry }) => entry);
  return { agent, entries };
}

const cases = [];
const test = (name, body) => cases.push({ name, body });

test("a SIGTERM during a tool call yields the turn after the call, and the next process continues it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-sigterm-"));
  const { child, exited, line } = startChild("short", dir);
  try {
    const sessionId = await waitInTool(line);
    const requestsBefore = requests.length;
    child.kill("SIGTERM");
    // `go` goes in only after libfx has asked the turn to yield.
    await line("sigterm-seen");
    child.stdin.write("go\n");
    const status = await guarded(exited, "the child's exit");
    assert.equal(status.signal, "SIGTERM");
    assert.equal(requests.length, requestsBefore, "the model was asked again after the tool went out");
    const { agent, entries } = await logOf(dir, sessionId);
    try {
      const release = entries.findLast((entry) => entry.k === "release");
      assert.ok(release, "the child wrote no release");
      assert.equal(release.cutoff, undefined, "the turn was cut off instead of yielding");
      const turn = agent.session(sessionId).resume();
      for await (const _ of turn) {}
      const result = await turn.result;
      assert.equal(result.stopReason, "end_turn");
      assert.equal(toolResults(requests.at(-1)).length, 1);
    } finally {
      await agent.close();
    }
  } finally {
    killIfRunning(child);
    await rm(dir, { recursive: true, force: true });
  }
});

test("a SIGTERM during a tool call that does not return cuts the turn off after its bound, and the process exits by the signal", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-sigterm-"));
  const { child, exited, line } = startChild("hang", dir);
  try {
    const sessionId = await waitInTool(line);
    child.kill("SIGTERM");
    // The tool never returns, so the child exits only once the bound cuts the
    // turn off: the release below names that cut-off.
    const status = await guarded(exited, "the child's exit");
    assert.equal(status.signal, "SIGTERM");
    const { agent, entries } = await logOf(dir, sessionId);
    try {
      assert.ok(entries.some((entry) => entry.k === "release" && typeof entry.cutoff === "string"), "no release names a cut-off");
    } finally {
      await agent.close();
    }
  } finally {
    killIfRunning(child);
    await rm(dir, { recursive: true, force: true });
  }
});

test("an app that listens for SIGTERM itself keeps its exit, and libfx still hands off", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-sigterm-"));
  const { child, exited, line } = startChild("app-listener", dir);
  try {
    const sessionId = await waitInTool(line);
    child.kill("SIGTERM");
    const status = await guarded(exited, "the child's exit");
    assert.equal(status.code, 7);
    assert.equal(status.signal, null);
    const { agent, entries } = await logOf(dir, sessionId);
    try {
      assert.ok(entries.some((entry) => entry.k === "release" && typeof entry.cutoff === "string"), "no release names a cut-off");
    } finally {
      await agent.close();
    }
  } finally {
    killIfRunning(child);
    await rm(dir, { recursive: true, force: true });
  }
});

test("handOffOnSigterm: false leaves SIGTERM to Node.js", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-sigterm-"));
  const { child, exited, line } = startChild("off", dir);
  try {
    const sessionId = await waitInTool(line);
    child.kill("SIGTERM");
    const status = await guarded(exited, "the child's exit");
    assert.equal(status.signal, "SIGTERM");
    const { agent, entries } = await logOf(dir, sessionId);
    try {
      const lastLease = entries.findLastIndex((entry) => entry.k === "lease");
      assert.notEqual(lastLease, -1, "the child took no lease");
      assert.equal(entries.slice(lastLease + 1).some((entry) => entry.k === "release"), false, "a release came after the last lease");
    } finally {
      await agent.close();
    }
  } finally {
    killIfRunning(child);
    await rm(dir, { recursive: true, force: true });
  }
});

test("one SIGTERM listener serves every agent, and close() removes it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-sigterm-"));
  try {
    const before = process.listenerCount("SIGTERM");
    const first = createFxAgent({ durability: local({ dir }) });
    const second = createFxAgent({ durability: local({ dir }) });
    assert.equal(process.listenerCount("SIGTERM"), before + 1);
    await first.close();
    assert.equal(process.listenerCount("SIGTERM"), before + 1);
    await second.close();
    assert.equal(process.listenerCount("SIGTERM"), before);
    assert.throws(() => createFxAgent({ handOffOnSigterm: "yes" }), { name: "TypeError" });
    assert.throws(() => createFxAgent({ handOffOnSigterm: { within: -1 } }), { name: "TypeError" });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`durable SIGTERM hand-off passed: ${cases.length} tests`);
} finally {
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
