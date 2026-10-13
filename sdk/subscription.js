// Subscription credentials for libfx agents: Codex on a ChatGPT plan, Grok on
// a Grok plan. The engine sends these providers' requests without credentials;
// this module adds them at the fetch edge, from the host's `credentials`
// callback, refreshing near expiry and once after a rejection. Credentials
// never enter the engine or a session's saved records, and are masked in the
// body of a failed response.
//
// A provider spec supplies what differs: which requests it authorizes, how its
// credentials are checked and refreshed, and which headers carry them.

const refreshSkewMs = 5 * 60 * 1000;
const maxRememberedCredentials = 256;
const maxTokenBytes = 64 * 1024;
const maxErrorBodyBytes = 64 * 1024;
const encoder = new TextEncoder();

/** A non-empty, bounded credential field, or undefined when optional and absent. */
export function tokenString(value, name, required, label) {
  if (value === undefined && !required) return undefined;
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`${label} credentials ${name} must be a non-empty string`);
  }
  if (encoder.encode(value).length > maxTokenBytes) {
    throw new RangeError(`${label} credentials ${name} exceeds ${maxTokenBytes} bytes`);
  }
  return value;
}

/** The claims of a JWT, or null when it is not one. Does not verify it. */
export function jwtClaims(token) {
  const part = typeof token === "string" ? token.split(".")[1] : undefined;
  if (!part) return null;
  try {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const binary = atob(base64);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const claims = JSON.parse(new TextDecoder().decode(bytes));
    return claims && typeof claims === "object" ? claims : null;
  } catch {
    return null;
  }
}

/**
 * Validates credentials from the host. `accountId` and `expiresAt` default to
 * the access token's claims, `accountClaim(claims)` picking the account.
 * Returns a new object.
 */
export function normalizeCredentials(value, { label, accountClaim }) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("credentials() must return { accessToken, refreshToken?, accountId?, expiresAt? }");
  }
  const accessToken = tokenString(value.accessToken, "accessToken", true, label);
  const refreshToken = tokenString(value.refreshToken, "refreshToken", false, label);
  const claims = jwtClaims(accessToken);
  const accountId = value.accountId === undefined ? accountClaim(claims) : tokenString(value.accountId, "accountId", true, label);
  if (typeof accountId !== "string" || accountId.length === 0) {
    throw new TypeError(`${label} credentials need an accountId; it was not in the access token`);
  }
  let expiresAt = value.expiresAt;
  if (expiresAt === undefined && Number.isFinite(claims?.exp)) expiresAt = claims.exp * 1000;
  if (expiresAt !== undefined && !Number.isFinite(expiresAt)) {
    throw new TypeError(`${label} credentials expiresAt must be milliseconds since the epoch`);
  }
  return { accessToken, ...(refreshToken === undefined ? {} : { refreshToken }), accountId, ...(expiresAt === undefined ? {} : { expiresAt }) };
}

/**
 * A failed response whose body cannot repeat the credentials its request
 * carried. Some servers quote the bearer token back in an error, and the
 * engine shows and saves error details, so this edge, the only code that knows
 * the token, masks it the way fx masks error details from its own providers.
 * JSON is normalized first, so an escaped copy cannot survive.
 */
async function withoutCredentials(response, credentials) {
  if (response.status < 400) return response;
  const raw = await boundedText(response, maxErrorBodyBytes);
  let body = raw ?? "Provider error details exceeded the local limit";
  if (raw !== null && /^\s*[[{"]/.test(raw)) {
    try {
      body = JSON.stringify(JSON.parse(raw));
    } catch {
      body = "Provider error details could not be decoded";
    }
  }
  for (const secret of [credentials.accessToken, credentials.refreshToken]) {
    if (!secret) continue;
    for (const form of new Set([secret, JSON.stringify(secret).slice(1, -1)])) body = body.split(form).join("*".repeat(form.length));
  }
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  headers.delete("content-encoding");
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}

/** The body as text, or null once it exceeds `limit` bytes. */
async function boundedText(response, limit) {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return text + decoder.decode();
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
}

/** True when the credentials can and should be refreshed before use. */
export function needsRefresh(credentials, nowMs) {
  return credentials.refreshToken !== undefined &&
    credentials.expiresAt !== undefined &&
    credentials.expiresAt - refreshSkewMs <= nowMs;
}

/** The engine option that carries an agent's `createCredentialMemory()`. */
export const credentialMemory = Symbol.for("libfx.credentialMemory");

/**
 * Refresh state for `createSubscriptionAuthorizer()`. An agent gives the same
 * memory to every session's engine, so its sessions refresh an account once.
 */
export function createCredentialMemory() {
  return { descendants: new Map(), refreshing: new Map(), saved: new WeakMap() };
}

/**
 * The fetch edge for subscription requests. `credentials({ provider, sessionId })`
 * supplies credentials; `onCredentials(next, { provider, sessionId })` receives
 * refreshed ones once for each session that uses them, so the host can save them.
 * `refreshLock({ provider, sessionId }, refresh)` runs `refresh` while the host
 * holds a lock on the account, for a host with several servers.
 *
 * Each spec: `{ provider, matches(endpoint), sessionId(headers), normalize(value),
 * refresh(credentials, { fetch, signal }), authorize(headers, endpoint, credentials) }`.
 */
export function createSubscriptionAuthorizer(specs, { credentials, onCredentials, refreshLock, fetch, now = Date.now, memory = createCredentialMemory() }) {
  if (typeof credentials !== "function") throw new TypeError("a subscription provider needs a credentials() function");
  if (onCredentials !== undefined && typeof onCredentials !== "function") {
    throw new TypeError("onCredentials must be a function");
  }
  if (refreshLock !== undefined && typeof refreshLock !== "function") {
    throw new TypeError("refreshLock must be a function");
  }
  // Each access token the host supplied maps to the newest credentials refreshed
  // from it, so a host that has not saved a rotation yet never spends the old
  // refresh token twice. Engines that share `memory` share this.
  const { descendants, refreshing, saved } = memory;
  const keyOf = (spec, token) => `${spec.provider}\u0000${token}`;

  const remember = (spec, supplied, next) => {
    const key = keyOf(spec, supplied.accessToken);
    descendants.delete(key);
    descendants.set(key, next);
    if (descendants.size > maxRememberedCredentials) descendants.delete(descendants.keys().next().value);
  };

  // A host that keeps credentials per session must also save a rotation that
  // another session's request made.
  const savedBy = (next) => {
    let sessions = saved.get(next);
    if (!sessions) saved.set(next, (sessions = new Set()));
    return sessions;
  };
  const save = async (spec, next, sessionId) => {
    if (!onCredentials) return;
    const sessions = savedBy(next);
    if (sessions.has(sessionId)) return;
    sessions.add(sessionId);
    await onCredentials(next, { provider: spec.provider, sessionId });
  };

  const redeem = async (spec, supplied, current, sessionId, signal) => {
    if (refreshLock) {
      // Another server may have refreshed and saved them while this one waited.
      const latest = spec.normalize(await credentials({ provider: spec.provider, sessionId }));
      if (latest.accessToken !== current.accessToken && latest.accessToken !== supplied.accessToken && !needsRefresh(latest, now())) {
        remember(spec, supplied, latest);
        savedBy(latest).add(sessionId);
        return latest;
      }
    }
    const next = await spec.refresh(current, { fetch, signal });
    remember(spec, supplied, next);
    await save(spec, next, sessionId);
    return next;
  };

  // With `refreshLock`, the host holds a lock on the account while the refresh
  // runs, so its servers refresh one at a time.
  const locked = async (spec, supplied, current, sessionId, signal) => {
    let next;
    await refreshLock({ provider: spec.provider, sessionId }, async () => {
      next = await redeem(spec, supplied, current, sessionId, signal);
    });
    if (next === undefined) throw new Error("refreshLock must run and await the refresh it is given");
    return next;
  };

  const refresh = async (spec, supplied, current, sessionId, signal) => {
    const key = keyOf(spec, current.refreshToken);
    let task = refreshing.get(key);
    if (!task) {
      task = (refreshLock ? locked : redeem)(spec, supplied, current, sessionId, signal).finally(() => refreshing.delete(key));
      refreshing.set(key, task);
    }
    const next = await task;
    if (sessionId !== undefined) await save(spec, next, sessionId);
    return next;
  };

  const current = async (spec, sessionId, signal) => {
    const supplied = spec.normalize(await credentials({ provider: spec.provider, sessionId }));
    const best = descendants.get(keyOf(spec, supplied.accessToken)) ?? supplied;
    const used = needsRefresh(best, now()) ? await refresh(spec, supplied, best, sessionId, signal) : best;
    if (used !== supplied && sessionId !== undefined) await save(spec, used, sessionId);
    return { supplied, used };
  };

  const withCredentials = (spec, endpoint, init, used) => {
    const headers = new Headers(init.headers);
    spec.authorize(headers, endpoint, used);
    return { ...init, headers };
  };

  return {
    /** The spec that authorizes requests to `endpoint` (origin and path), if any. */
    specFor: (endpoint) => specs.find((spec) => spec.matches(endpoint)),
    /** Sends one request with credentials, refreshing once after a 401. */
    async fetch(spec, endpoint, hostFetch, input, init = {}) {
      const sessionId = spec.sessionId(new Headers(init.headers)) || undefined;
      const { used } = await current(spec, sessionId, init.signal);
      const response = await hostFetch(input, withCredentials(spec, endpoint, init, used));
      if (response.status !== 401 || used.refreshToken === undefined) return withoutCredentials(response, used);
      await response.body?.cancel().catch(() => {});
      // Another request may have replaced these credentials while this one was
      // out. Only a rejection of the newest ones spends a refresh token.
      const latest = await current(spec, sessionId, init.signal);
      const next = latest.used.accessToken !== used.accessToken
        ? latest.used
        : await refresh(spec, latest.supplied, used, sessionId, init.signal);
      return withoutCredentials(await hostFetch(input, withCredentials(spec, endpoint, init, next)), next);
    },
  };
}
