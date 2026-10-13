#!/usr/bin/env node
// libfx on a real World (@workflow/world-local) through a persistence store
// written outside libfx (world-persistence.mjs): a session stored in a run,
// fencing between two processes, a killed process whose session a new one
// resumes, and checkpoints a load starts from.
//
//   node sdk/tests/test-world-persistence.mjs <world-root> [native|wasm]
//
// <world-root> holds node_modules/@workflow/world-local, such as sdk/durable
// after `npm ci --prefix sdk/durable`: the World libfx bundles.
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxEngine, FxFencedError } from "../node.js";
import { worldPersistence } from "./world-persistence.mjs";

const args = process.argv.slice(2);
const child = args[0] === "--child" ? Object.fromEntries(args.slice(1).map((value, index, all) => index % 2 === 0 ? [value.replace(/^--/, ""), all[index + 1]] : null).filter(Boolean)) : null;
const worldRoot = child ? child.world : args[0];
const backend = child ? child.backend : (args[1] || "native");
if (!worldRoot || !existsSync(join(worldRoot, "node_modules/@workflow/world-local"))) {
  throw new Error("usage: test-world-persistence.mjs <world-root> [native|wasm]; <world-root> must contain @workflow/world-local");
}
const { createWorld } = await import(pathToFileURL(join(worldRoot, "node_modules/@workflow/world-local/dist/index.js")).href);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) : null;
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const userTexts = (prompt) => prompt.filter((message) => message.role === "user").map(textOf);

// "send it" asks for one send_email call, then answers. Any other prompt is
// answered with its own text.
function framesFor(prompt) {
  const asked = prompt.some((message) => message.role === "user" && textOf(message) === "send it");
  if (asked && toolResults(prompt).length === 0) {
    return [
      { type: "tool-call", toolCallId: "call-send", toolName: "send_email", input: { to: "ops@example.com" } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
    ];
  }
  const text = textOf(prompt.filter((message) => message.role === "user").at(-1));
  return [
    { type: "text-delta", id: "answer", delta: asked ? "sent" : `answer to ${text}` },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
  ];
}

async function startGateway() {
  const requests = [];
  const sessionIds = [];
  const server = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ object: "list", data: [{ id: "workflow/model", type: "language" }] }));
        return;
      }
      const prompt = JSON.parse(body).prompt;
      requests.push(prompt);
      sessionIds.push(request.headers["x-session-id"]);
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(framesFor(prompt).map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  return { server, requests, sessionIds, port: server.address().port };
}

// The app's agent, the same in every process: a store for the session, whose
// run id is also the session id.
function defineAgent(port, onSend) {
  const send = {
    description: "Sends an email.",
    inputSchema: { type: "object" },
    writes: true,
    execute: (input) => onSend(input),
  };
  return (persistence, settings = {}) => createFxEngine({
    backend,
    nativeAddon: addon,
    ...(wasm ? { wasm } : {}),
    fetch: (input, init) => {
      const url = new URL(String(input?.url ?? input));
      return url.hostname === "ai-gateway.vercel.sh" ? fetch(`http://127.0.0.1:${port}${url.pathname}`, init) : fetch(input, init);
    },
    apiKey: "workflow-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "workflow/model",
    tools: { send_email: send },
    persistence,
    sessionId: persistence.runId,
    ...settings,
  });
}

const freshWorld = async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  return world;
};

// The session's events, decoded from the records a load returns. Records are
// libfx's bytes; only libfx's own tests read them.
async function storedEvents(world, runId) {
  const { journal } = await worldPersistence(world, { runId }).load();
  return journal.flatMap((record) => JSON.parse(new TextDecoder().decode(record.data)).events);
}

async function until(check, message, ms = 5000) {
  for (const deadline = Date.now() + ms; !(await check());) {
    if (Date.now() > deadline) throw new Error(message);
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
}

// world-local's queue teardown calls undici's Agent.close(), which Bun's
// built-in undici lacks. Only that known failure is skipped, and only on Bun.
async function closeWorld(world) {
  try {
    await world.close?.();
  } catch (error) {
    if (!(process.versions.bun && error instanceof TypeError && error.message.includes("httpAgent?.close"))) throw error;
  }
}

async function run(agent, input, options) {
  const turn = agent.prompt(input, options);
  for await (const _ of turn) {}
  return turn.result;
}

// Child: start a session, report its run id, run "send it", and stop inside
// send_email after its effect, the way a process dies mid-turn. The parent
// kills it there.
if (child) {
  const world = createWorld({ dataDir: child.data, recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(Number(child.port), async () => {
    appendFileSync(child.effects, "send_email\n");
    process.stdout.write("effect\n");
    await new Promise(() => {});
  });
  const store = worldPersistence(world);
  process.stdout.write(`session ${store.runId}\n`);
  const agent = await createAgent(store);
  await run(agent, "send it");
  throw new Error("the child should have been killed inside send_email");
}

const gateway = await startGateway();
const cases = [];
const test = (name, body) => cases.push({ name, body });

test("a session stored in a World restores in a new agent", async () => {
  const world = await freshWorld();
  const createAgent = defineAgent(gateway.port, () => "sent");
  gateway.sessionIds.length = 0;
  const store = worldPersistence(world);
  const agent = await createAgent(store);
  assert.equal((await run(agent, "remember plums")).stopReason, "end_turn");
  await agent.close();
  assert.match(store.runId, /^wrun_/);

  const again = await createAgent(worldPersistence(world, { runId: store.runId }));
  gateway.requests.length = 0;
  await run(again, "what did I say");
  await again.close();
  assert.ok(userTexts(gateway.requests[0]).includes("remember plums"), "the restored session holds the earlier turn");
  assert.ok(gateway.sessionIds.length >= 2 && gateway.sessionIds.every((id) => id === store.runId), JSON.stringify(gateway.sessionIds));
  await closeWorld(world);
});

test("a new session reaches its first model request after three World writes and no reads", async () => {
  const world = await freshWorld();
  const calls = [];
  const events = new Proxy(world.events, {
    get(target, prop) {
      const value = Reflect.get(target, prop);
      if (prop === "create") {
        return (runId, request, params) => {
          calls.push(request.eventType === "step_created" ? request.eventData?.stepName : request.eventType);
          return value.call(target, runId, request, params);
        };
      }
      if (prop === "list") return (...list) => { calls.push("list"); return value.apply(target, list); };
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const recorded = new Proxy(world, { get: (target, prop) => prop === "events" ? events : Reflect.get(target, prop) });
  const store = worldPersistence(recorded);
  const agent = await defineAgent(gateway.port, () => "sent")(store, {
    fetch: (input, init) => {
      const url = new URL(String(input?.url ?? input));
      if ((init?.method ?? "GET") === "POST") calls.push("model");
      return fetch(url.hostname === "ai-gateway.vercel.sh" ? `http://127.0.0.1:${gateway.port}${url.pathname}` : input, init);
    },
  });
  assert.equal((await run(agent, "first words")).stopReason, "end_turn");
  await agent.close();
  assert.deepEqual(calls.slice(0, calls.indexOf("model")), ["run_created", "run_started", "fx.record"]);

  const again = await defineAgent(gateway.port, () => "sent")(worldPersistence(world, { runId: store.runId }));
  gateway.requests.length = 0;
  await run(again, "what came first");
  await again.close();
  assert.ok(userTexts(gateway.requests[0]).includes("first words"), "the new run restores");
  await closeWorld(world);
});

test("a second process on the session fences the first, and its late write is not part of the session", async () => {
  const world = await freshWorld();
  const createAgent = defineAgent(gateway.port, () => "sent");
  const store = worldPersistence(world);
  const first = await createAgent(store);
  await run(first, "one");
  // turn.result does not wait for the turn's last appends, so the takeover
  // waits for the commit to reach the World.
  await until(async () => (await storedEvents(world, store.runId)).some((event) => event.type === "turn_committed"), "the first turn never committed");

  const second = await createAgent(worldPersistence(world, { runId: store.runId }));
  await run(second, "two");
  await second.close();
  const fenced = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause instanceof FxFencedError;
  await assert.rejects(run(first, "three"), fenced);
  await first.close();

  const events = await storedEvents(world, store.runId);
  assert.deepEqual(events.filter((event) => event.type === "turn_committed").map((event) => event.data.user.text), ["one", "two"]);
  const reopened = await createAgent(worldPersistence(world, { runId: store.runId }));
  gateway.requests.length = 0;
  await run(reopened, "and now");
  await reopened.close();
  assert.ok(!userTexts(gateway.requests[0]).includes("three"), "the fenced write left nothing behind");
  await closeWorld(world);
});

test("a killed process's session resumes in a new process, which answers the call it left running", async () => {
  const data = mkdtempSync(join(tmpdir(), "libfx-world-"));
  const effects = join(data, "effects.log");
  const execArgs = backend === "wasm" && !process.versions.bun ? ["--experimental-wasm-jspi"] : [];
  const worker = spawn(process.execPath, [...execArgs, fileURLToPath(import.meta.url), "--child",
    "--world", worldRoot, "--backend", backend, "--data", data,
    "--port", String(gateway.port), "--effects", effects], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  let stdout = "";
  worker.stderr.on("data", (chunk) => { stderr += chunk; });
  await new Promise((resolveEffect, rejectEffect) => {
    worker.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.includes("effect\n")) resolveEffect();
    });
    worker.on("exit", (code) => rejectEffect(new Error(`worker exited (${code}) before the effect: ${stderr}`)));
  });
  worker.kill("SIGKILL");
  await new Promise((resolveExit) => worker.once("close", resolveExit));
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");
  const runId = /session (\S+)\n/.exec(stdout)?.[1];
  assert.ok(runId, stdout);

  let sends = 0;
  const world = createWorld({ dataDir: data, recoverActiveRuns: false });
  await world.start?.();
  const agent = await defineAgent(gateway.port, () => { sends += 1; return "sent"; })(worldPersistence(world, { runId }));
  gateway.requests.length = 0;
  const resumed = agent.resume();
  assert.ok(resumed, "the killed turn is open");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await agent.close();

  assert.equal(sends, 0, "send_email did not run again");
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");
  assert.ok(JSON.stringify(gateway.requests[0]).includes("Resuming from unexpected session interruption."), "the model is told");
  assert.match(JSON.stringify(toolResults(gateway.requests[0])), /may have partly run/);
  const last = (await storedEvents(world, runId)).at(-1);
  assert.equal(last.type, "turn_committed");
  assert.equal(last.data.kind, "assistant");
  assert.equal(last.data.user.text, "send it");
  await closeWorld(world);
});

test("a checkpoint in the run lets a load read only from it on", async () => {
  const world = await freshWorld();
  const createAgent = defineAgent(gateway.port, () => "sent");
  const store = worldPersistence(world);
  const agent = await createAgent(store, { checkpointAfterBytes: 0 });
  await run(agent, "remember plums");
  await run(agent, "send it");
  await run(agent, "and pears", { turnId: "turn-pears" });
  await agent.close();

  let read = 0;
  const events = new Proxy(world.events, {
    get(target, prop) {
      const value = Reflect.get(target, prop);
      if (prop === "list") return async (...list) => { const page = await value.apply(target, list); read += page.data.length; return page; };
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const counted = new Proxy(world, { get: (target, prop) => prop === "events" ? events : Reflect.get(target, prop) });
  const loaded = await worldPersistence(counted, { runId: store.runId, pageSize: 2 }).load();
  assert.ok(loaded.checkpoint, "the run holds a checkpoint");
  assert.equal(loaded.journal.length, 0, "the last checkpoint covers every record");
  const total = (await world.events.list({ runId: store.runId, pagination: { limit: 1000 } })).data.length;
  assert.ok(read < total, `a load read ${read} of ${total} events`);

  const again = await createAgent(worldPersistence(world, { runId: store.runId }));
  gateway.requests.length = 0;
  const retried = again.prompt("and pears", { turnId: "turn-pears" });
  assert.equal((await retried.result).stopReason, "end_turn");
  assert.equal(gateway.requests.length, 0, "the ended turn did not run again");
  await run(again, "what did I say");
  await again.close();
  const users = userTexts(gateway.requests[0]);
  for (const text of ["remember plums", "send it", "and pears", "what did I say"]) assert.ok(users.includes(text), `${text} is in the history`);
  await closeWorld(world);
});

try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`world persistence passed: ${backend}`);
} finally {
  gateway.server.closeAllConnections();
  await new Promise((resolveClose) => gateway.server.close(resolveClose));
}
