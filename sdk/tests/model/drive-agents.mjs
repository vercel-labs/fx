// Drives real libfx durable agents along the TLC state graphs of
// AgentRouting.tla, and checks after every step that the code is where the
// model allows.
//
//   bun sdk/tests/model/drive-agents.mjs [send|consume] [--walks N] [--depth N] [--seed S]
//
// Two processes, p1 and p2, are two worker threads (agent-process.mjs), each
// with a module instance and a globalThis of its own: p1 has the agents S
// and C, and p2 only S, all over one world-local directory, each agent on a
// World of its own, as agents created without a durability have. The
// queue they share is the driver's: it holds every message until the walk
// delivers it to a process, to one of its Worlds picked at random, as the
// graph's Send and Deliver steps say. With "send" a prompt's input is stored
// before it is queued, as on local(); with "consume" the worker that takes
// it stores it, as on a World whose queue keeps its messages (Vercel).
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
const mode = args.find((arg) => arg === "send" || arg === "consume") ?? "send";
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
const graph = await loadGraph(resolve(here, "graphs", `agents-${mode}.dot`));
const hosts = { p1: ["S", "C"], p2: ["S"] };

// The queue the processes share: every message, until a step delivers it.
const held = [];
const keys = new Map();
let sentCount = 0;
function enqueue({ queueName, payload, idempotencyKey }) {
  if (idempotencyKey !== undefined && keys.has(idempotencyKey)) return { messageId: keys.get(idempotencyKey) };
  sentCount += 1;
  const message = { id: `msg_${String(sentCount).padStart(6, "0")}`, queueName, payload, attempt: 0 };
  if (idempotencyKey !== undefined) keys.set(idempotencyKey, message.id);
  held.push(message);
  return { messageId: message.id };
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
const viewOf = ({ owner, queue, ran, missed, sends }) => `owner ${canonical(owner)} queue ${set(queue)} ran ${set(ran)} missed ${set(missed)} sends ${sends}`;

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
  return { sessions, ran: new Set(), missed: new Set(), sends: 0, close };
}

// The driver's view of the code, in the model's terms.
async function observe(walk) {
  const nameOf = new Map(Object.entries(walk.sessions).map(([name, id]) => [id, name]));
  const owners = await processes.p1.call("owners", { sessionIds: Object.values(walk.sessions) });
  const owner = Object.fromEntries(Object.entries(walk.sessions).map(([name, id]) => [name, owners[id]]));
  const queue = held.map(({ payload }) => ({ id: Number(payload.input.messageId.slice(1)), s: nameOf.get(payload.input.sessionId), n: payload.input.agent }));
  const ran = [...walk.ran].map((item) => JSON.parse(item)).map(([id, agent]) => [nameOf.get(id), agent]);
  return { owner, queue, ran, missed: [...walk.missed], sends: walk.sends };
}

// Performs the step `act` names on the code.
async function perform(walk, act) {
  if (act.name === "Send") {
    await processes.p1.call("prompt", { agent: act.n, sessionId: walk.sessions[act.s], input: `prompt ${act.id}`, messageId: `m${act.id}` });
    walk.sends += 1;
    return;
  }
  const message = held.find(({ payload }) => payload.input.messageId === `m${act.id}`);
  assert.ok(message, `message ${act.id} is queued`);
  message.attempt += 1;
  const outcome = await processes[act.p].call("deliver", {
    world: Math.floor(random() * hosts[act.p].length),
    payload: message.payload,
    meta: { queueName: message.queueName, messageId: message.id, attempt: message.attempt },
  });
  for (const item of outcome.ran) walk.ran.add(JSON.stringify(item));
  if (outcome.delivered) held.splice(held.indexOf(message), 1);
  else walk.missed.add(outcome.missed);
}

const seenStates = new Set([graph.init]);
const seenEdges = new Set();
const outcomes = { send: 0, run: 0, forward: 0, miss: 0 };
let steps = 0;

// What a step from `from` to `to` did, as the model has it.
function outcomeOf(from, to) {
  if (to.act.name === "Send") return "send";
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
    // agent, so the queue drains.
    for (let left = 32; left > 0 && graph.states.get(at).queue.length > 0; left -= 1) {
      await step((successors) => successors.find((id) => graph.states.get(id).act.name === "Deliver" && graph.states.get(id).act.p === "p1"));
    }
    assert.deepEqual(graph.states.get(at).queue, [], `walk ${number} drains its queue`);
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
