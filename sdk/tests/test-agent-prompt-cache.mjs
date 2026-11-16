#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, memory, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-prompt-cache.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
// Each model family asks for caching in its own syntax, as the fx CLI does.
const families = [
  { model: "anthropic/claude-sonnet-5.5", marker: '"cacheControl"' },
  { model: "openai/gpt-5.6-luna", marker: '"promptCacheBreakpoint"' },
  { model: "amazon/nova-pro", marker: '"cachePoint"' },
];
const catalog = { object: "list", data: families.map(({ model }) => ({ id: model, type: "language" })) };

function mockGateway() {
  const chatBodies = [];
  const fetch = async (_url, init = {}) => {
    if (String(init.method ?? "GET").toUpperCase() === "GET") return Response.json(catalog);
    chatBodies.push(new TextDecoder().decode(init.body));
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":1}}}\n\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { chatBodies, fetch };
}

const backendOptions = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
};

// The messages a request sends, without the cache markers on them, so a marker
// that moves to a later message does not count as a changed message.
function messagesWithoutMarkers(body) {
  const strip = (value) => {
    if (Array.isArray(value)) return value.map(strip);
    if (value === null || typeof value !== "object") return value;
    return Object.fromEntries(Object.entries(value).filter(([name]) => name !== "providerOptions").map(([name, inner]) => [name, strip(inner)]));
  };
  return strip(JSON.parse(body).prompt);
}

for (const { model, marker } of families) {
  const gateway = mockGateway();
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    model,
    apiKey: "sdk-prompt-cache-test-key",
    fetch: gateway.fetch,
    instructions: "Answer in one word.",
  });
  try {
    let sessionId;
    for (const prompt of ["say ok", "say ok again"]) {
      const turn = agent.session(sessionId).prompt(prompt);
      sessionId = (await turn.accepted).sessionId;
      for await (const _ of turn) {}
      assert.equal((await turn.result).stopReason, "end_turn");
    }
  } finally {
    await agent.close();
  }

  assert.equal(gateway.chatBodies.length, 2, `${model}: one request per turn`);
  for (const [index, body] of gateway.chatBodies.entries()) {
    assert.equal(JSON.parse(body).providerOptions?.gateway?.caching, "auto", `${model} request ${index + 1} asks AI Gateway to cache`);
    assert.ok(body.includes(marker), `${model} request ${index + 1} marks its stable start with ${marker}`);
  }
  // The second turn's request starts with the first turn's, so the cache the
  // first request wrote covers it.
  const [first, second] = gateway.chatBodies.map(messagesWithoutMarkers);
  assert.deepEqual(second.slice(0, first.length), first, `${model}: the second request starts with the first`);
}

console.log(`libfx prompt caching (${backend}) passed`);
