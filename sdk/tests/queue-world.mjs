// A World whose queue delivers the way Vercel Queues does, over world-local's
// runs, events and streams, for tests of a World that cannot tell whether a
// lease's holder runs:
//
// - a delivery holds its message until its handler returns, and the message
//   keeps its id across deliveries, each with the next attempt;
// - a handler that returns `{ timeoutSeconds }` has the message's payload
//   sent again that much later as a new message, as world-vercel does;
// - one that throws gets the same message again shortly;
// - `lapse(message)` delivers a message again while its delivery still runs,
//   as the queue does once the process holding it died or lost it;
//   `rerun(message)` runs its delivery again, attempt and all, as Vercel
//   does when a function's process exits mid-delivery; and `adopt(message)`
//   delivers here a message another of these Worlds held, as one queue
//   shared by two processes hands a message on;
// - with `hold`, it declares `capabilities.experimental_queueHold`, as
//   world-vercel does, and a send with `experimental_hold` comes back with
//   `experimental_held`, whose `consume(handler)` runs the message's first
//   delivery in the sender, or with `experimental_notHeld`, when `hold` is
//   "notHeld" or the hold is refused, and the queue delivers it as usual.
//
// The test starts the World and passes it to world(), so it stays the
// test's: `closeQueueWorlds()` closes them after the agents.
import { world } from "../durable/world.mjs";

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
const opened = [];

function createBroker({ retryMs, hold }) {
  const handlers = new Map();
  const inner = Symbol("handler");
  const timers = new Set();
  // Messages not yet acknowledged, by id.
  const messages = new Map();
  const keys = new Map();
  const sent = [];
  // Ids stay distinct across Worlds, so one can take another's message.
  const tag = crypto.randomUUID().slice(0, 8);
  let count = 0;
  let closed = false;
  const later = (fn, ms) => {
    if (closed) return;
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timers.add(timer);
  };
  const acknowledge = (message) => {
    messages.delete(message.id);
    if (message.key !== undefined && keys.get(message.key) === message.id) keys.delete(message.key);
  };
  const send = async (queueName, payload, options = {}) => {
    const { delaySeconds = 0, idempotencyKey } = options;
    const holding = hold !== undefined && options.experimental_hold !== undefined;
    if (holding && delaySeconds > 0) throw new Error("experimental_hold cannot be combined with delaySeconds");
    if (idempotencyKey !== undefined && keys.has(idempotencyKey)) {
      return { messageId: keys.get(idempotencyKey), ...(holding ? { experimental_notHeld: { reason: "duplicate" } } : {}) };
    }
    count += 1;
    const message = { id: `msg_${tag}${String(count).padStart(8, "0")}`, queueName, payload, attempt: 0, key: idempotencyKey, options };
    messages.set(message.id, message);
    if (idempotencyKey !== undefined) keys.set(idempotencyKey, message.id);
    sent.push(message);
    if (holding && hold === "held") {
      message.held = true;
      return { messageId: message.id, experimental_held: heldHandle(message) };
    }
    later(() => deliver(message), delaySeconds * 1000);
    return { messageId: message.id, ...(holding ? { experimental_notHeld: { reason: "lost" } } : {}) };
  };
  // A message held for its sender: its first delivery runs in `consume()`,
  // with what a delivery's handler returns meaning what it means there. One
  // given back or never consumed is delivered as usual.
  const heldHandle = (message) => {
    let used = false;
    return {
      messageId: message.id,
      leaseExpiresAt: new Date(Date.now() + 30_000),
      async consume(handler) {
        if (used) throw new Error("a held message is consumed once");
        used = true;
        message.consumed = true;
        await run(message, handler);
      },
      async release(delaySeconds = 0) {
        if (used) throw new Error("a held message is consumed once");
        used = true;
        later(() => deliver(message), delaySeconds * 1000);
      },
    };
  };
  // One delivery of `message` to `handler`, then its acknowledgement.
  const run = (message, handler, again = false) => {
    if (!again) message.attempt += 1;
    const attempt = message.attempt;
    return Promise.resolve()
      .then(() => handler(message.payload, { queueName: message.queueName, messageId: message.id, attempt, deliveryCount: attempt }))
      .then((result) => {
        // world-vercel sends the next message before it acknowledges this
        // one, so a delivery the queue has since handed on still sends it.
        if (Number.isFinite(result?.timeoutSeconds)) void send(message.queueName, message.payload, { delaySeconds: result.timeoutSeconds });
        if (attempt === message.attempt) acknowledge(message);
      }, () => {
        if (attempt === message.attempt) later(() => deliver(message), retryMs);
      });
  };
  const deliver = (message, again = false) => {
    if (closed || !messages.has(message.id)) return;
    const prefix = [...handlers.keys()].find((name) => message.queueName.startsWith(name));
    if (prefix === undefined) return later(() => deliver(message, again), 10);
    void run(message, handlers.get(prefix), again);
  };
  return {
    sent,
    // The messages not yet acknowledged whose libfx message matches.
    held(match = () => true) {
      return [...messages.values()].filter((message) => match(message.payload?.input ?? {}));
    },
    lapse(message) {
      deliver(message);
    },
    rerun(message) {
      deliver(message, true);
    },
    adopt(message) {
      const copy = { ...message };
      messages.set(copy.id, copy);
      deliver(copy);
      return copy;
    },
    queue: send,
    createQueueHandler(_prefix, handler) {
      const route = async () => new Response("this test World delivers in process", { status: 404 });
      route[inner] = handler;
      return route;
    },
    registerHandler(prefix, route) {
      handlers.set(prefix, route[inner]);
    },
    close() {
      closed = true;
      for (const timer of timers) clearTimeout(timer);
      timers.clear();
    },
  };
}

// The in-band writer fence `@workflow/world` defines, for a world-local
// without it: a count per run of the in-band writes it took, reported with
// each listing, read before it, and a refusal, before anything is written,
// of an in-band write that expects another count. A world-local with its own
// fence keeps it. Either way it keeps what each create was asked, for tests.
// `settleMs` holds an accepted write's count back that long after its event
// is published, as world-local's count on disk lags its event.
function withInBandFence(stored, { settleMs = 0 } = {}) {
  const own = stored.capabilities?.inBandFence === true;
  const counts = new Map();
  const seqs = new Map();
  const locks = new Map();
  const creates = [];
  const slotOf = (event) => Number(/^[a-z]+_(\d{26})$/.exec(String(event?.eventId ?? ""))?.[1] ?? 0);
  const noteSeq = (runId, event) => seqs.set(runId, Math.max(seqs.get(runId) ?? 0, slotOf(event)));
  const locked = (runId, fn) => {
    const run = (locks.get(runId) ?? Promise.resolve()).then(fn);
    locks.set(runId, run.catch(() => {}));
    return run;
  };
  const create = async (runId, data, params) => {
    creates.push({ runId, data, params });
    if (own) return stored.events.create(runId, data, params);
    if (!params?.inBand || data?.eventType === "run_created") {
      const result = await stored.events.create(runId, data, params);
      noteSeq(runId, result.event);
      return result;
    }
    return locked(runId, async () => {
      const current = counts.get(runId) ?? 1;
      if (params.expectedSeqInBand !== current) {
        throw Object.assign(new Error(`In-band write on run ${runId} expected seqInBand ${params.expectedSeqInBand}, but the run is at ${current}.`), { name: "InBandSupersededError", status: 412, code: "in-band-superseded", seqInBand: current });
      }
      const result = await stored.events.create(runId, data, params);
      noteSeq(runId, result.event);
      if (settleMs > 0) await new Promise((resolve) => setTimeout(resolve, settleMs));
      const allocated = result.event ? 1 : 0;
      counts.set(runId, current + allocated);
      return { ...result, allocated };
    });
  };
  const list = async (params) => {
    if (own) return stored.events.list(params);
    const snapshot = { seq: seqs.get(params.runId) ?? 0, seqInBand: counts.get(params.runId) ?? 1 };
    return { ...(await stored.events.list(params)), snapshot };
  };
  return {
    events: { ...stored.events, create, list },
    capabilities: { ...stored.capabilities, inBandFence: true },
    creates,
  };
}

/**
 * The durability, a World at `dir` with that queue passed to world(), and its
 * broker. With `inBandFence`, `true` or `{ settleMs }`, the World has the
 * in-band writer fence, and `fence.creates` holds what each create was asked.
 * With `hold`, "held" or "notHeld", the World's queue holds messages for
 * their sender, and a send that asks for a hold gets it or is refused.
 */
export async function queueWorldAt(dir, { retryMs = 20, inBandFence = false, hold, ...options } = {}) {
  const stored = createWorld({ dataDir: dir, recoverActiveRuns: false });
  await stored.start();
  const broker = createBroker({ retryMs, hold });
  const fence = inBandFence ? withInBandFence(stored, inBandFence === true ? {} : inBandFence) : null;
  const instance = {
    ...stored,
    ...(fence ? { events: fence.events, capabilities: fence.capabilities } : {}),
    ...(hold === undefined ? {} : { capabilities: { ...(fence?.capabilities ?? stored.capabilities), experimental_queueHold: true } }),
    queue: broker.queue,
    createQueueHandler: broker.createQueueHandler,
    registerHandler: broker.registerHandler,
    async close() {
      broker.close();
      await stored.close();
    },
  };
  opened.push(instance);
  // The broker keeps its messages in memory, so a message dies with the
  // process and prompt() stores each prompt before it sends it.
  // Every delivery comes from the queue unless a test asks for prompts to run
  // in the request that sent them.
  return { durability: world(instance, { name: "queue", pollMs: 250, queueDurable: false, runInRequest: false, ...options }), broker, fence };
}

export async function closeQueueWorlds() {
  for (const instance of opened.splice(0)) await instance.close().catch(() => {});
}
