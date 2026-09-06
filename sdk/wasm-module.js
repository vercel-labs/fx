const modulePromisesBySource = new Map();
const modulePromisesByObject = new WeakMap();
const moduleFailureSource = Symbol("libfx.moduleFailureSource");

export function withModuleFailure(input, onFailure) {
  return { [moduleFailureSource]: { input, onFailure } };
}

async function compileModule(input) {
  const failureSource = input?.[moduleFailureSource];
  if (failureSource) {
    try {
      return await compileModule(failureSource.input);
    } catch (error) {
      failureSource.onFailure();
      throw error;
    }
  }
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

export function loadModule(input) {
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
