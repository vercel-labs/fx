// `libfx/grok`: sign in with a Grok plan for a Grok agent. Two flows, both
// plain data between steps so a website can start in one request and finish in
// another:
//
// - Device code: the user enters a short code on xAI's page.
// - Paste the address: the user signs in on xAI, lands on a page at
//   127.0.0.1 that does not load, and pastes its address back.
import { grokAccountId, grokClientId, grokIssuer, normalizeGrokCredentials, refreshGrokCredentials } from "./grok.js";
import { hostFetch, pkceChallenge, randomSecret, readSignInAddress, signInError, wait } from "./oauth.js";

const scope = "openid profile email offline_access grok-cli:access api:access";
const deviceGrant = "urn:ietf:params:oauth:grant-type:device_code";
const slowDownMs = 5000;

const form = (fields) => ({
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
  body: new URLSearchParams(fields).toString(),
});

/** Credentials for a token response, with the account it belongs to. */
async function credentialsFor(tokens, { fetch, signal }) {
  const accountId = await grokAccountId(tokens.access_token, { fetch, signal });
  return normalizeGrokCredentials({
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token,
    accountId,
    ...(Number.isFinite(tokens.expires_in) ? { expiresAt: Date.now() + tokens.expires_in * 1000 } : {}),
  });
}

/** Starts a sign-in. Keep the result on the server: `verifier` is secret. */
export async function startSignIn() {
  const verifier = randomSecret();
  const state = randomSecret();
  // xAI accepts any loopback port. Nothing listens there: the user copies the address.
  const port = 1024 + (crypto.getRandomValues(new Uint16Array(1))[0] % (65536 - 1024));
  const redirectUri = `http://127.0.0.1:${port}/callback`;
  const url = new URL(`${grokIssuer}/oauth2/authorize`);
  for (const [key, value] of Object.entries({
    response_type: "code",
    client_id: grokClientId,
    redirect_uri: redirectUri,
    scope,
    code_challenge: await pkceChallenge(verifier),
    code_challenge_method: "S256",
    state,
    referrer: "fx",
  })) url.searchParams.set(key, value);
  return { url: url.href, state, verifier, redirectUri };
}

/** Finishes a sign-in from the address the user pasted. */
export async function finishSignIn(signIn, address, { fetch, signal } = {}) {
  if (!signIn || typeof signIn.state !== "string" || typeof signIn.verifier !== "string" || typeof signIn.redirectUri !== "string") {
    throw new TypeError("finishSignIn() needs the object startSignIn() returned");
  }
  const { code, state } = readSignInAddress(address, { prefix: "LIBFX_GROK", issuer: "xAI", redirectUri: signIn.redirectUri });
  if (state !== signIn.state) {
    throw signInError("LIBFX_GROK_SIGN_IN_STATE_MISMATCH", "That address is from a different sign-in. Start again and paste the address from this one.");
  }
  const response = await hostFetch(fetch)(`${grokIssuer}/oauth2/token`, {
    ...form({ grant_type: "authorization_code", client_id: grokClientId, code, code_verifier: signIn.verifier, redirect_uri: signIn.redirectUri }),
    signal,
  });
  if (response.status === 400 || response.status === 401) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_GROK_SIGN_IN_EXPIRED", "This sign-in expired or was already used. Start again.", { status: response.status });
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_GROK_SIGN_IN_FAILED", `xAI could not finish the sign-in (HTTP ${response.status}).`, { status: response.status });
  }
  return credentialsFor(await response.json(), { fetch, signal });
}

/** Starts a device code sign-in. Show `userCode` and `verificationUrl`. */
export async function startDeviceSignIn({ fetch, signal } = {}) {
  const response = await hostFetch(fetch)(`${grokIssuer}/oauth2/device/code`, { ...form({ client_id: grokClientId, scope }), signal });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw signInError("LIBFX_GROK_DEVICE_CODE_UNAVAILABLE", `xAI did not issue a device code (HTTP ${response.status}).`, { status: response.status });
  }
  const body = await response.json();
  const expiresIn = Number(body.expires_in);
  if (typeof body.user_code !== "string" || typeof body.device_code !== "string" || typeof body.verification_uri !== "string" || !Number.isFinite(expiresIn)) {
    throw signInError("LIBFX_GROK_DEVICE_CODE_UNAVAILABLE", "xAI returned a device code response libfx does not understand.");
  }
  const interval = Number(body.interval);
  return {
    verificationUrl: typeof body.verification_uri_complete === "string" ? body.verification_uri_complete : body.verification_uri,
    userCode: body.user_code,
    deviceCode: body.device_code,
    intervalMs: Math.max(Number.isFinite(interval) ? interval : 5, 1) * 1000,
    expiresAt: Date.now() + expiresIn * 1000,
  };
}

/** One poll: `{ credentials }`, or `{ pending: true, slowDown }` until the user enters the code. */
async function poll(device, { fetch, signal }) {
  if (!device || typeof device.deviceCode !== "string" || typeof device.userCode !== "string") {
    throw new TypeError("pollDeviceSignIn() needs the object startDeviceSignIn() returned");
  }
  if (Date.now() > device.expiresAt) {
    throw signInError("LIBFX_GROK_DEVICE_CODE_EXPIRED", "The code expired before it was entered. Start again.");
  }
  const response = await hostFetch(fetch)(`${grokIssuer}/oauth2/token`, {
    ...form({ grant_type: deviceGrant, device_code: device.deviceCode, client_id: grokClientId }),
    signal,
  });
  if (response.ok) return { credentials: await credentialsFor(await response.json(), { fetch, signal }) };
  const body = await response.json().catch(() => null);
  switch (body?.error) {
    case "authorization_pending": return { pending: true, slowDown: false };
    case "slow_down": return { pending: true, slowDown: true };
    case "expired_token":
      throw signInError("LIBFX_GROK_DEVICE_CODE_EXPIRED", "The code expired before it was entered. Start again.");
    case "access_denied":
      throw signInError("LIBFX_GROK_SIGN_IN_DENIED", "The sign-in was declined on xAI's page.", { reason: body.error });
    default:
      throw signInError("LIBFX_GROK_SIGN_IN_FAILED", `xAI could not finish the sign-in (HTTP ${response.status}).`, { status: response.status });
  }
}

/** Checks a device sign-in once: credentials when the user has entered the code, otherwise null. */
export async function pollDeviceSignIn(device, { fetch, signal } = {}) {
  const result = await poll(device, { fetch, signal });
  return result.credentials ?? null;
}

/** Waits until the user enters the code, polling at xAI's interval and slowing down when asked. */
export async function completeDeviceSignIn(device, { fetch, signal } = {}) {
  let intervalMs = device?.intervalMs;
  for (;;) {
    const result = await poll(device, { fetch, signal });
    if (result.credentials) return result.credentials;
    if (result.slowDown) intervalMs += slowDownMs;
    await wait(intervalMs, signal);
  }
}

/** Refreshes credentials. Grok agents refresh on their own; this is for hosts. */
export function refreshCredentials(credentials, { fetch, signal } = {}) {
  return refreshGrokCredentials(normalizeGrokCredentials(credentials), { fetch, signal });
}
