#!/usr/bin/env node
// A Codex (ChatGPT plan) agent: the engine's requests reach Codex through the
// host fetch with the host's ChatGPT credentials, refreshed when needed, and
// never touch AI Gateway. No network: every request is answered here.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-codex.mjs [native|wasm]");
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

const accountId = "acct-fixture";
const tenDays = 864000;
function jwt(label, expiresInSeconds) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "none" })}.${part({
    exp: Math.floor(Date.now() / 1000) + expiresInSeconds,
    "https://api.openai.com/auth": { chatgpt_account_id: accountId, chatgpt_plan_type: "business" },
    label,
  })}.signature`;
}

const models = {
  models: [
    { slug: "gpt-6.1-sol", visibility: "list", supported_in_api: true, priority: 1, supported_reasoning_levels: [{ effort: "low" }, { effort: "high" }], additional_speed_tiers: [], input_modalities: ["text", "image"], context_window: 272000 },
    { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, priority: 2, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
  ],
};
const replySse =
  'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}\n\n' +
  'data: {"type":"response.output_text.delta","output_index":0,"delta":"libfx ok"}\n\n' +
  'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":23,"output_tokens":7}}}\n\n';

/** A host fetch that plays npm, Codex and OpenAI's token endpoint. */
function codexWorld({ rejectFirstReply = false, refreshedToken }) {
  const log = [];
  let replies = 0;
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    log.push({ method, url, headers, body });
    if (url === "https://registry.npmjs.org/@openai/codex/latest") return Response.json({ version: "0.162.1", name: "@openai/codex" });
    if (url === "https://chatgpt.com/backend-api/codex/models?client_version=0.162.1") return Response.json(models);
    if (url === "https://auth.openai.com/oauth/token" && method === "POST") {
      return Response.json({ access_token: refreshedToken, refresh_token: "rt-2", expires_in: tenDays });
    }
    if (url === "https://chatgpt.com/backend-api/codex/responses" && method === "POST") {
      replies += 1;
      if (rejectFirstReply && replies === 1) return Response.json({ detail: "token expired" }, { status: 401 });
      return new Response(replySse, { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

async function runTurn(options) {
  const events = [];
  const engine = await createFxEngine({ ...backendOptions, provider: "codex", model: "gpt-6.1-sol", onEvent: (event) => events.push(event), ...options });
  try {
    const turn = engine.prompt("say ok");
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    return { result: await turn.result, text, events };
  } finally {
    await engine.close();
  }
}

const replyRequests = (log) => log.filter((entry) => entry.url === "https://chatgpt.com/backend-api/codex/responses");
const assertNoSecrets = (value, secrets) => {
  const text = JSON.stringify(value);
  for (const secret of secrets) assert.equal(text.includes(secret), false, "libfx diagnostics must not expose ChatGPT credentials");
};

// 1. A Codex turn on the host's credentials, with no Gateway request.
{
  const access = jwt("first", tenDays);
  const world = codexWorld({ refreshedToken: jwt("unused", tenDays) });
  const asked = [];
  const { result, text, events } = await runTurn({
    fetch: world.fetch,
    credentials: (request) => { asked.push(request); return { accessToken: access, refreshToken: "rt-1" }; },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx ok");
  assert.equal(world.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false, "a Codex agent must not call AI Gateway");
  assert.equal(world.log.some((entry) => entry.url.startsWith("https://auth.openai.com/")), false, "fresh credentials need no refresh");
  const [reply] = replyRequests(world.log);
  assert.ok(reply, "the turn must reach Codex");
  assert.equal(reply.headers.get("authorization"), `Bearer ${access}`);
  assert.equal(reply.headers.get("chatgpt-account-id"), accountId);
  assert.equal(reply.headers.get("originator"), "fx");
  assert.equal(reply.headers.get("OpenAI-Beta"), "responses=experimental");
  const sessionId = reply.headers.get("session-id");
  assert.ok(sessionId, "Codex requests carry the session id");
  assert.equal(reply.headers.get("x-client-request-id"), sessionId);
  const payload = JSON.parse(reply.body);
  assert.equal(payload.model, "gpt-6.1-sol");
  assert.equal(payload.store, false);
  assert.equal(payload.stream, true);
  assert.match(JSON.stringify(payload.input), /say ok/);
  const models = world.log.find((entry) => entry.url.startsWith("https://chatgpt.com/backend-api/codex/models"));
  if (models) {
    assert.equal(models.headers.get("authorization"), `Bearer ${access}`, "the model list uses the same credentials");
    assert.equal(models.headers.get("chatgpt-account-id"), accountId);
  }
  // The model-list request carries no session header, and still names it.
  assert.ok(asked.length > 1, "the model list and the reply each ask for credentials");
  assert.deepEqual(asked.filter((request) => request.sessionId !== sessionId), [], "every credentials() call names the session, as providers.mdx says");
  assert.ok(asked.every((request) => request.provider === "codex"), "credentials() learns the provider");
  assertNoSecrets(events, [access, "rt-1"]);
}

// 2. A rejected token is refreshed once and the request sent again.
{
  const first = jwt("rejected", tenDays);
  const second = jwt("refreshed", tenDays);
  const world = codexWorld({ rejectFirstReply: true, refreshedToken: second });
  const saved = [];
  const { result, text, events } = await runTurn({
    fetch: world.fetch,
    credentials: () => ({ accessToken: first, refreshToken: "rt-1" }),
    onCredentials: (credentials, info) => { saved.push({ credentials, info }); },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx ok");
  const refreshes = world.log.filter((entry) => entry.url === "https://auth.openai.com/oauth/token");
  assert.equal(refreshes.length, 1, "one rejection causes one refresh");
  assert.deepEqual(JSON.parse(refreshes[0].body), { client_id: "app_EMoamEEZ73f0CkXaXp7hrann", grant_type: "refresh_token", refresh_token: "rt-1" });
  const replies = replyRequests(world.log);
  assert.equal(replies.length, 2);
  assert.equal(replies[0].headers.get("authorization"), `Bearer ${first}`);
  assert.equal(replies[1].headers.get("authorization"), `Bearer ${second}`);
  assert.equal(replies[1].body, replies[0].body, "the resent request is unchanged");
  assert.equal(saved.length, 1, "the host receives the refreshed credentials once");
  assert.equal(saved[0].credentials.accessToken, second);
  assert.equal(saved[0].info.provider, "codex", "onCredentials learns the provider");
  assert.equal(saved[0].credentials.refreshToken, "rt-2");
  assert.equal(saved[0].credentials.accountId, accountId);
  assert.ok(saved[0].credentials.expiresAt > Date.now() + 9 * 24 * 3600 * 1000);
  assertNoSecrets(events, [first, second, "rt-1", "rt-2"]);
}

// 3. Credentials about to expire are refreshed before the request. The model
// list, whose headers name no session, refreshes them, and refreshLock and
// onCredentials still learn the session, so a host can key both by it.
{
  const expiring = jwt("expiring", 60);
  const fresh = jwt("fresh", tenDays);
  const world = codexWorld({ refreshedToken: fresh });
  const locked = [];
  const saved = [];
  const { result } = await runTurn({
    fetch: world.fetch,
    credentials: () => ({ accessToken: expiring, refreshToken: "rt-1" }),
    refreshLock: (info, refresh) => { locked.push(info); return refresh(); },
    onCredentials: (credentials, info) => { saved.push({ accessToken: credentials.accessToken, info }); },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(world.log.filter((entry) => entry.url === "https://auth.openai.com/oauth/token").length, 1);
  for (const entry of world.log.filter((entry) => entry.url.startsWith("https://chatgpt.com/"))) {
    assert.equal(entry.headers.get("authorization"), `Bearer ${fresh}`, "no Codex request uses the expiring token");
  }
  const sessionId = replyRequests(world.log)[0].headers.get("session-id");
  assert.deepEqual(locked, [{ provider: "codex", sessionId }], "refreshLock names the session");
  assert.deepEqual(saved, [{ accessToken: fresh, info: { provider: "codex", sessionId } }], "onCredentials names the session");
}

// 5. A durable session asks for its own session's credentials.
{
  const access = jwt("durable", tenDays);
  const world = codexWorld({ refreshedToken: jwt("unused", tenDays) });
  const asked = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "codex",
    model: "gpt-6.1-sol",
    fetch: world.fetch,
    credentials: (request) => { asked.push(request.sessionId); return { accessToken: access, refreshToken: "rt-1" }; },
  });
  try {
    const turn = agent.session().prompt("say ok");
    const { sessionId } = await turn.accepted;
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.equal(text, "libfx ok");
    assert.ok(asked.includes(sessionId), "credentials() is asked for the durable session's own credentials");
    assert.deepEqual(asked.filter((id) => id !== sessionId), [], "every credentials() call, the model list's included, names the session");
    assert.equal(replyRequests(world.log)[0].headers.get("session-id"), sessionId);
    assert.equal(world.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false);
  } finally {
    await agent.close();
  }
}

// 4. Options are checked before anything starts.
await assert.rejects(createFxEngine({ ...backendOptions, provider: "codex", model: "gpt-6.1-sol" }), /needs a credentials\(\) function/);
await assert.rejects(createFxEngine({ ...backendOptions, provider: "custom", apiKey: "key" }), /provider must be "gateway", "codex", "grok" or a custom provider/);
await assert.rejects(createFxEngine({ ...backendOptions, apiKey: "key", credentials: () => ({}) }), /credentials needs provider "codex"/);
await assert.rejects(createFxEngine({ ...backendOptions, apiKey: "key", onCredentials: () => {} }), /onCredentials needs provider "codex"/);
// QUAL-18: the error says what is missing and how to pass it.
await assert.rejects(createFxEngine({ ...backendOptions }), /^TypeError: no AI Gateway credentials were found: pass apiKey, an AI Gateway API key or a Vercel OIDC token, to createFxEngine\(\)$/);
await assert.rejects(createFxEngine({ ...backendOptions, apiKey: "" }), /^TypeError: apiKey must be a non-empty string$/);

// fx's default model is an AI Gateway id, which Codex doesn't serve, so a
// Codex agent must name its model, and nothing is requested without one.
{
  const world = codexWorld({});
  await assert.rejects(
    createFxEngine({ ...backendOptions, provider: "codex", fetch: world.fetch, credentials: () => ({ accessToken: "at-first", refreshToken: "rt-1" }) }),
    /provider "codex" needs a model; fx's default model is an AI Gateway id/,
  );
  assert.deepEqual(world.log, []);
}

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Codex agent passed`);
