// Durable agent sessions: the code that runs an agent in a script runs it in
// production. Every model step and tool intent is stored in the session's
// log before anything depends on it, one worker at a time runs a session
// under a lease, and a turn that runs out of time, crashes, or lands on
// another server continues where it stopped.
//
// The agent loop itself is a harness the core drives through a small
// contract (see `createDurableAgentFactory`): fx is one, in fx-harness.js.
//
// A session is one ordered log plus one stream of what the user sees. The
// log holds three kinds of entry:
//
// - inputs (`prompt`, `steer`, `cancel`), which any server may add;
// - a chain of lease claims, lease releases and the harness's records, each
//   naming the chained entry before it, so taking the lease fences the old
//   holder's next write;
// - checkpoints, each covering the chain up to a record.
//
// `prompt()` only queues a message. The worker the queue delivers it to adds
// the input to the log, takes the lease, and runs every turn the log holds
// until none is left, or its time runs out: then it asks the queue to
// deliver the same message again, and the next worker continues the turn.
//
// TLA+ models: `tests/tla/sdk/DurableSession.tla` (the log, leases and
// takeovers), `tests/tla/sdk/AgentRouting.tla` (agent names and routing),
// and `tests/tla/sdk/DurableSteer.tla` (where each message a user sends is
// placed). The drivers in `tests/tla/drivers/` run this code along them.

// A write the session's chain refused because another worker continued it.
// Harnesses recognize it by its code.
class FencedError extends Error {
  constructor(message) {
    super(message);
    this.name = "FencedError";
    this.code = "FX_FENCED";
  }
}

const durabilityTag = Symbol.for("libfx.durability");
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// The core's rule for turn and input ids, which messages become.
const idPattern = /^[A-Za-z0-9._-]{1,128}$/;
const validId = (id) => typeof id === "string" && idPattern.test(id);
const idRule = "1 to 128 letters, digits, '.', '_' or '-'";
const newId = (prefix) => `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;

// How long a worker leaves for a model step it decides not to start.
const defaultReserveMs = 30_000;
// A lease with nothing to show whether its holder lives expires this long
// after it was taken or last renewed, and its holder renews it every third of
// that while it runs. So a worker that dies frees its session this soon
// after its last renewal, not at its function's deadline.
const defaultLeaseMs = 15_000;

// Whether the queue shows whether a worker lives, delivering the message its
// delivery held again once it is gone, so the worker holds its lease to the
// deadline that bounds it and renews nothing.
const queueHeld = (backend, deadline) => !backend.livenessKnown && backend.queueLeases === true && deadline !== null;
// Whether a worker holds its lease to its deadline and renews nothing: when
// whether it lives is known, or the queue shows it.
const heldToDeadline = (backend, deadline) => backend.livenessKnown || queueHeld(backend, deadline);

// When a lease taken or renewed now runs out: never past the deadline its
// worker stops at, and when it is held to that deadline, only there.
function leaseEnd(backend, deadline) {
  if (heldToDeadline(backend, deadline)) return deadline;
  const renewed = Date.now() + backend.leaseMs;
  return deadline === null ? renewed : Math.min(renewed, deadline);
}
// The newest consumed message ids a checkpoint keeps, so a message the queue
// delivers again after its turn ended is still recognized.
const recentIdsKept = 256;
// The longest a message waits for a live holder before it is delivered again.
const maxBackstopSeconds = 300;

// Base64 of a Uint8Array: the runtime's own encoder where it has one, and
// otherwise four letters from the table for each three bytes. Both are fast
// enough for a large image; btoa over String.fromCharCode is not.
const base64Letters = encoder.encode("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
const toBase64 = (bytes) => {
  if (typeof bytes.toBase64 === "function") return bytes.toBase64();
  const letters = new Uint8Array(Math.ceil(bytes.length / 3) * 4);
  const whole = bytes.length - (bytes.length % 3);
  let at = 0;
  for (let index = 0; index < whole; index += 3) {
    const group = (bytes[index] << 16) | (bytes[index + 1] << 8) | bytes[index + 2];
    letters[at] = base64Letters[group >> 18];
    letters[at + 1] = base64Letters[(group >> 12) & 63];
    letters[at + 2] = base64Letters[(group >> 6) & 63];
    letters[at + 3] = base64Letters[group & 63];
    at += 4;
  }
  if (whole < bytes.length) {
    // One or two bytes left: two or three letters, then "=" padding.
    const two = whole + 1 < bytes.length;
    const group = (bytes[whole] << 16) | (two ? bytes[whole + 1] << 8 : 0);
    letters[at] = base64Letters[group >> 18];
    letters[at + 1] = base64Letters[(group >> 12) & 63];
    letters[at + 2] = two ? base64Letters[(group >> 6) & 63] : 61;
    letters[at + 3] = 61;
  }
  return decoder.decode(letters);
};
const fromBase64 = (text) => {
  if (typeof Uint8Array.fromBase64 === "function") return Uint8Array.fromBase64(text);
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
};

// A session keeps each prompt image once, in its image store, named by the
// lowercase hex SHA-256 of its bytes, as libfx's core names it; the log only
// names it.
async function imageName(bytes) {
  const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
  let name = "";
  for (const byte of digest) name += byte.toString(16).padStart(2, "0");
  return name;
}
const base64url = (text) => toBase64(encoder.encode(text)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
// The key a harness's store gives its image store under, `{ put, get }`:
// `persistenceImages` in fx-sdk.js, which engines read it from.
const persistenceImages = Symbol.for("libfx.persistenceImages");

// A view of the bytes in an ArrayBuffer or typed array, or null.
const byteView = (value) => (value instanceof ArrayBuffer ? new Uint8Array(value)
  : ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null);

// A prompt's input as the queue and the log hold it: JSON, so image data is
// base64 text. With `named`, the session stores each image in its image
// store and the log names it (`storePromptImages`); `images` says whether any
// image has data to store.
//
// Each image block is copied once and only the copy is read, since an
// accessor can return something else the next time it is read, and the log
// must hold what was checked. The blocks are walked by index for the same
// reason: an Array subclass can make map() return anything. Pure.
function promptInputForLog(input, { named = false } = {}) {
  let images = false;
  const blocks = [];
  for (let index = 0; index < input.length; index += 1) {
    const block = input[index];
    if (block?.type !== "image") {
      blocks.push(block);
      continue;
    }
    const image = { ...block };
    if (image.data !== undefined && typeof image.data !== "string") throw new TypeError("a durable prompt carries image data as a base64 string");
    if (typeof image.data === "string") images = named;
    blocks.push(image);
  }
  return { input: blocks, images };
}

// Stores each image a prompt's input holds in the session's image store,
// before the input that names it is stored, and returns the input naming
// them: `{ type: "image", mimeType, sourceRef?, data: { sha256 } }`. An older
// libfx refuses data it can't read, so a worker that predates names fails
// the turn rather than run it without its images. A store that fails rejects
// with its own error. With `images` null it only names them, for a prompt the
// log already holds.
async function storePromptImages(images, input) {
  const blocks = [];
  for (const block of input) {
    if (block?.type !== "image" || block.data === undefined) {
      blocks.push(block);
      continue;
    }
    const { data, ...rest } = block;
    const bytes = fromBase64(data);
    const sha256 = await imageName(bytes);
    if (images) await images.put(sha256, bytes);
    blocks.push({ ...rest, data: { sha256 } });
  }
  return blocks;
}

// A prompt's input with each named image read back from the session's image
// store, as base64, which is how a harness has always received image data.
// `missing` names the first image the store does not hold.
async function resolvePromptImages(images, input) {
  if (!Array.isArray(input)) return { input };
  const blocks = [];
  for (const block of input) {
    const name = block?.type === "image" ? block.data?.sha256 : undefined;
    if (typeof name !== "string") {
      blocks.push(block);
      continue;
    }
    const bytes = await images.get(name);
    if (!bytes) return { missing: name };
    // Bytes that aren't the ones named are not the image its caller sent.
    if (await imageName(bytes) !== name) return { missing: name, corrupt: true };
    blocks.push({ ...block, data: toBase64(bytes) });
  }
  return { input: blocks };
}

/**
 * The durability that keeps sessions in this process only. Agents given the
 * same `memory()` share its sessions, as servers share a database. With
 * `maxDurationMs`, each delivery runs as if its function stopped after that
 * long, stopping `reserveMs` before, as on Vercel.
 */
export function memory({ maxDurationMs, reserveMs } = {}) {
  checkDurations("memory", { maxDurationMs, reserveMs });
  let backend = null;
  return { [durabilityTag]: true, name: "memory", create: () => (backend ??= createMemoryBackend({ maxDurationMs, reserveMs })) };
}

function checkDurations(name, { maxDurationMs, reserveMs }) {
  for (const [key, value] of Object.entries({ maxDurationMs, reserveMs })) {
    if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw new TypeError(`${name}() ${key} must be a non-negative integer`);
  }
}

// A durability is `memory()`, or a World one from `libfx/durable-world` (and
// `libfx/durable-local` and `libfx/durable-vercel`, built on it): `{ world() }`
// and how its workers hold sessions.
function isDurability(value) {
  return Boolean(value && typeof value === "object" && value[durabilityTag] === true &&
    (typeof value.create === "function" || typeof value.world === "function"));
}

async function createBackend(durability) {
  if (typeof durability.create === "function") return durability.create();
  checkDurations(durability.name, durability);
  return createWorldBackend(await durability.world(), durability);
}

// The workers holding a session in this process, across every agent in it,
// so a lease this process took is judged by whether its worker still runs.
const liveHolders = (globalThis[Symbol.for("libfx.liveHolders")] ??= new Set());

// Times a turn's engine may stop under it before the turn is cancelled, or
// ends with an error when it never started; and further times it may stop
// while that cancel runs before the session can run no more turns.
const maxHarnessStops = 3;
const maxCancelStops = 2;
// Times in a row the deadline may cut off the same step of a turn, with no
// record between, before the next delivery stops running it again.
const maxCutoffs = 3;

// ---------------------------------------------------------------------------
// The session log, folded. Pure: the same entries always fold the same way.

// How many times in a row the deadline cut off an open turn's step. A
// harness that marks its records with the step a turn is at counts the
// cut-offs while that step stays the same, since continuing a cut-off step
// can write a record with no progress in it. For one that marks no steps,
// any record is progress.
const noCutoffs = { cutoffs: 0, cutStep: null, step: null, named: false };
function afterRecord(cut, marks) {
  let next = cut;
  for (const mark of marks ?? []) {
    if (typeof mark.start === "string") next = noCutoffs;
    else if (typeof mark.step === "string") next = { ...next, step: mark.step, named: true };
  }
  return next.named ? next : { ...next, cutoffs: 0 };
}
function afterCutoff(cut) {
  const same = !cut.named || cut.step === cut.cutStep;
  return { ...cut, cutoffs: same ? cut.cutoffs + 1 : 1, cutStep: cut.step };
}

/**
 * Folds a session's log into what a worker acts on. `entries` are
 * `{ cursor, entry }` in log order from the latest checkpoint's `through`;
 * cursors are increasing integer strings. `now` and `alive(lease)` decide
 * whether a lease stands; `alive` returns true, false, or null for unknown.
 */
export function foldSessionLog(entries, { now = 0, alive = () => null } = {}) {
  let checkpoint = null;
  for (const item of entries) if (item.entry?.k === "checkpoint") checkpoint = item;
  const base = checkpoint?.entry ?? null;
  let head = base ? base.through ?? null : null;
  let lease = base?.lease ?? null;
  // The highest epoch any lease in the chain took. A release clears the
  // lease but not this: the next claim takes a higher epoch, so its UI lines
  // outrank every earlier line.
  let epoch = base?.lease?.epoch ?? 0;
  const consumed = new Set(base?.recent ?? []);
  const recent = [...(base?.recent ?? [])];
  // Which of those were steers, so a prompt and a steer cannot share an id
  // after a checkpoint drops their inputs. A checkpoint from before this was
  // kept does not say.
  const baseSteers = new Set(base?.recentSteers ?? []);
  const kindsKnown = base === null || Array.isArray(base?.recentSteers);
  // Inputs the open turn accepted and has not placed, which a withdrawal can
  // hand back. They count as taken until then.
  const held = new Set(base?.held ?? []);
  for (const id of held) consumed.add(id);
  const seenInputs = new Set();
  const inputs = [];
  const records = [];
  // A checkpoint taken where a turn yielded leaves that turn open.
  // `from` is where the input that opened it was stored: steers stored after
  // it join it, before it started too.
  let openTurn = typeof base?.openTurn?.id === "string" ? { id: base.openTurn.id, at: Number(base.openTurn.at) || 0, from: Number(base.openTurn.from ?? base.openTurn.at) || 0, context: base.openTurn.context ?? null, settings: base.openTurn.settings ?? null } : null;
  let lastTurnId = base?.lastTurnId ?? null;
  // The agent the session belongs to: the one its first stored input, or the
  // checkpoint it was restored from, names. A session stored before agents
  // had names belongs to the default agent.
  let agent = typeof base?.agent === "string" ? base.agent : base && base.through != null ? defaultAgentName : null;
  let yielded = base?.yielded === true;
  // The context each prompt's or steer's caller gave, and the settings its
  // session object set, which its turn runs with: an untaken steer becomes a
  // turn.
  const contexts = new Map();
  const settingsOf = new Map();
  for (const input of base?.pending ?? []) {
    if (input.context !== undefined) contexts.set(input.messageId, input.context);
    if (input.settings !== undefined) settingsOf.set(input.messageId, input.settings);
  }
  // How many times each turn's engine stopped under it.
  const stops = new Map();
  const failed = new Map();
  // Deadline cut-offs in a row of the open turn's step.
  let cut = noCutoffs;
  let maxCursor = 0;
  const consume = (id) => {
    if (consumed.has(id)) return;
    consumed.add(id);
    recent.push(id);
  };
  // A steer its turn accepted and ended without placing: the model never saw
  // it, so it waits for a turn again.
  const handBack = (id) => {
    if (!consumed.delete(id)) return;
    const index = recent.lastIndexOf(id);
    if (index >= 0) recent.splice(index, 1);
  };
  for (const input of base?.pending ?? []) {
    if (seenInputs.has(input.key)) continue;
    seenInputs.add(input.key);
    inputs.push(input);
  }
  for (const { cursor, entry } of entries) {
    const position = Number(cursor);
    if (position > maxCursor) maxCursor = position;
    switch (entry?.k) {
      case "input":
        agent ??= typeof entry.agent === "string" ? entry.agent : defaultAgentName;
        if (seenInputs.has(entry.key)) break;
        seenInputs.add(entry.key);
        inputs.push({ ...entry, cursor: position });
        if (entry.context !== undefined) contexts.set(entry.messageId, entry.context);
        if (entry.settings !== undefined) settingsOf.set(entry.messageId, entry.settings);
        break;
      case "lease":
      case "release":
      case "record": {
        // A chained entry stands only when it continues the chain; the
        // first writer to continue a cursor wins and the rest are fenced.
        if ((entry.a ?? null) !== head) break;
        head = cursor;
        if (entry.k === "lease") {
          lease = { holder: entry.holder, epoch: entry.epoch, expiresAt: entry.expiresAt ?? null, pid: entry.pid, host: entry.host, delivery: entry.delivery, cursor };
          if (Number.isSafeInteger(entry.epoch) && entry.epoch > epoch) epoch = entry.epoch;
        } else if (entry.k === "release") {
          if (lease?.holder === entry.holder) lease = null;
          if (typeof entry.cutoff === "string" && entry.cutoff === openTurn?.id) cut = afterCutoff(cut);
        } else {
          cut = afterRecord(cut, entry.marks);
          records.push({ cursor, data: entry.data });
          for (const mark of entry.marks ?? []) {
            if (typeof mark.start === "string") {
              const opener = inputs.find((input) => input.messageId === mark.start);
              openTurn = { id: mark.start, at: position, from: opener?.cursor ?? position, context: contexts.get(mark.start) ?? null, settings: settingsOf.get(mark.start) ?? null };
              consume(mark.start);
              yielded = false;
            } else if (mark.end === true) {
              if (openTurn) lastTurnId = openTurn.id;
              openTurn = null;
              yielded = false;
              // A turn's unplaced inputs end with it, handed back first.
              held.clear();
            } else if (mark.yield === true) {
              yielded = true;
            } else if (typeof mark.accepted === "string") {
              consume(mark.accepted);
              held.add(mark.accepted);
            } else if (typeof mark.placed === "string") {
              held.delete(mark.placed);
            } else if (typeof mark.withdrawn === "string") {
              held.delete(mark.withdrawn);
              handBack(mark.withdrawn);
            }
          }
        }
        break;
      }
      case "failed":
        // A message whose turn could not start is answered and done.
        failed.set(entry.messageId, entry.error ?? { name: "Error", message: "the turn failed" });
        consume(entry.messageId);
        break;
      case "ended":
        // A turn that ended before writing a record of its own, such as one
        // the harness refused or its cancel stopped first. Its outcome is on
        // the UI stream.
        consume(entry.messageId);
        break;
      case "stopped":
        stops.set(entry.messageId, (stops.get(entry.messageId) ?? 0) + 1);
        break;
      default:
        break;
    }
  }
  // What the inputs ask for, given the turns the records started. A
  // prompt's own cancel names its turn, in whichever order the two land.
  const cancelTargets = new Set();
  for (const input of inputs) {
    if (input.type === "cancel" && typeof input.target === "string") cancelTargets.add(input.target);
  }
  // An open turn whose harness could not start has ended for its viewers.
  const openFailed = openTurn !== null && failed.has(openTurn.id);
  // The turns waiting to run, each with the steers that join it when it
  // starts, whether it waited or ran when they came, as the fx CLI's steering
  // does: a text steer stored after the open turn's opener joins that turn,
  // and otherwise the turn waiting before it. A steer that cannot join a
  // turn waits as its own, and the turn it came after ends at its next safe
  // point, at once if it has not started; the steers after it join its turn.
  // A steer with no turn to join starts one.
  const pending = [];
  const steers = [];
  const openOwner = openTurn !== null && !openFailed ? { joiners: steers, ends: false } : null;
  let cancelOpen = false;
  let owner = null;
  for (const input of inputs) {
    if (openOwner !== null && owner === null && input.cursor > openTurn.from) owner = openOwner;
    if (consumed.has(input.messageId)) continue;
    const forOpenTurn = openTurn !== null && input.cursor > openTurn.at;
    if (input.type === "prompt") {
      const entry = { ...input, ...(cancelTargets.has(input.messageId) ? { cancelled: true } : {}), joiners: [], ends: false };
      pending.push(entry);
      // While a turn runs, steers still join it: a prompt is the next turn.
      if (owner === null || owner !== openOwner) owner = entry;
    } else if (input.type === "steer") {
      if (owner !== null && joinable(input.input)) owner.joiners.push(input);
      else {
        if (owner !== null) owner.ends = true;
        owner = { ...input, type: "prompt", joiners: [], ends: false };
        pending.push(owner);
      }
    } else if (input.type === "cancel") {
      if (typeof input.target === "string") {
        if (openTurn?.id === input.target) cancelOpen = true;
      } else if (forOpenTurn) cancelOpen = true;
    }
  }
  // A cancel is spent once it can no longer apply: a prompt's own cancel
  // once its turn ended, and a session cancel once the turn open when it
  // landed ended. Its id is kept like a turn's, so a late delivery of the
  // same message is not taken as a new cancel.
  for (const input of inputs) {
    if (consumed.has(input.messageId)) continue;
    // A resume only asks that its session be woken: it is spent once
    // stored, and its id is kept so its deliveries are known.
    if (input.type === "resume") {
      consume(input.messageId);
      continue;
    }
    if (input.type !== "cancel") continue;
    const live = typeof input.target === "string"
      ? !consumed.has(input.target) || openTurn?.id === input.target
      : openTurn !== null && input.cursor > openTurn.at;
    if (!live) consume(input.messageId);
  }
  // A cancel the failed open turn is due waits for the next prompt's
  // engine. One whose engine stopped each time it continued it is
  // cancelled; one whose engine stopped even then can never go on, and the
  // session runs no more turns.
  const openStops = openTurn === null ? 0 : stops.get(openTurn.id) ?? 0;
  const halted = openStops >= maxHarnessStops + maxCancelStops;
  const stuck = openStops >= maxHarnessStops && !halted;
  const kinds = new Map(inputs.map((input) => [input.messageId, input.type]));
  const kindOf = (id) => kinds.get(id) ?? (baseSteers.has(id) ? "steer" : kindsKnown ? "prompt" : null);
  return {
    // Inputs no turn has taken, as written: what a checkpoint keeps, with
    // the ones the open turn holds unplaced, which a withdrawal hands back.
    unconsumed: inputs.filter((input) => !consumed.has(input.messageId)),
    held: inputs.filter((input) => held.has(input.messageId)),
    heldIds: [...held],
    // A steer that cannot join the open turn waits for it to end.
    endOpen: openOwner?.ends === true,
    head,
    // The lease others must respect, and the chain's latest whether or not
    // it still stands: a worker checks the latter is its own.
    lease: leaseStands(lease, now, alive) ? lease : null,
    lastLease: lease,
    lastEpoch: epoch,
    checkpoint: base ? { through: base.through ?? null, data: base.data } : null,
    records,
    openTurn,
    cut: openTurn === null ? noCutoffs : cut,
    cutoffs: openTurn === null ? 0 : cut.cutoffs,
    openFailed,
    lastTurnId,
    agent,
    yielded,
    pending,
    steers,
    cancelOpen,
    recent: recent.slice(-recentIdsKept),
    recentSteers: recent.slice(-recentIdsKept).filter((id) => kindOf(id) === "steer"),
    // What kind of input a taken id named, or null when no record says.
    consumedKind: (id) => (consumed.has(id) ? kindOf(id) : null),
    consumed,
    failed,
    stops,
    inputKeys: seenInputs,
    maxCursor,
    stuck,
    halted,
    // A halted session's open turn is work until it ends with an error.
    hasWork: (openTurn !== null && !openFailed) || pending.length > 0,
  };
}

function leaseStands(lease, now, alive) {
  if (!lease) return false;
  const living = alive(lease);
  if (living === false) return false;
  if (lease.expiresAt !== null && lease.expiresAt !== undefined && now >= lease.expiresAt) return false;
  return true;
}

// Which queue message a delivery carries, by the queue's own id, and which
// delivery of it this is, when the World reports both.
function deliveryOf(meta) {
  const messageId = meta?.messageId;
  const attempt = meta?.attempt;
  return typeof messageId === "string" && messageId.length > 0 && Number.isSafeInteger(attempt) && attempt > 0
    ? { messageId, attempt }
    : null;
}

// Whether `delivery`, in another process, carries the message whose delivery
// took `lease`. A queue hands a message on only once the delivery holding it
// let it go unacknowledged: its handler failed, or its process died or lost
// the message. On Vercel, a function whose process exits mid-delivery runs
// the same delivery again, attempt and all, in a new process. Either way the
// holder no longer runs the session, or runs it replaced without knowing,
// and its next write is fenced.
function redelivers(delivery, lease) {
  const held = lease?.delivery;
  return Boolean(delivery && held && held.messageId === delivery.messageId &&
    Number.isSafeInteger(held.attempt) && delivery.attempt >= held.attempt);
}

// ---------------------------------------------------------------------------
// Backends. Each gives sessions a log, a stream, and a queue.

function createMemoryBackend({ maxDurationMs, reserveMs } = {}) {
  const sessions = new Map();
  const holders = liveHolders;
  // The agents sharing the backend, by name: an agent's copies take the
  // deliveries for its name in turn.
  const handlers = new Map();
  const timers = new Set();
  const sessionFor = (id) => {
    let session = sessions.get(id);
    if (!session) {
      session = { entries: [], head: null, ui: [], uiWaiters: new Set(), watchers: new Set(), images: new Map() };
      sessions.set(id, session);
    }
    return session;
  };
  const later = (fn, ms) => {
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timers.add(timer);
  };
  // A message keeps its id across its deliveries, as a queue's does.
  const deliver = (message, attempt, messageId = newId("qmsg")) => {
    if (handlers.size === 0) return later(() => deliver(message, attempt, messageId), 10);
    const group = handlers.get(agentOf(message));
    // No agent of that name here yet: tried again, as a failed delivery is.
    if (!group) {
      if (attempt < 48) later(() => deliver(message, attempt + 1, messageId), 1000);
      return;
    }
    const handler = group.members[group.turn++ % group.members.length];
    Promise.resolve()
      .then(() => handler(message, { messageId, attempt }))
      .then((result) => {
        if (Number.isFinite(result?.timeoutSeconds)) later(() => deliver(message, attempt + 1, messageId), result.timeoutSeconds * 1000);
      }, () => {
        if (attempt < 48) later(() => deliver(message, attempt + 1, messageId), 1000);
      });
  };
  return {
    name: "memory",
    livenessKnown: true,
    runInRequest: false,
    queueDurable: false,
    pollMs: null,
    reserveMs: reserveMs ?? defaultReserveMs,
    maxDurationMs: maxDurationMs ?? null,
    newSessionId: () => newId("ses"),
    validSessionId: validId,
    deadline: () => null,
    holderInfo: () => ({}),
    alive: (lease) => holders.has(lease.holder),
    holding(holder, held) {
      if (held) holders.add(holder);
      else holders.delete(holder);
    },
    async session(id) {
      const session = sessionFor(id);
      return {
        async read() {
          let from = 0;
          for (let index = session.entries.length - 1; index >= 0; index -= 1) {
            const entry = session.entries[index].entry;
            if (entry.k === "checkpoint") {
              from = entry.through === null ? 0 : Number(entry.through);
              break;
            }
          }
          return session.entries.slice(from);
        },
        async readSince(cursor) {
          return session.entries.slice(Number(cursor));
        },
        async append(entry) {
          const chained = entry.k === "lease" || entry.k === "release" || entry.k === "record";
          if (chained && (entry.a ?? null) !== session.head) {
            // A retry of an entry that landed returns its cursor.
            const landed = session.entries.find((item) => item.entry.key !== undefined && item.entry.key === entry.key && item.entry.k === entry.k);
            if (landed) return landed.cursor;
            throw new FencedError(`another worker continued session ${id}`);
          }
          const cursor = String(session.entries.length + 1);
          session.entries.push({ cursor, entry: structuredClone(entry) });
          if (chained) session.head = cursor;
          for (const watcher of session.watchers) watcher();
          return cursor;
        },
        watch(fn) {
          session.watchers.add(fn);
          return () => session.watchers.delete(fn);
        },
        images: {
          async put(name, bytes) {
            if (!session.images.has(name)) session.images.set(name, bytes.slice());
          },
          async get(name) {
            return session.images.get(name)?.slice();
          },
        },
        ui: {
          async write(lines) {
            session.ui.push(...lines);
            for (const waiter of session.uiWaiters) waiter();
          },
          async length() {
            return session.ui.length;
          },
          read(from) {
            let index = from;
            let wake = null;
            const notify = () => wake?.();
            return new ReadableStream({
              start() { session.uiWaiters.add(notify); },
              async pull(controller) {
                while (index >= session.ui.length) await new Promise((resolve) => { wake = resolve; });
                wake = null;
                controller.enqueue(encoder.encode(`${session.ui[index++]}\n`));
              },
              cancel() { session.uiWaiters.delete(notify); notify(); },
            });
          },
        },
      };
    },
    queue: {
      async send(message, { delaySeconds = 0 } = {}) {
        later(() => deliver(message, 1), delaySeconds * 1000);
      },
    },
    listen(fn, name = defaultAgentName) {
      const group = joinGroup(handlers, name, fn);
      return () => {
        leaveGroup(handlers, name, group, fn);
        if (handlers.size > 0) return;
        // Nobody is left to deliver to.
        for (const timer of timers) clearTimeout(timer);
        timers.clear();
      };
    },
  };
}

// World runs are sessions; `fx.log` steps are its entries.
const logStep = "fx.log";
// A World names streams for its whole project, so each session's stream is
// named after its run, as Workflow names a run's own streams: `strm_` and
// the run's id, then `_user_` and the base64url of the namespace
// "libfx-ui".
const uiStreamOf = (runId) => `${runId.replace(/^wrun_/, "strm_")}_user_bGliZngtdWk`;
// The stream that holds an image, named as the UI stream is, with the
// namespace "libfx-image-" and the image's name.
const imageStreamOf = (runId, name) => `${runId.replace(/^wrun_/, "strm_")}_user_${base64url(`libfx-image-${name}`)}`;
const queuePrefix = "__libfx_wkf_workflow_";
// The name of an agent created without one, and of whatever a message or a
// session from before names belonged to.
const defaultAgentName = "default";
const agentNameRule = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// The agent a queued message is for.
const agentOf = (message) => (typeof message?.agent === "string" ? message.agent : defaultAgentName);
const queueName = `${queuePrefix}session`;
const eventIdPattern = /^[a-z]+_(\d{26})$/;

function ulid(now = Date.now()) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let rest = now, index = 0; index < 10; index += 1, rest = Math.floor(rest / 32)) time = alphabet[rest % 32] + time;
  let random = "";
  for (const byte of crypto.getRandomValues(new Uint8Array(16))) random += alphabet[byte % 32];
  return time + random;
}

// The entries that continue a session's chain of claims and records.
function chainedKind(k) {
  return k === "lease" || k === "release" || k === "record";
}

// A run's in-band count right after its creation, as `@workflow/world`
// defines it (`IN_BAND_SEQ_AT_RUN_CREATION`): `run_created` counts as the
// first in-band write.
const inBandAtRunCreation = 1;

// The World's in-band writer fence refused a write: another writer moved the
// run's in-band count past the one the write expected.
function inBandSuperseded(error) {
  return error?.name === "InBandSupersededError" || error?.code === "in-band-superseded" || error?.status === 412;
}

function slotOf(event) {
  const match = eventIdPattern.exec(String(event?.eventId ?? ""));
  if (!match) throw new Error(`the World returned event id ${JSON.stringify(event?.eventId ?? null)}, which holds no slot`);
  return Number(match[1]);
}

function logEntryOf(event) {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== logStep) return null;
  const input = event.eventData.input;
  if (!(input instanceof Uint8Array)) return null;
  try { return JSON.parse(decoder.decode(input)); } catch { return null; }
}

const missingRun = (error) => error?.status === 404 || /not found|does not exist|ENOENT/i.test(String(error?.message ?? ""));
// Tries for a failed UI stream read that is not a missing stream.
const streamReadRetries = 5;
// How often a viewer looks for a session stream that does not exist yet,
// and for how long before it backs off.
const missingStreamPollMs = 50;
const missingStreamFastMs = 2000;

// Events a session-log read lists per page: the first page, then the rest.
const firstPageEvents = 10;
const laterPageEvents = 100;

// The agents listening on each World in this process. A World holds one
// handler for libfx's queue, so the agents given one World take its
// deliveries in turn, as servers sharing a queue do.
const listenersOf = new WeakMap();

// Adds `member` to the group for `name` in `groups`, a Map of name to
// `{ members, turn }`, and returns the group; leaveGroup takes it out again.
function joinGroup(groups, name, member) {
  let group = groups.get(name);
  if (!group) groups.set(name, group = { members: [], turn: 0 });
  group.members.push(member);
  return group;
}

function leaveGroup(groups, name, group, member) {
  const index = group.members.indexOf(member);
  if (index >= 0) group.members.splice(index, 1);
  if (group.members.length === 0 && groups.get(name) === group) groups.delete(name);
}

function noAgentNamed(name) {
  return Object.assign(new Error(`no libfx agent named ${JSON.stringify(name)} runs in this process; the queue delivers this again`), { code: "FX_NO_AGENT", agent: name });
}

// The durable agents in this process, by name, from when each is created
// until it closes, each as `{ open, durability }`: a route delivers each
// message to the agent it names, and a function that only receives queue
// messages has its agents here before any of them is used. Shared by every
// copy of this module in the process.
const agentsByName = (globalThis[Symbol.for("libfx.durableAgents")] ??= new Map());

// The backend a member opens, or null when it cannot open, as an agent
// libfx refused to create cannot.
const openMember = (member) => member.open().catch(() => null);

// The World backend of an agent named `name` in this process whose
// durability `matches`, the agent's copies in turn, or null.
async function agentNamed(name, matches) {
  const group = agentsByName.get(name);
  if (!group) return null;
  const { members } = group;
  const first = group.turn++;
  for (let index = 0; index < members.length; index += 1) {
    const member = members[(first + index) % members.length];
    if (!matches(await member.durability())) continue;
    const created = await openMember(member);
    if (typeof created?.deliverHere === "function") return created;
  }
  return null;
}

// Agents share sessions through the durability they were created with, so
// one on another durability can hold other sessions.
const agentSharing = (name, durability) => agentNamed(name, (other) => other === durability);

// The store a World keeps its sessions in, as its queue messages name it:
// its `store`, which is its name unless the app named the store.
const worldStore = (durability) => durability?.store ?? durability?.name;

// The store a durability keeps its sessions in, as libfx tells stores apart:
// a memory() is its own, and a World's is its worldStore(). Two agents of one
// name on one store are one agent.
const storeOf = (durability) => (typeof durability?.create === "function" ? durability : `world:${worldStore(durability)}`);

// A route takes its deployment's deliveries for every World in the process,
// so a delivery goes to the agent its message names on the store it names,
// and never to one of that name on another store
// (`tests/tla/sdk/TenantIsolation.tla` RunsInSenderStore).
const agentOnStore = (name, store) => agentNamed(name, (other) => typeof other.world === "function" && other.create === undefined && worldStore(other) === store);

/**
 * The request handler a deployment mounts for queue deliveries, for every
 * durable agent in the process: each delivery goes to the agent its message
 * names, on the store it names. One route and one queue trigger serve any
 * number of agents.
 */
export function wakeHandler() {
  return async (request) => {
    for (const group of agentsByName.values()) {
      for (const member of group.members) {
        const created = await openMember(member);
        if (created?.viaRoute === true) return created.queueHandler(request);
      }
    }
    return new Response("no libfx agent in this process takes queue deliveries from a route", { status: 503 });
  };
}

const nameInUse = (name) => Object.assign(
  new Error(`an agent named ${JSON.stringify(name)} with another configuration already runs on this store in this process; give each configuration its own name, or each store its own \`store\``),
  { code: "FX_AGENT_NAME_IN_USE", agent: name },
);

// Whether two agents' options are one configuration: the same values, and
// the same functions and objects other than plain ones. `onEvent` only
// watches the agent, so it is left out.
function definitionOf(options) {
  const { onEvent: _onEvent, ...definition } = options;
  return definition;
}
function sameDefinition(a, b, depth = 0) {
  if (Object.is(a, b)) return true;
  if (depth > 32 || a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (ArrayBuffer.isView(a) || ArrayBuffer.isView(b)) {
    if (!ArrayBuffer.isView(a) || !ArrayBuffer.isView(b) || a.byteLength !== b.byteLength) return false;
    const left = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
    const right = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    for (let index = 0; index < left.length; index += 1) if (left[index] !== right[index]) return false;
    return true;
  }
  const plain = (value) => Array.isArray(value) || Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null;
  if (!plain(a) || !plain(b) || Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => Object.hasOwn(b, key) && sameDefinition(a[key], b[key], depth + 1));
}

// Refuses `member` when another agent of `name` on its store has another
// configuration: deliveries for a name on a store go to any of its agents,
// so they must be one agent (`tests/tla/sdk/TenantIsolation.tla`
// RunsOnSenderAgent). Agents created without a durability share their
// factory's default, so they are on one store even before one of them has
// learned which store that is.
const sameStore = (a, b) => a.store === b.store || (a.defaults !== null && a.defaults === b.defaults);
function claimName(name, member) {
  for (const other of agentsByName.get(name)?.members ?? []) {
    if (other !== member && sameStore(other, member) && !sameDefinition(other.definition, member.definition)) throw nameInUse(name);
  }
}

// libfx starts and closes a World it `owned`, having created it; a World the
// app passed in stays the app's.
function createWorldBackend(world, durability) {
  const { name, reserveMs, pollMs, leaseMs, alive, holderInfo, livenessKnown = false, queueLeases = false, runInRequest = queueLeases, waitUntil, queueDurable = false, maxDurationMs, owned = true } = durability;
  const spec = world.specVersion === undefined ? {} : { specVersion: world.specVersion };
  const created = new Set();
  // Runs being created now: writes that go out together create a run once.
  const creating = new Map();
  // Workers in this process hear about each other's entries at once; others
  // poll.
  const watchers = new Map();
  const changed = (runId) => { for (const watcher of watchers.get(runId) ?? []) watcher(); };
  let handler = null;
  const route = typeof world.registerHandler !== "function";
  const listEvents = (runId, cursor, limit) => world.events.list({
    runId,
    pagination: { sortOrder: "desc", limit, ...(cursor ? { cursor } : {}) },
    resolveData: "all",
  });
  // `meta` says which queue message this is and which delivery of it.
  const deliverTo = async (handle, message, meta) => {
    const input = message?.input;
    if (!input || typeof input !== "object") return undefined;
    if (!handle) {
      // A World libfx created closes with its agent. The app's own World
      // outlives it, so its queue keeps the message for the next agent.
      if (owned) return undefined;
      throw new Error("no libfx agent is listening; the queue delivers this again");
    }
    const result = await handle(input, meta);
    // The queue delivers this same message again, which takes back a lease
    // its worker could not let go.
    if (result?.redeliver === true) throw new Error("libfx asks the queue to deliver this message again");
    return Number.isFinite(result?.timeoutSeconds) ? { timeoutSeconds: result.timeoutSeconds } : undefined;
  };
  const store = worldStore(durability);
  // The route a deployment mounts delivers to the agent in this process the
  // message names, on the store it names, whichever agent's route it is. A
  // message from before stores were named is for this World's store.
  const queueHandler = world.createQueueHandler(queuePrefix, async (message, meta) => {
    const named = agentOf(message?.input);
    const agent = await agentOnStore(named, typeof message?.input?.store === "string" ? message.input.store : store);
    if (!agent) throw noAgentNamed(named);
    return agent.deliverHere(message, meta);
  });
  const backend = {
    name,
    store,
    livenessKnown,
    queueLeases,
    // A prompt runs in the request that took it, held by its backstop's
    // message, which the queue keeps until after the request's deadline.
    runInRequest: queueLeases && runInRequest,
    // Keeps the request alive for a turn it runs after its response.
    waitUntil: waitUntil ?? null,
    queueDurable,
    pollMs: pollMs ?? 1000,
    reserveMs: reserveMs ?? defaultReserveMs,
    leaseMs: leaseMs ?? defaultLeaseMs,
    maxDurationMs: maxDurationMs ?? null,
    world,
    newSessionId: () => `wrun_${typeof world.createRunId === "function" ? world.createRunId({}) : ulid()}`,
    validSessionId: (id) => typeof id === "string" && /^wrun_[0-9A-Za-z]{10,64}$/.test(id),
    deadline: () => null,
    holderInfo: holderInfo ?? (() => ({})),
    // Whether a lease's holder still runs, as `delivery` can tell: a worker
    // of this process runs while it holds it, and the message its delivery
    // held, delivered to this process, means it no longer does.
    alive(lease, delivery = null) {
      if (liveHolders.has(lease.holder)) return true;
      const mine = holderInfo?.() ?? {};
      if (mine.pid !== undefined && lease.pid === mine.pid && lease.host === mine.host) return false;
      if (redelivers(delivery, lease)) return false;
      return alive ? alive(lease) : null;
    },
    holding(holder, held) {
      if (held) liveHolders.add(holder);
      else liveHolders.delete(holder);
    },
    async start() {
      if (owned) await world.start?.();
      if (typeof world.getRuntimeDeadline === "function") {
        backend.deadline = () => backend.runtimeDeadline ?? null;
      }
    },
    async refreshDeadline() {
      if (typeof world.getRuntimeDeadline !== "function") return;
      try {
        const deadline = await world.getRuntimeDeadline();
        backend.runtimeDeadline = deadline instanceof Date ? deadline.getTime() : null;
      } catch {
        backend.runtimeDeadline = null;
      }
    },
    async session(runId) {
      // The newest slot this worker has seen.
      let known = 0;
      // The images this worker knows the run's image store holds.
      const storedImages = new Set();
      // Where the World has the in-band writer fence, chained entries are
      // written in-band, each expecting the World's count of in-band writes
      // at the entry it continues, so the World refuses one that continues a
      // superseded head and nothing of it lands. `inBandAt` maps a chained
      // entry's cursor (`null` for an empty chain) to the count right after
      // it: from the snapshot a read returns, or from the write itself. The
      // check after a write stays, since a World may count per process.
      const inBandAt = new Map();
      let inBand = world.capabilities?.inBandFence === true;
      const noteInBand = (cursor, count) => {
        inBandAt.delete(cursor);
        inBandAt.set(cursor, count);
        if (inBandAt.size > 16) inBandAt.delete(inBandAt.keys().next().value);
      };
      // A snapshot is read before its listing, so it gives the count at the
      // chain's head only when it covers the head's slot. It never replaces
      // a count this worker's own write reported.
      const noteSnapshot = (snapshot, cursor) => {
        if (!inBand || cursor === undefined || inBandAt.has(cursor) || !Number.isSafeInteger(snapshot?.seqInBand)) return;
        if (cursor !== "null" && !(Number(cursor) <= snapshot.seq)) return;
        noteInBand(cursor, snapshot.seqInBand);
      };
      const ensureRun = () => {
        if (created.has(runId)) return Promise.resolve();
        let pending = creating.get(runId);
        if (!pending) {
          pending = createRun().finally(() => creating.delete(runId));
          creating.set(runId, pending);
        }
        return pending;
      };
      const createRun = async () => {
        try {
          const deploymentId = typeof world.getDeploymentId === "function" ? await world.getDeploymentId() : "libfx";
          await world.events.create(runId, {
            eventType: "run_created",
            ...spec,
            eventData: { deploymentId, workflowName: "libfx/session", input: encoder.encode("{}") },
          });
        } catch (error) {
          // Another worker created it first.
          if (!/exist|conflict|409|already/i.test(String(error?.message ?? "")) && error?.status !== 409) throw error;
        }
        try {
          await world.events.create(runId, { eventType: "run_started", ...spec });
        } catch (error) {
          if (!/exist|conflict|409|already|started|status/i.test(String(error?.message ?? "")) && error?.status !== 409) throw error;
        }
        created.add(runId);
      };
      // Events newest first, down to and excluding slot `stopBelow`.
      const newestFirst = async (stopBelow, stopAtCheckpoint) => {
        const events = [];
        let through = null;
        let snapshot;
        // The newest chained entry read: the chain's head, unless the read
        // stopped before reaching any.
        let newestChained;
        // Ends the read. `head` is where the chain's head is when the read
        // found no chained entry, or undefined when the read does not show.
        const done = (head) => {
          noteSnapshot(snapshot, newestChained ?? head);
          return { events, through };
        };
        // A session's newest checkpoint is usually among its last few
        // entries, so a read starts with a small page and fetches more only
        // while it has not reached where it stops; every page carries its
        // entries' payloads, a checkpoint holding the whole conversation.
        for (let cursor, limit = firstPageEvents; ; limit = laterPageEvents) {
          let page;
          try {
            page = await listEvents(runId, cursor, limit);
          } catch (error) {
            if (!missingRun(error)) throw error;
            // The run's creation starts its count.
            if (stopBelow === 0) noteSnapshot({ seq: 0, seqInBand: inBandAtRunCreation }, "null");
            return { events, through };
          }
          snapshot ??= page.snapshot;
          for (const event of page.data) {
            const slot = slotOf(event);
            if (slot > known) known = slot;
            if (slot <= stopBelow) return done(undefined);
            // The checkpoint stands for the entries through its `through`,
            // the last of them the chain's head.
            if (through !== null && slot <= through) return done(through === 0 ? "null" : String(through));
            const entry = logEntryOf(event);
            if (!entry) continue;
            created.add(runId);
            if (newestChained === undefined && chainedKind(entry.k)) newestChained = String(slot);
            events.push({ cursor: String(slot), entry });
            if (stopAtCheckpoint && through === null && entry.k === "checkpoint") {
              through = entry.through === null || entry.through === undefined ? 0 : Number(entry.through);
            }
          }
          if (!page.hasMore) return done(stopBelow > 0 ? undefined : through ? String(through) : "null");
          cursor = page.cursor;
        }
      };
      return {
        async read() {
          const { events } = await newestFirst(0, true);
          return events.reverse();
        },
        async readSince(cursor) {
          const { events } = await newestFirst(Number(cursor), false);
          return events.reverse();
        },
        async append(entry) {
          await ensureRun();
          const chained = chainedKind(entry.k);
          // A chained entry asks the World to report every event since the
          // one it continues, so a competing continuation is seen.
          const after = chained ? (entry.a === null || entry.a === undefined ? 0 : Number(entry.a)) : known;
          const continues = entry.a === null || entry.a === undefined ? "null" : String(entry.a);
          let expected = chained && inBand ? inBandAt.get(continues) : undefined;
          const event = {
            eventType: "step_created",
            correlationId: `step_${ulid()}`,
            eventData: { stepName: logStep, input: encoder.encode(JSON.stringify(entry)) },
          };
          let result;
          for (let recounted = false; ;) {
            try {
              result = await world.events.create(runId, event, expected === undefined ? { eventCount: after } : { eventCount: after, inBand: true, expectedSeqInBand: expected });
              break;
            } catch (error) {
              if (expected === undefined) throw error;
              if (inBandSuperseded(error)) {
                // The next read maps the head afresh.
                inBandAt.delete(continues);
                // A World counts a write after it publishes it, so a read
                // between the two gave this head the count before its own
                // write. When nothing else continued the head, the write goes
                // again once at the count the World reports.
                if (!recounted && Number.isSafeInteger(error?.seqInBand)) {
                  const { events: since } = await newestFirst(after, false);
                  const rivals = since.filter(({ entry: other }) => chainedKind(other.k) && (other.a ?? null) === (entry.a ?? null));
                  // Our own earlier write of this entry landed first.
                  const ours = rivals.find(({ entry: other }) => other.key !== undefined && other.key === entry.key && other.k === entry.k);
                  if (ours) return ours.cursor;
                  if (rivals.length === 0) {
                    recounted = true;
                    expected = error.seqInBand;
                    continue;
                  }
                }
                throw new FencedError(`another worker continued session ${runId}`);
              }
              // A World may refuse in-band writes on a run it stamped before
              // it had the fence; the write goes out-of-band, as before.
              if (!(error?.status >= 400 && error?.status < 500) || error?.status === 409) throw error;
              inBand = false;
              expected = undefined;
            }
          }
          const slot = slotOf(result.event);
          if (slot > known) known = slot;
          if (expected !== undefined && result.allocated !== undefined) noteInBand(String(slot), expected + result.allocated);
          changed(runId);
          if (!chained || slot === after + 1) return String(slot);
          const reported = Array.isArray(result.events) ? result.events : (await newestFirst(after, false)).events.map((item) => ({ eventId: `evnt_${String(item.cursor).padStart(26, "0")}`, ...item }));
          for (const event of reported) {
            const other = event.entry ?? logEntryOf(event);
            const otherSlot = event.entry ? Number(event.cursor) : slotOf(event);
            if (!other || otherSlot <= after || otherSlot >= slot) continue;
            const otherChained = chainedKind(other.k);
            if (!otherChained || (other.a ?? null) !== (entry.a ?? null)) continue;
            // Our own earlier write of this entry landed first.
            if (other.key !== undefined && other.key === entry.key && other.k === entry.k) return String(otherSlot);
            throw new FencedError(`another worker continued session ${runId}`);
          }
          return String(slot);
        },
        watch(fn) {
          let set = watchers.get(runId);
          if (!set) watchers.set(runId, set = new Set());
          set.add(fn);
          return () => set.delete(fn);
        },
        // Each image is a stream of the run, named after it, so it is read by
        // name wherever checkpoints fall. Two writers of one image each add
        // its bytes once; a read takes the first chunk that matches the name.
        images: {
          async put(name, bytes) {
            if (storedImages.has(name)) return;
            // Refused here, before the prompt is stored, rather than by every
            // worker that reads the image back.
            if (typeof world.streams.getChunks !== "function") throw new TypeError("a World needs streams.getChunks() to keep a session's images");
            await ensureRun();
            const stream = imageStreamOf(runId, name);
            let present = false;
            try {
              present = Number((await world.streams.getInfo(runId, stream))?.tailIndex ?? -1) >= 0;
            } catch (error) {
              if (!missingRun(error)) throw error;
            }
            if (!present) await world.streams.write(runId, stream, bytes);
            storedImages.add(name);
          },
          async get(name) {
            let page;
            try {
              page = await world.streams.getChunks(runId, imageStreamOf(runId, name), { limit: 8 });
            } catch (error) {
              if (missingRun(error)) return undefined;
              throw error;
            }
            for (const chunk of page?.data ?? []) {
              const bytes = byteView(chunk?.data);
              if (bytes && bytes.byteLength > 0 && await imageName(bytes) === name) {
                storedImages.add(name);
                return bytes.slice();
              }
            }
            return undefined;
          },
        },
        ui: {
          async write(lines) {
            await ensureRun();
            const chunks = lines.map((line) => `${line}\n`);
            if (typeof world.streams.writeMulti === "function" && chunks.length > 1) await world.streams.writeMulti(runId, uiStreamOf(runId), chunks);
            else for (const chunk of chunks) await world.streams.write(runId, uiStreamOf(runId), chunk);
          },
          async length() {
            try {
              const info = await world.streams.getInfo(runId, uiStreamOf(runId));
              return Math.max(0, Number(info?.tailIndex ?? -1) + 1);
            } catch {
              return 0;
            }
          },
          read(from) {
            let reader = null;
            let cancelled = false;
            const opened = Date.now();
            return new ReadableStream({
              async pull(controller) {
                for (let delay = missingStreamPollMs, failures = 0; !reader;) {
                  if (cancelled) return;
                  try {
                    reader = (await world.streams.get(runId, uiStreamOf(runId), from)).getReader();
                  } catch (error) {
                    // A stream nobody wrote yet appears with the turn's first
                    // event; any other failure gets a few tries, then ends
                    // the read, so its viewer hears of it.
                    const missing = missingRun(error);
                    if (!missing && ++failures > streamReadRetries) {
                      controller.error(error);
                      return;
                    }
                    await new Promise((resolve) => setTimeout(resolve, delay));
                    // A new session's stream appears within moments of its
                    // first prompt, so it is looked for often at first.
                    delay = missing && Date.now() - opened < missingStreamFastMs ? missingStreamPollMs : Math.min(delay * 2, 1000);
                  }
                }
                const { value, done } = await reader.read();
                if (done) controller.close();
                else controller.enqueue(typeof value === "string" ? encoder.encode(value) : value);
              },
              // A live World read can take minutes to cancel, so nothing
              // waits for it: a viewer that has its turn's end is done.
              cancel() {
                cancelled = true;
                void reader?.cancel().catch(() => {});
              },
            });
          },
        },
      };
    },
    queue: {
      // Returns the queue's id for the message, when the World gives one.
      async send(message, { delaySeconds = 0, idempotencyKey } = {}) {
        const sent = await world.queue(queueName, { runId: message.sessionId, requestId: message.messageId, input: message }, {
          ...(idempotencyKey ? { idempotencyKey } : {}),
          ...(delaySeconds > 0 ? { delaySeconds } : {}),
        });
        return typeof sent?.messageId === "string" && sent.messageId.length > 0 ? { messageId: sent.messageId } : {};
      },
    },
    // The route a deployment mounts for queue deliveries, until the World
    // can deliver to an in-process handler itself.
    queueHandler,
    durability,
    // Whether the queue delivers to queueHandler, mounted by the deployment.
    viaRoute: route,
    // Delivers a routed message to this backend's agent.
    deliverHere: (message, meta) => deliverTo(handler, message, meta),
    listen(fn, name = defaultAgentName) {
      handler = fn;
      if (route) return () => { if (handler === fn) handler = null; };
      // The agents on this World, by name: an agent's copies take the
      // deliveries for its name in turn. A name none of them has goes to an
      // agent of that name on the same durability elsewhere in the process,
      // as each agent has a World of its own, and one the process has none
      // of is left for the queue to deliver again.
      let listeners = listenersOf.get(world);
      if (!listeners) {
        listeners = new Map();
        listenersOf.set(world, listeners);
        world.registerHandler(queuePrefix, world.createQueueHandler(queuePrefix, async (message, meta) => {
          const named = agentOf(message?.input);
          const group = listeners.get(named);
          if (group) return deliverTo(group.members[group.turn++ % group.members.length], message, meta);
          const agent = await agentSharing(named, durability);
          if (agent) return agent.deliverHere(message, meta);
          if (listeners.size === 0) return deliverTo(null, message, meta);
          throw noAgentNamed(named);
        }));
      }
      const group = joinGroup(listeners, name, fn);
      return () => {
        if (handler === fn) handler = null;
        leaveGroup(listeners, name, group, fn);
      };
    },
    // Closing is best effort: a runtime whose HTTP agent cannot close, as
    // under Bun, still lets the agent go.
    async close() {
      if (!owned) return;
      try {
        await world.close?.();
      } catch {}
    },
  };
  return backend;
}


// ---------------------------------------------------------------------------
// The worker: runs a session's turns while it holds the lease.

// Lines a worker writes to the session's UI stream, in order. A line goes
// out at once when no write is in flight; lines pushed during one go
// together in the next. Each carries the worker's lease epoch, so a reader
// can tell a replaced worker's late lines from its successor's.
function uiWriter(log, onError, epoch) {
  let queued = [];
  let writing = null;
  const send = () => {
    const lines = queued;
    queued = [];
    writing = log.ui.write(lines).catch(onError).then(() => {
      writing = null;
      if (queued.length > 0) send();
    });
  };
  return {
    push(event) {
      queued.push(JSON.stringify(epoch === undefined ? event : { ...event, epoch }));
      if (!writing) send();
    },
    // Waits until every line pushed so far is written.
    async settle() {
      while (writing) await writing;
    },
  };
}

// What a turn runs with: its caller's context and its session object's
// settings, from the input that started it or from the open turn.
const runOf = (input) => ({ context: input?.context ?? null, settings: input?.settings ?? null });

const errorSummary = (error) => ({ name: error?.name ?? "Error", message: String(error?.message ?? error), ...(error?.code ? { code: error.code } : {}) });
// The harness contract: a fenced write rejects with this code.
const isFenced = (error) => error?.code === "FX_FENCED";

// The kinds of message a session's queue carries.
const messageTypes = new Set(["prompt", "steer", "cancel", "resume"]);

// What the queue carries for a message: only which input of which session
// it names, for which agent, on which store. A delivery can arrive at a
// public route, so its body may come from anyone: a worker acts only on a
// message its session's log already holds, and runs only what that log
// says (`tests/tla/sdk/TenantIsolation.tla` OnlySentRuns).
function queuedMessage(message, store) {
  return {
    type: message.type,
    messageId: message.messageId,
    sessionId: message.sessionId,
    agent: typeof message.agent === "string" ? message.agent : defaultAgentName,
    ...(typeof store === "string" ? { store } : {}),
  };
}

// The message a delivery names, as queuedMessage() has it, or null for one
// no sender could have queued on `backend`.
function deliveredMessage(backend, delivered) {
  if (!delivered || typeof delivered !== "object" || !messageTypes.has(delivered.type)) return null;
  if (!validId(delivered.messageId) || !backend.validSessionId(delivered.sessionId)) return null;
  if (delivered.agent !== undefined && typeof delivered.agent !== "string") return null;
  return queuedMessage(delivered);
}

// Whether the session's log holds the input `message` names, or names it
// among those a turn already took.
const knownMessage = (state, message) => state.inputKeys.has(`${message.type}:${message.messageId}`) || state.consumed.has(message.messageId);

// The most a durable input may hold: its content blocks with its caller's
// context and its session object's settings, as JSON. The engine refuses a
// prompt frame over 8 MiB (`maxPromptFrameBytes` in fx-sdk.js), so a larger
// input could never run; it is refused before anything is stored.
const maxInputBytes = 8 * 1024 * 1024;
const jsonBytes = (value) => (value === undefined ? 0 : encoder.encode(JSON.stringify(value)).byteLength);
// A JSON value as it stands now, so what libfx measures is what it stores,
// however the caller changes its object later. Pure.
const jsonSnapshot = (value) => {
  const text = JSON.stringify(value);
  return text === undefined ? undefined : JSON.parse(text);
};
const inputTooLarge = (bytes) => Object.assign(
  new RangeError(`a durable input with its context and settings is ${bytes} bytes; the most is ${maxInputBytes}`),
  { code: "FX_INPUT_TOO_LARGE", bytes, limit: maxInputBytes },
);

// What a message adds to its session's log: a restored agent's first
// checkpoint and the message's input, a prompt with its caller's context and
// its session object's settings. Only the sender calls it, before it queues
// the message, so what a turn runs and as whom comes from the app's own
// call, never from a queue delivery. Nothing the log already holds. Pure.
function messageEntries(state, message) {
  const entries = [];
  const named = typeof message.agent === "string" ? { agent: message.agent } : {};
  if (message.seed && state.checkpoint === null && state.records.length === 0) {
    entries.push({ k: "checkpoint", through: null, data: message.seed, ...named });
  }
  const key = `${message.type}:${message.messageId}`;
  const known = state.inputKeys.has(key) || state.consumed.has(message.messageId) || idInUse(state, message);
  if (messageTypes.has(message.type) && !known) {
    entries.push({
      k: "input",
      key,
      type: message.type,
      messageId: message.messageId,
      ...named,
      ...(message.input === undefined ? {} : { input: message.input }),
      ...(typeof message.target === "string" ? { target: message.target } : {}),
      ...((message.type === "prompt" || message.type === "steer") && message.context !== undefined ? { context: message.context } : {}),
      ...((message.type === "prompt" || message.type === "steer") && message.settings !== undefined ? { settings: message.settings } : {}),
    });
  }
  return entries;
}

// Whether a steer's input can join a turn: text. One with images or
// resources runs as its own turn, after the running one hands off to it.
const joinable = (input) => typeof input === "string" || (Array.isArray(input) && input.every((block) => block?.type === "text"));

// Whether `message` reuses the id of the session's other kind of input: one
// id names one input, prompt or steer.
function idInUse(state, message) {
  const other = message.type === "prompt" ? "steer" : message.type === "steer" ? "prompt" : null;
  if (other === null) return false;
  return state.inputKeys.has(`${other}:${message.messageId}`) || state.consumedKind?.(message.messageId) === other;
}

const messageIdInUse = (message) => Object.assign(
  new TypeError(`messageId ${JSON.stringify(message.messageId)} already names a ${message.type === "prompt" ? "steer" : "prompt"} in this session`),
  { code: "FX_MESSAGE_ID_IN_USE" },
);

// Writes what a message adds to its session, in order, and returns how many
// entries it wrote. Only the sender calls it, before it queues the message.
// A message that reuses another input's id writes nothing and throws.
async function recordMessage(log, state, message) {
  if (idInUse(state, message)) throw messageIdInUse(message);
  const entries = messageEntries(state, message);
  for (const entry of entries) await log.append(entry);
  return entries.length;
}

/**
 * The session as a worker can start it before its claim lands: the log it
 * read, with this message's input in it, when that leaves no open turn and
 * a prompt to run. The turn's first model request then needs nothing the
 * claim writes. Null when the worker must claim first: an open turn
 * continues only from the log as its claim finds it, and a restored agent's
 * first checkpoint lands before anything reads it. `fold` folds entries the
 * way the worker does. Pure.
 */
export function earlyStart(entries, state, message, fold) {
  const writes = messageEntries(state, message);
  if (writes.some((entry) => entry.k !== "input")) return null;
  // The input lands after everything the worker read.
  const next = writes.length === 0 ? state : fold([...entries, ...writes.map((entry) => ({ cursor: String(state.maxCursor), entry }))]);
  if (next.openTurn !== null || next.halted || next.pending.length === 0) return null;
  return { writes, state: next };
}

// The log as a worker writes it under a claim still in flight: each write
// waits for the claim, and none is made once it failed. `ready` resolves
// true when the claim landed and false when it failed. A UI line written
// under a failed claim is dropped: its turn never ran for anyone.
function gatedLog(log, ready, claimError) {
  return {
    ...log,
    async append(entry) {
      if (!(await ready)) throw claimError();
      return log.append(entry);
    },
    ui: {
      ...log.ui,
      async write(lines) {
        if (await ready) await log.ui.write(lines);
      },
    },
  };
}

// How long before its deadline a worker stops itself, at most: it cancels
// the model or tool call still running, so it never runs on after its lease
// could pass to another worker.
const hardStopMs = 2000;

const durableInternals = Symbol.for("libfx.durableInternals");

// The shortest wait before a message that found its session running in this
// process is delivered again, as a backstop for the running worker.
const runningBackstopSeconds = 2;

// When a delivery that starts now must stop: its function's deadline, or
// `maxDurationMs` after now; null when nothing stops it.
const deliveryDeadline = (backend) => backend.deadline() ?? (backend.maxDurationMs === null ? null : Date.now() + backend.maxDurationMs);

// How long past the request's own deadline the queue keeps a prompt that
// request runs itself, before it delivers it as a backstop.
const inlineBackstopMarginSeconds = 5;

class SessionWorker {
  constructor(agent, backend, sessionId) {
    this.agent = agent;
    this.backend = backend;
    this.sessionId = sessionId;
    // Set while this process runs the session; each run holds its own lease.
    this.running = false;
    // Deliveries in progress for the session in this process.
    this.deliveries = 0;
    this.holder = null;
  }

  // The log folded as `delivery` judges whether a lease's holder lives.
  fold(entries, delivery = null) {
    return foldSessionLog(entries, { now: Date.now(), alive: (lease) => this.backend.alive(lease, delivery) });
  }

  // One queue delivery, `delivery` its message's id and attempt when the
  // queue reports them. Its sender stored its input before queueing it, so a
  // steer or cancel reaches the running turn even before this runs. A
  // delivery the session's log does not hold is not from a sender and is
  // dropped before anything is written, whether or not its session exists
  // (`tests/tla/sdk/TenantIsolation.tla` OnlySentRuns). Then it runs the
  // session when no live worker holds it. Returns `{ timeoutSeconds }` to
  // have the same message delivered again later.
  async consume(message, delivery = null) {
    const log = await this.backend.session(this.sessionId);
    let entries = await log.read();
    let state = this.fold(entries, delivery);
    if (!knownMessage(state, message)) {
      this.agent.emit("session.refused", { sessionId: this.sessionId, messageId: message.messageId, reason: "unknown message" });
      return undefined;
    }
    await this.backend.refreshDeadline?.();
    // When this delivery's function stops, if it does.
    const deadline = this.backend.deadline() ?? (this.backend.maxDurationMs === null ? null : Date.now() + this.backend.maxDurationMs);
    // A session runs only on the agent it belongs to, the one its first
    // stored input names. A message that reached another agent, as one sent
    // to another agent's session does, goes on to it.
    const owner = state.agent ?? agentOf(message);
    if (owner !== this.agent.name) {
      await this.backend.queue.send(queuedMessage({ ...message, agent: owner }, this.backend.store), {
        idempotencyKey: `${message.sessionId}:${message.type}:${message.messageId}:to:${owner}`,
      });
      this.agent.emit("session.forwarded", { sessionId: this.sessionId, agent: owner });
      return undefined;
    }
    for (let claims = 0; claims < 8; claims += 1) {
      // A session with no open turn starts its next prompt at once: the
      // first model request goes out while the lease is written, and
      // nothing else is written until it lands.
      const early = this.running || state.lease ? null : earlyStart(entries, state, message, (items) => this.fold(items, delivery));
      let outcome;
      if (early) {
        outcome = await this.claim(log, state, deadline, early, delivery);
      } else {
        if (this.running) return { timeoutSeconds: runningBackstopSeconds };
        if (!state.hasWork) {
          if (message.type === "resume") await this.answerIdle(log, message);
          return undefined;
        }
        if (state.lease) {
          // The live holder takes this input from the log; come back as a
          // backstop once its lease would have run out.
          const left = state.lease.expiresAt ? Math.ceil((state.lease.expiresAt - Date.now()) / 1000) + 1 : 5;
          return { timeoutSeconds: Math.max(1, Math.min(maxBackstopSeconds, left)) };
        }
        outcome = await this.claim(log, state, deadline, null, delivery);
      }
      if (outcome === "yielded") return { timeoutSeconds: 0 };
      // A write that failed for any other reason: the same message runs the
      // session again shortly. A lease held to the deadline, which a release
      // that failed may leave standing, is let go only by a later delivery of
      // this message, and a queue may send `{ timeoutSeconds }` on as a new
      // one, so the queue is asked for this one again.
      if (outcome === "failed") return queueHeld(this.backend, deadline) ? { redeliver: true } : { timeoutSeconds: 1 };
      if (outcome === "fenced") {
        // Another worker took the session over; this one stops.
        this.agent.emit("session.fenced", { sessionId: this.sessionId, epoch: state.lastEpoch + 1 });
        return undefined;
      }
      // The turns ran, or another worker's write came before this claim:
      // read the log again.
      entries = await log.read();
      state = this.fold(entries, delivery);
    }
    return { timeoutSeconds: 1 };
  }

  // Claims the session where `state` read it, with a lease that continues
  // the chain there, and runs it. With `early`, what `earlyStart` returned,
  // the message's input is written with the lease and the next turn starts
  // before either lands. The lease names `delivery`, so a later delivery of
  // the same message can tell it lost its holder. Returns what run()
  // returns, or "refused" when another worker's write came before the claim.
  async claim(log, state, deadline, early, delivery = null) {
    // Claimed before the first await, so a delivery that arrives meanwhile
    // sees the session running here.
    this.running = true;
    this.holder = newId("wkr");
    const lease = {
      k: "lease",
      a: state.head,
      holder: this.holder,
      epoch: state.lastEpoch + 1,
      expiresAt: leaseEnd(this.backend, deadline),
      ...this.backend.holderInfo(),
      ...(delivery ? { delivery } : {}),
    };
    this.backend.holding(this.holder, true);
    try {
      // Both writes go out at once and neither waits for the other; the
      // claim settles once both have, with the lease's cursor if it landed
      // and the first failure.
      const writes = [log.append(lease), ...(early?.writes ?? []).map((entry) => log.append(entry))];
      const claimed = Promise.allSettled(writes).then(async ([leased, ...rest]) => {
        const head = leased.status === "fulfilled" ? leased.value : null;
        const error = leased.status === "rejected" ? leased.reason : rest.find((item) => item.status === "rejected")?.reason ?? null;
        if (error || !early) return { head, error };
        // A lease the World took without reporting a competing one is
        // checked against the log, as run() checks one taken first. One that
        // fails is refused like a fenced write rather than stopped: this
        // worker has run nothing, and its input may land after the other
        // worker's last read, so the delivery reads the log again.
        try {
          const now = this.fold(await log.read());
          return { head, error: now.lastLease?.holder === this.holder ? null : new FencedError(`another worker continued session ${this.sessionId}`) };
        } catch (readError) {
          return { head, error: readError };
        }
      });
      let outcome;
      try {
        outcome = await this.run(log, claimed, lease, deadline, early?.state ?? null);
      } catch (error) {
        if ((await claimed).error === null) throw error;
      }
      const settled = await claimed;
      if (settled.error === null) return outcome;
      // A claim that failed counts for nothing, whatever its turn did: it
      // wrote nothing and showed nothing. A fenced one leaves the delivery
      // to read the log and try again; after any other failure the same
      // message runs the session again shortly, once a lease that landed is
      // let go.
      if (isFenced(settled.error)) return "refused";
      this.agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(settled.error) });
      if (settled.head !== null) await log.append({ k: "release", a: settled.head, holder: this.holder }).catch(() => {});
      return "failed";
    } finally {
      this.backend.holding(this.holder, false);
      this.running = false;
    }
  }

  // A resume with nothing to continue still answers its viewer.
  async answerIdle(log, message) {
    const ui = uiWriter(log, (error) => this.agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }));
    ui.push({ type: "idle", requestId: message.messageId });
    await ui.settle();
  }

  // Runs turns under the lease `claimed` settles with, `{ head, error }`,
  // until the log holds no work, the time runs out, or another worker takes
  // over. With `early`, the state the session was read in, the first turn
  // starts before the claim lands: every write waits for it, and once it
  // failed nothing more is written and the turn stops. The caller answers
  // for a claim that failed.
  async run(raw, claimed, lease, deadline, early) {
    const agent = this.agent;
    let head = null;
    let failed = null;
    let claimFailed = false;
    let released = false;
    // Whether the claim landed.
    const ready = claimed.then((claim) => {
      head = claim.head;
      if (claim.error === null) return true;
      failed = claim.error;
      claimFailed = true;
      return false;
    });
    const log = gatedLog(raw, ready, () => failed);
    let chain = ready;
    // The turns a record this worker stored started, and the open turn's
    // cut-offs as this worker's own records leave them.
    const started = new Set();
    let cut = early?.cut ?? noCutoffs;
    // Every chained entry, the harness's records included, continues the
    // newest one this worker wrote.
    const chained = (entry) => {
      if (entry.k === "record") cut = afterRecord(cut, entry.marks);
      const appended = chain.then(async () => {
        if (failed) throw failed;
        try {
          head = await log.append({ ...entry, a: head });
          for (const mark of entry.marks ?? []) if (typeof mark.start === "string") started.add(mark.start);
          return head;
        } catch (error) {
          failed = error;
          throw error;
        }
      });
      chain = appended.catch(() => {});
      return appended;
    };
    // A release after the deadline cut off a turn's step names that turn.
    const release = async (cutoff = null) => {
      await chain;
      if (failed || released) return;
      released = true;
      await chained({ k: "release", holder: this.holder, ...(cutoff ? { cutoff } : {}) }).catch(() => {});
    };
    // Why the chain broke: another worker's write fenced this one out, or a
    // write failed for another reason, which the same message retries.
    const broken = () => {
      if (isFenced(failed)) return "fenced";
      if (!claimFailed) agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(failed) });
      return "failed";
    };
    let state = early;
    if (!state) {
      if (!(await ready)) return broken();
      state = this.fold(await log.read());
      if (state.lastLease?.holder !== this.holder) return "fenced";
      cut = state.cut;
    }
    const ui = uiWriter(log, (error) => agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }), lease.epoch);
    // When the lease runs out, as this worker last renewed it.
    let leaseExpiresAt = lease.expiresAt;
    // An image read that threw while the engine opened.
    let imageReadFailed = null;
    const store = {
      load: async () => ({
        ...(state.checkpoint?.data ? { checkpoint: { through: state.checkpoint.through ?? "0", data: fromBase64(state.checkpoint.data) } } : {}),
        journal: state.records.map((record) => ({ cursor: record.cursor, data: fromBase64(record.data) })),
        // Until the claim lands, the chain where the worker read it.
        head: head ?? state.head,
      }),
      append: ({ idempotencyKey, data, marks }) => chained({ k: "record", key: idempotencyKey, data: toBase64(data), marks }).then((cursor) => ({ cursor })),
      // The engine stores each prompt image before it sends it; a prompt
      // from the log names images already here.
      [persistenceImages]: {
        put: (name, bytes) => log.images.put(name, bytes),
        get: async (name) => {
          try {
            return await log.images.get(name);
          } catch (error) {
            // The store failed to answer, which says nothing of the image.
            imageReadFailed = error;
            throw error;
          }
        },
      },
      saveCheckpoint: async ({ through, data }) => {
        // What a fold that starts at this checkpoint would otherwise miss:
        // inputs before it that no turn took or that the open turn holds
        // unplaced, the ids it ran, the turn a yield left open, and the lease.
        const now = this.fold(await log.read());
        // In log order, so a fold from here orders turns as one from the start.
        const kept = [...now.unconsumed, ...now.held].filter((input) => input.cursor <= Number(through)).sort((a, b) => a.cursor - b.cursor);
        await log.append({
          k: "checkpoint",
          through,
          data: toBase64(data),
          pending: kept,
          ...(now.heldIds.length > 0 ? { held: now.heldIds } : {}),
          recent: now.recent,
          recentSteers: now.recentSteers,
          lastTurnId: now.lastTurnId,
          ...(now.agent === null ? {} : { agent: now.agent }),
          ...(now.openTurn ? { openTurn: now.openTurn, yielded: now.yielded } : {}),
          lease: { holder: this.holder, epoch: lease.epoch, expiresAt: leaseExpiresAt, pid: lease.pid, host: lease.host, ...(lease.delivery ? { delivery: lease.delivery } : {}) },
        });
      },
    };
    // The turn running now, which a deadline or a lost lease cancels.
    let turnNow = null;
    let renew = null;
    if (!heldToDeadline(this.backend, deadline)) {
      // A lease nothing else shows alive is renewed while its worker runs,
      // and never after its release, which would take the session back. A
      // renewal fenced out by another worker's write stops the turn at once,
      // as a claim that failed does.
      renew = setInterval(() => {
        if (released || failed || this.stopping) return;
        leaseExpiresAt = leaseEnd(this.backend, deadline);
        void chained({ k: "lease", holder: this.holder, epoch: lease.epoch, expiresAt: leaseExpiresAt, ...this.backend.holderInfo(), ...(lease.delivery ? { delivery: lease.delivery } : {}) })
          .catch((error) => { if (isFenced(error)) turnNow?.cancel({ reason: "handoff" }); });
      }, Math.max(1, Math.floor(this.backend.leaseMs / 3)));
    }
    // Shortly before the deadline the worker hands the open turn back to the
    // log, cutting off whatever call is still running, and the same message
    // continues the turn in a new delivery. Half the reserve, at most
    // hardStopMs; a reserve of zero never stops a step.
    const stopMargin = deadline === null ? 0 : Math.min(hardStopMs, Math.floor(this.backend.reserveMs / 2));
    this.stopping = false;
    this.stopNow = () => {
      if (this.stopping) return;
      this.stopping = true;
      // Which cut-off in a row of the same step this is.
      agent.emit("session.deadline", { sessionId: this.sessionId, epoch: lease.epoch, cutoffs: afterCutoff(cut).cutoffs });
      turnNow?.cancel({ reason: "handoff" });
    };
    // A turn that started under a claim that then failed stops at once and
    // stores nothing.
    void ready.then((landed) => { if (!landed) turnNow?.cancel({ reason: "handoff" }); });
    const hardStop = stopMargin > 0 && deadline - stopMargin > Date.now()
      ? setTimeout(this.stopNow, deadline - stopMargin - Date.now())
      : null;
    let harness = null;
    let harnessRun = runOf(null);
    this.settled = () => (harness ? harness.settled() : Promise.resolve());
    // A harness that throws instead of returning a turn cannot run one; the
    // same message runs the session again with a new harness.
    const unusable = (error) => {
      agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(error) });
      return "failed";
    };
    try {
      if (state.halted) {
        // Even cancelling the open turn stopped its engine, so the session
        // can run no more turns. The turn and every prompt waiting end with
        // an error, without starting an engine.
        const id = state.openTurn.id;
        if (!state.failed.has(id)) {
          const error = { name: "Error", message: "the engine stopped each time it continued this turn, even to cancel it" };
          await log.append({ k: "failed", messageId: id, error });
          ui.push({ type: "turn_end", messageId: id, stopReason: "error", usage: {}, error });
        }
        for (const waiting of state.pending) {
          await log.append({ k: "ended", messageId: waiting.messageId });
          ui.push({ type: "turn_end", messageId: waiting.messageId, stopReason: "error", usage: {}, error: { name: "Error", message: "the session's open turn cannot continue" } });
        }
        await ui.settle();
        return "done";
      }
      try {
        // What the turn it runs first runs with: the open turn's context and
        // settings, or the next prompt's.
        harnessRun = runOf(state.openTurn ?? state.pending[0]);
        harness = await agent.openHarness(this.sessionId, store, harnessRun, ready);
      } catch (error) {
        // The image store failed to answer while the engine read the
        // session's images: as when the log can't be read, the delivery
        // fails and its message runs again; nothing failed the turn.
        if (imageReadFailed) throw imageReadFailed;
        // A harness that cannot start fails the turn waiting on it, once:
        // the open turn, or after it failed, the next prompt.
        const waiting = state.openTurn && !state.openFailed ? state.openTurn.id : state.pending[0]?.messageId;
        if (waiting) {
          const summary = errorSummary(error);
          await log.append({ k: "failed", messageId: waiting, error: summary });
          ui.push({ type: "turn_end", messageId: waiting, stopReason: "error", usage: {}, error: summary });
        }
        agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(error) });
        return "done";
      }
      const yieldAt = deadline === null ? undefined : Math.max(1, deadline - this.backend.reserveMs);
      for (;;) {
        if (failed) return broken();
        if (this.stopping) {
          await harness.close();
          harness = null;
          await release();
          // A worker replaced without knowing it learns so at the release.
          return failed ? broken() : "yielded";
        }
        const open = harness.openTurn;
        let turn = null;
        let messageId = null;
        let fresh = false;
        let spent = false;
        if (open?.id) {
          // A call left running reruns only when running it twice is safe.
          // Any other call is never run again: the model is told it may have
          // partly run, and the turn goes on.
          messageId = open.id;
          ui.push({ type: "turn_resume", messageId, sessionId: this.sessionId });
          // It lands before the turn goes on, so any line the replaced
          // worker writes after it ranks below it and stays hidden.
          await ui.settle();
          // A step the deadline cut off maxCutoffs times in a row would be
          // cut off forever. A cut-off call is not run again, so the model
          // hears it may have partly run; a model request ends the turn,
          // cancelled, as a turn whose engine keeps stopping does.
          spent = state.openTurn?.id === messageId && state.cutoffs >= maxCutoffs;
          try {
            turn = harness.resume({ yieldAt, ...(spent ? { rerun: false } : {}) });
          } catch (error) {
            await log.append({ k: "stopped", messageId });
            return unusable(error);
          }
        }
        if (!turn) {
          const next = state.pending[0];
          if (!next) break;
          messageId = next.messageId;
          if ((state.stops.get(messageId) ?? 0) >= maxHarnessStops) {
            // An engine that stops each time it starts this turn would hold
            // the session forever; the turn ends with an error instead.
            await log.append({ k: "ended", messageId });
            ui.push({ type: "turn_end", messageId, stopReason: "error", usage: {}, error: { name: "Error", message: `the engine stopped each of the ${maxHarnessStops} times it started this turn` } });
            await ui.settle();
            state = this.fold(await log.read());
            continue;
          }
          if (next.cancelled) {
            // Its own cancel came before it started, so it never runs.
            await log.append({ k: "ended", messageId });
            ui.push({ type: "turn_end", messageId, stopReason: "cancelled", usage: {} });
            await ui.settle();
            state = this.fold(await log.read());
            continue;
          }
          // Each prompt runs with the context its caller gave and its session
          // object's settings.
          const wanted = runOf(next);
          if (JSON.stringify(wanted) !== JSON.stringify(harnessRun)) {
            await harness.close();
            harness = null;
            harness = await agent.openHarness(this.sessionId, store, wanted, ready);
            harnessRun = wanted;
          }
          // A prompt names the images it stored; the engine gets their bytes.
          const withImages = await resolvePromptImages(log.images, next.input);
          if (withImages.missing) {
            // A history without the image is not the one its caller sent.
            await log.append({ k: "ended", messageId });
            const message = withImages.corrupt
              ? `the session's image store holds other bytes under image ${withImages.missing}`
              : `the session's image store does not hold image ${withImages.missing}`;
            ui.push({ type: "turn_end", messageId, stopReason: "error", usage: {}, error: { name: "Error", message } });
            await ui.settle();
            state = this.fold(await log.read());
            continue;
          }
          try {
            turn = harness.prompt(withImages.input ?? "", { turnId: messageId, yieldAt });
          } catch (error) {
            await log.append({ k: "stopped", messageId });
            return unusable(error);
          }
          ui.push({ type: "turn_start", messageId, sessionId: this.sessionId, ...(typeof next.input === "string" ? { input: next.input } : {}) });
          fresh = true;
        }
        turnNow = turn;
        if (this.stopping || claimFailed) turn.cancel({ reason: "handoff" });
        else if (spent && !(open.calls?.length > 0)) turn.cancel();
        // A new turn takes the steers sent while it waited to start.
        const joining = fresh ? { ...state, steers: state.pending[0]?.joiners ?? [], endOpen: state.pending[0]?.ends === true } : state;
        const outcome = await this.drive(log, harness, turn, messageId, joining, ui);
        turnNow = null;
        if (outcome === "fenced") return "fenced";
        if (outcome === "yielded") {
          // Commit, checkpoint, release: the next delivery loads the
          // checkpoint and the few records after it. A turn handed back at
          // the deadline stored nothing more, so it has none to save.
          await harness.saveCheckpoint();
          await harness.close();
          harness = null;
          await release(this.stopping ? messageId : null);
          return failed ? broken() : "yielded";
        }
        if (outcome.stopped) {
          // Closing the engine waits for the records it still had in flight,
          // so the log shows how far the turn got.
          await harness.close().catch(() => {});
          harness = null;
          await chain;
          if (failed) return broken();
          state = this.fold(await log.read());
          if (state.openTurn?.id !== messageId && state.consumed.has(messageId)) {
            // Its end landed before its engine stopped, so it ended, though
            // how is unknown.
            ui.push({ type: "turn_end", messageId, stopReason: "unknown", usage: {} });
            await ui.settle();
          } else {
            await log.append({ k: "stopped", messageId });
          }
          return unusable(outcome.stopped);
        }
        const { result } = outcome;
        if (fresh && !failed && !started.has(messageId)) {
          // A turn that ended before writing a record, such as a prompt the
          // harness refused or one a cancel stopped first, is done too. The
          // log says so before its viewers hear it ended, so a retry that
          // reads the log finds it ended.
          state = this.fold(await log.read());
          if (!state.consumed.has(messageId)) await log.append({ k: "ended", messageId });
        }
        // The turn's records have landed, so its viewers hear it ended now;
        // the log is read after, for what comes next.
        ui.push({ type: "turn_end", messageId, stopReason: result.stopReason, usage: result.usage ?? {}, ...(result.error ? { error: result.error } : {}) });
        await ui.settle();
        state = this.fold(await log.read());
        if (!fresh && !failed && harness.openTurn?.id === messageId) {
          // A harness that leaves a turn open after it ended would run it
          // again forever; the worker stops instead.
          agent.emit("session.error", { sessionId: this.sessionId, error: { name: "Error", message: `turn ${messageId} ended but stayed open` } });
          break;
        }
        if (state.lastLease?.holder !== this.holder && !failed) return "fenced";
      }
      if (failed) {
        await harness.close();
        harness = null;
        return broken();
      }
      // The last turn's records and end have landed, so the worker lets go
      // before its engine shuts down: a prompt that lands meanwhile starts at
      // once, here or in another process, instead of waiting for the
      // shutdown. The engine stores nothing more; the agent waits for it on
      // close.
      await release();
      agent.track(harness.close().catch(() => {}));
      harness = null;
      return failed ? broken() : "done";
    } finally {
      if (hardStop) clearTimeout(hardStop);
      this.stopNow = null;
      this.settled = null;
      if (renew) clearInterval(renew);
      if (harness) await harness.close().catch(() => {});
      await ui.settle().catch(() => {});
      // A worker that stops on an error still lets the next one in. One
      // whose write failed before its release releases outside its broken
      // chain, so the retry need not wait out the lease; a fenced one holds
      // nothing to release.
      if (!failed && !released) await release().catch(() => {});
      else if (failed && !isFenced(failed) && !released) {
        released = true;
        await log.append({ k: "release", a: head, holder: this.holder }).catch(() => {});
      }
    }
  }

  // Streams one turn to the session's viewers and applies the steers and
  // cancels the log receives while it runs. Returns "fenced", "yielded",
  // `{ stopped }` when its harness stopped under it, or `{ result }` for a
  // turn that ended, whose end the caller writes.
  async drive(log, harness, turn, messageId, state, ui) {
    // The inputs `state` was folded from are placed already: the fold gave
    // each a turn, joined it to one, or spent it. The poll applies only the
    // inputs stored after them. After an early start, that includes this
    // message's own input, landing past `since`.
    const applied = new Set(state.inputKeys);
    let since = String(state.maxCursor);
    let polling = false;
    let again = false;
    let stopped = false;
    // A text steer joins the turn. Any other ends it at its next safe point
    // and, never taken, runs as the next turn, as the fx CLI hands off; the
    // steers after that one join its turn.
    let ending = false;
    const endTurn = () => {
      if (ending) return;
      ending = true;
      void Promise.resolve().then(() => turn.endForSteer?.()).catch(() => {});
    };
    const steerTurn = (steer) => {
      // One id names one input, so a steer with this turn's id is its own
      // opener or one that reused the id, which the log never runs.
      if (steer.messageId === messageId) return;
      if (!joinable(steer.input)) endTurn();
      else if (!ending) void turn.steer(steer.input, steer.messageId).catch(() => {});
    };
    const apply = async () => {
      if (stopped) return;
      if (polling) { again = true; return; }
      polling = true;
      try {
        do {
          again = false;
          const entries = await log.readSince(since);
          for (const { cursor, entry } of entries) {
            if (Number(cursor) > Number(since)) since = cursor;
            if (entry?.k !== "input" || applied.has(entry.key)) continue;
            applied.add(entry.key);
            if (entry.type === "steer") steerTurn(entry);
            else if (entry.type === "cancel" && (entry.target === undefined || entry.target === messageId)) turn.cancel();
          }
        } while (again && !stopped);
      } catch {} finally {
        polling = false;
      }
    };
    for (const steer of state.steers) {
      applied.add(steer.key);
      steerTurn(steer);
    }
    if (state.endOpen) endTurn();
    // An open turn whose engine kept stopping is cancelled the way a user
    // would, so the prompts behind it can run.
    if (state.cancelOpen || (state.stuck && state.openTurn?.id === messageId)) turn.cancel();
    const unwatch = log.watch?.(() => { void apply(); });
    const timer = this.backend.pollMs ? setInterval(() => { void apply(); }, this.backend.pollMs) : null;
    void apply();
    let result;
    try {
      for await (const event of turn) ui.push({ ...event, messageId });
      result = await turn.result;
    } catch (error) {
      if (isFenced(error)) return "fenced";
      // The harness stopped under the turn; the next delivery continues it
      // with a new one.
      if (error?.code === "FX_HARNESS_STOPPED") return { stopped: error };
      result = { stopReason: "error", error: errorSummary(error) };
    } finally {
      stopped = true;
      unwatch?.();
      if (timer) clearInterval(timer);
    }
    // Viewers hear a turn ended only once the log says so too, so a retry
    // that reads the log finds it ended.
    try {
      await harness.settled();
    } catch (error) {
      if (isFenced(error)) return "fenced";
      throw error;
    }
    // A turn handed back at the deadline continues in the next delivery,
    // like one that yielded.
    if (result.stopReason === "yielded" || (this.stopping && result.stopReason === "cancelled")) {
      ui.push({ type: "turn_yield", messageId });
      await ui.settle();
      return "yielded";
    }
    return { result };
  }
}

// ---------------------------------------------------------------------------
// The public API.

const internalEvent = new Set(["turn_start", "turn_resume", "turn_yield", "turn_end", "idle"]);

// Which UI lines a reader shows: each line no earlier line outranks. A
// replaced worker's lines carry its older lease epoch, so once its successor
// has written, they stay hidden. The same stored stream always shows the
// same lines, from any server and after any refresh.
function uiRanker(high = 0) {
  return (event) => {
    if (!Number.isSafeInteger(event?.epoch)) return true;
    if (event.epoch < high) return false;
    high = event.epoch;
    return true;
  };
}

// The ranker as it stands after the first `count` lines of the stream.
async function uiRankerAt(log, count) {
  const shows = uiRanker();
  if (count === 0) return shows;
  const reader = log.ui.read(0).getReader();
  let buffered = "";
  let seen = 0;
  try {
    while (seen < count) {
      const { value, done } = await reader.read();
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0 && seen < count; index = buffered.indexOf("\n")) {
        const line = buffered.slice(0, index);
        buffered = buffered.slice(index + 1);
        seen += 1;
        try { shows(JSON.parse(line)); } catch {}
      }
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
  return shows;
}

// What a retried `messageId` finds in its session: its turn still waiting or
// running (`follow`), no trace of it (`fresh`), a turn it already ran,
// settled from that turn's end on the stream before `from` or from the
// log's record of its failure, or `unsure` when the log says it ran but
// neither shows how. Once this call has `sent` the message, a recorded
// failure may be this send's own run, so it is not called a repeat.
async function retryOutcome(log, state, messageId, from, { sent }) {
  const waiting = state.inputKeys.has(`prompt:${messageId}`) && !state.consumed.has(messageId);
  if ((state.openTurn?.id === messageId && !state.failed.has(messageId)) || waiting) return { follow: true };
  if (!state.consumed.has(messageId)) return { fresh: true };
  const ended = await turnEndIn(log, messageId, from);
  if (ended) return { settled: { ...ended, repeated: true } };
  const error = state.failed.get(messageId);
  if (error) return { settled: { messageId, stopReason: "error", error, ...(sent ? {} : { repeated: true }) } };
  return { unsure: true };
}

// The end a turn's worker wrote, among the first `count` lines of the
// stream, as a reader shows them; null when none did.
async function turnEndIn(log, messageId, count) {
  if (count === 0) return null;
  const shows = uiRanker();
  const reader = log.ui.read(0).getReader();
  let buffered = "";
  let seen = 0;
  let found = null;
  try {
    while (seen < count) {
      const { value, done } = await reader.read();
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0 && seen < count; index = buffered.indexOf("\n")) {
        const line = buffered.slice(0, index);
        buffered = buffered.slice(index + 1);
        seen += 1;
        let event;
        try { event = JSON.parse(line); } catch { continue; }
        if (shows(event) && event.type === "turn_end" && event.messageId === messageId) found = event;
      }
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
  if (!found) return null;
  const { type: _type, ...rest } = found;
  return rest;
}

// How long a retried turn waits for an end the log already holds.
const retryEndWaitMs = 30_000;

// One turn as its viewer sees it: the session stream from `from` on, its
// events only, until its end. `start` queues the turn at once and returns
// the stream; a resume learns its turn from the first one the stream shows.
// The stream is read only once something reads the view, its events,
// `readable` or `result`, so a prompt nobody follows holds no read open.
function turnView({ messageId, resumeRequest = null, start }) {
  // A retried turn reports the outcome of the turn its id already ran.
  let repeated = false;
  const events = [];
  const waiters = [];
  let done = false;
  let failure = null;
  let id = resumeRequest ? null : messageId;
  let settle;
  const result = new Promise((resolve, reject) => { settle = { resolve, reject }; });
  void result.catch(() => {});
  const wake = () => { for (const waiter of waiters.splice(0)) waiter(); };
  const finish = (value, error) => {
    if (done) return;
    done = true;
    if (error) {
      failure = error;
      settle.reject(error);
    } else settle.resolve(repeated ? { ...value, repeated: true } : value);
    wake();
  };
  const started = start();
  void started.catch(() => {});
  let following = false;
  const follow = () => {
    if (following) return;
    following = true;
    void read();
  };
  const read = async () => {
    try {
      const { log, from, settled, attaching, endWithinMs, unsure } = await started;
      // A turn whose end this view finds after its own start may be the
      // message's first run, so only an end found before it is a repeat.
      repeated = settled?.repeated === true || (endWithinMs !== undefined && !unsure);
      if (settled) {
        // A turn that already ended still tells a viewer how, so a route
        // returning `readable` sends its outcome.
        const { messageId: _id, ...rest } = settled;
        events.push({ type: "turn_end", messageId, ...rest });
        return finish(settled);
      }
      // A view of a turn already running ranks from what came before it;
      // a new turn's takeovers all come after its own start.
      const shows = attaching ? await uiRankerAt(log, from) : uiRanker();
      const reader = log.ui.read(from).getReader();
      // A turn whose end the log holds but no line shows yet: a worker that
      // stopped between the two never writes it, so the outcome is unknown.
      let gaveUp = null;
      if (endWithinMs !== undefined) {
        gaveUp = setTimeout(() => {
          void reader.cancel().catch(() => {});
          finish({ messageId, stopReason: "unknown", usage: {} });
        }, endWithinMs);
      }
      let buffered = "";
      let cursor = from;
      for (;;) {
        const { value, done: ended } = await reader.read();
        if (ended) break;
        buffered += decoder.decode(value, { stream: true });
        for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
          const line = buffered.slice(0, index);
          buffered = buffered.slice(index + 1);
          cursor += 1;
          let event;
          try { event = JSON.parse(line); } catch { continue; }
          if (!shows(event)) continue;
          if (id === null) {
            if (event.type === "idle" && event.requestId === resumeRequest) {
              void reader.cancel().catch(() => {});
              return finish({ stopReason: "idle", usage: {} });
            }
            if (event.type !== "turn_resume" && event.type !== "turn_start") continue;
            id = event.messageId;
          }
          if (event.messageId !== id) continue;
          events.push({ ...event, cursor });
          wake();
          if (event.type === "turn_end") {
            if (gaveUp) clearTimeout(gaveUp);
            void reader.cancel().catch(() => {});
            const { type: _type, messageId: _id, ...rest } = event;
            return finish({ messageId: id, ...rest });
          }
        }
      }
      if (gaveUp) clearTimeout(gaveUp);
      finish(null, new Error("the session stream ended before the turn did"));
    } catch (error) {
      finish(null, error);
    }
  };
  async function* iterate(raw) {
    for (let index = 0; ; index += 1) {
      while (index >= events.length) {
        if (done) {
          if (failure) throw failure;
          return;
        }
        await new Promise((resolve) => waiters.push(resolve));
      }
      const event = events[index];
      if (raw) yield event;
      else if (!internalEvent.has(event.type)) {
        const { messageId: _id, cursor: _cursor, ...rest } = event;
        yield rest;
      }
    }
  }
  return {
    get messageId() { return id; },
    get result() {
      follow();
      return result;
    },
    // Dropping a turn cancels nothing; `session.cancel()` does.
    [Symbol.asyncIterator]() {
      follow();
      return iterate(false);
    },
    // Each line is one event with the cursor `stream()` resumes after it.
    get readable() {
      follow();
      const iterator = iterate(true);
      return new ReadableStream({
        async pull(controller) {
          try {
            const { value, done: ended } = await iterator.next();
            if (ended) controller.close();
            else controller.enqueue(encoder.encode(`${JSON.stringify(value)}\n`));
          } catch (error) {
            controller.error(error);
          }
        },
        cancel() { void iterator.return?.(); },
      });
    },
  };
}

/**
 * Builds a durable agent over a harness: the agent loop that runs a turn.
 * The core owns the session's log, its lease, the queue, deadlines and the
 * UI stream; the harness owns turns and what its records mean.
 *
 * `harness(options)` receives the caller's options without `durability` and
 * returns:
 *
 * - `open({ sessionId, store, context, settings, durability, ready })`: the
 *   harness session for one worker, for turns with that `context` and those
 *   `settings`. `store` is where it keeps the session: `load()` resolves
 *   `{ checkpoint?, journal, head }`, `append({ idempotencyKey, data, marks })`
 *   stores one opaque record durably and resolves `{ cursor }`, and
 *   `saveCheckpoint({ through, data })` stores what the records through
 *   `through` add up to. Each record's `marks` tell the core where turns
 *   start (`{ start: turnId }`), yield (`{ yield: true }`) and end
 *   (`{ end: true }`), which inputs a turn took (`{ accepted: id }`), when
 *   its model request first carries one (`{ placed: id }`), and which it
 *   ended without placing (`{ withdrawn: id }`), which wait for a turn again.
 *   A write another worker's write fenced out rejects with a `FX_FENCED`
 *   code. `ready`, when given, resolves true once the worker's claim on the
 *   session lands and false when it failed: the core may start a turn
 *   before then, and the harness runs no tool until it resolves true. The
 *   core holds the store's writes and the turn's UI lines meanwhile.
 * - `seed` (optional): the bytes of a checkpoint a new session starts from.
 * - `settings(sessionOptions)` (optional): what an `agent.session()` call
 *   sets over the agent's options for the turns it starts, as JSON the core
 *   stores with each prompt and passes to `open()`, or undefined for none.
 *   It throws a TypeError for options it refuses.
 * - `checkPrompt(input)` (optional): throws a TypeError or RangeError for
 *   a prompt input the harness would refuse. A session's `prompt()` calls it
 *   before it stores anything, so a prompt it refuses is never stored.
 *
 * A harness session has `prompt(input, { turnId, yieldAt })` and
 * `resume({ yieldAt, rerun })`, each returning a turn, where `rerun: false`
 * runs no call left running again; `openTurn`, the turn its records left
 * open as `{ id, calls? }`, with the calls it left running, or null;
 * `settled()`, which resolves once
 * every record it started is stored; `saveCheckpoint()`;
 * `exportCheckpoint()`, the conversation as bytes; and `close()`. A turn is
 * an async iterable of the events its viewers see, with `result` resolving
 * `{ stopReason, usage? }`, `steer(text, id)`, and `cancel(options)`, where
 * `{ reason: "handoff" }` stops it at once and stores nothing more, so the
 * next worker continues it. A turn may have `endForSteer()`, which ends it
 * at its next safe point, at once while its model streams a reply, for a
 * steer that cannot join it; without it, such a steer waits for the turn to
 * end. Either way the steer runs as the next turn. A turn stops before a
 * model request once `yieldAt` has passed, with the stop reason `yielded`.
 *
 * An input the harness refuses only once a turn runs it is a turn that ends
 * with an error.
 * `prompt()` and `resume()` throw only when the harness cannot run a turn,
 * and a turn whose harness stopped under it rejects with a
 * `FX_HARNESS_STOPPED` code; either way the same message runs the session
 * again with a new harness. After 3 stops a turn is resumed and cancelled at
 * once, or ends with an error when it never started; when its harness stops
 * twice more, even to cancel it, the session runs no more turns.
 *
 * `defaultDurability()` picks the durability when the caller names none, and
 * `defaultShared` says it hands every such agent the same one, as Node's
 * does, so that agents created without a durability share a store. `name` is
 * the factory's name in errors, and `label` the agent's.
 */
export function createDurableAgentFactory({ harness, defaultDurability, defaultShared = false, name = "createAgent", label = "agent" }) {
  return function createDurableAgent(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError(`${name}() options must be an object`);
    }
    const { durability, name: agentName = defaultAgentName, ...harnessOptions } = options;
    if (durability !== undefined && !isDurability(durability)) {
      throw new TypeError("durability must come from memory(), local(), vercel() or world()");
    }
    if (typeof agentName !== "string" || !agentNameRule.test(agentName)) {
      throw new TypeError(`${name}() name must be 1 to 64 letters, digits, ".", "_" or "-", starting with a letter or digit`);
    }
    const plugged = harness(harnessOptions);
    const seed = plugged.seed === undefined ? undefined : toBase64(plugged.seed);
    const emit = (type, detail = {}) => {
      try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
    };
    const agent = {
      name: agentName,
      emit,
      // Work that outlives the delivery that started it, which close() waits
      // for: an engine that shuts down after its worker let go.
      track(work) {
        active.add(work);
        void work.finally(() => active.delete(work));
      },
      openHarness: (sessionId, store, run, ready) => plugged.open({
        sessionId,
        store,
        context: run?.context ?? null,
        ...(run?.settings == null ? {} : { settings: run.settings }),
        durability: chosenDurability,
        ...(ready ? { ready } : {}),
      }),
    };
    let backendPromise = null;
    let durabilityPromise = null;
    let chosenDurability = null;
    let unlisten = null;
    let closed = false;
    const workers = new Map();
    const active = new Set();
    const backend = () => {
      if (closed) return Promise.reject(new Error(`${label} is closed`));
      backendPromise ??= (async () => {
        const chosen = await durabilityOf();
        // An agent created without a durability learns its store only now.
        if (member.store !== storeOf(chosen)) {
          member.store = storeOf(chosen);
          try {
            claimName(agentName, member);
          } catch (error) {
            leaveGroup(agentsByName, agentName, registered, member);
            throw error;
          }
        }
        chosenDurability = chosen;
        const created = await createBackend(chosen);
        await created.start?.();
        unlisten = created.listen((delivered, meta) => {
          // Only which input a delivery names is read from it: the rest of
          // its body, which a forged delivery would choose, is ignored.
          const message = deliveredMessage(created, delivered);
          if (!message) {
            emit("session.refused", { reason: "malformed message" });
            return undefined;
          }
          return receive(created, message, deliveryOf(meta));
        }, agentName);
        return created;
      })();
      return backendPromise;
    };
    // The durability the agent's sessions live in, chosen once.
    const durabilityOf = () => (durabilityPromise ??= durability ? Promise.resolve(durability) : defaultDurability());
    // In the process's agents from now, so a route that receives a message
    // for this agent finds it before anything uses it. One created without a
    // durability claims the default's store until it knows which that is:
    // the store every such agent shares where the factory hands them all one
    // durability, and a store of its own where each gets its own.
    const unresolved = defaultShared ? defaultDurability : Symbol("default store");
    const member = { open: backend, durability: durabilityOf, definition: definitionOf(harnessOptions), store: durability ? storeOf(durability) : unresolved, defaults: durability ? null : unresolved };
    claimName(agentName, member);
    const registered = joinGroup(agentsByName, agentName, member);
    // One delivery of `message` to the session's worker here: from the
    // queue, with `delivery` naming the queue's message and attempt, or with
    // `inRequest` from the request that took the prompt.
    const receive = (created, message, delivery, { inRequest = false } = {}) => {
      let worker = workers.get(message.sessionId);
      if (!worker) {
        worker = new SessionWorker(agent, created, message.sessionId);
        workers.set(message.sessionId, worker);
      }
      worker.deliveries += 1;
      let work = worker.consume(message, delivery);
      if (inRequest) {
        // No queue delivered this message, so none delivers it again: a turn
        // that must go on later continues in a fresh message. One whose
        // write failed is left to the backstop, which takes its lease over.
        work = work.then(async (result) => {
          if (Number.isFinite(result?.timeoutSeconds)) {
            await created.queue.send(message, {
              idempotencyKey: `${message.sessionId}:${message.type}:${message.messageId}:${newId("again")}`,
              ...(result.timeoutSeconds > 0 ? { delaySeconds: result.timeoutSeconds } : {}),
            });
          }
          return result;
        });
      }
      active.add(work);
      void work.catch((error) => {
        // Its queue delivers the message again; the host hears why.
        emit("session.error", { sessionId: message.sessionId, error: errorSummary(error) });
      }).finally(() => {
        active.delete(work);
        worker.deliveries -= 1;
        // A worker lives while a delivery runs it.
        if (worker.deliveries === 0 && !worker.running && workers.get(message.sessionId) === worker) workers.delete(message.sessionId);
      });
      return work;
    };

    const openSession = (requestedId, sessionOptions = {}) => {
      if (requestedId !== undefined && !validId(requestedId)) throw new TypeError(`session id must be ${idRule}`);
      let context;
      try { context = jsonSnapshot(sessionOptions?.context); } catch { throw new TypeError("session context must be JSON"); }
      const settings = jsonSnapshot(plugged.settings?.(sessionOptions ?? {}));
      // What every input this session object sends carries besides itself.
      const carried = jsonBytes(context) + jsonBytes(settings);
      // Refuses an input too large to store before anything is stored
      // (`tests/tla/sdk/TenantIsolation.tla` StoredWithinLimit).
      const admit = (input) => {
        const bytes = jsonBytes(input) + carried;
        if (bytes > maxInputBytes) throw inputTooLarge(bytes);
      };
      let id = requestedId ?? null;
      let seeded = seed === undefined || requestedId !== undefined;
      const resolved = backend().then((created) => {
        id ??= created.newSessionId();
        if (!created.validSessionId(id)) throw new TypeError(`${created.name} durability cannot hold session id ${JSON.stringify(id)}`);
        return { created, id };
      });
      void resolved.catch(() => {});
      // With `inRequest`, a prompt runs here, in the request that took it,
      // where the durability allows (see `runInRequest`).
      const send = async (message, { inRequest = false } = {}) => {
        const { created, id: sessionId } = await resolved;
        const extra = {
          ...(seeded ? {} : { seed }),
          ...(context === undefined ? {} : { context }),
          ...(settings === undefined ? {} : { settings }),
        };
        const full = { ...message, ...extra, agent: agentName, sessionId };
        // The input and its caller's context reach the log here, on the
        // app's own call, before the caller hears it was accepted. The queue
        // carries only which input to run, so a delivery cannot choose what
        // a turn runs or as whom (`tests/tla/sdk/TenantIsolation.tla`
        // OnlySentRuns), and a queue that ends with the process loses no
        // input.
        const log = await created.session(sessionId);
        await recordMessage(log, foldSessionLog(await log.read()), full);
        const queued = queuedMessage(full, created.store);
        const idempotencyKey = `${sessionId}:${message.type}:${message.messageId}`;
        if (inRequest && created.runInRequest) {
          await created.refreshDeadline?.();
          const deadline = deliveryDeadline(created);
          if (deadline !== null) {
            // This request runs the turn, and the queue keeps the message as
            // a backstop it delivers only after the request's deadline, by
            // when the request has stopped. The lease names the backstop, so
            // if the request died, the backstop takes the session over and
            // continues the turn.
            const delaySeconds = Math.ceil(Math.max(0, deadline - Date.now()) / 1000) + inlineBackstopMarginSeconds;
            const { messageId: backstop } = await created.queue.send(queued, { idempotencyKey, delaySeconds }) ?? {};
            seeded = true;
            const delivery = backstop ? { messageId: backstop, attempt: 0 } : null;
            // receive() reports a failure to the host; the backstop retries it.
            const work = receive(created, queued, delivery, { inRequest: true }).then(() => {}, () => {});
            created.waitUntil?.(work);
            return;
          }
        }
        await created.queue.send(queued, { idempotencyKey });
        seeded = true;
      };
      // Settles once the latest prompt from this session object with images
      // to store is stored or has failed; null while none has. Each later
      // prompt waits for it, so they are stored in the order made.
      let storing = null;
      // `ready`, when given, resolves the input once it can be stored; only a
      // prompt that is stored calls it.
      // `aborted()` says whether the prompt's signal has aborted. One that
      // aborted before the prompt's send began never stores it; `progress.sent`
      // is set as the send begins, after which an abort cancels the prompt.
      const startTurn = (type, messageId, input, retried = false, aborted = () => false, ready = null, progress = null) => {
        let accept;
        const accepted = new Promise((resolve, reject) => { accept = { resolve, reject }; });
        void accepted.catch(() => {});
        const view = turnView({
          messageId,
          resumeRequest: type === "resume" ? messageId : null,
          start: async () => {
            try {
              const read = input === undefined || ready === null || aborted() ? input : await ready();
              const message = { type, messageId, ...(input === undefined ? {} : { input: read }) };
              const queue = () => {
                if (progress) progress.sent = true;
                return send(message, { inRequest: type === "prompt" });
              };
              const { created, id: sessionId } = await resolved;
              const log = await created.session(sessionId);
              let attaching = type === "resume";
              let from = null;
              // The viewer's start is read before the message is queued, so
              // every line this message's own turn writes comes after it, and
              // an end for this id before it can only be from a turn this id
              // already ran.
              if (retried) from = await log.ui.length();
              if (retried && !aborted()) {
                // The log, for that answer, is read alongside the one queue
                // send.
                const [state] = await Promise.all([
                  log.read().then(foldSessionLog),
                  queue().then(() => accept.resolve({ messageId, sessionId })),
                ]);
                // One the log does not know yet is this send's own. When the
                // log says it ran and nothing shows how, either this send's
                // own turn already ended, its end after `from`, or a turn
                // this id ran before never wrote its end.
                const outcome = await retryOutcome(log, state, messageId, from, { sent: true });
                if (outcome.settled) return { settled: outcome.settled };
                if (outcome.unsure) return { log, from, attaching: true, endWithinMs: retryEndWaitMs, unsure: true };
                return { log, from, attaching: outcome.follow === true };
              }
              if (retried) {
                // A turn this id already ran answers from the log, without
                // queueing it again. The viewer's start was read first, so a
                // turn that ends after it has its end in view.
                const outcome = await retryOutcome(log, foldSessionLog(await log.read()), messageId, from, { sent: false });
                if (outcome.follow) attaching = true;
                else if (!outcome.fresh) {
                  accept.resolve({ messageId, sessionId });
                  if (outcome.settled) return { settled: outcome.settled };
                  return { log, from, attaching: true, endWithinMs: retryEndWaitMs };
                }
              }
              // The viewer starts where the stream is now, before the
              // message can produce anything.
              from ??= await log.ui.length();
              if (aborted()) {
                // A prompt whose signal aborted before its send began is never
                // stored; a retry of one the log holds only follows its turn.
                accept.resolve({ messageId, sessionId });
                if (!attaching) return { settled: { messageId, stopReason: "cancelled", usage: {} } };
                return { log, from, attaching };
              }
              await queue();
              accept.resolve({ messageId, sessionId });
              return { log, from, attaching };
            } catch (error) {
              accept.reject(error);
              throw error;
            }
          },
        });
        return Object.assign(view, { accepted });
      };
      const session = {
        get id() { return id; },
        /**
         * Queues `input` as the session's next turn and returns a view of it.
         * With `messageId`, a retried call is the same turn: it continues a
         * turn still running and answers one that ended, without running it
         * again. Each image is stored once in the session's image store and
         * the log names it. A later prompt from this session object waits for
         * an earlier one's images. An input the harness would refuse throws
         * here and is never stored. A prompt whose signal aborts before it is
         * stored is never stored either: it ends cancelled.
         */
        prompt(input, promptOptions = {}) {
          if (closed) throw new Error(`${label} is closed`);
          const messageId = promptOptions.messageId ?? newId("msg");
          if (!validId(messageId)) throw new TypeError(`messageId must be ${idRule}`);
          if (typeof input !== "string" && !Array.isArray(input)) throw new TypeError("prompt input must be a string or an array of content blocks");
          const signal = promptOptions.signal;
          if (signal !== undefined && typeof signal?.addEventListener !== "function") throw new TypeError("prompt signal must be an AbortSignal");
          const aborted = signal?.aborted === true;
          const retried = promptOptions.messageId !== undefined;
          // The input travels through the queue and the log as JSON. Its
          // images go to the session's image store first and the log names
          // them; a prompt aborted before the call stores nothing, so it
          // keeps them as base64.
          const named = !aborted;
          const stored = Array.isArray(input) ? promptInputForLog(input, { named }) : { input, images: false };
          // The copy the log will hold is what is checked: a getter can't
          // show the check one value and the log another.
          admit(stored.input);
          plugged.checkPrompt?.(stored.input);
          const before = storing;
          const ready = before || stored.images ? async () => {
            // The prompt waits for an earlier one and its image writes only
            // until its signal aborts; what it waited for may still land, but
            // the prompt is not stored.
            let release = () => {};
            const abortion = signal === undefined ? null : new Promise((resolve) => {
              signal.addEventListener("abort", resolve, { once: true });
              release = () => signal.removeEventListener("abort", resolve);
            });
            const unlessAborted = (promise) => {
              if (abortion === null) return promise;
              void promise.catch(() => {});
              return Promise.race([promise, abortion]);
            };
            try {
              await unlessAborted(before ?? Promise.resolve());
              if (signal?.aborted) return null;
              let read = stored.input;
              if (stored.images) {
                const { created, id: sessionId } = await resolved;
                const log = await created.session(sessionId);
                // A retry of a prompt the log already holds is answered from
                // the log: its images are named, not written again.
                const known = retried && knownMessage(foldSessionLog(await log.read()), { type: "prompt", messageId });
                if (signal?.aborted) return null;
                read = await unlessAborted(storePromptImages(known ? null : log.images, read));
                if (signal?.aborted) return null;
              }
              // An agent closed meanwhile stores nothing more.
              if (closed) throw new Error(`${label} is closed`);
              return read;
            } finally {
              release();
            }
          } : null;
          const progress = { sent: false };
          const turn = startTurn("prompt", messageId, stored.input, retried, () => signal?.aborted === true, ready, progress);
          if (stored.images && !aborted) {
            // A later prompt waits for this one and every one before it: one
            // withdrawn while it waited settles before them.
            const settled = Promise.all([before, turn.accepted.then(() => {}, () => {})]).then(() => {});
            storing = settled;
            void settled.then(() => { if (storing === settled) storing = null; });
          }
          if (signal !== undefined && !signal.aborted) {
            // The prompt's own cancel: it stops this turn whether it runs or
            // still waits, and never a later one. A prompt whose send had not
            // begun is never stored, so it needs none.
            const stop = () => {
              if (progress.sent) void send({ type: "cancel", messageId: newId("cnl"), target: messageId }).catch(() => {});
            };
            signal.addEventListener("abort", stop, { once: true });
            void turn.result.finally(() => signal.removeEventListener("abort", stop)).catch(() => {});
          }
          return turn;
        },
        /** Continues the turn a stopped worker left open, if any. */
        resume() {
          if (closed) throw new Error(`${label} is closed`);
          return startTurn("resume", newId("res"));
        },
        /**
         * The session's events after `cursor`, as NDJSON, from any server.
         * A cursor is one a line carried, and a line shows only when no line
         * before it outranks it, so the epoch of the line a cursor names is
         * the rank every line after it is held to: the read starts there, not
         * at the stream's start, and lines rank the same however a reader
         * reconnects. After a line with no epoch it reads from the start.
         */
        stream(cursor = 0) {
          if (!Number.isSafeInteger(cursor) || cursor < 0) throw new TypeError("stream cursor must be a non-negative integer");
          let reader = null;
          let buffered = "";
          let next = 0;
          let shows = uiRanker();
          // Opens the read: at the cursor's own line, which sets the rank,
          // or from the start when it carries none.
          const open = async (ui) => {
            if (cursor === 0) return ui.read(0).getReader();
            const at = ui.read(cursor - 1).getReader();
            let first = "";
            for (;;) {
              const index = first.indexOf("\n");
              if (index >= 0) {
                let epoch = null;
                try { epoch = JSON.parse(first.slice(0, index))?.epoch; } catch {}
                if (!Number.isSafeInteger(epoch)) break;
                shows = uiRanker(epoch);
                buffered = first.slice(index + 1);
                next = cursor;
                return at;
              }
              const { value, done } = await at.read();
              if (done) return at;
              first += decoder.decode(value, { stream: true });
            }
            void at.cancel().catch(() => {});
            return ui.read(0).getReader();
          };
          return new ReadableStream({
            async pull(controller) {
              if (!reader) {
                const { created, id: sessionId } = await resolved;
                reader = await open((await created.session(sessionId)).ui);
              }
              for (;;) {
                const index = buffered.indexOf("\n");
                if (index >= 0) {
                  const line = buffered.slice(0, index);
                  buffered = buffered.slice(index + 1);
                  next += 1;
                  let event;
                  try { event = JSON.parse(line); } catch { continue; }
                  if (!shows(event) || next <= cursor) continue;
                  controller.enqueue(encoder.encode(`${JSON.stringify({ ...event, cursor: next })}\n`));
                  return;
                }
                const { value, done } = await reader.read();
                if (done) {
                  controller.close();
                  return;
                }
                buffered += decoder.decode(value, { stream: true });
              }
            },
            cancel() { void reader?.cancel().catch(() => {}); },
          });
        },
        /**
         * Guidance for the running turn, or the next turn when none runs: it
         * cuts a streaming reply short, waits for a running tool, and joins a
         * turn waiting to start. A steer with images or resources cannot
         * join a turn: the running one ends at its next safe point and the
         * steer runs next. With `messageId`, a retried call adds nothing;
         * one id names one input of the session, prompt or steer: reusing a
         * prompt's id throws `FX_MESSAGE_ID_IN_USE`, or, where the queue
         * outlives the process and the sender reads no log, the worker drops
         * the steer and emits a `session.error` with that code. Resolves once
         * the steer is stored, with its id, which the stream's events for it
         * carry.
         */
        async steer(input, steerOptions = {}) {
          if (typeof input === "string" ? input.length === 0 : !Array.isArray(input) || input.length === 0) {
            throw new TypeError("steer input must be a non-empty string or array of content blocks");
          }
          if (Array.isArray(input) && input.some((block) => block?.type === "image" && block.data !== undefined && typeof block.data !== "string")) {
            throw new TypeError("a durable steer carries image data as a base64 string");
          }
          if (steerOptions === null || typeof steerOptions !== "object") throw new TypeError("steer options must be an object");
          const messageId = steerOptions.messageId ?? newId("str");
          if (!validId(messageId)) throw new TypeError(`messageId must be ${idRule}`);
          admit(input);
          // A steer's images go in the session's image store before the steer
          // that names them, as a prompt's do; storing one again under its
          // name is harmless, so a retry needs no check.
          let named = input;
          if (Array.isArray(input) && input.some((block) => block?.type === "image" && typeof block.data === "string")) {
            const { created, id: sessionId } = await resolved;
            named = await storePromptImages((await created.session(sessionId)).images, input);
            if (closed) throw new Error(`${label} is closed`);
          }
          await send({ type: "steer", messageId, input: named });
          return { messageId };
        },
        /** Cancels the running turn; dropping a turn's view does not. */
        async cancel() {
          await send({ type: "cancel", messageId: newId("cnl") });
        },
        /** The session's state as opaque bytes, read without changing it. */
        async checkpoint() {
          const { created, id: sessionId } = await resolved;
          const log = await created.session(sessionId);
          const state = foldSessionLog(await log.read());
          const readOnly = {
            load: async () => ({
              ...(state.checkpoint?.data ? { checkpoint: { through: state.checkpoint.through ?? "0", data: fromBase64(state.checkpoint.data) } } : {}),
              journal: state.records.map((record) => ({ cursor: record.cursor, data: fromBase64(record.data) })),
              head: state.head,
            }),
            append: async () => { throw new Error("a checkpoint reads the session without changing it"); },
            // The records name the session's images; the engine reads them
            // from its image store to export them.
            [persistenceImages]: {
              get: (name) => log.images.get(name),
              put: async () => { throw new Error("a checkpoint reads the session without changing it"); },
            },
          };
          const harness = await agent.openHarness(sessionId, readOnly, null);
          try {
            return await harness.exportCheckpoint();
          } finally {
            await harness.close().catch(() => {});
          }
        },
      };
      return session;
    };

    let defaultSession = null;
    const durableAgent = {
      // For tests and drivers: stops a session's running worker as its
      // deadline would.
      [durableInternals]: {
        stopAtDeadline: (sessionId) => workers.get(sessionId)?.stopNow?.(),
        // Waits for what a session's running turn has written so far.
        settled: async (sessionId) => { await workers.get(sessionId)?.settled?.(); },
        // Delivers a queue message to this agent as its queue would.
        deliver: async (delivered, delivery) => {
          const created = await backend();
          const message = deliveredMessage(created, delivered);
          return message ? receive(created, message, delivery) : undefined;
        },
        liveWorkers: () => workers.size,
        // A session's log as one worker holds it, with its own view of the
        // chain.
        openLog: async (sessionId) => (await backend()).session(sessionId),
        // The newest lease the session's log holds, standing or not.
        lastLease: async (sessionId) => {
          const log = await (await backend()).session(sessionId);
          return foldSessionLog(await log.read()).lastLease;
        },
        // Whether a lease stands on the session now, as a worker reading it
        // would judge: unexpired, and not held by a worker known dead.
        leaseStands: async (sessionId) => {
          const held = await backend();
          const log = await held.session(sessionId);
          return foldSessionLog(await log.read(), { now: Date.now(), alive: (lease) => held.alive(lease) }).lease !== null;
        },
      },
      /** Opens session `id`, or a new one; no I/O until it is used. */
      session(id, sessionOptions) {
        if (closed) throw new Error(`${label} is closed`);
        // A session object holds nothing a later call needs, so each call
        // gets its own, with its own context. Only a missing id starts a
        // new session; `null` is as invalid as any other non-id.
        return openSession(id, sessionOptions);
      },
      /** An id for a new session, before its first prompt. */
      async newSessionId() {
        return (await backend()).newSessionId();
      },
      /** The agent's name: its sessions' turns run only on agents with this name. */
      get name() {
        return agentName;
      },
      /** The agent's own session, for code that holds one conversation. */
      get sessionId() {
        return defaultSession?.id ?? null;
      },
      prompt(input, promptOptions) {
        defaultSession ??= openSession(undefined);
        return defaultSession.prompt(input, promptOptions);
      },
      checkpoint() {
        defaultSession ??= openSession(undefined);
        return defaultSession.checkpoint();
      },
      /**
       * The request handler a deployment mounts for queue deliveries, until
       * its World can deliver to this process itself.
       */
      wakeHandler() {
        return async (request) => {
          const created = await backend();
          if (typeof created.queueHandler !== "function") return new Response("this durability delivers in process", { status: 404 });
          return created.queueHandler(request);
        };
      },
      /** Waits for the work this process is running, then lets go. */
      async close() {
        if (closed) return;
        closed = true;
        leaveGroup(agentsByName, agentName, registered, member);
        while (active.size > 0) await Promise.allSettled([...active]);
        if (backendPromise) {
          const created = await backendPromise.catch(() => null);
          unlisten?.();
          await created?.close?.();
        }
      },
    };
    return durableAgent;
  };
}
