// A libfx persistence store over a Workflow World, written the way an app or
// the Workflow package would write it: libfx never sees the World, and this
// store never reads libfx's records.
//
// A session is one World run. Each record and each checkpoint is a
// `step_created` event in it, and a record's cursor is its event slot. A
// World commits a write at the next free slot rather than refusing it, so a
// record also stores the cursor it continued: a load keeps only the unbroken
// chain of records, and a write that lands after another writer's record for
// the same cursor is fenced.
import { FxFencedError } from "../node.js";

const recordStep = "fx.record";
const checkpointStep = "fx.checkpoint";
// Event ids are a prefix and the slot, zero-padded to 26 digits.
const eventId = /^[a-z]+_(\d{26})$/;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// A ULID: 48 bits of time, then 80 random bits, in Crockford base32.
function ulid(now = Date.now()) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let rest = now, index = 0; index < 10; index += 1, rest = Math.floor(rest / 32)) time = alphabet[rest % 32] + time;
  let random = "";
  for (const byte of crypto.getRandomValues(new Uint8Array(16))) random += alphabet[byte % 32];
  return time + random;
}

function slotOf(event) {
  const match = eventId.exec(String(event?.eventId ?? ""));
  if (!match) throw new Error(`the World returned event id ${JSON.stringify(event?.eventId ?? null)}, which holds no slot`);
  return Number(match[1]);
}

const toBase64 = (bytes) => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("base64");
const fromBase64 = (text) => new Uint8Array(Buffer.from(text, "base64"));

// The payload of one of this store's steps, or null for any other event.
function stepOf(event, stepName) {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== stepName) return null;
  const input = event.eventData.input;
  if (!(input instanceof Uint8Array)) return null;
  try { return JSON.parse(decoder.decode(input)); } catch { return null; }
}

/**
 * The persistence store for one session. Without `runId`, the store names a
 * new run at once and creates it with the session's first record, so a new
 * session reads nothing before its first model request.
 */
export function worldPersistence(world, { runId = null, pageSize = 100 } = {}) {
  let created = runId !== null;
  const id = runId ?? `wrun_${typeof world.createRunId === "function" ? world.createRunId({}) : ulid()}`;
  // The newest slot this store has seen; each write names it.
  let eventCount = 0;
  const spec = world.specVersion === undefined ? {} : { specVersion: world.specVersion };

  async function createRun() {
    await world.events.create(id, {
      eventType: "run_created",
      ...spec,
      eventData: { deploymentId: "fx", workflowName: "fx", input: encoder.encode("{}") },
    });
    const started = await world.events.create(id, { eventType: "run_started", ...spec }, { eventCount: 1 });
    eventCount = slotOf(started.event);
    created = true;
  }

  // Writes one step after the newest slot seen; returns its slot and the
  // events that landed between.
  async function write(stepName, payload) {
    const known = eventCount;
    const result = await world.events.create(id, {
      eventType: "step_created",
      correlationId: `step_${ulid()}`,
      eventData: { stepName, input: encoder.encode(JSON.stringify(payload)) },
    }, { eventCount: known });
    const slot = slotOf(result.event);
    eventCount = Math.max(eventCount, slot);
    if (slot === known + 1) return { slot, between: [] };
    const reported = Array.isArray(result.events) ? result.events : await readNewestFirst(known);
    return { slot, between: reported.filter((event) => slotOf(event) > known && slotOf(event) < slot) };
  }

  // The run's events, newest first, down to and excluding `stopBelow`.
  async function readNewestFirst(stopBelow) {
    const events = [];
    for (let cursor; ;) {
      const page = await world.events.list({ runId: id, pagination: { sortOrder: "desc", limit: pageSize, ...(cursor ? { cursor } : {}) }, resolveData: "all" });
      for (const event of page.data) {
        if (slotOf(event) <= stopBelow) return events;
        events.push(event);
      }
      if (!page.hasMore) return events;
      cursor = page.cursor;
    }
  }

  return {
    get runId() {
      return id;
    },
    // The latest checkpoint and the records after it: the run is read newest
    // first, as far back as that checkpoint's cursor.
    async load() {
      if (!created) return {};
      const newestFirst = [];
      let checkpoint = null;
      let stopAt = 0;
      for (let cursor, done = false; !done;) {
        const page = await world.events.list({ runId: id, pagination: { sortOrder: "desc", limit: pageSize, ...(cursor ? { cursor } : {}) }, resolveData: "all" });
        for (const event of page.data) {
          const slot = slotOf(event);
          eventCount = Math.max(eventCount, slot);
          if (checkpoint && slot <= stopAt) { done = true; break; }
          const saved = checkpoint ? null : stepOf(event, checkpointStep);
          if (saved) {
            // Records stored after the snapshot but before this event follow it.
            checkpoint = saved;
            stopAt = Number(saved.through);
            continue;
          }
          newestFirst.push(event);
        }
        if (!page.hasMore) done = true;
        cursor = page.cursor;
      }
      let head = checkpoint?.through ?? null;
      const journal = [];
      for (const event of newestFirst.reverse()) {
        const record = stepOf(event, recordStep);
        if (!record || record.expected !== head) continue;
        head = String(slotOf(event));
        journal.push({ cursor: head, data: fromBase64(record.data) });
      }
      return {
        ...(checkpoint ? { checkpoint: { through: checkpoint.through, data: fromBase64(checkpoint.data) } } : {}),
        journal,
      };
    },
    async append({ expected, idempotencyKey, data }) {
      if (!created) {
        if (expected !== null) throw new FxFencedError(`run ${id} does not exist yet`);
        await createRun();
      }
      const { slot, between } = await write(recordStep, { expected, key: idempotencyKey, data: toBase64(data) });
      if (between.some((event) => stepOf(event, recordStep)?.expected === expected)) {
        throw new FxFencedError(`another writer continued run ${id} at cursor ${expected}`);
      }
      return { cursor: String(slot) };
    },
    async saveCheckpoint({ through, data }) {
      await write(checkpointStep, { through, data: toBase64(data) });
    },
  };
}
