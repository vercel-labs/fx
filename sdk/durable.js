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
// `prompt()` adds its input, with its caller's context, to the log, then
// queues a message that only names it: the session, the message id and its
// kind. The worker the queue delivers it to takes the lease and runs every
// turn the log holds until none is left, or its time runs out: then it asks
// the queue to deliver the same message again, and the next worker continues
// the turn.
//
// A queue message is never trusted with what to run or as whom. A delivery
// can arrive at a public route, so its body may come from anyone; the worker
// acts only on a message its session's log already holds, and runs only
// what that log says. Writing to the log takes the store's own credentials,
// which only the app's authenticated `prompt()` path holds.

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
// A lease with nothing to show whether its holder lives expires after this,
// and its holder renews it well before.
const unknownHolderLeaseMs = 60_000;
// The newest consumed message ids a checkpoint keeps, so a message the queue
// delivers again after its turn ended is still recognized.
const recentIdsKept = 256;
// The longest a message waits for a live holder before it is delivered again.
const maxBackstopSeconds = 300;

const toBase64 = (bytes) => {
  let text = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(text);
};
const fromBase64 = (text) => Uint8Array.from(atob(text), (char) => char.charCodeAt(0));

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

// A durability is `memory()`, or a World one from `libfx/durable-local` or
// `libfx/durable-vercel`: `{ world() }` and how its workers hold sessions.
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

// ---------------------------------------------------------------------------
// The session log, folded. Pure: the same entries always fold the same way.

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
  const seenInputs = new Set();
  const inputs = [];
  const records = [];
  // A checkpoint taken where a turn yielded leaves that turn open.
  let openTurn = typeof base?.openTurn?.id === "string" ? { id: base.openTurn.id, at: Number(base.openTurn.at) || 0, context: base.openTurn.context ?? null } : null;
  let lastTurnId = base?.lastTurnId ?? null;
  let yielded = base?.yielded === true;
  // The context each prompt's or steer's caller gave, which its turn runs
  // with: an untaken steer becomes a turn. Only an input in the log has one;
  // a queue message never carries it.
  const contexts = new Map();
  for (const input of base?.pending ?? []) if (input.context !== undefined) contexts.set(input.messageId, input.context);
  // How many times each turn's engine stopped under it.
  const stops = new Map();
  const failed = new Map();
  let maxCursor = 0;
  const consume = (id) => {
    if (consumed.has(id)) return;
    consumed.add(id);
    recent.push(id);
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
        if (seenInputs.has(entry.key)) break;
        seenInputs.add(entry.key);
        inputs.push({ ...entry, cursor: position });
        if (entry.context !== undefined) contexts.set(entry.messageId, entry.context);
        break;
      case "lease":
      case "release":
      case "record": {
        // A chained entry stands only when it continues the chain; the
        // first writer to continue a cursor wins and the rest are fenced.
        if ((entry.a ?? null) !== head) break;
        head = cursor;
        if (entry.k === "lease") {
          lease = { holder: entry.holder, epoch: entry.epoch, expiresAt: entry.expiresAt ?? null, pid: entry.pid, host: entry.host, cursor };
          if (Number.isSafeInteger(entry.epoch) && entry.epoch > epoch) epoch = entry.epoch;
        } else if (entry.k === "release") {
          if (lease?.holder === entry.holder) lease = null;
        } else {
          records.push({ cursor, data: entry.data });
          for (const mark of entry.marks ?? []) {
            if (typeof mark.start === "string") {
              openTurn = { id: mark.start, at: position, context: contexts.get(mark.start) ?? null };
              consume(mark.start);
              yielded = false;
            } else if (mark.end === true) {
              if (openTurn) lastTurnId = openTurn.id;
              openTurn = null;
              yielded = false;
            } else if (mark.yield === true) {
              yielded = true;
            } else if (typeof mark.accepted === "string") {
              consume(mark.accepted);
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
  const pending = [];
  const steers = [];
  let cancelOpen = false;
  for (const input of inputs) {
    if (consumed.has(input.messageId)) continue;
    const forOpenTurn = openTurn !== null && input.cursor > openTurn.at;
    if (input.type === "prompt") pending.push(cancelTargets.has(input.messageId) ? { ...input, cancelled: true } : input);
    else if (input.type === "steer") {
      // A steer its turn never took becomes the next turn.
      if (forOpenTurn) steers.push(input);
      else pending.push({ ...input, type: "prompt" });
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
    // A resume request asks only that its session be woken: it is spent once
    // recorded, and its id is kept so its deliveries are recognized.
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
  // An open turn whose harness could not start has ended for its viewers; a
  // cancel it is due waits for the next prompt's engine. One whose engine
  // stopped each time it continued it is cancelled; one whose engine stopped
  // even then can never go on, and the session runs no more turns.
  const openFailed = openTurn !== null && failed.has(openTurn.id);
  const openStops = openTurn === null ? 0 : stops.get(openTurn.id) ?? 0;
  const halted = openStops >= maxHarnessStops + maxCancelStops;
  const stuck = openStops >= maxHarnessStops && !halted;
  return {
    // Inputs no turn has taken, as written: what a checkpoint keeps.
    unconsumed: inputs.filter((input) => !consumed.has(input.messageId)),
    head,
    // The lease others must respect, and the chain's latest whether or not
    // it still stands: a worker checks the latter is its own.
    lease: leaseStands(lease, now, alive) ? lease : null,
    lastLease: lease,
    lastEpoch: epoch,
    checkpoint: base ? { through: base.through ?? null, data: base.data } : null,
    records,
    openTurn,
    openFailed,
    lastTurnId,
    yielded,
    pending,
    steers,
    cancelOpen,
    recent: recent.slice(-recentIdsKept),
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

// ---------------------------------------------------------------------------
// Backends. Each gives sessions a log, a stream, and a queue.

function createMemoryBackend({ maxDurationMs, reserveMs } = {}) {
  const sessions = new Map();
  const holders = liveHolders;
  // Each agent sharing the backend takes deliveries in turn.
  const handlers = [];
  let turnOf = 0;
  const timers = new Set();
  const sessionFor = (id) => {
    let session = sessions.get(id);
    if (!session) {
      session = { entries: [], head: null, ui: [], uiWaiters: new Set(), watchers: new Set() };
      sessions.set(id, session);
    }
    return session;
  };
  const later = (fn, ms) => {
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timers.add(timer);
  };
  const deliver = (message, attempt) => {
    if (handlers.length === 0) return later(() => deliver(message, attempt), 10);
    const handler = handlers[turnOf++ % handlers.length];
    Promise.resolve()
      .then(() => handler(message, { attempt }))
      .then((result) => {
        if (Number.isFinite(result?.timeoutSeconds)) later(() => deliver(message, attempt + 1), result.timeoutSeconds * 1000);
      }, () => {
        if (attempt < 48) later(() => deliver(message, attempt + 1), 1000);
      });
  };
  return {
    name: "memory",
    livenessKnown: true,
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
    listen(fn) {
      handlers.push(fn);
      return () => {
        const index = handlers.indexOf(fn);
        if (index >= 0) handlers.splice(index, 1);
        if (handlers.length > 0) return;
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
const queuePrefix = "__libfx_wkf_workflow_";
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

function createWorldBackend(world, { name, reserveMs, pollMs, alive, holderInfo, livenessKnown = false, queueDurable = false, maxDurationMs }) {
  const spec = world.specVersion === undefined ? {} : { specVersion: world.specVersion };
  const created = new Set();
  // Workers in this process hear about each other's entries at once; others
  // poll.
  const watchers = new Map();
  const changed = (runId) => { for (const watcher of watchers.get(runId) ?? []) watcher(); };
  let handler = null;
  let removeHandler = null;
  const route = typeof world.registerHandler !== "function";
  const listEvents = (runId, cursor) => world.events.list({
    runId,
    pagination: { sortOrder: "desc", limit: 100, ...(cursor ? { cursor } : {}) },
    resolveData: "all",
  });
  const queueHandler = world.createQueueHandler(queuePrefix, async (message) => {
    const input = message?.input;
    if (!handler || !input || typeof input !== "object") return undefined;
    const result = await handler(input);
    return Number.isFinite(result?.timeoutSeconds) ? { timeoutSeconds: result.timeoutSeconds } : undefined;
  });
  const backend = {
    name,
    livenessKnown,
    queueDurable,
    pollMs: pollMs ?? 1000,
    reserveMs: reserveMs ?? defaultReserveMs,
    maxDurationMs: maxDurationMs ?? null,
    world,
    newSessionId: () => `wrun_${typeof world.createRunId === "function" ? world.createRunId({}) : ulid()}`,
    validSessionId: (id) => typeof id === "string" && /^wrun_[0-9A-Za-z]{10,64}$/.test(id),
    deadline: () => null,
    holderInfo: holderInfo ?? (() => ({})),
    alive(lease) {
      const mine = holderInfo?.() ?? {};
      if (mine.pid !== undefined && lease.pid === mine.pid && lease.host === mine.host) return liveHolders.has(lease.holder);
      return alive ? alive(lease) : null;
    },
    holding(holder, held) {
      if (held) liveHolders.add(holder);
      else liveHolders.delete(holder);
    },
    async start() {
      await world.start?.();
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
      const ensureRun = async () => {
        if (created.has(runId)) return;
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
        for (let cursor; ;) {
          let page;
          try {
            page = await listEvents(runId, cursor);
          } catch (error) {
            if (missingRun(error)) return { events, through };
            throw error;
          }
          for (const event of page.data) {
            const slot = slotOf(event);
            if (slot > known) known = slot;
            if (slot <= stopBelow) return { events, through };
            if (through !== null && slot <= through) return { events, through };
            const entry = logEntryOf(event);
            if (!entry) continue;
            created.add(runId);
            events.push({ cursor: String(slot), entry });
            if (stopAtCheckpoint && through === null && entry.k === "checkpoint") {
              through = entry.through === null || entry.through === undefined ? 0 : Number(entry.through);
            }
          }
          if (!page.hasMore) return { events, through };
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
          const chained = entry.k === "lease" || entry.k === "release" || entry.k === "record";
          // A chained entry asks the World to report every event since the
          // one it continues, so a competing continuation is seen.
          const after = chained ? (entry.a === null || entry.a === undefined ? 0 : Number(entry.a)) : known;
          const result = await world.events.create(runId, {
            eventType: "step_created",
            correlationId: `step_${ulid()}`,
            eventData: { stepName: logStep, input: encoder.encode(JSON.stringify(entry)) },
          }, { eventCount: after });
          const slot = slotOf(result.event);
          if (slot > known) known = slot;
          changed(runId);
          if (!chained || slot === after + 1) return String(slot);
          const reported = Array.isArray(result.events) ? result.events : (await newestFirst(after, false)).events.map((item) => ({ eventId: `evnt_${String(item.cursor).padStart(26, "0")}`, ...item }));
          for (const event of reported) {
            const other = event.entry ?? logEntryOf(event);
            const otherSlot = event.entry ? Number(event.cursor) : slotOf(event);
            if (!other || otherSlot <= after || otherSlot >= slot) continue;
            const otherChained = other.k === "lease" || other.k === "release" || other.k === "record";
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
            return new ReadableStream({
              async pull(controller) {
                for (let delay = 50, failures = 0; !reader; delay = Math.min(delay * 2, 1000)) {
                  if (cancelled) return;
                  try {
                    reader = (await world.streams.get(runId, uiStreamOf(runId), from)).getReader();
                  } catch (error) {
                    // A stream nobody wrote yet appears with the turn's first
                    // event; any other failure gets a few tries, then ends
                    // the read, so its viewer hears of it.
                    if (!missingRun(error) && ++failures > streamReadRetries) {
                      controller.error(error);
                      return;
                    }
                    await new Promise((resolve) => setTimeout(resolve, delay));
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
      async send(message, { delaySeconds = 0, idempotencyKey } = {}) {
        await world.queue(queueName, { runId: message.sessionId, requestId: message.messageId, input: message }, {
          ...(idempotencyKey ? { idempotencyKey } : {}),
          ...(delaySeconds > 0 ? { delaySeconds } : {}),
        });
      },
    },
    // The route a deployment mounts for queue deliveries, until the World
    // can deliver to an in-process handler itself.
    queueHandler,
    listen(fn) {
      handler = fn;
      if (!route && !removeHandler) {
        world.registerHandler(queuePrefix, queueHandler);
        removeHandler = () => {};
      }
      return () => { if (handler === fn) handler = null; };
    },
    // Closing is best effort: a runtime whose HTTP agent cannot close, as
    // under Bun, still lets the agent go.
    async close() {
      try {
        await world.close?.();
      } catch {}
    },
  };
  return backend;
}


// ---------------------------------------------------------------------------
// The worker: runs a session's turns while it holds the lease.

// Lines a worker writes to the session's UI stream, sent in small batches.
// Each carries the worker's lease epoch, so a reader can tell a replaced
// worker's late lines from its successor's.
function uiWriter(log, onError, epoch) {
  let queued = [];
  let scheduled = null;
  let tail = Promise.resolve();
  const flush = () => {
    if (scheduled) clearTimeout(scheduled);
    scheduled = null;
    if (queued.length === 0) return tail;
    const lines = queued;
    queued = [];
    tail = tail.then(() => log.ui.write(lines)).catch(onError);
    return tail;
  };
  return {
    push(event) {
      queued.push(JSON.stringify(epoch === undefined ? event : { ...event, epoch }));
      scheduled ??= setTimeout(flush, 20);
    },
    settle: flush,
  };
}

const errorSummary = (error) => ({ name: error?.name ?? "Error", message: String(error?.message ?? error), ...(error?.code ? { code: error.code } : {}) });
// The harness contract: a fenced write rejects with this code.
const isFenced = (error) => error?.code === "FX_FENCED";

// The kinds of message a session's queue carries.
const messageTypes = new Set(["prompt", "steer", "cancel", "resume"]);

// Whether the session's log holds the message a delivery names: its input,
// or its id among those already taken.
const knownMessage = (state, message) => state.inputKeys.has(`${message.type}:${message.messageId}`) || state.consumed.has(message.messageId);

// Writes what a message adds to its session, before the message is queued:
// a restored agent's first checkpoint and the message's input, a prompt with
// its caller's context. Only the sender calls it, so what a turn runs and as
// whom comes from the app's own call, never from a queue delivery. It writes
// nothing the log already holds, so a retried send writes it once.
async function recordMessage(log, state, message) {
  if (message.seed && state.checkpoint === null && state.records.length === 0) {
    await log.append({ k: "checkpoint", through: null, data: message.seed });
  }
  const key = `${message.type}:${message.messageId}`;
  if (messageTypes.has(message.type) && !knownMessage(state, message)) {
    await log.append({
      k: "input",
      key,
      type: message.type,
      messageId: message.messageId,
      ...(message.input === undefined ? {} : { input: message.input }),
      ...(typeof message.target === "string" ? { target: message.target } : {}),
      ...((message.type === "prompt" || message.type === "steer") && message.context !== undefined ? { context: message.context } : {}),
    });
  }
}

// How long before its deadline a worker stops itself, at most: it cancels
// the model or tool call still running, so it never runs on after its lease
// could pass to another worker.
const hardStopMs = 2000;

const durableInternals = Symbol.for("libfx.durableInternals");

// The shortest wait before a message that found its session running in this
// process is delivered again, as a backstop for the running worker.
const runningBackstopSeconds = 2;

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

  fold(entries) {
    return foldSessionLog(entries, { now: Date.now(), alive: (lease) => this.backend.alive(lease) });
  }

  // One queue delivery. Its sender wrote its input to the log before queueing
  // it, so a steer or cancel reaches the running turn even before this runs.
  // A delivery names a message the log must already hold; any other is not
  // from a sender and is dropped before anything is written, whether or not
  // its session exists. Then it runs the session when no live worker holds
  // it. Returns `{ timeoutSeconds }` to have the same message delivered again
  // later.
  async consume(message) {
    const log = await this.backend.session(this.sessionId);
    let state = this.fold(await log.read());
    if (!knownMessage(state, message)) {
      this.agent.emit("session.refused", { reason: "unknown message" });
      return undefined;
    }
    await this.backend.refreshDeadline?.();
    // When this delivery's function stops, if it does.
    const deadline = this.backend.deadline() ?? (this.backend.maxDurationMs === null ? null : Date.now() + this.backend.maxDurationMs);
    for (let claims = 0; claims < 8; claims += 1) {
      if (this.running) return { timeoutSeconds: runningBackstopSeconds };
      state = this.fold(await log.read());
      if (!state.hasWork) {
        if (message.type === "resume") await this.answerIdle(log, message);
        return undefined;
      }
      if (this.running) return { timeoutSeconds: runningBackstopSeconds };
      if (state.lease) {
        // The live holder takes this input from the log; come back as a
        // backstop once its lease would have run out.
        const left = state.lease.expiresAt ? Math.ceil((state.lease.expiresAt - Date.now()) / 1000) + 1 : 5;
        return { timeoutSeconds: Math.max(1, Math.min(maxBackstopSeconds, left)) };
      }
      // Claimed before the first await, so a delivery that arrives meanwhile
      // sees the session running here.
      this.running = true;
      this.holder = newId("wkr");
      const lease = {
        k: "lease",
        a: state.head,
        holder: this.holder,
        epoch: state.lastEpoch + 1,
        expiresAt: deadline ?? (this.backend.livenessKnown ? null : Date.now() + unknownHolderLeaseMs),
        ...this.backend.holderInfo(),
      };
      let head;
      this.backend.holding(this.holder, true);
      let outcome;
      try {
        try {
          head = await log.append(lease);
        } catch (error) {
          if (isFenced(error)) continue;
          throw error;
        }
        outcome = await this.run(log, head, lease, deadline);
      } finally {
        this.backend.holding(this.holder, false);
        this.running = false;
      }
      if (outcome === "yielded") return { timeoutSeconds: 0 };
      // A write that failed for any other reason: the same message runs the
      // session again shortly.
      if (outcome === "failed") return { timeoutSeconds: 1 };
      if (outcome === "fenced") {
        // Another worker took the session over; this one stops.
        this.agent.emit("session.fenced", { sessionId: this.sessionId, epoch: lease.epoch });
        return undefined;
      }
    }
    return { timeoutSeconds: 1 };
  }

  // A resume with nothing to continue still answers its viewer.
  async answerIdle(log, message) {
    const ui = uiWriter(log, (error) => this.agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }));
    ui.push({ type: "idle", requestId: message.messageId });
    await ui.settle();
  }

  // Runs turns under the lease claimed at `head` until the log holds no
  // work, the time runs out, or another worker takes over.
  async run(log, claimHead, lease, deadline) {
    const agent = this.agent;
    let head = claimHead;
    let chain = Promise.resolve();
    let failed = null;
    let released = false;
    // Every chained entry, the harness's records included, continues the
    // newest one this worker wrote.
    const chained = (entry) => {
      const appended = chain.then(async () => {
        if (failed) throw failed;
        try {
          head = await log.append({ ...entry, a: head });
          return head;
        } catch (error) {
          failed = error;
          throw error;
        }
      });
      chain = appended.catch(() => {});
      return appended;
    };
    const release = async () => {
      await chain;
      if (failed || released) return;
      released = true;
      await chained({ k: "release", holder: this.holder }).catch(() => {});
    };
    // Why the chain broke: another worker's write fenced this one out, or a
    // write failed for another reason, which the same message retries.
    const broken = () => {
      if (isFenced(failed)) return "fenced";
      agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(failed) });
      return "failed";
    };
    let state = this.fold(await log.read());
    if (state.lastLease?.holder !== this.holder) return "fenced";
    const ui = uiWriter(log, (error) => agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }), lease.epoch);
    const store = {
      load: async () => ({
        ...(state.checkpoint?.data ? { checkpoint: { through: state.checkpoint.through ?? "0", data: fromBase64(state.checkpoint.data) } } : {}),
        journal: state.records.map((record) => ({ cursor: record.cursor, data: fromBase64(record.data) })),
        head,
      }),
      append: ({ idempotencyKey, data, marks }) => chained({ k: "record", key: idempotencyKey, data: toBase64(data), marks }).then((cursor) => ({ cursor })),
      saveCheckpoint: async ({ through, data }) => {
        // What a fold that starts at this checkpoint would otherwise miss:
        // inputs before it that no turn took, the ids it ran, the turn a
        // yield left open, and the lease.
        const now = this.fold(await log.read());
        await log.append({
          k: "checkpoint",
          through,
          data: toBase64(data),
          pending: now.unconsumed.filter((input) => input.cursor <= Number(through)),
          recent: now.recent,
          lastTurnId: now.lastTurnId,
          ...(now.openTurn ? { openTurn: now.openTurn, yielded: now.yielded } : {}),
          lease: { holder: this.holder, epoch: lease.epoch, expiresAt: lease.expiresAt, pid: lease.pid, host: lease.host },
        });
      },
    };
    let renew = null;
    if (lease.expiresAt !== null && deadline === null) {
      // A lease nothing else shows alive is renewed while its worker runs.
      renew = setInterval(() => {
        void chained({ k: "lease", holder: this.holder, epoch: lease.epoch, expiresAt: Date.now() + unknownHolderLeaseMs, ...this.backend.holderInfo() }).catch(() => {});
      }, unknownHolderLeaseMs / 3);
    }
    // Shortly before the deadline the worker hands the open turn back to the
    // log, cutting off whatever call is still running, and the same message
    // continues the turn in a new delivery. Half the reserve, at most
    // hardStopMs; a reserve of zero never stops a step.
    const stopMargin = deadline === null ? 0 : Math.min(hardStopMs, Math.floor(this.backend.reserveMs / 2));
    let turnNow = null;
    this.stopping = false;
    this.stopNow = () => {
      if (this.stopping) return;
      this.stopping = true;
      agent.emit("session.deadline", { sessionId: this.sessionId, epoch: lease.epoch });
      turnNow?.cancel({ reason: "handoff" });
    };
    const hardStop = stopMargin > 0 && deadline - stopMargin > Date.now()
      ? setTimeout(this.stopNow, deadline - stopMargin - Date.now())
      : null;
    let harness = null;
    let harnessContext = null;
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
        // The context of the turn it runs first: the open turn's, or the
        // next prompt's.
        harnessContext = (state.openTurn ? state.openTurn.context : state.pending[0]?.context) ?? null;
        harness = await agent.openHarness(this.sessionId, store, harnessContext);
      } catch (error) {
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
        if (open?.id) {
          // A call left running reruns only when running it twice is safe.
          // Any other call is never run again: the model is told it may have
          // partly run, and the turn goes on.
          messageId = open.id;
          ui.push({ type: "turn_resume", messageId, sessionId: this.sessionId });
          // It lands before the turn goes on, so any line the replaced
          // worker writes after it ranks below it and stays hidden.
          await ui.settle();
          try {
            turn = harness.resume({ yieldAt });
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
          // Each prompt runs with the context its caller gave.
          const wanted = next.context ?? null;
          if (JSON.stringify(wanted ?? null) !== JSON.stringify(harnessContext ?? null)) {
            await harness.close();
            harness = null;
            harness = await agent.openHarness(this.sessionId, store, wanted);
            harnessContext = wanted;
          }
          try {
            turn = harness.prompt(next.input ?? "", { turnId: messageId, yieldAt });
          } catch (error) {
            await log.append({ k: "stopped", messageId });
            return unusable(error);
          }
          ui.push({ type: "turn_start", messageId, sessionId: this.sessionId, ...(typeof next.input === "string" ? { input: next.input } : {}) });
          fresh = true;
        }
        turnNow = turn;
        if (this.stopping) turn.cancel({ reason: "handoff" });
        const outcome = await this.drive(log, harness, turn, messageId, state, ui);
        turnNow = null;
        if (outcome === "fenced") return "fenced";
        if (outcome === "yielded") {
          // Commit, checkpoint, release: the next delivery loads the
          // checkpoint and the few records after it. A turn handed back at
          // the deadline stored nothing more, so it has none to save.
          await harness.saveCheckpoint();
          await harness.close();
          harness = null;
          await release();
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
        state = this.fold(await log.read());
        if (fresh && !failed && !state.consumed.has(messageId)) {
          // A turn that ended before writing a record, such as a prompt the
          // harness refused or one a cancel stopped first, is done too. The
          // log says so before its viewers hear it ended, so a retry that
          // reads the log finds it ended.
          await log.append({ k: "ended", messageId });
          state = this.fold(await log.read());
        }
        ui.push({ type: "turn_end", messageId, stopReason: result.stopReason, usage: result.usage ?? {}, ...(result.error ? { error: result.error } : {}) });
        await ui.settle();
        if (!fresh && !failed && harness.openTurn?.id === messageId) {
          // A harness that leaves a turn open after it ended would run it
          // again forever; the worker stops instead.
          agent.emit("session.error", { sessionId: this.sessionId, error: { name: "Error", message: `turn ${messageId} ended but stayed open` } });
          break;
        }
        if (state.lastLease?.holder !== this.holder && !failed) return "fenced";
      }
      await harness.close();
      harness = null;
      if (failed) return broken();
      await release();
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
    const applied = new Set();
    let since = String(state.maxCursor);
    let polling = false;
    let again = false;
    let stopped = false;
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
            if (entry.type === "steer" && typeof entry.input === "string") void turn.steer(entry.input, entry.messageId).catch(() => {});
            else if (entry.type === "cancel" && (entry.target === undefined || entry.target === messageId)) turn.cancel();
          }
        } while (again && !stopped);
      } catch {} finally {
        polling = false;
      }
    };
    for (const steer of state.steers) {
      applied.add(steer.key);
      if (typeof steer.input === "string") void turn.steer(steer.input, steer.messageId).catch(() => {});
    }
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
function uiRanker() {
  let high = 0;
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
// events only, until its end. `start` queues the turn and returns the
// stream; a resume learns its turn from the first one the stream shows.
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
  void (async () => {
    try {
      const { log, from, settled, attaching, endWithinMs } = await start();
      repeated = settled?.repeated === true || endWithinMs !== undefined;
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
  })();
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
    result,
    // Dropping a turn cancels nothing; `session.cancel()` does.
    [Symbol.asyncIterator]() { return iterate(false); },
    // Each line is one event with the cursor `stream()` resumes after it.
    get readable() {
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
 * - `open({ sessionId, store, context, durability })`: the harness session
 *   for one worker. `store` is where it keeps the session: `load()` resolves
 *   `{ checkpoint?, journal, head }`, `append({ idempotencyKey, data, marks })`
 *   stores one opaque record durably and resolves `{ cursor }`, and
 *   `saveCheckpoint({ through, data })` stores what the records through
 *   `through` add up to. Each record's `marks` tell the core where turns
 *   start (`{ start: turnId }`), yield (`{ yield: true }`) and end
 *   (`{ end: true }`), and which inputs a turn took (`{ accepted: id }`).
 *   A write another worker's write fenced out rejects with a `FX_FENCED`
 *   code.
 * - `seed` (optional): the bytes of a checkpoint a new session starts from.
 *
 * A harness session has `prompt(input, { turnId, yieldAt })` and
 * `resume({ yieldAt })`, each returning a turn; `openTurn`, the turn its
 * records left open as `{ id }`, or null; `settled()`, which resolves once
 * every record it started is stored; `saveCheckpoint()`;
 * `exportCheckpoint()`, the conversation as bytes; and `close()`. A turn is
 * an async iterable of the events its viewers see, with `result` resolving
 * `{ stopReason, usage? }`, `steer(text, id)`, and `cancel(options)`, where
 * `{ reason: "handoff" }` stops it at once and stores nothing more, so the
 * next worker continues it. It stops before a model request once `yieldAt`
 * has passed, with the stop reason `yielded`.
 *
 * An input the harness refuses is a turn that ends with an error.
 * `prompt()` and `resume()` throw only when the harness cannot run a turn,
 * and a turn whose harness stopped under it rejects with a
 * `FX_HARNESS_STOPPED` code; either way the same message runs the session
 * again with a new harness. After 3 stops a turn is resumed and cancelled at
 * once, or ends with an error when it never started; when its harness stops
 * twice more, even to cancel it, the session runs no more turns.
 *
 * `defaultDurability()` picks the durability when the caller names none,
 * `name` is the factory's name in errors, and `label` the agent's.
 */
export function createDurableAgentFactory({ harness, defaultDurability, name = "createAgent", label = "agent" }) {
  return function createDurableAgent(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError(`${name}() options must be an object`);
    }
    const { durability, ...harnessOptions } = options;
    if (durability !== undefined && !isDurability(durability)) {
      throw new TypeError("durability must come from memory(), local() or vercel()");
    }
    const plugged = harness(harnessOptions);
    const seed = plugged.seed === undefined ? undefined : toBase64(plugged.seed);
    const emit = (type, detail = {}) => {
      try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
    };
    const agent = {
      emit,
      openHarness: (sessionId, store, context) => plugged.open({ sessionId, store, context, durability: chosenDurability }),
    };
    let backendPromise = null;
    let chosenDurability = null;
    let unlisten = null;
    let closed = false;
    const workers = new Map();
    const active = new Set();
    const backend = () => {
      if (closed) return Promise.reject(new Error(`${label} is closed`));
      backendPromise ??= (async () => {
        const chosen = durability ?? await defaultDurability();
        chosenDurability = chosen;
        const created = await createBackend(chosen);
        await created.start?.();
        unlisten = created.listen((delivered) => {
          // Only the message's name is read from a delivery: the rest of its
          // body, which a forged delivery would choose, is ignored.
          if (!delivered || typeof delivered !== "object" || !messageTypes.has(delivered.type) || !validId(delivered.messageId) || !created.validSessionId(delivered.sessionId)) {
            emit("session.refused", { reason: "malformed message" });
            return undefined;
          }
          const message = { type: delivered.type, messageId: delivered.messageId, sessionId: delivered.sessionId };
          let worker = workers.get(message.sessionId);
          if (!worker) {
            worker = new SessionWorker(agent, created, message.sessionId);
            workers.set(message.sessionId, worker);
          }
          worker.deliveries += 1;
          const work = worker.consume(message);
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
        });
        return created;
      })();
      return backendPromise;
    };

    const openSession = (requestedId, sessionOptions = {}) => {
      if (requestedId !== undefined && !validId(requestedId)) throw new TypeError(`session id must be ${idRule}`);
      const context = sessionOptions?.context;
      if (context !== undefined) {
        try { JSON.stringify(context); } catch { throw new TypeError("session context must be JSON"); }
      }
      let id = requestedId ?? null;
      let seeded = seed === undefined || requestedId !== undefined;
      const resolved = backend().then((created) => {
        id ??= created.newSessionId();
        if (!created.validSessionId(id)) throw new TypeError(`${created.name} durability cannot hold session id ${JSON.stringify(id)}`);
        return { created, id };
      });
      void resolved.catch(() => {});
      const send = async (message) => {
        const { created, id: sessionId } = await resolved;
        const extra = {
          ...(seeded ? {} : { seed }),
          ...(context === undefined ? {} : { context }),
        };
        const full = { ...message, ...extra, sessionId };
        // The input and its caller's context reach the log here, on the
        // app's own call, before the caller hears the message was accepted.
        // The queue carries only which message to run, so a delivery cannot
        // choose what a turn runs or as whom, and a queue that ends with the
        // process loses no input.
        const log = await created.session(sessionId);
        await recordMessage(log, foldSessionLog(await log.read()), full);
        await created.queue.send({ type: message.type, messageId: message.messageId, sessionId }, { idempotencyKey: `${sessionId}:${message.type}:${message.messageId}` });
        seeded = true;
      };
      const startTurn = (type, messageId, input, retried = false, aborted = false) => {
        let accept;
        const accepted = new Promise((resolve, reject) => { accept = { resolve, reject }; });
        void accepted.catch(() => {});
        const view = turnView({
          messageId,
          resumeRequest: type === "resume" ? messageId : null,
          start: async () => {
            try {
              const { created, id: sessionId } = await resolved;
              const log = await created.session(sessionId);
              let attaching = type === "resume";
              let from = null;
              if (retried) {
                // A turn this id already ran answers from the log, without
                // queueing it again. The viewer's start is read first, so a
                // turn that ends after it has its end in view.
                from = await log.ui.length();
                const state = foldSessionLog(await log.read());
                // One still waiting or running: follow it.
                if ((state.openTurn?.id === messageId && !state.failed.has(messageId)) || (state.inputKeys.has(`prompt:${messageId}`) && !state.consumed.has(messageId))) attaching = true;
                else if (state.consumed.has(messageId)) {
                  accept.resolve({ messageId, sessionId });
                  const ended = await turnEndIn(log, messageId, from);
                  if (ended) return { settled: { ...ended, repeated: true } };
                  const error = state.failed.get(messageId);
                  if (error) return { settled: { messageId, stopReason: "error", error, repeated: true } };
                  return { log, from, attaching: true, endWithinMs: retryEndWaitMs };
                }
              }
              if (aborted && !attaching) {
                // A new prompt whose signal had aborted is never stored.
                accept.resolve({ messageId, sessionId });
                return { settled: { messageId, stopReason: "cancelled", usage: {} } };
              }
              // The viewer starts where the stream is now, before the
              // message can produce anything.
              from ??= await log.ui.length();
              await send({ type, messageId, ...(input === undefined ? {} : { input }) });
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
         * again.
         */
        prompt(input, promptOptions = {}) {
          if (closed) throw new Error(`${label} is closed`);
          const messageId = promptOptions.messageId ?? newId("msg");
          if (!validId(messageId)) throw new TypeError(`messageId must be ${idRule}`);
          if (typeof input !== "string" && !Array.isArray(input)) throw new TypeError("prompt input must be a string or an array of content blocks");
          // The input travels through the queue and the log as JSON.
          if (Array.isArray(input) && input.some((block) => block?.type === "image" && block.data !== undefined && typeof block.data !== "string")) {
            throw new TypeError("a durable prompt carries image data as a base64 string");
          }
          const signal = promptOptions.signal;
          if (signal !== undefined && typeof signal?.addEventListener !== "function") throw new TypeError("prompt signal must be an AbortSignal");
          const turn = startTurn("prompt", messageId, input, promptOptions.messageId !== undefined, signal?.aborted === true);
          if (signal !== undefined && !signal.aborted) {
            // The prompt's own cancel: it stops this turn whether it runs or
            // still waits, and never a later one.
            const stop = () => { void send({ type: "cancel", messageId: newId("cnl"), target: messageId }).catch(() => {}); };
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
         * The stream is read from its start, so lines rank the same however
         * a reader reconnects.
         */
        stream(cursor = 0) {
          if (!Number.isSafeInteger(cursor) || cursor < 0) throw new TypeError("stream cursor must be a non-negative integer");
          let reader = null;
          let buffered = "";
          let next = 0;
          const shows = uiRanker();
          return new ReadableStream({
            async pull(controller) {
              if (!reader) {
                const { created, id: sessionId } = await resolved;
                reader = (await created.session(sessionId)).ui.read(0).getReader();
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
        /** Guidance for the running turn, or the next turn when none runs. */
        async steer(text) {
          if (typeof text !== "string" || text.length === 0) throw new TypeError("steer text must be a non-empty string");
          await send({ type: "steer", messageId: newId("str"), input: text });
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
      // deadline would, and waits for what its turn has written so far.
      [durableInternals]: {
        stopAtDeadline: (sessionId) => workers.get(sessionId)?.stopNow?.(),
        settled: async (sessionId) => { await workers.get(sessionId)?.settled?.(); },
        liveWorkers: () => workers.size,
      },
      /** Opens session `id`, or a new one; no I/O until it is used. */
      session(id, sessionOptions) {
        if (closed) throw new Error(`${label} is closed`);
        // A session object holds nothing a later call needs, so each call
        // gets its own, with its own context.
        return openSession(id ?? undefined, sessionOptions);
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
