import { access, readFile } from "node:fs/promises";
import { closeSync } from "node:fs";
import { createRequire } from "node:module";
import { Socket } from "node:net";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CoreOutput } from "./core-output.js";
import { loadModule, withModuleFailure } from "./wasm-module.js";
import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";

export { encodeXtermKeyEvent, fxSdkApiVersion, listModels, supportsJspi, xtermAdapter };
export const libfxApiVersion = 2;
const nativeCoreApiVersion = 3;

const fetchOperationStale = 0;
const fetchOperationApplied = 1;
const fetchOperationBackpressure = 2;

const nodeRequire = createRequire(import.meta.url);
const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url);
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url);
let nativeBackendPromise;
const wasmFilePromises = new Map();

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

function jspiFallbackError(surface, nativeError) {
  const nativeDetail = nativeError ? ` Native loading failed: ${nativeError.message}.` : " No compatible native addon was found.";
  const error = new Error(
    `libfx could not start the ${surface} backend.${nativeDetail} ` +
    "The WebAssembly fallback requires JavaScript Promise Integration (JSPI). " +
    "Run Node with --experimental-wasm-jspi or install a libfx package containing a compatible native addon.",
  );
  error.code = "LIBFX_JSPI_REQUIRED";
  error.cause = nativeError;
  return error;
}

async function loadNativeCandidate(candidate) {
  if (candidate == null) return null;
  if (candidate instanceof URL) {
    if (candidate.protocol === "file:" && candidate.pathname.endsWith(".node")) {
      // Bundlers trace the asset URL; Node must load the native file at runtime.
      return Reflect.apply(nodeRequire, undefined, [fileURLToPath(candidate)]);
    }
    const imported = await import(candidate.href);
    return imported.default ?? imported;
  }
  if (typeof candidate === "object") return candidate.default ?? candidate;
  if (typeof candidate !== "string") {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  if (candidate.endsWith(".node")) {
    return Reflect.apply(nodeRequire, undefined, [isAbsolute(candidate) ? candidate : resolve(candidate)]);
  }
  const imported = await import(candidate.startsWith("file:") ? candidate : pathToFileURL(candidate).href);
  return imported.default ?? imported;
}

function defaultNativeCandidate() {
  // Local path bindings let deployment tracers retain these assets in the generated CommonJS entry.
  if (process.platform === "linux" && process.arch === "x64") {
    const path = fileURLToPath(new URL("./libfx.linux-x64.node", import.meta.url));
    return path;
  }
  if (process.platform === "linux" && process.arch === "arm64") {
    const path = fileURLToPath(new URL("./libfx.linux-arm64.node", import.meta.url));
    return path;
  }
  if (process.platform === "darwin" && process.arch === "x64") {
    const path = fileURLToPath(new URL("./libfx.darwin-x64.node", import.meta.url));
    return path;
  }
  if (process.platform === "darwin" && process.arch === "arm64") {
    const path = fileURLToPath(new URL("./libfx.darwin-arm64.node", import.meta.url));
    return path;
  }
  return null;
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
  if (candidate instanceof URL) return candidate.protocol === "file:" ? fileURLToPath(candidate) : null;
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
  const candidate = defaultNativeCandidate();
  if (!candidate) {
    return { backend: null, error: null, failure: "unsupported" };
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

function wasmInput(input) {
  const path = wasmFilePath(input);
  if (path === null) {
    if (input instanceof URL) return input.href;
    return input;
  }
  const cached = wasmFilePromises.get(path);
  if (cached) return cached;
  const pendingRead = readFile(path);
  let pending;
  pending = withModuleFailure(pendingRead, () => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  wasmFilePromises.set(path, pending);
  pendingRead.catch(() => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  return pending;
}

function wasmFilePath(input) {
  if (input instanceof URL && input.protocol === "file:") return fileURLToPath(input);
  if (typeof input === "string" && !URL.canParse(input)) return resolve(input);
  return null;
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
        `native addon artifact was not found${detailError?.message ? `: ${detailError.message}` : ""}`,
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
        "WebAssembly backend requires JavaScript Promise Integration (JSPI)",
      ),
    });
    return { surface, backend: "unavailable", attempts };
  }
  const defaultWasm = surface === "agent" ? defaultCoreWasm : defaultTermWasm;
  const wasmSource = wasm ?? defaultWasm;
  try {
    await loadModule(await wasmInput(wasmSource));
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
  const { apiKey, model, gatewayChatUrl } = options;
  const core = addon.createCore({
    apiKey,
    home: options.home ?? homedir(),
    workspaceRoot: options.workspaceRoot ?? process.cwd(),
    ...(model === undefined ? {} : { model }),
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
  const abortHostEffects = () => {
    fetchState?.controller.abort();
    try { addon.abortCoreFetch(core); } catch {}
  };
  const finish = (code, error) => {
    if (settled) return;
    settled = true;
    outputError = error;
    output.close();
    abortHostEffects();
    try { addon.destroyCore(core); } catch {}
    readySocket.destroy();
    void readyClosed.then(() => exitedResolve(code));
  };
  const pumpFetch = async (request) => {
    const controller = new AbortController();
    const state = { handle: request.handle, controller };
    fetchState = state;
    try {
      const response = await (options.fetch ?? globalThis.fetch)(request.url, {
        method: request.method,
        headers: new Headers(JSON.parse(request.headers).map(({ name, value }) => [name, value])),
        body: request.body?.length ? Buffer.from(request.body, "base64") : undefined,
        signal: controller.signal,
      });
      const started = addon.startCoreFetchResponse(core, state.handle, response.status);
      if (started === fetchOperationStale) return;
      if (started !== fetchOperationApplied) throw new Error(`invalid native fetch start result ${started}`);
      if (response.body) {
        for await (const chunk of response.body) {
          const buffer = Buffer.from(chunk);
          let offset = 0;
          while (offset < buffer.length) {
            const end = Math.min(offset + 64 * 1024, buffer.length);
            const pushed = addon.pushCoreFetchResponse(core, state.handle, buffer.subarray(offset, end));
            if (pushed === fetchOperationApplied) {
              offset = end;
              continue;
            }
            if (pushed === fetchOperationStale) return;
            if (pushed !== fetchOperationBackpressure) throw new Error(`invalid native fetch push result ${pushed}`);
            await new Promise((resolve) => setTimeout(resolve, 2));
          }
        }
      }
      const finished = addon.finishCoreFetch(core, state.handle);
      if (finished !== fetchOperationApplied && finished !== fetchOperationStale) {
        throw new Error(`invalid native fetch finish result ${finished}`);
      }
    } catch (error) {
      if (error?.name !== "AbortError" || !controller.signal.aborted) {
        try {
          if (addon.coreFetchActive(core, state.handle)) addon.failCoreFetch(core, state.handle);
        } catch {}
      }
    } finally {
      if (fetchState === state) {
        fetchState = null;
        queueMicrotask(drainReady);
      }
    }
  };
  function drainReady() {
    if (settled) return;
    try {
      if (fetchState) {
        if (!fetchState.controller.signal.aborted && !addon.coreFetchActive(core, fetchState.handle)) {
          fetchState.controller.abort();
        }
      } else {
        const fetchRequest = addon.takeCoreFetch(core);
        if (fetchRequest) void pumpFetch(JSON.parse(fetchRequest.toString("utf8")));
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
  return createWasmAgent({
    ...options,
    runtimeFactory(runtimeOptions) {
      return createNativeCoreRuntime(addon, runtimeOptions);
    },
  });
}

async function createWithFallback(surface, nativeMethod, wasmFactory, defaultWasm, options) {
  const { nativeAddon, backend = "auto", ...runtimeOptions } = options ?? {};
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }

  let nativeError;
  let nativeAttempted = false;
  if (backend !== "wasm") {
    const native = await resolveNativeBackend(nativeAddon);
    nativeError = native.error;
    if (typeof native.backend?.[nativeMethod] === "function") {
      nativeAttempted = true;
      try {
        if (surface === "agent") return await createNativeAgent(native.backend, runtimeOptions);
        return await native.backend[nativeMethod](runtimeOptions);
      } catch (error) {
        nativeError = error;
        if (backend === "native") throw error;
      }
    }
    if (backend === "native") {
      const error = nativeError ?? new Error(`native addon does not provide ${nativeMethod}()`);
      error.code ??= "LIBFX_NATIVE_UNAVAILABLE";
      throw error;
    }
  }

  if (!supportsJspi()) {
    if (nativeAttempted) throw nativeError;
    throw jspiFallbackError(surface, nativeError);
  }
  const wasmSource = runtimeOptions.wasm ?? defaultWasm;
  return wasmFactory({ ...runtimeOptions, wasm: await wasmInput(wasmSource) });
}

export async function createFxAgent(options = {}) {
  if (options != null && Object.hasOwn(Object(options), "env")) {
    throw new TypeError("createFxAgent() does not accept env; pass apiKey and model directly");
  }
  return createWithFallback(
    "agent",
    "createCore",
    createWasmAgent,
    defaultCoreWasm,
    options,
  );
}

export function createFxTerminal(options = {}) {
  return createWithFallback("terminal", "createFxTerminal", createWasmTerminal, defaultTermWasm, options);
}
