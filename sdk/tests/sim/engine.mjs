#!/usr/bin/env node
// Simulates libfx engines that save a session to a store, under random
// sessions and injected faults, and checks the rules libfx keeps from the
// outside: what each model request carries and what the store holds.
//
// A run is a plan made from its seed: the session's settings (checkpoint
// threshold, image window, a provider size limit, store faults) and a list of
// steps: prompts with images as bytes, Blobs or base64; tool turns, some of
// which pause and are resumed; prompts libfx must refuse; crashes between
// turns and during them; cancels; and clean reopens. After every step the run
// checks each new model request and the store. At the end it reopens the
// store as it stood after every write, as a crash at that point would leave
// it, and checks that the session opens, resumes, and lost no turn that had
// finished.
//
//   node sdk/tests/sim/engine.mjs [--seed S] [--runs N] [--steps N]
//     [--backend native|wasm|both] [--cuts N] [--plan FILE] [--shrink]
//
// --backend both runs each plan on both backends and compares them. A failing
// plan is saved to a file that --plan replays; --shrink first removes steps
// while the plan still fails.
import { readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../../node.js";
import { checkRequest, checkSaved, defaultRequestBytes, nativeRequestBytes, requestContext } from "./checks.mjs";
import { faultyStore, imagePool, lookupToolFor, modelStandIn, randomSource, settle, storeAt } from "./world.mjs";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
// SIM_ADDON and SIM_WASM run another build, such as a mutant's.
const addon = process.env.SIM_ADDON ?? resolve(scriptDir, "../../../zig-out/lib/libfx.node");
const windowOption = Symbol.for("libfx.imageWindow");
const pool = imagePool();
let wasmBytes = null;

// ---------------------------------------------------------------------------
// Plans

const badKinds = ["empty", "base64", "mislabeled", "tooMany", "blobMislabeled", "unsupported"];
const jpegBytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const badInput = (kind) => ({
  empty: () => "",
  base64: () => [{ type: "image", data: "aGVsbG8", mimeType: "image/png" }],
  mislabeled: () => [{ type: "image", data: jpegBytes.slice(), mimeType: "image/png" }],
  tooMany: () => Array.from({ length: 9 }, () => pool.block(0, "base64")),
  blobMislabeled: () => [{ type: "image", data: new Blob([jpegBytes], { type: "image/png" }) }],
  unsupported: () => [{ type: "image", mimeType: "image/svg+xml", sourceRef: "host:sim" }],
})[kind]();

/** The plan seed `seed` makes: settings and `steps` steps. */
export function planRun(seed, steps) {
  const random = randomSource(seed);
  const plan = {
    seed,
    checkpointAfterBytes: random.pick([0, 0, 64 * 1024, 1024 * 1024]),
    window: random.pick([null, { images: 3, bytes: 3_000_000 }, { images: 6, bytes: 8_000_000 }]),
    // A provider that refuses requests past this share of the size libfx fits
    // them to. libfx lowers its limit to 3/4 of a refused request, twice per
    // turn, so it reaches any share above 0.5625 within a turn.
    providerShare: random.pick([null, null, 0.62, 0.8]),
    slowness: random.pick([0, 2, 6]),
    ops: [],
  };
  // A step's store fault: its nth append or image write fails, or the nth
  // image write of a tool's result.
  const faultRate = random.pick([0, 0, 0.3]);
  const toolImagesOn = random.chance(0.6);
  const faultKinds = toolImagesOn ? ["append", "image", "toolImage"] : ["append", "image"];
  const fault = () => (random.chance(faultRate) ? { kind: random.pick(faultKinds), nth: 1 + random.int(3) } : null);
  // Swarm testing: each plan turns each kind of step and feature on or off,
  // so some plans run long stretches of prompts and others mostly crash, and
  // a bug that needs one or the other is reached. Prompts are always on.
  const on = {
    bad: random.chance(0.5),
    crash: random.chance(0.5),
    crashDuring: random.chance(0.5),
    reopen: random.chance(0.5),
    cancel: random.chance(0.5),
    pause: random.chance(0.5),
    tool: random.chance(0.7),
    large: random.chance(0.6),
    toolImages: toolImagesOn,
  };
  plan.features = Object.keys(on).filter((name) => on[name]);
  // At most three images, at most two of the largest: within a prompt's 6 MiB.
  const images = () => {
    const chosen = [];
    let large = 0;
    for (let count = random.int(4); count > 0; count -= 1) {
      const wantsLarge = on.large && random.chance(0.18) && large < 2;
      if (wantsLarge) large += 1;
      chosen.push({ index: wantsLarge ? 10 + random.int(2) : random.int(10), form: random.pick(["bytes", "blob", "base64"]) });
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
  const kinds = [["prompt", 6], ...["bad", "crash", "crashDuring", "reopen", "cancel"].filter((kind) => on[kind]).map((kind) => [kind, 1])];
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
      const tool = on.tool && random.chance(0.35);
      plan.ops.push({ op: "prompt", marker: marker(tool), images: images(), pause: on.pause && tool && random.chance(0.4), fault: fault(), ...(tool ? { toolImages: toolShots() } : {}) });
    } else if (kind === "bad") {
      plan.ops.push({ op: "bad", kind: random.pick(badKinds) });
    } else if (kind === "crash" || kind === "reopen") {
      plan.ops.push({ op: kind });
    } else if (kind === "crashDuring") {
      plan.ops.push({ op: "crashDuring", marker: marker(true), images: images(), atRequest: 1 + random.int(2), fault: fault(), toolImages: toolShots() });
    } else {
      plan.ops.push({ op: "cancel", marker: marker(true), images: images(), fault: fault(), toolImages: toolShots() });
    }
  }
  return plan;
}

// ---------------------------------------------------------------------------
// Running a plan

const crashed = () => Object.assign(new Error("the process crashed"), { code: "SIM_CRASHED" });
const within = (promise, label, ms = 30_000) => {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, reject) => { timer = setTimeout(() => reject(Object.assign(new Error(`${label} took more than ${ms} ms`), { code: "SIM_HUNG" })), ms); }),
  ]);
};
// An error a call threw, as an outcome; one without a code says what it is.
const threwOf = (error) => `threw:${error?.code ?? error?.name}${error?.code || /^(TypeError|RangeError)$/.test(error?.name) ? "" : ` (${String(error?.message).slice(0, 160)})`}`;
const outcomeOf = (turn) => turn.result.then(
  (result) => (result.stopReason === "error" ? `error:${result.error?.code ?? result.error?.message ?? ""}` : result.stopReason),
  (error) => `rejected:${error?.code ?? error?.name}${error?.code || /^(TypeError|RangeError)$/.test(error?.name) ? "" : ` (${String(error?.message).slice(0, 160)})`}`,
);
// resume() returns null when no turn is open.
const resumeOutcome = (engine) => {
  const turn = engine.resume();
  return turn ? outcomeOf(turn) : Promise.resolve("idle");
};
// Waits until the store has taken no write for a while: a turn saves its
// checkpoint after it ends.
const quiet = async (box) => {
  for (let stable = 0, last = box.writes(); stable < 4; ) {
    await settle(8);
    const now = box.writes();
    stable = now === last ? stable + 1 : 0;
    last = now;
  }
};

/**
 * Runs `plan` on `backend` and returns the rules it broke, each step's
 * outcome, and the turns a final request held.
 */
export async function executePlan(plan, backend, { cuts: cutLimit = 60 } = {}) {
  if (backend === "wasm") wasmBytes ??= await readFile(process.env.SIM_WASM ?? resolve(scriptDir, "../../../zig-out/bin/fx-core.wasm"));
  const box = faultyStore({ slowness: plan.slowness });
  const endMarker = `sim-${plan.seed}-end`;
  const cutMarker = `sim-${plan.seed}-cut`;
  const prompts = new Map([[endMarker, []], [cutMarker, []]]);
  const order = new Map();
  plan.ops.forEach((op, index) => {
    if (!op.marker) return;
    prompts.set(op.marker, op.images.map((image) => image.index));
    order.set(op.marker, index);
  });
  // The images each turn's tool call returns; older plans have none.
  const toolImages = new Map(plan.ops.filter((op) => op.toolImages?.length).map((op) => [op.marker, op.toolImages]));
  const context = requestContext({ pool, prompts, window: plan.window, tools: toolImages });
  const broken = [];
  const outcomes = [];
  // The store's write count when each turn finished: a crash after it must not lose the turn.
  const completedAt = new Map();
  // Only an engine that a fault hit may report that failure. A turn's last
  // records are lazy, so the turn can end first and a later call report it.
  let firedAtOpen = 0;
  const faulted = () => box.fired() > firedAtOpen;
  const allowedFault = (outcome) => faulted() && /FX_JOURNAL_APPEND_FAILED|SIM_APPEND|SIM_PUT/.test(outcome);

  let hook = null;
  const transportCap = backend === "native" ? nativeRequestBytes : Infinity;
  const providerLimit = plan.providerShare ? Math.floor(plan.providerShare * Math.min(defaultRequestBytes, transportCap)) : null;
  const model = modelStandIn({ providerLimit, onRequest: (observed) => { box.toolRunning(false); return hook?.(observed); } });
  // An engine learns a smaller limit when it retries a request a provider
  // refused as too large; a new engine starts from the default again. A
  // refusal a cancel overtook is never retried, so nothing is learned from it.
  const opensAt = new Set();
  let learned = null;
  // A refusal no retry followed, such as one a cancel overtook, may still have
  // taught the engine a limit: it learns when it handles the refusal, and the
  // cancel can land after that, so the retry never goes out.
  let maybeLearned = null;
  let checked = 0;
  // The newest prompt a request carries; a resumed turn's ends with a notice.
  const newestMarker = (observed) => observed.users.findLast((user) => user.marker !== null)?.marker ?? null;
  const checkRequests = (where, requests = model.requests) => {
    for (; checked < requests.length; checked += 1) {
      const observed = requests[checked];
      const previous = requests[checked - 1];
      if (opensAt.has(checked)) {
        learned = null;
        maybeLearned = null;
      } else if (previous?.rejected && newestMarker(previous) === newestMarker(observed)) {
        learned = Math.min(learned ?? Infinity, Math.floor(previous.bytes / 4) * 3);
        if (process.env.SIM_TRACE) console.log(`  check: request ${checked + 1} retries ${checked} (${newestMarker(observed)}); the limit is ${learned}`);
      } else if (previous?.rejected) {
        maybeLearned = Math.min(maybeLearned ?? Infinity, Math.floor(previous.bytes / 4) * 3);
      }
      const cap = Math.min(learned ?? defaultRequestBytes, transportCap);
      const fitCap = Math.min(cap, maybeLearned ?? Infinity);
      for (const rule of checkRequest(observed, context, cap, fitCap)) broken.push(`${where}: request ${checked + 1}: ${rule}`);
    }
  };
  const optionsFor = (life, persistence, fetch) => ({
    backend,
    nativeAddon: addon,
    ...(backend === "wasm" ? { wasm: wasmBytes } : {}),
    apiKey: "sim-key",
    model: "sim/vision",
    fetch: async (input, init) => {
      if (!life.alive) throw crashed();
      const response = await fetch(input, init);
      if (!life.alive) throw crashed();
      return response;
    },
    persistence,
    checkpointAfterBytes: plan.checkpointAfterBytes,
    tools: [lookupToolFor({ pool, images: toolImages, onRun: () => box.toolRunning(true) })],
    ...(plan.window ? { [windowOption]: plan.window } : {}),
  });

  let life = null;
  let engine = null;
  const open = async (where) => {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      life = { alive: true };
      firedAtOpen = box.fired();
      opensAt.add(model.requests.length);
      try {
        engine = await within(createFxEngine(optionsFor(life, box.persistenceFor(life), model.fetch)), `${where}: opening`);
        return;
      } catch (error) {
        engine = null;
        if (error?.code === "SIM_APPEND") continue;
        broken.push(`${where}: the session did not open: ${error?.code ?? ""} ${error?.message}`);
        return;
      }
    }
    broken.push(`${where}: the session did not open through eight injected append failures`);
  };
  const kill = () => {
    if (life) life.alive = false;
    const dead = engine;
    engine = null;
    void dead?.close().catch(() => {});
  };
  // A host that hit an append failure starts a new engine.
  const restart = async (where) => {
    kill();
    await open(where);
  };
  // Continues whatever turn the store holds open, as a host does whenever it
  // opens a session or before it sends more: a turn that paused, or one a
  // crash or a failed append cut off. The turn it finishes is the one its
  // requests carry.
  let resuming = false;
  const resumeOpen = async (where) => {
    if (resuming) return;
    resuming = true;
    try {
      for (let attempt = 0; engine && attempt < 4; attempt += 1) {
        const before = model.requests.length;
        let outcome;
        try {
          outcome = await within(resumeOutcome(engine), `${where}: resuming`);
        } catch (error) {
          outcome = threwOf(error);
        }
        if (outcome === "idle") return;
        const last = model.requests.slice(before).at(-1);
        const marker = last ? newestMarker(last) : null;
        if (outcome === "end_turn") {
          if (marker) completedAt.set(marker, box.writes());
          return;
        }
        if (allowedFault(outcome)) {
          await restart(`${where}: after a resume's injected fault`);
          continue;
        }
        if (outcome !== "yielded") broken.push(`${where}: resuming ${marker ?? "the open turn"} ended ${outcome}`);
        return;
      }
    } finally {
      resuming = false;
    }
  };
  const ready = async (where) => {
    if (!engine) await open(where);
    await resumeOpen(where);
    return engine !== null;
  };
  const inputOf = (op) => [{ type: "text", text: op.marker }, ...op.images.map(({ index, form }) => pool.block(index, form))];

  await open("start");
  for (const [index, op] of plan.ops.entries()) {
    const where = `step ${index + 1} (${op.op}${op.marker ? ` ${op.marker}` : op.kind ? ` ${op.kind}` : ""})`;
    let outcome = "skipped";
    box.arm(op.fault ?? null);
    try {
      if (op.op === "prompt" || op.op === "cancel") {
        if (await ready(where)) {
          for (let attempt = 0; attempt < 3; attempt += 1) {
            const controller = new AbortController();
            if (op.op === "cancel") hook = (observed) => { if (newestMarker(observed) === op.marker) controller.abort(); };
            try {
              const turn = engine.prompt(inputOf(op), { ...(op.pause ? { yieldAt: Date.now() } : {}), ...(op.op === "cancel" ? { signal: controller.signal } : {}) });
              outcome = await within(outcomeOf(turn), where);
            } catch (error) {
              outcome = threwOf(error);
            }
            hook = null;
            if (outcome !== "threw:FX_JOURNAL_APPEND_FAILED" || !faulted()) break;
            await restart(where);
            if (!(await ready(where))) break;
          }
          if (outcome === "end_turn") completedAt.set(op.marker, box.writes());
          else if (outcome === "yielded" && op.pause) { /* the next step resumes it */ }
          else if (outcome === "cancelled" && op.op === "cancel") { /* the turn ended cancelled */ }
          else if (allowedFault(outcome)) {
            if (/APPEND/.test(outcome)) await restart(where);
          } else broken.push(`${where}: the turn ended ${outcome}`);
        }
      } else if (op.op === "bad") {
        if (await ready(where)) {
          await quiet(box);
          const before = box.writes();
          try {
            outcome = await within(outcomeOf(engine.prompt(badInput(op.kind))), where);
          } catch (error) {
            outcome = threwOf(error);
          }
          await settle(4);
          if (!/^(threw|rejected):(TypeError|RangeError)$/.test(outcome)) broken.push(`${where}: libfx should refuse it at once, and it ${outcome}`);
          // A turn's end saves a checkpoint it owes, of what was stored
          // before; a refused prompt adds no record and no image.
          const wrote = box.states.slice(before).map((state) => state.kind).filter((kind) => kind !== "checkpoint");
          if (wrote.length > 0) broken.push(`${where}: a refused prompt wrote to the store: ${wrote.join(", ")}`);
        }
      } else if (op.op === "crash") {
        kill();
        await ready(where);
        outcome = "crashed";
      } else if (op.op === "reopen") {
        if (engine) await within(engine.close(), `${where}: closing`);
        engine = null;
        await ready(where);
        outcome = "reopened";
      } else if (op.op === "crashDuring") {
        if (await ready(where)) {
          let seen = 0;
          const dying = life;
          let crash;
          const crashedNow = new Promise((resolve) => { crash = resolve; });
          hook = (observed) => {
            if (newestMarker(observed) === op.marker && ++seen === op.atRequest) {
              dying.alive = false;
              crash("crashed");
            }
          };
          let turn = null;
          try {
            turn = engine.prompt(inputOf(op));
          } catch (error) {
            outcome = threwOf(error);
          }
          if (turn) {
            void turn.result.catch(() => {});
            outcome = await within(Promise.race([crashedNow, outcomeOf(turn)]), where);
          }
          hook = null;
          if (outcome === "end_turn") completedAt.set(op.marker, box.writes());
          else {
            kill();
            await ready(where);
          }
        }
      }
    } catch (error) {
      broken.push(`${where}: ${error?.code === "SIM_HUNG" ? error.message : `threw ${error?.stack ?? error}`}`);
      kill();
    }
    box.arm(null);
    outcomes.push(outcome);
    if (process.env.SIM_TRACE) console.log(`${where}: ${outcome}`);
    checkRequests(where);
    const toolRefusals = box.refusals().filter((refusal) => refusal.duringTool);
    // A tool image the store refused stays in its result, in the saved data.
    const inline = new Set(toolRefusals.map((refusal) => pool.heldIn(refusal.bytes)).filter((index) => index >= 0));
    for (const rule of checkSaved(box.store, pool, inline)) broken.push(`${where}: ${rule}`);
  }

  // A last turn, whose request shows the whole saved session.
  let finalMarkers = [];
  if (await ready("the end")) {
    const before = model.requests.length;
    const outcome = await within(outcomeOf(engine.prompt(endMarker)), "the end").catch((error) => `threw:${error?.code}`);
    if (outcome === "end_turn") finalMarkers = (model.requests.slice(before).at(-1)?.users ?? []).flatMap((user) => user.markers).filter((marker) => marker !== endMarker);
    else if (!allowedFault(outcome)) broken.push(`the end: the last turn ended ${outcome}`);
    await engine.close().catch(() => {});
  }
  checkRequests("the end");

  // A crash after any write: the store as it stood then opens, resumes, and
  // has every turn that had finished by then, in order and once.
  const total = box.states.length;
  const picked = total <= cutLimit ? Array.from({ length: total }, (_, index) => index + 1)
    : [...new Set(Array.from({ length: cutLimit }, (_, index) => Math.max(1, Math.round(((index + 1) * total) / cutLimit))))];
  for (const k of picked) {
    const state = box.states[k - 1];
    const where = `a crash after write ${k} of ${total} (${state.kind})`;
    if (process.env.SIM_TRACE) console.log(`${where}:`);
    const cutModel = modelStandIn();
    const cutLife = { alive: true };
    let cutEngine;
    try {
      cutEngine = await within(createFxEngine(optionsFor(cutLife, await storeAt(state), cutModel.fetch)), `${where}: opening`);
    } catch (error) {
      broken.push(`${where}: the session did not open: ${error?.code ?? ""} ${error?.message}`);
      continue;
    }
    try {
      const resumed = await within(resumeOutcome(cutEngine), `${where}: resuming`);
      if (resumed !== "idle" && resumed !== "end_turn") broken.push(`${where}: resuming ended ${resumed}`);
      const probe = await within(outcomeOf(cutEngine.prompt(cutMarker)), `${where}: a new turn`);
      if (probe !== "end_turn") broken.push(`${where}: a new turn ended ${probe}`);
    } catch (error) {
      broken.push(`${where}: ${error?.message}`);
    }
    await cutEngine.close().catch(() => {});
    const cutContext = requestContext({ pool, prompts, window: plan.window, tools: toolImages });
    for (const [at, observed] of cutModel.requests.entries()) {
      for (const rule of checkRequest(observed, cutContext, Math.min(defaultRequestBytes, transportCap))) broken.push(`${where}: request ${at + 1}: ${rule}`);
    }
    const markers = (cutModel.requests.at(-1)?.users ?? []).flatMap((user) => user.markers).filter((marker) => marker !== cutMarker);
    if (new Set(markers).size !== markers.length) broken.push(`${where}: a turn appears twice`);
    const positions = markers.map((marker) => order.get(marker));
    if (positions.some((position, at) => at > 0 && position < positions[at - 1])) broken.push(`${where}: its turns are out of order`);
    for (const [marker, at] of completedAt) {
      if (at <= k && !markers.includes(marker)) broken.push(`${where}: ${marker}, which finished at write ${at}, is lost (it holds ${markers.join(", ") || "no turn"})`);
    }
  }
  return { broken, outcomes, finalMarkers, writes: total, cuts: picked.length, requests: model.requests.length };
}

// ---------------------------------------------------------------------------
// The command line

/** The plan with as few steps as still break a rule on `backend`. */
async function shrink(plan, backend, cuts) {
  let ops = plan.ops;
  let chunks = 2;
  while (ops.length > 1) {
    const size = Math.ceil(ops.length / chunks);
    let smaller = null;
    for (let start = 0; start < ops.length && !smaller; start += size) {
      const candidate = [...ops.slice(0, start), ...ops.slice(start + size)];
      if ((await executePlan({ ...plan, ops: candidate }, backend, { cuts })).broken.length > 0) smaller = candidate;
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
  // Then each fault that the failure does not need.
  for (let index = 0; index < ops.length; index += 1) {
    if (!ops[index].fault) continue;
    const candidate = ops.map((op, at) => (at === index ? { ...op, fault: null } : op));
    if ((await executePlan({ ...plan, ops: candidate }, backend, { cuts })).broken.length > 0) ops = candidate;
  }
  return { ...plan, ops };
}

// Racy steps may end either way, so only the others compare across backends.
const comparable = (plan, outcomes) => outcomes.filter((_, index) => !["cancel", "crashDuring"].includes(plan.ops[index].op));

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const option = (name, fallback) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : fallback);
  const firstSeed = Number(option("seed", 1));
  const runs = Number(option("runs", 10));
  const steps = Number(option("steps", 24));
  const cuts = Number(option("cuts", 60));
  const backendOption = option("backend", "native");
  const planFile = option("plan", null);
  const backends = backendOption === "both" ? ["native", "wasm"] : [backendOption];
  let failed = 0;
  const started = Date.now();
  for (let run = 0; run < (planFile ? 1 : runs); run += 1) {
    const plan = planFile ? JSON.parse(await readFile(planFile, "utf8")) : planRun(firstSeed + run, steps);
    const results = [];
    for (const backend of backends) results.push({ backend, ...(await executePlan(plan, backend, { cuts })) });
    const broken = results.flatMap(({ backend, broken }) => broken.map((rule) => `${backend}: ${rule}`));
    // A fault fails the nth write, and each backend batches its records its
    // own way, so a fault lands on different records: only a plan without
    // faults compares across backends.
    if (results.length === 2 && !plan.ops.some((op) => op.fault)) {
      const [a, b] = results;
      if (JSON.stringify(comparable(plan, a.outcomes)) !== JSON.stringify(comparable(plan, b.outcomes))) {
        broken.push(`the backends' steps ended differently: ${JSON.stringify(comparable(plan, a.outcomes))} against ${JSON.stringify(comparable(plan, b.outcomes))}`);
      }
      if (JSON.stringify(a.finalMarkers) !== JSON.stringify(b.finalMarkers)) broken.push(`the backends' sessions hold different turns: ${a.finalMarkers.join(" ")} against ${b.finalMarkers.join(" ")}`);
    }
    const summary = results.map(({ backend, writes, cuts: cut, requests }) => `${backend} ${requests} requests, ${writes} writes, ${cut} crash points`).join("; ");
    if (broken.length === 0) {
      console.log(`ok seed ${plan.seed}: ${plan.ops.length} steps; ${summary}`);
      continue;
    }
    failed += 1;
    console.log(`FAIL seed ${plan.seed}: ${summary}`);
    for (const rule of broken.slice(0, 12)) console.log(`  ${rule}`);
    let saved = plan;
    if (args.includes("--shrink")) {
      saved = await shrink(plan, results.find((result) => result.broken.length > 0)?.backend ?? backends[0], cuts);
      console.log(`  shrunk to ${saved.ops.length} steps`);
    }
    const file = join(tmpdir(), `libfx-sim-engine-${plan.seed}.json`);
    await writeFile(file, JSON.stringify(saved, null, 2));
    console.log(`  replay: node sdk/tests/sim/engine.mjs --plan ${file} --backend ${backendOption}`);
  }
  console.log(`${failed === 0 ? "ok" : "FAIL"} engine simulation: ${planFile ? 1 : runs} runs, ${failed} failed, ${Math.round((Date.now() - started) / 1000)} s`);
  process.exit(failed === 0 ? 0 : 1);
}
