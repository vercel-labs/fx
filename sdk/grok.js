// Grok (xAI subscription) credentials for libfx agents: the Grok endpoints,
// how a Grok plan's credentials are checked and refreshed, and the headers
// that carry them. `subscription.js` adds them at the fetch edge.
import { normalizeCredentials } from "./subscription.js";

export const grokIssuer = "https://auth.x.ai";
export const grokClientId = "b1a00492-073a-47ea-816f-4c329264a828";

const proxyOrigin = "https://cli-chat-proxy.grok.com";
const responsesPath = "/v1/responses";
const modelsPath = "/v1/models";
const languageModelsEndpoint = "https://api.x.ai/v1/language-models";

function endpointOf(url) {
  try {
    const parsed = new URL(String(url));
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return null;
  }
}

/** True only for the exact Grok endpoints the engine calls. */
export function isGrokRequest(url) {
  const endpoint = endpointOf(url);
  return endpoint === `${proxyOrigin}${responsesPath}` ||
    endpoint === `${proxyOrigin}${modelsPath}` ||
    endpoint === languageModelsEndpoint;
}

/**
 * Validates credentials from the host. The account id defaults to the access
 * token's `sub` claim when the token carries one; sign-in from `libfx/grok`
 * always returns it. Returns a new object.
 */
export function normalizeGrokCredentials(value) {
  return normalizeCredentials(value, { label: "Grok", accountClaim: (claims) => claims?.sub });
}

function grokError(code, message, status) {
  const error = new Error(message);
  error.code = code;
  if (status !== undefined) error.status = status;
  return error;
}

/** The xAI account an access token belongs to: the `sub` of its userinfo. */
export async function grokAccountId(accessToken, { fetch, signal } = {}) {
  const doFetch = fetch ?? globalThis.fetch?.bind(globalThis);
  const response = await doFetch(`${grokIssuer}/oauth2/userinfo`, {
    headers: { authorization: `Bearer ${accessToken}`, accept: "application/json" },
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw grokError("LIBFX_GROK_ACCOUNT_UNAVAILABLE", `xAI did not identify the account (HTTP ${response.status})`, response.status);
  }
  const info = await response.json().catch(() => null);
  if (typeof info?.sub !== "string" || info.sub.length === 0) {
    throw grokError("LIBFX_GROK_ACCOUNT_UNAVAILABLE", "xAI's account response had no account id");
  }
  return info.sub;
}

/**
 * Exchanges a refresh token at xAI, keeping the old refresh token when the
 * response does not rotate it, and confirms the new token is for the same
 * account.
 */
export async function refreshGrokCredentials(credentials, { fetch, signal } = {}) {
  if (credentials.refreshToken === undefined) throw new TypeError("Grok credentials have no refreshToken");
  const doFetch = fetch ?? globalThis.fetch?.bind(globalThis);
  const response = await doFetch(`${grokIssuer}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: grokClientId, refresh_token: credentials.refreshToken }).toString(),
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw grokError("LIBFX_GROK_REFRESH_FAILED", `Grok token refresh failed with HTTP ${response.status}`, response.status);
  }
  const tokens = await response.json();
  const next = normalizeGrokCredentials({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token ?? credentials.refreshToken,
    accountId: credentials.accountId,
    ...(Number.isFinite(tokens.expires_in) ? { expiresAt: Date.now() + tokens.expires_in * 1000 } : {}),
  });
  if (await grokAccountId(next.accessToken, { fetch, signal }) !== credentials.accountId) {
    throw grokError("LIBFX_GROK_ACCOUNT_CHANGED", "The refreshed Grok token belongs to a different account");
  }
  return next;
}

/** Grok on a Grok plan, for `createSubscriptionAuthorizer()`. */
export const grokSubscription = {
  provider: "grok",
  matches: isGrokRequest,
  sessionId: (headers) => headers.get("x-grok-conv-id"),
  normalize: normalizeGrokCredentials,
  refresh: refreshGrokCredentials,
  authorize(headers, endpoint, credentials) {
    headers.set("authorization", `Bearer ${credentials.accessToken}`);
    if (endpoint === `${proxyOrigin}${responsesPath}`) headers.set("x-grok-user-id", credentials.accountId);
    if (endpoint === `${proxyOrigin}${modelsPath}`) headers.set("x-userid", credentials.accountId);
  },
};
