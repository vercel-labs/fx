// ChatGPT (Codex) credentials for libfx agents: the Codex endpoints, how a
// ChatGPT plan's credentials are checked and refreshed, and the headers that
// carry them. `subscription.js` adds them at the fetch edge.
import { normalizeCredentials } from "./subscription.js";

export const chatgptIssuer = "https://auth.openai.com";
export const chatgptClientId = "app_EMoamEEZ73f0CkXaXp7hrann";

const codexOrigin = "https://chatgpt.com";
const codexPaths = new Set(["/backend-api/codex/responses", "/backend-api/codex/models"]);
const authClaim = "https://api.openai.com/auth";

/** True only for the exact Codex endpoints the engine calls. */
export function isCodexRequest(url) {
  let parsed;
  try { parsed = new URL(String(url)); } catch { return false; }
  return parsed.origin === codexOrigin && codexPaths.has(parsed.pathname);
}

/**
 * Validates credentials from the host. The account id and expiry default to
 * the access token's own claims. Returns a new object.
 */
export function normalizeChatgptCredentials(value) {
  return normalizeCredentials(value, { label: "ChatGPT", accountClaim: (claims) => claims?.[authClaim]?.chatgpt_account_id });
}

/**
 * Exchanges a refresh token at OpenAI. Keeps the old refresh token when the
 * response does not rotate it.
 */
export async function refreshChatgptCredentials(credentials, { fetch, signal } = {}) {
  if (credentials.refreshToken === undefined) throw new TypeError("ChatGPT credentials have no refreshToken");
  const doFetch = fetch ?? globalThis.fetch?.bind(globalThis);
  const response = await doFetch(`${chatgptIssuer}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_id: chatgptClientId, grant_type: "refresh_token", refresh_token: credentials.refreshToken }),
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    const error = new Error(`ChatGPT token refresh failed with HTTP ${response.status}`);
    error.code = "LIBFX_CHATGPT_REFRESH_FAILED";
    error.status = response.status;
    throw error;
  }
  const tokens = await response.json();
  const next = normalizeChatgptCredentials({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token ?? credentials.refreshToken,
    ...(Number.isFinite(tokens.expires_in) ? { expiresAt: Date.now() + tokens.expires_in * 1000 } : {}),
  });
  return next.accountId === credentials.accountId ? next : { ...next, accountId: credentials.accountId };
}

/** Codex on a ChatGPT plan, for `createSubscriptionAuthorizer()`. */
export const codexSubscription = {
  provider: "codex",
  matches: isCodexRequest,
  sessionId: (headers) => headers.get("session-id"),
  normalize: normalizeChatgptCredentials,
  refresh: refreshChatgptCredentials,
  authorize(headers, _endpoint, credentials) {
    headers.set("authorization", `Bearer ${credentials.accessToken}`);
    headers.set("chatgpt-account-id", credentials.accountId);
  },
};
