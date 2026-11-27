// Runs the built fx binary along tests/tla/auth/SubscriptionRefresh.tla and has
// TLC check every run it observes (SubscriptionRefreshTrace.tla).
//
// Each subscription run is one `fx status --json` or `fx ask --json --no-save`
// on a fresh profile whose saved Grok or Codex login has a chosen expiry,
// against a local fake issuer and provider. The status runs cover the
// expiries at the edges of i64 and of the one-minute margin. The ask runs
// start from an expired login, and the fake issuer answers the refresh with
// every reply the model knows: a rotated refresh token or none, a usable,
// missing, or overflowing lifetime, the same account or another, and a save
// that works or fails because the auth file was made read-only. Two more ask
// runs start from the smallest i64.
//
// Each MCP run is one `fx mcp show fixture --json` on a fresh profile whose
// saved MCP login has a chosen expires_at_ms and skew_ms, both at the edges of
// i64 among them, against a local MCP server that takes the saved token and
// the one a refresh brings, and a token endpoint that answers one refresh.
// fx asks the saved expiry and skew before its first request: a login that is
// due is refreshed and saved first (due), and one that is not goes out as
// saved (sent).
//
// For each run the driver records the outcome (the expiry read as expired or
// live, the prompt answered, the login signed out, the account changed, the
// save failed, the MCP request due or sent, an integer overflow abort, or any
// other crash) and what is left of the saved login. TLC replays the runs
// through the model's own actions. --self-check also replays them through the
// model of fx before the PR (ClearAtTake and Saturating FALSE, SendAdd
// "plain") and the model of this PR's head before the MCP fix (SendAdd
// "plain"), which must each reject them.
//
// fx runs only through `env -i` with every variable written out: a temporary
// HOME and FX_HOME, FX_DISABLE_KEYCHAIN=1, FX_SOUND=0, the fake endpoints, and
// a fake gateway key and URL. The fake gateway counts every request it gets; a
// run that reaches it, or that asks the fakes for anything the scenario does
// not expect, fails the driver.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/auth/driver.ts
//   bun tests/tla/drivers/auth/driver.ts --self-check --jobs 8
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce or the fakes did not expect, 2 a toolchain or harness
// failure.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, targetModule } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Provider = "codex" | "grok";
type Lifetime = "ok" | "missing" | "overflow";
type ReplySpec = { rotated: boolean; lifetime: Lifetime; account: "same" | "changed"; save: "ok" | "fail" };
type ModelReply = ReplySpec | { rotated: false; lifetime: "none"; account: "none"; save: "none" };
type Outcome = "expired" | "live" | "due" | "sent" | "answered" | "signed_out" | "account_changed" | "save_failed" | "abort" | "crash" | "unknown";
type FileState = "saved" | "rotated" | "deleted" | "unknown";
type SubscriptionCase = { id: string; cmd: "status" | "ask"; provider: Provider; expiry: Expiry; reply: ModelReply };
type McpCase = { id: string; cmd: "send"; provider: "mcp"; expiry: Expiry; skew: Skew; reply: ModelReply };
type Case = SubscriptionCase | McpCase;
type Observation = Case & {
  outcome: Outcome;
  file: FileState;
  anomalies: string[];
  evidence: { exit: number | null; signal: string | null; stdout: string; stderr: string; requests: string[]; seconds: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const NO_REPLY: ModelReply = { rotated: false, lifetime: "none", account: "none", save: "none" };
// The one-minute margin of a subscription login (Skew in the model).
const SUBSCRIPTION_SKEW_MODEL = 6;
const ACCOUNT = "acct_tla_driver";
const OTHER_ACCOUNT = "acct_tla_other";
const ANSWER = "AUTH_DRIVER_ANSWER";
const tlaDir = join(TLA_ROOT, "auth");

// The saved expiries, as the auth file holds them, and their place on the
// model's range (Bound 128, Skew 6, Now 60). The map keeps their order and
// where each lies against i64's minimum plus the margin, zero, and now.
type Expiry = { name: string; json: () => string; model: number };
const HOUR = 3_600_000;
const EXPIRIES: Expiry[] = [
  { name: "i64-min", json: () => "-9223372036854775808", model: -128 },
  { name: "i64-min-plus-59999", json: () => "-9223372036854715809", model: -123 },
  { name: "i64-min-plus-60000", json: () => "-9223372036854715808", model: -122 },
  { name: "minus-one", json: () => "-1", model: -1 },
  { name: "zero", json: () => "0", model: 0 },
  { name: "one-minute", json: () => "60000", model: 6 },
  { name: "hour-ago", json: () => String(Date.now() - HOUR), model: 54 },
  { name: "hour-ahead", json: () => String(Date.now() + HOUR), model: 67 },
  { name: "i64-max", json: () => "9223372036854775807", model: 127 },
];
const byName = (name: string) => EXPIRIES.find((e) => e.name === name)!;

// The skew_ms an MCP login saves, as the credential holds it, and its place on
// the same range. fx adds it to the clock (about 1.8e12 ms), so the model's Now
// of 60 stands for that and each skew keeps its place against the sum's
// overflow: the values from 2^63 - 1 - now upward overflow, the rest do not.
type Skew = { name: string; json: string; model: number };
const SKEWS: Skew[] = [
  { name: "i64-min", json: "-9223372036854775808", model: -128 },
  { name: "minus-one", json: "-1", model: -1 },
  { name: "zero", json: "0", model: 0 },
  { name: "default", json: "30000", model: 3 },
  { name: "i64-max-minus-one", json: "9223372036854775806", model: 126 },
  { name: "i64-max", json: "9223372036854775807", model: 127 },
];
const MCP_EXPIRIES = ["i64-min", "zero", "hour-ago", "hour-ahead", "i64-max"].map(byName);

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} takes a positive whole number`);
  return value;
}
const options = { selfCheck: process.argv.includes("--self-check"), jobs: option("--jobs", 4) };

function cases(): Case[] {
  const out: Case[] = [];
  for (const expiry of MCP_EXPIRIES) {
    for (const skew of SKEWS) {
      out.push({ id: `send-mcp-${expiry.name}-skew-${skew.name}`, cmd: "send", provider: "mcp", expiry, skew, reply: NO_REPLY });
    }
  }
  for (const provider of ["codex", "grok"] as const) {
    for (const expiry of EXPIRIES) {
      out.push({ id: `status-${provider}-${expiry.name}`, cmd: "status", provider, expiry, reply: NO_REPLY });
    }
    const replies: ReplySpec[] = [];
    for (const rotated of [true, false]) {
      replies.push({ rotated, lifetime: "ok", account: "same", save: "ok" });
      replies.push({ rotated, lifetime: "ok", account: "same", save: "fail" });
      replies.push({ rotated, lifetime: "missing", account: "same", save: "ok" });
      replies.push({ rotated, lifetime: "overflow", account: "same", save: "ok" });
      replies.push({ rotated, lifetime: "ok", account: "changed", save: "ok" });
    }
    for (const reply of replies) {
      const id = `ask-${provider}-${reply.rotated ? "rotated" : "kept"}-${reply.lifetime}-${reply.account}-save-${reply.save}`;
      out.push({ id, cmd: "ask", provider, expiry: byName("hour-ago"), reply });
    }
    out.push({
      id: `ask-${provider}-i64-min-rotated-ok`, cmd: "ask", provider, expiry: byName("i64-min"),
      reply: { rotated: true, lifetime: "ok", account: "same", save: "ok" },
    });
  }
  return out;
}

function accessToken(provider: Provider, account: string, tag: string): string {
  if (provider === "grok") return `grok-${tag}`;
  // No `exp` claim, so a reply without expires_in leaves Codex no lifetime.
  const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: account } })).toString("base64url");
  return `header.${payload}.${tag}`;
}

function tokenReply(c: SubscriptionCase): string {
  const reply = c.reply as ReplySpec;
  const account = c.provider === "codex" && reply.account === "changed" ? OTHER_ACCOUNT : ACCOUNT;
  let body = `{"access_token":${JSON.stringify(accessToken(c.provider, account, "fresh"))}`;
  if (reply.rotated) body += `,"refresh_token":"${c.provider}-refresh-next"`;
  if (reply.lifetime === "ok") body += `,"expires_in":3600`;
  if (reply.lifetime === "overflow") body += `,"expires_in":9223372036854775807`;
  return body + "}";
}

/** The fake issuer and provider for one run, and a fake gateway that must stay unused. */
function startFakes(c: SubscriptionCase, authPath: string, helpers: any) {
  const requests: string[] = [];
  const unexpected: string[] = [];
  let modelRequests = 0;
  let tokenRequests = 0;
  const reply = c.reply as ReplySpec;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "POST" ? await request.text() : "";
      requests.push(`${request.method} ${path}`);
      if (path === "/models") {
        return Response.json(c.provider === "codex"
          ? { models: [{ slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 }] }
          : { data: [{ id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
      }
      if (path === "/modalities") {
        return Response.json({ models: [{ id: "grok-4.20", input_modalities: ["text"], output_modalities: ["text"] }] });
      }
      if (path === "/token") {
        tokenRequests += 1;
        if (c.cmd !== "ask") unexpected.push("token request from fx status");
        if (reply.save === "fail") chmodSync(authPath, 0o400);
        return new Response(tokenReply(c), { headers: { "content-type": "application/json" } });
      }
      if (path === "/userinfo" && c.provider === "grok") {
        return Response.json({ sub: reply.account === "changed" ? OTHER_ACCOUNT : ACCOUNT });
      }
      if (path === "/responses") {
        if (body.includes(helpers.TITLE_GENERATION_MARKER)) return helpers.fakeResponsesTitleDefault();
        modelRequests += 1;
        return new Response(
          `data: ${JSON.stringify({ type: "response.output_text.delta", delta: ANSWER })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      unexpected.push(`${request.method} ${path}`);
      return new Response("not found", { status: 404 });
    },
  });
  const gatewayRequests: string[] = [];
  const gateway = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      gatewayRequests.push(`${request.method} ${new URL(request.url).pathname}`);
      return new Response("the fake gateway is not part of this run", { status: 500 });
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  const gatewayBase = `http://127.0.0.1:${gateway.port}`;
  const env: Record<string, string> = c.provider === "codex"
    ? {
      FX_PROVIDER: "codex",
      FX_MODEL: "gpt-5.4-mini",
      FX_TEST_CHATGPT_TOKEN_URL: `${base}/token`,
      FX_TEST_OPENAI_CODEX_MODELS_URL: `${base}/models`,
      FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${base}/responses`,
      FX_TEST_CODEX_CLIENT_VERSION: "0.153.0",
    }
    : {
      FX_PROVIDER: "grok",
      FX_MODEL: "grok-4.20",
      FX_TEST_GROK_TOKEN_URL: `${base}/token`,
      FX_TEST_GROK_USERINFO_URL: `${base}/userinfo`,
      FX_TEST_XAI_GROK_MODELS_URL: `${base}/models`,
      FX_TEST_XAI_GROK_MODALITIES_URL: `${base}/modalities`,
      FX_TEST_XAI_GROK_RESPONSES_URL: `${base}/responses`,
      FX_TEST_GROK_CLIENT_VERSION: "1.0.6",
    };
  return {
    env: { ...env, FX_GATEWAY_BASE_URL: gatewayBase, FX_GATEWAY_CHAT_URL: `${gatewayBase}/v1/chat/completions` },
    requests,
    unexpected,
    gatewayRequests,
    counts: () => ({ token: tokenRequests, model: modelRequests }),
    stop() {
      server.stop(true);
      gateway.stop(true);
    },
  };
}

function seedLogin(home: string, c: SubscriptionCase): string {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const authPath = join(fxDir, c.provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json");
  const access = JSON.stringify(accessToken(c.provider, ACCOUNT, "stale"));
  writeFileSync(
    authPath,
    `{"version":1,"access_token":${access},"refresh_token":"${c.provider}-refresh","expires_at_ms":${c.expiry.json()},"account_id":"${ACCOUNT}"}\n`,
    { mode: 0o600 },
  );
  chmodSync(authPath, 0o600);
  return authPath;
}

function fileState(authPath: string, provider: Provider): FileState {
  if (!existsSync(authPath)) return "deleted";
  try {
    const saved = JSON.parse(readFileSync(authPath, "utf8"));
    if (saved.refresh_token === `${provider}-refresh`) return "saved";
    if (saved.refresh_token === `${provider}-refresh-next`) return "rotated";
  } catch {
    // An unreadable or partly written file is not a state the model has.
  }
  return "unknown";
}

function classify(c: SubscriptionCase, exit: number | null, signal: string | null, stdout: string, stderr: string): Outcome {
  const all = `${stdout}\n${stderr}`;
  if (all.includes("integer overflow")) return "abort";
  if (signal !== null || exit === null || exit > 1) return "crash";
  let json: any = null;
  try {
    json = JSON.parse(stdout);
  } catch {
    json = null;
  }
  if (c.cmd === "status") {
    if (exit !== 0 || !json) return "unknown";
    return json.auth_expired === true ? "expired" : "live";
  }
  if (exit === 0 && typeof json?.output === "string" && json.output.includes(ANSWER)) return "answered";
  if (exit === 1) {
    switch (json?.error) {
      // The failed refresh deleted the login, so fx asks to sign in again.
      case "MissingCredentials":
        return "signed_out";
      case "CredentialAuthorityChanged":
        return "account_changed";
      case "CredentialRefreshPersistenceUncertain":
        return "save_failed";
    }
  }
  return "unknown";
}

async function runSubscriptionCase(c: SubscriptionCase, helpers: any, scratch: string): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${c.id}-`));
  const home = join(root, "home");
  const tmp = join(root, "tmp");
  mkdirSync(home, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  const authPath = seedLogin(home, c);
  const fakes = startFakes(c, authPath, helpers);
  const vars: Record<string, string> = {
    HOME: home,
    PATH: "/usr/bin:/bin",
    TMPDIR: tmp,
    FX_HOME: join(home, ".fx"),
    FX_DISABLE_KEYCHAIN: "1",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-auth-driver-key",
    ...fakes.env,
  };
  const args = c.cmd === "status" ? ["status", "--json"] : ["ask", "--json", "--no-save", "refresh first"];
  const argv = ["/usr/bin/env", "-i", ...Object.entries(vars).map(([k, v]) => `${k}=${v}`), binary, ...args];
  const started = performance.now();
  try {
    const child = Bun.spawn(argv, { cwd: root, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    await child.exited;
    clearTimeout(timer);
    const signal = child.signalCode ?? null;
    const exit = signal === null ? child.exitCode : null;
    if (existsSync(authPath)) chmodSync(authPath, 0o600);
    const anomalies = [...fakes.unexpected];
    if (fakes.gatewayRequests.length > 0) anomalies.push(`the fake gateway got ${fakes.gatewayRequests.join(", ")}`);
    const counts = fakes.counts();
    if (c.cmd === "ask" && c.expiry.model <= 60 && counts.token !== 1 && signal === null) {
      anomalies.push(`${counts.token} token requests for an expired login`);
    }
    return {
      ...c,
      outcome: classify(c, exit, signal, stdout, stderr),
      file: fileState(authPath, c.provider),
      anomalies,
      evidence: {
        exit, signal, stdout: stdout.slice(-600), stderr: stderr.slice(-600), requests: fakes.requests,
        seconds: Math.round(performance.now() - started) / 1000,
      },
    };
  } finally {
    fakes.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const MCP_ACCESS_SAVED = "mcp-access-saved-driver";
const MCP_ACCESS_FRESH = "mcp-access-fresh-driver";
const MCP_REFRESH_SAVED = "mcp-refresh-saved-driver";
const MCP_REFRESH_NEXT = "mcp-refresh-next-driver";
const MCP_CLIENT_ID = "fx-mcp-auth-test";

/**
 * A local MCP server that takes the saved access token and the one a refresh
 * brings, and the token endpoint beside it, which answers a refresh with the
 * second. Anything else it is asked for is recorded as unexpected.
 */
async function startMcpFakes() {
  const fixtures = await targetModule("fixtures/mcp-modern-http.ts");
  const upstream = fixtures.startModernMcpHttpFixture("json");
  const mcpRequests: Array<{ method: string; authorization: string | null }> = [];
  const unexpected: string[] = [];
  let tokenRequests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "GET" ? "" : await request.text();
      if (path === "/mcp") {
        const authorization = request.headers.get("authorization");
        mcpRequests.push({ method: request.method, authorization });
        const token = authorization?.startsWith("Bearer ") ? authorization.slice(7) : "";
        if (token !== MCP_ACCESS_SAVED && token !== MCP_ACCESS_FRESH) return new Response("", { status: 401 });
        const headers = new Headers(request.headers);
        headers.set("connection", "close");
        // No pooled connection between the two fakes: a socket the fixture just closed must not be reused.
        return await fetch(upstream.url, { method: request.method, headers, keepalive: false, ...(body === "" ? {} : { body }) });
      }
      if (path === "/token") {
        tokenRequests += 1;
        const form = new URLSearchParams(body);
        if (form.get("grant_type") !== "refresh_token" || form.get("refresh_token") !== MCP_REFRESH_SAVED) {
          unexpected.push(`POST /token ${form.get("grant_type")}`);
        }
        return Response.json({
          access_token: MCP_ACCESS_FRESH, refresh_token: MCP_REFRESH_NEXT, token_type: "Bearer",
          scope: "tools.read offline_access", expires_in: 3600,
        });
      }
      unexpected.push(`${request.method} ${path}`);
      return new Response("not found", { status: 404 });
    },
  });
  const gatewayRequests: string[] = [];
  const gateway = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      gatewayRequests.push(`${request.method} ${new URL(request.url).pathname}`);
      return new Response("the fake gateway is not part of this run", { status: 500 });
    },
  });
  return {
    base: `http://127.0.0.1:${server.port}`,
    gatewayBase: `http://127.0.0.1:${gateway.port}`,
    mcpRequests,
    unexpected,
    gatewayRequests,
    tokens: () => tokenRequests,
    stop() {
      server.stop(true);
      gateway.stop(true);
      upstream.stop();
    },
  };
}

/** The login store as fx saved it: the refresh token it holds tells whether a refresh ran. */
function mcpFileState(storePath: string): FileState {
  if (!existsSync(storePath)) return "deleted";
  try {
    const store = JSON.parse(readFileSync(storePath, "utf8"));
    const entry = store.servers?.find((server: any) => server.name === "fixture");
    if (!entry) return "deleted";
    const saved = JSON.parse(entry.credential);
    if (saved.refresh === MCP_REFRESH_SAVED) return "saved";
    if (saved.refresh === MCP_REFRESH_NEXT) return "rotated";
  } catch {
    // An unreadable or partly written store is not a state the model has.
  }
  return "unknown";
}

function classifyMcp(exit: number | null, signal: string | null, stdout: string, stderr: string, tokens: number, first: string | null): Outcome {
  if (`${stdout}\n${stderr}`.includes("integer overflow")) return "abort";
  if (signal !== null || exit === null || exit > 1) return "crash";
  let json: any = null;
  try {
    json = JSON.parse(stdout);
  } catch {
    json = null;
  }
  if (exit !== 0 || json?.status !== "ready") return "unknown";
  if (tokens === 1 && first === `Bearer ${MCP_ACCESS_FRESH}`) return "due";
  if (tokens === 0 && first === `Bearer ${MCP_ACCESS_SAVED}`) return "sent";
  return "unknown";
}

async function runMcpCase(c: McpCase, scratch: string): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${c.id}-`));
  const home = join(root, "home");
  const tmp = join(root, "tmp");
  mkdirSync(home, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  const fxDir = join(home, ".fx");
  mkdirSync(join(fxDir, "mcp-credentials"), { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const fakes = await startMcpFakes();
  try {
    const url = `${fakes.base}/mcp`;
    writeFileSync(join(fxDir, "settings.json"), "{}");
    writeFileSync(join(fxDir, "mcp.json"), JSON.stringify({
      mcp: { fixture: { type: "http", url, oauth: { client_id: MCP_CLIENT_ID, scopes: ["tools.read"] }, startup_timeout_ms: 5_000 } },
    }));
    // The credential's numbers are written as text: JavaScript cannot hold 2^63 - 1.
    const credential = `{"access":${str(MCP_ACCESS_SAVED)},"refresh":${str(MCP_REFRESH_SAVED)},"expires_at_ms":${c.expiry.json()},` +
      `"skew_ms":${c.skew.json},"token_endpoint":${str(`${fakes.base}/token`)},"revocation_endpoint":${str(`${fakes.base}/revoke`)},` +
      `"resource":${str(url)},"client_id":${str(MCP_CLIENT_ID)},"client_secret":null,"method":"none"}`;
    const storePath = join(fxDir, "mcp-credentials", "credentials-v3.json");
    writeFileSync(storePath, JSON.stringify({ version: 1, servers: [{ name: "fixture", url, credential }] }), { mode: 0o600 });
    const vars: Record<string, string> = {
      HOME: home,
      PATH: "/usr/bin:/bin",
      TMPDIR: tmp,
      FX_HOME: fxDir,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_DOTENV: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      NO_COLOR: "1",
      AI_GATEWAY_API_KEY: "fake-auth-driver-key",
      FX_GATEWAY_BASE_URL: fakes.gatewayBase,
      FX_GATEWAY_CHAT_URL: `${fakes.gatewayBase}/v1/chat/completions`,
    };
    const argv = ["/usr/bin/env", "-i", ...Object.entries(vars).map(([k, v]) => `${k}=${v}`), binary, "mcp", "show", "fixture", "--json"];
    const started = performance.now();
    const child = Bun.spawn(argv, { cwd: root, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    await child.exited;
    clearTimeout(timer);
    const signal = child.signalCode ?? null;
    const exit = signal === null ? child.exitCode : null;
    const anomalies = [...fakes.unexpected];
    if (fakes.gatewayRequests.length > 0) anomalies.push(`the fake gateway got ${fakes.gatewayRequests.join(", ")}`);
    const outcome = classifyMcp(exit, signal, stdout, stderr, fakes.tokens(), fakes.mcpRequests[0]?.authorization ?? null);
    if (outcome !== "abort" && outcome !== "crash" && fakes.mcpRequests.length === 0) anomalies.push("no request reached the fake MCP server");
    return {
      ...c,
      outcome,
      file: mcpFileState(storePath),
      anomalies,
      evidence: {
        exit, signal, stdout: stdout.slice(-600), stderr: stderr.slice(-600),
        requests: fakes.mcpRequests.map((r) => `${r.method} /mcp ${r.authorization ?? "no token"}`).concat(Array(fakes.tokens()).fill("POST /token")),
        seconds: Math.round(performance.now() - started) / 1000,
      },
    };
  } finally {
    fakes.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

async function runCase(c: Case, helpers: any, scratch: string): Promise<Observation> {
  return c.provider === "mcp" ? await runMcpCase(c, scratch) : await runSubscriptionCase(c, helpers, scratch);
}

const str = (value: string) => JSON.stringify(value);

function replyValue(r: ModelReply): string {
  return `[rotated |-> ${r.rotated ? "TRUE" : "FALSE"}, lifetime |-> ${str(r.lifetime)}, account |-> ${str(r.account)}, save |-> ${str(r.save)}]`;
}

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[cmd |-> ${str(o.cmd)}, provider |-> ${str(o.provider)}, stored |-> ${o.expiry.model}, ` +
    `margin |-> ${o.provider === "mcp" ? o.skew.model : SUBSCRIPTION_SKEW_MODEL}, ` +
    `reply |-> ${replyValue(o.reply)}, outcome |-> ${str(o.outcome)}, file |-> ${str(o.file)}]`;
  return [
    "--------------------- MODULE SubscriptionRefreshObserved ---------------------",
    "(* Generated by tests/tla/drivers/auth/driver.ts. Do not edit. *)",
    "EXTENDS Integers, Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

// The model the runs are replayed through: the design, or fx as it was.
type Model = "design" | "before-pr" | "before-mcp-fix";
const MODELS: Record<Model, { fixed: "TRUE" | "FALSE"; sendAdd: string }> = {
  design: { fixed: "TRUE", sendAdd: "saturate" },
  "before-pr": { fixed: "FALSE", sendAdd: "plain" },
  // This PR's head before the MCP fix: the subscription logins were fixed.
  "before-mcp-fix": { fixed: "TRUE", sendAdd: "plain" },
};

async function runTrace(observations: Observation[], model: Model, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${model}-`));
  writeFileSync(join(dir, "SubscriptionRefreshObserved.tla"), observedModule(observations));
  const { fixed, sendAdd } = MODELS[model];
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    '    Providers = {"codex", "grok", "mcp"}',
    "    Expiries <- AllExpiries",
    "    Margins <- AllMargins",
    "    Bound = 128",
    "    Skew = 6",
    "    Now = 60",
    `    ClearAtTake = ${fixed}`,
    `    Saturating = ${fixed}`,
    "    SignOutBadReply = TRUE",
    "    SaveRotated = TRUE",
    `    SendAdd = "${sendAdd}"`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "SubscriptionRefreshTrace.tla", "trace.cfg",
    ["SubscriptionRefresh.tla", "SubscriptionRefreshTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first run the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], model: Model, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), model, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.log(`TOOL_ERROR: missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const helpers = await targetHelpers();
  const out = outDir("auth");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const all = cases();
  const observations: Observation[] = new Array(all.length);
  const started = performance.now();
  let next = 0;
  await Promise.all(Array.from({ length: options.jobs }, async () => {
    while (next < all.length) {
      const index = next++;
      observations[index] = await runCase(all[index]!, helpers, scratch);
    }
  }));
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) counts[o.outcome] = (counts[o.outcome] ?? 0) + 1;
  console.log(`${observations.length} runs of ${binary} in ${((performance.now() - started) / 1000).toFixed(1)}s, outcomes ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const odd = observations.find((o) => o.anomalies.length > 0);
  if (odd) {
    console.log(`REJECTED: run ${odd.id} did what the fakes did not expect: ${odd.anomalies.join("; ")}`);
    return 1;
  }
  const unread = observations.find((o) => o.outcome === "unknown" || o.file === "unknown");
  if (unread) {
    console.log(`REJECTED: run ${unread.id} ended in a way the driver cannot read: ${JSON.stringify(unread)}`);
    return 1;
  }

  const design = await runTrace(observations, "design", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "design", out);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    for (const [model, name] of [["before-pr", "fx before the PR"], ["before-mcp-fix", "the PR's head before the MCP fix"]] as const) {
      const old = await runTrace(observations, model, out);
      console.log(`self-check, the model of ${name}: ${old.verdict} (must be REJECTED)`);
      if (old.verdict !== "REJECTED") return old.verdict === "TOOL_ERROR" ? 2 : 1;
    }
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
