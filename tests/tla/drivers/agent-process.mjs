// One process of drive-agents.mjs, in a worker thread so it has a module
// instance and a globalThis of its own, as a process does: its agents, on
// one durability over the walk's world-local directory that makes each of
// them a World of its own, as the durability of agents created without one
// does. Every message its agents queue goes to the driver, which holds them
// all until a step delivers one here, to the queue handler of the World the
// driver picks.
//
// With "recover", the durability recovers sessions as local() does, on what
// the driver says of each writer: an input's writer still runs while the
// driver holds a message for its session, so one whose messages a crash
// lost has died. A Recover step starts another copy of an agent here, which
// looks through the sessions as it starts.
import { parentPort, workerData } from "node:worker_threads";
import { createDurableAgentFactory, foldSessionLog } from "../../../sdk/durable.js";
import { world } from "../../../sdk/durable/world.mjs";

const { names, mode } = workerData;
const { createWorld } = await import(new URL("../../../sdk/durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const encoder = new TextEncoder();
const inner = Symbol("handler");

// The turns this process ran since the driver last asked, as [sessionId, agent name].
let ran = [];

// A harness whose every turn is one step, recorded with the agent's name.
const createAgent = createDurableAgentFactory({
  name: "createRoutingAgent",
  defaultDurability: async () => { throw new Error("the driver passes a durability"); },
  harness: ({ tag }) => ({
    async open({ sessionId, store }) {
      await store.load();
      return {
        prompt(_input, { turnId }) {
          const result = (async () => {
            await store.append({ idempotencyKey: `${turnId}:start`, data: encoder.encode(JSON.stringify({ turnId, start: true })), marks: [{ start: turnId }] });
            ran.push([sessionId, tag]);
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

// Calls to the driver, which answers each by its id.
const waiting = new Map();
let asked = 0;
const ask = (message) => new Promise((resolve) => {
  asked += 1;
  waiting.set(asked, resolve);
  parentPort.postMessage({ ...message, id: asked });
});

let walk = null;
// With "recover": the session whose input a prompt is writing now, and the
// sessions the driver holds a message for.
let writing = null;
let queued = new Set();
const recoveredBy = globalThis[Symbol.for("libfx.recoveredBy")];

const methods = {
  // A walk over `dir`: this process's agents, each listening.
  async open({ dir }) {
    const handlers = [];
    // Each agent's World, which libfx starts and closes with the agent.
    const createInstance = () => {
      const index = handlers.push(null) - 1;
      return {
        ...createWorld({ dataDir: dir, recoverActiveRuns: false }),
        queue: (queueName, payload, { idempotencyKey } = {}) => ask({ type: "send", queueName, payload, idempotencyKey }),
        createQueueHandler(_prefix, handler) {
          const route = async () => new Response("this test World delivers in process", { status: 404 });
          route[inner] = handler;
          return route;
        },
        registerHandler(_prefix, route) {
          handlers[index] = route[inner];
        },
      };
    };
    const recovery = mode === "recover" ? {
      livenessKnown: true,
      holderInfo: () => (writing ? { session: writing } : { worker: true }),
      alive: (writer) => (typeof writer.session === "string" ? queued.has(writer.session) : null),
      recover: () => true,
    } : {};
    const durability = world(createInstance, { name: "routing", pollMs: 250, runInRequest: false, ...recovery });
    const agents = Object.fromEntries(names.map((name) => [name, createAgent({ durability, name, tag: name })]));
    walk = { handlers, agents, durability, copies: [] };
    ran = [];
  },
  newSessionId: () => walk.agents[names[0]].newSessionId(),
  // Opens every agent's backend, so each listens, as one does once it has
  // served a request.
  async listen({ sessionId }) {
    for (const agent of Object.values(walk.agents)) await agent[Symbol.for("libfx.durableInternals")].openLog(sessionId);
  },
  async prompt({ agent, sessionId, input, messageId }) {
    writing = sessionId;
    try {
      await walk.agents[agent].session(sessionId).prompt(input, { messageId }).accepted;
    } finally {
      writing = null;
    }
  },
  // Agent `agent` starts here again, as in a process that starts, and looks
  // through the sessions with what the driver holds: `sessions` are those it
  // holds a message for.
  async recover({ agent, sessions }) {
    queued = new Set(sessions);
    recoveredBy.get(walk.durability)?.delete(agent);
    const copy = createAgent({ durability: walk.durability, name: agent, tag: agent });
    walk.copies.push(copy);
    await copy[Symbol.for("libfx.durableInternals")].recovery();
  },
  // The inputs no turn has taken, by session.
  async pending({ sessionIds }) {
    const internals = walk.agents[names[0]][Symbol.for("libfx.durableInternals")];
    const pending = {};
    for (const sessionId of sessionIds) pending[sessionId] = foldSessionLog(await (await internals.openLog(sessionId)).read()).unconsumed.map((input) => input.messageId);
    return pending;
  },
  // Delivers a queued message to the World `world` of this process, by
  // index; a name this process has no agent for is a miss.
  async deliver({ world: index, payload, meta }) {
    try {
      await walk.handlers[index % walk.handlers.length](payload, meta);
      return { delivered: true, ran: ran.splice(0) };
    } catch (error) {
      if (error?.code !== "FX_NO_AGENT") throw error;
      return { delivered: false, missed: error.agent, ran: ran.splice(0) };
    }
  },
  // The agent each session belongs to, as its log has it.
  async owners({ sessionIds }) {
    const internals = walk.agents[names[0]][Symbol.for("libfx.durableInternals")];
    const owners = {};
    for (const sessionId of sessionIds) owners[sessionId] = foldSessionLog(await (await internals.openLog(sessionId)).read()).agent ?? "none";
    return owners;
  },
  async close() {
    if (!walk) return;
    for (const agent of [...Object.values(walk.agents), ...walk.copies]) await agent.close().catch(() => {});
    walk = null;
    queued = new Set();
  },
};

parentPort.on("message", async (message) => {
  if (message.type === "answer") {
    waiting.get(message.id)?.(message.value);
    waiting.delete(message.id);
    return;
  }
  try {
    parentPort.postMessage({ type: "result", id: message.id, value: await methods[message.method](message.args ?? {}) });
  } catch (error) {
    parentPort.postMessage({ type: "result", id: message.id, error: { message: String(error?.stack ?? error), code: error?.code } });
  }
});
