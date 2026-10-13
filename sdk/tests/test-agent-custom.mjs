#!/usr/bin/env node
// A custom provider agent: the engine's requests reach an OpenAI-compatible
// server through the host fetch, with the host's API key on that server's chat
// URL only, and never touch AI Gateway. No network: every request is answered
// here.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { customProviderDefinition, customProviderSpec } from "../custom-provider.js";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";
import { createSubscriptionAuthorizer } from "../subscription.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-custom.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backendOptions = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
};

const baseUrl = "https://models.example/v1/";
const chatUrl = "https://models.example/v1/chat/completions";
const provider = { name: "local", baseUrl, models: { "local-model": { contextWindow: 32768, maxOutputTokens: 4096, supportsToolUse: true } } };

const sse = (...chunks) => chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
const reply = (text) => sse(
  { id: "chat-1", model: "local-model", choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
  { choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
);
const toolCall = sse(
  { choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call-1", type: "function", function: { name: "lookup", arguments: "{\"key\":\"alpha\"}" } }] }, finish_reason: null }] },
  { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
);

/** A host fetch that plays an OpenAI-compatible server; `answer(index, request)` picks each reply. */
function server({ answer = () => reply("libfx on a custom provider") } = {}) {
  const log = [];
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    const entry = { method, url, headers, body };
    log.push(entry);
    if (url === chatUrl && method === "POST") {
      const answered = answer(log.filter((logged) => logged.url === chatUrl).length - 1, entry);
      if (answered instanceof Response) return answered;
      return new Response(answered, { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

async function runTurn(options, prompt = "say ok") {
  const events = [];
  const engine = await createFxEngine({ ...backendOptions, provider, model: "local-model", onEvent: (event) => events.push(event), ...options });
  try {
    const turn = engine.prompt(prompt);
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    return { result: await turn.result, text, events, sessionId: engine.sessionId };
  } finally {
    await engine.close();
  }
}

const chatRequests = (log) => log.filter((entry) => entry.url === chatUrl);
const assertNoGateway = (log) => assert.equal(log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false, "a custom provider agent must not call AI Gateway");

// 1. A turn on the host's API key reaches only the provider's chat URL.
{
  const world = server();
  const asked = [];
  const { result, text, events, sessionId } = await runTurn({
    fetch: world.fetch,
    credentials: (request) => { asked.push(request); return { apiKey: "sk-provider" }; },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on a custom provider");
  assertNoGateway(world.log);
  assert.deepEqual(world.log.map((entry) => entry.url), [chatUrl], "the only request is the chat request");
  const [request] = chatRequests(world.log);
  assert.equal(request.headers.get("authorization"), "Bearer sk-provider");
  assert.equal(request.headers.get("accept"), "text/event-stream");
  const payload = JSON.parse(request.body);
  assert.equal(payload.model, "local-model");
  assert.equal(payload.stream, true);
  assert.match(JSON.stringify(payload.messages), /say ok/);
  assert.ok(asked.length > 0 && asked.every((entry) => entry.provider === "local"), "credentials() learns the provider's name");
  assert.ok(asked.some((entry) => entry.sessionId === sessionId), "credentials() learns which session the request is for");
  assert.equal(JSON.stringify(events).includes("sk-provider"), false, "libfx diagnostics must not expose the API key");
}

// 2. Without credentials(), requests carry no key, as a local server expects.
{
  const world = server();
  const { result, text } = await runTurn({ fetch: world.fetch });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on a custom provider");
  assert.equal(chatRequests(world.log)[0].headers.get("authorization"), null);
}

// 3. A tool call round-trips through Chat Completions.
{
  const world = server({ answer: (index) => index === 0 ? toolCall : reply("alpha is beta") });
  const lookup = {
    name: "lookup",
    description: "Looks up a key",
    idempotent: true,
    inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
    execute: async ({ key }) => `value of ${key} is beta`,
  };
  const { result, text } = await runTurn({ fetch: world.fetch, credentials: () => ({ apiKey: "sk-provider" }), tools: [lookup] }, "look up alpha");
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "alpha is beta");
  const [first, second] = chatRequests(world.log);
  assert.ok(JSON.parse(first.body).tools.some((tool) => tool.function?.name === "lookup"), "the model is offered the host tool");
  const messages = JSON.parse(second.body).messages;
  const call = messages.find((message) => message.role === "assistant" && message.tool_calls);
  assert.equal(call.tool_calls[0].id, "call-1");
  const answer = messages.find((message) => message.role === "tool");
  assert.equal(answer.tool_call_id, "call-1");
  assert.match(JSON.stringify(answer.content), /value of alpha is beta/);
  assert.equal(second.headers.get("authorization"), "Bearer sk-provider");
}

// 4. A rejected key is not refreshed or resent; the turn reports the failure.
{
  const world = server({ answer: () => Response.json({ error: { message: "invalid api key" } }, { status: 401 }) });
  let asked = 0;
  const outcome = await runTurn({ fetch: world.fetch, credentials: () => { asked += 1; return { apiKey: "sk-wrong" }; } }).catch((error) => ({ error }));
  assert.ok(outcome.error || outcome.result.stopReason !== "end_turn", "the turn does not finish on a rejected key");
  assert.equal(chatRequests(world.log).length, 1, "a rejected request is not resent");
  assert.ok(asked >= 1);
}

// 5. A durable session continues in a new agent, and follows the agent's
// provider to another base URL with its history, like a change of model.
{
  const durability = memory();
  const world = server({ answer: (index) => reply(index === 0 ? "first reply" : "second reply") });
  const agentOptions = (overrides = {}) => ({
    ...backendOptions,
    durability,
    provider,
    model: "local-model",
    fetch: world.fetch,
    credentials: () => ({ apiKey: "sk-provider" }),
    ...overrides,
  });
  const first = createFxAgent(agentOptions());
  let id;
  try {
    const session = first.session();
    assert.equal((await session.prompt("first").result).stopReason, "end_turn");
    id = session.id;
  } finally {
    await first.close();
  }

  const second = createFxAgent(agentOptions());
  try {
    const turn = second.session(id).prompt("second");
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.equal(text, "second reply");
    const resumed = JSON.parse(chatRequests(world.log)[1].body).messages;
    assert.match(JSON.stringify(resumed), /first reply/, "the resumed session keeps its history");
  } finally {
    await second.close();
  }

  const elsewhereUrl = "https://elsewhere.example/v1/chat/completions";
  const elsewhere = [];
  const moved = createFxAgent(agentOptions({
    provider: { ...provider, baseUrl: "https://elsewhere.example/v1" },
    fetch: async (input, init = {}) => {
      const url = String(input?.url ?? input);
      const body = typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
      elsewhere.push({ url, headers: new Headers(init.headers), body });
      if (url !== elsewhereUrl) return new Response("unexpected", { status: 599 });
      return new Response(reply("third reply"), { status: 200, headers: { "content-type": "text/event-stream" } });
    },
  }));
  const before = world.log.length;
  try {
    assert.equal((await moved.session(id).prompt("third").result).stopReason, "end_turn");
  } finally {
    await moved.close();
  }
  assert.deepEqual(elsewhere.map((entry) => entry.url), [elsewhereUrl]);
  assert.equal(elsewhere[0].headers.get("authorization"), "Bearer sk-provider");
  assert.match(elsewhere[0].body, /second reply/, "the session's history goes with it");
  assert.equal(world.log.length, before, "the first server hears nothing more");
  assertNoGateway(world.log);
}

// 6. A server that quotes the key back in an error never gets it into the
// turn, its events, or the saved session, even escaped.
{
  const key = "sk-quoted-back";
  const escaped = [...key].map((char) => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
  const world = server({
    answer: (_index, request) => new Response(
      `{"detail":"bad credential ${request.headers.get("authorization")}","escaped":"${escaped}"}`,
      { status: 403, headers: { "content-type": "application/json" } },
    ),
  });
  const durability = memory();
  const events = [];
  const streamed = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability,
    provider,
    model: "local-model",
    fetch: world.fetch,
    credentials: () => ({ apiKey: key }),
    onEvent: (event) => events.push(event),
  });
  let sessionId;
  try {
    const turn = agent.session().prompt("say ok");
    ({ sessionId } = await turn.accepted);
    for await (const event of turn) streamed.push(event);
    assert.notEqual((await turn.result).stopReason, "end_turn");
  } finally {
    await agent.close();
  }
  assert.equal(chatRequests(world.log)[0].headers.get("authorization"), `Bearer ${key}`, "the key reached the server");
  assert.match(JSON.stringify(streamed), /bad credential Bearer \*{14}/, "the error reaches the turn with the key masked");
  // Everything the session saved: its log, with byte payloads as text, and its UI stream.
  const stored = await durability.create().session(sessionId);
  const log = JSON.stringify(await stored.readSince(0), (_, value) => value instanceof Uint8Array ? Buffer.from(value).toString("latin1") : value);
  const lines = await stored.ui.length();
  assert.ok(lines > 0, "the session saved its UI stream");
  const reader = stored.ui.read(0).getReader();
  let ui = "";
  for (let line = 0; line < lines; line += 1) ui += new TextDecoder().decode((await reader.read()).value);
  await reader.cancel();
  // Undoes \u escapes at any depth of JSON nesting, so an escaped copy counts.
  const decoded = (text) => text.replace(/\\+u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
  for (const [where, text] of [["the stream", JSON.stringify(streamed)], ["the events", JSON.stringify(events)], ["the saved log", log], ["the saved UI stream", ui]]) {
    assert.equal(decoded(text).includes(key), false, `${where} must not repeat the key`);
  }
}

// 7. The key is added to the provider's chat URL and nowhere else, as the
// engine names a request: origin and path.
{
  const definition = customProviderDefinition(provider);
  const auth = createSubscriptionAuthorizer([customProviderSpec(definition, () => undefined)], { credentials: () => ({ apiKey: "sk-provider" }) });
  assert.ok(auth.specFor(chatUrl), "the chat URL carries the key");
  for (const endpoint of [
    "https://models.example/v1/models",
    "https://models.example/v1/chat/completions/extra",
    "https://models.example/chat/completions",
    "http://models.example/v1/chat/completions",
    "https://models.example.evil/v1/chat/completions",
    "https://ai-gateway.vercel.sh/v1/chat/completions",
  ]) {
    assert.equal(auth.specFor(endpoint), undefined, `${endpoint} must not carry the key`);
  }
}

// 8. Options are checked before anything starts.
const base = { ...backendOptions, model: "local-model" };
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, name: "codex" } }), /provider.name must be/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, name: "1local" } }), /provider.name must be/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, baseUrl: "http://models.example/v1" } }), /https, or http on localhost/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, baseUrl: "https://models.example/v1?key=1" } }), /credentials, a query or a fragment/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, apiKey: "sk" } }), /unknown field apiKey/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, models: { "local-model": { context: 1 } } } }), /unknown field context/);
await assert.rejects(createFxEngine({ ...backendOptions, provider }), /a custom provider needs a model/);
await assert.rejects(createFxEngine({ ...base, provider, credentials: "sk" }), /credentials must be a function/);
await assert.rejects(createFxEngine({ ...base, provider, onCredentials: () => {} }), /onCredentials needs provider "codex" or "grok"/);
await assert.rejects(createFxEngine({ ...base, provider, refreshLock: async (_info, refresh) => refresh() }), /refreshLock needs provider "codex" or "grok"/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, models: { "local-model": { contextWindow: 100, maxOutputTokens: 100 } } } }), /maxOutputTokens must be less than contextWindow/);
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, models: { "local-model": { supportsVision: "yes" } } } }), /supportsVision must be a boolean/);
// The engine applies the CLI's complete rules to what passes the quick checks.
await assert.rejects(createFxEngine({ ...base, provider: { ...provider, baseUrl: "https://models_example.test/v1" } }));

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} custom provider agent passed`);
