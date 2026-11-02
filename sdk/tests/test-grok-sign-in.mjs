#!/usr/bin/env node
// `libfx/grok` against a fake xAI: device code sign-in, the paste-the-address
// sign-in and refresh, with the error each mistake produces. No network.
import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import {
  completeDeviceSignIn,
  finishSignIn,
  pollDeviceSignIn,
  refreshCredentials,
  startDeviceSignIn,
  startSignIn,
} from "../grok-sign-in.js";
import { normalizeGrokCredentials } from "../grok.js";

const clientId = "b1a00492-073a-47ea-816f-4c329264a828";
const scope = "openid profile email offline_access grok-cli:access api:access";
const accountId = "xai-account-fixture";

/**
 * A fake xAI auth server. `tokenStatus` answers code exchanges, `pollAnswers`
 * answers device polls in order, and `account` is who userinfo says the token is.
 */
function xai({ tokenStatus = 200, pollAnswers = [], account = accountId, userinfoStatus = 200 } = {}) {
  const log = [];
  const fetch = async (url, init = {}) => {
    const body = typeof init.body === "string" ? init.body : init.body === undefined ? undefined : String(init.body);
    log.push({ url: String(url), method: init.method ?? "GET", headers: new Headers(init.headers), body });
    if (url === "https://auth.x.ai/oauth2/device/code") {
      return Response.json({ device_code: "dc-1", user_code: "ABCD-EFGH", verification_uri: "https://accounts.x.ai/oauth2/device", verification_uri_complete: "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH", expires_in: 1800, interval: 0 });
    }
    if (url === "https://auth.x.ai/oauth2/token") {
      const grant = new URLSearchParams(body).get("grant_type");
      if (grant === "urn:ietf:params:oauth:grant-type:device_code") {
        const answer = pollAnswers.shift() ?? "authorization_pending";
        if (answer !== 200) return Response.json({ error: answer }, { status: 400 });
      } else if (tokenStatus !== 200) {
        return Response.json({ error: "invalid_grant" }, { status: tokenStatus });
      }
      return Response.json({ access_token: `at-${grant}`, refresh_token: grant === "refresh_token" ? "rt-rotated" : "rt-1", expires_in: 21600, token_type: "Bearer" });
    }
    if (url === "https://auth.x.ai/oauth2/userinfo") {
      if (userinfoStatus !== 200) return new Response("no", { status: userinfoStatus });
      return Response.json({ sub: account, email: "user@example.com" });
    }
    return new Response("unexpected", { status: 599 });
  };
  return { fetch, log };
}

const rejectsWith = (promise, code) => assert.rejects(promise, (error) => {
  assert.equal(error.code, code);
  return true;
});
const formOf = (entry) => Object.fromEntries(new URLSearchParams(entry.body));

// startSignIn: the CLI's own authorize request, with an S256 challenge of the secret verifier.
const signIn = await startSignIn();
{
  const url = new URL(signIn.url);
  assert.equal(`${url.origin}${url.pathname}`, "https://auth.x.ai/oauth2/authorize");
  const params = Object.fromEntries(url.searchParams);
  assert.equal(params.client_id, clientId);
  assert.equal(params.response_type, "code");
  assert.equal(params.scope, scope);
  assert.equal(params.code_challenge_method, "S256");
  assert.equal(params.code_challenge, createHash("sha256").update(signIn.verifier).digest("base64url"));
  assert.equal(params.state, signIn.state);
  assert.equal(params.referrer, "fx");
  assert.equal(params.redirect_uri, signIn.redirectUri);
  const redirect = new URL(signIn.redirectUri);
  assert.equal(`${redirect.protocol}//${redirect.hostname}${redirect.pathname}`, "http://127.0.0.1/callback");
  assert.ok(Number(redirect.port) >= 1024 && Number(redirect.port) <= 65535, "a loopback port xAI accepts");
  assert.notEqual((await startSignIn()).verifier, signIn.verifier, "every sign-in has its own secret");
}

// finishSignIn: every paste style yields the account's credentials.
for (const pasted of [
  `${signIn.redirectUri}?code=auth-code&state=${signIn.state}`,
  `code=auth-code&state=${signIn.state}`,
  `\`${signIn.redirectUri}?code=auth-code&state=${signIn.state}\` `,
]) {
  const server = xai();
  const credentials = await finishSignIn(signIn, pasted, { fetch: server.fetch });
  assert.equal(credentials.accessToken, "at-authorization_code");
  assert.equal(credentials.refreshToken, "rt-1");
  assert.equal(credentials.accountId, accountId, "the account comes from userinfo");
  assert.ok(credentials.expiresAt > Date.now() + 5 * 3600 * 1000);
  const exchange = server.log.find((entry) => entry.url === "https://auth.x.ai/oauth2/token");
  assert.equal(exchange.headers.get("content-type"), "application/x-www-form-urlencoded");
  assert.deepEqual(formOf(exchange), { grant_type: "authorization_code", client_id: clientId, code: "auth-code", code_verifier: signIn.verifier, redirect_uri: signIn.redirectUri });
  const userinfo = server.log.find((entry) => entry.url === "https://auth.x.ai/oauth2/userinfo");
  assert.equal(userinfo.headers.get("authorization"), "Bearer at-authorization_code");
}

// finishSignIn: each mistake has its own error.
await rejectsWith(finishSignIn(signIn, `code=auth-code&state=other`, { fetch: xai().fetch }), "LIBFX_GROK_SIGN_IN_STATE_MISMATCH");
await rejectsWith(finishSignIn(signIn, "localhost", { fetch: xai().fetch }), "LIBFX_GROK_SIGN_IN_INVALID_ADDRESS");
await rejectsWith(finishSignIn(signIn, `${signIn.redirectUri}?error=access_denied&state=${signIn.state}`, { fetch: xai().fetch }), "LIBFX_GROK_SIGN_IN_DENIED");
await rejectsWith(finishSignIn(signIn, `code=used&state=${signIn.state}`, { fetch: xai({ tokenStatus: 400 }).fetch }), "LIBFX_GROK_SIGN_IN_EXPIRED");
await rejectsWith(finishSignIn(signIn, `code=c&state=${signIn.state}`, { fetch: xai({ tokenStatus: 503 }).fetch }), "LIBFX_GROK_SIGN_IN_FAILED");
await rejectsWith(finishSignIn(signIn, `code=c&state=${signIn.state}`, { fetch: xai({ userinfoStatus: 401 }).fetch }), "LIBFX_GROK_ACCOUNT_UNAVAILABLE");
await assert.rejects(finishSignIn({ url: signIn.url }, `code=c&state=${signIn.state}`), TypeError);

// Device code: start, pending, slow down, then signed in.
{
  const server = xai({ pollAnswers: ["authorization_pending", "slow_down", 200] });
  const device = await startDeviceSignIn({ fetch: server.fetch });
  assert.equal(device.userCode, "ABCD-EFGH");
  assert.equal(device.verificationUrl, "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH");
  assert.equal(device.intervalMs, 1000, "the interval has a floor of one second");
  assert.ok(device.expiresAt > Date.now() + 29 * 60 * 1000);
  assert.deepEqual(formOf(server.log[0]), { client_id: clientId, scope });
  assert.equal(await pollDeviceSignIn(device, { fetch: server.fetch }), null, "pending");
  assert.equal(await pollDeviceSignIn(device, { fetch: server.fetch }), null, "slow down");
  const credentials = await pollDeviceSignIn(device, { fetch: server.fetch });
  assert.equal(credentials.accessToken, "at-urn:ietf:params:oauth:grant-type:device_code");
  assert.equal(credentials.accountId, accountId);
  const polls = server.log.filter((entry) => entry.url === "https://auth.x.ai/oauth2/token");
  assert.deepEqual(formOf(polls[0]), { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: "dc-1", client_id: clientId });
}
{
  const server = xai({ pollAnswers: ["authorization_pending", 200] });
  const device = await startDeviceSignIn({ fetch: server.fetch });
  const started = Date.now();
  const credentials = await completeDeviceSignIn(device, { fetch: server.fetch });
  assert.equal(credentials.accountId, accountId);
  assert.ok(Date.now() - started >= 900, "waits the interval between polls");
}
{
  const server = xai({ pollAnswers: ["slow_down", "authorization_pending", "authorization_pending"] });
  const device = await startDeviceSignIn({ fetch: server.fetch });
  const controller = new AbortController();
  setTimeout(() => controller.abort(new Error("stopped")), 300);
  await assert.rejects(completeDeviceSignIn(device, { fetch: server.fetch, signal: controller.signal }), /stopped/);
}
await rejectsWith(pollDeviceSignIn(await startDeviceSignIn({ fetch: xai().fetch }), { fetch: xai({ pollAnswers: ["expired_token"] }).fetch }), "LIBFX_GROK_DEVICE_CODE_EXPIRED");
await rejectsWith(pollDeviceSignIn(await startDeviceSignIn({ fetch: xai().fetch }), { fetch: xai({ pollAnswers: ["access_denied"] }).fetch }), "LIBFX_GROK_SIGN_IN_DENIED");
await rejectsWith(pollDeviceSignIn({ ...(await startDeviceSignIn({ fetch: xai().fetch })), expiresAt: Date.now() - 1 }, { fetch: xai().fetch }), "LIBFX_GROK_DEVICE_CODE_EXPIRED");
await rejectsWith(startDeviceSignIn({ fetch: async () => new Response("no", { status: 403 }) }), "LIBFX_GROK_DEVICE_CODE_UNAVAILABLE");

// Refresh: form request, rotation kept, and the account must not change.
{
  const server = xai();
  const next = await refreshCredentials({ accessToken: "at-old", refreshToken: "rt-1", accountId }, { fetch: server.fetch });
  assert.equal(next.accessToken, "at-refresh_token");
  assert.equal(next.refreshToken, "rt-rotated");
  assert.equal(next.accountId, accountId);
  assert.deepEqual(formOf(server.log[0]), { grant_type: "refresh_token", client_id: clientId, refresh_token: "rt-1" });
}
await rejectsWith(refreshCredentials({ accessToken: "at-old", refreshToken: "rt-1", accountId }, { fetch: xai({ account: "someone-else" }).fetch }), "LIBFX_GROK_ACCOUNT_CHANGED");
await rejectsWith(refreshCredentials({ accessToken: "at-old", refreshToken: "rt-1", accountId }, { fetch: xai({ tokenStatus: 400 }).fetch }), "LIBFX_GROK_REFRESH_FAILED");

// Credentials: an opaque token needs an accountId; a JWT's `sub` supplies one.
assert.throws(() => normalizeGrokCredentials({ accessToken: "opaque" }), /Grok credentials need an accountId/);
{
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const token = `${part({ alg: "none" })}.${part({ sub: "from-claim", exp: 2_000_000_000 })}.sig`;
  const credentials = normalizeGrokCredentials({ accessToken: token });
  assert.equal(credentials.accountId, "from-claim");
  assert.equal(credentials.expiresAt, 2_000_000_000_000);
}

console.log("Grok sign-in passed");
