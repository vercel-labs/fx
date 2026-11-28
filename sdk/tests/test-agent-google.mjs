#!/usr/bin/env node
// A Google Gemini agent: the engine's requests reach Google's Interactions
// endpoint through the host fetch with the host's Gemini API key in
// `x-goog-api-key`, never touch AI Gateway, and fail closed on the unsupported
// plan route. No network: every request is answered here.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { googleApiKeySpec, isGoogleRequest } from "../google.js";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";
import { createSubscriptionAuthorizer } from "../subscription.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-google.mjs [native|wasm]");
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

const interactionsUrl = "https://generativelanguage.googleapis.com/v1beta/interactions";
const planUrl = "https://generativelanguage.googleapis.com/v1beta/interactions:createPerUserQuota";

const sse = (...events) => events.map(([name, data]) => `event: ${name}\ndata: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`).join("");
const textReply = (text) => sse(
  ["interaction.created", { event_type: "interaction.created", interaction: { id: "int_1", status: "in_progress", object: "interaction", model: "gemini-4-hydrogen" } }],
  ["step.start", { event_type: "step.start", index: 0, step: { type: "model_output" } }],
  ["step.delta", { event_type: "step.delta", index: 0, delta: { type: "text", text } }],
  ["step.stop", { event_type: "step.stop", index: 0 }],
  ["interaction.completed", { event_type: "interaction.completed", interaction: { id: "int_1", status: "completed", usage: { total_input_tokens: 23, total_output_tokens: 7 } } }],
  ["done", "[DONE]"],
);
const toolCallReply = sse(
  ["interaction.created", { event_type: "interaction.created", interaction: { id: "int_1", status: "in_progress", object: "interaction", model: "gemini-4-hydrogen" } }],
  ["step.start", { event_type: "step.start", index: 0, step: { type: "thought" } }],
  ["step.delta", { event_type: "step.delta", index: 0, delta: { type: "thought_signature", signature: "sig-step-0" } }],
  ["step.stop", { event_type: "step.stop", index: 0 }],
  ["step.start", { event_type: "step.start", index: 1, step: { type: "function_call", id: "call_1", name: "lookup", arguments: { key: "alpha" } } }],
  ["step.stop", { event_type: "step.stop", index: 1 }],
  ["interaction.completed", { event_type: "interaction.completed", interaction: { id: "int_1", status: "requires_action", usage: { total_input_tokens: 20, total_output_tokens: 9 } } }],
  ["done", "[DONE]"],
);

/** A host fetch that plays Google's Interactions API. */
function googleWorld({ answer = () => textReply("libfx on google") } = {}) {
  const log = [];
  let replies = 0;
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    const entry = { method, url, headers, body };
    log.push(entry);
    if (url === interactionsUrl && method === "POST") {
      const answered = answer(replies++, entry);
      if (answered instanceof Response) return answered;
      return new Response(answered, { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

async function runTurn(options, prompt = "say ok") {
  const events = [];
  const engine = await createFxEngine({ ...backendOptions, provider: "google", model: "gemini-4-hydrogen", onEvent: (event) => events.push(event), ...options });
  try {
    const turn = engine.prompt(prompt);
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    return { result: await turn.result, text, events, sessionId: engine.sessionId };
  } finally {
    await engine.close();
  }
}

const replyRequests = (log) => log.filter((entry) => entry.url === interactionsUrl);
const assertNoSecrets = (value, secrets) => {
  const text = JSON.stringify(value);
  for (const secret of secrets) assert.equal(text.includes(secret), false, "libfx diagnostics must not expose Gemini API keys");
};

// 1. A Google turn on the host's Gemini API key reaches /v1beta/interactions
// with x-goog-api-key and no AI Gateway or plan request.
{
  const world = googleWorld({});
  const asked = [];
  const { result, text, events, sessionId } = await runTurn({
    fetch: world.fetch,
    credentials: (request) => { asked.push(request); return { apiKey: "gm-first" }; },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on google");
  assert.equal(world.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false, "a Google agent must not call AI Gateway");
  assert.equal(world.log.some((entry) => entry.url.includes("createPerUserQuota")), false, "only the API key route is used");
  assert.deepEqual(world.log.map((entry) => entry.url), [interactionsUrl]);
  const [reply] = replyRequests(world.log);
  assert.equal(reply.headers.get("x-goog-api-key"), "gm-first");
  assert.equal(reply.headers.get("authorization"), null);
  assert.equal(reply.headers.get("accept"), "text/event-stream");
  const payload = JSON.parse(reply.body);
  assert.equal(payload.model, "gemini-4-hydrogen");
  assert.equal(payload.store, false);
  assert.equal(payload.stream, true);
  assert.equal(payload.max_output_tokens, undefined);
  assert.match(JSON.stringify(payload.input), /say ok/);
  assert.ok(asked.some((request) => request.sessionId === sessionId), "credentials() learns which session the request is for");
  assert.ok(asked.length > 0 && asked.every((request) => request.provider === "google"), "credentials() learns the provider");
  assertNoSecrets(events, ["gm-first"]);
}

// 2. A 429 daily-limit body maps to the same failure the CLI path gives.
{
  const dailyBody = JSON.stringify({
    error: {
      code: "too_many_requests",
      message: "You've reached today's AI Ultra limit for gemini-4-hydrogen in third-party apps. Your daily limit refreshes in 5 hours, 18 minutes. Until then, you can switch to other models.",
    },
  });
  const world = googleWorld({
    answer: () => new Response(dailyBody, {
      status: 429,
      headers: { "content-type": "application/json", "retry-after": "19104" },
    }),
  });
  const { result, events } = await runTurn({
    fetch: world.fetch,
    credentials: () => ({ apiKey: "gm-quota" }),
  });
  assert.equal(result.stopReason, "refused");
  const failureText = `${result.error?.message ?? ""} ${JSON.stringify(events)}`;
  assert.match(
    failureText,
    /Daily limit reached for gemini-4-hydrogen; resets in 5 h 18 min\. Switch models or try again after reset\./,
  );
  assert.equal(failureText.includes("Or use a Gemini API key"), false);
  assert.equal(failureText.includes("one.google.com"), false);
  assert.equal(replyRequests(world.log).length, 1, "quota_exhausted is not retried");
}

// 3. A tool call round-trips through Gemini Interactions, preserving thought replay.
{
  const world = googleWorld({ answer: (index) => index === 0 ? toolCallReply : textReply("alpha is beta") });
  const lookup = {
    name: "lookup",
    description: "Looks up a key",
    idempotent: true,
    inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
    execute: async ({ key }) => `value of ${key} is beta`,
  };
  const { result, text } = await runTurn({ fetch: world.fetch, credentials: () => ({ apiKey: "gm-tools" }), tools: [lookup] }, "look up alpha");
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "alpha is beta");
  const [first, second] = replyRequests(world.log);
  assert.ok(JSON.parse(first.body).tools.some((tool) => tool.name === "lookup"), "the model is offered the host tool");
  const secondInput = JSON.stringify(JSON.parse(second.body).input);
  assert.match(secondInput, /sig-step-0/, "thought signature replays on the next turn");
  assert.match(secondInput, /value of alpha is beta/);
  assert.equal(second.headers.get("x-goog-api-key"), "gm-tools");
}

// 4. A server that quotes the Gemini API key back in an error never leaks it
// into the turn, events, or saved session, even escaped.
{
  const key = "gm-quoted-secret";
  const escaped = [...key].map((char) => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
  const world = googleWorld({
    answer: (_index, request) => new Response(
      `{"error":{"code":403,"message":"bad credential ${request.headers.get("x-goog-api-key")}","escaped":"${escaped}"}}`,
      { status: 403, headers: { "content-type": "application/json" } },
    ),
  });
  const durability = memory();
  const events = [];
  const streamed = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability,
    provider: "google",
    model: "gemini-4-hydrogen",
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
  assert.equal(replyRequests(world.log)[0].headers.get("x-goog-api-key"), key, "the key reached the server");
  assert.match(JSON.stringify(streamed), /Google refused this Gemini API key \(HTTP 403\)/);
  const stored = await durability.create().session(sessionId);
  const log = JSON.stringify(await stored.readSince(0), (_, value) => value instanceof Uint8Array ? Buffer.from(value).toString("latin1") : value);
  const decoded = (text) => text.replace(/\\+u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
  for (const [where, content] of [["the stream", JSON.stringify(streamed)], ["the events", JSON.stringify(events)], ["the saved log", log]]) {
    assert.equal(decoded(content).includes(key), false, `${where} must not repeat the key`);
  }
}

// 5. The API key goes only to /v1beta/interactions; the plan route fails closed.
{
  const auth = createSubscriptionAuthorizer([googleApiKeySpec(() => undefined)], { credentials: () => ({ apiKey: "gm-only-api" }) });
  assert.equal(isGoogleRequest(interactionsUrl), true);
  assert.equal(isGoogleRequest(planUrl), false);
  assert.ok(auth.specFor(interactionsUrl), "the API key endpoint is authorized");
  for (const endpoint of [
    planUrl,
    "https://generativelanguage.googleapis.com/v1beta/models",
    "https://generativelanguage.googleapis.com/v1beta/interactions/extra",
    "http://generativelanguage.googleapis.com/v1beta/interactions",
    "https://ai-gateway.vercel.sh/v4/ai/language-model",
  ]) {
    assert.equal(auth.specFor(endpoint), undefined, `${endpoint} must not carry the Gemini API key`);
  }

  assert.throws(
    () => auth.specFor(interactionsUrl).normalize({ accessToken: "ya29.plan-token" }),
    /Google plan credentials are not supported/,
  );

  // Plan-style credentials ({ accessToken }) fail closed without sending.
  const world = googleWorld({});
  const outcome = await runTurn({
    fetch: world.fetch,
    credentials: () => ({ accessToken: "ya29.plan-token" }),
  }).catch((error) => ({ error }));
  assert.ok(outcome.error || outcome.result.stopReason !== "end_turn", "plan credentials fail closed");
  assert.equal(world.log.length, 0, "nothing is sent when the host supplies plan credentials");
}

// 6. A durable Google agent asks for its own session's credentials and checks
// session-level model selection.
{
  const world = googleWorld({});
  const asked = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "google",
    fetch: world.fetch,
    credentials: (request) => { asked.push(request.sessionId); return { apiKey: "gm-durable" }; },
  });
  try {
    const named = agent.session(undefined, { model: "gemini-4-hydrogen" }).prompt("say ok");
    const { sessionId } = await named.accepted;
    for await (const event of named) void event;
    assert.equal((await named.result).stopReason, "end_turn");
    assert.ok(asked.includes(sessionId), "credentials() learns the durable session's id");
    const unnamed = agent.session().prompt("say ok");
    for await (const event of unnamed) void event;
    const refused = await unnamed.result;
    assert.equal(refused.stopReason, "error");
    assert.match(refused.error.message, /provider "google" needs a model; fx's default model is an AI Gateway id/);
    assert.equal(replyRequests(world.log).length, 1, "nothing is sent for the session without a model");
  } finally {
    await agent.close();
  }
}

// 7. Options are checked before anything starts.
await assert.rejects(createFxEngine({ ...backendOptions, provider: "google", model: "gemini-4-hydrogen" }), /provider "google" needs a credentials\(\) function/);
await assert.rejects(
  createFxEngine({ ...backendOptions, provider: "google", model: "gemini-4-hydrogen", credentials: () => ({ apiKey: "gm-k" }), onCredentials: () => {} }),
  /onCredentials needs provider "codex" or "grok"/,
);
await assert.rejects(
  createFxEngine({ ...backendOptions, provider: "google", model: "gemini-4-hydrogen", credentials: () => ({ apiKey: "gm-k" }), refreshLock: async (_info, refresh) => refresh() }),
  /refreshLock needs provider "codex" or "grok"/,
);
await assert.rejects(
  createFxEngine({ ...backendOptions, provider: { name: "google", baseUrl: "https://models.example/v1" }, model: "gemini-4-hydrogen" }),
  /provider\.name must be/,
);
{
  const world = googleWorld({});
  await assert.rejects(
    createFxEngine({ ...backendOptions, provider: "google", fetch: world.fetch, credentials: () => ({ apiKey: "gm-k" }) }),
    /provider "google" needs a model; fx's default model is an AI Gateway id/,
  );
  assert.deepEqual(world.log, []);
}

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Google agent passed`);
