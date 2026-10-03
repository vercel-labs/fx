#!/usr/bin/env node
// The host tool contract: tools as an object, replay and writes
// declarations, non-empty error results, and calls that run together until a
// writer, with results in the model's order.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createMemoryJournal } from "../node.js";

const backend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

// The prompt names the calls of the first response: "call a b c" calls the
// tools a, b and c in that order. The next request is answered with text.
const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const requests = [];
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "contract/model", type: "language" }] }));
      return;
    }
    const prompt = JSON.parse(body).prompt;
    requests.push(prompt);
    const words = textOf(prompt.filter((message) => message.role === "user").at(-1)).split(/\s+/);
    const frames = words[0] === "call" && toolResults(prompt).length === 0
      ? [
        ...words.slice(1).map((name, index) => ({ type: "tool-call", toolCallId: `call-${index}`, toolName: name, input: {} })),
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
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  const method = String(init?.method ?? input?.method ?? "GET").toUpperCase();
  if (url.hostname === "ai-gateway.vercel.sh" && method === "GET") {
    return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  }
  return fetch(input, init);
};
const options = (tools, extra = {}) => ({
  backend,
  nativeAddon: addon,
  ...(backend === "wasm" ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "contract-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "contract/model",
  tools,
  ...extra,
});

async function run(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

// A tool that records when each of its calls ran.
const spans = [];
const timed = (name, extra = {}) => ({
  description: `Records when ${name} runs.`,
  inputSchema: { type: "object" },
  ...extra,
  execute: async () => {
    const span = { name, start: performance.now(), end: null };
    spans.push(span);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 40));
    span.end = performance.now();
    return `${name} ok`;
  },
});

const cases = [];
const test = (name, body) => cases.push({ name, body });

test("tools may be an object keyed by name", async () => {
  const agent = await createFxAgent(options({ list: timed("list"), read: timed("read") }));
  requests.length = 0;
  spans.length = 0;
  assert.equal((await run(agent, "call list read")).stopReason, "end_turn");
  await agent.close();
  assert.deepEqual(spans.map((span) => span.name).sort(), ["list", "read"]);
  await assert.rejects(createFxAgent(options({ list: { ...timed("list"), name: "other" } })), /tool list has a different name: other/);
});

test("calls run together until a writer, and results keep the model's order", async () => {
  const agent = await createFxAgent(options({
    first: timed("first"),
    second: timed("second"),
    save: timed("save", { writes: true }),
    after: timed("after"),
  }));
  requests.length = 0;
  spans.length = 0;
  await run(agent, "call first second save after");
  await agent.close();
  const span = Object.fromEntries(spans.map((value) => [value.name, value]));
  const overlap = (a, b) => a.start < b.end && b.start < a.end;
  if (backend === "native") {
    assert.ok(overlap(span.first, span.second), "calls before a writer run together");
  } else {
    assert.ok(!overlap(span.first, span.second), "a build without threads runs calls one at a time");
  }
  // The writer starts after every earlier call ends, and nothing passes it.
  assert.ok(span.save.start >= Math.max(span.first.end, span.second.end));
  assert.ok(span.after.start >= span.save.end);
  const results = toolResults(requests.at(-1)).map((part) => part.toolName);
  assert.deepEqual(results, ["first", "second", "save", "after"]);
});

test("execute receives the model's call id", async () => {
  const seen = [];
  const probe = {
    description: "Records its context.",
    inputSchema: { type: "object" },
    execute: async (_input, context) => {
      seen.push({ toolCallId: context.toolCallId, aborted: context.signal.aborted });
      return "probed";
    },
  };
  const agent = await createFxAgent(options({ probe }));
  await run(agent, "call probe probe");
  await agent.close();
  assert.deepEqual(seen.map((entry) => entry.toolCallId).sort(), ["call-0", "call-1"]);
  assert.ok(seen.every((entry) => entry.aborted === false));
});

test("an error without a message still reaches the model as text", async () => {
  const agent = await createFxAgent(options({
    broken: { description: "Fails.", inputSchema: { type: "object" }, execute: async () => { throw new Error(""); } },
  }));
  requests.length = 0;
  await run(agent, "call broken");
  await agent.close();
  const [result] = toolResults(requests.at(-1));
  const text = JSON.stringify(result.output ?? result);
  assert.match(text, /Tool broken failed without a message/);
});

test("replay and writes are checked, and a journal requires replay", async () => {
  await assert.rejects(createFxAgent(options({ read: timed("read", { replay: "sometimes" }) })), /tool read replay must be "safe" or "never"/);
  await assert.rejects(createFxAgent(options({ read: timed("read", { writes: "yes" }) })), /tool read writes must be a boolean/);
  await assert.rejects(
    createFxAgent(options({ read: timed("read") }, { journal: createMemoryJournal() })),
    /tool read needs replay: "safe" or "never" when a journal is set/,
  );
  const agent = await createFxAgent(options({ read: timed("read", { replay: "safe" }) }, { journal: createMemoryJournal() }));
  await agent.close();
});

try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`tool contract passed: ${backend}`);
} finally {
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
