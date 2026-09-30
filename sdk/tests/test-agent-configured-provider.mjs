#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";
import { normalizeAgentOptions } from "../fx-sdk.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-configured-provider.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) throw new Error("WebAssembly backend requires JSPI");
const asset = backend === "native"
  ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
  : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) };
const gatewayOptions = normalizeAgentOptions({
  apiKey: "fixture-gateway-key", providerJson: "not a provider", providerCredential: "fixture", providerEndpoint: "https://wrong.example",
});
assert.equal(gatewayOptions.providerJson, undefined);
assert.equal(gatewayOptions.providerCredential, undefined);
assert.equal(gatewayOptions.providerEndpoint, undefined);
const requests = [];
let hostFetches = 0;
let toolExecutions = 0;
let redirectedRequests = 0;
let holdNextFetch = false;
let fetchAborted = false;
let resolveFetchStarted;

function response(model, text) {
  const events = [
    { id: "custom-1", model, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
    { id: "custom-1", model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
    { id: "custom-1", model, choices: [], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } },
  ];
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
}
function toolResponse(model) {
  const events = [
    { id: "custom-tool", model, choices: [{ index: 0, delta: { tool_calls: [
      { index: 0, id: "call-1", type: "function", function: { name: "lookup", arguments: '{"key":"x"}' } },
    ] }, finish_reason: null }] },
    { id: "custom-tool", model, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ];
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
}
const server = createServer((request, reply) => {
  let raw = "";
  request.on("data", (chunk) => { raw += chunk; });
  request.on("end", () => {
    if (request.url === "/redirect-target") {
      redirectedRequests++;
      reply.writeHead(200); reply.end("redirect reached"); return;
    }
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
      reply.writeHead(404); reply.end("unexpected model endpoint"); return;
    }
    const body = JSON.parse(raw);
    requests.push({
      path: request.url,
      authorization: request.headers.authorization ?? null,
      gatewayHeaders: Boolean(request.headers["ai-gateway-protocol-version"] || request.headers["x-vercel-ai-gateway-team"]),
      body,
    });
    if (body.model === "redirect-model") {
      reply.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/redirect-target` });
      reply.end(); return;
    }
    if (body.model === "reject-model") {
      reply.writeHead(401, { "content-type": "text/plain" });
      reply.end("Invalid token: fixture-provider-key");
      return;
    }
    reply.writeHead(200, { "content-type": "text/event-stream" });
    const toolResult = body.messages.some((message) => message.role === "tool");
    reply.end(body.model === "remote-model" && !toolResult
      ? toolResponse(body.model)
      : response(body.model, toolResult ? "tool complete" : "custom reply"));
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const origin = `http://127.0.0.1:${server.address().port}`;
const local = {
  id: "local", protocol: "openai-chat-completions", baseUrl: `${origin}/v1`,
  auth: { type: "none" },
  modelMetadata: { "local-model": { contextWindow: 32768, maxOutputTokens: 1024, supportsToolUse: true } },
};
const remote = {
  ...local, id: "remote", auth: { type: "bearer", token: "fixture-provider-key" },
  modelMetadata: {
    "remote-model": { contextWindow: 32768, supportsToolUse: true },
    "reject-model": { contextWindow: 32768 },
    "redirect-model": { contextWindow: 32768 },
  },
};
const options = (provider, model, other = {}) => ({
  backend, ...asset, provider, model: { id: model }, ...other,
  fetch(input, init) {
    hostFetches++;
    const url = new URL(input?.url ?? input);
    assert.equal(url.origin, origin, "a configured provider must not request Gateway metadata or chat");
    assert.equal(url.pathname, "/v1/chat/completions");
    assert.equal(init.redirect, "error");
    if (holdNextFetch) {
      holdNextFetch = false;
      resolveFetchStarted();
      return new Promise((_, reject) => init.signal.addEventListener("abort", () => {
        fetchAborted = true;
        reject(new DOMException("Aborted", "AbortError"));
      }, { once: true }));
    }
    return globalThis.fetch(input, init);
  },
});
async function turnText(agent) {
  const turn = agent.prompt("reply using this provider");
  const events = [];
  for await (const event of turn) events.push(event);
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  return { events, text: events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), result };
}

let agent;
try {
  // The unauthenticated connection needs no Gateway credential or catalog request.
  agent = await createFxAgent(options(local, "local-model"));
  assert.equal((await turnText(agent)).text, "custom reply");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].authorization, null);
  assert.equal(requests[0].gatewayHeaders, false);
  assert.equal(requests[0].body.model, "local-model");
  assert.equal(hostFetches, 1);
  const checkpoint = await agent.checkpoint();
  await agent.close();
  agent = await createFxAgent(options(local, "local-model", { checkpoint }));
  assert.equal((await turnText(agent)).text, "custom reply");
  assert.ok(requests[1].body.messages.some((message) => message.role === "assistant" && message.content === "custom reply"));
  await agent.close();
  agent = null;

  agent = await createFxAgent(options(local, "local-model"));
  const fetchStarted = new Promise((resolveStarted) => { resolveFetchStarted = resolveStarted; });
  holdNextFetch = true;
  const cancelled = agent.prompt("cancel this request");
  let startDeadline;
  try {
    await Promise.race([fetchStarted, new Promise((_, reject) => {
      startDeadline = setTimeout(() => reject(new Error("configured fetch did not start")), 2000);
    })]);
  } finally { clearTimeout(startDeadline); }
  cancelled.cancel();
  assert.equal((await cancelled.result).stopReason, "cancelled");
  assert.equal(fetchAborted, true);
  assert.equal((await turnText(agent)).text, "custom reply", "cancellation left the core unusable");
  await agent.close();
  agent = null;

  // A separate bearer connection keeps its credential out of the no-auth route.
  agent = await createFxAgent(options(remote, "remote-model", { tools: [{
    name: "lookup", description: "Look up a value", inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
    async execute({ key }, { signal }) { assert.equal(signal.aborted, false); assert.equal(key, "x"); toolExecutions++; return "lookup-value"; },
  }] }));
  const handled = await turnText(agent);
  assert.equal(handled.text, "tool complete");
  assert.equal(toolExecutions, 1);
  assert.equal(handled.events.find((event) => event.type === "tool_start")?.name, "lookup");
  const remoteRequests = requests.filter((request) => request.body.model === "remote-model");
  assert.equal(remoteRequests.length, 2);
  assert.ok(remoteRequests.every((request) => request.authorization === "Bearer fixture-provider-key" && !request.gatewayHeaders));
  assert.ok(remoteRequests[1].body.messages.some((message) => message.role === "tool" && JSON.stringify(message).includes("lookup-value")));
  await agent.close();
  agent = null;

  agent = await createFxAgent(options(remote, "reject-model"));
  const rejected = agent.prompt("reject this request");
  let refusalText = "";
  for await (const event of rejected) if (event.type === "text_delta") refusalText += event.delta;
  assert.equal((await rejected.result).stopReason, "refused");
  assert.match(refusalText, /HTTP 401/);
  assert.doesNotMatch(refusalText, /fixture-provider-key/);
  await agent.close();
  agent = null;

  agent = await createFxAgent(options(remote, "redirect-model"));
  const redirected = agent.prompt("do not follow this redirect");
  let redirectOutcome;
  try {
    for await (const _ of redirected) {}
    redirectOutcome = await redirected.result;
  } catch (error) { redirectOutcome = error; }
  assert.notEqual(redirectOutcome?.stopReason, "end_turn");
  assert.equal(redirectedRequests, 0, "host fetch followed a credentialed redirect");
  assert.ok(requests.some((request) => request.body.model === "redirect-model"));
  await agent.close();
  agent = null;

  // Invalid configurations must reject before any native/Wasm model request.
  const beforeInvalid = hostFetches;
  for (const [overrides, expected] of [
    [{ apiKey: "fixture-gateway-key" }, /cannot be mixed/],
    [{ gatewayChatUrl: `${origin}/gateway/chat` }, /cannot be mixed/],
    [{ provider: { ...local, baseUrl: "http://example.com/v1" } }, /HTTPS or loopback HTTP/],
    [{ provider: { ...local, baseUrl: "https://user:pass@example.com/v1" } }, /must not contain credentials/],
    [{ provider: { ...local, auth: { type: "none", token: "unexpected" } } }, /not allowed with auth.type none/],
    [{ provider: { ...remote, auth: { type: "bearer", token: "bad token" } } }, /visible ASCII only/],
    [{ provider: { ...local, id: "gateway" } }, /non-reserved connection name/],
    [{ model: undefined }, /model is required and must be a non-empty string/],
    [{ provider: { ...local, protocol: "unsupported" } }, /unsupported provider.protocol/],
    [{ provider: { ...local, unknown: true } }, /unsupported provider option/],
    [{ provider: { ...local, modelMetadata: { "local-model": { supportsToolUse: "yes" } } } }, /supportsToolUse must be a boolean/],
    [{ provider: { ...local, modelMetadata: null } }, /provider.modelMetadata must be an object/],
    [{ tools: [{ name: "web_search", providerExecuted: true }] }, /available only with Vercel AI Gateway/],
  ]) {
    await assert.rejects(createFxAgent(options(local, "local-model", overrides)), expected);
  }
  await assert.rejects(createFxAgent(options(local, "local-model", { model: { id: "local-model", fast: true } })),
    (error) => error.code === "LIBFX_MODEL_UNSUPPORTED_FAST" && error.capability === "fast");
  assert.equal(hostFetches, beforeInvalid);

  agent = await createFxAgent(options(local, "local-model", {
    backend: "auto",
    ...(backend === "wasm" ? { nativeAddon: false } : {}),
  }));
  assert.equal((await turnText(agent)).text, "custom reply", "automatic backend selection changed the configured route");
  await agent.close();
  agent = null;
  if (backend === "wasm") {
    agent = await createFxAgent(options(local, "local-model", {
      backend: "auto",
      nativeAddon: { libfxApiVersion: 3, createCore() { assert.fail("old addon must not start"); } },
    }));
    assert.equal((await turnText(agent)).text, "custom reply", "an old native addon prevented the Wasm fallback");
    await agent.close();
    agent = null;
  }
  console.log(`${backend} configured provider integration passed`);
} finally {
  await agent?.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
