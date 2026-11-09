// The durable core with a harness that is not fx: a scripted agent whose
// turns are a few steps, each stored as one record. It shows the contract
// `createDurableAgentFactory` documents is all a harness needs, and is the
// smallest example of one.
//
//   node sdk/tests/test-durable-core.mjs [memory|local|world|queue]
import { strict as assert } from "node:assert";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDurableAgentFactory, extendLogView, foldSessionLog, handoffEntries, memory, wakeHandler } from "../durable.js";
import { world } from "../durable/world.mjs";

const durabilityKind = process.argv[2] || "memory";
const { local } = durabilityKind === "local" ? await import("../durable/local.mjs") : {};
// "world": the app's own World through world(); see app-world.mjs.
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("./app-world.mjs") : {};
// "queue": a World whose queue delivers as Vercel Queues does, which shows
// whether a worker lives, so leases are held without renewals; see
// queue-world.mjs.
const { queueWorldAt, closeQueueWorlds } = durabilityKind === "world" || durabilityKind === "queue" ? await import("./queue-world.mjs") : {};
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const dirs = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Every step any harness session ran, as `turnId:step`.
const ran = [];
// Every turn a harness session was asked to start, by id.
const prompted = [];
// Inputs whose first prompt throws, as a harness that cannot run does, and
// whose first turn stops under them, as one whose engine exited does.
const flaky = new Set(["flaky"]);
const stopping = new Set(["halting"]);
// An input whose engine stops every time it starts it, and one whose engine
// stops right after the turn's end lands.
const doomed = "doomed";
const stopsAfterEnd = new Set(["omega"]);
// An input whose engine stops each time it continues its started turn unless
// the turn is being cancelled, one whose engine stops even then, and one
// whose end record is still landing when its engine stops.
const brittle = "brittle";
const shattered = "shattered";
const endsLate = new Set(["late"]);
// How many engines the scripted harness opened and closed, how long each
// takes to close, and a promise each open waits for while a test holds it.
const opened = { count: 0 };
const closed = { count: 0 };
const closeDelay = { ms: 0 };
const openHold = { until: null };
const harnessStopped = (message) => Object.assign(new Error(message), { code: "FX_HARNESS_STOPPED" });
// Steps that wait until a test lets them go, by text.
const holds = new Map();

/**
 * A turn of `input` is `steps` steps, each producing one word. A session
 * keeps them as records `{ turnId, step, word }`, with the turn's start and
 * end marked, and a yield as its own record.
 */
function scriptedHarness({ steps = 3 } = {}) {
  return () => ({
    async open({ store }) {
      opened.count += 1;
      if (openHold.until) await openHold.until;
      const loaded = await store.load();
      const records = loaded.journal.map((record) => JSON.parse(decoder.decode(record.data)));
      let handedOff = false;
      let key = 0;
      const landing = new Set();
      const append = async (record, marks) => {
        if (handedOff) throw new Error("handed off");
        await store.append({ idempotencyKey: `scripted:${Date.now()}:${key++}`, data: encoder.encode(JSON.stringify(record)), marks });
        records.push(record);
      };
      const turnOf = (turnId) => records.filter((record) => record.turnId === turnId && record.word !== undefined);
      const openTurn = () => {
        for (let index = records.length - 1; index >= 0; index -= 1) {
          if (records[index].end) return null;
          if (records[index].start) return { id: records[index].turnId, input: records[index].input };
        }
        return null;
      };
      const run = (turnId, input, yieldAt) => scriptedTurn(async (push, signal) => {
        try {
          return await steps_(turnId, input, yieldAt, push, signal);
        } catch (error) {
          // A cancel ends the turn; a handoff, or an engine that stopped,
          // stores nothing more.
          if (signal.aborted && !handedOff && error?.code !== "FX_HARNESS_STOPPED") await append({ turnId, end: true }, [{ end: true }]).catch(() => {});
          throw error;
        }
      }, () => { handedOff = true; });
      const steps_ = async (turnId, input, yieldAt, push, signal) => {
        if (input === brittle || input === shattered) {
          // The engine dies at its next model request, which a cancel that
          // arrives first avoids, as fx's kernel does.
          await sleep(5);
          if (input === brittle && signal.aborted) throw new Error("aborted");
          throw harnessStopped("the engine exited mid-turn");
        }
        let first = true;
        for (let step = turnOf(turnId).length; step < steps; step += 1) {
          if (!first && yieldAt !== undefined && Date.now() >= yieldAt) {
            await append({ turnId, yield: true }, [{ yield: true }]);
            return { stopReason: "yielded" };
          }
          first = false;
          const word = `${input}-${step}`;
          const hold = holds.get(word);
          if (hold) {
            hold.started();
            await Promise.race([hold.released, new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }))]);
          }
          // A step takes time, as a model call or a tool does.
          await sleep(2);
          if (signal.aborted) throw new Error("aborted");
          ran.push(`${turnId}:${step}`);
          const last = step === steps - 1;
          if (last && endsLate.delete(input)) {
            // The end record is still on its way when the engine stops.
            const write = sleep(150).then(() => append({ turnId, step, word, end: true }, [{ end: true }]));
            landing.add(write);
            push({ type: "text_delta", delta: `${word} ` });
            throw harnessStopped("the engine exited as the turn ended");
          }
          await append({ turnId, step, word, ...(last ? { end: true } : {}) }, last ? [{ end: true }] : []);
          push({ type: "text_delta", delta: `${word} ` });
        }
        if (stopsAfterEnd.delete(input)) throw harnessStopped("the engine exited after the turn ended");
        return { stopReason: "end_turn" };
      };
      return {
        prompt(input, { turnId, yieldAt } = {}) {
          prompted.push(turnId);
          // A harness refuses an input with a turn that ends in an error
          // before it writes anything, as fx's kernel refuses an empty
          // prompt. One that throws cannot run a turn at all.
          if (flaky.delete(input)) throw new Error("the harness stopped");
          if (stopping.delete(input) || input === doomed) {
            const stopped = harnessStopped("the engine exited");
            const result = Promise.reject(stopped);
            result.catch(() => {});
            return { result, steer: async () => {}, cancel() {}, async *[Symbol.asyncIterator]() { throw stopped; } };
          }
          if (input === "refuse") return scriptedTurn(async () => ({ stopReason: "error", error: { name: "Error", message: "refused" } }), () => {});
          const started = append({ turnId, start: true, input }, [{ start: turnId }]);
          return chain(started, () => run(turnId, input, yieldAt));
        },
        resume({ yieldAt } = {}) {
          const open = openTurn();
          return run(open.id, open.input, yieldAt);
        },
        get openTurn() {
          const open = openTurn();
          return open && { id: open.id };
        },
        settled: async () => {},
        saveCheckpoint: async () => {},
        exportCheckpoint: async () => encoder.encode(JSON.stringify(records.filter((record) => record.word !== undefined).map((record) => record.word))),
        // Closing waits for the records still landing, as fx's engine does,
        // and takes `closeDelay.ms` more, as an engine that saves on close.
        close: async () => {
          await Promise.allSettled([...landing]);
          if (closeDelay.ms > 0) await sleep(closeDelay.ms);
          closed.count += 1;
        },
      };
    },
  });
}

// A turn: its events as an async iterable, its `result`, and `cancel()`; a
// handoff stops it and stores nothing more.
function scriptedTurn(body, onHandoff) {
  const queue = [];
  let wake = null;
  let finished = false;
  const controller = new AbortController();
  let cancelled = false;
  const result = body((event) => { queue.push(event); wake?.(); }, controller.signal)
    .catch((error) => {
      // A stopped harness is not a turn's outcome; it reaches the core as is.
      if (error?.code === "FX_HARNESS_STOPPED") throw error;
      return cancelled ? { stopReason: "cancelled" } : { stopReason: "error", error: { name: "Error", message: String(error?.message ?? error) } };
    })
    .finally(() => { finished = true; wake?.(); });
  void result.catch(() => {});
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
        while (queue.length) yield queue.shift();
        if (finished) return;
        await new Promise((resolve) => { wake = resolve; });
        wake = null;
      }
    },
  };
}

// A turn that starts once `before` resolves.
function chain(before, next) {
  let turn = null;
  const ready = before.then(() => { turn = next(); return turn; });
  // A turn whose start was refused rejects; the core may never ask.
  const result = ready.then((value) => value.result);
  void result.catch(() => {});
  return {
    result,
    steer: async (...args) => (await ready).steer(...args),
    // A turn whose start was refused has nothing to cancel.
    cancel: (options) => { ready.then((value) => value.cancel(options), () => {}); },
    async *[Symbol.asyncIterator]() { yield* await ready; },
  };
}

const createAgent = createDurableAgentFactory({ harness: scriptedHarness(), defaultDurability: async () => memory(), name: "createScriptedAgent" });

// Agents that record which of them opened each session's engine, by `tag`.
const openedBy = [];
const createTaggedAgent = createDurableAgentFactory({
  harness: ({ tag }) => {
    const plugged = scriptedHarness()();
    return { open: (args) => { openedBy.push([tag, args.sessionId]); return plugged.open(args); } };
  },
  defaultDurability: async () => memory(),
  name: "createTaggedAgent",
});
const openersOf = (sessionId) => [...new Set(openedBy.filter(([, id]) => id === sessionId).map(([tag]) => tag))];

async function durabilityFor(options = {}) {
  if (durabilityKind === "memory") return memory(options);
  const dir = await mkdtemp(join(tmpdir(), "libfx-core-"));
  dirs.push(dir);
  return durabilityAt(dir, options);
}

// A durability of this run's kind on `dir`: each call is another server on
// the same store.
async function durabilityAt(dir, options = {}) {
  // A queue-held lease needs a deadline: a function's, ten minutes away.
  if (durabilityKind === "queue") return (await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000, ...options })).durability;
  return durabilityKind === "world" ? appWorldAt(dir, options) : local({ dir, ...options });
}

async function textOf(turn) {
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  return { text: text.trim(), result: await turn.result };
}

async function readLines(stream, count, quietMs = 300) {
  const reader = stream.getReader();
  let buffered = "";
  const lines = [];
  while (lines.length < count) {
    let timer;
    const quiet = new Promise((resolve) => { timer = setTimeout(() => resolve({ done: true }), quietMs); });
    const { value, done } = await Promise.race([reader.read(), quiet]);
    clearTimeout(timer);
    if (done) break;
    buffered += decoder.decode(value, { stream: true });
    for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
      lines.push(JSON.parse(buffered.slice(0, index)));
      buffered = buffered.slice(index + 1);
    }
  }
  await reader.cancel();
  return lines;
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("a prompt runs its steps, and the session replays from any cursor", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const { text, result } = await textOf(session.prompt("alpha", { messageId: "turn-a" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "alpha-0 alpha-1 alpha-2");
  const lines = await readLines(session.stream(0), 8);
  assert.deepEqual(lines.map((line) => line.type), ["turn_start", "text_delta", "text_delta", "text_delta", "turn_end"]);
  const later = await readLines(session.stream(lines[2].cursor), 8);
  assert.deepEqual(later, lines.slice(3), "a reconnect from a cursor shows the lines after it");
  assert.deepEqual(JSON.parse(decoder.decode(await session.checkpoint())), ["alpha-0", "alpha-1", "alpha-2"]);
  await agent.close();
});

test("a turn longer than the time limit continues in the next delivery, each step once", async () => {
  const agent = createAgent({ durability: await durabilityFor({ maxDurationMs: 1, reserveMs: 0 }) });
  const session = agent.session();
  const before = ran.length;
  const { text, result } = await textOf(session.prompt("beta", { messageId: "turn-b" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "beta-0 beta-1 beta-2");
  assert.deepEqual(ran.slice(before), ["turn-b:0", "turn-b:1", "turn-b:2"]);
  const lines = await readLines(session.stream(0), 16);
  assert.equal(lines.filter((line) => line.type === "turn_yield").length, 2);
  assert.equal(lines.filter((line) => line.type === "turn_resume").length, 2);
  await agent.close();
});

test("a step cut off at the deadline continues in the next delivery", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  let started;
  const hold = { started: () => started(), released: new Promise(() => {}) };
  const holding = new Promise((resolve) => { started = resolve; });
  holds.set("gamma-1", hold);
  const before = ran.length;
  const turn = session.prompt("gamma", { messageId: "turn-g" });
  await holding;
  holds.delete("gamma-1");
  agent[Symbol.for("libfx.durableInternals")].stopAtDeadline(session.id);
  const { text, result } = await textOf(turn);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "gamma-0 gamma-1 gamma-2");
  assert.deepEqual(ran.slice(before), ["turn-g:0", "turn-g:1", "turn-g:2"], "the cut-off step ran once, in the next delivery");
  await agent.close();
});

test("two agents prompting one session run its turns one at a time, in one history", async () => {
  const durability = await durabilityFor();
  const first = createAgent({ durability });
  const second = createAgent({ durability });
  const session = first.session();
  await textOf(session.prompt("delta", { messageId: "turn-d" }));
  const [a, b] = await Promise.all([
    textOf(first.session(session.id).prompt("one", { messageId: "turn-1" })),
    textOf(second.session(session.id).prompt("two", { messageId: "turn-2" })),
  ]);
  assert.equal(a.text, "one-0 one-1 one-2");
  assert.equal(b.text, "two-0 two-1 two-2");
  const words = JSON.parse(decoder.decode(await first.session(session.id).checkpoint()));
  assert.equal(words.length, 9);
  for (const name of ["one", "two"]) {
    const at = words.indexOf(`${name}-0`);
    assert.deepEqual(words.slice(at, at + 3), [`${name}-0`, `${name}-1`, `${name}-2`], "turns never interleave");
  }
  await first.close();
  await second.close();
});

test("agents with different names each run only their own sessions' turns", async () => {
  const durability = await durabilityFor();
  // Each agent's own prompts reach it directly, never through the other.
  const forwarded = [];
  const onEvent = (event) => { if (event.type === "session.forwarded") forwarded.push(event); };
  const support = createTaggedAgent({ durability, name: "support", tag: "support", onEvent });
  const coding = createTaggedAgent({ durability, name: "coding", tag: "coding", onEvent });
  assert.equal(support.name, "support");
  const ours = support.session();
  const theirs = coding.session();
  for (let round = 0; round < 4; round += 1) {
    const [a, b] = await Promise.all([textOf(ours.prompt(`s${round}`)), textOf(theirs.prompt(`c${round}`))]);
    assert.equal(a.text, `s${round}-0 s${round}-1 s${round}-2`);
    assert.equal(b.text, `c${round}-0 c${round}-1 c${round}-2`);
  }
  assert.deepEqual(openersOf(ours.id), ["support"]);
  assert.deepEqual(openersOf(theirs.id), ["coding"]);
  assert.deepEqual(forwarded, [], "every delivery went to the agent its message names");
  await support.close();
  await coding.close();
});

test("a prompt to another agent's session runs on that session's agent", async () => {
  const durability = await durabilityFor();
  const events = [];
  const support = createTaggedAgent({ durability, name: "support", tag: "support" });
  const coding = createTaggedAgent({ durability, name: "coding", tag: "coding", onEvent: (event) => events.push(event) });
  const session = support.session();
  await textOf(session.prompt("first"));
  const { text, result } = await textOf(coding.session(session.id).prompt("second"));
  assert.equal(text, "second-0 second-1 second-2");
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(openersOf(session.id), ["support"]);
  assert.ok(events.some((event) => event.type === "session.forwarded" && event.sessionId === session.id && event.agent === "support"), "the sender says it sent the message on");
  await support.close();
  await coding.close();
});

if (durabilityKind === "local") {
  // local() makes each agent a World of its own, which delivers only the
  // messages it queued, as world-local does.
  test("agents on one durability, each on a World of its own, still send each other's prompts on", async () => {
    const durability = await durabilityFor();
    const support = createTaggedAgent({ durability, name: "support", tag: "support" });
    const coding = createTaggedAgent({ durability, name: "coding", tag: "coding" });
    const ours = support.session();
    const theirs = coding.session();
    await Promise.all([textOf(ours.prompt("one")), textOf(theirs.prompt("two"))]);
    const [a, b] = await Promise.all([textOf(coding.session(ours.id).prompt("three")), textOf(support.session(theirs.id).prompt("four"))]);
    assert.equal(a.text, "three-0 three-1 three-2");
    assert.equal(b.text, "four-0 four-1 four-2");
    assert.deepEqual(openersOf(ours.id), ["support"]);
    assert.deepEqual(openersOf(theirs.id), ["coding"]);
    await support.close();
    await coding.close();
  });
}

test("an agent's name defaults to default, and a malformed one is refused", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  assert.equal(agent.name, "default");
  await agent.close();
  for (const name of ["", "two words", "-dash", "x".repeat(65), 7, null]) {
    assert.throws(() => createAgent({ name }), /createScriptedAgent\(\) name must be 1 to 64 letters/, `refuses ${JSON.stringify(name)}`);
  }
  const named = createAgent({ name: "a.b_c-9" });
  assert.equal(named.name, "a.b_c-9");
  await named.close();
});

test("a retried message runs its turn once", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const before = ran.length;
  await textOf(session.prompt("epsilon", { messageId: "turn-e" }));
  const again = await session.prompt("epsilon", { messageId: "turn-e" }).result;
  assert.equal(again.stopReason, "end_turn");
  assert.equal(ran.length - before, 3, "the retry ran nothing");
  await agent.close();
});

// A step a test holds until it lets it go.
function holdStep(word) {
  let started;
  let release;
  const holding = new Promise((resolve) => { started = resolve; });
  const released = new Promise((resolve) => { release = resolve; });
  holds.set(word, { started: () => started(), released });
  return { holding, release: () => { holds.delete(word); release(); } };
}

// How long a test waits for a cancel to reach the log.
const landMs = durabilityKind === "memory" ? 50 : 400;

test("a turn that ends before writing a record runs once, and the session goes on", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const before = prompted.length;
  const refused = await session.prompt("refuse", { messageId: "turn-r" }).result;
  assert.equal(refused.stopReason, "error");
  const { text, result } = await textOf(session.prompt("zeta", { messageId: "turn-z" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "zeta-0 zeta-1 zeta-2");
  assert.deepEqual(prompted.slice(before), ["turn-r", "turn-z"], "the refused turn ran once");
  const again = await session.prompt("refuse", { messageId: "turn-r" }).result;
  assert.equal(again.stopReason, "error", "a retry reports the turn's own outcome");
  assert.equal(again.repeated, true);
  assert.deepEqual(prompted.slice(before), ["turn-r", "turn-z"], "the retry ran nothing");
  await agent.close();
});

test("a harness that throws instead of starting a turn is replaced, and no prompt is lost", async () => {
  const events = [];
  const agent = createAgent({ durability: await durabilityFor(), onEvent: (event) => events.push(event.type) });
  const session = agent.session();
  const before = prompted.length;
  const flakyTurn = session.prompt("flaky", { messageId: "turn-flaky" });
  await flakyTurn.accepted;
  const queued = session.prompt("eta", { messageId: "turn-eta0" });
  const { text, result } = await textOf(flakyTurn);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "flaky-0 flaky-1 flaky-2");
  assert.equal((await queued.result).stopReason, "end_turn", "the prompt behind it ran too");
  assert.deepEqual(prompted.slice(before), ["turn-flaky", "turn-flaky", "turn-eta0"], "a new harness ran the turn");
  assert.ok(events.includes("session.error"), JSON.stringify(events));
  await agent.close();
});

test("a prompt's signal cancels its own turn, whether it runs or waits, and never another", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const before = ran.length;
  // An abort while the prompt waits behind a running turn.
  const held = holdStep("theta-1");
  const running = session.prompt("theta", { messageId: "turn-theta" });
  await held.holding;
  const waiting = new AbortController();
  const queued = session.prompt("iota", { messageId: "turn-iota", signal: waiting.signal });
  await queued.accepted;
  waiting.abort();
  await sleep(landMs);
  held.release();
  assert.equal((await running.result).stopReason, "end_turn", "the turn ahead ran to its end");
  assert.equal((await queued.result).stopReason, "cancelled");
  const retried = await session.prompt("iota", { messageId: "turn-iota" }).result;
  assert.equal(retried.stopReason, "cancelled", "a retry reports the cancel");
  // An abort while the prompt's own turn runs.
  const own = holdStep("kappa-1");
  const stopping = new AbortController();
  const kappa = session.prompt("kappa", { messageId: "turn-kappa", signal: stopping.signal });
  await own.holding;
  stopping.abort();
  assert.equal((await kappa.result).stopReason, "cancelled");
  own.release();
  // An abort after its turn ended stops nothing later.
  const ended = new AbortController();
  assert.equal((await session.prompt("lambda", { messageId: "turn-lambda", signal: ended.signal }).result).stopReason, "end_turn");
  const later = holdStep("mu-1");
  const mu = session.prompt("mu", { messageId: "turn-mu" });
  await later.holding;
  ended.abort();
  await sleep(landMs);
  later.release();
  assert.equal((await mu.result).stopReason, "end_turn");
  // A signal that had already aborted runs nothing.
  assert.equal((await session.prompt("nu", { messageId: "turn-nu", signal: AbortSignal.abort() }).result).stopReason, "cancelled");
  assert.deepEqual(ran.slice(before).filter((step) => /iota|nu/.test(step)), [], "the cancelled prompts ran no step");
  await agent.close();
});

if (durabilityKind === "memory") {
  test("a write that fails for a reason other than a takeover is retried", async () => {
    const durability = memory({ maxDurationMs: 1, reserveMs: 0 });
    // The backend the agent shares, with the first release it writes refused.
    const backend = durability.create();
    const open = backend.session.bind(backend);
    let refusals = 0;
    backend.session = async (id) => {
      const log = await open(id);
      return {
        ...log,
        append: async (entry) => {
          if (entry.k === "release" && refusals === 0) {
            refusals += 1;
            throw new Error("the store is briefly unavailable");
          }
          return log.append(entry);
        },
      };
    };
    const events = [];
    const agent = createAgent({ durability, onEvent: (event) => events.push(event.type) });
    const { text, result } = await textOf(agent.session().prompt("xi", { messageId: "turn-xi" }));
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "xi-0 xi-1 xi-2");
    assert.equal(refusals, 1);
    assert.ok(!events.includes("session.fenced"), "a failed write is not a takeover");
    assert.ok(events.includes("session.error"), JSON.stringify(events));
    await agent.close();
  });
}

if (durabilityKind === "local") {
  test("a session stream that cannot be read fails its view instead of waiting", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-"));
    dirs.push(dir);
    const durability = local({ dir });
    const worldOf = durability.world;
    const bound = (target, overrides) => new Proxy(target, {
      get(object, key) {
        if (key in overrides) return overrides[key];
        const value = object[key];
        return typeof value === "function" ? value.bind(object) : value;
      },
    });
    durability.world = async () => {
      const world = await worldOf();
      const denied = async () => { throw Object.assign(new Error("forbidden"), { status: 403 }); };
      return bound(world, { streams: bound(world.streams, { get: denied }) });
    };
    const agent = createAgent({ durability });
    const started = performance.now();
    await assert.rejects(agent.session().prompt("omicron", { messageId: "turn-o" }).result, /forbidden/);
    assert.ok(performance.now() - started < 10_000, "the view failed promptly");
    await agent.close();
  });
}

test("a turn whose harness stops under it, and the prompts behind it, still run", async () => {
  const events = [];
  const agent = createAgent({ durability: await durabilityFor(), onEvent: (event) => events.push(event.type) });
  const session = agent.session();
  const before = prompted.length;
  const first = session.prompt("halting", { messageId: "turn-halt" });
  await first.accepted;
  const behind = session.prompt("tau", { messageId: "turn-tau" });
  const { text, result } = await textOf(first);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "halting-0 halting-1 halting-2");
  assert.equal((await behind.result).stopReason, "end_turn");
  assert.deepEqual(prompted.slice(before), ["turn-halt", "turn-halt", "turn-tau"]);
  assert.ok(events.includes("session.error"), JSON.stringify(events));
  await agent.close();
});

test("an engine that stops each time it starts a turn ends that turn, and the session goes on", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const before = prompted.length;
  const stuck = session.prompt(doomed, { messageId: "turn-doomed" });
  await stuck.accepted;
  const behind = session.prompt("psi", { messageId: "turn-psi" });
  const ended = await stuck.result;
  assert.equal(ended.stopReason, "error");
  assert.match(ended.error?.message ?? "", /stopped each of the 3 times/);
  assert.equal((await behind.result).stopReason, "end_turn", "the prompt behind it ran");
  assert.deepEqual(prompted.slice(before), ["turn-doomed", "turn-doomed", "turn-doomed", "turn-psi"]);
  await agent.close();
});

test("a turn whose engine stops after its end landed still ends for its viewers", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const { text, result } = await textOf(session.prompt("omega", { messageId: "turn-omega" }));
  assert.equal(result.stopReason, "unknown");
  assert.equal(text, "omega-0 omega-1 omega-2");
  assert.equal((await session.prompt("after", { messageId: "turn-after" }).result).stopReason, "end_turn");
  await agent.close();
});

test("a started turn whose engine keeps stopping is cancelled, and the prompts behind it run", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const stuck = session.prompt(brittle, { messageId: "turn-brittle" });
  await stuck.accepted;
  const behind = session.prompt("zeta2", { messageId: "turn-zeta2" });
  assert.equal((await stuck.result).stopReason, "cancelled");
  assert.equal((await behind.result).stopReason, "end_turn");
  assert.equal((await session.prompt("eta2").result).stopReason, "end_turn");
  // A retry by id answers from the log.
  assert.equal((await session.prompt(brittle, { messageId: "turn-brittle" }).result).repeated, true);
  await agent.close();
});

// An agent whose first `works` engines open and whose later ones cannot,
// or, given a function, whose engines open when `opens(n)` says so.
function agentWhoseEnginesFailAfter(works, durability) {
  const scripted = scriptedHarness();
  const counts = { opens: 0 };
  const opens = typeof works === "function" ? works : (n) => n <= works;
  const create = createDurableAgentFactory({
    harness: (options) => {
      const base = scripted(options);
      return { open: async (args) => {
        counts.opens += 1;
        if (!opens(counts.opens)) throw new Error("no engine");
        return base.open(args);
      } };
    },
    defaultDurability: async () => memory(),
    name: "createFailingAgent",
  });
  return { agent: create({ durability }), counts };
}

// Engines stop opening within a bounded number of tries: the count holds
// still for 2.5 s, within 10 s, and stays within `limit`.
async function opensSettle(counts, limit) {
  for (let tries = 0; tries < 4; tries += 1) {
    const before = counts.opens;
    await sleep(2500);
    if (counts.opens === before) break;
  }
  const settled = counts.opens;
  await sleep(2500);
  assert.equal(counts.opens, settled, "no more engines once nothing can run");
  assert.ok(counts.opens <= limit, `opened ${counts.opens} engines`);
}

test("an engine that cannot open again fails the open turn once, then each prompt waiting", async () => {
  const { agent, counts } = agentWhoseEnginesFailAfter(1, await durabilityFor());
  const session = agent.session();
  const open = session.prompt(shattered, { messageId: "turn-dies" });
  await open.accepted;
  const behind = session.prompt("iota2", { messageId: "turn-iota2" });
  const first = await open.result;
  assert.equal(first.stopReason, "error");
  assert.match(first.error?.message ?? "", /no engine/);
  const second = await behind.result;
  assert.equal(second.stopReason, "error");
  assert.match(second.error?.message ?? "", /no engine/);
  await opensSettle(counts, 3);
  await agent.close();
});

test("a stuck turn whose engine then cannot open is not opened forever", async () => {
  const { agent, counts } = agentWhoseEnginesFailAfter(3, await durabilityFor());
  const session = agent.session();
  const ended = await session.prompt(shattered, { messageId: "turn-stuck" }).result;
  assert.equal(ended.stopReason, "error");
  await opensSettle(counts, 8);
  await agent.close();
});

test("a cancel for a turn whose engine cannot open is not retried forever", async () => {
  const { agent, counts } = agentWhoseEnginesFailAfter(1, await durabilityFor());
  const session = agent.session();
  const ended = await session.prompt(shattered, { messageId: "turn-cancelled" }).result;
  assert.equal(ended.stopReason, "error");
  await session.cancel();
  await opensSettle(counts, 8);
  await agent.close();
});

// Engines that open, except during a 1.5 s outage that starts once engine
// `after` has opened.
function outageAfter(after) {
  const outage = { until: Infinity };
  const opens = (n) => {
    if (n === after) outage.until = Date.now() + 1500;
    return n <= after || Date.now() >= outage.until;
  };
  return { opens, over: () => sleep(Math.max(0, outage.until - Date.now()) + 50) };
}

test("an outage while a stuck turn is cancelled does not halt the session", async () => {
  // Three engines stop under the turn; the next ones cannot open for a while.
  const outage = outageAfter(3);
  const { agent } = agentWhoseEnginesFailAfter(outage.opens, await durabilityFor());
  const session = agent.session();
  const stuck = await session.prompt(brittle, { messageId: "turn-outage" }).result;
  assert.equal(stuck.stopReason, "error");
  assert.match(stuck.error?.message ?? "", /no engine/);
  await outage.over();
  // The next prompt's engine cancels the open turn, then runs the prompt.
  assert.equal((await session.prompt("kappa2").result).stopReason, "end_turn");
  assert.equal((await session.prompt("lambda2").result).stopReason, "end_turn");
  await agent.close();
});

test("an outage while a cancel waits does not halt the session", async () => {
  // The first engine stops under the turn; the next ones cannot open for a while.
  const outage = outageAfter(1);
  const { agent } = agentWhoseEnginesFailAfter(outage.opens, await durabilityFor());
  const session = agent.session();
  const ended = await session.prompt(brittle, { messageId: "turn-blip" }).result;
  assert.equal(ended.stopReason, "error");
  await session.cancel();
  await outage.over();
  assert.equal((await session.prompt("mu2").result).stopReason, "end_turn");
  assert.equal((await session.prompt("nu2").result).stopReason, "end_turn");
  await agent.close();
});

test("a lone started turn whose engine stops even when cancelled ends, and the session refuses more turns", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const ended = await session.prompt(shattered, { messageId: "turn-shattered" }).result;
  assert.equal(ended.stopReason, "error");
  assert.match(ended.error?.message ?? "", /even to cancel it/);
  // Later prompts end with an error without starting an engine.
  const engines = opened.count;
  const later = await session.prompt("theta2").result;
  assert.equal(later.stopReason, "error");
  assert.match(later.error?.message ?? "", /open turn cannot continue/);
  assert.equal(opened.count, engines, "no engine started");
  const retried = await Promise.race([
    session.prompt(shattered, { messageId: "turn-shattered" }).result,
    sleep(5000).then(() => { throw new Error("the retry did not answer"); }),
  ]);
  assert.equal(retried.repeated, true);
  assert.equal(retried.stopReason, "error");
  await agent.close();
});

test("a turn whose end is still landing when its engine stops ends as unknown", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const { text, result } = await textOf(session.prompt("late", { messageId: "turn-late" }));
  assert.equal(result.stopReason, "unknown");
  assert.equal(text, "late-0 late-1 late-2");
  assert.equal((await session.prompt("after late", { messageId: "turn-after-late" }).result).stopReason, "end_turn");
  await agent.close();
});

test("a World stream that takes forever to cancel holds no view or retry", async () => {
  if (durabilityKind !== "local") return;
  // As Vercel's live stream reads can: cancelling one never settles.
  const base = await durabilityFor();
  const stalled = {
    ...base,
    world: async () => {
      const world = await base.world();
      const get = world.streams.get.bind(world.streams);
      const streams = Object.assign(Object.create(world.streams), {
        async get(...args) {
          const reader = (await get(...args)).getReader();
          return new ReadableStream({
            async pull(controller) {
              const { value, done } = await reader.read();
              if (done) controller.close();
              else controller.enqueue(value);
            },
            cancel: () => new Promise(() => {}),
          });
        },
      });
      return Object.assign(Object.create(world), { streams });
    },
  };
  const agent = createAgent({ durability: stalled });
  const session = agent.session();
  const within = (promise, label) => Promise.race([promise, sleep(5000).then(() => { throw new Error(`${label} did not finish`); })]);
  const turn = session.prompt("xi2", { messageId: "turn-xi2" });
  // Its readable closes once the turn ends.
  const reader = turn.readable.getReader();
  await within((async () => { for (;;) { const { done } = await reader.read(); if (done) return; } })(), "the view's readable");
  assert.equal((await turn.result).stopReason, "end_turn");
  const again = await within(session.prompt("xi2", { messageId: "turn-xi2" }).result, "the retry");
  assert.equal(again.repeated, true);
  assert.equal(again.stopReason, "end_turn");
  await agent.close();
});

test("a prompt sent when the last turn ends starts without waiting for its engine to shut down", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  closeDelay.ms = 1500;
  try {
    assert.equal((await session.prompt("first", { messageId: "turn-first" }).result).stopReason, "end_turn");
    const sent = performance.now();
    const { text, result } = await textOf(session.prompt("second", { messageId: "turn-second" }));
    const took = performance.now() - sent;
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "second-0 second-1 second-2");
    assert.ok(took < 1000, `the next turn waited ${took.toFixed(0)}ms for the last one's engine to shut down`);
  } finally {
    closeDelay.ms = 0;
  }
  // The agent still waits for every engine it started on close.
  await agent.close();
});

// A World durability that tells `onRead(from)` where each stream read starts.
function watchingReads(base, onRead) {
  return {
    ...base,
    world: async () => {
      const world = await base.world();
      const get = world.streams.get.bind(world.streams);
      const streams = Object.assign(Object.create(world.streams), {
        get(runId, name, from, ...rest) {
          onRead(from);
          return get(runId, name, from, ...rest);
        },
      });
      return Object.assign(Object.create(world), { streams });
    },
  };
}

if (durabilityKind === "queue") {
  test("on a World with the in-band fence, a worker's chained entries go in-band, and one that continues a superseded head is refused before it lands", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fence-"));
    dirs.push(dir);
    const { durability, fence } = await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000, inBandFence: true });
    const agent = createAgent({ durability });
    const internals = agent[Symbol.for("libfx.durableInternals")];
    const session = agent.session();
    assert.equal((await textOf(session.prompt("omicron"))).result.stopReason, "end_turn");
    for (let tries = 0; internals.liveWorkers() > 0; tries += 1) {
      assert.ok(tries < 200, "the worker never let go");
      await sleep(10);
    }
    // The worker's chained entries went in-band, each expecting the count
    // the one before it left, from the run's creation on; its input, turn end
    // and any checkpoint went out-of-band.
    const writes = fence.creates
      .filter((create) => create.runId === session.id && create.data?.eventType === "step_created")
      .map((create) => ({ entry: JSON.parse(decoder.decode(create.data.eventData.input)), params: create.params ?? {} }));
    const isChained = ({ entry }) => entry.k === "lease" || entry.k === "record" || entry.k === "release";
    const chained = writes.filter(isChained);
    assert.ok(chained.length >= 3, JSON.stringify(writes.map(({ entry }) => entry.k)));
    assert.deepEqual(chained.map(({ params }) => [params.inBand, params.expectedSeqInBand]), chained.map((_, index) => [true, 1 + index]));
    assert.deepEqual(writes.filter((write) => !isChained(write)).map(({ params }) => params.inBand), writes.filter((write) => !isChained(write)).map(() => undefined));
    // Two workers that read the same head both continue it: the World takes
    // the first, and refuses the second before any of it is written.
    const first = await internals.openLog(session.id);
    const second = await internals.openLog(session.id);
    const { head } = foldSessionLog(await first.read());
    assert.equal(foldSessionLog(await second.read()).head, head);
    const lease = (holder) => ({ k: "lease", a: head, holder, epoch: 90, expiresAt: Date.now() + 60_000, pid: 1, host: "test" });
    const won = await first.append(lease("wkr_first"));
    await assert.rejects(second.append(lease("wkr_second")), (error) => error.code === "FX_FENCED");
    const continuing = (await first.read()).filter(({ entry }) => entry.k === "lease" && entry.a === head).map(({ entry }) => entry.holder);
    assert.deepEqual(continuing, ["wkr_first"], "the refused lease never landed");
    // The worker that won goes on from its own write.
    await first.append({ k: "release", a: won, holder: "wkr_first" });
    assert.equal(foldSessionLog(await second.read()).lastLease, null);
    await agent.close();
  });

  test("a worker that read the head while its in-band count was settling still continues it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fence-settle-"));
    dirs.push(dir);
    const { durability } = await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000, inBandFence: { settleMs: 300 } });
    const agent = createAgent({ durability });
    const internals = agent[Symbol.for("libfx.durableInternals")];
    const session = agent.session();
    assert.equal((await textOf(session.prompt("pi"))).result.stopReason, "end_turn");
    for (let tries = 0; internals.liveWorkers() > 0; tries += 1) {
      assert.ok(tries < 200, "the worker never let go");
      await sleep(10);
    }
    const first = await internals.openLog(session.id);
    const { head } = foldSessionLog(await first.read());
    const lease = { k: "lease", a: head, holder: "wkr_first", epoch: 90, expiresAt: Date.now() + 60_000, pid: 1, host: "test" };
    const writing = first.append(lease);
    // A second worker reads after the lease is published, but before the
    // World counts it.
    const second = await internals.openLog(session.id);
    let seen = null;
    for (let tries = 0; seen === null; tries += 1) {
      assert.ok(tries < 100, "the lease never showed");
      const { head: now } = foldSessionLog(await second.read());
      if (now !== head) seen = now;
      else await sleep(5);
    }
    assert.equal(seen, await writing);
    // Nothing else continued the lease, so the release goes through.
    const released = await second.append({ k: "release", a: seen, holder: "wkr_first" });
    assert.equal(foldSessionLog(await first.read()).head, released);
    // One that continues a head another worker continued is still refused.
    await assert.rejects(first.append({ k: "release", a: seen, holder: "wkr_first" }), (error) => error.code === "FX_FENCED");
    await agent.close();
  });
}

if (durabilityKind === "queue") {
  test("where the queue holds sessions, a prompt runs in the request that took it, and its queued message waits as a backstop", async () => {
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    for (const [input, maxDurationMs] of [["nu", 60_000], ["xi3", 300]]) {
      const dir = await mkdtemp(join(tmpdir(), "libfx-in-request-"));
      dirs.push(dir);
      const waited = [];
      const { durability, broker } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs, reserveMs: 100, waitUntil: (work) => waited.push(work) });
      const agent = createAgent({ durability });
      const session = agent.session();
      // With the short deadline, a step outlasts the request.
      if (maxDurationMs < 1000) {
        const slow = holdStep(`${input}-1`);
        void slow.holding.then(() => setTimeout(slow.release, 600));
      }
      const { text, result } = await textOf(session.prompt(input, { messageId: `turn-${input}` }));
      assert.equal(result.stopReason, "end_turn");
      assert.equal(text, [0, 1, 2].map((step) => `${input}-${step}`).join(" "));
      // The queue's first copy of the prompt is the backstop, and the turn
      // ran before any delivery of it.
      const [backstop, ...after] = broker.sent.filter((message) => message.payload?.input?.messageId === `turn-${input}`);
      assert.equal(backstop.attempt, 0, "the backstop waited");
      if (maxDurationMs < 1000) {
        assert.ok(after.length > 0, "a turn longer than the request went on in a fresh message");
      } else {
        assert.equal(after.length, 0, "the request ran the whole turn");
        // The request's lease names the backstop, so if the request had died,
        // the backstop's delivery would take the session over.
        assert.deepEqual((await internals(agent).lastLease(session.id)).delivery, { messageId: backstop.id, attempt: 0 });
      }
      assert.equal(waited.length, 1, "the request's run went to waitUntil");
      assert.equal(await waited[0], undefined);
      for (let tries = 0; internals(agent).liveWorkers() > 0; tries += 1) {
        assert.ok(tries < 200, "the request's worker never let go");
        await sleep(10);
      }
      // The backstop, delivered at last, finds nothing to do.
      const ranBefore = ran.length;
      broker.lapse(backstop);
      for (let tries = 0; broker.held(() => true).some((message) => message.id === backstop.id); tries += 1) {
        assert.ok(tries < 200, "the backstop was never acknowledged");
        await sleep(10);
      }
      assert.equal(backstop.attempt, 1);
      assert.equal(ran.length, ranBefore, "the backstop ran nothing");
      assert.deepEqual(JSON.parse(decoder.decode(await session.checkpoint())), [0, 1, 2].map((step) => `${input}-${step}`));
      await agent.close();
    }
  });

  test("an image prompt run in the request reads its image from the store, and no queued copy holds it", async () => {
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    for (const maxDurationMs of [60_000, 300]) {
      const dir = await mkdtemp(join(tmpdir(), "libfx-in-request-image-"));
      dirs.push(dir);
      const waited = [];
      const { durability, broker } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs, reserveMs: 100, waitUntil: (work) => waited.push(work) });
      const { agent, seen } = recordingAgent(durability);
      const session = agent.session();
      // With the short deadline, a step outlasts the request.
      if (maxDurationMs < 1000) {
        const slow = holdStep("image-1");
        void slow.holding.then(() => setTimeout(slow.release, 600));
      }
      const messageId = `turn-image-${maxDurationMs}`;
      const turn = session.prompt([{ type: "text", text: "look" }, image], { messageId });
      assert.equal((await turn.result).stopReason, "end_turn");
      assert.equal(waited.length, 1, "the request ran the turn");
      assert.deepEqual(seen, [[{ type: "text", text: "look" }, image]], "with its image, read once");
      const sent = broker.sent.filter((message) => message.payload?.input?.messageId === messageId);
      assert.equal(sent[0].attempt, 0, "the backstop waited");
      if (maxDurationMs < 1000) assert.ok(sent.length > 1, "a turn longer than the request went on in a fresh message");
      for (const message of sent) {
        const payload = JSON.stringify(message.payload);
        assert.ok(!payload.includes(png), "a queued copy holds none of the image");
      }
      await waited[0];
      for (let tries = 0; internals(agent).liveWorkers() > 0; tries += 1) {
        assert.ok(tries < 200, "the request's worker never let go");
        await sleep(10);
      }
      // The backstop, delivered at last, runs nothing.
      broker.lapse(sent[0]);
      for (let tries = 0; broker.held(() => true).some((message) => message.id === sent[0].id); tries += 1) {
        assert.ok(tries < 200, "the backstop was never acknowledged");
        await sleep(10);
      }
      assert.equal(seen.length, 1, "the backstop ran nothing");
      await agent.close();
    }
  });
}

test("a reconnect reads the stream from its cursor's line, not its start", async () => {
  if (durabilityKind === "memory") return;
  const starts = [];
  const agent = createAgent({ durability: watchingReads(await durabilityFor(), (from) => starts.push(from)) });
  const session = agent.session();
  assert.equal((await session.prompt("rho", { messageId: "turn-rho" }).result).stopReason, "end_turn");
  const lines = await readLines(session.stream(0), 8);
  starts.length = 0;
  const later = await readLines(session.stream(lines[2].cursor), 8);
  assert.deepEqual(later, lines.slice(3), "a reconnect from a cursor shows the lines after it");
  assert.deepEqual(starts, [lines[2].cursor - 1], "the read starts at the cursor's own line");
  await agent.close();
});

test("each prompt's turn runs with its own caller's context, resumed or not", async () => {
  const seen = [];
  const contextual = createDurableAgentFactory({
    harness: () => {
      const base = scriptedHarness()();
      return { open: async (options) => { const session = await base.open(options); return { ...session, prompt: (input, opts) => { seen.push([input, options.context]); return session.prompt(input, opts); }, resume: (opts) => { seen.push(["resume", options.context]); return session.resume(opts); }, get openTurn() { return session.openTurn; } }; } };
    },
    defaultDurability: async () => memory(),
  });
  const agent = contextual({ durability: await durabilityFor({ maxDurationMs: 1, reserveMs: 0 }) });
  const opened = agent.session(undefined, { context: { user: "a" } });
  assert.equal((await opened.prompt("upsilon").result).stopReason, "end_turn");
  const id = opened.id;
  assert.equal((await agent.session(id).prompt("phi").result).stopReason, "end_turn");
  assert.equal((await agent.session(id, { context: { user: "b" } }).prompt("chi").result).stopReason, "end_turn");
  assert.deepEqual(seen.filter(([input]) => input === "upsilon").map(([, c]) => c), [{ user: "a" }]);
  assert.deepEqual(seen.filter(([input]) => input === "phi").map(([, c]) => c), [null], "a call without context passes none");
  assert.deepEqual(seen.filter(([input]) => input === "chi").map(([, c]) => c), [{ user: "b" }]);
  // A steer to an idle session starts a turn with the steering call's context.
  await agent.session(id, { context: { user: "s" } }).steer("guide");
  assert.equal((await agent.session(id).prompt("after guide").result).stopReason, "end_turn");
  assert.deepEqual(seen.filter(([input]) => input === "guide").map(([, c]) => c), [{ user: "s" }]);
  // Every turn yielded at each step; each resume ran with its own turn's context.
  const order = seen.map(([input, context]) => `${input}:${JSON.stringify(context)}`);
  for (const [word, context] of [["upsilon", { user: "a" }], ["phi", null], ["chi", { user: "b" }]]) {
    const at = order.indexOf(`${word}:${JSON.stringify(context)}`);
    assert.deepEqual(order.slice(at + 1, at + 3), [`resume:${JSON.stringify(context)}`, `resume:${JSON.stringify(context)}`], `${word} resumed with its own context`);
  }
  await agent.close();
});

test("each prompt's turn runs with its session object's settings, resumed or not", async () => {
  const seen = [];
  const configurable = createDurableAgentFactory({
    harness: () => {
      const base = scriptedHarness()();
      return {
        settings: ({ model }) => (model === undefined ? undefined : { model }),
        open: async (options) => {
          const session = await base.open(options);
          const ran = options.settings ?? null;
          return { ...session, prompt: (input, opts) => { seen.push([input, ran]); return session.prompt(input, opts); }, resume: (opts) => { seen.push(["resume", ran]); return session.resume(opts); }, get openTurn() { return session.openTurn; } };
        },
      };
    },
    defaultDurability: async () => memory(),
  });
  const agent = configurable({ durability: await durabilityFor({ maxDurationMs: 1, reserveMs: 0 }) });
  const opened = agent.session(undefined, { model: "m1" });
  assert.equal((await opened.prompt("upsilon").result).stopReason, "end_turn");
  const id = opened.id;
  assert.equal((await agent.session(id).prompt("phi").result).stopReason, "end_turn");
  assert.equal((await agent.session(id, { model: "m2" }).prompt("chi").result).stopReason, "end_turn");
  assert.deepEqual(seen.filter(([input]) => input === "upsilon").map(([, s]) => s), [{ model: "m1" }]);
  assert.deepEqual(seen.filter(([input]) => input === "phi").map(([, s]) => s), [null], "a call without settings runs with the agent's");
  assert.deepEqual(seen.filter(([input]) => input === "chi").map(([, s]) => s), [{ model: "m2" }]);
  // Every turn yielded at each step; each resume ran with its own turn's settings.
  const order = seen.map(([input, settings]) => `${input}:${JSON.stringify(settings)}`);
  for (const [word, settings] of [["upsilon", { model: "m1" }], ["phi", null], ["chi", { model: "m2" }]]) {
    const at = order.indexOf(`${word}:${JSON.stringify(settings)}`);
    assert.deepEqual(order.slice(at + 1, at + 3), [`resume:${JSON.stringify(settings)}`, `resume:${JSON.stringify(settings)}`], `${word} resumed with its own settings`);
  }
  // A harness's refusal reaches the caller when the session object is made.
  const strict = createDurableAgentFactory({
    harness: () => ({ ...scriptedHarness()(), settings: () => { throw new TypeError("no such model"); } }),
    defaultDurability: async () => memory(),
  })({ durability: await durabilityFor() });
  assert.throws(() => strict.session(undefined, { model: "nope" }), /^TypeError: no such model$/);
  await strict.close();
  await agent.close();
});

// A real 1x1 PNG, as a caller would send it.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
const pngBytes = Uint8Array.from(atob(png), (char) => char.charCodeAt(0));
const image = { type: "image", data: png, mimeType: "image/png" };
// An image block of its own: the PNG with byte `n` after it, so its name is
// new and storing it writes it.
const imageOf = (n) => ({ type: "image", data: Buffer.from([...pngBytes, n]).toString("base64"), mimeType: "image/png" });
// An agent whose harness records each prompt input it is handed, and runs an
// image prompt as the word "image"; with `refuseFirst`, its first prompt
// throws, as a harness that cannot run a turn does.
function recordingAgent(durability, { refuseFirst = false } = {}) {
  const seen = [];
  let refusals = refuseFirst ? 1 : 0;
  const agent = createDurableAgentFactory({
    harness: () => {
      const base = scriptedHarness()();
      return {
        open: async (options) => {
          const session = await base.open(options);
          return {
            ...session,
            prompt: (input, opts) => {
              seen.push(input);
              if (refusals > 0) {
                refusals -= 1;
                throw new Error("the harness stopped");
              }
              return session.prompt(typeof input === "string" ? input : "image", opts);
            },
            get openTurn() { return session.openTurn; },
          };
        },
      };
    },
    defaultDurability: async () => memory(),
  })({ durability });
  return { agent, seen };
}
const kinds = (seen) => seen.map((input) => (typeof input === "string" ? input : "image"));

test("a durable prompt carries image data as base64: bytes and files throw from prompt(), and nothing is queued", async () => {
  const { agent, seen } = recordingAgent(await durabilityFor());
  const session = agent.session();
  const refused = [
    { type: "image", data: 42, mimeType: "image/png" },
    { type: "image", data: new Uint8Array(pngBytes), mimeType: "image/png" },
    { type: "image", data: new Uint8Array(pngBytes).buffer, mimeType: "image/png" },
    { type: "image", data: new Blob([pngBytes], { type: "image/png" }) },
    { type: "image", data: new File([pngBytes], "shot.png", { type: "image/png" }) },
  ];
  for (const block of refused) {
    assert.throws(
      () => session.prompt([{ type: "text", text: "look" }, block]),
      (error) => error instanceof TypeError && /^a durable prompt carries image data as a base64 string$/.test(error.message),
    );
  }
  const turn = session.prompt([{ type: "text", text: "look" }, image, { ...image, sourceRef: "uploads:shot" }]);
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.deepEqual(seen, [[{ type: "text", text: "look" }, image, { ...image, sourceRef: "uploads:shot" }]], "base64 passes as given");
  await agent.close();
});

test("a prompt storing its image is stored before the prompts made after it, and a failed image write stores nothing", async () => {
  const fault = { writeMs: 150 };
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), fault));
  const session = agent.session();
  const first = session.prompt([imageOf(1)]);
  const second = session.prompt("second");
  assert.deepEqual([(await first.result).stopReason, (await second.result).stopReason], ["end_turn", "end_turn"]);
  assert.deepEqual(kinds(seen), ["image", "second"]);
  fault.failWrites = 1;
  const failing = session.prompt([imageOf(2)]);
  const after = session.prompt("after");
  await assert.rejects(failing.accepted, /^Error: the store is full$/);
  await assert.rejects(failing.result, /^Error: the store is full$/);
  assert.equal((await after.result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["image", "second", "after"], "the failed write stored no turn, and the prompt behind it ran");
  await agent.close();
});

test("a prompt's signal or the agent closing while its image is stored keeps its turn from running", async () => {
  const fault = { writeMs: 400 };
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), fault));
  const session = agent.session();
  const controller = new AbortController();
  const cancelled = session.prompt([imageOf(3)], { messageId: "turn-store", signal: controller.signal });
  await sleep(20);
  const aborted = Date.now();
  controller.abort();
  await cancelled.accepted;
  assert.equal((await cancelled.result).stopReason, "cancelled");
  assert.ok(Date.now() - aborted < 300, "the prompt stopped waiting for its image write at once");
  // Neither the prompt nor a cancel naming it was stored: its id runs anew.
  assert.equal((await session.prompt("after", { messageId: "turn-store" }).result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["after"]);
  fault.writeMs = 150;
  const closing = session.prompt([imageOf(4)]);
  await agent.close();
  await assert.rejects(closing.accepted, /agent is closed/);
  await assert.rejects(closing.result, /agent is closed/);
  assert.deepEqual(kinds(seen), ["after"]);
});

test("a prompt withdrawn while it waits keeps the prompts behind it waiting for the ones before it", async () => {
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), { writeMs: 300 }));
  const session = agent.session();
  const first = session.prompt([imageOf(5)], { messageId: "turn-first" });
  const controller = new AbortController();
  const second = session.prompt([imageOf(6)], { messageId: "turn-second", signal: controller.signal });
  const third = session.prompt("third", { messageId: "turn-third" });
  await sleep(20);
  controller.abort();
  assert.equal((await second.result).stopReason, "cancelled");
  assert.equal((await first.result).stopReason, "end_turn");
  assert.equal((await third.result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["image", "third"], "the prompt behind the withdrawn one still came after the one before it");
  await agent.close();
});

test("an image prompt its first worker could not start runs from the log with the same base64, once", async () => {
  const { agent, seen } = recordingAgent(await durabilityFor(), { refuseFirst: true });
  const session = agent.session();
  const shot = { ...image, sourceRef: "uploads:shot" };
  assert.equal((await session.prompt([shot], { messageId: "turn-img" }).result).stopReason, "end_turn");
  assert.deepEqual(seen, [[shot], [shot]]);
  const again = await agent.session(session.id).prompt([shot], { messageId: "turn-img" }).result;
  assert.equal(again.repeated, true);
  assert.equal(seen.length, 2, "the retry ran nothing");
  await agent.close();
});

test("an image block is read once, so the log holds what was checked", async () => {
  const { agent, seen } = recordingAgent(await durabilityFor());
  const session = agent.session();
  // Accessors that answer one way when checked and another way after.
  let dataReads = 0;
  let mimeReads = 0;
  const shifting = {
    type: "image",
    get data() { dataReads += 1; return dataReads === 1 ? png : new Uint8Array([1, 2, 3]); },
    mimeType: "image/png",
    sourceRef: "uploads:shifting",
  };
  const relabelled = {
    type: "image",
    data: png,
    get mimeType() { mimeReads += 1; return mimeReads === 1 ? "image/png" : undefined; },
  };
  assert.equal((await session.prompt([{ type: "text", text: "look" }, shifting, relabelled]).result).stopReason, "end_turn");
  assert.deepEqual(seen.at(-1), [{ type: "text", text: "look" }, { ...image, sourceRef: "uploads:shifting" }, image]);
  assert.deepEqual([dataReads, mimeReads], [1, 1]);
  // An Array subclass whose map() returns something else still stores its blocks.
  class Remapped extends Array { map() { return "not the caller's blocks"; } }
  const blocks = Remapped.from([{ type: "text", text: "remapped" }, image]);
  assert.equal((await session.prompt(blocks).result).stopReason, "end_turn");
  assert.deepEqual(seen.at(-1), [{ type: "text", text: "remapped" }, image]);
  await agent.close();
});

const pngName = Buffer.from(await crypto.subtle.digest("SHA-256", pngBytes)).toString("hex");
// Every image stream's name holds this: "_user_", then the base64url of the
// namespace "libfx-image-".
const imageStreamTag = `_user_${Buffer.from("libfx-image-").toString("base64url")}`;

// The durability with a faulty image store: with `fault.lose`, every image
// reads back as missing; with `fault.corrupt`, every image reads back with
// its last byte changed; `fault.failWrites` fails that many image writes;
// `fault.writeMs` makes each image write wait that long first. The test may
// change `fault` as it goes. A World's faults are in its streams, under the
// code that names images.
function faultyImages(durability, fault = {}) {
  fault.failWrites ??= 0;
  const slowly = async () => { if (fault.writeMs) await sleep(fault.writeMs); };
  const refuse = () => {
    fault.failWrites -= 1;
    throw new Error("the store is full");
  };
  const flipped = (bytes) => {
    if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) return bytes;
    const copy = bytes.slice();
    copy[copy.length - 1] ^= 0xff;
    return copy;
  };
  if (typeof durability.create === "function") {
    return {
      ...durability,
      create() {
        const backend = durability.create();
        return {
          ...backend,
          async session(id) {
            const log = await backend.session(id);
            return {
              ...log,
              images: {
                put: async (name, bytes) => {
                  await slowly();
                  return fault.failWrites > 0 ? refuse() : log.images.put(name, bytes);
                },
                get: async (name) => {
                  if (fault.lose) return undefined;
                  const bytes = await log.images.get(name);
                  return fault.corrupt ? flipped(bytes) : bytes;
                },
              },
            };
          },
        };
      },
    };
  }
  const isImage = (name) => String(name).includes(imageStreamTag);
  const bound = (target, value) => (typeof value === "function" ? value.bind(target) : value);
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      const streams = new Proxy(world.streams, {
        get(target, prop) {
          const value = Reflect.get(target, prop);
          if (prop === "write") {
            return async (runId, name, chunk) => {
              if (!isImage(name)) return value.call(target, runId, name, chunk);
              await slowly();
              return fault.failWrites > 0 ? refuse() : value.call(target, runId, name, chunk);
            };
          }
          if (prop === "getChunks") {
            return async (runId, name, options) => {
              if (fault.lose && isImage(name)) return { data: [], cursor: null, hasMore: false, done: false };
              const result = await value.call(target, runId, name, options);
              if (!fault.corrupt || !isImage(name) || !Array.isArray(result?.data)) return result;
              return { ...result, data: result.data.map((chunk) => ({ ...chunk, data: flipped(chunk?.data) })) };
            };
          }
          return bound(target, value);
        },
      });
      return new Proxy(world, { get: (target, prop) => (prop === "streams" ? streams : bound(target, Reflect.get(target, prop))) });
    },
  };
}

// Every file under a World's folder, for checking what it stored. A lock or
// temporary file gone by the time it is read is skipped.
async function filesUnder(dir) {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile()) continue;
    try {
      files.push(await readFile(join(entry.parentPath ?? entry.path, entry.name)));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  return files;
}

test("a durable prompt stores each image once in the session's image store, and the log only names it", async () => {
  const durability = await durabilityFor();
  const { agent, seen } = recordingAgent(durability);
  const session = agent.session();
  const turn = session.prompt([
    { type: "text", text: "look" },
    image,
    { ...image, sourceRef: "uploads:shot" },
    image,
  ]);
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.deepEqual(seen, [[{ type: "text", text: "look" }, image, { ...image, sourceRef: "uploads:shot" }, image]]);
  if (typeof durability.create === "function") {
    const log = await durability.create().session(session.id);
    const entries = (await log.readSince("0")).map(({ entry }) => entry);
    assert.deepEqual(entries.find((entry) => entry.k === "input")?.input, [
      { type: "text", text: "look" },
      { type: "image", mimeType: "image/png", data: { sha256: pngName } },
      { type: "image", mimeType: "image/png", sourceRef: "uploads:shot", data: { sha256: pngName } },
      { type: "image", mimeType: "image/png", data: { sha256: pngName } },
    ]);
    assert.ok(!JSON.stringify(entries).includes(png), "no entry holds the image's base64");
    assert.deepEqual(await log.images.get(pngName), pngBytes);
  }
  await agent.close();
  if (typeof durability.create !== "function") {
    // On disk: the image's bytes once, in its stream, and its base64 nowhere.
    const files = await filesUnder(dirs.at(-1));
    assert.ok(!files.some((bytes) => bytes.includes(Buffer.from(png))), "no file holds the image's base64");
    assert.equal(files.filter((bytes) => bytes.includes(Buffer.from(pngBytes))).length, 1, "one file holds the image's bytes");
  }
});

test("an image the session's store no longer holds fails its turn, naming it", async () => {
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), { lose: true }));
  const session = agent.session();
  const result = await session.prompt([{ type: "text", text: "look" }, image]).result;
  assert.equal(result.stopReason, "error");
  assert.match(result.error.message, new RegExp(`does not hold image ${pngName}`));
  assert.deepEqual(seen, [], "the harness never ran it");
  assert.equal((await session.prompt("after").result).stopReason, "end_turn");
  await agent.close();
});

test("an image whose stored bytes changed fails its turn, naming it", async () => {
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), { corrupt: true }));
  const session = agent.session();
  const result = await session.prompt([{ type: "text", text: "look" }, image]).result;
  assert.equal(result.stopReason, "error");
  // A World's read skips bytes that don't match the name, so to it the image
  // is missing; a store that returns them fails the check after the read.
  assert.match(result.error.message, new RegExp(`(holds other bytes under|does not hold) image ${pngName}`));
  assert.deepEqual(seen, [], "the harness never ran it");
  assert.equal((await session.prompt("after").result).stopReason, "end_turn");
  await agent.close();
});

test("a World whose streams lack getChunks refuses an image prompt before storing it, and text still runs", async () => {
  const durability = await durabilityFor();
  // memory() keeps images itself; the others keep them in World streams.
  if (typeof durability.world !== "function") return;
  const bound = (target, value) => (typeof value === "function" ? value.bind(target) : value);
  const withoutGetChunks = {
    ...durability,
    async world() {
      const world = await durability.world();
      const streams = new Proxy(world.streams, { get: (target, prop) => (prop === "getChunks" ? undefined : bound(target, Reflect.get(target, prop))) });
      return new Proxy(world, { get: (target, prop) => (prop === "streams" ? streams : bound(target, Reflect.get(target, prop))) });
    },
  };
  const { agent, seen } = recordingAgent(withoutGetChunks);
  const session = agent.session();
  const refused = session.prompt([{ type: "text", text: "look" }, image]);
  await assert.rejects(refused.accepted, (error) => error instanceof TypeError && /getChunks/.test(error.message));
  await assert.rejects(refused.result);
  assert.equal((await session.prompt("text only").result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["text only"]);
  await agent.close();
});

test("a failed image write rejects the prompt before anything is stored", async () => {
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), { failWrites: 1 }));
  const session = agent.session();
  const refused = session.prompt([{ type: "text", text: "look" }, image], { messageId: "refused-img" });
  // The store's own error.
  const storeFailed = (error) => error.message === "the store is full";
  await assert.rejects(refused.accepted, storeFailed);
  await assert.rejects(refused.result, storeFailed);
  assert.equal((await session.prompt([{ type: "text", text: "again" }, image]).result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["image"], "only the second prompt was stored and ran");
  // The refused prompt was never stored, so its retry is a new turn.
  const retried = await session.prompt([{ type: "text", text: "look" }, image], { messageId: "refused-img" }).result;
  assert.equal(retried.stopReason, "end_turn");
  assert.notEqual(retried.repeated, true);
  assert.deepEqual(kinds(seen), ["image", "image"]);
  await agent.close();
});

test("a failed image write rejects a steer before it is sent", async () => {
  const fault = {};
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), fault));
  const session = agent.session();
  assert.equal((await session.prompt("first").result).stopReason, "end_turn");
  fault.failWrites = 1;
  // The store's own error.
  await assert.rejects(session.steer([{ type: "text", text: "look" }, image]), (error) => error.message === "the store is full");
  // The steer was never sent, so no turn ran for it before the next prompt.
  assert.equal((await session.prompt("after").result).stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["first", "after"]);
  await agent.close();
});

test("a retried image prompt the log already holds is answered without writing its images again", async () => {
  const fault = {};
  const { agent, seen } = recordingAgent(faultyImages(await durabilityFor(), fault));
  const session = agent.session();
  assert.equal((await session.prompt([{ type: "text", text: "look" }, image], { messageId: "img-once" }).result).stopReason, "end_turn");
  // From now on every image write fails, so a retry that wrote again would fail.
  fault.failWrites = Infinity;
  const again = await agent.session(session.id).prompt([{ type: "text", text: "look" }, image], { messageId: "img-once" }).result;
  assert.equal(again.repeated, true);
  assert.equal(again.stopReason, "end_turn");
  assert.deepEqual(kinds(seen), ["image"], "the retry ran nothing");
  await agent.close();
});

test("base64 is the same with and without the runtime's own encoder and decoder", async () => {
  const reference = (bytes) => btoa(String.fromCharCode(...bytes));
  const inputs = [...Array.from({ length: 9 }, (_, n) => pngBytes.subarray(0, n + 1)), Uint8Array.from({ length: 3000 }, (_, i) => (i * 131) & 255)];
  const run = async () => {
    const { agent, seen } = recordingAgent(await durabilityFor());
    const session = agent.session();
    // Each image is decoded to be stored, and encoded again for the harness.
    for (const bytes of inputs) assert.equal((await session.prompt([{ type: "image", data: reference(bytes), mimeType: "image/png" }]).result).stopReason, "end_turn");
    // Each turn's records went through the log as base64 and back.
    const words = JSON.parse(decoder.decode(await session.checkpoint()));
    await agent.close();
    return { seen, words };
  };
  const native = await run();
  const encode = Uint8Array.prototype.toBase64;
  const decode = Uint8Array.fromBase64;
  delete Uint8Array.prototype.toBase64;
  delete Uint8Array.fromBase64;
  let fallback;
  try {
    fallback = await run();
  } finally {
    if (encode) Uint8Array.prototype.toBase64 = encode;
    if (decode) Uint8Array.fromBase64 = decode;
  }
  for (const result of [native, fallback]) {
    assert.deepEqual(result.seen.map((input) => input[0].data), inputs.map(reference));
    assert.equal(result.words.length, inputs.length * 3);
  }
});

test("a worker lives only while a delivery runs it", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const internals = agent[Symbol.for("libfx.durableInternals")];
  for (const name of ["pi", "rho", "sigma"]) await agent.session().prompt(name).result;
  for (let waited = 0; internals.liveWorkers() > 0 && waited < 2000; waited += 20) await sleep(20);
  assert.equal(internals.liveWorkers(), 0);
  await agent.close();
});

test("a new session's id can come before its first prompt, and null is no id", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  assert.throws(() => agent.session(null), /session id must be/);
  const id = await agent.newSessionId();
  const first = agent.session(id).prompt("alpha", { messageId: "turn-a" });
  assert.equal((await first.accepted).sessionId, id);
  assert.equal((await first.result).stopReason, "end_turn");
  // The same first request sent again reaches the same session and runs once.
  const again = await agent.session(id).prompt("alpha", { messageId: "turn-a" }).result;
  assert.equal(again.repeated, true);
  assert.deepEqual(JSON.parse(decoder.decode(await agent.session(id).checkpoint())), ["alpha-0", "alpha-1", "alpha-2"]);
  await agent.close();
});

// A memory durability whose stream loses each failed turn's end, as when
// that write fails after the log recorded the failure.
function losingFailedEnds(base) {
  let wrapped = null;
  const dropped = (line) => {
    try {
      const event = JSON.parse(line);
      return event.type === "turn_end" && event.stopReason === "error";
    } catch { return false; }
  };
  return {
    ...base,
    create() {
      const backend = base.create();
      wrapped ??= Object.assign(Object.create(backend), {
        async session(id) {
          const log = await backend.session(id);
          const ui = Object.assign(Object.create(log.ui), { write: (lines) => log.ui.write(lines.filter((line) => !dropped(line))) });
          return Object.assign(Object.create(log), { ui });
        },
      });
      return wrapped;
    },
  };
}

if (durabilityKind === "memory") {
  test("a retried prompt whose failed turn left no end on the stream answers with its error at once", async () => {
    const { agent, counts } = agentWhoseEnginesFailAfter(0, losingFailedEnds(memory()));
    const session = agent.session();
    // Its view never hears the end it lost; the log still has the failure.
    await session.prompt("alpha", { messageId: "turn-a" }).accepted;
    while (counts.opens === 0) await new Promise((wait) => setTimeout(wait, 10));
    await new Promise((wait) => setTimeout(wait, landMs));
    let timer;
    const result = await Promise.race([
      session.prompt("alpha", { messageId: "turn-a" }).result,
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("the retry waited for an end that never comes")), 5000); }),
    ]).finally(() => clearTimeout(timer));
    assert.equal(result.stopReason, "error");
    assert.equal(result.error.message, "no engine");
    await agent.close();
  });
}

test("world() checks its options, and an agent names it among the durabilities", async () => {
  assert.throws(() => world(), /world\(\) takes a World or a function that creates one/);
  assert.throws(() => world({}, { pollMs: 0 }), /world\(\) pollMs must be a positive integer/);
  assert.throws(() => world({}, { leaseMs: 999 }), /world\(\) leaseMs must be an integer of at least 1000/);
  assert.throws(() => world({}, { leaseMs: 1500.5 }), /world\(\) leaseMs must be an integer of at least 1000/);
  assert.throws(() => world({}, { name: "pg", queueDurable: "yes" }), /pg\(\) queueDurable must be a boolean/);
  assert.throws(() => world({}, { name: "pg", queueLeases: 1 }), /pg\(\) queueLeases must be a boolean/);
  assert.throws(() => world({}, { name: "pg", livenessKnown: true }), /pg\(\) livenessKnown needs alive\(\)/);
  assert.throws(() => world({}, { alive: true }), /world\(\) alive must be a function/);
  assert.throws(() => world({}, { name: "pg", runInRequest: true }), /pg\(\) runInRequest needs queueLeases/);
  assert.throws(() => world({}, { waitUntil: true }), /world\(\) waitUntil must be a function/);
  assert.deepEqual([world({}).runInRequest, world({}, { queueLeases: true }).runInRequest, world({}, { queueLeases: true, runInRequest: false }).runInRequest], [false, true, false]);
  // vercel() runs prompts in the request unless its leases are renewed.
  const { vercel } = await import("../durable/vercel.mjs");
  assert.deepEqual([vercel().runInRequest, vercel({ leaseMs: 15_000 }).runInRequest], [true, false]);
  assert.equal(typeof vercel().waitUntil, "function");
  assert.throws(() => createAgent({ durability: {} }), /durability must come from memory\(\), local\(\), vercel\(\) or world\(\)/);
});

if (durabilityKind === "world") {
  test("an app's World stays the app's: libfx neither starts nor closes it", async () => {
    const durability = await durabilityFor();
    const instance = await durability.world();
    const calls = [];
    for (const key of ["start", "close"]) {
      const original = instance[key];
      instance[key] = async (...args) => { calls.push(key); return original.apply(instance, args); };
    }
    const agent = createAgent({ durability });
    assert.equal((await agent.session().prompt("alpha", { messageId: "turn-a" }).result).stopReason, "end_turn");
    await agent.close();
    assert.deepEqual(calls, []);
    const next = createAgent({ durability });
    assert.equal((await next.session().prompt("beta", { messageId: "turn-b" }).result).stopReason, "end_turn", "the World still serves the next agent");
    await next.close();
  });

  test("agents given one World take its deliveries in turn, and one closing leaves the others theirs", async () => {
    const durability = await durabilityFor();
    const first = createAgent({ durability });
    const second = createAgent({ durability });
    assert.equal((await first.session().prompt("one", { messageId: "turn-1" }).result).stopReason, "end_turn");
    assert.equal((await second.session().prompt("two", { messageId: "turn-2" }).result).stopReason, "end_turn");
    // The World's one handler for libfx's queue came last from the second.
    await second.close();
    assert.equal((await first.session().prompt("three", { messageId: "turn-3" }).result).stopReason, "end_turn");
    await first.close();
  });
}

// A World durability whose session stream reads are counted.
function countingStreamReads(durability) {
  const counts = { reads: 0 };
  const worldOf = durability.world;
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await worldOf();
      const streams = new Proxy(world.streams, {
        get(target, key) {
          if (key !== "get") return bound(target, key);
          return (...args) => {
            counts.reads += 1;
            return target.get(...args);
          };
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "streams" ? streams : bound(target, key)) });
    },
  }, counts];
}

if (durabilityKind !== "memory") {
  test("a prompt nobody reads holds no read of the session stream, and a later reader still sees its turn", async () => {
    const [durability, counts] = countingStreamReads(await durabilityFor());
    const agent = createAgent({ durability });
    const turn = agent.session().prompt("alpha", { messageId: "turn-a" });
    const { sessionId } = await turn.accepted;
    // The turn runs to its end with nobody reading it.
    let words = [];
    for (let waited = 0; words.length < 3 && waited < 5000; waited += 20) {
      await sleep(20);
      words = JSON.parse(decoder.decode(await agent.session(sessionId).checkpoint()));
    }
    assert.deepEqual(words, ["alpha-0", "alpha-1", "alpha-2"]);
    assert.equal(counts.reads, 0, "nothing read the session stream");
    const { text, result } = await textOf(turn);
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "alpha-0 alpha-1 alpha-2", "a reader that comes later sees the whole turn");
    assert.ok(counts.reads > 0, "reading the view read the stream");
    await agent.close();
  });
}

// The fx.log entries a session's log holds, oldest first.
async function logEntries(durability, sessionId) {
  const instance = await durability.world();
  const page = await instance.events.list({ runId: sessionId, pagination: { sortOrder: "asc", limit: 1000 }, resolveData: "all" });
  return page.data
    .filter((event) => event.eventType === "step_created" && event.eventData?.stepName === "fx.log")
    .map((event) => JSON.parse(decoder.decode(event.eventData.input)));
}

if (durabilityKind === "world" || durabilityKind === "queue") {
  for (const [how, name] of [
    ["lapse", "a later delivery of the message whose delivery holds a session takes the session over at once"],
    // Vercel runs a delivery whose function's process exited again, attempt and all.
    ["rerun", "a delivery run again after its process died takes its session over at once"],
  ]) test(name, async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-redelivered-"));
    dirs.push(dir);
    // A lease that outlasts the test, renewed or held to a deadline ten
    // minutes away: only the redelivery can free the session.
    const { durability, broker } = await queueWorldAt(dir, durabilityKind === "queue" ? { queueLeases: true, maxDurationMs: 600_000 } : { leaseMs: 60_000, maxDurationMs: 600_000 });
    const fenced = [];
    const first = createAgent({ durability, onEvent: (event) => { if (event.type === "session.fenced") fenced.push(event); } });
    const second = createAgent({ durability });
    // Both take deliveries from the World, the first one first.
    await first.newSessionId();
    await second.newSessionId();
    const held = holdStep("zeta-1");
    const before = ran.length;
    const session = first.session();
    const turn = session.prompt("zeta", { messageId: "turn-z" });
    await held.holding;
    // The queue gives up on the first worker's process, which this one no
    // longer runs as, and delivers the prompt's message again.
    const holders = globalThis[Symbol.for("libfx.liveHolders")];
    for (const holder of [...holders]) holders.delete(holder);
    holds.delete("zeta-1");
    const [message] = broker.held((input) => input.messageId === "turn-z");
    assert.ok(message, "the prompt's message is still held");
    const lapsed = Date.now();
    broker[how](message);
    const { text, result } = await textOf(turn);
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "zeta-0 zeta-1 zeta-2");
    assert.ok(Date.now() - lapsed < 5000, `the session was taken over ${Date.now() - lapsed} ms after its message came back, not when its lease ran out`);
    assert.deepEqual(ran.slice(before), ["turn-z:0", "turn-z:1", "turn-z:2"], "the second worker continued the turn from its held step");
    // The first worker's held step goes on, and its next write is refused.
    held.release();
    for (let waited = 0; fenced.length === 0 && waited < 5000; waited += 20) await sleep(20);
    assert.equal(fenced.length, 1, "the replaced worker stopped at its next write");
    const lines = await readLines(session.stream(0), 32);
    assert.equal(lines.filter((line) => line.type === "turn_end").length, 1, "the turn ended once");
    await first.close();
    await second.close();
  });
}

if (durabilityKind === "queue") {
  test("a worker holds a session the queue shows it holds without renewing its lease", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-held-"));
    dirs.push(dir);
    // The same turn on two Worlds that cannot tell whether a worker lives:
    // one whose queue shows it, and one where each worker renews a 1 s lease.
    const leases = {};
    for (const [kind, options] of [["held", { queueLeases: true, maxDurationMs: 600_000 }], ["renewed", { leaseMs: 1000, maxDurationMs: 600_000 }]]) {
      const { durability } = await queueWorldAt(join(dir, kind), options);
      const agent = createAgent({ durability });
      const held = holdStep(`hold-${kind}-1`);
      const session = agent.session();
      const turn = session.prompt(`hold-${kind}`, { messageId: `turn-${kind}` });
      await held.holding;
      await sleep(2500);
      held.release();
      assert.equal((await turn.result).stopReason, "end_turn");
      // The worker lets the session go after its viewers hear the turn ended.
      let entries = await logEntries(durability, session.id);
      for (let waited = 0; !entries.some((entry) => entry.k === "release") && waited < 2000; waited += 20) {
        await sleep(20);
        entries = await logEntries(durability, session.id);
      }
      leases[kind] = entries.filter((entry) => entry.k === "lease").length;
      assert.equal(entries.filter((entry) => entry.k === "release").length, 1, `${kind}: the worker let the session go once`);
      if (kind === "held") {
        const [lease] = entries.filter((entry) => entry.k === "lease");
        assert.equal(lease.expiresAt - Date.now() > 590_000 - 3000, true, "the lease runs to the deadline");
        assert.equal(typeof lease.delivery?.messageId, "string", "the lease names the delivery holding it");
      }
      await agent.close();
    }
    assert.equal(leases.held, 1, "one claim and no renewals");
    assert.ok(leases.renewed >= 6, `the renewed lease was written ${leases.renewed} times in 2.5 s`);
  });

  test("a worker whose release failed has its own message delivered again, which lets the session go", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-unreleased-"));
    dirs.push(dir);
    const { durability } = await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000 });
    // The World refuses the first release written, as an outage would.
    const instance = await durability.world();
    const events = instance.events;
    let refused = 0;
    instance.events = {
      ...events,
      list: events.list.bind(events),
      async create(runId, event, params) {
        const entry = event?.eventData?.stepName === "fx.log" ? JSON.parse(decoder.decode(event.eventData.input)) : null;
        if (entry?.k === "release" && refused === 0) {
          refused += 1;
          throw new Error("the World is briefly unavailable");
        }
        return events.create(runId, event, params);
      },
    };
    const agent = createAgent({ durability });
    const session = agent.session();
    assert.equal((await session.prompt("kappa", { messageId: "turn-k" }).result).stopReason, "end_turn");
    // The next prompt is another message. Had the first one gone on as a new
    // message, the lease it could not release would stand until its deadline.
    const started = Date.now();
    assert.equal((await session.prompt("lambda", { messageId: "turn-l" }).result).stopReason, "end_turn");
    assert.equal(refused, 1);
    assert.ok(Date.now() - started < 10_000, `the next prompt ran ${Date.now() - started} ms after it was sent`);
    await agent.close();
  });
}

if (durabilityKind === "memory") {
  test("a session belongs to the agent its first input or its checkpoint names, and one from before names to default", () => {
    const input = (messageId, agent) => ({ k: "input", key: `${messageId}:prompt`, type: "prompt", messageId, ...(agent ? { agent } : {}) });
    const ownerOf = (...entries) => foldSessionLog(entries.map((entry, index) => ({ cursor: String(index + 1), entry }))).agent;
    assert.equal(ownerOf(), null);
    assert.equal(ownerOf(input("m1", "support"), input("m2", "coding")), "support");
    assert.equal(ownerOf(input("m1"), input("m2", "coding")), "default");
    assert.equal(ownerOf({ k: "checkpoint", through: null, data: "seed", agent: "coding" }, input("m1", "support")), "coding");
    assert.equal(ownerOf({ k: "checkpoint", through: null, data: "seed" }, input("m1", "support")), "support");
    assert.equal(ownerOf({ k: "checkpoint", through: "7", data: "saved" }), "default");
    assert.equal(ownerOf({ k: "checkpoint", through: "7", data: "saved", agent: "support" }, input("m9", "coding")), "support");
  });
}

if (durabilityKind === "queue") {
  test("one route serves every agent in the process, each delivery to the agent its message names", async () => {
    const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-"));
    dirs.push(dir);
    const stored = createWorld({ dataDir: dir, recoverActiveRuns: false });
    await stored.start();
    // A World that delivers only over HTTP, to the route the test posts to.
    const sent = [];
    const instance = {
      ...stored,
      registerHandler: undefined,
      queue: async (queueName, payload) => { sent.push({ queueName, payload }); return { messageId: `msg_${sent.length}` }; },
      createQueueHandler: (_prefix, handler) => async (request) => {
        const { payload, meta } = await request.json();
        try {
          await handler(payload, meta);
          return new Response("ok");
        } catch (error) {
          return Response.json({ code: error?.code, agent: error?.agent }, { status: 500 });
        }
      },
    };
    const durability = world(instance, { name: "route", queueDurable: true });
    const support = createTaggedAgent({ durability, name: "support", tag: "support" });
    const coding = createTaggedAgent({ durability, name: "coding", tag: "coding" });
    // An agent on another durability of the same kind, as an app that gives
    // one agent vercel() and another vercel({ leaseMs }) has.
    const ops = createTaggedAgent({ durability: world(instance, { name: "route", queueDurable: true }), name: "ops", tag: "ops" });
    let attempt = 0;
    const post = (route, { queueName, payload }) => {
      attempt += 1;
      const meta = { queueName, messageId: `msg_post_${attempt}`, attempt: 1 };
      return route(new Request("https://app.example/wake", { method: "POST", body: JSON.stringify({ payload, meta }) }));
    };
    const ours = support.session();
    const theirs = coding.session();
    const opsSession = ops.session();
    const first = ours.prompt("alpha");
    const second = theirs.prompt("beta");
    const fourth = opsSession.prompt("delta");
    await Promise.all([first.accepted, second.accepted, fourth.accepted]);
    const shared = wakeHandler();
    // Every message reaches the one route, whichever agent sent it.
    for (const message of sent.splice(0)) assert.equal((await post(shared, message)).status, 200);
    assert.equal((await textOf(first)).text, "alpha-0 alpha-1 alpha-2");
    assert.equal((await textOf(second)).text, "beta-0 beta-1 beta-2");
    assert.equal((await textOf(fourth)).text, "delta-0 delta-1 delta-2");
    assert.deepEqual(openersOf(opsSession.id), ["ops"]);
    // An agent's own route delivers to the agent a message names, too.
    const third = ours.prompt("gamma");
    await third.accepted;
    const [message] = sent.splice(0);
    assert.equal((await post(coding.wakeHandler(), message)).status, 200);
    assert.equal((await textOf(third)).text, "gamma-0 gamma-1 gamma-2");
    assert.deepEqual(openersOf(ours.id), ["support"]);
    assert.deepEqual(openersOf(theirs.id), ["coding"]);
    // A name no agent here has is refused for the queue to deliver again.
    const ghost = { ...message, payload: { ...message.payload, input: { ...message.payload.input, agent: "ghost", messageId: "ghost-1" } } };
    const refused = await post(shared, ghost);
    assert.equal(refused.status, 500);
    assert.deepEqual(await refused.json(), { code: "FX_NO_AGENT", agent: "ghost" });
    await support.close();
    await coding.close();
    await ops.close();
    assert.equal((await post(shared, message)).status, 503, "with no agent left, the route says so");
    await stored.close();
  });
}

if (durabilityKind === "memory") {
  test("one name on one store is one agent: another configuration under it is refused", async () => {
    const durability = memory();
    const support = createTaggedAgent({ durability, name: "support", tag: "acme" });
    assert.throws(() => createTaggedAgent({ durability, name: "support", tag: "evil" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE" && error.agent === "support");
    // A copy with the same configuration is the same agent, as one on each
    // server is, and only watching it differently does not change it.
    const copy = createTaggedAgent({ durability, name: "support", tag: "acme", onEvent: () => {} });
    // Another store, or another name, holds other sessions.
    const elsewhere = createTaggedAgent({ durability: memory(), name: "support", tag: "evil" });
    const named = createTaggedAgent({ durability, name: "billing", tag: "evil" });
    await copy.close();
    await support.close();
    // Once the first configuration is gone, the name is free again.
    const later = createTaggedAgent({ durability, name: "support", tag: "evil" });
    for (const agent of [elsewhere, named, later]) await agent.close();
  });

  test("agents created without a name or a durability are one agent only when configured alike", async () => {
    // Node keeps one default durability per environment, so every agent
    // created without one shares its store.
    const shared = memory();
    const tagged = createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => shared, defaultShared: true, name: "createDefaultAgent" });
    const first = tagged({ tag: "key-a" });
    assert.throws(() => tagged({ tag: "key-b" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE" && error.agent === "default");
    const same = tagged({ tag: "key-a" });
    await same.close();
    await first.close();
  });

  test("agents created without a durability each get their own store where the default is not shared, so any options are allowed", async () => {
    // The browser gives every such agent a memory() of its own.
    const tagged = createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => memory(), name: "createBrowserAgent" });
    const first = tagged({ tag: "key-a" });
    const other = tagged({ tag: "key-b" });
    await first.newSessionId();
    const opened = tagged({ tag: "key-c" });
    await opened.newSessionId();
    await other.newSessionId();
    for (const agent of [first, other, opened]) await agent.close();
  });

  test("an agent created without a durability is refused at once after another of its name opened the shared default", async () => {
    const shared = memory();
    const tagged = createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => shared, defaultShared: true, name: "createDefaultAgent" });
    const first = tagged({ tag: "key-a" });
    await first.newSessionId();
    assert.throws(() => tagged({ tag: "key-b" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE" && error.agent === "default");
    const same = tagged({ tag: "key-a" });
    await same.newSessionId();
    await same.close();
    await first.close();
  });

  test("an input over the size limit is refused before anything is stored", async () => {
    const agent = createAgent({ durability: memory() });
    const session = agent.session(undefined, { context: { user: "a" } });
    assert.equal((await session.prompt("first").result).stopReason, "end_turn");
    const inputs = async () => (await (await agent[Symbol.for("libfx.durableInternals")].openLog(session.id)).read()).filter(({ entry }) => entry.k === "input").length;
    const before = await inputs();
    const big = "x".repeat(8 * 1024 * 1024);
    assert.throws(() => session.prompt(big), (error) => error?.code === "FX_INPUT_TOO_LARGE" && error.limit === 8 * 1024 * 1024);
    await assert.rejects(session.steer(big), (error) => error?.code === "FX_INPUT_TOO_LARGE");
    assert.equal(await inputs(), before, "no input was stored");
    await agent.close();
  });

  test("a session stores its context as it was when the session opened", async () => {
    const agent = createAgent({ durability: memory() });
    const context = { user: "a" };
    const session = agent.session(undefined, { context });
    try {
      await session.prompt("first").result;
      const log = await agent[Symbol.for("libfx.durableInternals")].openLog(session.id);
      const inputs = async () => (await log.read()).filter(({ entry }) => entry.k === "input").map(({ entry }) => entry);
      // A change the caller makes later reaches neither the size check nor
      // the log, so the 8 MiB limit holds for what is stored.
      context.user = "x".repeat(8 * 1024 * 1024);
      await session.steer("next", { messageId: "steer-after-change" });
      const stored = (await inputs()).find((entry) => entry.messageId === "steer-after-change");
      assert.deepEqual(stored.context, { user: "a" });
      assert.ok(JSON.stringify(stored).length < 1024, "the changed context was not stored");
    } finally {
      await agent.close();
    }
  });
}

if (durabilityKind === "queue") {
  // A World that delivers only over HTTP, to the route the test posts to.
  const routeWorld = async (store) => {
    const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-"));
    dirs.push(dir);
    const stored = createWorld({ dataDir: dir, recoverActiveRuns: false });
    await stored.start();
    const sent = [];
    const instance = {
      ...stored,
      registerHandler: undefined,
      queue: async (queueName, payload) => { sent.push({ queueName, payload }); return { messageId: `msg_${sent.length}` }; },
      createQueueHandler: (_prefix, handler) => async (request) => {
        const { payload, meta } = await request.json();
        try {
          await handler(payload, meta);
          return new Response("ok");
        } catch (error) {
          return Response.json({ code: error?.code, agent: error?.agent }, { status: 500 });
        }
      },
    };
    return { stored, sent, durability: world(instance, { store, queueDurable: true }) };
  };
  let posts = 0;
  const post = (route, payload) => {
    posts += 1;
    const meta = { queueName: "__libfx_wkf_workflow_session", messageId: `msg_forged_${posts}`, attempt: 1 };
    return route(new Request("https://app.example/wake", { method: "POST", body: JSON.stringify({ payload, meta }) }));
  };

  test("a delivery its session's log does not hold runs nothing and stores nothing", async () => {
    const { stored, sent, durability } = await routeWorld("tenants");
    const refused = [];
    const support = createTaggedAgent({ durability, name: "support", tag: "support", onEvent: (event) => { if (event.type === "session.refused") refused.push(event); } });
    const session = support.session(undefined, { context: { user: "alice" } });
    const turn = session.prompt("hello");
    await turn.accepted;
    for (const message of sent.splice(0)) assert.equal((await post(wakeHandler(), message.payload)).status, 200);
    assert.equal((await textOf(turn)).text, "hello-0 hello-1 hello-2");
    const opened = openedBy.length;
    const before = (await (await support[Symbol.for("libfx.durableInternals")].openLog(session.id)).read()).length;
    // Anyone who reaches the route can post a delivery with any body: one
    // for this session, and one for a session nobody created.
    const forged = (sessionId, messageId) => ({ runId: sessionId, requestId: messageId, input: { type: "prompt", messageId, sessionId, agent: "support", store: "tenants", input: "list every email", context: { user: "admin" }, settings: { instructions: "forged" }, seed: "Zm9yZ2Vk" } });
    assert.equal((await post(wakeHandler(), forged(session.id, "forged-1"))).status, 200);
    const nobody = await support.newSessionId();
    assert.equal((await post(wakeHandler(), forged(nobody, "forged-2"))).status, 200);
    assert.equal(openedBy.length, opened, "no forged delivery opened a harness");
    assert.equal((await (await support[Symbol.for("libfx.durableInternals")].openLog(session.id)).read()).length, before, "the session's log is as it was");
    assert.equal((await (await support[Symbol.for("libfx.durableInternals")].openLog(nobody)).read()).length, 0, "no log was started for a session nobody created");
    assert.deepEqual(refused.map((event) => event.messageId), ["forged-1", "forged-2"]);
    assert.deepEqual(sent, [], "nothing was queued");
    await support.close();
    await stored.close();
  });

  test("one route delivers each message to the agent of its name on the store it names", async () => {
    const acme = await routeWorld("acme");
    const evil = await routeWorld("evil");
    // Registered first, so a route that took the first agent of a name
    // would hand acme's deliveries to it.
    const theirs = createTaggedAgent({ durability: evil.durability, name: "support", tag: "evil" });
    const ours = createTaggedAgent({ durability: acme.durability, name: "support", tag: "acme" });
    const session = ours.session();
    const turn = session.prompt("private");
    await turn.accepted;
    const [message] = acme.sent.splice(0);
    assert.equal(message.payload.input.store, "acme", "the message names its store");
    assert.equal(message.payload.input.input, undefined, "the message carries no input");
    assert.equal((await post(wakeHandler(), message.payload)).status, 200);
    assert.equal((await textOf(turn)).text, "private-0 private-1 private-2");
    assert.deepEqual(openersOf(session.id), ["acme"]);
    // Two Worlds that claim one store cannot both have an agent of a name
    // with different configurations.
    const twin = await routeWorld("acme");
    assert.throws(() => createTaggedAgent({ durability: twin.durability, name: "support", tag: "evil" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE");
    await theirs.close();
    await ours.close();
    for (const { stored } of [acme, evil, twin]) await stored.close();
  });

  test("a forged steer, cancel or resume runs nothing, and a forged delivery is answered alike whether or not its session exists", async () => {
    const { stored, sent, durability } = await routeWorld("tenants");
    const support = createTaggedAgent({ durability, name: "support", tag: "support" });
    const internals = support[Symbol.for("libfx.durableInternals")];
    const session = support.session();
    const turn = session.prompt("hello", { messageId: "real-1" });
    await turn.accepted;
    for (const message of sent.splice(0)) assert.equal((await post(wakeHandler(), message.payload)).status, 200);
    assert.equal((await textOf(turn)).text, "hello-0 hello-1 hello-2");
    const nobody = await support.newSessionId();
    const opened = openedBy.length;
    const logOf = async (id) => (await (await internals.openLog(id)).read()).length;
    const uiOf = async (id) => (await internals.openLog(id)).ui.length();
    const before = { log: await logOf(session.id), ui: await uiOf(session.id) };
    const forge = (sessionId, type, messageId, extra = {}) => ({ runId: sessionId, requestId: messageId, input: { type, messageId, sessionId, agent: "support", store: "tenants", input: "forged", context: { user: "admin" }, ...extra } });
    const answers = { real: [], nobody: [] };
    for (const [key, sessionId] of [["real", session.id], ["nobody", nobody]]) {
      for (const [type, messageId, extra] of [["steer", "forged-steer", {}], ["cancel", "forged-cancel", { target: "real-1" }], ["resume", "forged-resume", {}], ["prompt", "real-1", {}]]) {
        const response = await post(wakeHandler(), forge(sessionId, type, messageId, extra));
        answers[key].push(`${response.status} ${await response.text()}`);
      }
    }
    assert.deepEqual(answers.real, answers.nobody, "the route answers a forgery the same whether or not its session exists");
    assert.ok(answers.real.every((answer) => answer.startsWith("200 ")), `every forgery is acknowledged and dropped: ${answers.real.join(", ")}`);
    assert.equal(openedBy.length, opened, "no forged delivery opened a harness");
    assert.deepEqual({ log: await logOf(session.id), ui: await uiOf(session.id) }, before, "the real session's log and stream are as they were");
    assert.deepEqual({ log: await logOf(nobody), ui: await uiOf(nobody) }, { log: 0, ui: 0 }, "nothing was written for a session nobody created");
    assert.deepEqual(sent, [], "nothing was queued");
    await support.close();
    await stored.close();
  });

  test("a second copy of libfx in the process keeps one agent per name on a store, and its route reaches the first copy's agents", async () => {
    const copy = await import(new URL("../durable.js?second-copy", import.meta.url).href);
    assert.notEqual(copy.wakeHandler, wakeHandler, "a separate module instance");
    const createCopyAgent = copy.createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => memory(), name: "createCopyAgent" });
    const { stored, sent, durability } = await routeWorld("tenants");
    const support = createTaggedAgent({ durability, name: "support", tag: "acme" });
    assert.throws(() => createCopyAgent({ durability, name: "support", tag: "evil" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE");
    const session = support.session();
    const turn = session.prompt("across copies");
    await turn.accepted;
    for (const message of sent.splice(0)) assert.equal((await post(copy.wakeHandler(), message.payload)).status, 200);
    assert.equal((await textOf(turn)).text, "across copies-0 across copies-1 across copies-2");
    assert.deepEqual(openersOf(session.id), ["acme"]);
    await support.close();
    await stored.close();
  });

  test("a delivery for an agent that has closed fails, and no agent of its name on another store takes it", async () => {
    const acme = await routeWorld("acme");
    const carl = await routeWorld("carl");
    const theirs = createTaggedAgent({ durability: carl.durability, name: "support", tag: "carl" });
    const ours = createTaggedAgent({ durability: acme.durability, name: "support", tag: "acme" });
    const session = ours.session();
    await session.prompt("after close").accepted;
    const [message] = acme.sent.splice(0);
    await ours.close();
    const response = await post(wakeHandler(), message.payload);
    assert.equal(response.status, 500, "the queue keeps the message to deliver again");
    assert.deepEqual(await response.json(), { code: "FX_NO_AGENT", agent: "support" });
    assert.deepEqual(openersOf(session.id), [], "no agent ran the closed agent's session");
    await theirs.close();
    for (const { stored } of [acme, carl]) await stored.close();
  });
}

// A log of `count` slots as a World holds one: inputs, a chain of leases,
// records and releases, and checkpoints whose `through` only moves forward.
function randomLog(seed, count) {
  let state = seed;
  const next = () => (state = (state * 1103515245 + 12345) % 2147483648) / 2147483648;
  const log = [];
  let through = null;
  for (let slot = 1; slot <= count; slot += 1) {
    const roll = next();
    let entry;
    if (roll < 0.15 && slot > 2) {
      through = String(Math.max(Number(through ?? 0), Math.floor(1 + next() * (slot - 1))));
      entry = { k: "checkpoint", through, data: `c${slot}` };
    } else if (roll < 0.35) entry = { k: "input", key: `prompt:p${slot}`, type: "prompt", messageId: `p${slot}` };
    else entry = { k: ["lease", "record", "release"][Math.floor(next() * 3)], a: null, n: slot };
    log.push({ cursor: String(slot), entry });
  }
  return log;
}

// The log as a whole read returns it: every entry after the newest
// checkpoint's `through`, which is 0 without one.
function wholeRead(log) {
  let through = 0;
  for (const { entry } of log) if (entry.k === "checkpoint") through = entry.through === null ? 0 : Number(entry.through);
  return { entries: log.filter(({ cursor }) => Number(cursor) > through), through };
}

test("a log view extended by the entries after it reads as the whole log does, wherever it was cut", () => {
  for (let seed = 1; seed <= 200; seed += 1) {
    const log = randomLog(seed, 1 + (seed % 40));
    const whole = wholeRead(log);
    const chained = [...whole.entries].reverse().find(({ entry }) => ["lease", "record", "release"].includes(entry.k));
    for (let cut = 0; cut <= log.length; cut += 1) {
      const next = extendLogView(wholeRead(log.slice(0, cut)), log.slice(cut));
      assert.ok(next, `seed ${seed} cut ${cut} kept a view`);
      assert.deepEqual(next.entries, whole.entries, `seed ${seed} cut ${cut}`);
      assert.equal(next.through, whole.through);
      assert.equal(next.head, chained?.cursor ?? (whole.through ? String(whole.through) : "null"));
    }
  }
  // A checkpoint covering less than the view starts after cannot stand for
  // the view; only a whole read can answer it.
  const view = { entries: [{ cursor: "12", entry: { k: "record", a: "11" } }], through: 10 };
  assert.equal(extendLogView(view, [{ cursor: "13", entry: { k: "checkpoint", through: "5" } }]), null);
});

test("a worker starts from its sender's read only when the sender's entries took the very next slots", () => {
  const read = [{ cursor: "7", entry: { k: "release" } }];
  const input = (cursor) => ({ cursor, entry: { k: "input", messageId: "m" } });
  assert.deepEqual(handoffEntries(read, 9, [input("10")]), [...read, input("10")]);
  assert.deepEqual(handoffEntries(read, 9, [input("10"), input("11")]), [...read, input("10"), input("11")]);
  // Another server's write landed between the read and the input.
  assert.equal(handoffEntries(read, 9, [input("11")]), null);
  assert.equal(handoffEntries(read, 9, [input("10"), input("12")]), null);
  // Nothing written, or a log that cannot say what it has seen.
  assert.equal(handoffEntries(read, 9, []), null);
  assert.equal(handoffEntries(read, undefined, [input("10")]), null);
  assert.equal(handoffEntries(read, null, [input("10")]), null);
  // The worker gets what the World stored, not the sender's own objects.
  const written = [input("10")];
  handoffEntries(read, 9, written)[1].entry.changed = true;
  assert.equal(written[0].entry.changed, undefined);
});

// A World durability that tells `onList(params)` of each log listing and
// `onCreate(kind)` of each entry written.
function watchingLog(base, { onList = () => {}, onCreate = () => {} } = {}) {
  return {
    ...base,
    world: async () => {
      const world = await base.world();
      const list = world.events.list.bind(world.events);
      const create = world.events.create.bind(world.events);
      const events = Object.assign(Object.create(world.events), {
        list(params, ...rest) {
          onList(params);
          return list(params, ...rest);
        },
        create(runId, event, ...rest) {
          if (event?.eventType === "step_created") {
            try { onCreate(JSON.parse(decoder.decode(event.eventData.input)).k); } catch {}
          }
          return create(runId, event, ...rest);
        },
      });
      return Object.assign(Object.create(world), { events });
    },
  };
}

async function untilIdle(agent) {
  const internals = agent[Symbol.for("libfx.durableInternals")];
  for (let tries = 0; internals.liveWorkers() > 0; tries += 1) {
    assert.ok(tries < 200, "the worker never let go");
    await sleep(10);
  }
}

if (durabilityKind !== "memory") {
  test("a server reads again only what landed in a session's log since it last read it, and sees what a fresh server sees", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-log-view-"));
    dirs.push(dir);
    const lists = [];
    const agent = createAgent({ durability: watchingLog(await durabilityAt(dir), { onList: (params) => lists.push(params) }) });
    const session = agent.session();
    for (const input of ["rho", "sigma", "tau", "chi"]) assert.equal((await textOf(session.prompt(input))).result.stopReason, "end_turn");
    await untilIdle(agent);
    const ours = await agent[Symbol.for("libfx.durableInternals")].openLog(session.id);
    // More entries than a read's first page, so a whole read lists two.
    const first = await ours.read();
    assert.ok(first.length > 10);
    // A caller that changes what a read returned changes nothing stored.
    for (const item of first) item.entry.changedByCaller = true;
    const other = createAgent({ durability: await durabilityAt(dir) });
    const theirs = await other[Symbol.for("libfx.durableInternals")].openLog(session.id);
    const fresh = async () => {
      const reader = createAgent({ durability: await durabilityAt(dir) });
      const entries = await (await reader[Symbol.for("libfx.durableInternals")].openLog(session.id)).read();
      await reader.close();
      return entries;
    };
    // Another server adds an input.
    await theirs.append({ k: "input", key: "cancel:cnl_elsewhere", type: "cancel", messageId: "cnl_elsewhere" });
    lists.length = 0;
    const cached = await ours.read();
    assert.equal(lists.length, 1, "one short page lists what landed since");
    assert.equal(lists[0].pagination.cursor, undefined);
    assert.deepEqual(cached, await fresh());
    // Then a checkpoint that covers the chain: only the entries after its
    // head are read, the input written after the head and the checkpoint.
    const { head } = foldSessionLog(await theirs.read());
    await theirs.append({ k: "checkpoint", through: head, data: "", pending: [], recent: [] });
    const after = await ours.read();
    assert.deepEqual(after, await fresh());
    assert.deepEqual(after.map(({ entry }) => entry.k), ["input", "checkpoint"]);
    // A view many entries behind reads only back to the newest checkpoint
    // among them, not every entry since the view.
    let last;
    for (let index = 0; index < 15; index += 1) {
      last = await theirs.append({ k: "input", key: `cancel:cnl_burst${index}`, type: "cancel", messageId: `cnl_burst${index}` });
    }
    await theirs.append({ k: "checkpoint", through: last, data: "", pending: [], recent: [] });
    lists.length = 0;
    const behind = await ours.read();
    assert.equal(lists.length, 1, "the read stops at the checkpoint on its first page");
    assert.deepEqual(behind, await fresh());
    assert.deepEqual(behind.map(({ entry }) => entry.k), ["checkpoint"]);
    for (const closing of [agent, other]) await closing.close();
  });

  test("a server whose listing skips a slot keeps no view past it, and reads the entry once the World shows it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-log-gap-"));
    dirs.push(dir);
    // Slots the World's listings leave out, as a World can list a newer
    // write before an earlier one has landed.
    const hidden = new Set();
    const hiding = async () => {
      const base = await durabilityAt(dir);
      return {
        ...base,
        world: async () => {
          const world = await base.world();
          const list = world.events.list.bind(world.events);
          const events = Object.assign(Object.create(world.events), {
            async list(...args) {
              const page = await list(...args);
              const slot = (event) => Number(/_(\d{26})$/.exec(String(event.eventId))?.[1]);
              return { ...page, data: page.data.filter((event) => !hidden.has(slot(event))) };
            },
          });
          return Object.assign(Object.create(world), { events });
        },
      };
    };
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    const agent = createAgent({ durability: await hiding() });
    const session = agent.session();
    for (const input of ["omicron", "psi"]) assert.equal((await textOf(session.prompt(input))).result.stopReason, "end_turn");
    await untilIdle(agent);
    const ours = await internals(agent).openLog(session.id);
    await ours.read();
    assert.ok(Number.isSafeInteger(ours.newest()));
    const other = createAgent({ durability: await durabilityAt(dir) });
    const theirs = await internals(other).openLog(session.id);
    // Another server writes three inputs, and the middle one does not list yet.
    await theirs.append({ k: "input", key: "cancel:cnl_first", type: "cancel", messageId: "cnl_first" });
    hidden.add(Number(await theirs.append({ k: "input", key: "cancel:cnl_late", type: "cancel", messageId: "cnl_late" })));
    await theirs.append({ k: "input", key: "cancel:cnl_next", type: "cancel", messageId: "cnl_next" });
    const ids = (entries) => entries.map(({ entry }) => entry.messageId);
    const gapped = await ours.read();
    assert.ok(ids(gapped).includes("cnl_first") && ids(gapped).includes("cnl_next") && !ids(gapped).includes("cnl_late"));
    assert.equal(ours.newest(), null, "a read that skipped a slot hands no worker its view");
    // A server's first, whole read keeps no view past the gap either.
    const late = createAgent({ durability: await hiding() });
    const latecomer = await internals(late).openLog(session.id);
    assert.ok(!ids(await latecomer.read()).includes("cnl_late"));
    assert.equal(latecomer.newest(), null);
    hidden.clear();
    // Nor does a whole read that did not reach the run's first event.
    hidden.add(1);
    const bottom = createAgent({ durability: await hiding() });
    const unreached = await internals(bottom).openLog(session.id);
    await unreached.read();
    assert.equal(unreached.newest(), null, "a whole read that missed the first slot keeps no view");
    hidden.clear();
    const fresh = createAgent({ durability: await durabilityAt(dir) });
    const whole = await (await internals(fresh).openLog(session.id)).read();
    assert.ok(ids(whole).includes("cnl_late"));
    for (const log of [ours, latecomer, unreached]) {
      assert.deepEqual(await log.read(), whole, "the entry is read once the World lists it");
      assert.ok(Number.isSafeInteger(log.newest()));
    }
    // The lowest of the newer writes lists late: the newer listing does not
    // reach the view, so the read is whole and keeps no view.
    hidden.add(Number(await theirs.append({ k: "input", key: "cancel:cnl_low", type: "cancel", messageId: "cnl_low" })));
    await theirs.append({ k: "input", key: "cancel:cnl_high", type: "cancel", messageId: "cnl_high" });
    assert.ok(!ids(await ours.read()).includes("cnl_low"));
    assert.equal(ours.newest(), null, "a newer listing that does not reach the view hands no worker its view");
    hidden.clear();
    assert.ok(ids(await ours.read()).includes("cnl_low"));
    // A whole read that stops at a checkpoint keeps a view, but only when its
    // listing reached that checkpoint's through.
    const through = await theirs.append({ k: "input", key: "cancel:cnl_covered", type: "cancel", messageId: "cnl_covered" });
    await theirs.append({ k: "input", key: "cancel:cnl_after", type: "cancel", messageId: "cnl_after" });
    await theirs.append({ k: "checkpoint", through, data: "", pending: [], recent: [] });
    for (let slot = 1; slot <= Number(through) + 1; slot += 1) hidden.add(slot);
    const short = createAgent({ durability: await hiding() });
    const shortLog = await internals(short).openLog(session.id);
    assert.ok(!ids(await shortLog.read()).includes("cnl_after"));
    assert.equal(shortLog.newest(), null, "a listing that ended above the checkpoint's through keeps no view");
    hidden.clear();
    const cold = createAgent({ durability: await hiding() });
    const coldLog = await internals(cold).openLog(session.id);
    const coldRead = await coldLog.read();
    assert.deepEqual(coldRead.map(({ entry }) => entry.k), ["input", "checkpoint"]);
    assert.ok(Number.isSafeInteger(coldLog.newest()), "a whole read that stopped at a checkpoint keeps a view");
    assert.deepEqual(await shortLog.read(), coldRead);
    for (const closing of [agent, other, late, bottom, fresh, short, cold]) await closing.close();
  });

  test("a write a log makes while its own read lists shows in its next read", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-log-own-write-"));
    dirs.push(dir);
    // Runs once inside the next listing, after the World answered it.
    let during = null;
    const base = await durabilityAt(dir);
    const durability = {
      ...base,
      world: async () => {
        const world = await base.world();
        const list = world.events.list.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async list(...args) {
            const page = await list(...args);
            const write = during;
            during = null;
            await write?.();
            return page;
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    const agent = createAgent({ durability });
    const session = agent.session();
    for (const input of ["iota", "kappa"]) assert.equal((await textOf(session.prompt(input))).result.stopReason, "end_turn");
    await untilIdle(agent);
    const ours = await internals(agent).openLog(session.id);
    await ours.read();
    let written;
    during = async () => { written = await ours.append({ k: "note", n: 1 }); };
    const listed = await ours.read();
    assert.ok(written && !listed.some(({ cursor }) => cursor === written), "the listing was answered before the write");
    const next = await ours.read();
    assert.ok(next.some(({ cursor }) => cursor === written));
    const fresh = createAgent({ durability: await durabilityAt(dir) });
    assert.deepEqual(next, await (await internals(fresh).openLog(session.id)).read());
    for (const closing of [agent, fresh]) await closing.close();
  });
}

if (durabilityKind === "queue") {
  test("a prompt the request runs itself starts its worker from the sender's read, without reading the log again", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-"));
    dirs.push(dir);
    const ops = [];
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const agent = createAgent({ durability: watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) }) });
    const session = agent.session();
    assert.equal((await textOf(session.prompt("upsilon"))).result.stopReason, "end_turn");
    await untilIdle(agent);
    ops.length = 0;
    assert.equal((await textOf(session.prompt("phi"))).result.stopReason, "end_turn");
    const input = ops.indexOf("input");
    const lease = ops.indexOf("lease", input);
    assert.ok(input >= 0 && lease > input, JSON.stringify(ops));
    assert.deepEqual(ops.slice(input + 1, lease), [], "nothing read or written between the input and the worker's lease");
    await agent.close();
  });

  test("a new session's first prompt the request runs itself starts its worker from the sender's read", async () => {
    for (const inBandFence of [false, true]) {
      const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-new-"));
      dirs.push(dir);
      const ops = [];
      const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000, inBandFence });
      const agent = createAgent({ durability: watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) }) });
      const session = agent.session();
      assert.equal((await textOf(session.prompt("chi"))).result.stopReason, "end_turn");
      const input = ops.indexOf("input");
      const lease = ops.indexOf("lease", input);
      assert.ok(input >= 0 && lease > input, JSON.stringify(ops));
      assert.deepEqual(ops.slice(input + 1, lease), [], `nothing read or written between the input and the worker's lease (inBandFence ${inBandFence})`);
      await untilIdle(agent);
      // The session goes on from the log the first turn left.
      assert.equal((await textOf(session.prompt("psi"))).result.stopReason, "end_turn");
      await agent.close();
    }
  });

  test("a worker reads the log itself when another writer creates the new session's run first", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-race-"));
    dirs.push(dir);
    const ops = [];
    // Runs once, just before this agent creates the run.
    let before = null;
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const watched = watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) });
    const durability = {
      ...watched,
      world: async () => {
        const world = await watched.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(runId, event, ...rest) {
            if (before && event?.eventType === "run_created") {
              const write = before;
              before = null;
              await write(runId);
            }
            return create(runId, event, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    const agent = createAgent({ durability });
    const other = createAgent({ durability: await durabilityAt(dir) });
    before = async (runId) => (await internals(other).openLog(runId)).append({ k: "note", n: 1 });
    // An id this agent did not mint, so its sender reads the log before it
    // tries to create the run, as a first prompt from another server does.
    const session = agent.session(await other.newSessionId());
    assert.equal((await textOf(session.prompt("tau"))).result.stopReason, "end_turn");
    assert.equal(before, null, "the other writer created the run");
    const input = ops.indexOf("input");
    const lease = ops.indexOf("lease", input);
    assert.ok(input >= 0 && lease > input, JSON.stringify(ops));
    assert.ok(ops.slice(input + 1, lease).includes("list"), "the worker read the log before its lease");
    for (const closing of [agent, other]) await closing.close();
  });

  test("a first prompt on an id another server minted starts its worker from the sender's read once its sender creates the run", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-unminted-"));
    dirs.push(dir);
    const ops = [];
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const agent = createAgent({ durability: watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) }) });
    const other = createAgent({ durability: await durabilityAt(dir) });
    // Not minted here: the sender reads the missing run first, then creates it.
    const session = agent.session(await other.newSessionId());
    assert.equal((await textOf(session.prompt("upsilon"))).result.stopReason, "end_turn");
    const input = ops.indexOf("input");
    const lease = ops.indexOf("lease", input);
    assert.ok(input >= 0 && ops.indexOf("list") < input && lease > input, JSON.stringify(ops));
    assert.deepEqual(ops.slice(input + 1, lease), [], "the worker took the sender's read of the run it created");
    for (const closing of [agent, other]) await closing.close();
  });

  test("a new chat's first lease is written in-band where the World fences in-band writes", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-inband-"));
    dirs.push(dir);
    const leases = [];
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000, inBandFence: true });
    const durability = {
      ...base,
      world: async () => {
        const world = await base.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          create(runId, event, params, ...rest) {
            if (event?.eventType === "step_created") {
              try { if (JSON.parse(decoder.decode(event.eventData.input)).k === "lease") leases.push(params?.inBand === true); } catch {}
            }
            return create(runId, event, params, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const agent = createAgent({ durability });
    assert.equal((await textOf(agent.session().prompt("phi"))).result.stopReason, "end_turn");
    assert.ok(leases.length > 0, "the turn took a lease");
    assert.equal(leases[0], true, "the first lease was written in-band");
    await agent.close();
  });

  test("a creation event that does not land at the very next slot leaves the worker to read the log itself", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-skip-"));
    dirs.push(dir);
    const ops = [];
    let raced = false;
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    const other = createAgent({ durability: await durabilityAt(dir) });
    const id = await other.newSessionId();
    const otherLog = await internals(other).openLog(id);
    const watched = watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) });
    const durability = {
      ...watched,
      world: async () => {
        const world = await watched.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(runId, event, ...rest) {
            if (!raced && runId === id && event?.eventType === "run_started") {
              raced = true;
              // Another server's entries land after the run is created, then
              // the World answers this run_started with an event two slots on,
              // past them.
              await create(runId, event, ...rest).catch(() => {});
              await otherLog.append({ k: "note", n: 1 });
              await otherLog.append({ k: "note", n: 2 });
              const listed = (await world.events.list({ runId, pagination: { limit: 100 } })).data;
              const newest = Math.max(...listed.map((event) => Number(/(\d{26})$/.exec(event.eventId)[1])));
              return { event: { eventId: `evnt_${String(newest).padStart(26, "0")}` } };
            }
            return create(runId, event, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const agent = createAgent({ durability });
    assert.equal((await textOf(agent.session(id).prompt("omicron"))).result.stopReason, "end_turn");
    assert.ok(raced, "the run_started answer was replaced");
    const input = ops.indexOf("input");
    const lease = ops.indexOf("lease", input);
    assert.ok(input >= 0 && lease > input, JSON.stringify(ops));
    assert.ok(ops.slice(input + 1, lease).includes("list"), "the worker read the log before its lease");
    for (const closing of [agent, other]) await closing.close();
  });

  test("a worker reads the log itself when another write lands between its sender's read and the input", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-gap-"));
    dirs.push(dir);
    const ops = [];
    // Runs once, just before the next input is written.
    let before = null;
    const kindOf = (event) => {
      try { return JSON.parse(decoder.decode(event.eventData.input)).k; } catch { return null; }
    };
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const watched = watchingLog(base, { onList: () => ops.push("list"), onCreate: (kind) => ops.push(kind) });
    const durability = {
      ...watched,
      world: async () => {
        const world = await watched.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(runId, event, ...rest) {
            if (before && event?.eventType === "step_created" && kindOf(event) === "input") {
              const write = before;
              before = null;
              await write();
            }
            return create(runId, event, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
    const agent = createAgent({ durability });
    const session = agent.session();
    assert.equal((await textOf(session.prompt("lambda"))).result.stopReason, "end_turn");
    await untilIdle(agent);
    const other = createAgent({ durability: await durabilityAt(dir) });
    const theirs = await internals(other).openLog(session.id);
    ops.length = 0;
    before = () => theirs.append({ k: "note", n: 1 });
    assert.equal((await textOf(session.prompt("mu"))).result.stopReason, "end_turn");
    const input = ops.indexOf("input");
    const lease = ops.indexOf("lease", input);
    assert.ok(input >= 0 && lease > input, JSON.stringify(ops));
    assert.ok(ops.slice(input + 1, lease).includes("list"), "the worker read the log before its lease");
    for (const closing of [agent, other]) await closing.close();
  });

  const entryOfEvent = (event) => {
    try { return event?.eventType === "step_created" ? JSON.parse(decoder.decode(event.eventData.input)) : null; } catch { return null; }
  };
  // A World with hooks: before(entry) runs before a write, after(entry) once
  // it landed, onList() at each listing, onQueue(payload, options) before a send.
  const hookedWorld = (base, hooks) => ({
    ...base,
    world: async () => {
      const world = await base.world();
      const list = world.events.list.bind(world.events);
      const create = world.events.create.bind(world.events);
      const queue = world.queue.bind(world);
      const events = Object.assign(Object.create(world.events), {
        async list(...args) {
          await hooks.onList?.(args[0]);
          return list(...args);
        },
        async create(runId, event, ...rest) {
          const entry = entryOfEvent(event);
          if (entry) await hooks.before?.(entry);
          const result = await create(runId, event, ...rest);
          if (entry) await hooks.after?.(entry);
          return result;
        },
      });
      return Object.assign(Object.create(world), {
        events,
        async queue(name, payload, options = {}) {
          await hooks.onQueue?.(payload, options);
          return queue(name, payload, options);
        },
      });
    },
  });
  const internalsOf = (agent) => agent[Symbol.for("libfx.durableInternals")];

  test("a prompt's worker reads the log again when a turn ran here after its sender's read, so the prompt starts once", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-handoff-stale-"));
    dirs.push(dir);
    // Runs once, at the first listing after a's release: a's worker reading
    // the log again, once it stopped running. Then the next release, b's,
    // resolves `bReleased`.
    let onRelease = null;
    let beforeList = null;
    let ranB;
    const bReleased = new Promise((resolve) => { ranB = resolve; });
    let bStored;
    const stored = new Promise((resolve) => { bStored = resolve; });
    // Resolves at the next listing, once armed.
    let listed = null;
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const durability = hookedWorld(base, {
      onList: async () => {
        const wake = listed;
        listed = null;
        wake?.();
        const run = beforeList;
        beforeList = null;
        await run?.();
      },
      // b's sender goes on from its write, to its backstop and its worker,
      // once the turn before b ran b here and its worker read the log
      // again, with nothing running.
      after: async (entry) => {
        if (entry.k === "release") {
          if (onRelease) [beforeList, onRelease] = [onRelease, null];
          else ranB();
        }
        if (entry.k === "input" && entry.messageId === "stale-b") {
          bStored();
          await bReleased;
          await new Promise((resolve) => { listed = resolve; });
        }
      },
    });
    const agent = createAgent({ durability });
    const session = agent.session();
    // a's turn ends before its release lands.
    let sent;
    const second = new Promise((resolve) => { sent = resolve; });
    // b's sender reads the log after a's worker stopped and stores b before
    // that worker reads the log again, so a's worker runs b first.
    onRelease = async () => {
      sent(textOf(session.prompt("nu", { messageId: "stale-b" })));
      await stored;
    };
    assert.equal((await textOf(session.prompt("xi", { messageId: "stale-a" }))).result.stopReason, "end_turn");
    const { text, result } = await second;
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "nu-0 nu-1 nu-2");
    await untilIdle(agent);
    assert.deepEqual(prompted.filter((id) => id === "stale-b"), ["stale-b"], "b's turn started once");
    await agent.close();
  });


  test("a sender that reads while a claim's lease is still landing does not start a turn twice", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-lease-landing-"));
    dirs.push(dir);
    let onLease = null;
    let bStored;
    const stored = new Promise((resolve) => { bStored = resolve; });
    let armedRelease = false;
    let ranB;
    const bReleased = new Promise((resolve) => { ranB = resolve; });
    let listed = null;
    const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
    const durability = hookedWorld(base, {
      onList: () => { const wake = listed; listed = null; wake?.(); },
      before: async (entry) => {
        if (entry.k === "lease" && onLease) { const run = onLease; onLease = null; await run(); }
      },
      after: (entry) => {
        if (entry.k === "input" && entry.messageId === "m2-b") bStored();
        if (entry.k === "release" && armedRelease) { armedRelease = false; ranB(); }
      },
      onQueue: async (payload, options) => {
        if (payload?.input?.messageId === "m2-b" && options.delaySeconds > 0) {
          await bReleased;
          await new Promise((resolve) => { listed = resolve; });
        }
      },
    });
    const agent = createAgent({ durability });
    const session = agent.session();
    assert.equal((await textOf(session.prompt("warm", { messageId: "m2-w" }))).result.stopReason, "end_turn");
    await untilIdle(agent);
    let sent;
    const second = new Promise((resolve) => { sent = resolve; });
    // a's claim is running, its lease not yet in the log, when b's sender
    // marks and reads; b lands before the lease does.
    onLease = async () => {
      armedRelease = true;
      sent(textOf(session.prompt("nu", { messageId: "m2-b" })));
      await stored;
    };
    const first = await textOf(session.prompt("xi", { messageId: "m2-a" }));
    assert.equal(first.result.stopReason, "end_turn");
    const { text, result } = await second;
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "nu-0 nu-1 nu-2");
    await untilIdle(agent);
    assert.deepEqual(prompted.filter((id) => id.startsWith("m2-")), ["m2-w", "m2-a", "m2-b"], "each turn started once");
    await agent.close();
  });

  test("a prompt whose turn another sender's worker ran before its own worker started starts once", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-other-sender-"));
    dirs.push(dir);
    let onBStored = null;
    const pending = [];
    const { durability: base } = await queueWorldAt(dir, {
      queueLeases: true, runInRequest: true, maxDurationMs: 60_000,
      waitUntil: (work) => pending.push(work),
    });
    const durability = hookedWorld(base, {
      // b's sender goes on from its write, to its backstop and its worker,
      // once c's worker ran b and relinquished the worker.
      after: async (entry) => {
        if (entry.k === "input" && entry.messageId === "bc-b" && onBStored) {
          const run = onBStored;
          onBStored = null;
          run();
          await cTurn;
          // The turn can finish before receive()'s finally. Only warm and c
          // have waitUntil work here: b is still held at its input write.
          await Promise.all(pending);
        }
      },
    });
    const agent = createAgent({ durability });
    const session = agent.session();
    assert.equal((await textOf(session.prompt("warm", { messageId: "bc-w" }))).result.stopReason, "end_turn");
    await Promise.all(pending);
    let cTurn;
    onBStored = () => { cTurn = textOf(session.prompt("chi", { messageId: "bc-c" })); };
    const b = await textOf(session.prompt("nu", { messageId: "bc-b" }));
    const c = await cTurn;
    assert.equal(b.text, "nu-0 nu-1 nu-2");
    assert.equal(c.text, "chi-0 chi-1 chi-2");
    await Promise.all(pending);
    assert.deepEqual(prompted.filter((id) => id.startsWith("bc-")), ["bc-w", "bc-b", "bc-c"], "each turn started once");
    await agent.close();
  });

  for (const [how, what] of [["backstop", "a backstop send"], ["input", "an input write"]]) {
    test(`${what} that fails leaves no worker held`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-held-fail-"));
      dirs.push(dir);
      const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
      const durability = hookedWorld(base, {
        before: (entry) => { if (how === "input" && entry.k === "input" && entry.messageId === "f-b") throw new Error("input write failed"); },
        onQueue: (payload, options) => { if (how === "backstop" && payload?.input?.messageId === "f-b" && options.delaySeconds > 0) throw new Error("backstop failed"); },
      });
      const agent = createAgent({ durability });
      const session = agent.session();
      assert.equal((await textOf(session.prompt("warm", { messageId: "f-w" }))).result.stopReason, "end_turn");
      await untilIdle(agent);
      await assert.rejects(textOf(session.prompt("nu", { messageId: "f-b" })));
      assert.equal(internalsOf(agent).liveWorkers(), 0, "no worker is left held");
      await agent.close();
    });
  }
}

// A durability whose World records each call it takes, as `[name, runId]`
// with `name` `list`, `getInfo`, `create:<eventType>`, `create:<entry
// kind>` or `queue`, and fails a call once where `faults` names it:
// `faults.add("create:input")`.
function countingWorld(base, calls, faults = new Set()) {
  const failOnce = (name, runId) => {
    calls.push([name, runId]);
    if (!faults.delete(name)) return;
    throw Object.assign(new Error("injected failure"), { status: 503, call: name });
  };
  return {
    ...base,
    world: async () => {
      const world = await base.world();
      const list = world.events.list.bind(world.events);
      const create = world.events.create.bind(world.events);
      const getInfo = world.streams.getInfo.bind(world.streams);
      const queue = world.queue.bind(world);
      const events = Object.assign(Object.create(world.events), {
        list(...args) {
          calls.push(["list", args[0]?.runId]);
          return list(...args);
        },
        async create(runId, event, ...rest) {
          let name = `create:${event?.eventType}`;
          if (event?.eventType === "step_created") {
            try { name = `create:${JSON.parse(decoder.decode(event.eventData.input)).k}`; } catch {}
          }
          failOnce(name, runId);
          return create(runId, event, ...rest);
        },
      });
      const streams = Object.assign(Object.create(world.streams), {
        getInfo(...args) {
          calls.push(["getInfo", args[0]]);
          return getInfo(...args);
        },
      });
      return Object.assign(Object.create(world), {
        events,
        streams,
        async queue(...args) {
          failOnce("queue", args[1]?.runId);
          return queue(...args);
        },
      });
    },
  };
}

// The calls for session `id`, and those up to its first queue send.
const callsOf = (calls, id) => calls.filter(([, runId]) => runId === id).map(([name]) => name);
const admission = (calls, id) => {
  const mine = callsOf(calls, id);
  return mine.slice(0, mine.indexOf("queue") + 1);
};
const reads = (names) => names.filter((name) => name === "list" || name === "getInfo").length;

if (durabilityKind !== "memory") {
  test("a new chat's first prompt, on an id this process minted, reads nothing before it is stored, retried or not", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-"));
    dirs.push(dir);
    const calls = [];
    const agent = createAgent({ durability: countingWorld(await durabilityAt(dir), calls) });
    const id = await agent.newSessionId();
    const first = agent.session(id).prompt("alpha", { messageId: "turn-fresh" });
    assert.equal((await first.accepted).sessionId, id);
    assert.deepEqual(admission(calls, id), ["create:run_created", "create:run_started", "create:input", "queue"]);
    assert.equal((await first.result).stopReason, "end_turn");
    await untilIdle(agent);
    // A retry of it reads the session as before, and runs nothing again.
    const ranBefore = ran.length;
    calls.length = 0;
    const again = await agent.session(id).prompt("alpha", { messageId: "turn-fresh" }).result;
    assert.equal(again.repeated, true);
    assert.deepEqual(ran.slice(ranBefore).filter((step) => step.startsWith("turn-fresh:")), [], "the retry ran nothing");
    assert.ok(reads(callsOf(calls, id)) > 0, "the retry read the session");
    // A session the agent names itself is new as well.
    calls.length = 0;
    const own = agent.session();
    const turn = own.prompt("beta");
    await turn.accepted;
    assert.deepEqual(admission(calls, own.id), ["create:run_created", "create:run_started", "create:input", "queue"]);
    assert.equal((await turn.result).stopReason, "end_turn");
    assert.deepEqual(JSON.parse(decoder.decode(await agent.session(id).checkpoint())), ["alpha-0", "alpha-1", "alpha-2"]);
    await agent.close();
  });

  test("a prompt aborted while its run is being created stores and queues nothing, and its same-id retry runs once", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-abort-"));
    dirs.push(dir);
    const calls = [];
    const counted = countingWorld(await durabilityAt(dir), calls);
    let started;
    let release;
    const holding = new Promise((resolve) => { started = resolve; });
    const released = new Promise((resolve) => { release = resolve; });
    let id;
    const durability = {
      ...counted,
      world: async () => {
        const world = await counted.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(runId, event, ...rest) {
            if (runId === id && event?.eventType === "run_created") {
              started();
              await released;
            }
            return create(runId, event, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const agent = createAgent({ durability });
    try {
      id = await agent.newSessionId();
      const messageId = "turn-abort-create";
      const before = ran.length;
      const promptedBefore = prompted.length;
      const controller = new AbortController();
      const turn = agent.session(id).prompt("omicron", { messageId, signal: controller.signal });
      await holding;
      controller.abort();
      release();
      assert.equal((await turn.accepted).sessionId, id);
      assert.equal((await turn.result).stopReason, "cancelled");
      await untilIdle(agent);
      assert.deepEqual(callsOf(calls, id), ["create:run_created", "create:run_started"], "the aborted prompt wrote only the run's creation, with no input or queue send");
      assert.deepEqual(prompted.slice(promptedBefore), [], "the aborted prompt started no turn");
      assert.deepEqual(ran.slice(before), [], "the aborted prompt ran no steps");
      calls.length = 0;
      const retry = agent.session(id).prompt("omicron", { messageId });
      await retry.accepted;
      assert.ok(reads(admission(calls, id)) > 0, "the retry read the run the aborted prompt created");
      const result = await retry.result;
      assert.equal(result.stopReason, "end_turn");
      assert.notEqual(result.repeated, true, "the aborted prompt did not run the turn");
      await untilIdle(agent);
      assert.equal(callsOf(calls, id).filter((name) => name === "create:input").length, 1, "the retry stored the input once");
      assert.equal(callsOf(calls, id).filter((name) => name === "queue").length, 1, "the retry queued the input once");
      assert.deepEqual(prompted.slice(promptedBefore), [messageId], "the retry started the turn once");
      assert.deepEqual(ran.slice(before), [0, 1, 2].map((step) => `${messageId}:${step}`), "the retry ran each step once");
      assert.deepEqual(JSON.parse(decoder.decode(await agent.session(id).checkpoint())), ["omicron-0", "omicron-1", "omicron-2"]);
    } finally {
      release();
      await agent.close();
    }
  });

  test("a minted id another server prompted first is read as before, and its turn runs once", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-other-"));
    dirs.push(dir);
    const calls = [];
    const agent = createAgent({ durability: countingWorld(await durabilityAt(dir), calls) });
    const other = createAgent({ durability: await durabilityAt(dir) });
    // Sequential: the other server ran the turn before this one's first prompt.
    const id = await agent.newSessionId();
    const ranBefore = ran.length;
    assert.equal((await other.session(id).prompt("gamma", { messageId: "turn-g" }).result).stopReason, "end_turn");
    await untilIdle(other);
    const mine = await agent.session(id).prompt("gamma", { messageId: "turn-g" }).result;
    assert.equal(mine.repeated, true, "the run existed, so the turn is answered from it");
    assert.ok(reads(admission(calls, id)) > 0, "the run existed, so the session was read");
    assert.deepEqual(ran.slice(ranBefore).filter((step) => step.startsWith("turn-g:")), ["turn-g:0", "turn-g:1", "turn-g:2"]);
    // Concurrent: both servers send one first prompt together.
    const both = await agent.newSessionId();
    const ranThen = ran.length;
    const results = await Promise.all([agent, other].map((each) => each.session(both).prompt("delta", { messageId: "turn-d" }).result));
    for (const result of results) assert.equal(result.stopReason, "end_turn");
    await untilIdle(agent);
    await untilIdle(other);
    assert.deepEqual(ran.slice(ranThen).filter((step) => step.startsWith("turn-d:")).sort(), ["turn-d:0", "turn-d:1", "turn-d:2"], "the turn ran once");
    assert.deepEqual(JSON.parse(decoder.decode(await agent.session(both).checkpoint())), ["delta-0", "delta-1", "delta-2"]);
    for (const closing of [agent, other]) await closing.close();
  });

  test("a run_created that lands past the first slot does not count as creating the run", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-late-"));
    dirs.push(dir);
    const calls = [];
    const counted = countingWorld(await durabilityAt(dir), calls);
    let id = null;
    // A World that answers run_created on an existing run with success, at a
    // later slot, instead of refusing it.
    const durability = {
      ...counted,
      world: async () => {
        const world = await counted.world();
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(runId, event, ...rest) {
            if (runId === id && event?.eventType === "run_created") {
              await create(runId, event, ...rest).catch(() => {});
              return { event: { eventId: `evnt_${String(7).padStart(26, "0")}` } };
            }
            return create(runId, event, ...rest);
          },
        });
        return Object.assign(Object.create(world), { events });
      },
    };
    const agent = createAgent({ durability });
    const other = createAgent({ durability: await durabilityAt(dir) });
    id = await agent.newSessionId();
    const ranBefore = ran.length;
    assert.equal((await other.session(id).prompt("zeta", { messageId: "turn-z" }).result).stopReason, "end_turn");
    await untilIdle(other);
    const mine = await agent.session(id).prompt("zeta", { messageId: "turn-z" }).result;
    assert.equal(mine.repeated, true, "the run existed, so the turn is answered from it");
    assert.ok(reads(admission(calls, id)) > 0, "the session was read");
    assert.deepEqual(ran.slice(ranBefore).filter((step) => step.startsWith("turn-z:")), ["turn-z:0", "turn-z:1", "turn-z:2"], "the turn ran once");
    for (const closing of [agent, other]) await closing.close();
  });

  test("a new chat's first prompt whose write fails is stored by its retry once, and queued", async () => {
    for (const fault of ["create:run_started", "create:input", "queue"]) {
      const dir = await mkdtemp(join(tmpdir(), "libfx-fresh-fail-"));
      dirs.push(dir);
      const calls = [];
      const faults = new Set([fault]);
      const base = durabilityKind === "queue"
        ? (await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000, reserveMs: 100 })).durability
        : await durabilityAt(dir);
      const agent = createAgent({ durability: countingWorld(base, calls, faults) });
      const id = await agent.newSessionId();
      const messageId = `turn-${fault.replace(/[^a-z]/g, "")}`;
      await assert.rejects(agent.session(id).prompt("eps", { messageId }).accepted, { message: "injected failure", status: 503, call: fault }, fault);
      const writes = ["create:run_created", "create:run_started", "create:input", "queue"];
      assert.deepEqual(callsOf(calls, id), writes.slice(0, writes.indexOf(fault) + 1), `${fault}: only the writes through the failed call were attempted`);
      const ranBefore = ran.length;
      calls.length = 0;
      const retry = agent.session(id).prompt("eps", { messageId });
      await retry.accepted;
      assert.ok(reads(admission(calls, id)) > 0, `${fault}: the retry read the session`);
      assert.equal(callsOf(calls, id).filter((name) => name === "queue").length, 1, `${fault}: the retry queued its message once`);
      const result = await retry.result;
      assert.equal(result.stopReason, "end_turn", fault);
      assert.notEqual(result.repeated, true, `${fault}: no earlier attempt ran it`);
      await untilIdle(agent);
      assert.deepEqual(ran.slice(ranBefore).filter((step) => step.startsWith(`${messageId}:`)), [0, 1, 2].map((step) => `${messageId}:${step}`), `${fault}: it ran once`);
      const inputs = callsOf(calls, id).filter((name) => name === "create:input").length;
      assert.equal(inputs, fault === "queue" ? 0 : 1, `${fault}: the input is stored once`);
      await agent.close();
    }
  });
}

if (durabilityKind === "queue") {
  // A durability whose World holds the backstop of each prompt a request
  // runs itself, the delayed send keyed by the prompt alone, until the test
  // lets it go or fails it.
  // It records `queued` in `calls` once the queue took the backstop, and
  // `stream` for each stream write.
  const holdingBackstops = (base, calls) => {
    const held = [];
    const cancelStored = barrier();
    let waiting = null;
    const durability = {
      ...base,
      world: async () => {
        const world = await base.world();
        const queue = world.queue.bind(world);
        const write = world.streams.write.bind(world.streams);
        const create = world.events.create.bind(world.events);
        const events = Object.assign(Object.create(world.events), {
          async create(...args) {
            const result = await create(...args);
            const event = args[1];
            const entry = event?.eventType === "step_created" ? JSON.parse(decoder.decode(event.eventData.input)) : null;
            if (entry?.k === "input" && entry.type === "cancel") cancelStored.resolve();
            return result;
          },
        });
        const streams = Object.assign(Object.create(world.streams), {
          write(runId, ...rest) {
            calls.push(["stream", runId]);
            return write(runId, ...rest);
          },
          writeMulti: undefined,
        });
        return Object.assign(Object.create(world), {
          events,
          streams,
          async queue(name, payload, options) {
            const backstop = options?.delaySeconds > 0 && options.idempotencyKey === `${payload.runId}:prompt:${payload.input?.messageId}`;
            if (!backstop) return queue(name, payload, options);
            await new Promise((resolve, reject) => {
              held.push({ release: resolve, fail: reject });
              waiting?.();
            });
            const sent = await queue(name, payload, options);
            calls.push(["queued", payload.runId]);
            return sent;
          },
        });
      },
    };
    const next = async () => {
      while (held.length === 0) await new Promise((resolve) => { waiting = resolve; });
      return held.shift();
    };
    return { durability, next, cancelStored: cancelStored.promise };
  };
  const internals = (agent) => agent[Symbol.for("libfx.durableInternals")];
  const until = async (done, what) => {
    for (let tries = 0; !(await done()); tries += 1) {
      assert.ok(tries < 300, what);
      await sleep(10);
    }
  };
  // What `calls` shows the session's own World calls wrote since `mark`.
  const writesSince = (calls, mark, id) => callsOf(calls.slice(mark), id).filter((name) => name.startsWith("create:") || name === "stream");
  const inRequestAgent = async (dir, options = {}) => {
    const calls = [];
    const { durability: base, broker } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000, ...options });
    const backstops = holdingBackstops(base, calls);
    const durability = countingWorld(backstops.durability, calls);
    return { calls, broker, backstops, durability };
  };
  const backstopOf = (broker, messageId) => broker.sent.filter((message) => message.payload?.input?.messageId === messageId);

  const barrier = () => {
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    return { promise, resolve };
  };
  const bounded = async (promise, what) => {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(what)), 1000);
      })]);
    } finally {
      clearTimeout(timer);
    }
  };

  for (const [outcome, slowOpen] of [["success", true], ["failure", true], ["success", false], ["failure", false]]) {
    test(`same-session concurrency: a backed second prompt finishes before the first backstop's ${outcome} (${slowOpen ? "opening" : "opened"} engine)`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-pending-first-"));
      dirs.push(dir);
      const { calls, broker, backstops, durability } = await inRequestAgent(dir);
      const opening = barrier();
      const releaseOpen = barrier();
      const releaseClose = barrier();
      const lateClosed = barrier();
      let opens = 0;
      let lateCloses = 0;
      const models = [];
      const create = createDurableAgentFactory({
        harness: () => ({
          async open(args) {
            const first = opens++ === 0;
            if (first && slowOpen) {
              opening.resolve();
              await releaseOpen.promise;
            }
            const engine = await scriptedHarness()().open(args);
            if (first && !slowOpen) opening.resolve();
            return {
              ...engine,
              prompt(input, options) {
                models.push(options.turnId);
                return engine.prompt(input, options);
              },
              async close() {
                if (first) await releaseClose.promise;
                await engine.close();
                if (first) { lateCloses += 1; lateClosed.resolve(); }
              },
            };
          },
        }),
        defaultDurability: async () => memory(),
      });
      const agent = create({ durability });
      const session = agent.session();
      const first = session.prompt("pending-first", { messageId: "pending-first" });
      let firstSettled = false;
      void first.accepted.then(() => { firstSettled = true; }, () => { firstSettled = true; });
      const firstSend = await backstops.next();
      let secondSend;
      try {
        await bounded(opening.promise, "first engine did not begin opening");
        const mark = calls.length;
        const second = session.prompt("ready-second", { messageId: "ready-second" });
        secondSend = await bounded(backstops.next(), "second backstop did not start");
        assert.deepEqual(writesSince(calls, mark, session.id), ["create:input"], "only second input stored before its own backstop");
        assert.deepEqual(models, [], "neither prompt reached a model before its own backstop");
        secondSend.release();
        await bounded(second.accepted, "second prompt not accepted");
        assert.equal((await bounded(second.result, "second prompt waited for first backstop")).stopReason, "end_turn");
        assert.deepEqual(models, ["pending-first", "ready-second"], "the backed contender drained stored inputs in canonical log order");
        assert.equal(firstSettled, false, "first acceptance still waits for its own backstop");
        assert.equal(broker.sent.length, 1, "no artificial queue retry for second prompt");
        if (outcome === "failure") {
          firstSend.fail(new Error("first backstop failed"));
          await assert.rejects(first.accepted, /first backstop failed/);
          await assert.rejects(first.result, /first backstop failed/);
        } else {
          firstSend.release();
          await bounded(first.accepted, "first prompt not accepted");
          assert.equal((await bounded(first.result, "first prompt did not resume after its backstop")).stopReason, "end_turn");
        }
        releaseOpen.resolve();
        releaseClose.resolve();
        await bounded(lateClosed.promise, "displaced early opener did not close");
        assert.equal(lateCloses, 1, "displaced engine closed exactly once");
        await bounded(agent.close(), "workers did not stop");
        assert.deepEqual(models, ["pending-first", "ready-second"], "late opener never ran a duplicate");
        assert.equal(lateCloses, 1, "agent close did not close the displaced engine twice");
        const entries = await logEntries(durability, session.id);
        const [contender] = backstopOf(broker, "ready-second");
        assert.deepEqual(entries.find((entry) => entry.k === "lease").delivery, { messageId: contender.id, attempt: 0 }, "the contender's own backstop holds the lease that drained the log");
        for (const id of models) assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.start === id)).length, 1, `${id}: one durable start`);
        assert.equal(internals(agent).liveWorkers(), 0, "no held workers");
      } finally {
        firstSend.release();
        secondSend?.release();
        releaseOpen.resolve();
        releaseClose.resolve();
        await agent.close();
      }
    });
  }

  test("same-session concurrency: a failing concurrent duplicate cannot revoke the original prompt's successful backstop", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-backed-duplicate-"));
    dirs.push(dir);
    const { backstops, durability } = await inRequestAgent(dir);
    const opening = barrier();
    const releaseOpen = barrier();
    const create = createDurableAgentFactory({
      harness: () => ({
        async open(args) {
          opening.resolve();
          await releaseOpen.promise;
          return scriptedHarness()().open(args);
        },
      }),
      defaultDurability: async () => memory(),
    });
    const agent = create({ durability });
    const session = agent.session();
    const mark = prompted.length;
    const first = session.prompt("backed-original", { messageId: "backed-original" });
    const firstSend = await backstops.next();
    let duplicateSend;
    try {
      await bounded(opening.promise, "first engine did not begin opening");
      firstSend.release();
      await bounded(first.accepted, "first backstop did not succeed");
      const duplicate = session.prompt("backed-original", { messageId: "backed-original" });
      duplicateSend = await bounded(backstops.next(), "duplicate backstop did not start");
      duplicateSend.fail(new Error("duplicate backstop failed"));
      await assert.rejects(duplicate.accepted, /duplicate backstop failed/);
      await assert.rejects(duplicate.result, /duplicate backstop failed/);
      releaseOpen.resolve();
      assert.equal((await bounded(first.result, "duplicate failure revoked the backed original")).stopReason, "end_turn");
      await bounded(agent.close(), "duplicate left held work");
      assert.deepEqual(prompted.slice(mark), ["backed-original"], "original started once");
      assert.equal(internals(agent).liveWorkers(), 0);
    } finally {
      firstSend.release();
      duplicateSend?.release();
      releaseOpen.resolve();
      await agent.close();
    }
  });

  // An opener's backstop can succeed in the same turn of the event loop as a
  // backed contender stops it: claim()'s race has then settled on the
  // backstop before stop() rejects giveWay. The opener must give way all the
  // same, or the contender waits out the opener's whole claim, the live claim
  // consume() must never await. Giving way, its engine asks the model
  // nothing, and the next claim, the contender's or the opener's own
  // delivery's, opens another to run both turns. Here the queue takes each
  // backstop before the test holds its answer, so the answers come back over
  // promises alone, the contender's first and the opener's `ticks`
  // microtasks later.
  for (const ticks of [0, 1, 2, 3]) {
    test(`same-session concurrency: an opener whose backstop succeeds as a backed contender stops it still gives way (${ticks} ticks apart)`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-displaced-race-"));
      dirs.push(dir);
      const { durability: base } = await queueWorldAt(dir, { queueLeases: true, runInRequest: true, maxDurationMs: 60_000 });
      const answers = [];
      let waiting = null;
      const durability = {
        ...base,
        world: async () => {
          const world = await base.world();
          const queue = world.queue.bind(world);
          return Object.assign(Object.create(world), {
            async queue(name, payload, options) {
              const sent = await queue(name, payload, options);
              if (options?.delaySeconds > 0 && options.idempotencyKey === `${payload.runId}:prompt:${payload.input?.messageId}`) {
                await new Promise((resolve) => {
                  answers.push(resolve);
                  waiting?.();
                });
              }
              return sent;
            },
          });
        },
      };
      const nextAnswer = async () => {
        while (answers.length === 0) await new Promise((resolve) => { waiting = resolve; });
        return answers.shift();
      };
      const opening = barrier();
      // Each engine opened, in order: the turns it asked the model for, and
      // how many times it closed.
      const engines = [];
      const create = createDurableAgentFactory({
        harness: () => ({
          async open(args) {
            const record = { asked: [], closed: 0 };
            engines.push(record);
            opening.resolve();
            const engine = await scriptedHarness()().open(args);
            return {
              ...engine,
              prompt(input, options) {
                record.asked.push(options.turnId);
                return engine.prompt(input, options);
              },
              async close() {
                await engine.close();
                record.closed += 1;
              },
            };
          },
        }),
        defaultDurability: async () => memory(),
      });
      const agent = create({ durability });
      const session = agent.session();
      const first = session.prompt("racing-opener", { messageId: "racing-opener" });
      const answerFirst = await nextAnswer();
      let answerSecond;
      try {
        await bounded(opening.promise, "the opener did not begin opening its engine");
        const second = session.prompt("racing-contender", { messageId: "racing-contender" });
        answerSecond = await bounded(nextAnswer(), "the contender's backstop was not sent");
        // The contender's handoff holds the log its send read, so it reaches
        // the wait for its own backstop over resolved promises alone.
        await sleep(0);
        answerSecond();
        for (let tick = 0; tick < ticks; tick += 1) await null;
        answerFirst();
        assert.equal((await bounded(second.result, "the contender's prompt did not end")).stopReason, "end_turn");
        assert.equal((await bounded(first.result, "the opener's prompt did not end")).stopReason, "end_turn");
        await bounded(agent.close(), "workers did not stop");
        assert.deepEqual(engines.flatMap((engine) => engine.asked), ["racing-opener", "racing-contender"], "each turn started once, in log order");
        assert.deepEqual(engines[0].asked, [], "the opener gave way: the engine it opened asked the model nothing");
        assert.equal(engines[0].closed, 1, "the opener's engine closed once");
        assert.equal(internals(agent).liveWorkers(), 0, "no held workers");
      } finally {
        answerFirst();
        answerSecond?.();
        await agent.close();
      }
    });
  }

  test("same-session concurrency: a backed later prompt recovers a failed sender's stored input in log order", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-unbacked-retry-"));
    dirs.push(dir);
    const { backstops, durability } = await inRequestAgent(dir);
    const agent = createAgent({ durability });
    const session = agent.session();
    const mark = prompted.length;
    const first = session.prompt("retry-first", { messageId: "retry-first" });
    const firstSend = await backstops.next();
    let secondSend;
    let retrySend;
    try {
      firstSend.fail(new Error("first backstop failed"));
      await assert.rejects(first.accepted, /first backstop failed/);
      await assert.rejects(first.result, /first backstop failed/);
      assert.equal(internals(agent).liveWorkers(), 0, "failure holds no worker");
      const second = session.prompt("retry-second", { messageId: "retry-second" });
      secondSend = await bounded(backstops.next(), "second backstop did not start");
      secondSend.release();
      assert.equal((await bounded(second.result, "second prompt did not finish")).stopReason, "end_turn");
      assert.deepEqual(prompted.slice(mark), ["retry-first", "retry-second"], "later backed delivery recovered the earlier stored input");
      const retry = session.prompt("retry-first", { messageId: "retry-first" });
      retrySend = await bounded(backstops.next(), "retry backstop did not start");
      retrySend.release();
      assert.equal((await bounded(retry.result, "retry did not finish")).stopReason, "end_turn");
      await bounded(agent.close(), "retry left held work");
      assert.deepEqual(prompted.slice(mark), ["retry-first", "retry-second"], "retry did not repeat a recovered input");
      assert.equal(internals(agent).liveWorkers(), 0);
      const entries = await logEntries(durability, session.id);
      assert.equal(entries.filter((entry) => entry.k === "input" && entry.messageId === "retry-first").length, 1, "retry reused the stored input");
    } finally {
      firstSend.release();
      secondSend?.release();
      retrySend?.release();
      await agent.close();
    }
  });

  test("same-session concurrency: an accepted steer recovers a stored prompt after its first send failed", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-failed-steer-"));
    dirs.push(dir);
    const { backstops, durability } = await inRequestAgent(dir);
    const steered = barrier();
    const joins = [];
    const create = createDurableAgentFactory({
      harness: () => ({
        async open(args) {
          const engine = await scriptedHarness()().open(args);
          return {
            ...engine,
            prompt(input, options) {
              const turn = engine.prompt(input, options);
              return {
                ...turn,
                async steer(text, id) {
                  joins.push([options.turnId, id, text]);
                  await args.store.append({ idempotencyKey: `steer:${id}`, data: encoder.encode("{}"), marks: [{ accepted: id }, { placed: id }] });
                  steered.resolve();
                },
              };
            },
          };
        },
      }),
      defaultDurability: async () => memory(),
    });
    const agent = create({ durability });
    const session = agent.session();
    const mark = prompted.length;
    const held = holdStep("failed-steer-0");
    const first = session.prompt("failed-steer", { messageId: "failed-steer" });
    const firstSend = await backstops.next();
    try {
      firstSend.fail(new Error("first backstop failed"));
      await assert.rejects(first.accepted, /first backstop failed/);
      await assert.rejects(first.result, /first backstop failed/);
      assert.equal(internals(agent).liveWorkers(), 0, "failed send holds no worker");
      await session.steer("guidance", { messageId: "recovery-steer" });
      await bounded(steered.promise, "accepted steer was stranded behind a failed sender");
      held.release();
      await bounded(untilIdle(agent), "steer delivery did not finish");
      assert.deepEqual(prompted.slice(mark), ["failed-steer"]);
      assert.deepEqual(joins, [["failed-steer", "recovery-steer", "guidance"]]);
      const entries = await logEntries(durability, session.id);
      assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.start === "failed-steer")).length, 1, "recovered prompt started once");
      assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.end === true)).length, 1, "recovered prompt finished");
      assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.placed === "recovery-steer")).length, 1, "steer placed once");
    } finally {
      firstSend.release();
      held.release();
      await agent.close();
    }
  });

  test("same-session concurrency: local resume discovers a successful remote retry without its matching delivery", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-remote-retry-"));
    dirs.push(dir);
    const { backstops, durability } = await inRequestAgent(dir);
    const agent = createAgent({ durability });
    const session = agent.session();
    const mark = prompted.length;
    const first = session.prompt("remote-retry", { messageId: "remote-retry" });
    const firstSend = await backstops.next();
    const { durability: base, broker } = await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 60_000 });
    // Enqueue-only retry elsewhere. Its queue accepted it, but its matching
    // delivery cannot clear process-local state before this process resumes.
    const remote = createAgent({ durability: {
      ...base,
      world: async () => {
        const instance = await base.world();
        return Object.assign(Object.create(instance), {
          queue: (name, payload, options) => instance.queue(name, payload, { ...options, delaySeconds: 60 }),
        });
      },
    } });
    try {
      firstSend.fail(new Error("first backstop failed"));
      await assert.rejects(first.accepted, /first backstop failed/);
      await assert.rejects(first.result, /first backstop failed/);
      assert.equal(internals(agent).liveWorkers(), 0);
      const retry = remote.session(session.id).prompt("remote-retry", { messageId: "remote-retry" });
      await bounded(retry.accepted, "remote retry was not queued");
      assert.deepEqual(prompted.slice(mark), [], "remote retry has not been delivered");
      const resume = session.resume();
      assert.equal((await bounded(resume.result, "local resume excluded the successful remote retry")).stopReason, "end_turn");
      assert.equal((await bounded(retry.result, "remote retry did not observe recovery")).stopReason, "end_turn");
      await bounded(untilIdle(agent), "resume worker did not stop");
      const [delivery] = broker.sent;
      await bounded(internals(agent).deliver(delivery.payload.input, { messageId: delivery.id, attempt: 1 }), "matching retry delivery did not settle");
      assert.deepEqual(prompted.slice(mark), ["remote-retry"], "late matching delivery did not repeat recovery");
      const entries = await logEntries(durability, session.id);
      assert.equal(entries.filter((entry) => entry.k === "input" && entry.messageId === "remote-retry").length, 1);
      assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.start === "remote-retry")).length, 1);
    } finally {
      firstSend.release();
      await agent.close();
      await remote.close();
    }
  });

  for (const outcome of ["success", "failure", "abort"]) {
    test(`same-session concurrency: three prompts make progress in log order, with first ${outcome} and concurrent duplicates`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-ready-order-"));
      dirs.push(dir);
      const { broker, backstops, durability } = await inRequestAgent(dir);
      const opening = barrier();
      const models = [];
      let activeModels = 0;
      let concurrentModels = 0;
      const create = createDurableAgentFactory({
        harness: () => ({
          async open(args) {
            const engine = await scriptedHarness()().open(args);
            opening.resolve();
            return {
              ...engine,
              prompt(input, options) {
                assert.ok(backstopOf(broker, "order-third").length > 0, "the contender's successful backstop holds the claim that drains the log");
                models.push(options.turnId);
                activeModels += 1;
                if (activeModels > 1) concurrentModels += 1;
                const turn = engine.prompt(input, options);
                const result = turn.result.finally(() => { activeModels -= 1; });
                void result.catch(() => {});
                return { ...turn, result };
              },
            };
          },
        }),
        defaultDurability: async () => memory(),
      });
      const agent = create({ durability });
      const session = agent.session();
      const controller = new AbortController();
      const first = session.prompt("order-first", { messageId: "order-first", signal: controller.signal });
      const firstSend = await backstops.next();
      const thirdStep = holdStep("order-third-0");
      let secondSend;
      let thirdSend;
      try {
        await bounded(opening.promise, "first engine did not open");
        const second = session.prompt("order-second", { messageId: "order-second" });
        secondSend = await bounded(backstops.next(), "second send did not start");
        const third = session.prompt("order-third", { messageId: "order-third" });
        thirdSend = await bounded(backstops.next(), "third send did not start");
        if (outcome === "abort") {
          controller.abort();
          await bounded(backstops.cancelStored, "targeted cancel was not stored");
        }
        thirdSend.release();
        await bounded(thirdStep.holding, "third prompt waited for an unbacked predecessor");
        const expected = outcome === "abort" ? ["order-second", "order-third"] : ["order-first", "order-second", "order-third"];
        assert.deepEqual(models, expected, "stored inputs ran in canonical log order, skipping only the cancelled input");
        const [delivery] = backstopOf(broker, "order-third");
        const duplicates = await bounded(Promise.all(Array.from({ length: 3 }, () => internals(agent).deliver({ type: "prompt", sessionId: session.id, messageId: "order-third", agent: agent.name }, { messageId: delivery.id, attempt: 0 }))), "duplicate deliveries waited on the running turn");
        assert.ok(duplicates.every((result) => result?.timeoutSeconds > 0), "active claims still answer without awaiting their run/turn/steer dependencies");
        thirdStep.release();
        assert.equal((await bounded(third.result, "third prompt did not finish")).stopReason, "end_turn");
        secondSend.release();
        assert.equal((await bounded(second.result, "second prompt starved behind first")).stopReason, "end_turn");
        assert.deepEqual(models, expected, "second sender settling did not repeat work");
        if (outcome === "failure") {
          firstSend.fail(new Error("first backstop failed"));
          await assert.rejects(first.accepted, /first backstop failed/);
          await assert.rejects(first.result, /first backstop failed/);
        } else {
          firstSend.release();
          await bounded(first.accepted, "first prompt not accepted");
          assert.equal((await bounded(first.result, "first prompt starved after its backstop")).stopReason, outcome === "abort" ? "cancelled" : "end_turn");
        }
        await bounded(agent.close(), "workers did not stop");
        assert.deepEqual(models, expected, "each stored input started once, with no late duplicate");
        assert.equal(concurrentModels, 0, "genuine concurrent duplicate model paths remain zero");
        assert.equal(activeModels, 0, "no running model paths left");
        assert.equal(internals(agent).liveWorkers(), 0, "no held workers");
        const entries = await logEntries(durability, session.id);
        if (outcome === "abort") assert.equal(entries.filter((entry) => entry.k === "ended" && entry.messageId === "order-first").length, 1, "aborted prompt ended exactly once");
        for (const id of models) assert.equal(entries.filter((entry) => entry.k === "record" && entry.marks?.some((mark) => mark.start === id)).length, 1, `${id}: one durable start`);
      } finally {
        firstSend.release();
        secondSend?.release();
        thirdSend?.release();
        thirdStep.release();
        await agent.close();
      }
    });
  }

  test("a prompt the request runs opens its engine while its backstop is sent, and writes, shows and asks the model nothing before it is queued", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-engine-"));
    dirs.push(dir);
    const { calls, broker, backstops, durability } = await inRequestAgent(dir);
    const agent = createAgent({ durability });
    const session = agent.session();
    // A new chat's first prompt, and a follow-up.
    for (const input of ["omicron", "pi"]) {
      const messageId = `turn-early-${input}`;
      const openedBefore = opened.count;
      const turn = session.prompt(input, { messageId });
      let accepted = false;
      void turn.accepted.then(() => { accepted = true; }, () => {});
      const send = await backstops.next();
      const mark = calls.length;
      await until(() => opened.count > openedBefore, `${input}: the engine opened while the backstop was sent`);
      await sleep(100);
      assert.deepEqual(writesSince(calls, mark, session.id), [], `${input}: nothing written or shown before the backstop is queued`);
      assert.ok(!prompted.includes(messageId), `${input}: no model request before the backstop is queued`);
      assert.equal(accepted, false, `${input}: not accepted before the backstop is queued`);
      send.release();
      await turn.accepted;
      assert.equal((await turn.result).stopReason, "end_turn");
      const after = callsOf(calls.slice(mark), session.id);
      assert.ok(after.indexOf("queued") >= 0 && after.indexOf("queued") < after.indexOf("create:lease"), `${input}: the lease came after the backstop: ${JSON.stringify(after)}`);
      const [backstop, ...more] = backstopOf(broker, messageId);
      assert.equal(more.length, 0);
      assert.deepEqual((await internals(agent).lastLease(session.id)).delivery, { messageId: backstop.id, attempt: 0 }, `${input}: the lease names the backstop`);
      await untilIdle(agent);
    }
    await agent.close();
  });

  test("a prompt whose backstop fails rejects with nothing its early worker did stored or shown, and its retry is stored once and runs once in its request", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-unqueued-"));
    dirs.push(dir);
    const { calls, broker, backstops, durability } = await inRequestAgent(dir);
    const errors = [];
    const agent = createAgent({ durability, onEvent: (event) => { if (event.type === "session.error") errors.push(event); } });
    const session = agent.session();
    const messageId = "turn-unqueued";
    // An engine that takes a while to close, so a retry would find a worker
    // that had not stopped yet.
    closeDelay.ms = 200;
    try {
      const openedBefore = opened.count;
      const turn = session.prompt("rho", { messageId });
      const send = await backstops.next();
      const mark = calls.length;
      await until(() => opened.count > openedBefore, "the engine opened while the backstop was sent");
      send.fail(Object.assign(new Error("injected backstop failure"), { status: 503 }));
      await assert.rejects(turn.accepted, /injected backstop failure/);
      await assert.rejects(turn.result, /injected backstop failure/);
      assert.equal(internals(agent).liveWorkers(), 0, "the early worker stopped before the prompt failed");
      assert.deepEqual(writesSince(calls, mark, session.id), [], "nothing written or shown after the input");
      assert.ok(!prompted.includes(messageId), "no model request");
      assert.deepEqual(errors, [], "the prompt's failure is its caller's, not a session error");
      assert.deepEqual((await logEntries(durability, session.id)).map((entry) => entry.k), ["input"]);
      assert.equal(await (await internals(agent).openLog(session.id)).ui.length(), 0, "the stream holds no line");
      // The retry stores nothing again and runs the turn in its request, once.
      const ranBefore = ran.length;
      const retry = session.prompt("rho", { messageId });
      (await backstops.next()).release();
      await retry.accepted;
      assert.equal((await retry.result).stopReason, "end_turn");
      await untilIdle(agent);
      assert.deepEqual(ran.slice(ranBefore).filter((step) => step.startsWith(`${messageId}:`)), [0, 1, 2].map((step) => `${messageId}:${step}`), "it ran once");
      const entries = await logEntries(durability, session.id);
      assert.equal(entries.filter((entry) => entry.k === "input").length, 1, "the input is stored once");
      assert.equal(entries.filter((entry) => entry.k === "lease").length, 1, "one claim");
      const sent = backstopOf(broker, messageId);
      assert.equal(sent.length, 1, "only the retry's backstop reached the queue, and nothing went on later");
      assert.deepEqual(entries.find((entry) => entry.k === "lease").delivery, { messageId: sent[0].id, attempt: 0 });
      // A follow-up that finds its session running here starts nothing
      // early, so it waits for its backstop, and one that failed sends
      // nothing more.
      const busy = holdStep("upsilon-1");
      const running = session.prompt("upsilon", { messageId: "turn-busy" });
      (await backstops.next()).release();
      await busy.holding;
      const queues = () => callsOf(calls, session.id).filter((name) => name === "queue").length;
      const queuedBefore = queues();
      const follow = session.prompt("phi", { messageId: "turn-follow" });
      (await backstops.next()).fail(new Error("injected backstop failure"));
      await assert.rejects(follow.accepted, /injected backstop failure/);
      assert.equal(queues(), queuedBefore + 1, "nothing was queued after the failed backstop");
      busy.release();
      assert.equal((await running.result).stopReason, "end_turn");
      await untilIdle(agent);
    } finally {
      closeDelay.ms = 0;
    }
    await agent.close();
  });

  test("a prompt whose backstop fails while its engine is still opening rejects at once, and the engine closes once it opens", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-slow-open-"));
    dirs.push(dir);
    const { calls, backstops, durability } = await inRequestAgent(dir);
    const agent = createAgent({ durability });
    const session = agent.session();
    const messageId = "turn-slow-open";
    let letOpen = () => {};
    openHold.until = new Promise((resolve) => { letOpen = resolve; });
    try {
      const openedBefore = opened.count;
      const turn = session.prompt("chi", { messageId });
      const send = await backstops.next();
      const mark = calls.length;
      await until(() => opened.count > openedBefore, "the engine began to open while the backstop was sent");
      const closedBefore = closed.count;
      send.fail(new Error("injected backstop failure"));
      // The open is still held, so only a rejection that does not wait for
      // it comes in time.
      const outcome = await Promise.race([turn.accepted.then(() => "accepted", (error) => error), sleep(200).then(() => "still waiting")]);
      assert.match(String(outcome?.message ?? outcome), /injected backstop failure/, "rejected within 200 ms, while the engine was still opening");
      await assert.rejects(turn.result, /injected backstop failure/);
      assert.equal(internals(agent).liveWorkers(), 0, "the worker stopped before the prompt failed");
      assert.deepEqual(writesSince(calls, mark, session.id), [], "nothing written or shown after the input");
      assert.ok(!prompted.includes(messageId), "no model request");
      assert.deepEqual((await logEntries(durability, session.id)).map((entry) => entry.k), ["input"]);
      assert.equal(closed.count, closedBefore, "the engine has not opened yet");
      // The agent's close() waits for the late engine, which closes once it
      // opens.
      openHold.until = null;
      letOpen();
      await agent.close();
      assert.equal(closed.count, closedBefore + 1, "the late engine closed");
    } finally {
      openHold.until = null;
      letOpen();
    }
  });

  test("a prompt to another agent's session whose backstop fails rejects, and is not sent on to that agent", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-forward-"));
    dirs.push(dir);
    const { broker, backstops, durability } = await inRequestAgent(dir);
    const support = createTaggedAgent({ durability, name: "support", tag: "support" });
    const coding = createTaggedAgent({ durability, name: "coding", tag: "coding" });
    const session = support.session();
    const first = session.prompt("psi", { messageId: "turn-owned" });
    (await backstops.next()).release();
    assert.equal((await first.result).stopReason, "end_turn");
    await untilIdle(support);
    const turn = coding.session(session.id).prompt("omega", { messageId: "turn-forward-unqueued" });
    const send = await backstops.next();
    // Time for a worker that does not wait for the backstop to send it on.
    await sleep(100);
    send.fail(new Error("injected backstop failure"));
    await assert.rejects(turn.accepted, /injected backstop failure/);
    await assert.rejects(turn.result, /injected backstop failure/);
    assert.deepEqual(broker.sent.filter((message) => message.key?.endsWith(":to:support")).map((message) => message.key), [], "nothing was sent on to support");
    await support.close();
    await coding.close();
  });

  test("a backed cancel displaces a pending opener and ends the stored prompt once without a model request", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-abort-"));
    dirs.push(dir);
    const { broker, backstops, durability } = await inRequestAgent(dir);
    const agent = createAgent({ durability });
    const session = agent.session();
    const messageId = "turn-early-abort";
    const controller = new AbortController();
    const openedBefore = opened.count;
    const turn = session.prompt("sigma", { messageId, signal: controller.signal });
    let accepted = false;
    void turn.accepted.then(() => { accepted = true; }, () => {});
    const send = await backstops.next();
    try {
      await until(() => opened.count > openedBefore, "the engine opened while the backstop was sent");
      controller.abort();
      await until(async () => (await logEntries(durability, session.id)).some((entry) => entry.k === "ended" && entry.messageId === messageId), "the backed cancel did not finish the stored prompt");
      const lines = await bounded(readLines(session.stream(0), 1), "cancel outcome was not shown before the prompt's backstop");
      assert.deepEqual(lines.map((line) => line.stopReason), ["cancelled"]);
      assert.equal(accepted, false, "prompt acceptance still waits for its own send");
      assert.ok(!prompted.includes(messageId), "cancelled input made no model request");
      send.release();
      await turn.accepted;
      assert.equal((await bounded(turn.result, "cancelled prompt viewer did not settle")).stopReason, "cancelled");
      await untilIdle(agent);
      const allLines = await readLines(session.stream(0), 32);
      assert.deepEqual(allLines.filter((line) => line.type === "turn_end").map((line) => line.stopReason), ["cancelled"], "the turn ended once, cancelled");
      const entries = await logEntries(durability, session.id);
      assert.equal(entries.filter((entry) => entry.k === "input" && entry.type === "prompt").length, 1);
      const cancel = broker.sent.find((message) => message.payload?.input?.type === "cancel");
      assert.deepEqual(entries.find((entry) => entry.k === "lease").delivery, { messageId: cancel.id, attempt: 1 }, "the cancel's successful delivery holds the recovery lease");
    } finally {
      send.release();
      await agent.close();
    }
  });

  test("an early-opened request's lease names its backstop, whose delivery takes the turn over once the request's process died", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-early-recover-"));
    dirs.push(dir);
    const { calls, broker, backstops, durability } = await inRequestAgent(dir, { maxDurationMs: 600_000 });
    const fenced = [];
    const first = createAgent({ durability, onEvent: (event) => { if (event.type === "session.fenced") fenced.push(event); } });
    // Another process on the same store, whose queue hands it the backstop.
    const { durability: elsewhere, broker: theirs } = await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000 });
    const second = createAgent({ durability: elsewhere });
    await second.newSessionId();
    const messageId = "turn-early-recover";
    const held = holdStep("tau-1");
    const session = first.session();
    const openedBefore = opened.count;
    const before = ran.length;
    const turn = session.prompt("tau", { messageId });
    const send = await backstops.next();
    const mark = calls.length;
    await until(() => opened.count > openedBefore, "the engine opened while the backstop was sent");
    assert.deepEqual(writesSince(calls, mark, session.id), [], "no lease before the backstop is queued");
    send.release();
    await held.holding;
    const [backstop] = backstopOf(broker, messageId);
    assert.deepEqual((await internals(first).lastLease(session.id)).delivery, { messageId: backstop.id, attempt: 0 }, "the lease names the backstop");
    // The request's process dies mid-step; the queue hands the backstop on.
    const holders = globalThis[Symbol.for("libfx.liveHolders")];
    for (const holder of [...holders]) holders.delete(holder);
    holds.delete("tau-1");
    theirs.adopt(backstop);
    await until(() => ran.slice(before).filter((step) => step.startsWith(`${messageId}:`)).length === 3, "the backstop's delivery continued the turn");
    assert.deepEqual(ran.slice(before).filter((step) => step.startsWith(`${messageId}:`)), [0, 1, 2].map((step) => `${messageId}:${step}`), "each step ran once");
    held.release();
    await turn.result.catch(() => {});
    await until(() => fenced.length > 0, "the replaced worker stopped at its next write");
    const lines = await readLines(second.session(session.id).stream(0), 32);
    assert.equal(lines.filter((line) => line.type === "turn_end").length, 1, "the turn ended once");
    for (const closing of [first, second]) await closing.close();
  });
}

let failed = 0;
for (const [name, fn] of tests) {
  const started = performance.now();
  try {
    let timer;
    await Promise.race([fn(), new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("timed out after 30s")), 30_000); })]).finally(() => clearTimeout(timer));
    console.log(`ok ${name} (${(performance.now() - started).toFixed(0)}ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n  ${error?.stack ?? error}`);
  }
}
await closeAppWorlds?.();
await closeQueueWorlds?.();
for (const dir of dirs) await rm(dir, { recursive: true, force: true }).catch(() => {});
console.log(`${tests.length - failed}/${tests.length} core tests passed (${durabilityKind})`);
process.exit(failed ? 1 : 0);
