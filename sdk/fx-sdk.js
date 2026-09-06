import { CoreOutput, maxCoreMessageBytes } from "./core-output.js";

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

const modulePromisesBySource = new Map();
const modulePromisesByObject = new WeakMap();

async function compileModule(input) {
  if (input instanceof WebAssembly.Module) return input;
  if (typeof input === "string") input = fetch(input);
  if (input instanceof Promise) input = await input;
  if (input instanceof WebAssembly.Module) return input;
  if (input instanceof Response) {
    const contentType = input.headers.get("content-type")?.split(";", 1)[0].trim().toLowerCase();
    if (contentType === "application/wasm" && typeof WebAssembly.compileStreaming === "function") {
      return WebAssembly.compileStreaming(input);
    }
    const bytes = await input.arrayBuffer();
    return WebAssembly.compile(bytes);
  }
  if (input instanceof ArrayBuffer || ArrayBuffer.isView(input)) {
    return WebAssembly.compile(input);
  }
  throw new TypeError("wasm must be a URL, Response, ArrayBuffer, typed array, or WebAssembly.Module");
}

function loadModule(input) {
  if (input instanceof WebAssembly.Module) return Promise.resolve(input);
  const isString = typeof input === "string";
  if (!isString && (typeof input !== "object" || input === null)) return compileModule(input);
  const cache = isString ? modulePromisesBySource : modulePromisesByObject;
  const cached = cache.get(input);
  if (cached) return cached;
  const pending = compileModule(input);
  cache.set(input, pending);
  pending.catch(() => {
    if (cache.get(input) === pending) cache.delete(input);
  });
  return pending;
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
  function hostToolCall(namePtr, nameLen, argumentsPtr, argumentsLen, outputPtr, outputCap, statusPtr) {
    pendingHostToolResult = null;
    if (typeof options.hostToolExecutor !== "function") return -1;
    if (options.traceWasi) console.error("fx host tool call start");
    let input;
    try { input = JSON.parse(text(argumentsPtr, argumentsLen)); } catch { return -1; }
    return Promise.resolve(options.hostToolExecutor(text(namePtr, nameLen), input)).then((result) => {
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
    fx_host_tool_result_read(offset, ptr, cap) {
      if (!pendingHostToolResult || offset < 0 || offset > pendingHostToolResult.length) return -1;
      const chunk = pendingHostToolResult.subarray(offset, offset + cap);
      bytes(ptr, chunk.length).set(chunk);
      return chunk.length;
    },
    fx_host_tool_result_release() { pendingHostToolResult = null; },
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
        if (!String(error).includes("proc_exit")) console.error(error);
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
  const unsubscribeData = options.terminal.onData(forwardData);
  const unsubscribeKeyData = options.terminal.onKeyData?.(forwardData) ?? (() => {});
  const signalResize = () => {
    emit("terminal.resize", { cols: options.terminal.cols, rows: options.terminal.rows });
    runtime.wake();
  };
  const unsubscribeResize = options.terminal.onResize(signalResize);
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
    descriptors.push({ name, description, inputSchema: schema });
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

export async function createFxAgent(options = {}) {
  options = normalizeAgentOptions(options);
  const hostTools = normalizeHostTools(options.tools);
  const instructions = normalizeInstructions(options.instructions);
  const initialCheckpoint = checkpointBytes(options.checkpoint);
  const pending = new Map();
  let nextId = 1;
  let sessionId = null;
  let activeTurn = null;
  let closing = false;
  const isCurrentTurn = (turn) => turn && activeTurn === turn && !turn.cancelled && !closing;
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
  const executeHostTool = async (name, input, requestedSessionId) => {
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
        return execute(input, { signal: controller.signal });
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
    return { content, isError, rich, cancelled: controller.signal.aborted || !isCurrentTurn(turn) };
  };
  emit("runtime.start");
  const runtimeOptions = {
    ...options,
    fetch: transportFetch,
    args: ["acp"],
    env: agentEnvironment(options),
    hostToolExecutor: executeHostTool,
  };
  const runtime = options.runtimeFactory
    ? await options.runtimeFactory(runtimeOptions)
    : await instantiate(runtimeOptions);
  emit("runtime.ready");
  const send = (message) => {
    if (closing) throw new Error("fx agent is closing");
    emit("acp.send", { message });
    runtime.write(`${JSON.stringify(message)}\n`);
  };
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    try { send({ jsonrpc: "2.0", id, method, params }); } catch (error) { pending.delete(id); reject(error); }
  });
  runtime.exited.then((code) => {
    emit("runtime.exit", { code });
    closing = true;
    const error = runtime.error ?? new Error(`fx-core exited with code ${code} before completing the ACP request`);
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });
  runtime.setLineHandler((message, size) => {
    emit("acp.receive", { message });
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
    if (message.method === "libfx/tool_call") {
      const { content, isError, rich, cancelled } = await executeHostTool(
        message.params?.name,
        message.params?.input,
        message.params?.sessionId,
      );
      if (cancelled || closing) return;
      const response = { jsonrpc: "2.0", id: message.id, result: { content, isError, ...(rich ? { contentType: "rich" } : {}) } };
      if (encoder.encode(JSON.stringify(response)).length + 1 > 8 * 1024 * 1024) {
        response.result = { content: "Host tool result exceeded the response frame limit", isError: true };
      }
      send(response);
      return;
    }
    const waiter = pending.get(message.id); if (!waiter) return; pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message)); else waiter.resolve(message.result);
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

    const sessionResult = await request("libfx/new");
    sessionId = sessionResult.sessionId;
    if (initialCheckpoint) {
      await request("libfx/restore", {
        sessionId,
        checkpoint: bytesToBase64(initialCheckpoint),
      });
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
      if (closing) throw new Error("fx agent is closed");
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      return normalizeTurn(startTurn(input, promptOptions));
    },
    async checkpoint() {
      if (closing) throw new Error("fx agent is closed");
      if (activeTurn) throw new Error("cannot checkpoint while a prompt is active");
      const response = await request("libfx/checkpoint", { sessionId });
      if (typeof response?.checkpoint !== "string") throw new Error("fx returned an invalid checkpoint");
      return base64ToBytes(response.checkpoint);
    },
    async close() {
      if (closing) { await runtime.exited; return; }
      const turn = activeTurn;
      turn?.cancel();
      if (turn) await turn.result.catch(() => {});
      closing = true;
      runtime.closeStdin();
      await runtime.exited;
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
    const result = rawTurn.result.then((value) => ({
      stopReason: value.stopReason,
      usage: normalizeTurnUsage(value.usage),
    }));
    void result.catch(() => {});
    return {
      cancel() { rawTurn.cancel(); },
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

  function startTurn(input, promptOptions) {
    const prompt = normalizePromptInput(input);
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
      get cancelled() { return cancelled; },
      cancel() {
        if (finished || cancelled) return;
        cancelled = true;
        resumeOutput?.();
        resumeOutput = null;
        send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
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
      finished = true;
      turn.result = Promise.resolve({ stopReason: "cancelled" });
      return turn;
    }
    activeTurn = turn;
    const abort = () => turn.cancel();
    signal?.addEventListener("abort", abort, { once: true });
    turn.result = request("session/prompt", { sessionId, prompt })
      .then((response) => ({ stopReason: cancelled ? "cancelled" : response.stopReason, usage: response.usage }))
      .catch((error) => {
        if (error.message === "Cancelled") return { stopReason: "cancelled" };
        terminalError = error;
        throw error;
      })
      .finally(() => {
        finished = true;
        resumeOutput?.();
        resumeOutput = null;
        signal?.removeEventListener("abort", abort);
        if (activeTurn === turn) activeTurn = null;
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
