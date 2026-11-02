#!/usr/bin/env bun
// Drives real libfx durable agents along the TLC state graph of
// TenantIsolation.tla, and checks after every step that the code is in a
// state the model allows.
//
//   bun tests/tla/drivers/drive-tenants.mjs [--walks N] [--depth N] [--seed S]
//
// `tests/tla/sdk/check.sh` model-checks the spec and writes
// graphs/tenants-route.dot, the "four" topology with every rule on.
//
// This process is the shared function. Four tenants each create one agent
// in it, as the model's Register steps say: acme and evil both name theirs
// "support" on store key k1 but keep their sessions in different Worlds, bob
// names his "billing" on acme's World, and carl names his "support" on store
// key k2. Every World delivers only over HTTP, to one wakeHandler() route, as
// vercel() does, and its queue is the driver's: it holds each message until a
// Deliver step posts it to the route. A Forge step posts a delivery no queue
// sent, as anyone who can reach the route can. The harness is scripted: its
// turns record which tenant's agent ran them, in which World, with which
// context, which is what the model checks.
//
// After each step the driver reads every session's log in every World, the
// turns that ran, and what is queued, and keeps the model states that match.
// A step that leaves none is a conformance failure.
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createDurableAgentFactory, foldSessionLog, wakeHandler } from "../../../sdk/durable.js";
import { world } from "../../../sdk/durable/world.mjs";
import { loadGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const walks = Number(option("walks", 40));
const depth = Number(option("depth", 14));
let seed = Number(option("seed", Date.now() % 100000));
const firstSeed = seed;
// A small deterministic generator, so a failing walk can be run again.
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const pick = (items) => items[Math.floor(random() * items.length)];

const here = fileURLToPath(new URL(".", import.meta.url));
const { createWorld } = await import(new URL("../../../sdk/durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const graph = await loadGraph(resolve(here, "../sdk/graphs/tenants-route.dot"));
const durableInternals = Symbol.for("libfx.durableInternals");
const encoder = new TextEncoder();

// The "four" topology, as TenantIsolation.tla defines it.
const tenants = ["acme", "evil", "bob", "carl"];
const nameOf = { acme: "support", evil: "support", bob: "billing", carl: "support" };
const keyOf = { acme: "k1", evil: "k1", bob: "k1", carl: "k2" };
const storeOf = { acme: "A", evil: "B", bob: "A", carl: "C" };
const stores = ["A", "B", "C"];
const keyOfStore = { A: "k1", B: "k1", C: "k2" };
// Comfortably over the limit libfx admits for one input (sdk/durable.js
// maxInputBytes).
const oversizeBytes = 9 * 1024 * 1024;

// ---------------------------------------------------------------------------
// The code under test.

// Every turn any agent ran, as the harness saw it.
const turns = [];
const createTenantAgent = createDurableAgentFactory({
  name: "createTenantAgent",
  defaultDurability: async () => { throw new Error("the driver passes a durability"); },
  harness: ({ tenant, storeOfDurability }) => ({
    async open({ sessionId, store, context, durability }) {
      await store.load();
      return {
        prompt(_input, { turnId }) {
          const result = (async () => {
            await store.append({ idempotencyKey: `${turnId}:start`, data: encoder.encode(JSON.stringify({ turnId, start: true })), marks: [{ start: turnId }] });
            turns.push({ tenant, store: storeOfDurability(durability), sessionId, turnId, context });
            await store.append({ idempotencyKey: `${turnId}:end`, data: encoder.encode(JSON.stringify({ turnId, end: true })), marks: [{ end: true }] });
            return { stopReason: "end_turn" };
          })();
          return { result, steer: async () => {}, cancel() {}, async *[Symbol.asyncIterator]() { await result; } };
        },
        resume() {
          throw new Error("no turn of this harness is ever left open");
        },
        get openTurn() {
          return null;
        },
        settled: async () => {},
        saveCheckpoint: async () => {},
        exportCheckpoint: async () => new Uint8Array(),
        close: async () => {},
      };
    },
  }),
});

// The queue every World shares: each message, until a step delivers it.
const held = [];
const keys = new Set();
let queued = 0;
function enqueue(queueName, payload, idempotencyKey) {
  queued += 1;
  const messageId = `msg_${String(queued).padStart(6, "0")}`;
  if (idempotencyKey !== undefined && keys.has(idempotencyKey)) return { messageId };
  if (idempotencyKey !== undefined) keys.add(idempotencyKey);
  held.push({ messageId, queueName, payload, attempt: 0 });
  return { messageId };
}

// A World over `dir` that delivers only to the route the driver posts to.
function routeWorld(dir) {
  const stored = createWorld({ dataDir: dir, recoverActiveRuns: false });
  return {
    stored,
    instance: {
      ...stored,
      registerHandler: undefined,
      queue: async (queueName, payload, { idempotencyKey } = {}) => enqueue(queueName, payload, idempotencyKey),
      createQueueHandler: (_prefix, handler) => async (request) => {
        const { payload, meta } = await request.json();
        try {
          await handler(payload, meta);
          return Response.json({ ok: true });
        } catch (error) {
          return Response.json({ code: error?.code ?? null, message: String(error?.message ?? error) }, { status: 500 });
        }
      },
    },
  };
}

let posted = 0;
async function post(payload) {
  posted += 1;
  const meta = { queueName: "__libfx_wkf_workflow_session", messageId: `msg_post_${posted}`, attempt: 1 };
  const response = await wakeHandler()(new Request("https://app.example/api/libfx", { method: "POST", body: JSON.stringify({ payload, meta }) }));
  return { status: response.status, body: await response.json().catch(() => null) };
}

async function openWalk() {
  const base = await mkdtemp(join(tmpdir(), "libfx-tenants-"));
  const worlds = {};
  const durabilities = {};
  const labelOf = new Map();
  for (const st of stores) {
    worlds[st] = routeWorld(join(base, st));
    await worlds[st].stored.start?.();
    durabilities[st] = world(worlds[st].instance, { store: keyOfStore[st], queueDurable: true, runInRequest: false, pollMs: 250 });
    labelOf.set(durabilities[st], st);
  }
  const storeOfDurability = (durability) => labelOf.get(durability) ?? "?";
  // One reader per World, named apart from every tenant's agent.
  const observers = {};
  for (const st of stores) {
    observers[st] = createTenantAgent({ name: `observer-${st}`, durability: durabilities[st], tenant: `observer-${st}`, storeOfDurability });
  }
  held.length = 0;
  keys.clear();
  turns.length = 0;
  // Each tenant's session, a run id a World accepts.
  const sessionOf = {};
  for (const t of tenants) sessionOf[t] = await observers.A.newSessionId();
  const tenantOfSession = new Map(tenants.map((t) => [sessionOf[t], t]));
  const walk = { base, worlds, durabilities, storeOfDurability, observers, sessionOf, tenantOfSession, agents: {}, refused: new Set(), sent: [] };
  walk.close = async () => {
    for (const agent of [...Object.values(walk.agents), ...Object.values(observers)]) await agent.close().catch(() => {});
    for (const st of stores) await Promise.resolve(worlds[st].stored.close?.()).catch(() => {});
    await rm(base, { recursive: true, force: true });
  };
  return walk;
}

// ---------------------------------------------------------------------------
// The code's state, in the model's terms.

const idOf = (messageId) => (messageId === "f0" ? 0 : /^m(\d+)$/.test(messageId ?? "") ? Number(messageId.slice(1)) : `?${messageId}`);
const contextOf = (context) => (context === undefined || context === null ? "none" : typeof context.tenant === "string" ? context.tenant : "?");
const sizeOf = (input) => (JSON.stringify(input ?? "").length > oversizeBytes - 1024 ? "big" : "ok");

async function observe(walk) {
  const { sessionOf, tenantOfSession } = walk;
  const log = {};
  const owner = {};
  const done = {};
  for (const st of stores) {
    log[st] = [];
    owner[st] = {};
    done[st] = [];
    const internals = walk.observers[st][durableInternals];
    for (const t of tenants) {
      const entries = await (await internals.openLog(sessionOf[t])).read();
      const folded = foldSessionLog(entries);
      owner[st][t] = folded.agent ?? "none";
      for (const { entry } of entries) {
        if (entry?.k !== "input" || (entry.type !== "prompt" && entry.type !== "steer")) continue;
        log[st].push({ id: idOf(entry.messageId), s: tenantOfSession.get(entry.sessionId ?? sessionOf[t]) ?? t, n: entry.agent ?? "none", ctx: contextOf(entry.context), size: sizeOf(entry.input) });
      }
      for (const id of folded.consumed) done[st].push(idOf(id));
    }
  }
  const queue = held.map(({ payload }) => ({ id: idOf(payload.input?.messageId), s: tenantOfSession.get(payload.input?.sessionId) ?? "?", n: payload.input?.agent ?? "none" }));
  const ran = turns.map((turn) => ({ id: idOf(turn.turnId), def: turn.tenant, store: turn.store, ctx: contextOf(turn.context) }));
  return { agents: Object.keys(walk.agents), refused: [...walk.refused], log, owner, done, queue, ran };
}

// One canonical form for model and code alike: every collection in this
// spec is a set, so arrays compare sorted.
const canonical = (value) => {
  if (Array.isArray(value)) return `{${[...new Set(value.map(canonical))].sort().join(",")}}`;
  if (value && typeof value === "object") return `[${Object.keys(value).sort().map((key) => `${key}:${canonical(value[key])}`).join(",")}]`;
  return JSON.stringify(value);
};
const viewOf = (state) => canonical({
  agents: state.agents,
  refused: state.refused,
  log: state.log,
  owner: state.owner,
  done: state.done,
  queue: state.queue.map(({ id, s, n }) => ({ id, s, n })),
  ran: state.ran,
});

// ---------------------------------------------------------------------------
// The steps.

async function perform(walk, act) {
  const { sessionOf } = walk;
  switch (act.name) {
    case "Register": {
      const t = act.t;
      try {
        const agent = createTenantAgent({ name: nameOf[t], durability: walk.durabilities[storeOf[t]], tenant: t, storeOfDurability: walk.storeOfDurability });
        // Opens its backend, as its first request does.
        await agent.newSessionId();
        walk.agents[t] = agent;
      } catch (error) {
        if (error?.code !== "FX_AGENT_NAME_IN_USE") throw error;
        walk.refused.add(t);
        return "register refused";
      }
      return "register";
    }
    case "Prompt": {
      const session = walk.agents[act.t].session(sessionOf[act.t], { context: { tenant: act.t } });
      await session.prompt(`prompt ${act.id}`, { messageId: `m${act.id}` }).accepted;
      walk.sent.push(act.id);
      return "prompt";
    }
    case "Oversize": {
      const session = walk.agents[act.t].session(sessionOf[act.t], { context: { tenant: act.t } });
      const big = "x".repeat(oversizeBytes);
      try {
        if (act.k === "prompt") await session.prompt(big).accepted;
        else await session.steer(big);
      } catch (error) {
        if (error?.code !== "FX_INPUT_TOO_LARGE") throw error;
        return "oversize refused";
      }
      return "oversize stored";
    }
    case "Deliver": {
      const message = held.find(({ payload }) => payload.input?.messageId === `m${act.id}` && payload.input?.sessionId === sessionOf[act.s] &&
        payload.input?.agent === act.n && (payload.input?.store === undefined || payload.input.store === act.key));
      assert.ok(message, `message ${act.id} for ${act.s} on ${act.n}/${act.key} is queued`);
      message.attempt += 1;
      const { status, body } = await post(message.payload);
      if (status === 200) held.splice(held.indexOf(message), 1);
      else if (body?.code !== "FX_NO_AGENT") throw new Error(`delivery of ${act.id} failed: ${status} ${JSON.stringify(body)}`);
      return status === 200 ? "delivered" : "missed";
    }
    case "Forge": {
      const sessionId = sessionOf[act.s];
      const messageId = act.id === 0 ? "f0" : `m${act.id}`;
      const before = held.length;
      const ranBefore = turns.length;
      const { status } = await post({
        runId: sessionId,
        requestId: messageId,
        input: { type: "prompt", messageId, sessionId, agent: act.n, store: act.key, input: "forged", context: { tenant: "forger" }, settings: { instructions: "forged" } },
      });
      if (status !== 200) return "forge missed";
      if (held.length > before) return "forge forwarded";
      return turns.length > ranBefore ? "forge woke a sent prompt" : "forge refused";
    }
    default:
      throw new Error(`no step ${act.name}`);
  }
}

// ---------------------------------------------------------------------------
// The walks.

const sameAct = (a, b) => canonical(a) === canonical(b);
const seenStates = new Set([graph.init]);
const seenEdges = new Set();
const outcomes = {};
let steps = 0;

// The acts the frontier's states allow next, by name then variant, so a
// name with many variants, such as Forge, does not crowd out the rest.
function chooseAct(frontier, only) {
  const acts = new Map();
  for (const id of frontier) {
    for (const next of graph.next.get(id) ?? []) {
      const act = graph.states.get(next).act;
      if (only && !only(act, graph.states.get(id))) continue;
      acts.set(canonical(act), act);
    }
  }
  if (acts.size === 0) return null;
  const byName = new Map();
  for (const act of acts.values()) byName.set(act.name, [...(byName.get(act.name) ?? []), act]);
  const variants = pick([...byName.values()]);
  // Most forged deliveries name an agent that runs, so they test the
  // refusal rather than miss.
  if (variants[0].name === "Forge" && random() < 0.8) {
    const running = new Set([...frontier].flatMap((id) => graph.states.get(id).agents).map((t) => `${nameOf[t]}/${keyOf[t]}`));
    const aimed = variants.filter((act) => running.has(`${act.n}/${act.key}`));
    if (aimed.length > 0) return pick(aimed);
  }
  return pick(variants);
}

async function walkOnce(number) {
  const walk = await openWalk();
  let frontier = new Set([graph.init]);
  const path = [];
  const step = async (act) => {
    path.push(canonical(act));
    const outcome = await perform(walk, act);
    outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
    const seen = await observe(walk);
    const view = viewOf(seen);
    const next = new Set();
    for (const from of frontier) {
      for (const to of graph.next.get(from) ?? []) {
        const state = graph.states.get(to);
        if (!sameAct(state.act, act) || viewOf(state) !== view) continue;
        next.add(to);
        seenEdges.add(`${from}>${to}`);
        seenStates.add(to);
      }
    }
    if (next.size === 0) {
      const expected = [...frontier].flatMap((from) => [...(graph.next.get(from) ?? [])]).filter((to) => sameAct(graph.states.get(to).act, act)).map((to) => viewOf(graph.states.get(to)));
      throw new Error(`walk ${number} (seed ${firstSeed}) left the model after\n  ${path.join("\n  ")}\n  code:  ${view}\n  model: ${[...new Set(expected)].join("\n         ")}`);
    }
    frontier = next;
    steps += 1;
  };
  try {
    for (let taken = 0; taken < depth; taken += 1) {
      const act = chooseAct(frontier);
      if (!act) break;
      await step(act);
    }
    // The queue's fairness: every message an agent can take reaches it.
    const deliverable = (act, state) => act.name === "Deliver" && state.agents.some((t) => nameOf[t] === act.n && keyOf[t] === act.key);
    for (let left = 16; left > 0; left -= 1) {
      const act = chooseAct(frontier, deliverable);
      if (!act) break;
      await step(act);
    }
    // Every prompt an app sent ran, on its own agent, as SentRuns says.
    const ranIds = new Set(turns.map((turn) => idOf(turn.turnId)));
    for (const id of walk.sent) assert.ok(ranIds.has(id), `walk ${number}: prompt ${id} ran`);
  } finally {
    await walk.close();
  }
}

for (let number = 1; number <= walks; number += 1) await walkOnce(number);
const edges = [...graph.next.values()].reduce((total, successors) => total + successors.size, 0);
console.log(`${walks} walks (seed ${firstSeed}), ${steps} steps (${Object.entries(outcomes).sort().map(([name, count]) => `${count} ${name}`).join(", ")}): ${seenStates.size} of ${graph.states.size} states and ${seenEdges.size} of ${edges} edges, every step one the model allows`);
for (const outcome of ["register", "register refused", "prompt", "delivered", "forge refused", "forge missed", "oversize refused"]) {
  assert.ok((outcomes[outcome] ?? 0) > 0, `the walks reach "${outcome}" at least once`);
}
