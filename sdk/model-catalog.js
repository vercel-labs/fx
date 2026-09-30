const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const sharedStores = new WeakMap();
const maxCatalogBytes = 4 * 1024 * 1024;
const maxCatalogEntries = 10000;
const maxScopes = 16;
const maxStoreBytes = 16 * 1024 * 1024;
const freshMs = 5 * 60 * 1000;
const usableMs = 60 * 60 * 1000;
const retryMs = 1000;
export const maxModelBytes = 1024;
let nextRevision = 1;

export async function cancelResponseBody(response) {
  try { await response.body?.cancel(); } catch {}
}

async function readCatalog(response, signal, previous) {
  if (signal?.aborted) {
    await cancelResponseBody(response);
    throw signal.reason;
  }
  const declared = Number(response.headers.get("content-length"));
  if (declared > maxCatalogBytes) {
    await cancelResponseBody(response);
    throw new RangeError("model catalog exceeds the 4194304 byte libfx limit");
  }
  const reader = response.body?.getReader();
  const abort = () => { void reader?.cancel(signal?.reason).catch(() => {}); };
  signal?.addEventListener("abort", abort, { once: true });
  const chunks = [];
  let length = 0;
  try {
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > maxCatalogBytes) {
          try { await reader.cancel(); } catch {}
          throw new RangeError("model catalog exceeds the 4194304 byte libfx limit");
        }
        chunks.push(value);
      }
    } else {
      const bytes = new Uint8Array(await response.arrayBuffer());
      length = bytes.length;
      if (length > maxCatalogBytes) throw new RangeError("model catalog exceeds the 4194304 byte libfx limit");
      chunks.push(bytes);
    }
  } finally { signal?.removeEventListener("abort", abort); reader?.releaseLock(); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let text, catalog;
  try {
    text = decoder.decode(bytes);
    if (previous?.text === text) return { ...previous, revision: String(nextRevision++) };
    catalog = JSON.parse(text);
  } catch { throw new TypeError("model catalog response is malformed"); }
  if (!catalog || typeof catalog !== "object" || !Array.isArray(catalog.data)) throw new TypeError("model catalog response is malformed");
  if (catalog.data.length > maxCatalogEntries) throw new RangeError("model catalog exceeds the 10000 entry libfx limit");
  const byId = new Map();
  for (const entry of catalog.data) {
    if (!entry || typeof entry !== "object" ||
        (typeof entry.type === "string" && entry.type.toLowerCase() !== "language") ||
        typeof entry.id !== "string" || !entry.id || encoder.encode(entry.id).length > maxModelBytes) continue;
    const rows = byId.get(entry.id) ?? [];
    rows.push(entry);
    byId.set(entry.id, rows);
  }
  return { text, bytes: length, byId, ids: [...byId.keys()].sort(), revision: String(nextRevision++) };
}

class CatalogHttpError extends Error {
  constructor(status, retryAfter) {
    super(`model catalog request failed with HTTP ${status}`);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

function scopeKey(url, init) {
  const headers = new Headers(init.headers);
  return JSON.stringify([String(url), headers.get("authorization"), headers.get("x-vercel-ai-gateway-team")]);
}

function waitFor(promise, signal) {
  if (!signal) return promise;
  if (signal.aborted) {
    void promise.catch(() => {});
    return Promise.reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
  }
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}

export function createCatalogReader(fetchSource, {
  identity = fetchSource, shared = false, now = () => performance.now(), onBackgroundTask,
} = {}) {
  let store = shared ? sharedStores.get(identity) : null;
  if (!store) {
    store = new Map();
    if (shared) sharedStores.set(identity, store);
  }
  const due = new Map();
  let lastEntry = null;

  function evict() {
    let bytes = 0;
    for (const entry of store.values()) bytes += entry.snapshot?.bytes ?? 0;
    for (const [key, entry] of store) {
      if (store.size <= maxScopes && bytes <= maxStoreBytes) break;
      if (entry.pending) continue;
      store.delete(key);
      bytes -= entry.snapshot?.bytes ?? 0;
    }
  }

  function entryFor(url, init) {
    const key = scopeKey(url, init);
    let entry = store.get(key);
    if (!entry) {
      entry = { key, url: String(url), init: { method: "GET", headers: new Headers(init.headers) },
        snapshot: null, fetchedAt: 0, retryAt: 0, error: null, pending: null, controller: null, invalidated: false, waiters: 0, background: false, failures: 0 };
      if (store.size < maxScopes || [...store.values()].some(item => !item.pending)) {
        store.set(key, entry);
        evict();
      }
    }
    lastEntry = entry;
    return entry;
  }

  function start(entry) {
    if (entry.pending) return entry.pending;
    const controller = new AbortController();
    entry.controller = controller;
    const timeout = setTimeout(() => controller.abort(new DOMException("Catalog request timed out", "TimeoutError")), 10000);
    const pending = (async () => {
      let ownedResponse;
      try {
        const fetchTask = Promise.resolve().then(() => fetchSource(entry.url, { ...entry.init, signal: controller.signal })).then(async response => {
          ownedResponse = response;
          if (controller.signal.aborted) {
            await cancelResponseBody(response);
            throw controller.signal.reason;
          }
          return response;
        });
        const response = await waitFor(fetchTask, controller.signal);
        if (!response.ok) {
          const retryAfter = response.headers.get("retry-after");
          await cancelResponseBody(response);
          throw new CatalogHttpError(response.status, retryAfter);
        }
        const snapshot = await waitFor(readCatalog(response, controller.signal, entry.snapshot), controller.signal);
        if (entry.invalidated || controller.signal.aborted) throw new DOMException("Aborted", "AbortError");
        entry.snapshot = snapshot;
        entry.fetchedAt = now();
        entry.error = null;
        entry.retryAt = 0;
        entry.failures = 0;
        evict();
        return snapshot;
      } catch (error) {
        if (controller.signal.aborted && ownedResponse) await cancelResponseBody(ownedResponse);
        entry.error = error;
        entry.failures++;
        const seconds = Number(error.retryAfter);
        const dateDelay = Date.parse(error.retryAfter) - Date.now();
        const delay = Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds * 1000, usableMs)
          : Number.isFinite(dateDelay) && dateDelay > 0 ? Math.min(dateDelay, usableMs) : retryMs;
        const transient = !(error instanceof CatalogHttpError) && !(error instanceof RangeError) && error.message !== "model catalog response is malformed";
        entry.retryAt = error.name === "AbortError" || (transient && entry.failures === 1) ? 0 : now() + delay;
        if (error.status === 401 || error.status === 403) entry.snapshot = null;
        throw error;
      } finally {
        clearTimeout(timeout);
        entry.pending = null;
        entry.controller = null;
        entry.background = false;
      }
    })();
    entry.pending = pending;
    void pending.catch(() => {});
    return pending;
  }

  function usable(entry) {
    const age = now() - entry.fetchedAt;
    return !entry.invalidated && entry.snapshot && age >= 0 && age < usableMs;
  }

  async function get(url, init) {
    const entry = entryFor(url, init);
    if (usable(entry)) {
      if (now() - entry.fetchedAt >= freshMs) due.set(entry.key, entry);
      return entry.snapshot;
    }
    if (!entry.pending && entry.error && now() < entry.retryAt) throw entry.error;
    entry.waiters++;
    try { return await waitFor(start(entry), init.signal); }
    finally {
      entry.waiters--;
      if (entry.pending && !entry.waiters && !entry.background) entry.controller?.abort();
    }
  }

  return {
    async models(url, init) { return [...(await get(url, init)).ids]; },
    async fetch(url, init) {
      try {
        return new Response((await get(url, init)).text, { headers: { "content-type": "application/json" } });
      } catch (error) {
        if (!(error instanceof CatalogHttpError)) throw error;
        return new Response(null, { status: error.status });
      }
    },
    metadata(url, init, model) {
      if (!model) return null;
      const key = scopeKey(url, init);
      const entry = store.get(key) ?? (!shared && lastEntry?.key === key ? lastEntry : null);
      if (!entry || !usable(entry)) return null;
      const age = now() - entry.fetchedAt;
      const data = entry.snapshot.byId.get(model) ?? [];
      if (age >= freshMs || (!data.length && age >= 30000)) due.set(key, entry);
      const value = { model, revision: entry.snapshot.revision, validForMs: Math.floor(usableMs - age), data };
      const serialized = JSON.stringify(value);
      if (data.length > 64 || encoder.encode(serialized).length > 65536) return null;
      return JSON.parse(serialized);
    },
    refresh() {
      for (const [key, entry] of due) {
        due.delete(key);
        if (entry.invalidated || entry.pending || now() < entry.retryAt) continue;
        entry.background = true;
        const task = start(entry).catch(() => {});
        onBackgroundTask?.(task);
      }
    },
    invalidate(url, init) {
      const key = scopeKey(url, init);
      const entry = store.get(key) ?? (!shared && lastEntry?.key === key ? lastEntry : null);
      if (!entry) return;
      entry.invalidated = true;
      entry.snapshot = null;
      entry.controller?.abort();
      store.delete(key);
      due.delete(key);
      if (lastEntry === entry) lastEntry = null;
    },
    release() {
      lastEntry = null;
      due.clear();
      if (!shared) {
        for (const entry of store.values()) entry.controller?.abort();
        store.clear();
      }
    },
  };
}
