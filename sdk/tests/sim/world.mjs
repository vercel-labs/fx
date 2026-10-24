// The world a libfx simulation runs in: a seeded random source, a pool of
// images, a model stand-in that records what each request carries, and a
// store that can fail, crash, and keep a copy of itself after every write.
// Nothing here waits on a clock: a slow write yields to the event loop a
// number of times the seed chooses, so a seed replays the same choices.
import { createMemoryPersistence } from "../../node.js";

// libfx's own key for a persistence's image store, which durable sessions
// give the engines they run.
const persistenceImages = Symbol.for("libfx.persistenceImages");

/**
 * `persistence` with an image store that keeps each image once, by name, in
 * `images`, which it also exposes as `persistence.images`.
 */
export function withImageStore(persistence, images = new Map()) {
  return Object.assign(persistence, {
    images,
    [persistenceImages]: {
      put: async (name, bytes) => { if (!images.has(name)) images.set(name, Uint8Array.from(bytes)); },
      get: async (name) => images.get(name)?.slice(),
    },
  });
}

/**
 * A seeded random source: the same seed gives the same choices. Mulberry32
 * hashes its state on every draw, so neighbouring seeds start far apart; a
 * plain xorshift seeded with 1, 2, 3... begins near zero and makes every
 * small seed choose alike.
 */
export function randomSource(seed) {
  let state = Number(seed) >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), state | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    int: (n) => Math.floor(next() * n),
    chance: (p) => next() < p,
    pick: (items) => items[Math.floor(next() * items.length)],
  };
}

/** Yields to the event loop `times` times, letting other work land between. */
export async function settle(times = 1) {
  for (let index = 0; index < times; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");

// PNG bytes, then xorshift filler, so no image's bytes appear inside another's.
function imageOf(size, salt) {
  const bytes = new Uint8Array(size);
  bytes.set(png);
  let x = (salt * 2654435761) >>> 0 || 1;
  for (let index = png.length; index < size; index += 1) {
    x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0;
    bytes[index] = x & 255;
  }
  return bytes;
}

/**
 * The images a simulation draws on: two of each size, small to large. The
 * largest are big enough that a few of them pass the native request limit.
 */
export function imagePool() {
  const sizes = [300, 2_000, 20_000, 200_000, 900_000, 2_600_000];
  const images = sizes.flatMap((size, index) => [imageOf(size, index * 2 + 1), imageOf(size, index * 2 + 2)]);
  const base64 = images.map((bytes) => Buffer.from(bytes).toString("base64"));
  const indexOfBase64 = new Map(base64.map((text, index) => [text, index]));
  // Windows of each image to look for in saved data, raw and as base64.
  const rawProbe = images.map((bytes) => Buffer.from(bytes.subarray(80, Math.min(144, bytes.length))));
  const base64Probe = base64.map((text) => Buffer.from(text.slice(108, 188)));
  return {
    images,
    base64,
    indexOfBase64,
    /** The image `index` as a prompt block, in the form `form` chooses. */
    block(index, form) {
      if (form === "bytes") return { type: "image", data: images[index].slice(), mimeType: "image/png" };
      if (form === "blob") return { type: "image", data: new Blob([images[index]], { type: "image/png" }) };
      return { type: "image", data: base64[index], mimeType: "image/png" };
    },
    /** The serialized size of image `index` in a request: its base64. */
    encodedBytes: (index) => base64[index].length,
    /**
     * The index of an image whose bytes `data` holds, or -1. With `only`, just
     * whether `data` holds image `only`.
     */
    heldIn(data, only) {
      const buffer = Buffer.from(data);
      const holds = (index) => buffer.includes(rawProbe[index]) || buffer.includes(base64Probe[index]);
      return only === undefined ? images.findIndex((_, index) => holds(index)) : holds(only);
    },
  };
}

// libfx writes each image into the prompt text as a placeholder, and puts a
// note before the text for each image it leaves out of a request.
const windowNotePattern = /\[Image #(\d+) is no longer in this session/g;
const sizeNotePattern = /\[Image #(\d+) not sent to keep the request under the provider's size limit/g;
// A whole size note, as the request carries it.
const sizeNoteTextPattern = /\[Image #(\d+) not sent to keep the request under the provider's size limit\.[^\]]*\]\n?/g;
const idsOf = (text, pattern) => [...text.matchAll(pattern)].map((match) => Number(match[1]));

/**
 * A user message of a model request, as the model sees it. One message can
 * hold several prompts, such as a turn cut off before its answer and the
 * prompt after it, so it is read as segments: each prompt's marker, then the
 * placeholders of its images.
 */
function readUserMessage(message) {
  const parts = Array.isArray(message.content) ? message.content : [{ type: "text", text: String(message.content ?? "") }];
  const text = parts.filter((part) => part.type === "text").map((part) => part.text).join("");
  const segments = [];
  let current = { marker: null, ids: [] };
  for (const match of text.matchAll(/(sim-[0-9a-z+:-]+)|\[Image #(\d+)\]/g)) {
    if (match[1]) {
      if (current.marker !== null || current.ids.length > 0) segments.push(current);
      current = { marker: match[1], ids: [] };
    } else {
      current.ids.push(Number(match[2]));
    }
  }
  if (current.marker !== null || current.ids.length > 0) segments.push(current);
  return {
    text,
    segments,
    markers: segments.map((segment) => segment.marker).filter((marker) => marker !== null),
    // Whether a turn starts here: a prompt, or a steer that runs as a turn of
    // its own. A steer that joins a running turn comes as a live update in
    // it, and libfx's own messages, such as the notice a resumed turn adds,
    // start nothing.
    startsTurn: !text.startsWith("<user_steering>") && (segments.some((segment) => segment.marker !== null) || /steer-\d+-\d+/.test(text)),
    // The newest prompt in the message.
    marker: segments.at(-1)?.marker ?? null,
    windowNoted: new Set(idsOf(text, windowNotePattern)),
    sizeNoted: new Set(idsOf(text, sizeNotePattern)),
    // Each size note's text, by image id, so a check can measure what
    // sending that image instead would take.
    sizeNotes: new Map([...text.matchAll(sizeNoteTextPattern)].map((match) => [Number(match[1]), match[0]])),
    // Whether the message holds a list of parts, as one with an image does.
    inParts: Array.isArray(message.content),
    sent: parts.filter((part) => part.type === "file").map((part) => part.data?.data),
  };
}

// A tool result's images come in the user message after it; a result's notes
// count the images of it the request leaves out.
const toolFollowupText = "Attached image(s) from the tool result.";
// A result can carry several notes of one kind, such as one per image left out.
const toolWindowNotePattern = /\[(\d+) images? from this result (?:is|are) no longer in this session/g;
const toolSizeNotePattern = /\[(\d+) images? from this result not sent to keep the request under/g;

/**
 * A tool result of a model request, read as a user message the checks skip
 * over, holding which turn's call it answers, how many of its images the
 * request notes as dropped or left out, and the images it carries.
 */
function readToolResult(part) {
  const output = part.output ?? {};
  const text = typeof output.value === "string" ? output.value
    : Array.isArray(output.value) ? output.value.filter((item) => item?.type === "text").map((item) => item.text).join("") : "";
  const count = (pattern) => [...text.matchAll(pattern)].reduce((sum, match) => sum + Number(match[1]), 0);
  return {
    text: "", segments: [], markers: [], marker: null, startsTurn: false,
    windowNoted: new Set(), sizeNoted: new Set(), sizeNotes: new Map(), inParts: true, sent: [],
    tool: { key: /value of (sim-[0-9a-z+:-]+)/.exec(text)?.[1] ?? null, windowNoted: count(toolWindowNotePattern), sizeNoted: count(toolSizeNotePattern), sent: [], results: 1 },
  };
}

/**
 * The user messages of a request, in order, with each tool result in its
 * place and the images the message after it carries for it.
 */
function readConversation(prompt) {
  const users = [];
  let results = [];
  for (const message of prompt) {
    if (message.role === "tool") {
      results = (Array.isArray(message.content) ? message.content : []).filter((part) => part.type === "tool-result").map(readToolResult);
      for (const result of results) result.tool.results = results.length;
      users.push(...results);
    } else if (message.role === "user") {
      const user = readUserMessage(message);
      // A simulated turn makes one call at a time, so one result has them all.
      if (results.length > 0 && user.text.startsWith(toolFollowupText)) results.at(-1).tool.sent.push(...user.sent);
      else users.push(user);
      results = [];
    }
  }
  return users;
}

/**
 * A model stand-in. It records each request, refuses one larger than
 * `providerLimit` with a 413 as a provider would, and answers a turn whose
 * marker asks for the tool with a tool call before its text, so the turn
 * makes a second request. `onRequest` sees each request as it arrives.
 */
export function modelStandIn({ providerLimit = null, onRequest = () => {} } = {}) {
  const requests = [];
  const answer = (frames) => new Response(
    frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
  const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
  async function fetch(input, init) {
    const request = input instanceof Request ? input : new Request(input, init);
    if (request.method === "GET") {
      // A large context, so a session never needs compacting.
      return Response.json({ object: "list", data: [{ id: "sim/vision", type: "language", context_window: 2_000_000, max_tokens: 8192, tags: ["tool-use", "vision", "file-input"] }] });
    }
    const body = await request.text();
    const prompt = JSON.parse(body).prompt;
    const users = readConversation(prompt);
    // The turn's own last user message: not the one that carries a tool
    // result's images, which comes after that result.
    const carriesToolImages = (message) => message.role === "user" && Array.isArray(message.content)
      && message.content[0]?.type === "text" && message.content[0].text.startsWith(toolFollowupText);
    const lastUser = prompt.findLastIndex((message) => message.role === "user" && !carriesToolImages(message));
    const toolAnswered = prompt.slice(lastUser + 1).some((message) => message.role === "tool");
    const observed = { bytes: Buffer.byteLength(body), users, rejected: false };
    requests.push(observed);
    // SIM_DUMP=<dir> keeps each request's body.
    if (process.env.SIM_DUMP) await import("node:fs/promises").then((fs) => fs.writeFile(`${process.env.SIM_DUMP}/request-${requests.length}.json`, body));
    if (process.env.SIM_TRACE) {
      console.log(`  model: request ${requests.length}, ${observed.bytes} bytes, ${prompt.length} messages`);
      for (const user of users) {
        if (user.tool) {
          console.log(`    tool: ${user.tool.key} window-noted ${user.tool.windowNoted} size-noted ${user.tool.sizeNoted} sent ${user.tool.sent.length}`);
          continue;
        }
        console.log(`    user: ${user.segments.map((segment) => `${segment.marker ?? "-"}[${segment.ids.join(",")}]`).join(" ")} window-noted [${[...user.windowNoted]}] size-noted [${[...user.sizeNoted]}] sent ${user.sent.length}: ${JSON.stringify(user.text.slice(0, 140))}`);
      }
    }
    await onRequest(observed);
    if (providerLimit !== null && observed.bytes > providerLimit) {
      observed.rejected = true;
      return new Response(JSON.stringify({ error: { message: "request entity too large", type: "invalid_request_error" } }), {
        status: 413,
        headers: { "content-type": "application/json" },
      });
    }
    const marker = users.findLast((user) => !user.tool)?.marker ?? "";
    if (marker.includes("+tool") && !toolAnswered) {
      return answer([
        { type: "tool-call", toolCallId: `call-${requests.length}`, toolName: "lookup", input: { key: marker } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ]);
    }
    return answer([
      { type: "text-delta", id: "a", delta: "ok" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ]);
  }
  return { requests, fetch };
}

/** The host tool a simulated turn calls. */
export const lookupTool = {
  name: "lookup",
  description: "Looks up a key",
  inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
  execute: async ({ key }) => `value of ${key}`,
};

/**
 * The host tool with images: for a turn whose marker `images` maps to pool
 * indices, the call returns those images with its text. `onRun` sees each
 * call start.
 */
export function lookupToolFor({ pool, images = new Map(), onRun = () => {} }) {
  return {
    ...lookupTool,
    execute: async ({ key }) => {
      onRun(key);
      const shots = images.get(key) ?? [];
      if (shots.length === 0) return `value of ${key}`;
      return { type: "libfx.tool-result", text: `value of ${key}`, images: shots.map((index) => ({ type: "image", data: pool.base64[index], mimeType: "image/png" })) };
    },
  };
}

// The event types a record holds, for the trace.
const decoderFor = (data) => {
  try {
    return JSON.parse(new TextDecoder().decode(data)).events.map((event) => event.type).join(" ");
  } catch {
    return "?";
  }
};

const crashed = () => Object.assign(new Error("the process crashed"), { code: "SIM_CRASHED" });

/**
 * A memory store that keeps a copy of itself after each write. Each call
 * waits up to `slowness` event-loop turns, as many as a count says, and a
 * fault `arm()` sets fails one call: `{ kind: "append" | "image", nth }`, the
 * nth call of that kind after arming. Neither depends on when calls arrive, so
 * a plan replays the same faults however the engine batches its writes. A
 * crashed process (`life.alive` false) can neither read nor write it.
 */
export function faultyStore({ slowness = 0 } = {}) {
  const store = withImageStore(createMemoryPersistence());
  const images = store[persistenceImages];
  let calls = 0;
  const delay = () => settle((calls++ * 7) % (slowness + 1));
  let armed = null;
  let firedTotal = 0;
  // Whether a tool call is running: from its start until the next model
  // request, which is when libfx stores the images it returned.
  let toolRunning = false;
  const refusals = [];
  const fails = (kind) => {
    const matches = armed?.kind === kind || (kind === "image" && armed?.kind === "toolImage" && toolRunning);
    if (!armed || armed.fired || !matches) return false;
    armed.seen += 1;
    armed.fired = armed.seen === armed.nth;
    // A tool image the store refuses fails no call: the turn goes on with the
    // image kept in its result.
    if (armed.fired && !(kind === "image" && toolRunning)) firedTotal += 1;
    return armed.fired;
  };
  // SIM_TRACE=1 prints each call the store takes.
  const trace = process.env.SIM_TRACE ? (line) => console.log(`  store: ${line}`) : () => {};
  const states = [];
  const copyRecords = () => store.records.map((record) => ({ ...record, data: record.data.slice() }));
  const keep = (kind) => {
    states.push({
      kind,
      records: copyRecords(),
      checkpoint: store.checkpoint && { through: store.checkpoint.through, data: store.checkpoint.data.slice() },
      images: new Map(store.images),
    });
  };
  const persistenceFor = (life) => ({
    load: async () => {
      if (!life.alive) throw crashed();
      return store.load();
    },
    append: async (input) => {
      if (!life.alive) throw crashed();
      if (fails("append")) {
        trace(`append of ${input.data?.byteLength ?? "?"} bytes fails: ${decoderFor(input.data)}`);
        throw Object.assign(new Error("injected append failure"), { code: "SIM_APPEND" });
      }
      await delay();
      if (!life.alive) throw crashed();
      const out = await store.append(input).catch((error) => {
        trace(`append of ${input.data.byteLength} bytes after ${input.after ?? "none"} is refused: ${error?.code ?? ""} ${error?.message}`);
        throw error;
      });
      keep("append");
      trace(`write ${states.length}: append ${out.cursor}, ${input.data.byteLength} bytes${input.barrier ? ", barrier" : ""}: ${decoderFor(input.data)}`);
      return out;
    },
    saveCheckpoint: async (input) => {
      if (!life.alive) throw crashed();
      await store.saveCheckpoint(input);
      keep("checkpoint");
      trace(`write ${states.length}: checkpoint through ${input.through}`);
    },
    [persistenceImages]: {
      put: async (name, bytes) => {
        if (!life.alive) throw crashed();
        if (fails("image")) {
          refusals.push({ name, bytes: Uint8Array.from(bytes), duringTool: toolRunning });
          trace(`image ${name.slice(0, 8)} fails${toolRunning ? ", a tool's" : ""}`);
          throw Object.assign(new Error("injected image write failure"), { code: "SIM_PUT" });
        }
        await delay();
        // A write the crash caught in flight never lands.
        if (!life.alive) return new Promise(() => {});
        await images.put(name, bytes);
        keep("image");
        trace(`write ${states.length}: image ${name.slice(0, 8)}`);
      },
      get: async (name) => {
        if (!life.alive) throw crashed();
        return images.get(name);
      },
    },
  });
  return {
    store,
    states,
    persistenceFor,
    /** Fails one call to come, as `fault` says; null fails none. */
    arm: (fault) => {
      armed = fault ? { ...fault, seen: 0, fired: false } : null;
    },
    /** Marks a tool call running, or not. */
    toolRunning: (running) => { toolRunning = running; },
    /** The image writes the store refused: name, bytes, and whether a tool's. */
    refusals: () => refusals,
    /** How many armed faults have failed their call so far. */
    fired: () => firedTotal,
    /** How many writes have landed. */
    writes: () => states.length,
  };
}

/** A fresh store holding `state`, one of a faulty store's kept copies. */
export async function storeAt(state) {
  const copy = withImageStore(createMemoryPersistence());
  copy.records.push(...state.records.map((record) => ({ ...record, data: record.data.slice() })));
  if (state.checkpoint) await copy.saveCheckpoint({ through: state.checkpoint.through, data: state.checkpoint.data.slice() });
  for (const [name, bytes] of state.images) copy.images.set(name, bytes);
  return copy;
}
