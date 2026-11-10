// Runs the built fx binary along tests/tla/tls_roots/TlsRoots.tla and has TLC
// check every run it observes (TlsRootsTrace.tla).
//
// Each run is one HTTPS client of fx under a macOS sandbox profile that denies
// reads of /Library/Keychains/System.keychain, alone or with the root
// certificates keychain and /etc/ssl/cert.pem. Two clients are driven: `fx ask`
// to a configured provider whose base URL is https, and `fx mcp show` for an
// MCP server whose URL is https. Both point at a local TLS server with a
// self-signed certificate, so fx must reject every handshake: a connection
// shows the roots loaded, and a request would show verification was off.
//
// For each run it records how the sandbox left the files, how the request
// ended ("tls" when the server saw a handshake, "failed" when fx stopped before
// it connected), and the roots fx's trace log says it loaded. Every trace line
// of the run must name the same roots. TLC replays the runs through the
// model's own actions. --self-check also replays them through the model of fx
// before the change (Rule = "today"), which must reject them. --stress N adds
// one `fx ask` run with N https MCP servers, each with a client of its own, and
// prints its wall time and peak memory.
//
// No run lets fx read /Library/Keychains/System.keychain. Every fx process
// gets FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, a temporary HOME, and local servers.
//
// Usage (from the repository root, after zig build, on macOS):
//   bun tests/tla/drivers/tls_roots/driver.ts
//   bun tests/tla/drivers/tls_roots/driver.ts --self-check
//   bun tests/tla/drivers/tls_roots/driver.ts --stress 200
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain or harness failure.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetModule, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type FileState = "ok" | "denied";
type Outcome = "tls" | "failed" | "unknown";
type Source = "keychain" | "public_bundle" | "none" | "mixed";
type Observation = {
  id: string;
  site: "ask" | "mcp";
  roots: FileState;
  system: FileState;
  pem: "roots" | "denied";
  outcome: Outcome;
  source: Source;
  evidence: { exit: number | null; stopped: boolean; stderr: string; counts: object; trace: string[]; seconds: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const LOAD_FAILURE = "couldn't load trusted certificates";
const tlaDir = join(TLA_ROOT, "tls_roots");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  stress: option("--stress", 0),
};

type Fixture = Awaited<ReturnType<typeof loadFixture>>;

async function loadFixture() {
  return await targetModule("fixtures/untrusted-tls.ts");
}

// The roots each trace line of the run names: src/core/shared/tls_roots.zig
// writes `event=roots_loaded source=<keychain|public_bundle>` or
// `event=roots_failed`.
function sourceOf(lines: string[]): Source {
  const named = new Set<Source>();
  for (const line of lines) {
    const loaded = /event=roots_loaded source=(keychain|public_bundle)\b/.exec(line);
    if (loaded) named.add(loaded[1] as Source);
    else if (line.includes("event=roots_failed")) named.add("none");
  }
  if (named.size === 0) return "none";
  return named.size === 1 ? [...named][0]! : "mixed";
}

async function runOne(
  fixture: Fixture,
  tls: any,
  out: string,
  id: string,
  site: "ask" | "mcp",
  denied: { roots: boolean; pem: boolean },
  mcpServers = 1,
): Promise<Observation> {
  const root = join(out, id);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: "local",
    auto_upgrade: false,
    permission_mode: "ask",
    providers: {
      local: {
        protocol: "openai-chat-completions",
        base_url: tls.url("/v1"),
        auth: { type: "none" },
        model_metadata: { m1: { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
      },
    },
    models: { local: "m1" },
  }), { mode: 0o600 });
  const servers: Record<string, object> = {};
  for (let n = 0; n < mcpServers; n++) {
    servers[n === 0 ? "fixture" : `fixture${n}`] = {
      type: "http", url: tls.url(`/mcp/${n}`), startup_timeout_ms: 3000, operation_timeout_ms: 3000,
    };
  }
  writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({ mcp: servers }), { mode: 0o600 });
  const deny = [fixture.SYSTEM_KEYCHAIN];
  if (denied.roots) deny.unshift(fixture.ROOT_KEYCHAIN);
  if (denied.pem) deny.push(fixture.PUBLIC_BUNDLE);
  const profile = fixture.denyProfile(root, "profile", deny);
  const trace = join(root, "trace.log");
  const env = testEnvironment({
    HOME: home,
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-tls-roots-driver-key",
    // Nothing should reach the AI Gateway; these keep it local if it did.
    FX_GATEWAY_BASE_URL: "http://127.0.0.1:9/",
    FX_GATEWAY_CHAT_URL: "http://127.0.0.1:9/v1/ai/language-model",
    FX_TEST_GATEWAY_CHAT_URL: "http://127.0.0.1:9/v1/ai/language-model",
    FX_TEST_GATEWAY_MODELS_URL: "http://127.0.0.1:9/v1/models",
    FX_TRACE_LOG: trace,
  });
  const before = { ...tls.counts };
  const args = site === "ask" ? ["ask", "--provider", "local", "--model", "m1", "--no-save", "hi"] : ["mcp", "show", "fixture"];
  const started = performance.now();
  const run = await fixture.runSandboxed(profile, binary, args, {
    cwd: workspace,
    env,
    timeoutMs: 60_000,
    // fx retries a refused handshake, so an ask run stops once every client
    // it started had time to reach the server.
    stopWhen: site === "ask"
      ? async () => (await tls.waitFor((c: any) => c.rejected >= before.rejected + mcpServers, 20_000)) && (await Bun.sleep(300), true)
      : undefined,
  });
  const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
  const after = { ...tls.counts };
  const lines = existsSync(trace) ? readFileSync(trace, "utf8").split("\n").filter((line) => line.includes("[tls]")) : [];
  const reached = after.connections > before.connections && after.rejected > before.rejected;
  let outcome: Outcome = "unknown";
  if (after.requests !== before.requests) outcome = "unknown"; // verification was off: no model state says so
  else if (reached) outcome = "tls";
  else if (site === "mcp" || run.stderr.includes(LOAD_FAILURE)) outcome = "failed";
  return {
    id,
    site,
    roots: denied.roots ? "denied" : "ok",
    system: "denied",
    pem: denied.pem ? "denied" : "roots",
    outcome,
    source: sourceOf(lines),
    evidence: {
      exit: run.code,
      stopped: run.stopped,
      stderr: run.stderr.slice(-300),
      counts: { connections: after.connections - before.connections, rejected: after.rejected - before.rejected, requests: after.requests - before.requests },
      trace: lines.slice(0, 6),
      seconds,
    },
  };
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[roots |-> ${str(o.roots)}, system |-> ${str(o.system)}, pem |-> ${str(o.pem)}, outcome |-> ${str(o.outcome)}, source |-> ${str(o.source)}]`;
  return [
    "--------------------------- MODULE TlsRootsObserved ---------------------------",
    "(* Generated by tests/tla/drivers/tls_roots/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = join(parent, `trace-${rule}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "TlsRootsObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "  OSes = {\"macos\"}",
    "  Sites = {\"run\"}",
    "  Skips = {}",
    "  Requests = {1}",
    `  Rule = ${str(rule)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const tlc = await runTlc(dir, "TlsRootsTrace.tla", "trace.cfg", ["TlsRoots.tla", "TlsRootsTrace.tla"], tlaDir);
  if (tlc.exitCode === 12 && tlc.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (tlc.exitCode === 0 && tlc.output.includes("No error has been found")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

async function main(): Promise<number> {
  const fixture = await loadFixture();
  if (!fixture.sandboxAvailable()) {
    console.log("TOOL_ERROR: this driver needs macOS with sandbox-exec and openssl");
    return 2;
  }
  const out = outDir("tls_roots");
  const tls = await fixture.startUntrustedTlsServer();
  const observations: Observation[] = [];
  const started = performance.now();
  try {
    let n = 0;
    for (const site of ["ask", "mcp"] as const) {
      for (const roots of [false, true]) {
        for (const pem of [false, true]) {
          // One run at a time, so each run's counts are its own.
          observations.push(await runOne(fixture, tls, out, `run${n++}-${site}`, site, { roots, pem }));
        }
      }
    }
    if (options.stress > 0) {
      const stress = await runOne(fixture, tls, out, `stress-${options.stress}`, "ask", { roots: false, pem: false }, options.stress);
      console.log(`stress: ${options.stress} https MCP servers and one provider in one fx ask: ` +
        `${JSON.stringify(stress.evidence.counts)} in ${stress.evidence.seconds}s, trace lines ${stress.evidence.trace.length}+, ` +
        `outcome ${stress.outcome}, roots ${stress.source}`);
      observations.push(stress);
    }
  } finally {
    tls.stop();
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  for (const o of observations) {
    console.log(`${o.id}: roots=${o.roots} system=${o.system} pem=${o.pem} -> ${o.outcome}, ${o.source} ${JSON.stringify(o.evidence.counts)}`);
  }
  console.log(`${observations.length} runs of ${binary} in ${seconds}s`);
  console.log(`observations: ${join(out, "observations.json")}`);
  const unknown = observations.find((o) => o.outcome === "unknown");
  if (unknown) {
    console.log(`REJECTED: run ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }
  const design = await runTrace(observations, "fixed", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    for (let k = 1; k <= observations.length; k++) {
      const prefix = await runTrace(observations.slice(0, k), "fixed", join(out, `prefix-${k}`));
      if (prefix.verdict === "REJECTED") {
        console.log(`first run the model cannot produce: ${JSON.stringify(observations[k - 1])}`);
        break;
      }
    }
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
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
