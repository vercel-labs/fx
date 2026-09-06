#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-request-context.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const requestMethods = [];
const requestBodies = [];
const requestHeaders = [];
const sdkEvents = [];
let nativeCatalogRequests = 0;
const encoded = new TextEncoder();
const decoder = new TextDecoder();

const catalogServer = createServer((request, response) => {
  nativeCatalogRequests += 1;
  request.resume();
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({
    object: "list",
    data: [{ id: "request-context/model", type: "language" }],
  }));
});
await new Promise((resolveListen) => catalogServer.listen(0, "127.0.0.1", resolveListen));
const previousCatalogBaseUrl = process.env.FX_GATEWAY_BASE_URL;
process.env.FX_GATEWAY_BASE_URL = `http://127.0.0.1:${catalogServer.address().port}`;

const gatewayFetch = async (_url, init = {}) => {
  const method = init.method ?? "GET";
  requestMethods.push(method);
  if (method === "GET") {
    return Response.json({
      object: "list",
      data: [{ id: "request-context/model", type: "language" }],
    });
  }

  requestHeaders.push(new Headers(init.headers));
  requestBodies.push(JSON.parse(
    typeof init.body === "string" ? init.body : decoder.decode(init.body),
  ));
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "x-vercel-id": "iad1::request-context",
      "x-generation-id": "generation-context",
      "x-model-id": "request-context/model",
      "x-vercel-ai-gateway-provider": "fixture-provider",
    },
  });
};

const backendOptions = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
};

async function capture(instructions, prompt) {
  const agent = await createFxAgent({
    ...backendOptions,
    fetch: gatewayFetch,
    onEvent(event) { sdkEvents.push(event); },
    apiKey: "request-context-key",
    model: "request-context/model",
    ...(instructions === undefined ? {} : { instructions }),
  });
  try {
    const turn = agent.prompt(prompt);
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, "end_turn");
  } finally {
    await agent.close();
  }
}

function systemText(payload) {
  const messages = payload.prompt ?? payload.messages;
  assert.ok(Array.isArray(messages), "Gateway request must contain prompt messages");
  return messages
    .filter((message) => message.role === "system")
    .map((message) => message.content);
}

try {
  await capture(undefined, "NO_INSTRUCTIONS_REQUEST");
  await capture("HOST_INSTRUCTIONS_ONLY", "HOST_INSTRUCTIONS_REQUEST");

  assert.deepEqual(requestMethods, ["GET", "POST", "GET", "POST"], "each agent must resolve model metadata through host fetch before sending");
  assert.equal(nativeCatalogRequests, 0, "model metadata must not bypass host fetch through native HTTP");
  assert.equal(requestBodies.length, 2);
  const transportStarts = sdkEvents.filter((event) => event.type === "transport.start");
  const transportResponses = sdkEvents.filter((event) => event.type === "transport.response");
  assert.deepEqual(transportStarts.map((event) => [event.method, event.attempt]), [["GET", 1], ["POST", 2], ["GET", 1], ["POST", 2]]);
  assert.deepEqual(transportResponses.map((event) => event.attempt), [1, 2, 1, 2]);
  for (const event of transportStarts) {
    assert.equal(event.endpoint, event.method === "GET"
      ? "https://ai-gateway.vercel.sh/coding-agent/v1/models"
      : "https://ai-gateway.vercel.sh/v3/ai/language-model");
    assert.equal(event.model, "request-context/model");
  }
  for (const event of transportResponses) {
    assert.equal(event.status, 200);
    assert.ok(event.elapsedMs >= 0);
    assert.equal(event.requestId, event.attempt === 1 ? null : "iad1::request-context");
    assert.equal(event.generationId, event.attempt === 1 ? null : "generation-context");
    assert.equal(event.model, "request-context/model");
    assert.equal(event.provider, event.attempt === 1 ? null : "fixture-provider");
  }
  assert.doesNotMatch(JSON.stringify(sdkEvents), /request-context-key/, "transport diagnostics must not expose credentials");
  for (const headers of requestHeaders) {
    assert.equal(headers.has("x-vercel-gateway-extended-time"), false, "libfx must not opt into extended Gateway execution time");
    assert.ok(headers.get("x-session-id"), "libfx must retain its session identity header");
    assert.equal(headers.get("x-session-affinity"), headers.get("x-session-id"), "libfx must retain Gateway session affinity");
  }
  assert.deepEqual(systemText(requestBodies[0]), [], "omitted instructions must not add hidden system context");
  assert.deepEqual(systemText(requestBodies[1]), ["HOST_INSTRUCTIONS_ONLY"], "host instructions must be the complete system context");
  assert.match(JSON.stringify(requestBodies[0]), /NO_INSTRUCTIONS_REQUEST/);
  assert.match(JSON.stringify(requestBodies[1]), /HOST_INSTRUCTIONS_REQUEST/);

  console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Agent request context passed`);
} finally {
  if (previousCatalogBaseUrl === undefined) delete process.env.FX_GATEWAY_BASE_URL;
  else process.env.FX_GATEWAY_BASE_URL = previousCatalogBaseUrl;
  catalogServer.closeAllConnections();
  await new Promise((resolveClose) => catalogServer.close(resolveClose));
}
