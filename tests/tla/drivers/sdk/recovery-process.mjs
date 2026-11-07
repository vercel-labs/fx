// One process of an app that keeps libfx sessions and its own Workflow SDK
// runs in one World, for queue-recovery.ts. It runs in Node, which lets it
// put a fake clock under world-local's queue: Bun does not take the patch.
//
//   node recovery-process.mjs <plan.json>
//
// The plan, a JSON file, says what this process does:
//
//   dir        the World's data folder
//   first      the app's first process: it recovers nothing, so it reports
//              no restart
//   recover    whether starting the World recovers its active runs
//              (false: libfx's own local() World)
//   namespace  this process's WORKFLOW_QUEUE_NAMESPACE, or none
//   agent      the libfx agent's name, "default" or another
//   lateAgent  create the agent only after the World started
//   race       start new sessions and turns while the World starts
//   sessions   how many new libfx sessions to create, each with one turn
//   appRuns    how many runs of the app's own workflow to create
//   turns      ids of earlier sessions to prompt once the World started
//   resume     ids of earlier sessions to resume (a turn a crash left open)
//   crash      leave one more session with a turn held mid-step, print
//              {"op":"ready"}, and wait to be killed
//   known      ids of the runs earlier processes created, whose status it
//              reports at the end with the runs it created
//
// It prints one JSON event per line, in an order the model can take:
// "restart" with the messages recovery queued, each "deliver" of a recovery
// message, each "create" with the namespace the World stored for the run,
// each "turn" with its outcome, and each run's "status" at the end.
import { readFileSync } from "node:fs";
import timersPromises from "node:timers/promises";
import { syncBuiltinESMExports } from "node:module";

const plan = JSON.parse(readFileSync(process.argv[2], "utf8"));
const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The fake clock: world-local sleeps through node:timers/promises before it
// delivers a message again (5 s after a refusal, up to 256 deliveries) and
// before a delayed message. Patched before world-local loads, sleeps of a
// second or more run on real time until `flush()`, which advances fake time
// 30 minutes, past every redelivery the World would make, and hands what is
// still pending back to real time.
const realSleep = timersPromises.setTimeout;
const clock = { fake: false, now: 0, pending: [] };
timersPromises.setTimeout = (ms, value, options) => {
  if (!clock.fake || !(ms >= 1000)) return realSleep(ms, value, options);
  return new Promise((resolve, reject) => {
    const entry = { at: clock.now + ms, resolve: () => resolve(value) };
    clock.pending.push(entry);
    options?.signal?.addEventListener("abort", () => {
      clock.pending = clock.pending.filter((other) => other !== entry);
      reject(Object.assign(new Error("aborted"), { name: "AbortError" }));
    }, { once: true });
  });
};
syncBuiltinESMExports();
const turnsOfEvents = async () => { for (let index = 0; index < 50; index += 1) await new Promise((resolve) => setImmediate(resolve)); };
async function flush(totalMs = 30 * 60_000, stepMs = 5000) {
  for (let elapsed = 0; elapsed < totalMs; elapsed += stepMs) {
    clock.now += stepMs;
    const due = clock.pending.filter((entry) => entry.at <= clock.now);
    clock.pending = clock.pending.filter((entry) => entry.at > clock.now);
    for (const entry of due) entry.resolve();
    await turnsOfEvents();
  }
  clock.fake = false;
  for (const entry of clock.pending.splice(0)) setTimeout(entry.resolve, entry.at - clock.now);
}

const { createDurableAgentFactory, memory } = await import("../../../../sdk/durable.js");
const { restartedWorldAt, createAppRun } = await import("../../../../sdk/tests/restarted-world.mjs");

// A turn: its events, its `result`, and `cancel()`; a handoff stops it and
// stores nothing more.
function turnOf(body, onHandoff) {
  const events = [];
  let wake = null;
  let finished = false;
  let cancelled = false;
  const controller = new AbortController();
  const result = body((event) => { events.push(event); wake?.(); }, controller.signal)
    .catch((error) => (cancelled ? { stopReason: "cancelled" } : { stopReason: "error", error: { name: "Error", message: String(error?.message ?? error) } }))
    .finally(() => { finished = true; wake?.(); });
  return {
    result,
    steer: async () => {},
    cancel(options = {}) {
      if (options.reason === "handoff") onHandoff();
      cancelled = true;
      controller.abort();
    },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (events.length) yield events.shift();
        if (finished) return;
        await new Promise((resolve) => { wake = resolve; });
        wake = null;
      }
    },
  };
}

// The steps the "hold" input's turn reached; it waits at its second step.
const held = { reached: null };
const holding = new Promise((resolve) => { held.reached = resolve; });

// A harness whose turn of `input` is three steps, each one record, with the
// turn's start and end marked.
const harness = () => ({
  async open({ store }) {
    const loaded = await store.load();
    const records = loaded.journal.map((record) => JSON.parse(decoder.decode(record.data)));
    let key = 0;
    let handedOff = false;
    const append = async (record, marks) => {
      if (handedOff) throw new Error("handed off");
      await store.append({ idempotencyKey: `recovery:${process.pid}:${Date.now()}:${key++}`, data: encoder.encode(JSON.stringify(record)), marks });
      records.push(record);
    };
    const stepsOf = (turnId) => records.filter((record) => record.turnId === turnId && record.word !== undefined).length;
    const openTurn = () => {
      for (let index = records.length - 1; index >= 0; index -= 1) {
        if (records[index].end) return null;
        if (records[index].start) return { id: records[index].turnId, input: records[index].input };
      }
      return null;
    };
    const run = (turnId, input, start) => turnOf(async (push, signal) => {
      if (start) await append({ turnId, start: true, input }, [{ start: turnId }]);
      for (let step = stepsOf(turnId); step < 3; step += 1) {
        if (input === "hold" && step === 1 && plan.crash) {
          held.reached();
          await new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
        }
        await sleep(1);
        if (signal.aborted) throw new Error("aborted");
        const word = `${input}-${step}`;
        const last = step === 2;
        await append({ turnId, step, word, ...(last ? { end: true } : {}) }, last ? [{ end: true }] : []);
        push({ type: "text_delta", delta: `${word} ` });
      }
      return { stopReason: "end_turn" };
    }, () => { handedOff = true; });
    return {
      prompt: (input, { turnId } = {}) => run(turnId, input, true),
      resume() {
        const open = openTurn();
        return run(open.id, open.input, false);
      },
      get openTurn() {
        const open = openTurn();
        return open && { id: open.id };
      },
      settled: async () => {},
      saveCheckpoint: async () => {},
      exportCheckpoint: async () => encoder.encode(JSON.stringify(records.filter((record) => record.word !== undefined).map((record) => record.word))),
      close: async () => {},
    };
  },
});

const createAgent = createDurableAgentFactory({ harness, defaultDurability: async () => memory(), name: "createRecoveryAgent" });

// How a turn ended: "ran" when it reached its end, "failed" otherwise, as
// when the World has failed the session's run and refuses its writes.
async function outcomeOf(start) {
  try {
    let timer;
    const result = await Promise.race([
      start().result,
      new Promise((resolve) => { timer = setTimeout(() => resolve({ stopReason: "timeout" }), 20_000); }),
    ]).finally(() => clearTimeout(timer));
    return result?.stopReason === "end_turn" ? "ran" : "failed";
  } catch {
    return "failed";
  }
}

const restarted = await restartedWorldAt(plan.dir, { recover: plan.recover !== false, namespace: plan.namespace });
let agent = null;
const makeAgent = async () => {
  agent = createAgent({ durability: restarted.durability, ...(plan.agent && plan.agent !== "default" ? { name: plan.agent } : {}) });
  // The agent takes the World's deliveries from now on.
  await agent.newSessionId();
};
const created = [];
const turns = [];
// A new session with one turn: the turn creates its run.
const newSession = async () => {
  const session = agent.session();
  const outcome = await outcomeOf(() => session.prompt("alpha"));
  created.push(session.id);
  turns.push({ runId: session.id, outcome });
};

if (!plan.lateAgent) await makeAgent();
const racing = [];
if (plan.first) {
  await restarted.start();
} else {
  clock.fake = true;
  const race = () => {
    for (let index = 0; index < (plan.sessions ?? 0); index += 1) racing.push(newSession());
    for (const runId of plan.turns ?? []) racing.push(outcomeOf(() => agent.session(runId).prompt("beta")).then((outcome) => turns.push({ runId, outcome })));
  };
  const starting = restarted.start();
  if (plan.race && !plan.lateAgent) race();
  await starting;
  if (plan.lateAgent) {
    await makeAgent();
    // A late agent's turns race the World's redeliveries instead.
    if (plan.race) race();
  }
  await turnsOfEvents();
  await flush();
  await Promise.all(racing);
}

// What recovery queued: the first delivery of each message, all of which the
// fake clock let through.
const firstDeliveries = new Map();
for (const delivery of restarted.deliveries) {
  const key = `${delivery.runId} ${delivery.queueName}`;
  if (!firstDeliveries.has(key)) firstDeliveries.set(key, delivery);
}
const topicOf = (queueName) => (queueName.startsWith("__libfx_wkf_workflow_") ? "libfx" : "default");
const queued = [...firstDeliveries.values()].map((delivery) => ({ runId: delivery.runId, topic: topicOf(delivery.queueName) }));
const queuedIds = new Set(queued.map((message) => message.runId));
const createEvent = async (runId, kind) => ({ op: "create", runId, kind, ns: (await restarted.run(runId)).namespace ?? "none" });

if (!plan.first) {
  // A session raced in while the World listed its runs: it was created
  // before the listing exactly when recovery queued it.
  const before = created.filter((runId) => queuedIds.has(runId));
  for (const runId of before) emit(await createEvent(runId, "libfx"));
  emit({ op: "restart", agents: plan.agent && plan.agent !== "default" ? "named" : "default", recover: plan.recover !== false, queued });
  for (const delivery of restarted.deliveries) {
    const outcome = delivery.consumer === "workflow"
      ? delivery.outcome
      : delivery.status === 200 ? "acked" : delivery.attempt >= 256 ? "dropped" : "refused";
    emit({ op: "deliver", runId: delivery.runId, consumer: delivery.consumer, outcome, attempt: delivery.attempt, status: delivery.status });
  }
  for (const runId of created.filter((id) => !before.includes(id))) emit(await createEvent(runId, "libfx"));
}

if (!plan.race || plan.first) {
  for (let index = 0; index < (plan.sessions ?? 0); index += 1) {
    await newSession();
    emit(await createEvent(created.at(-1), "libfx"));
  }
  for (const runId of plan.turns ?? []) turns.push({ runId, outcome: await outcomeOf(() => agent.session(runId).prompt("beta")) });
}
const appCreated = [];
for (let index = 0; index < (plan.appRuns ?? 0); index += 1) {
  appCreated.push(await createAppRun(restarted.instance));
  emit(await createEvent(appCreated.at(-1), "app"));
}
for (const runId of plan.resume ?? []) turns.push({ runId, outcome: await outcomeOf(() => agent.session(runId).resume()) });
for (const turn of turns) emit({ op: "turn", runId: turn.runId, outcome: turn.outcome });

if (plan.crash) {
  const session = agent.session();
  void session.prompt("hold").result.catch(() => {});
  await holding;
  for (let waited = 0; waited < 10_000; waited += 20) {
    if (await restarted.run(session.id).then(() => true, () => false)) break;
    await sleep(20);
  }
  emit(await createEvent(session.id, "libfx"));
  emit({ op: "ready", runId: session.id });
  await new Promise(() => {});
}

for (const runId of [...(plan.known ?? []), ...created, ...appCreated]) emit({ op: "status", runId, status: (await restarted.run(runId)).status });
emit({ op: "end" });
await agent?.close().catch(() => {});
await restarted.close();
process.exit(0);
