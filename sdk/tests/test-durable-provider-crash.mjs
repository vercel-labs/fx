#!/usr/bin/env node
// A durable session on a provider the host authorizes (Codex on a ChatGPT plan,
// Grok on a Grok plan, or a custom provider with an API key) survives a
// SIGKILL. A child process runs a turn on a local() durability and is killed
// during the model's reply or during a tool call; a fresh agent here resumes
// the turn on the credentials its own credentials() supplies. No credential
// reaches the saved session. No network.
//
//   node test-durable-provider-crash.mjs [native|wasm]
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";
import { local } from "../durable/local.mjs";

const args = process.argv.slice(2);
const childAt = args.indexOf("--child");
const backend = args[0] && args[0] !== "--child" ? args[0] : "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-durable-provider-crash.mjs [native|wasm]");
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

const accountId = "acct-crash";
function codexJwt(label) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "none" })}.${part({ exp: Math.floor(Date.now() / 1000) + 864000, "https://api.openai.com/auth": { chatgpt_account_id: accountId }, label })}.sig`;
}

const event = (value) => `data: ${JSON.stringify(value)}\n\n`;
// The wire formats: how a text reply and a lookup call stream, and where a
// request carries the conversation.
const responsesProtocol = {
  history: (payload) => payload.input,
  sawToolOutput: (payload) => JSON.stringify(payload.input).includes("function_call_output"),
  textReply: (text) =>
    event({ type: "response.output_item.added", output_index: 0, item: { type: "message" } }) +
    event({ type: "response.output_text.delta", output_index: 0, delta: text }) +
    event({ type: "response.completed", response: { status: "completed", usage: { input_tokens: 5, output_tokens: 2 } } }),
  lookupCall:
    event({ type: "response.output_item.added", output_index: 0, item: { type: "function_call", call_id: "call_lookup", name: "lookup" } }) +
    event({ type: "response.function_call_arguments.delta", output_index: 0, delta: JSON.stringify({ key: "order-7" }) }) +
    event({ type: "response.completed", response: { status: "completed", usage: { input_tokens: 5, output_tokens: 2 } } }),
};
const chatProtocol = {
  history: (payload) => payload.messages,
  sawToolOutput: (payload) => payload.messages.some((message) => message.role === "tool"),
  textReply: (text) =>
    event({ choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] }) +
    event({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }) +
    "data: [DONE]\n\n",
  lookupCall:
    event({ choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call_lookup", type: "function", function: { name: "lookup", arguments: JSON.stringify({ key: "order-7" }) } }] }, finish_reason: null }] }) +
    event({ choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] }) +
    "data: [DONE]\n\n",
};

// What differs between the providers: the wire format, the fake endpoints
// besides the reply, the credentials, and the headers that carry session and
// account, if any.
const providers = {
  codex: {
    label: "Codex",
    provider: "codex",
    protocol: responsesProtocol,
    model: "gpt-6.1-sol",
    token: codexJwt,
    credentials: (token) => ({ accessToken: token, refreshToken: "rt-crash" }),
    replyUrl: "https://chatgpt.com/backend-api/codex/responses",
    sessionHeader: "session-id",
    accountHeader: "chatgpt-account-id",
    serve(url) {
      if (url === "https://registry.npmjs.org/@openai/codex/latest") return Response.json({ version: "0.162.1" });
      if (url.startsWith("https://chatgpt.com/backend-api/codex/models")) {
        return Response.json({ models: [
          { slug: "gpt-6.1-sol", visibility: "list", supported_in_api: true, priority: 1, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
          { slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true, priority: 2, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 272000 },
        ] });
      }
      return null;
    },
  },
  grok: {
    label: "Grok",
    provider: "grok",
    protocol: responsesProtocol,
    model: "grok-4.5",
    token: (label) => `at-${label}`,
    credentials: (token) => ({ accessToken: token, refreshToken: "rt-crash", accountId, expiresAt: Date.now() + 6 * 3600 * 1000 }),
    replyUrl: "https://cli-chat-proxy.grok.com/v1/responses",
    sessionHeader: "x-grok-conv-id",
    accountHeader: "x-grok-user-id",
    serve(url) {
      if (url === "https://x.ai/cli/stable") return new Response("1.0.50\n");
      if (url === "https://cli-chat-proxy.grok.com/v1/models") {
        return Response.json({ data: [{ id: "grok-4.5", model: "grok-4.5", api_backend: "responses", context_window: 500000, supports_reasoning_effort: true, reasoning_efforts: [{ value: "low" }] }] });
      }
      if (url === "https://api.x.ai/v1/language-models") return Response.json({ models: [] });
      return null;
    },
  },
  // The session reaches credentials() from the agent, not from a header.
  custom: {
    label: "custom provider",
    provider: { name: "local", baseUrl: "https://models.example/v1", models: { "local-model": { supportsToolUse: true } } },
    protocol: chatProtocol,
    model: "local-model",
    token: (label) => `sk-${label}`,
    credentials: (token) => ({ apiKey: token }),
    replyUrl: "https://models.example/v1/chat/completions",
    serve: () => null,
  },
};
// The dying process and the resuming one hold different tokens, so a request
// can show which process authorized it.
const tokensFor = (spec) => ({ child: spec.token("child-process"), parent: spec.token("resuming-process") });

/** A fake provider. `holdReply` streams the first event of a reply and then never finishes it. */
function fakeProvider(spec, { holdReply = false, onReply } = {}) {
  const log = [];
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    log.push({ method, url, headers: new Headers(init.headers), body });
    const served = spec.serve(url);
    if (served) return served;
    if (url === spec.replyUrl && method === "POST") {
      const payload = JSON.parse(body);
      const sawLookup = spec.protocol.sawToolOutput(payload);
      const wantsLookup = JSON.stringify(spec.protocol.history(payload)).includes("use lookup");
      // A request that allows no tool calls gets text, as a real model gives.
      const reply = wantsLookup && !sawLookup && payload.tool_choice !== "none"
        ? spec.protocol.lookupCall
        : spec.protocol.textReply(sawLookup ? "found order-7" : wantsLookup ? "could not confirm order-7" : "hello again");
      onReply?.(payload);
      if (!holdReply) return new Response(reply, { status: 200, headers: { "content-type": "text/event-stream" } });
      const firstEvent = reply.slice(0, reply.indexOf("\n\n") + 2);
      return new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode(firstEvent)); } }), {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

function agentOptions(dir, spec, { fetch, token, asked, lookupRuns, lookupStarted, events }) {
  return {
    ...backendOptions,
    ...(events ? { onEvent: (event) => events.push(event) } : {}),
    durability: local({ dir }),
    provider: spec.provider,
    model: spec.model,
    fetch,
    credentials: (request) => { asked?.push(request.sessionId); return spec.credentials(token); },
    tools: [{
      name: "lookup",
      description: "Looks up an order",
      idempotent: true,
      inputSchema: { type: "object", properties: { key: { type: "string" } } },
      execute: async ({ key }, { sessionId }) => {
        lookupRuns?.push(sessionId);
        if (lookupStarted) {
          // A call starts only after its intent is stored, so the crash
          // comes the moment the tool runs.
          lookupStarted();
          await new Promise(() => {}); // the process dies here
        }
        return { content: `${key} shipped` };
      },
    }],
  };
}

// The child: start a turn, report the session once the crash point is reached, wait to be killed.
if (childAt !== -1) {
  const [dir, phase, provider] = args.slice(childAt + 1);
  const spec = providers[provider];
  let reached;
  const crashPoint = new Promise((resolveReached) => { reached = resolveReached; });
  const fake = fakeProvider(spec, { holdReply: phase === "reply", onReply: () => { if (phase === "reply") reached(); } });
  const agent = createFxAgent(agentOptions(dir, spec, {
    fetch: fake.fetch,
    token: tokensFor(spec).child,
    ...(phase === "tool" ? { lookupStarted: () => reached() } : {}),
  }));
  const turn = agent.session().prompt(phase === "tool" ? "use lookup for order-7" : "say hello");
  const { sessionId } = await turn.accepted;
  await crashPoint;
  process.stdout.write(`${JSON.stringify({ sessionId })}\n`);
  await new Promise(() => {});
}

// True when the text, or base64 found in it decoded up to two levels deep,
// contains any of the secrets. The local World stores entries as base64.
function holdsSecret(text, secrets, depth = 2) {
  if (secrets.some((secret) => text.includes(secret))) return true;
  if (depth === 0) return false;
  for (const [encoded] of text.matchAll(/[A-Za-z0-9+/_-]{24,}={0,2}/g)) {
    const decoded = Buffer.from(encoded, "base64").toString("latin1");
    if (holdsSecret(decoded, secrets, depth - 1)) return true;
  }
  return false;
}

async function filesUnder(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await filesUnder(path));
    else if ((await stat(path)).size < 16 * 1024 * 1024) out.push(path);
  }
  return out;
}

async function crashAndResume(provider, phase) {
  const spec = providers[provider];
  const tokens = tokensFor(spec);
  const dir = await mkdtemp(join(tmpdir(), `libfx-${provider}-crash-`));
  try {
    const child = spawn(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), backend, "--child", dir, phase, provider], {
      stdio: ["ignore", "pipe", "inherit"],
      env: { ...process.env },
    });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    const started = Date.now();
    while (!output.includes("\n")) {
      if (child.exitCode !== null) throw new Error(`the ${phase} child exited early with ${child.exitCode}`);
      if (Date.now() - started > 30_000) throw new Error(`the ${phase} child never reached its crash point`);
      await new Promise((wait) => setTimeout(wait, 20));
    }
    const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
    child.kill("SIGKILL");
    const [, signal] = await new Promise((exited) => child.once("exit", (code, sig) => exited([code, sig])));
    assert.equal(signal, "SIGKILL", "the child died by SIGKILL, mid-turn");

    const fake = fakeProvider(spec);
    const asked = [];
    const lookupRuns = [];
    const events = [];
    const agent = createFxAgent(agentOptions(dir, spec, { fetch: fake.fetch, token: tokens.parent, asked, lookupRuns, events }));
    let text = "";
    const lines = [];
    try {
      const resumed = agent.session(sessionId).resume();
      for await (const line of resumed) {
        lines.push(line);
        if (line.type === "text_delta") text += line.delta;
      }
      const result = await resumed.result;
      const seen = () => JSON.stringify({
        lines: lines.map(({ type, name, isError, content, text: lineText }) => ({ type, name, isError, content, text: lineText })),
        requests: fake.log.filter((entry) => entry.method === "POST").map((entry) => spec.protocol.history(JSON.parse(entry.body))),
        events: events.map(({ type, error, message, status, reason }) => ({ type, error, message, status, reason })),
        result,
      }).slice(0, 6000);
      assert.equal(result.stopReason, "end_turn", `the ${spec.label} ${phase} crash leaves a turn that resumes to its end; saw ${seen()}`);
    } finally {
      await agent.close();
    }

    const replies = fake.log.filter((entry) => entry.url === spec.replyUrl);
    assert.ok(replies.length >= 1, `the resumed turn called ${spec.label}`);
    for (const reply of replies) {
      assert.equal(reply.headers.get("authorization"), `Bearer ${tokens.parent}`, "the resuming process authorizes with its own credentials");
      if (spec.accountHeader) assert.equal(reply.headers.get(spec.accountHeader), accountId);
      if (spec.sessionHeader) assert.equal(reply.headers.get(spec.sessionHeader), sessionId, "the resumed requests belong to the crashed session");
    }
    assert.ok(asked.includes(sessionId), "credentials() is asked for the crashed session's credentials");
    assert.equal(fake.log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false);
    const history = JSON.stringify(spec.protocol.history(JSON.parse(replies.at(-1).body)));
    if (phase === "reply") {
      assert.match(history, /say hello/, "the resumed turn keeps the user's prompt");
      assert.equal(text, "hello again");
    } else {
      assert.match(history, /use lookup for order-7/);
      assert.deepEqual(lookupRuns, [sessionId], "the idempotent lookup ran again, once, in the resuming process");
      assert.match(history, /order-7 shipped/, "the model received the rerun lookup's result");
      assert.equal(text, "found order-7");
    }

    // The saved session holds no credentials from either process.
    const files = await filesUnder(dir);
    assert.ok(files.length > 0, "the session was saved");
    for (const path of files) {
      const bytes = await readFile(path, "latin1");
      assert.equal(holdsSecret(bytes, [tokens.child, tokens.parent, "rt-crash"]), false, `${path} must not contain ${spec.label} credentials`);
    }
    return { sessionId, replies: replies.length, resumeMs: Date.now() - started };
  } catch (error) {
    if (process.env.PROVIDER_CRASH_KEEP) console.error(`kept ${dir}`);
    throw error;
  } finally {
    if (!process.env.PROVIDER_CRASH_KEEP) await rm(dir, { recursive: true, force: true });
  }
}

for (const provider of Object.keys(providers)) {
  for (const phase of ["reply", "tool"]) {
    const result = await crashAndResume(provider, phase);
    const label = providers[provider].label;
    console.log(`  ${backend} crash during the ${phase === "reply" ? `${label} reply` : `${label} lookup tool`}: resumed with ${result.replies} request(s), ${result.resumeMs} ms from start to resumed end`);
  }
}
console.log(`${process.versions.bun ? "Bun" : "Node"} ${backend} durable provider crash passed`);
