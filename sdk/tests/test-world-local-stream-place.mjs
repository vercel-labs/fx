#!/usr/bin/env node
// The World libfx bundles for local() puts a stream's chunk where it lands
// (DUR-38; `tests/tla/sdk/UiStream.tla` Placement). A UI line whose write
// was on its way when its worker stalled lands after the lines the worker
// that took the session over wrote meanwhile, which a live reader already
// has, so that reader's lines and cursors stay a replay's.
//
//   node sdk/tests/test-world-local-stream-place.mjs [<libfx-package-dir>]
//
// With a package directory, such as sdk/dist/libfx, this tests its
// durable.js and durable/local.mjs. Without one, it bundles the durability
// modules first, with Bun (`BUN_BIN`, default `bun`) after `npm ci --prefix
// sdk/durable`. A write is held on its way by holding the file system call
// that lands its chunk, here and not in libfx. The writers in other
// processes are this script with `--child`.
import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import fsp, { mkdtemp, readdir, rm } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const child = args[0] === "--child" ? Object.fromEntries(args.slice(1).map((value, index, all) => index % 2 === 0 ? [value.replace(/^--/, ""), all[index + 1]] : null).filter(Boolean)) : null;
const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "../..");
const dirs = [];

let packageDir = child ? child.package : args[0];
if (!packageDir) {
  packageDir = await mkdtemp(join(tmpdir(), "libfx-stream-bundle-"));
  dirs.push(packageDir);
  const bundled = spawnSync(process.env.BUN_BIN || "bun", [join(repoRoot, "sdk/scripts/bundle-durable.mjs"), packageDir], { stdio: "inherit" });
  if (bundled.error) throw bundled.error;
  if (bundled.status !== 0) process.exit(bundled.status ?? 1);
}
packageDir = resolve(packageDir);
const localModule = join(packageDir, "durable/local.mjs");
if (!existsSync(localModule)) throw new Error(`no durable/local.mjs in ${packageDir}`);
const { local } = await import(pathToFileURL(localModule).href);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const runId = "wrun_01K00000000000000000STREAM";

async function openWorld(dir) {
  const world = local({ dir }).world();
  await world.start?.();
  return world;
}

// The text of each chunk of a stream, in the order a replay reads them.
async function replayOf(world, stream) {
  const page = await world.streams.getChunks(runId, stream, { limit: 1000 });
  return page.data.map((chunk) => decoder.decode(chunk.data));
}

// Writes `writes` chunks to one stream, each after the one before landed, as
// libfx's UI writer does, once told to go.
async function runChild({ dir, stream, writes, tag }) {
  const world = await openWorld(dir);
  console.log("ready");
  for await (const line of createInterface({ input: process.stdin })) {
    if (line !== "go") continue;
    for (let index = 0; index < Number(writes); index += 1) await world.streams.write(runId, stream, `${tag}-${index}\n`);
    console.log("done");
    await world.close?.();
    return;
  }
}

if (child) {
  await runChild(child);
  process.exit(0);
}

const { createDurableAgentFactory } = await import(pathToFileURL(existsSync(join(packageDir, "durable.js")) ? join(packageDir, "durable.js") : join(repoRoot, "sdk/durable.js")).href);
const { queueWorldAt, closeQueueWorlds } = await import("./queue-world.mjs");

// Holds the file system call that lands a chunk whose line matches, as a
// worker frozen with that write on its way would: world-local 5.1.1 renames
// a written chunk into place, and the bundled World links it into place. The
// first call for a matching chunk waits until the test lets it go.
const landingHolds = new Set();
const isChunk = (path) => /[\\/]streams[\\/]chunks[\\/]/.test(String(path)) && /^chnk_[^\\/]*\.bin$/.test(String(path).split(/[\\/]/).at(-1));
const lineOf = (path) => {
  try {
    return JSON.parse(decoder.decode(readFileSync(path).subarray(1)));
  } catch {
    return null;
  }
};
// File systems that make no hard links: a link() in a stream folder fails.
const noLinks = { on: false };
for (const key of ["rename", "link"]) {
  const original = fsp[key];
  fsp[key] = async function (from, to, ...rest) {
    if (key === "link" && noLinks.on && isChunk(to)) throw Object.assign(new Error("operation not supported"), { code: "ENOTSUP" });
    if (isChunk(to)) {
      const line = landingHolds.size > 0 ? lineOf(from) : null;
      for (const hold of landingHolds) {
        if (!hold.matches(line)) continue;
        landingHolds.delete(hold);
        hold.started();
        await hold.released;
        break;
      }
    }
    return original.call(this, from, to, ...rest);
  };
}
syncBuiltinESMExports();
function holdLanding(matches) {
  let started;
  let release;
  const holding = new Promise((resolve) => { started = resolve; });
  const released = new Promise((resolve) => { release = resolve; });
  const hold = { matches, started: () => started(), released };
  landingHolds.add(hold);
  return { holding, release: () => { landingHolds.delete(hold); release(); } };
}

// A scripted harness: a turn of `input` is three steps, each a record and
// then a `text_delta` of its word, `${input}-${step}`. A step in `holds`
// waits until the test lets it go.
const holds = new Map();
function holdStep(word) {
  let started;
  let release;
  const holding = new Promise((resolve) => { started = resolve; });
  const released = new Promise((resolve) => { release = resolve; });
  holds.set(word, { started: () => started(), released });
  return { holding, release: () => { holds.delete(word); release(); } };
}
function scriptedHarness() {
  return () => ({
    async open({ store }) {
      const records = (await store.load()).journal.map((record) => JSON.parse(decoder.decode(record.data)));
      let handedOff = false;
      let key = 0;
      const append = async (record, marks) => {
        if (handedOff) throw new Error("handed off");
        await store.append({ idempotencyKey: `stream:${Date.now()}:${key++}`, data: encoder.encode(JSON.stringify(record)), marks });
        records.push(record);
      };
      const openTurn = () => {
        for (let index = records.length - 1; index >= 0; index -= 1) {
          if (records[index].end) return null;
          if (records[index].start) return { id: records[index].turnId, input: records[index].input };
        }
        return null;
      };
      const run = (turnId, input) => scriptedTurn(async (push, signal) => {
        for (let step = records.filter((record) => record.turnId === turnId && record.word !== undefined).length; step < 3; step += 1) {
          const word = `${input}-${step}`;
          const hold = holds.get(word);
          if (hold) {
            hold.started();
            await Promise.race([hold.released, new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }))]);
          }
          await sleep(2);
          if (signal.aborted) throw new Error("aborted");
          const last = step === 2;
          await append({ turnId, step, word, ...(last ? { end: true } : {}) }, last ? [{ end: true, stopReason: "end_turn" }] : []);
          push({ type: "text_delta", delta: `${word} ` });
        }
        return { stopReason: "end_turn" };
      }, () => { handedOff = true; });
      return {
        prompt(input, { turnId } = {}) {
          const started = append({ turnId, start: true, input }, [{ start: turnId }]);
          let turn = null;
          const ready = started.then(() => (turn = run(turnId, input)));
          const result = ready.then((value) => value.result);
          void result.catch(() => {});
          return {
            result,
            steer: async () => {},
            cancel: (options) => { ready.then((value) => value.cancel(options), () => {}); },
            async *[Symbol.asyncIterator]() { yield* await ready; },
          };
        },
        resume() {
          const open = openTurn();
          return run(open.id, open.input);
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
}
function scriptedTurn(body, onHandoff) {
  const queue = [];
  let wake = null;
  let finished = false;
  const controller = new AbortController();
  let cancelled = false;
  const result = body((event) => { queue.push(event); wake?.(); }, controller.signal)
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
        while (queue.length) yield queue.shift();
        if (finished) return;
        await new Promise((resolve) => { wake = resolve; });
        wake = null;
      }
    },
  };
}
const createAgent = createDurableAgentFactory({ harness: scriptedHarness(), defaultDurability: async () => { throw new Error("each agent here names its World"); }, name: "createStreamAgent" });

// The lines a session stream gives, with their cursors, until it is quiet.
async function readLines(stream, quietMs = 600) {
  const reader = stream.getReader();
  let buffered = "";
  const lines = [];
  for (;;) {
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
// A reader that follows a session stream from now on.
function follow(stream) {
  const lines = [];
  const reader = stream.getReader();
  let buffered = "";
  const done = (async () => {
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ done: true }));
      if (done) return;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
  })();
  return { lines, stop: async () => { await reader.cancel().catch(() => {}); await done; } };
}
const shown = (lines) => lines.map(({ cursor, type, epoch, delta }) => `${cursor}:${type}@${epoch}${delta === undefined ? "" : `:${delta.trim()}`}`);

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("DUR-38: a line on its way when its worker stalled lands after the lines of the worker that took the session over, and a live reader's cursors stay a replay's", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-stream-takeover-"));
  dirs.push(dir);
  // The first worker, the one that takes over, and a reader, each on a World
  // of its own over the session's folder, as each in a process of its own.
  const open = (dataDir) => local({ dir: dataDir }).world();
  const first = await queueWorldAt(dir, { open, leaseMs: 1000 });
  const second = await queueWorldAt(dir, { open, leaseMs: 1000 });
  const reading = await queueWorldAt(dir, { open });
  // The first worker's renewals are held while it stalls.
  const instance = await first.durability.world();
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
      return async (run, event, options) => {
        const entry = event?.eventData?.stepName === "fx.log" ? JSON.parse(decoder.decode(event.eventData.input)) : null;
        if (entry?.k === "lease") {
          stalledHolder ??= entry.holder;
          if (stalled && entry.holder === stalledHolder) await new Promise((go) => heldRenewals.push(go));
        }
        return target.create(run, event, options);
      };
    },
  });
  const fenced = [];
  const a = createAgent({ durability: first.durability, onEvent: (event) => { if (event.type === "session.fenced") fenced.push(event); } });
  const b = createAgent({ durability: second.durability });
  const reader = createAgent({ durability: reading.durability });
  await a.newSessionId();
  await b.newSessionId();
  // The first step's line is on its way when the worker stalls before its
  // second step.
  const late = holdLanding((line) => line?.type === "text_delta" && line.delta === "kappa-0 ");
  const step = holdStep("kappa-1");
  const turn = a.session().prompt("kappa", { messageId: "turn-kappa" });
  const { sessionId } = await turn.accepted;
  void turn.result.catch(() => {});
  const live = follow(reader.session(sessionId).stream(0));
  await late.holding;
  await step.holding;
  stalled = true;
  holds.delete("kappa-1");
  await sleep(1300);
  const holders = globalThis[Symbol.for("libfx.liveHolders")];
  for (const holder of [...holders]) holders.delete(holder);
  // The queue hands the prompt's message to the second worker's process.
  const [message] = first.broker.held((input) => input.messageId === "turn-kappa");
  assert.ok(message, "the prompt's message is still held");
  second.broker.adopt(message);
  for (let waited = 0; !live.lines.some((line) => line.type === "turn_end") && waited < 10_000; waited += 20) await sleep(20);
  const before = shown(live.lines);
  assert.ok(before.some((line) => line.includes(":turn_end@")), `the second worker ended the turn: ${JSON.stringify(before)}`);
  assert.ok(!before.some((line) => line.endsWith(":kappa-0")), "the first step's line had not landed");
  // The first worker goes on: its line lands, then its renewal is fenced out.
  late.release();
  step.release();
  stalled = false;
  for (const go of heldRenewals.splice(0)) go();
  for (let waited = 0; fenced.length === 0 && waited < 5000; waited += 20) await sleep(20);
  assert.equal(fenced.length, 1, "the stalled worker stopped at its renewal");
  // Every line the stream holds, as stored, in place order.
  const log = await reader[Symbol.for("libfx.durableInternals")].openLog(sessionId);
  let stored = [];
  for (let waited = 0; !stored.some((line) => line.delta === "kappa-0 ") && waited < 5000; waited += 50) {
    await sleep(50);
    stored = (await readLines(log.ui.read(0), 200)).map(({ type, epoch, delta }) => ({ type, epoch, delta }));
  }
  const lateAt = stored.findIndex((line) => line.delta === "kappa-0 ");
  assert.ok(lateAt >= 0, "the first step's line landed");
  await sleep(400);
  await live.stop();
  const replay = await readLines(reader.session(sessionId).stream(0));
  assert.deepEqual(shown(live.lines), shown(replay), "the live reader got the lines, under the cursors, a replay from cursor 0 gets");
  const takeover = stored.findIndex((line) => line.epoch > stored[0].epoch);
  assert.ok(takeover > 0 && lateAt > stored.findLastIndex((line) => line.epoch > stored[0].epoch), `the late line landed after the second worker's lines: ${JSON.stringify(stored)}`);
  // A reader that reconnects from the cursor of a line the live reader had
  // gets the lines the live reader had after it.
  const resumeAt = live.lines.findIndex((line) => line.epoch > live.lines[0].epoch);
  assert.deepEqual(shown(await readLines(reader.session(sessionId).stream(live.lines[resumeAt].cursor))), shown(live.lines.slice(resumeAt + 1)), "a reconnect from a cursor the live reader had");
  await a.close();
  await b.close();
  await reader.close();
  await closeQueueWorlds();
});

test("writers in other processes racing to write one stream land every chunk once, where every reader puts it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-stream-race-"));
  dirs.push(dir);
  const stream = "strm_01K00000000000000000STREAM_user_race";
  const world = await openWorld(dir);
  await world.streams.write(runId, stream, "start\n");
  const writers = Array.from({ length: 4 }, (_, index) => {
    const proc = spawn(process.execPath, [scriptPath, "--child", "--package", packageDir, "--dir", dir, "--stream", stream, "--writes", "40", "--tag", `w${index}`], { stdio: ["pipe", "pipe", "inherit"] });
    const lines = createInterface({ input: proc.stdout });
    const said = [];
    const waiting = [];
    lines.on("line", (line) => (waiting.length ? waiting.shift()(line) : said.push(line)));
    const next = () => said.length ? Promise.resolve(said.shift()) : new Promise((resolve) => waiting.push(resolve));
    const exited = new Promise((resolve) => proc.once("close", resolve));
    return { proc, next, exited };
  });
  for (const writer of writers) assert.equal(await writer.next(), "ready");
  // A reader in this process, on a World of its own, follows the stream.
  const readerWorld = await openWorld(dir);
  const reader = (await readerWorld.streams.get(runId, stream, 0)).getReader();
  const live = [];
  const following = (async () => {
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ done: true }));
      if (done) return;
      live.push(decoder.decode(value));
    }
  })();
  for (const writer of writers) writer.proc.stdin.write("go\n");
  for (const writer of writers) assert.equal(await writer.next(), "done");
  await Promise.all(writers.map((writer) => writer.exited));
  for (let waited = 0; live.length < 161 && waited < 5000; waited += 50) await sleep(50);
  await reader.cancel();
  await following;
  const replay = await replayOf(world, stream);
  assert.equal(replay.length, 161, "every chunk landed once");
  assert.equal(new Set(replay).size, 161, "no chunk landed twice");
  assert.deepEqual(live, replay, "the live reader got the chunks in a replay's order");
  for (const tag of ["w0", "w1", "w2", "w3"]) {
    const own = replay.filter((text) => text.startsWith(`${tag}-`));
    assert.deepEqual(own, own.map((_, index) => `${tag}-${index}\n`), `${tag}'s chunks are in its order`);
  }
  await readerWorld.close?.();
  await world.close?.();
});

test("one World's writes to a stream land in the order they were called", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-stream-order-"));
  dirs.push(dir);
  const world = await openWorld(dir);
  const stream = "strm_01K00000000000000000STREAM_user_order";
  let resolveRun;
  const later = new Promise((resolve) => { resolveRun = resolve; });
  // The first write waits for its run id, and the batch's first chunk is the
  // largest: neither lands ahead of what was called before it.
  const writes = [
    world.streams.write(later, stream, "one\n"),
    world.streams.write(runId, stream, "two\n"),
    world.streams.writeMulti(runId, stream, [`${"three".repeat(1 << 18)}\n`, "four\n", "five\n"]),
    world.streams.write(runId, stream, "six\n"),
  ];
  await sleep(50);
  assert.deepEqual(await replayOf(world, stream), [], "nothing landed ahead of the write still waiting for its run id");
  resolveRun(runId);
  await Promise.all(writes);
  await world.streams.close(runId, stream);
  const replay = (await replayOf(world, stream)).map((text) => text.slice(0, 5).replace(/\n$/, ""));
  assert.deepEqual(replay, ["one", "two", "three", "four", "five", "six"]);
  assert.equal((await world.streams.getChunks(runId, stream)).done, true, "the stream ended after its last chunk");
  await world.close?.();
});

test("on a file system that makes no hard links, chunks still land in order, and a World that links goes on after them", async () => {
  const dir = await mkdtemp(join(tmpdir(), "libfx-stream-nolinks-"));
  dirs.push(dir);
  const stream = "strm_01K00000000000000000STREAM_user_nolinks";
  // Written where links work, as a folder that moved since.
  const before = await openWorld(dir);
  await before.streams.write(runId, stream, "linked\n");
  await before.close?.();
  noLinks.on = true;
  const writers = [await openWorld(dir), await openWorld(dir)];
  try {
    for (const [index, text] of ["a", "b", "c", "d"].entries()) await writers[index % 2].streams.write(runId, stream, `${text}\n`);
  } finally {
    noLinks.on = false;
    for (const writer of writers) await writer.close?.();
  }
  const after = await openWorld(dir);
  await after.streams.write(runId, stream, "linked again\n");
  assert.deepEqual(await replayOf(after, stream), ["linked\n", "a\n", "b\n", "c\n", "d\n", "linked again\n"]);
  const files = await readdir(join(dir, "streams/chunks", stream));
  assert.deepEqual(files.filter((name) => !/^chnk_[0-9A-Z]{26}\.bin$/.test(name)), [], "no temporary file was left behind");
  assert.equal(files.length, 6);
  await after.close?.();
});

let failed = 0;
for (const [name, fn] of tests) {
  const started = performance.now();
  try {
    let timer;
    await Promise.race([fn(), new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("timed out after 60s")), 60_000); })]).finally(() => clearTimeout(timer));
    console.log(`ok ${name} (${(performance.now() - started).toFixed(0)}ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n  ${error?.stack ?? error}`);
  }
}
for (const dir of dirs) await rm(dir, { recursive: true, force: true }).catch(() => {});
console.log(`${tests.length - failed}/${tests.length} stream placement tests passed (${localModule})`);
process.exit(failed ? 1 : 0);
