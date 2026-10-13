#!/usr/bin/env node
// A Grok (Grok plan) agent: the engine's requests reach xAI's subscription
// proxy through the host fetch with the host's Grok credentials, refreshed
// when needed, and never touch AI Gateway. No network: every request is
// answered here.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-grok.mjs [native|wasm]");
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

const clientId = "b1a00492-073a-47ea-816f-4c329264a828";
const accountId = "xai-account-fixture";
const sixHours = 6 * 3600 * 1000;
const responsesUrl = "https://cli-chat-proxy.grok.com/v1/responses";
const modelsUrl = "https://cli-chat-proxy.grok.com/v1/models";
const languageModelsUrl = "https://api.x.ai/v1/language-models";
const tokenUrl = "https://auth.x.ai/oauth2/token";
const userinfoUrl = "https://auth.x.ai/oauth2/userinfo";

const models = {
  data: [
    { id: "grok-4.5", model: "grok-4.5", api_backend: "responses", context_window: 500000, supports_reasoning_effort: true, reasoning_efforts: [{ value: "low" }, { value: "high" }] },
    { id: "grok-4.7", model: "grok-4.7", api_backend: "responses", context_window: 500000, supports_reasoning_effort: false, reasoning_efforts: [] },
  ],
};
const languageModels = { models: [{ id: "grok-4.5", input_modalities: ["text", "image"], output_modalities: ["text"] }] };
const replySse =
  'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}\n\n' +
  'data: {"type":"response.output_text.delta","output_index":0,"delta":"libfx on grok"}\n\n' +
  'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":23,"output_tokens":7}}}\n\n';

/** A host fetch that plays x.ai's version file, the subscription proxy, and xAI's OAuth endpoints. */
function grokWorld({ rejectFirstReply = false, rejectToken, refreshedToken = "unused", refreshedAccount = accountId }) {
  const log = [];
  let replies = 0;
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    log.push({ method, url, headers, body });
    if (url === "https://x.ai/cli/stable") return new Response("1.0.50\n");
    if (url === modelsUrl) return Response.json(models);
    if (url === languageModelsUrl) return Response.json(languageModels);
    if (url === tokenUrl && method === "POST") {
      return Response.json({ access_token: refreshedToken, refresh_token: "rt-2", expires_in: 21600, token_type: "Bearer" });
    }
    if (url === userinfoUrl) {
      const token = headers.get("authorization")?.replace(/^Bearer /, "");
      return Response.json({ sub: token === refreshedToken ? refreshedAccount : accountId, email: "user@example.com" });
    }
    if (url === responsesUrl && method === "POST") {
      replies += 1;
      if (rejectFirstReply && replies === 1) return Response.json({ error: "token expired" }, { status: 401 });
      if (rejectToken && headers.get("authorization") === `Bearer ${rejectToken}`) return Response.json({ error: "token expired" }, { status: 401 });
      return new Response(replySse, { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

async function runTurn(options) {
  const events = [];
  const engine = await createFxEngine({ ...backendOptions, provider: "grok", model: "grok-4.5", onEvent: (event) => events.push(event), ...options });
  try {
    const turn = engine.prompt("say ok");
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    return { result: await turn.result, text, events };
  } finally {
    await engine.close();
  }
}

const credentialsFor = (accessToken, extra = {}) => ({ accessToken, refreshToken: "rt-1", accountId, expiresAt: Date.now() + sixHours, ...extra });
const replyRequests = (log) => log.filter((entry) => entry.url === responsesUrl);
const assertNoSecrets = (value, secrets) => {
  const text = JSON.stringify(value);
  for (const secret of secrets) assert.equal(text.includes(secret), false, "libfx diagnostics must not expose Grok credentials");
};

// 1. A Grok turn on the host's credentials, with no Gateway request.
{
  const world = grokWorld({});
  const asked = [];
  const { result, text, events } = await runTurn({
    fetch: world.fetch,
    credentials: (request) => { asked.push(request); return credentialsFor("at-first"); },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on grok");
  assert.equal(world.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false, "a Grok agent must not call AI Gateway");
  assert.equal(world.log.some((entry) => entry.url.startsWith("https://auth.x.ai/")), false, "fresh credentials need no refresh");
  const [reply] = replyRequests(world.log);
  assert.ok(reply, "the turn must reach Grok");
  assert.equal(reply.headers.get("authorization"), "Bearer at-first");
  assert.equal(reply.headers.get("x-grok-user-id"), accountId);
  assert.equal(reply.headers.get("X-XAI-Token-Auth"), "xai-grok-cli");
  assert.equal(reply.headers.get("x-authenticateresponse"), "authenticate-response");
  assert.equal(reply.headers.get("x-grok-client-version"), "1.0.50");
  assert.equal(reply.headers.get("x-grok-client-identifier"), "fx");
  assert.equal(reply.headers.get("x-grok-model-override"), "grok-4.5");
  const sessionId = reply.headers.get("x-grok-conv-id");
  assert.ok(sessionId, "Grok requests carry the session id");
  const payload = JSON.parse(reply.body);
  assert.equal(payload.model, "grok-4.5");
  assert.equal(payload.store, false);
  assert.equal(payload.stream, true);
  assert.match(JSON.stringify(payload.input), /say ok/);
  const list = world.log.find((entry) => entry.url === modelsUrl);
  if (list) {
    assert.equal(list.headers.get("authorization"), "Bearer at-first", "the model list uses the same credentials");
    assert.equal(list.headers.get("x-userid"), accountId);
    assert.equal(list.headers.get("x-grok-user-id"), null);
  }
  const enrichment = world.log.find((entry) => entry.url === languageModelsUrl);
  if (enrichment) {
    assert.equal(enrichment.headers.get("authorization"), "Bearer at-first");
    assert.equal(enrichment.headers.get("x-userid"), null, "only the subscription proxy hears the account id");
  }
  assert.ok(asked.some((request) => request.sessionId === sessionId), "credentials() learns which session the request is for");
  assert.ok(asked.length > 0 && asked.every((request) => request.provider === "grok"), "credentials() learns the provider");
  assertNoSecrets(events, ["at-first", "rt-1"]);
}

// 2. A rejected token is refreshed once, checked against the account, and the request sent again.
{
  const world = grokWorld({ rejectFirstReply: true, refreshedToken: "at-second" });
  const saved = [];
  const { result, text, events } = await runTurn({
    fetch: world.fetch,
    credentials: () => credentialsFor("at-rejected"),
    onCredentials: (credentials, info) => { saved.push({ credentials, info }); },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on grok");
  const refreshes = world.log.filter((entry) => entry.url === tokenUrl);
  assert.equal(refreshes.length, 1, "one rejection causes one refresh");
  assert.equal(refreshes[0].headers.get("content-type"), "application/x-www-form-urlencoded");
  assert.deepEqual(Object.fromEntries(new URLSearchParams(refreshes[0].body)), { grant_type: "refresh_token", client_id: clientId, refresh_token: "rt-1" });
  const checks = world.log.filter((entry) => entry.url === userinfoUrl);
  assert.equal(checks.length, 1, "the refreshed token's account is checked");
  assert.equal(checks[0].headers.get("authorization"), "Bearer at-second");
  const replies = replyRequests(world.log);
  assert.equal(replies.length, 2);
  assert.equal(replies[0].headers.get("authorization"), "Bearer at-rejected");
  assert.equal(replies[1].headers.get("authorization"), "Bearer at-second");
  assert.equal(replies[1].body, replies[0].body, "the resent request is unchanged");
  assert.equal(saved.length, 1, "the host receives the refreshed credentials once");
  assert.equal(saved[0].info.provider, "grok", "onCredentials learns the provider");
  assert.equal(saved[0].credentials.accessToken, "at-second");
  assert.equal(saved[0].credentials.refreshToken, "rt-2");
  assert.equal(saved[0].credentials.accountId, accountId);
  assert.ok(saved[0].credentials.expiresAt > Date.now() + 5 * 3600 * 1000);
  assertNoSecrets(events, ["at-rejected", "at-second", "rt-1", "rt-2"]);
}

// 3. Credentials about to expire are refreshed before the request.
{
  const world = grokWorld({ refreshedToken: "at-fresh" });
  const { result } = await runTurn({ fetch: world.fetch, credentials: () => credentialsFor("at-expiring", { expiresAt: Date.now() + 60_000 }) });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(world.log.filter((entry) => entry.url === tokenUrl).length, 1);
  for (const entry of world.log.filter((entry) => entry.url.startsWith("https://cli-chat-proxy.grok.com/"))) {
    assert.equal(entry.headers.get("authorization"), "Bearer at-fresh", "no Grok request uses the expiring token");
  }
}

// 4. A refresh that comes back for another account is never used or saved.
{
  // Every request on the user's own token is rejected, so only a refresh could finish the turn.
  const world = grokWorld({ rejectToken: "at-mine", refreshedToken: "at-other", refreshedAccount: "someone-else" });
  const saved = [];
  const outcome = await runTurn({
    fetch: world.fetch,
    credentials: () => credentialsFor("at-mine"),
    onCredentials: (credentials) => { saved.push(credentials); },
  }).catch((error) => ({ error }));
  assert.ok(outcome.error || outcome.result.stopReason !== "end_turn", "the turn does not finish on another account's token");
  assert.equal(saved.length, 0, "the host never receives another account's credentials");
  assert.ok(world.log.some((entry) => entry.url === userinfoUrl), "the refreshed token was checked");
  for (const entry of world.log.filter((entry) => entry.url.startsWith("https://cli-chat-proxy.grok.com/"))) {
    assert.notEqual(entry.headers.get("authorization"), "Bearer at-other", "no Grok request uses another account's token");
  }
}

// 5. A durable session asks for its own session's credentials.
{
  const world = grokWorld({});
  const asked = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "grok",
    model: "grok-4.5",
    fetch: world.fetch,
    credentials: (request) => { asked.push(request.sessionId); return credentialsFor("at-durable"); },
  });
  try {
    const turn = agent.session().prompt("say ok");
    const { sessionId } = await turn.accepted;
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.equal(text, "libfx on grok");
    assert.ok(asked.includes(sessionId), "credentials() is asked for the durable session's own credentials");
    assert.equal(replyRequests(world.log)[0].headers.get("x-grok-conv-id"), sessionId);
    assert.equal(world.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false);
  } finally {
    await agent.close();
  }
}

// 6. One agent's sessions refresh an account once, and each session hears the
// refreshed credentials, for a host that keeps them per session.
{
  const world = grokWorld({ refreshedToken: "at-shared" });
  const saved = [];
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "grok",
    model: "grok-4.5",
    fetch: world.fetch,
    credentials: () => credentialsFor("at-expiring", { expiresAt: Date.now() + 60_000 }),
    onCredentials: (credentials, { sessionId }) => { saved.push({ accessToken: credentials.accessToken, sessionId }); },
  });
  try {
    const turns = [agent.session().prompt("say ok"), agent.session().prompt("say ok")];
    const sessionIds = await Promise.all(turns.map(async (turn) => (await turn.accepted).sessionId));
    for (const turn of turns) {
      for await (const event of turn) void event;
      assert.equal((await turn.result).stopReason, "end_turn");
    }
    assert.equal(world.log.filter((entry) => entry.url === tokenUrl).length, 1, "the sessions share one refresh");
    for (const sessionId of sessionIds) {
      assert.ok(saved.some((entry) => entry.sessionId === sessionId && entry.accessToken === "at-shared"), "each session hears the refreshed credentials");
    }
  } finally {
    await agent.close();
  }
}

// 7. A rejection that arrives after another session refreshed retries on the
// new token instead of spending the old refresh token again.
{
  const world = grokWorld({ refreshedToken: "at-new" });
  let rejected = 0;
  let secondSent;
  const bothSent = new Promise((resolve) => { secondSent = resolve; });
  let releaseLate;
  const late = new Promise((resolve) => { releaseLate = resolve; });
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    // The refresh finishes only once both sessions have sent the old token.
    if (url === tokenUrl) await bothSent;
    if (url === responsesUrl) {
      const authorization = new Headers(init.headers).get("authorization");
      if (authorization === "Bearer at-old") {
        rejected += 1;
        if (rejected === 2) {
          secondSent();
          // Rejected only after the first session's refresh has finished.
          await late;
        }
        return Response.json({ error: "token expired" }, { status: 401 });
      }
      if (authorization === "Bearer at-new") releaseLate();
    }
    return world.fetch(input, init);
  };
  const agent = createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "grok",
    model: "grok-4.5",
    fetch,
    credentials: () => credentialsFor("at-old"),
  });
  try {
    const turns = [agent.session().prompt("say ok"), agent.session().prompt("say ok")];
    for (const turn of turns) {
      for await (const event of turn) void event;
      assert.equal((await turn.result).stopReason, "end_turn");
    }
    assert.equal(rejected, 2);
    assert.equal(world.log.filter((entry) => entry.url === tokenUrl).length, 1, "a late rejection does not refresh again");
    assert.equal(replyRequests(world.log).filter((entry) => entry.headers.get("authorization") === "Bearer at-new").length, 2);
  } finally {
    await agent.close();
  }
}

// 8. Two servers that share a lock refresh an account once: the second waits,
// then uses the credentials the first saved.
{
  const world = grokWorld({ refreshedToken: "at-renewed" });
  let stored = credentialsFor("at-expiring", { expiresAt: Date.now() + 60_000 });
  // The refresh finishes only once both servers have asked for credentials, so
  // without the lock each would spend the refresh token.
  const asked = new Set();
  let bothAsked;
  const ready = new Promise((resolve) => { bothAsked = resolve; });
  const fetch = async (input, init = {}) => {
    if (String(input?.url ?? input) === tokenUrl) await ready;
    return world.fetch(input, init);
  };
  let held = Promise.resolve();
  const refreshLock = (_info, refresh) => {
    const run = held.then(refresh);
    held = run.catch(() => {});
    return run;
  };
  const server = (name) => createFxAgent({
    ...backendOptions,
    durability: memory(),
    provider: "grok",
    model: "grok-4.5",
    fetch,
    credentials: () => {
      asked.add(name);
      if (asked.size === 2) bothAsked();
      return stored;
    },
    onCredentials: (credentials) => { stored = credentials; },
    refreshLock,
  });
  const servers = [server("a"), server("b")];
  try {
    const turns = servers.map((agent) => agent.session().prompt("say ok"));
    for (const turn of turns) {
      for await (const event of turn) void event;
      assert.equal((await turn.result).stopReason, "end_turn");
    }
    assert.equal(world.log.filter((entry) => entry.url === tokenUrl).length, 1, "servers that share a lock refresh an account once");
    assert.equal(replyRequests(world.log).filter((entry) => entry.headers.get("authorization") === "Bearer at-renewed").length, 2);
  } finally {
    await Promise.all(servers.map((agent) => agent.close()));
  }
}

// A lock that never runs the refresh fails the request instead of sending the
// expiring credentials.
{
  const world = grokWorld({ refreshedToken: "at-unused" });
  const outcome = await runTurn({
    fetch: world.fetch,
    credentials: () => credentialsFor("at-expiring", { expiresAt: Date.now() + 60_000 }),
    refreshLock: async () => {},
  }).catch((error) => ({ error }));
  assert.ok(outcome.error || outcome.result.stopReason !== "end_turn", "the turn does not finish without a refresh");
  assert.equal(world.log.filter((entry) => entry.url === tokenUrl).length, 0);
  assert.equal(replyRequests(world.log).length, 0, "nothing is sent on credentials the lock never refreshed");
}

// 9. Options are checked before anything starts.
await assert.rejects(createFxEngine({ ...backendOptions, provider: "grok", model: "grok-4.5" }), /provider "grok" needs a credentials\(\) function/);
await assert.rejects(
  createFxEngine({ ...backendOptions, provider: "grok", model: "grok-4.5", credentials: () => credentialsFor("at-first"), refreshLock: "lock" }),
  /refreshLock must be a function/,
);
await assert.rejects(createFxEngine({ ...backendOptions, apiKey: "key", refreshLock: async (_info, refresh) => refresh() }), /refreshLock needs provider "codex" or "grok"/);

console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} Grok agent passed`);
