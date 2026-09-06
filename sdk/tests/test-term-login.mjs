#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxTerminal, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-term-login.mjs");
  process.exit(2);
}

const wasm = await readFile(wasmPath);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const issuer = "https://vercel.com";
const verificationUrl = "https://vercel.com/oauth/device";
const verificationUrlComplete = `${verificationUrl}?user_code=TEST-CODE`;
const accessToken = "term-login-access-token-sentinel";
const refreshToken = "term-login-refresh-token-sentinel";
const placeholder = "term-login-placeholder";
const teamId = "team_sdk_e2e";
const gatewayRequests = [];
const openedUrls = [];
let tokenPolls = 0;

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json" },
});

function sseResponse(label) {
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: {"type":"text-delta","id":"answer","delta":"${label}"}\n\n`));
      controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
}

const stubFetch = async (input, init = {}) => {
  const url = new URL(String(input));
  const method = init.method || "GET";
  const headers = new Headers(init.headers);

  if (url.href === `${issuer}/.well-known/openid-configuration`) {
    return json({
      issuer,
      device_authorization_endpoint: "https://api.vercel.com/login/oauth/device-authorization",
      token_endpoint: "https://api.vercel.com/login/oauth/token",
      revocation_endpoint: "https://api.vercel.com/login/oauth/revoke",
    });
  }
  if (url.href === "https://api.vercel.com/login/oauth/device-authorization") {
    if (method !== "POST" || headers.get("content-type") !== "application/x-www-form-urlencoded") {
      throw new Error("device authorization request contract mismatch");
    }
    return json({
      device_code: "stub-device-code",
      user_code: "TEST-CODE",
      verification_uri: verificationUrl,
      verification_uri_complete: verificationUrlComplete,
      expires_in: 60,
      interval: 1,
    });
  }
  if (url.href === "https://api.vercel.com/login/oauth/token") {
    tokenPolls += 1;
    if (tokenPolls <= 2) return json({ error: "authorization_pending" }, 400);
    return json({
      access_token: accessToken,
      refresh_token: refreshToken,
      expires_in: 3600,
      scope: "openid offline_access",
      token_type: "Bearer",
    });
  }
  if (url.href === "https://api.vercel.com/v2/teams") {
    if (headers.get("authorization") !== `Bearer ${accessToken}`) {
      throw new Error("teams request did not use the granted credential");
    }
    return json({ teams: [{ id: teamId, slug: "example-team", name: "Example Team" }] });
  }
  if (url.href === "https://api.vercel.com/login/oauth/revoke") return json({});
  if (`${url.origin}${url.pathname}` === "https://ai-gateway.vercel.sh/coding-agent/v1/models") {
    const requestTeam = url.searchParams.get("teamId") ?? headers.get("x-vercel-ai-gateway-team");
    if (headers.get("authorization") === `Bearer ${accessToken}` && requestTeam !== teamId) {
      throw new Error("authenticated model catalog omitted the selected team");
    }
    return json({
      object: "list",
      data: [{ id: "stub/login-model", type: "language", released: 1, tags: ["tool-use"] }],
    });
  }
  if (url.href === "https://ai-gateway.vercel.sh/v3/ai/language-model") {
    gatewayRequests.push({ authorization: headers.get("authorization") });
    return sseResponse(`LOGIN_GATEWAY_OK_${gatewayRequests.length}`);
  }
  throw new Error(`unexpected stub request: ${method} ${url.origin}${url.pathname}`);
};

let storedRecord = null;
let nextRevision = 1;
const storeFacts = { loads: 0, commits: [], removes: [] };
const oauthSessionStore = {
  load() {
    storeFacts.loads += 1;
    return storedRecord ? { bytes: storedRecord.bytes.slice(), revision: storedRecord.revision } : null;
  },
  commit(bytes, expectedRevision) {
    const currentRevision = storedRecord?.revision;
    if (currentRevision !== expectedRevision) {
      const error = new Error("OAuth session revision conflict");
      error.code = "FX_OAUTH_SESSION_REVISION_CONFLICT";
      throw error;
    }
    if (!(bytes instanceof Uint8Array)) throw new TypeError("OAuth session commit must receive opaque bytes");
    const revision = String(nextRevision++);
    storedRecord = { bytes: bytes.slice(), revision };
    storeFacts.commits.push({ expectedRevision, revision, opaque: true });
    return { revision };
  },
  remove(expectedRevision) {
    storeFacts.removes.push({ expectedRevision });
    if (!storedRecord) return "missing";
    if (storedRecord.revision !== expectedRevision) {
      const error = new Error("OAuth session revision conflict");
      error.code = "FX_OAUTH_SESSION_REVISION_CONFLICT";
      throw error;
    }
    storedRecord = null;
    return true;
  },
};

function createTerminalCapture() {
  let transcript = "";
  let trace = "";
  const events = [];
  return {
    terminal: {
      cols: 90,
      rows: 28,
      write(value) {
        const chunk = value instanceof Uint8Array ? value : encoder.encode(value);
        transcript += decoder.decode(chunk, { stream: true });
      },
      async drain() {},
      onData() { return () => {}; },
      onResize() { return () => {}; },
    },
    stderr(value) {
      const chunk = value instanceof Uint8Array ? value : encoder.encode(value);
      trace += decoder.decode(chunk, { stream: true });
    },
    event(event) { events.push(event); },
    transcript() { return transcript; },
    trace() { return trace; },
    events,
  };
}

async function waitFor(predicate, label, diagnostics = () => "") {
  const deadline = performance.now() + 15000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}: ${diagnostics()}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function start(env = {}) {
  const capture = createTerminalCapture();
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: capture.terminal,
    env: { FX_THEME: "dark", FX_TRACE_STDERR: "1", FX_TRACE_SCOPES: "auth", ...env },
    fetch: stubFetch,
    openUrl(url) { openedUrls.push(url); return true; },
    oauthSessionStore,
    onEvent: capture.event,
    stderr: capture.stderr,
  });
  await waitFor(
    () => capture.transcript().includes("Run /help for commands"),
    "fx-term startup",
    () => JSON.stringify(capture.transcript().slice(-1000)),
  );
  return { capture, runtime };
}

async function exit(runtime, label) {
  runtime.write("/exit\r");
  const code = await Promise.race([
    runtime.exited,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${label} exit`)), 5000)),
  ]);
  if (code !== 0) throw new Error(`${label} exited with code ${code}`);
}

function assertNoSecretLeaks(capture, label) {
  const exposed = `${capture.transcript()}\n${capture.trace()}\n${JSON.stringify(capture.events)}`;
  for (const secret of [accessToken, refreshToken]) {
    if (exposed.includes(secret)) throw new Error(`${label} exposed OAuth secret material`);
  }
}

const first = await start({ AI_GATEWAY_API_KEY: placeholder });
first.runtime.write("/login\r");
await waitFor(
  () => openedUrls.length === 1 && first.capture.transcript().includes("TEST-CODE"),
  "verification URL and code presentation",
  () => JSON.stringify(first.capture.transcript().slice(-1500)),
);
if (openedUrls[0] !== verificationUrlComplete) throw new Error("openUrl did not receive the complete verification URL");
if (!first.capture.transcript().includes(verificationUrl)) throw new Error("terminal did not show the verification URL");
await waitFor(
  () => first.capture.transcript().includes("Signed in to Vercel."),
  "cooperative OAuth completion",
  () => `polls=${tokenPolls}, output=${JSON.stringify(first.capture.transcript().slice(-1500))}`,
);
await waitFor(
  () => first.capture.transcript().includes("Vercel team · Search:"),
  "team selection",
  () => JSON.stringify(first.capture.transcript().slice(-1500)),
);
first.runtime.write("\r");
await waitFor(
  () => first.capture.transcript().includes("Changed Vercel team to Example Team") ||
    first.capture.transcript().includes("The Vercel team changed and a valid model was selected for this run"),
  "validated team activation",
  () => JSON.stringify(first.capture.transcript().slice(-1500)),
);
if (tokenPolls !== 3) throw new Error(`expected three token polls, received ${tokenPolls}`);
if (storeFacts.commits.length !== 2 || storeFacts.commits[0].expectedRevision !== undefined) {
  throw new Error("initial OAuth commit did not honor the empty revision contract");
}
if (storeFacts.commits[1].expectedRevision !== storeFacts.commits[0].revision) {
  throw new Error("team selection did not update the current OAuth revision");
}
if (!storedRecord || !storeFacts.commits.every((commit) => commit.opaque)) {
  throw new Error("OAuth session was not committed as opaque records");
}

first.runtime.write("first authenticated prompt\r");
await waitFor(
  () => gatewayRequests.length === 1,
  "first authenticated gateway response",
  () => JSON.stringify(first.capture.transcript().slice(-1500)),
);
await new Promise((resolve) => setTimeout(resolve, 200));
if (gatewayRequests[0]?.authorization !== `Bearer ${accessToken}`) {
  throw new Error("gateway did not receive the logged-in bearer credential");
}
if (gatewayRequests[0].authorization === `Bearer ${placeholder}`) {
  throw new Error("gateway received the placeholder after login");
}
assertNoSecretLeaks(first.capture, "first terminal");
await exit(first.runtime, "first terminal");

const pollsBeforeRestore = tokenPolls;
const second = await start();
if (tokenPolls !== pollsBeforeRestore) throw new Error("restored boot unexpectedly restarted OAuth login");
if (openedUrls.length !== 1) throw new Error("restored boot unexpectedly raised a verification URL");
second.runtime.write("restored authenticated prompt\r");
await waitFor(
  () => gatewayRequests.length === 2,
  "restored authenticated gateway response",
  () => JSON.stringify(second.capture.transcript().slice(-1500)),
);
await new Promise((resolve) => setTimeout(resolve, 200));
if (gatewayRequests[1]?.authorization !== `Bearer ${accessToken}`) {
  throw new Error("restored terminal did not use the stored logged-in credential");
}

second.runtime.write("/logout\r");
await waitFor(
  () => second.capture.transcript().includes("Signed out of fx."),
  "OAuth logout",
  () => JSON.stringify(second.capture.transcript().slice(-1500)),
);
if (storedRecord !== null || storeFacts.removes.length !== 1) throw new Error("logout did not remove the OAuth record");
if (storeFacts.removes[0].expectedRevision !== storeFacts.commits[1].revision) {
  throw new Error("logout did not remove the expected OAuth revision");
}
assertNoSecretLeaks(second.capture, "restored terminal");
await exit(second.runtime, "second terminal");

console.log(`term login passed: open_url=true, transcript_url=true, transcript_code=true, signed_in=true, polls=${tokenPolls}, oauth_bearer=true, opaque_commit=true, restored=true, logout_removed=true, leaks=0`);
