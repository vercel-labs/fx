// fx honors HTTPS_PROXY, HTTP_PROXY, ALL_PROXY, and NO_PROXY: every
// connection it opens by host name goes through the proxy as CONNECT, then
// TLS to the real host inside the tunnel, and a proxy that refuses fails the
// request with a message that names the proxy and the reason.
//
// Everything stays on this machine. proxy-target.test resolves nowhere, so
// fx can reach it only through the local proxy, which pipes it to a local
// TLS server whose certificate fx does not trust: the ClientHello's server
// name and fx refusing that certificate show TLS ran to the real host. The
// providers and subscriptions fx can point at a test endpoint accept only
// loopback URLs, and loopback always goes direct, so FX_TEST_NET_PROXY_LOOPBACK
// sends loopback through the proxy too; each fake server then checks that
// every request it got came from a socket the proxy opened.
//
// Every fx run gets an environment built from nothing but what the test
// writes out, so no proxy or credential from the developer's shell leaks in.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { completion } from "./fixtures/chat-completions";
import { startModernMcpHttpFixture } from "./fixtures/mcp-modern-http";
import { startConnectProxy } from "./fixtures/net-proxy/proxy";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 60_000;
const TARGET = "proxy-target.test";
const CREDENTIALS = "user:p%40ss";
/** Basic base64("user:p@ss"): the password goes decoded, as curl sends it. */
const CREDENTIALS_HEADER = "Basic dXNlcjpwQHNz";

type Run = { code: number | null; stdout: string; stderr: string; ms: number };

let workRoot: string;
let tlsTarget: ReturnType<typeof Bun.serve>;
let tlsRequests = 0;

beforeAll(() => {
  workRoot = realpathSync(mkdtempSync(join(tmpdir(), "fx-net-proxy-e2e-")));
  const cert = join(workRoot, "target.pem");
  const key = join(workRoot, "target.key");
  // A certificate no trust store holds, made fresh so no key is committed.
  const made = Bun.spawnSync(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
    "-nodes", "-subj", `/CN=${TARGET}`, "-addext", `subjectAltName=DNS:${TARGET}`, "-days", "2",
    "-keyout", key, "-out", cert], { stdout: "pipe", stderr: "pipe" });
  if (made.exitCode !== 0) throw new Error(`openssl failed: ${made.stderr.toString()}`);
  tlsTarget = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    tls: { cert: readFileSync(cert, "utf8"), key: readFileSync(key, "utf8") },
    fetch: () => {
      tlsRequests += 1;
      return new Response("tunnel-ok");
    },
  });
});

afterAll(() => {
  tlsTarget?.stop(true);
  rmSync(workRoot, { recursive: true, force: true });
});

function newHome(name: string): string {
  const home = mkdtempSync(join(workRoot, `${name}-`));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  return home;
}

const modelMetadata = { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true };

/** A profile with one custom chat-completions provider at `baseUrl`. */
function writeProvider(home: string, baseUrl: string) {
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "custom",
    auto_upgrade: false,
    permission_mode: "ask",
    providers: {
      custom: {
        protocol: "openai-chat-completions",
        base_url: baseUrl,
        auth: { type: "none" },
        model_metadata: { "custom-model": modelMetadata },
      },
    },
    models: { custom: "custom-model" },
  }), { mode: 0o600 });
}

/** A local server that records the remote port of every request. */
function serveLocal(handle: (request: Request, path: string) => Response | Promise<Response>) {
  const remotePorts: number[] = [];
  const paths: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request, srv) {
      remotePorts.push(srv.requestIP(request)?.port ?? -1);
      const path = new URL(request.url).pathname;
      paths.push(path);
      return handle(request, path);
    },
  });
  return { port: server.port!, base: `http://127.0.0.1:${server.port}`, remotePorts, paths, stop: () => server.stop(true) };
}

/** A fake AI Gateway; the requests every run needs it for stay local. */
function serveGateway(text = "GATEWAY_PROXY_OK") {
  const gateway = serveLocal(async (request, path) => {
    if (path === "/coding-agent/v1/models") {
      return Response.json({ data: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    }
    if (request.method !== "POST") return new Response("not found", { status: 404 });
    await request.text();
    return new Response(
      [{ type: "text-delta", id: "t", delta: text },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 2 } } }]
        .map(event => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n",
      { headers: { "content-type": "text/event-stream" } },
    );
  });
  return { ...gateway, env: { FX_GATEWAY_BASE_URL: gateway.base, FX_GATEWAY_CHAT_URL: `${gateway.base}/v4/ai/language-model` } };
}

/**
 * Runs the built fx with exactly `env` and nothing inherited. `until` is
 * polled while it runs; once it holds, fx is stopped after `graceMs`.
 */
async function runFx(argv: string[], env: Record<string, string>, options: { timeoutMs?: number; until?: () => boolean; graceMs?: number } = {}): Promise<Run> {
  const started = performance.now();
  const child = Bun.spawn([FX_BIN, ...argv], { cwd: env.HOME, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), options.timeoutMs ?? 30_000);
  let poll: ReturnType<typeof setInterval> | undefined;
  if (options.until) {
    poll = setInterval(() => {
      if (!options.until!()) return;
      clearInterval(poll);
      setTimeout(() => child.kill(), options.graceMs ?? 500);
    }, 50);
  }
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  clearTimeout(timer);
  if (poll) clearInterval(poll);
  return { code: child.signalCode ? null : code, stdout, stderr, ms: performance.now() - started };
}

function baseEnv(home: string, extra: Record<string, string>): Record<string, string> {
  return {
    HOME: home,
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    TMPDIR: process.env.TMPDIR ?? "/tmp",
    FX_HOME: join(home, ".fx"),
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_TEST_SKIP_ONBOARDING: "1",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-net-proxy-key",
    ...extra,
  };
}

const ask = ["ask", "--no-save", "hi"];
const askCustom = ["ask", "--provider", "custom", "--model", "custom-model", "--no-save", "hi"];

function show(run: Run): string {
  return `exit ${run.code} after ${Math.round(run.ms)} ms\nstdout: ${run.stdout.slice(0, 600)}\nstderr: ${run.stderr.slice(0, 1200)}`;
}

describe("net proxy", () => {
  test("an https provider is reached only through the proxy, as CONNECT and then TLS to the host", async () => {
    tlsRequests = 0;
    const proxy = await startConnectProxy({ routes: { [`${TARGET}:443`]: tlsTarget.port! } });
    const gateway = serveGateway();
    const home = newHome("tls");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url(CREDENTIALS) }), {
        timeoutMs: 20_000,
        until: () => proxy.log.some(entry => entry.sni !== null),
      });
      expect(proxy.log.length, show(run)).toBeGreaterThan(0);
      for (const entry of proxy.log) {
        expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
        expect(entry.authorization).toBe(CREDENTIALS_HEADER);
        expect(entry.firstClientByte).toBe(0x16);
      }
      expect(proxy.log.some(entry => entry.sni === TARGET)).toBe(true);
      // fx checks the certificate against proxy-target.test and refuses it,
      // so no request reached the server, in plain text or otherwise.
      expect(tlsRequests).toBe(0);
    } finally {
      proxy.close();
      gateway.stop();
    }
  }, TIMEOUT);

  test("a model request completes through the proxy, which lowercase https_proxy names", async () => {
    const proxy = await startConnectProxy();
    const provider = serveLocal(() => completion("custom-model", "CUSTOM_PROXY_OK"));
    const gateway = serveGateway();
    const home = newHome("custom");
    try {
      writeProvider(home, `${provider.base}/v1`);
      const run = await runFx(askCustom, baseEnv(home, {
        ...gateway.env,
        // Lowercase wins, as in curl; the uppercase proxy accepts nothing.
        https_proxy: proxy.url(CREDENTIALS),
        HTTPS_PROXY: "http://127.0.0.1:1",
        FX_TEST_NET_PROXY_LOOPBACK: "1",
      }));
      expect(run.code, show(run)).toBe(0);
      expect(run.stdout).toContain("CUSTOM_PROXY_OK");
      const tunnel = proxy.log.find(entry => entry.requestLine === `CONNECT 127.0.0.1:${provider.port} HTTP/1.1`);
      expect(tunnel, JSON.stringify(proxy.log)).toBeDefined();
      expect(tunnel!.authorization).toBe(CREDENTIALS_HEADER);
      expect(provider.remotePorts.length).toBeGreaterThan(0);
      for (const port of provider.remotePorts) expect(proxy.upstreamPorts.has(port)).toBe(true);
    } finally {
      proxy.close();
      provider.stop();
      gateway.stop();
    }
  }, TIMEOUT);

  test("loopback goes direct while a proxy is set", async () => {
    const proxy = await startConnectProxy();
    const provider = serveLocal(() => completion("custom-model", "LOOPBACK_DIRECT_OK"));
    const gateway = serveGateway();
    const home = newHome("loopback");
    try {
      writeProvider(home, `${provider.base}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url(), HTTP_PROXY: proxy.url(), ALL_PROXY: proxy.url() }));
      expect(run.code, show(run)).toBe(0);
      expect(run.stdout).toContain("LOOPBACK_DIRECT_OK");
      expect(proxy.log).toEqual([]);
    } finally {
      proxy.close();
      provider.stop();
      gateway.stop();
    }
  }, TIMEOUT);

  test("NO_PROXY keeps a host off the proxy", async () => {
    const proxy = await startConnectProxy();
    const provider = serveLocal(() => completion("custom-model", "NO_PROXY_DIRECT_OK"));
    const gateway = serveGateway();
    const home = newHome("no-proxy");
    try {
      writeProvider(home, `${provider.base}/v1`);
      const run = await runFx(askCustom, baseEnv(home, {
        ...gateway.env,
        HTTPS_PROXY: proxy.url(),
        NO_PROXY: "example.invalid, 127.0.0.0/8",
        FX_TEST_NET_PROXY_LOOPBACK: "1",
      }));
      expect(run.code, show(run)).toBe(0);
      expect(run.stdout).toContain("NO_PROXY_DIRECT_OK");
      expect(proxy.log).toEqual([]);
      for (const port of provider.remotePorts) expect(proxy.upstreamPorts.has(port)).toBe(false);
    } finally {
      proxy.close();
      provider.stop();
      gateway.stop();
    }
  }, TIMEOUT);

  test("a proxy that answers 407 fails the request at once and names the proxy and the reason", async () => {
    const proxy = await startConnectProxy({ status: 407 });
    const gateway = serveGateway();
    const home = newHome("refused");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url(CREDENTIALS) }), { timeoutMs: 20_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.ms).toBeLessThan(15_000);
      expect(run.stderr).toContain(`proxy 127.0.0.1:${proxy.port} refused CONNECT to ${TARGET}:443: 407 Proxy Authentication Required`);
      expect(run.stderr).not.toContain("Offline");
      expect(run.stderr + run.stdout).not.toContain("p%40ss");
      expect(run.stderr + run.stdout).not.toContain("p@ss");
      expect(proxy.log.length).toBeGreaterThan(0);
      for (const entry of proxy.log) expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
    } finally {
      proxy.close();
      gateway.stop();
    }
  }, TIMEOUT);

  for (const variant of [
    { name: "bytes that are not HTTP", options: { garbage: true } },
    { name: "a 200 and then bytes before fx speaks", options: { early: true } },
  ]) {
    test(`a proxy that answers with ${variant.name} fails the request and says so`, async () => {
      const proxy = await startConnectProxy(variant.options);
      const gateway = serveGateway();
      const home = newHome("garbage");
      try {
        writeProvider(home, `https://${TARGET}/v1`);
        const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url() }), { timeoutMs: 20_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stderr).toContain(`proxy 127.0.0.1:${proxy.port} answered CONNECT to ${TARGET}:443 with bytes that are not HTTP`);
        for (const entry of proxy.log) expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
      } finally {
        proxy.close();
        gateway.stop();
      }
    }, TIMEOUT);
  }

  test("a proxy that answers 502 is retried and never bypassed", async () => {
    const proxy = await startConnectProxy({ status: 502 });
    const gateway = serveGateway();
    const home = newHome("bad-gateway");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url() }), {
        timeoutMs: 25_000,
        until: () => proxy.log.length >= 2,
      });
      expect(proxy.log.length, show(run)).toBeGreaterThanOrEqual(2);
      for (const entry of proxy.log) expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
    } finally {
      proxy.close();
      gateway.stop();
    }
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())("the interactive app names the proxy when it refuses CONNECT", async () => {
    const proxy = await startConnectProxy({ status: 407 });
    const gateway = serveGateway();
    const home = newHome("tui-refused");
    writeProvider(home, `https://${TARGET}/v1`);
    // The session inherits the shell, so every proxy variable is set here.
    const session = await TmuxSession.create({
      cwd: home,
      width: 200,
      isolated: true,
      env: {
        ...baseEnv(home, gateway.env),
        HTTPS_PROXY: proxy.url(CREDENTIALS),
        HTTP_PROXY: undefined,
        ALL_PROXY: undefined,
        NO_PROXY: undefined,
        https_proxy: undefined,
        http_proxy: undefined,
        all_proxy: undefined,
        no_proxy: undefined,
      },
    });
    try {
      await session.waitForComposer();
      await session.sendText("hi");
      await session.sendKeys("Enter");
      const pane = await session.waitForText(`refused CONNECT to ${TARGET}:443: 407 Proxy Authentication Required`, 20_000);
      expect(pane).toContain(`proxy 127.0.0.1:${proxy.port}`);
      expect(pane).not.toContain("p%40ss");
      for (const entry of proxy.log) expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
    } finally {
      await session.kill();
      proxy.close();
      gateway.stop();
    }
  }, TIMEOUT);

  test("a SOCKS proxy is refused with a message, and its credentials stay out of it", async () => {
    const gateway = serveGateway();
    const home = newHome("socks");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, ALL_PROXY: "socks5://user:secret-word@127.0.0.1:1080" }), { timeoutMs: 20_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stderr).toContain("fx supports only http:// proxies, but ALL_PROXY is socks5://...");
      expect(run.stderr + run.stdout).not.toContain("secret-word");
    } finally {
      gateway.stop();
    }
  }, TIMEOUT);
});

type Subscription = "codex" | "grok";
const SUBSCRIPTION_ACCOUNT = "acct_net_proxy_e2e";

function subscriptionAccessToken(provider: Subscription, signature: string): string {
  if (provider === "grok") return `grok-${signature}`;
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: SUBSCRIPTION_ACCOUNT },
  })).toString("base64url");
  return `header.${payload}.${signature}`;
}

/** An expired sign-in, so fx refreshes it through the token endpoint first. */
function writeExpiredSubscriptionLogin(home: string, provider: Subscription) {
  writeFileSync(join(home, ".fx", provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json"), JSON.stringify({
    version: 1,
    access_token: subscriptionAccessToken(provider, "stale"),
    refresh_token: `${provider}-refresh`,
    expires_at_ms: Date.now() - 60_000,
    account_id: SUBSCRIPTION_ACCOUNT,
  }) + "\n", { mode: 0o600 });
}

/** Codex's or Grok's sign-in, version, catalog, and model endpoints. */
function serveSubscription(provider: Subscription, text: string) {
  const fake = serveLocal(async (request, path) => {
    if (path === "/version") return provider === "codex" ? Response.json({ version: "0.153.1" }) : new Response("1.0.13\n");
    if (path === "/models") {
      return Response.json(provider === "codex"
        ? { models: [{ slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 }] }
        : { data: [{ id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
    }
    if (path === "/modalities") return Response.json({ models: [{ id: "grok-4.20", input_modalities: ["text"], output_modalities: ["text"] }] });
    if (path === "/token") return Response.json({ access_token: subscriptionAccessToken(provider, "fresh"), refresh_token: `${provider}-refresh-next`, expires_in: 3600 });
    if (path === "/userinfo") return Response.json({ sub: SUBSCRIPTION_ACCOUNT });
    await request.text();
    return new Response(
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
        'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
      { headers: { "content-type": "text/event-stream" } },
    );
  });
  const env: Record<string, string> = provider === "codex"
    ? {
      FX_PROVIDER: "codex",
      FX_MODEL: "gpt-5.4-mini",
      FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${fake.base}/responses`,
      FX_TEST_OPENAI_CODEX_MODELS_URL: `${fake.base}/models`,
      FX_TEST_CHATGPT_TOKEN_URL: `${fake.base}/token`,
      FX_TEST_CODEX_VERSION_URL: `${fake.base}/version`,
    }
    : {
      FX_PROVIDER: "grok",
      FX_MODEL: "grok-4.20",
      FX_TEST_XAI_GROK_RESPONSES_URL: `${fake.base}/responses`,
      FX_TEST_XAI_GROK_MODELS_URL: `${fake.base}/models`,
      FX_TEST_XAI_GROK_MODALITIES_URL: `${fake.base}/modalities`,
      FX_TEST_GROK_TOKEN_URL: `${fake.base}/token`,
      FX_TEST_GROK_USERINFO_URL: `${fake.base}/userinfo`,
      FX_TEST_GROK_VERSION_URL: `${fake.base}/version`,
    };
  return { ...fake, env };
}

describe("net proxy for each provider family", () => {
  const cases = [
    { name: "AI Gateway", marker: "GATEWAY_PROXY_OK" },
    { name: "Codex subscription", marker: "CODEX_PROXY_OK", subscription: "codex" as const },
    { name: "Grok subscription", marker: "GROK_PROXY_OK", subscription: "grok" as const },
  ];
  for (const testCase of cases) {
    test(`${testCase.name}: sign-in, catalog, and model requests go only through the proxy`, async () => {
      const proxy = await startConnectProxy();
      const gateway = serveGateway(testCase.marker);
      const subscription = testCase.subscription ? serveSubscription(testCase.subscription, testCase.marker) : null;
      const home = newHome(testCase.subscription ?? "gateway");
      try {
        writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, permission_mode: "ask" }), { mode: 0o600 });
        if (testCase.subscription) writeExpiredSubscriptionLogin(home, testCase.subscription);
        const env = baseEnv(home, {
          ...gateway.env,
          ...(subscription ? subscription.env : { FX_MODEL: "openai/gpt-5" }),
          HTTPS_PROXY: proxy.url(CREDENTIALS),
          HTTP_PROXY: proxy.url(CREDENTIALS),
          FX_TEST_NET_PROXY_LOOPBACK: "1",
        });
        if (subscription) delete env.AI_GATEWAY_API_KEY;
        const run = await runFx(ask, env);
        expect(run.code, show(run)).toBe(0);
        expect(run.stdout).toContain(testCase.marker);
        const served = subscription ?? gateway;
        expect(served.remotePorts.length).toBeGreaterThan(0);
        if (subscription) {
          // Sign-in refresh, the client version lookup, and the catalog.
          expect(subscription.paths).toContain("/token");
          expect(subscription.paths).toContain("/version");
          expect(subscription.paths).toContain("/models");
        }
        for (const fake of [gateway, subscription]) {
          if (!fake) continue;
          for (const port of fake.remotePorts) expect(proxy.upstreamPorts.has(port)).toBe(true);
        }
        expect(proxy.log.some(entry => entry.requestLine === `CONNECT 127.0.0.1:${served.port} HTTP/1.1`)).toBe(true);
        for (const entry of proxy.log) expect(entry.authorization).toBe(CREDENTIALS_HEADER);
      } finally {
        proxy.close();
        gateway.stop();
        subscription?.stop();
      }
    }, TIMEOUT);
  }
});

test("an MCP HTTP server is reached only through the proxy", async () => {
  const proxy = await startConnectProxy();
  const mcp = startModernMcpHttpFixture("json");
  const home = newHome("mcp");
  try {
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false }), { mode: 0o600 });
    writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: { fixture: { type: "http", url: mcp.url, startup_timeout_ms: 5_000 } } }), { mode: 0o600 });
    const run = await runFx(["mcp", "show", "fixture"], baseEnv(home, {
      HTTPS_PROXY: proxy.url(CREDENTIALS),
      HTTP_PROXY: proxy.url(CREDENTIALS),
      FX_TEST_NET_PROXY_LOOPBACK: "1",
    }));
    expect(run.code, show(run)).toBe(0);
    expect(run.stdout).toContain("status     ready");
    const port = new URL(mcp.url).port;
    expect(proxy.log.some(entry => entry.requestLine === `CONNECT 127.0.0.1:${port} HTTP/1.1`), JSON.stringify(proxy.log)).toBe(true);
    for (const entry of proxy.log) expect(entry.authorization).toBe(CREDENTIALS_HEADER);
  } finally {
    proxy.close();
    mcp.stop();
  }
}, TIMEOUT);
