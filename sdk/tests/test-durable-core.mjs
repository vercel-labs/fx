// The durable core with a harness that is not fx: a scripted agent whose
// turns are a few steps, each stored as one record. It shows the contract
// `createDurableAgentFactory` documents is all a harness needs, and is the
// smallest example of one.
//
//   node sdk/tests/test-durable-core.mjs [memory|local|world|queue]
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
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
// Inputs whose end records say only that the turn ended, not how, as an
// earlier libfx wrote them. Every other end mark says how (DUR-20).
const unsaidEnds = new Set();
// Inputs whose turn's last step streams a reply, these events, before the
// record that ends the turn, whose end mark carries the reply's text, as
// fx's does.
const answers = new Map();
// Inputs in `answers` whose reply is saved in a record of its own before the
// record that ends the turn, as fx saves it: a resume after that record ends
// the turn with the saved reply, asking no model and streaming none of it,
// as fx's engine does in a session whose stream already holds it.
const savesReply = new Set();
// Inputs in `savesReply` whose resume restarts the saved reply instead of
// ending the turn with it, as fx's engine does when the resume brings inputs
// the saved reply never saw: it shows `restartNotice` as a text line, as fx
// does when it restarts an answer, then streams the reply again.
const restarts = new Set();
const restartNotice = "\n\n[Response interrupted. Restarting.]\n\n";
// Inputs in `answers` whose engine, cancelled once the record that ends its
// turn is on its way, drops the rest of its reply and answers cancelled, as
// fx's engine did before it followed that record.
const lateCancels = new Set();
const replyOf = (input) => answers.get(input).filter((event) => event.type === "text_delta").map((event) => event.delta).join("");
const endMarks = (input, stopReason) => [unsaidEnds.has(input) ? { end: true }
  : { end: true, stopReason, ...(answers.has(input) && stopReason === "end_turn" ? { reply: replyOf(input) } : {}) }];
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
          if (signal.aborted && !handedOff && error?.code !== "FX_HARNESS_STOPPED") await append({ turnId, end: true }, endMarks(input, "cancelled")).catch(() => {});
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
        if (records.some((record) => record.turnId === turnId && record.saved)) {
          if (restarts.has(input)) {
            push({ type: "text_delta", delta: restartNotice });
            for (const event of answers.get(input)) push(event);
          }
          await append({ turnId, end: true }, endMarks(input, "end_turn"));
          return { stopReason: "end_turn" };
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
          if (last && answers.has(input)) {
            const reply = answers.get(input);
            const late = lateCancels.has(input);
            for (const event of late ? reply.slice(0, 1) : reply) push(event);
            if (savesReply.has(input)) {
              await append({ turnId, step, word, saved: true }, []);
              await append({ turnId, end: true }, endMarks(input, "end_turn"));
            } else {
              await append({ turnId, step, word, end: true }, endMarks(input, "end_turn"));
            }
            if (late) {
              if (signal.aborted) return { stopReason: "cancelled" };
              for (const event of reply.slice(1)) push(event);
            }
            continue;
          }
          if (last && endsLate.delete(input)) {
            // The end record is still on its way when the engine stops.
            const write = sleep(150).then(() => append({ turnId, step, word, end: true }, endMarks(input, "end_turn")));
            landing.add(write);
            push({ type: "text_delta", delta: `${word} ` });
            throw harnessStopped("the engine exited as the turn ended");
          }
          await append({ turnId, step, word, ...(last ? { end: true } : {}) }, last ? endMarks(input, "end_turn") : []);
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
// Agents whose turns are one step: the reply of an input in `answers`.
const createAnsweringAgent = createDurableAgentFactory({ harness: scriptedHarness({ steps: 1 }), defaultDurability: async () => memory(), name: "createScriptedAgent" });

// Agents that record which of them opened each session's engine, by `tag`.
const openedBy = [];
const taggedHarness = ({ tag }) => {
  const plugged = scriptedHarness()();
  return { open: (args) => { openedBy.push([tag, args.sessionId]); return plugged.open(args); } };
};
const createTaggedAgent = createDurableAgentFactory({ harness: taggedHarness, defaultDurability: async () => memory(), name: "createTaggedAgent" });
// The same, as a factory whose process is a development server.
const createDevTaggedAgent = createDurableAgentFactory({ harness: taggedHarness, defaultDurability: async () => memory(), development: () => true, name: "createTaggedAgent" });
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

  // Vercel's World answers a process without a deployment's credentials with
  // a bare "Unauthorized". Here a local server answers as it does.
  test("vercel() without a deployment's credentials refuses a prompt saying what it needs", async () => {
    const server = createServer((request, response) => {
      request.resume();
      response.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ code: "unauthorized", message: "Unauthorized" }));
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const saved = { url: process.env.VERCEL_WORKFLOW_SERVER_URL, token: process.env.VERCEL_OIDC_TOKEN };
    process.env.VERCEL_WORKFLOW_SERVER_URL = `http://127.0.0.1:${server.address().port}`;
    delete process.env.VERCEL_OIDC_TOKEN;
    try {
      const { vercel } = await import("../durable/vercel.mjs");
      const agent = createAgent({ durability: vercel(), name: "outside-vercel" });
      const refused = await agent.session().prompt("alpha").accepted.then(() => null, (error) => error);
      assert.ok(refused, "the prompt is refused");
      assert.match(refused.message, /vercel\(\) keeps sessions in a Vercel project and needs a deployment's credentials/);
      assert.match(refused.message, /set VERCEL_OIDC_TOKEN/);
      assert.equal(refused.code, "unauthorized");
      assert.equal(refused.status, 401);
      assert.equal(refused.cause?.name, "WorkflowWorldError");
      await agent.close();
    } finally {
      for (const [key, value] of [["VERCEL_WORKFLOW_SERVER_URL", saved.url], ["VERCEL_OIDC_TOKEN", saved.token]]) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      server.close();
    }
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

test("a turn whose engine stops after its end landed still ends for its viewers, as its end says (DUR-20)", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const { text, result } = await textOf(session.prompt("omega", { messageId: "turn-omega" }));
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "omega-0 omega-1 omega-2");
  assert.equal((await session.prompt("after", { messageId: "turn-after" }).result).stopReason, "end_turn");
  // An end an earlier libfx wrote says only that the turn ended.
  stopsAfterEnd.add("omega-elder");
  unsaidEnds.add("omega-elder");
  assert.equal((await session.prompt("omega-elder", { messageId: "turn-omega-elder" }).result).stopReason, "unknown");
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

test("a turn whose end is still landing when its engine stops ends as that end says", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  const { text, result } = await textOf(session.prompt("late", { messageId: "turn-late" }));
  assert.equal(result.stopReason, "end_turn");
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

test("opening a session starts no durability until the session is used", async () => {
  // How often the agent created its durability's backend or World.
  const counts = { started: 0 };
  const base = await durabilityFor();
  const durability = typeof base.create === "function"
    ? { ...base, create() { counts.started += 1; return base.create(); } }
    : { ...base, async world() { counts.started += 1; return base.world(); } };
  const agent = createAgent({ durability });
  const fresh = agent.session();
  const named = agent.session("wrun_01JRCOREOPENNOIO00000");
  await sleep(100);
  assert.equal(counts.started, 0, "API-12, API-31: createAgent() and session() did no I/O");
  assert.equal(fresh.id, null, "a new session has no id before it is used");
  assert.equal(named.id, "wrun_01JRCOREOPENNOIO00000");
  assert.equal((await fresh.prompt("alpha", { messageId: "turn-a" }).result).stopReason, "end_turn");
  assert.equal(counts.started, 1, "the first prompt started the durability, once");
  assert.ok(typeof fresh.id === "string", "and gave the new session its id");
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

test("a session id its durability can't hold throws from session() at once, with a code", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const invalid = (pattern) => (error) => error instanceof TypeError && error.code === "FX_SESSION_ID_INVALID" && pattern.test(error.message);
  assert.throws(() => agent.session("bad id"), invalid(/session id must be/));
  if (durabilityKind === "memory") assert.equal(agent.session("my-chat").id, "my-chat");
  else assert.throws(() => agent.session("my-chat"), invalid(/^session id "my-chat" is not a Workflow run id .* the only id (local|app|queue)\(\) holds/));
  // One whose factory's default durability is a World, as Node's is, knows
  // so before that durability is chosen.
  const worldDefault = createDurableAgentFactory({ harness: scriptedHarness(), defaultDurability: async () => { throw new Error("no durability is chosen"); }, defaultWorld: true, name: "createWorldAgent" })({ name: "world-default" });
  assert.throws(() => worldDefault.session("my-chat"), invalid(/the only id the default durability holds/));
  assert.equal(worldDefault.session("wrun_01JRCOREOPENNOIO00000").id, "wrun_01JRCOREOPENNOIO00000");
  await worldDefault.close();
  await agent.close();
});

test("a session's steer() and cancel() after its agent closed reject as prompt() throws", async () => {
  const agent = createAgent({ durability: await durabilityFor() });
  const session = agent.session();
  assert.equal((await session.prompt("alpha").result).stopReason, "end_turn");
  await agent.close();
  assert.throws(() => session.prompt("after"), /agent is closed/);
  await assert.rejects(session.steer("after"), /agent is closed/);
  await assert.rejects(session.cancel(), /agent is closed/);
});

if (durabilityKind === "memory") {
  test("memory() holds a message no agent listens for, with no timer, and delivers it to the next one", async () => {
    // A process whose agents all closed exits by itself after a send.
    const script = `import { memory } from ${JSON.stringify(new URL("../durable.js", import.meta.url).href)};\n` +
      "await memory().create().queue.send({ type: \"cancel\", messageId: \"cnl-1\", sessionId: \"s\", agent: \"default\" });";
    const child = spawnSync(process.execPath, ["--input-type=module", "-e", script], { timeout: 5000, encoding: "utf8" });
    assert.equal(child.signal, null, `the process exited by itself: ${child.stderr}`);
    assert.equal(child.status, 0, child.stderr);
    const backend = memory().create();
    await backend.queue.send({ type: "cancel", messageId: "cnl-2", sessionId: "s", agent: "default" });
    await sleep(50);
    const seen = [];
    const unlisten = backend.listen((message) => { seen.push(message.messageId); });
    await sleep(50);
    assert.deepEqual(seen, ["cnl-2"]);
    unlisten();
  });
}

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

// memory(), with a worker that dies right after the record that ends its
// turn while `dies.now` is set: its turn_end lines never land, nor any line
// `dies.lost(line)` names, and it never lets the session go.
function dyingAfterEnd(base, dies) {
  let wrapped = null;
  const isEnd = (line) => {
    try {
      const event = JSON.parse(line);
      return event.type === "turn_end" || dies.lost?.(event) === true;
    } catch {
      return false;
    }
  };
  return {
    ...base,
    create() {
      const backend = base.create();
      wrapped ??= Object.assign(Object.create(backend), {
        async session(id) {
          const log = await backend.session(id);
          return {
            ...log,
            ui: { ...log.ui, write: (lines) => log.ui.write(dies.now ? lines.filter((line) => !isEnd(line)) : lines) },
            append: (entry) => (dies.now && entry?.k === "release" ? Promise.reject(new Error("the process died")) : log.append(entry)),
          };
        },
      });
      return wrapped;
    },
  };
}

if (durabilityKind === "memory") {
  test("a turn whose worker died between its end and its turn_end line ends for its viewers when the session is next delivered", async () => {
    const dies = { now: true };
    const durability = dyingAfterEnd(memory(), dies);
    const agent = createAgent({ durability });
    const session = agent.session();
    const first = session.prompt("alpha", { messageId: "turn-a" });
    const { sessionId } = await first.accepted;
    // The log holds the turn's end; the stream never heard it.
    const log = await durability.create().session(sessionId);
    const ended = async () => foldSessionLog(await log.read()).lastTurnId === "turn-a";
    while (!(await ended())) await sleep(10);
    await sleep(landMs);
    dies.now = false;
    let timer;
    const retried = await Promise.race([
      session.prompt("alpha", { messageId: "turn-a" }).result,
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("the retry waited for an end nobody writes")), 5000); }),
    ]).finally(() => clearTimeout(timer));
    // The record that ended it says how (DUR-20, `tests/tla/sdk/DurableSession.tla`
    // EndLine, EndSaysHow).
    assert.equal(retried.stopReason, "end_turn");
    assert.equal((await first.result).stopReason, "end_turn");
    const lines = await readLines(session.stream(0), 100);
    const ends = lines.filter((line) => line.type === "turn_end" && line.messageId === "turn-a");
    assert.deepEqual(ends.map((line) => line.stopReason), ["end_turn"]);
    assert.equal((await session.prompt("after", { messageId: "turn-after" }).result).stopReason, "end_turn");
    await agent.close();
  });

  test("a turn an earlier libfx ended, whose worker died before its turn_end line, ends for its viewers as unknown", async () => {
    const dies = { now: true };
    const durability = dyingAfterEnd(memory(), dies);
    const agent = createAgent({ durability });
    const session = agent.session();
    unsaidEnds.add("elder");
    const first = session.prompt("elder", { messageId: "turn-elder" });
    const { sessionId } = await first.accepted;
    const log = await durability.create().session(sessionId);
    while (foldSessionLog(await log.read()).lastTurnId !== "turn-elder") await sleep(10);
    await sleep(landMs);
    dies.now = false;
    // Its record does not say how it ended.
    assert.equal((await session.prompt("elder", { messageId: "turn-elder" }).result).stopReason, "unknown");
    assert.equal((await first.result).stopReason, "unknown");
    await agent.close();
  });

  // DUR-20, DUR-38, DUR-64: the record that ends a turn carries its reply,
  // so the worker that writes the end a crashed holder left missing first
  // shows the part of the reply that holder's lines never did, once, and
  // nothing a reader already has (`tests/tla/sdk/DurableSession.tla`
  // ReplyShownOnce).
  for (const [shown, lost, rest] of [
    ["part of its reply", (event) => event.type === "text_delta" && event.delta !== "one ", "two three "],
    ["none of its reply", (event) => event.type === "text_delta", "one two three "],
    ["its whole reply", () => false, null],
  ]) {
    test(`a turn whose worker died after its end, having shown ${shown}, shows the rest of the reply once before its end`, async () => {
      answers.set("answer", [{ type: "reasoning_delta", delta: "hm" }, { type: "text_delta", delta: "one " }, { type: "text_delta", delta: "two " }, { type: "text_delta", delta: "three " }]);
      const dies = { now: true, lost };
      const durability = dyingAfterEnd(memory(), dies);
      const agent = createAnsweringAgent({ durability });
      const session = agent.session();
      const first = session.prompt("answer", { messageId: "turn-answer" });
      const { sessionId } = await first.accepted;
      const log = await durability.create().session(sessionId);
      while (foldSessionLog(await log.read()).lastTurnId !== "turn-answer") await sleep(10);
      await sleep(landMs);
      dies.now = false;
      let timer;
      const retried = await Promise.race([
        session.prompt("answer", { messageId: "turn-answer" }).result,
        new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("the retry waited for an end nobody writes")), 5000); }),
      ]).finally(() => clearTimeout(timer));
      assert.equal(retried.stopReason, "end_turn");
      const lines = (await readLines(session.stream(0), 100)).filter((line) => line.messageId === "turn-answer");
      const dead = lines.filter((line) => line.epoch === 1).map((line) => [line.type, line.delta ?? null]);
      assert.deepEqual(lines.filter((line) => line.epoch !== 1).map((line) => [line.type, line.delta ?? null]), [
        ...(rest === null ? [] : [["text_delta", rest]]),
        ["turn_end", null],
      ], `after the dead worker's ${JSON.stringify(dead)}`);
      const text = lines.filter((line) => line.type === "text_delta").map((line) => line.delta).join("");
      assert.equal(text, "one two three ", "the reply once and whole");
      // The first prompt's view follows the stream, so it reads that too.
      assert.equal((await textOf(first)).text, "one two three");
      answers.delete("answer");
      await agent.close();
    });
  }

  // memory() over `base`, with a worker that dies right after the record
  // that saves its turn's reply, before the record that ends the turn, while
  // `dies.armed` is set: from that record until the test sets `dies.dead`
  // back no write but a sender's input lands. Its turn_end lines never land,
  // nor any line `dies.lost(line)` names; its text lines still on their way
  // when the record landed do.
  const dyingAfterSave = (base, dies) => {
    let wrapped = null;
    const saves = (entry) => entry?.k === "record" && JSON.parse(Buffer.from(entry.data, "base64").toString("utf8")).saved === true;
    const shown = (line) => {
      try {
        const event = JSON.parse(line);
        return event.type !== "turn_end" && dies.lost?.(event) !== true;
      } catch {
        return true;
      }
    };
    return {
      ...base,
      create() {
        const backend = base.create();
        wrapped ??= Object.assign(Object.create(backend), {
          async session(id) {
            const log = await backend.session(id);
            return {
              ...log,
              ui: { ...log.ui, write: (lines) => log.ui.write(dies.armed || dies.dead ? lines.filter(shown) : lines) },
              async append(entry) {
                if (dies.dead && entry?.k !== "input") throw new Error("the process died");
                const appended = await log.append(entry);
                if (dies.armed && saves(entry)) {
                  dies.armed = false;
                  dies.dead = true;
                }
                return appended;
              },
            };
          },
        });
        return wrapped;
      },
    };
  };
  const within = (promise, what) => {
    let timer;
    return Promise.race([promise, new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error(what)), 5000); })]).finally(() => clearTimeout(timer));
  };
  const linesOf = async (session, messageId) => (await readLines(session.stream(0), 100)).filter((line) => line.messageId === messageId).map((line) => [line.epoch, line.type, line.delta ?? null]);
  const replyText = (lines) => lines.filter(([, type]) => type === "text_delta").map(([, , delta]) => delta).join("");

  // DUR-20, DUR-38: a worker that resumes a turn whose reply was saved before
  // its end was stored ends it with that reply, asking the model nothing, and
  // streams none of it. So it first shows the part of the reply the dead
  // worker's lines never did, once (`tests/tla/sdk/DurableSession.tla`
  // Commit with ResumeFills, ReplyShownOnceUnlessLate).
  for (const [shown, lost, rest] of [
    ["part of its reply", (event) => event.type === "text_delta" && event.delta !== "one ", "two three "],
    ["none of its reply", (event) => event.type === "text_delta", "one two three "],
    ["its whole reply", () => false, null],
  ]) {
    test(`a turn whose worker died after saving its reply, having shown ${shown}, ends with that reply on resume and shows its rest once`, async () => {
      answers.set("saved", [{ type: "reasoning_delta", delta: "hm" }, { type: "text_delta", delta: "one " }, { type: "text_delta", delta: "two " }, { type: "text_delta", delta: "three " }]);
      savesReply.add("saved");
      const dies = { armed: true, dead: false, lost };
      const durability = dyingAfterSave(memory(), dies);
      const agent = createAnsweringAgent({ durability });
      const session = agent.session();
      const first = session.prompt("saved", { messageId: "turn-saved" });
      await first.accepted;
      while (!dies.dead) await sleep(10);
      // A dead worker never lets the session go: it stays dead until its run is over.
      while (agent[Symbol.for("libfx.durableInternals")].liveWorkers() > 0) await sleep(10);
      dies.dead = false;
      const steps = ran.length;
      const retried = await within(session.prompt("saved", { messageId: "turn-saved" }).result, "the retry waited for an end nobody writes");
      assert.equal(retried.stopReason, "end_turn");
      assert.equal(ran.length, steps, "the resume ran no step: the saved reply ends the turn");
      const lines = await linesOf(session, "turn-saved");
      assert.deepEqual(lines.filter(([epoch]) => epoch !== 1).map(([, type, delta]) => [type, delta]), [
        ["turn_resume", null],
        ...(rest === null ? [] : [["text_delta", rest]]),
        ["turn_end", null],
      ], `after the dead worker's ${JSON.stringify(lines.filter(([epoch]) => epoch === 1))}`);
      assert.equal(replyText(lines), "one two three ", "the reply once and whole");
      assert.equal((await textOf(first)).text, "one two three");
      answers.delete("saved");
      savesReply.delete("saved");
      await agent.close();
    });
  }

  // The worker that ended such a turn with its saved reply can die before
  // its turn_end line too. The worker that writes that end reads the turn's
  // text across the resumed worker's turn_resume line, so it shows only what
  // neither worker's lines did (`tests/tla/sdk/DurableSession.tla` Unshown).
  for (const [label, lostAfter, rest] of [
    ["having shown the rest of the reply", () => false, null],
    ["before the rest of the reply landed", (event) => event.type === "text_delta", "two three "],
  ]) {
    test(`a turn ended with its saved reply whose worker died ${label} shows the reply once when the session is next delivered`, async () => {
      answers.set("saved twice", [{ type: "text_delta", delta: "one " }, { type: "text_delta", delta: "two " }, { type: "text_delta", delta: "three " }]);
      savesReply.add("saved twice");
      const late = { now: false, lost: lostAfter };
      const dies = { armed: true, dead: false, lost: (event) => event.type === "text_delta" && event.delta !== "one " };
      const durability = dyingAfterSave(dyingAfterEnd(memory(), late), dies);
      const agent = createAnsweringAgent({ durability });
      const internals = agent[Symbol.for("libfx.durableInternals")];
      const session = agent.session();
      const first = session.prompt("saved twice", { messageId: "turn-twice" });
      const { sessionId } = await first.accepted;
      while (!dies.dead) await sleep(10);
      while (internals.liveWorkers() > 0) await sleep(10);
      dies.dead = false;
      // The resuming worker ends the turn with the saved reply, then dies.
      late.now = true;
      void session.prompt("saved twice", { messageId: "turn-twice" }).result.catch(() => {});
      const log = await durability.create().session(sessionId);
      while (foldSessionLog(await log.read()).lastTurnId !== "turn-twice") await sleep(10);
      await sleep(landMs);
      while (internals.liveWorkers() > 0) await sleep(10);
      late.now = false;
      const steps = ran.length;
      const retried = await within(session.prompt("saved twice", { messageId: "turn-twice" }).result, "the retry waited for an end nobody writes");
      assert.equal(retried.stopReason, "end_turn");
      assert.equal(ran.length, steps);
      const lines = await linesOf(session, "turn-twice");
      assert.deepEqual(lines.filter(([epoch]) => epoch > 2).map(([, type, delta]) => [type, delta]), [
        ...(rest === null ? [] : [["text_delta", rest]]),
        ["turn_end", null],
      ], `after ${JSON.stringify(lines.filter(([epoch]) => epoch <= 2))}`);
      assert.equal(replyText(lines), "one two three ", "the reply once and whole");
      assert.equal(lines.filter(([, type]) => type === "turn_end").length, 1);
      answers.delete("saved twice");
      savesReply.delete("saved twice");
      await agent.close();
    });
  }

  // DUR-38: a resume that restarts a saved reply shows the restart notice as
  // a text line, then the reply again, so the turn's text ends with the dead
  // worker's start of the reply, that notice and the resumed worker's start
  // of it. When that worker dies after the record that ends the turn, the
  // worker that writes the end shows only what of that reply the resumed
  // worker's lines never did, once (`tests/tla/sdk/DurableSession.tla`
  // Unshown, with Restarts).
  test("a turn whose resume restarted its saved reply, and whose worker then died after its end, shows that reply once after the restart", async () => {
    answers.set("restarted", [{ type: "text_delta", delta: "one " }, { type: "text_delta", delta: "two " }, { type: "text_delta", delta: "three " }]);
    savesReply.add("restarted");
    restarts.add("restarted");
    const late = { now: false, lost: (event) => event.type === "text_delta" && (event.delta === "two " || event.delta === "three ") };
    const dies = { armed: true, dead: false, lost: (event) => event.type === "text_delta" && event.delta !== "one " };
    const durability = dyingAfterSave(dyingAfterEnd(memory(), late), dies);
    const agent = createAnsweringAgent({ durability });
    const internals = agent[Symbol.for("libfx.durableInternals")];
    const session = agent.session();
    const first = session.prompt("restarted", { messageId: "turn-restarted" });
    const { sessionId } = await first.accepted;
    while (!dies.dead) await sleep(10);
    while (internals.liveWorkers() > 0) await sleep(10);
    dies.dead = false;
    // The resuming worker restarts the reply, ends the turn, then dies.
    late.now = true;
    void session.prompt("restarted", { messageId: "turn-restarted" }).result.catch(() => {});
    const log = await durability.create().session(sessionId);
    while (foldSessionLog(await log.read()).lastTurnId !== "turn-restarted") await sleep(10);
    await sleep(landMs);
    while (internals.liveWorkers() > 0) await sleep(10);
    late.now = false;
    const retried = await within(session.prompt("restarted", { messageId: "turn-restarted" }).result, "the retry waited for an end nobody writes");
    assert.equal(retried.stopReason, "end_turn");
    const lines = await linesOf(session, "turn-restarted");
    assert.deepEqual(lines.filter(([epoch]) => epoch > 2).map(([, type, delta]) => [type, delta]), [
      ["text_delta", "two three "],
      ["turn_end", null],
    ], `after ${JSON.stringify(lines.filter(([epoch]) => epoch <= 2))}`);
    const text = replyText(lines);
    assert.equal(text.slice(text.lastIndexOf(restartNotice) + restartNotice.length), "one two three ", "the reply once and whole after the restart");
    answers.delete("restarted");
    savesReply.delete("restarted");
    restarts.delete("restarted");
    await agent.close();
  });

  // memory(), holding the first record that ends a turn while `hold.armed`
  // is set, until the test calls `hold.release()`.
  const holdingEnd = (base, hold) => {
    let wrapped = null;
    return {
      ...base,
      create() {
        const backend = base.create();
        wrapped ??= Object.assign(Object.create(backend), {
          async session(id) {
            const log = await backend.session(id);
            return {
              ...log,
              async append(entry) {
                if (hold.armed && recordEnds(entry)) {
                  hold.armed = false;
                  await new Promise((go) => { hold.release = go; });
                }
                return log.append(entry);
              },
            };
          },
        });
        return wrapped;
      },
    };
  };

  // DUR-20, DUR-64: once the record that ends a turn is on its way to the
  // log, the turn ended as that record says. A cancel then stops nothing,
  // even with an engine that answers it cancelled and drops the rest of its
  // reply: the turn's end line says what the log says, after the whole reply
  // (`tests/tla/sdk/DurableSession.tla` LateCancel, EndSaysHow).
  test("a cancel that reaches a turn once its end is on its way stops nothing: the turn ends as that end says, with its whole reply", async () => {
    answers.set("late cancel", [{ type: "text_delta", delta: "one " }, { type: "text_delta", delta: "two " }, { type: "text_delta", delta: "three " }]);
    lateCancels.add("late cancel");
    const hold = { armed: true, release: null };
    const agent = createAnsweringAgent({ durability: holdingEnd(memory(), hold) });
    const session = agent.session();
    const turn = session.prompt("late cancel", { messageId: "turn-late" });
    await turn.accepted;
    while (hold.release === null) await sleep(5);
    await session.cancel();
    await sleep(landMs);
    hold.release();
    assert.equal((await within(turn.result, "the turn's result never came")).stopReason, "end_turn");
    const lines = (await readLines(session.stream(0), 100)).filter((line) => line.messageId === "turn-late");
    assert.deepEqual(lines.filter((line) => line.type.startsWith("turn_")).map((line) => [line.type, line.stopReason]), [["turn_start", undefined], ["turn_end", "end_turn"]]);
    assert.equal(lines.filter((line) => line.type === "text_delta").map((line) => line.delta).join(""), "one two three ", "the reply once and whole");
    // The cancel is spent with the turn it came for.
    assert.equal((await within(session.prompt("after", { messageId: "turn-after-late" }).result, "the next turn never ended")).stopReason, "end_turn");
    answers.delete("late cancel");
    lateCancels.delete("late cancel");
    await agent.close();
  });
}

// memory(), with a worker that dies right after the first entry that ends a
// turn while `dies.armed` is set, by default a record: from then until the
// test sets `dies.dead` back, no write but a sender's input lands, and no
// line reaches the stream.
const recordEnds = (entry) => entry?.k === "record" && (entry.marks ?? []).some((mark) => mark.end === true);
// The entry that ends a turn which wrote no record of its own.
const endedEntry = (entry) => entry?.k === "ended";
function deadAfterEnd(base, dies, ends = recordEnds) {
  let wrapped = null;
  return {
    ...base,
    create() {
      const backend = base.create();
      wrapped ??= Object.assign(Object.create(backend), {
        async session(id) {
          const log = await backend.session(id);
          return {
            ...log,
            ui: { ...log.ui, write: (lines) => log.ui.write(dies.dead ? [] : lines) },
            async append(entry) {
              if (dies.dead && entry?.k !== "input") throw new Error("the process died");
              const appended = await log.append(entry);
              if (dies.armed && ends(entry)) {
                dies.armed = false;
                dies.dead = true;
              }
              return appended;
            },
          };
        },
      });
      return wrapped;
    },
  };
}

if (durabilityKind === "memory") {
  test("a turn whose worker died between its end and its turn_end line ends for its viewers before the next queued turn runs", async () => {
    const dies = { armed: true, dead: false };
    const durability = deadAfterEnd(memory(), dies);
    const agent = createAgent({ durability });
    const session = agent.session();
    const first = session.prompt("alpha", { messageId: "turn-a" });
    await first.accepted;
    const second = session.prompt("beta", { messageId: "turn-b" });
    await second.accepted;
    while (!dies.dead) await sleep(10);
    await sleep(landMs);
    dies.dead = false;
    let timer;
    const [a, b] = await Promise.race([
      Promise.all([first.result, second.result]),
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("the first turn never ended for its viewers")), 5000); }),
    ]).finally(() => clearTimeout(timer));
    assert.equal(a.stopReason, "end_turn", "the first turn ended as its record says");
    assert.equal(b.stopReason, "end_turn");
    const lines = await readLines(session.stream(0), 200);
    const ends = (id) => lines.filter((line) => line.type === "turn_end" && line.messageId === id).length;
    assert.equal(ends("turn-a"), 1);
    assert.equal(ends("turn-b"), 1);
    const at = (type, id) => lines.findIndex((line) => line.type === type && line.messageId === id);
    assert.ok(at("turn_end", "turn-a") < at("turn_start", "turn-b"), "the first turn ended for its viewers before the next one started");
    await agent.close();
  });

  // DUR-20, DUR-25: a turn that ends before writing any record ends through
  // an `ended` entry in the log, then its turn_end line, and the next worker
  // writes that line when its holder died between the two, as for a turn a
  // record ended (`tests/tla/sdk/DurableSession.tla` with Refused, EndLine).
  // Each retry here would otherwise wait 30 s for an end nobody writes.
  // Its `ended` entry says how it ended, so both its viewers and a retry
  // hear that (DUR-20).
  const endsForItsViewers = async (session, input, messageId, first, expected) => {
    let timer;
    const retried = await Promise.race([
      session.prompt(input, { messageId }).result,
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("the retry waited for an end nobody writes")), 5000); }),
    ]).finally(() => clearTimeout(timer));
    const outcome = (result) => ({ stopReason: result.stopReason, ...(result.error ? { error: result.error.message } : {}) });
    assert.deepEqual(outcome(retried), expected);
    assert.deepEqual(outcome(await first.result), expected);
    const lines = await readLines(session.stream(0), 100);
    assert.equal(lines.filter((line) => line.type === "turn_end" && line.messageId === messageId).length, 1);
    assert.equal((await session.prompt("after", { messageId: `${messageId}-after` }).result).stopReason, "end_turn");
  };

  test("a prompt the harness refused, whose worker died before its turn_end line, ends for its viewers when the session is next delivered", async () => {
    const dies = { armed: true, dead: false };
    const agent = createAgent({ durability: deadAfterEnd(memory(), dies, endedEntry) });
    const session = agent.session();
    const first = session.prompt("refuse", { messageId: "turn-r" });
    await first.accepted;
    while (!dies.dead) await sleep(10);
    await sleep(landMs);
    dies.dead = false;
    await endsForItsViewers(session, "refuse", "turn-r", first, { stopReason: "error", error: "refused" });
    await agent.close();
  });

  test("a prompt its own cancel stopped before it started, whose worker died before its turn_end line, ends for its viewers when the session is next delivered", async () => {
    const dies = { armed: false, dead: false };
    const agent = createAgent({ durability: deadAfterEnd(memory(), dies, endedEntry) });
    const session = agent.session();
    // The prompt waits behind a running turn, and its cancel lands first.
    const held = holdStep("alpha-1");
    const running = session.prompt("alpha", { messageId: "turn-a" });
    await held.holding;
    const waiting = new AbortController();
    const first = session.prompt("beta", { messageId: "turn-b", signal: waiting.signal });
    await first.accepted;
    waiting.abort();
    const log = await agent[Symbol.for("libfx.durableInternals")].openLog(session.id);
    while (!(await log.read()).some(({ entry }) => entry.type === "cancel" && entry.target === "turn-b")) await sleep(10);
    dies.armed = true;
    held.release();
    assert.equal((await running.result).stopReason, "end_turn");
    while (!dies.dead) await sleep(10);
    await sleep(landMs);
    dies.dead = false;
    await endsForItsViewers(session, "beta", "turn-b", first, { stopReason: "cancelled" });
    await agent.close();
  });

  // A resume answers its viewer with the turn its delivery continues, whose
  // lines that viewer follows; idle is the answer for a resume with nothing
  // to continue, never for one whose turn then ended.
  test("a resume() that continued a turn another worker left open writes no idle line for its request", async () => {
    const durability = memory();
    const first = createAgent({ durability });
    const second = createAgent({ durability });
    const held = holdStep("kappa-1");
    const turn = first.session().prompt("kappa", { messageId: "turn-k" });
    const { sessionId } = await turn.accepted;
    await held.holding;
    // The first worker's process is gone, as far as its lease shows.
    const holders = globalThis[Symbol.for("libfx.liveHolders")];
    for (const holder of [...holders]) holders.delete(holder);
    holds.delete("kappa-1");
    const resumed = await second.session(sessionId).resume().result;
    assert.equal(resumed.stopReason, "end_turn");
    assert.equal((await turn.result).stopReason, "end_turn");
    const lines = await readLines(second.session(sessionId).stream(0), 32);
    assert.deepEqual(lines.filter((line) => line.type === "idle"), [], "the resume that continued the turn wrote no idle line");
    assert.equal(lines.filter((line) => line.type === "turn_end").length, 1);
    // A resume with nothing to continue still answers idle.
    assert.equal((await second.session(sessionId).resume().result).stopReason, "idle");
    held.release();
    await first.close();
    await second.close();
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

// A World durability whose session streams live in this test, as
// world-local's do on disk: each chunk gets its place in the stream when its
// write starts, and a reader is handed each chunk once it is visible, in
// place order among those it has not had, as world-local's reader in another
// process is. A batch's chunks become visible last first, as world-local's
// parallel writes of one batch can finish, or in order with `inOrder`. The
// first write is slow, so the lines a turn pushes meanwhile go out together.
function batchesLandOutOfOrder(durability, { inOrder = false } = {}) {
  const seen = { batches: 0 };
  const worldOf = durability.world;
  const streams = new Map();
  const streamOf = (runId, name) => {
    const key = `${runId}/${name}`;
    if (!streams.has(key)) streams.set(key, { chunks: [], visible: new Set(), readers: new Set(), writes: 0 });
    return streams.get(key);
  };
  const land = (stream, place) => {
    stream.visible.add(place);
    for (const wake of stream.readers) wake();
  };
  const fake = {
    async write(runId, name, chunk) {
      const stream = streamOf(runId, name);
      const place = stream.chunks.push(chunk) - 1;
      if (stream.writes++ === 0) await sleep(150);
      land(stream, place);
    },
    async writeMulti(runId, name, chunks) {
      seen.batches += 1;
      const stream = streamOf(runId, name);
      const places = chunks.map((chunk) => stream.chunks.push(chunk) - 1);
      for (const place of inOrder ? places : [...places].reverse()) {
        await sleep(20);
        land(stream, place);
      }
    },
    async getInfo(runId, name) {
      return { tailIndex: streamOf(runId, name).visible.size - 1 };
    },
    async get(runId, name, from = 0) {
      const stream = streamOf(runId, name);
      const sorted = [...stream.visible].sort((a, b) => a - b);
      const handed = new Set(sorted);
      const next = sorted.slice(from);
      let wake = null;
      let cancelled = false;
      const notify = () => wake?.();
      stream.readers.add(notify);
      return new ReadableStream({
        async pull(controller) {
          while (!cancelled) {
            if (next.length > 0) {
              controller.enqueue(encoder.encode(stream.chunks[next.shift()]));
              return;
            }
            const fresh = [...stream.visible].filter((place) => !handed.has(place)).sort((a, b) => a - b);
            for (const place of fresh) { handed.add(place); next.push(place); }
            if (fresh.length === 0) await new Promise((resolve) => { wake = resolve; });
          }
        },
        cancel() {
          cancelled = true;
          stream.readers.delete(notify);
          notify();
        },
      });
    },
  };
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await worldOf();
      const streams = new Proxy(world.streams, { get: (target, key) => (Object.hasOwn(fake, key) ? fake[key] : bound(target, key)) });
      return new Proxy(world, { get: (target, key) => (key === "streams" ? streams : bound(target, key)) });
    },
  }, seen];
}

if (durabilityKind !== "memory") {
  const createLongAgent = createDurableAgentFactory({ harness: scriptedHarness({ steps: 6 }), defaultDurability: async () => memory(), name: "createLongAgent" });
  // A reader that follows the turn from its start, and a replay after it.
  const liveAndReplay = async (agent) => {
    const session = agent.session();
    const turn = session.prompt("omicron", { messageId: "turn-o" });
    const { sessionId } = await turn.accepted;
    const live = readLines(agent.session(sessionId).stream(0), 32, 1000);
    assert.equal((await turn.result).stopReason, "end_turn");
    return { live: await live, replay: await readLines(agent.session(sessionId).stream(0), 32) };
  };

  test("a live reader gets a turn's lines in stored order and under a replay's cursors, though the World can land a batch out of order", async () => {
    const [durability, seen] = batchesLandOutOfOrder(await durabilityFor());
    const agent = createLongAgent({ durability });
    const { live, replay } = await liveAndReplay(agent);
    assert.equal(replay.length, 8, JSON.stringify(replay));
    assert.deepEqual(live, replay, "DUR-38: the live reader got what a replay from cursor 0 gets");
    assert.equal(seen.batches, 0, "no batch went to a World that may land it out of order");
    await agent.close();
  });

  test("a World that keeps a batch in order, as Vercel's does, gets a turn's lines in batches", async () => {
    const { vercel } = await import("../durable/vercel.mjs");
    const inOrder = Symbol.for("libfx.batchesInOrder");
    assert.equal(vercel()[inOrder], true, "vercel() says its World keeps a batch in order");
    const [durability, seen] = batchesLandOutOfOrder({ ...(await durabilityFor()), [inOrder]: true }, { inOrder: true });
    const agent = createLongAgent({ durability });
    const { live, replay } = await liveAndReplay(agent);
    assert.deepEqual(live, replay);
    assert.ok(seen.batches > 0, "the lines pushed during a write went out in one batch");
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

if (durabilityKind === "world") {
  // DUR-30 ("does no more work"), DUR-38: a worker that stalls past its
  // lease, as a frozen process does, may have been taken over without
  // knowing it. When it goes on, it writes no line to the session's stream
  // until a renewal of its own lands, and none at all once that renewal is
  // fenced out (`tests/tla/sdk/DurableSession.tla` LateLine).
  test("a worker whose lease ran out while it stalled, which another worker took over, writes no line to the stream when it goes on", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-stalled-"));
    dirs.push(dir);
    const { durability, broker } = await queueWorldAt(dir, { leaseMs: 1000 });
    // The first worker's renewals are held while it stalls.
    const instance = await durability.world();
    const events = instance.events;
    let stalledHolder = null;
    let stalled = false;
    const heldRenewals = [];
    instance.events = new Proxy(events, {
      get(target, key) {
        if (key !== "create") {
          const value = Reflect.get(target, key);
          return typeof value === "function" ? value.bind(target) : value;
        }
        return async (runId, event, options) => {
          const entry = event?.eventData?.stepName === "fx.log" ? JSON.parse(decoder.decode(event.eventData.input)) : null;
          if (entry?.k === "lease") {
            stalledHolder ??= entry.holder;
            if (stalled && entry.holder === stalledHolder) await new Promise((go) => heldRenewals.push(go));
          }
          return target.create(runId, event, options);
        };
      },
    });
    answers.set("eta", [{ type: "text_delta", delta: "the " }, { type: "text_delta", delta: "answer" }]);
    const fenced = [];
    const first = createAnsweringAgent({ durability, onEvent: (event) => { if (event.type === "session.fenced") fenced.push(event); } });
    const second = createAnsweringAgent({ durability });
    await first.newSessionId();
    await second.newSessionId();
    const held = holdStep("eta-0");
    const session = first.session();
    const turn = session.prompt("eta", { messageId: "turn-eta" });
    await held.holding;
    // The first worker stalls past its lease; the second worker's step runs.
    stalled = true;
    holds.delete("eta-0");
    await sleep(1300);
    const holders = globalThis[Symbol.for("libfx.liveHolders")];
    for (const holder of [...holders]) holders.delete(holder);
    const [message] = broker.held((input) => input.messageId === "turn-eta");
    assert.ok(message, "the prompt's message is still held");
    broker.lapse(message);
    const { text, result } = await textOf(turn);
    assert.equal(result.stopReason, "end_turn");
    assert.equal(text, "the answer");
    // The first worker goes on: its reply streams while its renewal is still
    // on its way, then the renewal lands and is fenced out.
    held.release();
    await sleep(200);
    stalled = false;
    for (const go of heldRenewals.splice(0)) go();
    for (let waited = 0; fenced.length === 0 && waited < 5000; waited += 20) await sleep(20);
    assert.equal(fenced.length, 1, "the stalled worker stopped at its renewal");
    await sleep(200);
    const log = await first[Symbol.for("libfx.durableInternals")].openLog(session.id);
    const stored = (await readLines(log.ui.read(0), 64)).filter((line) => Number.isSafeInteger(line.epoch));
    const firstEpoch = stored[0].epoch;
    const takeover = stored.findIndex((line) => line.epoch > firstEpoch);
    assert.ok(takeover > 0, JSON.stringify(stored.map((line) => `${line.type}@${line.epoch}`)));
    const late = stored.slice(takeover).filter((line) => line.epoch === firstEpoch);
    assert.deepEqual(late.map((line) => `${line.type}@${line.epoch}`), [], "the stalled worker wrote no line after the takeover");
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

  // DUR-20: the entry that ends a turn says how, and a fold from a checkpoint
  // still knows how the last turn ended.
  test("the log says how each turn ended, and a checkpoint keeps the last turn's", () => {
    const input = (messageId) => ({ k: "input", key: `${messageId}:prompt`, type: "prompt", messageId });
    const record = (head, marks) => ({ k: "record", a: head, data: "", marks });
    const fold = (entries) => foldSessionLog(entries.map((entry, index) => ({ cursor: String(index + 1), entry })));
    const state = fold([
      input("t1"), record(null, [{ start: "t1" }]), record("2", [{ end: true, stopReason: "max_output_tokens" }]),
      input("t2"), { k: "ended", messageId: "t2", stopReason: "error", error: { name: "Error", message: "refused" } },
      input("t3"), record("3", [{ start: "t3" }]), record("7", [{ end: true }]),
    ]);
    assert.deepEqual(state.endingOf("t1"), { stopReason: "max_output_tokens" });
    assert.deepEqual(state.endingOf("t2"), { stopReason: "error", error: { name: "Error", message: "refused" } });
    // An end an earlier libfx wrote says nothing of how.
    assert.equal(state.endingOf("t3"), null);
    assert.equal(state.endingOf("t9"), null);
    // A second end of a turn already ended changes nothing.
    assert.deepEqual(fold([input("t1"), record(null, [{ start: "t1" }]), record("2", [{ end: true, stopReason: "cancelled" }, { end: true, stopReason: "end_turn" }])]).endingOf("t1"), { stopReason: "cancelled" });
    const restored = fold([{ k: "checkpoint", through: "9", data: "saved", lastTurnId: "t1", lastTurnEnd: { stopReason: "end_turn" } }]);
    assert.equal(restored.lastTurnId, "t1");
    assert.deepEqual(restored.endingOf("t1"), { stopReason: "end_turn" });
    // An end also keeps the turn's reply, which recovery shows before the
    // end it writes (DUR-20, DUR-38), and the steer with images the turn
    // ended for, which that end names; so does a checkpoint of it, and an
    // `ended` entry keeps its steer.
    const said = fold([
      input("t4"), record(null, [{ start: "t4" }]), record("2", [{ end: true, stopReason: "cancelled", endedBySteer: "s4", reply: "so far" }]),
      input("t5"), { k: "ended", messageId: "t5", stopReason: "cancelled", endedBySteer: "s5" },
    ]);
    assert.deepEqual(said.endingOf("t4"), { stopReason: "cancelled", endedBySteer: "s4", reply: "so far" });
    assert.deepEqual(said.endingOf("t5"), { stopReason: "cancelled", endedBySteer: "s5" });
    const kept = fold([{ k: "checkpoint", through: "9", data: "saved", lastTurnId: "t4", lastTurnEnd: said.endingOf("t4") }]);
    assert.deepEqual(kept.endingOf("t4"), { stopReason: "cancelled", endedBySteer: "s4", reply: "so far" });
    // Neither is anything but a string, and a steer's is an id.
    assert.deepEqual(fold([input("t6"), record(null, [{ start: "t6" }]), record("2", [{ end: true, stopReason: "end_turn", endedBySteer: "not an id!", reply: 7 }])]).endingOf("t6"), { stopReason: "end_turn" });
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
    const big = "x".repeat(16 * 1024 * 1024);
    assert.throws(() => session.prompt(big), (error) => error?.code === "FX_INPUT_TOO_LARGE" && error.limit === 16 * 1024 * 1024);
    await assert.rejects(session.steer(big), (error) => error?.code === "FX_INPUT_TOO_LARGE");
    assert.equal(await inputs(), before, "no input was stored");
    await agent.close();
  });

  // DUR-23, API-42: a harness whose engine frames inputs, as fx's does, has
  // the core refuse an input that frame cannot hold, which no turn could run,
  // and only that: image data, which travels beside the frame, does not count.
  test("an input its engine's frame cannot hold is refused before anything is stored, and image data does not count toward it", async () => {
    const maxFrameBytes = 4096;
    // Text counts toward the frame; image data does not.
    const frameBytes = (input) => 100 + (typeof input === "string" ? input.length : input.reduce((total, block) => total + (block.type === "text" ? block.text.length : 0), 0));
    const createFramedAgent = createDurableAgentFactory({
      harness: () => ({ ...scriptedHarness()(), frameBytes, maxFrameBytes }),
      defaultDurability: async () => memory(),
      name: "createFramedAgent",
    });
    const agent = createFramedAgent({ durability: memory() });
    const session = agent.session(undefined, { context: { user: "a" } });
    assert.equal((await session.prompt("first").result).stopReason, "end_turn");
    const inputs = async () => (await (await agent[Symbol.for("libfx.durableInternals")].openLog(session.id)).read()).filter(({ entry }) => entry.k === "input").length;
    const before = await inputs();
    const over = "x".repeat(maxFrameBytes - 100 + 1);
    assert.throws(() => session.prompt(over), (error) => error instanceof RangeError && error.code === "FX_INPUT_TOO_LARGE" && error.bytes === maxFrameBytes + 1 && error.limit === maxFrameBytes);
    await assert.rejects(session.steer(over), (error) => error?.code === "FX_INPUT_TOO_LARGE" && error.limit === maxFrameBytes);
    assert.equal(await inputs(), before, "no input was stored");
    // Image data far over the frame, with text that fills it, is stored.
    const image = { type: "image", data: "A".repeat(9 * 1024 * 1024), mimeType: "image/png" };
    const turn = session.prompt([{ type: "text", text: over.slice(1) }, image]);
    await turn.accepted;
    assert.equal(await inputs(), before + 1, "the input with its images was stored");
    await turn.result;
    // The session stores an image once, by name, and its log entry only names
    // it, so what counts toward the 16 MiB a session stores for one input is
    // the image's bytes, not its base64: 16 MiB of base64 is 12 MiB stored.
    const large = { ...image, data: "A".repeat(16 * 1024 * 1024) };
    const kept = session.prompt([{ type: "text", text: "small" }, large]);
    await kept.accepted;
    assert.equal(await inputs(), before + 2, "an input whose stored bytes fit was stored, though its base64 does not fit");
    await kept.result;
    // Past the 16 MiB a session stores for one input, images are refused too.
    const huge = { ...image, data: "A".repeat(22 * 1024 * 1024) };
    assert.throws(() => session.prompt([{ type: "text", text: "small" }, huge]), (error) => error?.code === "FX_INPUT_TOO_LARGE" && error.limit === 16 * 1024 * 1024 && error.bytes > 16.5 * 1024 * 1024);
    await assert.rejects(session.steer([{ type: "text", text: "small" }, huge]), (error) => error?.code === "FX_INPUT_TOO_LARGE" && error.limit === 16 * 1024 * 1024);
    assert.equal(await inputs(), before + 2);
    await agent.close();
  });

  // QUAL-18: the refusal names the cause and what to do (decision D2).
  test("refusing a second agent of one name says why and what to do", async () => {
    const shared = memory();
    const tagged = createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => shared, defaultShared: true, name: "createDefaultAgent" });
    const chat = tagged({ tag: "chat" });
    assert.throws(() => tagged({ tag: "summarizer" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE" && error.agent === "default" &&
      error.message === "createDefaultAgent() options differ from those of an agent already created without a name in this process; agents created without a name all have the name \"default\", and agents of one name on one store must be copies of one agent, so give each agent its own name, such as createDefaultAgent({ name: \"summarizer\" })");
    const durability = memory();
    const support = createTaggedAgent({ durability, name: "support", tag: "acme" });
    assert.throws(() => createTaggedAgent({ durability, name: "support", tag: "evil" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE" &&
      error.message === "an agent named \"support\" already runs on this store in this process with other options, and agents of one name on one store must be copies of one agent; give each agent its own name, or each its own store");
    await support.close();
    await chat.close();
  });

  // Decision D1: SEC-2 keeps the refusal unless the runtime that builds the
  // factory says the process is a development server. The core reads no
  // environment; sdk/tests/test-durable.mjs checks how Node decides.
  test("SEC-2: a factory refuses another configuration under a name unless its development() returns true", async () => {
    const strict = createDurableAgentFactory({ harness: taggedHarness, defaultDurability: async () => memory(), development: () => false, name: "createTaggedAgent" });
    const loose = createDurableAgentFactory({ harness: taggedHarness, defaultDurability: async () => memory(), development: () => "development", name: "createTaggedAgent" });
    // Not even where the process environment says development, as a
    // browser bundle's shim may.
    const saved = process.env.NODE_ENV;
    process.env.NODE_ENV = "development";
    try {
      for (const create of [createTaggedAgent, strict, loose]) {
        const durability = memory();
        const support = create({ durability, name: "support", tag: "acme" });
        assert.throws(() => create({ durability, name: "support", tag: "evil" }), (error) => error?.code === "FX_AGENT_NAME_IN_USE");
        await support.close();
      }
    } finally {
      if (saved === undefined) delete process.env.NODE_ENV;
      else process.env.NODE_ENV = saved;
    }
  });

  test("in development, an agent with other options replaces the one its name had: that one's running turn ends there, and later turns run on the new one", async () => {
    const durability = memory();
    const internals = Symbol.for("libfx.durableInternals");
    const old = createDevTaggedAgent({ durability, name: "support", tag: "old" });
    const session = old.session();
    const held = holdStep("first-1");
    const running = session.prompt("first");
    const events = [];
    let fresh;
    try {
      await held.holding;
      fresh = createDevTaggedAgent({ durability, name: "support", tag: "new", onEvent: (event) => events.push(event) });
    } finally {
      held.release();
    }
    assert.deepEqual(events.filter((event) => event.type === "agent.replaced").map(({ agent, replaced }) => ({ agent, replaced })), [{ agent: "support", replaced: 1 }]);
    assert.equal((await textOf(running)).text, "first-0 first-1 first-2");
    assert.deepEqual(openersOf(session.id), ["old"], "the turn the old agent was running ended there");
    while (old[internals].liveWorkers() > 0) await sleep(5);
    // A module loaded before still prompts through the old agent; its
    // turn runs on the new one, as one sent through the new agent does.
    assert.equal((await textOf(old.session(session.id).prompt("second"))).text, "second-0 second-1 second-2");
    assert.equal((await textOf(fresh.session(session.id).prompt("third"))).text, "third-0 third-1 third-2");
    assert.deepEqual(openersOf(session.id), ["old", "new"]);
    // A third configuration replaces the new one too, and the old agent's
    // deliveries follow the name to it.
    const third = createDevTaggedAgent({ durability, name: "support", tag: "third" });
    while (fresh[internals].liveWorkers() > 0) await sleep(5);
    assert.equal((await textOf(old.session(session.id).prompt("fourth"))).text, "fourth-0 fourth-1 fourth-2");
    assert.deepEqual(openersOf(session.id), ["old", "new", "third"]);
    for (const agent of [old, fresh, third]) await agent.close();
  });

  test("in development, an agent created without a name replaces an earlier one with other options, on the shared default store", async () => {
    const shared = memory();
    const tagged = createDurableAgentFactory({ harness: ({ tag }) => scriptedHarness()(), defaultDurability: async () => shared, defaultShared: true, development: () => true, name: "createDefaultAgent" });
    const first = tagged({ tag: "key-a" });
    await first.newSessionId();
    const events = [];
    const second = tagged({ tag: "key-b", onEvent: (event) => events.push(event) });
    assert.equal(events.filter((event) => event.type === "agent.replaced").length, 1);
    // The earlier agent, now replaced, opens nothing under the name again.
    const turn = first.session().prompt("hello");
    assert.equal((await textOf(turn)).text, "hello-0 hello-1 hello-2");
    for (const agent of [first, second]) await agent.close();
  });

  // Decision D1: a chain of replacements ends at the newest agent. An agent
  // created without a durability learns its store only when first used, so
  // a newer agent on that store, created after it, may be registered first
  // (`tests/tla/sdk/TenantIsolation.tla` Resolve, ReplacedByNewer).
  test("in development, an older agent that learns its store after a newer one took it gives way to the newer one", async () => {
    const shared = memory();
    const tagged = createDurableAgentFactory({ harness: taggedHarness, defaultDurability: async () => shared, defaultShared: true, development: () => true, name: "createDefaultAgent" });
    const replaced = [];
    const watch = (label) => (event) => { if (event.type === "agent.replaced") replaced.push([label, event.replaced]); };
    // A module loaded before an edit, whose agent takes the default store.
    const older = tagged({ name: "support", tag: "older", onEvent: watch("older") });
    // The module after the edit names the store.
    const newer = tagged({ name: "support", tag: "newer", durability: shared, onEvent: watch("newer") });
    assert.deepEqual(replaced, [], "neither knows yet that the other is on its store");
    // A route that loaded the module before uses its agent now.
    const session = older.session();
    assert.equal((await textOf(session.prompt("first"))).text, "first-0 first-1 first-2");
    assert.deepEqual(replaced, [["newer", 1]], "the newer agent replaced the older one");
    assert.deepEqual(openersOf(session.id), ["newer"], "the turn sent through the older agent ran on the newer one");
    assert.equal((await textOf(newer.session(session.id).prompt("second"))).text, "second-0 second-1 second-2");
    assert.deepEqual(openersOf(session.id), ["newer"]);
    for (const agent of [older, newer]) await agent.close();
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

if (durabilityKind === "local") {
  // Decision D1, as `next dev` reloads a module: the module creates its agent
  // again on a local() of its own over the same directory, while a route that
  // loaded the module before still prompts through the old agent, whose
  // World's queue delivers to it.
  test("in development, an agent on a new local() over the same directory replaces the old one, and prompts sent through the old one run on it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-core-reload-"));
    dirs.push(dir);
    const internals = Symbol.for("libfx.durableInternals");
    const old = createDevTaggedAgent({ durability: local({ dir }), name: "support", tag: "old-module" });
    const first = old.session();
    assert.equal((await textOf(first.prompt("alpha"))).text, "alpha-0 alpha-1 alpha-2");
    const fresh = createDevTaggedAgent({ durability: local({ dir }), name: "support", tag: "new-module" });
    while (old[internals].liveWorkers() > 0) await sleep(5);
    assert.equal((await textOf(old.session(first.id).prompt("beta"))).text, "beta-0 beta-1 beta-2");
    assert.equal((await textOf(fresh.session(first.id).prompt("gamma"))).text, "gamma-0 gamma-1 gamma-2");
    assert.deepEqual(openersOf(first.id), ["old-module", "new-module"]);
    await old.close();
    await fresh.close();
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
