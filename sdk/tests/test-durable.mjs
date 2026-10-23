#!/usr/bin/env node
// Durable sessions through createFxAgent: the production problems Rauch's
// durability doc lists, on memory() and local(), against a fake gateway.
//
//   node --experimental-wasm-jspi sdk/tests/test-durable.mjs [memory|local] [native|wasm]
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxEngine, memory } from "../node.js";
import { createFxEngine as createWasmEngine } from "../fx-sdk.js";
import { foldSessionLog } from "../durable.js";
import { holdWrites } from "./hold-writes.mjs";
import { testHooks } from "./hooks-fixture.mjs";

const durabilityKind = process.argv[2] || "memory";
const engineBackend = process.argv[3] || "native";
const childMode = process.argv[4] === "--child";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = engineBackend === "wasm" ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) : undefined;
const { local } = durabilityKind === "memory" ? {} : await import("../durable/local.mjs");
// "vercel": Vercel's World holds the sessions; see vercel-storage.mjs.
const { vercelStorage } = durabilityKind === "vercel" ? await import("./vercel-storage.mjs") : {};
// "world": the app's own World through world(); see app-world.mjs.
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("./app-world.mjs") : {};
// Vercel's World is a round trip away, so its tests wait longer for a
// stream's next chunk, give a function more time, and run longer.
const remote = durabilityKind === "vercel";
const streamQuietMs = remote ? 3000 : 300;
// A remote stream's first chunk waits for its connection as well.
const streamFirstMs = remote ? 15_000 : streamQuietMs;
const timeScale = remote ? 6 : 1;
const testTimeoutMs = remote ? 120_000 : 30_000;
const durabilityAt = async (dir, options = {}) => {
  if (durabilityKind === "vercel") return vercelStorage({ dir, ...options });
  if (durabilityKind === "world") return appWorldAt(dir, options);
  return local({ dir, ...options });
};
// A World that cannot tell whether a lease's holder runs, as Vercel's cannot:
// a worker renews its lease every third of `leaseTestMs`, and its function's
// deadline is ten minutes away.
const leaseTestMs = 2000;
const leasedAt = async (dir) => {
  const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
  const { world } = await import("../durable/world.mjs");
  return world(() => createWorld({ dataDir: dir, recoverActiveRuns: false }), { name: "leased", pollMs: 250, leaseMs: leaseTestMs, maxDurationMs: 600_000 });
};
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const onePixelPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
// The same storage on a queue that outlives the process, as on Vercel: the
// worker that takes a message writes its input, not the sender.
const queueDurableAt = async (dir) => ({ ...(await durabilityAt(dir)), queueDurable: true });
// The steer a crash test's child sends, which asks the model for a lookup.
// The engine adds an image's placeholder to its text, so a word follows the
// tool's name.
const crashSteer = (kind) => (kind === "image"
  ? [{ type: "text", text: "use lookup with this" }, { type: "image", data: onePixelPng, mimeType: "image/png" }]
  : "use lookup");
const resumeNotice = "Resuming from unexpected session interruption.";
// The user message the gateway adds after a tool result's images.
const toolImageFollowUp = "Attached image(s) from the tool result.";

const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const userTexts = (prompt) => prompt.filter((message) => message.role === "user").map(textOf);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const toolCall = (id, name, input) => [{ type: "tool-call", toolCallId: id, toolName: name, input }, finish("tool-calls")];
const answer = (text) => [{ type: "text-delta", id: "answer", delta: text }, finish("stop")];

// The model, by the newest user message of the request, past any resume
// notice: "use <tool>" calls the tool once, then answers with its result;
// "loop" calls lookup three times; "stall" never answers; "slow reply"
// streams its answer a word at a time for a few seconds; "stalled reply"
// sends one word and goes quiet for `stallMs`; "slow tool call" writes a
// lookup call's input a little at a time for a few seconds; anything else is
// echoed.
function framesFor(prompt) {
  const users = userTexts(prompt).filter((text) => text !== resumeNotice && text !== toolImageFollowUp);
  const text = users.at(-1) ?? "";
  const results = toolResults(prompt);
  const turnResults = results.filter((part) => String(part.toolCallId).startsWith(`call-${users.length}-`));
  if (text.startsWith("use ")) {
    const tool = text.slice(4).split(" ")[0];
    if (turnResults.length === 0) return toolCall(`call-${users.length}-0`, tool, { key: "alpha" });
    return answer(`done: ${JSON.stringify(turnResults.at(-1).output)}`);
  }
  if (text === "stall") return null;
  if (text === "slow reply") return slowReply;
  if (text === "stalled reply") return stalledReply;
  if (text === "slow tool call") return slowToolCall;
  if (text === "loop") {
    if (turnResults.length < 3) return toolCall(`call-${users.length}-${turnResults.length}`, "lookup", { key: `k${turnResults.length}` });
    return answer(`looped ${turnResults.length}`);
  }
  return answer(`echo: ${text}`);
}

// A long reply: `slowFrames` words, one every 40 ms. Each request for one
// records how many words it sent.
const slowReply = Symbol("slow reply");
const slowFrames = 75;
const slow = [];
const stalledReply = Symbol("stalled reply");
const slowToolCall = Symbol("slow tool call");
const slowTools = [];
const stallMs = 4000;

const requests = [];
// Each chat request's model and prompt, for the tests of a session's settings.
const chats = [];
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [
        // It takes images, for the steers that carry one.
        { id: "durable/model", type: "language", tags: ["vision", "file-input"] },
        { id: "durable/vision-model", type: "language", tags: ["tool-use", "vision", "file-input"] },
      ] }));
      return;
    }
    const prompt = JSON.parse(body).prompt;
    requests.push(prompt);
    chats.push({ model: request.headers["ai-language-model-id"] ?? null, prompt });
    const frames = framesFor(prompt);
    if (frames === null) return;
    if (frames === stalledReply) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(`data: ${JSON.stringify({ type: "text-delta", id: "answer", delta: "first " })}\n\n`);
      const timer = setTimeout(() => response.end(`data: ${JSON.stringify(finish("stop"))}\n\ndata: [DONE]\n\n`), stallMs);
      response.on("close", () => clearTimeout(timer));
      return;
    }
    if (frames === slowToolCall) {
      const record = { sent: 0 };
      slowTools.push(record);
      response.writeHead(200, { "content-type": "text/event-stream" });
      // Some text first, as a model writes before it calls a tool.
      response.write(`data: ${JSON.stringify({ type: "text-delta", id: "answer", delta: "Looking it up. " })}\n\n`);
      response.write(`data: ${JSON.stringify({ type: "tool-input-start", id: "slow-call", toolName: "lookup" })}\n\n`);
      const timer = setInterval(() => {
        if (record.sent < slowFrames) {
          response.write(`data: ${JSON.stringify({ type: "tool-input-delta", id: "slow-call", delta: record.sent === 0 ? "{\"key\":\"k" : "k" })}\n\n`);
          record.sent += 1;
          return;
        }
        clearInterval(timer);
        const frames = [{ type: "tool-input-delta", id: "slow-call", delta: "\"}" }, { type: "tool-input-end", id: "slow-call" }, ...toolCall("slow-call", "lookup", { key: "k" })];
        response.end(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
      }, 40);
      response.on("close", () => clearInterval(timer));
      return;
    }
    if (frames === slowReply) {
      const record = { sent: 0 };
      slow.push(record);
      response.writeHead(200, { "content-type": "text/event-stream" });
      const timer = setInterval(() => {
        if (record.sent < slowFrames) {
          response.write(`data: ${JSON.stringify({ type: "text-delta", id: "answer", delta: `w${record.sent} ` })}\n\n`);
          record.sent += 1;
          return;
        }
        clearInterval(timer);
        response.end(`data: ${JSON.stringify(finish("stop"))}\n\ndata: [DONE]\n\n`);
      }, 40);
      response.on("close", () => clearInterval(timer));
      return;
    }
    // Each answer takes a moment, as a model's does.
    setTimeout(() => {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
    }, 15);
  });
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const { port } = server.address();
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  if (url.hostname === "ai-gateway.vercel.sh") return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  return fetch(input, init);
};

// Tools. A gate holds a call until the test opens it.
const runs = [];
// The `context` and `sessionId` each lookup call received.
const contexts = [];
const sessionsSeen = [];
const gates = new Map();
const gate = (name) => {
  let open;
  const promise = new Promise((resolveGate) => { open = resolveGate; });
  const entry = { promise, open, started: null };
  entry.started = new Promise((resolveStarted) => { entry.markStarted = resolveStarted; });
  gates.set(name, entry);
  return entry;
};
const lookup = {
  name: "lookup",
  description: "Looks up a key",
  idempotent: true,
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async ({ key }, { executionId, context, sessionId }) => {
    runs.push(["lookup", executionId]);
    contexts.push(context ?? null);
    sessionsSeen.push(sessionId);
    const held = gates.get("lookup");
    if (held) {
      held.markStarted();
      await held.promise;
    }
    return `value of ${key}`;
  },
};
const send = {
  name: "send",
  description: "Sends an invoice",
  idempotent: false,
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async (_input, { executionId }) => {
    runs.push(["send", executionId]);
    const held = gates.get("send");
    if (held) {
      held.markStarted();
      await held.promise;
    }
    return "sent";
  },
};
// An idempotent writer: a service that dedupes on the execution id, so a
// call that runs again under the same id changes nothing twice.
const save = {
  name: "save",
  description: "Saves a key",
  idempotent: true,
  writes: true,
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async (_input, { executionId }) => {
    runs.push(["save", executionId]);
    const held = gates.get("save");
    if (held) {
      held.markStarted();
      await held.promise;
    }
    return "saved";
  },
};

const dirs = [];
async function durabilityFor(options = {}) {
  if (durabilityKind === "memory") return memory(options);
  const dir = options.dir ?? await mkdtemp(join(tmpdir(), "libfx-durable-"));
  dirs.push(dir);
  return durabilityAt(dir, options);
}
// A World durability that records how many events each listing returned.
const listingsOf = (durability) => {
  const listed = [];
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      const events = new Proxy(world.events, {
        get(target, key) {
          if (key !== "list") return bound(target, key);
          return async (...args) => {
            const page = await target.list(...args);
            listed.push(page.data.length);
            return page;
          };
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "events" ? events : bound(target, key)) });
    },
  }, listed];
};

// A memory() durability whose session logs the test can reach into: `hold`
// holds the next log read until `release`, and `onAppend`, `slowReads` and
// `onUiWrite` watch or slow the rest.
const probeLogs = (durability) => {
  const probe = { armed: false, held: null, reached: null, slowReadsMs: 0, onAppend: null, onUiWrite: null };
  probe.hold = () => {
    probe.armed = true;
    let reached;
    probe.reached = new Promise((resolve) => { reached = resolve; });
    probe.held = new Promise((resolve) => { probe.release = resolve; });
    probe.arrive = reached;
  };
  const create = durability.create;
  const wrapped = new WeakMap();
  return [{
    ...durability,
    create() {
      const backend = create();
      if (!wrapped.has(backend)) {
        wrapped.set(backend, {
          ...backend,
          async session(id) {
            const log = await backend.session(id);
            return {
              ...log,
              async read() {
                if (probe.armed) {
                  probe.armed = false;
                  probe.arrive();
                  await probe.held;
                }
                if (probe.slowReadsMs) await new Promise((resolve) => setTimeout(resolve, probe.slowReadsMs));
                return log.read();
              },
              async append(entry) {
                const cursor = await log.append(entry);
                probe.onAppend?.(entry);
                return cursor;
              },
              ui: {
                ...log.ui,
                async write(lines) {
                  probe.onUiWrite?.(lines);
                  return log.ui.write(lines);
                },
              },
            };
          },
        });
      }
      return wrapped.get(backend);
    },
  }, probe];
};

// A World durability whose session streams answer "not found" until their
// first write, as Vercel's World does; `firstWrite` says when that was.
const streamsAppearOnWrite = (durability) => {
  const seen = { firstWrite: null };
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      const streams = new Proxy(world.streams, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key === "write" || key === "writeMulti") {
            return async (...args) => {
              seen.firstWrite ??= Date.now();
              return value.apply(target, args);
            };
          }
          if (key === "get") {
            return async (...args) => {
              if (seen.firstWrite === null) throw Object.assign(new Error("stream not found"), { status: 404 });
              return value.apply(target, args);
            };
          }
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "streams" ? streams : bound(target, key)) });
    },
  }, seen];
};

// A memory() durability whose queue counts as outliving the process.
const queueOutlivesProcess = (durability) => {
  const create = durability.create;
  const wrapped = new WeakMap();
  return {
    ...durability,
    create() {
      const backend = create();
      if (!wrapped.has(backend)) wrapped.set(backend, { ...backend, queueDurable: true });
      return wrapped.get(backend);
    },
  };
};
const agentOptions = (durability, extra = {}) => ({
  ...(testHooks ? { hooks: testHooks } : {}),
  backend: engineBackend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "durable-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "durable/model",
  tools: [lookup, send, save],
  durability,
  ...extra,
});

async function collect(turn) {
  let text = "";
  const types = [];
  for await (const event of turn) {
    types.push(event.type);
    if (event.type === "text_delta") text += event.delta;
  }
  return { text, types, result: await turn.result };
}

// Up to `count` lines, or what arrives before the stream is quiet for
// `quietMs`: a session's stream follows it forever.
async function readLines(stream, count, quietMs = streamQuietMs) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  const lines = [];
  while (lines.length < count) {
    let timer;
    const wait = lines.length === 0 && buffered === "" ? Math.max(quietMs, streamFirstMs) : quietMs;
    const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), wait); });
    const { value, done } = await Promise.race([reader.read(), quiet]);
    clearTimeout(timer);
    if (done) break;
    buffered += decoder.decode(value, { stream: true });
    for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
      lines.push(JSON.parse(buffered.slice(0, index)));
      buffered = buffered.slice(index + 1);
    }
  }
  await reader.cancel();
  return lines.slice(0, count);
}

const until = async (check, what, ms = 10_000) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) throw new Error(`timed out waiting for ${what}`);
    await new Promise((wait) => setTimeout(wait, 10));
  }
};

// A prompt the fake model echoes back, so its turn stores more than 64 KiB
// and its end saves a checkpoint.
const bulky = "x".repeat(40 * 1024);

// A child process for the crash tests. With a tool, it starts a turn whose
// tool never finishes and prints the session id once the tool runs. With
// `accepted`, it dies the moment its prompt is accepted.
if (childMode && process.argv[6] === "accepted") {
  const agent = createFxAgent(agentOptions(await durabilityAt(process.argv[5])));
  const session = agent.session();
  const { sessionId } = await session.prompt("hello").accepted;
  process.stdout.write(`${JSON.stringify({ sessionId })}\n`, () => process.kill(process.pid, "SIGKILL"));
  await new Promise(() => {});
}
// With `steer`, a steer starts the turn instead, on a queue that outlives the
// process, so the turn starts before the steer's input lands.
if (childMode && process.argv[6] === "steer") {
  gate("lookup");
  const agent = createFxAgent(agentOptions(await queueDurableAt(process.argv[5])));
  const session = agent.session();
  await session.steer(crashSteer(process.argv[7]), { messageId: "crash-steer" });
  await gates.get("lookup").started;
  await agent[Symbol.for("libfx.durableInternals")].settled(session.id);
  console.log(JSON.stringify({ sessionId: session.id, executionId: runs.find(([name]) => name === "lookup")?.[1] }));
  await new Promise(() => {});
}
if (childMode) {
  const dir = process.argv[5];
  const tool = process.argv[6];
  gate(tool);
  const agent = createFxAgent(agentOptions(process.argv[7] === "leased" ? await leasedAt(dir) : await durabilityAt(dir)));
  const session = agent.session();
  void session.prompt(`use ${tool}`, { messageId: "crash-turn" }).result.catch(() => {});
  await gates.get(tool).started;
  // A lookup starts before its intent is stored: wait for the intent, so the
  // crash comes after the log holds the call. Any other call starts only
  // after its intent lands, so the crash comes the moment it runs.
  if (tool === "lookup") await agent[Symbol.for("libfx.durableInternals")].settled(session.id);
  console.log(JSON.stringify({ sessionId: session.id, executionId: runs.find(([name]) => name === tool)?.[1] }));
  await new Promise(() => {});
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("a prompt streams its turn, and the session replays from any cursor", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const turn = agent.prompt("hello");
  const { text, result } = await collect(turn);
  assert.equal(text, "echo: hello");
  assert.equal(result.stopReason, "end_turn");
  const accepted = await turn.accepted;
  assert.match(accepted.messageId, /^msg_/);
  assert.equal(accepted.sessionId, agent.sessionId);
  const lines = await readLines(agent.session(agent.sessionId).stream(0), 3);
  assert.deepEqual(lines.map((line) => line.type), ["turn_start", "text_delta", "turn_end"]);
  assert.equal(lines[0].sessionId, agent.sessionId, "a client learns the session from the first line");
  assert.deepEqual(lines.map((line) => line.cursor), [1, 2, 3]);
  const later = await readLines(agent.session(agent.sessionId).stream(2), 1);
  assert.equal(later[0].type, "turn_end");
  await agent.close();
});

test("each session's stream holds only its own turns", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const first = agent.session();
  const second = agent.session();
  await collect(first.prompt("first session"));
  await collect(second.prompt("second session"));
  for (const [session, input] of [[first, "first session"], [second, "second session"]]) {
    const lines = await readLines(session.stream(0), 16);
    const starts = lines.filter((line) => line.type === "turn_start");
    assert.deepEqual(starts.map((line) => line.input), [input], "a stream never shows another session's turn");
    assert.ok(starts.every((line) => line.sessionId === session.id));
  }
  await agent.close();
});

test("a retried prompt with the same messageId runs its turn once", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const first = await collect(session.prompt("only once", { messageId: "same-1" }));
  const before = requests.length;
  const repeat = session.prompt("only once", { messageId: "same-1" });
  const again = await repeat.result;
  const repeatedLines = await readLines(repeat.readable, 1);
  assert.equal(repeatedLines[0].type, "turn_end", "a route returning readable still sends the outcome");
  assert.equal(repeatedLines[0].repeated, true);
  assert.equal(first.result.stopReason, "end_turn");
  assert.equal(again.stopReason, "end_turn");
  assert.equal(again.repeated, true);
  assert.equal(requests.length, before, "the retry sent nothing to the model");
  await agent.close();
});

test("two servers prompting one session run its turns one at a time, in one history", async () => {
  const durability = await durabilityFor();
  const one = createFxAgent(agentOptions(durability));
  const two = createFxAgent(agentOptions(durability));
  const session = one.session();
  await session.prompt("first").result;
  const id = session.id;
  const [a, b] = await Promise.all([
    collect(one.session(id).prompt("from one")),
    collect(two.session(id).prompt("from two")),
  ]);
  assert.equal(a.result.stopReason, "end_turn");
  assert.equal(b.result.stopReason, "end_turn");
  // Both workers may send a model request before either claim lands; only
  // the one whose claim lands runs a turn, so the stream holds each turn
  // whole, one after the other.
  const lines = await readLines(one.session(id).stream(0), 30);
  const order = [];
  for (const line of lines) if (order.at(-1) !== line.messageId) order.push(line.messageId);
  assert.equal(order.length, 3, `each turn's lines are together: ${lines.map((line) => `${line.type}:${line.messageId}`).join(" ")}`);
  const last = requests.at(-1);
  const users = userTexts(last);
  assert.equal(users[0], "first");
  assert.ok(users.includes("from one") && users.includes("from two"), "the later turn saw the earlier one");
  await one.close();
  await two.close();
});

test("a prompt's model request goes out before its claim lands, and nothing shows until it does", async () => {
  const [durability, writes] = holdWrites(await durabilityFor(), (entry) => entry.k === "lease");
  const agent = createFxAgent(agentOptions(durability));
  const before = requests.length;
  const turn = agent.session().prompt("hello");
  const { sessionId } = await turn.accepted;
  await writes.next();
  await until(() => requests.length > before, "the model request while the lease is held");
  // The model answered by now, but its turn has not shown or ended.
  await new Promise((wait) => setTimeout(wait, 100 * timeScale));
  assert.deepEqual(await readLines(agent.session(sessionId).stream(0), 1, 150), [], "nothing shows before the claim lands");
  writes.release();
  const { text, result } = await collect(turn);
  assert.equal(text, "echo: hello");
  assert.equal(result.stopReason, "end_turn");
  assert.equal(requests.length - before, 1, "the turn sent one model request");
  const lines = await readLines(agent.session(sessionId).stream(0), 3);
  assert.deepEqual(lines.map((line) => line.type), ["turn_start", "text_delta", "turn_end"]);
  await agent.close();
});

test("a claim another worker's write came before runs no tool and writes nothing", async () => {
  const shared = await durabilityFor();
  const [held, writes] = holdWrites(shared, (entry) => entry.k === "lease");
  const events = [];
  const first = createFxAgent(agentOptions(held, { onEvent: (event) => events.push(event.type) }));
  const before = runs.length;
  const turn = first.session().prompt("use lookup");
  const { sessionId } = await turn.accepted;
  await writes.next();
  // The model asks for the tool while the first worker's claim is held.
  await new Promise((wait) => setTimeout(wait, 150 * timeScale));
  assert.equal(runs.length, before, "no tool runs before the claim lands");
  // Another worker takes the session and runs the turn.
  const second = createFxAgent(agentOptions(shared));
  const resumed = await collect(second.session(sessionId).resume());
  assert.equal(resumed.result.stopReason, "end_turn");
  assert.equal(runs.length - before, 1);
  // The first claim lands after it and counts for nothing.
  writes.release();
  const { result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn", "the first caller sees the turn the other worker ran");
  // Closing waits for the first worker's delivery to finish.
  await first.close();
  assert.equal(runs.length - before, 1, "the tool ran once");
  assert.ok(!events.includes("session.fenced") && !events.includes("session.error"), `a refused claim is neither fenced nor an error: ${events.join(", ")}`);
  const lines = await readLines(second.session(sessionId).stream(0), 20);
  assert.deepEqual(lines.filter((line) => line.type === "turn_start" || line.type === "turn_end" || line.type === "tool_start").map((line) => line.type), ["turn_start", "tool_start", "turn_end"]);
  await second.close();
});

test("an early claim another worker took over before its check runs no tool and writes nothing", async () => {
  const shared = await durabilityFor();
  const [held, writes] = holdWrites(shared, (entry) => entry.k === "lease", { landFirst: true });
  const events = [];
  const first = createFxAgent(agentOptions(held, { onEvent: (event) => events.push(event.type) }));
  const before = runs.length;
  const turn = first.session().prompt("use lookup");
  const { sessionId } = await turn.accepted;
  // The first worker's lease is in the log, but the worker has not heard so.
  await writes.next();
  // The platform gives up on it, and another worker takes the session over
  // from its lease and runs the turn.
  const holders = globalThis[Symbol.for("libfx.liveHolders")];
  for (const holder of [...holders]) holders.delete(holder);
  const second = createFxAgent(agentOptions(shared));
  const resumed = await collect(second.session(sessionId).resume());
  assert.equal(resumed.result.stopReason, "end_turn");
  assert.equal(runs.length - before, 1);
  // The first worker hears its lease landed, and its check refuses the claim.
  writes.release();
  const { result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn", "the first caller sees the turn the other worker ran");
  await first.close();
  assert.equal(runs.length - before, 1, "the tool ran once");
  assert.ok(!events.includes("session.fenced") && !events.includes("session.error"), `a refused claim is neither fenced nor an error: ${events.join(", ")}`);
  const lines = await readLines(second.session(sessionId).stream(0), 20);
  assert.deepEqual(lines.filter((line) => line.type === "turn_start" || line.type === "turn_end" || line.type === "tool_start").map((line) => line.type), ["turn_start", "tool_start", "turn_end"]);
  await second.close();
});

if (durabilityKind === "memory") {
  test("an early claim whose log hid a competing claim runs no tool and writes nothing", async () => {
    const shared = await durabilityFor();
    const [held, writes] = holdWrites(shared, (entry) => entry.k === "lease", { unreported: true });
    const events = [];
    const first = createFxAgent(agentOptions(held, { onEvent: (event) => events.push(event.type) }));
    const before = runs.length;
    const turn = first.session().prompt("use lookup");
    const { sessionId } = await turn.accepted;
    await writes.next();
    const second = createFxAgent(agentOptions(shared));
    const resumed = await collect(second.session(sessionId).resume());
    assert.equal(resumed.result.stopReason, "end_turn");
    // The chain refuses the first claim, but its log reports it landed.
    writes.release();
    const { result } = await collect(turn);
    assert.equal(result.stopReason, "end_turn", "the first caller sees the turn the other worker ran");
    await first.close();
    assert.equal(runs.length - before, 1, "the tool ran once");
    assert.ok(!events.includes("session.fenced") && !events.includes("session.error"), `a refused claim is neither fenced nor an error: ${events.join(", ")}`);
    await second.close();
  });

  // Every sender stores its input before it queues the message, whatever
  // the queue, so it refuses a steer that reuses a prompt's id itself.
  test("on a queue that outlives the process, a steer reusing a prompt's id is refused and runs nothing", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor())));
    const session = agent.session();
    assert.equal((await session.prompt("hello there", { messageId: "m-dup" }).result).stopReason, "end_turn");
    await assert.rejects(session.steer("again", { messageId: "m-dup" }), (error) => error?.code === "FX_MESSAGE_ID_IN_USE");
    const lines = await readLines(session.stream(0), 64);
    assert.equal(lines.filter((line) => line.type === "turn_start").length, 1, "the steer ran no turn");
    await agent.close();
  });

  // On a queue that outlives the process, the worker writes a message's input
  // with its claim and starts the turn before either lands, so the input
  // reaches the log after the point the turn reads steers from.
  test("on a queue that outlives the process, a steer with an image that starts a turn runs it once, with the image", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor())));
    const session = agent.session();
    const before = requests.length;
    await session.steer([{ type: "text", text: "match this first" }, { type: "image", data: onePixelPng, mimeType: "image/png" }], { messageId: "m-image-first" });
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-image-first", "the image's turn");
    const end = lines.find((line) => line.type === "turn_end" && line.messageId === "m-image-first");
    assert.equal(end.stopReason, "end_turn", `the image's turn ended with ${JSON.stringify(end).slice(0, 300)}`);
    assert.equal(lines.filter((line) => line.type === "turn_start").length, 1, "the steer ran one turn");
    assert.equal(requests.length - before, 1, "the turn sent one model request");
    assert.ok(JSON.stringify(requests.at(-1)).includes("image"), "the request carried the image");
    await agent.close();
  });

  test("on a queue that outlives the process, a text steer that starts a turn reaches the model once", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor())));
    const session = agent.session();
    const before = requests.length;
    await session.steer("guide me first", { messageId: "m-text-first" });
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-text-first", "the steer's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-text-first").stopReason, "end_turn");
    // A turn after it, so a second request for the reapplied steer would have gone out by now.
    assert.equal((await session.prompt("after the guide").result).stopReason, "end_turn");
    const forSteer = requests.slice(before).filter((prompt) => !userTexts(prompt).includes("after the guide"));
    assert.equal(forSteer.length, 1, "the steer's turn sent one model request");
    assert.equal(userTexts(forSteer[0]).filter((text) => text.includes("guide me first")).length, 1, "the steer reached the model once");
    await agent.close();
  });

  test("on a queue that outlives the process, a turn a steer started still takes the steers after it", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor())));
    const session = agent.session();
    let before = slow.length;
    await session.steer("slow reply", { messageId: "m-slow-text" });
    await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
    await session.steer("be brief", { messageId: "m-brief-second" });
    let lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-slow-text", "the steer's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-slow-text").stopReason, "end_turn");
    assert.deepEqual(lines.filter((line) => line.type === "turn_start").map((line) => line.messageId), ["m-slow-text"], "the text steer joined the turn");
    const texts = userTexts(requests.at(-1));
    assert.equal(texts.filter((text) => text.includes("slow reply")).length, 1, "the steer that started the turn reached the model once");
    assert.equal(texts.filter((text) => text.includes("be brief")).length, 1, "the steer after it joined the turn once");
    // One with an image still ends the turn and runs as its own.
    before = slow.length;
    await session.steer("slow reply", { messageId: "m-slow-image" });
    await until(() => slow.length > before && slow.at(-1).sent > 0, "the second reply to stream");
    await session.steer([{ type: "text", text: "match this next" }, { type: "image", data: onePixelPng, mimeType: "image/png" }], { messageId: "m-image-second" });
    lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-image-second", "the image's turn");
    assert.deepEqual(lines.filter((line) => line.type === "turn_start").map((line) => line.messageId), ["m-slow-text", "m-slow-image", "m-image-second"]);
    assert.ok(slow.at(-1).sent < slowFrames, "the image ended the streaming turn early");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-image-second").stopReason, "end_turn");
    assert.ok(JSON.stringify(requests.at(-1)).includes("image"), "the image reached the model in its own turn");
    await agent.close();
  });

  // A redelivery names the input its sender stored and carries none, so the
  // steer is in the log once however often it is delivered.
  test("on a queue that outlives the process, a steer that starts a turn and is delivered again runs once", async () => {
    const [held, writes] = holdWrites(queueOutlivesProcess(await durabilityFor()), (entry) => entry.k === "lease");
    const agent = createFxAgent(agentOptions(held));
    const session = agent.session();
    const before = requests.length;
    await session.steer("guide me again", { messageId: "m-redelivered" });
    await writes.next();
    void agent[Symbol.for("libfx.durableInternals")].deliver({ type: "steer", messageId: "m-redelivered", input: "a body the worker ignores", agent: "default", sessionId: session.id });
    await writes.release();
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-redelivered", "the steer's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-redelivered").stopReason, "end_turn");
    assert.equal((await session.prompt("after the redelivery").result).stopReason, "end_turn");
    const all = await readLines(session.stream(0), 64);
    assert.equal(all.filter((line) => line.type === "turn_start" && line.messageId === "m-redelivered").length, 1, "the steer ran one turn");
    const forSteer = requests.slice(before).filter((prompt) => !userTexts(prompt).includes("after the redelivery"));
    assert.equal(forSteer.length, 1, "the steer's turn sent one model request");
    assert.equal(userTexts(forSteer[0]).filter((text) => text === "guide me again").length, 1, "the steer reached the model once");
    await agent.close();
  });

  test("on a queue that outlives the process, a cancel still ends a turn a steer started", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor())));
    const session = agent.session();
    const before = slow.length;
    await session.steer("slow reply", { messageId: "m-slow-cancel" });
    await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
    await session.cancel();
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-slow-cancel", "the steer's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-slow-cancel").stopReason, "cancelled");
    assert.ok(slow.at(-1).sent < slowFrames, "the cancel ended the streaming reply early");
    assert.equal((await session.prompt("after the cancel").result).stopReason, "end_turn");
    const all = await readLines(session.stream(0), 256);
    assert.equal(all.filter((line) => line.type === "turn_start" && line.messageId === "m-slow-cancel").length, 1, "the cancelled steer did not run again");
    await agent.close();
  });

  // A session cancel stops the turn running when it lands. One that finds a
  // prompt waiting with no worker starts that prompt, and on a queue that
  // outlives the process it does so before its own input lands; the prompt
  // still runs, as it does when the sender stores the cancel first.
  for (const [where, wrap] of [["on a queue that outlives the process", queueOutlivesProcess], ["when its sender stores it", (durability) => durability]]) {
    test(`${where}, a session cancel that finds a prompt waiting to start leaves it to run`, async () => {
      const agent = createFxAgent(agentOptions(wrap(await durabilityFor())));
      const session = agent.session();
      assert.equal((await session.prompt("hello there").result).stopReason, "end_turn");
      const internals = agent[Symbol.for("libfx.durableInternals")];
      // A worker still running would take the next prompt itself.
      await until(() => internals.liveWorkers() === 0, "the first worker to let the session go");
      // A prompt waits in the log with no worker, as one whose delivery has
      // not come yet does.
      const log = await internals.openLog(session.id);
      await log.append({ k: "input", key: "prompt:m-waiting", type: "prompt", messageId: "m-waiting", agent: "default", input: "the waiting prompt" });
      const before = requests.length;
      await session.cancel();
      const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-waiting", "the waiting prompt's turn");
      assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-waiting").stopReason, "end_turn", "the cancel landed before the turn started");
      assert.ok(requests.slice(before).some((prompt) => userTexts(prompt).includes("the waiting prompt")), "the prompt reached the model");
      await agent.close();
    });
  }

  // One id names one input. Two senders racing the id check can store a
  // steer under a waiting prompt's id; the log takes the id as the prompt's,
  // so the steer never runs.
  test("a steer stored under a waiting prompt's id never reaches the model", async () => {
    const agent = createFxAgent(agentOptions(await durabilityFor()));
    const session = agent.session();
    assert.equal((await session.prompt("hello there").result).stopReason, "end_turn");
    const internals = agent[Symbol.for("libfx.durableInternals")];
    await until(() => internals.liveWorkers() === 0, "the first worker to let the session go");
    const log = await internals.openLog(session.id);
    await log.append({ k: "input", key: "prompt:m-shared", type: "prompt", messageId: "m-shared", agent: "default", input: "the shared prompt" });
    await log.append({ k: "input", key: "steer:m-shared", type: "steer", messageId: "m-shared", agent: "default", input: "the steer that reused its id" });
    const before = requests.length;
    // The prompt's delivery comes.
    await internals.deliver({ type: "prompt", messageId: "m-shared", input: "the shared prompt", agent: "default", sessionId: session.id });
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-shared", "the prompt's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-shared").stopReason, "end_turn");
    const sent = requests.slice(before);
    assert.ok(sent.some((prompt) => userTexts(prompt).includes("the shared prompt")), "the prompt reached the model");
    assert.ok(!sent.some((prompt) => JSON.stringify(prompt).includes("the steer that reused its id")), "the steer never did");
    await agent.close();
  });

  // A text steer joins the latest prompt waiting to start. One whose own
  // delivery starts the first of two waiting prompts, on a queue that
  // outlives the process, still leaves that prompt to finish and joins the
  // second, as it does when the sender stores it first.
  for (const [where, wrap] of [["on a queue that outlives the process", queueOutlivesProcess], ["when its sender stores it", (durability) => durability]]) {
    test(`${where}, a steer that finds two prompts waiting joins the second and leaves the first to finish`, async () => {
      const agent = createFxAgent(agentOptions(wrap(await durabilityFor())));
      const session = agent.session();
      assert.equal((await session.prompt("hello there").result).stopReason, "end_turn");
      const internals = agent[Symbol.for("libfx.durableInternals")];
      await until(() => internals.liveWorkers() === 0, "the first worker to let the session go");
      const log = await internals.openLog(session.id);
      await log.append({ k: "input", key: "prompt:m-first-waiting", type: "prompt", messageId: "m-first-waiting", agent: "default", input: "slow reply" });
      await log.append({ k: "input", key: "prompt:m-second-waiting", type: "prompt", messageId: "m-second-waiting", agent: "default", input: "the second prompt" });
      const slowBefore = slow.length;
      const before = requests.length;
      await session.steer("and keep it short", { messageId: "m-late-steer" });
      const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-second-waiting", "the second prompt's turn");
      assert.deepEqual(lines.filter((line) => line.type === "turn_start").slice(1).map((line) => line.messageId), ["m-first-waiting", "m-second-waiting"], "the steer ran no turn of its own");
      assert.deepEqual(lines.filter((line) => line.type === "turn_end").slice(1).map((line) => [line.messageId, line.stopReason]), [["m-first-waiting", "end_turn"], ["m-second-waiting", "end_turn"]]);
      assert.deepEqual(slow.slice(slowBefore).map((record) => record.sent), [slowFrames], "the first prompt's reply streamed to the end");
      const withSteer = requests.slice(before).filter((prompt) => userTexts(prompt).some((text) => text.includes("and keep it short")));
      assert.ok(withSteer.length > 0, "the steer reached the model");
      assert.ok(withSteer.every((prompt) => userTexts(prompt).includes("the second prompt")), "the steer reached only the second prompt's turn");
      await agent.close();
    });
  }

  test("on a queue that outlives the process, a turn a steer started that the deadline cuts off continues once in the next delivery", async () => {
    const agent = createFxAgent(agentOptions(queueOutlivesProcess(await durabilityFor({ maxDurationMs: 1500 * timeScale, reserveMs: 1000 * timeScale }))));
    const held = gate("lookup");
    const session = agent.session();
    await session.steer("use lookup", { messageId: "m-lookup-first" });
    await held.started;
    // The call never returns on its own; a rerun goes through at once.
    gates.delete("lookup");
    const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-lookup-first", "the steer's turn");
    assert.equal(lines.find((line) => line.type === "turn_end" && line.messageId === "m-lookup-first").stopReason, "end_turn");
    assert.equal(lines.filter((line) => line.type === "turn_start").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_yield").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_resume").length, 1);
    assert.equal(userTexts(requests.at(-1)).filter((text) => text === "use lookup").length, 1, "the steer reached the model once");
    await agent.close();
  });

  // With a queue that outlives the process, as on Vercel, a prompt's input
  // still reaches the log before its message is queued, so no delivery can
  // run ahead of it, and its caller hears it was accepted only once stored.
  test("on a queue that outlives the process, a prompt is accepted and queued only once its input is stored", async () => {
    const [held, writes] = holdWrites(queueOutlivesProcess(await durabilityFor()), (entry) => entry.k === "input");
    const agent = createFxAgent(agentOptions(held));
    const before = requests.length;
    const turn = agent.session().prompt("one");
    let accepted = false;
    void turn.accepted.then(() => { accepted = true; });
    await writes.next();
    await new Promise((resolve) => setTimeout(resolve, 200 * timeScale));
    assert.equal(accepted, false, "not accepted while its input is held");
    assert.equal(requests.length, before, "nothing ran while its input is held");
    writes.release();
    let timer;
    const stranded = new Promise((_, fail) => { timer = setTimeout(() => fail(new Error("the prompt never ran")), 10_000 * timeScale); });
    const ran = await Promise.race([collect(turn), stranded]).finally(() => clearTimeout(timer));
    assert.equal(ran.text, "echo: one");
    await agent.close();
  });
}

if (durabilityKind !== "memory") {
  test("a session's log reads stop at its newest checkpoint, so they stay one small page however long its history grows", async () => {
    const [durability, listed] = listingsOf(await durabilityFor());
    let saves = 0;
    const agent = createFxAgent(agentOptions(durability, { onEvent: (event) => { if (event.type === "checkpoint.save") saves += 1; } }));
    const session = agent.session();
    for (let turn = 0; turn < 8; turn += 1) assert.equal((await session.prompt(`turn ${turn}`).result).stopReason, "end_turn");
    // Short turns save no checkpoint; one that stores more than 64 KiB does.
    assert.equal((await session.prompt(bulky).result).stopReason, "end_turn");
    await until(() => saves === 1, "the checkpoint after 64 KiB");
    listed.length = 0;
    const { text } = await collect(session.prompt("one more"));
    assert.equal(text, "echo: one more");
    assert.ok(listed.length > 0, "the turn read its log");
    assert.ok(Math.max(...listed) <= 10, `each read stopped at the newest checkpoint within one page, before the turns under it: ${listed.join(", ")}`);
    await agent.close();
  });
}

if (durabilityKind === "memory") {
  test("a prompt with a messageId is accepted after its one send, and its first run is no repeat", async () => {
    const [durability, probe] = probeLogs(await durabilityFor());
    const agent = createFxAgent(agentOptions(durability));
    const session = agent.session();
    assert.equal((await session.prompt("before").result).stopReason, "end_turn");
    // The route's check of the log is held; the prompt is accepted anyway.
    probe.hold();
    const turn = session.prompt("first try", { messageId: "first-try" });
    await probe.reached;
    await Promise.race([
      turn.accepted,
      new Promise((_, fail) => setTimeout(() => fail(new Error("accepted waited for the log check")), 2000 * timeScale)),
    ]);
    // The turn runs to its end while the check is held, so the check finds
    // it already ended.
    await until(async () => (await readLines(session.stream(0), 64, 100)).some((line) => line.type === "turn_end" && line.messageId === "first-try"), "the turn's end");
    probe.release();
    const { text, result } = await collect(turn);
    assert.equal(text, "echo: first try");
    assert.equal(result.stopReason, "end_turn");
    assert.notEqual(result.repeated, true, "a message's first run is no repeat");
    // A real retry still answers from the turn that ran.
    const again = await session.prompt("first try", { messageId: "first-try" }).result;
    assert.equal(again.repeated, true);
    await agent.close();
  });

  test("a turn's end shows once its records land, before the worker reads the log again", async () => {
    const [durability, probe] = probeLogs(await durabilityFor());
    let endRecord = null;
    let endLine = null;
    probe.onAppend = (entry) => {
      if (entry.k === "record" && (entry.marks ?? []).some((mark) => mark.end === true) && endRecord === null) {
        endRecord = Date.now();
        probe.slowReadsMs = 400;
      }
    };
    probe.onUiWrite = (lines) => {
      if (endLine === null && lines.some((line) => JSON.parse(line).type === "turn_end")) endLine = Date.now();
    };
    const agent = createFxAgent(agentOptions(durability));
    const { text } = await collect(agent.session().prompt("hello"));
    assert.equal(text, "echo: hello");
    assert.ok(endRecord !== null && endLine !== null, "the turn stored its end and showed it");
    assert.ok(endLine - endRecord < 200, `the end showed ${endLine - endRecord} ms after its record landed`);
    probe.slowReadsMs = 0;
    await agent.close();
  });
}

if (durabilityKind !== "memory") {
  test("a new session's first line reaches its viewer moments after it is written", async () => {
    const [appearing, seen] = streamsAppearOnWrite(await durabilityFor());
    const [durability, writes] = holdWrites(appearing, (entry) => entry.k === "lease");
    const agent = createFxAgent(agentOptions(durability));
    const turn = agent.session().prompt("hello");
    await writes.next();
    // The viewer has looked for the session's stream for a while before
    // the claim lands and the first line is written.
    await new Promise((wait) => setTimeout(wait, 900 * timeScale));
    writes.release();
    let firstSeen = null;
    for await (const _event of turn) firstSeen ??= Date.now();
    assert.ok(seen.firstWrite !== null && firstSeen !== null);
    assert.ok(firstSeen - seen.firstWrite < 250 * timeScale, `the first line arrived ${firstSeen - seen.firstWrite} ms after it was written`);
    await agent.close();
  });
}

test("a steer reaches the running turn at its next model request", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const held = gate("lookup");
  const session = agent.session();
  const turn = session.prompt("use lookup please");
  await held.started;
  await session.steer("also mention the color blue");
  // The worker takes it from the log while the tool runs.
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  held.open();
  gates.delete("lookup");
  const { result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn");
  assert.ok(JSON.stringify(requests.at(-1)).includes("also mention the color blue"), "the next request carried the steer");
  await agent.close();
});

// The session's lines from the start until `done` holds for one of them.
async function linesUntil(session, done, label, ms = 15_000 * timeScale) {
  const reader = session.stream(0).getReader();
  const decoder = new TextDecoder();
  const lines = [];
  let buffered = "";
  let timer;
  const timeout = new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms); });
  try {
    while (!lines.some(done)) {
      const { value, done: ended } = await Promise.race([reader.read(), timeout]);
      if (ended) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
  } finally {
    clearTimeout(timer);
    await reader.cancel().catch(() => {});
  }
  return lines;
}

test("a steer cuts a streaming reply short, and the turn goes on with it", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const before = slow.length;
  const turn = session.prompt("slow reply");
  const { messageId } = await turn.accepted;
  // Steer once the reply has reached the turn's viewer.
  const events = turn[Symbol.asyncIterator]();
  for (let next = await events.next(); !next.done && next.value.type !== "text_delta"; next = await events.next());
  assert.deepEqual(await session.steer("be brief", { messageId: "m-brief" }), { messageId: "m-brief" });
  for (let next = await events.next(); !next.done; next = await events.next());
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  // Counted by the model server, so a remote World's latency cannot hide a
  // reply that ran to its end.
  assert.ok(slow[before].sent < slowFrames, `the reply sent ${slow[before].sent} of ${slowFrames} words, not cut short`);
  const last = requests.at(-1);
  assert.ok(userTexts(last).some((text) => text.includes("be brief")), "the next request carried the steer");
  assert.ok(JSON.stringify(last).includes("w0"), "the reply so far stays in the turn");
  assert.ok(!JSON.stringify(last).includes(`w${slowFrames - 1}`), "the rest of the reply was cut short");
  const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === messageId, "the turn's end");
  assert.deepEqual(lines.filter((line) => line.type === "turn_start").map((line) => line.messageId), [messageId], "the steer joined the turn");
  const joined = lines.filter((line) => line.type === "user_message");
  assert.deepEqual(joined.map((line) => [line.id, line.messageId]), [["m-brief", messageId]], "the stream shows where the steer joined, by its id");
  await agent.close();
});

test("a steer cuts short a reply that has gone quiet", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const turn = session.prompt("stalled reply");
  const events = turn[Symbol.asyncIterator]();
  for (let next = await events.next(); !next.done && next.value.type !== "text_delta"; next = await events.next());
  const steeredAt = Date.now();
  await session.steer("go on without it", { messageId: "m-quiet" });
  for (let next = await events.next(); !next.done; next = await events.next());
  assert.equal((await turn.result).stopReason, "end_turn");
  const waited = Date.now() - steeredAt;
  assert.ok(waited < stallMs / 2, `the turn ended ${waited} ms after the steer, not after the model's next byte`);
  assert.ok(userTexts(requests.at(-1)).some((text) => text.includes("go on without it")), "the next request carried the steer");
  await agent.close();
});

test("a steer with an image ends the streaming turn, and runs as the next turn", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const before = slow.length;
  const turn = session.prompt("slow reply");
  const { messageId } = await turn.accepted;
  await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
  await session.steer([{ type: "text", text: "match this" }, { type: "image", data: onePixelPng, mimeType: "image/png" }], { messageId: "m-image" });
  await session.steer("and keep it small", { messageId: "m-after-image" });
  const first = await turn.result;
  assert.notEqual(first.stopReason, "end_turn", "the running turn did not finish its reply");
  assert.ok(slow[before].sent < slowFrames, `the running reply sent ${slow[before].sent} of ${slowFrames} words, not cut short`);
  const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-image", "the image's turn");
  assert.deepEqual(lines.filter((line) => line.type === "turn_start").map((line) => line.messageId), [messageId, "m-image"]);
  const imageRequest = requests.findLast((prompt) => userTexts(prompt).some((text) => text.includes("match this")));
  assert.ok(imageRequest && JSON.stringify(imageRequest).includes("image"), `the image reached the model in its own turn: ${JSON.stringify(requests.slice(-2).map((prompt) => prompt.filter((message) => message.role === "user")))}`.slice(0, 1500));
  assert.ok(JSON.stringify(requests.at(-1)).includes("and keep it small"), "the steer after the image joined its turn");
  await agent.close();
});

// Text over the engine's 64 KiB steering limit, which the durable 8 MiB
// input limit still takes.
const longSteer = (name) => `${name}: ${"x".repeat(64 * 1024)}`;

test("a steer over 64 KiB of text ends the streaming turn, and runs as the next turn", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const before = slow.length;
  const turn = session.prompt("slow reply");
  const { messageId } = await turn.accepted;
  await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
  await session.steer(longSteer("long"), { messageId: "m-long" });
  await session.steer("and keep it small", { messageId: "m-after-long" });
  const first = await turn.result;
  assert.notEqual(first.stopReason, "end_turn", "the running turn did not finish its reply");
  assert.ok(slow[before].sent < slowFrames, `the running reply sent ${slow[before].sent} of ${slowFrames} words, not cut short`);
  const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-long", "the long steer's turn");
  assert.deepEqual(lines.filter((line) => line.type === "turn_start").map((line) => line.messageId), [messageId, "m-long"]);
  const last = userTexts(requests.at(-1));
  assert.equal(last.filter((text) => text.startsWith("long: ")).length, 1, "the long steer reached the model once");
  assert.ok(last.some((text) => text.includes("and keep it small")), "the steer after it joined its turn");
  await agent.close();
});

test("two steers over 64 KiB of text sent together each run as a turn, and the session goes on", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const before = slow.length;
  const turn = session.prompt("slow reply");
  const { messageId } = await turn.accepted;
  await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
  // The first opens a turn of its own and the second joins it there, where
  // the engine refuses it as it starts.
  await Promise.all([
    session.steer(longSteer("first"), { messageId: "m-long-1" }),
    session.steer(longSteer("second"), { messageId: "m-long-2" }),
  ]);
  await turn.result;
  const ended = (id) => (line) => line.type === "turn_end" && line.messageId === id;
  const lines = await linesUntil(session, (line) => ended("m-long-1")(line) || ended("m-long-2")(line), "a long steer's turn");
  const all = lines.some(ended("m-long-1")) && lines.some(ended("m-long-2"))
    ? lines
    : await linesUntil(session, (line) => ended(lines.some(ended("m-long-1")) ? "m-long-2" : "m-long-1")(line), "the other long steer's turn");
  const starts = all.filter((line) => line.type === "turn_start").map((line) => line.messageId);
  assert.equal(starts[0], messageId);
  assert.deepEqual(starts.slice(1).sort(), ["m-long-1", "m-long-2"], "each long steer ran as a turn of its own");
  const { result } = await collect(session.prompt("still there?"));
  assert.equal(result.stopReason, "end_turn", "the session takes prompts after them");
  const last = userTexts(requests.at(-1));
  for (const name of ["first", "second"]) {
    assert.equal(last.filter((text) => text.startsWith(`${name}: `)).length, 1, `the ${name} long steer reached the model once`);
  }
  await agent.close();
});

test("a cancel keeps the steer its turn never took, and it runs next", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const held = gate("lookup");
  const session = agent.session();
  const turn = session.prompt("use lookup before the stop");
  await held.started;
  await session.steer("after the stop", { messageId: "m-after-stop" });
  // The worker gives it to the running turn, which waits for the tool.
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  await session.cancel();
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  held.open();
  gates.delete("lookup");
  assert.equal((await turn.result).stopReason, "cancelled");
  await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-after-stop", "the steer's own turn");
  assert.ok(userTexts(requests.at(-1)).some((text) => text.includes("after the stop")), "the steer ran as the next turn");
  await agent.close();
});

// The cancel ends the step before its call runs, so the turn's progress is
// cleared before the turn ends: the steer is withdrawn ahead of that, while it
// still belongs to the turn, or the session's journal no longer opens.
test("a cancel while the model writes a tool call keeps the steer waiting for the call, and it runs next", async () => {
  const shared = await durabilityFor();
  const agent = createFxAgent(agentOptions(shared));
  const session = agent.session();
  const before = slowTools.length;
  const turn = session.prompt("slow tool call");
  const { sessionId } = await turn.accepted;
  await until(() => slowTools.length > before && slowTools.at(-1).sent > 3, "the tool call's input");
  await session.steer("after the cancel", { messageId: "m-after-cancel" });
  // The worker gives it to the running turn, which waits for the call.
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  await session.cancel();
  assert.equal((await turn.result).stopReason, "cancelled");
  const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-after-cancel", "the steer's own turn");
  const end = lines.find((line) => line.type === "turn_end" && line.messageId === "m-after-cancel");
  assert.equal(end.stopReason, "end_turn", `the steer's turn ended with ${JSON.stringify(end).slice(0, 300)}`);
  assert.ok(userTexts(requests.at(-1)).some((text) => text.includes("after the cancel")), "the steer ran as the next turn");
  await agent.close();
  // Another worker opens the session from its log.
  const second = createFxAgent(agentOptions(shared));
  const again = await second.session(sessionId).prompt("after the reload").result;
  assert.equal(again.stopReason, "end_turn", `the reopened session ended its turn with ${JSON.stringify(again).slice(0, 300)}`);
  await second.close();
});

test("a steer's messageId makes a retry add nothing, and names no prompt", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  assert.equal((await session.prompt("hello there", { messageId: "m-hello" }).result).stopReason, "end_turn");
  await assert.rejects(session.steer("again", { messageId: "m-hello" }), (error) => error?.code === "FX_MESSAGE_ID_IN_USE");
  await assert.rejects(session.steer("bad", { messageId: "no spaces" }), TypeError);
  await session.steer("guide me", { messageId: "m-guide" });
  await session.steer("guide me", { messageId: "m-guide" });
  await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-guide", "the steer's turn");
  // A turn after it, so a second turn for the retry would have run by now.
  assert.equal((await session.prompt("after the guide").result).stopReason, "end_turn");
  const all = await readLines(session.stream(0), 64);
  assert.equal(all.filter((line) => line.type === "turn_start" && line.messageId === "m-guide").length, 1, "the retried steer ran once");
  assert.equal(all.filter((line) => line.type === "turn_start" && line.messageId === "m-hello").length, 1);
  await agent.close();
});

test("steers stored while a prompt waits join its turn; one with an image ends it and waits for its own", () => {
  const log = [
    { cursor: "1", entry: { k: "lease", a: null, holder: "w1", epoch: 1, expiresAt: null } },
    { cursor: "2", entry: { k: "input", key: "prompt:p1", type: "prompt", messageId: "p1", input: "first" } },
    { cursor: "3", entry: { k: "input", key: "steer:s1", type: "steer", messageId: "s1", input: "also" } },
    { cursor: "4", entry: { k: "input", key: "steer:s2", type: "steer", messageId: "s2", input: [{ type: "text", text: "look" }, { type: "image", data: "AA==", mimeType: "image/png" }] } },
    { cursor: "5", entry: { k: "input", key: "steer:s3", type: "steer", messageId: "s3", input: [{ type: "text", text: "and this" }] } },
  ];
  const waiting = foldSessionLog(log);
  assert.deepEqual(waiting.pending.map((input) => [input.messageId, input.joiners.map((joiner) => joiner.messageId), input.ends]), [["p1", ["s1"], true], ["s2", ["s3"], false]]);
  // Started, the turn has the same steers and still ends for the image.
  const started = foldSessionLog([...log, { cursor: "6", entry: { k: "record", a: "1", key: "r1", data: "AA==", marks: [{ start: "p1" }] } }]);
  assert.equal(started.openTurn.id, "p1");
  assert.deepEqual(started.steers.map((input) => input.messageId), ["s1"]);
  assert.equal(started.endOpen, true);
  assert.deepEqual(started.pending.map((input) => [input.messageId, input.joiners.map((joiner) => joiner.messageId)]), [["s2", ["s3"]]]);
});

test("a checkpoint keeps a steer the open turn holds unplaced, and a withdrawal hands it back", () => {
  const log = [
    { cursor: "1", entry: { k: "lease", a: null, holder: "w1", epoch: 1, expiresAt: null } },
    { cursor: "2", entry: { k: "input", key: "prompt:p1", type: "prompt", messageId: "p1", input: "first" } },
    { cursor: "3", entry: { k: "record", a: "1", key: "r1", data: "AA==", marks: [{ start: "p1" }] } },
    { cursor: "4", entry: { k: "input", key: "steer:s1", type: "steer", messageId: "s1", input: "also" } },
    { cursor: "5", entry: { k: "record", a: "3", key: "r2", data: "AA==", marks: [{ accepted: "s1" }, { yield: true }] } },
  ];
  const before = foldSessionLog(log);
  assert.deepEqual(before.steers, [], "the turn took the steer");
  assert.deepEqual(before.heldIds, ["s1"]);
  const kept = [...before.unconsumed, ...before.held].filter((input) => input.cursor <= 5);
  const checkpoint = { k: "checkpoint", through: "5", data: "AA==", pending: kept, held: before.heldIds, recent: before.recent, recentSteers: before.recentSteers, lastTurnId: before.lastTurnId, openTurn: before.openTurn, yielded: before.yielded, lease: before.lastLease };
  const after = foldSessionLog([{ cursor: "6", entry: checkpoint }]);
  assert.deepEqual(after.steers, [], "the held steer is not applied twice");
  assert.deepEqual(after.pending, []);
  // The checkpoint still knows which taken ids were prompts and which steers.
  assert.equal(after.consumedKind("p1"), "prompt");
  assert.equal(after.consumedKind("s1"), "steer");
  assert.equal(foldSessionLog([{ cursor: "6", entry: { ...checkpoint, recentSteers: undefined } }]).consumedKind("p1"), null, "an older checkpoint does not say");
  // The turn ends without placing it: the steer runs next, from the checkpoint's copy.
  const ended = foldSessionLog([
    { cursor: "6", entry: checkpoint },
    { cursor: "7", entry: { k: "record", a: "5", key: "r3", data: "AA==", marks: [{ withdrawn: "s1" }, { end: true }] } },
  ]);
  assert.deepEqual(ended.pending.map((input) => [input.messageId, input.input]), [["s1", "also"]]);
  // Placed instead, it ends with the turn.
  const placed = foldSessionLog([
    { cursor: "6", entry: checkpoint },
    { cursor: "7", entry: { k: "record", a: "5", key: "r3", data: "AA==", marks: [{ placed: "s1" }, { end: true }] } },
  ]);
  assert.deepEqual(placed.pending, []);
  assert.deepEqual(placed.heldIds, []);
});

test("cancel stops the running turn; dropping its view does not", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const held = gate("lookup");
  const session = agent.session();
  const dropped = session.prompt("use lookup for dropping");
  for await (const _event of dropped) break;
  await held.started;
  const turn = session.prompt("after the dropped one");
  await new Promise((wait) => setTimeout(wait, 30));
  assert.equal(gates.get("lookup"), held, "the dropped turn still runs");
  await session.cancel();
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  held.open();
  gates.delete("lookup");
  assert.equal((await dropped.result).stopReason, "cancelled");
  assert.equal((await turn.result).stopReason, "end_turn");
  await agent.close();
});

test("a turn's end saves a checkpoint once the records since the last reach 64 KiB, and the next turn starts from it", async () => {
  const saves = [];
  const opens = [];
  const agent = createFxAgent(agentOptions(await durabilityFor(), {
    onEvent: (event) => {
      if (event.type === "checkpoint.save") saves.push(event);
      else if (event.type === "journal.open") opens.push(event);
    },
  }));
  const session = agent.session();
  for (const text of ["use lookup", "hello again"]) assert.equal((await collect(session.prompt(text))).result.stopReason, "end_turn");
  assert.equal(saves.length, 0, `short turns save no checkpoint: ${JSON.stringify(saves)}`);
  const short = opens.filter((open) => open.turns > 0);
  assert.ok(short.length >= 1 && short.every((open) => !open.checkpoint && open.events > 0), JSON.stringify(opens));
  // The save follows the turn's end.
  assert.equal((await collect(session.prompt(bulky))).result.stopReason, "end_turn");
  await until(() => saves.length > 0, "the checkpoint after 64 KiB");
  assert.equal(saves.length, 1, `the turn that crossed 64 KiB saved one: ${JSON.stringify(saves)}`);
  opens.length = 0;
  assert.equal((await collect(session.prompt("after the checkpoint"))).result.stopReason, "end_turn");
  await agent.close();
  const later = opens.filter((open) => open.turns > 0);
  assert.ok(later.length >= 1 && later.every((open) => open.checkpoint && open.events === 0), JSON.stringify(opens));
});

test("a checkpoint where a turn yielded keeps the turn open, and its steers stay its own", () => {
  const log = [
    { cursor: "1", entry: { k: "lease", a: null, holder: "w1", epoch: 1, expiresAt: null } },
    { cursor: "2", entry: { k: "input", key: "prompt:p1", type: "prompt", messageId: "p1", input: "loop" } },
    { cursor: "3", entry: { k: "record", a: "1", key: "r1", data: "AA==", marks: [{ start: "p1" }] } },
    { cursor: "4", entry: { k: "input", key: "steer:s1", type: "steer", messageId: "s1", input: "also this" } },
    { cursor: "5", entry: { k: "record", a: "3", key: "r2", data: "AA==", marks: [{ yield: true }] } },
  ];
  const before = foldSessionLog(log);
  assert.equal(before.openTurn.id, "p1");
  assert.equal(before.yielded, true);
  assert.deepEqual(before.steers.map((input) => input.messageId), ["s1"]);
  // The checkpoint a worker saves at that yield.
  const checkpoint = {
    k: "checkpoint",
    through: "5",
    data: "AA==",
    pending: before.unconsumed.filter((input) => input.cursor <= 5),
    recent: before.recent,
    lastTurnId: before.lastTurnId,
    openTurn: before.openTurn,
    yielded: before.yielded,
    lease: before.lastLease,
  };
  const after = foldSessionLog([{ cursor: "6", entry: checkpoint }]);
  assert.deepEqual(after.openTurn, before.openTurn);
  assert.equal(after.yielded, true);
  assert.deepEqual(after.steers.map((input) => input.messageId), ["s1"], "the open turn's steer stays its steer");
  assert.deepEqual(after.pending, [], "no input becomes a new turn");
  assert.equal(after.lastEpoch, 1);
});

test("a turn longer than a function's time limit continues in the next delivery", async () => {
  const saves = [];
  const opens = [];
  const errors = [];
  const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1, reserveMs: 0 }), {
    onEvent: (event) => {
      if (event.type === "checkpoint.save") saves.push(event);
      else if (event.type === "checkpoint.error") errors.push(event);
      else if (event.type === "journal.open") opens.push(event);
    },
  }));
  const before = requests.length;
  const runsBefore = runs.length;
  const session = agent.session();
  const turn = session.prompt("loop");
  const { text, result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "looped 3");
  const sent = requests.slice(before);
  assert.equal(sent.length, 4, "each model step ran once");
  assert.ok(sent.every((prompt) => !JSON.stringify(prompt).includes(resumeNotice)), "a yield is not an interruption");
  assert.equal(runs.length - runsBefore, 3, "each tool call ran once");
  // Every delivery after the first model step stopped and handed on.
  const lines = await readLines(session.stream(0), 32);
  assert.equal(lines.filter((line) => line.type === "turn_yield").length, 3);
  assert.equal(lines.filter((line) => line.type === "turn_resume").length, 3);
  // A checkpoint at each yield, and none at the turn's short end; each
  // delivery after a yield loaded its checkpoint with no record after it.
  assert.deepEqual(errors, []);
  assert.equal(saves.length, 3, JSON.stringify(saves));
  const resumed = opens.filter((open) => open.resumable);
  assert.equal(resumed.length, 3);
  assert.ok(resumed.every((open) => open.checkpoint && open.events === 0), JSON.stringify(resumed));
  await agent.close();
});

for (const tool of ["lookup", "send"]) {
  test(`a ${tool} call still running near the deadline is cut off, and the next delivery continues the turn`, async () => {
    const deadlines = [];
    const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1500 * timeScale, reserveMs: 1000 * timeScale }), {
      onEvent: (event) => { if (event.type === "session.deadline") deadlines.push(event); },
    }));
    const held = gate(tool);
    const before = runs.filter(([name]) => name === tool).length;
    const turn = agent.prompt(`use ${tool}`);
    await held.started;
    // The call never returns on its own; a rerun goes through at once.
    gates.delete(tool);
    const { result } = await collect(turn);
    assert.equal(result.stopReason, "end_turn");
    assert.equal(deadlines.length, 1, "the worker stopped itself once, before its deadline");
    const ran = runs.filter(([name]) => name === tool).length - before;
    if (tool === "lookup") assert.equal(ran, 2, "the cut-off call ran again in the next delivery");
    else {
      assert.equal(ran, 1, "a call with effects never runs twice on its own");
      assert.ok(JSON.stringify(requests.at(-1)).includes("may have partly run"), "the model hears the call may have run");
    }
    const lines = await readLines(agent.session(agent.sessionId).stream(0), 32);
    assert.equal(lines.filter((line) => line.type === "turn_yield").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_resume").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_end").length, 1);
    if (tool === "send") assertEndedAsPossiblyRun(lines, lines.find((line) => line.type === "tool_start" && line.name === "send").id);
    await agent.close();
  });
}

// A call the resume answers as possibly run ends on the session stream, once,
// with what the model heard, so a viewer never shows it running for good.
function assertEndedAsPossiblyRun(lines, id) {
  const ends = lines.filter((line) => line.type === "tool_end" && line.id === id);
  assert.equal(ends.length, 1, `the call's tool_end shows once: ${JSON.stringify(lines.filter((line) => line.id === id))}`);
  assert.equal(ends[0].isError, true);
  assert.equal(ends[0].name, "send");
  assert.ok(typeof ends[0].content === "string" && ends[0].content.includes("may have partly run"), JSON.stringify(ends[0]));
  assert.ok(JSON.stringify(requests.at(-1)).includes(JSON.stringify(ends[0].content).slice(1, -1)), "the line says what the model heard");
}

test("a call the deadline cuts off 3 times in a row is not run again, and the model hears it may have partly run", async () => {
  const deadlines = [];
  const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1500 * timeScale, reserveMs: 1000 * timeScale }), {
    onEvent: (event) => { if (event.type === "session.deadline") deadlines.push(event.cutoffs); },
  }));
  // The call never returns within a delivery.
  const held = gate("lookup");
  const before = runs.filter(([name]) => name === "lookup").length;
  const { result } = await collect(agent.prompt("use lookup"));
  gates.delete("lookup");
  held.open();
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(deadlines, [1, 2, 3], "each deadline cut off the same step once more");
  assert.equal(runs.filter(([name]) => name === "lookup").length - before, 3, "the call ran once and was rerun twice");
  assert.ok(JSON.stringify(requests.at(-1)).includes("may have partly run"), "the model hears the call may have run");
  await agent.close();
});

test("a model request the deadline cuts off 3 times in a row cancels its turn", async () => {
  const deadlines = [];
  const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1500 * timeScale, reserveMs: 1000 * timeScale }), {
    onEvent: (event) => { if (event.type === "session.deadline") deadlines.push(event.cutoffs); },
  }));
  const before = requests.length;
  const { result } = await collect(agent.prompt("stall"));
  assert.equal(result.stopReason, "cancelled");
  assert.deepEqual(deadlines, [1, 2, 3]);
  assert.ok(requests.length - before <= 4, "the request is not sent on for good");
  // The session goes on with the next prompt.
  assert.equal((await agent.prompt("after the stall").result).stopReason, "end_turn");
  await agent.close();
});

test("a worker that froze is replaced, and its next write is refused", async () => {
  const durability = await durabilityFor();
  const slow = createFxAgent(agentOptions(durability));
  const held = gate("lookup");
  const session = slow.session();
  const turn = session.prompt("use lookup while frozen", { messageId: "frozen-turn" });
  await held.started;
  // The platform gives up on the frozen worker: its lease no longer stands.
  const holders = globalThis[Symbol.for("libfx.liveHolders")];
  const frozen = [...holders];
  for (const holder of frozen) holders.delete(holder);
  gates.delete("lookup");
  const fresh = createFxAgent(agentOptions(durability));
  const next = fresh.session(session.id).prompt("after the takeover");
  assert.equal((await next.result).stopReason, "end_turn");
  // The open turn was continued by the new worker: lookup is idempotent, so
  // it ran again there.
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  // Waking, the frozen worker's next write is refused. A model request may
  // overlap that write, but no tool runs and the session hears nothing.
  const runsBefore = runs.length;
  held.open();
  await new Promise((wait) => setTimeout(wait, 300));
  assert.equal(runs.length, runsBefore, "the frozen worker ran no tool after waking");
  const lines = await readLines(fresh.session(session.id).stream(0), 64).catch(() => []);
  const ends = lines.filter((line) => line.type === "turn_end" && line.messageId === "frozen-turn");
  assert.equal(ends.length, 1, "the turn ended once");
  // Its late lines rank below its successor's and stay hidden, and a reader
  // that reconnects mid-stream sees the same lines.
  const epochs = lines.map((line) => line.epoch).filter(Number.isSafeInteger);
  assert.deepEqual(epochs, [...epochs].sort((a, b) => a - b), "no shown line comes from a replaced worker after its successor's");
  const middle = lines[Math.floor(lines.length / 2)].cursor;
  assert.deepEqual(await readLines(fresh.session(session.id).stream(middle), 64), lines.filter((line) => line.cursor > middle), "a reconnect shows the same lines");
  // A later turn, after the session was released, claims a higher epoch, so
  // its lines still show after the takeover's.
  const later = fresh.session(session.id).prompt("a later turn", { messageId: "later-turn" });
  assert.equal((await later.result).stopReason, "end_turn");
  const shown = await readLines(fresh.session(session.id).stream(0), 96);
  const end = shown.find((line) => line.type === "turn_end" && line.messageId === "later-turn");
  assert.ok(end, "the later turn's lines show");
  assert.ok(end.epoch > Math.max(...epochs), "the later turn's epoch outranks every earlier line");
  await slow.close();
  await fresh.close();
});

if (durabilityKind !== "memory") {
  for (const tool of ["lookup", "send", "save"]) {
    test(`a crash during ${tool} ${tool === "send" ? "never sends twice, and the turn goes on" : "reruns the idempotent call under the same execution id"}`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-durable-crash-"));
      dirs.push(dir);
      const child = spawn(process.execPath, [
        ...process.execArgv,
        fileURLToPath(import.meta.url),
        durabilityKind,
        engineBackend,
        "--child",
        dir,
        tool,
      ], { stdio: ["ignore", "pipe", "inherit"], env: { ...process.env } });
      let output = "";
      child.stdout.on("data", (chunk) => { output += chunk; });
      await until(() => output.includes("\n"), "the child to start its tool", 30_000);
      const { sessionId, executionId } = JSON.parse(output.trim().split("\n")[0]);
      child.kill("SIGKILL");
      await new Promise((exited) => child.once("exit", exited));
      const runsBefore = runs.filter(([name]) => name === tool).length;
      const agent = createFxAgent(agentOptions(await durabilityAt(dir)));
      const session = agent.session(sessionId);
      const resumed = await session.resume().result;
      assert.equal(resumed.stopReason, "end_turn");
      const reran = runs.filter(([name]) => name === tool).length - runsBefore;
      if (tool === "send") {
        assert.equal(reran, 0, "a call with effects never runs twice on its own");
        // The turn went on at once, and the model was told the call may have
        // partly run.
        assert.ok(JSON.stringify(requests.at(-1)).includes("may have partly run"), "the model hears the call may have run");
        // Its viewers see the call end as the model does, once the turn
        // resumed. The dead worker's `tool_start` may not have landed.
        const lines = await readLines(session.stream(0), 64);
        const ended = lines.filter((line) => line.type === "tool_end" && line.name === "send");
        assert.equal(ended.length, 1, "the call ended once");
        assert.equal(ended[0].isError, true);
        const answer = toolResults(requests.at(-1)).find((part) => part.toolName === "send");
        assert.equal(ended[0].id, answer?.toolCallId, "the end names the call the model heard about");
        assert.ok(JSON.stringify(answer).includes(ended[0].content), `the line says what the model heard: ${ended[0].content}`);
        assert.ok(lines.indexOf(ended[0]) > lines.findIndex((line) => line.type === "turn_resume"), "the end comes after the turn resumed");
        for (const start of lines.filter((line) => line.type === "tool_start" && line.name === "send")) assert.equal(start.id, ended[0].id);
      } else {
        // The last request shows how the resumed turn saw the call, if not.
        assert.equal(reran, 1, `the idempotent call ran again; the model last saw ${JSON.stringify(requests.at(-1)).slice(-600)}`);
        // Under the id it started with, so a service keyed on it dedupes.
        assert.deepEqual(runs.filter(([name]) => name === tool).slice(runsBefore).map(([, id]) => id), [executionId]);
      }
      await agent.close();
    });
  }

  // Another worker takes the turn over as a queue that outlives the process
  // would, delivering the steer again, or for a resume.
  for (const kind of ["text", "image"]) {
    for (const takeover of ["redelivery", "resume"]) {
      test(`a crash during a turn ${kind === "image" ? "an image" : "a text"} steer started on a queue that outlives the process goes on once on another worker, by ${takeover === "redelivery" ? "the steer delivered again" : "a resume"}`, async () => {
        const dir = await mkdtemp(join(tmpdir(), "libfx-durable-steer-crash-"));
        dirs.push(dir);
        const child = spawn(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), durabilityKind, engineBackend, "--child", dir, "steer", kind], {
          stdio: ["ignore", "pipe", "inherit"], env: { ...process.env },
        });
        const exited = new Promise((resolveExit) => child.once("exit", resolveExit));
        let output = "";
        child.stdout.on("data", (chunk) => { output += chunk; });
        try {
          // Within the test's own timeout, so a child that never gets there
          // fails here and is stopped.
          await until(() => output.includes("\n"), "the child to start its tool", testTimeoutMs / 2);
        } finally {
          child.kill("SIGKILL");
          await exited;
        }
        const { sessionId, executionId } = JSON.parse(output.trim().split("\n")[0]);
        const runsBefore = runs.filter(([name]) => name === "lookup").length;
        const errors = [];
        const agent = createFxAgent(agentOptions(await queueDurableAt(dir), {
          onEvent: (event) => { if (event.type === "session.error") errors.push(event); },
        }));
        const session = agent.session(sessionId);
        if (takeover === "resume") assert.equal((await session.resume().result).stopReason, "end_turn");
        else await agent[Symbol.for("libfx.durableInternals")].deliver({ type: "steer", messageId: "crash-steer", input: crashSteer(kind), agent: "default", sessionId });
        const lines = await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "crash-steer", "the steer's turn");
        assert.deepEqual(lines.filter((line) => line.type === "turn_end").map((line) => [line.messageId, line.stopReason]), [["crash-steer", "end_turn"]], "the turn ended once");
        assert.ok(lines.some((line) => line.type === "turn_resume" && line.messageId === "crash-steer"), "the new worker continued the turn");
        // The dead worker's `turn_start` may not have landed; none comes after.
        assert.ok(lines.filter((line) => line.type === "turn_start").every((line) => line.messageId === "crash-steer"), "no other turn ran");
        assert.ok(lines.filter((line) => line.type === "turn_start").length <= 1, "the steer did not start a second turn");
        assert.deepEqual(runs.filter(([name]) => name === "lookup").slice(runsBefore).map(([, id]) => id), [executionId], "the idempotent call ran again under its id");
        assert.equal(userTexts(requests.at(-1)).filter((text) => text.includes("use lookup")).length, 1, "the steer reached the model once");
        if (kind === "image") assert.ok(JSON.stringify(requests.at(-1)).includes("image/png"), "the image is still in the turn");
        assert.deepEqual(errors, [], "the takeover reported no error");
        await agent.close();
      });
    }
  }
}

if (durabilityKind === "local") {
  test("a worker that dies frees its session a lease after its last renewal, not at its deadline", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-durable-leased-"));
    dirs.push(dir);
    const child = spawn(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), durabilityKind, engineBackend, "--child", dir, "send", "leased"], {
      stdio: ["ignore", "pipe", "inherit"], env: { ...process.env },
    });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    await until(() => output.includes("\n"), "the child to start its tool", 30_000);
    const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
    child.kill("SIGKILL");
    await new Promise((exited) => child.once("exit", exited));
    const killedAt = Date.now();
    const sendsBefore = runs.filter(([name]) => name === "send").length;
    const agent = createFxAgent(agentOptions(await leasedAt(dir)));
    const resumed = await agent.session(sessionId).resume().result;
    const waited = Date.now() - killedAt;
    assert.equal(resumed.stopReason, "end_turn");
    assert.equal(runs.filter(([name]) => name === "send").length - sendsBefore, 0, "a call with effects never runs twice on its own");
    // The dead worker renewed at most a third of a lease before the kill, so
    // its session frees within a lease of it, plus the backstop's rounding.
    assert.ok(waited < 5 * leaseTestMs, `the session freed ${waited} ms after the crash, not at the deadline`);
    await agent.close();
  });

  test("a worker busy for longer than its lease keeps the session by renewing it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-durable-renew-"));
    dirs.push(dir);
    const events = [];
    const held = gate("lookup");
    const first = createFxAgent(agentOptions(await leasedAt(dir), { onEvent: (event) => events.push(event.type) }));
    const second = createFxAgent(agentOptions(await leasedAt(dir)));
    try {
      const session = first.session();
      const turn = session.prompt("use lookup", { messageId: "long-turn" });
      await turn.accepted;
      await held.started;
      const lookupsBefore = runs.filter(([name]) => name === "lookup").length;
      // Another server's prompt comes while the call runs for three leases.
      const next = second.session(session.id).prompt("hello", { messageId: "next-turn" });
      await new Promise((wait) => setTimeout(wait, 3 * leaseTestMs));
      held.open();
      assert.equal((await turn.result).stopReason, "end_turn");
      assert.equal((await next.result).stopReason, "end_turn");
      assert.ok(!events.includes("session.fenced"), "no other worker took the session over");
      assert.equal(runs.filter(([name]) => name === "lookup").length, lookupsBefore, "the call ran once");
    } finally {
      gates.delete("lookup");
      held.open();
      await first.close();
      await second.close();
    }
  });

  test("a worker whose renewals stall past its lease stops its turn at the renewal another worker fenced", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-durable-lapse-"));
    dirs.push(dir);
    const internals = Symbol.for("libfx.durableInternals");
    const events = [];
    let stalled = false;
    const [durability, writes] = holdWrites(await leasedAt(dir), (entry) => stalled && entry.k === "lease");
    const first = createFxAgent(agentOptions(durability, { onEvent: (event) => events.push(event.type) }));
    const second = createFxAgent(agentOptions(await leasedAt(dir)));
    let takeover = null;
    try {
      const requestsBefore = requests.length;
      const session = first.session();
      const turn = session.prompt("stall", { messageId: "lapsed-turn" });
      void turn.result.catch(() => {});
      await turn.accepted;
      // The first worker waits on a model request that never answers.
      await until(() => requests.length > requestsBefore, "the first worker's model request");
      // Its model request can go out before its claim lands.
      await until(async () => (await first[internals].lastLease(session.id)) !== null, "the first worker's claim");
      const holder = (await first[internals].lastLease(session.id)).holder;
      // Its renewals stall until its lease runs out, and another worker
      // takes the session over, as the queue's next delivery would.
      stalled = true;
      await new Promise((wait) => setTimeout(wait, leaseTestMs + 1000));
      takeover = second.session(session.id).resume();
      void takeover.result.catch(() => {});
      await until(async () => (await second[internals].lastLease(session.id))?.holder !== holder, "the takeover");
      assert.ok(!events.includes("session.fenced"), "the first worker has not written since");
      // The stalled renewal lands and is fenced out: the first worker stops
      // its model request at once instead of waiting on it.
      await writes.releaseHeld();
      await until(() => events.includes("session.fenced"), "the first worker to stop", 2 * leaseTestMs);
      await until(() => first[internals].liveWorkers() === 0, "the first worker to let the session go", 2 * leaseTestMs);
      // The turn goes on with the second worker, where its request stalls too.
      await second.session(session.id).cancel();
      assert.equal((await takeover.result).stopReason, "cancelled");
    } finally {
      writes.release();
      await first.close();
      await second.close();
    }
  });
}

if (durabilityKind !== "memory") {
  test("a prompt accepted just before a crash still runs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-durable-accepted-"));
    dirs.push(dir);
    const child = spawn(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), durabilityKind, engineBackend, "--child", dir, "accepted"], {
      stdio: ["ignore", "pipe", "inherit"], env: { ...process.env },
    });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    await new Promise((exited) => child.once("exit", exited));
    const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
    const agent = createFxAgent(agentOptions(await durabilityAt(dir)));
    const { text, result } = await collect(agent.session(sessionId).resume());
    assert.equal(result.stopReason, "end_turn", "the accepted prompt was in the log");
    assert.equal(text, "echo: hello");
    await agent.close();
  });
}

test("an option the backend rejects fails the first turn once", async () => {
  const events = [];
  const agent = createFxAgent(agentOptions(await durabilityFor(), {
    model: { id: "durable/model", effort: "high" },
    onEvent: (event) => { if (event.type === "session.error") events.push(event); },
  }));
  const sent = requests.length;
  const result = await agent.prompt("hello").result;
  assert.equal(result.stopReason, "error");
  assert.equal(result.error?.code, "LIBFX_MODEL_UNSUPPORTED_EFFORT");
  assert.equal(events.length, 1);
  assert.equal(requests.length, sent, "no model request was made");
  await agent.close();
});

// A 1x1 PNG, as bytes, for the image tests below.
const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
const pngBytes = () => Uint8Array.from(atob(pngBase64), (char) => char.charCodeAt(0));

test("a prompt the engine would refuse throws, stores nothing, and the session goes on", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor(), { model: "durable/vision-model" }));
  const session = agent.session();
  const image = (data, mimeType = "image/png") => ({ type: "image", data, mimeType });
  for (const [input, refusal] of [
    ["", /prompt is empty/],
    [[{ type: "text" }], /text prompt block 0 requires text/],
    [[{ type: "text", text: "look" }, image("not base64!")], /image prompt block 1 requires canonical base64 data/],
    [[{ type: "text", text: "look" }, image(pngBytes())], /a durable prompt carries image data as a base64 string/],
    [[{ type: "text", text: "look" }, image(pngBase64, "image/jpeg")], /image prompt block 1 holds image\/png data, not image\/jpeg/],
    [[{ type: "text", text: "look" }, image(pngBase64, "image/gif")], /image prompt block 1 holds image\/png data, not image\/gif/],
    [[{ type: "text", text: "look" }, image(Buffer.from([1, 2, 3, 4]).toString("base64"))], /image prompt block 1 is not a PNG, JPEG, GIF or WebP image/],
    [[{ type: "text", text: "look" }, image(pngBase64, "image/bmp")], /image prompt block 1 mimeType must be image\/png, image\/jpeg, image\/gif or image\/webp/],
    [[{ type: "text", text: "look" }, ...Array.from({ length: 9 }, () => image(pngBase64))], /prompt cannot contain more than 8 images/],
  ]) {
    assert.throws(() => session.prompt(input, { messageId: "refused" }), refusal);
  }
  // Nothing was stored under that id, so a prompt with it runs.
  const { text, result } = await collect(session.prompt("hello again", { messageId: "refused" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "echo: hello again");
  await agent.close();
});

test("a durable prompt's images reach the model as the base64 it was given", async () => {
  const png = pngBase64;
  const agent = createFxAgent(agentOptions(await durabilityFor(), { model: "durable/vision-model" }));
  const { text, result } = await collect(agent.session().prompt([
    { type: "text", text: "look" },
    { type: "image", data: png, mimeType: "image/png" },
    { type: "image", data: png, mimeType: "image/png", sourceRef: "uploads:shot" },
  ]));
  assert.equal(result.stopReason, "end_turn");
  // The model hears each image's placeholder alongside its text.
  assert.equal(text, "echo: look\n[Image #1]\n[Image #2]");
  const files = chats.at(-1).prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
  const file = { type: "file", mediaType: "image/png", data: { type: "data", data: png } };
  assert.deepEqual(files, [file, file]);
  await agent.close();
});

test("an image read that fails while the engine opens runs the turn again instead of failing it", async () => {
  const base = await durabilityFor();
  // memory() hands out its sessions directly, so one image read can fail.
  if (typeof base.create !== "function") return;
  const fault = { failReads: 0 };
  const durability = {
    ...base,
    create() {
      const backend = base.create();
      return {
        ...backend,
        async session(id) {
          const log = await backend.session(id);
          return {
            ...log,
            images: {
              put: (name, bytes) => log.images.put(name, bytes),
              get: async (name) => {
                if (fault.failReads > 0) {
                  fault.failReads -= 1;
                  throw new Error("the image store did not answer");
                }
                return log.images.get(name);
              },
            },
          };
        },
      };
    },
  };
  const png = pngBase64;
  const first = createFxAgent(agentOptions(durability, { model: "durable/vision-model" }));
  const session = first.session();
  assert.equal((await session.prompt([{ type: "text", text: "look" }, { type: "image", data: png, mimeType: "image/png" }]).result).stopReason, "end_turn");
  await first.close();
  // A new agent's engine reads the session's image as it opens; that read
  // fails once.
  fault.failReads = 1;
  const second = createFxAgent(agentOptions(durability, { model: "durable/vision-model" }));
  const { result } = await collect(second.session(session.id).prompt("and now"));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(fault.failReads, 0, "the failed read happened");
  const files = chats.at(-1).prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
  assert.deepEqual(files.map((part) => part.data?.data), [png]);
  await second.close();
});

test("an engine given an image the log names refuses it, so a worker that can't read names fails the turn", async () => {
  // The log holds a stored image as `data: { sha256 }`, which an engine that
  // predates names can't read, with or without a sourceRef: such a worker
  // fails the turn instead of running it without the image.
  const { durability: _durability, tools: _tools, ...engineOptions } = agentOptions(null, { model: "durable/vision-model" });
  const engine = await createFxEngine(engineOptions);
  const named = { type: "image", mimeType: "image/png", data: { sha256: "a".repeat(64) } };
  for (const block of [named, { ...named, sourceRef: "uploads:shot" }]) {
    assert.throws(() => engine.prompt([{ type: "text", text: "look" }, block]), /requires base64 data, bytes, or a Blob/);
  }
  await engine.close();
});

test("a durable prompt checks the copy its log holds, so a getter can't pass one image and store another", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor(), { model: "durable/vision-model" }));
  let reads = 0;
  const block = { type: "image", mimeType: "image/png" };
  Object.defineProperty(block, "data", { enumerable: true, get: () => (reads++ === 0 ? pngBase64 : Buffer.from([1, 2, 3, 4]).toString("base64")) });
  const { result } = await collect(agent.session().prompt([{ type: "text", text: "look" }, block]));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(reads, 1, "the block was read once");
  const files = chats.at(-1).prompt.flatMap((message) => Array.isArray(message.content) ? message.content : []).filter((part) => part.type === "file");
  assert.deepEqual(files.map((part) => part.data?.data), [pngBase64]);
  await agent.close();
});

test("a durable prompt cancelled while its image is stored is never stored, and sends no cancel", async () => {
  const base = await durabilityFor();
  // memory() hands out its sessions directly, so its image writes can be held.
  if (typeof base.create !== "function") return;
  let release;
  const held = new Promise((resolveHeld) => { release = resolveHeld; });
  const durability = {
    ...base,
    create() {
      const backend = base.create();
      return {
        ...backend,
        async session(id) {
          const log = await backend.session(id);
          return { ...log, images: { put: async (name, bytes) => { await held; return log.images.put(name, bytes); }, get: (name) => log.images.get(name) } };
        },
      };
    },
  };
  const agent = createFxAgent(agentOptions(durability, { model: "durable/vision-model" }));
  const session = agent.session();
  const controller = new AbortController();
  const turn = session.prompt([{ type: "text", text: "look" }, { type: "image", data: pngBase64, mimeType: "image/png" }], { messageId: "withdrawn", signal: controller.signal });
  await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  controller.abort();
  // The prompt stops waiting for its image write at once.
  await turn.accepted;
  assert.equal((await turn.result).stopReason, "cancelled");
  release();
  // Neither the prompt nor a cancel naming it was stored: one stored would
  // answer a prompt with its id from the log, and a cancel would end it.
  const { text, result } = await collect(session.prompt("hello again", { messageId: "withdrawn" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "echo: hello again");
  await agent.close();
});

test("an engine refuses the same prompts in prompt(), before its core sees them", async () => {
  const { durability: _durability, tools: _tools, ...engineOptions } = agentOptions(null, { model: "durable/vision-model" });
  const engine = await createFxEngine(engineOptions);
  assert.throws(() => engine.prompt(""), /prompt is empty/);
  assert.throws(() => engine.prompt([{ type: "text", text: "look" }, { type: "image", data: pngBytes(), mimeType: "image/jpeg" }]), /holds image\/png data, not image\/jpeg/);
  await assert.rejects(engine.prompt([{ type: "text", text: "look" }, { type: "image", data: new File([pngBytes()], "shot.jpg", { type: "image/jpeg" }) }]).result, /holds image\/png data, not image\/jpeg/);
  const { result } = await collect(engine.prompt("hello"));
  assert.equal(result.stopReason, "end_turn");
  await engine.close();
});

test("a durable session saves each image once, and a new agent sends it again", async () => {
  // A PNG header, then filler, so its bytes are easy to look for.
  const header = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII="), (char) => char.charCodeAt(0));
  const bytes = new Uint8Array(300_000);
  bytes.set(header);
  for (let index = header.length; index < bytes.length; index += 1) bytes[index] = (index * 31 + 7) & 255;
  const base64 = Buffer.from(bytes).toString("base64");
  const durability = await durabilityFor();
  const holdsImage = (data) => data.includes(Buffer.from(base64.slice(1000, 1100))) || data.includes(Buffer.from(bytes.subarray(1000, 1064)));
  const savedData = (entry) => (entry.k === "record" || entry.k === "checkpoint" ? Buffer.from(entry.data, "base64") : Buffer.from(JSON.stringify(entry)));
  // A remote World keeps nothing on this machine, so what reaches it is
  // watched instead: each entry the log appends, and each stream write.
  const sent = { entries: [], imageWrites: 0 };
  if (remote) {
    const open = durability.world.bind(durability);
    durability.world = async () => {
      const world = await open();
      const create = world.events.create.bind(world.events);
      world.events.create = async (runId, event, ...rest) => {
        const input = event?.eventData?.input;
        if (input instanceof Uint8Array) {
          try {
            const entry = JSON.parse(Buffer.from(input).toString("utf8"));
            if (typeof entry?.k === "string") sent.entries.push(entry);
          } catch {}
        }
        return create(runId, event, ...rest);
      };
      const write = world.streams.write.bind(world.streams);
      world.streams.write = async (runId, stream, data, ...rest) => {
        if (data instanceof Uint8Array && Buffer.from(data).equals(Buffer.from(bytes))) sent.imageWrites += 1;
        return write(runId, stream, data, ...rest);
      };
      return world;
    };
  }
  const first = createFxAgent(agentOptions(durability, { model: "durable/vision-model" }));
  const session = first.session();
  // Records that only name the image stay small, so the second prompt is
  // `bulky`: its turn's end saves a checkpoint, which must name the images too.
  for (const text of ["look", bulky]) {
    const { result } = await collect(session.prompt([{ type: "text", text }, { type: "image", data: base64, mimeType: "image/png" }]));
    assert.equal(result.stopReason, "end_turn");
  }
  // A turn's checkpoint is saved after its end, and close() waits for it.
  await first.close();
  if (durabilityKind === "memory" || remote) {
    // Every entry, records and checkpoints decoded: names only.
    const entries = remote ? sent.entries : (await (await durability.create().session(session.id)).readSince("0")).map(({ entry }) => entry);
    assert.ok(entries.some((entry) => entry.k === "checkpoint"));
    assert.ok(!entries.map(savedData).some(holdsImage), "no entry holds the image");
  }
  if (remote) {
    assert.equal(sent.imageWrites, 1, "the World got the image's bytes once");
  } else if (durabilityKind !== "memory") {
    const files = [];
    for (const entry of await readdir(dirs.at(-1), { withFileTypes: true, recursive: true })) {
      if (!entry.isFile()) continue;
      try {
        files.push(await readFile(join(entry.parentPath ?? entry.path, entry.name)));
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
    assert.ok(!files.some((data) => data.includes(Buffer.from(base64.slice(1000, 1100)))), "no file holds the image as base64");
    assert.equal(files.filter((data) => data.includes(Buffer.from(bytes.subarray(1000, 1064)))).length, 1, "one file holds the image's bytes");
  }

  const second = createFxAgent(agentOptions(durabilityKind === "memory" ? durability : await durabilityFor({ dir: dirs.at(-1) }), { model: "durable/vision-model" }));
  const { result } = await collect(second.session(session.id).prompt("and now"));
  assert.equal(result.stopReason, "end_turn");
  const files = chats.at(-1).prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
  assert.deepEqual(files.map((part) => part.data?.data), [base64, base64]);
  await second.close();
});

// A PNG of 300 KB with filler after its header, so its bytes are easy to
// look for, as base64.
const shotBytes = (() => {
  const header = Uint8Array.from(atob(onePixelPng), (char) => char.charCodeAt(0));
  const bytes = new Uint8Array(300_000);
  bytes.set(header);
  for (let index = header.length; index < bytes.length; index += 1) bytes[index] = (index * 17 + 3) & 255;
  return bytes;
})();
const shotBase64 = Buffer.from(shotBytes).toString("base64");
const shotName = createHash("sha256").update(shotBytes).digest("hex");
const holdsShot = (data) => data.includes(Buffer.from(shotBase64.slice(1000, 1100))) || data.includes(Buffer.from(shotBytes.subarray(1000, 1064)));
const entryData = (entry) => (entry.k === "record" || entry.k === "checkpoint" ? Buffer.from(entry.data, "base64") : Buffer.from(JSON.stringify(entry)));
// Returns the screenshot as a typed result.
const screenshot = {
  name: "screenshot",
  description: "Takes a screenshot",
  idempotent: true,
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async () => ({ type: "libfx.tool-result", text: "the screen", images: [{ type: "image", data: shotBase64, mimeType: "image/png" }] }),
};
const requestFiles = (prompt) => prompt
  .filter((message) => message.role === "user" && Array.isArray(message.content))
  .flatMap((message) => message.content)
  .filter((part) => part.type === "file")
  .map((part) => part.data?.data ?? part.data);

test("a durable session saves a tool's image once, its log only names it, and a new agent sends it again", async () => {
  const durability = await durabilityFor();
  const withShots = { model: "durable/vision-model", tools: [lookup, send, save, screenshot] };
  const first = createFxAgent(agentOptions(durability, withShots));
  const session = first.session();
  const { result } = await collect(session.prompt("use screenshot"));
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(requestFiles(chats.at(-1).prompt), [shotBase64], "the model saw the screenshot");
  await first.close();
  if (durabilityKind === "memory") {
    const log = await durability.create().session(session.id);
    const entries = (await log.readSince("0")).map(({ entry }) => entry);
    assert.ok(!entries.map(entryData).some(holdsShot), "no entry holds the screenshot");
    assert.ok(Buffer.from(await log.images.get(shotName)).equals(Buffer.from(shotBytes)), "the image store holds it by name");
  }

  const second = createFxAgent(agentOptions(durabilityKind === "memory" ? durability : await durabilityFor({ dir: dirs.at(-1) }), withShots));
  const { result: after } = await collect(second.session(session.id).prompt("and now"));
  assert.equal(after.stopReason, "end_turn");
  assert.deepEqual(requestFiles(chats.at(-1).prompt), [shotBase64], "a new agent sends the screenshot again");
  await second.close();
});

test("a durable steer saves its image once, and its log entry only names it", async () => {
  const durability = await durabilityFor();
  const agent = createFxAgent(agentOptions(durability, { model: "durable/vision-model" }));
  const session = agent.session();
  const before = slow.length;
  const turn = session.prompt("slow reply");
  await turn.accepted;
  await until(() => slow.length > before && slow.at(-1).sent > 0, "the reply to stream");
  await session.steer([{ type: "text", text: "match the shot" }, { type: "image", data: shotBase64, mimeType: "image/png" }], { messageId: "m-shot" });
  await turn.result;
  await linesUntil(session, (line) => line.type === "turn_end" && line.messageId === "m-shot", "the steer's turn");
  const steered = chats.findLast(({ prompt }) => userTexts(prompt).some((text) => text.includes("match the shot")));
  assert.deepEqual(requestFiles(steered.prompt), [shotBase64], "the steer's image reached the model");
  await agent.close();
  if (durabilityKind === "memory") {
    const log = await durability.create().session(session.id);
    const entries = (await log.readSince("0")).map(({ entry }) => entry);
    const entry = entries.find((item) => item.k === "input" && item.messageId === "m-shot");
    assert.ok(entry, "the steer is in the log");
    assert.deepEqual(entry.input.find((block) => block.type === "image").data, { sha256: shotName });
    assert.ok(!entries.map(entryData).some(holdsShot), "no entry holds the image");
    assert.ok(Buffer.from(await log.images.get(shotName)).equals(Buffer.from(shotBytes)), "the image store holds it by name");
  }
});

test("the fx harness tells a refused turn from one whose core exited under it", async () => {
  const { fxHarness } = await import("../fx-harness.js");
  const { coreAnswered, engineInternals } = await import("../fx-sdk.js");
  // A stand-in engine whose one turn fails, and whose core may then exit.
  const engineWith = ({ error, exits }) => {
    let exit;
    const exited = new Promise((resolve) => { exit = resolve; });
    const result = Promise.reject(error);
    result.catch(() => {});
    if (exits) setTimeout(() => exit(1), 10);
    return {
      prompt: () => ({ result, steer: async () => {}, cancel() {}, async *[Symbol.asyncIterator]() {} }),
      close: async () => {},
      [engineInternals]: { exited, openTurn: null, settled: async () => {}, checkpoint: async () => {} },
    };
  };
  const failure = async (engine) => {
    const session = await fxHarness({ createEngine: async () => engine })({}).open({ sessionId: "s", store: {}, context: null });
    return session.prompt("x").result.catch((error) => error);
  };
  assert.equal((await failure(engineWith({ error: new Error("write to a closed core"), exits: true }))).code, "FX_HARNESS_STOPPED");
  assert.notEqual((await failure(engineWith({ error: new Error("a request failed"), exits: false }))).code, "FX_HARNESS_STOPPED", "a live core ended the turn");
  const answered = await failure(engineWith({ error: Object.assign(new Error("Empty prompt"), { [coreAnswered]: true }), exits: true }));
  assert.equal(answered.message, "Empty prompt");
  assert.notEqual(answered.code, "FX_HARNESS_STOPPED", "the core answered, so it refused the turn");
});

test("each factory names itself in its option errors", async () => {
  await assert.rejects(createWasmEngine(5), /^TypeError: createFxEngine\(\) options must be an object$/);
  await assert.rejects(createFxEngine({ env: {} }), /^TypeError: createFxEngine\(\) does not accept env/);
  // The durable agent refuses it when created, before any session opens.
  assert.throws(() => createFxAgent({ env: {} }), /^TypeError: createFxAgent\(\) does not accept env$/);
});

test("each agent.session() call carries its own context to the tools", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const first = agent.session();
  await first.prompt("hello").result;
  const before = contexts.length;
  for (const user of ["a", "b"]) {
    assert.equal((await agent.session(first.id, { context: { user } }).prompt("use lookup").result).stopReason, "end_turn");
  }
  assert.deepEqual(contexts.slice(before), [{ user: "a" }, { user: "b" }]);
  assert.deepEqual(sessionsSeen.slice(before), [first.id, first.id], "every call hears its session's id");
  // A prompt queued behind another caller's running turn still runs with
  // its own caller's context.
  const held = gate("lookup");
  const running = agent.session(first.id, { context: { user: "c" } }).prompt("use lookup");
  await held.started;
  const queued = agent.session(first.id, { context: { user: "d" } }).prompt("use lookup");
  await queued.accepted;
  gates.delete("lookup");
  held.open();
  assert.equal((await running.result).stopReason, "end_turn");
  assert.equal((await queued.result).stopReason, "end_turn");
  assert.deepEqual(contexts.slice(-2), [{ user: "c" }, { user: "d" }]);
  await agent.close();
});

test("a session object's model and instructions reach its model requests, over the agent's", async () => {
  const systemOf = (prompt) => prompt.filter((message) => message.role === "system").map(textOf).join("\n");
  const agent = createFxAgent(agentOptions(await durabilityFor(), { instructions: "Agent rules." }));
  const first = agent.session(undefined, { model: { id: "durable/other" }, instructions: ["Chat rules.", "Chat style."] });
  const before = chats.length;
  assert.equal((await first.prompt("hello").result).stopReason, "end_turn");
  assert.equal((await agent.session(first.id).prompt("plain").result).stopReason, "end_turn");
  const sent = chats.slice(before);
  assert.deepEqual(sent.map((chat) => chat.model), ["durable/other", "durable/model"]);
  assert.match(systemOf(sent[0].prompt), /Chat rules\.\n\nChat style\./);
  assert.doesNotMatch(systemOf(sent[0].prompt), /Agent rules/);
  assert.match(systemOf(sent[1].prompt), /Agent rules\./, "a call without settings runs with the agent's");
  // Settings the engine would refuse are refused when the session object is made.
  assert.throws(() => agent.session(first.id, { model: { id: "durable/model", speed: 1 } }), /^TypeError: unsupported model option: speed$/);
  assert.throws(() => agent.session(first.id, { model: 5 }), /^TypeError: session model must be a model id or a model object$/);
  assert.throws(() => agent.session(first.id, { instructions: 5 }), /^TypeError: instructions must be a string or an array of strings$/);
  await agent.close();
});

test("createFxAgent() refuses a host tool that does not say whether it is idempotent", async () => {
  const durability = await durabilityFor();
  const { idempotent: _idempotent, ...unmarked } = send;
  const refusal = /tool send must set idempotent: true if running a call twice is safe, or idempotent: false if it is not/;
  assert.throws(() => createFxAgent(agentOptions(durability, { tools: [lookup, unmarked] })), refusal);
  const { name: _name, ...keyed } = unmarked;
  assert.throws(() => createFxAgent(agentOptions(durability, { tools: { send: keyed } })), refusal);
  assert.throws(() => createFxAgent(agentOptions(durability, { tools: [{ ...send, idempotent: "yes" }] })), refusal);
  // A tool the provider runs has nothing to say.
  const agent = createFxAgent(agentOptions(durability, { tools: [lookup, { name: "web_search", providerExecuted: true }] }));
  await agent.close();
});

test("a tool that stops being idempotent changes the tools a checkpoint names", async () => {
  const durability = await durabilityFor();
  const first = createFxAgent(agentOptions(durability));
  const session = first.session();
  assert.equal((await session.prompt(bulky).result).stopReason, "end_turn");
  // Closing waits for the checkpoint that turn's end saves.
  await first.close();

  const mismatches = [];
  const onEvent = (event) => { if (event.type === "checkpoint.mismatch") mismatches.push(event.changed); };
  const other = createFxAgent(agentOptions(durability, { tools: [{ ...lookup, idempotent: false }, send], onEvent }));
  assert.equal((await other.session(session.id).prompt("lookup no longer reruns").result).stopReason, "end_turn");
  await other.close();
  assert.deepEqual(mismatches, [["toolSchemaHash"]]);
});

test("a checkpoint names the libfx, tools and model that saved it, and a resume with others hears so", async () => {
  const durability = await durabilityFor();
  const mismatches = (list) => (event) => { if (event.type === "checkpoint.mismatch") list.push(event); };
  const first = createFxAgent(agentOptions(durability));
  const session = first.session();
  assert.equal((await session.prompt(bulky).result).stopReason, "end_turn");
  await first.close();

  const same = [];
  const again = createFxAgent(agentOptions(durability, { onEvent: mismatches(same) }));
  assert.equal((await again.session(session.id).prompt("same tools").result).stopReason, "end_turn");
  await again.close();
  assert.deepEqual(same, []);

  const changed = [];
  const other = createFxAgent(agentOptions(durability, { tools: [lookup], model: "durable/other", onEvent: mismatches(changed) }));
  assert.equal((await other.session(session.id).prompt("fewer tools").result).stopReason, "end_turn");
  await other.close();
  assert.equal(changed.length, 1, JSON.stringify(changed));
  assert.equal(changed[0].sessionId, session.id);
  assert.deepEqual(changed[0].changed, ["toolSchemaHash", "model"]);
  assert.equal(changed[0].saved.model, "durable/model");
  assert.equal(changed[0].current.model, "durable/other");
  assert.equal(changed[0].saved.libfxVersion, changed[0].current.libfxVersion);

  // A checkpoint carried to a new agent reports the same way.
  const source = createFxAgent(agentOptions(await durabilityFor()));
  await source.prompt("carry this").result;
  const checkpoint = await source.checkpoint();
  await source.close();
  const carried = [];
  const restored = createFxAgent(agentOptions(await durabilityFor(), { checkpoint, model: "durable/other", onEvent: mismatches(carried) }));
  assert.equal((await restored.prompt("still here").result).stopReason, "end_turn");
  await restored.close();
  assert.deepEqual(carried.map((event) => event.changed), [["model"]]);
});

test("a checkpoint restores the conversation in a new agent", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  await agent.prompt("remember the word kiwi").result;
  const checkpoint = await agent.checkpoint();
  assert.ok(checkpoint instanceof Uint8Array && checkpoint.byteLength > 0);
  await agent.close();
  const restored = createFxAgent(agentOptions(await durabilityFor(), { checkpoint }));
  assert.equal((await restored.prompt("what was the word").result).stopReason, "end_turn");
  assert.deepEqual(userTexts(requests.at(-1)), ["remember the word kiwi", "what was the word"]);
  await restored.close();
});

test("a checkpoint after an image prompt holds the image, and a new agent sends it", async () => {
  const png = pngBase64;
  const agent = createFxAgent(agentOptions(await durabilityFor(), { model: "durable/vision-model" }));
  const look = [{ type: "text", text: "look" }, { type: "image", data: png, mimeType: "image/png" }];
  assert.equal((await agent.prompt(look).result).stopReason, "end_turn");
  // The session's records name the image; the checkpoint carries its bytes.
  const checkpoint = await agent.checkpoint();
  await agent.close();
  const restored = createFxAgent(agentOptions(await durabilityFor(), { checkpoint, model: "durable/vision-model" }));
  assert.equal((await restored.prompt("what was in it").result).stopReason, "end_turn");
  const files = chats.at(-1).prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
  assert.deepEqual(files.map((part) => part.data?.data), [png]);
  await restored.close();
});

// LIBFX_TEST_ONLY runs only the tests whose names contain it.
const only = process.env.LIBFX_TEST_ONLY;
const selected = only ? tests.filter(([name]) => name.includes(only)) : tests;
let failed = 0;
for (const [name, fn] of selected) {
  const started = performance.now();
  try {
    let timer;
    await Promise.race([
      fn(),
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error(`timed out after ${testTimeoutMs / 1000}s`)), testTimeoutMs); }),
    ]).finally(() => clearTimeout(timer));
    console.log(`ok ${name} (${(performance.now() - started).toFixed(0)}ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n  ${error?.stack ?? error}`);
  }
}
server.close();
await closeAppWorlds?.();
for (const dir of dirs) await rm(dir, { recursive: true, force: true }).catch(() => {});
console.log(`${selected.length - failed}/${selected.length} durable tests passed (${durabilityKind}, ${engineBackend})`);
process.exit(failed ? 1 : 0);
