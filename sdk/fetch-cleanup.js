export const cleanupTimeoutMs = 100;
export const cleanupByteLimit = 64 * 1024;

// A response's Retry-After in whole seconds, read as native fx reads it
// (digits only), or -1 when it has none. Both hosts pass it to fx.
export function retryAfterSeconds(headers) {
  const value = headers.get("retry-after")?.trim();
  if (!value || !/^\d+$/.test(value)) return -1;
  return Math.min(Number(value), 0x7fffffff);
}

// Policy only; the host owns the reader, clock, cancellation and teardown.
export function fetchCleanupAction(state, maxAge = cleanupTimeoutMs, maxBytes = cleanupByteLimit) {
  if (state.eof) return "done";
  if (state.canceled || state.failed) return "abort";
  if (state.consumed) {
    return state.age >= maxAge || state.discarded >= maxBytes ? "abort" : "drain";
  }
  return state.alive && state.active && !state.closing ? "forward" : "abort";
}
