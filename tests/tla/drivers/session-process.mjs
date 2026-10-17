// One server of drive.mjs, in a worker thread so it has a module instance and
// a globalThis of its own, and with them its own registry of agents, as a
// server does: two such agents of one name on one store are copies of one
// agent, not two configurations in one process. The driver keeps the walk.
// Each model request, tool call, held write and event of this server's agent
// goes to the driver, which answers it, and the driver calls the methods
// below to act on the agent.
//
// The threads share one set of live lease holders in shared memory, as the
// agents of one process share libfx's: whether a holder runs is what the
// driver, as the platform, says, and a Freeze takes a holder out of the set.
// They also share the call ids whose first intent was seen.
import { parentPort, workerData } from "node:worker_threads";
import { sharedSet } from "./shared-set.mjs";

const { w, liveBuffer, announcedBuffer, tool, toolFlags, runsAhead, durabilityKind, leaseMs, streamQuietMs, backend, addon, wasm, hooks } = workerData;
// Set before libfx loads, which keeps a set it finds.
globalThis[Symbol.for("libfx.liveHolders")] = sharedSet(liveBuffer);
const announced = sharedSet(announcedBuffer);

const { createFxAgent } = await import("../../../sdk/node.js");
const { local } = await import("../../../sdk/durable/local.mjs");
const { holdWrites } = await import("../../../sdk/tests/hold-writes.mjs");
// The fixture checks its events at the exit of its process, which a thread
// the driver ends never reaches, so this thread counts what it saw and the
// driver checks the counts of every thread.
const { testHooks } = hooks ? await import("../../../sdk/tests/hooks-fixture.mjs") : {};
const hooksSeen = { events: 0, errors: [] };
const observedHooks = testHooks && {
  onEvent(event) {
    hooksSeen.events += 1;
    testHooks.onEvent(event);
  },
  onError(error) {
    hooksSeen.errors.push(String(error?.stack ?? error));
    testHooks.onError(error);
  },
};
const leasedWorld = durabilityKind === "leased" ? await (async () => {
  const { createWorld } = await import(new URL("../../../sdk/durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
  const { world } = await import("../../../sdk/durable/world.mjs");
  return (dir) => world(() => createWorld({ dataDir: dir, recoverActiveRuns: false }), { name: "leased", pollMs: 250, leaseMs });
})() : null;
const { vercelStorage } = durabilityKind === "vercel" ? await import("../../../sdk/tests/vercel-storage.mjs") : {};
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
const { queueWorldAt, closeQueueWorlds } = durabilityKind === "queue" ? await import("../../../sdk/tests/queue-world.mjs") : {};
const durableInternals = Symbol.for("libfx.durableInternals");

const sse = (frames) => new Response(
  [...frames, "[DONE]"].map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));

// The ids of the calls a session-log record announces, from its stored
// journal events.
const intentCallIds = (entry) => {
  try {
    const { events } = JSON.parse(Buffer.from(entry.data, "base64").toString("utf8"));
    return events.filter((event) => event?.type === "tool_intent").flatMap((event) => event.data.map((call) => call.id));
  } catch {
    return [];
  }
};

// The queue as the driver runs it: a message the code asks to have delivered
// again later, as a backstop, is not, so nothing runs that the driver did not
// start. One handed back at a deadline still comes back at once.
function withoutBackstops(durability) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...args) => {
            const result = await handler(...args);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

// Holds each write to the session stream that carries a turn_end line its
// worker writes while it heads the session's chain, until the driver lets it
// go, so a walk can stop a worker between the record that ends its turn and
// that line (`tests/tla/sdk/DurableSession.tla` EndLine). A replaced
// worker's late line goes out at once, as the model's MaybeLine has it.
// Lines before a held one in the same write go out at once.
function holdEndLines(durability, heads, changed) {
  const waiting = [];
  const decoder = new TextDecoder();
  const isEnd = (chunk) => {
    try {
      return JSON.parse(typeof chunk === "string" ? chunk : decoder.decode(chunk)).type === "turn_end";
    } catch {
      return false;
    }
  };
  const hold = () => new Promise((go) => {
    waiting.push(go);
    changed();
  });
  const ends = {
    get held() { return waiting.length; },
    release() {
      for (const go of waiting.splice(0)) go();
      changed();
    },
  };
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      const streams = new Proxy(world.streams, {
        get(target, key) {
          if (key === "write") {
            return async (runId, name, chunk) => {
              if (isEnd(chunk) && (await heads(runId))) await hold();
              return target.write(runId, name, chunk);
            };
          }
          if (key === "writeMulti") {
            return async (runId, name, chunks) => {
              const at = chunks.findIndex(isEnd);
              if (at < 0 || !(await heads(runId))) return target.writeMulti(runId, name, chunks);
              if (at > 0) await target.writeMulti(runId, name, chunks.slice(0, at));
              await hold();
              return target.writeMulti(runId, name, chunks.slice(at));
            };
          }
          return bound(target, key);
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "streams" ? streams : bound(target, key)) });
    },
  }, ends];
}

// The walk now open, and what of it waits on the driver. Every message to the
// driver names the walk it comes from, so one a closed walk's agent sends
// late is dropped.
let walk = null;
let ids = 0;
const post = (state, message) => parentPort.postMessage({ ...message, walk: state.id });

const methods = {
  // A walk over `dir`: this server's agent, its World, and its held writes.
  async open({ id, dir }) {
    const requests = new Map();
    const calls = new Map();
    const claims = new Set();
    // The renewals of a frozen leased worker, held until it wakes.
    const renewals = new Set();
    const state = { id, requests, calls, frozen: false, renewals };
    // A queue-held lease runs to its worker's deadline, ten minutes away.
    const queueWorld = durabilityKind === "queue" ? await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000 }) : null;
    const stored = leasedWorld ? leasedWorld(dir) : durabilityKind === "world" ? await appWorldAt(dir) : durabilityKind === "vercel" ? vercelStorage({ dir }) : queueWorld ? queueWorld.durability : local({ dir });
    // What the driver reads of the held writes: their kind, a lease's
    // holder, and whether one is a frozen worker's renewal.
    // And how many turn_end lines it holds.
    const postHeld = () => {
      if (walk === state) post(state, { type: "held", held: state.writes.held.map((entry) => ({ k: entry.k, holder: entry.holder ?? null, renewal: renewals.has(entry) })), ends: state.ends.held });
    };
    // Whether the chain's latest lease is one this worker claimed.
    const heads = async (sessionId) => claims.has((await state.agent[durableInternals].lastLease(sessionId))?.holder);
    const [ending, ends] = holdEndLines(withoutBackstops(stored), heads, () => queueMicrotask(postHeld));
    state.ends = ends;
    const [durability, writes] = holdWrites(ending, (entry) => {
      // The write is held, if it is, once this returns.
      queueMicrotask(postHeld);
      // The first intent of a call that runs ahead waits for the Intent step.
      if (entry.k === "record") {
        if (!runsAhead) return false;
        return intentCallIds(entry).filter((callId) => announced.claim(callId)).length > 0;
      }
      if (entry.k !== "lease") return false;
      if (!claims.has(entry.holder)) {
        claims.add(entry.holder);
        return true;
      }
      if (!state.frozen) return false;
      renewals.add(entry);
      return true;
    });
    state.writes = writes;
    state.broker = queueWorld?.broker ?? null;
    state.postHeld = postHeld;
    state.agent = createFxAgent({
      ...(observedHooks ? { hooks: observedHooks } : {}),
      backend,
      nativeAddon: addon,
      ...(wasm ? { wasm } : {}),
      apiKey: "model-key",
      model: "model/test",
      async fetch(input, init) {
        // The WebAssembly host passes a Request, the native one a URL and init.
        const request = input instanceof Request ? input : new Request(input, init);
        if (request.method === "GET") return Response.json({ object: "list", data: [{ id: "model/test", type: "language" }] });
        const prompt = JSON.parse(await request.text()).prompt;
        const signal = init?.signal ?? request.signal;
        return new Promise((resolveResponse, rejectResponse) => {
          const requestId = (ids += 1);
          requests.set(requestId, (frames) => resolveResponse(sse(frames)));
          post(state, { type: "request", id: requestId, kind: toolResults(prompt).length > 0 ? "model2" : "model1" });
          signal?.addEventListener("abort", () => {
            if (requests.delete(requestId)) post(state, { type: "request-gone", id: requestId });
            rejectResponse(signal.reason ?? new Error("aborted"));
          }, { once: true });
        });
      },
      tools: [{
        name: tool,
        description: { send: "Sends an invoice", write: "Saves a key", lookup: "Looks up a key" }[tool],
        ...toolFlags,
        inputSchema: { type: "object", properties: { key: { type: "string" } } },
        execute: (input, { signal, executionId }) => new Promise((resolveCall, rejectCall) => {
          const callId = (ids += 1);
          calls.set(callId, () => resolveCall(`value of ${input.key}`));
          post(state, { type: "call", id: callId, executionId });
          signal?.addEventListener("abort", () => {
            if (calls.delete(callId)) post(state, { type: "call-gone", id: callId });
            rejectCall(signal.reason ?? new Error("aborted"));
          }, { once: true });
        }),
      }],
      durability,
      onEvent: (event) => {
        if (event.type === "session.fenced" || !/^(acp|transport)\./.test(event.type)) {
          post(state, { type: "event", event: event.type, error: event.error ? JSON.stringify(event.error) : null });
        }
      },
    });
    walk = state;
  },
  // The driver answers a model request, and ends a tool call.
  answer({ id, frames }) {
    const resolveRequest = walk?.requests.get(id);
    walk?.requests.delete(id);
    resolveRequest?.(frames);
  },
  end({ id }) {
    const resolveCall = walk?.calls.get(id);
    walk?.calls.delete(id);
    resolveCall?.();
  },
  async prompt({ text, messageId }) {
    const turn = walk.agent.session().prompt(text, { messageId });
    void turn.result.catch(() => {});
    return (await turn.accepted).sessionId;
  },
  resume({ sessionId }) {
    void walk.agent.session(sessionId).resume().result.catch(() => {});
  },
  async leaseHolder({ sessionId }) {
    return (await walk.agent[durableInternals].lastLease(sessionId))?.holder ?? null;
  },
  liveWorkers: () => walk.agent[durableInternals].liveWorkers(),
  leaseStands: ({ sessionId }) => walk.agent[durableInternals].leaseStands(sessionId),
  stopAtDeadline({ sessionId }) {
    walk.agent[durableInternals].stopAtDeadline(sessionId);
  },
  // Lets the writes held now go; with `settle`, resolves once they settled.
  // The driver hears the held writes before the answer either way.
  async releaseHeld({ settle = true } = {}) {
    const settled = walk.writes.releaseHeld();
    walk.postHeld();
    if (!settle) return;
    await settled;
    walk.postHeld();
  },
  // The turn_end lines held now go out (`tests/tla/sdk/DurableSession.tla`
  // EndLine).
  releaseEnds() {
    walk.ends.release();
  },
  // A claim lands: the holder of the last held lease, and the live holders
  // just before it goes out.
  async claim() {
    const holder = walk.writes.held.filter((entry) => entry.k === "lease").at(-1)?.holder ?? null;
    const before = [...globalThis[Symbol.for("libfx.liveHolders")]];
    await methods.releaseHeld();
    return { holder, before };
  },
  freeze() {
    walk.frozen = true;
  },
  // Wakes this worker; on the leased World its held renewals land, and it
  // says whether any did.
  async wake({ leased }) {
    walk.frozen = false;
    if (!leased || walk.renewals.size === 0) return false;
    walk.renewals.clear();
    await methods.releaseHeld();
    return true;
  },
  // The last message this World's queue held for the session and delivered
  // more than once: the message of a delivery the queue gave up on.
  lapsed({ sessionId }) {
    return walk.broker.held((input) => input.sessionId === sessionId).filter((message) => message.attempt > 0).at(-1) ?? null;
  },
  // Delivers here a message another server's queue held, as one queue shared
  // by two processes hands a message on.
  adopt({ message }) {
    walk.broker.adopt(message);
  },
  async stream({ sessionId, cursor = 0 }) {
    const reader = walk.agent.session(sessionId).stream(cursor).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), streamQuietMs); });
      const { value, done } = await Promise.race([reader.read(), quiet]);
      clearTimeout(timer);
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
    await reader.cancel().catch(() => {});
    return lines;
  },
  async close() {
    const state = walk;
    if (!state) return;
    walk = null;
    state.writes.release();
    state.ends.release();
    for (const resolveRequest of state.requests.values()) resolveRequest([{ type: "error", errorText: "walk over" }]);
    for (const resolveCall of state.calls.values()) resolveCall();
    state.requests.clear();
    state.calls.clear();
    await Promise.race([state.agent.close().catch(() => {}), sleep(3000)]);
    await closeAppWorlds?.();
    await closeQueueWorlds?.();
  },
  hooksSeen: () => hooksSeen,
};

parentPort.on("message", async ({ id, method, args }) => {
  try {
    parentPort.postMessage({ type: "result", id, value: await methods[method](args ?? {}) });
  } catch (error) {
    parentPort.postMessage({ type: "result", id, error: { message: `${w}.${method}: ${String(error?.stack ?? error)}`, code: error?.code } });
  }
});
