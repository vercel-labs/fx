const modulePromisesBySource = new Map();
const modulePromisesByObject = new WeakMap();
const moduleFailureSource = Symbol("libfx.moduleFailureSource");

export function withModuleFailure(input, onFailure) {
  return { [moduleFailureSource]: { input, onFailure } };
}

// A server's error page is not WebAssembly: say which URL answered what,
// instead of letting the compiler report the page's first bytes. The URL
// loses its query, which can hold a signed URL's token. The page is read to
// its end, as a body to compile would be, so the request has finished when
// the error is thrown.
async function responseFailure(response, requested) {
  let url = response.url || requested || "the wasm Response";
  try {
    const parsed = new URL(url);
    url = `${parsed.origin}${parsed.pathname}`;
  } catch {}
  const status = `HTTP ${response.status}${response.statusText ? ` ${response.statusText}` : ""}`;
  await response.arrayBuffer().catch(() => {});
  return Object.assign(
    new Error(`fx WebAssembly at ${url} could not load: the server answered ${status}. Serve the .wasm file at that URL, or pass wasm as bytes or a WebAssembly.Module`),
    { code: "LIBFX_WASM_LOAD_FAILED", url, status: response.status },
  );
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
  const requested = typeof input === "string" ? input : undefined;
  if (typeof input === "string") input = fetch(input);
  if (input instanceof Promise) input = await input;
  if (input instanceof WebAssembly.Module) return input;
  if (input instanceof Response) {
    if (!input.ok) throw await responseFailure(input, requested);
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
