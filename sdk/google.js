// Google Gemini credentials for libfx agents: the Gemini API key endpoint
// and the header that carries the host's key. `subscription.js` adds it at the
// fetch edge. Only the API key route is supported today; the Google plan route
// is not supported.
import { tokenString } from "./subscription.js";

const googleOrigin = "https://generativelanguage.googleapis.com";
const interactionsPath = "/v1beta/interactions";
const interactionsEndpoint = `${googleOrigin}${interactionsPath}`;

function endpointOf(url) {
  try {
    const parsed = new URL(String(url));
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return null;
  }
}

/** True only for the Gemini API key endpoint the engine calls. */
export function isGoogleRequest(url) {
  return endpointOf(url) === interactionsEndpoint;
}

/**
 * Google Gemini API key spec for `createSubscriptionAuthorizer()`: the host's
 * API key in `x-goog-api-key`, on `/v1beta/interactions` only. A key has no
 * refresh token, so it is never refreshed, and a rejected request returns as it is.
 */
export function googleApiKeySpec(sessionId) {
  return {
    provider: "google",
    matches: isGoogleRequest,
    sessionId: () => sessionId(),
    normalize(value) {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new TypeError('credentials() must return { apiKey } for provider "google"');
      }
      if (value.accessToken !== undefined && value.apiKey === undefined) {
        throw new TypeError('provider "google" supports only the Gemini API key route ({ apiKey }); Google plan credentials are not supported');
      }
      return { accessToken: tokenString(value.apiKey, "apiKey", true, "Google") };
    },
    authorize(headers, _endpoint, credentials) {
      headers.set("x-goog-api-key", credentials.accessToken);
    },
  };
}
