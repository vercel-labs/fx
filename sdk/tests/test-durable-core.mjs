// The durable core with a harness that is not fx: a scripted agent whose
// turns are a few steps, each stored as one record. It shows the contract
// `createDurableAgentFactory` documents is all a harness needs, and is the
// smallest example of one.
//
//   node sdk/tests/test-durable-core.mjs [memory|local|world|queue]
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDurableAgentFactory, foldSessionLog, memory, wakeHandler } from "../durable.js";
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
// How many engines the scripted harness opened, and how long each takes to
// close.
const opened = { count: 0 };
const closeDelay = { ms: 0 };
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
