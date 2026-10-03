import { CoreOutput, maxCoreMessageBytes } from "./core-output.js";
import { loadModule } from "./wasm-module.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const strictDecoder = new TextDecoder("utf-8", { fatal: true });
const workspaceInfoLimit = 4 * 1024;
const workspaceCommandLimit = 64 * 1024;
const workspaceOutputLimit = 64 * 1024;
const maxInstructionsBytes = 64 * 1024;
const maxApiKeyBytes = 64 * 1024;
const maxModelBytes = 1024;
// Matches the kernel's ReasoningEffort.max_name_bytes.
const maxEffortBytes = 64;
const maxUrlBytes = 16 * 1024;
const maxModelCatalogBytes = 4 * 1024 * 1024;
const maxModelCatalogEntries = 10_000;
const streamReadsPerTaskYield = 32;
const transportActivityIntervalMs = 250;
const maxUnreadEventBytes = 1024 * 1024;
const maxUnreadEvents = 256;
// Prompt images travel as raw bytes beside the ACP frame and are base64
// encoded only in the model request. An image may use 5 MiB of encoded
// request data, and a prompt's images 8 MiB, so the raw limits are 3/4 of that.
// The kernel still validates content and media type.
const maxPromptImages = 8;
const maxPromptImageDataBytes = 5 * 1024 * 1024;
const maxPromptImagesDataBytes = 8 * 1024 * 1024;
const maxPromptImageBytes = (maxPromptImageDataBytes / 4) * 3;
const maxPromptImagesBytes = (maxPromptImagesDataBytes / 4) * 3;
// Matches the native attachment table: one prompt's images or one checkpoint.
const maxPendingAttachments = 8;
const maxOutboundAttachments = 4;
// Matches the core's kernel checkpoint limit (max_checkpoint_bytes).
const maxCheckpointBytes = 4 * 1024 * 1024;
// Matches the core's journal load limit (journal.max_load_bytes).
const maxJournalBytes = 4 * 1024 * 1024;
// The core's ACP reader drops frames over 8 MiB without a request id to answer
// (jsonrpc frame_resource_byte_limit), so the SDK must never emit one. The
// envelope allowance covers the method key and request id.
const maxPromptFrameBytes = 8 * 1024 * 1024;
const promptFrameEnvelopeBytes = 128;
const maxSteeringMessageBytes = 64 * 1024;
const maxSteeringMessages = 64;
const maxSteeringQueueBytes = 1024 * 1024;
// tool_start events carry a bounded preview of the tool input; larger inputs
// are marked truncated instead of dropped or sent whole.
const maxToolStartInputBytes = 64 * 1024;

function boundedString(value, name, maxBytes, required) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${name} ${required ? "is required and " : ""}must be a non-empty string`);
  }
  if (encoder.encode(value).length > maxBytes) {
    throw new RangeError(`${name} exceeds the ${maxBytes} byte libfx limit`);
  }
  return value;
}

function validateGatewayChatUrl(value) {
  if (value === undefined) return;
  boundedString(value, "gatewayChatUrl", maxUrlBytes, false);
  let url;
  try { url = new URL(value); } catch { throw new TypeError("gatewayChatUrl must be a valid URL"); }
  if (url.username || url.password || url.hash) {
    throw new TypeError("gatewayChatUrl must not contain credentials or a fragment");
  }
  if (url.href === "https://ai-gateway.vercel.sh/v4/ai/language-model") return;
  if (url.href === "https://ai-gateway.vercel.sh/v3/ai/language-model") return;
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "[::1]" || url.hostname === "localhost";
  if (url.protocol !== "http:" || !loopback || !url.port) {
    throw new TypeError("gatewayChatUrl must use the canonical Gateway or explicit loopback HTTP");
  }
}

// Mirrors the kernel's ReasoningEffort.parse: "auto"/"adaptive"/"default" pick
// the model default; anything else must be a bounded effort name.
function normalizeEffort(value) {
  if (value === undefined) return undefined;
  boundedString(value, "effort", maxEffortBytes, false);
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new TypeError('effort must use only letters, digits, ".", "-", or "_"');
  }
  return value;
}

// Mirrors the CLI's --fast/--no-fast toggle: a strict boolean, with undefined
// leaving the model default in place.
function normalizeFast(value) {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") {
    throw new TypeError("fast must be a boolean");
  }
  return value;
}

function normalizeUltrafast(value) {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") {
    throw new TypeError("ultrafast must be a boolean");
  }
  return value;
}

export function normalizeAgentOptions(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("createFxAgent() options must be an object");
  }
  const options = { ...value };
  if (Object.hasOwn(options, "env")) {
    throw new TypeError("createFxAgent() does not accept env; pass apiKey and model directly");
  }
  options.apiKey = boundedString(options.apiKey, "apiKey", maxApiKeyBytes, true);
  if (options.model !== null && typeof options.model === "object" && !Array.isArray(options.model)) {
    if (Object.hasOwn(options, "effort") || Object.hasOwn(options, "fast") || Object.hasOwn(options, "ultrafast")) {
      throw new TypeError("model options cannot be mixed with top-level effort, fast, or ultrafast");
    }
    const model = options.model;
    for (const name of Object.keys(model)) {
      if (name !== "id" && name !== "effort" && name !== "fast" && name !== "ultrafast") {
        throw new TypeError(`unsupported model option: ${name}`);
      }
    }
    options.model = boundedString(model.id, "model.id", maxModelBytes, true);
    options.effort = normalizeEffort(model.effort);
    options.fast = normalizeFast(model.fast);
    options.ultrafast = normalizeUltrafast(model.ultrafast);
  } else {
    options.model = boundedString(options.model, "model", maxModelBytes, false);
    options.effort = normalizeEffort(options.effort);
    options.fast = normalizeFast(options.fast);
    options.ultrafast = normalizeUltrafast(options.ultrafast);
  }
  validateGatewayChatUrl(options.gatewayChatUrl);
  if (options.resizeImage !== undefined && typeof options.resizeImage !== "function") {
    throw new TypeError("resizeImage must be a function");
  }
  if (options.sessionId !== undefined && options.sessionId !== null && !validSessionId(options.sessionId)) {
    throw new TypeError(`sessionId must be ${sessionIdRule}`);
  }
  // A separate key, so normalizing these options again reads the caller's value.
  if (options.modelCatalog !== undefined) options.modelCatalogBody = modelCatalogBody(options.modelCatalog);
  if (options.journal !== undefined) {
    const journal = options.journal;
    if (!journal || typeof journal !== "object" ||
      typeof journal.append !== "function" || typeof journal.load !== "function") {
      throw new TypeError("journal must be an object with append() and load()");
    }
    if (options.checkpoint !== undefined) {
      throw new TypeError("journal cannot be combined with checkpoint");
    }
  }
  if (options.world !== undefined) {
    validateWorld(options.world);
    if (options.journal !== undefined) throw new TypeError("world cannot be combined with journal");
    if (options.checkpoint !== undefined) throw new TypeError("world cannot be combined with checkpoint");
  }
  if (options.wakeAfterSeconds !== undefined) {
    if (options.world === undefined) throw new TypeError("wakeAfterSeconds needs world");
    validateWakeAfterSeconds(options.wakeAfterSeconds);
  }
  return options;
}

/**
 * Another writer took over the session after this agent loaded it. A journal
 * rejects the append with this error; the agent stops its turn at once and
 * makes no further effect or write. Check `code === "FX_FENCED"` when the
 * error may come from another copy of libfx.
 */
export class FxFencedError extends Error {
  constructor(message) {
    super(message);
    this.name = "FxFencedError";
    this.code = "FX_FENCED";
  }
}

/** The journal was written by a newer libfx than this one. */
export class FxJournalVersionError extends Error {
  constructor(message) {
    super(message);
    this.name = "FxJournalVersionError";
    this.code = "FX_JOURNAL_VERSION";
  }
}

// A journal this libfx cannot open: more than one load holds
// (FX_JOURNAL_TOO_LARGE), or events that do not fold (FX_JOURNAL_INVALID).
function journalLoadError(message, code, cause) {
  const error = new Error(message, cause === undefined ? undefined : { cause });
  error.code = code;
  return error;
}

// The core's libfx/journal_open errors, by their exact message. The journal
// tests open a journal for each, so rewording one fails them, except the size
// limit: libfx refuses a journal over it before the core sees one, so that
// entry is a backstop.
const journalOpenErrorCodes = new Map([
  ["Invalid libfx journal", "FX_JOURNAL_INVALID"],
  ["libfx journal events are out of order", "FX_JOURNAL_INVALID"],
  ["libfx journal is too large", "FX_JOURNAL_TOO_LARGE"],
  ["libfx journal holds more than 1024 turns", "FX_JOURNAL_TOO_LARGE"],
]);

/**
 * The turn the journal left open started under other instructions, tools or
 * model than this agent has, so `resume()` will not continue it. `prompt()`
 * ends it as interrupted instead.
 */
export class FxConfigMismatchError extends Error {
  constructor(message) {
    super(message);
    this.name = "FxConfigMismatchError";
    this.code = "FX_CONFIG_MISMATCH";
  }
}

/**
 * A journal that keeps events in memory, for tests and for hosts that copy
 * them elsewhere. `events` is the stored list, oldest first. An append that
 * does not continue the stored events is rejected, so a second agent cannot
 * write the same journal.
 */
export function createMemoryJournal(events = []) {
  if (!Array.isArray(events)) throw new TypeError("events must be an array");
  const stored = [...events];
  const lastSeq = () => stored.at(-1)?.seq ?? 0;
  return {
    events: stored,
    async append(batch) {
      const expected = lastSeq() + 1;
      if (batch[0]?.seq !== expected) {
        throw new FxFencedError(`another agent appended to this journal: expected seq ${expected}, received ${batch[0]?.seq}`);
      }
      stored.push(...batch);
    },
    async load() {
      return { events: stored.slice() };
    },
  };
}

// World storage. A session `createFxAgent({ world })` keeps is a World run,
// and each journal append is one `step_created` event in it, so the run's
// event log holds the session. The World is the app's, such as
// `createWorld()` from `@workflow/world-vercel`; libfx imports no Workflow
// package.
const worldJournalStep = "libfx.journal";
// A heartbeat is a step of its own: Worlds accept only their event types.
const worldHeartbeatStep = "libfx.heartbeat";
const worldJournalFormat = "libfx-journal-v1";
// A run names its workflow and deployment; nothing executes these runs.
const worldWorkflowName = "libfx";
// The queue topic of that workflow's runs (`getQueueTopicPrefix`).
const worldQueueName = `__wkf_workflow_${worldWorkflowName}`;
const defaultWakeAfterSeconds = 300;
// Event ids are `evnt_` followed by the slot, zero-padded to 26 digits.
const worldEventId = /^[a-z]+_(\d{26})$/;
// Failures a later delivery of the same wake would repeat, by code, so an
// error from another copy of libfx counts too.
const permanentWorldOpenFailures = new Set(["FX_CONFIG_MISMATCH", "FX_JOURNAL_TOO_LARGE", "FX_JOURNAL_INVALID"]);

// A ULID: 48 bits of time, then 80 random bits, in Crockford base32.
function worldUlid(now = Date.now()) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let rest = now, index = 0; index < 10; index += 1, rest = Math.floor(rest / 32)) time = alphabet[rest % 32] + time;
  let random = "";
  for (const byte of crypto.getRandomValues(new Uint8Array(16))) random += alphabet[byte % 32];
  return time + random;
}

function validateWorld(world) {
  if (!world?.events || typeof world.events.create !== "function" || typeof world.events.list !== "function" || typeof world.queue !== "function") {
    throw new TypeError("world must be a Workflow World with events.create(), events.list() and queue()");
  }
}

function validateWakeAfterSeconds(value) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new TypeError("wakeAfterSeconds must be a positive number");
  }
}

// Fencing reads the slot from the id, so an id in another form stops the
// write rather than letting it pass unchecked.
function worldSlot(event) {
  const match = worldEventId.exec(String(event?.eventId ?? ""));
  if (!match) throw new Error(`the World returned event id ${JSON.stringify(event?.eventId ?? null)}, which libfx cannot read a slot from`);
  return Number(match[1]);
}

// An event's payload travels as bytes, the form every World stores: here,
// UTF-8 JSON, which no World's own format prefix starts like.
function worldPayload(value) {
  return encoder.encode(JSON.stringify(value));
}

function worldPayloadOf(bytes) {
  if (!(bytes instanceof Uint8Array)) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

function worldBatch(event) {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== worldJournalStep) return null;
  const input = worldPayloadOf(event.eventData.input);
  if (input?.format !== worldJournalFormat || !Array.isArray(input.events) || input.events.length === 0) return null;
  return input.events;
}

// Whether a turn is open after `events`: progress or a tool intent opens one;
// a commit or a cleared turn closes it; compaction leaves it as it was.
function worldTurnOpenAfter(open, events) {
  for (const event of events) {
    if (event.type === "turn_progress" || event.type === "tool_intent") open = true;
    else if (event.type === "turn_committed" || event.type === "turn_progress_cleared") open = false;
  }
  return open;
}

// Whether the journal holds follow-ups no turn has run: accepted, and never
// placed by a progress or withdrawn.
function worldHoldsFollowUps(events) {
  const waiting = new Set();
  for (const event of events) {
    if (event.type === "input_accepted" && event.data?.kind === "follow_up") waiting.add(event.data.id);
    else if (event.type === "input_withdrawn") waiting.delete(event.data?.id);
    else if (event.type === "turn_progress") for (const id of event.inputs ?? []) waiting.delete(id);
  }
  return waiting.size > 0;
}

// The journal events a run holds. A batch counts only if it continues the
// events before it; a fenced writer's late batch repeats a seq and is skipped.
function worldJournalEvents(events) {
  const journalEvents = [];
  for (const event of events) {
    const batch = worldBatch(event);
    if (batch && batch[0].seq === journalEvents.length + 1) journalEvents.push(...batch);
  }
  return journalEvents;
}

async function readWorldRun(world, runId) {
  const events = [];
  let cursor;
  for (;;) {
    const page = await world.events.list({
      runId,
      pagination: { sortOrder: "asc", limit: 1000, ...(cursor ? { cursor } : {}) },
      resolveData: "all",
    });
    events.push(...page.data);
    if (!page.hasMore) break;
    cursor = page.cursor;
  }
  return events;
}

// The journal of a World session. `sessionId` opens that run; without it,
// `load()` creates one, and its id becomes the agent's `sessionId`.
// `wakeAfterSeconds` bounds how long an open turn may go without a write:
// the agent writes a heartbeat while a turn is open, so the queue route
// takes the turn over only once its process has stopped.
// `onWakeFailed(error)` hears once when the World cannot queue a wake, as
// outside a deployment; the session is kept, and only an automatic resume
// after a crash is lost.
function worldJournal(world, sessionId, wakeAfterSeconds = defaultWakeAfterSeconds, onWakeFailed = () => {}) {
  const wakeAfterMs = wakeAfterSeconds * 1000;
  // At least 100 ms, so a short test timeout does not turn into a write loop.
  const heartbeatMs = Math.max(100, wakeAfterMs / 3);

  let runId = sessionId ?? null;
  // Slots this process has seen. Slots are dense, so this is the last one.
  let eventCount = 0;
  let previous = Promise.resolve();
  let fenced = null;
  // The seq the next journal batch starts at.
  let nextSeq = 1;
  let turnOpen = false;
  // Whether this process queued a wake for the open turn, and whether the
  // World refused one.
  let wakeQueued = false;
  let wakeUnavailable = false;
  let lastWriteAt = 0;
  let heartbeat = null;
  let closed = false;

  const queueWake = (delaySeconds) => Promise.resolve()
    .then(() => world.queue(worldQueueName, { runId }, { delaySeconds }))
    .catch((error) => {
      wakeUnavailable = true;
      onWakeFailed(error);
    });
  // Step ids are `step_` and a ULID, the form Worlds accept.
  const stepId = () => `step_${worldUlid()}`;

  function fence(message) {
    fenced = new FxFencedError(message);
    stopHeartbeat();
    return fenced;
  }

  // Writes one event at the slot after the last one this process has seen.
  // A World never refuses a write for a taken slot: it commits at the next
  // free one and reports what it skipped, some Worlds with the new event
  // too. When a skipped event is another writer's batch starting at `seq`,
  // that batch continues the journal and this process's view is stale, so it
  // stops writing; load skips whatever it wrote after the other batch.
  async function commit(request, seq) {
    if (fenced) throw fenced;
    const result = await world.events.create(runId, request, { eventCount });
    lastWriteAt = Date.now();
    const slot = worldSlot(result.event);
    const expected = eventCount + 1;
    eventCount = slot;
    if (slot === expected) return;
    const reported = Array.isArray(result.events) ? result.events : await readWorldRun(world, runId);
    const skipped = reported.filter((event) => {
      const other = worldSlot(event);
      return other >= expected && other < slot;
    });
    if (skipped.some((event) => worldBatch(event)?.[0].seq === seq)) {
      throw fence(`another process wrote to session ${runId}; this one has stopped`);
    }
  }

  function serialize(task) {
    const done = previous.then(task);
    previous = done.catch(() => {});
    return done;
  }

  function startHeartbeat() {
    if (heartbeat) return;
    heartbeat = setInterval(() => {
      if (Date.now() - lastWriteAt < heartbeatMs) return;
      // A failed heartbeat is not retried here; the next one or the next
      // append writes again, and a fence stops both.
      serialize(() => (turnOpen && !fenced
        ? commit({ eventType: "step_created", correlationId: stepId(), eventData: { stepName: worldHeartbeatStep, input: worldPayload({}) } }, nextSeq)
        : undefined)).catch(() => {});
    }, heartbeatMs);
    heartbeat.unref?.();
  }

  function stopHeartbeat() {
    if (!heartbeat) return;
    clearInterval(heartbeat);
    heartbeat = null;
  }

  async function write(batch) {
    const open = worldTurnOpenAfter(turnOpen, batch);
    const wake = open && !wakeQueued && !wakeUnavailable;
    // A unique step id per write: a write that died partway can leave its id
    // taken in some Worlds, and must not block the write that replaces it.
    const step = commit({
      eventType: "step_created",
      correlationId: stepId(),
      eventData: { stepName: worldJournalStep, input: worldPayload({ format: worldJournalFormat, events: batch }) },
    }, batch[0].seq);
    // The wake rides alongside the turn's first write, so it costs no extra
    // round trip; without it no one resumes the turn if this process stops.
    // A wake the World refuses does not fail the write.
    await Promise.all([step, wake ? queueWake(wakeAfterSeconds) : undefined]);
    nextSeq = batch.at(-1).seq + 1;
    turnOpen = open;
    if (open) {
      wakeQueued = true;
      startHeartbeat();
    } else {
      wakeQueued = false;
      stopHeartbeat();
    }
  }

  return {
    async load() {
      if (runId === null) {
        // The client names a new run, as Workflow's `start()` does; a World
        // that embeds its own metadata in the id mints it.
        const created = `wrun_${typeof world.createRunId === "function" ? world.createRunId({}) : worldUlid()}`;
        await world.events.create(created, {
          eventType: "run_created",
          ...(world.specVersion === undefined ? {} : { specVersion: world.specVersion }),
          eventData: { deploymentId: worldWorkflowName, workflowName: worldWorkflowName, input: worldPayload({ format: worldJournalFormat }) },
        });
        // Nobody else knows the new run, so there is nothing to read back.
        // Should the World have added events of its own, the first write
        // finds them and continues after them.
        const started = await world.events.create(created, {
          eventType: "run_started",
          ...(world.specVersion === undefined ? {} : { specVersion: world.specVersion }),
        }, { eventCount: 1 });
        runId = created;
        eventCount = worldSlot(started.event);
        return { events: [], sessionId: runId };
      }
      let events = await readWorldRun(world, runId);
      // A run takes steps once it has started; one whose creator stopped
      // before starting it is started here.
      if (!events.some((event) => event.eventType === "run_started")) {
        await world.events.create(runId, {
          eventType: "run_started",
          ...(world.specVersion === undefined ? {} : { specVersion: world.specVersion }),
        }, { eventCount: events.length });
        events = await readWorldRun(world, runId);
      }
      eventCount = events.length;
      const journalEvents = worldJournalEvents(events);
      nextSeq = journalEvents.length + 1;
      turnOpen = worldTurnOpenAfter(false, journalEvents);
      return { events: journalEvents, sessionId: runId };
    },
    append(batch) {
      if (closed) return Promise.reject(new Error("the session's journal is closed"));
      // Each write states the slot it expects, so writes go out in call order.
      return serialize(() => write(batch));
    },
    // The agent closed: no more heartbeats, so a turn it left open, such as
    // one handed off, goes silent and the queue route resumes it.
    close() {
      closed = true;
      stopHeartbeat();
    },
  };
}

/**
 * The queue route for sessions `createFxAgent({ world })` keeps, for example
 * `export const POST = worldHandler({ world, createAgent })` in
 * `app/.well-known/workflow/v1/flow/route.js`. Resumes the session a queue
 * message names when its open turn, or a follow-up it holds, has gone
 * `wakeAfterSeconds` without a write; checks again later while the owner is
 * still writing; does nothing once no work is left.
 *
 * `createAgent({ sessionId })` builds the agent the app builds, with the same
 * tools, instructions and model, for that session.
 */
export function worldHandler({ world, createAgent, wakeAfterSeconds = defaultWakeAfterSeconds } = {}) {
  validateWorld(world);
  if (typeof createAgent !== "function") throw new TypeError("createAgent must be a function");
  validateWakeAfterSeconds(wakeAfterSeconds);
  const wakeAfterMs = wakeAfterSeconds * 1000;
  return async (request) => {
    let message;
    try {
      message = await request.json();
    } catch {
      return new Response("invalid queue message", { status: 400 });
    }
    const target = message?.runId;
    if (typeof target !== "string") return new Response("queue message has no runId", { status: 400 });

    const events = await readWorldRun(world, target);
    const journalEvents = worldJournalEvents(events);
    if (!worldTurnOpenAfter(false, journalEvents) && !worldHoldsFollowUps(journalEvents)) return new Response(null, { status: 204 });
    const lastAt = Math.max(0, ...events.map((event) => new Date(event.createdAt).getTime()).filter(Number.isFinite));
    const silentMs = Date.now() - lastAt;
    if (silentMs < wakeAfterMs) {
      // The owner wrote recently and may still be running the turn.
      await world.queue(worldQueueName, { runId: target }, { delaySeconds: Math.max(1, Math.ceil((wakeAfterMs - silentMs) / 1000)) });
      return new Response(null, { status: 204 });
    }

    let agent = null;
    try {
      agent = await createAgent({ sessionId: target });
      // An agent on another run would answer the wake and strand this one.
      if (agent.sessionId !== target) throw new TypeError("createAgent({ sessionId }) must open that session");
      // The open turn first, then each follow-up the journal held.
      for (let turn = agent.resume(); turn; turn = agent.resume()) {
        for await (const _ of turn) {}
        await turn.result;
      }
    } catch (error) {
      // Asking again will not change these: a deployment with other tools,
      // instructions or model cannot resume the turn, and this libfx cannot
      // open a journal that is too large or does not fold. A config
      // mismatch waits for the session's next prompt, which ends the turn
      // as interrupted.
      if (!permanentWorldOpenFailures.has(error?.code)) throw error;
      return new Response(`session ${target} was not resumed: ${error.message}`, { status: 200 });
    } finally {
      await agent?.close();
    }
    return new Response(null, { status: 204 });
  };
}

// Marks the turn `agent.resume()` starts; never a caller-visible option.
const resumeTurn = Symbol("libfx.resume");
// Carries the follow-up a turn runs: `{ id, accepted }`.
const followUpInput = Symbol("libfx.followUp");

function journalAppendError(cause) {
  const error = new Error("libfx journal append failed", { cause });
  error.code = "FX_JOURNAL_APPEND_FAILED";
  return error;
}

// What shapes a turn: instructions, model, and each tool's name,
// description, schema, replay policy and whether it writes. A turn the
// journal left open continues only under the same hash.
async function configHashOf(instructions, model, tools) {
  const text = JSON.stringify({
    instructions: instructions ?? null,
    model: model ?? null,
    tools: tools.map((tool) => [
      tool.name,
      tool.description ?? null,
      tool.inputSchema ?? null,
      tool.replay ?? null,
      tool.writes ?? null,
    ]),
  });
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

// Restoring an open turn needs only its newest progress, so an older one's
// state is left out of a load (data: null). A load then grows with the
// session's committed turns, not with every step of every turn.
function withoutSupersededProgress(events) {
  const kept = new Array(events.length);
  let superseded = false;
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    const type = event?.type;
    kept[index] = superseded && type === "turn_progress" && event.data != null ? { ...event, data: null } : event;
    if (type === "turn_progress" || type === "turn_committed" || type === "turn_progress_cleared") superseded = true;
  }
  return kept;
}

// A session id reaches gateway headers; the core applies the same rule.
function validSessionId(id) {
  return typeof id === "string" && /^[A-Za-z0-9._-]{1,255}$/.test(id) &&
    id !== "." && id !== ".." && id.toLowerCase() !== "v2";
}
const sessionIdRule = "1 to 255 letters, digits, '.', '_' or '-'";

function journalLoaded(loaded) {
  if (!loaded || typeof loaded !== "object" || !Array.isArray(loaded.events)) {
    throw new TypeError("journal.load() must resolve to { events: [] }");
  }
  const sessionId = loaded.sessionId ?? null;
  if (sessionId !== null && !validSessionId(sessionId)) {
    throw new TypeError(`journal.load() sessionId must be ${sessionIdRule}`);
  }
  return { events: loaded.events, sessionId };
}

function agentEnvironment(options) {
  return {
    AI_GATEWAY_API_KEY: options.apiKey,
    ...(options.model === undefined ? {} : { FX_MODEL: options.model }),
    ...(options.effort === undefined ? {} : { FX_EFFORT: options.effort }),
    ...(options.fast === undefined ? {} : { FX_FAST: options.fast ? "true" : "false" }),
    ...(options.ultrafast === undefined ? {} : { FX_ULTRAFAST: options.ultrafast ? "true" : "false" }),
    ...(options.gatewayChatUrl === undefined ? {} : { FX_GATEWAY_CHAT_URL: options.gatewayChatUrl }),
  };
}

function agentRpcError(response) {
  const error = new Error(response.message);
  const data = response.data;
  if (data && ["LIBFX_MODEL_UNSUPPORTED_EFFORT", "LIBFX_MODEL_UNSUPPORTED_FAST", "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST"].includes(data.code) &&
    typeof data.model === "string" &&
    data.capability === (data.code === "LIBFX_MODEL_UNSUPPORTED_FAST" ? "fast" : data.code === "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST" ? "ultrafast" : "effort")) {
    error.code = data.code;
    error.model = data.model;
    error.capability = data.capability;
  }
  return error;
}

async function cancelResponseBody(response) {
  try {
    await response.body?.cancel();
  } catch {}
}

async function readBoundedResponseText(response, limit) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) {
    await cancelResponseBody(response);
    throw new RangeError(`model catalog exceeds the ${limit} byte libfx limit`);
  }
  if (!response.body) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > limit) throw new RangeError(`model catalog exceeds the ${limit} byte libfx limit`);
    return strictDecoder.decode(bytes);
  }

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value?.length) continue;
    total += value.length;
    if (total > limit) {
      try {
        await reader.cancel();
      } catch {}
      throw new RangeError(`model catalog exceeds the ${limit} byte libfx limit`);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return strictDecoder.decode(bytes);
}

export async function listModels(options = {}) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("listModels() options must be an object");
  }
  const apiKey = boundedString(options.apiKey, "apiKey", maxApiKeyBytes, true);
  const fetchModels = options.fetch ?? globalThis.fetch?.bind(globalThis);
  if (typeof fetchModels !== "function") throw new TypeError("fetch is unavailable");
  const response = await fetchModels("https://ai-gateway.vercel.sh/coding-agent/v1/models", {
    method: "GET",
    headers: { authorization: `Bearer ${apiKey}` },
  });
  if (!response.ok) {
    await cancelResponseBody(response);
    throw new Error(`model catalog request failed with HTTP ${response.status}`);
  }

  let catalog;
  try {
    catalog = JSON.parse(await readBoundedResponseText(response, maxModelCatalogBytes));
  } catch (error) {
    if (error instanceof RangeError) throw error;
    throw new TypeError("model catalog response is malformed");
  }
  if (!catalog || typeof catalog !== "object" || !Array.isArray(catalog.data)) {
    throw new TypeError("model catalog response is malformed");
  }
  if (catalog.data.length > maxModelCatalogEntries) {
    throw new RangeError(`model catalog exceeds the ${maxModelCatalogEntries} entry libfx limit`);
  }

  const ids = new Set();
  for (const entry of catalog.data) {
    if (!entry || typeof entry !== "object") continue;
    if (typeof entry.type === "string" && entry.type.toLowerCase() !== "language") continue;
    if (typeof entry.id !== "string" || entry.id.length === 0) continue;
    if (encoder.encode(entry.id).length > maxModelBytes) continue;
    ids.add(entry.id);
  }
  return [...ids].sort();
}

function validWorkspacePath(path) {
  if (typeof path !== "string" || !path.startsWith("/") || path.includes("\0")) return false;
  if (strictDecoder.decode(encoder.encode(path)) !== path) return false;
  if (path === "/") return true;
  if (path.endsWith("/")) return false;
  return path.slice(1).split("/").every((part) => part && part !== "." && part !== "..");
}

function prepareWorkspaceAdapter(workspace) {
  if (workspace == null) return { present: false, valid: false };
  try {
    const info = workspace.info;
    const permission = workspace.permission;
    if (!info || typeof workspace.exec !== "function" || info.version !== 1 ||
      !validWorkspacePath(info.root) || !validWorkspacePath(info.cwd) ||
      !validWorkspacePath(info.home) || info.cwd !== info.root ||
      info.gitAvailable !== false || info.ephemeral !== true ||
      (permission !== "allow-sandboxed" && permission !== "prompt")) {
      return { present: true, valid: false };
    }
    const value = {
      version: 1,
      root: info.root,
      cwd: info.cwd,
      home: info.home,
      git: false,
      ephemeral: true,
      permission,
    };
    const encoded = encoder.encode(JSON.stringify(value));
    if (encoded.length > workspaceInfoLimit) return { present: true, valid: false };
    return { present: true, valid: true, adapter: workspace, info: value, encoded };
  } catch {
    return { present: true, valid: false };
  }
}

function utf8Prefix(value, limit) {
  if (value.length <= limit) return value;
  let end = limit;
  while (end > 0 && (value[end] & 0xc0) === 0x80) end -= 1;
  return value.subarray(0, end);
}

export const fxSdkApiVersion = 2;

export function supportsJspi() {
  return typeof WebAssembly.Suspending === "function" &&
    typeof WebAssembly.promising === "function";
}

export function encodeXtermKeyEvent(event) {
  if (event.type !== "keydown" || event.altKey || event.ctrlKey) return null;
  if (event.key === "Enter" && event.shiftKey && !event.metaKey) return "\x1b[13;2u";
  if (event.metaKey) {
    const modifiers = 8 | (event.shiftKey ? 1 : 0);
    if (event.key === "Backspace") return `\x1b[127;${modifiers + 1}u`;
    const arrow = { ArrowUp: "A", ArrowDown: "B", ArrowRight: "C", ArrowLeft: "D" }[event.key];
    if (arrow) return `\x1b[1;${modifiers + 1}${arrow}`;
    const shortcut = { a: 97, c: 99, x: 120, z: 122 }[event.key.toLowerCase()];
    if (shortcut) return `\x1b[${shortcut};${modifiers + 1}u`;
  }
  return null;
}

function xtermPointerCell(term, event) {
  const root = term.element;
  const screen = root?.querySelector?.(".xterm-screen") || root;
  const rect = screen?.getBoundingClientRect?.();
  if (!rect || rect.width <= 0 || rect.height <= 0 || term.cols <= 0 || term.rows <= 0) return null;
  if (event.clientX < rect.left || event.clientX >= rect.right ||
    event.clientY < rect.top || event.clientY >= rect.bottom) return null;
  return {
    column: Math.min(term.cols, Math.floor((event.clientX - rect.left) * term.cols / rect.width) + 1),
    row: Math.min(term.rows, Math.floor((event.clientY - rect.top) * term.rows / rect.height) + 1),
  };
}

function installXtermClickHandler(term, callback) {
  const element = term.element;
  if (typeof element?.addEventListener !== "function") return () => {};
  let pointerDown = null;
  const down = (event) => {
    if (event.button !== 0) return;
    pointerDown = { id: event.pointerId, x: event.clientX, y: event.clientY };
  };
  const up = (event) => {
    const start = pointerDown;
    pointerDown = null;
    if (!start || event.button !== 0 || event.pointerId !== start.id ||
      event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (dx * dx + dy * dy > 16) return;
    if (term.modes?.mouseTrackingMode && term.modes.mouseTrackingMode !== "none") return;
    const cell = xtermPointerCell(term, event);
    if (!cell) return;
    callback(`\x1b[<0;${cell.column};${cell.row}M\x1b[<0;${cell.column};${cell.row}m`);
  };
  const cancel = () => { pointerDown = null; };
  element.addEventListener("pointerdown", down);
  element.addEventListener("pointerup", up);
  element.addEventListener("pointercancel", cancel);
  return () => {
    element.removeEventListener("pointerdown", down);
    element.removeEventListener("pointerup", up);
    element.removeEventListener("pointercancel", cancel);
  };
}

function installXtermShortcutHandler(term, callback) {
  const element = term.element;
  if (typeof element?.addEventListener !== "function") return () => {};
  const keydown = (event) => {
    if (xtermSelectionOwnsShortcut(term, event)) return;
    const data = encodeXtermKeyEvent(event);
    if (data === null) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    callback(data);
  };
  element.addEventListener("keydown", keydown, true);
  return () => element.removeEventListener("keydown", keydown, true);
}

function xtermSelectionOwnsShortcut(term, event) {
  return event.type === "keydown" && event.metaKey &&
    (event.key.toLowerCase() === "c" || event.key.toLowerCase() === "x") &&
    term.hasSelection?.();
}

export function xtermAdapter(term) {
  let keyDataHandler = null;
  if (typeof term.attachCustomKeyEventHandler === "function") {
    term.attachCustomKeyEventHandler((event) => {
      if (xtermSelectionOwnsShortcut(term, event)) return true;
      const data = encodeXtermKeyEvent(event);
      if (data === null || keyDataHandler === null) return true;
      keyDataHandler(data);
      return false;
    });
  }
  return {
    write(bytes) { term.write(typeof bytes === "string" ? bytes : decoder.decode(bytes)); },
    onData(callback) { const disposable = term.onData(callback); return () => disposable.dispose(); },
    onKeyData(callback) {
      keyDataHandler = callback;
      const removeShortcutHandler = installXtermShortcutHandler(term, callback);
      const removeClickHandler = installXtermClickHandler(term, callback);
      return () => {
        removeShortcutHandler();
        removeClickHandler();
        if (keyDataHandler === callback) keyDataHandler = null;
      };
    },
    get cols() { return term.cols; },
    get rows() { return term.rows; },
    onResize(callback) { const disposable = term.onResize(callback); return () => disposable.dispose(); },
  };
}

class ByteQueue {
  chunks = [];
  waiters = [];
  closed = false;

  push(bytes) {
    if (this.closed) throw new Error("fx runtime stdin is closed");
    if (!bytes.length) return;
    this.chunks.push(bytes);
    this.wake();
  }

  read(max) {
    if (!this.chunks.length) return null;
    const chunk = this.chunks[0];
    const value = chunk.subarray(0, max);
    if (value.length === chunk.length) this.chunks.shift();
    else this.chunks[0] = chunk.subarray(value.length);
    return value;
  }

  wait(timeoutMs) {
    if (this.closed) return Promise.resolve(true);
    return new Promise((resolve) => {
      let settled = false;
      let timer;
      const waiter = () => {
        if (settled) return;
        settled = true;
        if (timer !== undefined) clearTimeout(timer);
        resolve(true);
      };
      this.waiters.push(waiter);
      if (timeoutMs !== undefined) {
        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) this.waiters.splice(index, 1);
          resolve(false);
        }, timeoutMs);
      }
    });
  }

  close() {
    this.closed = true;
    this.wake();
  }

  wake() {
    this.waiters.splice(0).forEach((resolve) => resolve());
  }
}

function raceWithTimeout(promise, timeoutMs, timeoutValue) {
  let timer;
  return new Promise((resolve, reject) => {
    timer = setTimeout(() => resolve(timeoutValue), timeoutMs);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); },
    );
  });
}

function yieldToHostTask() {
  if (typeof globalThis.setImmediate === "function") {
    return new Promise((resolve) => globalThis.setImmediate(resolve));
  }
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function createRuntime(options) {
  // Creating this inside a Wasm call would retain that instance through the error stack.
  const abortReason = new DOMException("This operation was aborted", "AbortError");
  const stdin = new ByteQueue();
  const streams = new Map();
  const httpRequests = new Set();
  const steering = [];
  let steeringBytes = 0;
  let steeringOpen = false;
  // Raw payloads beside ACP frames: the core copies inbound bytes into its
  // own memory and publishes outbound bytes for the agent to take.
  const inboundAttachments = new Map();
  const outboundAttachments = new Map();
  let nextOutboundAttachment = 1;
  const workspaceExecs = new Set();
  const workspace = prepareWorkspaceAdapter(options.workspace);
  const args = ["fx", ...(options.args || [])];
  const env = Object.entries(options.env || {}).map(([key, value]) => `${key}=${value}`);
  let instance;
  let nextHandle = 1;
  let exitedResolve;
  let exitCode = null;
  let aborted = false;
  let coreOutput;
  let outputError;
  const exited = new Promise((resolve) => { exitedResolve = resolve; });
  const markExited = (code) => {
    if (exitCode !== null) return;
    exitCode = code;
    exitedResolve(code);
  };
  const memory = () => instance.exports.memory;
  const bytes = (ptr, len) => new Uint8Array(memory().buffer, ptr, len);
  const text = (ptr, len) => decoder.decode(bytes(ptr, len));
  const writeU32 = (ptr, value) => new DataView(memory().buffer).setUint32(ptr, value, true);
  const writeU64 = (ptr, value) => new DataView(memory().buffer).setBigUint64(ptr, BigInt(value), true);

  function checkedBytes(ptr, len) {
    if (!Number.isInteger(ptr) || !Number.isInteger(len) || ptr < 0 || len < 0 ||
      ptr > memory().buffer.byteLength || len > memory().buffer.byteLength - ptr) return null;
    return bytes(ptr, len);
  }

  function writeVector(values, ptrs, data) {
    let cursor = data;
    values.forEach((value, index) => {
      const encoded = encoder.encode(`${value}\0`);
      writeU32(ptrs + index * 4, cursor);
      bytes(cursor, encoded.length).set(encoded);
      cursor += encoded.length;
    });
  }

  function emitStdout(chunk) {
    if (options.stdout) return options.stdout(chunk);
  }

  function fdWrite(fd, iovs, count, nwritten) {
    if (options.traceWasi) console.error("wasi fd_write", { fd, count });
    const view = new DataView(memory().buffer);
    let total = 0;
    for (let index = 0; index < count; index++) {
      total += view.getUint32(iovs + index * 8 + 4, true);
    }
    if (coreOutput && total > maxCoreMessageBytes) throw new RangeError("core output message exceeds 64 MiB");
    if (fd === 1 || fd === 2) {
      const chunk = new Uint8Array(total);
      let offset = 0;
      for (let index = 0; index < count; index++) {
        const ptr = view.getUint32(iovs + index * 8, true);
        const len = view.getUint32(iovs + index * 8 + 4, true);
        chunk.set(bytes(ptr, len), offset);
        offset += len;
      }
      if (fd === 1) {
        const pending = emitStdout(chunk);
        if (coreOutput && pending) return Promise.resolve(pending).then(() => {
          writeU32(nwritten, total);
          return 0;
        });
      }
      else if (typeof options.stderr === "function") options.stderr(chunk);
      else console.warn(decoder.decode(chunk));
    }
    writeU32(nwritten, total);
    return 0;
  }

  function fdRead(fd, iovs, count, nread) {
    if (fd !== 0) return 8;
    const attempt = () => {
      const view = new DataView(memory().buffer);
      let total = 0;
      for (let index = 0; index < count; index++) {
        const ptr = view.getUint32(iovs + index * 8, true);
        const len = view.getUint32(iovs + index * 8 + 4, true);
        const chunk = stdin.read(len);
        if (!chunk) break;
        bytes(ptr, chunk.length).set(chunk);
        total += chunk.length;
        if (chunk.length < len) break;
      }
      if (total) { writeU32(nread, total); return 0; }
      return null;
    };
    const immediate = attempt();
    if (immediate !== null) return immediate;
    if (stdin.closed) { writeU32(nread, 0); return 0; }
    return stdin.wait().then(() => {
      const result = attempt();
      if (result !== null) return result;
      writeU32(nread, 0);
      return 0;
    });
  }

  function pollOneoff(subscriptions, events, count, nevents) {
    const view = new DataView(memory().buffer);
    for (let index = 0; index < count; index++) {
      const base = subscriptions + index * 48;
      const type = view.getUint8(base + 8);
      if (type === 1 && stdin.chunks.length) {
        bytes(events, 32).fill(0);
        bytes(events, 8).set(bytes(base, 8));
        view.setUint8(events + 10, 1);
        writeU32(nevents, 1);
        return 0;
      }
    }
    let timeout = null;
    for (let index = 0; index < count; index++) {
      const base = subscriptions + index * 48;
      if (view.getUint8(base + 8) === 0) timeout = Number(view.getBigUint64(base + 24, true) / 1000000n);
    }
    return stdin.wait(timeout === null ? undefined : timeout).then(() => {
      bytes(events, 32).fill(0);
      bytes(events, 8).set(bytes(subscriptions, 8));
      writeU32(nevents, 1);
      return 0;
    });
  }

  function termPollInput(timeoutMs) {
    options.onTerminalPoll?.();
    if (stdin.chunks.length) return 1;
    if (stdin.closed) return -1;
    if (timeoutMs === 0) return 0;
    return stdin.wait(timeoutMs >= 0 ? timeoutMs : undefined).then(() =>
      stdin.chunks.length ? 1 : (stdin.closed ? -1 : 0));
  }

  function headersFromJson(ptr, len) {
    const headers = new Headers();
    for (const { name, value } of JSON.parse(text(ptr, len) || "[]")) headers.append(name, value);
    return headers;
  }

  function streamOpen(methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen) {
    const controller = new AbortController();
    const handle = nextHandle++;
    const state = {
      controller,
      reader: null,
      leftover: new Uint8Array(),
      response: null,
      responseError: null,
      responseSettled: null,
      pendingRead: null,
      readResult: null,
      readError: null,
      readsSinceTaskYield: 0,
    };
    streams.set(handle, state);
    state.responseSettled = Promise.resolve().then(() => options.fetch(text(urlPtr, urlLen), {
      method: text(methodPtr, methodLen),
      headers: headersFromJson(headersPtr, headersLen),
      body: bodyLen ? bytes(bodyPtr, bodyLen).slice() : undefined,
      signal: controller.signal,
    })).then((response) => {
      state.response = response;
      state.reader = response.body?.getReader() || null;
    }).catch((error) => {
      state.responseError = error;
    });
    return handle;
  }

  function streamStatus(handle, statusOut) {
    const state = streams.get(handle);
    if (!state) return -1;
    const settled = () => {
      if (state.responseError) return state.responseError?.name === "AbortError" ? -2 : -1;
      if (!state.response) return 0;
      new DataView(memory().buffer).setUint16(statusOut, state.response.status, true);
      return 1;
    };
    const immediate = settled();
    if (immediate !== 0) return immediate;
    return raceWithTimeout(state.responseSettled.then(() => true), 50, false).then((ready) =>
      ready ? settled() : 0);
  }

  function streamNext(handle, outPtr, outCap) {
    const state = streams.get(handle);
    if (!state) return -1;
    const yieldAfterReadyResult = (result) => {
      if (result <= 0) return result;
      state.readsSinceTaskYield += 1;
      if (state.readsSinceTaskYield < streamReadsPerTaskYield) return result;
      state.readsSinceTaskYield = 0;
      return yieldToHostTask().then(() => result);
    };
    const copy = (chunk) => {
      const written = chunk.subarray(0, outCap);
      bytes(outPtr, written.length).set(written);
      state.leftover = chunk.subarray(written.length);
      return written.length;
    };
    const consume = () => {
      if (state.leftover.length) return copy(state.leftover);
      if (state.readError) return state.readError?.name === "AbortError" ? -2 : -1;
      if (!state.readResult) return null;
      const { done, value } = state.readResult;
      state.readResult = null;
      if (done) return 0;
      if (!value?.length) return null;
      options.onTransportChunk?.(value.length);
      return copy(value);
    };
    const immediate = consume();
    if (immediate !== null) return yieldAfterReadyResult(immediate);
    if (!state.reader) return 0;
    if (!state.pendingRead) {
      state.pendingRead = state.reader.read().then((result) => {
        state.readResult = result;
        state.pendingRead = null;
      }).catch((error) => {
        state.readError = error;
        state.pendingRead = null;
      });
    }
    return raceWithTimeout(state.pendingRead.then(() => true), 50, false).then((ready) => {
      if (!ready) return -3;
      const result = consume();
      return result === null ? -3 : yieldAfterReadyResult(result);
    });
  }

  function httpRequest(methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen, statusOut, responsePtr, responseCap) {
    const controller = new AbortController();
    httpRequests.add(controller);
    let onAbort;
    const cancelled = new Promise((resolve) => {
      onAbort = () => resolve(-1);
      controller.signal.addEventListener("abort", onAbort, { once: true });
    });
    const request = (async () => {
      const response = await options.fetch(text(urlPtr, urlLen), {
        method: text(methodPtr, methodLen),
        headers: headersFromJson(headersPtr, headersLen),
        body: bodyLen ? bytes(bodyPtr, bodyLen).slice() : undefined,
        signal: controller.signal,
      });
      if (controller.signal.aborted) {
        void cancelResponseBody(response);
        return -1;
      }
      const body = new Uint8Array(await response.arrayBuffer());
      if (controller.signal.aborted) return -1;
      new DataView(memory().buffer).setUint16(statusOut, response.status, true);
      if (body.length > responseCap) return -2;
      bytes(responsePtr, body.length).set(body);
      return body.length;
    })().catch(() => -1);
    return Promise.race([request, cancelled]).finally(() => {
      controller.signal.removeEventListener("abort", onAbort);
      httpRequests.delete(controller);
    });
  }

  function clearSteering() {
    steering.length = 0;
    steeringBytes = 0;
  }

  function queueSteering(text, id = "") {
    if (!steeringOpen) throw new Error("no prompt is running");
    const value = encoder.encode(text);
    if (value.length === 0) throw new TypeError("steering text cannot be empty");
    if (value.length > maxSteeringMessageBytes) {
      throw new RangeError(`steering text exceeds the ${maxSteeringMessageBytes} byte libfx limit`);
    }
    if (steering.length >= maxSteeringMessages || value.length > maxSteeringQueueBytes - steeringBytes) {
      throw new Error("steering queue is full");
    }
    steering.push({ id, value });
    steeringBytes += value.length;
  }

  // The core takes queued steering at a boundary; until then it can be withdrawn.
  function withdrawSteering(id) {
    const index = steering.findIndex((entry) => entry.id === id);
    if (index < 0) return false;
    steeringBytes -= steering[index].value.length;
    steering.splice(index, 1);
    return true;
  }

  // Each message is its input id, a newline, then the text.
  function steeringTake(outputPtr, outputCap) {
    const entry = steering[0];
    if (!entry) return 0;
    const output = checkedBytes(outputPtr, outputCap);
    const id = encoder.encode(entry.id);
    const length = id.length + 1 + entry.value.length;
    if (!output || length > output.length) return -1;
    output.set(id, 0);
    output[id.length] = 10;
    output.set(entry.value, id.length + 1);
    steering.shift();
    steeringBytes -= entry.value.length;
    return length;
  }

  function writeAttachment(id, data) {
    if (inboundAttachments.size >= maxPendingAttachments) throw new Error("attachment table is full");
    inboundAttachments.set(id, data.slice());
  }

  function attachmentSize(id) {
    return inboundAttachments.get(id >>> 0)?.length ?? -1;
  }

  function attachmentTake(id, outputPtr, outputCap) {
    const key = id >>> 0;
    const value = inboundAttachments.get(key);
    if (!value) return -1;
    // An empty payload needs no output buffer, whose pointer may be arbitrary.
    if (value.length > 0) {
      const output = checkedBytes(outputPtr, outputCap);
      if (!output || value.length > output.length) return -1;
      output.set(value);
    }
    inboundAttachments.delete(key);
    return value.length;
  }

  function attachmentPut(inputPtr, inputLen) {
    const input = checkedBytes(inputPtr, inputLen);
    if (!input || outboundAttachments.size >= maxOutboundAttachments) return -1;
    const id = nextOutboundAttachment;
    nextOutboundAttachment = id === 0x7fffffff ? 1 : id + 1;
    outboundAttachments.set(id, input.slice());
    return id;
  }

  // Resolves once the agent's journal holds every event the core sent.
  function journalFlush() {
    if (typeof options.journalFlush !== "function") return -1;
    return Promise.resolve().then(() => options.journalFlush()).then(() => 0, () => -1);
  }

  let pendingHostToolResult = null;
  function hostToolCall(namePtr, nameLen, argumentsPtr, argumentsLen, outputPtr, outputCap, statusPtr, callIdPtr, callIdLen) {
    pendingHostToolResult = null;
    if (typeof options.hostToolExecutor !== "function") return -1;
    if (options.traceWasi) console.error("fx host tool call start");
    let input;
    try { input = JSON.parse(text(argumentsPtr, argumentsLen)); } catch { return -1; }
    return Promise.resolve(options.hostToolExecutor(text(namePtr, nameLen), input, undefined, text(callIdPtr, callIdLen))).then((result) => {
      if (options.traceWasi) console.error("fx host tool call settled", result.cancelled, result.isError);
      if (result.cancelled) return -2;
      const output = encoder.encode(result.content);
      bytes(statusPtr, 1)[0] = (result.isError ? 1 : 0) + (result.rich ? 2 : 0);
      if (output.length > outputCap) {
        if (!result.rich || output.length > 8 * 1024 * 1024) return -3;
        pendingHostToolResult = output;
        return output.length;
      }
      bytes(outputPtr, output.length).set(output);
      return output.length;
    }).catch(() => -1);
  }

  function openUrl(urlPtr, urlLen) {
    if (typeof options.openUrl !== "function") return 0;
    return Promise.resolve().then(() => options.openUrl(text(urlPtr, urlLen))).then((accepted) =>
      accepted === false ? 0 : 1).catch(() => 0);
  }

  function clipboardCopy(valuePtr, valueLen) {
    let clipboard = options.clipboard;
    if (clipboard === undefined) {
      try { clipboard = globalThis.navigator?.clipboard; } catch { clipboard = null; }
    }
    if (typeof clipboard?.writeText !== "function") return Promise.resolve(0);
    const value = text(valuePtr, valueLen);
    return Promise.resolve().then(() => clipboard.writeText(value)).then((accepted) => {
      if (accepted === false) return 0;
      options.emit?.("clipboard.copy", { length: value.length });
      return 1;
    }).catch((error) => {
      options.emit?.("clipboard.copy_error", { error });
      return 0;
    });
  }

  function oauthSessionLoad(outPtr, outCap, revisionPtr, revisionCap, revisionLenOut) {
    if (!options.oauthSessionStore?.load) return -1;
    return Promise.resolve().then(() => options.oauthSessionStore.load()).then((record) => {
      if (!record) return -2;
      const value = record.bytes instanceof Uint8Array ? record.bytes : new Uint8Array(record.bytes);
      if (typeof record.revision !== "string") return -1;
      const revision = encoder.encode(record.revision);
      if (value.length > outCap || revision.length > revisionCap) return -3;
      bytes(outPtr, value.length).set(value);
      bytes(revisionPtr, revision.length).set(revision);
      writeU32(revisionLenOut, revision.length);
      return value.length;
    }).catch(() => -1);
  }

  function oauthSessionCommit(valuePtr, valueLen, expectedPtr, expectedLen, revisionPtr, revisionCap, revisionLenOut) {
    if (!options.oauthSessionStore?.commit) return -1;
    const expectedRevision = expectedLen ? text(expectedPtr, expectedLen) : undefined;
    const value = bytes(valuePtr, valueLen).slice();
    return Promise.resolve().then(() => options.oauthSessionStore.commit(value, expectedRevision)).then((result) => {
      if (typeof result?.revision !== "string") return -1;
      const revision = encoder.encode(result.revision);
      if (revision.length > revisionCap) return -1;
      bytes(revisionPtr, revision.length).set(revision);
      writeU32(revisionLenOut, revision.length);
      return 0;
    }).catch((error) => error?.code === "FX_OAUTH_SESSION_REVISION_CONFLICT" ? -2 : -1);
  }

  function oauthSessionRemove(expectedPtr, expectedLen) {
    if (!options.oauthSessionStore?.remove) return -1;
    const expectedRevision = expectedLen ? text(expectedPtr, expectedLen) : undefined;
    return Promise.resolve().then(() => options.oauthSessionStore.remove(expectedRevision)).then((result) =>
      result === false || result === "missing" ? 1 : 0
    ).catch((error) => error?.code === "FX_OAUTH_SESSION_REVISION_CONFLICT" ? -2 : -1);
  }

  function configGet(idPtr, idLen, outPtr, outCap) {
    if (!options.configStore?.get) return -2;
    const configId = text(idPtr, idLen);
    return Promise.resolve().then(() => options.configStore.get(configId)).then((value) => {
      if (value === null || value === undefined) return -2;
      if (typeof value !== "string") throw new TypeError("configStore.get() must return a string or null");
      const encoded = encoder.encode(value);
      if (encoded.length > outCap) return -3;
      bytes(outPtr, encoded.length).set(encoded);
      options.emit?.("config.restore", { configId, value });
      return encoded.length;
    }).catch((error) => {
      options.emit?.("config.restore_error", { configId, error });
      return -1;
    });
  }

  function configSet(idPtr, idLen, valuePtr, valueLen) {
    if (!options.configStore?.set) return 0;
    const configId = text(idPtr, idLen);
    const value = text(valuePtr, valueLen);
    return Promise.resolve().then(() => options.configStore.set(configId, value)).then(() => {
      options.emit?.("config.changed", { configId, value, source: "terminal" });
      return 0;
    }).catch((error) => {
      options.emit?.("config.persist_error", { configId, error });
      return -1;
    });
  }

  function promptHistoryLoad(workspacePtr, workspaceLen, limit, outPtr, outCap) {
    if (!options.promptHistoryStore?.load) return -1;
    const workspaceRoot = text(workspacePtr, workspaceLen);
    return Promise.resolve().then(() => options.promptHistoryStore.load(workspaceRoot, limit)).then((entries) => {
      if (!Array.isArray(entries) || entries.some((entry) => typeof entry !== "string")) {
        throw new TypeError("promptHistoryStore.load() must return an array of strings");
      }
      const value = encoder.encode(JSON.stringify(entries));
      if (value.length > outCap) return -2;
      bytes(outPtr, value.length).set(value);
      options.emit?.("history.restore", { workspaceRoot, count: entries.length });
      return value.length;
    }).catch((error) => {
      options.emit?.("history.restore_error", { workspaceRoot, error });
      return -1;
    });
  }

  function promptHistoryAppend(timestampMs, workspacePtr, workspaceLen, valuePtr, valueLen) {
    if (!options.promptHistoryStore?.append) return -1;
    const workspaceRoot = text(workspacePtr, workspaceLen);
    const value = text(valuePtr, valueLen);
    return Promise.resolve().then(() => options.promptHistoryStore.append(workspaceRoot, value, Number(timestampMs))).then((result) => {
      options.emit?.("history.append", { workspaceRoot });
      if (result === "duplicate") return 1;
      if (result === "record_too_large") return 2;
      return 0;
    }).catch((error) => {
      options.emit?.("history.append_error", { workspaceRoot, error });
      return -1;
    });
  }

  function promptHistoryClear(workspacePtr, workspaceLen) {
    if (!options.promptHistoryStore?.clear) return -1;
    const workspaceRoot = text(workspacePtr, workspaceLen);
    return Promise.resolve().then(() => options.promptHistoryStore.clear(workspaceRoot)).then(() => {
      options.emit?.("history.clear", { workspaceRoot });
      return 0;
    }).catch((error) => {
      options.emit?.("history.clear_error", { workspaceRoot, error });
      return -1;
    });
  }

  function sessionLoad(idPtr, idLen, outPtr, outCap, revisionPtr, revisionCap, revisionLenOut) {
    if (!options.sessionStore) return -1;
    return Promise.resolve().then(() => options.sessionStore.load(text(idPtr, idLen))).then((record) => {
      if (!record) return -2;
      const value = record.bytes instanceof Uint8Array ? record.bytes : new Uint8Array(record.bytes);
      const revision = encoder.encode(record.revision);
      if (value.length > outCap || revision.length > revisionCap) return -3;
      bytes(outPtr, value.length).set(value);
      bytes(revisionPtr, revision.length).set(revision);
      writeU32(revisionLenOut, revision.length);
      return value.length;
    }).catch(() => -1);
  }

  function sessionCommit(idPtr, idLen, valuePtr, valueLen, expectedPtr, expectedLen, revisionPtr, revisionCap, revisionLenOut) {
    if (!options.sessionStore) return -1;
    const id = text(idPtr, idLen);
    const expectedRevision = expectedLen ? text(expectedPtr, expectedLen) : undefined;
    return Promise.resolve().then(() => options.sessionStore.commit(id, bytes(valuePtr, valueLen).slice(), expectedRevision)).then((result) => {
      const revision = encoder.encode(result.revision);
      if (revision.length > revisionCap) return -1;
      bytes(revisionPtr, revision.length).set(revision);
      writeU32(revisionLenOut, revision.length);
      return 0;
    }).catch((error) => error?.code === "FX_SESSION_REVISION_CONFLICT" ? -2 : -1);
  }

  function sessionList(outPtr, outCap) {
    if (!options.sessionStore) return -1;
    return Promise.resolve().then(() => options.sessionStore.list()).then((records) => {
      const value = encoder.encode(JSON.stringify(records));
      if (value.length > outCap) return -2;
      bytes(outPtr, value.length).set(value);
      return value.length;
    }).catch(() => -1);
  }

  function sessionRemove(idPtr, idLen) {
    if (!options.sessionStore) return -1;
    return Promise.resolve().then(() => options.sessionStore.remove(text(idPtr, idLen))).then(() => 0).catch(() => -1);
  }

  function workspaceInfo(outPtr, outCap) {
    if (!workspace.present) return -2;
    if (!workspace.valid) return -4;
    const output = checkedBytes(outPtr, outCap);
    if (!output) return -4;
    if (workspace.encoded.length > outCap) return -3;
    output.set(workspace.encoded);
    return workspace.encoded.length;
  }

  function workspaceExec(commandPtr, commandLen, timeoutMs, outputPtr, outputCap, resultPtr) {
    if (!workspace.present) return Promise.resolve(-2);
    if (!workspace.valid) return Promise.resolve(-4);
    const commandBytes = checkedBytes(commandPtr, commandLen);
    const output = checkedBytes(outputPtr, outputCap);
    const resultBytes = checkedBytes(resultPtr, 32);
    if (!commandBytes || !output || !resultBytes || commandLen > workspaceCommandLimit ||
      outputCap > workspaceOutputLimit || !Number.isInteger(timeoutMs) ||
      timeoutMs < 1 || timeoutMs > 30_000) return Promise.resolve(-4);
    let command;
    try {
      command = strictDecoder.decode(commandBytes);
    } catch {
      return Promise.resolve(-4);
    }
    if (command.includes("\0")) return Promise.resolve(-4);

    const controller = new AbortController();
    let resolveAbort;
    const aborted = new Promise((resolve) => { resolveAbort = resolve; });
    const state = {
      controller,
      status: null,
      abort(status) {
        if (this.status !== null) return;
        this.status = status;
        resolveAbort(status);
        controller.abort(new DOMException(
          status === -5 ? "workspace command timed out" : "workspace command aborted",
          status === -5 ? "TimeoutError" : "AbortError",
        ));
      },
    };
    workspaceExecs.add(state);
    const timer = setTimeout(() => state.abort(-5), timeoutMs);
    const execution = Promise.resolve().then(() => workspace.adapter.exec({
      command,
      cwd: workspace.info.cwd,
      signal: controller.signal,
      timeoutMs,
      outputLimitBytes: workspaceOutputLimit,
    })).then((value) => {
      if (state.status !== null) return state.status;
      if (!value || !Number.isInteger(value.exitCode) || value.exitCode < -0x80000000 ||
        value.exitCode > 0x7fffffff || typeof value.stdout !== "string" ||
        typeof value.stderr !== "string") return -1;
      const stdout = encoder.encode(value.stdout);
      const stderr = encoder.encode(value.stderr);
      if (stdout.length > 0xffffffff || stderr.length > 0xffffffff) return -1;

      let stdoutCap = stdout.length;
      let stderrCap = stderr.length;
      if (stdout.length + stderr.length > outputCap) {
        stdoutCap = Math.min(stdout.length, Math.ceil(outputCap / 2));
        stderrCap = Math.min(stderr.length, Math.floor(outputCap / 2));
        let remaining = outputCap - stdoutCap - stderrCap;
        const stdoutExtra = Math.min(remaining, stdout.length - stdoutCap);
        stdoutCap += stdoutExtra;
        remaining -= stdoutExtra;
        stderrCap += Math.min(remaining, stderr.length - stderrCap);
      }
      const stdoutPreview = utf8Prefix(stdout, stdoutCap);
      const stderrPreview = utf8Prefix(stderr, stderrCap);
      output.set(stdoutPreview, 0);
      output.set(stderrPreview, stdoutPreview.length);
      const copied = stdoutPreview.length + stderrPreview.length;
      const view = new DataView(memory().buffer, resultPtr, 32);
      view.setInt32(0, value.exitCode, true);
      view.setUint32(4, 0, true);
      view.setUint32(8, stdoutPreview.length, true);
      view.setUint32(12, stdout.length, true);
      view.setUint32(16, stdoutPreview.length, true);
      view.setUint32(20, stderrPreview.length, true);
      view.setUint32(24, stderr.length, true);
      view.setUint32(28, copied < stdout.length + stderr.length ? 1 : 0, true);
      return 0;
    }).catch((error) => {
      if (state.status !== null) return state.status;
      if (error?.name === "TimeoutError") return -5;
      if (error?.name === "AbortError") return -3;
      return -1;
    });
    return Promise.race([execution, aborted]).finally(() => {
      clearTimeout(timer);
      workspaceExecs.delete(state);
    });
  }

  function abortHostEffects() {
    pendingHostToolResult = null;
    streams.forEach((state) => state.controller.abort(abortReason));
    httpRequests.forEach((controller) => controller.abort(abortReason));
    workspaceExecs.forEach((state) => state.abort(-3));
  }

  const unavailable = () => 52;
  const wasi = {
    args_sizes_get(count, size) { if (options.traceWasi) console.error("wasi args_sizes_get"); writeU32(count, args.length); writeU32(size, args.reduce((n, v) => n + encoder.encode(v).length + 1, 0)); return 0; },
    args_get(ptrs, data) { if (options.traceWasi) console.error("wasi args_get"); writeVector(args, ptrs, data); return 0; },
    environ_sizes_get(count, size) { if (options.traceWasi) console.error("wasi environ_sizes_get"); writeU32(count, env.length); writeU32(size, env.reduce((n, v) => n + encoder.encode(v).length + 1, 0)); return 0; },
    environ_get(ptrs, data) { if (options.traceWasi) console.error("wasi environ_get"); writeVector(env, ptrs, data); return 0; },
    fd_write: options.args?.[0] === "acp" ? new WebAssembly.Suspending(fdWrite) : fdWrite,
    fd_read: new WebAssembly.Suspending(fdRead),
    fd_close() { return 0; },
    fd_fdstat_get(fd, out) {
      if (options.traceWasi) console.error("wasi fd_fdstat_get", fd);
      bytes(out, 24).fill(0);
      const view = new DataView(memory().buffer);
      view.setUint8(out, fd <= 2 ? 2 : 0);
      view.setBigUint64(out + 8, 0xffffffffffffffffn, true);
      view.setBigUint64(out + 16, 0xffffffffffffffffn, true);
      return 0;
    },
    fd_filestat_get: unavailable,
    fd_filestat_set_size: unavailable,
    fd_filestat_set_times: unavailable,
    fd_pread: unavailable,
    fd_prestat_get() { return 8; },
    fd_prestat_dir_name: unavailable,
    fd_pwrite: unavailable,
    fd_readdir: unavailable,
    fd_seek() { return 29; },
    fd_sync() { return 0; },
    clock_res_get(_id, out) { if (options.traceWasi) console.error("wasi clock_res_get"); writeU64(out, 1000000n); return 0; },
    clock_time_get(_id, _precision, out) { if (options.traceWasi) console.error("wasi clock_time_get"); writeU64(out, BigInt(Date.now()) * 1000000n); return 0; },
    path_create_directory: unavailable,
    path_filestat_get: unavailable,
    path_filestat_set_times: unavailable,
    path_link: unavailable,
    path_open: unavailable,
    path_readlink: unavailable,
    path_remove_directory: unavailable,
    path_rename: unavailable,
    path_symlink: unavailable,
    path_unlink_file: unavailable,
    random_get(ptr, len) { crypto.getRandomValues(bytes(ptr, len)); return 0; },
    poll_oneoff: new WebAssembly.Suspending(pollOneoff),
    proc_exit(code) { if (options.traceWasi) console.error("wasi proc_exit", code); markExited(code); throw new WebAssembly.RuntimeError(`proc_exit(${code})`); },
  };

  const fx = {
    fx_term_poll_input: new WebAssembly.Suspending(termPollInput),
    fx_clipboard_copy: new WebAssembly.Suspending(clipboardCopy),
    fx_prompt_history_available() { return options.promptHistoryStore ? 1 : 0; },
    fx_workspace_available() { return workspace.present ? 1 : 0; },
    fx_workspace_info: workspaceInfo,
    fx_workspace_exec: new WebAssembly.Suspending(workspaceExec),
    fx_http_stream_open: streamOpen,
    fx_http_stream_status: new WebAssembly.Suspending(streamStatus),
    fx_http_stream_next: new WebAssembly.Suspending(streamNext),
    fx_http_stream_close(handle) { const state = streams.get(handle); state?.controller.abort(abortReason); streams.delete(handle); },
    fx_http_request: new WebAssembly.Suspending(httpRequest),
    fx_host_tool_call: new WebAssembly.Suspending(hostToolCall),
    fx_journal_flush: new WebAssembly.Suspending(journalFlush),
    fx_host_tool_result_read(offset, ptr, cap) {
      if (!pendingHostToolResult || offset < 0 || offset > pendingHostToolResult.length) return -1;
      const chunk = pendingHostToolResult.subarray(offset, offset + cap);
      bytes(ptr, chunk.length).set(chunk);
      return chunk.length;
    },
    fx_host_tool_result_release() { pendingHostToolResult = null; },
    fx_steering_take: steeringTake,
    fx_steering_close() { steeringOpen = false; clearSteering(); },
    fx_attachment_size: attachmentSize,
    fx_attachment_take: attachmentTake,
    fx_attachment_put: attachmentPut,
    fx_open_url: new WebAssembly.Suspending(openUrl),
    fx_oauth_session_load: new WebAssembly.Suspending(oauthSessionLoad),
    fx_oauth_session_commit: new WebAssembly.Suspending(oauthSessionCommit),
    fx_oauth_session_remove: new WebAssembly.Suspending(oauthSessionRemove),
    fx_config_get: new WebAssembly.Suspending(configGet),
    fx_config_set: new WebAssembly.Suspending(configSet),
    fx_prompt_history_load: new WebAssembly.Suspending(promptHistoryLoad),
    fx_prompt_history_append: new WebAssembly.Suspending(promptHistoryAppend),
    fx_prompt_history_clear: new WebAssembly.Suspending(promptHistoryClear),
    fx_session_load: new WebAssembly.Suspending(sessionLoad),
    fx_session_commit: new WebAssembly.Suspending(sessionCommit),
    fx_session_list: new WebAssembly.Suspending(sessionList),
    fx_session_remove: new WebAssembly.Suspending(sessionRemove),
    fx_term_size(cols, rows) {
      const width = options.terminal?.cols || 80;
      const height = options.terminal?.rows || 24;
      new DataView(memory().buffer).setUint16(cols, width, true);
      new DataView(memory().buffer).setUint16(rows, height, true);
      options.emit?.("terminal.size", { cols: width, rows: height });
    },
  };

  return {
    imports: { wasi_snapshot_preview1: wasi, fx }, exited,
    setInstance(value) { instance = value; },
    write(data) { stdin.push(typeof data === "string" ? encoder.encode(data) : data); },
    writeAttachment,
    takeAttachment(id) {
      const value = outboundAttachments.get(id) ?? null;
      outboundAttachments.delete(id);
      return value;
    },
    discardAttachments() { inboundAttachments.clear(); },
    wake() { stdin.wake(); },
    closeStdin() { steeringOpen = false; clearSteering(); stdin.close(); },
    openSteering() { clearSteering(); steeringOpen = true; },
    steer: queueSteering,
    withdrawSteering,
    closeSteering() { steeringOpen = false; clearSteering(); },
    abortHostEffects,
    abort(error) {
      aborted = true;
      outputError = error;
      coreOutput?.close();
      abortHostEffects();
      stdin.close();
      markExited(130);
    },
    markExited,
    get aborted() { return aborted; },
    get exitCode() { return exitCode; },
    get error() { return outputError; },
    setLineHandler(handler) {
      coreOutput = new CoreOutput(handler);
      options.stdout = (chunk) => coreOutput.write(chunk);
    },
    finishOutput() { coreOutput?.finish(); },
  };
}

async function instantiate(options) {
  if (!supportsJspi()) throw new Error("fx WebAssembly requires JSPI (Chrome or Edge 137+)");
  const runtime = createRuntime({ fetch: globalThis.fetch.bind(globalThis), ...options });
  const module = await loadModule(options.wasm);
  const instance = await WebAssembly.instantiate(module, runtime.imports);
  runtime.setInstance(instance);
  const start = WebAssembly.promising(instance.exports._start);
  start().then(
    () => {
      runtime.setInstance(null);
      try { runtime.finishOutput(); runtime.markExited(0); }
      catch (error) { runtime.abort(error); }
    },
    (error) => {
      runtime.setInstance(null);
      if (options.args?.[0] === "acp" && !String(error).includes("proc_exit")) runtime.abort(error);
      else {
        if (!String(error).includes("proc_exit")) {
          runtime.abortHostEffects();
          console.error(error);
        }
        runtime.markExited(runtime.aborted ? 130 : 1);
      }
    },
  );
  return runtime;
}

export async function createFxTerminal(options) {
  if (!options?.terminal) throw new TypeError("terminal is required");
  const emit = (type, detail = {}) => {
    try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
  };
  let resolveInteractive;
  let rejectInteractive;
  let interactiveScheduled = false;
  const interactive = new Promise((resolve, reject) => {
    resolveInteractive = resolve;
    rejectInteractive = reject;
  });
  const stdout = (bytes) => options.terminal.write(bytes);
  const onTerminalPoll = () => {
    if (interactiveScheduled) return;
    interactiveScheduled = true;
    queueMicrotask(async () => {
      try {
        await options.terminal.drain?.();
        resolveInteractive();
      } catch (error) {
        rejectInteractive(error);
      }
    });
  };
  emit("runtime.start", { surface: "terminal" });
  const runtime = await instantiate({ ...options, emit, stdout, onTerminalPoll });
  runtime.exited.then((code) => {
    if (!interactiveScheduled) rejectInteractive(new Error(`fx terminal exited with code ${code} before becoming interactive`));
  });
  emit("runtime.ready", { surface: "terminal" });
  const interruptKey = options.interruptKey ?? "\x03";
  const forwardData = (data) => {
    if (interruptKey && data.includes(interruptKey)) runtime.abortHostEffects();
    runtime.write(data);
  };
  const signalResize = () => {
    emit("terminal.resize", { cols: options.terminal.cols, rows: options.terminal.rows });
    runtime.wake();
  };
  let unsubscribeData;
  let unsubscribeKeyData;
  let unsubscribeResize;
  let subscriptionsReleased = false;
  const releaseSubscriptions = () => {
    if (subscriptionsReleased) return;
    subscriptionsReleased = true;
    try { unsubscribeData?.(); } catch (error) { emit("terminal.cleanup_error", { source: "data", error }); }
    try { unsubscribeKeyData?.(); } catch (error) { emit("terminal.cleanup_error", { source: "key_data", error }); }
    try { unsubscribeResize?.(); } catch (error) { emit("terminal.cleanup_error", { source: "resize", error }); }
  };
  runtime.exited.then((code) => {
    releaseSubscriptions();
    emit("runtime.exit", { surface: "terminal", code });
  });
  try {
    unsubscribeData = options.terminal.onData(forwardData);
    unsubscribeKeyData = options.terminal.onKeyData?.(forwardData);
    unsubscribeResize = options.terminal.onResize(signalResize);
  } catch (error) {
    // The rejected factory never transfers this promise to a caller.
    interactive.catch(() => {});
    releaseSubscriptions();
    runtime.abort();
    throw error;
  }
  return {
    interactive,
    exited: runtime.exited,
    write(data) {
      if (interruptKey && typeof data === "string" && data.includes(interruptKey)) runtime.abortHostEffects();
      runtime.write(data);
    },
    resize: signalResize,
    abort() { releaseSubscriptions(); runtime.abort(); },
  };
}

function blobByteLength(value) {
  if (typeof Blob === "undefined" || value == null) return null;
  try {
    return Object.getOwnPropertyDescriptor(Blob.prototype, "size").get.call(value);
  } catch {
    return null;
  }
}

function normalizeImageSourceRef(value, name) {
  boundedString(value, `${name} sourceRef`, 512, false);
  if (value !== undefined && /[\x00-\x1f\x7f\uD800-\uDFFF]/u.test(value)) {
    throw new TypeError(`${name} sourceRef must be valid UTF-8 without ASCII controls`);
  }
  return value;
}

function omitReferencedImageData(blocks) {
  return blocks.map((block) => block.type !== "image" || block.sourceRef === undefined ? block : {
    type: "image",
    mimeType: block.mimeType,
    sourceRef: block.sourceRef,
  });
}

function promptImageDataBytes(prompt) {
  return prompt.reduce((total, block) => {
    if (block.type !== "image") return total;
    if (typeof block.data === "string") return total + block.data.length;
    const byteLength = block.bytes?.byteLength ?? block.byteLength ?? blobByteLength(block.data) ?? 0;
    return total + Math.ceil(byteLength / 3) * 4;
  }, 0);
}

// Returns a Uint8Array view of an ArrayBuffer or typed array, or null.
function byteView(value) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  return null;
}

const base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Returns the decoded length of canonical, unwrapped base64, or -1.
function canonicalBase64ByteLength(value) {
  if (value.length === 0 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return -1;
  const groups = value.length / 4;
  if (value.endsWith("==")) {
    return (base64Alphabet.indexOf(value[value.length - 3]) & 0x0f) === 0 ? groups * 3 - 2 : -1;
  }
  if (value.endsWith("=")) {
    return (base64Alphabet.indexOf(value[value.length - 2]) & 0x03) === 0 ? groups * 3 - 1 : -1;
  }
  return groups * 3;
}

function requireImageMimeType(mimeType, index) {
  if (typeof mimeType !== "string" || mimeType.length === 0 || mimeType.length > 128) {
    throw new TypeError(`image prompt block ${index} requires a mimeType`);
  }
}

function checkImageByteLength(byteLength, index) {
  if (byteLength > maxPromptImageBytes) {
    throw new RangeError(`image prompt block ${index} exceeds the ${maxPromptImageBytes} byte per-image libfx limit`);
  }
}

function checkPromptImagesByteLength(byteLength) {
  if (byteLength > maxPromptImagesBytes) {
    throw new RangeError(`prompt images exceed the ${maxPromptImagesBytes} byte libfx limit`);
  }
}

// Pixel inputs carry a private source and byteLength until preparation;
// reference-only inputs remain public image descriptors without pixel data.
function normalizePromptImage(block, index) {
  const sourceRef = normalizeImageSourceRef(block.sourceRef, `image prompt block ${index}`);
  const reference = sourceRef === undefined ? {} : { sourceRef };
  if (block.data === undefined && sourceRef !== undefined) {
    requireImageMimeType(block.mimeType, index);
    return { type: "image", mimeType: block.mimeType, ...reference };
  }
  const size = blobByteLength(block.data);
  if (size !== null) {
    const mimeType = block.data.type;
    if (block.mimeType !== undefined && block.mimeType !== mimeType) {
      throw new TypeError(`image prompt block ${index} mimeType disagrees with Blob.type`);
    }
    requireImageMimeType(mimeType, index);
    if (!Number.isSafeInteger(size) || size <= 0) {
      throw new TypeError(`image prompt block ${index} requires a non-empty Blob with a valid size`);
    }
    return { type: "image", source: "blob", data: block.data, mimeType, byteLength: size, ...reference };
  }
  if (typeof block.data === "string" && block.data.length > 0) {
    requireImageMimeType(block.mimeType, index);
    const byteLength = canonicalBase64ByteLength(block.data);
    if (byteLength <= 0) throw new TypeError(`image prompt block ${index} requires canonical base64 data`);
    return { type: "image", source: "base64", data: block.data, mimeType: block.mimeType, byteLength, ...reference };
  }
  const bytes = typeof block.data === "string" ? null : byteView(block.data);
  if (!bytes || bytes.byteLength === 0) {
    throw new TypeError(`image prompt block ${index} requires base64 data, bytes, or a Blob`);
  }
  requireImageMimeType(block.mimeType, index);
  return { type: "image", source: "bytes", data: bytes, mimeType: block.mimeType, byteLength: bytes.byteLength, ...reference };
}

// With deferImageLimits, byte limits apply after resizeImage instead.
function normalizePromptInput(input, { deferImageLimits = false } = {}) {
  if (typeof input === "string") return [{ type: "text", text: input }];
  if (!Array.isArray(input)) throw new TypeError("prompt input must be a string or an array of prompt blocks");
  let imageCount = 0;
  let imageBytes = 0;
  let prompt = input.map((block, index) => {
    if (!block || typeof block !== "object") throw new TypeError(`prompt block ${index} must be an object`);
    if (block.type === "image") {
      const image = normalizePromptImage(block, index);
      imageCount += 1;
      if (imageCount > maxPromptImages) {
        throw new RangeError(`prompt cannot contain more than ${maxPromptImages} images`);
      }
      if (!deferImageLimits) {
        if (image.byteLength > maxPromptImageBytes && image.sourceRef !== undefined) {
          return omitReferencedImageData([image])[0];
        }
        checkImageByteLength(image.byteLength ?? 0, index);
        imageBytes += image.byteLength ?? 0;
      }
      return image;
    }
    if (block.type === "text") {
      if (typeof block.text !== "string") throw new TypeError(`text prompt block ${index} requires text`);
      return { type: "text", text: block.text };
    }
    if (block.type === "resource") {
      const resource = block.resource || block;
      if (typeof resource.uri !== "string") throw new TypeError(`resource prompt block ${index} requires uri`);
      if (resource.text !== undefined && typeof resource.text !== "string") throw new TypeError(`resource prompt block ${index} text must be a string`);
      return { type: "resource", resource: { uri: resource.uri, ...(resource.text === undefined ? {} : { text: resource.text }) } };
    }
    throw new TypeError(`unsupported prompt block type: ${String(block.type)}`);
  });
  if (!deferImageLimits) {
    if (imageBytes > maxPromptImagesBytes) {
      prompt = omitReferencedImageData(prompt);
      imageBytes = prompt.reduce((total, block) => total + (block.type === "image" ? block.byteLength ?? 0 : 0), 0);
    }
    checkPromptImagesByteLength(imageBytes);
    if (promptFrameSize(prompt) > maxPromptFrameBytes) prompt = omitReferencedImageData(prompt);
  }
  return prompt;
}

// Image bytes travel beside the frame as attachment references, but the model
// request carries them base64 encoded and the native host caps that request at
// 8 MiB. Images therefore count at their encoded size, the same budget they
// had inside the frame. With countImages false, only the frame counts.
function promptFrameSize(prompt, countImages = true) {
  const encodedImageBytes = countImages ? promptImageDataBytes(prompt) : 0;
  const projected = prompt.map((block) => block.type !== "image" ? block : {
    type: "image",
    mimeType: block.mimeType,
    ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
    ...(block.data === undefined && block.bytes === undefined ? {} : { _meta: { fx: { attachment: 0xffffffff } } }),
  });
  return encoder.encode(JSON.stringify({ sessionId: "", prompt: projected })).length +
    encodedImageBytes + promptFrameEnvelopeBytes;
}

function checkPromptFrameSize(prompt, countImages) {
  if (promptFrameSize(prompt, countImages) > maxPromptFrameBytes) {
    throw new RangeError(`prompt exceeds the ${maxPromptFrameBytes} byte libfx frame limit`);
  }
}

// Returns prompt blocks whose images carry { mimeType, bytes }. Synchronous
// sources only: base64 is decoded and caller bytes are used in place.
function preparePromptImages(blocks) {
  return blocks.map((block) => block.type !== "image" || block.data === undefined ? block : {
    type: "image",
    mimeType: block.mimeType,
    bytes: block.source === "base64" ? base64ToBytes(block.data) : block.data,
    ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
  });
}

function resizedPromptImage(value, index) {
  const bytes = byteView(value?.bytes);
  if (!bytes || bytes.byteLength === 0 || typeof value.mimeType !== "string" ||
    value.mimeType.length === 0 || value.mimeType.length > 128) {
    throw new TypeError(`resizeImage must return non-empty bytes and a mimeType for image prompt block ${index}`);
  }
  // Copied because a hook may reuse its output buffer for the next image.
  return { bytes: bytes.slice(), mimeType: value.mimeType };
}

// Reads Blob images and applies resizeImage, then checks the final byte and
// frame limits. Returns null when the turn is cancelled first.
async function materializePromptImages(blocks, isCancelled, resizeImage) {
  let prepared = [];
  let imageBytes = 0;
  for (let index = 0; index < blocks.length; index++) {
    if (isCancelled()) return null;
    const block = blocks[index];
    if (block.type !== "image" || block.data === undefined) {
      prepared.push(block);
      continue;
    }
    let image = block.source === "blob"
      ? { mimeType: block.mimeType, bytes: new Uint8Array(await block.data.arrayBuffer()) }
      : preparePromptImages([block])[0];
    if (isCancelled()) return null;
    if (resizeImage) {
      image = resizedPromptImage(await resizeImage({ bytes: image.bytes, mimeType: image.mimeType }), index);
      if (isCancelled()) return null;
    }
    image = {
      type: "image",
      mimeType: image.mimeType,
      bytes: image.bytes,
      ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
    };
    if (image.bytes.byteLength > maxPromptImageBytes && image.sourceRef !== undefined) {
      image = omitReferencedImageData([image])[0];
    }
    checkImageByteLength(image.bytes?.byteLength ?? 0, index);
    imageBytes += image.bytes?.byteLength ?? 0;
    prepared.push(image);
    if (imageBytes > maxPromptImagesBytes) {
      prepared = omitReferencedImageData(prepared);
      // Do not read more referenced Blobs after the actual aggregate overflows.
      blocks = omitReferencedImageData(blocks);
      imageBytes = prepared.reduce((total, entry) => total + (entry.bytes?.byteLength ?? 0), 0);
    }
    checkPromptImagesByteLength(imageBytes);
  }
  if (promptFrameSize(prepared) > maxPromptFrameBytes) prepared = omitReferencedImageData(prepared);
  checkPromptFrameSize(prepared, true);
  return prepared;
}

function normalizeSteeringInput(input) {
  const blocks = normalizePromptInput(input);
  if (blocks.some((block) => block.type !== "text")) {
    throw new TypeError("steering accepts only text blocks");
  }
  const text = blocks.map((block) => block.text).join("\n");
  if (text.length === 0) throw new TypeError("steering text cannot be empty");
  if (encoder.encode(text).length > maxSteeringMessageBytes) {
    throw new RangeError(`steering text exceeds the ${maxSteeringMessageBytes} byte libfx limit`);
  }
  return text;
}

// `tools` is an array of descriptors, or an object of descriptors keyed by
// name. With a journal, every tool libfx runs declares whether a call that
// may have started can run again (`replay`).
function normalizeHostTools(value, { journaled = false } = {}) {
  if (value === undefined) return { descriptors: [], executors: new Map() };
  let entries;
  if (Array.isArray(value)) {
    entries = value;
  } else if (value && typeof value === "object") {
    entries = Object.entries(value).map(([key, tool]) => {
      if (!tool || typeof tool !== "object") throw new TypeError(`tool ${key} must be an object`);
      if (tool.name !== undefined && tool.name !== key) throw new TypeError(`tool ${key} has a different name: ${tool.name}`);
      return { ...tool, name: key };
    });
  } else {
    throw new TypeError("tools must be an array or an object");
  }
  if (entries.length > 64) throw new RangeError("tools cannot contain more than 64 entries");
  const descriptors = [];
  const executors = new Map();
  const names = new Set();
  for (const [index, tool] of entries.entries()) {
    if (!tool || typeof tool !== "object") throw new TypeError(`tool ${index} must be an object`);
    const { name, description, inputSchema, execute, providerExecuted, replay, writes } = tool;
    if (typeof name !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(name)) {
      throw new TypeError(`tool ${index} has an invalid name`);
    }
    if (names.has(name)) throw new TypeError(`duplicate tool name: ${name}`);
    names.add(name);
    if (providerExecuted !== undefined && typeof providerExecuted !== "boolean") {
      throw new TypeError(`tool ${name} providerExecuted must be a boolean`);
    }
    if (providerExecuted === true) {
      if (execute !== undefined) throw new TypeError(`provider-executed tool ${name} must not define execute()`);
      descriptors.push({ name, providerExecuted: true });
      continue;
    }
    if (typeof description !== "string") throw new TypeError(`tool ${name} requires a description`);
    if (typeof execute !== "function") throw new TypeError(`tool ${name} requires execute()`);
    if (replay !== undefined && replay !== "safe" && replay !== "never") {
      throw new TypeError(`tool ${name} replay must be "safe" or "never"`);
    }
    if (journaled && replay === undefined) {
      throw new TypeError(`tool ${name} needs replay: "safe" or "never" when a journal is set`);
    }
    if (writes !== undefined && typeof writes !== "boolean") throw new TypeError(`tool ${name} writes must be a boolean`);
    if (!inputSchema || typeof inputSchema !== "object" || Array.isArray(inputSchema)) {
      throw new TypeError(`tool ${name} requires an object inputSchema`);
    }
    let schema;
    try { schema = JSON.parse(JSON.stringify(inputSchema)); } catch {
      throw new TypeError(`tool ${name} inputSchema must be JSON-serializable`);
    }
    descriptors.push({
      name,
      description,
      inputSchema: schema,
      ...(replay === undefined ? {} : { replay }),
      ...(writes === undefined ? {} : { writes }),
    });
    executors.set(name, execute);
  }
  return { descriptors, executors };
}

// The model catalog a host supplies, as the response body the core would
// otherwise fetch: `{ data }` as AI Gateway returns it, or the entries alone.
function modelCatalogBody(value) {
  const entries = Array.isArray(value) ? value : value?.data;
  if (!Array.isArray(entries)) throw new TypeError("modelCatalog must be an array of catalog entries or { data: [...] }");
  if (entries.length > maxModelCatalogEntries) {
    throw new RangeError(`modelCatalog exceeds the ${maxModelCatalogEntries} entry libfx limit`);
  }
  for (const entry of entries) {
    if (!entry || typeof entry !== "object" || typeof entry.id !== "string" || entry.id === "") {
      throw new TypeError("each modelCatalog entry needs a string id");
    }
  }
  let body;
  try { body = JSON.stringify({ object: "list", data: entries }); } catch {
    throw new TypeError("modelCatalog must be JSON-serializable");
  }
  if (encoder.encode(body).length > maxModelCatalogBytes) {
    throw new RangeError(`modelCatalog exceeds the ${maxModelCatalogBytes} byte libfx limit`);
  }
  return body;
}

function normalizeInstructions(value) {
  let instructions;
  if (value === undefined) instructions = "";
  else if (typeof value === "string") instructions = value;
  if (Array.isArray(value) && value.every((entry) => typeof entry === "string")) {
    instructions = value.filter(Boolean).join("\n\n");
  }
  if (instructions === undefined) {
    throw new TypeError("instructions must be a string or an array of strings");
  }
  if (encoder.encode(instructions).length > maxInstructionsBytes) {
    throw new RangeError(`instructions exceed the ${maxInstructionsBytes} byte libfx limit`);
  }
  return instructions;
}

function hostToolContent(value) {
  if (value?.type === "libfx.tool-result") {
    if (typeof value.text !== "string" || !Array.isArray(value.images) || value.images.length > 8) {
      throw new TypeError("invalid typed tool result");
    }
    let images = value.images.map((image) => {
      if (image?.type !== "image") throw new TypeError("invalid tool image");
      const sourceRef = normalizeImageSourceRef(image.sourceRef, "tool image");
      const referenceOnly = image.data === undefined && sourceRef !== undefined;
      if ((!referenceOnly && typeof image.data !== "string") || typeof image.mimeType !== "string" || image.mimeType.length === 0 || image.mimeType.length > 128 || (image.data?.length > maxPromptImageDataBytes && sourceRef === undefined)) {
        throw new TypeError("invalid tool image");
      }
      return {
        type: "image",
        ...(!referenceOnly && image.data.length <= maxPromptImageDataBytes ? { data: image.data } : {}),
        mimeType: image.mimeType,
        ...(sourceRef === undefined ? {} : { sourceRef }),
      };
    });
    if (promptImageDataBytes(images) > maxPromptImagesDataBytes) images = omitReferencedImageData(images);
    if (promptImageDataBytes(images) > maxPromptImagesDataBytes) throw new RangeError("tool images exceed the result limit");
    let content = JSON.stringify({ text: value.text, images });
    if (encoder.encode(content).length > maxPromptImagesDataBytes) {
      images = omitReferencedImageData(images);
      content = JSON.stringify({ text: value.text, images });
    }
    if (encoder.encode(content).length > maxPromptImagesDataBytes) throw new RangeError("typed tool result exceeds the result limit");
    return { content, rich: true, isError: value.isError === true };
  }
  if (typeof value === "string") return { content: value, rich: false };
  if (value === undefined) return { content: "null", rich: false };
  const encoded = JSON.stringify(value);
  return { content: encoded === undefined ? "null" : encoded, rich: false };
}

function checkpointBytes(value) {
  if (value === undefined) return null;
  if (value instanceof Uint8Array) return value.slice();
  if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
  }
  throw new TypeError("checkpoint must be an ArrayBuffer or typed array");
}

function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export async function createFxAgent(options = {}) {
  options = normalizeAgentOptions(options);
  const hostTools = normalizeHostTools(options.tools, { journaled: options.journal !== undefined || options.world !== undefined });
  const instructions = normalizeInstructions(options.instructions);
  const initialCheckpoint = checkpointBytes(options.checkpoint);
  // Checked before the core starts, and with the core's message, so both
  // backends report it the same way.
  if (initialCheckpoint && initialCheckpoint.byteLength > maxCheckpointBytes) {
    throw new Error("libfx checkpoint is too large");
  }
  const pending = new Map();
  let nextId = 1;
  let sessionId = null;
  let activeTurn = null;
  let closing = false;
  let coreExitError = null;
  const isCurrentTurn = (turn) => turn && activeTurn === turn && !turn.cancelled && !closing;
  // Events go to the host in the order the core sends them. Events that
  // arrive together share one append, and an append starts without waiting
  // for earlier ones, so a remote journal adds one round trip to a turn
  // rather than one per append. The host stores calls in call order.
  const journal = options.world !== undefined
    ? worldJournal(options.world, options.sessionId ?? null, options.wakeAfterSeconds, (error) => {
      emit("journal.wake_failed", { error: error instanceof Error ? error.name : "Error", message: error?.message ?? "" });
    })
    : options.journal ?? null;
  let resumable = false;
  let openTurnConfigMismatch = false;
  // Follow-ups waiting for the turn ahead of them, oldest first.
  const followUps = [];
  // A follow-up this agent queued starts when the turn ahead of it ends, ahead
  // of any the journal held: those have no caller, so each waits for
  // `resume()` to start it, oldest first.
  const runNextFollowUp = (resuming = false) => {
    if (activeTurn || closing || journalFailure) return;
    const index = followUps.findIndex((entry) => (entry.held === true) === resuming);
    if (index < 0) return;
    const [next] = followUps.splice(index, 1);
    let turn;
    try {
      turn = normalizeTurn(startTurn(next.text, { [followUpInput]: { id: next.id, accepted: next.accepted } }));
    } catch (error) {
      next.rejectTurn?.(error);
      return;
    }
    next.resolveTurn?.(turn);
  };
  let journalQueue = [];
  let journalFlushScheduled = false;
  const journalPending = new Set();
  let journalFailure = null;
  // Set by `turn.cancel({ reason: "handoff" })`: the journal keeps the open
  // turn for another agent, so this one stores nothing more.
  let handedOff = false;
  const handedOffError = () => new Error("this agent handed its session off; open it again to continue");
  // Input events (`accepted:<id>`, `withdrawn:<id>`) once stored, and the
  // steer and withdraw calls waiting for them.
  const durableInputs = new Set();
  const inputWaiters = new Map();
  const waitForInput = (key) => {
    if (durableInputs.delete(key)) return Promise.resolve();
    if (journalFailure) return Promise.reject(journalFailure);
    return new Promise((resolve, reject) => {
      const waiters = inputWaiters.get(key) ?? [];
      waiters.push({ resolve, reject });
      inputWaiters.set(key, waiters);
    });
  };
  const settleInputs = (batch) => {
    for (const event of batch) {
      if (event.type !== "input_accepted" && event.type !== "input_withdrawn") continue;
      const key = `${event.type === "input_accepted" ? "accepted" : "withdrawn"}:${event.data?.id}`;
      durableInputs.add(key);
      for (const waiter of inputWaiters.get(key) ?? []) waiter.resolve();
      inputWaiters.delete(key);
    }
  };
  const rejectInputWaiters = (keys, error) => {
    for (const key of keys) {
      for (const waiter of inputWaiters.get(key) ?? []) waiter.reject(error);
      inputWaiters.delete(key);
    }
  };
  // close() reports a failure no turn or prompt call has reported yet.
  let journalFailureReported = false;
  const reportJournalFailure = () => {
    journalFailureReported = true;
    return journalFailure;
  };
  const queueJournalEvents = (events) => {
    if (journalFailure || !Array.isArray(events) || events.length === 0) return;
    if (handedOff) {
      // The agent that opens the session next decides about these inputs.
      const dropped = events
        .filter((event) => event?.type === "input_accepted" || event?.type === "input_withdrawn")
        .map((event) => `${event.type === "input_accepted" ? "accepted" : "withdrawn"}:${event.data?.id}`);
      rejectInputWaiters(dropped, handedOffError());
      return;
    }
    journalQueue.push(...events);
    // A turn notes a new config right before its first progress, a barrier:
    // the two go out in one write instead of two in a row.
    if (events.every((event) => event?.type === "session_config")) return;
    if (journalFlushScheduled) return;
    journalFlushScheduled = true;
    queueMicrotask(flushJournal);
  };
  function flushJournal() {
    journalFlushScheduled = false;
    if (journalFailure || journalQueue.length === 0) return;
    const batch = journalQueue;
    journalQueue = [];
    emit("journal.append", { events: batch.length });
    let appended;
    try {
      appended = Promise.resolve(journal.append(batch));
    } catch (error) {
      appended = Promise.reject(error);
    }
    const settled = appended.then(() => {
      settleInputs(batch);
    }, (error) => {
      // Later events would leave a gap after the failed batch.
      journalQueue = [];
      if (journalFailure) return;
      journalFailure = journalAppendError(error);
      emit("journal.error", { error: error instanceof Error ? error.name : "Error" });
      rejectInputWaiters([...inputWaiters.keys()], journalFailure);
      // Nothing the turn does from here can be saved, and after a fence the
      // session has another owner: stop the turn and its effects now.
      activeTurn?.cancel();
    }).finally(() => journalPending.delete(settled));
    journalPending.add(settled);
  }
  // The journal's own work, such as a heartbeat, ends with the agent: once,
  // after the last append settles.
  let journalClosed = null;
  function closeJournal() {
    journalClosed ??= journalSettled().catch(() => {}).then(() => {
      if (typeof journal.close === "function") return journal.close();
    });
    return journalClosed;
  }
  async function journalSettled() {
    for (;;) {
      if (journalFlushScheduled || journalQueue.length > 0) flushJournal();
      if (journalPending.size === 0) break;
      await Promise.all([...journalPending]);
    }
    if (journalFailure) throw journalFailure;
  }
  const emit = (type, detail = {}) => {
    try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
  };
  // `checkpoint` is deprecated in favor of `journal`; each use is reported once.
  const deprecatedUses = new Set();
  const deprecated = (api) => {
    if (deprecatedUses.has(api)) return;
    deprecatedUses.add(api);
    emit("deprecated", { api, replacement: "journal" });
  };
  if (options.checkpoint !== undefined) deprecated("checkpoint");
  const hostFetch = options.fetch ?? globalThis.fetch?.bind(globalThis);
  const transportFetch = async (input, init = {}) => {
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    let endpoint = String(input?.url ?? input);
    let path = null;
    try {
      const url = new URL(endpoint);
      endpoint = `${url.origin}${url.pathname}`;
      path = url.pathname;
    } catch {}
    // A supplied catalog answers the core's catalog request without the network.
    if (options.modelCatalogBody && method === "GET" && path === "/coding-agent/v1/models") {
      return new Response(options.modelCatalogBody, { status: 200, headers: { "content-type": "application/json" } });
    }
    for (let attemptIndex = 0; attemptIndex < 2; attemptIndex++) {
      const startedAt = performance.now();
      const attempt = activeTurn ? ++activeTurn.transportAttempts : attemptIndex + 1;
      if (activeTurn) {
        activeTurn.transportBytes = 0;
        activeTurn.lastTransportActivityAt = null;
      }
      emit("transport.start", { attempt, method, endpoint, model: options.model });
      try {
        if (activeTurn?.cancelled) {
          runtime.abortHostEffects();
          throw new DOMException("Aborted", "AbortError");
        }
        if (!hostFetch) throw new TypeError("fetch is unavailable");
        const response = await hostFetch(input, init);
        const headers = response.headers;
        emit("transport.response", {
          attempt,
          status: response.status,
          elapsedMs: performance.now() - startedAt,
          requestId: headers.get("x-vercel-id"),
          generationId: headers.get("x-generation-id"),
          model: headers.get("x-model-id") ?? options.model,
          provider: headers.get("x-vercel-ai-gateway-provider") ?? headers.get("x-ai-gateway-provider"),
        });
        return response;
      } catch (error) {
        const errorName = error instanceof Error ? error.name : "Error";
        const elapsedMs = performance.now() - startedAt;
        emit("transport.error", { attempt, elapsedMs, error: errorName });
        if (init.signal?.aborted) throw new DOMException("Aborted", "AbortError");
        if (attemptIndex === 1) throw error;
        emit("transport.retry", {
          attempt,
          nextAttempt: attempt + 1,
          elapsedMs,
          error: errorName,
        });
        if (init.signal?.aborted) throw new DOMException("Aborted", "AbortError");
      }
    }
    throw new Error("transport retry exhausted");
  };
  const executeHostTool = async (name, input, requestedSessionId, toolCallId) => {
    const execute = hostTools.executors.get(name);
    const turn = requestedSessionId === undefined || requestedSessionId === sessionId
      ? activeTurn
      : null;
    if (!isCurrentTurn(turn)) return { content: "", isError: true, cancelled: true };
    const controller = new AbortController();
    turn.toolControllers.add(controller);
    let onAbort;
    const aborted = new Promise((resolve) => { onAbort = () => resolve(); });
    controller.signal.addEventListener("abort", onAbort, { once: true });
    let content = "";
    let rich = false;
    let isError = false;
    try {
      if (!execute) throw new Error(`unknown host tool: ${String(name)}`);
      const execution = Promise.resolve().then(() => {
        if (controller.signal.aborted || !isCurrentTurn(turn)) return;
        // The model's call id is stable across restores of a journaled
        // session, so a tool can use it as an idempotency key.
        return execute(input, { signal: controller.signal, toolCallId: String(toolCallId ?? "") });
      });
      const value = await Promise.race([execution, aborted]);
      if (!controller.signal.aborted) {
        const normalized = hostToolContent(value);
        content = normalized.content;
        rich = normalized.rich;
        isError = normalized.isError === true;
      }
    } catch (error) {
      isError = true;
      if (error?.toolResult?.type === "libfx.tool-result") {
        try {
          const normalized = hostToolContent(error.toolResult);
          content = normalized.content;
          rich = normalized.rich;
        } catch {
          content = error instanceof Error ? error.message : String(error);
        }
      } else {
        content = error instanceof Error ? error.message : String(error);
      }
    } finally {
      controller.signal.removeEventListener("abort", onAbort);
      turn.toolControllers.delete(controller);
    }
    // Providers reject an empty error result, which would end the session.
    if (isError && content === "") content = `Tool ${String(name)} failed without a message`;
    return { content, isError, rich, cancelled: controller.signal.aborted || !isCurrentTurn(turn) };
  };
  emit("runtime.start");
  const runtimeOptions = {
    ...options,
    fetch: transportFetch,
    args: ["acp"],
    env: agentEnvironment(options),
    hostToolExecutor: executeHostTool,
    journalFlush: () => journalSettled(),
    onTransportChunk(byteLength) {
      const turn = activeTurn;
      if (!isCurrentTurn(turn) || !Number.isSafeInteger(byteLength) || byteLength <= 0) return;
      turn.transportBytes += byteLength;
      const now = performance.now();
      if (turn.lastTransportActivityAt !== null && now - turn.lastTransportActivityAt < transportActivityIntervalMs) return;
      turn.lastTransportActivityAt = now;
      emit("transport.activity", {
        attempt: turn.transportAttempts,
        chunkBytes: byteLength,
        totalBytes: turn.transportBytes,
      });
    },
  };
  const runtime = options.runtimeFactory
    ? await options.runtimeFactory(runtimeOptions)
    : await instantiate(runtimeOptions);
  emit("runtime.ready");
  const send = (message) => {
    if (closing) throw new Error("fx agent is closing");
    emit("acp.send", { message });
    if (message.method === "session/prompt" && activeTurn?.cancelled) throw new Error("Cancelled");
    runtime.write(`${JSON.stringify(message)}\n`);
    if (message.method === "session/prompt") activeTurn?.promptWritten();
  };
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    try { send({ jsonrpc: "2.0", id, method, params }); } catch (error) { pending.delete(id); reject(error); }
  });
  // Raw payloads ride beside the next frame instead of inside it. Payloads
  // left by an earlier frame that never reached the core are dropped first.
  let nextAttachmentId = 1;
  const attachBytes = (payloads) => {
    if (typeof runtime.writeAttachment !== "function") throw new Error("fx runtime does not accept binary attachments");
    runtime.discardAttachments?.();
    return payloads.map((bytes) => {
      const id = nextAttachmentId;
      nextAttachmentId = id === 0x7fffffff ? 1 : id + 1;
      runtime.writeAttachment(id, bytes);
      return id;
    });
  };
  let checkpointTail = null;
  let pendingCheckpoints = 0;
  async function takeCheckpoint() {
    if (closing) throw new Error("fx agent is closed");
    if (activeTurn) throw new Error("cannot checkpoint while a prompt is active");
    const response = await request("libfx/checkpoint", { sessionId });
    const id = response?.checkpointAttachment;
    const bytes = Number.isSafeInteger(id) && id > 0 ? runtime.takeAttachment?.(id) : null;
    if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) throw new Error("fx returned an invalid checkpoint");
    return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }
  const sendPrompt = (blocks, resuming = false, followUp = null) => {
    if (resuming) return request("session/prompt", { sessionId, prompt: [], _meta: { fx: { continueRecovery: true } } });
    const images = blocks.filter((block) => block.type === "image" && block.bytes !== undefined);
    const ids = images.length ? attachBytes(images.map((block) => block.bytes)) : [];
    let next = 0;
    const prompt = blocks.map((block) => block.type !== "image" ? block : {
      type: "image",
      mimeType: block.mimeType,
      ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
      ...(block.bytes === undefined ? {} : { _meta: { fx: { attachment: ids[next++] } } }),
    });
    // A follow-up's turn places it; the core records it as accepted first
    // when the host could not.
    const meta = followUp ? { _meta: { fx: { inputId: followUp.id, inputAccepted: followUp.accepted } } } : {};
    return request("session/prompt", { sessionId, prompt, ...meta });
  };
  runtime.exited.then((code) => {
    closing = true;
    // An agent whose core exited writes nothing more.
    if (journal) void closeJournal().catch(() => {});
    const error = runtime.error ?? new Error(`fx-core exited with code ${code} before completing the ACP request`);
    coreExitError = error;
    activeTurn?.failImagePrep(error);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
    emit("runtime.exit", { code });
  });
  runtime.setLineHandler((message, size) => {
    emit("acp.receive", { message });
    if (message.method === "libfx/journal_append") {
      if (journal && message.params?.sessionId === sessionId) {
        queueJournalEvents(message.params.events);
      }
      return;
    }
    if (message.method === "session/update") {
      if (message.params.sessionId === sessionId) return activeTurn?.push(message.params.update, size);
      return;
    }
    void handleControlMessage(message).catch((error) => runtime.abort(error));
  });
  async function handleControlMessage(message) {
    if (message.method === "session/request_permission") {
      const turn = activeTurn;
      if (!isCurrentTurn(turn)) return;
      emit("permission.request", { request: message.params });
      if (!isCurrentTurn(turn)) return;
      let optionId = null;
      try { optionId = await options.onPermission?.(message.params); } catch {}
      if (!isCurrentTurn(turn)) return;
      emit("permission.resolve", { optionId });
      if (!isCurrentTurn(turn)) return;
      send({ jsonrpc: "2.0", id: message.id, result: optionId ? { outcome: { outcome: "selected", optionId } } : { outcome: { outcome: "cancelled" } } });
      return;
    }
    if (message.method === "libfx/journal_flush") {
      // Every append the core sent before this request is already queued.
      let failure = null;
      try { await journalSettled(); } catch (error) { failure = error; }
      if (closing) return;
      send(failure
        ? { jsonrpc: "2.0", id: message.id, error: { code: -32000, message: failure.message } }
        : { jsonrpc: "2.0", id: message.id, result: {} });
      return;
    }
    if (message.method === "libfx/tool_call") {
      const { content, isError, rich, cancelled } = await executeHostTool(
        message.params?.name,
        message.params?.input,
        message.params?.sessionId,
        message.params?.toolCallId,
      );
      if (cancelled || closing) return;
      const response = { jsonrpc: "2.0", id: message.id, result: { content, isError, ...(rich ? { contentType: "rich" } : {}) } };
      if (rich && encoder.encode(JSON.stringify(response)).length + 1 > maxPromptFrameBytes) {
        const result = JSON.parse(content);
        response.result.content = JSON.stringify({ ...result, images: omitReferencedImageData(result.images) });
      }
      if (encoder.encode(JSON.stringify(response)).length + 1 > 8 * 1024 * 1024) {
        response.result = { content: "Host tool result exceeded the response frame limit", isError: true };
      }
      send(response);
      return;
    }
    const waiter = pending.get(message.id); if (!waiter) return; pending.delete(message.id);
    if (message.error) waiter.reject(agentRpcError(message.error)); else waiter.resolve(message.result);
  }
  try {
    await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        ...(hostTools.descriptors.length || instructions
          ? { libfx: { tools: hostTools.descriptors, instructions } }
          : {}),
      },
    });

    // A journal may name its session; the id stays the same across restores,
    // so gateway session affinity and caching survive them.
    const loaded = journal ? journalLoaded(await journal.load()) : null;
    const requestedSessionId = options.sessionId ?? loaded?.sessionId ?? null;
    if (loaded?.sessionId && options.sessionId && loaded.sessionId !== options.sessionId) {
      throw new TypeError("sessionId does not match the journal's session");
    }
    const sessionResult = await request("libfx/new", requestedSessionId === null ? {} : { sessionId: requestedSessionId });
    sessionId = sessionResult.sessionId;
    if (initialCheckpoint) {
      const [checkpointAttachment] = attachBytes([initialCheckpoint]);
      await request("libfx/restore", { sessionId, checkpointAttachment });
    }
    if (journal) {
      const { events } = loaded;
      const params = { sessionId, configHash: await configHashOf(instructions, options.model, hostTools.descriptors) };
      if (events.length > 0) {
        const bytes = encoder.encode(JSON.stringify(withoutSupersededProgress(events)));
        if (bytes.byteLength > maxJournalBytes) throw journalLoadError("libfx journal is too large", "FX_JOURNAL_TOO_LARGE");
        [params.journalAttachment] = attachBytes([bytes]);
      }
      const opened = await request("libfx/journal_open", params).catch((error) => {
        const message = error?.message ?? "";
        if (/newer fx/.test(message)) throw new FxJournalVersionError(message);
        const code = journalOpenErrorCodes.get(message);
        if (code) throw journalLoadError(message, code, error);
        throw error;
      });
      resumable = opened?.resumable === true;
      openTurnConfigMismatch = resumable && opened?.configMatches === false;
      // Follow-ups the journal holds, as accepted; each waits for `resume()`.
      for (const held of Array.isArray(opened?.followUps) ? opened.followUps : []) {
        followUps.push({ id: held.id, text: held.text, accepted: true, held: true });
      }
      emit("journal.open", { events: events.length, turns: opened?.turns, resumable });
    }
  } catch (error) {
    closing = true;
    try { runtime.abortHostEffects(); } catch {}
    try { runtime.closeStdin(); } catch {}
    try { await runtime.exited; } catch {}
    throw error;
  }

  const agent = {
    // The session's id: for a World session, its run id.
    get sessionId() {
      return sessionId;
    },
    prompt(input, promptOptions = {}) {
      if (closing) throw new Error("fx agent is closed");
      if (journalFailure) throw reportJournalFailure();
      if (handedOff) throw handedOffError();
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      // A new prompt ends a turn the last process left open as interrupted.
      resumable = false;
      return normalizeTurn(startTurn(input, promptOptions));
    },
    /**
     * Continues the turn the last process left open, with no new input, and
     * returns it; returns null when the journal holds no open turn. The
     * model is told the session was interrupted; calls that were running
     * come back answered as possibly run.
     */
    resume(promptOptions = {}) {
      if (closing) throw new Error("fx agent is closed");
      if (journalFailure) throw reportJournalFailure();
      if (handedOff) throw handedOffError();
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      if (resumable) {
        if (openTurnConfigMismatch) {
          throw new FxConfigMismatchError("the open turn started under other instructions, tools or model; prompt() ends it as interrupted");
        }
        resumable = false;
        return normalizeTurn(startTurn(null, { ...promptOptions, [resumeTurn]: true }));
      }
      // With no open turn, the follow-ups the journal held are the work left.
      const next = followUps.find((entry) => entry.held);
      if (!next) return null;
      let started = null;
      const resolveTurn = next.resolveTurn;
      next.resolveTurn = (turn) => {
        started = turn;
        resolveTurn?.(turn);
      };
      runNextFollowUp(true);
      return started;
    },
    /**
     * Queues `input` to run as its own turn after the current one, or at once
     * when no turn is running. Returns a promise for that turn, carrying the
     * follow-up's `id` and `accepted`, which resolves `{ id }` once a
     * journal holds it.
     */
    followUp(input) {
      if (closing) return Promise.reject(new Error("fx agent is closed"));
      if (journalFailure) return Promise.reject(reportJournalFailure());
      if (handedOff) return Promise.reject(handedOffError());
      let text;
      try { text = normalizeSteeringInput(input); } catch (error) { return Promise.reject(error); }
      const id = `in_${crypto.randomUUID()}`;
      const entry = { id, text, accepted: false };
      const started = new Promise((resolve, reject) => { entry.resolveTurn = resolve; entry.rejectTurn = reject; });
      let accepted;
      if (journal && activeTurn && typeof runtime.steer !== "function") {
        // The native core records it now, ahead of the turn that will run it.
        entry.accepted = true;
        accepted = request("libfx/follow_up", { sessionId, id, text })
          .then(() => waitForInput(`accepted:${id}`))
          .then(() => ({ id }), (error) => {
            const index = followUps.indexOf(entry);
            if (index >= 0) followUps.splice(index, 1);
            entry.rejectTurn(error);
            throw error;
          });
      } else {
        // Its own turn records it with the first progress, a barrier; it is
        // accepted once that is stored.
        accepted = started.then(() => (journal ? waitForInput(`accepted:${id}`) : undefined)).then(() => ({ id }));
      }
      followUps.push(entry);
      void accepted.catch(() => {});
      queueMicrotask(runNextFollowUp);
      started.id = id;
      started.accepted = accepted;
      return started;
    },
    /** Deprecated: pass a `journal` instead. */
    checkpoint() {
      deprecated("checkpoint");
      // One checkpoint runs at a time: each holds an outbound attachment until
      // it is taken, and the native table holds only a few. An idle call still
      // sends its request before returning, ahead of a later prompt(). The slot
      // is claimed before that send, so a call from an event handler during it
      // still waits. The count drops before the caller's own reaction to `run`,
      // so a call made right after awaiting the previous one is idle.
      const previous = pendingCheckpoints > 0 ? checkpointTail : null;
      pendingCheckpoints++;
      let release;
      checkpointTail = new Promise((resolve) => { release = resolve; });
      const run = previous ? previous.then(takeCheckpoint) : takeCheckpoint();
      const settle = () => { pendingCheckpoints--; release(); };
      run.then(settle, settle);
      return run;
    },
    async close() {
      if (closing) {
        await runtime.exited;
        if (journal) await closeJournal();
        return;
      }
      const turn = activeTurn;
      turn?.cancel();
      if (turn) await turn.result.catch(() => {});
      closing = true;
      // A journal keeps these; the next `resume()` runs them.
      for (const entry of followUps.splice(0)) entry.rejectTurn?.(new Error("fx agent closed before the follow-up ran"));
      runtime.closeStdin();
      await runtime.exited;
      // Every append the session started has landed, or close reports why.
      if (journal) {
        let failure = null;
        try {
          await journalSettled();
        } catch {
          if (!journalFailureReported) failure = reportJournalFailure();
        }
        await closeJournal();
        if (failure) throw failure;
      }
    },
  };
  return agent;

  function normalizeTurn(rawTurn) {
    const toolNames = new Map();
    const started = new Set();
    const eventFor = (update) => {
      if (update.sessionUpdate === "agent_message_chunk") {
        const delta = update.content?.text;
        if (!delta || delta.startsWith("[context]")) return null;
        return { type: "text_delta", delta };
      }
      if (update.sessionUpdate === "agent_thought_chunk") {
        const delta = update.content?.text;
        return delta ? { type: "reasoning_delta", delta } : null;
      }
      if (update.sessionUpdate === "user_message_chunk" && update.content?.type === "text") {
        return { type: "user_message", text: update.content.text };
      }
      if (update.sessionUpdate === "tool_call") {
        toolNames.set(update.toolCallId, update.name || update.toolName || update.title || "tool");
        if (started.has(update.toolCallId)) return null;
        started.add(update.toolCallId);
        return {
          type: "tool_start",
          id: update.toolCallId,
          name: toolNames.get(update.toolCallId),
          ...toolStartInput(update.rawInput),
        };
      }
      if (update.sessionUpdate === "tool_call_update" &&
        (update.status === "completed" || update.status === "failed")) {
        const content = update.content?.find((entry) => entry.content?.type === "text")?.content?.text;
        return {
          type: "tool_end",
          id: update.toolCallId,
          name: toolNames.get(update.toolCallId) || "tool",
          ...(content === undefined ? {} : { content }),
          isError: update.status === "failed",
        };
      }
      return null;
    };
    const result = rawTurn.result.then((value) => ({
      stopReason: value.stopReason,
      usage: normalizeTurnUsage(value.usage),
    }));
    void result.catch(() => {});
    return {
      cancel(cancelOptions) { rawTurn.cancel(cancelOptions); },
      steer(input) { return rawTurn.steer(normalizeSteeringInput(input)); },
      withdraw(id) { return rawTurn.withdraw(id); },
      [Symbol.asyncIterator]() {
        const iterator = (async function* () {
          for await (const update of rawTurn) {
            const event = eventFor(update);
            if (event) yield event;
          }
        })();
        return {
          next(value) { return iterator.next(value); },
          return(value) { rawTurn.cancel(); return iterator.return(value); },
          throw(error) { rawTurn.cancel(); return iterator.throw(error); },
          [Symbol.asyncIterator]() { return this; },
        };
      },
      result,
    };
  }

  function normalizeTurnUsage(usage) {
    const result = {};
    if (Number.isSafeInteger(usage?.inputTokens)) result.inputTokens = usage.inputTokens;
    if (Number.isSafeInteger(usage?.outputTokens)) result.outputTokens = usage.outputTokens;
    if (Number.isSafeInteger(usage?.cacheReadTokens)) result.cacheReadTokens = usage.cacheReadTokens;
    if (Number.isSafeInteger(usage?.cacheWriteTokens)) result.cacheWriteTokens = usage.cacheWriteTokens;
    if (Number.isSafeInteger(usage?.reasoningTokens)) result.reasoningTokens = usage.reasoningTokens;
    return result;
  }

  // The input object rides the event when it fits the preview budget; larger
  // inputs become a bounded JSON prefix plus an explicit marker.
  function toolStartInput(rawInput) {
    if (rawInput === undefined || rawInput === null) return {};
    const serialized = JSON.stringify(rawInput);
    if (serialized === undefined) return {};
    const bytes = encoder.encode(serialized);
    if (bytes.length <= maxToolStartInputBytes) return { input: rawInput };
    return { inputTruncated: true, inputPreview: decoder.decode(utf8Prefix(bytes, maxToolStartInputBytes)) };
  }

  function startTurn(input, promptOptions) {
    const resizeImage = options.resizeImage;
    const resuming = promptOptions[resumeTurn] === true;
    const followUp = promptOptions[followUpInput] ?? null;
    const normalized = resuming ? [] : normalizePromptInput(input, { deferImageLimits: resizeImage !== undefined });
    const hasPixels = normalized.some((block) => block.type === "image" && block.data !== undefined);
    // Blob reads and resizeImage run before the prompt frame is sent.
    const asyncImages = hasPixels && (resizeImage !== undefined ||
      normalized.some((block) => block.type === "image" && block.source === "blob"));
    // resizeImage decides the final image sizes, so they are counted after it runs.
    checkPromptFrameSize(normalized, resizeImage === undefined);
    // Snapshot caller-owned bytes, which could change before an async send.
    const prompt = asyncImages
      ? normalized.map((block) => block.type === "image" && block.source === "bytes" ? { ...block, data: block.data.slice() } : block)
      : preparePromptImages(normalized);
    const signal = promptOptions.signal;
    if (signal !== undefined && (typeof signal?.addEventListener !== "function" || typeof signal?.removeEventListener !== "function")) throw new TypeError("prompt signal must be an AbortSignal");
    const queue = [];
    const waiters = [];
    let queuedBytes = 0;
    let resumeOutput;
    let iteratorTaken = false;
    let terminalError;
    let reportedPressure = false;
    let discardedBytes = 0;
    let cancelImagePrep = null;
    let rejectImagePrep = null;
    let resolvePromptStart = null;
    const promptStarted = asyncImages ? new Promise((resolve) => { resolvePromptStart = resolve; }) : null;
    let pendingSteeringCount = 0;
    let pendingSteeringBytes = 0;
    // This turn's steers: whether each reached the core, or was withdrawn first.
    const steers = new Map();
    const withdrawnSteer = (id) => Object.assign(new Error("steer was withdrawn"), { code: "FX_STEER_WITHDRAWN", id });
    const startSteer = (id, text) => {
      if (finished || cancelled || activeTurn !== turn) {
        return Promise.reject(new Error("no prompt is running"));
      }
      if (closing) return Promise.reject(coreExitError ?? new Error("fx agent is closing"));
      const local = { sent: false, withdrawn: false };
      steers.set(id, local);
      const apply = () => {
        if (local.withdrawn) return Promise.resolve({ id, withdrawn: true });
        if (finished || cancelled || activeTurn !== turn) {
          return Promise.reject(new Error("no prompt is running"));
        }
        if (closing) return Promise.reject(coreExitError ?? new Error("fx agent is closing"));
        try {
          local.sent = true;
          const accepted = () => (journal ? waitForInput(`accepted:${id}`) : Promise.resolve());
          if (typeof runtime.steer === "function") {
            runtime.steer(text, id);
            void turn.push({
              sessionUpdate: "user_message_chunk",
              content: { type: "text", text },
            });
            // The web core accepts it when it takes it at the next boundary.
            return accepted().then(() => ({ id }), (error) => (error?.code === "FX_STEER_WITHDRAWN" ? { id, withdrawn: true } : Promise.reject(error)));
          }
          return request("libfx/steer", { sessionId, text, id }).then(accepted).then(() => ({ id }));
        } catch (error) {
          return Promise.reject(error);
        }
      };
      if (!resolvePromptStart) return apply();
      const bytes = encoder.encode(text).length;
      if (pendingSteeringCount >= maxSteeringMessages || bytes > maxSteeringQueueBytes - pendingSteeringBytes) {
        return Promise.reject(new Error("steering queue is full"));
      }
      pendingSteeringCount++;
      pendingSteeringBytes += bytes;
      return promptStarted.then((started) => {
        if (coreExitError && !cancelled) throw coreExitError;
        return started === true ? apply() : Promise.reject(started instanceof Error ? started : new Error("no prompt is running"));
      }).finally(() => { pendingSteeringCount--; pendingSteeringBytes -= bytes; });
    };
    const toolControllers = new Set();
    let finished = false;
    let cancelled = false;
    const turn = {
      push(update, size = encoder.encode(JSON.stringify(update)).length) {
        if (cancelled || finished) { discardedBytes += size; return; }
        if (size > maxCoreMessageBytes) throw new RangeError("core output message exceeds 64 MiB");
        if (queue.length && (queue.length >= maxUnreadEvents || size > maxUnreadEventBytes - queuedBytes)) {
          const capacity = new Promise((resolveCapacity) => { resumeOutput = resolveCapacity; });
          if (!reportedPressure) {
            reportedPressure = true;
            emit("output.backpressure", { bufferedBytes: queuedBytes, bufferedEvents: queue.length });
          }
          return capacity.then(() => turn.push(update, size));
        }
        const waiter = waiters.shift();
        if (waiter) waiter.resolve({ value: update, done: false });
        else { queue.push({ update, size }); queuedBytes += size; }
      },
      toolControllers,
      transportAttempts: 0,
      transportBytes: 0,
      lastTransportActivityAt: null,
      get cancelled() { return cancelled; },
      failImagePrep(error) {
        rejectImagePrep?.(error);
        rejectImagePrep = null;
        cancelImagePrep = null;
      },
      promptWritten() {
        resolvePromptStart?.(true);
        resolvePromptStart = null;
      },
      // Resolves `{ id }` once the steer is accepted: in a journaled session,
      // once its acceptance is stored. The promise carries `id` at once.
      steer(text) {
        const id = `in_${crypto.randomUUID()}`;
        const steered = startSteer(id, text).then((value) => value ?? { id });
        steered.id = id;
        return steered;
      },
      // 'withdrawn' when the model never saw the steer, else 'already_placed'.
      withdraw(id) {
        const local = steers.get(id);
        if (!local) return Promise.resolve("already_placed");
        if (!local.sent) {
          local.withdrawn = true;
          return Promise.resolve("withdrawn");
        }
        if (typeof runtime.withdrawSteering === "function") {
          if (!runtime.withdrawSteering(id)) return Promise.resolve("already_placed");
          local.withdrawn = true;
          rejectInputWaiters([`accepted:${id}`], withdrawnSteer(id));
          return Promise.resolve("withdrawn");
        }
        return request("libfx/withdraw", { sessionId, id }).then(async (response) => {
          if (response?.result !== "withdrawn") return "already_placed";
          if (journal) await waitForInput(`withdrawn:${id}`);
          return "withdrawn";
        });
      },
      cancel(cancelOptions = {}) {
        const reason = cancelOptions?.reason;
        if (reason !== undefined && reason !== "handoff") throw new TypeError('cancel() reason must be "handoff" when given');
        if (reason === "handoff" && !journal) throw new TypeError("a handoff needs a journal to keep the turn in");
        if (finished || cancelled) return;
        if (reason === "handoff") {
          handedOff = true;
          // The journal keeps queued follow-ups for the next agent.
          for (const entry of followUps.splice(0)) entry.rejectTurn?.(handedOffError());
        }
        cancelled = true;
        cancelImagePrep?.();
        cancelImagePrep = null;
        rejectImagePrep = null;
        resolvePromptStart?.(false);
        resolvePromptStart = null;
        runtime.closeSteering?.();
        resumeOutput?.();
        resumeOutput = null;
        if (!closing) send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
        for (const controller of toolControllers) controller.abort();
        runtime.abortHostEffects();
      },
      [Symbol.asyncIterator]() {
        if (iteratorTaken) throw new Error("a turn has only one event consumer");
        iteratorTaken = true;
        return {
          next() {
            if (queue.length) {
              const { update, size } = queue.shift();
              queuedBytes -= size;
              resumeOutput?.();
              resumeOutput = null;
              return Promise.resolve({ value: update, done: false });
            }
            if (terminalError) return Promise.reject(terminalError);
            if (finished) return Promise.resolve({ done: true });
            return new Promise((resolve, reject) => waiters.push({ resolve, reject }));
          },
          return() { turn.cancel(); return Promise.resolve({ done: true }); },
        };
      },
    };
    if (signal?.aborted) {
      resolvePromptStart?.(false);
      resolvePromptStart = null;
      finished = true;
      turn.result = Promise.resolve({ stopReason: "cancelled" });
      return turn;
    }
    activeTurn = turn;
    runtime.openSteering?.();
    const abort = () => turn.cancel();
    signal?.addEventListener("abort", abort, { once: true });
    const imagePrepCancelled = asyncImages ? new Promise((resolve, reject) => {
      cancelImagePrep = () => resolve(null);
      rejectImagePrep = reject;
    }) : null;
    let response;
    if (asyncImages) {
      response = Promise.race([
        Promise.resolve().then(() => materializePromptImages(prompt, () => cancelled || closing, resizeImage)),
        imagePrepCancelled,
      ]).then((prepared) => {
        cancelImagePrep = null;
        rejectImagePrep = null;
        if (coreExitError && !cancelled) throw coreExitError;
        if (prepared === null || cancelled || closing) {
          resolvePromptStart?.(false);
          resolvePromptStart = null;
          return { stopReason: "cancelled" };
        }
        return sendPrompt(prepared, false, followUp);
      });
    } else {
      try { response = sendPrompt(prompt, resuming, followUp); } catch (error) { response = Promise.reject(error); }
    }
    // Appends after a turn's first progress are lazy, so the result does not
    // wait for them; `close()` does. A failure already seen fails the turn.
    turn.result = response
      .then((value) => {
        if (journalFailure) throw reportJournalFailure();
        return { stopReason: cancelled ? "cancelled" : value.stopReason, usage: value.usage };
      })
      .catch(async (error) => {
        cancelImagePrep = null;
        rejectImagePrep = null;
        resolvePromptStart?.(error);
        resolvePromptStart = null;
        // A failed append is why the core stopped, including when the turn
        // was cancelled because of it; report the host's error.
        if (journalFailure) {
          terminalError = reportJournalFailure();
          throw terminalError;
        }
        if (cancelled && error.message === "Cancelled") return { stopReason: "cancelled" };
        terminalError = error;
        throw terminalError;
      })
      .finally(() => {
        finished = true;
        resumeOutput?.();
        resumeOutput = null;
        signal?.removeEventListener("abort", abort);
        if (activeTurn === turn) activeTurn = null;
        // A steer still queued when the turn ends never reached the model.
        if (typeof runtime.withdrawSteering === "function") {
          const untaken = [...steers.keys()].filter((id) => runtime.withdrawSteering(id));
          rejectInputWaiters(untaken.map((id) => `accepted:${id}`), new Error("the turn ended before it took the steer"));
        }
        for (const id of steers.keys()) {
          durableInputs.delete(`accepted:${id}`);
          durableInputs.delete(`withdrawn:${id}`);
        }
        queueMicrotask(runNextFollowUp);
        runtime.closeSteering?.();
        toolControllers.clear();
        if (discardedBytes) emit("output.discarded", { reason: "cancelled", bytes: discardedBytes });
        for (const waiter of waiters.splice(0)) {
          if (terminalError) waiter.reject(terminalError);
          else waiter.resolve({ done: true });
        }
      });
    if (signal?.aborted) turn.cancel();
    void turn.result.catch(() => {});
    return turn;
  }
}
