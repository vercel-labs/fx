import { CoreOutput, maxCoreMessageBytes } from "./core-output.js";
import { loadModule } from "./wasm-module.js";
import {
  decodeEntry, JournalConflict, PersistenceUncertain, PendingTurnError,
  RequestConflict, RecoveryRequired, JournalCapacityExceeded, parseToolInput, maxJournalEntryBytes, normalizeTurnUsage,
} from "./journal-codec.js";
import { createProjection } from "./transcript.js";

export { JournalConflict, PersistenceUncertain, PendingTurnError, RequestConflict, RecoveryRequired, JournalCapacityExceeded } from "./journal-codec.js";
export { createProjection, readCheckpoint } from "./transcript.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const strictDecoder = new TextDecoder("utf-8", { fatal: true });
const workspaceInfoLimit = 4 * 1024;
const workspaceCommandLimit = 64 * 1024;
const workspaceOutputLimit = 64 * 1024;
const maxInstructionsBytes = 64 * 1024;
const maxApiKeyBytes = 64 * 1024;
const maxModelBytes = 1024;
const maxUrlBytes = 16 * 1024;
const maxModelCatalogBytes = 4 * 1024 * 1024;
const maxModelCatalogEntries = 10_000;
const streamReadsPerTaskYield = 32;
const maxUnreadEventBytes = 1024 * 1024;
const maxUnreadEvents = 256;
const maxJournalAppendFrameBytes = 4 * Math.ceil(maxJournalEntryBytes / 3) + 2048;

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
  if (url.href === "https://ai-gateway.vercel.sh/v3/ai/language-model") return;
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "[::1]" || url.hostname === "localhost";
  if (url.protocol !== "http:" || !loopback || !url.port) {
    throw new TypeError("gatewayChatUrl must use the canonical Gateway or explicit loopback HTTP");
  }
}

function normalizeAgentOptions(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("createFxAgent() options must be an object");
  }
  const options = { ...value };
  if (options.checkpoint !== undefined || options.onCheckpoint !== undefined) {
    throw new TypeError("checkpoint and onCheckpoint were replaced by journal and onEntry; restore journal entries and acknowledge each entry after durable storage");
  }
  if ((options.journal !== undefined) !== (options.onEntry !== undefined)) {
    throw new TypeError("journal and onEntry must be supplied together");
  }
  if (options.journal !== undefined) {
    if (options.journal === null || (typeof options.journal[Symbol.iterator] !== "function" &&
        typeof options.journal[Symbol.asyncIterator] !== "function")) {
      throw new TypeError("journal must be an iterable or async iterable of journal entries");
    }
    if (typeof options.onEntry !== "function") throw new TypeError("onEntry must be a function");
  }
  if (Object.hasOwn(options, "env")) {
    throw new TypeError("createFxAgent() does not accept env; pass apiKey and model directly");
  }
  options.apiKey = boundedString(options.apiKey, "apiKey", maxApiKeyBytes, true);
  options.model = boundedString(options.model, "model", maxModelBytes, false);
  validateGatewayChatUrl(options.gatewayChatUrl);
  return options;
}

function agentEnvironment(options) {
  return {
    AI_GATEWAY_API_KEY: options.apiKey,
    ...(options.model === undefined ? {} : { FX_MODEL: options.model }),
    ...(options.gatewayChatUrl === undefined ? {} : { FX_GATEWAY_CHAT_URL: options.gatewayChatUrl }),
  };
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
  }
  return null;
}

export function xtermAdapter(term) {
  let keyDataHandler = null;
  if (typeof term.attachCustomKeyEventHandler === "function") {
    term.attachCustomKeyEventHandler((event) => {
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
      return () => { if (keyDataHandler === callback) keyDataHandler = null; };
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

  let pendingHostToolResult = null;
  let pendingHostToolRelease = null;
  function hostToolCall(namePtr, nameLen, argumentsPtr, argumentsLen, outputPtr, outputCap, statusPtr, contextPtr, contextLen) {
    pendingHostToolResult = null;
    pendingHostToolRelease = null;
    if (typeof options.hostToolExecutor !== "function") return -1;
    if (options.traceWasi) console.error("fx host tool call start");
    let input;
    let context;
    try {
      input = JSON.parse(text(argumentsPtr, argumentsLen));
      if (contextLen !== undefined && contextLen !== 0) {
        const value = checkedBytes(contextPtr, contextLen);
        if (!value || contextLen > workspaceCommandLimit) return -1;
        context = JSON.parse(strictDecoder.decode(value));
      }
    } catch { return -1; }
    return Promise.resolve().then(() => options.hostToolExecutor(text(namePtr, nameLen), input, undefined, context)).then((result) => {
      if (options.traceWasi) console.error("fx host tool call settled", result?.cancelled, result?.isError);
      // Cancellation is safe only if the executor never entered. Unknown work
      // after entry must poison the owner even if core takes an interrupt path.
      if (result?.cancelled) return result.executionOutcome === "not_started" ? -2 : -5;
      if (result?.executionOutcome !== "completed" || typeof result.content !== "string" || typeof result.isError !== "boolean") return -4;
      const output = encoder.encode(result.content);
      bytes(statusPtr, 1)[0] = (result.isError ? 1 : 0) + (result.rich ? 2 : 0);
      if (output.length > outputCap) {
        if (!result.rich || output.length > 8 * 1024 * 1024) return -3;
        pendingHostToolResult = output;
        pendingHostToolRelease = result.releaseCompleted;
        return output.length;
      }
      bytes(outputPtr, output.length).set(output);
      pendingHostToolRelease = result.releaseCompleted;
      return output.length;
    }).catch(() => -1);
  }

  function openUrl(urlPtr, urlLen) {
    if (typeof options.openUrl !== "function") return 0;
    return Promise.resolve().then(() => options.openUrl(text(urlPtr, urlLen))).then((accepted) =>
      accepted === false ? 0 : 1).catch(() => 0);
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
    pendingHostToolRelease = null;
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

  let queuedSuspension = false;
  let suspensionFlag = 0;
  const fx = {
    fx_libfx_bind_suspend(ptr) {
      suspensionFlag = ptr;
      if (ptr && queuedSuspension) bytes(ptr, 1)[0] = 1;
      queuedSuspension = false;
    },
    fx_term_poll_input: new WebAssembly.Suspending(termPollInput),
    fx_prompt_history_available() { return options.promptHistoryStore ? 1 : 0; },
    fx_workspace_available() { return workspace.present ? 1 : 0; },
    fx_workspace_info: workspaceInfo,
    fx_workspace_exec: new WebAssembly.Suspending(workspaceExec),
    fx_http_stream_open: streamOpen,
    fx_http_stream_status: new WebAssembly.Suspending(streamStatus),
    fx_http_stream_next: new WebAssembly.Suspending(streamNext),
    fx_http_stream_close(handle) { const state = streams.get(handle); state?.controller.abort(abortReason); streams.delete(handle); },
    fx_http_request: new WebAssembly.Suspending(httpRequest),
    fx_libfx_checkpoint_set: new WebAssembly.Suspending(async (ptr, len) => {
      try {
        const ack = await options.onCheckpoint?.(bytes(ptr, len).slice());
        return ack?.durable === true ? 1 : 0;
      } catch { return 0; }
    }),
    fx_libfx_journal_append: new WebAssembly.Suspending(async (ptr, len) => {
      try {
        const value = checkedBytes(ptr, len);
        if (!value || len > maxJournalAppendFrameBytes) throw new JournalConflict("Invalid journal append frame");
        await options.journalAppend(JSON.parse(strictDecoder.decode(value)));
        return 1;
      } catch (error) {
        options.journalFailure?.(error);
        return 0;
      }
    }),
    fx_host_tool_call: new WebAssembly.Suspending(hostToolCall),
    fx_host_tool_result_read(offset, ptr, cap) {
      if (!pendingHostToolResult || offset < 0 || offset > pendingHostToolResult.length) return -1;
      const chunk = pendingHostToolResult.subarray(offset, offset + cap);
      bytes(ptr, chunk.length).set(chunk);
      return chunk.length;
    },
    fx_host_tool_result_release() {
      pendingHostToolResult = null;
      pendingHostToolRelease?.();
      pendingHostToolRelease = null;
    },
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
    wake() { stdin.wake(); },
    closeStdin() { stdin.close(); },
    requestSuspend() {
      if (suspensionFlag) bytes(suspensionFlag, 1)[0] = 1;
      else queuedSuspension = true;
    },
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

function normalizePromptInput(input) {
  if (typeof input === "string") return [{ type: "text", text: input }];
  if (!Array.isArray(input)) throw new TypeError("prompt input must be a string or an array of prompt blocks");
  return input.map((block, index) => {
    if (!block || typeof block !== "object") throw new TypeError(`prompt block ${index} must be an object`);
    if (block.type === "image") throw new TypeError("image prompt blocks are unsupported");
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
}

function normalizeHostTools(value) {
  if (value === undefined) return { descriptors: [], executors: new Map() };
  if (!Array.isArray(value)) throw new TypeError("tools must be an array");
  if (value.length > 64) throw new RangeError("tools cannot contain more than 64 entries");
  const descriptors = [];
  const executors = new Map();
  for (const [index, tool] of value.entries()) {
    if (!tool || typeof tool !== "object") throw new TypeError(`tool ${index} must be an object`);
    const { name, description, inputSchema, execute } = tool;
    if (typeof name !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(name)) {
      throw new TypeError(`tool ${index} has an invalid name`);
    }
    if (executors.has(name)) throw new TypeError(`duplicate tool name: ${name}`);
    if (typeof description !== "string") throw new TypeError(`tool ${name} requires a description`);
    if (typeof execute !== "function") throw new TypeError(`tool ${name} requires execute()`);
    if (!inputSchema || typeof inputSchema !== "object" || Array.isArray(inputSchema)) {
      throw new TypeError(`tool ${name} requires an object inputSchema`);
    }
    let schema;
    try { schema = JSON.parse(JSON.stringify(inputSchema)); } catch {
      throw new TypeError(`tool ${name} inputSchema must be JSON-serializable`);
    }
    const replay = tool.replay === undefined ? "blocked" : tool.replay;
    if (replay !== "safe" && replay !== "blocked") throw new TypeError(`tool ${name} replay must be safe or blocked`);
    descriptors.push({ name, description, inputSchema: schema, replay });
    executors.set(name, execute);
  }
  return { descriptors, executors };
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
    let imageBytes = 0;
    const images = value.images.map((image) => {
      if (image?.type !== "image" || typeof image.data !== "string" || typeof image.mimeType !== "string" || image.mimeType.length > 128 || image.data.length > 5 * 1024 * 1024) {
        throw new TypeError("invalid tool image");
      }
      imageBytes += image.data.length;
      if (imageBytes > 8 * 1024 * 1024) throw new RangeError("tool images exceed the result limit");
      return { type: "image", data: image.data, mimeType: image.mimeType };
    });
    const content = JSON.stringify({ text: value.text, images });
    if (new TextEncoder().encode(content).length > 8 * 1024 * 1024) throw new RangeError("typed tool result exceeds the result limit");
    return { content, rich: true, isError: value.isError === true };
  }
  if (typeof value === "string") return { content: value, rich: false };
  if (value === undefined) return { content: "null", rich: false };
  const encoded = JSON.stringify(value);
  return { content: encoded === undefined ? "null" : encoded, rich: false, isError: value?.isError === true };
}

function bytesToBase64(value) {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 0x8000) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function wireJournalEntry(value) {
  if (typeof value?.bytes !== "string" || value.bytes.length > 4 * Math.ceil(maxJournalEntryBytes / 3)) {
    throw new JournalConflict("Invalid journal entry bytes");
  }
  let bytes;
  try { bytes = base64ToBytes(value.bytes); } catch { throw new JournalConflict("Invalid journal entry base64"); }
  if (bytesToBase64(bytes) !== value.bytes) throw new JournalConflict("Noncanonical journal entry base64");
  return decodeEntry({ ...value, bytes });
}

function publicJournalEntry(entry) {
  return Object.freeze({ seq: entry.seq, kind: entry.kind, bytes: entry.bytes.slice(), hash: entry.hash });
}

function coreRequestError(value) {
  const message = String(value?.message ?? "fx request failed");
  const classes = { JournalConflict, PersistenceUncertain, PendingTurnError, RequestConflict, RecoveryRequired, JournalCapacityExceeded };
  const name = typeof value?.data?.code === "string" ? value.data.code
    : typeof value?.code === "string" ? value.code : message.split(":", 1)[0];
  const ErrorClass = Object.hasOwn(classes, name) ? classes[name] : Error;
  return new ErrorClass(message);
}

function createTurnOutput(cancel, emit) {
  const queue = [];
  const readers = new Set();
  let first = 0;
  let next = 0;
  let queuedBytes = 0;
  let finished = false;
  let terminalError;
  let capacity;
  let releaseCapacity;
  let reportedPressure = false;
  let epoch = 0;
  function release() {
    let consumed = next;
    for (const reader of readers) consumed = Math.min(consumed, reader.cursor);
    while (first < consumed) { queuedBytes -= queue.shift().size; first++; }
    releaseCapacity?.();
    releaseCapacity = null;
    capacity = null;
  }
  function read(reader) {
    if (reader.closed) return { done: true };
    if (reader.cursor < next) {
      const value = queue[reader.cursor++ - first].update;
      release();
      return { value, done: false };
    }
    if (terminalError) throw terminalError;
    return finished ? { done: true } : null;
  }
  function wake() {
    for (const reader of readers) {
      while (reader.waiters.length) {
        let result;
        try { result = read(reader); } catch (error) {
          reader.waiters.splice(0).forEach((waiter) => waiter.reject(error));
          break;
        }
        if (result === null) break;
        reader.waiters.shift().resolve(result);
      }
    }
  }
  return {
    push(update, size, incomingEpoch = epoch) {
      if (finished || !readers.size || incomingEpoch !== epoch) return;
      if (queue.length && (queue.length >= maxUnreadEvents || size > maxUnreadEventBytes - queuedBytes)) {
        if (!capacity) capacity = new Promise((resolve) => { releaseCapacity = resolve; });
        const pendingCapacity = capacity;
        if (!reportedPressure) {
          reportedPressure = true;
          emit("output.backpressure", { bufferedBytes: queuedBytes, bufferedEvents: queue.length });
        }
        return pendingCapacity.then(() => this.push(update, size, incomingEpoch));
      }
      queue.push({ update, size });
      queuedBytes += size;
      next++;
      wake();
    },
    subscribe() {
      if (readers.size >= maxUnreadEvents) throw new RangeError("Too many consumers attached to this turn");
      const reader = { cursor: next, waiters: [], closed: false };
      readers.add(reader);
      const detach = () => {
        reader.closed = true;
        readers.delete(reader);
        reader.waiters.splice(0).forEach((waiter) => waiter.resolve({ done: true }));
        release();
      };
      return {
        next() {
          try {
            const result = read(reader);
            return result ? Promise.resolve(result) : new Promise((resolve, reject) => reader.waiters.push({ resolve, reject }));
          } catch (error) { return Promise.reject(error); }
        },
        return() { detach(); cancel(); return Promise.resolve({ done: true }); },
        [Symbol.asyncIterator]() { return this; },
      };
    },
    discard() {
      epoch++;
      for (const reader of readers) reader.cursor = next;
      release();
    },
    finish(error) {
      finished = true;
      terminalError = error;
      releaseCapacity?.();
      releaseCapacity = null;
      capacity = null;
      wake();
    },
  };
}

export async function createFxAgent(options = {}) {
  options = normalizeAgentOptions(options);
  const hostTools = normalizeHostTools(options.tools);
  const instructions = normalizeInstructions(options.instructions);
  const journalEnabled = options.journal !== undefined;
  let projection = createProjection();
  let journalFailure = null;
  let journalTail = Promise.resolve();
  let journalCallbacks = 0;
  let journalStatus = { idle: true, lastSeq: 0, pendingTurn: null };
  let durableCalls = [];
  let durableMessageId = null;
  let closePromise;
  let closeRequested = false;
  const hostExecutions = new Set();
  const controlCallbacks = new Set();
  const pending = new Map();
  let nextId = 1;
  let sessionId = null;
  let activeTurn = null;
  let closing = false;
  const isCurrentTurn = (turn) => turn && activeTurn === turn && !turn.cancelled && !closing && !journalFailure;
  const assertOpen = () => {
    if (journalFailure) throw journalFailure;
    if (closing || closeRequested) throw new Error("fx agent is closed");
  };
  const requireJournal = () => {
    if (!journalEnabled) throw new TypeError("Durable recovery requires journal and onEntry");
  };
  function failJournal(error) {
    if (!journalFailure) journalFailure = error instanceof JournalConflict || error instanceof PersistenceUncertain
      ? error : new PersistenceUncertain(undefined, { cause: error });
    return journalFailure;
  }
  function track(promise, collection) {
    collection.add(promise);
    const release = () => collection.delete(promise);
    promise.then(release, release);
    return promise;
  }
  function adoptJournalStatus(entry) {
    const body = entry.body;
    let pendingTurn = journalStatus.pendingTurn;
    if (entry.kind === "turn_start") {
      durableCalls = [];
      durableMessageId = null;
      pendingTurn = { turnId: body.turnId, requestId: body.requestId, lastSeq: entry.seq, awaiting: "model" };
    } else if (entry.kind === "model_step" && body.phase !== "context") {
      durableMessageId = body.messageId;
      durableCalls = body.phase === "request" ? [] : body.calls.map((call) => ({
        callId: call.callId, name: call.name, input: parseToolInput(call.argumentsJson), replay: call.replay,
      }));
    } else if (entry.kind === "tool_result") {
      durableCalls = durableCalls.slice(1);
    } else if (entry.kind === "turn_end" || entry.kind === "checkpoint") {
      durableCalls = [];
      durableMessageId = null;
      pendingTurn = null;
    }
    if (pendingTurn) pendingTurn = {
      ...pendingTurn, lastSeq: entry.seq,
      awaiting: durableCalls.length ? { tool: durableCalls[0] } : "model",
    };
    journalStatus = { idle: !pendingTurn, lastSeq: entry.seq, pendingTurn };
  }
  function appendJournal(params) {
    const operation = journalTail.then(async () => {
      if (journalFailure) throw journalFailure;
      requireJournal();
      if (sessionId === null || params?.sessionId !== sessionId) throw new JournalConflict("Journal append targets a different session");
      const entry = wireJournalEntry(params.entry);
      const candidate = projection.preview(entry);
      const isNew = entry.seq > journalStatus.lastSeq;
      journalCallbacks++;
      try {
        await options.onEntry(publicJournalEntry(entry));
      } catch (error) {
        throw failJournal(new PersistenceUncertain(undefined, { cause: error }));
      } finally {
        journalCallbacks--;
      }
      projection = candidate.projection;
      if (!isNew) return;
      adoptJournalStatus(entry);
      if (entry.kind === "turn_start") {
        await activeTurn?.push({ journalEvent: {
          type: "turn_start", turnId: entry.body.turnId, messageId: entry.body.userMessageId,
          requestId: entry.body.requestId,
        } });
      } else if (entry.kind === "tool_result") {
        await activeTurn?.push({ journalEvent: {
          type: "tool_end", turnId: entry.body.turnId, messageId: durableMessageId,
          callId: entry.body.callId, content: entry.body.content, isError: entry.body.isError,
        } });
      } else if (entry.kind === "turn_end") {
        await activeTurn?.push({ journalEvent: {
          type: "turn_end", turnId: entry.body.turnId, result: normalizeJournalResult(entry.body.result),
        } });
      }
    }).catch((error) => { throw failJournal(error); });
    journalTail = operation.catch(() => {});
    return operation;
  }
  const emit = (type, detail = {}) => {
    try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
  };
  const hostFetch = options.fetch ?? globalThis.fetch?.bind(globalThis);
  const transportFetch = async (input, init = {}) => {
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    let endpoint = String(input?.url ?? input);
    try {
      const url = new URL(endpoint);
      endpoint = `${url.origin}${url.pathname}`;
    } catch {}
    for (let attemptIndex = 0; attemptIndex < 2; attemptIndex++) {
      const startedAt = performance.now();
      const attempt = activeTurn ? ++activeTurn.transportAttempts : attemptIndex + 1;
      emit("transport.start", { attempt, method, endpoint, model: options.model });
      try {
        if (journalFailure) throw journalFailure;
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
        if (journalFailure) throw journalFailure;
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
  const executeHostTool = async (name, input, requestedSessionId, context) => {
    if (journalFailure) throw journalFailure;
    const execute = hostTools.executors.get(name);
    const turn = requestedSessionId === undefined || requestedSessionId === sessionId
      ? activeTurn
      : null;
    if (!isCurrentTurn(turn)) return { content: "", isError: true, executionOutcome: "not_started", cancelled: true };
    if (journalEnabled && (!context || typeof context.turnId !== "string" || !context.turnId ||
        typeof context.callId !== "string" || !context.callId || typeof context.requestId !== "string" ||
        !context.requestId || typeof context.recovering !== "boolean" ||
        (turn.requestId !== undefined && turn.requestId !== context.requestId) ||
        context.turnId !== journalStatus.pendingTurn?.turnId || context.callId !== durableCalls[0]?.callId ||
        name !== durableCalls[0]?.name)) {
      throw failJournal(new JournalConflict("Host tool context does not identify the active journal turn"));
    }
    const controller = new AbortController();
    turn.toolControllers.add(controller);
    let onAbort;
    const aborted = new Promise((resolve) => { onAbort = () => resolve(); });
    controller.signal.addEventListener("abort", onAbort, { once: true });
    let content = "";
    let rich = false;
    let isError = false;
    // An exception (including result encoding failure) does not acknowledge the
    // external effect. Only a successfully returned/encoded result is terminal.
    let executionOutcome = "not_started";
    try {
      if (!execute) throw new Error(`unknown host tool: ${String(name)}`);
      if (journalEnabled) await turn.push({ journalEvent: {
        type: "tool_start", turnId: context.turnId, messageId: durableMessageId,
        callId: context.callId, name, input,
      } });
      const execution = track(Promise.resolve().then(() => {
        if (controller.signal.aborted || !isCurrentTurn(turn)) return;
        executionOutcome = "uncertain";
        turn.enteredToolControllers.add(controller);
        return execute(input, { ...context, signal: controller.signal });
      }), hostExecutions);
      const value = await Promise.race([execution, aborted]);
      if (!controller.signal.aborted && isCurrentTurn(turn)) {
        const normalized = journalEnabled && value && typeof value.content === "string" &&
          (value.isError === undefined || typeof value.isError === "boolean")
          ? { content: value.content, isError: value.isError === true, rich: false }
          : hostToolContent(value);
        content = normalized.content;
        rich = normalized.rich;
        isError = normalized.isError === true;
        executionOutcome = "completed";
      }
    } catch (error) {
      if (error instanceof PersistenceUncertain || error instanceof JournalConflict) throw failJournal(error);
      isError = true;
      content = "Host tool outcome is uncertain";
      // Diagnostic getters/encoding can themselves throw. They must not prevent
      // the uncertain outcome from reaching core or turn it into completion.
      try {
        if (error?.toolResult?.type === "libfx.tool-result") {
          const normalized = hostToolContent(error.toolResult);
          content = normalized.content;
          rich = normalized.rich;
        } else {
          content = error instanceof Error ? error.message : String(error);
        }
      } catch {}
    } finally {
      controller.signal.removeEventListener("abort", onAbort);
      turn.toolControllers.delete(controller);
    }
    return {
      content, isError, rich, executionOutcome,
      cancelled: controller.signal.aborted || !isCurrentTurn(turn),
      // Keep entry evidence until the bridge has delivered a terminal result.
      // Exceptions and lost/invalid replies retain it through turn settlement.
      releaseCompleted() {
        if (executionOutcome === "completed") turn.enteredToolControllers.delete(controller);
      },
    };
  };
  emit("runtime.start");
  const runtimeOptions = {
    ...options,
    fetch: transportFetch,
    args: ["acp"],
    env: agentEnvironment(options),
    hostToolExecutor: executeHostTool,
    journalAppend: appendJournal,
    journalFailure: failJournal,
  };
  const runtime = options.runtimeFactory
    ? await options.runtimeFactory(runtimeOptions)
    : await instantiate(runtimeOptions);
  emit("runtime.ready");
  const send = (message) => {
    if (closing) throw new Error("fx agent is closing");
    emit("acp.send", { message });
    const line = `${JSON.stringify(message)}\n`;
    if (encoder.encode(line).length > 8 * 1024 * 1024) throw new RangeError("ACP request exceeds the 8 MiB frame limit");
    runtime.write(line);
  };
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    try { send({ jsonrpc: "2.0", id, method, params }); } catch (error) { pending.delete(id); reject(error); }
  });
  runtime.exited.then((code) => {
    emit("runtime.exit", { code });
    closing = true;
    const error = journalFailure ?? runtime.error ?? new Error(`fx-core exited with code ${code} before completing the ACP request`);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  runtime.setLineHandler((message, size) => {
    emit("acp.receive", { message });
    if (message.method === "session/update") {
      if (message.params?.sessionId === sessionId) return activeTurn?.push(message.params.update, size);
      return;
    }
    void track(handleControlMessage(message), controlCallbacks).catch((error) => runtime.abort(journalFailure ?? error));
  });
  async function handleControlMessage(message) {
    if (message.method === "libfx/checkpoint_set") {
      if (!closing) send({ jsonrpc: "2.0", id: message.id, result: { durable: false } });
      return;
    }
    if (message.method === "libfx/journal_append") {
      let durable = false;
      try { await appendJournal(message.params); durable = true; } catch {}
      if (!closing) send({ jsonrpc: "2.0", id: message.id, result: { durable } });
      return;
    }
    if (message.method === "session/request_permission") {
      const turn = activeTurn;
      if (message.params?.sessionId !== sessionId) return;
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
    if (message.method === "libfx/tool_call") {
      if (message.params?.sessionId !== sessionId) throw new JournalConflict("Host tool call targets a different session");
      const { content, isError, rich, executionOutcome, cancelled, releaseCompleted } = await executeHostTool(
        message.params?.name,
        message.params?.input,
        message.params?.sessionId,
        message.params?.context,
      );
      if (cancelled || closing) return;
      const response = { jsonrpc: "2.0", id: message.id, result: { content, isError, executionOutcome, ...(rich ? { contentType: "rich" } : {}) } };
      if (encoder.encode(JSON.stringify(response)).length + 1 > 8 * 1024 * 1024) {
        response.result = { content: "Host tool result exceeded the response frame limit", isError: true, executionOutcome: "uncertain" };
      }
      send(response);
      if (response.result.executionOutcome === "completed") releaseCompleted?.();
      return;
    }
    const waiter = pending.get(message.id); if (!waiter) return; pending.delete(message.id);
    if (message.error) waiter.reject(journalFailure ?? coreRequestError(message.error));
    else if (journalFailure) waiter.reject(journalFailure);
    else waiter.resolve(message.result);
  }
  try {
    const initialized = await request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        ...(hostTools.descriptors.length || instructions || journalEnabled
          ? { libfx: { tools: hostTools.descriptors, instructions, ...(journalEnabled ? { journal: true } : {}) } }
          : {}),
      },
    });
    if (journalEnabled && initialized?._meta?.libfxJournalVersion !== 1) {
      throw new TypeError("The fx core does not support journal version 1; update the core and SDK together");
    }

    const sessionResult = await request("libfx/new");
    sessionId = sessionResult.sessionId;
    if (typeof sessionId !== "string" || !sessionId) throw new Error("fx returned an invalid session identity");
    if (journalEnabled) {
      for await (const value of options.journal) {
        const entry = decodeEntry(value);
        const candidate = projection.preview(entry);
        // Large entries keep the existing ACP input-frame bound. The core
        // adopts only the fully received, hash- and payload-validated entry.
        if (entry.bytes.length <= 4 * 1024 * 1024) {
          await request("libfx/journal/restore", {
            sessionId,
            entry: { seq: entry.seq, kind: entry.kind, bytes: bytesToBase64(entry.bytes), hash: entry.hash },
          });
        } else {
          await request("libfx/journal/restore_begin", {
            sessionId, entry: { seq: entry.seq, kind: entry.kind, hash: entry.hash }, byteLength: entry.bytes.length,
          });
          for (let offset = 0; offset < entry.bytes.length; offset += 64 * 1024) {
            await request("libfx/journal/restore_append", {
              sessionId, offset, bytes: bytesToBase64(entry.bytes.subarray(offset, offset + 64 * 1024)),
            });
          }
          await request("libfx/journal/restore_finish", { sessionId });
        }
        projection = candidate.projection;
        if (entry.seq > journalStatus.lastSeq) adoptJournalStatus(entry);
      }
      journalStatus = await request("libfx/status", { sessionId });
    }
  } catch (error) {
    closing = true;
    try { runtime.abortHostEffects(); } catch {}
    try { runtime.closeStdin(); } catch {}
    try { await runtime.exited; } catch {}
    throw error;
  }

  const agent = {
    prompt(input, promptOptions = {}) {
      assertOpen();
      if (journalEnabled) boundedString(promptOptions.requestId, "requestId", 1024, true);
      if (activeTurn) {
        if (!journalEnabled || promptOptions.requestId !== activeTurn.requestId) {
          throw journalEnabled ? new PendingTurnError() : new Error("a prompt is already in progress for this session");
        }
        if (JSON.stringify(normalizePromptInput(input)) !== activeTurn.inputJson) throw new RequestConflict();
        return normalizeTurn(activeTurn, promptOptions.signal);
      }
      return normalizeTurn(startTurn(input, promptOptions));
    },
    async suspend() {
      assertOpen();
      requireJournal();
      const turn = activeTurn;
      if (!turn) return null;
      if (!turn.suspension) {
        turn.suspending = true;
        turn.suspension = (async () => {
          if (runtime.requestSuspend) runtime.requestSuspend();
          else await request("libfx/suspend", { sessionId });
          try { await turn.result; } catch (error) {
            if (!(error instanceof PendingTurnError) || !error.status) throw error;
          }
          return agent.status();
        })();
      }
      return turn.suspension;
    },
    async status() {
      assertOpen();
      if (journalEnabled) {
        if (activeTurn || journalCallbacks) return structuredClone(journalStatus);
        journalStatus = await request("libfx/status", { sessionId });
        return structuredClone(journalStatus);
      }
      if (activeTurn) return { state: activeTurn.cancelledWithEnteredTool ? "blocked" : activeTurn.suspending ? "suspending" : "running", canResume: false };
      return request("libfx/status", { sessionId });
    },
    resume(promptOptions = {}) {
      assertOpen();
      requireJournal();
      if (activeTurn) throw new PendingTurnError();
      return normalizeTurn(startTurn([], promptOptions, "libfx/resume"));
    },
    async abandon() {
      assertOpen();
      requireJournal();
      if (activeTurn) throw new PendingTurnError();
      await request("libfx/abandon", { sessionId });
    },
    async checkpoint() {
      assertOpen();
      requireJournal();
      if (activeTurn) throw new Error("cannot checkpoint while a prompt is active");
      const response = await request("libfx/checkpoint", { sessionId });
      const entry = wireJournalEntry(response?.entry);
      if (entry.kind !== "checkpoint" || entry.seq !== journalStatus.lastSeq) {
        throw failJournal(new JournalConflict("fx returned an unacknowledged checkpoint"));
      }
      projection.preview(entry);
      return publicJournalEntry(entry);
    },
    close() {
      if (!closePromise) {
        closeRequested = true;
        closePromise = (async () => {
          const turn = activeTurn;
          if (!closing) turn?.cancel();
          if (turn) await turn.result.catch(() => {});
          await journalTail;
          while (hostExecutions.size || controlCallbacks.size) {
            await Promise.allSettled([...hostExecutions, ...controlCallbacks]);
          }
          if (!closing) {
            closing = true;
            runtime.closeStdin();
          }
          await runtime.exited;
        })();
      }
      return closePromise;
    },
  };
  return agent;

  function normalizeTurn(rawTurn, signal) {
    validateSignal(signal);
    const source = rawTurn.subscribe();
    let iteratorTaken = false;
    const abort = () => rawTurn.cancel();
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) rawTurn.cancel();
    const toolNames = new Map();
    const started = new Set();
    const eventFor = (update) => {
      if (journalEnabled) {
        if (update.journalEvent) return structuredClone(update.journalEvent);
        if (update.sessionUpdate === "libfx/journal_event") return structuredClone(update.event);
      }
      if (update.sessionUpdate === "agent_message_chunk") {
        const delta = update.content?.text;
        if (!delta || delta.startsWith("[context]")) return null;
        return { type: "text_delta", delta, ...(journalEnabled ? { key: update.journalKey, ordinal: update.journalOrdinal } : {}) };
      }
      if (update.sessionUpdate === "agent_thought_chunk") {
        const delta = update.content?.text;
        return delta ? { type: "reasoning_delta", delta, ...(journalEnabled ? { key: update.journalKey, ordinal: update.journalOrdinal } : {}) } : null;
      }
      if (journalEnabled) return null;
      if (update.sessionUpdate === "tool_call") {
        toolNames.set(update.toolCallId, update.name || update.toolName || update.title || "tool");
        if (started.has(update.toolCallId)) return null;
        started.add(update.toolCallId);
        return {
          type: "tool_start",
          id: update.toolCallId,
          name: toolNames.get(update.toolCallId),
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
    const result = rawTurn.result.then((value) => journalEnabled
      ? normalizeJournalResult(value.journalResult)
      : { stopReason: value.stopReason, usage: normalizeTurnUsage(value.usage) })
      .finally(() => signal?.removeEventListener("abort", abort));
    void result.catch(() => {});
    return {
      cancel() { rawTurn.cancel(); },
      [Symbol.asyncIterator]() {
        if (iteratorTaken) throw new Error("a turn has only one event consumer");
        iteratorTaken = true;
        const iterator = (async function* () {
          for await (const update of source) {
            const event = eventFor(update);
            if (event) yield event;
          }
        })();
        return {
          next(value) { return iterator.next(value); },
          return(value) { void source.return(); return iterator.return(value); },
          throw(error) { void source.return(); return iterator.throw(error); },
          [Symbol.asyncIterator]() { return this; },
        };
      },
      result,
    };
  }

  function validateSignal(signal) {
    if (signal !== undefined && (typeof signal?.addEventListener !== "function" || typeof signal?.removeEventListener !== "function")) {
      throw new TypeError("prompt signal must be an AbortSignal");
    }
  }

  function normalizeJournalResult(value) {
    if (!value || typeof value.ok !== "boolean") throw failJournal(new JournalConflict("fx returned an invalid journal turn result"));
    return { ...value, ...(value.usage === undefined ? {} : { usage: normalizeTurnUsage(value.usage) }) };
  }

  function startTurn(input, promptOptions, method = "session/prompt") {
    const prompt = method === "libfx/resume" ? [] : normalizePromptInput(input);
    const requestId = journalEnabled && method === "session/prompt"
      ? boundedString(promptOptions.requestId, "requestId", 1024, true) : undefined;
    const signal = promptOptions.signal;
    validateSignal(signal);
    const toolControllers = new Set();
    let finished = false;
    let cancelled = false;
    let terminalError;
    let discardedBytes = 0;
    let generationKey;
    let ordinal = 0;
    const output = createTurnOutput(() => turn.cancel(), emit);
    const firstSubscription = output.subscribe();
    let subscribed = false;
    const turn = {
      requestId: requestId ?? (journalEnabled ? journalStatus.pendingTurn?.requestId : undefined),
      inputJson: JSON.stringify(prompt),
      push(update, size = encoder.encode(JSON.stringify(update)).length) {
        if (finished || (cancelled && !update.journalEvent && update.sessionUpdate !== "libfx/journal_event")) {
          discardedBytes += size;
          return;
        }
        if (size > maxCoreMessageBytes) throw new RangeError("core output message exceeds 64 MiB");
        if (journalEnabled && update.sessionUpdate === "libfx/journal_generation") {
          const key = update.key;
          if (!key || [key.turnId, key.messageId, key.generationId].some((value) => typeof value !== "string" || !value) ||
              key.turnId !== journalStatus.pendingTurn?.turnId) {
            throw failJournal(new JournalConflict("Model generation does not identify the pending journal turn"));
          }
          generationKey = Object.freeze({ turnId: key.turnId, messageId: key.messageId, generationId: key.generationId });
          ordinal = 0;
          return;
        }
        if (journalEnabled && (update.sessionUpdate === "agent_message_chunk" || update.sessionUpdate === "agent_thought_chunk")) {
          const delta = update.content?.text;
          if (!delta || (update.sessionUpdate === "agent_message_chunk" && delta.startsWith("[context]"))) return;
          if (!generationKey) throw failJournal(new JournalConflict("Text delta is missing its journal generation"));
          update = { ...update, journalKey: generationKey, journalOrdinal: ++ordinal };
          size = encoder.encode(JSON.stringify(update)).length;
        }
        return output.push(update, size);
      },
      subscribe() {
        if (subscribed) return output.subscribe();
        subscribed = true;
        return firstSubscription;
      },
      toolControllers,
      enteredToolControllers: new Set(),
      cancelledWithEnteredTool: false,
      transportAttempts: 0,
      get cancelled() { return cancelled; },
      cancel() {
        if (finished || cancelled) return;
        cancelled = true;
        output.discard();
        turn.cancelledWithEnteredTool = turn.enteredToolControllers.size > 0;
        try {
          if (!closing) send({ jsonrpc: "2.0", method: "session/cancel", params: {
            sessionId,
            _meta: { fx: { hostToolExecution: turn.cancelledWithEnteredTool ? "uncertain" : "not_started" } },
          } });
        } finally {
          for (const controller of toolControllers) controller.abort();
          runtime.abortHostEffects();
        }
      },
    };
    if (signal?.aborted) {
      finished = true;
      const error = journalEnabled ? new DOMException("Cancelled before admission", "AbortError") : undefined;
      output.finish(error);
      turn.result = error ? Promise.reject(error) : Promise.resolve({ stopReason: "cancelled" });
      void turn.result.catch(() => {});
      return turn;
    }
    activeTurn = turn;
    const abort = () => turn.cancel();
    signal?.addEventListener("abort", abort, { once: true });
    turn.result = request(method, { sessionId, prompt, ...(requestId === undefined ? {} : { requestId }) })
      .then((response) => {
        if (journalFailure) throw journalFailure;
        if (journalEnabled) {
          if (response.stopReason === "suspended" && response.journalStatus?.pendingTurn) {
            journalStatus = response.journalStatus;
            const error = new PendingTurnError("Turn suspended; explicitly resume or abandon the pending turn");
            error.status = structuredClone(journalStatus);
            error.pendingTurn = error.status.pendingTurn;
            throw error;
          }
          normalizeJournalResult(response.journalResult);
          if (!projection.requests().get(turn.requestId)?.complete ||
              (response.journalReplay && response.requestId !== turn.requestId)) {
            throw failJournal(new JournalConflict("fx returned a result without the request's durable turn end"));
          }
          return response;
        }
        if (turn.cancelledWithEnteredTool) throw new Error("HostToolOutcomeUncertain: cancellation interrupted an entered host executor");
        return { stopReason: cancelled ? "cancelled" : response.stopReason, usage: response.usage };
      })
      .catch((error) => {
        if (journalFailure) error = journalFailure;
        if (!journalEnabled) {
          if (turn.cancelledWithEnteredTool && error.message === "Cancelled") error = new Error("HostToolOutcomeUncertain: cancellation interrupted an entered host executor");
          if (error.message === "Cancelled") return { stopReason: "cancelled" };
        }
        terminalError = error;
        throw error;
      })
      .finally(async () => {
        await journalTail;
        // A cancelled host promise can outlive the bridge reply. Keep ownership
        // until it settles; its external receipt remains the host's authority.
        while (hostExecutions.size || controlCallbacks.size) {
          await Promise.allSettled([...hostExecutions, ...controlCallbacks]);
        }
        finished = true;
        signal?.removeEventListener("abort", abort);
        if (activeTurn === turn) activeTurn = null;
        toolControllers.clear();
        if (discardedBytes) emit("output.discarded", { reason: "cancelled", bytes: discardedBytes });
        output.finish(terminalError);
      });
    if (signal?.aborted) turn.cancel();
    void turn.result.catch(() => {});
    return turn;
  }
}
