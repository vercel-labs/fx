#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-effort.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
const catalog = {
  object: "list",
  data: [
    {
      id: "sdk/core-model",
      type: "language",
      tags: ["reasoning"],
      reasoning_options: [{ type: "effort", values: ["low", "high"] }],
    },
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
  apiKey: "sdk-effort-test-key",
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

// An advertised effort is validated at creation and applied to the turn request.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: { id: "sdk/core-model", effort: "high" } });
  assert.equal(gateway.state.catalogFetches, 1);
  const result = await runPrompt(agent);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 1);
  assert.equal(gateway.state.chatBodies[0].reasoning, "high");
  await agent.close();
}

// An effort the model does not advertise rejects with the supported set.
{
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { model: "sdk/core-model", effort: "max" }),
    (error) => {
      assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_EFFORT");
      assert.equal(error.model, "sdk/core-model");
      assert.equal(error.capability, "effort");
      assert.match(error.message, /"max"/);
      assert.match(error.message, /sdk\/core-model/);
      assert.match(error.message, /low, high/);
      return true;
    },
  );
  assert.equal(gateway.state.catalogFetches, 1);
}

// A model without reasoning effort options rejects any named effort.
{
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { model: "sdk/plain-model", effort: "high" }),
    (error) => {
      assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_EFFORT");
      assert.equal(error.model, "sdk/plain-model");
      assert.equal(error.capability, "effort");
      assert.match(error.message, /unavailable for the active model/);
      return true;
    },
  );
  assert.equal(gateway.state.catalogFetches, 1);
}

// Malformed effort values are rejected before any runtime or network work.
{
  const gateway = mockGateway();
  await assert.rejects(
    createAgent(gateway, { model: "sdk/core-model", effort: "turbo!" }),
    (error) => error instanceof TypeError && /letters, digits/.test(error.message),
  );
  await assert.rejects(
    createAgent(gateway, { model: "sdk/core-model", effort: 5 }),
    (error) => error instanceof TypeError && /effort/.test(error.message),
  );
  await assert.rejects(
    createAgent(gateway, { model: "sdk/core-model", effort: "x".repeat(65) }),
    (error) => error instanceof RangeError,
  );
  assert.equal(gateway.state.catalogFetches, 0);
  assert.equal(gateway.state.chatBodies.length, 0);
}

// Model-object options must not silently override legacy top-level settings.
{
  const gateway = mockGateway();
  for (const options of [
    { model: { id: "sdk/core-model", effort: "high" }, effort: "low" },
    { model: { id: "sdk/core-model", fast: true }, fast: false },
  ]) {
    await assert.rejects(createAgent(gateway, options), /model options cannot be mixed/);
  }
  await assert.rejects(createAgent(gateway, { model: { effort: "low" } }), /model.id/);
  await assert.rejects(createAgent(gateway, { model: { id: "sdk/core-model", efffort: "high" } }), /unsupported model option: efffort/);
  await assert.rejects(
    createAgent(gateway, {
      backend: "auto",
      wasm: resolve(scriptDir, "missing-model-validation.wasm"),
      model: { id: "sdk/core-model", effort: "high" },
      effort: "low",
    }),
    (error) => error instanceof TypeError && /model options cannot be mixed/.test(error.message),
  );
  assert.equal(gateway.state.catalogFetches, 0);
}

// The model default needs no validation fetch and sends no reasoning field.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/core-model", effort: "default" });
  assert.equal(gateway.state.catalogFetches, 0);
  await runPrompt(agent);
  assert.equal(gateway.state.chatBodies[0].reasoning, undefined);
  await agent.close();
}

// Without the option, creation and prompts behave exactly as before.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/core-model" });
  assert.equal(gateway.state.catalogFetches, 0);
  await runPrompt(agent);
  assert.equal(gateway.state.chatBodies[0].reasoning, undefined);
  await agent.close();
}

console.log(`${backend} agent effort support passed`);
