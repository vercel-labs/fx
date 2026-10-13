#!/usr/bin/env node
// `libfx/chatgpt` against a fake OpenAI: the paste-the-address sign-in, device
// code sign-in and refresh, with the error each mistake produces. No network.
import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import {
  completeDeviceSignIn,
  finishSignIn,
  pollDeviceSignIn,
  refreshCredentials,
  startDeviceSignIn,
  startSignIn,
} from "../chatgpt-sign-in.js";

const clientId = "app_EMoamEEZ73f0CkXaXp7hrann";
const accountId = "acct-fixture";
function jwt(label) {
  const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "none" })}.${part({ exp: Math.floor(Date.now() / 1000) + 864000, "https://api.openai.com/auth": { chatgpt_account_id: accountId }, label })}.sig`;
}

/** A fake OpenAI auth server. `tokenStatus` answers code exchanges; `pollAnswers` answers device polls in order. */
function openai({ tokenStatus = 200, pollAnswers = [] } = {}) {
  const log = [];
  const fetch = async (url, init = {}) => {
    const body = typeof init.body === "string" ? init.body : init.body === undefined ? undefined : String(init.body);
    log.push({ url: String(url), method: init.method ?? "GET", headers: new Headers(init.headers), body });
    if (url === "https://auth.openai.com/oauth/token") {
      if (tokenStatus !== 200) return Response.json({ error: { code: "token_expired" } }, { status: tokenStatus });
      const grant = new Headers(init.headers).get("content-type")?.includes("json") ? JSON.parse(body).grant_type : new URLSearchParams(body).get("grant_type");
      return Response.json({ access_token: jwt(grant), refresh_token: grant === "refresh_token" ? "rt-rotated" : "rt-1", id_token: "id", expires_in: 864000 });
    }
    if (url === "https://auth.openai.com/api/accounts/deviceauth/usercode") {
      return Response.json({ device_auth_id: "device-1", user_code: "ABCD-1234", interval: "1" });
    }
    if (url === "https://auth.openai.com/api/accounts/deviceauth/token") {
      const answer = pollAnswers.shift() ?? 403;
      if (answer === 200) return Response.json({ authorization_code: "device-code", code_verifier: "device-verifier", code_challenge: "challenge" });
      return new Response("pending", { status: answer });
    }
    return new Response("unexpected", { status: 599 });
  };
  return { fetch, log };
}

const rejectsWith = (promise, code) => assert.rejects(promise, (error) => {
  assert.equal(error.code, code);
  return true;
});

// startSignIn: the CLI's own authorize request, with an S256 challenge of the secret verifier.
const signIn = await startSignIn();
{
  const url = new URL(signIn.url);
  assert.equal(`${url.origin}${url.pathname}`, "https://auth.openai.com/oauth/authorize");
  const params = Object.fromEntries(url.searchParams);
  assert.equal(params.client_id, clientId);
  assert.equal(params.redirect_uri, "http://localhost:1455/auth/callback");
  assert.equal(params.response_type, "code");
  assert.equal(params.code_challenge_method, "S256");
  assert.equal(params.code_challenge, createHash("sha256").update(signIn.verifier).digest("base64url"));
  assert.equal(params.state, signIn.state);
  assert.equal(params.originator, "fx");
  assert.equal(params.scope, "openid profile email offline_access api.connectors.read api.connectors.invoke");
  assert.equal(url.href.includes(signIn.verifier), false, "the verifier never leaves the server");
  const other = await startSignIn();
  assert.notEqual(other.state, signIn.state);
  assert.notEqual(other.verifier, signIn.verifier);
}

// finishSignIn: every paste people make, then the exchange.
const callback = `http://localhost:1455/auth/callback?code=the-code&scope=openid&state=${signIn.state}`;
for (const pasted of [callback, `\`${callback}\``, ` "${callback}" `, `<${callback}>`, callback.slice(callback.indexOf("?"))]) {
  const server = openai();
  const credentials = await finishSignIn(signIn, pasted, { fetch: server.fetch });
  assert.equal(credentials.accountId, accountId);
  assert.equal(credentials.refreshToken, "rt-1");
  assert.ok(credentials.expiresAt > Date.now());
  assert.equal(server.log.length, 1);
  assert.equal(server.log[0].headers.get("content-type"), "application/x-www-form-urlencoded");
  assert.deepEqual(Object.fromEntries(new URLSearchParams(server.log[0].body)), {
    grant_type: "authorization_code",
    client_id: clientId,
    code: "the-code",
    code_verifier: signIn.verifier,
    redirect_uri: "http://localhost:1455/auth/callback",
  });
}

// finishSignIn mistakes, none of which reach OpenAI.
{
  const server = openai();
  await rejectsWith(finishSignIn(signIn, "chrome-error://chromewebdata/", { fetch: server.fetch }), "LIBFX_CHATGPT_SIGN_IN_INVALID_ADDRESS");
  await rejectsWith(finishSignIn(signIn, "localhost", { fetch: server.fetch }), "LIBFX_CHATGPT_SIGN_IN_INVALID_ADDRESS");
  await rejectsWith(finishSignIn(signIn, callback.replace(signIn.state, "another-state"), { fetch: server.fetch }), "LIBFX_CHATGPT_SIGN_IN_STATE_MISMATCH");
  await rejectsWith(
    finishSignIn(signIn, `http://localhost:1455/auth/callback?error=access_denied&error_description=User+cancelled&state=${signIn.state}`, { fetch: server.fetch }),
    "LIBFX_CHATGPT_SIGN_IN_DENIED",
  );
  assert.equal(server.log.length, 0);
  await assert.rejects(finishSignIn({ url: signIn.url }, callback), TypeError);
}

// An expired or reused code, and an OpenAI failure.
await rejectsWith(finishSignIn(signIn, callback, { fetch: openai({ tokenStatus: 401 }).fetch }), "LIBFX_CHATGPT_SIGN_IN_EXPIRED");
await rejectsWith(finishSignIn(signIn, callback, { fetch: openai({ tokenStatus: 400 }).fetch }), "LIBFX_CHATGPT_SIGN_IN_EXPIRED");
await rejectsWith(finishSignIn(signIn, callback, { fetch: openai({ tokenStatus: 503 }).fetch }), "LIBFX_CHATGPT_SIGN_IN_FAILED");

// Device code: pending, then entered.
{
  const server = openai({ pollAnswers: [403, 404, 200] });
  const device = await startDeviceSignIn({ fetch: server.fetch });
  assert.equal(device.verificationUrl, "https://auth.openai.com/codex/device");
  assert.equal(device.userCode, "ABCD-1234");
  assert.equal(device.intervalMs, 1000);
  assert.deepEqual(JSON.parse(server.log[0].body), { client_id: clientId });
  const plain = JSON.parse(JSON.stringify(device));
  assert.equal(await pollDeviceSignIn(plain, { fetch: server.fetch }), null, "a serialized device sign-in can be polled later");
  assert.equal(await pollDeviceSignIn(plain, { fetch: server.fetch }), null);
  const credentials = await pollDeviceSignIn(plain, { fetch: server.fetch });
  assert.equal(credentials.accountId, accountId);
  const exchange = server.log.at(-1);
  assert.deepEqual(Object.fromEntries(new URLSearchParams(exchange.body)), {
    grant_type: "authorization_code",
    client_id: clientId,
    code: "device-code",
    code_verifier: "device-verifier",
    redirect_uri: "https://auth.openai.com/deviceauth/callback",
  });
}

// completeDeviceSignIn waits at OpenAI's interval and stops on abort.
{
  const server = openai({ pollAnswers: [403, 200] });
  const device = { ...(await startDeviceSignIn({ fetch: server.fetch })), intervalMs: 10 };
  assert.equal((await completeDeviceSignIn(device, { fetch: server.fetch })).accountId, accountId);
  const pending = openai({ pollAnswers: [403, 403, 403] });
  await assert.rejects(
    completeDeviceSignIn({ ...device, intervalMs: 1000 }, { fetch: pending.fetch, signal: AbortSignal.timeout(50) }),
    (error) => error.name === "TimeoutError" || error.name === "AbortError",
  );
}

// An expired device code explains how to turn device code sign-in on.
await assert.rejects(
  pollDeviceSignIn({ verificationUrl: "", userCode: "X", deviceAuthId: "d", intervalMs: 1000, expiresAt: Date.now() - 1 }, { fetch: openai().fetch }),
  (error) => error.code === "LIBFX_CHATGPT_DEVICE_CODE_EXPIRED" && /security settings/.test(error.message),
);

// refreshCredentials rotates the refresh token.
{
  const server = openai();
  const refreshed = await refreshCredentials({ accessToken: jwt("old"), refreshToken: "rt-1" }, { fetch: server.fetch });
  assert.equal(refreshed.refreshToken, "rt-rotated");
  assert.equal(refreshed.accountId, accountId);
  assert.deepEqual(JSON.parse(server.log[0].body), { client_id: clientId, grant_type: "refresh_token", refresh_token: "rt-1" });
  await rejectsWith(refreshCredentials({ accessToken: jwt("old"), refreshToken: "rt-1" }, { fetch: openai({ tokenStatus: 401 }).fetch }), "LIBFX_CHATGPT_REFRESH_FAILED");
}

console.log("ChatGPT sign-in passed");
