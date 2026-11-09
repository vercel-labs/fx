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
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { completion } from "./fixtures/chat-completions";
import { startModernMcpHttpFixture } from "./fixtures/mcp-modern-http";
import { startConnectProxy } from "./fixtures/net-proxy/proxy";
import { TmuxSession, fakeGatewayFinalText, fakeGatewayToolCall, fakeShellRun, startFakeGateway, tmuxAvailable } from "./tmux-helpers";

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

type Output = { stdout: string; stderr: string };

/**
 * Runs the built fx with exactly `env` and nothing inherited. `until` is
 * polled with the output so far while it runs; once it holds, fx is stopped
 * after `graceMs`.
 */
async function runFx(argv: string[], env: Record<string, string>, options: { timeoutMs?: number; until?: (output: Output) => boolean; graceMs?: number } = {}): Promise<Run> {
  const started = performance.now();
  const child = Bun.spawn([FX_BIN, ...argv], { cwd: env.HOME, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const output: Output = { stdout: "", stderr: "" };
  const pump = async (stream: ReadableStream<Uint8Array>, key: keyof Output) => {
    const decoder = new TextDecoder();
    const reader = stream.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      output[key] += decoder.decode(value, { stream: true });
    }
  };
  const pumps = Promise.all([pump(child.stdout, "stdout"), pump(child.stderr, "stderr")]);
  const timer = setTimeout(() => child.kill(), options.timeoutMs ?? 30_000);
  let poll: ReturnType<typeof setInterval> | undefined;
  if (options.until) {
    poll = setInterval(() => {
      if (!options.until!(output)) return;
      clearInterval(poll);
      setTimeout(() => child.kill(), options.graceMs ?? 500);
    }, 50);
  }
  const code = await child.exited;
  await pumps;
  clearTimeout(timer);
  if (poll) clearInterval(poll);
  return { code: child.signalCode ? null : code, stdout: output.stdout, stderr: output.stderr, ms: performance.now() - started };
}

/** A loopback port nothing listens on: a proxy that is down. */
async function closedPort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as net.AddressInfo).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  return port;
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

/** The retry notices `fx ask` printed on stderr, one per line. */
function retryNoticeLines(stderr: string): string[] {
  return stderr.split("\n").filter(line => /^\[notice\] (Offline|Connection lost)/.test(line));
}

function retryNotices(run: Run): string[] {
  return retryNoticeLines(run.stderr);
}

/**
 * A retry notice that names the proxy ends in `note` and still says when the
 * next try is, or that fx is retrying, within the 95 bytes of a status text.
 * The full sentence stays in the final error and in `fx models`.
 */
function expectNoticeKeepsWait(line: string, note: string, run: Run): void {
  expect(line, show(run)).toMatch(/^\[notice\] [^\u00b7]+ \u00b7 (next try in \d+s|retrying)/);
  expect(line.endsWith(` \u00b7 ${note}`), show(run)).toBe(true);
  expect(Buffer.byteLength(line) - "[notice] ".length, show(run)).toBeLessThanOrEqual(95);
}

describe("net proxy failures name the proxy", () => {
  for (const family of [
    { name: "AI Gateway", custom: false },
    { name: "a custom chat-completions provider", custom: true },
    { name: "a Codex subscription", custom: false, subscription: "codex" as const },
    { name: "a Grok subscription", custom: false, subscription: "grok" as const },
  ]) {
    test(`${family.name}: a proxy fx cannot reach is retried, and the notices name it as the cause`, async () => {
      const dead = await closedPort();
      const gateway = serveGateway();
      const subscription = family.subscription ? serveSubscription(family.subscription, "NEVER_REACHED") : null;
      // Grok's client version is looked up before its first request, and a
      // lookup that fails ends the run before any request. A second fake,
      // which NO_PROXY keeps off the proxy, answers it, so the model request
      // is what meets the dead proxy.
      const version = family.subscription === "grok" ? serveLocal(() => new Response("1.0.13\n")) : null;
      const home = newHome("dead-proxy");
      try {
        if (family.custom) writeProvider(home, `https://${TARGET}/v1`);
        if (family.subscription) {
          writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, permission_mode: "ask" }), { mode: 0o600 });
          writeValidSubscriptionLogin(home, family.subscription);
        }
        const env = baseEnv(home, {
          ...gateway.env,
          ...(subscription ? subscription.env : {}),
          ...(version ? { FX_TEST_GROK_VERSION_URL: `${version.base}/version`, NO_PROXY: `127.0.0.1:${version.port}` } : {}),
          ...(family.custom ? {} : { FX_TEST_NET_PROXY_LOOPBACK: "1" }),
          ...(family.custom || subscription ? {} : { FX_MODEL: "openai/gpt-5" }),
          HTTPS_PROXY: `http://127.0.0.1:${dead}`,
        });
        if (subscription) delete env.AI_GATEWAY_API_KEY;
        const run = await runFx(family.custom ? askCustom : ask, env, {
          timeoutMs: 30_000,
          until: ({ stderr }) => retryNoticeLines(stderr).length >= 2,
        });
        const note = `proxy 127.0.0.1:${dead} unreachable`;
        const notices = retryNotices(run);
        expect(notices.length, show(run)).toBeGreaterThanOrEqual(2);
        for (const line of notices) expectNoticeKeepsWait(line, note, run);
        expect(run.stderr).not.toContain("ConnectionRefused");
        // Nothing reached the fake provider: every request needed the proxy.
        expect(subscription?.remotePorts.length ?? 0).toBe(0);
      } finally {
        gateway.stop();
        subscription?.stop();
        version?.stop();
      }
    }, TIMEOUT);
  }

  test("a proxy that answers 502 is retried, and the notices name it and its answer", async () => {
    const proxy = await startConnectProxy({ status: 502 });
    const gateway = serveGateway();
    const home = newHome("bad-gateway-notice");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url() }), {
        timeoutMs: 25_000,
        until: ({ stderr }) => stderr.includes("retrying"),
      });
      const note = `proxy 127.0.0.1:${proxy.port} answered 502`;
      const notices = retryNotices(run);
      expect(notices.length, show(run)).toBeGreaterThanOrEqual(2);
      for (const line of notices) expectNoticeKeepsWait(line, note, run);
      expect(notices.some(line => line.includes("next try in")), show(run)).toBe(true);
      expect(notices.some(line => line.includes("retrying")), show(run)).toBe(true);
      for (const entry of proxy.log) expect(entry.requestLine).toBe(`CONNECT ${TARGET}:443 HTTP/1.1`);
    } finally {
      proxy.close();
      gateway.stop();
    }
  }, TIMEOUT);

  test("fx models names the proxy when it cannot connect through it", async () => {
    const dead = await closedPort();
    const bad = await startConnectProxy({ status: 502 });
    const gateway = serveGateway();
    try {
      for (const { proxy, sentence } of [
        { proxy: `http://127.0.0.1:${dead}`, sentence: `could not connect to proxy 127.0.0.1:${dead} (connection refused)` },
        { proxy: bad.url(), sentence: `proxy 127.0.0.1:${bad.port} refused CONNECT to 127.0.0.1:${gateway.port}: 502 Bad Gateway` },
      ]) {
        const home = newHome("models-proxy");
        const env = baseEnv(home, { ...gateway.env, FX_MODEL: "openai/gpt-5", HTTPS_PROXY: proxy, FX_TEST_NET_PROXY_LOOPBACK: "1" });
        const run = await runFx(["models"], env, { timeoutMs: 45_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stderr, show(run)).toContain(`fx models: could not list models: couldn't connect to AI Gateway: ${sentence}; check your network connection or firewall`);
        const json = await runFx(["models", "--json"], env, { timeoutMs: 45_000 });
        expect(JSON.parse(json.stdout).error, show(json)).toContain(sentence);
      }
    } finally {
      bad.close();
      gateway.stop();
    }
  }, 120_000);

  test("a proxy that sends 102 before its 200 opens the tunnel, and one that sends 101 does not", async () => {
    for (const interim of [102, 100]) {
      const proxy = await startConnectProxy({ interim });
      const provider = serveLocal(() => completion("custom-model", "INTERIM_PROXY_OK"));
      const gateway = serveGateway();
      const home = newHome("interim");
      try {
        writeProvider(home, `${provider.base}/v1`);
        const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: proxy.url(), FX_TEST_NET_PROXY_LOOPBACK: "1" }));
        expect(run.code, show(run)).toBe(0);
        expect(run.stdout).toContain("INTERIM_PROXY_OK");
        expect(proxy.log.some(entry => entry.requestLine === `CONNECT 127.0.0.1:${provider.port} HTTP/1.1`), JSON.stringify(proxy.log)).toBe(true);
        for (const port of provider.remotePorts) expect(proxy.upstreamPorts.has(port)).toBe(true);
      } finally {
        proxy.close();
        provider.stop();
        gateway.stop();
      }
    }
    const refusing = await startConnectProxy({ status: 101 });
    const gateway = serveGateway();
    const home = newHome("switching");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: refusing.url() }), { timeoutMs: 20_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stderr).toContain(`proxy 127.0.0.1:${refusing.port} refused CONNECT to ${TARGET}:443: 101`);
    } finally {
      refusing.close();
      gateway.stop();
    }
  }, 120_000);

  test("a proxy host with an underscore is accepted, and its failure is named", async () => {
    const gateway = serveGateway();
    const home = newHome("underscore");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      // .invalid never resolves, so the proxy cannot be reached; fx must say
      // that, and not that the value is not a proxy URL.
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: "http://squid_proxy.invalid:3128" }), {
        timeoutMs: 25_000,
        until: ({ stderr }) => stderr.includes("[notice] Offline"),
      });
      expect(run.stderr).not.toContain("is not a proxy URL fx can read");
      for (const line of retryNotices(run)) expectNoticeKeepsWait(line, "proxy squid_proxy.invalid:3128 unreachable", run);
    } finally {
      gateway.stop();
    }
  }, TIMEOUT);

  test("a proxy host of 253 bytes is cut in the notice, which still says when the next try is", async () => {
    const gateway = serveGateway();
    const home = newHome("long-host");
    // Three labels of 61 letters, one of 59, and .invalid make a 253-byte host
    // that never resolves, so the proxy cannot be reached.
    const host = ["a".repeat(61), "b".repeat(61), "c".repeat(61), "d".repeat(59)].join(".") + ".invalid";
    expect(host.length).toBe(253);
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: `http://${host}:3128` }), {
        timeoutMs: 25_000,
        until: ({ stderr }) => stderr.includes("retrying"),
      });
      // 48 bytes: "proxy ", 22 letters of the host and an ellipsis, ":3128", " unreachable".
      const note = `proxy ${"a".repeat(22)}\u2026:3128 unreachable`;
      expect(Buffer.byteLength(note)).toBe(48);
      const notices = retryNotices(run);
      expect(notices.length, show(run)).toBeGreaterThanOrEqual(2);
      for (const line of notices) expectNoticeKeepsWait(line, note, run);
      expect(notices.some(line => line.includes("retrying")), show(run)).toBe(true);
    } finally {
      gateway.stop();
    }
  }, TIMEOUT);

  test("every refused proxy variable names its own reason, and never repeats hostile bytes", async () => {
    const gateway = serveGateway();
    const home = newHome("reasons");
    try {
      writeProvider(home, `https://${TARGET}/v1`);
      for (const [value, message] of [
        ["http:///path", "HTTPS_PROXY has no host name; use http://host:port"],
        ["http://bad_host!:1", "HTTPS_PROXY has a host name fx cannot use: bad_host!"],
        ["http://a%1b%5b31mb:80", "HTTPS_PROXY has a host name fx cannot use"],
        ["http://proxy.test:99999", "HTTPS_PROXY has a port fx cannot use; use a number from 1 to 65535"],
        ["http://[::1", "HTTPS_PROXY is not a proxy URL fx can read; use http://host:port"],
      ] as const) {
        const run = await runFx(askCustom, baseEnv(home, { ...gateway.env, HTTPS_PROXY: value }), { timeoutMs: 20_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stderr, show(run)).toContain(`fx: ${message}`);
        expect(run.stderr).not.toContain("\x1b[31m");
      }
    } finally {
      gateway.stop();
    }
  }, TIMEOUT);

  test("NO_PROXY entries fx drops are logged once, however long the list", async () => {
    for (const extra of [2, 4_000]) {
      const proxy = await startConnectProxy({ status: 407 });
      const gateway = serveGateway();
      const home = newHome("no-proxy-drops");
      const trace = join(home, "net-proxy-trace.log");
      try {
        writeProvider(home, `https://${TARGET}/v1`);
        // Two entries that do not parse, 1000 that fit, and `extra` past the limit.
        const entries = ["bad:port", "10.0.0.0/33", ...Array.from({ length: 1000 + extra }, (_, i) => `d${i}.corp.test`)];
        const run = await runFx(askCustom, baseEnv(home, {
          ...gateway.env,
          HTTPS_PROXY: proxy.url(),
          NO_PROXY: entries.join(","),
          FX_TRACE_LOG: trace,
          FX_TRACE_SCOPES: "net_proxy",
        }), { timeoutMs: 20_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stderr).toContain("refused CONNECT");
        expect(existsSync(trace)).toBe(true);
        const dropped = readFileSync(trace, "utf8").split("\n").filter(line => line.includes("no_proxy dropped"));
        expect(dropped.length, dropped.join("\n")).toBe(1);
        expect(dropped[0]).toContain(`invalid=2 over_limit=${extra}`);
      } finally {
        proxy.close();
        gateway.stop();
      }
    }
  }, 120_000);

  test.skipIf(!tmuxAvailable())("the interactive app names a proxy it cannot reach in its status line", async () => {
    const dead = await closedPort();
    const gateway = serveGateway();
    const home = newHome("tui-dead");
    writeProvider(home, `https://${TARGET}/v1`);
    const session = await TmuxSession.create({
      cwd: home,
      width: 200,
      isolated: true,
      env: {
        ...baseEnv(home, gateway.env),
        HTTPS_PROXY: `http://127.0.0.1:${dead}`,
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
      const pane = await session.waitForText(`proxy 127.0.0.1:${dead} unreachable`, 25_000);
      expect(pane).toContain("Offline");
      expect(pane).toMatch(/next try in \d+s|retrying/);
    } finally {
      await session.kill();
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

/** A sign-in that has not expired, so fx goes straight to the model request. */
function writeValidSubscriptionLogin(home: string, provider: Subscription) {
  writeFileSync(join(home, ".fx", provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json"), JSON.stringify({
    version: 1,
    access_token: subscriptionAccessToken(provider, "fresh"),
    refresh_token: `${provider}-refresh`,
    expires_at_ms: Date.now() + 3_600_000,
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

/** A fake release server for `fx upgrade`: the latest version is there, no archive is. */
function serveRelease() {
  return serveLocal((_request, path) => (path === "/latest.txt" ? new Response("9.9.9\n") : new Response("missing", { status: 404 })));
}

/** A profile with a valid Grok sign-in, so `fx ask` goes straight to its version lookup. */
function grokHome(name: string): string {
  const home = newHome(name);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, permission_mode: "ask" }), { mode: 0o600 });
  writeValidSubscriptionLogin(home, "grok");
  return home;
}

describe("net proxy failures in version lookups, fx upgrade, and reviewer traces", () => {
  test("a Grok client version lookup behind a proxy fx cannot reach ends fx ask naming the proxy", async () => {
    const dead = await closedPort();
    const grok = serveSubscription("grok", "NEVER_REACHED");
    const home = grokHome("version-dead");
    try {
      const env = baseEnv(home, { ...grok.env, HTTPS_PROXY: `http://127.0.0.1:${dead}`, FX_TEST_NET_PROXY_LOOPBACK: "1" });
      const run = await runFx(ask, env, { timeoutMs: 30_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stderr, show(run)).toContain(`fx: could not connect to proxy 127.0.0.1:${dead} (connection refused)`);
      expect(run.stderr).not.toContain("provider version unavailable");
      expect(run.stderr).not.toContain("ConnectionRefused");
      // Nothing reached the fake: the lookup needed the proxy, and ended the run.
      expect(grok.remotePorts.length).toBe(0);
    } finally {
      grok.stop();
    }
  }, TIMEOUT);

  test("a Grok client version lookup behind a proxy that refuses CONNECT names the proxy and its answer", async () => {
    const proxy = await startConnectProxy({ status: 407 });
    const grok = serveSubscription("grok", "NEVER_REACHED");
    const home = grokHome("version-407");
    try {
      const env = baseEnv(home, { ...grok.env, HTTPS_PROXY: proxy.url(CREDENTIALS), FX_TEST_NET_PROXY_LOOPBACK: "1" });
      const run = await runFx(ask, env, { timeoutMs: 30_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stderr, show(run)).toContain(`fx: proxy 127.0.0.1:${proxy.port} refused CONNECT to 127.0.0.1:${grok.port}: 407 Proxy Authentication Required`);
      expect(run.stderr + run.stdout).not.toContain("p%40ss");
      expect(grok.remotePorts.length).toBe(0);
    } finally {
      proxy.close();
      grok.stop();
    }
  }, TIMEOUT);

  test("a Grok client version lookup that fails for another reason keeps its own text, with a proxy that works and with none", async () => {
    const proxy = await startConnectProxy();
    const grok = serveSubscription("grok", "NEVER_REACHED");
    const broken = serveLocal(() => new Response("no release", { status: 500 }));
    const home = grokHome("version-500");
    try {
      for (const withProxy of [true, false]) {
        const env = baseEnv(home, {
          ...grok.env,
          FX_TEST_GROK_VERSION_URL: `${broken.base}/version`,
          ...(withProxy ? { HTTPS_PROXY: proxy.url(), FX_TEST_NET_PROXY_LOOPBACK: "1" } : {}),
        });
        const run = await runFx(ask, env, { timeoutMs: 30_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stderr, show(run)).toContain("fx: provider version unavailable");
        expect(run.stderr).not.toContain("proxy");
        if (withProxy) {
          // The lookup did go through the proxy, and the proxy was not at fault.
          expect(proxy.log.some(entry => entry.requestLine === `CONNECT 127.0.0.1:${broken.port} HTTP/1.1`), JSON.stringify(proxy.log)).toBe(true);
        }
      }
    } finally {
      proxy.close();
      grok.stop();
      broken.stop();
    }
  }, TIMEOUT);

  test("fx models names the proxy when Codex's version lookup, made inside its catalog fetch, cannot connect", async () => {
    const dead = await closedPort();
    const codex = serveSubscription("codex", "NEVER_REACHED");
    const home = newHome("codex-models-dead");
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, permission_mode: "ask" }), { mode: 0o600 });
    writeValidSubscriptionLogin(home, "codex");
    try {
      const env = baseEnv(home, { ...codex.env, HTTPS_PROXY: `http://127.0.0.1:${dead}`, FX_TEST_NET_PROXY_LOOPBACK: "1" });
      const run = await runFx(["models"], env, { timeoutMs: 45_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stderr, show(run)).toContain(`could not connect to proxy 127.0.0.1:${dead} (connection refused)`);
      expect(codex.remotePorts.length).toBe(0);
    } finally {
      codex.stop();
    }
  }, 60_000);

  test("fx upgrade through a proxy fx cannot reach names the proxy, as text and as JSON", async () => {
    const dead = await closedPort();
    const release = serveRelease();
    const home = newHome("upgrade-dead");
    try {
      const env = baseEnv(home, { FX_TEST_UPGRADE_BASE_URL: release.base, HTTPS_PROXY: `http://127.0.0.1:${dead}`, FX_TEST_NET_PROXY_LOOPBACK: "1" });
      const sentence = `could not connect to proxy 127.0.0.1:${dead} (connection refused)`;
      const text = await runFx(["upgrade"], env, { timeoutMs: 40_000 });
      expect(text.code, show(text)).toBe(1);
      expect(text.stdout, show(text)).toBe(`error: failed to fetch latest version from CDN: ${sentence}\n`);
      const json = await runFx(["upgrade", "--json"], env, { timeoutMs: 40_000 });
      expect(json.code, show(json)).toBe(1);
      expect(JSON.parse(json.stdout), show(json)).toEqual({ kind: "upgrade", error: `failed to fetch latest version from CDN: ${sentence}` });
      expect(release.remotePorts.length).toBe(0);
    } finally {
      release.stop();
    }
  }, 90_000);

  test("fx upgrade whose proxy refuses the archive download names the proxy in the download error", async () => {
    const proxy = await startConnectProxy({ refuseAfter: 1 });
    const release = serveRelease();
    const home = newHome("upgrade-407");
    try {
      const env = baseEnv(home, { FX_TEST_UPGRADE_BASE_URL: release.base, HTTPS_PROXY: proxy.url(CREDENTIALS), FX_TEST_NET_PROXY_LOOPBACK: "1" });
      const run = await runFx(["upgrade"], env, { timeoutMs: 40_000 });
      expect(run.code, show(run)).toBe(1);
      expect(run.stdout, show(run)).toBe(`error: failed to download release archive: proxy 127.0.0.1:${proxy.port} refused CONNECT to 127.0.0.1:${release.port}: 407 Proxy Authentication Required\n`);
      // The version came through the tunnel, and the archive request never did.
      expect(release.paths).toEqual(["/latest.txt"]);
      expect(run.stdout + run.stderr).not.toContain("p%40ss");
    } finally {
      proxy.close();
      release.stop();
    }
  }, TIMEOUT);

  test("fx upgrade keeps today's texts when the proxy is not at fault, with a proxy that works and with none", async () => {
    const proxy = await startConnectProxy();
    const release = serveRelease();
    const home = newHome("upgrade-plain");
    try {
      for (const withProxy of [true, false]) {
        const env = baseEnv(home, {
          FX_TEST_UPGRADE_BASE_URL: release.base,
          ...(withProxy ? { HTTPS_PROXY: proxy.url(), FX_TEST_NET_PROXY_LOOPBACK: "1" } : {}),
        });
        const run = await runFx(["upgrade"], env, { timeoutMs: 40_000 });
        expect(run.code, show(run)).toBe(1);
        expect(run.stdout, show(run)).toBe("error: failed to download release archive\n");
        const json = await runFx(["upgrade", "--json"], env, { timeoutMs: 40_000 });
        expect(JSON.parse(json.stdout), show(json)).toEqual({ kind: "upgrade", error: "failed to download release archive" });
      }
      // The proxy relayed the version and the archive requests: it was not at fault.
      expect(proxy.log.some(entry => entry.requestLine === `CONNECT 127.0.0.1:${release.port} HTTP/1.1`), JSON.stringify(proxy.log)).toBe(true);
    } finally {
      proxy.close();
      release.stop();
    }
  }, 120_000);

  test("a reviewer that cannot reach its endpoint through the proxy leaves the proxy in its trace line and nowhere on screen", async () => {
    const dead = await closedPort();
    const marker = "REVIEWER_PROXY_TRACE";
    const gateway = startFakeGateway([fakeShellRun("cmd_1", `printf '%s' "${marker}"`), fakeGatewayFinalText("Held the command.")]);
    const home = newHome("reviewer-trace");
    const trace = join(home, "reviewer-trace.log");
    try {
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, sandbox: "none", permission: {} }), { mode: 0o600 });
      const env = baseEnv(home, {
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: "openai/gpt-5",
        FX_PERMISSION_MODE: "auto",
        FX_REVIEW_MODEL: "typesafeai/jev",
        TYPESAFE_API_KEY: "net-proxy-reviewer-key",
        // The gateway is on loopback and goes direct; the reviewer's host
        // resolves nowhere, so only the proxy could reach it.
        TYPESAFE_BASE_URL: "https://jev-reviewer.test/v1/systemone",
        HTTPS_PROXY: `http://127.0.0.1:${dead}`,
        FX_TRACE_LOG: trace,
        FX_TRACE_SCOPES: "permission",
      });
      const run = await runFx(["ask", "--auto", "--quiet", "--json", "Print the marker."], env, { timeoutMs: 40_000 });
      expect(existsSync(trace), show(run)).toBe(true);
      const lines = readFileSync(trace, "utf8").split("\n").filter(line => line.includes("event=auto_review_typesafe_transport result="));
      expect(lines.length, show(run)).toBeGreaterThanOrEqual(1);
      for (const line of lines) {
        expect(line).toContain("reason=fetch_error");
        expect(line.endsWith(` proxy="could not connect to proxy 127.0.0.1:${dead} (connection refused)"`), line).toBe(true);
      }
      // No new user-visible field: the proxy is in the trace and nowhere else.
      expect(run.stdout + run.stderr).not.toContain("could not connect to proxy");
    } finally {
      gateway.stop();
    }
  }, 90_000);
});

/** web_fetch's target: an address literal its public-address rule admits without DNS. */
const FETCH_ADDRESS = "93.184.216.34";

/**
 * Runs `fx ask` with a fake model that calls web_fetch on FETCH_ADDRESS, behind
 * the proxy at `proxyUrl`, and returns the model's next request, which carries
 * web_fetch's result. web_fetch dials the proxy itself, not through the process
 * Io that model requests use.
 */
async function fetchBehind(proxyUrl: string): Promise<{ run: Run; toolResult: string; requests: number }> {
  const gateway = startFakeGateway([
    fakeGatewayToolCall("fetch_1", "web_fetch", { url: `https://${FETCH_ADDRESS}/docs` }),
    fakeGatewayFinalText("DONE_AFTER_FETCH"),
  ]);
  const home = newHome("web-fetch");
  try {
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      auto_upgrade: false,
      permission: { web_fetch: { [`domain:${FETCH_ADDRESS}`]: "allow" } },
    }), { mode: 0o600 });
    const run = await runFx(["ask", "--auto", "--json", "--no-save", "Fetch the page."], baseEnv(home, {
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: "openai/gpt-5",
      HTTPS_PROXY: proxyUrl,
    }), { timeoutMs: 40_000 });
    // Only the tool messages of the second request: the rest is the prompt and the tool list.
    const second = gateway.requests[1]?.body ?? "";
    let toolResult: string;
    try {
      toolResult = JSON.stringify((JSON.parse(second).prompt as Array<{ role: string }>).filter(message => message.role === "tool"));
    } catch {
      toolResult = second.slice(-2_000);
    }
    return { run, toolResult, requests: gateway.requests.length };
  } finally {
    gateway.stop();
  }
}

describe("web_fetch behind a proxy fx cannot use names the proxy to the model", () => {
  test("a proxy at a closed port is named, whatever name the platform gives the refused connect", async () => {
    // macOS polls a refused non-blocking connect as HUP alone, which web_fetch's
    // own dialer used to hand to the model as a bare UnexpectedClose.
    const dead = await closedPort();
    const { run, toolResult, requests } = await fetchBehind(`http://127.0.0.1:${dead}`);
    expect(run.code, show(run)).toBe(0);
    expect(requests, show(run)).toBe(2);
    expect(toolResult, show(run)).toContain("web_fetch transport failed");
    expect(toolResult, show(run)).toContain(`could not connect to proxy 127.0.0.1:${dead} (`);
  }, TIMEOUT);

  test("a proxy host that never resolves is named", async () => {
    // The dialer's own error for a name that does not resolve is on no platform's list.
    const { run, toolResult, requests } = await fetchBehind("http://never-resolves-proxy.invalid:3128");
    expect(run.code, show(run)).toBe(0);
    expect(requests, show(run)).toBe(2);
    expect(toolResult, show(run)).toContain("could not connect to proxy never-resolves-proxy.invalid:3128 (");
  }, TIMEOUT);

  test("a proxy that answers 407 is named with its answer, and the CONNECT names the checked address", async () => {
    const proxy = await startConnectProxy({ status: 407 });
    try {
      const { run, toolResult } = await fetchBehind(proxy.url());
      expect(run.code, show(run)).toBe(0);
      expect(toolResult, show(run)).toContain(`proxy 127.0.0.1:${proxy.port} refused CONNECT to ${FETCH_ADDRESS}:443: 407 Proxy Authentication Required`);
      expect(proxy.log.map(entry => entry.requestLine)).toEqual([`CONNECT ${FETCH_ADDRESS}:443 HTTP/1.1`]);
    } finally {
      proxy.close();
    }
  }, TIMEOUT);

  test("a relay that closes after the tunnel opens is not blamed on the proxy", async () => {
    // The proxy did its part: the far side takes the connection and closes it,
    // so TLS fails inside an open tunnel.
    const closer = net.createServer(socket => socket.destroy());
    await new Promise<void>(resolve => closer.listen(0, "127.0.0.1", resolve));
    const proxy = await startConnectProxy({ routes: { [`${FETCH_ADDRESS}:443`]: (closer.address() as net.AddressInfo).port } });
    try {
      const { run, toolResult } = await fetchBehind(proxy.url());
      expect(run.code, show(run)).toBe(0);
      expect(proxy.log.map(entry => entry.requestLine), show(run)).toEqual([`CONNECT ${FETCH_ADDRESS}:443 HTTP/1.1`]);
      expect(toolResult, show(run)).toContain("web_fetch transport failed");
      expect(toolResult).not.toContain("could not connect to proxy");
      expect(toolResult).not.toContain(`proxy 127.0.0.1:${proxy.port}`);
    } finally {
      proxy.close();
      closer.close();
    }
  }, TIMEOUT);
});
