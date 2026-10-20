import { CoreOutput, maxCoreMessageBytes } from "./core-output.js";
import { codexSubscription } from "./chatgpt.js";
import { customProviderDefinition, customProviderSpec } from "./custom-provider.js";
import { grokSubscription } from "./grok.js";
import { createSubscriptionAuthorizer, credentialMemory, refreshFailed } from "./subscription.js";
import { loadModule } from "./wasm-module.js";
import { toolObservation } from "./tool-observation.js";

// Providers that run on a user's plan, authorized by the host's credentials.
const subscriptionProviders = new Set(["codex", "grok"]);

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const strictDecoder = new TextDecoder("utf-8", { fatal: true });
const workspaceInfoLimit = 4 * 1024;
const workspaceCommandLimit = 64 * 1024;
const workspaceOutputLimit = 64 * 1024;
// Matches max_instruction_file_bytes and max_instruction_path_bytes in js_host_workspace.zig.
const workspaceInstructionFileLimit = 1024 * 1024;
const workspaceInstructionPathLimit = 4 * 1024;
const workspaceReadTimeoutMs = 10_000;
const maxInstructionsBytes = 64 * 1024;
const maxApiKeyBytes = 64 * 1024;
const maxModelBytes = 1024;
// Matches the kernel's ReasoningEffort.max_name_bytes.
const maxEffortBytes = 64;
const maxUrlBytes = 16 * 1024;
// The answer a resumed turn gives a call its crash left running; matches
// unfinished_tool_output in session_adapter.zig.
const unfinishedToolOutput = "fx stopped while this tool was running, so it may have partly run. Check its effects before running it again.";
const maxModelCatalogBytes = 4 * 1024 * 1024;
const maxModelCatalogEntries = 10_000;
const streamReadsPerTaskYield = 32;
const transportActivityIntervalMs = 250;
const maxUnreadEventBytes = 1024 * 1024;
const maxUnreadEvents = 256;
// Prompt images travel as raw bytes beside the ACP frame and are base64
// encoded only in the model request. An image may use 5 MiB of encoded
// request data, and a prompt's images 8 MiB, so the raw limits are 3/4 of that.
// The kernel still validates content and media type, and holds a prompt to
// these limits too: `max_libfx_prompt_images` and
// `max_libfx_prompt_images_bytes` in src/core/images/image_attachments.zig
// must match them.
const maxPromptImages = 8;
const maxPromptImageDataBytes = 5 * 1024 * 1024;
const maxPromptImagesDataBytes = 8 * 1024 * 1024;
const maxPromptImageBytes = (maxPromptImageDataBytes / 4) * 3;
const maxPromptImagesBytes = (maxPromptImagesDataBytes / 4) * 3;
// Matches the core's limit on one tool result's images (max_tool_images in
// src/core/images/image_data.zig).
const maxToolResultImages = 8;
// Matches the core's kernel checkpoint limit (max_checkpoint_bytes), which
// holds a session's history with its images, and its turn limit
// (max_history_turns).
const maxCheckpointBytes = 32 * 1024 * 1024;
const maxCheckpointTurns = 1024;
// How the core's answer to `checkpoint()` begins when the conversation is
// past a checkpoint's limits (server.zig checkpoint_too_large).
const checkpointTooLargePrefix = "libfx checkpoint is too large: ";
// Why the core skipped a checkpoint save after a turn, by the reason it
// gives (server.zig SnapshotSkip), for the checkpoint.error the host hears.
const checkpointSkips = {
  too_large: `no checkpoint was saved: the conversation is over the ${maxCheckpointBytes / (1024 * 1024)} MiB a checkpoint holds, so each load reads every record since the last checkpoint`,
  too_many_turns: `no checkpoint was saved: the conversation has more than the ${maxCheckpointTurns} turns a checkpoint holds, so each load reads every record since the last checkpoint`,
  invalid: "no checkpoint was saved: the conversation could not be written as one, so each load reads every record since the last checkpoint",
};
// Matches the native attachment table (src/napi_core_main.zig): at most 8
// attachments wait to be taken, each up to one kernel checkpoint, and twice
// that together, since a journal opens from its snapshot and its records
// attached at once. An open stages a session's saved images in batches the
// table holds.
const maxPendingAttachments = 8;
const maxPendingAttachmentBytes = 2 * maxCheckpointBytes;
// The image store reads an open runs at once: a batch's worth, so a batch is
// read while the one before it is staged.
const maxImageReads = maxPendingAttachments;
const maxOutboundAttachments = 4;
// Matches the core's journal load limit (journal.max_load_bytes).
const maxJournalBytes = 32 * 1024 * 1024;
// The core's ACP reader drops frames over 8 MiB without a request id to answer
// (jsonrpc frame_resource_byte_limit), so the SDK must never emit one. Prompt
// images travel beside the frame, so only text, resources and metadata count.
// The envelope allowance covers what session/prompt adds around its blocks at
// its longest: the JSON-RPC envelope and request id, a 255-byte session id,
// and `_meta.fx` with a turn id, an input id and a yield time.
export const maxPromptFrameBytes = 8 * 1024 * 1024;
const promptFrameEnvelopeBytes = 1024;
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

// What a caller that names no AI Gateway credential does about it (QUAL-18).
function missingGatewayKey(factory) {
  return new TypeError(`no AI Gateway credentials were found: pass apiKey, an AI Gateway API key or a Vercel OIDC token, to ${factory}()`);
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

// The model choice in `options`, a model object or a model ID with the
// deprecated top-level options, as `{ model, effort, fast, ultrafast }`.
export function normalizeModelChoice(options) {
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
    return {
      model: boundedString(model.id, "model.id", maxModelBytes, true),
      effort: normalizeEffort(model.effort),
      fast: normalizeFast(model.fast),
      ultrafast: normalizeUltrafast(model.ultrafast),
    };
  }
  return {
    model: boundedString(options.model, "model", maxModelBytes, false),
    effort: normalizeEffort(options.effort),
    fast: normalizeFast(options.fast),
    ultrafast: normalizeUltrafast(options.ultrafast),
  };
}

export function normalizeAgentOptions(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("createFxEngine() options must be an object");
  }
  const options = { ...value };
  if (options.hooks !== undefined) {
    const hooks = options.hooks;
    if (!hooks || typeof hooks !== "object" || Array.isArray(hooks) || typeof hooks.onEvent !== "function") {
      throw new TypeError("hooks must be an object with onEvent()");
    }
    if (hooks.onError !== undefined && typeof hooks.onError !== "function") throw new TypeError("hooks.onError must be a function");
    if (hooks.captureContent !== undefined && typeof hooks.captureContent !== "boolean") throw new TypeError("hooks.captureContent must be a boolean");
    options.hooks = {
      captureContent: hooks.captureContent === true,
      onEvent: hooks.onEvent.bind(hooks),
      ...(hooks.onError === undefined ? {} : { onError: hooks.onError.bind(hooks) }),
      ...(hooks.parent === undefined ? {} : { parent: { ...hooks.parent } }),
    };
    if (options.hooks.parent !== undefined) {
      for (const name of ["rootSessionId", "sessionId", "turnId", "callId"]) {
        if (typeof options.hooks.parent[name] !== "string" || options.hooks.parent[name].length === 0 || options.hooks.parent[name].length > 1024) throw new TypeError(`hooks.parent.${name} must be a bounded identity`);
      }
    }
  }
  if (Object.hasOwn(options, "env")) {
    throw new TypeError("createFxEngine() does not accept env; pass apiKey and model directly");
  }
  // Derived from the caller's provider every time, so normalizing again agrees.
  const custom = options.provider !== null && typeof options.provider === "object"
    ? customProviderDefinition(options.provider)
    : undefined;
  if (!custom && options.provider !== undefined && options.provider !== "gateway" && !subscriptionProviders.has(options.provider)) {
    throw new TypeError("provider must be \"gateway\", \"codex\", \"grok\" or a custom provider { name, baseUrl }");
  }
  options.customProvider = custom;
  options.providerName = custom ? custom.name : options.provider;
  const subscription = subscriptionProviders.has(options.provider);
  // Gateway needs its key; every other provider runs on the host's
  // credentials. An engine reads no environment, so the key comes only from
  // here.
  if (options.apiKey === undefined && !subscription && !custom) throw missingGatewayKey("createFxEngine");
  options.apiKey = boundedString(options.apiKey, "apiKey", maxApiKeyBytes, false);
  if (subscription && typeof options.credentials !== "function") {
    throw new TypeError(`provider "${options.provider}" needs a credentials() function`);
  }
  if (!subscription && !custom && options.credentials !== undefined) {
    throw new TypeError("credentials needs provider \"codex\", \"grok\" or a custom provider");
  }
  // A custom provider's key is never refreshed, so it has no onCredentials or refreshLock.
  for (const name of ["onCredentials", "refreshLock"]) {
    if (!subscription && options[name] !== undefined) throw new TypeError(`${name} needs provider "codex" or "grok"`);
  }
  for (const name of ["credentials", "onCredentials", "refreshLock", "fetch", "onEvent"]) {
    if (options[name] !== undefined && typeof options[name] !== "function") throw new TypeError(`${name} must be a function`);
  }
  Object.assign(options, normalizeModelChoice(options));
  // fx's default model is a Gateway id. Codex, Grok, and a custom provider
  // name their own models, so each needs one, as the fx CLI asks for.
  if (custom && options.model === undefined) throw new TypeError("a custom provider needs a model");
  if (subscription && options.model === undefined) {
    throw new TypeError(`provider "${options.provider}" needs a model; fx's default model is an AI Gateway id`);
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
  if (options.persistence !== undefined) {
    const persistence = options.persistence;
    if (!persistence || typeof persistence !== "object" ||
      typeof persistence.load !== "function" || typeof persistence.append !== "function" ||
      (persistence.saveCheckpoint !== undefined && typeof persistence.saveCheckpoint !== "function")) {
      throw new TypeError("persistence must be an object with load(), append() and, optionally, saveCheckpoint()");
    }
    if (options.checkpoint !== undefined) {
      throw new TypeError("persistence cannot be combined with checkpoint");
    }
  }
  if (options.checkpointAfterBytes !== undefined) {
    if (options.persistence === undefined) throw new TypeError("checkpointAfterBytes needs persistence");
    if (!Number.isSafeInteger(options.checkpointAfterBytes) || options.checkpointAfterBytes < 0) {
      throw new RangeError("checkpointAfterBytes must be a non-negative integer");
    }
  }
  return options;
}

// Keys for libfx's own session worker; symbols keep them off the engine's
// public surface.
export const engineInternals = Symbol.for("libfx.engineInternals");
export const journalMarksWanted = Symbol.for("libfx.journalMarks");
// The Gateway catalog an agent fetched, a Map shared by every engine the
// agent opens, so the agent fetches it once for all its sessions (API-15).
export const catalogMemory = Symbol.for("libfx.catalogMemory");
// What a session worker that stores its inputs itself gives its engine: a
// function the core waits on before a turn ends, which hands the running turn
// the inputs stored since the worker last read them. A steer sent while the
// reply streamed then continues the turn (API-50).
export const turnEndInputs = Symbol.for("libfx.turnEndInputs");
// A persistence's image store, `{ put(name, bytes), get(name) }`, which keeps
// each image once, named by the SHA-256 of its bytes, so records and
// checkpoints only name it. Durable sessions give one to the engines they
// run; without it, images stay inline.
export const persistenceImages = Symbol.for("libfx.persistenceImages");
// `{ images, bytes }`: a smaller image window than the core's, the newest
// images a session with an image store keeps, so tests can reach its edge.
// The core's is one model request's budget, 100 images whose base64 takes at
// most 30 MiB; `bytes` counts base64 too.
const imageWindowLimits = Symbol.for("libfx.imageWindow");
// Marks an error the core answered a request with, as opposed to one from a
// core that stopped answering.
export const coreAnswered = Symbol.for("libfx.coreAnswered");
// `{ name, store }`: the durable agent an engine runs turns for, which the
// Node.js loader counts its native runtime toward (`runtimeShareKey` in
// node.js). An engine created without one counts toward the engines its
// JavaScript realm created outside an agent.
export const runtimeAgent = Symbol.for("libfx.runtimeAgent");

/**
 * Another writer took over the session after this agent loaded it. A
 * persistence store rejects an append whose `expected` cursor is not its head
 * with this error; the agent stops its turn at once and makes no further
 * effect or write. Check `code === "FX_FENCED"` when the error may come from
 * another copy of libfx.
 */
export class FxFencedError extends Error {
  constructor(message) {
    super(message);
    this.name = "FxFencedError";
    this.code = "FX_FENCED";
  }
}

/** The journal, or the `checkpoint` option, was written by a newer libfx. */
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
  ["libfx journal images are too large", "FX_JOURNAL_TOO_LARGE"],
  ["Invalid libfx journal images", "FX_JOURNAL_INVALID"],
  ["libfx image does not match its name", "FX_JOURNAL_IMAGE_MISSING"],
]);

// An image's name in a persistence's image store: the lowercase hex SHA-256
// of its bytes, as the core names it.
async function imageName(bytes) {
  const digest = new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
  let name = "";
  for (const byte of digest) name += byte.toString(16).padStart(2, "0");
  return name;
}

function imageMissingError(name, cause) {
  const error = journalLoadError(`libfx journal names an image the store does not hold: ${name}`, "FX_JOURNAL_IMAGE_MISSING", cause);
  error.image = name;
  return error;
}

/**
 * A persistence store that keeps a session's records and its latest
 * checkpoint in memory, for tests and for hosts that copy them elsewhere.
 * `records` is the stored list, oldest first. An append whose `expected`
 * cursor is not the last record's is refused, so a second agent cannot write
 * the same session, and an append that repeats a stored write's
 * `idempotencyKey` returns that write's cursor.
 */
export function createMemoryPersistence() {
  const records = [];
  let checkpoint = null;
  const head = () => records.at(-1)?.cursor ?? null;
  return {
    records,
    get checkpoint() {
      return checkpoint;
    },
    async load() {
      const after = checkpoint ? records.findIndex((record) => record.cursor === checkpoint.through) + 1 : 0;
      return {
        ...(checkpoint ? { checkpoint: { data: checkpoint.data.slice(), through: checkpoint.through } } : {}),
        journal: records.slice(after).map(({ cursor, data }) => ({ cursor, data: data.slice() })),
      };
    },
    async append({ expected, idempotencyKey, data }) {
      const stored = records.find((record) => record.idempotencyKey === idempotencyKey);
      if (stored) return { cursor: stored.cursor };
      if (expected !== head()) {
        throw new FxFencedError(`another agent appended to this session: expected ${expected}, head ${head()}`);
      }
      const cursor = String(records.length + 1);
      records.push({ cursor, idempotencyKey, data: data.slice() });
      return { cursor };
    },
    async saveCheckpoint({ through, data }) {
      checkpoint = { through, data: data.slice() };
    },
  };
}

// Marks the turn `agent.resume()` starts; never a caller-visible option.
const resumeTurn = Symbol("libfx.resume");
// Carries the follow-up a turn runs: `{ id, accepted }`.
const followUpInput = Symbol("libfx.followUp");
// Carries the ids of the calls a resumed turn runs again.
const rerunCallIds = Symbol("libfx.rerun");
// Marks a resume whose host already holds what the turn sent before it
// stopped, as a durable session's stream does, so the turn does not send it
// again. Any other resume runs in a host that saw none of it. Never a
// caller-visible option; `fx-harness.js` sets it.
export const resumeOutputShown = Symbol.for("libfx.resumeOutputShown");

function journalAppendError(cause) {
  const error = new Error("libfx journal append failed", { cause });
  error.code = "FX_JOURNAL_APPEND_FAILED";
  return error;
}

// Restoring an open turn needs only its newest progress, and the ones it
// extends when it carries only what is new back to one that carries all of
// it, and the results of calls no progress has answered yet. So an older
// progress's state, and an answered call's result, are left out of a load
// (data: null). A load then grows with the session's committed turns, not
// with every step of every turn.
function withoutSupersededProgress(events) {
  const kept = new Array(events.length);
  let superseded = false;
  let answered = false;
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    const type = event?.type;
    const dropped = event?.data != null && ((type === "turn_progress" && superseded) || (type === "tool_result" && answered));
    kept[index] = dropped ? { ...event, data: null } : event;
    if (type === "turn_committed" || type === "turn_progress_cleared") {
      superseded = true;
      answered = true;
    } else if (type === "turn_progress") {
      answered = true;
      if (event.base === undefined) superseded = true;
    }
  }
  return kept;
}

// A session id reaches gateway headers; the core applies the same rule.
function validSessionId(id) {
  return typeof id === "string" && /^[A-Za-z0-9._-]{1,255}$/.test(id) &&
    id !== "." && id !== ".." && id.toLowerCase() !== "v2";
}
const sessionIdRule = "1 to 255 letters, digits, '.', '_' or '-'";

// A record is one append's events as UTF-8 JSON. Its shape is libfx's; a
// store keeps the bytes as they are.
const journalRecordFormat = "libfx-journal-v1";
// Checkpoints after the journal since the last one reaches this many bytes.
const defaultCheckpointAfterBytes = 1024 * 1024;
// A turn id reaches the journal and tool calls; the core applies the same rule.
const turnIdRule = "1 to 128 letters, digits, '.', '_' or '-'";

function validTurnId(id) {
  return typeof id === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(id);
}

function checkOnAmbiguous(onAmbiguous) {
  if (onAmbiguous !== undefined && typeof onAmbiguous !== "function") throw new TypeError("onAmbiguous must be a function");
}

// A call's input as the model wrote it: JSON when it parses, else the text.
function parsedToolInput(text) {
  try { return JSON.parse(text); } catch { return text; }
}

function validCursor(cursor) {
  return typeof cursor === "string" && cursor.length > 0 && cursor.length <= 1024;
}

function encodeJournalRecord(events) {
  return encoder.encode(JSON.stringify({ format: journalRecordFormat, events }));
}

function persistenceBytes(value, what) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError(`${what} must be bytes`);
}

function decodeJournalRecord(data) {
  let value;
  try { value = JSON.parse(decoder.decode(persistenceBytes(data, "a journal record's data"))); } catch (error) {
    if (error instanceof TypeError && /must be bytes/.test(error.message)) throw error;
    throw journalLoadError("Invalid libfx journal", "FX_JOURNAL_INVALID", error);
  }
  if (value?.format !== journalRecordFormat || !Array.isArray(value.events)) {
    if (typeof value?.format === "string" && value.format.startsWith("libfx-journal-v")) {
      throw new FxJournalVersionError("libfx journal was written by a newer fx");
    }
    throw journalLoadError("Invalid libfx journal", "FX_JOURNAL_INVALID");
  }
  return value.events;
}

// The last `seq` a checkpoint covers, from its header: `FXSN`, a version
// byte, then the seq as a little-endian u64. The core checks the rest.
function checkpointSeq(bytes) {
  if (bytes.byteLength < 13 || decoder.decode(bytes.subarray(0, 4)) !== "FXSN") {
    throw journalLoadError("Invalid libfx journal", "FX_JOURNAL_INVALID");
  }
  return Number(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(5, true));
}

// Reads what `persistence.load()` returns: the latest checkpoint, if any, and
// the records after it, as the events the core folds after that checkpoint.
// Modeled in `tests/tla/durable/SnapshotTail.tla`.
async function loadPersistence(persistence) {
  const loaded = await persistence.load();
  if (!loaded || typeof loaded !== "object") {
    throw new TypeError("persistence.load() must resolve to { checkpoint?, journal? }");
  }
  let checkpoint = null;
  let covered = 0;
  let head = null;
  if (loaded.checkpoint != null) {
    const { data, through } = loaded.checkpoint;
    if (!validCursor(through)) throw new TypeError("persistence.load() checkpoint.through must be a cursor string");
    checkpoint = persistenceBytes(data, "checkpoint.data").slice();
    if (checkpoint.byteLength > maxCheckpointBytes) throw journalLoadError("libfx journal is too large", "FX_JOURNAL_TOO_LARGE");
    covered = checkpointSeq(checkpoint);
    head = through;
  }
  const records = loaded.journal ?? [];
  if (typeof records[Symbol.iterator] !== "function" && typeof records[Symbol.asyncIterator] !== "function") {
    throw new TypeError("persistence.load() journal must be an iterable of { cursor, data }");
  }
  const events = [];
  let bytes = 0;
  for await (const record of records) {
    if (!record || !validCursor(record.cursor)) throw new TypeError("each journal record needs a cursor string");
    // The load limit applies once an open turn's older progress is dropped.
    const data = persistenceBytes(record.data, "a journal record's data");
    bytes += data.byteLength;
    // A store may return records the checkpoint already covers.
    for (const event of decodeJournalRecord(data)) if (!(Number.isSafeInteger(event?.seq) && event.seq <= covered)) events.push(event);
    head = record.cursor;
  }
  // A store whose log holds entries of its own between records names the
  // entry the next record follows.
  if (loaded.head !== undefined) {
    if (loaded.head !== null && !validCursor(loaded.head)) throw new TypeError("persistence.load() head must be a cursor string or null");
    head = loaded.head;
  }
  return { checkpoint, events, head, tailBytes: bytes, lastSeq: events.at(-1)?.seq ?? covered };
}

// How a turn's end event says the turn ended: the stop reason its prompt
// answered with, or "error" for a prompt that failed; null for an end an
// earlier libfx wrote, which does not say.
const journalEndReason = (event) => (typeof event?.stopReason === "string" && event.stopReason.length > 0 ? event.stopReason : null);
const isJournalEnd = (event) => event?.type === "turn_committed" || event?.type === "turn_progress_cleared";

// Events someone waits on, so the record holding one is a barrier: a steer
// or withdrawal its caller awaits, and the end or yield a turn's result does.
const waitedForEvents = new Set(["input_accepted", "input_withdrawn", "turn_committed", "turn_progress_cleared", "turn_yielded"]);

// What a record's events say about turns, in order, for a store that tracks
// them without reading records: a turn started, ended, and how, or yielded,
// an input was accepted or handed back unplaced, or the step the open turn is
// at, as its tool steps finished and the state of its calls. With `replies`,
// as libfx's durable sessions ask, the end that commits a turn also carries
// its reply, the text its last step streamed, so a worker that writes the end
// of a turn whose own worker died first shows what of it no reader has
// (DUR-20, DUR-38).
function journalMarks(events, replies = false) {
  const marks = [];
  for (const event of events) {
    if (event?.type === "turn_progress") {
      if (typeof event.turnId === "string") marks.push({ start: event.turnId });
      // The inputs its model request carries for the first time.
      for (const id of Array.isArray(event.inputs) ? event.inputs : []) if (typeof id === "string") marks.push({ placed: id });
      // A progress that carries only what is new counts all the turn's steps.
      const steps = Number.isSafeInteger(event.steps) ? event.steps : event.data?.execution?.tool_steps?.length;
      if (Number.isSafeInteger(steps)) marks.push({ step: `${steps}:${String(event.data?.tool_state ?? "none")}` });
    } else if (isJournalEnd(event)) {
      const stopReason = journalEndReason(event);
      const reply = replies && event.type === "turn_committed" && typeof event.data?.assistant === "string" && event.data.assistant.length > 0 ? event.data.assistant : null;
      marks.push({ end: true, ...(stopReason === null ? {} : { stopReason }), ...(reply === null ? {} : { reply }) });
    } else if (event?.type === "turn_yielded") marks.push({ yield: true });
    else if (event?.type === "input_accepted" && typeof event.data?.id === "string") marks.push({ accepted: event.data.id });
    else if (event?.type === "input_withdrawn" && typeof event.data?.id === "string") marks.push({ withdrawn: event.data.id });
  }
  return marks;
}

function agentEnvironment(options) {
  return {
    ...(options.apiKey === undefined ? {} : { AI_GATEWAY_API_KEY: options.apiKey }),
    ...(options.providerName === undefined ? {} : { FX_PROVIDER: options.providerName }),
    ...(options.customProvider === undefined ? {} : { FX_CONFIGURED_PROVIDERS: options.customProvider.json }),
    ...(options.model === undefined ? {} : { FX_MODEL: options.model }),
    ...(options.effort === undefined ? {} : { FX_EFFORT: options.effort }),
    ...(options.fast === undefined ? {} : { FX_FAST: options.fast ? "true" : "false" }),
    ...(options.ultrafast === undefined ? {} : { FX_ULTRAFAST: options.ultrafast ? "true" : "false" }),
    ...(options.gatewayChatUrl === undefined ? {} : { FX_GATEWAY_CHAT_URL: options.gatewayChatUrl }),
  };
}

function agentRpcError(response) {
  const error = new Error(response.message);
  error[coreAnswered] = true;
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
  if (options.apiKey === undefined) throw missingGatewayKey("listModels");
  const apiKey = boundedString(options.apiKey, "apiKey", maxApiKeyBytes, false);
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

function workspacePathInside(root, path) {
  return root === "/" ? path.startsWith("/") : path === root || path.startsWith(`${root}/`);
}

// fx only reads AGENTS.md files below the workspace root or the host home.
function workspaceInstructionPathAllowed(info, path) {
  return validWorkspacePath(path) && path.endsWith("/AGENTS.md") &&
    (workspacePathInside(info.root, path) || workspacePathInside(info.home, path));
}

// The first rule of workspace version 1 an adapter breaks, or null.
function workspaceContractBreak(workspace, info, permission, readFile) {
  if (!info) return "workspace.info is required";
  if (typeof workspace.exec !== "function") return "workspace.exec must be a function";
  if (info.version !== 1) return "workspace.info.version must be 1";
  if (readFile !== undefined && typeof readFile !== "function") return "workspace.readFile must be a function when present";
  for (const key of ["root", "cwd", "home"]) {
    if (!validWorkspacePath(info[key])) return `workspace.info.${key} must be a normalized absolute path`;
  }
  if (info.cwd !== info.root) return "workspace.info.cwd must equal workspace.info.root";
  if (info.gitAvailable !== false) return "workspace.info.gitAvailable must be false";
  if (info.ephemeral !== true) return "workspace.info.ephemeral must be true";
  if (permission !== "allow-sandboxed" && permission !== "prompt") return "workspace.permission must be \"allow-sandboxed\" or \"prompt\"";
  return null;
}

function prepareWorkspaceAdapter(workspace) {
  if (workspace == null) return { present: false, valid: false };
  try {
    const info = workspace.info;
    const permission = workspace.permission;
    const readFile = workspace.readFile;
    const broken = workspaceContractBreak(workspace, info, permission, readFile);
    if (broken) return { present: true, valid: false, reason: broken };
    const value = {
      version: 1,
      root: info.root,
      cwd: info.cwd,
      home: info.home,
      git: false,
      ephemeral: true,
      permission,
      instruction_files: typeof readFile === "function",
    };
    const encoded = encoder.encode(JSON.stringify(value));
    if (encoded.length > workspaceInfoLimit) {
      return { present: true, valid: false, reason: `workspace.info must take at most ${workspaceInfoLimit} bytes as JSON` };
    }
    return { present: true, valid: true, adapter: workspace, info: value, encoded };
  } catch (error) {
    return { present: true, valid: false, reason: `reading the workspace adapter threw ${error?.name ?? "an error"}` };
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
  // A steer that cannot join the running turn waits to run next.
  let steeringHandoff = false;
  // The running turn's steering closed because the turn was cancelled. The
  // core reads this as it ends the turn, before it reads the cancel itself.
  let steeringCancelled = false;
  // Raw payloads beside ACP frames: the core copies inbound bytes into its
  // own memory and publishes outbound bytes for the agent to take.
  const inboundAttachments = new Map();
  const outboundAttachments = new Map();
  let nextOutboundAttachment = 1;
  const workspaceOperations = new Set();
  const workspace = prepareWorkspaceAdapter(options.workspace);
  // fx runs without a workspace it refuses, and shows that it refused one;
  // the app hears which rule the adapter broke.
  if (workspace.present && !workspace.valid) options.emit?.("workspace.invalid", { reason: workspace.reason });
  let reportedTerminalSize = { cols: 0, rows: 0 };
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

  // A failure after libfx's own abort is a cancel, whatever the host's fetch
  // threw; any other failure, an AbortError of its own included, is an error
  // (API-60, API-63), as on the native backend.
  const streamFailure = (state) => state.controller.signal.aborted ? -2 : -1;

  function streamStatus(handle, statusOut) {
    const state = streams.get(handle);
    if (!state) return -1;
    const settled = () => {
      if (state.responseError) return streamFailure(state);
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
      if (state.readError) return streamFailure(state);
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
    steeringHandoff = false;
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

  // Resolves once the session's worker has handed in the inputs it stored
  // since it last read them; each steer is queued by then.
  function takeInputs() {
    if (typeof options.takeInputs !== "function") return 0;
    return Promise.resolve().then(() => options.takeInputs()).then(() => 0, () => -1);
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
    }).catch((error) => {
      // The app learns that a turn was not saved, and why: on a revision
      // conflict, fx stops saving this conversation (app_session_runtime.zig).
      options.emit?.("session.persist_error", { sessionId: id, error });
      return error?.code === "FX_SESSION_REVISION_CONFLICT" ? -2 : -1;
    });
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

    return runWorkspaceOperation(timeoutMs, "workspace command", (signal) => workspace.adapter.exec({
      command,
      cwd: workspace.info.cwd,
      signal,
      timeoutMs,
      outputLimitBytes: workspaceOutputLimit,
    }), (value) => {
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
    });
  }

  function workspaceReadFile(pathPtr, pathLen, outPtr, outCap, resultPtr) {
    if (!workspace.present || (workspace.valid && typeof workspace.adapter.readFile !== "function")) {
      return Promise.resolve(-2);
    }
    if (!workspace.valid) return Promise.resolve(-4);
    const pathBytes = checkedBytes(pathPtr, pathLen);
    if (!pathBytes || !checkedBytes(outPtr, outCap) || !checkedBytes(resultPtr, 8) ||
      pathLen > workspaceInstructionPathLimit || outCap > workspaceInstructionFileLimit) {
      return Promise.resolve(-4);
    }
    let path;
    try {
      path = strictDecoder.decode(pathBytes);
    } catch {
      return Promise.resolve(-4);
    }
    if (!workspaceInstructionPathAllowed(workspace.info, path)) return Promise.resolve(-4);

    return runWorkspaceOperation(workspaceReadTimeoutMs, "workspace read", (signal) => workspace.adapter.readFile({
      path,
      signal,
    }), (value) => {
      if (value == null) return -6;
      let content;
      if (typeof value === "string") {
        content = encoder.encode(value);
      } else if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
        content = value instanceof ArrayBuffer
          ? new Uint8Array(value)
          : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        try {
          strictDecoder.decode(content);
        } catch {
          return -7;
        }
      } else {
        return -1;
      }
      if (content.length > 0xffffffff) return -1;
      const copied = Math.min(content.length, outCap);
      // Reacquire views: memory may have grown while the host read was pending.
      bytes(outPtr, copied).set(content.subarray(0, copied));
      const view = new DataView(memory().buffer, resultPtr, 8);
      view.setUint32(0, content.length, true);
      view.setUint32(4, copied, true);
      return 0;
    });
  }

  // Runs one host workspace effect under a deadline and the shared Ctrl+C
  // abort path. `finish` maps the host value to an ABI status.
  function runWorkspaceOperation(timeoutMs, label, start, finish) {
    const controller = new AbortController();
    let resolveAbort;
    const aborted = new Promise((resolve) => { resolveAbort = resolve; });
    const state = {
      status: null,
      abort(status) {
        if (this.status !== null) return;
        this.status = status;
        resolveAbort(status);
        controller.abort(new DOMException(
          status === -5 ? `${label} timed out` : `${label} aborted`,
          status === -5 ? "TimeoutError" : "AbortError",
        ));
      },
    };
    workspaceOperations.add(state);
    const timer = setTimeout(() => state.abort(-5), timeoutMs);
    const execution = Promise.resolve().then(() => start(controller.signal)).then((value) => {
      if (state.status !== null) return state.status;
      return finish(value);
    }).catch((error) => {
      if (state.status !== null) return state.status;
      if (error?.name === "TimeoutError") return -5;
      if (error?.name === "AbortError") return -3;
      return -1;
    });
    return Promise.race([execution, aborted]).finally(() => {
      clearTimeout(timer);
      workspaceOperations.delete(state);
    });
  }

  function abortHostEffects() {
    pendingHostToolResult = null;
    streams.forEach((state) => state.controller.abort(abortReason));
    httpRequests.forEach((controller) => controller.abort(abortReason));
    workspaceOperations.forEach((state) => state.abort(-3));
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
    fx_workspace_read_file: new WebAssembly.Suspending(workspaceReadFile),
    fx_http_stream_open: streamOpen,
    fx_http_stream_status: new WebAssembly.Suspending(streamStatus),
    fx_http_stream_next: new WebAssembly.Suspending(streamNext),
    fx_http_stream_close(handle) { const state = streams.get(handle); state?.controller.abort(abortReason); streams.delete(handle); },
    fx_http_request: new WebAssembly.Suspending(httpRequest),
    fx_host_tool_call: new WebAssembly.Suspending(hostToolCall),
    fx_journal_flush: new WebAssembly.Suspending(journalFlush),
    fx_take_inputs: new WebAssembly.Suspending(takeInputs),
    fx_host_tool_result_read(offset, ptr, cap) {
      if (!pendingHostToolResult || offset < 0 || offset > pendingHostToolResult.length) return -1;
      const chunk = pendingHostToolResult.subarray(offset, offset + cap);
      bytes(ptr, chunk.length).set(chunk);
      return chunk.length;
    },
    fx_host_tool_result_release() { pendingHostToolResult = null; },
    fx_steering_take: steeringTake,
    fx_steering_close() { steeringOpen = false; clearSteering(); },
    // -1 once the turn takes no more steering, -2 when that is because the
    // turn was cancelled, else twice how many steers wait, plus one when a
    // handoff does.
    fx_steering_state() { return steeringOpen ? steering.length * 2 + (steeringHandoff ? 1 : 0) : steeringCancelled ? -2 : -1; },
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
    // The browser has no SIGWINCH, so fx asks for the size on every pass of
    // its loop, about 60 times a second while idle; only a size it has not
    // reported yet is a diagnostic.
    fx_term_size(cols, rows) {
      const width = options.terminal?.cols || 80;
      const height = options.terminal?.rows || 24;
      new DataView(memory().buffer).setUint16(cols, width, true);
      new DataView(memory().buffer).setUint16(rows, height, true);
      if (width === reportedTerminalSize.cols && height === reportedTerminalSize.rows) return;
      reportedTerminalSize = { cols: width, rows: height };
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
    openSteering() { clearSteering(); steeringOpen = true; steeringCancelled = false; },
    steer: queueSteering,
    withdrawSteering,
    // Ends the running turn at its next safe point; false when none runs.
    handOffSteering() {
      if (!steeringOpen) return false;
      steeringHandoff = true;
      return true;
    },
    closeSteering() { steeringOpen = false; clearSteering(); },
    // Closes the running turn's steering because the turn was cancelled.
    cancelSteering() { steeringOpen = false; steeringCancelled = true; clearSteering(); },
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

// The terminal's requests report the transport.* diagnostics an engine's do.
// fx retries inside the core, so `attempt` numbers the terminal's requests
// from 1, which pairs each start with its response or error. The endpoint
// carries no query string, so no team or token reaches a diagnostic.
function terminalTransport(hostFetch, emit) {
  const send = hostFetch ?? globalThis.fetch.bind(globalThis);
  let requests = 0;
  return async (input, init = {}) => {
    const attempt = ++requests;
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    let endpoint = String(input?.url ?? input);
    try {
      const url = new URL(endpoint);
      endpoint = `${url.origin}${url.pathname}`;
    } catch {}
    const startedAt = performance.now();
    emit("transport.start", { attempt, method, endpoint, model: undefined });
    try {
      const response = await send(input, init);
      const headers = response.headers;
      emit("transport.response", {
        attempt,
        status: response.status,
        elapsedMs: performance.now() - startedAt,
        requestId: headers.get("x-vercel-id"),
        generationId: headers.get("x-generation-id"),
        model: headers.get("x-model-id") ?? undefined,
        provider: headers.get("x-vercel-ai-gateway-provider") ?? headers.get("x-ai-gateway-provider"),
      });
      return response;
    } catch (error) {
      emit("transport.error", { attempt, elapsedMs: performance.now() - startedAt, error: error instanceof Error ? error.name : "Error" });
      throw error;
    }
  };
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
  const runtime = await instantiate({ ...options, fetch: terminalTransport(options.fetch, emit), emit, stdout, onTerminalPoll });
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
  }
  return prompt;
}

// The image types libfx's core takes, each known by how its bytes start.
const imageSignatures = [
  ["image/png", 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]],
  ["image/jpeg", 0, [0xff, 0xd8, 0xff]],
  ["image/gif", 0, [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]],
  ["image/gif", 0, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]],
  ["image/webp", 0, [0x52, 0x49, 0x46, 0x46]],
];
const imageTypes = new Set(imageSignatures.map(([type]) => type));
const webpMarker = [0x57, 0x45, 0x42, 0x50];

// The image type `bytes` start as, or null.
function imageTypeOf(bytes) {
  const startsWith = (offset, signature) => bytes.length >= offset + signature.length && signature.every((byte, index) => bytes[offset + index] === byte);
  for (const [type, offset, signature] of imageSignatures) {
    if (!startsWith(offset, signature)) continue;
    if (type === "image/webp" && !startsWith(8, webpMarker)) continue;
    return type;
  }
  return null;
}

// Refuses image bytes that are not the type they declare, as libfx's core does.
function checkImageBytesType(bytes, mimeType, index) {
  const type = imageTypeOf(bytes);
  if (type === null) throw new TypeError(`image prompt block ${index} is not a PNG, JPEG, GIF or WebP image`);
  if (type !== mimeType) throw new TypeError(`image prompt block ${index} holds ${type} data, not ${mimeType}`);
}

/**
 * Checks a prompt's input as libfx takes it and returns it normalized:
 * every check `prompt()` makes, and the ones libfx's core makes on images,
 * which would otherwise refuse the prompt only once it reached the core: a
 * supported image type, and bytes or base64 that are that type. A Blob is not
 * read, so its bytes are checked once read (`checkImageBytesType`). With
 * `resizeImage`, image bytes are checked after it runs instead. Throws a
 * TypeError or RangeError.
 */
export function checkPromptInput(input, { resizeImage } = {}) {
  const resized = resizeImage !== undefined;
  const normalized = normalizePromptInput(input, { deferImageLimits: resized });
  // The core takes no prompt without text or an image; a resource adds neither.
  if (!normalized.some((block) => block.type === "image" || (block.type === "text" && block.text.length > 0))) {
    throw new TypeError("prompt is empty");
  }
  // Image data travels beside the frame, so the frame holds the text,
  // resources and metadata alone; image sizes, which resizeImage decides
  // where there is one, are checked apart from it.
  checkPromptFrameSize(normalized);
  normalized.forEach((block, index) => {
    if (block.type !== "image" || (resized && block.data !== undefined)) return;
    if (!imageTypes.has(block.mimeType)) throw new TypeError(`image prompt block ${index} mimeType must be image/png, image/jpeg, image/gif or image/webp`);
    if (block.source === "bytes") checkImageBytesType(block.data, block.mimeType, index);
    else if (block.source === "base64") checkImageBytesType(base64ToBytes(block.data.slice(0, 16)), block.mimeType, index);
  });
  return normalized;
}

// A stored image's name as session/prompt carries it: 64 hex digits.
const storedImageNameStandIn = "0".repeat(64);

// A prompt block as session/prompt carries it at its longest, from the
// caller's block or from normalizePromptInput()'s: an image's bytes travel
// beside the frame as an attachment, which the frame names, with the name
// the image store gave them where the engine has one (storePromptImages).
function framedPromptBlock(block) {
  if (block?.type === "text") return { type: "text", text: block.text };
  if (block?.type === "resource") {
    const resource = block.resource || block;
    return { type: "resource", resource: { uri: resource.uri, ...(resource.text === undefined ? {} : { text: resource.text }) } };
  }
  if (block?.type !== "image") return block;
  return {
    type: "image",
    mimeType: block.mimeType,
    ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
    ...(block.data === undefined && block.bytes === undefined ? {} : { _meta: { fx: { attachment: 0xffffffff, stored: storedImageNameStandIn } } }),
  };
}

// The most the session/prompt frame for these blocks can take. The model
// request also carries the images, base64 encoded; the native host's request
// budget holds a full frame and a prompt's 8 MiB of encoded images.
function promptFrameSize(prompt) {
  return encoder.encode(JSON.stringify(prompt.map(framedPromptBlock))).length + promptFrameEnvelopeBytes;
}

function checkPromptFrameSize(prompt) {
  if (promptFrameSize(prompt) > maxPromptFrameBytes) {
    throw new RangeError(`prompt exceeds the ${maxPromptFrameBytes} byte libfx frame limit`);
  }
}

/**
 * What a prompt `input` takes of the frame an engine sends it in, as
 * `prompt()` measures it, for a durable session to refuse an input no engine
 * could take before it stores it. Pure; it validates nothing, so an input
 * the engine refuses for another reason is measured too.
 */
export function promptFrameBytes(input) {
  return promptFrameSize(typeof input === "string" ? [{ type: "text", text: input }] : Array.isArray(input) ? input : [input]);
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
  // A callback's mimeType can be longer than the one it replaced.
  checkPromptFrameSize(prepared);
  // A file's bytes, or what resizeImage made, are checked once there are
  // some, after the size limits.
  prepared.forEach((image, index) => {
    if (image.type === "image" && image.bytes !== undefined) checkImageBytesType(image.bytes, image.mimeType, index);
  });
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

// A tool set's shape, so a checkpoint can tell when the tools it continues
// with changed since it was saved.
function toolSchemaHash(descriptors) {
  const shape = JSON.stringify([...descriptors].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)));
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(shape)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

// `tools` is an array of descriptors, or an object of descriptors keyed by
// name. What `idempotent` and `writes` mean after a crash and for calls that
// run together is modeled in `tests/tla/durable/ToolReplay.tla`, whose
// `replay: "safe"` is an idempotent tool that does not write, and in
// `tests/tla/durable/ParallelBatch.tla`.
function normalizeHostTools(value) {
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
    const { name, description, inputSchema, execute, providerExecuted, writes, idempotent } = tool;
    if (typeof name !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(name)) {
      throw new TypeError(`tool ${index} has an invalid name`);
    }
    if (names.has(name)) throw new TypeError(`duplicate tool name: ${name}`);
    names.add(name);
    if (providerExecuted !== undefined && typeof providerExecuted !== "boolean") {
      throw new TypeError(`tool ${name} providerExecuted must be a boolean`);
    }
    if (providerExecuted === true) {
      if (name !== "web_search") {
        throw new TypeError(`provider tool ${name} is not supported: web_search is the only provider tool, so define ${name} as a host tool with execute() instead`);
      }
      if (execute !== undefined) throw new TypeError(`provider-executed tool ${name} must not define execute()`);
      descriptors.push({ name, providerExecuted: true });
      continue;
    }
    if (typeof description !== "string") throw new TypeError(`tool ${name} requires a description`);
    if (typeof execute !== "function") throw new TypeError(`tool ${name} requires execute()`);
    if (writes !== undefined && typeof writes !== "boolean") throw new TypeError(`tool ${name} writes must be a boolean`);
    if (idempotent !== undefined && typeof idempotent !== "boolean") throw new TypeError(`tool ${name} idempotent must be a boolean`);
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
      ...(writes === undefined ? {} : { writes }),
      // The engine reads `idempotent`: such a tool runs beside others unless
      // it `writes`, and one that does not write starts before its intent is
      // stored. It is also in the shape a checkpoint records, so a change to
      // it counts as a changed tool set.
      ...(idempotent === true ? { idempotent: true } : {}),
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

// Answers a catalog request from `memory`, which maps a catalog URL to the
// body the agent's first request for it got. Every request of one agent
// carries that agent's credentials, so one entry per URL is enough (API-15),
// and a token that changes on each request, such as a Vercel OIDC token,
// adds none. Only a successful response is kept: a request that waited on
// one that failed fetches for itself. A request that waits on another
// engine's fetch still stops when its own `signal` aborts (API-60).
async function rememberedCatalog(memory, url, signal, fetchCatalog) {
  if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
  const remembered = memory.get(url);
  if (remembered) {
    const body = await untilAborted(remembered, signal);
    if (body === null) return fetchCatalog();
    return new Response(body, { status: 200, headers: { "content-type": "application/json" } });
  }
  let settle;
  memory.set(url, new Promise((resolve) => { settle = resolve; }));
  let body = null;
  try {
    const response = await fetchCatalog();
    if (!response.ok) return response;
    body = await readBoundedResponseText(response, maxModelCatalogBytes);
    return new Response(body, { status: response.status, headers: response.headers });
  } finally {
    if (body === null) memory.delete(url);
    settle(body);
  }
}

// `promise`, or an AbortError as soon as `signal` aborts.
function untilAborted(promise, signal) {
  if (!signal) return promise;
  let onAbort;
  const aborted = new Promise((_, reject) => {
    onAbort = () => reject(new DOMException("Aborted", "AbortError"));
    signal.addEventListener("abort", onAbort, { once: true });
  });
  return Promise.race([promise, aborted]).finally(() => signal.removeEventListener("abort", onAbort));
}

export function normalizeInstructions(value) {
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

// `stored` maps an image's base64 data to its name in the image store, for
// the images stored before the result goes to the core: their blocks carry
// the name, so the core names them too.
function hostToolContent(value, stored = null) {
  if (value?.type === "libfx.tool-result") {
    if (typeof value.text !== "string" || !Array.isArray(value.images)) {
      throw new TypeError("invalid typed tool result");
    }
    // The tool and the model both read this, so it names the limit.
    if (value.images.length > maxToolResultImages) {
      throw new RangeError(`a libfx.tool-result holds at most ${maxToolResultImages} images, and this one has ${value.images.length}`);
    }
    let images = value.images.map((image) => {
      if (image?.type !== "image") throw new TypeError("invalid tool image");
      const sourceRef = normalizeImageSourceRef(image.sourceRef, "tool image");
      const referenceOnly = image.data === undefined && sourceRef !== undefined;
      if ((!referenceOnly && typeof image.data !== "string") || typeof image.mimeType !== "string" || image.mimeType.length === 0 || image.mimeType.length > 128 || (image.data?.length > maxPromptImageDataBytes && sourceRef === undefined)) {
        throw new TypeError("invalid tool image");
      }
      const data = !referenceOnly && image.data.length <= maxPromptImageDataBytes ? image.data : undefined;
      return {
        type: "image",
        ...(data === undefined ? {} : { data }),
        mimeType: image.mimeType,
        ...(sourceRef === undefined ? {} : { sourceRef }),
        ...(data !== undefined && stored?.has(data) ? { stored: stored.get(data) } : {}),
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
    return { content, rich: true, isError: value.isError === true, images };
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

/**
 * One session on one fx core, with no durability of its own: `createFxAgent`
 * runs each durable session's turns on one of these, and a host with its own
 * storage may pass `persistence`.
 */
export async function createFxEngine(options = {}) {
  options = normalizeAgentOptions(options);
  const hostTools = normalizeHostTools(options.tools);
  const instructions = normalizeInstructions(options.instructions);
  // Recorded in every checkpoint this agent saves, so a later one can tell
  // it continues with another libfx, other tools, or another model.
  const checkpointMeta = {
    libfxVersion: String(fxSdkApiVersion),
    toolSchemaHash: toolSchemaHash(hostTools.descriptors),
    model: options.model ?? "",
  };
  const initialCheckpoint = checkpointBytes(options.checkpoint);
  // Checked before the core starts, and with the core's message, so both
  // backends report it the same way.
  if (initialCheckpoint && initialCheckpoint.byteLength > maxCheckpointBytes) {
    throw new Error("libfx checkpoint is too large");
  }
  const pending = new Map();
  let nextId = 1;
  let sessionId = null;
  const hookScopes = new Map();
  // Observation never participates in effects, journal barriers, or retries.
  // Contain both throws and rejected promises, including an error handler's.
  const hookError = (error) => {
    try { Promise.resolve(options.hooks?.onError?.(error)).catch(() => {}); } catch {}
  };
  const hook = (event) => {
    if (!options.hooks) return;
    if (options.hooks.parent) event = {
      ...event, rootSessionId: options.hooks.parent.rootSessionId,
      ...(event.sessionId === sessionId && event.parentSessionId == null ? {
        parentSessionId: options.hooks.parent.sessionId, parentTurnId: options.hooks.parent.turnId, parentCallId: options.hooks.parent.callId,
      } : {}),
    };
    if (event.type === "tool.start") {
      const { data, type, ...scope } = event;
      hookScopes.set(`${event.sessionId}:${data.call.callId}`, scope);
    } else if (event.type === "tool.end") hookScopes.delete(`${event.sessionId}:${event.data.call.callId}`);
    else if (event.type === "turn.end") {
      for (const [key, scope] of hookScopes) if (scope.executionId === event.executionId) hookScopes.delete(key);
    } else if (event.type === "journal.error" && event.data.fenced) hookScopes.clear();
    try { Promise.resolve(options.hooks.onEvent(event)).catch(hookError); } catch (error) { hookError(error); }
  };
  const journalHook = (type, data) => hook({
    version: 1, type, sessionId, rootSessionId: sessionId, parentSessionId: null, sourceSessionId: null, workId: null, turnId: null, executionId: null, stepIndex: 0,
    timestamp: Date.now(), contentCaptured: false, contentTruncated: false, data,
  });
  let activeTurn = null;
  let closing = false;
  let coreExitError = null;
  const isCurrentTurn = (turn) => turn && activeTurn === turn && !turn.cancelled && !closing;
  // Events go to the store in the order the core sends them, one append at
  // a time: events that arrive together become one record, and so do all
  // the events that arrive while an append is in flight. Each record's append
  // names the cursor of the one before it, so a store refuses a write that
  // does not continue what it holds, and says with `barrier` whether anyone
  // waits for it: the core before an action others can see, such as a tool
  // call with effects, or a caller for its input.
  const persistence = options.persistence ?? null;
  // A persistence with an image store keeps each prompt image once, by
  // name, and the core names it in records and checkpoints instead of
  // holding its bytes.
  const imageStorage = persistence?.[persistenceImages] ?? null;
  const imageStore = imageStorage !== null;
  const wantsMarks = persistence?.marks === true || persistence?.[journalMarksWanted] === true;
  const wantsReplies = persistence?.[journalMarksWanted] === true;
  const checkpointAfterBytes = options.checkpointAfterBytes ?? defaultCheckpointAfterBytes;
  // The store's last cursor, and the last seq its records hold.
  let journalHead = null;
  let appendedSeq = 0;
  // Record bytes stored since the last checkpoint.
  let bytesSinceCheckpoint = 0;
  let appendTail = Promise.resolve();
  // One per agent, so a store can tell a repeated write from another writer's.
  const writerId = crypto.randomUUID();
  // Pipelined appends and barriers are modeled in `tests/tla/durable/Journal.tla`,
  // and two processes appending to one log in `tests/tla/durable/Fencing.tla`.
  const journal = persistence && {
    append(events, barrier) {
      const data = encodeJournalRecord(events);
      const lastSeq = events.at(-1)?.seq;
      // A store that tracks turns without reading records asks for marks.
      const marks = wantsMarks ? { marks: journalMarks(events, wantsReplies) } : {};
      const appended = appendTail.then(async () => {
        const result = await persistence.append({ expected: journalHead, idempotencyKey: `${writerId}:${events[0]?.seq}`, data, barrier, ...marks });
        if (!validCursor(result?.cursor)) throw new TypeError("persistence.append() must resolve to { cursor }");
        journalHead = result.cursor;
        if (Number.isSafeInteger(lastSeq)) appendedSeq = lastSeq;
        bytesSinceCheckpoint += data.byteLength;
        journalHook("journal.commit", { cursor: result.cursor, firstSeq: Number.isSafeInteger(events[0]?.seq) ? events[0].seq : null, lastSeq: Number.isSafeInteger(lastSeq) ? lastSeq : null, eventCount: events.length });
      });
      // A failed append fails every later one: they would not continue it.
      appendTail = appended;
      return appended;
    },
  };
  let resumable = false;
  // The host's ids for the turn a crash left open and the last turn that
  // ended, so a retried prompt continues or skips its turn.
  let openTurnId = null;
  let lastTurnId = null;
  // How the journal says the last turn that ended ended, `{ id, stopReason }`
  // with a null reason for an end an earlier libfx wrote, so a retried prompt
  // of that turn reports it (DUR-20). `journalTurn` is the turn whose first
  // progress the journal holds, until its end.
  let lastTurnEnd = null;
  let journalTurn = null;
  const noteJournalEnds = (events) => {
    for (const event of events) {
      if (event?.type === "turn_progress" && validTurnId(event.turnId)) journalTurn = event.turnId;
      else if (isJournalEnd(event) && journalTurn !== null) {
        lastTurnEnd = { id: journalTurn, stopReason: journalEndReason(event) };
        journalTurn = null;
      }
    }
  };
  // The calls the open turn left running: `{ id, name, arguments }`, and
  // what the resume tells the model about each one it does not run again.
  let ambiguousCalls = [];
  // Asks `onAmbiguous` about each of them, once. Returns the ids of the
  // calls to run again, and the rest, which the resume answers as possibly
  // run.
  const settleAmbiguous = (onAmbiguous) => {
    const calls = ambiguousCalls;
    ambiguousCalls = [];
    const rerun = onAmbiguous === undefined
      ? []
      : calls.filter((call) => onAmbiguous({ executionId: call.id, name: call.name, input: parsedToolInput(call.arguments) }) === "rerun").map((call) => call.id);
    return { rerun, answered: calls.filter((call) => !rerun.includes(call.id)) };
  };
  // Continues the open turn: the calls it left running run again or are
  // answered as possibly run, and each answered one ends for the turn's
  // viewers as it does for the model. Modeled in
  // `tests/tla/durable/Resumption.tla`.
  const resumeOpenTurn = (promptOptions) => {
    const { rerun, answered } = settleAmbiguous(promptOptions.onAmbiguous);
    return normalizeTurn(startTurn(null, { ...promptOptions, [resumeTurn]: true, [rerunCallIds]: rerun }), answered);
  };
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
      turn = normalizeTurn(startTurn(next.text, { turnId: next.id, [followUpInput]: { id: next.id, accepted: next.accepted } }));
    } catch (error) {
      next.rejectTurn?.(error);
      return;
    }
    next.resolveTurn?.(turn);
  };
  let journalQueue = [];
  let journalFlushScheduled = false;
  const journalPending = new Set();
  // The append in flight, and whether anyone waits for the events queued
  // behind it.
  let journalInFlight = null;
  let journalBarrier = false;
  // Events that hold one of the turn's steps, a call or its result, or a
  // progress after the turn's first: a model request after them carries the
  // step. Whether the append in flight holds one.
  const holdsStep = (event) => event?.type === "tool_intent" || event?.type === "tool_result" || (event?.type === "turn_progress" && event.base !== undefined);
  let journalInFlightSteps = false;
  let journalFailure = null;
  // Set by `turn.cancel({ reason: "handoff" })`: the journal keeps the open
  // turn for another agent, so this one stores nothing more.
  let handedOff = false;
  const handedOffError = () => new Error("this agent handed its session off; open it again to continue");
  // Input events (`accepted:<id>`, `withdrawn:<id>`) once stored, and the
  // steer and withdraw calls waiting for them, which resolve only then
  // (`tests/tla/durable/Inbox.tla`).
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
  // `barrier`: the core waits for these events before it goes on.
  const queueJournalEvents = (events, barrier = false) => {
    if (journalFailure || !Array.isArray(events) || events.length === 0) return;
    if (handedOff) {
      // The agent that opens the session next decides about these inputs.
      const dropped = events
        .filter((event) => event?.type === "input_accepted" || event?.type === "input_withdrawn")
        .map((event) => `${event.type === "input_accepted" ? "accepted" : "withdrawn"}:${event.data?.id}`);
      rejectInputWaiters(dropped, handedOffError());
      return;
    }
    noteJournalEnds(events);
    activeTurn?.noteRecords?.(events);
    journalQueue.push(...events);
    // A caller waits for its steer or withdrawal to be stored, and a turn's
    // result for the turn's end or yield.
    if (barrier || events.some((event) => waitedForEvents.has(event?.type))) journalBarrier = true;
    // A turn notes a new config right before its first progress, a barrier:
    // the two go out in one write instead of two in a row.
    if (events.every((event) => event?.type === "session_config")) return;
    if (journalFlushScheduled) return;
    journalFlushScheduled = true;
    queueMicrotask(flushJournal);
  };
  // Sends the queued events as one record, unless an append is in flight:
  // then they wait for it, with any that arrive meanwhile, and go out
  // together once it lands.
  function flushJournal() {
    journalFlushScheduled = false;
    if (journalFailure || journalInFlight || journalQueue.length === 0) return;
    const batch = journalQueue;
    journalQueue = [];
    const barrier = journalBarrier;
    journalBarrier = false;
    journalInFlightSteps = batch.some(holdsStep);
    emit("journal.append", { events: batch.length, barrier });
    let appended;
    try {
      appended = Promise.resolve(journal.append(batch, barrier));
    } catch (error) {
      appended = Promise.reject(error);
    }
    const settled = appended.then(() => {
      settleInputs(batch);
    }, (error) => {
      // Later events would leave a gap after the failed batch.
      journalQueue = [];
      if (journalFailure) return;
      // A fence is the store's own answer, which an app checks for: the
      // turn rejects with it, also when the store carries it as the cause.
      // Any other failure says the append failed.
      const fence = error?.code === "FX_FENCED" ? error : error?.cause?.code === "FX_FENCED" ? error.cause : null;
      journalFailure = fence ?? journalAppendError(error);
      emit("journal.error", { error: error instanceof Error ? error.name : "Error" });
      journalHook("journal.error", { error: error instanceof Error ? error.name : "Error", fenced: fence !== null });
      rejectInputWaiters([...inputWaiters.keys()], journalFailure);
      // Nothing the turn does from here can be saved, and after a fence the
      // session has another owner: stop the turn and its effects now.
      activeTurn?.cancel();
    }).finally(() => {
      journalPending.delete(settled);
      journalInFlight = null;
      journalInFlightSteps = false;
      flushJournal();
    });
    journalInFlight = settled;
    journalPending.add(settled);
  }
  // The journal's own work, such as a heartbeat, ends with the agent: once,
  // after the last append settles.
  let journalClosed = null;
  function closeJournal() {
    journalClosed ??= journalSettled().catch(() => {}).then(() => checkpointing);
    return journalClosed;
  }
  async function journalSettled() {
    for (;;) {
      // This caller waits for every event queued so far.
      if (journalQueue.length > 0) journalBarrier = true;
      if (journalFlushScheduled || journalQueue.length > 0) flushJournal();
      if (journalPending.size === 0) break;
      await Promise.all([...journalPending]);
    }
    if (journalFailure) throw journalFailure;
  }
  // The store's answer to every append so far, without making any of them a
  // barrier. The core marks each event it needs stored before it goes on, so
  // its waits use this. So does a model request after a step: it waits to
  // learn whether the store refused the step, but a store may acknowledge a
  // record that is no barrier before it is durable, and the request then
  // still runs ahead of the commit (DUR-18, DUR-30).
  async function journalAnswered() {
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
  // A checkpoint saved by another libfx, with other tools, or for another
  // model still restores; the host hears what changed.
  const compareCheckpointMeta = (saved) => {
    if (!saved || typeof saved !== "object") return;
    const changed = Object.keys(checkpointMeta).filter((key) => typeof saved[key] === "string" && saved[key] !== "" && saved[key] !== checkpointMeta[key]);
    if (changed.length) emit("checkpoint.mismatch", { sessionId, changed, saved, current: checkpointMeta });
  };
  // Saves a checkpoint once the records since the last one reach
  // `checkpointAfterBytes`, or with `force` whatever their size, at a point
  // no turn is running: a turn's end, or where it yielded. A failed save
  // leaves the journal as it was; the next turn's end tries again. Returns
  // the save in flight, which never rejects.
  let checkpointing = null;
  const maybeCheckpoint = (force = false) => {
    if (checkpointing) return checkpointing;
    if (!persistence?.saveCheckpoint || closing || handedOff || journalFailure) return Promise.resolve();
    checkpointing = (async () => {
      // The turn's last records may still be in flight; count them first.
      await journalSettled();
      // A save begun before close() finishes; close() waits for it.
      if (activeTurn) return;
      if (bytesSinceCheckpoint === 0 || (!force && bytesSinceCheckpoint < checkpointAfterBytes)) return;
      const response = await request("libfx/snapshot", { sessionId, checkpointMeta });
      const id = response?.snapshotAttachment;
      // A session past a checkpoint's limits gets none; the host hears why,
      // since every load then reads all the records since the last one.
      const skipped = Object.hasOwn(checkpointSkips, response?.skipped ?? "") ? response.skipped : null;
      if (skipped) {
        emit("checkpoint.error", {
          error: "Error",
          message: checkpointSkips[skipped],
          ...(skipped === "invalid" ? {} : { code: "FX_CHECKPOINT_TOO_LARGE" }),
          skipped,
        });
        return;
      }
      if (!Number.isSafeInteger(id) || id <= 0) return;
      const bytes = runtime.takeAttachment?.(id);
      // The core took it after every event this agent stored, and no later.
      if (!(bytes instanceof Uint8Array) || response.atSeq !== appendedSeq) return;
      const through = journalHead;
      const covered = bytesSinceCheckpoint;
      await persistence.saveCheckpoint({ through, data: new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength) });
      bytesSinceCheckpoint -= covered;
      emit("checkpoint.save", { through, bytes: bytes.byteLength });
    })().catch((error) => {
      emit("checkpoint.error", { error: error instanceof Error ? error.name : "Error", message: error?.message ?? "" });
    }).finally(() => { checkpointing = null; });
    return checkpointing;
  };
  const hostFetch = options.fetch ?? globalThis.fetch?.bind(globalThis);
  // Adds the host's credentials to the provider's own requests.
  const providerAuth = subscriptionProviders.has(options.provider)
    ? createSubscriptionAuthorizer([codexSubscription, grokSubscription], { credentials: options.credentials, onCredentials: options.onCredentials, refreshLock: options.refreshLock, fetch: hostFetch, memory: options[credentialMemory], sessionId: () => sessionId ?? undefined })
    : options.customProvider && options.credentials
      ? createSubscriptionAuthorizer([customProviderSpec(options.customProvider, () => sessionId)], { credentials: options.credentials, fetch: hostFetch })
      : null;
  const transportFetch = async (input, init = {}) => {
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    let endpoint = String(input?.url ?? input);
    let path = null;
    try {
      const url = new URL(endpoint);
      endpoint = `${url.origin}${url.pathname}`;
      path = url.pathname;
    } catch {}
    const catalogRequest = method === "GET" && path === "/coding-agent/v1/models";
    // A supplied catalog answers the core's catalog request without the network.
    if (options.modelCatalogBody && catalogRequest) {
      return new Response(options.modelCatalogBody, { status: 200, headers: { "content-type": "application/json" } });
    }
    // So does one this engine's agent already fetched from the same URL.
    if (catalogRequest && options[catalogMemory]) {
      return rememberedCatalog(options[catalogMemory], String(input?.url ?? input), init.signal ?? input?.signal, () => networkFetch(input, init, method, endpoint));
    }
    if (journal && (journalFailure || journalInFlightSteps || journalQueue.some(holdsStep))) {
      // A model request carries the turn's steps. It waits for the store's
      // answer to the appends that hold them, however long that takes, and
      // never goes out once the store refused one, as a fenced store does
      // (DUR-30). On AI Gateway the core has already waited, at the
      // progress before the request (`setJournalProgress` in
      // src/acp/prompt.zig); other providers write no such progress. A
      // turn's first request holds no step and runs ahead (DUR-18): its
      // prompt is in the store already, or in the session's log.
      await journalAnswered().catch(() => {});
      if (journalFailure) {
        runtime.abortHostEffects();
        throw new DOMException("Aborted", "AbortError");
      }
    }
    return networkFetch(input, init, method, endpoint);
  };
  const networkFetch = async (input, init, method, endpoint) => {
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
        const spec = providerAuth?.specFor(endpoint);
        const response = spec
          ? await providerAuth.fetch(spec, endpoint, hostFetch, input, init)
          : await hostFetch(input, init);
        if (spec && activeTurn) activeTurn.refreshError = null;
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
        // A failed refresh may have spent the refresh token, so the request
        // is not sent again; the turn it fails reports why.
        if (error?.[refreshFailed]) {
          if (activeTurn) activeTurn.refreshError = error;
          throw error;
        }
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
  // A typed tool result's images go in the image store by name before the
  // result reaches the core, as a prompt's do, so the session's records name
  // them. The tool has already run, so an image the store refuses is not
  // lost: it stays in the result, and the records hold it inline.
  const storedToolContent = async (value) => {
    const normalized = hostToolContent(value);
    if (!imageStore || !normalized.images?.some((image) => image.data !== undefined)) return normalized;
    const stored = new Map();
    for (const image of normalized.images) {
      if (image.data === undefined || stored.has(image.data)) continue;
      let bytes;
      // Data that is not base64 is the core's to refuse.
      try { bytes = base64ToBytes(image.data); } catch { continue; }
      const name = await imageName(bytes);
      try {
        await imageStorage.put(name, bytes);
        stored.set(image.data, name);
      } catch {
        // Not stored: the result keeps the image, and the records hold it
        // inline.
      }
    }
    return stored.size ? hostToolContent(value, stored) : normalized;
  };
  const executeHostTool = async (name, input, requestedSessionId, toolCallId) => {
    const execute = hostTools.executors.get(name);
    const issuerSessionId = requestedSessionId ?? sessionId;
    const scope = hookScopes.get(`${issuerSessionId}:${toolCallId}`);
    // Hook metadata is not authority to execute a foreign session's tool.
    const turn = issuerSessionId === sessionId
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
        // The model's call id is stable across restores of a persisted
        // session, so a tool can key its own retries on it.
        return execute(input, {
          signal: controller.signal,
          executionId: String(toolCallId ?? ""),
          sessionId: issuerSessionId,
          ...(options.hooks && scope ? { observation: toolObservation(scope, String(toolCallId), options.hooks, hook, controller.signal) } : {}),
          ...(options.toolContext === undefined ? {} : { context: options.toolContext }),
        });
      });
      const value = await Promise.race([execution, aborted]);
      if (!controller.signal.aborted) {
        const normalized = await storedToolContent(value);
        content = normalized.content;
        rich = normalized.rich;
        isError = normalized.isError === true;
      }
    } catch (error) {
      isError = true;
      if (error?.toolResult?.type === "libfx.tool-result") {
        try {
          const normalized = await storedToolContent(error.toolResult);
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
    journalFlush: () => journalAnswered(),
    // A cancel or deadline doesn't wait for this read, as it doesn't wait
    // for a tool. A turn that is no longer current, cancelled or with the
    // agent closing, can take no steer (startSteer), so it reads nothing and
    // waits for nothing: what the read would find stays in the log, for the
    // next turn or for the turn a deadline left open.
    takeInputs: () => {
      const turn = activeTurn;
      if (!isCurrentTurn(turn)) return Promise.resolve();
      const read = Promise.resolve().then(() => options[turnEndInputs]?.());
      const controller = new AbortController();
      turn.toolControllers.add(controller);
      const aborted = new Promise((_, reject) => {
        controller.signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
      });
      return Promise.race([read, aborted]).finally(() => turn.toolControllers.delete(controller));
    },
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
    const response = await request("libfx/checkpoint", { sessionId, checkpointMeta }).catch((error) => {
      // The core says which limit the conversation passed.
      if (String(error?.message ?? "").startsWith(checkpointTooLargePrefix)) error.code = "FX_CHECKPOINT_TOO_LARGE";
      throw error;
    });
    const id = response?.checkpointAttachment;
    const bytes = Number.isSafeInteger(id) && id > 0 ? runtime.takeAttachment?.(id) : null;
    if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) throw new Error("fx returned an invalid checkpoint");
    return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }
  // Stores each prompt image in the persistence's image store, by name,
  // before the prompt that carries it is sent: nothing the core writes may
  // name an image the store does not hold. Returns the blocks with their
  // names, or null when the prompt stopped meanwhile.
  async function storePromptImages(blocks, stopped) {
    const named = [];
    for (const block of blocks) {
      if (block.type !== "image" || block.bytes === undefined) {
        named.push(block);
        continue;
      }
      const name = await imageName(block.bytes);
      if (stopped()) return null;
      await imageStorage.put(name, block.bytes);
      if (stopped()) return null;
      named.push({ ...block, stored: name });
    }
    return named;
  }
  const sendPrompt = (blocks, resuming = false, followUp = null, turnId = null, rerun = [], yieldAt = undefined, outputShown = false) => {
    // A journaled turn given a time to stop at yields before its first model
    // request after it, keeping the turn open.
    const stopAt = journal && yieldAt !== undefined ? { yieldAt } : {};
    if (resuming) {
      return request("session/prompt", { sessionId, prompt: [], _meta: { fx: { continueRecovery: true, ...(outputShown ? {} : { freshOutput: true }), ...(rerun.length ? { rerun } : {}), ...stopAt } } });
    }
    const images = blocks.filter((block) => block.type === "image" && block.bytes !== undefined);
    const ids = images.length ? attachBytes(images.map((block) => block.bytes)) : [];
    let next = 0;
    const prompt = blocks.map((block) => block.type !== "image" ? block : {
      type: "image",
      mimeType: block.mimeType,
      ...(block.sourceRef === undefined ? {} : { sourceRef: block.sourceRef }),
      // An image the store holds carries its name, so the core names it too.
      ...(block.bytes === undefined ? {} : { _meta: { fx: { attachment: ids[next++], ...(block.stored === undefined ? {} : { stored: block.stored }) } } }),
    });
    // A follow-up's turn places it; the core records it as accepted first
    // when the host could not. A journaled turn's first progress records its id.
    const fx = {
      ...(followUp ? { inputId: followUp.id, inputAccepted: followUp.accepted } : {}),
      ...((journal || options.hooks) && turnId ? { turnId } : {}),
      ...stopAt,
    };
    return request("session/prompt", { sessionId, prompt, ...(Object.keys(fx).length ? { _meta: { fx } } : {}) });
  };
  runtime.exited.then((code) => {
    hookScopes.clear();
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
    if (message.method === "libfx/hook") {
      if (message.params?.rootSessionId === sessionId && message.params?.version === 1) {
        if (message.params.type === "turn.end" && handedOff) message.params.data.handoff = true;
        hook(message.params);
      }
      return;
    }
    emit("acp.receive", { message });
    if (message.method === "libfx/journal_append") {
      if (journal && message.params?.sessionId === sessionId) {
        queueJournalEvents(message.params.events, message.params.barrier === true);
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
      try { await journalAnswered(); } catch (error) { failure = error; }
      if (closing) return;
      send(failure
        ? { jsonrpc: "2.0", id: message.id, error: { code: -32000, message: failure.message } }
        : { jsonrpc: "2.0", id: message.id, result: {} });
      return;
    }
    if (message.method === "libfx/take_inputs") {
      // Before a turn ends, the session's worker hands in the inputs it
      // stored since it last read them. Each steer is written to the core as
      // it is found, so the core has it before this answer.
      let failure = null;
      try { await options[turnEndInputs]?.(); } catch (error) { failure = error; }
      if (closing) return;
      send(failure
        ? { jsonrpc: "2.0", id: message.id, error: { code: -32000, message: String(failure?.message ?? failure) } }
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

    const loaded = persistence ? await loadPersistence(persistence) : null;
    const requestedSessionId = options.sessionId ?? null;
    const sessionResult = await request("libfx/new", {
      ...(requestedSessionId === null ? {} : { sessionId: requestedSessionId }),
      ...(options.hooks ? { hooks: { captureContent: options.hooks.captureContent === true } } : {}),
    });
    sessionId = sessionResult.sessionId;
    if (options.hooks && sessionResult?._meta?.fx?.hooksVersion !== 1) throw new Error("Semantic hooks require a matching libfx core with hooks version 1");
    if (initialCheckpoint) {
      const [checkpointAttachment] = attachBytes([initialCheckpoint]);
      const restored = await request("libfx/restore", { sessionId, checkpointAttachment }).catch((error) => {
        if (/newer fx/.test(error?.message ?? "")) throw new FxJournalVersionError(error.message);
        throw error;
      });
      compareCheckpointMeta(restored?.checkpointMeta);
    }
    if (journal) {
      const { events, checkpoint } = loaded;
      const journalBytes = events.length > 0 ? encoder.encode(JSON.stringify(withoutSupersededProgress(events))) : null;
      if (journalBytes && journalBytes.byteLength > maxJournalBytes) throw journalLoadError("libfx journal is too large", "FX_JOURNAL_TOO_LARGE");
      const openFailed = (error) => {
        const message = error?.message ?? "";
        if (/newer fx/.test(message)) throw new FxJournalVersionError(message);
        const code = journalOpenErrorCodes.get(message);
        if (code) throw journalLoadError(message, code, error);
        throw error;
      };
      const openOnce = () => {
        const params = {
          sessionId,
          ...(options.inputsDurable === true ? { inputsDurable: true } : {}),
          ...(imageStore ? { imageStore: true } : {}),
          ...(imageStore && options[imageWindowLimits] ? { imageWindow: options[imageWindowLimits] } : {}),
        };
        // One call: attaching again would drop the first attachment.
        const attachments = [];
        if (journalBytes) attachments.push(["journalAttachment", journalBytes]);
        if (checkpoint) attachments.push(["snapshotAttachment", checkpoint]);
        const ids = attachments.length ? attachBytes(attachments.map(([, bytes]) => bytes)) : [];
        attachments.forEach(([name], index) => { params[name] = ids[index]; });
        return request("libfx/journal_open", params).catch(openFailed);
      };
      // Stages the images a history names, read from the store, in batches
      // the attachment table holds. Up to `maxImageReads` reads run at once,
      // and the next ones start while a batch is staged, so an open waits on
      // a slow store about once per batch, not once per image, and holds at
      // most two batches' bytes. The images stage in the history's order. A
      // store that lacks one fails the open, naming the first one the
      // history names that it lacks, once every read the open started has
      // settled: the history without it is not the one saved.
      const stageImages = async (names) => {
        const wanted = [...new Set(names.map(String))];
        const read = (name) => {
          const reading = (async () => {
            const stored = imageStore ? await imageStorage.get(name) : undefined;
            if (stored === undefined || stored === null) throw imageMissingError(name);
            return { name, bytes: persistenceBytes(stored, "an image the image store returns") };
          })();
          // A read after one that failed is still waited for, below.
          reading.catch(() => {});
          return reading;
        };
        const reading = [];
        let next = 0;
        let batch = [];
        let batchBytes = 0;
        const flush = async () => {
          if (batch.length === 0) return;
          const ids = attachBytes(batch.map(({ bytes }) => bytes));
          const images = batch.map(({ name }, index) => ({ name, attachment: ids[index] }));
          batch = [];
          batchBytes = 0;
          await request("libfx/journal_images", { sessionId, images }).catch(openFailed);
        };
        try {
          while (next < wanted.length || reading.length > 0) {
            while (reading.length < maxImageReads && next < wanted.length) reading.push(read(wanted[next++]));
            const { name, bytes } = await reading[0];
            reading.shift();
            if (batch.length === maxPendingAttachments || batchBytes + bytes.byteLength > maxPendingAttachmentBytes) await flush();
            batch.push({ name, bytes });
            batchBytes += bytes.byteLength;
          }
          await flush();
        } catch (error) {
          await Promise.allSettled(reading);
          throw error;
        }
      };
      // A history that names images opens once they are staged from the
      // store: the core answers with the names it needs, all at once.
      let opened = await openOnce();
      if (Array.isArray(opened?.imagesNeeded)) {
        await stageImages(opened.imagesNeeded);
        opened = await openOnce();
        if (Array.isArray(opened?.imagesNeeded)) throw imageMissingError(String(opened.imagesNeeded[0]));
      }
      // A session too short to have saved a checkpoint has no saved meta.
      // Each model request's progress names the model it went to, so the
      // newest one says what such a session last ran on.
      const recordedModel = opened?.checkpointMeta || checkpointMeta.model === ""
        ? undefined
        : events.findLast((event) => event?.type === "turn_progress" && typeof event.model === "string" && event.model !== "")?.model;
      compareCheckpointMeta(recordedModel === undefined ? opened?.checkpointMeta : { model: recordedModel });
      resumable = opened?.resumable === true;
      openTurnId = resumable && validTurnId(opened?.openTurnId) ? opened.openTurnId : null;
      lastTurnId = validTurnId(opened?.lastTurnId) ? opened.lastTurnId : null;
      // A turn that ended before the checkpoint says nothing of how.
      noteJournalEnds(events);
      if (validTurnId(opened?.openTurnId)) journalTurn = opened.openTurnId;
      ambiguousCalls = resumable && Array.isArray(opened?.runningCalls)
        ? opened.runningCalls.filter((call) => typeof call?.id === "string" && typeof call.name === "string")
        : [];
      journalHead = loaded.head;
      appendedSeq = loaded.lastSeq;
      bytesSinceCheckpoint = loaded.tailBytes;
      // Follow-ups the journal holds, as accepted; each waits for `resume()`.
      for (const held of Array.isArray(opened?.followUps) ? opened.followUps : []) {
        followUps.push({ id: held.id, text: held.text, accepted: true, held: true });
      }
      emit("journal.open", { events: events.length, checkpoint: checkpoint !== null, turns: opened?.turns, resumable });
      journalHook("journal.restore", { cursor: loaded.head, lastSeq: loaded.lastSeq, resumable, openTurnId, lastTurnId });
    }
  } catch (error) {
    closing = true;
    try { runtime.abortHostEffects(); } catch {}
    try { runtime.closeStdin(); } catch {}
    try { await runtime.exited; } catch {}
    throw error;
  }

  const agent = {
    get sessionId() {
      return sessionId;
    },
    // What libfx's session worker needs beyond the public surface.
    [engineInternals]: {
      // Resolves once every record the session started has landed: a
      // turn's result does not wait for its last ones.
      settled() {
        return journal ? journalSettled() : Promise.resolve();
      },
      // Saves a checkpoint now, at a turn's end or where it yielded, whatever
      // has accumulated since the last; resolves once it is stored or skipped.
      checkpoint() {
        return maybeCheckpoint(true);
      },
      // Resolves when the core this agent runs on exits.
      exited: runtime.exited,
      // The turn the journal left open, if any, and the calls it left
      // running, as `{ executionId, name, input }`.
      get openTurn() {
        if (!resumable) return null;
        return {
          id: openTurnId,
          calls: ambiguousCalls.map((call) => ({ executionId: call.id, name: call.name, input: parsedToolInput(call.arguments) })),
        };
      },
    },
    /**
     * Starts a turn. With `turnId`, a retried call is the same turn: when the
     * journal left that turn open, this continues it as `resume()` does, and
     * when that turn already ended, this returns a turn that has ended too,
     * without running it again.
     */
    prompt(input, promptOptions = {}) {
      if (closing) throw new Error("fx agent is closed");
      if (journalFailure) throw reportJournalFailure();
      if (handedOff) throw handedOffError();
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      const turnId = promptOptions.turnId;
      if (turnId !== undefined && !validTurnId(turnId)) throw new TypeError(`turnId must be ${turnIdRule}`);
      checkOnAmbiguous(promptOptions.onAmbiguous);
      if (turnId !== undefined && journal) {
        if (resumable && turnId === openTurnId) {
          resumable = false;
          return resumeOpenTurn(promptOptions);
        }
        if (turnId === lastTurnId) return endedTurn(turnId);
      }
      // A new prompt ends a turn the last process left open as interrupted.
      resumable = false;
      ambiguousCalls = [];
      return normalizeTurn(startTurn(input, { ...promptOptions, turnId: turnId ?? `turn_${crypto.randomUUID()}` }));
    },
    /**
     * Continues the turn the last process left open, with no new input, and
     * returns it; returns null when the journal holds no open turn. The
     * model is told the session was interrupted; calls that were running
     * come back answered as possibly run, for the model to decide about,
     * unless `onAmbiguous(call)` returns "rerun" for them.
     */
    resume(promptOptions = {}) {
      if (closing) throw new Error("fx agent is closed");
      if (journalFailure) throw reportJournalFailure();
      if (handedOff) throw handedOffError();
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      checkOnAmbiguous(promptOptions.onAmbiguous);
      if (resumable) {
        resumable = false;
        return resumeOpenTurn(promptOptions);
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
    /**
     * The session's state as opaque bytes, when no prompt is running; pass
     * them as `checkpoint` to restore it in a new agent.
     */
    checkpoint() {
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
      hookScopes.clear();
      if (closing) {
        await runtime.exited;
        if (journal) await closeJournal();
        return;
      }
      const turn = activeTurn;
      turn?.cancel();
      if (turn) await turn.result.catch(() => {});
      // A checkpoint being taken needs the core; it finishes first.
      await checkpointing;
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

  // `answered`: calls a resumed turn answers as possibly run before it goes
  // on, whose `tool_end` comes first.
  function normalizeTurn(rawTurn, answered = []) {
    const toolNames = new Map();
    const started = new Set();
    const ended = new Set();
    let handoff = false;
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
        // A steer shows where it joined the turn, with the id it was sent with.
        const id = update._meta?.fx?.steering?.inputId;
        return { type: "user_message", text: update.content.text, ...(typeof id === "string" ? { id } : {}) };
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
        ended.add(update.toolCallId);
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
      ...(value.error ? { error: value.error } : {}),
    }));
    void result.catch(() => {});
    return {
      id: rawTurn.id ?? null,
      cancel(cancelOptions) {
        if (cancelOptions?.reason === "handoff") handoff = true;
        rawTurn.cancel(cancelOptions);
      },
      steer(input, id) {
        if (id !== undefined && !validTurnId(id)) throw new TypeError(`steer id must be ${turnIdRule}`);
        return rawTurn.steer(normalizeSteeringInput(input), id);
      },
      withdraw(id) { return rawTurn.withdraw(id); },
      [engineInternals]: rawTurn[engineInternals],
      [Symbol.asyncIterator]() {
        const iterator = (async function* () {
          for (const call of answered) {
            yield { type: "tool_end", id: call.id, name: call.name, content: unfinishedToolOutput, isError: true };
          }
          for await (const update of rawTurn) {
            const event = eventFor(update);
            if (event) yield event;
          }
          // A cancelled turn ends every call it showed. One the core never
          // ended, such as a provider search the cancel cut off, ends failed,
          // with no result. A handed-off turn's calls continue elsewhere.
          if (handoff || (await rawTurn.result.catch(() => null))?.stopReason !== "cancelled") return;
          for (const id of started) {
            if (!ended.has(id)) yield { type: "tool_end", id, name: toolNames.get(id) || "tool", isError: true };
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

  // A turn the journal shows already ended, returned for a retried prompt.
  // A retried prompt of the turn that ended last reports how the journal
  // says it ended (DUR-20): one that failed fails again, saying so, and an
  // end an earlier libfx wrote, which does not say, reports end_turn.
  function endedTurn(id) {
    const recorded = lastTurnEnd?.id === id ? lastTurnEnd.stopReason : null;
    const result = recorded === "error"
      ? Promise.reject(new Error(`turn ${id} already ran and failed; prompt with a new turnId to run it again`))
      : Promise.resolve({ stopReason: recorded ?? "end_turn", usage: {} });
    void result.catch(() => {});
    return {
      id,
      result,
      cancel() {},
      steer() { return Promise.reject(new Error("no prompt is running")); },
      withdraw() { return Promise.resolve("already_placed"); },
      async *[Symbol.asyncIterator]() {},
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
    const normalized = resuming ? [] : checkPromptInput(input, { resizeImage });
    const hasPixels = normalized.some((block) => block.type === "image" && block.data !== undefined);
    // Blob reads, resizeImage and storing images run before the prompt
    // frame is sent.
    const asyncImages = hasPixels && (resizeImage !== undefined || imageStore ||
      normalized.some((block) => block.type === "image" && block.source === "blob"));
    // Snapshot caller-owned bytes, which could change before an async send.
    const prompt = asyncImages
      ? normalized.map((block) => block.type === "image" && block.source === "bytes" ? { ...block, data: block.data.slice() } : block)
      : preparePromptImages(normalized);
    const signal = promptOptions.signal;
    if (signal !== undefined && (typeof signal?.addEventListener !== "function" || typeof signal?.removeEventListener !== "function")) throw new TypeError("prompt signal must be an AbortSignal");
    const yieldAt = promptOptions.yieldAt;
    if (yieldAt !== undefined && !(Number.isSafeInteger(yieldAt) && yieldAt > 0)) throw new TypeError("yieldAt must be a time in milliseconds since the epoch");
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
            // The web core accepts it when it takes it at the next boundary,
            // and shows where it joined the turn then.
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
    // Calls whose start the turn's events showed and whose end they did not.
    const shownCalls = new Set();
    // The provider's error a refused turn ended with (API-48, QUAL-18).
    let providerError = null;
    let finished = false;
    let cancelled = false;
    // How the record that ends this turn says it ended, once that record is
    // on its way to the store: undefined until then, and null for an end
    // that does not say. A resumed turn's first progress is in the journal
    // already; a new turn's end follows its own.
    let recordedEnd;
    let progressed = resuming;
    // What the core sent after a cancel, until the turn's end says whether
    // the cancel came in time.
    const held = [];
    let heldBytes = 0;
    // Hands an update to the turn's reader, or queues it for the next read.
    const deliver = (update, size) => {
      if (update?.sessionUpdate === "tool_call") shownCalls.add(update.toolCallId);
      else if (update?.sessionUpdate === "tool_call_update" && (update.status === "completed" || update.status === "failed")) shownCalls.delete(update.toolCallId);
      const waiter = waiters.shift();
      if (waiter) waiter.resolve({ value: update, done: false });
      else { queue.push({ update, size }); queuedBytes += size; }
    };
    const turn = {
      // The host's id: the one it gave, or for a resumed turn, the one the
      // turn started with.
      id: resuming ? openTurnId : promptOptions.turnId ?? null,
      push(update, size = encoder.encode(JSON.stringify(update)).length) {
        // A libfx core sends the text fx adds beside the reply as notices:
        // the provider's error goes in the result, any other to onEvent.
        if (update?.sessionUpdate === "notice") {
          const text = String(update.title ?? "");
          if (update.severity === "error") providerError = text;
          else if (!cancelled && !finished) emit("turn.notice", { sessionId, text });
          return;
        }
        const ended = update?.sessionUpdate === "tool_call_update" && (update.status === "completed" || update.status === "failed");
        if (cancelled || finished) {
          // A call the events showed still gets the end the core gave it,
          // unless the turn was handed off for another agent to continue.
          if (finished || handedOff || !ended || !shownCalls.has(update.toolCallId)) {
            // What the core sent after a cancel waits for the turn's end,
            // which says whether the cancel came in time (`noteRecords`).
            if (!finished && !handedOff && recordedEnd === undefined && journal && size <= maxUnreadEventBytes - heldBytes) {
              held.push({ update, size });
              heldBytes += size;
            } else {
              discardedBytes += size;
            }
            return;
          }
        }
        if (size > maxCoreMessageBytes) throw new RangeError("core output message exceeds 64 MiB");
        if (queue.length && (queue.length >= maxUnreadEvents || size > maxUnreadEventBytes - queuedBytes)) {
          const capacity = new Promise((resolveCapacity) => { resumeOutput = resolveCapacity; });
          if (!reportedPressure) {
            reportedPressure = true;
            emit("output.backpressure", { bufferedBytes: queuedBytes, bufferedEvents: queue.length });
          }
          return capacity.then(() => turn.push(update, size));
        }
        deliver(update, size);
      },
      // This turn's records as they go to the store. Once the record that
      // ends the turn is on its way, the turn ended as that record says: a
      // cancel the core took too late to stop it stops nothing, and what the
      // core sent after it is the turn's (DUR-20, DUR-64;
      // `tests/tla/durable/Resumption.tla` ResultSaysHow).
      noteRecords(events) {
        for (const event of events) {
          if (event?.type === "turn_progress") progressed = true;
          else if (progressed && recordedEnd === undefined && isJournalEnd(event)) {
            recordedEnd = journalEndReason(event);
            const late = held.splice(0);
            heldBytes = 0;
            // An end that says the turn finished overrides a cancel the core
            // took too late; one that says it failed does not, since a cancel
            // that comes first is why its request failed.
            if (cancelled && recordedEnd !== null && recordedEnd !== "cancelled" && recordedEnd !== "error") {
              cancelled = false;
              for (const { update, size } of late) deliver(update, size);
            } else {
              for (const { size } of late) discardedBytes += size;
            }
          }
        }
      },
      toolControllers,
      transportAttempts: 0,
      transportBytes: 0,
      lastTransportActivityAt: null,
      // A failed refresh that stopped one of the turn's requests, until a
      // later request with credentials succeeds.
      refreshError: null,
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
      steer(text, id = `in_${crypto.randomUUID()}`) {
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
      // For libfx's session worker: a steer that cannot join the turn, such
      // as one with images, ends the turn at its next safe point, at once
      // while the model streams a reply, so that steer can run next.
      [engineInternals]: {
        endForSteer() {
          const send = () => {
            if (finished || cancelled || activeTurn !== turn || closing) return undefined;
            if (typeof runtime.handOffSteering === "function") {
              runtime.handOffSteering();
              return undefined;
            }
            return request("libfx/handoff", { sessionId }).then(() => undefined);
          };
          const sent = promptStarted && resolvePromptStart ? promptStarted.then((started) => (started === true ? send() : undefined)) : Promise.resolve().then(send);
          return sent.catch(() => {});
        },
      },
      cancel(cancelOptions = {}) {
        const reason = cancelOptions?.reason;
        if (reason !== undefined && reason !== "handoff") throw new TypeError('cancel() reason must be "handoff" when given');
        if (reason === "handoff" && !journal) throw new TypeError("a handoff needs persistence to keep the turn in");
        // A turn whose end is on its way to the store has ended, as that end
        // says; there is nothing left to stop or hand off.
        if (finished || cancelled || recordedEnd !== undefined) return;
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
        // The web core hears of the cancel at once through its steering, so
        // an end it writes before it reads `session/cancel` says cancelled.
        if (typeof runtime.cancelSteering === "function") runtime.cancelSteering();
        else runtime.closeSteering?.();
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
      const stopped = () => cancelled || closing;
      response = Promise.race([
        Promise.resolve()
          .then(() => materializePromptImages(prompt, stopped, resizeImage))
          .then((prepared) => prepared && imageStore ? storePromptImages(prepared, stopped) : prepared),
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
        return sendPrompt(prepared, false, followUp, turn.id, [], yieldAt);
      });
    } else {
      try { response = sendPrompt(prompt, resuming, followUp, turn.id, promptOptions[rerunCallIds] ?? [], yieldAt, promptOptions[resumeOutputShown] === true); } catch (error) { response = Promise.reject(error); }
    }
    // Appends after a turn's first progress are lazy, so the turn runs ahead
    // of them, but its result waits until every record it wrote is stored:
    // a turn counts as done only once its end is durable, and a failure
    // among those records fails the turn.
    turn.result = response
      .then(async (value) => {
        if (journal) await journalSettled().catch(() => {});
        if (journalFailure) throw reportJournalFailure();
        if (value.stopReason === "yielded" && !cancelled) {
          // The core keeps the turn open: `resume()` continues it here, or
          // a later agent continues it from the journal.
          resumable = true;
          openTurnId = turn.id;
          ambiguousCalls = [];
        } else if (!handedOff) {
          // A handed-off turn stays open for the next agent.
          if (turn.id) lastTurnId = turn.id;
          openTurnId = null;
        }
        // A turn whose end went to the store ended as that end says, and
        // the result resolves from it (DUR-20).
        const stopReason = recordedEnd ?? (cancelled ? "cancelled" : value.stopReason);
        const refused = stopReason === "refused" && providerError !== null;
        return { stopReason, usage: value.usage, ...(refused ? { error: { name: "Error", message: providerError } } : {}) };
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
        // The core says only that a request failed; the refresh says why.
        terminalError = turn.refreshError ?? error;
        if (terminalError !== error) {
          try { terminalError[coreAnswered] = true; } catch {}
        }
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
        queueMicrotask(() => { void maybeCheckpoint(); });
        runtime.closeSteering?.();
        toolControllers.clear();
        // What a cancel stopped and no end of this turn ever said otherwise.
        for (const { size } of held.splice(0)) discardedBytes += size;
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
