#!/usr/bin/env bun
// Drives real libfx along paths of the TLC state graph of ImageStore.tla,
// and checks after every step that the code is in a state the model allows.
//
//   bun tests/tla/drivers/drive-images.mjs [--walks N] [--seed S] [--backend native|wasm]
//
// Each walk keeps one session in a memory persistence with an image store,
// first written by an engine without one, so its first image is saved
// inline as an older libfx saved it. Then the walk opens an engine on it and
// makes the prompts it chooses, each with image a or b; a turn's tool may
// return image a or b as well, which the engine stores before the core gets
// the result. Every engine keeps the model's window of images and bytes,
// where image b takes twice the bytes of the others, so a window edge of
// either kind drops an image. Every image write
// waits until the driver lets it land or fail; every model request waits
// until the driver ends its turn. A crash leaves the engine behind at once:
// its writes in flight never land, and nothing it does later reaches the
// store. The driver reopens the session, resuming a turn the crash left
// open, and may delete an image from the store. After each step the driver
// waits until the code is quiet and moves to the model states that show the
// same prompts, store, open state and held request. On every step, nothing
// saved may name an image the store does not hold (until one is deleted),
// only the old image, or a tool's image the store refused, may be saved
// inline, and a model request must carry
// exactly the history the model holds.
//
// `tests/tla/sdk/check.sh` writes graphs/images.dot from ImageStore-drive.cfg.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, createMemoryPersistence } from "../../../sdk/node.js";
import { loadGraph, walkGraph } from "./graph.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const walks = Number(option("walks", 40));
let seed = Number(option("seed", 1));
const backend = option("backend", "native");
if (!["native", "wasm"].includes(backend)) throw new Error("--backend is native or wasm");
const verbose = args.includes("--verbose");
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const quietMs = 150;
const stepTimeoutMs = 10_000;
// The model's window, which every engine the walk opens keeps too: its
// images, and its bytes in units, where image `big` takes two units and each
// other image one. A unit is the base64 of `unitBytes` bytes, which the
// window counts as a model request does.
const driveConfig = await readFile(resolve(here, "../sdk/ImageStore-drive.cfg"), "utf8");
const constant = (name) => new RegExp(`^\\s*${name} = "?(\\w+)"?$`, "m").exec(driveConfig)?.[1];
const windowImages = Number(constant("WindowImages"));
const windowUnits = Number(constant("WindowBytes"));
const big = constant("Big");
if (!(windowImages > 0) || !(windowUnits > 0) || !big) throw new Error("ImageStore-drive.cfg needs WindowImages, WindowBytes and Big");
const unitBytes = 4800;
const imageWindow = Symbol.for("libfx.imageWindow");
const decoder = new TextDecoder();
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const deferred = () => {
  let resolveIt;
  let rejectIt;
  const promise = new Promise((resolveP, rejectP) => { resolveIt = resolveP; rejectIt = rejectP; });
  promise.catch(() => {});
  return { promise, resolve: resolveIt, reject: rejectIt };
};
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

// The model's images, as PNG bytes the kernel accepts, each its own, of one
// unit or two. A unit is a multiple of 3 bytes, so its base64 takes exactly
// 4 bytes for every 3 and two units take twice one's.
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");
const labels = ["o", "a", "b"];
const unitsOf = (label) => (label === big ? 2 : 1);
const bytesOf = Object.fromEntries(labels.map((label) => [label, new Uint8Array(Buffer.concat([png, Buffer.alloc(unitsOf(label) * unitBytes - png.length, `image-${label}-`)]))]));
const windowBytes = windowUnits * unitBytes / 3 * 4;
const base64Of = Object.fromEntries(labels.map((label) => [label, Buffer.from(bytesOf[label]).toString("base64")]));
const nameOf = Object.fromEntries(await Promise.all(labels.map(async (label) => [label, Buffer.from(await crypto.subtle.digest("SHA-256", bytesOf[label])).toString("hex")])));
const labelOfName = Object.fromEntries(labels.map((label) => [nameOf[label], label]));
const labelOfBase64 = Object.fromEntries(labels.map((label) => [base64Of[label], label]));
const labelOfBytes = (bytes) => labelOfBase64[Buffer.from(bytes).toString("base64")] ?? "?";

// What a session saved, decoded: the names its records and checkpoint give,
// and the images they hold inline.
function durableBytes(value) {
  if (typeof value === "string") return Buffer.from(value, "utf8");
  if (value?.encoding === "base64") return Buffer.from(value.data, "base64");
  return null;
}
function savedImages(store) {
  const named = new Set();
  const inline = [];
  const visit = (value, blobs) => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item, blobs);
      return;
    }
    if (!value || typeof value !== "object") return;
    // One the session dropped keeps its name alone, which needs no bytes: an
    // image held inline takes the name of its bytes when it leaves.
    if (typeof value.inline_ref === "string" && value.dropped !== true) named.add(value.inline_ref);
    if (value.inline_data !== undefined) inline.push(durableBytes(value.inline_data));
    // A tool's image held inline: its base64 data.
    if (value.type === "image" && typeof value.data === "string" && typeof value.mimeType === "string") inline.push(Buffer.from(value.data, "base64"));
    if (Number.isInteger(value.inline_blob)) inline.push(blobs[value.inline_blob]);
    for (const item of Object.values(value)) visit(item, blobs);
  };
  for (const record of store.records) visit(JSON.parse(decoder.decode(record.data)), []);
  if (store.checkpoint) {
    // FXSN: magic, version, seq, turn, id length and id, an open turn from
    // version 2 on, then the FXCP checkpoint.
    const bytes = Buffer.from(store.checkpoint.data);
    const version = bytes[4];
    let at = 4 + 1 + 8 + 8;
    at += 1 + bytes[at];
    if (version >= 2) {
      const length = bytes.readUInt32LE(at);
      visit(JSON.parse(bytes.subarray(at + 4, at + 4 + length).toString("utf8")), []);
      at += 4 + length;
    }
    const checkpoint = bytes.subarray(at);
    const payload = checkpoint.subarray(4 + 2 + 2 + 4 + 32);
    if (checkpoint.readUInt16LE(4) === 1) {
      visit(JSON.parse(payload.toString("utf8")), []);
    } else {
      const jsonLength = payload.readUInt32LE(0);
      const json = JSON.parse(payload.subarray(4, 4 + jsonLength).toString("utf8"));
      const blobs = [];
      let offset = 4 + jsonLength;
      const count = payload.readUInt32LE(offset);
      offset += 4;
      for (let index = 0; index < count; index += 1) {
        const length = payload.readUInt32LE(offset);
        blobs.push(payload.subarray(offset + 4, offset + 4 + length));
        offset += 4 + length;
      }
      visit(json, blobs);
    }
  }
  return { named, inline };
}

const vision = "images/vision";
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
// The model calls the turn's tool for image `label`.
const callShot = (p, label) => new Response(
  [{ type: "tool-call", toolCallId: `call-${p}`, toolName: "shot", input: { label } }, { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage }, "[DONE]"]
    .map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
// The tool returns the image it is asked for.
const shot = {
  name: "shot",
  description: "Returns an image",
  inputSchema: { type: "object", properties: { label: { type: "string" } }, required: ["label"] },
  execute: async ({ label }) => ({ type: "libfx.tool-result", text: `image ${label}`, images: [{ type: "image", data: base64Of[label], mimeType: "image/png" }] }),
};
const answer = () => new Response(
  [{ type: "text-delta", id: "a", delta: "seen" }, { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage }, "[DONE]"]
    .map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);

// libfx's own key for a persistence's image store, which durable sessions
// give the engines they run.
const persistenceImages = Symbol.for("libfx.persistenceImages");

async function harness(n) {
  const store = createMemoryPersistence();
  // The image store: each image once, by name.
  const storedImages = new Map();
  const problems = [];
  // Held image writes by name, and the model request held now.
  const imageGates = new Map();
  let held = null;
  let answerNow = false;
  // Each engine's own fetch: a crashed engine reaches the model no more.
  const fetchFor = (current) => async (input, init) => {
    if (current && !current.alive) throw new Error("crashed");
    const request = input instanceof Request ? input : new Request(input, init);
    if (request.method === "GET") return Response.json({ object: "list", data: [{ id: vision, type: "language", tags: ["vision", "file-input"] }] });
    const prompt = JSON.parse(await request.text()).prompt;
    const users = prompt.filter((message) => message.role === "user");
    const text = users.map((message) => (Array.isArray(message.content) ? message.content : []).filter((part) => part.type === "text").map((part) => part.text).join("")).join("\n");
    const numbers = [...text.matchAll(/prompt-(\d+)/g)].map((match) => Number(match[1]));
    const images = users.flatMap((message) => (Array.isArray(message.content) ? message.content : []).filter((part) => part.type === "file"))
      .map((part) => labelOfBase64[part.data?.data] ?? "?");
    if (answerNow) return answer();
    const response = deferred();
    held = { p: numbers.at(-1) ?? 0, images, response, life: current };
    const signal = init?.signal ?? request.signal;
    signal?.addEventListener("abort", () => response.reject(signal.reason ?? new Error("aborted")), { once: true });
    return response.promise;
  };

  // Each engine's view of the store, until it crashes.
  let life = null;
  const persistenceFor = (current) => ({
    load: () => (current.alive ? store.load() : Promise.reject(new Error("crashed"))),
    append: (input) => (current.alive ? store.append(input) : Promise.reject(new Error("crashed"))),
    saveCheckpoint: (input) => (current.alive ? store.saveCheckpoint(input) : Promise.reject(new Error("crashed"))),
    [persistenceImages]: {
      async put(name, bytes) {
        if (!current.alive) throw new Error("crashed");
        const gate = imageGates.get(name);
        if (gate) {
          imageGates.delete(name);
          const lands = await gate.promise;
          if (!lands) throw new Error("injected image write failure");
          // A write the crash caught in flight never lands.
          if (!current.alive) return new Promise(() => {});
        }
        if (!storedImages.has(name)) storedImages.set(name, bytes.slice());
      },
      get: async (name) => {
        if (!current.alive) throw new Error("crashed");
        return storedImages.get(name)?.slice();
      },
    },
  });
  const engineOptions = (persistence, current = null) => ({
    backend,
    nativeAddon: addon,
    ...(wasm ? { wasm } : {}),
    apiKey: "images-key",
    model: vision,
    fetch: fetchFor(current),
    persistence,
    checkpointAfterBytes: 0,
    tools: [shot],
    [imageWindow]: { images: windowImages, bytes: windowBytes },
  });

  // The session an older libfx saved: its image inline, in a record and in a
  // checkpoint.
  {
    answerNow = true;
    const old = await createFxEngine(engineOptions({ load: () => store.load(), append: (input) => store.append(input), saveCheckpoint: (input) => store.saveCheckpoint(input) }));
    const turn = old.prompt([{ type: "text", text: "old" }, { type: "image", data: bytesOf.o, mimeType: "image/png" }]);
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, "end_turn");
    await old.close();
    answerNow = false;
  }

  let engine = null;
  let up = "down";
  let lost = false;
  let made = 0;
  const ph = Array(n).fill("unmade");
  const gates = {};
  // Each turn's tool image write, held until the driver lets it land or fail,
  // and the images the store refused, which the session holds inline.
  const toolGates = {};
  const refused = new Set();
  const watch = (p, turn) => {
    turn.result.then(
      (result) => { if (result.stopReason === "end_turn") ph[p - 1] = "ended"; },
      (error) => { if (error?.message === "injected image write failure") ph[p - 1] = "failed"; },
    );
  };

  async function perform(act) {
    const [name, p, image] = act;
    switch (name) {
      case "Make": {
        made = p;
        ph[p - 1] = "putting";
        gates[p] = deferred();
        imageGates.set(nameOf[image], { promise: gates[p].promise });
        const turn = engine.prompt([{ type: "text", text: `prompt-${p}` }, { type: "image", data: bytesOf[image].slice(), mimeType: "image/png" }]);
        void turn.result.catch(() => {});
        watch(p, turn);
        return;
      }
      case "PutLand": gates[p].resolve(true); return;
      case "PutFail": gates[p].resolve(false); return;
      case "ToolCall": {
        if (!held || held.p !== p) throw new Error(`no model request is held for prompt ${p}`);
        toolGates[p] = { gate: deferred(), image };
        imageGates.set(nameOf[image], { promise: toolGates[p].gate.promise });
        const { response } = held;
        held = null;
        response.resolve(callShot(p, image));
        return;
      }
      case "ToolPutLand": toolGates[p].gate.resolve(true); return;
      case "ToolPutFail": {
        refused.add(toolGates[p].image);
        toolGates[p].gate.resolve(false);
        return;
      }
      case "TurnEnd": {
        if (!held || held.p !== p) throw new Error(`no model request is held for prompt ${p}`);
        const { response } = held;
        held = null;
        response.resolve(answer());
        return;
      }
      case "Crash": {
        life.alive = false;
        // The crash ends the engine's held request and image writes with it.
        if (held) {
          held.response.reject(new Error("crashed"));
          held = null;
        }
        for (let q = 1; q <= n; q += 1) if (ph[q - 1] === "putting") ph[q - 1] = "lost";
        for (const gate of Object.values(gates)) gate.resolve(true);
        for (const { gate } of Object.values(toolGates)) gate.resolve(true);
        const left = engine;
        engine = null;
        up = "down";
        void left.close().catch(() => {});
        return;
      }
      case "OpenBegin": {
        life = { alive: true };
        try {
          engine = await createFxEngine(engineOptions(persistenceFor(life), life));
        } catch (error) {
          if (error?.code !== "FX_JOURNAL_IMAGE_MISSING") throw error;
          up = "failed";
          return;
        }
        up = "open";
        // A turn the crash left open continues.
        const resumed = engine.resume();
        if (resumed) {
          const open = ph.findIndex((phase) => phase === "started") + 1;
          if (open === 0) problems.push("the engine resumed a turn the model has no started prompt for");
          void resumed.result.catch(() => {});
          watch(open, resumed);
        }
        return;
      }
      case "Lose": {
        lost = true;
        storedImages.delete(nameOf[p]);
        return;
      }
      default: throw new Error(`the driver cannot take ${name}`);
    }
  }

  function observe() {
    // A prompt whose model request is held has started.
    if (held && held.life === life && ph[held.p - 1] !== "ended") ph[held.p - 1] = "started";
    const { named, inline } = savedImages(store);
    if (!lost) for (const name of named) if (!storedImages.has(name)) problems.push(`a record or checkpoint names ${labelOfName[name] ?? name}, which the store does not hold`);
    for (const bytes of inline) {
      const label = labelOfBytes(bytes);
      if (label !== "o" && !refused.has(label)) problems.push(`image ${label} is saved inline`);
    }
    return {
      made,
      ph: [...ph],
      up,
      store: [...storedImages.keys()].map((name) => labelOfName[name] ?? "?").sort(),
      held: held && held.life === life ? held.images : null,
    };
  }

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
    if (held) held.response.resolve(answer());
    for (const gate of Object.values(gates)) gate.resolve(true);
    for (const { gate } of Object.values(toolGates)) gate.resolve(true);
    if (engine) await Promise.race([engine.close().catch(() => {}), sleep(3000)]);
  }

  return { perform, settle, close, problems };
}

// ---------------------------------------------------------------------------
// Walks.

const graph = await loadGraph(resolve(here, "../sdk/graphs", "images.dot"));
const n = graph.states.get(graph.init).ph.length;
const autoActs = new Set(["Send", "TurnStart", "ToolResult", "Checkpoint", "Stage", "OpenMissing", "OpenOk"]);
// While a turn's tool stores its image or hands it on, no request is held.
const toolRunning = (state) => state.tph.some((phase) => ["called", "put", "refused"].includes(phase));
const view = (state) => JSON.stringify({
  made: state.made,
  ph: state.ph,
  up: state.up,
  store: [...state.store].sort(),
  // A model request carries the images the core keeps; a dropped one is a note.
  held: state.up === "open" && state.ph.includes("started") && !toolRunning(state) ? state.mem.filter((entry) => !entry.dropped).map((entry) => entry.i) : null,
});
const { steps, covered, totalEdges } = await walkGraph({
  graph,
  walks,
  random,
  verbose,
  autoActs,
  view,
  nameOf: (act) => act[0],
  sameAct: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  label: (act) => `${act[0]}(${act.slice(1).join(",")})`,
  open: () => harness(n),
});
if (!process.exitCode) console.log(`ok images: ${walks} walks, ${steps} steps matched the model; ${covered} of ${totalEdges} edges covered (${backend})`);
process.exit(process.exitCode ?? 0);
