#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-ultrafast-options.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
const supportedModel = "openai/gpt-6-astra";
const unsupportedModel = "openai/gpt-6-plain";
const solModel = "openai/gpt-5.6-sol";
const defaultModel = "spacexai/grok-4.7";
const catalog = {
  object: "list",
  data: [
    {
      id: supportedModel,
      type: "language",
      owned_by: "openai",
      pricing: {
        service_tiers: {
          ultrafast: { input: 0.00006, output: 0.0003 },
        },
      },
    },
    // The capability must stay OpenAI-only even if another catalog entry
    // advertises a positively priced tier with the same name.
    {
      id: "anthropic/gpt-6-astra",
      type: "language",
      owned_by: "anthropic",
      pricing: {
        service_tiers: {
          ultrafast: { input: 0.00006, output: 0.0003 },
        },
      },
    },
    { id: unsupportedModel, type: "language", owned_by: "openai" },
    {
      id: solModel,
      type: "language",
      owned_by: "openai",
      fast_options: [{ type: "toggle" }],
      pricing: {
        input_cache_read: "0.000001",
        service_tiers: {
          ultrafast: { input: "0.00006", output: "0.0003", input_cache_read: "0.000006" },
        },
      },
    },
    { id: defaultModel, type: "language", owned_by: "spacexai" },
  ],
};

function mockGateway(providerMetadata = { gateway: { serviceTier: "ultrafast", cost: "0.00036" } }) {
  const state = { catalogFetches: 0, chatBodies: [], chatModels: [] };
  const finish = {
    type: "finish",
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 3 }, outputTokens: { total: 2 } },
    ...(providerMetadata === null ? {} : { providerMetadata }),
  };
  const fetch = async (_url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      state.catalogFetches += 1;
      return Response.json(catalog);
    }
    state.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    state.chatModels.push(new Headers(init.headers).get("ai-language-model-id"));
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode(`data: ${JSON.stringify(finish)}\n\n`));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch };
}

async function runPrompt(agent, input = "say ok", expectedText = "ok") {
  const turn = agent.prompt(input);
  let text = "";
  for await (const event of turn) {
    if (event.type === "text_delta") text += event.delta;
  }
  assert.equal(text, expectedText);
  return turn.result;
}

function assertUltrafastRoute(body) {
  assert.equal(body.providerOptions?.openai?.serviceTier, "ultrafast");
  assert.deepEqual(body.providerOptions?.gateway?.only, ["openai"]);
  assert.equal(body.providerOptions?.gateway?.speed, undefined);
  assert.equal(body.providerOptions?.gateway?.fast, undefined);
}

function configOption(events, id) {
  for (const event of events) {
    const options = event.message?.result?.configOptions;
    const option = options?.find((candidate) => candidate.id === id);
    if (option) return option;
  }
  return null;
}

const home = await mkdtemp(join(tmpdir(), "libfx-ultrafast-"));
const previousHome = process.env.HOME;
try {
  process.env.HOME = home;
  const baseOptions = {
    backend,
    apiKey: "sdk-ultrafast-test-key",
    home,
    workspaceRoot: home,
    ...(backend === "native"
      ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
      : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
  };
  const createAgent = (gateway, overrides, events = []) =>
    createFxAgent({
      ...baseOptions,
      fetch: gateway.fetch,
      onEvent(event) {
        events.push(event);
      },
      ...overrides,
    });
  const withAgent = async (gateway, overrides, exercise, events = []) => {
    const agent = await createAgent(gateway, overrides, events);
    try {
      await exercise(agent);
    } finally {
      await agent.close();
    }
    assert.deepEqual(events.filter((event) => event.type === "runtime.exit").map((event) => event.code), [0]);
  };
  const assertCreationRejects = async (gateway, overrides, expected, events = []) => {
    let agent;
    try {
      await assert.rejects(async () => {
        agent = await createAgent(gateway, overrides, events);
      }, expected);
    } finally {
      await agent?.close();
    }
  };

  // A catalog-verified OpenAI ultrafast model creates a session, advertises
  // the ACP config option, and serializes the exclusive ultrafast provider route.
  {
    const gateway = mockGateway();
    const events = [];
    await withAgent(gateway, {
      model: { id: supportedModel, ultrafast: true },
    }, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 1);
      const option = configOption(events, "ultrafast");
      assert.equal(option?.currentValue, "true");
      assert.deepEqual(option?.options?.map((entry) => entry.value), ["false", "true"]);

      const result = await runPrompt(agent);
      assert.equal(result.stopReason, "end_turn");
      assert.equal(gateway.state.chatBodies.length, 1);
      const providerOptions = gateway.state.chatBodies[0].providerOptions;
      assert.equal(providerOptions?.openai?.serviceTier, "ultrafast");
      assert.deepEqual(providerOptions?.gateway?.only, ["openai"]);
      assert.equal(providerOptions?.gateway?.speed, undefined);
      assert.equal(providerOptions?.gateway?.fast, undefined);
    }, events);
  }

  // Unsupported catalog models reject during creation and never send a prompt.
  {
    const gateway = mockGateway();
    const events = [];
    await assertCreationRejects(
      gateway,
      { model: { id: unsupportedModel, ultrafast: true } },
      (error) => {
        assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST");
        assert.equal(error.model, unsupportedModel);
        assert.equal(error.capability, "ultrafast");
        assert.match(error.message, /Ultrafast mode is not available/);
        return true;
      },
      events,
    );
    assert.equal(gateway.state.catalogFetches, 1);
    assert.equal(gateway.state.chatBodies.length, 0);
    assert.deepEqual(events.filter((event) => event.type === "runtime.exit").map((event) => event.code), [0]);
  }

  // Explicit false preserves the ordinary route and does not send ultrafast
  // or fast provider options.
  {
    const gateway = mockGateway();
    await withAgent(gateway, {
      model: { id: supportedModel, ultrafast: false },
    }, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 0);
      const result = await runPrompt(agent);
      assert.equal(result.stopReason, "end_turn");
      const providerOptions = gateway.state.chatBodies[0].providerOptions;
      assert.equal(providerOptions?.openai?.serviceTier, undefined);
      assert.equal(providerOptions?.gateway?.speed, undefined);
      assert.equal(providerOptions?.gateway?.only, undefined);
      assert.equal(providerOptions?.gateway?.fast, undefined);
    });
  }

  // A string model accepts the top-level option.
  {
    const gateway = mockGateway();
    await withAgent(gateway, { model: supportedModel, ultrafast: true }, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 1);
      assert.equal((await runPrompt(agent)).stopReason, "end_turn");
      assert.equal(gateway.state.chatBodies.length, 1);
      assertUltrafastRoute(gateway.state.chatBodies[0]);
    });
  }

  // False works with a string or omitted model without a creation-time fetch.
  for (const overrides of [
    { model: supportedModel, ultrafast: false },
    { ultrafast: false },
  ]) {
    const gateway = mockGateway();
    await withAgent(gateway, overrides, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 0);
      assert.equal((await runPrompt(agent)).stopReason, "end_turn");
      assert.equal(gateway.state.chatBodies.length, 1);
      const body = gateway.state.chatBodies[0];
      assert.deepEqual(gateway.state.chatModels, [overrides.model ?? defaultModel]);
      assert.equal(body.providerOptions?.openai?.serviceTier, undefined);
      assert.equal(body.providerOptions?.gateway?.speed, undefined);
      assert.equal(body.providerOptions?.gateway?.only, undefined);
      assert.equal(body.providerOptions?.gateway?.fast, undefined);
    });
  }

  // Omitted model means the kernel default, not automatic Ultra model selection.
  // Neither an unsupported OpenAI model nor a priced non-OpenAI model can opt in.
  for (const [overrides, model] of [
    [{ ultrafast: true }, defaultModel],
    [{ model: "anthropic/gpt-6-astra", ultrafast: true }, "anthropic/gpt-6-astra"],
  ]) {
    const gateway = mockGateway();
    const events = [];
    await assertCreationRejects(gateway, overrides, (error) => {
      assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST");
      assert.equal(error.model, model);
      assert.equal(error.capability, "ultrafast");
      assert.match(error.message, /Ultrafast mode is not available/);
      return true;
    }, events);
    assert.equal(gateway.state.catalogFetches, 1);
    assert.equal(gateway.state.chatBodies.length, 0);
    assert.deepEqual(events.filter((event) => event.type === "runtime.exit").map((event) => event.code), [0]);
  }

  // Validation is strict on both option shapes and precedes runtime/transport.
  for (const overrides of [
    { model: supportedModel, ultrafast: 1 },
    { model: { id: supportedModel, ultrafast: "true" } },
  ]) {
    const gateway = mockGateway();
    const events = [];
    await assertCreationRejects(gateway, overrides, {
      name: "TypeError",
      message: "ultrafast must be a boolean",
    }, events);
    assert.equal(gateway.state.catalogFetches, 0);
    assert.equal(gateway.state.chatBodies.length, 0);
    assert.deepEqual(events, []);
  }

  // Even false or an explicitly present undefined cannot mix a model object
  // with top-level mode options; no precedence rule is invented for this shape.
  for (const overrides of [
    { model: { id: supportedModel }, ultrafast: true },
    { model: { id: supportedModel, ultrafast: true }, ultrafast: false },
    { model: { id: supportedModel }, ultrafast: undefined },
  ]) {
    const gateway = mockGateway();
    const events = [];
    await assertCreationRejects(gateway, overrides, {
      name: "TypeError",
      message: "model options cannot be mixed with top-level effort, fast, or ultrafast",
    }, events);
    assert.equal(gateway.state.catalogFetches, 0);
    assert.equal(gateway.state.chatBodies.length, 0);
    assert.deepEqual(events, []);
  }

  // Sol is eligible because its catalog has positive Ultra prices, including
  // cache reads, not because of its name or an Astra-only allowlist.
  {
    const gateway = mockGateway();
    const events = [];
    await withAgent(gateway, { model: { id: solModel, ultrafast: true } }, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 1);
      assert.equal(configOption(events, "ultrafast")?.currentValue, "true");
      assert.equal((await runPrompt(agent)).stopReason, "end_turn");
      assert.equal(gateway.state.chatBodies.length, 1);
      assert.deepEqual(gateway.state.chatModels, [solModel]);
      assertUltrafastRoute(gateway.state.chatBodies[0]);
    }, events);
  }

  // Unconfirmed serving appends a warning to the streamed text.
  {
    const gateway = mockGateway(null);
    await withAgent(gateway, { model: supportedModel, ultrafast: true }, async (agent) => {
      await runPrompt(
        agent,
        "say ok",
        "okUltrafast was requested, but Gateway did not confirm it was served; this response may have used a standard or lower tier.\n",
      );
      assert.equal(gateway.state.chatBodies.length, 1);
      assertUltrafastRoute(gateway.state.chatBodies[0]);
    });
  }

  // Both modes validate independently at creation. For a model supporting
  // both, Ultra wins on the wire; disabling Ultra leaves explicit Fast intact.
  for (const ultrafast of [true, false]) {
    const gateway = mockGateway();
    await withAgent(gateway, { model: { id: solModel, fast: true, ultrafast } }, async (agent) => {
      assert.equal(gateway.state.catalogFetches, 1);
      assert.equal((await runPrompt(agent)).stopReason, "end_turn");
      assert.equal(gateway.state.chatBodies.length, 1);
      const body = gateway.state.chatBodies[0];
      if (ultrafast) {
        assertUltrafastRoute(body);
      } else {
        assert.equal(body.providerOptions?.gateway?.speed, "fast");
        assert.equal(body.providerOptions?.gateway?.only, undefined);
        assert.equal(body.providerOptions?.openai?.serviceTier, undefined);
        assert.equal(body.providerOptions?.gateway?.fast, undefined);
      }
    });
  }
  {
    const gateway = mockGateway();
    await assertCreationRejects(gateway, {
      model: { id: supportedModel, fast: true, ultrafast: true },
    }, (error) => {
      assert.equal(error.code, "LIBFX_MODEL_UNSUPPORTED_FAST");
      assert.equal(error.model, supportedModel);
      assert.equal(error.capability, "fast");
      assert.match(error.message, /Fast mode is not available/);
      return true;
    });
    assert.equal(gateway.state.catalogFetches, 1);
    assert.equal(gateway.state.chatBodies.length, 0);
  }
} finally {
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  await rm(home, { recursive: true, force: true });
}

console.log(`${backend} agent ultrafast support passed`);
