// Runs the built fx through proxies that answer in the ways the repair of
// PR #1728 is about, and has TLC check what fx did against the design
// (tests/tla/net_proxy/NetProxyTrace.tla, NetProxyEnvTrace.tla, and
// NetProxyCallersTrace.tla).
//
// Each scenario is one environment action in the model's words: a proxy that
// sends 102 or 100 before its 200, one that sends 101, one that answers 502,
// one that answers 407, one that is down, or a proxy URL whose host has an
// underscore or another class. The driver runs fx once with that proxy and a
// local provider, reads what fx did (did the request reach the provider
// through the tunnel, what did the retry notices and the final error say), and
// writes it as a one-record module. TLC says whether the model can produce it.
//
// A third kind of scenario is a caller that fails and shows an error text: a Grok
// client version lookup that ends `fx ask`, and `fx upgrade`. Each runs behind a
// proxy that is down, one that refuses CONNECT, one that works while the server
// fails, and no proxy at all, and the driver reads whether the text names the
// proxy (NetProxyCallers.tla: a caller names the proxy for its own failure at
// the proxy, and never otherwise).
//
// With --self-check every observation is also checked against two models of
// older connectors. The connector as first written refuses interim heads, says
// only that the network is down when it retries, keeps slices of the
// environment, and refuses underscores. The connector as pushed before the short
// notice puts the whole sentence into the retry notice, which leaves no room for
// the wait when the sentence is long. A third model is fx before the callers took
// the proxy's sentence, which shows fixed text for the version lookup and for
// fx upgrade. Each must reject what the repaired fx did in every scenario where
// the two differ, and accept the rest, so the check cannot pass for any fx.
//
// Everything is local: loopback proxies, a loopback provider, a fake AI Gateway,
// a temporary FX_HOME, and FX_SOUND=0. No model is called.
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { completion } from "../../../e2e/fixtures/chat-completions";
import { startConnectProxy, type ProxyOptions } from "../../../e2e/fixtures/net-proxy/proxy";
import { TLA_ROOT, fxBin, runTlc } from "../lib/tlc";

const TARGET = "proxy-target.test";

const DESIGN = {
  UseProxy: "TRUE", AuthOnConnect: "TRUE", TlsAfterConnect: "TRUE", NoFallback: "TRUE", SharedFlag: "FALSE",
  PinFetchIp: "TRUE", DetailMode: "\"own_target\"", InterimMode: "\"skip_not_101\"", NoticeMode: "\"own_target\"",
  NoticeForm: "\"short\"", LongHost: "FALSE",
};
const FIRST = { ...DESIGN, InterimMode: "\"refuse\"", NoticeMode: "\"generic\"" };
/** The connector as pushed before the short notice: the whole sentence in the notice. */
const PUSHED = { ...DESIGN, NoticeForm: "\"full\"" };
const ENV_DESIGN = {
  Guard: "\"upper_only\"", BorrowHost: "FALSE", BorrowNoProxy: "FALSE", AcceptsUnderscore: "TRUE", AcceptsBang: "FALSE", NamesReasons: "TRUE",
};
const ENV_FIRST = {
  Guard: "\"none\"", BorrowHost: "TRUE", BorrowNoProxy: "TRUE", AcceptsUnderscore: "FALSE", AcceptsBang: "FALSE", NamesReasons: "FALSE",
};

/** The callers' design: the version lookup and fx upgrade take the proxy's sentence. */
const CALLERS_DESIGN = { VersionClaims: "TRUE", UpgradeClaims: "TRUE", ClearsAtStart: "TRUE", NamesWithoutFailure: "FALSE" };
/** fx before they did: both show fixed text. */
const CALLERS_HEAD = { ...CALLERS_DESIGN, VersionClaims: "FALSE", UpgradeClaims: "FALSE" };

type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Run = { code: number | null; stdout: string; stderr: string; ms: number };

/** What the proxy does, in the model's words, and what fx should then do. */
type Connection = {
  name: string;
  /** The model's word for the answer. */
  answer: string;
  /** "down": nothing listens at the proxy's port. */
  proxy: "down" | ProxyOptions;
  /** The request reaches a local provider through the tunnel, as opposed to a host nothing serves. */
  completes: boolean;
  /** Whether fx's retry notices or its error name the proxy with this text; null when the run ends in success. */
  sentence: ((proxyPort: number) => string) | null;
  /** Whether fx retries (notices) or ends (error). */
  retried: boolean;
  /** Whether the connector as first written did the same, so the model of it must accept the observation. */
  sameAsFirst: boolean;
  /** Whether the connector as pushed before the short notice did the same. */
  sameAsPushed: boolean;
  /** A proxy host name that never resolves, in place of 127.0.0.1:<port>; its port is 3128. */
  host?: string;
};

/** Three labels of 61 letters, one of 59, and .invalid: a 253-byte host that never resolves. */
const LONG_HOST = ["a".repeat(61), "b".repeat(61), "c".repeat(61), "d".repeat(59)].join(".") + ".invalid";

const connections: Connection[] = [
  { name: "interim 102 before 200", answer: "interim", proxy: { interim: 102 }, completes: true, sentence: null, retried: false, sameAsFirst: false, sameAsPushed: true },
  { name: "interim 100 before 200", answer: "interim", proxy: { interim: 100 }, completes: true, sentence: null, retried: false, sameAsFirst: false, sameAsPushed: true },
  { name: "101 before 200", answer: "switching", proxy: { status: 101 }, completes: false, sentence: p => `proxy 127.0.0.1:${p} refused CONNECT to ${TARGET}:443: 101`, retried: false, sameAsFirst: true, sameAsPushed: true },
  { name: "407", answer: "auth", proxy: { status: 407 }, completes: false, sentence: p => `proxy 127.0.0.1:${p} refused CONNECT to ${TARGET}:443: 407`, retried: false, sameAsFirst: true, sameAsPushed: true },
  { name: "502", answer: "refused", proxy: { status: 502 }, completes: false, sentence: null, retried: true, sameAsFirst: false, sameAsPushed: false },
  { name: "a proxy that is down", answer: "dead", proxy: "down", completes: false, sentence: null, retried: true, sameAsFirst: false, sameAsPushed: true },
  { name: "a proxy host of 253 bytes that never resolves", answer: "dead", proxy: "down", host: LONG_HOST, completes: false, sentence: null, retried: true, sameAsFirst: false, sameAsPushed: false },
];

/** A host class in the proxy URL, the way NetProxyEnv.tla names it. */
type HostClass = { cls: string; url: string; sameAsFirst: boolean };
const hostClasses: HostClass[] = [
  { cls: "letters", url: "http://squid-proxy.invalid:3128", sameAsFirst: true },
  { cls: "underscore", url: "http://squid_proxy.invalid:3128", sameAsFirst: false },
  { cls: "bang", url: "http://bad_host!:3128", sameAsFirst: false },
  { cls: "no_host", url: "http:///path", sameAsFirst: false },
  { cls: "bad_port", url: "http://proxy.invalid:99999", sameAsFirst: false },
];

/** A caller that fails and shows an error text, in NetProxyCallers.tla's words. */
type CallerScenario = {
  name: string;
  caller: "version" | "upgrade";
  proxy: "set" | "unset";
  cause: "at_proxy" | "elsewhere";
  /** The proxy the run has: down, refusing CONNECT (from the first, or after one relayed), working, or none. */
  via: "down" | "refuses" | "refuses_after_first" | "works" | "none";
  /** Whether fx before the callers took the sentence showed the same text, so that model must accept the observation. */
  sameAsHead: boolean;
};

const callerScenarios: CallerScenario[] = [
  { name: "a Grok version lookup behind a proxy that is down", caller: "version", proxy: "set", cause: "at_proxy", via: "down", sameAsHead: false },
  { name: "a Grok version lookup behind a proxy that refuses CONNECT", caller: "version", proxy: "set", cause: "at_proxy", via: "refuses", sameAsHead: false },
  { name: "a Grok version lookup that fails behind a proxy that works", caller: "version", proxy: "set", cause: "elsewhere", via: "works", sameAsHead: true },
  { name: "a Grok version lookup that fails with no proxy", caller: "version", proxy: "unset", cause: "elsewhere", via: "none", sameAsHead: true },
  { name: "fx upgrade behind a proxy that is down", caller: "upgrade", proxy: "set", cause: "at_proxy", via: "down", sameAsHead: false },
  { name: "fx upgrade behind a proxy that refuses the download", caller: "upgrade", proxy: "set", cause: "at_proxy", via: "refuses_after_first", sameAsHead: false },
  { name: "fx upgrade whose download fails behind a proxy that works", caller: "upgrade", proxy: "set", cause: "elsewhere", via: "works", sameAsHead: true },
  { name: "fx upgrade whose download fails with no proxy", caller: "upgrade", proxy: "unset", cause: "elsewhere", via: "none", sameAsHead: true },
];

function serveLocal(handle: (request: Request, path: string) => Response | Promise<Response>) {
  const remotePorts: number[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(request, srv) {
      remotePorts.push(srv.requestIP(request)?.port ?? -1);
      return handle(request, new URL(request.url).pathname);
    },
  });
  return { port: server.port!, base: `http://127.0.0.1:${server.port}`, remotePorts, stop: () => server.stop(true) };
}

/** A fake AI Gateway, so a run that starts on the default provider's catalog stays local. */
function serveGateway() {
  const gateway = serveLocal(async (request, path) => {
    if (path === "/coding-agent/v1/models") return Response.json({ data: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    if (request.method !== "POST") return new Response("not found", { status: 404 });
    await request.text();
    return new Response("data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  });
  return { ...gateway, env: { FX_GATEWAY_BASE_URL: gateway.base, FX_GATEWAY_CHAT_URL: `${gateway.base}/v4/ai/language-model` } };
}

async function closedPort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as net.AddressInfo).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  return port;
}

function profile(root: string, name: string, baseUrl: string): string {
  const home = mkdtempSync(join(root, `${name}-`));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "custom",
    auto_upgrade: false,
    permission_mode: "ask",
    providers: {
      custom: {
        protocol: "openai-chat-completions",
        base_url: baseUrl,
        auth: { type: "none" },
        model_metadata: { "custom-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
      },
    },
    models: { custom: "custom-model" },
  }), { mode: 0o600 });
  return home;
}

const customAsk = ["ask", "--provider", "custom", "--model", "custom-model", "--no-save", "hi"];

/** Runs fx with exactly `env`; `until` sees the stderr so far and stops the run once it holds. */
async function runFx(env: Record<string, string>, until: ((stderr: string) => boolean) | null, timeoutMs: number, argv: string[] = customAsk): Promise<Run> {
  const started = performance.now();
  const child = Bun.spawn([fxBin(), ...argv], {
    cwd: env.HOME, env, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const out = { stdout: "", stderr: "" };
  const pump = async (stream: ReadableStream<Uint8Array>, key: "stdout" | "stderr") => {
    const decoder = new TextDecoder();
    const reader = stream.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      out[key] += decoder.decode(value, { stream: true });
    }
  };
  const pumps = Promise.all([pump(child.stdout, "stdout"), pump(child.stderr, "stderr")]);
  const timer = setTimeout(() => child.kill(), timeoutMs);
  const poll = until ? setInterval(() => {
    if (!until(out.stderr)) return;
    clearInterval(poll);
    setTimeout(() => child.kill(), 500);
  }, 50) : undefined;
  const code = await child.exited;
  await pumps;
  clearTimeout(timer);
  if (poll) clearInterval(poll);
  return { code: child.signalCode ? null : code, stdout: out.stdout, stderr: out.stderr, ms: performance.now() - started };
}

function environment(home: string, gatewayEnv: Record<string, string>, extra: Record<string, string>): Record<string, string> {
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
    AI_GATEWAY_API_KEY: "fake-net-proxy-driver-key",
    ...gatewayEnv,
    ...extra,
  };
}

/** The retry notices: the status lines fx prints while it waits, and a line that has lost its cause to a long note. */
const retryNotices = (stderr: string) =>
  stderr.split("\n").filter(line => /^\[notice\] (Offline|Connection lost|Gateway error|Unreadable reply|Rate limited|could not connect|proxy )/.test(line));

type ConnObservation = { target: string; answer: string; phase: string; shown: string; notice: string };
type EnvObservation = { cls: string; accepted: boolean; reason: string };
type CallerObservation = { caller: string; proxy: string; cause: string; text: string };

async function observeConnection(root: string, scenario: Connection): Promise<{ observation: ConnObservation; evidence: string }> {
  const gateway = serveGateway();
  const provider = serveLocal(() => completion("custom-model", "NET_PROXY_DRIVER_OK"));
  const dead = scenario.proxy === "down" ? await closedPort() : 0;
  const proxy = scenario.proxy === "down" ? null : await startConnectProxy(scenario.proxy);
  const port = proxy ? proxy.port : dead;
  try {
    const home = profile(root, "conn", scenario.completes ? `${provider.base}/v1` : `https://${TARGET}/v1`);
    const env = environment(home, gateway.env, {
      HTTPS_PROXY: scenario.host ? `http://${scenario.host}:3128` : `http://127.0.0.1:${port}`,
      ...(scenario.completes ? { FX_TEST_NET_PROXY_LOOPBACK: "1" } : {}),
    });
    const run = await runFx(env, scenario.retried ? stderr => stderr.includes("retrying") : null, 30_000);
    const sentence = scenario.sentence ? scenario.sentence(port) : null;
    const through = provider.remotePorts.length > 0 && proxy !== null && provider.remotePorts.every(p => proxy.upstreamPorts.has(p));
    const phase = scenario.completes && run.code === 0 && run.stdout.includes("NET_PROXY_DRIVER_OK") && through ? "sent" : "failed";
    // A line names the proxy when it carries the scenario's sentence, or, for
    // a scenario with none, when it says which proxy it means.
    const mark = scenario.host ? `proxy ${scenario.host.slice(0, 12)}` : `proxy 127.0.0.1:${port}`;
    const names = (line: string) => (sentence !== null ? line.includes(sentence) : line.includes(mark));
    // A retry notice names the proxy and keeps its wait part, or has lost it.
    const keepsWait = (line: string) => /next try in|retrying/.test(line);
    const notices = retryNotices(run.stderr);
    const notice = notices.length === 0 ? "unread"
      : !notices.every(line => line.includes(mark)) ? "generic"
      : notices.every(keepsWait) ? "proxy" : "proxy_cut";
    const ended = run.code === 1;
    const errors = run.stderr.split("\n").filter(line => line.startsWith("fx: "));
    const shown = !ended ? "unread" : errors.some(names) ? "proxy" : "none";
    return {
      observation: { target: "routed", answer: scenario.answer, phase, shown, notice },
      evidence: `exit ${run.code} after ${Math.round(run.ms)} ms; notices ${notices.length}; stderr ${JSON.stringify(run.stderr.slice(-300))}`,
    };
  } finally {
    proxy?.close();
    provider.stop();
    gateway.stop();
  }
}

async function observeHostClass(root: string, hostClass: HostClass): Promise<{ observation: EnvObservation; evidence: string }> {
  const gateway = serveGateway();
  try {
    const home = profile(root, "env", `https://${TARGET}/v1`);
    const run = await runFx(environment(home, gateway.env, { HTTPS_PROXY: hostClass.url }),
      stderr => /\[notice\] (Offline|Connection lost)|fx: HTTPS_PROXY/.test(stderr), 20_000);
    // fx took the URL when it went on to connect and retry, and refused it
    // when it ended the run with a message about the variable.
    const refusal = /fx: HTTPS_PROXY (.*)/.exec(run.stderr)?.[1] ?? "";
    const accepted = refusal === "" && /\[notice\] (Offline|Connection lost)/.test(run.stderr);
    const reason = accepted ? "none"
      : /^has no host name/.test(refusal) ? "no_host"
      : /^has a host name fx cannot use/.test(refusal) ? "bad_host"
      : /^has a port fx cannot use/.test(refusal) ? "bad_port"
      : /^is not a proxy URL fx can read/.test(refusal) ? "unreadable"
      : "unknown";
    return {
      observation: { cls: hostClass.cls, accepted, reason },
      evidence: `exit ${run.code} after ${Math.round(run.ms)} ms; stderr ${JSON.stringify(run.stderr.slice(-300))}`,
    };
  } finally {
    gateway.stop();
  }
}

/** A profile with a valid Grok sign-in, so `fx ask` goes straight to its version lookup. */
function grokProfile(root: string, name: string): string {
  const home = mkdtempSync(join(root, `${name}-`));
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ auto_upgrade: false, permission_mode: "ask" }), { mode: 0o600 });
  writeFileSync(join(home, ".fx", "grok-auth.json"), JSON.stringify({
    version: 1,
    access_token: "grok-fresh",
    refresh_token: "grok-refresh",
    expires_at_ms: Date.now() + 3_600_000,
    account_id: "acct_net_proxy_driver",
  }) + "\n", { mode: 0o600 });
  return home;
}

async function observeCaller(root: string, scenario: CallerScenario): Promise<{ observation: CallerObservation; evidence: string }> {
  // The server the caller talks to. A Grok version lookup fails with a 500; fx
  // upgrade finds a latest version and no archive, so its download fails.
  const server = scenario.caller === "version"
    ? serveLocal(() => new Response("no release", { status: 500 }))
    : serveLocal((_request, path) => (path === "/latest.txt" ? new Response("9.9.9\n") : new Response("missing", { status: 404 })));
  const dead = scenario.via === "down" ? await closedPort() : 0;
  const proxy = scenario.via === "refuses" ? await startConnectProxy({ status: 407 })
    : scenario.via === "refuses_after_first" ? await startConnectProxy({ refuseAfter: 1 })
    : scenario.via === "works" ? await startConnectProxy()
    : null;
  const port = proxy ? proxy.port : dead;
  try {
    const routed = scenario.via !== "none"
      ? { HTTPS_PROXY: `http://127.0.0.1:${port}`, FX_TEST_NET_PROXY_LOOPBACK: "1" }
      : {};
    const home = scenario.caller === "version" ? grokProfile(root, "caller-version") : profile(root, "caller-upgrade", "http://127.0.0.1:9/v1");
    const env = scenario.caller === "version"
      ? environment(home, {}, {
        FX_PROVIDER: "grok",
        FX_MODEL: "grok-4.20",
        // Every Grok endpoint is the local server, so nothing can leave the machine.
        FX_TEST_GROK_VERSION_URL: `${server.base}/version`,
        FX_TEST_XAI_GROK_RESPONSES_URL: `${server.base}/responses`,
        FX_TEST_XAI_GROK_MODELS_URL: `${server.base}/models`,
        FX_TEST_XAI_GROK_MODALITIES_URL: `${server.base}/modalities`,
        FX_TEST_GROK_TOKEN_URL: `${server.base}/token`,
        FX_TEST_GROK_USERINFO_URL: `${server.base}/userinfo`,
        ...routed,
      })
      : environment(home, {}, { FX_TEST_UPGRADE_BASE_URL: server.base, ...routed });
    delete env.AI_GATEWAY_API_KEY;
    const run = await runFx(env, null, 40_000, scenario.caller === "version" ? ["ask", "--no-save", "hi"] : ["upgrade"]);
    // The text the run ended with: an error line on stderr for fx ask, the
    // error on stdout for fx upgrade.
    const shown = scenario.caller === "version"
      ? run.stderr.split("\n").filter(line => line.startsWith("fx: ")).join("\n")
      : run.stdout.split("\n").filter(line => line.startsWith("error: ")).join("\n");
    // What each caller said before it took the proxy's sentence: fixed text.
    const fixed = scenario.caller === "version"
      ? ["fx: provider version unavailable"]
      : ["error: failed to fetch latest version from CDN", "error: failed to download release archive", "error: failed to fetch checksum from CDN"];
    const namesProxy = proxy !== null || scenario.via === "down"
      ? shown.includes(`proxy 127.0.0.1:${port}`)
      : false;
    // "proxy" when the text names the proxy; "default" only when it is exactly
    // one of the caller's fixed texts; anything else is not a run the model
    // describes.
    const text = ended(run) && namesProxy ? "proxy" : ended(run) && fixed.includes(shown) ? "default" : "unread";
    return {
      observation: { caller: scenario.caller, proxy: scenario.proxy, cause: scenario.cause, text },
      evidence: `exit ${run.code} after ${Math.round(run.ms)} ms; shown ${JSON.stringify(shown)}; stderr ${JSON.stringify(run.stderr.slice(-200))}`,
    };
  } finally {
    proxy?.close();
    server.stop();
  }
}

/** The run ended on its own with a failure, rather than succeeding or being killed. */
const ended = (run: Run) => run.code === 1;

const quote = (value: string) => JSON.stringify(value);

function cfg(constants: Record<string, string>, extra: string[]): string {
  return ["INIT Init", "NEXT Next", "CONSTANTS", ...Object.entries(constants).map(([k, v]) => `    ${k} = ${v}`),
    "INVARIANT NotObserved", ...extra, "CHECK_DEADLOCK FALSE", ""].join("\n");
}

async function trace(dir: string, module: "NetProxyTrace" | "NetProxyEnvTrace" | "NetProxyCallersTrace", observedModule: string, observed: string, constants: Record<string, string>): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${observedModule}.tla`), [
    `---- MODULE ${observedModule} ----`,
    "(* Generated by tests/tla/drivers/net_proxy/binary.ts. Do not edit. *)",
    observed,
    "====",
    "",
  ].join("\n"));
  writeFileSync(join(dir, "trace.cfg"), cfg(constants, []));
  const base = module === "NetProxyTrace" ? ["NetProxy.tla", "NetProxyTrace.tla"]
    : module === "NetProxyEnvTrace" ? ["NetProxyEnv.tla", "NetProxyEnvTrace.tla"]
    : ["NetProxyCallers.tla", "NetProxyCallersTrace.tla"];
  const run = await runTlc(dir, module, "trace.cfg", base, join(TLA_ROOT, "net_proxy"));
  if (run.violated === "NotObserved") return "ACCEPTED";
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return "REJECTED";
  return "TOOL_ERROR";
}

const connRecord = (o: ConnObservation) =>
  `Observed == [target |-> ${quote(o.target)}, answer |-> ${quote(o.answer)}, phase |-> ${quote(o.phase)}, shown |-> ${quote(o.shown)}, notice |-> ${quote(o.notice)}]`;
const callerRecord = (o: CallerObservation) =>
  `ObservedCallers == [caller |-> ${quote(o.caller)}, proxy |-> ${quote(o.proxy)}, cause |-> ${quote(o.cause)}, text |-> ${quote(o.text)}]`;
const envRecord = (o: EnvObservation) =>
  `ObservedEnv == [cls |-> ${quote(o.cls)}, accepted |-> ${o.accepted ? "TRUE" : "FALSE"}, reason |-> ${quote(o.reason)}]`;

/** Runs every scenario; returns whether every observation was accepted (and, with selfCheck, discriminated). */
export async function runBinaryScenarios(out: string, selfCheck: boolean): Promise<boolean> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-net-proxy-driver-")));
  let ok = true;
  const say = (message: string) => console.log(message);
  say(`binary: ${fxBin()}`);
  for (const [index, scenario] of connections.entries()) {
    const { observation, evidence } = await observeConnection(root, scenario);
    const dir = join(out, `binary-conn-${index}`);
    const longHost = { LongHost: scenario.host ? "TRUE" : "FALSE" };
    const verdict = await trace(join(dir, "design"), "NetProxyTrace", "NetProxyObserved", connRecord(observation), { ...DESIGN, ...longHost });
    say(`binary ${scenario.name}: ${JSON.stringify(observation)} -> design ${verdict}`);
    if (verdict !== "ACCEPTED") {
      say(`  evidence: ${evidence}`);
      ok = false;
    }
    if (selfCheck) {
      const first = await trace(join(dir, "first"), "NetProxyTrace", "NetProxyObserved", connRecord(observation), { ...FIRST, ...longHost });
      const want: Verdict = scenario.sameAsFirst ? "ACCEPTED" : "REJECTED";
      say(`  self-check: the connector as first written ${first} (must be ${want})`);
      if (first !== want) ok = false;
      const pushed = await trace(join(dir, "pushed"), "NetProxyTrace", "NetProxyObserved", connRecord(observation), { ...PUSHED, ...longHost });
      const wantPushed: Verdict = scenario.sameAsPushed ? "ACCEPTED" : "REJECTED";
      say(`  self-check: the connector before the short notice ${pushed} (must be ${wantPushed})`);
      if (pushed !== wantPushed) ok = false;
    }
  }
  for (const [index, hostClass] of hostClasses.entries()) {
    const { observation, evidence } = await observeHostClass(root, hostClass);
    const dir = join(out, `binary-env-${index}`);
    const verdict = await trace(join(dir, "design"), "NetProxyEnvTrace", "NetProxyEnvObserved", envRecord(observation), ENV_DESIGN);
    say(`binary proxy host ${hostClass.cls} (${hostClass.url}): ${JSON.stringify(observation)} -> design ${verdict}`);
    if (verdict !== "ACCEPTED") {
      say(`  evidence: ${evidence}`);
      ok = false;
    }
    if (selfCheck) {
      const first = await trace(join(dir, "first"), "NetProxyEnvTrace", "NetProxyEnvObserved", envRecord(observation), ENV_FIRST);
      const want: Verdict = hostClass.sameAsFirst ? "ACCEPTED" : "REJECTED";
      say(`  self-check: the connector as first written ${first} (must be ${want})`);
      if (first !== want) ok = false;
    }
  }
  for (const [index, scenario] of callerScenarios.entries()) {
    const { observation, evidence } = await observeCaller(root, scenario);
    const dir = join(out, `binary-caller-${index}`);
    const verdict = await trace(join(dir, "design"), "NetProxyCallersTrace", "NetProxyCallersObserved", callerRecord(observation), CALLERS_DESIGN);
    say(`binary ${scenario.name}: ${JSON.stringify(observation)} -> design ${verdict}`);
    if (verdict !== "ACCEPTED") {
      say(`  evidence: ${evidence}`);
      ok = false;
    }
    if (selfCheck) {
      const head = await trace(join(dir, "head"), "NetProxyCallersTrace", "NetProxyCallersObserved", callerRecord(observation), CALLERS_HEAD);
      const want: Verdict = scenario.sameAsHead ? "ACCEPTED" : "REJECTED";
      say(`  self-check: fx before the callers took the proxy's sentence ${head} (must be ${want})`);
      if (head !== want) ok = false;
    }
  }
  return ok;
}
