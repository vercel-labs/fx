// Pieces the subscription sign-ins share: PKCE secrets, reading a pasted
// redirect address, and waiting between device code polls.

const maxAddressBytes = 16 * 1024;
const encoder = new TextEncoder();

export function signInError(code, message, fields = {}) {
  const error = new Error(message);
  error.code = code;
  return Object.assign(error, fields);
}

const base64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** A random URL-safe secret, for a PKCE verifier or an OAuth state. */
export const randomSecret = () => base64url(crypto.getRandomValues(new Uint8Array(32)));

/** The S256 challenge for a PKCE verifier. */
export async function pkceChallenge(verifier) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(verifier))));
}

export const hostFetch = (fetch) => fetch ?? globalThis.fetch?.bind(globalThis);

/**
 * Reads the sign-in result from a pasted address: the whole address, its query,
 * or either wrapped in quotes, backticks or angle brackets. `prefix` names the
 * error codes, `issuer` the sign-in page, and `redirectUri` the address the
 * user should have copied.
 */
export function readSignInAddress(text, { prefix, issuer, redirectUri }) {
  if (typeof text !== "string" || encoder.encode(text).length > maxAddressBytes) {
    throw signInError(`${prefix}_SIGN_IN_INVALID_ADDRESS`, `Paste the address of the page ${issuer} opened after you signed in.`);
  }
  const trimmed = text.trim().replace(/^[`'"<\s]+|[`'">\s]+$/g, "");
  let params;
  try {
    params = new URL(trimmed).searchParams;
  } catch {
    params = new URLSearchParams(trimmed.includes("?") ? trimmed.slice(trimmed.indexOf("?") + 1) : trimmed);
  }
  const error = params.get("error");
  if (error) {
    throw signInError(`${prefix}_SIGN_IN_DENIED`, `${issuer} did not sign you in: ${params.get("error_description") || error}`, { reason: error });
  }
  const code = params.get("code");
  if (!code) {
    throw signInError(
      `${prefix}_SIGN_IN_INVALID_ADDRESS`,
      `That address has no sign-in code. Copy the whole address of the page ${issuer} opened after you signed in; it starts with ${redirectUri}?code=`,
    );
  }
  return { code, state: params.get("state") };
}

/** Resolves after `ms`, or rejects when `signal` aborts first. */
export function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
    const timer = setTimeout(() => { signal?.removeEventListener("abort", onAbort); resolve(); }, ms);
    const onAbort = () => { clearTimeout(timer); reject(signal.reason ?? new DOMException("Aborted", "AbortError")); };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
