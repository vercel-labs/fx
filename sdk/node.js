import { access } from "node:fs/promises";
import { closeSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { homedir, tmpdir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { bundledAssetUrl } from "./bundled-asset.js";
import { CoreOutput } from "./core-output.js";
import { fetchCleanupAction, cleanupTimeoutMs, cleanupByteLimit } from "./fetch-cleanup.js";
import { createDurableAgentFactory, memory, wakeHandler } from "./durable.js";
import { fxHarness } from "./fx-harness.js";
import {
  createFxEngine as createEngine,
  createMemoryPersistence,
  FxFencedError,
  FxJournalVersionError,
  fxSdkApiVersion,
  listModels,
  normalizeAgentOptions,
  supportsJspi,
} from "./engine.js";
import { encodeXtermKeyEvent, xtermAdapter } from "./xterm.js";

export { createMemoryPersistence, encodeXtermKeyEvent, FxFencedError, FxJournalVersionError, fxSdkApiVersion, listModels, memory, supportsJspi, wakeHandler, xtermAdapter };
export const libfxApiVersion = 3;
const nativeCoreApiVersion = 4;

const fetchOperationStale = 0;
const fetchOperationApplied = 1;
const fetchOperationBackpressure = 2;

const nodeRequire = createRequire(import.meta.url);
let nativeBackendPromise;

const backendReasonCodes = {
  unsupportedPlatform: "LIBFX_UNSUPPORTED_PLATFORM",
  missingArtifact: "LIBFX_NATIVE_ARTIFACT_MISSING",
  nativeLoad: "LIBFX_NATIVE_LOAD_FAILED",
  nativeApi: "LIBFX_NATIVE_API_MISMATCH",
  missingSurface: "LIBFX_NATIVE_SURFACE_MISSING",
  disabledNative: "LIBFX_NATIVE_DISABLED",
  jspiUnavailable: "LIBFX_JSPI_UNAVAILABLE",
  wasmLoad: "LIBFX_WASM_LOAD_FAILED",
};

function sentence(message) {
  return `${message[0].toUpperCase()}${message.slice(1)}.`;
}

function jspiFallbackError(surface, native, nativeError) {
  const missingPackage = !nativeError && native?.failure === "missing" ? native.nativePackage : undefined;
  const nativeDetail = nativeError ? ` Native loading failed: ${nativeError.message}.`
    : missingPackage ? ` ${sentence(nativeFailureReason(native).message)}`
    : " No compatible native addon was found.";
  const remedy = missingPackage
    ? `Install ${missingPackage}, which libfx lists as an optional dependency, or run Node with --experimental-wasm-jspi.`
    : "Run Node with --experimental-wasm-jspi or install a libfx package containing a compatible native addon.";
  const error = new Error(
    `libfx could not start the ${surface} backend.${nativeDetail} ` +
    `The WebAssembly fallback requires JavaScript Promise Integration (JSPI). ${remedy}`,
  );
  error.code = "LIBFX_JSPI_REQUIRED";
  error.cause = nativeError ?? native?.probeError;
  return error;
}

async function loadNativeCandidate(candidate) {
  if (candidate == null) return null;
  if (candidate instanceof URL) {
    if (candidate.protocol === "") candidate = bundledAssetUrl(candidate);
    if (candidate.protocol === "file:" && candidate.pathname.endsWith(".node")) {
      // Bundlers trace the asset URL; Node must load the native file at runtime.
      return Reflect.apply(nodeRequire, undefined, [fileURLToPath(candidate)]);
    }
    // A module the caller names is its own file, which Node loads as is.
    const imported = await import(/* webpackIgnore: true */ /* turbopackIgnore: true */ candidate.href);
    return imported.default ?? imported;
  }
  if (typeof candidate === "object") return candidate.default ?? candidate;
  if (typeof candidate !== "string") {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  if (candidate.endsWith(".node")) {
    return Reflect.apply(nodeRequire, undefined, [isAbsolute(candidate) ? candidate : resolve(candidate)]);
  }
  const imported = await import(/* webpackIgnore: true */ /* turbopackIgnore: true */ candidate.startsWith("file:") ? candidate : pathToFileURL(candidate).href);
  return imported.default ?? imported;
}

// Each platform's addon ships in a package of its own, which libfx lists as
// an optional dependency, so a package manager installs only the one for its
// machine. The package's index.js names the addon with a literal
// `new URL("./libfx.node", import.meta.url)`, so a bundler that bundles
// libfx copies that one addon and traces it.
const nativePackages = {
  "darwin-arm64": "@libfx/libfx-darwin-arm64",
  "darwin-x64": "@libfx/libfx-darwin-x64",
  "linux-arm64": "@libfx/libfx-linux-arm64-gnu",
  "linux-x64": "@libfx/libfx-linux-x64-gnu",
};

// Each specifier is a literal, so Node, Turbopack, and file tracers find the
// installed package. A missing one fails here at run time, and inside `try`
// it does not fail a Turbopack build. webpack folds the `typeof` test and
// sees only a context over the platform packages that are installed, so it
// does not warn about the ones that are missing.
async function importNativePackage(name) {
  try {
    if (typeof __webpack_require__ === "function") {
      return await import(
        /* webpackInclude: /[\\/]libfx-(darwin|linux)-[a-z0-9-]+[\\/]index\.js$/ */
        `@libfx/libfx-${name.slice("@libfx/libfx-".length)}`
      );
    } else {
      if (name === "@libfx/libfx-darwin-arm64") return await import("@libfx/libfx-darwin-arm64");
      if (name === "@libfx/libfx-darwin-x64") return await import("@libfx/libfx-darwin-x64");
      if (name === "@libfx/libfx-linux-arm64-gnu") return await import("@libfx/libfx-linux-arm64-gnu");
      if (name === "@libfx/libfx-linux-x64-gnu") return await import("@libfx/libfx-linux-x64-gnu");
    }
  } catch (error) {
    return { error };
  }
  return { error: new Error(`${name} is not a libfx native addon package`) };
}

// The path of the addon the platform package names, or the error that kept
// the package from loading.
async function defaultNativeCandidate(name) {
  const imported = await importNativePackage(name);
  if (imported.error) return imported;
  const asset = imported.default;
  if (!(asset instanceof URL)) return { error: new TypeError(`${name} does not export its addon's URL`) };
  return { candidate: fileURLToPath(asset.protocol === "" ? bundledAssetUrl(asset) : asset) };
}

function validateNativeBackend(backend) {
  if (!backend) return null;
  const hasLowLevelCore = typeof backend.createCore === "function";
  const expectedVersion = hasLowLevelCore ? nativeCoreApiVersion : libfxApiVersion;
  if ((hasLowLevelCore || backend.libfxApiVersion !== undefined) && backend.libfxApiVersion !== expectedVersion) {
    const actualVersion = backend.libfxApiVersion ?? "missing";
    throw new Error(`native addon API version ${actualVersion} is incompatible with expected API version ${expectedVersion}`);
  }
  if (typeof backend.createCore !== "function" && typeof backend.createFxTerminal !== "function") {
    throw new Error("native addon must export createCore() or createFxTerminal()");
  }
  return backend;
}

function missingArtifact(error) {
  return error?.code === "ENOENT" || error?.code === "MODULE_NOT_FOUND" || error?.code === "ERR_MODULE_NOT_FOUND";
}

function nativeCandidateFilePath(candidate) {
  if (candidate instanceof URL) {
    if (candidate.protocol === "") candidate = bundledAssetUrl(candidate);
    return candidate.protocol === "file:" ? fileURLToPath(candidate) : null;
  }
  if (typeof candidate !== "string") return null;
  if (candidate.startsWith("file:")) return fileURLToPath(new URL(candidate));
  return URL.canParse(candidate) ? null : resolve(candidate);
}

async function nativeArtifactMissing(candidate) {
  try {
    const path = nativeCandidateFilePath(candidate);
    if (path === null) return false;
    await access(path);
    return false;
  } catch (error) {
    return missingArtifact(error);
  }
}

function validationFailure(error) {
  return error?.message?.startsWith("native addon API version ") ? "api" : "surface";
}

async function loadAndValidateNativeCandidate(candidate, artifactMissing = false) {
  let backend;
  try {
    backend = await loadNativeCandidate(candidate);
  } catch (error) {
    return { backend: null, error, failure: artifactMissing ? "missing" : "load" };
  }
  try {
    return { backend: validateNativeBackend(backend), error: null, failure: null };
  } catch (error) {
    return { backend: null, error, failure: validationFailure(error) };
  }
}

async function discoverNativeBackend() {
  const nativePackage = nativePackages[`${process.platform}-${process.arch}`];
  if (!nativePackage) {
    return { backend: null, error: null, failure: "unsupported" };
  }
  // The package's index.js only names its addon, so a package that cannot be
  // found is not installed or not part of the bundle.
  const { candidate, error: packageError } = await defaultNativeCandidate(nativePackage);
  if (packageError) {
    if (missingArtifact(packageError)) return { backend: null, error: null, probeError: packageError, failure: "missing", nativePackage };
    return { backend: null, error: packageError, failure: "load" };
  }
  try {
    await access(candidate);
  } catch (error) {
    if (missingArtifact(error)) {
      return { backend: null, error: null, probeError: error, failure: "missing" };
    }
    return { backend: null, error, failure: "load" };
  }
  return loadAndValidateNativeCandidate(candidate);
}

async function resolveNativeBackend(nativeAddon) {
  if (nativeAddon === false) return { backend: null, error: null, failure: "disabled" };
  if (nativeAddon !== undefined) {
    return loadAndValidateNativeCandidate(nativeAddon, await nativeArtifactMissing(nativeAddon));
  }
  nativeBackendPromise ??= discoverNativeBackend();
  return nativeBackendPromise;
}

function reason(code, message, error) {
  const causeCode = error?.code;
  return {
    code,
    message,
    ...(typeof causeCode === "string" || typeof causeCode === "number" ? { causeCode } : {}),
  };
}

function nativeFailureReason(result) {
  const detailError = result.probeError ?? result.error;
  switch (result.failure) {
    case "unsupported":
      return reason(
        backendReasonCodes.unsupportedPlatform,
        `native addon is not available for ${process.platform}-${process.arch}`,
      );
    case "missing":
      return reason(
        backendReasonCodes.missingArtifact,
        result.nativePackage
          ? `the native addon package ${result.nativePackage} for ${process.platform}-${process.arch} is not installed`
          : `native addon artifact was not found${detailError?.message ? `: ${detailError.message}` : ""}`,
        detailError,
      );
    case "load":
      return reason(
        backendReasonCodes.nativeLoad,
        `native addon failed to load${result.error?.message ? `: ${result.error.message}` : ""}`,
        result.error,
      );
    case "api":
      return reason(backendReasonCodes.nativeApi, result.error.message, result.error);
    case "surface":
      return reason(backendReasonCodes.missingSurface, result.error.message, result.error);
    case "disabled":
      return reason(backendReasonCodes.disabledNative, "native addon loading is disabled");
    default:
      return reason(backendReasonCodes.nativeLoad, "native addon is unavailable", result.error);
  }
}

function validateBackendInfoOptions(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("getBackendInfo() options must be an object");
  }
  const { nativeAddon, backend = "auto", surface = "agent", ...options } = value;
  for (const key of Object.keys(options)) {
    if (key !== "wasm") {
      throw new TypeError(`getBackendInfo() does not accept ${key}`);
    }
  }
  if (!new Set(["agent", "terminal"]).has(surface)) {
    throw new TypeError('surface must be "agent" or "terminal"');
  }
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }
  if (nativeAddon !== undefined && nativeAddon !== false &&
    typeof nativeAddon !== "string" && !(nativeAddon instanceof URL) &&
    (typeof nativeAddon !== "object" || nativeAddon === null)) {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  const validWasm = options.wasm === undefined || typeof options.wasm === "string" || options.wasm instanceof URL ||
    options.wasm instanceof Promise || options.wasm instanceof WebAssembly.Module || options.wasm instanceof Response ||
    options.wasm instanceof ArrayBuffer || ArrayBuffer.isView(options.wasm);
  if (Object.hasOwn(options, "wasm") && !validWasm) {
    throw new TypeError("wasm must be a URL, Response, ArrayBuffer, typed array, or WebAssembly.Module");
  }
  return { ...options, surface, backend, nativeAddon };
}

export async function getBackendInfo(value = {}) {
  const { surface, backend, nativeAddon, wasm } = validateBackendInfoOptions(value);
  const attempts = [];
  if (backend !== "wasm") {
    const native = await resolveNativeBackend(nativeAddon);
    const nativeMethod = surface === "agent" ? "createCore" : "createFxTerminal";
    if (typeof native.backend?.[nativeMethod] === "function") {
      attempts.push({ backend: "native", available: true, reason: null });
      return { surface, backend: "native", attempts };
    }
    const failureReason = native.backend
      ? reason(backendReasonCodes.missingSurface, `native addon does not provide ${nativeMethod}()`)
      : nativeFailureReason(native);
    attempts.push({ backend: "native", available: false, reason: failureReason });
    if (backend === "native") return { surface, backend: "unavailable", attempts };
  }

  if (!supportsJspi()) {
    attempts.push({
      backend: "wasm-jspi",
      available: false,
      reason: reason(
        backendReasonCodes.jspiUnavailable,
        "WebAssembly backend requires JavaScript Promise Integration (JSPI); run Node with --experimental-wasm-jspi",
      ),
    });
    return { surface, backend: "unavailable", attempts };
  }
  try {
    const { probeWasm } = await import("./node-wasm.js");
    await probeWasm(surface, wasm);
    attempts.push({ backend: "wasm-jspi", available: true, reason: null });
    return { surface, backend: "wasm-jspi", attempts };
  } catch (error) {
    attempts.push({
      backend: "wasm-jspi",
      available: false,
      reason: reason(
        backendReasonCodes.wasmLoad,
        `WebAssembly asset failed to load or compile: ${error?.message ?? String(error)}`,
        error,
      ),
    });
    return { surface, backend: "unavailable", attempts };
  }
}

function createNativeCoreRuntime(addon, options) {
  const { apiKey, providerName: provider, customProvider, model, effort, fast, ultrafast, gatewayChatUrl } = options;
  if (ultrafast !== undefined && addon.supportsUltrafast !== true) {
    const error = new Error("native addon does not support the ultrafast option");
    error.code = "LIBFX_NATIVE_CAPABILITY_UNAVAILABLE";
    throw error;
  }
  const capability = customProvider ? "supportsConfiguredProvider" : { codex: "supportsCodex", grok: "supportsGrok" }[provider];
  if (capability && addon[capability] !== true) {
    const error = new Error(`native addon does not support the ${provider} provider`);
    error.code = "LIBFX_NATIVE_CAPABILITY_UNAVAILABLE";
    throw error;
  }
  const core = addon.createCore({
    ...(apiKey === undefined ? {} : { apiKey }),
    ...(provider === undefined ? {} : { provider }),
    ...(customProvider === undefined ? {} : { configuredProviders: customProvider.json }),
    home: options.home ?? homedir(),
    workspaceRoot: options.workspaceRoot ?? process.cwd(),
    ...(model === undefined ? {} : { model }),
    ...(effort === undefined ? {} : { effort }),
    ...(fast === undefined ? {} : { fast }),
    ...(ultrafast === undefined ? {} : { ultrafast }),
    ...(gatewayChatUrl === undefined ? {} : { gatewayChatUrl }),
  });
  let readyFd;
  let readySocket;
  try {
    readyFd = addon.takeCoreReadyFd(core);
    readySocket = new Socket({ fd: readyFd, readable: true, writable: false });
  } catch (error) {
    if (readyFd !== undefined) {
      try { closeSync(readyFd); } catch {}
    }
    addon.destroyCore(core);
    throw error;
  }
  const readyClosed = new Promise((resolve) => readySocket.once("close", resolve));
  let exitedResolve;
  let lineHandler = null;
  const output = new CoreOutput((message, size) => lineHandler(message, size));
  let draining = false;
  let outputError;
  let settled = false;
  let fetchState = null;
  const exited = new Promise((resolve) => { exitedResolve = resolve; });
  function refreshFetch(state) {
    if (settled) return;
    if (typeof addon.coreFetchDisposition !== "function") {
      state.active = addon.coreFetchActive(core, state.handle);
      return;
    }
    // One native lock observes consumption and retirement together.
    const disposition = addon.coreFetchDisposition(core, state.handle);
    if (disposition !== 0 && disposition !== 1 && disposition !== 2) {
      throw new Error(`invalid native fetch disposition ${disposition}`);
    }
    state.consumed ||= disposition === 2;
    state.active = disposition === 1;
  }
  function cleanupAction(state) {
    return fetchCleanupAction({ ...state, alive: !settled,
      age: state.drainStarted === null ? 0 : performance.now() - state.drainStarted });
  }
  function beginDrain(state) {
    if (state.drainStarted !== null) return;
    state.drainStarted = performance.now();
    state.timer = setTimeout(() => state.controller.abort(), cleanupTimeoutMs);
  }
  const abortHostEffects = () => {
    if (fetchState) {
      fetchState.canceled = true;
      fetchState.controller.abort();
    }
    if (!settled) { try { addon.abortCoreFetch(core); } catch {} }
  };
  const finish = (code, error) => {
    if (settled) return;
    const state = fetchState;
    if (state) {
      refreshFetch(state);
      state.closing = true;
      state.failed ||= code !== 0 || error !== undefined;
    }
    settled = true;
    outputError = error;
    output.close();
    const destroy = () => {
      try { addon.destroyCore(core); } catch {}
      readySocket.destroy();
      void readyClosed.then(() => exitedResolve(code));
    };
    if (state && cleanupAction(state) === "drain") {
      beginDrain(state);
      void state.done.then(destroy);
    } else {
      if (state && cleanupAction(state) !== "done") state.controller.abort();
      destroy();
    }
  };
  const pumpFetch = async (request, body) => {
    const controller = new AbortController();
    let complete, reader;
    const state = { handle: request.handle, controller, consumed: false, active: true,
      canceled: false, failed: false, closing: false, eof: false, discarded: 0,
      drainStarted: null, timer: null, done: new Promise(resolve => { complete = resolve; }) };
    fetchState = state;
    let onAbort;
    const aborted = new Promise((_, reject) => {
      onAbort = () => reject(new DOMException("Aborted", "AbortError"));
      controller.signal.addEventListener("abort", onAbort, { once: true });
    });
    void aborted.catch(() => {});
    const wait = task => Promise.race([task, aborted]);
    try {
      const responseTask = Promise.resolve().then(() => (options.fetch ?? globalThis.fetch)(request.url, {
        method: request.method,
        headers: new Headers(JSON.parse(request.headers).map(({ name, value }) => [name, value])),
        body: body.length ? body : undefined,
        signal: controller.signal,
      })).then(response => {
        if (controller.signal.aborted) {
          void response.body?.cancel().catch(() => {});
          throw new DOMException("Aborted", "AbortError");
        }
        return response;
      });
      const response = await wait(responseTask);
      if (settled && !state.consumed) throw new DOMException("Aborted", "AbortError");
      const started = settled ? fetchOperationStale : addon.startCoreFetchResponse(core, state.handle, response.status);
      if (started !== fetchOperationApplied && started !== fetchOperationStale) throw new Error(`invalid native fetch start result ${started}`);
      state.active = started === fetchOperationApplied;
      reader = response.body?.getReader();
      while (reader) {
        refreshFetch(state);
        const action = cleanupAction(state);
        if (action === "abort") { controller.abort(); throw new DOMException("Aborted", "AbortError"); }
        if (action === "drain") beginDrain(state);
        const { done, value } = await wait(reader.read());
        if (done) break;
        const buffer = Buffer.from(value);
        options.onTransportChunk?.(buffer.length);
        let offset = 0;
        while (offset < buffer.length) {
          refreshFetch(state);
          const next = cleanupAction(state);
          if (next === "drain") {
            beginDrain(state);
            state.discarded += buffer.length - offset;
            if (state.discarded >= cleanupByteLimit) controller.abort();
            break;
          }
          if (next !== "forward") { controller.abort(); throw new DOMException("Aborted", "AbortError"); }
          const end = Math.min(offset + 64 * 1024, buffer.length);
          const pushed = addon.pushCoreFetchResponse(core, state.handle, buffer.subarray(offset, end));
          if (pushed === fetchOperationApplied) { offset = end; continue; }
          if (pushed === fetchOperationStale) {
            refreshFetch(state);
            if (cleanupAction(state) === "drain") continue;
            controller.abort(); throw new DOMException("Aborted", "AbortError");
          }
          if (pushed !== fetchOperationBackpressure) throw new Error(`invalid native fetch push result ${pushed}`);
          await wait(new Promise(resolve => setTimeout(resolve, 2)));
        }
      }
      state.eof = true;
      if (!settled && state.active) {
        const finished = addon.finishCoreFetch(core, state.handle);
        if (finished !== fetchOperationApplied && finished !== fetchOperationStale) throw new Error(`invalid native fetch finish result ${finished}`);
      }
    } catch (error) {
      if (!settled && !controller.signal.aborted) {
        state.failed = true;
        try { if (addon.coreFetchActive(core, state.handle)) addon.failCoreFetch(core, state.handle); } catch {}
      }
    } finally {
      clearTimeout(state.timer);
      controller.signal.removeEventListener("abort", onAbort);
      if (reader) {
        if (!state.eof) { try { void reader.cancel().catch(() => {}); } catch {} }
        try { reader.releaseLock(); } catch {}
      }
      complete();
      if (fetchState === state) { fetchState = null; queueMicrotask(drainReady); }
    }
  };
  function drainReady() {
    if (settled) return;
    try {
      if (fetchState) {
        refreshFetch(fetchState);
        const action = cleanupAction(fetchState);
        if (action === "drain") beginDrain(fetchState);
        if (action === "abort") fetchState.controller.abort();
      } else {
        // The core hands over JSON metadata and the raw request body separately.
        const fetchRequest = addon.takeCoreFetch(core);
        if (fetchRequest) void pumpFetch(JSON.parse(fetchRequest.request.toString("utf8")), fetchRequest.body);
      }
      if (addon.coreExitCode(core) !== 0) {
        finish(1, new Error("native output delivery failed"));
        return;
      }
      void drainOutput();
    } catch (error) {
      finish(1, error);
    }
  }
  async function drainOutput() {
    if (draining || settled) return;
    draining = true;
    try {
      while (!settled) {
        const chunk = addon.drainCore(core);
        if (!chunk.length) break;
        const pending = output.write(chunk);
        if (pending) await pending;
      }
      if (!settled && addon.coreExited(core)) {
        output.finish();
        finish(addon.coreExitCode(core));
      }
    } catch (error) {
      finish(1, error);
    } finally {
      draining = false;
    }
  }

  readySocket.on("data", drainReady);
  readySocket.on("end", () => { drainReady(); if (!settled) finish(1); });
  readySocket.on("error", () => finish(1));
  readySocket.on("close", () => { if (!settled) finish(1); });
  // Some runtimes defer descriptor adoption until connect().
  if (readySocket.pending) {
    try { readySocket.connect({ fd: readyFd }); } catch (error) { finish(1); throw error; }
  }

  return {
    exited,
    get error() { return outputError; },
    write(data) { addon.writeCore(core, Buffer.from(data)); },
    // The addon copies attachment bytes before returning.
    writeAttachment(id, bytes) {
      addon.writeCoreAttachment(core, id, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength));
    },
    takeAttachment(id) { return addon.takeCoreAttachment(core, id); },
    discardAttachments() { addon.discardCoreAttachments(core); },
    closeStdin() { addon.closeCore(core); },
    abortHostEffects,
    abort(error) {
      if (error) finish(1, error);
      else { abortHostEffects(); addon.closeCore(core); }
    },
    setLineHandler(handler) { lineHandler = handler; },
  };
}

function createNativeAgent(addon, options) {
  return createEngine({
    ...options,
    runtimeFactory(runtimeOptions) {
      return createNativeCoreRuntime(addon, runtimeOptions);
    },
  });
}

async function createWithFallback(surface, nativeMethod, options) {
  const { nativeAddon, backend = "auto", ...unvalidatedOptions } = options ?? {};
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }
  const runtimeOptions = surface === "agent" ? normalizeAgentOptions(unvalidatedOptions) : unvalidatedOptions;

  let native = null;
  let nativeError;
  let nativeAttempted = false;
  if (backend !== "wasm") {
    native = await resolveNativeBackend(nativeAddon);
    nativeError = native.error;
    if (typeof native.backend?.[nativeMethod] === "function") {
      nativeAttempted = true;
      try {
        if (surface === "agent") return await createNativeAgent(native.backend, runtimeOptions);
        return await native.backend[nativeMethod](runtimeOptions);
      } catch (error) {
        nativeError = error;
        if (backend === "native" || error?.code === "LIBFX_MODEL_UNSUPPORTED_FAST" ||
          error?.code === "LIBFX_MODEL_UNSUPPORTED_EFFORT" ||
          typeof error?.code === "string" && error.code.startsWith("LIBFX_MODEL_METADATA_")) throw error;
      }
    }
    if (backend === "native") {
      const missingPackage = native.failure === "missing" ? native.nativePackage : undefined;
      const error = nativeError ?? new Error(native.backend
        ? `native addon does not provide ${nativeMethod}()`
        : missingPackage
          ? `${sentence(nativeFailureReason(native).message)} Install ${missingPackage}, which libfx lists as an optional dependency.`
          : nativeFailureReason(native).message, native.probeError ? { cause: native.probeError } : undefined);
      error.code ??= "LIBFX_NATIVE_UNAVAILABLE";
      throw error;
    }
  }

  if (!supportsJspi()) {
    if (nativeAttempted) throw nativeError;
    throw jspiFallbackError(surface, native, nativeError);
  }
  const wasmBackend = await import("./node-wasm.js");
  return surface === "agent" ? wasmBackend.createWasmEngine(runtimeOptions) : wasmBackend.createWasmTerminal(runtimeOptions);
}

/**
 * One fx session on the native core, or on WebAssembly when the native
 * addon is unavailable, with no durability of its own. `createFxAgent`
 * runs durable sessions on these.
 */
export async function createFxEngine(options = {}) {
  return createWithFallback("agent", "createCore", options);
}

// The durability a session gets when the caller names none: Vercel's World
// on Vercel, otherwise files in the temporary directory. Each is its own
// module, loaded only here: a bundler copies the file the URL names and
// leaves the import itself to Node.
// Agents created without a durability share one for each place sessions
// live, as agents passed one durability do, so they can send each other's
// prompts on.
const environments = new Map();
function environmentDurability() {
  const dir = process.env.VERCEL ? null : process.env.FX_SESSIONS_DIR || resolve(tmpdir(), "libfx", "sessions");
  const key = dir ?? "vercel";
  if (!environments.has(key)) {
    environments.set(key, chooseEnvironmentDurability(dir).catch((error) => {
      environments.delete(key);
      throw error;
    }));
  }
  return environments.get(key);
}

async function chooseEnvironmentDurability(dir) {
  const load = (asset) => import(/* webpackIgnore: true */ /* turbopackIgnore: true */ (asset.protocol === "" ? bundledAssetUrl(asset) : asset).href);
  if (dir === null) {
    const { vercel } = await load(new URL("./durable/vercel.mjs", import.meta.url));
    return vercel();
  }
  const { local } = await load(new URL("./durable/local.mjs", import.meta.url));
  return local({ dir });
}

/**
 * An agent whose sessions survive crashes, timeouts and redeployments. It
 * does no I/O until a session is used.
 */
export const createFxAgent = createDurableAgentFactory({
  name: "createFxAgent",
  label: "fx agent",
  defaultDurability: environmentDurability,
  // One durability per environment, so agents created without one share it.
  defaultShared: true,
  harness: fxHarness({
    createEngine: createFxEngine,
    // An explicit key, then the durability's own credential, such as a
    // Vercel deployment's OIDC token, then the one in the environment.
    defaultApiKey: async (durability) => process.env.AI_GATEWAY_API_KEY ||
      (await Promise.resolve(durability?.gatewayKey?.()).catch(() => undefined)) ||
      process.env.VERCEL_OIDC_TOKEN || undefined,
  }),
});

export function createFxTerminal(options = {}) {
  return createWithFallback("terminal", "createFxTerminal", options);
}
