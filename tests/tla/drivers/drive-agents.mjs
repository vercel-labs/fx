// Drives real libfx durable agents along the TLC state graphs of
// AgentRouting.tla, and checks after every step that the code is where the
// model allows.
//
//   bun tests/tla/drivers/drive-agents.mjs [send|recover] [--walks N] [--depth N] [--seed S]
//
// Two processes, p1 and p2, are two worker threads (agent-process.mjs), each
// with a module instance and a globalThis of its own: p1 has the agents S
// and C, and p2 only S, all over one world-local directory, each agent on a
// World of its own, as agents created without a durability have. The
// queue they share is the driver's: it holds every message until the walk
// delivers it to a process, to one of its Worlds picked at random, as the
// graph's Send and Deliver steps say. A prompt's input is stored before it
// is queued, as on every durability. With "recover" the processes die with
// the messages they hold, as on local(): a Crash step drops a message the
// driver holds, and a Recover step starts another copy of an agent in a
// process, which looks through the sessions as it starts and queues a
// recovery for each one whose last writer died (agent-process.mjs). A
// recovery names an input its session already stored, as any message does;
// the driver tells it apart by its idempotency key.
//
// After each step the driver reads back each session's owner from its log,
// the turns each agent ran, the names a process had no agent for, and the
// messages still queued, and moves to the successor with that state. A step
// with no such successor is a conformance failure. Each walk ends by draining
// the queue through p1, as the queue's fairness does in the model.
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { loadGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const mode = args.find((arg) => arg === "send" || arg === "recover") ?? "send";
const walks = Number(option("walks", 40));
const depth = Number(option("depth", 24));
let seed = Number(option("seed", Date.now() % 100000));
const firstSeed = seed;
// A small deterministic generator, so a failing walk can be run again.
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const pick = (items) => items[Math.floor(random() * items.length)];

const here = fileURLToPath(new URL(".", import.meta.url));
const graph = await loadGraph(resolve(here, "../sdk/graphs", `agents-${mode}.dot`));
const hosts = { p1: ["S", "C"], p2: ["S"] };

// The queue the processes share: every message, until a step delivers it.
const held = [];
const keys = new Map();
let sentCount = 0;
function enqueue({ queueName, payload, idempotencyKey }) {
  if (idempotencyKey !== undefined && keys.has(idempotencyKey)) return { messageId: keys.get(idempotencyKey) };
  sentCount += 1;
  const message = { id: `msg_${String(sentCount).padStart(6, "0")}`, queueName, payload, attempt: 0, key: idempotencyKey };
  if (idempotencyKey !== undefined) keys.set(idempotencyKey, message.id);
  held.push(message);
  return { messageId: message.id };
}
// A recovery is sent under its own idempotency key, which ends in ":recover".
const isRecovery = (message) => typeof message.key === "string" && message.key.endsWith(":recover");
// Takes `message` out of the queue. A recovery's key goes with it, as on
// world-local, which drops a duplicate only while the first is in flight.
function dequeue(message) {
  held.splice(held.indexOf(message), 1);
  if (isRecovery(message) && message.key !== undefined) keys.delete(message.key);
}

// A process: calls to its worker, which also sends to the queue.
function startProcess(name) {
  const worker = new Worker(new URL("./agent-process.mjs", import.meta.url), { workerData: { names: hosts[name], mode } });
  const calls = new Map();
  let called = 0;
  worker.on("message", (message) => {
    if (message.type === "send") return worker.postMessage({ type: "answer", id: message.id, value: enqueue(message) });
    const call = calls.get(message.id);
    calls.delete(message.id);
    if (message.error) call.reject(Object.assign(new Error(`${name}: ${message.error.message}`), { code: message.error.code }));
    else call.resolve(message.value);
  });
  worker.on("error", (error) => { for (const call of calls.values()) call.reject(error); });
  return {
    call: (method, args) => new Promise((resolve, reject) => {
      called += 1;
      calls.set(called, { resolve, reject });
      worker.postMessage({ method, args, id: called });
    }),
    stop: () => worker.terminate(),
  };
}

const processes = Object.fromEntries(Object.keys(hosts).map((name) => [name, startProcess(name)]));

// The parts of a model state the driver observes, in one canonical form:
// records by key, and the sets queue, ran and missed in sorted order.
const canonical = (value) => {
  if (Array.isArray(value)) return `<<${value.map(canonical).join(",")}>>`;
  if (value && typeof value === "object") return `[${Object.keys(value).sort().map((key) => `${key}:${canonical(value[key])}`).join(",")}]`;
  return JSON.stringify(value);
};
const set = (items) => `{${items.map(canonical).sort().join(",")}}`;
// With "recover", the inputs each session holds untaken, which only that
// graph tracks.
const viewOf = ({ owner, queue, ran, missed, sends, stored, recovering, crashes }) =>
  `owner ${canonical(owner)} queue ${set(queue)} ran ${set(ran)} missed ${set(missed)} sends ${sends} recovering ${set(recovering)} crashes ${crashes}` +
  (mode === "recover" ? ` stored ${Object.keys(stored).sort().map((name) => `${name}:${set(stored[name])}`).join(",")}` : "");

async function openWalk() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-agents-"));
  held.length = 0;
  keys.clear();
  for (const process of Object.values(processes)) await process.call("open", { dir });
  const sessions = { s1: await processes.p1.call("newSessionId"), s2: await processes.p1.call("newSessionId") };
  for (const process of Object.values(processes)) await process.call("listen", { sessionId: sessions.s1 });
  const close = async () => {
    for (const process of Object.values(processes)) await process.call("close");
    await rm(dir, { recursive: true, force: true });
  };
  return { sessions, ran: new Set(), missed: new Set(), sends: 0, crashes: 0, copies: {}, close };
}

// The driver's view of the code, in the model's terms.
async function observe(walk) {
  const nameOf = new Map(Object.entries(walk.sessions).map(([name, id]) => [id, name]));
  const owners = await processes.p1.call("owners", { sessionIds: Object.values(walk.sessions) });
  const owner = Object.fromEntries(Object.entries(walk.sessions).map(([name, id]) => [name, owners[id]]));
  const prompts = held.filter((message) => !isRecovery(message));
  const queue = prompts.map(({ payload }) => ({ id: Number(payload.input.messageId.slice(1)), s: nameOf.get(payload.input.sessionId), n: payload.input.agent }));
  const ran = [...walk.ran].map((item) => JSON.parse(item)).map(([id, agent]) => [nameOf.get(id), agent]);
  const pending = await processes.p1.call("pending", { sessionIds: Object.values(walk.sessions) });
  const stored = Object.fromEntries(Object.entries(pending).map(([id, ids]) => [nameOf.get(id), ids.map((messageId) => Number(messageId.slice(1)))]));
  const recovering = [...new Set(held.filter(isRecovery).map(({ payload }) => JSON.stringify({ s: nameOf.get(payload.input.sessionId), n: payload.input.agent })))].map((item) => JSON.parse(item));
  return { owner, queue, ran, missed: [...walk.missed], sends: walk.sends, stored, recovering, crashes: walk.crashes };
}

// Delivers `message` to process `p`, at one of its Worlds picked at random,
// and records what ran or which name it found no agent for. True when the
// process took it.
async function deliverTo(walk, p, message) {
  message.attempt += 1;
  const outcome = await processes[p].call("deliver", {
    world: Math.floor(random() * (hosts[p].length + (walk.copies[p] ?? 0))),
    payload: message.payload,
    meta: { queueName: message.queueName, messageId: message.id, attempt: message.attempt },
  });
  for (const item of outcome.ran) walk.ran.add(JSON.stringify(item));
  if (!outcome.delivered) walk.missed.add(outcome.missed);
  return outcome.delivered;
}

// Performs the step `act` names on the code.
async function perform(walk, act) {
  if (act.name === "Send") {
    await processes.p1.call("prompt", { agent: act.n, sessionId: walk.sessions[act.s], input: `prompt ${act.id}`, messageId: `m${act.id}` });
    walk.sends += 1;
    return;
  }
  const recoveries = (s) => held.filter((message) => isRecovery(message) && message.payload.input.sessionId === walk.sessions[s]);
  if (act.name === "Recover") {
    // The sessions a message is on its way for have a writer that still runs.
    const sessions = held.filter((message) => !isRecovery(message)).map(({ payload }) => payload.input.sessionId);
    await processes[act.p].call("recover", { agent: act.n, sessions });
    walk.copies[act.p] = (walk.copies[act.p] ?? 0) + 1;
    return;
  }
  if (act.name === "CrashRecovery") {
    for (const message of recoveries(act.s)) dequeue(message);
    walk.crashes += 1;
    return;
  }
  if (act.name === "DeliverRecovery") {
    const [message, ...copies] = recoveries(act.s);
    assert.ok(message, `a recovery of ${act.s} is queued`);
    // Copies of one recovery that agents started apart sent run nothing
    // more once one has run, so they go with it.
    if (await deliverTo(walk, act.p, message)) for (const item of [message, ...copies]) dequeue(item);
    return;
  }
  const message = held.find((item) => !isRecovery(item) && item.payload.input.messageId === `m${act.id}`);
  assert.ok(message, `message ${act.id} is queued`);
  if (act.name === "Crash") {
    dequeue(message);
    walk.crashes += 1;
    return;
  }
  if (await deliverTo(walk, act.p, message)) dequeue(message);
}

const seenStates = new Set([graph.init]);
const seenEdges = new Set();
const outcomes = { send: 0, run: 0, forward: 0, miss: 0, crash: 0, recover: 0, recovered: 0 };
let steps = 0;

// What a step from `from` to `to` did, as the model has it.
function outcomeOf(from, to) {
  if (to.act.name === "Send") return "send";
  if (to.act.name === "Crash" || to.act.name === "CrashRecovery") return "crash";
  if (to.act.name === "Recover") return "recover";
  if (to.act.name === "DeliverRecovery") return to.recovering.length === from.recovering.length ? "miss" : "recovered";
  if (to.queue.length === from.queue.length) return set(to.queue) === set(from.queue) ? "miss" : "forward";
  return "run";
}

async function walkOnce(number) {
  const walk = await openWalk();
  let at = graph.init;
  const path = [];
  const step = async (choose) => {
    // A self-loop is a step too: a second miss in p2 leaves the state as is.
    const successors = [...(graph.next.get(at) ?? [])];
    const chosen = choose(successors);
    if (chosen === undefined) return false;
    const act = graph.states.get(chosen).act;
    path.push(JSON.stringify(act));
    await perform(walk, act);
    const seen = viewOf(await observe(walk));
    const match = successors.find((id) => canonical(graph.states.get(id).act) === canonical(act) && viewOf(graph.states.get(id)) === seen);
    if (match === undefined) {
      const expected = successors.filter((id) => canonical(graph.states.get(id).act) === canonical(act)).map((id) => viewOf(graph.states.get(id)));
      throw new Error(`walk ${number} (seed ${firstSeed}) left the model after ${path.join(" ")}\n  code:  ${seen}\n  model: ${expected.join("\n         ")}`);
    }
    seenEdges.add(`${at}>${match}`);
    seenStates.add(match);
    outcomes[outcomeOf(graph.states.get(at), graph.states.get(match))] += 1;
    at = match;
    steps += 1;
    return true;
  };
  try {
    for (let taken = 0; taken < depth; taken += 1) if (!(await step((successors) => (successors.length ? pick(successors) : undefined)))) break;
    // The queue's fairness: every message reaches a process that has its
    // agent, so the queue drains, and an agent of each stranded session's
    // name starts, so its work runs.
    const busy = (state) => state.queue.length > 0 || state.recovering.length > 0 || Object.values(state.stored).some((ids) => ids.length > 0);
    for (let left = 32; left > 0 && busy(graph.states.get(at)); left -= 1) {
      const by = (name) => (successors) => successors.find((id) => graph.states.get(id).act.name === name && graph.states.get(id).act.p === "p1");
      await step((successors) => by("Deliver")(successors) ?? by("DeliverRecovery")(successors) ?? by("Recover")(successors));
    }
    assert.ok(!busy(graph.states.get(at)), `walk ${number} drains its queue and runs its stranded work`);
    assert.equal(held.length, 0, `walk ${number} leaves nothing queued in the code`);
  } finally {
    await walk.close();
  }
}

try {
  for (let number = 1; number <= walks; number += 1) await walkOnce(number);
} finally {
  for (const process of Object.values(processes)) await process.stop();
}
const edges = [...graph.next.values()].reduce((total, successors) => total + successors.size, 0);
console.log(`${walks} walks (${mode}, seed ${firstSeed}), ${steps} steps (${Object.entries(outcomes).map(([name, count]) => `${count} ${name}`).join(", ")}): ${seenStates.size} of ${graph.states.size} states and ${seenEdges.size} of ${edges} edges, every step one the model allows`);
assert.ok(outcomes.forward > 0 && outcomes.miss > 0, "the walks forward a message and miss an agent at least once");
if (mode === "recover") assert.ok(outcomes.crash > 0 && outcomes.recover > 0 && outcomes.recovered > 0, "the walks lose a message, and recover and run its work, at least once");
