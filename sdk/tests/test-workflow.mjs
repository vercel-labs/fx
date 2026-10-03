#!/usr/bin/env node
// libfx on a real World (@workflow/world-local), through
// `createFxAgent({ world })` and `worldHandler`: a session stored in a run,
// fencing between two processes, and a killed process whose session the queue
// route resumes with no caller.
//
//   node sdk/tests/test-workflow.mjs <world-root> [native|wasm]
//
// <world-root> holds node_modules/@workflow/world-local, installed at test
// time; libfx itself depends on no @workflow package.
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxAgent, FxFencedError, worldHandler } from "../node.js";

// The Workflow queue topic prefix libfx's runs use.
const queuePrefix = "__wkf_workflow_";

const args = process.argv.slice(2);
const child = args[0] === "--child" ? Object.fromEntries(args.slice(1).map((value, index, all) => index % 2 === 0 ? [value.replace(/^--/, ""), all[index + 1]] : null).filter(Boolean)) : null;
const worldRoot = child ? child.world : args[0];
const backend = child ? child.backend : (args[1] || "native");
if (!worldRoot || !existsSync(join(worldRoot, "node_modules/@workflow/world-local"))) {
  throw new Error("usage: test-workflow.mjs <world-root> [native|wasm]; <world-root> must contain @workflow/world-local");
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

// The app's agent definition, the same in every process. `settings` carries
// the World options: `world`, and `sessionId` or `wakeAfterSeconds`.
function defineAgent(port, onSend, description = "Sends an email.") {
  const send = {
    description,
    inputSchema: { type: "object" },
    replay: "never",
    writes: true,
    execute: (input) => onSend(input),
  };
  return (settings) => createFxAgent({
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
    ...settings,
  });
}

// The queue route over `world`, building agents with `build`, counting each.
function route(world, build, onAgent = () => {}) {
  return worldHandler({
    world,
    wakeAfterSeconds: 1,
    createAgent: ({ sessionId }) => {
      onAgent();
      return build({ world, sessionId, wakeAfterSeconds: 1 });
    },
  });
}

const payloadOf = (bytes) => {
  if (!(bytes instanceof Uint8Array)) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
};

// The journal events a run holds, by the rule libfx loads with: a batch
// counts only if it continues the events before it.
async function storedEvents(world, runId) {
  const events = [];
  for (let cursor; ;) {
    const page = await world.events.list({ runId, pagination: { sortOrder: "asc", limit: 1000, ...(cursor ? { cursor } : {}) }, resolveData: "all" });
    for (const event of page.data) {
      const input = event.eventType === "step_created" && event.eventData?.stepName === "libfx.journal" ? payloadOf(event.eventData.input) : null;
      const batch = input?.format === "libfx-journal-v1" && Array.isArray(input.events) && input.events.length > 0 ? input.events : null;
      if (batch && batch[0].seq === events.length + 1) events.push(...batch);
    }
    if (!page.hasMore) break;
    cursor = page.cursor;
  }
  return events;
}

// A run the way libfx writes one, holding `events` as one journal batch.
async function seedRun(world, events) {
  const created = await world.events.create(null, {
    eventType: "run_created",
    ...(world.specVersion === undefined ? {} : { specVersion: world.specVersion }),
    eventData: { deploymentId: "libfx", workflowName: "libfx", input: new TextEncoder().encode(JSON.stringify({ format: "libfx-journal-v1" })) },
  });
  const runId = created.run?.runId ?? created.event?.runId;
  if (events.length > 0) {
    await world.events.create(runId, {
      eventType: "step_created",
      correlationId: `fxj_1_${crypto.randomUUID()}`,
      eventData: { stepName: "libfx.journal", input: new TextEncoder().encode(JSON.stringify({ format: "libfx-journal-v1", events })) },
    }, { eventCount: 1 });
  }
  return runId;
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

async function run(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

// Starts "send it", hands the turn off once send_email has started, and
// closes the agent, leaving the turn open for the queue route.
async function handOff(world, build, sending) {
  const owner = await build({ world, wakeAfterSeconds: 1 });
  const sessionId = owner.sessionId;
  const turn = owner.prompt("send it");
  const drained = (async () => { for await (const _ of turn) {} })().catch(() => {});
  await sending;
  turn.cancel({ reason: "handoff" });
  await turn.result.catch(() => {});
  await drained;
  await owner.close();
  return sessionId;
}

const within = (promise, ms, message) => Promise.race([
  promise,
  new Promise((_, rejectLate) => setTimeout(() => rejectLate(new Error(message)), ms)),
]);

// Child: run "send it" and stop inside send_email after its effect, the way
// a process dies mid-turn. The parent kills it there.
if (child) {
  const world = createWorld({ dataDir: child.data, recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(Number(child.port), async () => {
    appendFileSync(child.effects, "send_email\n");
    process.stdout.write("effect\n");
    await new Promise(() => {});
  });
  const agent = await createAgent({ world, sessionId: child.session });
  await run(agent, "send it");
  throw new Error("the child should have been killed inside send_email");
}

const gateway = await startGateway();
const cases = [];
const test = (name, body) => cases.push({ name, body });

test("a session stored in a World restores in a new agent", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(gateway.port, () => "sent");
  gateway.sessionIds.length = 0;
  const agent = await createAgent({ world });
  const sessionId = agent.sessionId;
  assert.equal((await run(agent, "remember plums")).stopReason, "end_turn");
  await agent.close();
  assert.match(sessionId, /^wrun_/);

  const again = await createAgent({ world, sessionId });
  gateway.requests.length = 0;
  await run(again, "what did I say");
  await again.close();
  const users = gateway.requests[0].filter((message) => message.role === "user").map(textOf);
  assert.ok(users.includes("remember plums"), "the restored session holds the earlier turn");
  // The run id is the session id in every gateway request, before and after the restore.
  assert.ok(gateway.sessionIds.length >= 2 && gateway.sessionIds.every((id) => id === sessionId), JSON.stringify(gateway.sessionIds));
  await closeWorld(world);
});

test("a new session reaches its first model request after three World writes and no reads", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
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
  const agent = await defineAgent(gateway.port, () => "sent")({
    world: recorded,
    fetch: (input, init) => {
      const url = new URL(String(input?.url ?? input));
      if ((init?.method ?? "GET") === "POST") calls.push("model");
      return fetch(url.hostname === "ai-gateway.vercel.sh" ? `http://127.0.0.1:${gateway.port}${url.pathname}` : input, init);
    },
  });
  assert.equal((await run(agent, "first words")).stopReason, "end_turn");
  await agent.close();
  assert.deepEqual(calls.slice(0, calls.indexOf("model")), ["run_created", "run_started", "libfx.journal"]);

  const again = await defineAgent(gateway.port, () => "sent")({ world, sessionId: agent.sessionId });
  gateway.requests.length = 0;
  await run(again, "what came first");
  await again.close();
  assert.ok(gateway.requests[0].some((message) => message.role === "user" && textOf(message) === "first words"), "the new run restores");
  await closeWorld(world);
});

test("a second process on the session fences the first", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(gateway.port, () => "sent");
  const first = await createAgent({ world });
  const sessionId = first.sessionId;
  await run(first, "one");
  // turn.result does not wait for the turn's last appends, so the takeover
  // waits for the commit to reach the World.
  await until(async () => (await storedEvents(world, sessionId)).some((event) => event.type === "turn_committed"), "the first turn never committed");

  const second = await createAgent({ world, sessionId });
  await run(second, "two");
  await second.close();
  const fenced = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause instanceof FxFencedError;
  await assert.rejects(run(first, "three"), fenced);
  // The failure was reported once, so close() has nothing left to report.
  await first.close();

  const events = await storedEvents(world, sessionId);
  const commits = events.filter((event) => event.type === "turn_committed").map((event) => event.data.user.text);
  assert.deepEqual(commits, ["one", "two"]);
  await closeWorld(world);
});

test("a killed process's session resumes from the queue with no caller", async () => {
  const data = mkdtempSync(join(tmpdir(), "libfx-world-"));
  const effects = join(data, "effects.log");
  const setup = createWorld({ dataDir: data, recoverActiveRuns: false });
  await setup.start?.();
  const sessionId = await seedRun(setup, []);
  await closeWorld(setup);

  const execArgs = backend === "wasm" && !process.versions.bun ? ["--experimental-wasm-jspi"] : [];
  const worker = spawn(process.execPath, [...execArgs, fileURLToPath(import.meta.url), "--child",
    "--world", worldRoot, "--backend", backend, "--data", data, "--session", sessionId,
    "--port", String(gateway.port), "--effects", effects], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  worker.stderr.on("data", (chunk) => { stderr += chunk; });
  await new Promise((resolveEffect, rejectEffect) => {
    worker.stdout.on("data", (chunk) => { if (String(chunk).includes("effect")) resolveEffect(); });
    worker.on("exit", (code) => rejectEffect(new Error(`worker exited (${code}) before the effect: ${stderr}`)));
  });
  worker.kill("SIGKILL");
  await new Promise((resolveExit) => worker.once("close", resolveExit));
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");

  // A new process: starting the World re-enqueues the session's run, and the
  // queue delivers it to the route.
  // The first delivery comes right after the kill, before the turn has been
  // silent for wakeAfterSeconds, so the route checks again later.
  let sends = 0;
  let agents = 0;
  const deliveries = [];
  const world = createWorld({ dataDir: data, recoverActiveRuns: true });
  const build = defineAgent(gateway.port, () => { sends += 1; return "sent"; });
  const handler = route(world, build, () => { agents += 1; });
  gateway.requests.length = 0;
  const resumed = new Promise((resolveResumed, rejectResumed) => {
    world.registerHandler(queuePrefix, async (request) => {
      try {
        const before = agents;
        const response = await handler(request);
        deliveries.push({ status: response.status, resumed: agents > before });
        if (agents > before) resolveResumed();
        return response;
      } catch (error) {
        rejectResumed(error);
        throw error;
      }
    });
  });
  await world.start();
  await resumed;
  await closeWorld(world);
  assert.equal(agents, 1);
  assert.deepEqual(deliveries.map((delivery) => delivery.resumed), [false, true]);
  assert.ok(deliveries.every((delivery) => delivery.status === 204));

  assert.equal(sends, 0, "send_email did not run again");
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");
  const body = JSON.stringify(gateway.requests[0]);
  assert.ok(body.includes("Resuming from unexpected session interruption."), "the model is told");
  assert.match(JSON.stringify(toolResults(gateway.requests[0])), /may have partly run/);

  // The session's journal now ends with the resumed turn committed.
  const reader = createWorld({ dataDir: data, recoverActiveRuns: false });
  const last = (await storedEvents(reader, sessionId)).at(-1);
  assert.equal(last.type, "turn_committed");
  assert.equal(last.data.kind, "assistant");
  assert.equal(last.data.user.text, "send it");
  await closeWorld(reader);
});

test("a wake while the owner is still running does not take the session over", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  let sends = 0;
  let agents = 0;
  let deliveries = 0;
  // send_email outlasts wakeAfterSeconds; the owner's heartbeats keep the turn fresh.
  const build = defineAgent(gateway.port, async () => {
    sends += 1;
    await new Promise((resolveSend) => setTimeout(resolveSend, 2500));
    return "sent";
  });
  const handler = route(world, build, () => { agents += 1; });
  world.registerHandler(queuePrefix, async (request) => {
    deliveries += 1;
    return handler(request);
  });
  const owner = await build({ world, wakeAfterSeconds: 1 });
  assert.equal((await run(owner, "send it")).stopReason, "end_turn");
  await owner.close();
  // Let the last queued check arrive and find the turn closed.
  await new Promise((resolveWait) => setTimeout(resolveWait, 1500));
  await closeWorld(world);
  assert.ok(deliveries >= 2, `the queue delivered ${deliveries} wakes during the turn`);
  assert.equal(agents, 0, "no wake took the session over");
  assert.equal(sends, 1);
});

test("a handed-off turn goes quiet when its agent closes, and the queue resumes it", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  let sends = 0;
  let agents = 0;
  let started;
  const sending = new Promise((resolveSending) => { started = resolveSending; });
  const build = defineAgent(gateway.port, () => {
    sends += 1;
    started();
    return new Promise(() => {});
  });
  const handler = route(world, build, () => { agents += 1; });
  let resumedStatus;
  const resumed = new Promise((resolveResumed) => { resumedStatus = resolveResumed; });
  world.registerHandler(queuePrefix, async (request) => {
    const before = agents;
    const response = await handler(request);
    if (agents > before) resumedStatus(response.status);
    return response;
  });
  await handOff(world, build, sending);
  // Without the close, the owner's heartbeat would keep the turn fresh.
  const status = await within(resumed, 10_000, "the queue never resumed the handed-off turn");
  await closeWorld(world);
  assert.equal(status, 204);
  assert.equal(agents, 1);
  assert.equal(sends, 1, "send_email did not run again");
});

test("the queue route acknowledges a turn it cannot resume under another config", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  let started;
  const sending = new Promise((resolveSending) => { started = resolveSending; });
  const build = defineAgent(gateway.port, () => { started(); return new Promise(() => {}); });
  // The next deployment describes send_email differently.
  const changed = defineAgent(gateway.port, () => "sent", "Sends an email with a signature.");
  const handler = route(world, changed);
  const deliveries = [];
  let acknowledged;
  const answered = new Promise((resolveAnswered) => { acknowledged = resolveAnswered; });
  world.registerHandler(queuePrefix, async (request) => {
    const response = await handler(request);
    deliveries.push({ status: response.status, text: await response.clone().text() });
    if (response.status === 200) acknowledged();
    return response;
  });
  await handOff(world, build, sending);
  await within(answered, 10_000, "the queue route never answered the wake");
  // An answered wake is not delivered again.
  await new Promise((resolveWait) => setTimeout(resolveWait, 1500));
  await closeWorld(world);
  const answers = deliveries.filter((delivery) => delivery.status === 200);
  assert.equal(answers.length, 1, JSON.stringify(deliveries));
  assert.match(answers[0].text, /was not resumed: the open turn started under other/);
  assert.equal(deliveries.at(-1).status, 200, "no wake followed the answer");
});

test("the queue route acknowledges a session no libfx can open", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  // An open turn whose progress does not fold.
  const sessionId = await seedRun(world, [{ v: 1, seq: 1, turn: 1, type: "turn_progress", data: { not: "a checkpoint" } }]);
  const handler = route(world, defineAgent(gateway.port, () => "sent"));
  await new Promise((resolveWait) => setTimeout(resolveWait, 1200));
  const response = await handler(new Request("http://localhost/queue", { method: "POST", body: JSON.stringify({ runId: sessionId }) }));
  await closeWorld(world);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /was not resumed: Invalid libfx journal/);
});

test("the queue route recognizes a config mismatch from another copy of libfx", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const sessionId = await seedRun(world, [{ v: 1, seq: 1, turn: 1, type: "turn_progress", data: {} }]);
  // The CommonJS bundle carries its own copy of the error class.
  const foreign = () => Object.assign(new Error("the open turn started under other instructions, tools or model"), { code: "FX_CONFIG_MISMATCH" });
  let closed = 0;
  const handler = worldHandler({
    world,
    wakeAfterSeconds: 1,
    createAgent: async ({ sessionId: opened }) => ({ sessionId: opened, resume() { throw foreign(); }, async close() { closed += 1; } }),
  });
  await new Promise((resolveWait) => setTimeout(resolveWait, 1200));
  const response = await handler(new Request("http://localhost/queue", { method: "POST", body: JSON.stringify({ runId: sessionId }) }));
  await closeWorld(world);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /was not resumed: the open turn started under other/);
  assert.equal(closed, 1);
});

test("the queue route refuses an agent on another session", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const sessionId = await seedRun(world, [{ v: 1, seq: 1, turn: 1, type: "turn_progress", data: {} }]);
  // This createAgent drops the sessionId, so it would open a new run.
  const build = defineAgent(gateway.port, () => "sent");
  const handler = worldHandler({ world, wakeAfterSeconds: 1, createAgent: () => build({ world }) });
  await new Promise((resolveWait) => setTimeout(resolveWait, 1200));
  await assert.rejects(
    handler(new Request("http://localhost/queue", { method: "POST", body: JSON.stringify({ runId: sessionId }) })),
    /createAgent\(\{ sessionId \}\) must open that session/,
  );
  await closeWorld(world);
});

test("a World that cannot queue a wake keeps the session", async () => {
  const inner = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await inner.start?.();
  // Outside a deployment, world-vercel refuses to queue.
  const world = { ...inner, queue: async () => { throw new Error("no deployment"); }, events: inner.events };
  const failures = [];
  const createAgent = defineAgent(gateway.port, () => "sent");
  const agent = await createAgent({ world, onEvent: (event) => { if (event.type === "journal.wake_failed") failures.push(event); } });
  const sessionId = agent.sessionId;
  assert.equal((await run(agent, "remember plums")).stopReason, "end_turn");
  assert.equal((await run(agent, "and pears")).stopReason, "end_turn");
  await agent.close();
  assert.deepEqual(failures.map((event) => event.message), ["no deployment"]);
  const again = await createAgent({ world, sessionId });
  gateway.requests.length = 0;
  await run(again, "what did I say");
  await again.close();
  assert.ok(gateway.requests[0].some((message) => message.role === "user" && textOf(message) === "and pears"));
  await closeWorld(inner);
});

test("a write that skips only another writer's heartbeat is not fenced", async () => {
  // Reports what a write skipped as world-vercel does: every event after the
  // writer's count, through the new one.
  const events = [];
  let foreignHeartbeat = true;
  const slotted = (request) => ({ ...request, eventId: `evnt_${String(events.length + 1).padStart(26, "0")}`, createdAt: new Date() });
  const world = {
    events: {
      async create(_runId, request, params = {}) {
        if (foreignHeartbeat && request.eventData?.stepName === "libfx.journal") {
          foreignHeartbeat = false;
          events.push(slotted({ eventType: "step_created", eventData: { stepName: "libfx.heartbeat", input: new Uint8Array() } }));
        }
        const event = slotted(request);
        events.push(event);
        return { event, events: events.slice(params.eventCount ?? 0) };
      },
      list: async () => ({ data: [...events], hasMore: false }),
    },
    queue: async () => {},
  };
  const agent = await defineAgent(gateway.port, () => "sent")({ world, sessionId: "wrun_test" });
  assert.equal((await run(agent, "one")).stopReason, "end_turn");
  assert.equal((await run(agent, "two")).stopReason, "end_turn");
  await agent.close();
});

test("a World event id without a slot stops the write", async () => {
  const world = {
    events: {
      create: async () => ({ event: { eventId: "event-without-a-slot" } }),
      list: async () => ({ data: [], hasMore: false }),
    },
    queue: async () => {},
  };
  const agent = await defineAgent(gateway.port, () => "sent")({ world, sessionId: "wrun_test" });
  await assert.rejects(
    run(agent, "hello"),
    (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && /cannot read a slot from/.test(error.cause?.message),
  );
  await agent.close();
});

test("world takes no journal or checkpoint, and wakeAfterSeconds needs world", async () => {
  const world = { events: { create: async () => ({}), list: async () => ({ data: [], hasMore: false }) }, queue: async () => {} };
  const build = defineAgent(gateway.port, () => "sent");
  await assert.rejects(build({ world, journal: { append() {}, async load() { return { events: [] }; } } }), /world cannot be combined with journal/);
  await assert.rejects(build({ world, checkpoint: new Uint8Array(8) }), /world cannot be combined with checkpoint/);
  await assert.rejects(build({ wakeAfterSeconds: 1 }), /wakeAfterSeconds needs world/);
  await assert.rejects(build({ world: { events: {} } }), /world must be a Workflow World/);
  assert.throws(() => worldHandler({ world }), /createAgent must be a function/);
});

try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`World integration passed: ${backend}`);
} finally {
  gateway.server.closeAllConnections();
  await new Promise((resolveClose) => gateway.server.close(resolveClose));
}
