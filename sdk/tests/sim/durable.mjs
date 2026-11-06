#!/usr/bin/env node
// Simulates durable libfx sessions (`createFxAgent`) on two workers that share
// one local() World, as two servers would, and checks from outside the rules
// a durable session keeps.
//
//   node sdk/tests/sim/durable.mjs [--seed S] [--runs N] [--steps N]
//     [--backend native|wasm] [--cuts N] [--plan file] [--shrink]
//
// A plan is a seeded list of steps: prompts on either worker, with base64
// images; prompts refused as invalid, a Blob among them; prompts whose signal
// aborts while their images are being stored; and crashes. A crash during a
// turn comes at its nth model request or the nth write its worker makes to
// the World, which can land or not; the host then sends the prompt again on
// the other worker under the same messageId, as a host that doesn't know
// whether it was stored does. A prompt step can also make the nth write
// either worker sends to the World fail, as storage does now and then; the
// host then sends the prompt again under its messageId, up to three times. A
// crashed worker's leases stop counting as alive, as a killed process's do,
// and nothing it writes lands any more: each of its calls to the World fails,
// so its code unwinds and frees its native runtime, as the end of its process
// would. A model request it already sent may still answer. Its slot gets a
// new agent, and both workers run one agent configuration.
//
// A steer step sends text guidance from either worker while a prompt's turn
// waits on its model, or once no turn runs, so it joins the next turn.
//
// Crash points: at writes the plan samples, the World's directory is copied
// as it stands, which is what a crash at that moment would leave. After the
// run each copy opens on a fresh agent, which sends one more prompt.
//
// Checked:
//   - every model request, by the request rules of checks.mjs;
//   - no session-log entry holds an image's bytes, and an entry names only
//     images whose writes have landed;
//   - the steps end as the API says: a prompt `end_turn`, a refused one
//     throws or rejects at once with nothing stored, an aborted one `cancelled`
//     with nothing stored;
//   - a last prompt's request holds every accepted prompt exactly once, in
//     the order they were accepted, and no refused or withdrawn one;
//   - every image a log entry names reads back with its bytes;
//   - a stored steer appears exactly once, after the prompt it was sent
//     during or after, and keeps the form it first came in, through the run
//     and its crashes and within each crash-point copy: a live update of the
//     turn it joined, or a turn's plain text;
//   - at each crash point, the new prompt's request holds every prompt that
//     had ended by then and every steer stored by then exactly once, and no
//     prompt that was never stored.
import { cpSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../node.js";
import { local } from "../../durable/local.mjs";
import { checkRequest, defaultRequestBytes, nativeRequestBytes, requestContext } from "./checks.mjs";
import { imagePool, lookupToolFor, modelStandIn, randomSource, settle } from "./world.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const addon = process.env.SIM_ADDON ?? resolve(scriptDir, "../../../zig-out/lib/libfx.node");
let wasmBytes = null;
const pool = imagePool();
const names = await Promise.all(pool.images.map(async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex")));
const liveHolders = globalThis[Symbol.for("libfx.liveHolders")] ??= new Set();
const internals = Symbol.for("libfx.durableInternals");
const windowOption = Symbol.for("libfx.imageWindow");
const workers = ["A", "B"];
// SIM_MEMORY=1: what of each run is still alive after it, by label.
const alive = new Set();
const finalized = new FinalizationRegistry((label) => alive.delete(label));
const track = (object, label) => {
  if (!process.env.SIM_MEMORY) return;
  alive.add(label);
  finalized.register(object, label);
};
const jpegBytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const badKinds = ["empty", "base64", "mislabeled", "tooMany", "blob"];
const badInput = (kind) => ({
  empty: () => "",
  base64: () => [{ type: "image", data: "aGVsbG8", mimeType: "image/png" }],
  mislabeled: () => [{ type: "image", data: jpegBytes.slice(), mimeType: "image/png" }],
  tooMany: () => Array.from({ length: 9 }, () => pool.block(0, "base64")),
  // A session prompt takes images as base64 only.
  blob: () => [{ type: "text", text: "look" }, { type: "image", data: new Blob([pool.images[0]], { type: "image/png" }) }],
})[kind]();

/** The plan seed `seed` makes: settings and `steps` steps. */
export function planDurable(seed, steps, cuts = 6) {
  const random = randomSource((seed ^ 0x5bd1e995) >>> 0);
  const on = {
    bad: random.chance(0.5),
    cancelRead: random.chance(0.5),
    crash: random.chance(0.5),
    crashDuring: random.chance(0.7),
    steer: random.chance(0.6),
    tool: random.chance(0.7),
    large: random.chance(0.5),
    // Tool calls return images.
    toolImages: random.chance(0.6),
    // Prompts go to either worker, or all to one.
    both: random.chance(0.6),
  };
  const plan = {
    seed,
    window: random.pick([null, { images: 3, bytes: 3_000_000 }, { images: 6, bytes: 8_000_000 }]),
    faultRate: random.pick([0, 0, 0.3]),
    // Writes after which a crash point is taken; a run that writes less
    // takes fewer.
    cutAt: [],
    features: Object.keys(on).filter((name) => on[name]),
    ops: [],
  };
  const images = () => {
    const chosen = [];
    let large = 0;
    for (let count = random.int(4); count > 0; count -= 1) {
      const wantsLarge = on.large && random.chance(0.18) && large < 2;
      if (wantsLarge) large += 1;
      chosen.push({ index: wantsLarge ? 10 + random.int(2) : random.int(10), form: "base64" });
    }
    return chosen;
  };
  // A tool call's images: up to three, at most one of the largest, so a
  // result stays within its 8 MiB.
  const toolShots = () => {
    if (!on.toolImages) return [];
    const shots = [];
    let large = false;
    for (let count = random.int(4); count > 0; count -= 1) {
      const wantsLarge = on.large && !large && random.chance(0.15);
      if (wantsLarge) large = true;
      shots.push(wantsLarge ? 10 + random.int(2) : random.int(10));
    }
    return shots;
  };
  const worker = () => (on.both ? random.pick(workers) : "A");
  const kinds = [["prompt", 6], ...["bad", "cancelRead", "crash", "crashDuring", "steer"].filter((kind) => on[kind]).map((kind) => [kind, kind === "crashDuring" || kind === "steer" ? 2 : 1])];
  const total = kinds.reduce((sum, [, weight]) => sum + weight, 0);
  const pickKind = () => {
    let roll = random.next() * total;
    for (const [kind, weight] of kinds) if ((roll -= weight) < 0) return kind;
    return "prompt";
  };
  for (let step = 1; step <= steps; step += 1) {
    const marker = (tool) => `sim-${seed}-${step}${tool ? "+tool" : ""}`;
    const kind = pickKind();
    if (kind === "prompt") {
      const fault = random.chance(plan.faultRate) ? { nth: 1 + random.int(6) } : null;
      const tool = on.tool && random.chance(0.35);
      plan.ops.push({ op: "prompt", worker: worker(), marker: marker(tool), images: images(), fault, toolImages: tool ? toolShots() : [] });
    } else if (kind === "bad") {
      plan.ops.push({ op: "bad", worker: worker(), kind: random.pick(badKinds), id: `bad-${seed}-${step}` });
    } else if (kind === "cancelRead") {
      plan.ops.push({ op: "cancelRead", worker: worker(), marker: marker(false), images: [...images(), { index: random.int(10), form: "base64" }] });
    } else if (kind === "crash") {
      plan.ops.push({ op: "crash", worker: worker() });
    } else if (kind === "steer") {
      plan.ops.push({ op: "steer", worker: worker(), sender: worker(), marker: marker(true), images: images(), at: random.pick(["request", "idle"]), id: `steer-${seed}-${step}`, toolImages: toolShots() });
    } else {
      const tool = on.tool && random.chance(0.5);
      plan.ops.push({
        op: "crashDuring",
        worker: worker(),
        marker: marker(tool),
        images: images(),
        at: random.pick(["request", "write"]),
        nth: 1 + random.int(4),
        toolImages: tool ? toolShots() : [],
      });
    }
  }
  const span = Math.max(1, steps * 14);
  const picked = new Set();
  for (let tries = 0; picked.size < cuts && tries < cuts * 10; tries += 1) picked.add(1 + random.int(span));
  plan.cutAt = [...picked].sort((a, b) => a - b);
  return plan;
}

const within = (promise, label, ms = 30_000) => {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, reject) => { timer = setTimeout(() => reject(Object.assign(new Error(`${label} took more than ${ms} ms`), { code: "SIM_HUNG" })), ms); }),
  ]);
};
const outcomeOf = (turn) => turn.result.then(
  (result) => (result.stopReason === "error" ? `error:${result.error?.code ?? result.error?.message ?? ""}` : result.stopReason),
  (error) => `rejected:${error?.code ?? error?.name}${error?.code || /^(TypeError|RangeError)$/.test(error?.name) ? "" : ` (${String(error?.message).slice(0, 160)})`}`,
);
const hang = () => new Promise(() => {});
const dead = () => Promise.reject(Object.assign(new Error("the worker crashed"), { code: "SIM_CRASHED" }));
// A prompt's messageId: its marker, in the letters a messageId allows.
const idOf = (marker) => marker.replace(/\+/g, "_");
const decoder = new TextDecoder();
const imageStreamSuffix = (name) => `_user_${Buffer.from(`libfx-image-${name}`).toString("base64url")}`;
// A session-log entry, as a World event that writes one carries it.
const logEntryOf = (event) => {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== "fx.log") return null;
  try {
    return JSON.parse(decoder.decode(event.eventData.input));
  } catch {
    return null;
  }
};
// An entry's text, with a record's stored events decoded.
const entryText = (entry) => {
  let text = JSON.stringify(entry);
  if (typeof entry?.data === "string") {
    try { text += Buffer.from(entry.data, "base64").toString("utf8"); } catch {}
  }
  return text;
};

/**
 * `object` as a worker sees it: every call goes through, until the worker
 * dies (`life.alive` false); then each call fails without going out, and a
 * call that was in flight fails, though what it wrote may have landed. A
 * dead worker's queue handler takes no more messages. `watch` sees
 * each World call with its arguments before it goes out (`before`) and once
 * it has landed (`after`).
 */
function mortal(object, life, watch, path = "") {
  const cache = new Map();
  return new Proxy(object, {
    get(target, key) {
      const value = Reflect.get(target, key);
      if (typeof key === "symbol") return typeof value === "function" ? value.bind(target) : value;
      if (cache.has(key)) return cache.get(key);
      let wrapped = value;
      if (typeof value === "function") {
        const name = `${path}${key}`;
        wrapped = (...args) => {
          if (!life.alive) return dead();
          // A queue handler of a dead worker takes no more messages.
          if (name === "createQueueHandler" && typeof args[1] === "function") {
            const handler = args[1];
            args = [args[0], (...input) => (life.alive ? handler(...input) : hang()), ...args.slice(2)];
          }
          if (watch.fails?.(name)) return Promise.reject(Object.assign(new Error("injected World write failure"), { code: "SIM_WORLD" }));
          watch.before?.(name, args, life);
          const result = value.apply(target, args);
          if (!(result instanceof Promise)) return result;
          return result.then((landed) => {
            watch.after?.(name, args, life);
            return life.alive ? landed : dead();
          });
        };
      } else if (value && typeof value === "object" && ["events", "streams", "runs", "steps", "hooks", "queue"].includes(key)) {
        wrapped = mortal(value, life, watch, `${path}${key}.`);
      }
      cache.set(key, wrapped);
      return wrapped;
    },
  });
}

/**
 * The rules `steers` broke in a request whose user messages are `users`: each
 * stored steer appears once, after the prompt it was sent during or after.
 */
function checkSteers(users, steers) {
  const broken = [];
  const text = users.map((user) => user.text).join("\n");
  for (const { id, after } of steers) {
    const found = [...text.matchAll(new RegExp(`${id}(?![0-9])`, "g"))];
    if (found.length !== 1) broken.push(`steer ${id}, which was stored, appears ${found.length} times`);
    const prompt = text.search(new RegExp(`${after.replace(/[+]/g, "\\+")}(?![0-9])`));
    if (found.length === 1 && prompt >= 0 && found[0].index < prompt) broken.push(`steer ${id} comes before ${after}, which it was sent during or after`);
  }
  return broken;
}

/** Runs `plan` on `backend`; returns the rules it broke and each step's outcome. */
export async function runDurable(plan, backend) {
  if (backend === "wasm") wasmBytes ??= await readFile(process.env.SIM_WASM ?? resolve(scriptDir, "../../../zig-out/bin/fx-core.wasm"));
  const dir = await mkdtemp(join(tmpdir(), "libfx-sim-durable-"));
  const broken = [];
  const outcomes = [];
  const endMarker = `sim-${plan.seed}-end`;
  const prompts = new Map([[endMarker, []]]);
  for (const op of plan.ops) if (op.marker) prompts.set(op.marker, op.images.map((image) => image.index));
  // The images each turn's tool call returns; older plans have none.
  const toolImages = new Map(plan.ops.filter((op) => op.toolImages?.length).map((op) => [op.marker, op.toolImages]));
  const context = requestContext({ pool, prompts, window: plan.window, tools: toolImages });
  const cap = Math.min(defaultRequestBytes, backend === "native" ? nativeRequestBytes : Infinity);
  let hook = null;
  const model = modelStandIn({ onRequest: (observed) => hook?.(observed) });
  track(model, `seed ${plan.seed} model`);
  let checked = 0;
  const checkRequests = (where) => {
    for (; checked < model.requests.length; checked += 1) {
      for (const rule of checkRequest(model.requests[checked], context, cap)) broken.push(`${where}: request ${checked + 1}: ${rule}`);
    }
  };

  // What reached the World, in order: the images whose writes landed, every
  // name a log entry gave, and the messageIds of the prompts stored.
  const landedImages = new Set();
  const named = new Set();
  const storedIds = new Set();
  // Writes that landed so far, from every worker; the write count when each
  // prompt ended and each steer was stored; and the crash-point copies.
  let writeCount = 0;
  const endedAt = new Map();
  const steers = [];
  const cutPoints = [];
  const cutAt = new Set(plan.cutAt ?? []);
  // Prompts never to appear: refused ones and ones withdrawn before stored.
  const absent = new Set();
  let where = "start";
  // The step's fault: the nth write to the World fails, once.
  let armed = null;
  const watch = {
    fails(name) {
      if (!armed || armed.fired || (name !== "events.create" && name !== "streams.write")) return false;
      armed.fired = ++armed.seen === armed.nth;
      return armed.fired;
    },
    before(name, args, life) {
      if (name !== "events.create") return;
      const entry = logEntryOf(args[1]);
      if (!entry) return;
      const text = entryText(entry);
      const held = pool.heldIn(Buffer.from(text));
      if (held >= 0) broken.push(`${where}: worker ${life.worker}'s log entry (${entry.k}) holds image ${held}'s bytes`);
      names.forEach((imageName, index) => {
        if (!text.includes(imageName)) return;
        named.add(imageName);
        if (!landedImages.has(imageName)) broken.push(`${where}: worker ${life.worker}'s log entry (${entry.k}) names image ${index} before its write landed`);
      });
    },
    after(name, args, life) {
      if (name === "streams.write") {
        const stream = String(args[1]);
        const index = names.findIndex((imageName) => stream.endsWith(imageStreamSuffix(imageName)));
        if (index >= 0) landedImages.add(names[index]);
      }
      if (name === "events.create") {
        const entry = logEntryOf(args[1]);
        if (entry?.k === "lease" && typeof entry.holder === "string") life.holders.add(entry.holder);
        if (entry?.k === "input" && entry.type === "prompt" && typeof entry.messageId === "string") storedIds.add(entry.messageId);
      }
      if (name === "events.create" || name === "streams.write") {
        writeCount += 1;
        if (cutAt.has(writeCount)) {
          // What a crash now leaves: every write that has landed, and no
          // file still being written.
          const copy = `${dir}-cut-${writeCount}`;
          cpSync(dir, copy, { recursive: true, filter: (source) => !source.includes(".tmp.") });
          cutPoints.push({ write: writeCount, dir: copy, absent: new Set(absent), stored: new Set(storedIds) });
        }
        life.writes += 1;
        life.onWrite?.();
      }
    },
  };

  // Both workers run one agent configuration, as two servers deploying the
  // same code do: libfx refuses two configurations of one agent name on one
  // store in a process. A worker's crash reaches it through its World, which
  // a configuration doesn't include: every call the dead worker makes to it
  // fails, so its turn stops at its next write.
  const fetch = (input, init) => model.fetch(input, init);
  const tools = [{ ...lookupToolFor({ pool, images: toolImages }), idempotent: true }];
  const slots = { A: null, B: null };
  const everyAgent = [];
  // Each agent's World as it is, under what its worker sees.
  const everyWorld = [];
  const make = (worker) => {
    const life = { alive: true, worker, writes: 0, holders: new Set(), onWrite: null };
    const stored = local({ dir });
    const durability = {
      ...stored,
      world: async () => {
        const world = await stored.world();
        everyWorld.push(world);
        track(world, `seed ${plan.seed} world ${everyWorld.length} (${worker})`);
        return mortal(world, life, watch);
      },
    };
    const agent = createFxAgent({
      backend,
      nativeAddon: addon,
      ...(backend === "wasm" ? { wasm: wasmBytes } : {}),
      apiKey: "sim-key",
      model: "sim/vision",
      fetch,
      tools,
      durability,
      ...(plan.window ? { [windowOption]: plan.window } : {}),
    });
    slots[worker] = { agent, life };
    everyAgent.push(agent);
    track(agent, `seed ${plan.seed} agent ${everyAgent.length} (${worker}, ${life.alive ? "live" : "dead"} at start)`);
    life.label = `seed ${plan.seed} agent ${everyAgent.length} (${worker})`;
    return slots[worker];
  };
  const live = (worker) => slots[worker] ?? make(worker);
  // The worker dies: its World never answers again, and its leases no
  // longer count as a running holder's.
  const kill = (worker) => {
    const slot = slots[worker];
    if (!slot) return;
    slot.life.alive = false;
    for (const holder of slot.life.holders) liveHolders.delete(holder);
    slots[worker] = null;
  };
  // One session, which either worker opens by its id.
  const sessionId = await live("A").agent.newSessionId();
  const sessionOn = (worker) => live(worker).agent.session(sessionId);
  // Until no live worker runs the session.
  const quiet = async () => {
    const started = Date.now();
    while (workers.some((worker) => slots[worker] && slots[worker].agent[internals].liveWorkers() > 0)) {
      if (Date.now() - started > 15_000) {
        broken.push(`${where}: a worker still runs the session 15 s after the step`);
        return;
      }
      await settle(4);
    }
    await settle(8);
  };
  const inputOf = (op) => [{ type: "text", text: op.marker }, ...op.images.map(({ index, form }) => pool.block(index, form))];
  // Accepted prompts, in order.
  const accepted = [];
  const accept = (marker) => {
    if (!accepted.includes(marker)) accepted.push(marker);
    if (!endedAt.has(marker)) endedAt.set(marker, writeCount);
  };

  for (const [index, op] of plan.ops.entries()) {
    where = `step ${index + 1} (${op.op} on ${op.worker}${op.marker ? ` ${op.marker}` : op.kind ? ` ${op.kind}` : ""})`;
    let outcome = "skipped";
    try {
      if (op.op === "prompt") {
        armed = op.fault ? { ...op.fault, seen: 0, fired: false } : null;
        const tries = [];
        for (let attempt = 0; attempt < 4; attempt += 1) {
          const worker = attempt % 2 === 0 ? op.worker : workers.find((each) => each !== op.worker);
          tries.push(await within(outcomeOf(sessionOn(worker).prompt(inputOf(op), { messageId: idOf(op.marker) })), `${where}: try ${attempt + 1}`));
          // Only a step whose write failed may end otherwise; its host sends
          // the prompt again.
          if (tries.at(-1) === "end_turn" || !armed?.fired) break;
          await quiet();
        }
        armed = null;
        outcome = tries.join(", then ");
        if (tries.at(-1) === "end_turn") accept(op.marker);
        else broken.push(`${where}: the turn ended ${outcome}`);
      } else if (op.op === "bad") {
        const before = storedIds.size;
        try {
          const turn = sessionOn(op.worker).prompt(badInput(op.kind), { messageId: op.id });
          outcome = await within(outcomeOf(turn), where);
        } catch (error) {
          outcome = `threw:${error?.code ?? error?.name}`;
        }
        if (!/^(threw|rejected):(TypeError|RangeError)$/.test(outcome)) broken.push(`${where}: libfx should refuse it at once, and it ${outcome}`);
        await quiet();
        if (storedIds.has(op.id) || storedIds.size !== before) broken.push(`${where}: a refused prompt was stored`);
      } else if (op.op === "cancelRead") {
        const input = inputOf(op);
        const controller = new AbortController();
        const turn = sessionOn(op.worker).prompt(input, { messageId: idOf(op.marker), signal: controller.signal });
        // The abort comes while the prompt's images are being stored.
        controller.abort();
        outcome = await within(outcomeOf(turn), where);
        if (outcome !== "cancelled") broken.push(`${where}: a prompt aborted while its images were being stored ended ${outcome}`);
        await quiet();
        if (storedIds.has(idOf(op.marker))) broken.push(`${where}: a prompt aborted while its images were being stored was stored`);
        absent.add(op.marker);
      } else if (op.op === "steer") {
        let steered = null;
        const sendSteer = () => {
          steered ??= sessionOn(op.sender).steer(op.id, { messageId: op.id }).then(
            () => { steers.push({ id: op.id, after: op.marker, storedAt: writeCount }); return "stored"; },
            (error) => `rejected:${error?.code ?? error?.name}`,
          );
        };
        if (op.at === "request") hook = (observed) => { if (observed.users.findLast((user) => user.marker !== null)?.marker === op.marker) sendSteer(); };
        const ended = await within(outcomeOf(sessionOn(op.worker).prompt(inputOf(op), { messageId: idOf(op.marker) })), where);
        hook = null;
        sendSteer();
        const steer = await within(steered, `${where}: the steer`);
        outcome = `${ended}, steer ${steer}`;
        if (ended === "end_turn") accept(op.marker);
        else broken.push(`${where}: the turn ended ${ended}`);
        if (steer !== "stored") broken.push(`${where}: the steer was ${steer}`);
      } else if (op.op === "crash") {
        kill(op.worker);
        outcome = "crashed";
      } else if (op.op === "crashDuring") {
        const slot = live(op.worker);
        let seen = 0;
        let crashed = false;
        // Settles when the crash comes; one that never comes holds nothing.
        let crashNoted;
        const crashedNow = new Promise((done) => { crashNoted = done; });
        const crash = () => {
          if (crashed) return;
          crashed = true;
          kill(op.worker);
          crashNoted("crashed");
        };
        if (op.at === "request") hook = (observed) => { if (observed.users.findLast((user) => user.marker !== null)?.marker === op.marker && ++seen === op.nth) crash(); };
        else slot.life.onWrite = () => { if (++seen === op.nth) crash(); };
        const turn = sessionOn(op.worker).prompt(inputOf(op), { messageId: idOf(op.marker) });
        void turn.result.catch(() => {});
        const first = await within(Promise.race([outcomeOf(turn), crashedNow]), where);
        hook = null;
        slot.life.onWrite = null;
        // Whether or not the crash came, the host can't tell whether the
        // prompt was stored, and sends it again on the other worker.
        if (!crashed) kill(op.worker);
        const other = workers.find((worker) => worker !== op.worker);
        outcome = `${first}, then ${await within(outcomeOf(sessionOn(other).prompt(inputOf(op), { messageId: idOf(op.marker) })), `${where}: the retry`)}`;
        if (outcome.endsWith("end_turn")) accept(op.marker);
        else broken.push(`${where}: the retry ended ${outcome}`);
      }
    } catch (error) {
      broken.push(`${where}: ${error?.code === "SIM_HUNG" ? error.message : `threw ${error?.stack ?? error}`}`);
    }
    await quiet();
    outcomes.push(outcome);
    if (process.env.SIM_TRACE) console.log(`${where}: ${outcome}`);
    checkRequests(where);
  }

  if (process.env.SIM_TRACE) console.log(`stored prompts: ${[...storedIds].join(" ")}`);
  // A last prompt shows the whole session.
  where = "the end";
  const before = model.requests.length;
  const last = await within(outcomeOf(sessionOn(workers.find((worker) => slots[worker]) ?? "A").prompt(endMarker, { messageId: idOf(endMarker) })), where).catch((error) => `threw:${error?.code}`);
  checkRequests(where);
  if (last !== "end_turn") broken.push(`the end: the last turn ended ${last}`);
  else {
    const users = model.requests.slice(before).at(-1)?.users ?? [];
    const markers = users.flatMap((user) => user.markers).filter((marker) => marker !== endMarker);
    for (const marker of new Set(markers)) {
      if (markers.filter((each) => each === marker).length > 1) broken.push(`the end: ${marker} appears ${markers.filter((each) => each === marker).length} times`);
      if (absent.has(marker)) broken.push(`the end: ${marker}, which was never stored, is in the session`);
    }
    for (const marker of accepted) if (!markers.includes(marker)) broken.push(`the end: ${marker}, which was accepted, is not in the session (it holds ${markers.join(" ") || "nothing"})`);
    for (const rule of checkSteers(users, steers)) broken.push(`the end: ${rule}`);
    const order = markers.filter((marker) => accepted.includes(marker));
    if (order.join(" ") !== accepted.filter((marker) => markers.includes(marker)).join(" ")) broken.push(`the end: the session holds its turns as ${order.join(" ")}, accepted as ${accepted.join(" ")}`);
  }
  // Every image the log named reads back with its bytes.
  const reader = slots.A ?? slots.B ?? make("A");
  {
    try {
      const log = await within(reader.agent[internals].openLog(sessionId), "opening the log");
      for (const imageName of named) {
        const bytes = await within(Promise.resolve(log.images.get(imageName)), "reading an image");
        const index = names.indexOf(imageName);
        if (!bytes || Buffer.compare(Buffer.from(bytes), Buffer.from(pool.images[index])) !== 0) broken.push(`the end: image ${index}, which the log names, reads back ${bytes ? "with other bytes" : "missing"}`);
      }
    } catch (error) {
      broken.push(`the end: reading the log failed: ${error?.message}`);
    }
  }
  // Live workers close as they would; a dead one's calls fail, so its close
  // frees its runtime too.
  await Promise.race([Promise.all(everyAgent.map((agent) => agent.close().catch(() => {}))), new Promise((done) => setTimeout(done, 10_000))]);
  for (const worker of workers) kill(worker);
  // A dead worker's World can't be closed through it, so its queue would
  // retry forever and hold the run in memory; close each one underneath, as
  // the end of a crashed process frees it.
  await Promise.race([Promise.all(everyWorld.map((world) => Promise.resolve(world.close?.()).catch(() => {}))), new Promise((done) => setTimeout(done, 10_000))]);

  // Each crash point opens on a fresh agent and runs one more prompt, which
  // first runs whatever the session still holds.
  const cutMarker = `sim-${plan.seed}-cut`;
  prompts.set(cutMarker, []);
  for (const cut of cutPoints) {
    where = `a crash after write ${cut.write}`;
    const cutModel = modelStandIn();
    const agent = createFxAgent({
      backend,
      nativeAddon: addon,
      ...(backend === "wasm" ? { wasm: wasmBytes } : {}),
      apiKey: "sim-key",
      model: "sim/vision",
      fetch: cutModel.fetch,
      tools: [{ ...lookupToolFor({ pool, images: toolImages }), idempotent: true }],
      durability: local({ dir: cut.dir }),
      ...(plan.window ? { [windowOption]: plan.window } : {}),
    });
    try {
      const probe = await within(outcomeOf(agent.session(sessionId).prompt(cutMarker, { messageId: idOf(cutMarker) })), `${where}: a new prompt`);
      // A copy reopened at a crash point can place a steer the run had stored
      // but not yet placed otherwise than the run did, as a live update of the
      // turn it resumes, so each copy keeps the forms its own requests show.
      const cutContext = requestContext({ pool, prompts, window: plan.window, tools: toolImages });
      for (const [at, observed] of cutModel.requests.entries()) {
        for (const rule of checkRequest(observed, cutContext, cap)) broken.push(`${where}: request ${at + 1}: ${rule}`);
      }
      if (probe !== "end_turn") broken.push(`${where}: a new prompt ended ${probe}`);
      else {
        const users = cutModel.requests.at(-1)?.users ?? [];
        const markers = users.flatMap((user) => user.markers).filter((marker) => marker !== cutMarker);
        for (const marker of new Set(markers)) {
          const times = markers.filter((each) => each === marker).length;
          if (times > 1) broken.push(`${where}: ${marker} appears ${times} times`);
          if (cut.absent.has(marker)) broken.push(`${where}: ${marker}, which was never stored, is in the session`);
        }
        for (const [marker, at] of endedAt) {
          if (at < cut.write && !markers.includes(marker)) broken.push(`${where}: ${marker}, which ended at write ${at}, is lost (it holds ${markers.join(" ") || "nothing"})`);
        }
        for (const rule of checkSteers(users, steers.filter((steer) => steer.storedAt < cut.write))) broken.push(`${where}: ${rule}`);
      }
    } catch (error) {
      broken.push(`${where}: ${error?.code === "SIM_HUNG" ? error.message : `threw ${error?.message}`}`);
    }
    await Promise.race([agent.close().catch(() => {}), new Promise((done) => setTimeout(done, 10_000))]);
    await rm(cut.dir, { recursive: true, force: true }).catch(() => {});
  }
  await rm(dir, { recursive: true, force: true }).catch(() => {});
  return { broken, outcomes, requests: model.requests.length, accepted: accepted.length, cuts: cutPoints.length };
}

// ---------------------------------------------------------------------------
// The command line

async function shrink(plan, backend) {
  let ops = plan.ops;
  let chunks = 2;
  while (ops.length > 1) {
    const size = Math.ceil(ops.length / chunks);
    let smaller = null;
    for (let start = 0; start < ops.length && !smaller; start += size) {
      const candidate = [...ops.slice(0, start), ...ops.slice(start + size)];
      if ((await runDurable({ ...plan, ops: candidate }, backend)).broken.length > 0) smaller = candidate;
    }
    if (smaller) {
      ops = smaller;
      chunks = Math.max(chunks - 1, 2);
    } else if (chunks >= ops.length) {
      break;
    } else {
      chunks = Math.min(chunks * 2, ops.length);
    }
  }
  return { ...plan, ops };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name, fallback) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : fallback);
  const firstSeed = Number(option("seed", 1));
  const runs = Number(option("runs", 10));
  const steps = Number(option("steps", 16));
  const cuts = Number(option("cuts", 6));
  const backend = option("backend", "native");
  const planFile = option("plan", null);
  let failed = 0;
  const started = Date.now();
  for (let run = 0; run < (planFile ? 1 : runs); run += 1) {
    const plan = planFile ? JSON.parse(await readFile(planFile, "utf8")) : planDurable(firstSeed + run, steps, cuts);
    const result = await runDurable(plan, backend);
    // SIM_MEMORY=1 shows the process's memory after each run.
    if (process.env.SIM_MEMORY) {
      // With --expose-gc, what is still held, not garbage not yet collected.
      for (let pass = 0; pass < 3; pass += 1) { globalThis.gc?.(); await settle(4); }
      const { rss, heapUsed, external, arrayBuffers } = process.memoryUsage();
      if (alive.size) console.log(`  still alive: ${[...alive].join(", ")}`);
      console.log(`  memory after seed ${plan.seed}: rss ${Math.round(rss / 1048576)} MiB, heap ${Math.round(heapUsed / 1048576)} MiB, external ${Math.round(external / 1048576)} MiB, buffers ${Math.round(arrayBuffers / 1048576)} MiB`);
    }
    if (result.broken.length === 0) {
      console.log(`ok seed ${plan.seed}: ${plan.ops.length} steps, ${result.accepted} prompts accepted, ${result.requests} requests, ${result.cuts} crash points`);
      continue;
    }
    failed += 1;
    console.log(`FAIL seed ${plan.seed}: ${result.requests} requests`);
    for (const rule of result.broken.slice(0, 12)) console.log(`  ${rule}`);
    let saved = plan;
    if (args.includes("--shrink")) {
      saved = await shrink(plan, backend);
      console.log(`  shrunk to ${saved.ops.length} steps`);
    }
    const file = join(tmpdir(), `libfx-sim-durable-${plan.seed}.json`);
    await writeFile(file, JSON.stringify(saved, null, 2));
    console.log(`  replay: node sdk/tests/sim/durable.mjs --plan ${file} --backend ${backend}`);
  }
  console.log(`${failed === 0 ? "ok" : "FAIL"} durable simulation: ${planFile ? 1 : runs} runs, ${failed} failed, ${Math.round((Date.now() - started) / 1000)} s`);
  process.exit(failed === 0 ? 0 : 1);
}
