import {
  decodeCheckpoint, decodeEntry, hashBytes, JournalConflict, parseJournalJson, parseToolInput,
  PendingTurnError, RequestConflict, normalizeTurnUsage,
} from "./journal-codec.js";

const encoder = new TextEncoder();
const strictUtf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const displayUtf8 = new TextDecoder("utf-8", { ignoreBOM: true });
const usageFields = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens"];
const stopReasons = new Set(["stop", "length", "tool_limit"]);
const failureReasons = new Set(["cancelled", "interrupted", "refused", "provider_error", "timeout"]);

function requireValue(condition, message) {
  if (!condition) throw new JournalConflict(message);
}

function object(value, label) {
  requireValue(value !== null && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  return value;
}

function string(value, label, empty = false) {
  requireValue(typeof value === "string" && (empty || value.length > 0), `${label} must be a string`);
  return value;
}

function boolean(value, label) {
  requireValue(typeof value === "boolean", `${label} must be a boolean`);
  return value;
}

function durableBytes(value, label) {
  if (typeof value === "string") return null;
  object(value, label);
  requireValue(Object.keys(value).join(",") === "encoding,data" && value.encoding === "base64" && typeof value.data === "string", `Invalid durable bytes for ${label}`);
  let binary;
  try { binary = atob(value.data); } catch { throw new JournalConflict(`Invalid base64 for ${label}`); }
  requireValue(btoa(binary) === value.data, `Noncanonical base64 for ${label}`);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  let validUtf8 = true;
  try { strictUtf8.decode(bytes); } catch { validUtf8 = false; }
  requireValue(!validUtf8, `UTF-8 ${label} must use the string representation`);
  return bytes;
}

function userParts(input) {
  const bytes = durableBytes(input.text, "UserTurn text");
  requireValue(Array.isArray(input.images), "UserTurn images must be an array");
  const parts = [{ type: "text", text: bytes ? displayUtf8.decode(bytes) : input.text }];
  for (const image of input.images) {
    object(image, "UserTurn image");
    requireValue(Number.isSafeInteger(image.id) && image.id >= 0, "Invalid image identity");
    durableBytes(image.path, "image path");
    durableBytes(image.media_type, "image media type");
    const part = { type: "image", id: image.id, path: image.path, mimeType: image.media_type };
    requireValue((image.snapshot_path == null) === (image.snapshot_sha256 == null), "Incomplete image snapshot reference");
    if (image.snapshot_path != null) {
      durableBytes(image.snapshot_path, "image snapshot path");
      durableBytes(image.snapshot_sha256, "image snapshot hash");
      part.snapshotPath = image.snapshot_path;
      part.snapshotSha256 = image.snapshot_sha256;
    }
    parts.push(part);
  }
  return parts;
}

function freeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
}

function equal(a, b) {
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && equal(a[key], b[key]));
}

function usage(value) {
  if (value == null) return {};
  object(value, "usage");
  const result = {};
  for (const key of usageFields) {
    if (value[key] == null) continue;
    requireValue(Number.isSafeInteger(value[key]) && value[key] >= 0, `Invalid usage ${key}`);
    result[key] = value[key];
  }
  return result;
}

function addUsage(target, incoming, previous = {}) {
  const result = { ...target };
  for (const key of usageFields) {
    if (incoming[key] === undefined && previous[key] === undefined) continue;
    const total = (target[key] ?? 0) - (previous[key] ?? 0) + (incoming[key] ?? 0);
    requireValue(Number.isSafeInteger(total) && total >= 0, `Usage total exceeds safe range for ${key}`);
    result[key] = total;
  }
  return result;
}

function emptyState() {
  return {
    lastSeq: 0, seen: new Map(), records: [], requests: new Map(),
    turnIds: new Set(), messageIds: new Set(), callIds: new Set(), generationIds: new Set(),
    model: "", usage: {}, messages: [], pending: null, nativeBase: null,
  };
}

function fork(state) {
  return {
    ...state, seen: new Map(state.seen), records: state.records.slice(), requests: new Map(state.requests),
    turnIds: new Set(state.turnIds), messageIds: new Set(state.messageIds), callIds: new Set(state.callIds), generationIds: new Set(state.generationIds),
    messages: state.messages.slice(), pending: state.pending ? { ...state.pending } : null,
  };
}

function updateMessage(state, index, message, changed) {
  state.messages[index] = freeze(message);
  changed.push(state.messages[index]);
}

function pendingCall(state) {
  return state.pending?.calls[state.pending.resultCount];
}

function validateTurn(state, body) {
  requireValue(state.pending !== null, "Journal record has no pending turn");
  requireValue(body.turnId === state.pending.turnId, "Journal turn identity does not match the pending turn");
}

function applyBody(state, body, changed) {
  if (state.pending && body.kind !== "tool_result" && body.kind !== "turn_end") state.pending.providerTerminal = false;
  switch (body.kind) {
    case "turn_start": {
      if (state.pending !== null) throw new PendingTurnError();
      for (const key of ["turnId", "userMessageId", "requestId", "inputHash", "model", "namespace", "runtimeTurnId", "inputJson"]) string(body[key], key);
      requireValue(hashBytes(encoder.encode(body.inputJson)) === body.inputHash, "Input hash does not match inputJson");
      if (state.requests.has(body.requestId)) throw new RequestConflict();
      requireValue(!state.turnIds.has(body.turnId), "Duplicate turn identity");
      requireValue(!state.messageIds.has(body.userMessageId), "Duplicate message identity");
      if (state.nativeBase) requireValue(body.namespace === state.nativeBase.id, "Native journal namespace changed");
      const input = object(parseJournalJson(body.inputJson), "UserTurn");
      const parts = userParts(input);
      state.model = body.model;
      state.turnIds.add(body.turnId);
      state.messageIds.add(body.userMessageId);
      state.requests.set(body.requestId, freeze({ inputHash: body.inputHash, turnId: body.turnId, complete: false }));
      state.pending = { turnId: body.turnId, requestId: body.requestId, calls: [], resultCount: 0, final: false, messageIndex: null, usage: {}, stepCount: 0, steeringCount: 0 };
      updateMessage(state, state.messages.length, {
        id: body.userMessageId, turnId: body.turnId, role: "user", status: "complete",
        parts,
      }, changed);
      break;
    }
    case "model_step": {
      if (body.phase === "context") {
        requireValue(body.change === undefined || body.change === "compaction" || body.change === "steering", "Unknown context change");
        requireValue(body.afterTurnCount === state.requests.size, "Context replacement has the wrong turn boundary");
        requireValue(body.turnId === (state.pending?.turnId ?? null), "Context replacement has the wrong pending turn");
        requireValue(!("completion" in body) && !("calls" in body) && !("generationId" in body), "Context replacement cannot select work");
        if (body.change === "steering") {
          requireValue(state.pending && !pendingCall(state), "Steering requires a settled execution boundary");
          requireValue(body.afterStepCount === state.pending.stepCount, "Steering has the wrong model boundary");
          requireValue(Array.isArray(body.guidance) && body.guidance.length > 0 && body.guidance.length <= 16384, "Invalid steering messages");
          requireValue(!("summary" in body) && !("retainedFrom" in body) && !("activeThrough" in body), "Steering cannot replace model history");
          const reservation = state.pending.reservation;
          const expectedDraft = reservation ? { turnId: body.turnId, messageId: reservation.messageId, generationId: reservation.generationId } : null;
          requireValue(equal(body.retiredDraft, expectedDraft), "Steering retires an unrelated draft");
          const firstId = `${body.turnId}:steering:${state.pending.steeringCount + 1}`;
          if (body.prefix !== null) {
            const prefix = object(body.prefix, "steering prefix");
            requireValue(Object.keys(prefix).length === 2 && prefix.id === `${firstId}:assistant` && !state.messageIds.has(prefix.id), "Invalid steering prefix identity");
            state.messageIds.add(prefix.id);
            updateMessage(state, state.messages.length, { id: prefix.id, turnId: body.turnId, role: "assistant", status: "complete", parts: [{ type: "text", text: string(prefix.text, "steering prefix", true) }] }, changed);
          }
          for (const item of body.guidance) {
            const message = object(item, "steering message");
            const id = `${body.turnId}:steering:${++state.pending.steeringCount}`;
            requireValue(Object.keys(message).length === 2 && message.id === id && !state.messageIds.has(id), "Invalid steering identity");
            state.messageIds.add(id);
            updateMessage(state, state.messages.length, { id, turnId: body.turnId, role: "user", status: "complete", parts: [{ type: "text", text: string(message.text, "steering text", true) }] }, changed);
          }
          state.pending.final = false;
          state.pending.messageIndex = null;
          break;
        }
        requireValue(!state.pending || (!pendingCall(state) && !state.pending.final), "Context replacement precedes the selected decision's completion");
        requireValue(object(body.summary, "context summary").kind === "compacted_summary", "Invalid context summary");
        projectLegacyPayload({ history: [body.summary], usage: {} }, 2, 1);
        const cut = object(body.retainedFrom, "context boundary");
        requireValue(Object.keys(cut).length === 3, "Invalid context boundary");
        for (const name of ["turns", "tool_steps", "steering"]) legacyInteger(cut[name], name);
        if (body.activeThrough !== undefined) {
          requireValue(state.pending && body.afterStepCount === state.pending.stepCount, "Active compaction has the wrong model boundary");
          const through = object(body.activeThrough, "active compaction boundary");
          requireValue(Object.keys(through).length === 2, "Invalid active compaction boundary");
          legacyInteger(through.tool_steps, "active tool steps");
          legacyInteger(through.steering, "active steering");
          const prior = state.pending.activeThrough ?? { tool_steps: 0, steering: 0 };
          requireValue(through.tool_steps >= prior.tool_steps && through.steering >= prior.steering &&
            through.tool_steps <= state.pending.stepCount && through.steering <= state.pending.steeringCount, "Invalid active compaction boundary");
          state.pending.activeThrough = through;
        } else requireValue(body.afterStepCount === undefined, "Missing active compaction boundary");
        break;
      }
      validateTurn(state, body);
      requireValue(!pendingCall(state) && !state.pending.final, "Model step precedes the prior decision's completion");
      string(body.messageId, "messageId");
      string(body.generationId, "generationId");
      requireValue(body.phase === undefined || body.phase === "request" || body.phase === "decision", "Unknown model step phase");
      if (body.phase === "request") {
        requireValue(!("completion" in body) && !("calls" in body) && !("final" in body), "A request reservation cannot contain a model decision");
        object(body.executionContext, "request execution context");
        requireValue(!state.messageIds.has(body.messageId), "Request reservation reuses a completed message");
        requireValue(!state.generationIds.has(body.generationId), "Duplicate request generation");
        requireValue((body.supersedesGenerationId ?? null) === (state.pending.reservation?.generationId ?? null), "Request supersedes an unrelated generation");
        if (state.pending.reservation) requireValue(body.messageId === state.pending.reservation.messageId, "Retry changed its message identity");
        state.generationIds.add(body.generationId);
        state.pending.reservation = { messageId: body.messageId, generationId: body.generationId };
        break;
      }
      if (state.pending.reservation) {
        requireValue(body.messageId === state.pending.reservation.messageId && body.generationId === state.pending.reservation.generationId, "Decision does not match the reserved generation");
      }
      boolean(body.final, "final");
      object(body.completion, "completion");
      requireValue(Array.isArray(body.calls) && body.calls.length <= 256, "Invalid selected calls");
      requireValue(!body.final || body.calls.length === 0, "Final model step cannot select tools");
      requireValue(!state.messageIds.has(body.messageId), "Duplicate message identity");
      const parts = [];
      if (body.completion.content != null) parts.push({ type: "text", text: string(body.completion.content, "completion content", true) });
      const calls = body.calls.map((call) => {
        object(call, "selected call");
        for (const key of ["callId", "providerId", "name", "argumentsJson"]) string(call[key], key);
        requireValue(call.replay === "safe" || call.replay === "blocked", "Invalid tool replay policy");
        requireValue(!state.callIds.has(call.callId), "Duplicate tool call identity");
        state.callIds.add(call.callId);
        const input = parseToolInput(call.argumentsJson);
        parts.push({ type: "tool_call", callId: call.callId, name: call.name, input, status: "pending" });
        return { callId: call.callId, name: call.name, input };
      });
      state.pending.providerTerminal = body.completion.finish_reason === "stop" &&
        typeof body.completion.content === "string" && body.completion.content.length > 0 &&
        body.calls.length > 0 && body.calls.every((call) => call.provenance === "provider_executed" &&
          typeof call.provider_result === "string" && call.provider_result.length > 0);
      const stepUsage = usage(body.completion.usage);
      state.usage = addUsage(state.usage, stepUsage);
      state.pending.usage = addUsage(state.pending.usage, stepUsage);
      state.pending.calls = calls;
      state.pending.resultCount = 0;
      state.pending.final = body.final;
      state.pending.messageIndex = state.messages.length;
      state.pending.reservation = null;
      state.pending.stepCount++;
      state.messageIds.add(body.messageId);
      updateMessage(state, state.messages.length, {
        id: body.messageId, turnId: body.turnId, role: "assistant",
        status: calls.length ? "running" : "complete", parts,
      }, changed);
      break;
    }
    case "tool_result": {
      validateTurn(state, body);
      const call = pendingCall(state);
      requireValue(call && body.callId === call.callId, "Tool result does not match the next selected call");
      string(body.content, "tool result content", true);
      boolean(body.isError, "tool result isError");
      const index = state.pending.messageIndex;
      const current = state.messages[index];
      const parts = current.parts.map((part) => part.type === "tool_call" && part.callId === call.callId ? { ...part, status: "complete" } : part);
      parts.push({ type: "tool_result", callId: body.callId, content: body.content, isError: body.isError });
      state.pending.resultCount++;
      updateMessage(state, index, { ...current, parts, status: pendingCall(state) ? "running" : "complete" }, changed);
      const persisted = body.persisted === undefined ? {} : object(body.persisted, "persisted tool result");
      const feedback = persisted.permission_feedback === undefined ? [] : legacyArray(persisted.permission_feedback, "permission feedback");
      for (const [ordinal, value] of feedback.entries()) {
        const id = `${body.callId}:feedback:${ordinal + 1}`;
        requireValue(!state.messageIds.has(id), "Duplicate permission feedback identity");
        state.messageIds.add(id);
        updateMessage(state, state.messages.length, {
          id, turnId: body.turnId, role: "user", status: "complete",
          parts: [{ type: "text", text: string(value, "permission feedback", true) }],
        }, changed);
      }
      break;
    }
    case "turn_end": {
      validateTurn(state, body);
      const result = object(body.result, "turn result");
      boolean(result.ok, "turn result ok");
      const firstUnresolved = pendingCall(state);
      if (result.ok) {
        const toolLimit = result.stopReason === "tool_limit" && state.records.at(-1)?.kind === "tool_result" && !state.pending.reservation;
        requireValue((state.pending.final || state.pending.providerTerminal || toolLimit) && !firstUnresolved, "Successful turn end requires a final response or settled tool limit");
        requireValue(stopReasons.has(result.stopReason), "Invalid turn stop reason");
        requireValue(result.pendingTool == null, "Successful turn cannot have a pending tool");
      } else {
        requireValue(failureReasons.has(result.reason), "Invalid turn failure reason");
        boolean(result.retryable, "turn result retryable");
        string(result.message, "turn result message", true);
        if (firstUnresolved) {
          const pending = object(result.pendingTool, "pendingTool");
          requireValue(pending.callId === firstUnresolved.callId && pending.name === firstUnresolved.name && equal(pending.input, firstUnresolved.input), "Turn end does not identify the first unresolved tool");
        } else requireValue(result.pendingTool == null, "Turn end identifies a tool that is not pending");
      }
      const index = state.pending.messageIndex;
      if (index !== null && (!result.ok || state.messages[index].status !== "complete")) {
        const current = state.messages[index];
        const parts = current.parts.map((part) => {
          if (part.type !== "tool_call" || part.status === "complete") return part;
          return { ...part, status: part.callId === firstUnresolved?.callId ? "unknown" : "skipped" };
        });
        const status = result.ok ? "complete" : result.reason === "interrupted" || result.reason === "cancelled" ? "interrupted" : "error";
        updateMessage(state, index, { ...current, status, parts }, changed);
      }
      if (result.usage != null) state.usage = addUsage(state.usage, usage(result.usage), state.pending.usage);
      const request = state.requests.get(state.pending.requestId);
      const outcome = { ...result, ...(result.usage === undefined ? {} : { usage: normalizeTurnUsage(result.usage) }) };
      state.requests.set(state.pending.requestId, freeze({ ...request, complete: true, result: outcome }));
      state.pending = null;
      break;
    }
    default:
      throw new JournalConflict("Invalid journal record kind");
  }
  state.records.push(body);
}

function checkpointState(body, seq, prior) {
  requireValue(Number.isSafeInteger(body.lastIncludedSeq) && body.lastIncludedSeq >= 0 && body.lastIncludedSeq === seq - 1, "Checkpoint coverage does not match its sequence");
  requireValue(Array.isArray(body.records) && body.records.length <= body.lastIncludedSeq && body.records.length <= 16384, "Invalid checkpoint record count");
  if (prior.lastSeq) {
    requireValue(prior.pending === null, "Checkpoint cannot replace a pending turn");
    requireValue(equal(prior.records, body.records), "Checkpoint rewrites retained journal history");
    requireValue(equal(prior.nativeBase, body.nativeBase ?? null), "Checkpoint rewrites native history");
  }
  const state = emptyState();
  if (body.nativeBase) {
    const base = object(body.nativeBase, "native history base");
    requireValue(Object.keys(base).length === 4 && base.v === 1, "Unknown native history base");
    const original = object(parseJournalJson(string(base.stateJson, "native state JSON")), "native state");
    requireValue(original.id === string(base.id, "native session id") && !Object.hasOwn(original, "recovery_checkpoint"), "Native history has unresolved or mismatched state");
    const context = object(parseJournalJson(string(base.contextJson, "native context JSON")), "native context");
    requireValue(context.id === base.id && context.context_history_start === 0 && !Object.hasOwn(context, "recovery_checkpoint"), "Invalid native model context");
    legacyArray(context.history, "native model history");
    const history = legacyArray(original.history, "native history");
    legacyInteger(original.context_history_start, "native context boundary");
    requireValue(original.context_history_start <= history.length, "Invalid native context boundary");
    const projected = projectLegacyPayload({ history, usage: {
      input_tokens: original.total_input_tokens, output_tokens: original.total_output_tokens,
    } }, 2, 16384);
    state.model = string(object(original.preferences, "native preferences").model, "native model");
    state.usage = { ...projected.usage };
    state.messages = projected.messages.slice();
    for (const message of state.messages) {
      state.messageIds.add(message.id);
      state.turnIds.add(message.turnId);
    }
    state.nativeBase = base;
  }
  for (const record of body.records) applyBody(state, record, []);
  requireValue(state.pending === null, "Checkpoint contains a pending turn");
  state.lastSeq = seq;
  state.seen = new Map(prior.seen);
  return state;
}

function changeFor(state, entry) {
  const decoded = decodeEntry(entry);
  const retiresGeneration = decoded.kind === "model_step" && decoded.body.phase !== "context" && (decoded.body.phase !== "request" || decoded.body.supersedesGenerationId != null);
  const retiredSteeringDraft = decoded.kind === "model_step" && decoded.body.phase === "context" && decoded.body.change === "steering" ? decoded.body.retiredDraft : null;
  const completedDrafts = retiredSteeringDraft != null ? freeze([{
    turnId: string(retiredSteeringDraft.turnId, "turnId"),
    messageId: string(retiredSteeringDraft.messageId, "messageId"),
    generationId: string(retiredSteeringDraft.generationId, "generationId"),
  }]) : retiresGeneration ? freeze([{
    turnId: string(decoded.body.turnId, "turnId"),
    messageId: string(decoded.body.messageId, "messageId"),
    generationId: string(decoded.body.phase === "request" ? decoded.body.supersedesGenerationId : decoded.body.generationId, "generationId"),
  }]) : freeze([]);
  const recorded = state.seen.get(decoded.seq);
  if (recorded !== undefined) {
    requireValue(recorded === decoded.hash, "Conflicting journal entry at an existing sequence");
    return { state, delta: freeze({ messages: [] }), completedDrafts };
  }
  requireValue(decoded.seq === state.lastSeq + 1 || (state.lastSeq === 0 && decoded.kind === "checkpoint"), "Journal sequence is not contiguous");
  let candidate;
  const changed = [];
  if (decoded.kind === "checkpoint") {
    candidate = checkpointState(decoded.body, decoded.seq, state);
    if (!state.lastSeq) changed.push(...candidate.messages);
  } else {
    requireValue(state.records.length < 16384, "Journal record capacity exceeded");
    candidate = fork(state);
    applyBody(candidate, decoded.body, changed);
    candidate.lastSeq = decoded.seq;
  }
  candidate.seen.set(decoded.seq, decoded.hash);
  return { state: candidate, delta: freeze({ messages: changed }), completedDrafts };
}

function projection(initial) {
  let state = initial;
  return Object.freeze({
    preview(entry) {
      const change = changeFor(state, entry);
      return { projection: projection(change.state), delta: change.delta, completedDrafts: change.completedDrafts };
    },
    apply(entry) {
      const change = changeFor(state, entry);
      state = change.state;
      return { delta: change.delta, completedDrafts: change.completedDrafts };
    },
    transcript() { return freeze({ model: state.model, usage: { ...state.usage }, messages: state.messages.slice() }); },
    requests() { return new Map(state.requests); },
  });
}

/** Pure replay. Call preview before persistence, or apply for already durable entries. */
export function createProjection(entries = []) {
  const result = projection(emptyState());
  for (const entry of entries) result.apply(entry);
  return result;
}

function legacyShape(value, required, optional = []) {
  object(value, "legacy checkpoint field");
  requireValue(required.every((key) => Object.hasOwn(value, key)) && Object.keys(value).every((key) => required.includes(key) || optional.includes(key)), "Invalid legacy checkpoint fields");
  return value;
}

function legacyInteger(value, label, minimum = 0) {
  requireValue(Number.isSafeInteger(value) && value >= minimum, `Invalid legacy ${label}`);
  return value;
}

function legacyText(value, label) {
  const bytes = durableBytes(value, label);
  return bytes ? displayUtf8.decode(bytes) : value;
}

function legacyOptionalText(value, label) {
  return value === null ? null : legacyText(value, label);
}

function legacyArray(value, label) {
  requireValue(Array.isArray(value), `Invalid legacy ${label}`);
  return value;
}

function legacyUser(value) {
  legacyShape(value, ["text", "images"], ["work_id"]);
  if (value.work_id !== undefined) string(value.work_id, "legacy work_id");
  for (const image of legacyArray(value.images, "images")) legacyShape(image, ["id", "path", "media_type"], ["snapshot_path", "snapshot_sha256"]);
  return userParts(value);
}

function legacyCall(call) {
  legacyShape(call, ["id", "name", "arguments_json", "provider_result"]);
  const callId = legacyText(call.id, "tool call id");
  const name = legacyText(call.name, "tool name");
  const argumentsJson = legacyText(call.arguments_json, "tool arguments");
  legacyOptionalText(call.provider_result, "provider result");
  // Malformed legacy arguments remain visible evidence, never repaired into
  // executable input. The native session codec's repairs are not replay authority.
  let input;
  try { input = parseJournalJson(argumentsJson); } catch { input = argumentsJson; }
  return { type: "tool_call", callId, name, input, status: "unknown" };
}

function legacyResult(result, version) {
  object(result, "legacy tool result");
  const fields = ["tool_call_id", "tool_name", "status", "output", "output_handle", "preview", "output_bytes", "stored_output_bytes", "truncated", "provider_native", "created_at_ms"];
  if (version >= 2) fields.push("permission_feedback");
  if (version >= 3 || (version === 2 && Object.hasOwn(result, "committed_file_presentation"))) fields.push("committed_file_presentation");
  if (version >= 3) fields.push("command_output_replay", "command_process_presentation");
  if (version >= 4) fields.push("terminal_action_presentation");
  legacyShape(result, fields, version >= 8 ? ["tool_images", "tool_image_handle"] : []);
  const callId = legacyText(result.tool_call_id, "tool result id");
  legacyText(result.tool_name, "tool result name");
  const content = legacyText(result.output, "tool result output");
  legacyOptionalText(result.output_handle, "tool output handle");
  legacyOptionalText(result.preview, "tool output preview");
  requireValue(result.status === "success" || result.status === "failure", "Invalid legacy tool result status");
  for (const key of ["output_bytes", "stored_output_bytes"]) legacyInteger(result[key], key);
  requireValue(Number.isSafeInteger(result.created_at_ms), "Invalid legacy tool timestamp");
  boolean(result.truncated, "legacy truncated");
  boolean(result.provider_native, "legacy provider_native");
  if (version >= 2) for (const text of legacyArray(result.permission_feedback, "permission feedback")) legacyText(text, "permission feedback");
  for (const key of ["committed_file_presentation", "command_output_replay", "command_process_presentation", "terminal_action_presentation"]) {
    if (result[key] != null) object(result[key], `legacy ${key}`);
  }
  if (result.tool_image_handle !== undefined) legacyOptionalText(result.tool_image_handle, "tool image handle");
  if (result.tool_images !== undefined) legacyArray(result.tool_images, "tool images");
  return { type: "tool_result", callId, content, isError: result.status === "failure" };
}

function legacyExecution(execution) {
  object(execution, "legacy execution");
  const version = legacyInteger(execution.schema_version, "execution version", 1);
  requireValue(version <= 9, "Unsupported legacy execution version");
  const fields = ["schema_version", "tool_steps", "files"];
  if (version >= 5) fields.push("turn_summary");
  if (version >= 6) fields.push("steering");
  legacyShape(execution, fields);
  const steps = legacyArray(execution.tool_steps, "tool steps").map((step) => {
    legacyShape(step, version >= 9 ? ["assistant", "tool_calls", "tool_results", "provider_replay"] : ["assistant", "tool_calls", "tool_results"]);
    const parts = [];
    if (step.assistant !== null) parts.push({ type: "text", text: legacyText(step.assistant, "step assistant") });
    const calls = legacyArray(step.tool_calls, "tool calls").map(legacyCall);
    const results = legacyArray(step.tool_results, "tool results").map((result) => legacyResult(result, version));
    for (const call of calls) {
      // Legacy checkpoints lack journal decision barriers. Only an actual saved
      // result establishes completion; absent results always remain unknown.
      if (results.some((result, index) => result.callId === call.callId && legacyText(step.tool_results[index].tool_name, "tool result name") === call.name)) call.status = "complete";
    }
    if (step.provider_replay != null) object(step.provider_replay, "legacy provider replay");
    parts.push(...calls, ...results);
    return parts;
  });
  for (const file of legacyArray(execution.files, "file evidence")) object(file, "legacy file evidence");
  if (execution.turn_summary != null) object(execution.turn_summary, "legacy turn summary");
  const steering = [];
  if (version >= 6) {
    let previous = 0;
    for (const item of legacyArray(execution.steering, "steering")) {
      if (version === 6) steering.push({ text: legacyText(item, "steering text"), after: steps.length, prefix: null });
      else {
        legacyShape(item, ["text", "assistant_prefix", "after_tool_step_count"]);
        const after = legacyInteger(item.after_tool_step_count, "steering position");
        requireValue(after >= previous && after <= steps.length, "Invalid legacy steering order");
        previous = after;
        steering.push({ text: legacyText(item.text, "steering text"), after, prefix: legacyOptionalText(item.assistant_prefix, "steering assistant prefix") });
      }
    }
  }
  return { steps, steering };
}

function legacyPending(value) {
  object(value, "legacy pending evidence");
  const fields = ["version", "turn_id", "user", "assistant_source", "execution", "cause", "action", "tool_state", "requested_fast_mode", "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation"];
  const version = legacyInteger(value.version, "pending version", 1);
  if (value.route_identity !== undefined) {
    requireValue(version >= 2 && version <= 4, "Unsupported legacy route version");
    fields.push("route_identity", "delivery", "route_model");
    const routeFields = ["connection_id", "adapter_kind", "permission_review_model_id"];
    if (version >= 3) routeFields.push("vision_model_id", "subagent_model_id");
    if (version === 4) routeFields.push("version", "endpoint", "protocol", "credential_ref");
    legacyShape(value.route_identity, routeFields);
    requireValue(value.route_identity.connection_id === "vercel" && value.route_identity.adapter_kind === "vercel_ai_gateway", "Invalid legacy route identity");
    if (version === 4) requireValue(value.route_identity.version === 1 && value.route_identity.protocol === "vercel_ai_gateway", "Unsupported legacy route protocol");
    for (const [key, item] of Object.entries(value.route_identity)) if (key !== "version") requireValue(typeof item === "string" && encoder.encode(item).length <= 4096, "Invalid legacy route field");
    requireValue(["possibly_sent", "definitely_unsent"].includes(value.delivery), "Invalid legacy delivery state");
  } else if (version === 1) fields.push("route_model");
  else {
    requireValue(version === 2, "Unsupported legacy pending version");
    fields.push("authority");
    legacyShape(value.authority, ["provider", "model", "credential_source", "credential_identity"]);
    const provider = string(value.authority.provider, "legacy provider").toLowerCase();
    requireValue(["gateway", "codex", "grok"].includes(provider), "Unknown legacy provider");
    const source = value.authority.credential_source;
    if (source !== null) {
      requireValue(["vercel_oidc_token", "ai_gateway_api_key", "fx_login", "stored_key", "chatgpt_subscription", "grok_subscription", "host_managed"].includes(source), "Unknown legacy credential source");
      requireValue(source === "host_managed" || (provider === "gateway" ? !["chatgpt_subscription", "grok_subscription"].includes(source) : source === `${provider === "codex" ? "chatgpt" : "grok"}_subscription`), "Legacy credential does not match its provider");
    }
    if (value.authority.credential_identity !== null) requireValue(value.authority.credential_source !== null && typeof value.authority.credential_identity === "string" && /^[0-9a-f]{64}$/.test(value.authority.credential_identity), "Invalid legacy credential identity");
  }
  legacyShape(value, fields, version === 1 ? ["route_provider"] : []);
  if (value.route_provider !== undefined) requireValue(["gateway", "codex", "grok"].includes(string(value.route_provider, "legacy provider").toLowerCase()), "Unknown legacy provider");
  legacyInteger(value.turn_id, "pending turn id", 1);
  const maximum = legacyInteger(value.max_provider_attempts, "attempt limit", 1);
  const consumed = legacyInteger(value.consumed_provider_attempts, "consumed attempts");
  boolean(value.outstanding_reservation, "legacy outstanding reservation");
  requireValue(consumed <= maximum && (!value.outstanding_reservation || consumed < maximum), "Invalid legacy attempt budget");
  for (const key of ["requested_fast_mode", "fast_mode"]) boolean(value[key], `legacy ${key}`);
  requireValue(["none", "proven_unexecuted", "confirmed", "uncertain"].includes(value.tool_state), "Unknown legacy tool state");
  requireValue(["network_interrupted", "response_interrupted", "provider_stream_timeout", "provider_unavailable", "rate_limited", "system_resumed", "suspended", "tool_state_uncertain", "authentication", "request_limit_reached"].includes(value.cause), "Unknown legacy recovery cause");
  requireValue(["retrying_request", "continuing_response", "regenerating_tool", "continuing_after_tool", "reconciling_tool", "waiting_for_connectivity", "paused"].includes(value.action), "Unknown legacy recovery action");
  const model = string(value.authority?.model ?? value.route_model, "pending model");
  requireValue(encoder.encode(model).length <= 1024 && !/[\x00-\x1f\x7f]/.test(model) && !/^\s|\s$/.test(model), "Invalid legacy pending model");
  return model;
}

function readLegacyCheckpoint(bytes) {
  requireValue(bytes.length >= 44 && bytes.length <= 4 * 1024 * 1024, "Invalid legacy checkpoint size");
  const header = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = header.getUint16(4, true);
  requireValue(version === 1 || version === 2, "Unsupported legacy checkpoint version");
  requireValue(header.getUint16(6, true) === 0 && header.getUint32(8, true) === bytes.length - 44, "Invalid legacy checkpoint header");
  const expected = Array.from(bytes.subarray(12, 44), (byte) => byte.toString(16).padStart(2, "0")).join("");
  requireValue(hashBytes(bytes.subarray(44)) === expected, "Legacy checkpoint hash mismatch");
  let text;
  try { text = strictUtf8.decode(bytes.subarray(44)); } catch { throw new JournalConflict("Invalid legacy checkpoint UTF-8"); }
  const body = object(parseJournalJson(text), "legacy checkpoint");
  return projectLegacyPayload(body, version, 1024);
}

function projectLegacyPayload(body, version, maxHistoryTurns) {
  const history = legacyArray(body.history, "history");
  requireValue(history.length <= maxHistoryTurns, "Legacy checkpoint history exceeds its turn limit");
  legacyShape(body.usage, [], usageFields);
  const messages = [];
  const append = (turnId, role, parts, status) => messages.push({ id: `${turnId}:${messages.length}`, turnId, role, status, parts });
  function conversation(turn, turnId, status, pending = false) {
    append(turnId, "user", legacyUser(turn.user), "complete");
    const execution = turn.execution !== undefined ? legacyExecution(turn.execution) : { steps: [], steering: [] };
    for (let i = 0; i <= execution.steps.length; i++) {
      for (const steering of execution.steering.filter((item) => item.after === i)) {
        if (steering.prefix) append(turnId, "assistant", [{ type: "text", text: steering.prefix }], "complete");
        append(turnId, "user", [{ type: "text", text: steering.text }], "complete");
      }
      if (i < execution.steps.length) {
        const parts = execution.steps[i];
        append(turnId, "assistant", parts, parts.some((part) => part.status === "unknown") ? "interrupted" : "complete");
      }
    }
    const source = pending ? turn.assistant_source : turn.assistant;
    const parts = source == null ? [] : [{ type: "text", text: legacyText(source, "assistant text") }];
    if (turn.tool_call != null) parts.push(legacyCall(turn.tool_call));
    if (parts.length || pending) append(turnId, "assistant", parts, status);
  }
  history.forEach((turn, index) => {
    object(turn, "legacy history turn");
    const turnId = `legacy:${index}`;
    if (turn.kind === "compacted_summary") {
      legacyShape(turn, ["kind", "summary", "removed_turn_count", "compaction_count"], ["root_user_messages", "root_user_messages_complete", "permission_feedback", "permission_feedback_complete"]);
      legacyInteger(turn.removed_turn_count, "removed turn count");
      legacyInteger(turn.compaction_count, "compaction count");
      requireValue((turn.root_user_messages_complete === undefined || turn.root_user_messages !== undefined) &&
        (turn.permission_feedback === undefined) === (turn.permission_feedback_complete === undefined) &&
        (turn.permission_feedback === undefined || turn.root_user_messages_complete !== undefined), "Invalid legacy summary completeness fields");
      for (const key of ["root_user_messages", "permission_feedback"]) if (turn[key] !== undefined) for (const item of legacyArray(turn[key], key)) legacyText(item, key);
      for (const key of ["root_user_messages_complete", "permission_feedback_complete"]) if (turn[key] !== undefined) boolean(turn[key], key);
      append(turnId, "assistant", [{ type: "text", text: legacyText(turn.summary, "compacted summary") }], "complete");
    } else if (turn.kind === "assistant") {
      legacyShape(turn, ["kind", "user", "assistant", "execution"], ["provider_replay"]);
      legacyText(turn.assistant, "legacy assistant");
      if (turn.provider_replay != null) object(turn.provider_replay, "legacy provider replay");
      conversation(turn, turnId, "complete");
    } else if (turn.kind === "interrupted") {
      legacyShape(turn, ["kind", "user", "assistant", "tool_call", "completed_tool_names"], ["execution", "terminal_reason", "cancelled_command"]);
      if (turn.terminal_reason !== undefined) requireValue(["cancelled", "failed"].includes(turn.terminal_reason), "Unknown legacy terminal reason");
      for (const name of legacyArray(turn.completed_tool_names, "completed tool names")) legacyText(name, "completed tool name");
      if (turn.cancelled_command != null) object(turn.cancelled_command, "legacy cancelled command");
      conversation(turn, turnId, turn.terminal_reason === "failed" ? "error" : "interrupted");
    } else if (turn.kind === "background_command") {
      legacyShape(turn, ["kind", "user", "log_path", "expect_url", "url", "background_record_id"], ["assistant", "execution"]);
      requireValue((turn.assistant === undefined) === (turn.execution === undefined), "Incomplete legacy background history");
      boolean(turn.expect_url, "legacy expect_url");
      if (turn.background_record_id !== null) requireValue(typeof turn.background_record_id === "string" && /^[0-9a-f]{32}$/.test(turn.background_record_id), "Invalid legacy background record id");
      const path = legacyText(turn.log_path, "legacy command log");
      const url = legacyOptionalText(turn.url, "legacy command URL");
      const prior = turn.assistant == null ? "" : legacyText(turn.assistant, "legacy assistant");
      const note = `[Historical command record: fx no longer owns or controls this process${path ? `; former log=${path}` : ""}${url !== null ? `; recorded url=${url}` : ""}]`;
      conversation({ ...turn, assistant: prior + (prior && !prior.endsWith("\n") ? "\n" : "") + note }, turnId, "complete");
    } else throw new JournalConflict("Unsupported legacy history kind");
  });
  let model = "";
  const pendingEvidence = body.recovery_checkpoint ?? null;
  if (Object.hasOwn(body, "recovery_checkpoint")) {
    requireValue(version === 2, "Version one legacy checkpoints cannot contain pending evidence");
    model = legacyPending(pendingEvidence);
    conversation(pendingEvidence, `legacy:${history.length}:pending`, "interrupted", true);
  }
  return freeze({ model, usage: usage(body.usage), messages, legacy: true, readOnly: true, pendingEvidence });
}

/** Inspects v1 journals or FXCP v1/v2 without execution. Legacy framing and
 * displayed fields are validated; hidden presentation metadata is preserved as
 * data, not admitted or repaired by the native execution codec. */
export function readCheckpoint(bytes) {
  requireValue(bytes instanceof Uint8Array, "Checkpoint bytes must be a Uint8Array");
  if (bytes[0] === 70 && bytes[1] === 88 && bytes[2] === 67 && bytes[3] === 80) return readLegacyCheckpoint(bytes);
  const body = decodeCheckpoint(bytes);
  requireValue(Number.isSafeInteger(body.lastIncludedSeq + 1), "Invalid checkpoint coverage");
  return projection(checkpointState(body, body.lastIncludedSeq + 1, emptyState())).transcript();
}
