#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-fast.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
const catalog = {
  object: "list",
  data: [
    { id: "sdk/fast-model", type: "language", fast_options: [{ type: "toggle" }] },
    { id: "sdk/intrinsic-model-fast", type: "language" },
    { id: "sdk/plain-model", type: "language" },
  ],
};

function mockGateway() {
  const state = { catalogFetches: 0, chatBodies: [] };
  const fetch = async (url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      state.catalogFetches += 1;
      return Response.json(catalog);
    }
    state.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch };
}

const baseOptions = {
  backend,
  apiKey: "sdk-fast-test-key",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
};
const createAgent = (gateway, overrides) =>
  createFxEngine({ ...baseOptions, fetch: gateway.fetch, ...overrides });

async function runPrompt(agent) {
  const turn = agent.prompt("say ok");
  for await (const _ of turn) {}
  return turn.result;
}

// A model with an advertised fast path accepts fast and sends it on the wire.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: { id: "sdk/fast-model", fast: true } });
  assert.equal(gateway.state.catalogFetches, 1);
  const result = await runPrompt(agent);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 1);
  assert.equal(gateway.state.chatBodies[0].providerOptions?.gateway?.speed, "fast");
  await agent.close();
}

// An intrinsically fast model already satisfies fast: true.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/intrinsic-model-fast", fast: true });
  assert.equal(gateway.state.catalogFetches, 1);
  const result = await runPrompt(agent);
  assert.equal(result.stopReason, "end_turn");
  await agent.close();
}

// A model without a fast path rejects fast: true and names the model.
{
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { model: "sdk/plain-model", fast: true }),
    (error) => {
      assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_FAST");
      assert.equal(error.model, "sdk/plain-model");
      assert.equal(error.capability, "fast");
      assert.match(error.message, /Fast mode is not available/);
      assert.match(error.message, /sdk\/plain-model/);
      return true;
    },
  );
  assert.equal(gateway.state.catalogFetches, 1);
}

// An unsupported model option in auto mode is a product error, not a reason
// to retry creation on another backend.
if (backend === "native") {
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { backend: "auto", model: { id: "sdk/plain-model", fast: true } }),
    (error) => error.code === "LIBFX_MODEL_UNSUPPORTED_FAST" && error.model === "sdk/plain-model",
  );
  assert.equal(gateway.state.catalogFetches, 1);
}

// Non-boolean fast values are rejected before any runtime or network work.
{
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { model: "sdk/fast-model", fast: "yes" }),
    (error) => error instanceof TypeError && /fast must be a boolean/.test(error.message),
  );
  await assert.rejects(
    createAgent(gateway, { model: "sdk/fast-model", fast: 1 }),
    (error) => error instanceof TypeError && /fast must be a boolean/.test(error.message),
  );
  assert.equal(gateway.state.catalogFetches, 0);
  assert.equal(gateway.state.chatBodies.length, 0);
}

// Disabling fast needs no validation fetch and sends no speed key.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/fast-model", fast: false });
  assert.equal(gateway.state.catalogFetches, 0);
  await runPrompt(agent);
  assert.equal(gateway.state.chatBodies[0].providerOptions?.gateway?.speed, undefined);
  await agent.close();
}

// Without the option, creation and prompts behave exactly as before.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/fast-model" });
  assert.equal(gateway.state.catalogFetches, 0);
  await runPrompt(agent);
  assert.equal(gateway.state.chatBodies[0].providerOptions?.gateway?.speed, undefined);
  await agent.close();
}

console.log(`${backend} agent fast support passed`);
