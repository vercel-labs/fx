#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, memory, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-summary-signed-replay.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

// Claude signs its reasoning for the exact messages it was written after. When
// fx writes its own summary, the summary replaces those messages, so no turn
// that holds Claude's signed reasoning may stay after it unchanged.
// Claude 4.6 and later binds its reasoning. fx gives this one a context window
// of 200,000 tokens, so a few large replies fill it.
const model = "anthropic/claude-opus-5.1";
const catalog = { object: "list", data: [{ id: model, type: "language", tags: ["tool-use", "reasoning"], context_window: 200_000, max_tokens: 8192 }] };
const encoded = new TextEncoder();
const signature = /SIG_[A-Za-z0-9_]+/g;

function sse(events) {
  return new Response(new ReadableStream({
    start(controller) {
      for (const event of events) controller.enqueue(encoded.encode(`data: ${JSON.stringify(event)}\n\n`));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
}

// A message as the provider compares it, without the cache markers that move
// from one request to the next.
function withoutOptions(value) {
  if (Array.isArray(value)) return value.map(withoutOptions);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).filter(([name]) => name !== "providerOptions").map(([name, inner]) => [name, withoutOptions(inner)]));
}

function mockGateway() {
  const requests = [];
  const prefixes = new Map();
  const refused = [];
  let turn = 0;
  const fetch = async (_url, init = {}) => {
    if (String(init.method ?? "GET").toUpperCase() === "GET") return Response.json(catalog);
    const text = new TextDecoder().decode(init.body);
    const body = JSON.parse(text);
    const summary = text.includes("You write compaction notes");
    // Each request records the replies Claude had signed when it was sent.
    requests.push({ summary, compacted: !summary && text.includes("<compacted_conversation>"), signedBefore: turn, body });
    const usage = { inputTokens: { total: Math.ceil(text.length / 4) }, outputTokens: { total: 5 } };
    if (summary) {
      return sse([
        { type: "text-delta", id: "summary", delta: "Facts:\n- F1: the user asked for six numbered turns." },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
      ]);
    }
    // Claude refuses a signed block sent after other messages than the ones
    // it was written after.
    for (const [index, message] of body.prompt.entries()) {
      for (const name of JSON.stringify(message).match(signature) ?? []) {
        const prefix = JSON.stringify(withoutOptions(body.prompt.slice(0, index)));
        if (!prefixes.has(name)) prefixes.set(name, prefix);
        else if (prefixes.get(name) !== prefix) {
          refused.push(`request ${requests.length}: ${name} at prompt.${index}`);
          return Response.json({ error: { type: "invalid_request_error", message: `messages.${index}: Invalid signature in thinking block` } }, { status: 400 });
        }
      }
    }
    turn += 1;
    const id = `reasoning_${turn}`;
    return sse([
      { type: "reasoning-start", id },
      { type: "reasoning-delta", id, delta: `Thinking about turn ${turn}.` },
      { type: "reasoning-end", id, providerMetadata: { anthropic: { signature: `SIG_s${turn}` } } },
      { type: "text-delta", id: "answer", delta: `Turn ${turn} done.\n${"alpha beta gamma delta sample line\n".repeat(600)}` },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ]);
  };
  return { requests, refused, fetch };
}

const backendOptions = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
};

const gateway = mockGateway();
const agent = createFxAgent({
  ...backendOptions,
  durability: memory(),
  model,
  apiKey: "sdk-summary-signed-replay-test-key",
  fetch: gateway.fetch,
  instructions: "Answer in one line.",
});
const results = [];
try {
  let sessionId;
  for (let turn = 1; turn <= 48 && !gateway.requests.some((request) => request.compacted); turn += 1) {
    const prompt = agent.session(sessionId).prompt(`TURN ${turn} Continue.`);
    sessionId = (await prompt.accepted).sessionId;
    for await (const _ of prompt) {}
    results.push((await prompt.result).stopReason);
  }
  // The next Claude turn after fx's summary.
  const prompt = agent.session(sessionId).prompt("TURN AFTER Continue.");
  for await (const _ of prompt) {}
  results.push((await prompt.result).stopReason);
} catch (error) {
  results.push(`error: ${error?.message ?? error}`);
} finally {
  await agent.close();
}

const after = gateway.requests.filter((request) => request.compacted);
assert.ok(after.length >= 2, `two Claude requests follow fx's summary: ${gateway.requests.length} requests, ${after.length} after it`);
for (const [index, request] of after.entries()) {
  const conversation = request.body.prompt.filter((message) => message.role !== "system");
  assert.ok(JSON.stringify(conversation[0]).includes("<compacted_conversation>"), `request ${index + 1} after the summary starts with it`);
  const kept = conversation.slice(1).flatMap((message) => JSON.stringify(message).match(signature) ?? []);
  const signedBeforeSummary = (name) => Number(name.slice("SIG_s".length)) <= after[0].signedBefore;
  assert.deepEqual(kept.filter(signedBeforeSummary), [], `request ${index + 1} after the summary sends no turn Claude signed before it`);
}
assert.deepEqual(gateway.refused, [], "Claude accepts every request");
assert.deepEqual(results, results.map(() => "end_turn"), "every turn ends");

console.log(`libfx fx summary keeps no signed turn (${backend}) passed`);
