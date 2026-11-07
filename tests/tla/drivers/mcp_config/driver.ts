// Runs the built fx binary along tests/tla/mcp_config/ProfileLoad.tla and has
// TLC check every run it observes (ProfileLoadTrace.tla).
//
// Each case is one profile mcp.json. The driver reads it two ways: with
// `fx mcp list --json` (the CLI, as the TUI reads it) and with an ACP session
// that sets _meta.fx.profileMcpServers and sends one prompt. For each it
// records which entries fx ran and which it named as skipped: the servers in
// the JSON and the stderr notes, and the servers listed in the first model
// request and the "ACP profile MCP config skipped" trace lines. Entries are
// URLs of every form the URL rule tells apart, a stdio server, and entries fx
// can't read for other reasons. The cases are each entry alone, every
// bad-and-good pair of a few, the profile from issue #1218, and --random
// seeded files of two to five entries.
//
// Each entry's kind comes from the driver's own reading of its URL, not from
// fx. TLC replays the runs through the model of the fix (--model fix, the
// default) or of fx before it (--model before); --self-check also requires
// the other model to reject them. Every fx process runs through `env -i` with
// a temporary profile, FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, and a local fake
// gateway whose request count is checked.
//
// Other modes, which TLC does not check:
//   --stress N   one profile of N entries, half of them bad, through both
//                surfaces; checks the counts and prints the wall times
//   --faults     a profile that is a folder, a symlink loop, not JSON, or has
//                "mcp" as an array; and http://localhost/mcp with nothing on
//                port 80 beside a working stdio server
//   --crash      SIGKILL fx acp while a profile server runs, then start again
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/mcp_config/driver.ts
//   bun tests/tla/drivers/mcp_config/driver.ts --self-check --random 40 --seed 7
//   bun tests/tla/drivers/mcp_config/driver.ts --model before   # fx before the fix
//   bun tests/tla/drivers/mcp_config/driver.ts --stress 1000
//
// Exit codes: 0 every run accepted (or the mode's checks held), 1 a run the
// model cannot produce or a failed check, 2 a toolchain or harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers } from "../lib/context";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Scheme = "https" | "http" | "other" | "stdio" | "broken";
type Kind = { scheme: Scheme; host: "loopback" | "remote" | "none"; port: boolean; extra: boolean };
type Entry = { label: string; config: unknown; kind: Kind };
type Surface = "cli" | "acp";
type Observation = {
  id: string;
  labels: string[];
  file: Kind[];
  loaded: Record<Surface, number[]>;
  noted: Record<Surface, number[]>;
  evidence: Record<string, unknown>;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const FIXTURE = join(REPO_ROOT, "tests", "e2e", "fixtures", "mcp-modern-stdio.mjs");
const tlaDir = join(TLA_ROOT, "mcp_config");
const MODELS = {
  fix: { PortRule: "loopback", AcpSkips: "TRUE" },
  before: { PortRule: "required", AcpSkips: "FALSE" },
} as const;

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function modelOption(): keyof typeof MODELS {
  const at = process.argv.indexOf("--model");
  const value = at < 0 ? "fix" : process.argv[at + 1];
  if (value !== "fix" && value !== "before") throw new Error("--model takes fix or before");
  return value;
}

const options = {
  model: modelOption(),
  selfCheck: process.argv.includes("--self-check"),
  random: option("--random", 20),
  seed: option("--seed", 1),
  jobs: option("--jobs", 6),
  stress: option("--stress", 0),
  faults: process.argv.includes("--faults"),
  crash: process.argv.includes("--crash"),
};

// The driver's own reading of a server URL: the parts fx's rule looks at.
// fx takes 127.0.0.1, localhost in any case, and [::1] as loopback, and no
// other spelling.
function kindOf(url: string): Kind {
  const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^#]*)(#.*)?$/.exec(url);
  if (!match) throw new Error(`driver cannot read ${url}`);
  const scheme = match[1]!.toLowerCase();
  const authority = match[2]!;
  const at = authority.lastIndexOf("@");
  const hostPort = at < 0 ? authority : authority.slice(at + 1);
  let host = hostPort;
  let rest = "";
  if (hostPort.startsWith("[")) {
    const close = hostPort.indexOf("]");
    host = hostPort.slice(0, close + 1);
    rest = hostPort.slice(close + 1);
  } else if (hostPort.includes(":")) {
    host = hostPort.slice(0, hostPort.indexOf(":"));
    rest = hostPort.slice(hostPort.indexOf(":"));
  }
  if (rest !== "" && !/^:\d+$/.test(rest)) throw new Error(`driver cannot read the port of ${url}`);
  return {
    scheme: scheme === "https" ? "https" : scheme === "http" ? "http" : "other",
    host: ["localhost", "127.0.0.1", "[::1]"].includes(host.toLowerCase()) ? "loopback" : "remote",
    port: rest !== "",
    extra: at >= 0 || match[4] !== undefined,
  };
}

const local = (scheme: "stdio" | "broken"): Kind => ({ scheme, host: "none", port: false, extra: false });

const URLS = [
  "https://mcp.example.invalid/mcp",
  "https://mcp.example.invalid:8443/mcp",
  "https://localhost/mcp",
  "https://user@mcp.example.invalid/mcp",
  "http://localhost/mcp",
  "http://127.0.0.1/mcp",
  "http://[::1]/mcp",
  "HTTP://LOCALHOST/mcp",
  "http://localhost:4321/mcp",
  "http://[::1]:4321/mcp",
  "http://user@localhost/mcp",
  "http://localhost/mcp#part",
  "http://example.com/mcp",
  "http://example.com:8080/mcp",
  "http://localhost.example.com/mcp",
  "http://127.0.0.2/mcp",
  "ftp://localhost/mcp",
  "ws://localhost:4321/mcp",
];

const ENTRIES: Entry[] = [
  ...URLS.map((url) => ({ label: url, config: { type: "http", url }, kind: kindOf(url) })),
  { label: "stdio", config: { type: "local", command: [process.execPath, FIXTURE] }, kind: local("stdio") },
  { label: "no command", config: { type: "local" }, kind: local("broken") },
  { label: "bad type", config: { type: "pigeon", url: "https://mcp.example.invalid/mcp" }, kind: local("broken") },
  { label: "not an object", config: 7, kind: local("broken") },
];
const entry = (label: string) => ENTRIES.find((candidate) => candidate.label === label)!;

// mulberry32: a small seeded generator, so a failing random file replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function cases(): Entry[][] {
  const result: Entry[][] = ENTRIES.map((one) => [one]);
  const bad = ["http://example.com/mcp", "http://example.com:8080/mcp", "http://localhost/mcp#part", "no command"].map(entry);
  const good = ["stdio", "http://localhost/mcp", "https://mcp.example.invalid/mcp"].map(entry);
  for (const b of bad) for (const g of good) result.push([b, g], [g, b]);
  // Issue #1218's profile, remote host changed to one that can't resolve.
  result.push([entry("https://mcp.example.invalid/mcp"), entry("http://localhost/mcp")]);
  const random = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    const size = 2 + Math.floor(random() * 4);
    result.push(Array.from({ length: size }, () => ENTRIES[Math.floor(random() * ENTRIES.length)]!));
  }
  return result;
}

type Root = { root: string; home: string; fxHome: string; workspace: string; trace: string };

function makeRoot(parent: string, id: string): Root {
  const root = realpathSync(mkdtempSync(join(parent, `${id}-`)));
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const workspace = join(root, "workspace");
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  writeFileSync(join(fxHome, "settings.json"), "{}");
  return { root, home, fxHome, workspace, trace: join(root, "trace.log") };
}

function writeProfile(root: Root, entries: Entry[]) {
  const servers: Record<string, unknown> = {};
  entries.forEach((one, index) => { servers[`s${index + 1}`] = one.config; });
  writeFileSync(join(root.fxHome, "mcp.json"), JSON.stringify({ mcp: servers }));
}

// Every variable on env's command line, so nothing leaks in from this shell.
function envArgv(root: Root, gateway: { baseUrl: string; chatUrl: string }, extra: string[] = []): string[] {
  return [
    "env", "-i",
    `HOME=${root.home}`,
    "PATH=/usr/bin:/bin",
    `FX_HOME=${root.fxHome}`,
    "FX_DISABLE_KEYCHAIN=1",
    "FX_SOUND=0",
    "FX_AUTO_UPGRADE=0",
    "FX_E2E_DISABLE_DOTENV=1",
    "NO_COLOR=1",
    `FX_GATEWAY_BASE_URL=${gateway.baseUrl}`,
    `FX_GATEWAY_CHAT_URL=${gateway.chatUrl}`,
    "FX_MODEL=openai/gpt-5",
    "AI_GATEWAY_API_KEY=fake-mcp-config-key",
    ...extra,
  ];
}

const serverIndex = (name: string) => /^s(\d+)$/.exec(name) ? Number(name.slice(1)) : -1;
const sortedUnique = (values: number[]) => [...new Set(values)].sort((a, b) => a - b);

async function listCli(helpers: any, root: Root, args: string[] = ["mcp", "list", "--json"]) {
  const gateway = helpers.startFakeGateway([]);
  try {
    const child = Bun.spawn([...envArgv(root, gateway), binary, ...args], {
      cwd: root.workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), 20_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    clearTimeout(timer);
    return { stdout, stderr, exit, gatewayRequests: gateway.requestCount() };
  } finally {
    gateway.stop();
  }
}

class Acp {
  private buffer = "";
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  readonly child: ReturnType<typeof Bun.spawn>;
  private nextId = 1;

  constructor(argv: string[], cwd: string) {
    this.child = Bun.spawn(argv, { cwd, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    this.reader = (this.child.stdout as ReadableStream<Uint8Array>).getReader();
  }

  async request(method: string, params: unknown, timeoutMs = 20_000): Promise<any> {
    const id = this.nextId++;
    const stdin = this.child.stdin as import("bun").FileSink;
    stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    stdin.flush();
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        if (!line.trim()) continue;
        const message = JSON.parse(line);
        if (message.id === id && ("result" in message || "error" in message)) return message;
        continue;
      }
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`fx acp did not answer ${method}`);
      const chunk = await Promise.race([
        this.reader.read(),
        new Promise<null>((resolve) => setTimeout(() => resolve(null), left)),
      ]);
      if (chunk === null) throw new Error(`fx acp did not answer ${method}`);
      if (chunk.done) throw new Error(`fx acp closed before answering ${method}`);
      this.buffer += new TextDecoder().decode(chunk.value);
    }
  }

  async close(): Promise<string> {
    (this.child.stdin as import("bun").FileSink).end();
    const timer = setTimeout(() => this.child.kill("SIGKILL"), 10_000);
    await this.child.exited;
    clearTimeout(timer);
    return await new Response(this.child.stderr as ReadableStream).text();
  }
}

// The text of every message in a model request, so the catalog can be read.
function requestText(body: string): string {
  const strings: string[] = [];
  const walk = (value: unknown) => {
    if (typeof value === "string") strings.push(value);
    else if (Array.isArray(value)) value.forEach(walk);
    else if (value && typeof value === "object") Object.values(value).forEach(walk);
  };
  walk(JSON.parse(body));
  return strings.join("\n");
}

async function openAcp(helpers: any, root: Root, responses: unknown[]) {
  const gateway = responses.length > 0
    ? helpers.startFakeGateway(responses)
    : helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("done"));
  const acp = new Acp(
    [...envArgv(root, gateway, [`FX_TRACE_LOG=${root.trace}`, "FX_TRACE_SCOPES=mcp"]), binary, "acp"],
    root.workspace,
  );
  await acp.request("initialize", { protocolVersion: 1 });
  const created = await acp.request("session/new", {
    cwd: root.workspace,
    mcpServers: [],
    _meta: { fx: { profileMcpServers: true } },
  });
  if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
  return { gateway, acp, sessionId: created.result.sessionId as string };
}

async function runAcp(helpers: any, root: Root) {
  const { gateway, acp, sessionId } = await openAcp(helpers, root, []);
  try {
    const prompted = await acp.request("session/prompt", { sessionId, prompt: [{ type: "text", text: "hi" }] }, 60_000);
    const stderr = await acp.close();
    const text = gateway.requests[0] ? requestText(gateway.requests[0].body) : "";
    const trace = existsSync(root.trace) ? readFileSync(root.trace, "utf8") : "";
    return {
      stopReason: prompted.result?.stopReason ?? null,
      listed: [...text.matchAll(/<server name="([^"]+)"/g)].map((m) => m[1]!),
      omitted: Number(/<catalog_truncated omitted_count="(\d+)"/.exec(text)?.[1] ?? 0),
      skippedLines: [...trace.matchAll(/ACP profile MCP config skipped [^\n]*server=(\S+)/g)].map((m) => m[1]!),
      requestedCount: Number(/ACP profile MCP servers requested count=(\d+)/.exec(trace)?.[1] ?? -1),
      unavailable: /ACP profile MCP servers unavailable[^\n]*/.exec(trace)?.[0] ?? null,
      gatewayRequests: gateway.requestCount(),
      stderr,
    };
  } finally {
    acp.child.kill("SIGKILL");
    gateway.stop();
  }
}

async function observe(helpers: any, parent: string, id: string, entries: Entry[]): Promise<Observation> {
  const root = makeRoot(parent, id);
  try {
    writeProfile(root, entries);
    const cli = await listCli(helpers, root);
    if (cli.exit !== 0) throw new Error(`${id}: fx mcp list exited ${cli.exit}: ${cli.stderr}`);
    if (cli.gatewayRequests !== 0) throw new Error(`${id}: fx mcp list sent ${cli.gatewayRequests} model requests, expected 0`);
    const cliLoaded = (JSON.parse(cli.stdout).servers as Array<{ name: string }>).map((s) => serverIndex(s.name));
    const cliNoted = [...cli.stderr.matchAll(/server '([^']+)' was skipped/g)].map((m) => serverIndex(m[1]!));
    const acp = await runAcp(helpers, root);
    if (acp.gatewayRequests !== 1) throw new Error(`${id}: fx acp sent ${acp.gatewayRequests} model requests, expected 1`);
    if (acp.stopReason !== "end_turn") throw new Error(`${id}: fx acp turn ended ${acp.stopReason}`);
    if (acp.omitted !== 0) throw new Error(`${id}: the catalog left out ${acp.omitted} servers`);
    return {
      id,
      labels: entries.map((one) => one.label),
      file: entries.map((one) => one.kind),
      loaded: { cli: sortedUnique(cliLoaded), acp: sortedUnique(acp.listed.map(serverIndex)) },
      noted: { cli: sortedUnique(cliNoted), acp: sortedUnique(acp.skippedLines.map(serverIndex)) },
      evidence: { cli_stderr: cli.stderr, acp_unavailable: acp.unavailable, acp_stderr: acp.stderr },
    };
  } finally {
    rmSync(root.root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const set = (values: number[]) => `{${values.join(", ")}}`;
const kindValue = (k: Kind) =>
  `[scheme |-> ${str(k.scheme)}, host |-> ${str(k.host)}, port |-> ${k.port ? "TRUE" : "FALSE"}, extra |-> ${k.extra ? "TRUE" : "FALSE"}]`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[file |-> <<${o.file.map(kindValue).join(", ")}>>,\n   ` +
    `loaded |-> [cli |-> ${set(o.loaded.cli)}, acp |-> ${set(o.loaded.acp)}],\n   ` +
    `noted |-> [cli |-> ${set(o.noted.cli)}, acp |-> ${set(o.noted.acp)}]]`;
  return [
    "---- MODULE ProfileLoadObserved ----",
    "\\* Generated by tests/tla/drivers/mcp_config/driver.ts. Do not edit.",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "====",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], model: keyof typeof MODELS, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${model}-`));
  writeFileSync(join(dir, "ProfileLoadObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "  N = 0",
    `  PortRule = ${str(MODELS[model].PortRule)}`,
    `  AcpSkips = ${MODELS[model].AcpSkips}`,
    "  Mutation = \"none\"",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "ProfileLoadTrace.tla", "trace.cfg", ["ProfileLoad.tla", "ProfileLoadTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], model: keyof typeof MODELS, parent: string): Promise<Observation | null> {
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

async function trace(helpers: any, out: string): Promise<number> {
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const all = cases();
  const observations: Observation[] = new Array(all.length);
  const started = performance.now();
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < all.length) {
      const index = next++;
      observations[index] = await observe(helpers, scratch, `case${index}`, all[index]!);
    }
  }));
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  console.log(`${observations.length} profiles of ${binary}, each through fx mcp list and fx acp, in ${seconds}s (seed ${options.seed})`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const other = options.model === "fix" ? "before" : "fix";
  const result = await runTrace(observations, options.model, out);
  console.log(`model ${options.model}: ${result.verdict} (TLC work ${result.dir})`);
  if (result.verdict === "TOOL_ERROR") return 2;
  if (result.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, options.model, out);
    console.log(`first profile the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const check = await runTrace(observations, other, out);
    console.log(`self-check, model ${other}: ${check.verdict} (must be REJECTED)`);
    if (check.verdict !== "REJECTED") return check.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  console.log("ACCEPTED");
  return 0;
}

function check(failures: string[], ok: boolean, what: string) {
  console.log(`${ok ? "ok  " : "FAIL"}  ${what}`);
  if (!ok) failures.push(what);
}

async function stress(helpers: any, out: string, n: number): Promise<number> {
  const failures: string[] = [];
  const pattern = ["http://example.com/mcp", "stdio", "http://localhost/mcp", "no command"].map(entry);
  const entries = Array.from({ length: n }, (_, i) => pattern[i % pattern.length]!);
  const good = entries.filter((one) => one.kind.scheme === "stdio" || one.kind.host === "loopback").length;
  const root = makeRoot(out, "stress");
  writeProfile(root, entries);
  let started = performance.now();
  const cli = await listCli(helpers, root);
  const cliSeconds = ((performance.now() - started) / 1000).toFixed(2);
  const cliLoaded = cli.exit === 0 ? JSON.parse(cli.stdout).servers.length : -1;
  const cliNoted = [...cli.stderr.matchAll(/was skipped/g)].length;
  check(failures, cli.exit === 0 && cli.gatewayRequests === 0, `fx mcp list exit ${cli.exit}, ${cli.gatewayRequests} model requests (${cliSeconds}s)`);
  check(failures, cliLoaded === good, `fx mcp list ran ${cliLoaded} of ${n} entries, expected ${good}`);
  check(failures, cliNoted === n - good, `fx mcp list noted ${cliNoted} skipped, expected ${n - good}`);
  started = performance.now();
  const acp = await runAcp(helpers, root);
  const acpSeconds = ((performance.now() - started) / 1000).toFixed(2);
  check(failures, acp.gatewayRequests === 1 && acp.stopReason === "end_turn", `fx acp turn ${acp.stopReason}, ${acp.gatewayRequests} model requests (${acpSeconds}s)`);
  check(failures, acp.requestedCount === good, `fx acp loaded ${acp.requestedCount} profile servers, expected ${good}`);
  check(failures, acp.listed.length + acp.omitted === good, `the catalog listed ${acp.listed.length} and left out ${acp.omitted}, expected ${good} in all`);
  check(failures, acp.skippedLines.length === n - good, `fx acp logged ${acp.skippedLines.length} skipped, expected ${n - good}`);
  check(failures, acp.stderr === "", `fx acp stderr empty (${JSON.stringify(acp.stderr.slice(0, 200))})`);
  rmSync(root.root, { recursive: true, force: true });
  console.log(failures.length === 0 ? `stress ${n}: every check held` : `stress ${n}: ${failures.length} checks failed`);
  return failures.length === 0 ? 0 : 1;
}

async function faults(helpers: any, out: string): Promise<number> {
  const failures: string[] = [];
  const unreadable: Array<[string, (root: Root) => void]> = [
    ["a folder", (root) => mkdirSync(join(root.fxHome, "mcp.json"))],
    ["a symlink loop", (root) => symlinkSync(join(root.fxHome, "mcp.json"), join(root.fxHome, "mcp.json"))],
    ["not JSON", (root) => writeFileSync(join(root.fxHome, "mcp.json"), "{\"mcp\":")],
    ["mcp as an array", (root) => writeFileSync(join(root.fxHome, "mcp.json"), "{\"mcp\":[]}")],
  ];
  for (const [what, plant] of unreadable) {
    const root = makeRoot(out, "fault");
    plant(root);
    const cli = await listCli(helpers, root);
    check(failures, cli.exit !== 0 && cli.stderr.includes("mcp.json") && cli.gatewayRequests === 0,
      `profile ${what}: fx mcp list exits ${cli.exit} naming the file: ${JSON.stringify(cli.stderr.trim().slice(0, 160))}`);
    const acp = await runAcp(helpers, root);
    check(failures, acp.stopReason === "end_turn" && acp.listed.length === 0 && acp.unavailable !== null && acp.stderr === "",
      `profile ${what}: the ACP session still runs, with no profile server and ${JSON.stringify(acp.unavailable)}`);
    rmSync(root.root, { recursive: true, force: true });
  }

  // Nothing listens on port 80, so http://localhost/mcp fails to start; the
  // stdio server beside it still works.
  const root = makeRoot(out, "fault-port80");
  writeProfile(root, [entry("http://localhost/mcp"), entry("stdio")]);
  const refused = await listCli(helpers, root, ["mcp", "show", "s1"]);
  check(failures, refused.exit === 1 && refused.gatewayRequests === 0 && !refused.stderr.includes("isn't valid"),
    `fx mcp show s1 (http://localhost/mcp, nothing on port 80) exits ${refused.exit}: ${JSON.stringify((refused.stdout + refused.stderr).trim().slice(0, 300))}`);
  const working = await listCli(helpers, root, ["mcp", "show", "s2"]);
  check(failures, working.exit === 0 && /status +ready/.test(working.stdout),
    `fx mcp show s2 (stdio beside it) exits ${working.exit} and is ready`);
  rmSync(root.root, { recursive: true, force: true });
  console.log(failures.length === 0 ? "faults: every check held" : `faults: ${failures.length} checks failed`);
  return failures.length === 0 ? 0 : 1;
}

async function crash(helpers: any, out: string): Promise<number> {
  const failures: string[] = [];
  const root = makeRoot(out, "crash");
  const pidPath = join(root.root, "good.pid");
  writeFileSync(join(root.fxHome, "mcp.json"), JSON.stringify({
    mcp: {
      bad: { type: "http", url: "http://example.com/mcp" },
      good: { type: "local", command: [process.execPath, FIXTURE], environment: { FX_MCP_PID_PATH: pidPath } },
    },
  }));
  const before = readFileSync(join(root.fxHome, "mcp.json"));
  const first = await openAcp(helpers, root, [
    helpers.fakeGatewayToolCall("good_call", "mcp_good_echo", { text: "crash" }),
    helpers.fakeGatewayFinalText("done"),
  ]);
  await first.acp.request("session/set_mode", { sessionId: first.sessionId, modeId: "full-access" });
  const prompted = await first.acp.request("session/prompt", { sessionId: first.sessionId, prompt: [{ type: "text", text: "use good" }] }, 60_000);
  check(failures, prompted.result?.stopReason === "end_turn" && existsSync(pidPath), `the good server ran before the kill (pid file ${existsSync(pidPath)})`);
  const serverPid = existsSync(pidPath) ? Number(readFileSync(pidPath, "utf8").trim()) : 0;
  first.acp.child.kill("SIGKILL");
  await first.acp.child.exited;
  first.gateway.stop();
  let alive = serverPid > 0;
  for (let i = 0; i < 50 && alive; i++) {
    try { process.kill(serverPid, 0); await Bun.sleep(100); } catch { alive = false; }
  }
  check(failures, !alive, `the good server (pid ${serverPid}) is gone within 5s of the kill`);
  check(failures, Buffer.compare(before, readFileSync(join(root.fxHome, "mcp.json"))) === 0, "~/.fx/mcp.json is byte for byte the same after the kill");
  const again = await runAcp(helpers, root);
  check(failures, again.listed.includes("good") && !again.listed.includes("bad") && again.skippedLines.includes("bad"),
    `after a restart the session lists ${JSON.stringify(again.listed)} and logs ${JSON.stringify(again.skippedLines)} as skipped`);
  rmSync(root.root, { recursive: true, force: true });
  console.log(failures.length === 0 ? "crash: every check held" : `crash: ${failures.length} checks failed`);
  return failures.length === 0 ? 0 : 1;
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("mcp_config");
  console.log(`binary: ${binary}`);
  if (options.stress > 0) return await stress(helpers, out, options.stress);
  if (options.faults) return await faults(helpers, out);
  if (options.crash) return await crash(helpers, out);
  return await trace(helpers, out);
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
