#!/usr/bin/env bun
// Drives real libfx along paths of the TLC state graph of PromptIntake.tla,
// and checks after every step that the code is in a state the model allows.
//
//   bun tests/tla/drivers/drive-intake.mjs [--walks N] [--seed S] [--durability memory|world]
//     [--harness fx|scripted] [--backend native|wasm]
//
// Each walk opens one agent and one session object, which makes the prompts
// the walk chooses: text, or a prompt with an image to prepare: base64 data
// whose write to the session's image store waits until the driver lets it
// land or fail. Every log write
// of a prompt, or of a prompt's cancel, waits until the driver lets it land
// or fail. With the fx harness each turn runs on a real fx engine, whose
// model request the driver holds until it ends the turn; with the scripted
// harness a turn is a stand-in the driver ends. After each step the driver
// waits until the code is quiet, reads back what it shows, and moves to the
// model states that show the same. Every stored prompt must name its image,
// already in the image store with the caller's bytes; and every model
// request must carry its prompt's image unchanged.
//
// `tests/tla/sdk/check.sh` writes graphs/intake.dot from PromptIntake-drive.cfg.
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { createFxAgent, memory } from "../../../sdk/node.js";
import { createDurableAgentFactory } from "../../../sdk/durable.js";
import { loadGraph, walkGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const walks = Number(option("walks", 40));
let seed = Number(option("seed", 1));
const durabilityKind = option("durability", "memory");
const harnessKind = option("harness", "fx");
const backend = option("backend", "native");
if (!["memory", "world"].includes(durabilityKind)) throw new Error("--durability is memory or world");
if (!["fx", "scripted"].includes(harnessKind)) throw new Error("--harness is fx or scripted");
const verbose = args.includes("--verbose");
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = harnessKind === "fx" && backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
// How long the code must show nothing new before a step has settled. An fx
// engine takes a moment to open, and a World's stream a moment to read.
const quietMs = (harnessKind === "fx" ? 200 : 60) + (durabilityKind === "world" ? 350 : 0);
const stepTimeoutMs = 10_000;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!check()) {
    if (Date.now() - started > ms) return false;
    await sleep(5);
  }
  return true;
};
const base64 = (bytes) => Buffer.from(bytes).toString("base64");
const deferred = () => {
  let resolveIt;
  let rejectIt;
  const promise = new Promise((resolveP, rejectP) => { resolveIt = resolveP; rejectIt = rejectP; });
  promise.catch(() => {});
  return { promise, resolve: resolveIt, reject: rejectIt };
};
// A PNG the kernel accepts, followed by bytes that name the walk and prompt,
// so each prompt's image is its own.
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");
const imageOf = (walk, i) => new Uint8Array(Buffer.concat([png, Buffer.from(`walk-${walk}-prompt-${i}`.padEnd(24, "."))]));

const nameOf = async (bytes) => Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
// An image's stream on a World, as libfx names it.
const imageStreamSuffix = (name) => `_user_${Buffer.from(`libfx-image-${name}`).toString("base64url")}`;

// A durability whose log writes of prompts and their cancels wait for the
// driver, which lets each land or fail, as do the image writes it is told to
// hold (`holdImage`). `images` has the bytes of every image write that
// landed, by name. Works on memory() and on a World.
function heldInputs(durability) {
  const held = new Map();
  const landed = [];
  const images = new Map();
  const heldImages = new Map();
  let open = false;
  const throughImage = async (name, bytes, write) => {
    const hold = heldImages.get(name);
    if (hold && !open) {
      heldImages.delete(name);
      if (!(await hold.promise)) throw Object.assign(new Error("injected image write failure"), { code: "FX_TEST_FAULT" });
    }
    const result = await write();
    images.set(name, Buffer.from(bytes).toString("base64"));
    return result;
  };
  const keyOf = (entry) => {
    if (entry?.k !== "input") return null;
    if (entry.type === "prompt") return `prompt:${entry.messageId}`;
    if (entry.type === "cancel" && typeof entry.target === "string") return `cancel:${entry.target}`;
    return null;
  };
  const through = async (entry, write) => {
    const key = keyOf(entry);
    if (key !== null && !open) {
      const lands = await new Promise((go) => held.set(key, { go }));
      held.delete(key);
      if (!lands) throw Object.assign(new Error("injected log write failure"), { code: "FX_TEST_FAULT" });
    }
    const result = await write();
    if (key !== null) landed.push(entry);
    return result;
  };
  const control = {
    held,
    landed,
    images,
    // The next write of the image named `name` waits for `settleImage`.
    holdImage(name) {
      const gate = {};
      gate.promise = new Promise((go) => { gate.go = go; });
      heldImages.set(name, gate);
      return gate;
    },
    async settle(key, lands) {
      if (!(await until(() => held.has(key)))) throw new Error(`no log write is held for ${key}`);
      held.get(key).go(lands);
    },
    openAll() {
      open = true;
      for (const item of [...held.values()]) item.go(true);
      for (const gate of [...heldImages.values()]) gate.go(true);
    },
  };
  if (typeof durability.create === "function") {
    const create = durability.create;
    const wrapped = new WeakMap();
    return [{
      ...durability,
      create() {
        const backend = create();
        if (!wrapped.has(backend)) {
          wrapped.set(backend, {
            ...backend,
            async session(id) {
              const log = await backend.session(id);
              return {
                ...log,
                append: (entry) => through(entry, () => log.append(entry)),
                images: { put: (name, bytes) => throughImage(name, bytes, () => log.images.put(name, bytes)), get: (name) => log.images.get(name) },
              };
            },
          });
        }
        return wrapped.get(backend);
      },
    }, control];
  }
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      // An image write is a write of its stream; the driver knows its name.
      const streams = new Proxy(world.streams, {
        get(target, key) {
          if (key !== "write") return bound(target, key);
          return async (runId, stream, chunk) => {
            const name = [...pendingNames].find((candidate) => String(stream).endsWith(imageStreamSuffix(candidate)));
            if (name === undefined) return target.write(runId, stream, chunk);
            return throughImage(name, chunk, () => target.write(runId, stream, chunk));
          };
        },
      });
      const events = new Proxy(world.events, {
        get(target, key) {
          if (key !== "create") return bound(target, key);
          return async (runId, event, params) => {
            if (event?.eventType !== "step_created" || event.eventData?.stepName !== "fx.log") return target.create(runId, event, params);
            // What the World stores, read back as the log reads it.
            const entry = JSON.parse(decoder.decode(event.eventData.input));
            return through(entry, () => target.create(runId, event, params));
          };
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "events" ? events : key === "streams" ? streams : bound(target, key)) });
    },
  }, control];
}
// The names of the walk's images, so a World's stream writes can be told
// apart from its other streams'.
const pendingNames = new Set();

// ---------------------------------------------------------------------------
// The code under test: one agent, one session object.

const vision = "intake/vision";
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const answer = (text) => new Response(
  [{ type: "text-delta", id: "a", delta: text }, { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage }, "[DONE]"]
    .map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
const promptNumber = (text) => Number(/prompt-(\d+)/.exec(text ?? "")?.[1]);

async function harness(walk, n) {
  const dir = await mkdtemp(join(tmpdir(), "libfx-intake-"));
  const [durability, writes] = heldInputs(durabilityKind === "world" ? await appWorldAt(dir) : memory());
  const expected = {};
  const names = {};
  const kinds = {};
  const imageGates = {};
  const controllers = {};
  const turnsRunning = new Map();
  const started = new Set();
  const acc = {};
  const accError = {};
  const res = {};
  const early = {};
  const problems = [];
  let made = 0;
  let closed = false;
  let closing = null;
  // Each turn's image as the model or the stand-in turn received it; a text
  // prompt's turn receives none.
  const received = (i, image) => {
    if (kinds[i] === "text") {
      if (image !== undefined) problems.push(`text prompt ${i}'s turn received an image`);
      return;
    }
    if (image?.data !== expected[i] || image?.mimeType !== "image/png") problems.push(`prompt ${i}'s turn received ${JSON.stringify(image).slice(0, 120)}`);
  };
  const turnStarted = (i, end, abortWith) => {
    if (started.has(i)) problems.push(`prompt ${i}'s turn started twice`);
    started.add(i);
    turnsRunning.set(i, { end, abortWith });
  };
  let agent;
  if (harnessKind === "fx") {
    agent = createFxAgent({
      backend,
      nativeAddon: addon,
      ...(wasm ? { wasm } : {}),
      apiKey: "intake-key",
      model: vision,
      durability,
      async fetch(input, init) {
        // The WebAssembly host passes a Request, the native one a URL and init.
        const request = input instanceof Request ? input : new Request(input, init);
        if (request.method === "GET") return Response.json({ object: "list", data: [{ id: vision, type: "language", tags: ["vision", "file-input"] }] });
        const prompt = JSON.parse(await request.text()).prompt;
        const last = prompt.filter((message) => message.role === "user").at(-1);
        const parts = Array.isArray(last?.content) ? last.content : [];
        const i = promptNumber(parts.filter((part) => part.type === "text").map((part) => part.text).join(""));
        const images = parts.filter((part) => part.type === "file");
        if (images.length !== (kinds[i] === "text" ? 0 : 1)) problems.push(`prompt ${i}'s model request carries ${images.length} images`);
        received(i, images[0] && { data: images[0].data?.data, mimeType: images[0].mediaType });
        const signal = init?.signal ?? request.signal;
        return new Promise((resolveResponse, rejectResponse) => {
          turnStarted(i, () => { turnsRunning.delete(i); resolveResponse(answer(`answered ${i}`)); });
          signal?.addEventListener("abort", () => { turnsRunning.delete(i); rejectResponse(signal.reason ?? new Error("aborted")); }, { once: true });
        });
      },
    });
  } else {
    agent = createDurableAgentFactory({
      harness: () => ({
        async open({ store }) {
          await store.load();
          let key = 0;
          const append = (record, marks) => store.append({ idempotencyKey: `intake:${Date.now()}:${key++}`, data: encoder.encode(JSON.stringify(record)), marks });
          return {
            prompt(input, { turnId }) {
              const i = promptNumber(input?.[0]?.text);
              received(i, input?.[1]);
              const ended = deferred();
              const result = (async () => {
                await append({ turnId, start: true }, [{ start: turnId }]);
                turnStarted(i, () => { turnsRunning.delete(i); ended.resolve("end_turn"); });
                const stopReason = await ended.promise;
                turnsRunning.delete(i);
                await append({ turnId, end: true }, [{ end: true }]);
                return { stopReason, usage: {} };
              })();
              return { result, steer: async () => {}, cancel: () => ended.resolve("cancelled"), async *[Symbol.asyncIterator]() { await result; } };
            },
            resume() { throw new Error("no walk leaves a turn open"); },
            get openTurn() { return null; },
            settled: async () => {},
            saveCheckpoint: async () => {},
            exportCheckpoint: async () => new Uint8Array(),
            close: async () => {},
          };
        },
      }),
      defaultDurability: async () => memory(),
    })({ durability });
  }
  const session = agent.session();

  async function perform(act) {
    const i = act.p;
    switch (act.name) {
      case "Make": {
        const controller = new AbortController();
        if (act.early) controller.abort();
        const image = imageOf(walk, i);
        expected[i] = base64(image);
        names[i] = await nameOf(image);
        kinds[i] = act.kind;
        early[i] = act.early;
        const blocks = [{ type: "text", text: `prompt-${i}` }];
        // An image prompt's image write is held until the driver lets it go.
        if (act.kind === "image") {
          blocks.push({ type: "image", data: expected[i], mimeType: "image/png" });
          pendingNames.add(names[i]);
          imageGates[i] = writes.holdImage(names[i]);
        }
        const turn = session.prompt(blocks, { messageId: `p${i}`, signal: controller.signal });
        controllers[i] = controller;
        made = i;
        acc[i] = "pending";
        res[i] = "pending";
        turn.accepted.then(() => { acc[i] = "resolved"; }, (error) => { acc[i] = "rejected"; accError[i] = error; });
        turn.result.then(
          (result) => { res[i] = result.stopReason === "end_turn" ? "end" : result.stopReason === "cancelled" ? "cancelled" : `other:${result.stopReason}:${result.error?.message ?? ""}`; },
          () => { res[i] = "rejected"; },
        );
        return;
      }
      case "Prepared":
        imageGates[i].go(true);
        return;
      case "PrepareFail":
        imageGates[i].go(false);
        return;
      case "Store": return writes.settle(`prompt:p${i}`, true);
      case "StoreFail": return writes.settle(`prompt:p${i}`, false);
      case "Abort": controllers[i].abort(); return;
      case "CancelStore": return writes.settle(`cancel:p${i}`, true);
      case "Close": {
        closed = true;
        closing = agent.close();
        // A closed agent's session object takes no more prompts.
        try {
          session.prompt("after close");
          problems.push("prompt() after close did not throw");
        } catch (error) {
          if (!/is closed/.test(error.message)) problems.push(`prompt() after close threw ${error.message}`);
        }
        return;
      }
      case "End": {
        if (!(await until(() => turnsRunning.has(i)))) throw new Error(`prompt ${i} has no turn to end`);
        turnsRunning.get(i).end();
        return;
      }
      default: throw new Error(`the driver cannot take ${act.name}`);
    }
  }

  function observe() {
    const stored = writes.landed.filter((entry) => entry.type === "prompt");
    const cancels = new Set(writes.landed.filter((entry) => entry.type === "cancel").map((entry) => entry.target));
    for (const entry of stored) {
      const i = promptNumber(entry.input?.[0]?.text);
      const image = entry.input?.[1];
      // What the log holds is JSON. An image prompt names its image, which
      // the image store already holds, with the caller's original bytes.
      if (!isDeepStrictEqual(JSON.parse(JSON.stringify(entry)), entry)) problems.push(`prompt ${i}'s entry is not JSON`);
      if (kinds[i] === "text") {
        if (entry.input?.length !== 1) problems.push(`text prompt ${i} stored ${JSON.stringify(entry.input).slice(0, 120)}`);
        continue;
      }
      if (image?.data?.sha256 !== names[i] || Object.keys(image.data).length !== 1 || image?.mimeType !== "image/png" || image?.type !== "image") problems.push(`prompt ${i} stored ${JSON.stringify(image).slice(0, 120)}`);
      if (writes.images.get(names[i]) !== expected[i]) problems.push(`prompt ${i} was stored before its image, or with other bytes`);
    }
    const order = stored.map((entry) => promptNumber(entry.input?.[0]?.text));
    const ph = [];
    for (let i = 1; i <= n; i += 1) {
      if (i > made) ph.push("unmade");
      else if (early[i]) ph.push("early");
      else if (order.includes(i)) ph.push("stored");
      else if (writes.held.has(`prompt:p${i}`)) ph.push("sending");
      else if (acc[i] === "rejected") ph.push(/is closed/.test(accError[i]?.message ?? "") ? "refused" : "failed");
      // Accepted, yet neither stored nor on its way: an abort withdrew it.
      else if (acc[i] === "resolved") ph.push("withdrawn");
      else ph.push("preparing");
    }
    const each = (fn) => Array.from({ length: n }, (_, index) => fn(index + 1));
    return {
      made,
      closed,
      log: order,
      ph,
      acc: each((i) => acc[i] ?? "pending"),
      res: each((i) => res[i] ?? "pending"),
      cancel: each((i) => (cancels.has(`p${i}`) ? "stored" : writes.held.has(`cancel:p${i}`) ? "held" : "none")),
      ran: each((i) => started.has(i)),
    };
  }

  // Waits until the code shows nothing new for quietMs.
  async function settle() {
    let last = JSON.stringify(observe());
    let since = Date.now();
    const begun = Date.now();
    while (Date.now() - since < quietMs) {
      await sleep(15);
      const now = JSON.stringify(observe());
      if (now !== last) { last = now; since = Date.now(); }
      if (Date.now() - begun > stepTimeoutMs) break;
    }
    return observe();
  }

  async function close() {
    writes.openAll();
    pendingNames.clear();
    for (const turn of [...turnsRunning.values()]) turn.end();
    await Promise.race([(closing ?? agent.close()).catch(() => {}), sleep(3000)]);
    await closeAppWorlds?.();
    await rm(dir, { recursive: true, force: true });
  }

  return { perform, settle, close, problems };
}

// ---------------------------------------------------------------------------
// Walks.

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "../sdk/graphs", "intake.dot"));
const n = graph.states.get(graph.init).ph.length;
const autoActs = new Set(["Released", "Start", "Skip", "CancelRun"]);
const view = (state) => JSON.stringify({
  made: state.made, closed: state.closed, log: state.log, ph: state.ph, acc: state.acc, res: state.res, cancel: state.cancel, ran: state.ran,
});
const { steps, covered, totalEdges } = await walkGraph({
  graph,
  walks,
  random,
  verbose,
  autoActs,
  view,
  nameOf: (act) => act.name,
  sameAct: (a, b) => a.name === b.name && a.p === b.p && a.kind === b.kind && a.early === b.early,
  label: (act) => `${act.name}(${act.p}${act.name === "Make" ? `,${act.kind}${act.early ? ",early" : ""}` : ""})`,
  // Closing ends what a walk can do, so it comes late more often than not.
  choose: (pool) => (pool.length > 1 && random() < 0.75 ? pool.filter((item) => item.act.name !== "Close") : pool),
  open: (walk) => harness(walk, n),
});
if (!process.exitCode) console.log(`ok intake: ${walks} walks, ${steps} steps matched the model; ${covered} of ${totalEdges} edges covered (${harnessKind}, ${durabilityKind}${harnessKind === "fx" ? `, ${backend}` : ""})`);
// A walk that ended with prompts stored after close leaves the memory
// queue retrying with nobody listening; nothing more runs.
process.exit(process.exitCode ?? 0);
