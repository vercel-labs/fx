#!/usr/bin/env node
// Durable sessions through createFxAgent: the production problems Rauch's
// durability doc lists, on memory() and local(), against a fake gateway.
//
//   node --experimental-wasm-jspi sdk/tests/test-durable.mjs [memory|local] [native|wasm]
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxEngine, memory } from "../node.js";
import { createFxEngine as createWasmEngine } from "../fx-sdk.js";
import { foldSessionLog } from "../durable.js";
import { holdWrites } from "./hold-writes.mjs";

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
const resumeNotice = "Resuming from unexpected session interruption.";

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
// "loop" calls lookup three times; "stall" never answers; anything else is
// echoed.
function framesFor(prompt) {
  const users = userTexts(prompt).filter((text) => text !== resumeNotice);
  const text = users.at(-1) ?? "";
  const results = toolResults(prompt);
  const turnResults = results.filter((part) => String(part.toolCallId).startsWith(`call-${users.length}-`));
  if (text.startsWith("use ")) {
    const tool = text.slice(4).split(" ")[0];
    if (turnResults.length === 0) return toolCall(`call-${users.length}-0`, tool, { key: "alpha" });
    return answer(`done: ${JSON.stringify(turnResults.at(-1).output)}`);
  }
  if (text === "stall") return null;
  if (text === "loop") {
    if (turnResults.length < 3) return toolCall(`call-${users.length}-${turnResults.length}`, "lookup", { key: `k${turnResults.length}` });
    return answer(`looped ${turnResults.length}`);
  }
  return answer(`echo: ${text}`);
}

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
      response.end(JSON.stringify({ object: "list", data: [{ id: "durable/model", type: "language" }] }));
      return;
    }
    const prompt = JSON.parse(body).prompt;
    requests.push(prompt);
    chats.push({ model: request.headers["ai-language-model-id"] ?? null, prompt });
    const frames = framesFor(prompt);
    if (frames === null) return;
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
  backend: engineBackend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "durable-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "durable/model",
  tools: [lookup, send],
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
if (childMode) {
  const dir = process.argv[5];
  const tool = process.argv[6];
  gate(tool);
  const agent = createFxAgent(agentOptions(process.argv[7] === "leased" ? await leasedAt(dir) : await durabilityAt(dir)));
  const session = agent.session();
  void session.prompt(`use ${tool}`, { messageId: "crash-turn" }).result.catch(() => {});
  // A call starts only after its record lands, so the crash comes the moment
  // the tool runs.
  await gates.get(tool).started;
  console.log(JSON.stringify({ sessionId: session.id }));
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

  // With a queue that outlives the process, as on Vercel, a message's input
  // is written with its claim's lease, so the lease can land first.
  test("a prompt whose input landed after another worker took the session over still runs", async () => {
    const base = queueOutlivesProcess(await durabilityFor());
    const [held, writes] = holdWrites(base, (entry) => entry.k === "input");
    const first = createFxAgent(agentOptions(held));
    const turn = first.session().prompt("one");
    const { sessionId } = await turn.accepted;
    await writes.next();
    await until(async () => (await first[Symbol.for("libfx.durableInternals")].lastLease(sessionId)) !== null, "the first worker's lease");
    // The platform gives up on the first worker, and another takes the
    // session over for a prompt of its own and finishes it.
    const holders = globalThis[Symbol.for("libfx.liveHolders")];
    for (const holder of [...holders]) holders.delete(holder);
    const second = createFxAgent(agentOptions(base));
    assert.equal((await collect(second.session(sessionId).prompt("two"))).result.stopReason, "end_turn");
    // Closing waits for its delivery to finish, so it cannot take the first
    // prompt as well.
    await second.close();
    // The first prompt lands only now; its worker reads the log again and
    // runs it.
    writes.release();
    let timer;
    const stranded = new Promise((_, fail) => { timer = setTimeout(() => fail(new Error("the first prompt never ran")), 10_000 * timeScale); });
    const ran = await Promise.race([collect(turn), stranded]).finally(() => clearTimeout(timer));
    assert.equal(ran.text, "echo: one");
    await first.close();
  });
}

if (durabilityKind !== "memory") {
  test("a session's log reads stay one small page however long its history grows", async () => {
    const [durability, listed] = listingsOf(await durabilityFor());
    const agent = createFxAgent(agentOptions(durability));
    const session = agent.session();
    for (let turn = 0; turn < 8; turn += 1) assert.equal((await session.prompt(`turn ${turn}`).result).stopReason, "end_turn");
    listed.length = 0;
    const { text } = await collect(session.prompt("one more"));
    assert.equal(text, "echo: one more");
    assert.ok(listed.length > 0, "the turn read its log");
    assert.ok(Math.max(...listed) <= 10, `each read stopped at the newest checkpoint within one page: ${listed.join(", ")}`);
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

test("every turn's end saves a checkpoint, and the next turn starts from it", async () => {
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
  await agent.close();
  assert.equal(saves.length, 2, JSON.stringify(saves));
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
  // A checkpoint at each yield and at the turn's end, and each delivery
  // after a yield loaded its checkpoint with no record after it.
  assert.deepEqual(errors, []);
  assert.equal(saves.length, 4, JSON.stringify(saves));
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
    await agent.close();
  });
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
  for (const tool of ["lookup", "send"]) {
    test(`a crash during ${tool} ${tool === "send" ? "never sends twice, and the turn goes on" : "reruns the idempotent call"}`, async () => {
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
      const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
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
      } else {
        // The last request shows how the resumed turn saw the call, if not.
        assert.equal(reran, 1, `the idempotent call ran again; the model last saw ${JSON.stringify(requests.at(-1)).slice(-600)}`);
      }
      await agent.close();
    });
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

test("a prompt the engine refuses ends its own turn once, and the session goes on", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const empty = await session.prompt("").result;
  assert.equal(empty.stopReason, "error");
  const malformed = await session.prompt([{ type: "text" }]).result;
  assert.equal(malformed.stopReason, "error");
  const { text, result } = await collect(session.prompt("hello again"));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "echo: hello again");
  await agent.close();
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

test("a tool that stops being idempotent changes the tools a checkpoint names", async () => {
  const durability = await durabilityFor();
  const first = createFxAgent(agentOptions(durability));
  const session = first.session();
  assert.equal((await session.prompt("hello").result).stopReason, "end_turn");
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
  assert.equal((await session.prompt("hello").result).stopReason, "end_turn");
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
