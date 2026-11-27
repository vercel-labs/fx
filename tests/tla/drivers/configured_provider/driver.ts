// Runs fx along the custom model connection models in
// tests/tla/configured_provider/ and has TLC check what it observes.
//
//   request    One `fx ask` per session against a local fake server, for every
//              shape of model metadata the model knows (declared levels and
//              their order, request fields, effort fields, an output limit,
//              the field that carries it), every configured effort, and a
//              script of replies: tool calls, a reply cut off by the output
//              limit, a final answer. The driver records what each request
//              carried and how many ignored-effort notices fx printed, and TLC
//              replays the sessions through ConfiguredRequest's own actions
//              (ConfiguredRequestTrace.tla).
//   catalog    One `fx models` per run, on one of two connections, with
//              fetch_models on or off and a server that lists its models,
//              refuses, or never answers. TLC replays the runs through
//              ConfiguredCatalog's actions (ConfiguredCatalogTrace.tla).
//   resume     A session saved on one connection, then the connection edited in
//              settings (its protocol, base_url, or auth, a field outside
//              those, or the whole connection removed), then resumed. The
//              driver records what fx sent and to which binding, and what it
//              said; TLC replays the runs through ConfiguredResume's actions
//              (ConfiguredResumeTrace.tla).
//   deadlines  Walks src/gateway/request_deadlines.zig along every edge of
//              ConfiguredDeadlines.tla's state graph, then seeded random
//              paths, through lab.zig, which owns the clock. After every step
//              the module's wait and its verdict on the deadline must match
//              the model's next state.
//   auth-walk  Walks the pure planner src/core/auth/command_token.zig along every
//              edge of ConfiguredAuth.tla's state graph, then seeded random paths,
//              through lab_auth.zig. After every step the planner's state (each
//              request's phase, reason, token, and refreshes, and each connection's
//              cache, runs, waiters, and generations) must match the model's next
//              state.
//   auth       Runs `fx ask` sessions with a command-auth helper (`fake-helper.ts`)
//              against a local fake server (fresh, revoked, refused twice, helper
//              exits non-zero, helper prints garbage, near-expiry, and helper hang
//              past fx's timeout) and has TLC replay each run's ordered log through
//              ConfiguredAuth.tla (`ConfiguredAuthTrace.tla`).
//
// --self-check also replays the observations through the model of fx before
// the change (Bug = "today"), which must reject them, expects a tampered
// expectation to be rejected, and plants bugs in a copy of
// request_deadlines.zig and command_token.zig, each of which the walks must catch.
// --stress N adds one session of N tool steps.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/configured_provider/driver.ts
//   bun tests/tla/drivers/configured_provider/driver.ts --self-check
//   bun tests/tla/drivers/configured_provider/driver.ts request --random 200 --seed 7 --jobs 8
//   bun tests/tla/drivers/configured_provider/driver.ts request --random 0 --stress 1000
//   bun tests/tla/drivers/configured_provider/driver.ts resume --self-check
//   bun tests/tla/drivers/configured_provider/driver.ts auth-walk --self-check
//   bun tests/tla/drivers/configured_provider/driver.ts auth --self-check
//
// Exit codes: 0 everything accepted (and every self-check rejected), 1 a run
// the model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { binary, targetModule, testEnvironment } from "../lib/context";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc, tlcToolchain, writeJson } from "../lib/tlc";

type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
const tlaDir = join(TLA_ROOT, "configured_provider");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const parts = ["request", "catalog", "resume", "deadlines", "auth-walk", "auth"].filter((part) => process.argv.includes(part));
const options = {
  parts: parts.length > 0 ? parts : ["request", "catalog", "resume", "deadlines", "auth-walk", "auth"],
  selfCheck: process.argv.includes("--self-check"),
  random: option("--random", 60),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
  stress: option("--stress", 0),
  walks: option("--walks", 300),
  steps: option("--steps", 14),
};

// mulberry32: a small seeded generator, so a failing random run replays.
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

const str = (value: string) => JSON.stringify(value);
const set = (values: string[]) => `{${values.map(str).join(", ")}}`;
const seq = (values: string[]) => `<<${values.join(", ")}>>`;

async function pool<T>(count: number, jobs: number, run: (index: number) => Promise<T>): Promise<T[]> {
  const results: T[] = new Array(count);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, jobs) }, async () => {
    while (next < count) {
      const index = next++;
      results[index] = await run(index);
    }
  }));
  return results;
}

// Replays `observed` through `trace` with TLC. ACCEPTED is the sentinel
// NotAllMatched being violated, which needs every observation to match.
async function runTrace(spec: string, observed: string, constants: string[], parent: string, label: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${label}-`));
  for (const file of [`${spec}.tla`, `${spec}Trace.tla`]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, `${spec}Observed.tla`), [
    `---- MODULE ${spec}Observed ----`,
    "(* Generated by tests/tla/drivers/configured_provider/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observed} >>`,
    "====",
    "",
  ].join("\n"));
  writeFileSync(join(dir, "trace.cfg"), ["SPECIFICATION TraceSpec", "CONSTANTS", ...constants.map((line) => `  ${line}`),
    "INVARIANT NotAllMatched", "CHECK_DEADLOCK FALSE", ""].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss16m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", `${spec}Trace.tla`], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch<T>(items: T[], check: (prefix: T[]) => Promise<Verdict>): Promise<T | null> {
  let low = 1;
  let high = items.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const verdict = await check(items.slice(0, middle));
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return items[low - 1] ?? null;
}

// ---------------------------------------------------------------------------
// request: sessions of `fx ask`, checked against ConfiguredRequest.tla.

const LEVELS = ["low", "high"];
const MODEL = "local-model";
type Kind = "answer" | "tool" | "cut";
type Fragment = string[];
type Definition = { declared: string[]; request: Fragment; levels: Record<string, Fragment>; limit: boolean; field: string };
type Sent = { effort: string; body: Record<string, string>; limit: string; field: string; resend: boolean };
type Session = {
  id: string;
  def: Definition;
  configured: string;
  loaded: "ok" | "rejected" | "unknown";
  replies: Kind[];
  sent: Sent[];
  notices: number;
  evidence: { exit: number; error: string | null; tail: string };
};

const ORDERS = [[], ["low"], ["high"], ["low", "high"], ["high", "low"]];
const REQUEST_FRAGMENTS: Fragment[] = [[], ["temperature"], ["temperature", "reasoning_effort"], ["model"]];
const LEVEL_FRAGMENTS: Fragment[] = [["reasoning_effort"], ["reasoning_effort", "temperature"], ["model"]];
const SCRIPTS: Kind[][] = [[], ["tool"], ["cut"], ["tool", "tool"], ["tool", "cut"], ["cut", "tool"], ["cut", "cut"]];

// The JSON a fragment stands for. Each value names where it came from, so a
// request body shows which fragment set each field.
function requestFields(fragment: Fragment): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  for (const key of fragment) fields[key] = key === "temperature" ? 0.2 : key === "model" ? "other-request" : "request";
  return fields;
}

function levelFields(fragment: Fragment, level: string): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  for (const key of fragment) fields[key] = key === "temperature" ? 0.7 : key === "model" ? "other-level" : level;
  return fields;
}

function metadataOf(def: Definition): Record<string, unknown> {
  const metadata: Record<string, unknown> = { context_window: 262144, supports_tool_use: true, output_limit_field: def.field };
  if (def.limit) metadata.max_output_tokens = 8192;
  if (def.request.length > 0) metadata.request = requestFields(def.request);
  if (def.declared.length > 0) {
    metadata.reasoning_efforts = Object.fromEntries(def.declared.map((level) => [level, levelFields(def.levels[level]!, level)]));
  }
  return metadata;
}

function sentOf(body: any, afterCut: boolean): Sent {
  const source = (key: string): string => {
    const value = body[key];
    if (key === "model") return value === MODEL ? "fx" : value === "other-request" ? "request" : value === "other-level" ? "level" : "unknown";
    if (value === undefined) return "absent";
    if (key === "temperature") return value === 0.2 ? "request" : value === 0.7 ? "level" : "unknown";
    return value === "request" ? "request" : LEVELS.includes(value) ? "level" : "unknown";
  };
  const field = body.max_tokens !== undefined ? "max_tokens" : body.max_completion_tokens !== undefined ? "max_completion_tokens" : "none";
  const amount = body.max_tokens ?? body.max_completion_tokens;
  return {
    effort: LEVELS.includes(body.reasoning_effort) ? body.reasoning_effort : "none",
    body: { model: source("model"), temperature: source("temperature"), reasoning_effort: source("reasoning_effort") },
    limit: amount === undefined ? "none" : amount === 8192 ? "model" : amount === 32768 ? "raised" : "unknown",
    field,
    resend: afterCut,
  };
}

function sse(chunks: unknown[]): Response {
  return new Response(chunks.map((value) => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } });
}

// A tool call whose reply ran out of output tokens mid-arguments.
function cutReply(model: string): Response {
  const args = JSON.stringify({ path: "note.txt" });
  return sse([
    { id: "chat-cut", model, choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call-cut", type: "function", function: { name: "read_file", arguments: args.slice(0, args.length - 4) } }] }, finish_reason: null }] },
    { id: "chat-cut", model, choices: [{ index: 0, delta: {}, finish_reason: "length" }] },
  ]);
}

async function runSession(fixtures: any, id: string, def: Definition, configured: string, script: Kind[], steps: number): Promise<Session> {
  const served: Kind[] = [];
  const f = fixtures.createConfiguredProviderFixture((body: any) => {
    const kind: Kind = script[served.length] ?? "answer";
    served.push(kind);
    if (kind === "tool") return fixtures.toolCompletion(body.model, "read_file", { path: "note.txt" }, `call-${served.length}`);
    if (kind === "cut") return cutReply(body.model);
    return fixtures.completion(body.model, `ANSWER_${id}`);
  });
  try {
    writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
    f.settings.providers.local.model_metadata = { [MODEL]: metadataOf(def) };
    if (configured !== "auto") f.settings.effort = configured;
    f.save();
    const child = Bun.spawn([binary, "ask", "--json", "--no-save", "Read note.txt"], {
      cwd: f.workspace,
      env: testEnvironment({ HOME: f.home, FX_MAX_AGENT_STEPS: String(steps), NO_COLOR: "1" }),
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), script.length > 50 ? 600_000 : 60_000);
    const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);
    let error: string | null = null;
    try {
      error = JSON.parse(stdout.trim()).error ?? null;
    } catch {
      error = "unreadable_output";
    }
    const requests: Array<{ body: any }> = f.requests;
    const loaded = requests.length > 0 ? "ok" : error === "ReservedRequestField" ? "rejected" : "unknown";
    return {
      id, def, configured, loaded,
      replies: served,
      sent: requests.map((request, index) => sentOf(request.body, index > 0 && served[index - 1] === "cut")),
      notices: stderr.split("is not available for").length - 1,
      evidence: { exit, error, tail: `${stdout}\n${stderr}`.slice(-300) },
    };
  } finally {
    f.close();
  }
}

function sessionValue(s: Session): string {
  const fragment = (f: Fragment) => set(f);
  const levels = `[${LEVELS.map((level) => `${level} |-> ${fragment(s.def.levels[level]!)}`).join(", ")}]`;
  const def = `[declared |-> ${seq(s.def.declared.map(str))}, request |-> ${fragment(s.def.request)}, levels |-> ${levels}, ` +
    `limit |-> ${s.def.limit ? "TRUE" : "FALSE"}, field |-> ${str(s.def.field)}]`;
  const sent = s.sent.map((r) =>
    `[effort |-> ${str(r.effort)}, body |-> [model |-> ${str(r.body.model!)}, temperature |-> ${str(r.body.temperature!)}, ` +
    `reasoning_effort |-> ${str(r.body.reasoning_effort!)}], limit |-> ${str(r.limit)}, field |-> ${str(r.field)}, ` +
    `resend |-> ${r.resend ? "TRUE" : "FALSE"}]`);
  return `[def |-> ${def}, configured |-> ${str(s.configured)}, loaded |-> ${str(s.loaded)}, replies |-> ${seq(s.replies.map(str))}, ` +
    `sent |-> ${seq(sent)}, notices |-> ${s.notices}]`;
}

function sessionCases(): Array<{ def: Definition; configured: string; script: Kind[] }> {
  const cases: Array<{ def: Definition; configured: string; script: Kind[] }> = [];
  let turn = 0;
  for (const declared of ORDERS) for (const request of REQUEST_FRAGMENTS) for (const fragment of LEVEL_FRAGMENTS) {
    for (const limit of [false, true]) for (const field of ["max_tokens", "max_completion_tokens"]) for (const configured of ["auto", ...LEVELS]) {
      const levels = Object.fromEntries(LEVELS.map((level) => [level, fragment]));
      cases.push({ def: { declared, request, levels, limit, field }, configured, script: SCRIPTS[turn++ % SCRIPTS.length]! });
    }
  }
  const next = generator(options.seed);
  const pick = <T>(items: T[]): T => items[Math.floor(next() * items.length)]!;
  for (let i = 0; i < options.random; i++) {
    const levels = Object.fromEntries(LEVELS.map((level) => [level, pick(LEVEL_FRAGMENTS.slice(0, 2))]));
    const script = Array.from({ length: Math.floor(next() * 5) }, () => pick<Kind>(["tool", "tool", "cut"]));
    cases.push({
      def: { declared: pick(ORDERS), request: pick(REQUEST_FRAGMENTS.slice(0, 3)), levels, limit: next() < 0.5, field: pick(["max_tokens", "max_completion_tokens"]) },
      configured: pick(["auto", ...LEVELS]),
      script,
    });
  }
  return cases;
}

const requestConstants = (bug: string) => [`Levels = ${set(LEVELS)}`, "MaxRequests = 100000", `Bug = ${str(bug)}`];

async function requestPart(out: string): Promise<number> {
  const fixtures = await targetModule("fixtures/chat-completions.ts");
  const cases = sessionCases();
  if (options.stress > 0) {
    const levels = Object.fromEntries(LEVELS.map((level) => [level, LEVEL_FRAGMENTS[1]!]));
    cases.push({
      def: { declared: ["low", "high"], request: ["temperature"], levels, limit: true, field: "max_tokens" },
      configured: "high",
      script: Array.from({ length: options.stress }, (): Kind => "tool"),
    });
  }
  const started = performance.now();
  const sessions = await pool(cases.length, options.jobs, (index) => {
    const { def, configured, script } = cases[index]!;
    return runSession(fixtures, `s${index}`, def, configured, script, 0);
  });
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "sessions.json"), sessions);
  const requests = sessions.reduce((sum, s) => sum + s.sent.length, 0);
  const rejected = sessions.filter((s) => s.loaded === "rejected").length;
  const noticed = sessions.filter((s) => s.notices > 0).length;
  const efforts = sessions.filter((s) => s.sent.some((r) => r.effort !== "none")).length;
  const notes = sessions.filter((s) => s.sent.some((r) => r.resend)).length;
  console.log(`request: ${sessions.length} sessions of ${binary} in ${seconds}s, ${requests} requests; ` +
    `${rejected} settings refused, ${efforts} sent a level, ${noticed} printed a notice, ${notes} sent a note after a cut`);
  if (options.stress > 0) {
    const stress = sessions.at(-1)!;
    console.log(`stress: ${options.stress} tool steps, ${stress.sent.length} requests, ` +
      `${stress.sent.filter((r) => r.effort === "high").length} carried the level, ${stress.notices} notices`);
  }

  const unknown = sessions.find((s) => s.loaded === "unknown" ||
    s.sent.some((r) => r.limit === "unknown" || Object.values(r.body).includes("unknown")));
  if (unknown) {
    console.log(`REJECTED: session ${unknown.id} did something the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }
  const check = async (items: Session[], bug: string) =>
    runTrace("ConfiguredRequest", items.map(sessionValue).join(",\n  "), requestConstants(bug), out, `request-${bug}`);
  const design = await check(sessions, "none");
  console.log(`request, the design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(sessions, async (prefix) => (await check(prefix, "none")).verdict);
    console.log(`first session the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await check(sessions, "today");
    console.log(`self-check, request, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
    const tampered = sessions.map((s) => (s.notices > 0 ? { ...s, notices: s.notices + 1 } : s));
    const twice = await check(tampered, "none");
    console.log(`self-check, request, a notice counted twice: ${twice.verdict} (must be REJECTED)`);
    if (twice.verdict !== "REJECTED") return twice.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// catalog: runs of `fx models`, checked against ConfiguredCatalog.tla.

type Server = "lists" | "refuses" | "silent";
type CatalogRun = {
  id: string;
  fetch: Record<string, boolean>;
  selected: string;
  server: Server;
  asked: Array<{ to: string; token: string }>;
  shown: string[][];
  lines: number;
  evidence: { exit: number; seconds: number; tail: string };
};

const CONNS = ["a", "b"];
const REFUSALS = [
  () => Response.json({ error: { message: "no" } }, { status: 401 }),
  () => new Response("down", { status: 500 }),
  () => new Response("{\"object\":\"list\",\"data\":", { headers: { "content-type": "application/json" } }),
  () => Response.json({ error: { message: "slow down" } }, { status: 429 }),
];

async function runCatalog(id: string, fetch: Record<string, boolean>, selected: string, server: Server, scratch: string, refusal: number): Promise<CatalogRun> {
  const asked: Array<{ to: string; token: string }> = [];
  const held: Array<() => void> = [];
  const host = Bun.serve({
    hostname: "127.0.0.1", port: 0, idleTimeout: 0,
    async fetch(request) {
      const [, conn, , leaf] = new URL(request.url).pathname.split("/");
      if (leaf !== "models" || !CONNS.includes(conn!)) return new Response("unexpected endpoint", { status: 500 });
      const token = /^Bearer token-([ab])$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "none";
      asked.push({ to: conn!, token });
      if (server === "silent") return new Promise<Response>((resolve) => held.push(() => resolve(new Response("late", { status: 500 }))));
      if (server === "refuses") return REFUSALS[refusal % REFUSALS.length]!();
      return Response.json({ object: "list", data: [{ id: `${conn}-listed`, object: "model" }] });
    },
  });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const providers = Object.fromEntries(CONNS.map((conn) => [conn, {
    protocol: "openai-chat-completions",
    base_url: `http://127.0.0.1:${host.port}/${conn}/v1`,
    auth: { type: "bearer", env: `FX_TEST_TOKEN_${conn.toUpperCase()}` },
    fetch_models: fetch[conn],
    timeouts: { connect_ms: 2000, first_response_ms: 300 },
    model_metadata: { [`${conn}-declared`]: { context_window: 32768 } },
  }]));
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    provider: selected, auto_upgrade: false, providers,
    models: Object.fromEntries(CONNS.map((conn) => [conn, `${conn}-declared`])),
  }));
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "models", "--json"], {
      cwd: workspace,
      env: testEnvironment({ HOME: home, FX_TEST_TOKEN_A: "token-a", FX_TEST_TOKEN_B: "token-b", NO_COLOR: "1" }),
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 30_000);
    const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);
    let ids: string[] = [];
    try {
      ids = JSON.parse(stdout.trim()).ids ?? [];
    } catch {
      ids = ["unreadable-output"];
    }
    return {
      id, fetch, selected, server, asked,
      shown: ids.map((model) => model.split("-")).sort(),
      lines: stderr.split("showing the models in settings").length - 1,
      evidence: { exit, seconds: Number(((performance.now() - started) / 1000).toFixed(2)), tail: `${stdout}\n${stderr}`.slice(-300) },
    };
  } finally {
    for (const release of held) release();
    host.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

function catalogValue(run: CatalogRun): string {
  const fetch = `[${CONNS.map((conn) => `${conn} |-> ${run.fetch[conn] ? "TRUE" : "FALSE"}`).join(", ")}]`;
  const asked = run.asked.map((ask) => `[to |-> ${str(ask.to)}, token |-> ${str(ask.token)}]`);
  const shown = `{${run.shown.map((model) => seq(model.map(str))).join(", ")}}`;
  return `[fetch |-> ${fetch}, selected |-> ${str(run.selected)}, server |-> ${str(run.server)}, asked |-> ${seq(asked)}, ` +
    `shown |-> ${shown}, lines |-> ${run.lines}]`;
}

const catalogConstants = (bug: string) => ["Timeout = 2", "MaxSwitches = 0", "MaxAsks = 100000", `Bug = ${str(bug)}`];

async function catalogPart(out: string): Promise<number> {
  const scratch = join(out, "catalog");
  mkdirSync(scratch, { recursive: true });
  const cases: Array<{ fetch: Record<string, boolean>; selected: string; server: Server; refusal: number }> = [];
  for (const a of [false, true]) for (const b of [false, true]) for (const selected of CONNS) {
    for (const server of ["lists", "silent"] as Server[]) cases.push({ fetch: { a, b }, selected, server, refusal: 0 });
    for (let refusal = 0; refusal < REFUSALS.length; refusal++) cases.push({ fetch: { a, b }, selected, server: "refuses", refusal });
  }
  const started = performance.now();
  const runs = await pool(cases.length, options.jobs, (index) => {
    const { fetch, selected, server, refusal } = cases[index]!;
    return runCatalog(`c${index}`, fetch, selected, server, scratch, refusal);
  });
  writeJson(join(out, "catalog-runs.json"), runs);
  const slowest = Math.max(...runs.map((run) => run.evidence.seconds));
  console.log(`catalog: ${runs.length} runs of ${binary} models in ${((performance.now() - started) / 1000).toFixed(1)}s; ` +
    `${runs.filter((run) => run.asked.length > 0).length} asked the server, ${runs.filter((run) => run.lines > 0).length} printed a failure line, ` +
    `slowest ${slowest}s`);
  const unread = runs.find((run) => run.evidence.exit !== 0 || run.shown.some((model) => model.length !== 2));
  if (unread) {
    console.log(`REJECTED: run ${unread.id} ended in a way the driver cannot read: ${JSON.stringify(unread)}`);
    return 1;
  }
  const check = async (items: CatalogRun[], bug: string) =>
    runTrace("ConfiguredCatalog", items.map(catalogValue).join(",\n  "), catalogConstants(bug), out, `catalog-${bug}`);
  const design = await check(runs, "none");
  console.log(`catalog, the design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(runs, async (prefix) => (await check(prefix, "none")).verdict);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await check(runs, "today");
    console.log(`self-check, catalog, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// resume: a saved session resumed after a settings edit, checked against
// ConfiguredResume.tla.

type Binding = { protocol: string; url: string; auth: string };
// `binding` null: the connection was removed from settings.
type ResumeEdit = { name: string; binding: Binding | null; other: boolean };
type ResumeRun = {
  id: string;
  saved: Binding;
  edit: ResumeEdit;
  outcome: string;
  sentTo: Binding | null;
  evidence: { first: number; exit: number; error: string | null; tail: string };
};

const RESUME_PROTOCOLS = ["openai-chat-completions", "anthropic-messages"];
// Two base URLs on the same local server, told apart by their path.
const RESUME_URLS = ["u1", "u2"];
const RESUME_AUTHS = ["none", "key"];

function messagesReply(text: string): Response {
  const events: Array<[string, unknown]> = [
    ["message_start", { type: "message_start", message: { id: "msg", type: "message", role: "assistant", model: "m", content: [], stop_reason: null, usage: { input_tokens: 5, output_tokens: 0 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 2 } }],
    ["message_stop", { type: "message_stop" }],
  ];
  return new Response(events.map(([name, data]) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`).join(""),
    { headers: { "content-type": "text/event-stream" } });
}

function chatReply(text: string): Response {
  return sse([{ id: "chat", model: "m", choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: "stop" }] }]);
}

function connectionOf(binding: Binding, port: number, other: boolean): Record<string, unknown> {
  return {
    protocol: binding.protocol,
    base_url: `http://127.0.0.1:${port}/${binding.url}/v1`,
    auth: binding.auth === "key" ? { type: "bearer", env: "FX_TEST_TOKEN_RESUME" } : { type: "none" },
    model_metadata: { m: { context_window: 32768, max_output_tokens: 1024 } },
    ...(other ? { timeouts: { stall_ms: 60000 }, headers: { "X-Org": { env: "FX_TEST_ORG" } } } : {}),
  };
}

async function runFxJson(args: string[], cwd: string, home: string): Promise<{ exit: number; error: string | null; session: string | null; tail: string }> {
  const child = Bun.spawn([binary, ...args], {
    cwd,
    env: testEnvironment({ HOME: home, FX_TEST_TOKEN_RESUME: "resume-token", FX_TEST_ORG: "org", NO_COLOR: "1" }),
    stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), 60_000);
  const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  let error: string | null = null;
  let session: string | null = null;
  try {
    const parsed = JSON.parse(stdout.trim());
    error = parsed.error ?? null;
    session = parsed.session_id || null;
  } catch {
    error = "unreadable_output";
  }
  return { exit, error, session, tail: `${stdout}\n${stderr}`.slice(-300) };
}

async function runResume(id: string, saved: Binding, edit: ResumeEdit, scratch: string): Promise<ResumeRun> {
  const seen: Binding[] = [];
  const host = Bun.serve({
    hostname: "127.0.0.1", port: 0, idleTimeout: 0,
    async fetch(request) {
      const [, url, , ...rest] = new URL(request.url).pathname.split("/");
      const leaf = rest.join("/");
      const protocol = leaf === "chat/completions" ? "openai-chat-completions" : leaf === "messages" ? "anthropic-messages" : null;
      if (!protocol || !RESUME_URLS.includes(url!)) return new Response("unexpected endpoint", { status: 500 });
      await request.text();
      seen.push({ protocol, url: url!, auth: request.headers.get("authorization") === "Bearer resume-token" ? "key" : "none" });
      return protocol === "anthropic-messages" ? messagesReply(`reply ${seen.length}`) : chatReply(`reply ${seen.length}`);
    },
  });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const settingsPath = join(home, ".fx", "settings.json");
  // A removed connection leaves another one selected, so the resume itself,
  // not the settings, finds it gone.
  const write = (binding: Binding | null, other: boolean) => writeFileSync(settingsPath, JSON.stringify({
    provider: binding ? "local" : "spare", auto_upgrade: false, models: { local: "m", spare: "m" },
    providers: {
      ...(binding ? { local: connectionOf(binding, host.port!, other) } : {}),
      spare: connectionOf({ protocol: "openai-chat-completions", url: "u1", auth: "none" }, host.port!, false),
    },
  }));
  try {
    write(saved, false);
    const first = await runFxJson(["ask", "--json", "first turn"], workspace, home);
    const sent = seen.length;
    if (first.exit !== 0 || !first.session || sent !== 1) {
      return { id, saved, edit, outcome: "unreadable", sentTo: null, evidence: { first: first.exit, exit: -1, error: first.error, tail: first.tail } };
    }
    write(edit.binding, edit.other);
    const second = await runFxJson(["ask", "--json", "--resume", first.session, "second turn"], workspace, home);
    const after = seen.slice(sent);
    const outcome = second.exit === 0 && after.length > 0 ? "sent"
      : second.error === "ConfiguredProviderChanged" ? "changed"
      : second.error === "UnknownConfiguredProvider" || second.error === "ConfiguredProviderRemoved" ? "unknown"
      : second.error === "CredentialTemporarilyUnavailable" ? "temporary"
      : "unreadable";
    return {
      id, saved, edit, outcome,
      // Whatever reached the server, refused resume or not: the model checks
      // that a session's history goes only to the binding it was saved with.
      sentTo: after[0] ?? null,
      evidence: { first: first.exit, exit: second.exit, error: second.error, tail: second.tail },
    };
  } finally {
    host.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

const bindingValue = (b: Binding) => `[protocol |-> ${str(b.protocol)}, url |-> ${str(b.url)}, auth |-> ${str(b.auth)}]`;

function resumeValue(run: ResumeRun): string {
  return `[saved |-> ${bindingValue(run.saved)}, current |-> ${run.edit.binding ? bindingValue(run.edit.binding) : "[removed |-> TRUE]"}, ` +
    `other |-> ${run.edit.other ? "TRUE" : "FALSE"}, outcome |-> ${str(run.outcome)}, ` +
    `sent_to |-> ${run.sentTo ? bindingValue(run.sentTo) : "[nothing |-> TRUE]"}]`;
}

const resumeConstants = (bug: string) => [
  `Protocols = ${set(RESUME_PROTOCOLS)}`, `Urls = ${set(RESUME_URLS)}`, `Auths = ${set(RESUME_AUTHS)}`, `Bug = ${str(bug)}`,
];

function resumeEdits(saved: Binding): ResumeEdit[] {
  const flip = (values: string[], value: string) => values.find((other) => other !== value)!;
  const protocol = { ...saved, protocol: flip(RESUME_PROTOCOLS, saved.protocol) };
  return [
    { name: "nothing", binding: saved, other: false },
    { name: "protocol", binding: protocol, other: false },
    { name: "base_url", binding: { ...saved, url: flip(RESUME_URLS, saved.url) }, other: false },
    { name: "auth", binding: { ...saved, auth: flip(RESUME_AUTHS, saved.auth) }, other: false },
    { name: "outside the binding", binding: saved, other: true },
    { name: "protocol and outside", binding: protocol, other: true },
    { name: "removed", binding: null, other: false },
  ];
}

async function resumePart(out: string): Promise<number> {
  const scratch = join(out, "resume");
  mkdirSync(scratch, { recursive: true });
  const cases: Array<{ saved: Binding; edit: ResumeEdit }> = [];
  for (const protocol of RESUME_PROTOCOLS) for (const url of RESUME_URLS) for (const auth of RESUME_AUTHS) {
    const saved = { protocol, url, auth };
    for (const edit of resumeEdits(saved)) cases.push({ saved, edit });
  }
  const started = performance.now();
  const runs = await pool(cases.length, options.jobs, (index) => runResume(`r${index}`, cases[index]!.saved, cases[index]!.edit, scratch));
  writeJson(join(out, "resume-runs.json"), runs);
  const count = (outcome: string) => runs.filter((run) => run.outcome === outcome).length;
  console.log(`resume: ${runs.length} sessions of ${binary} saved, edited, and resumed in ${((performance.now() - started) / 1000).toFixed(1)}s; ` +
    `${count("sent")} resumed, ${count("changed")} refused as changed, ${count("unknown")} as unknown, ${count("temporary")} as temporary`);
  const unread = runs.find((run) => run.outcome === "unreadable");
  if (unread) {
    console.log(`REJECTED: run ${unread.id} ended in a way the driver cannot read: ${JSON.stringify(unread)}`);
    return 1;
  }
  const check = async (items: ResumeRun[], bug: string) =>
    runTrace("ConfiguredResume", items.map(resumeValue).join(",\n  "), resumeConstants(bug), out, `resume-${bug}`);
  const design = await check(runs, "none");
  console.log(`resume, the design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(runs, async (prefix) => (await check(prefix, "none")).verdict);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await check(runs, "today");
    console.log(`self-check, resume, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// deadlines: request_deadlines.zig walked along ConfiguredDeadlines.tla.

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Hop = { from: string; to: string; label: string };
type LabState = { phase: string; clock: number; quiet: number; cause: string; waited: number; due: boolean };

const BOUNDS = { Connect: 1, Head: 2, Stall: 2, MaxClock: 4 };
const deadlinesModule = join(REPO_ROOT, "src", "gateway", "request_deadlines.zig");
const deadlinesLab = join(TLA_ROOT, "drivers", "configured_provider", "lab.zig");

function buildLab(labFile: string, depName: string, moduleSource: string, out: string, name: string): string | null {
  const bin = join(out, name);
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-O", "ReleaseSafe", "--dep", depName,
      `-Mroot=${labFile}`, `-M${depName}=${moduleSource}`,
      "--name", name, `-femit-bin=${bin}`],
    { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) {
    console.log(`building ${name} failed:\n${new TextDecoder().decode(build.stderr).slice(0, 2000)}`);
    return null;
  }
  return bin;
}

async function loadGraph(out: string): Promise<Graph | null> {
  const dir = join(out, "deadlines-graph");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), ["INIT Init", "NEXT Next", "CONSTANTS", `    Connect = ${BOUNDS.Connect}`, `    Head = ${BOUNDS.Head}`,
    `    Stall = ${BOUNDS.Stall}`, "    BuiltIn = 3", `    MaxClock = ${BOUNDS.MaxClock}`, "    Bug = \"none\"", "CHECK_DEADLOCK FALSE", ""].join("\n"));
  const run = await runTlc(dir, "ConfiguredDeadlines", "Driver.cfg", ["ConfiguredDeadlines.tla"], tlaDir, ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) {
    console.log(`TLC failed on ConfiguredDeadlines.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
    return null;
  }
  const graph = parseDotGraph(join(dir, "graph.dot"));
  if (!graph) return null;
  console.log(`deadlines: graph of ${graph.states.size} states, ${run.durationMs} ms`);
  return graph;
}

// Reads a graph TLC dumped with `-dump dot,actionlabels`: its states and edges.
function parseDotGraph(path: string): Graph | null {
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  let init = "";
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      if (!next.has(edge[1]!)) next.set(edge[1]!, []);
      next.get(edge[1]!)!.push({ to: edge[2]!, label: edge[3]! });
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const state: Model = {};
    for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(node[1]!, state);
    if (/style\s*=\s*filled/.test(node[3]!)) init = node[1]!;
  }
  if (!init) return null;
  return { states, next, init };
}

function walksOf(graph: Graph): Hop[][] {
  const parent = new Map<string, { from: string; label: string } | null>([[graph.init, null]]);
  const queue = [graph.init];
  for (let at = 0; at < queue.length; at += 1) {
    for (const edge of graph.next.get(queue[at]!) ?? []) {
      if (edge.to === queue[at] || parent.has(edge.to)) continue;
      parent.set(edge.to, { from: queue[at]!, label: edge.label });
      queue.push(edge.to);
    }
  }
  const walks: Hop[][] = [];
  for (const id of queue) {
    for (const edge of graph.next.get(id) ?? []) {
      if (edge.to === id) continue;
      const hops: Hop[] = [{ from: id, to: edge.to, label: edge.label }];
      for (let at = id; parent.get(at); at = parent.get(at)!.from) hops.unshift({ from: parent.get(at)!.from, to: at, label: parent.get(at)!.label });
      walks.push(hops);
    }
  }
  const random = generator(options.seed);
  for (let w = 0; w < options.walks; w += 1) {
    const hops: Hop[] = [];
    let at = graph.init;
    for (let i = 0; i < options.steps; i += 1) {
      const edges = (graph.next.get(at) ?? []).filter((edge) => edge.to !== at);
      if (edges.length === 0) break;
      const edge = edges[Math.floor(random() * edges.length)]!;
      hops.push({ from: at, to: edge.to, label: edge.label });
      at = edge.to;
    }
    walks.push(hops);
  }
  return walks;
}

const OPS: Record<string, string> = { Tick: "tick", Connects: "connects", HeadArrives: "head", Bytes: "bytes", Completes: "completes", Expires: "expires" };

// Whether the model lets the current wait run out in state `t`.
function due(t: Model): boolean {
  const bound = t.phase === "connecting" ? BOUNDS.Connect : t.phase === "awaiting_head" ? BOUNDS.Head : t.phase === "streaming" ? BOUNDS.Stall : null;
  return bound !== null && (t.phase === "streaming" ? t.quiet : t.clock) >= bound;
}

function runLab(bin: string, walks: Hop[][], out: string, name: string): LabState[] | null {
  const lines: string[] = [];
  for (const walk of walks) {
    lines.push(JSON.stringify({ op: "walk" }));
    for (const hop of walk) lines.push(JSON.stringify({ op: OPS[hop.label] }));
  }
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) {
    console.log(`${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr).slice(0, 2000)}`);
    return null;
  }
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line) as LabState);
  return results.length === lines.length ? results : null;
}

function mismatchesOf(walks: Hop[][], graph: Graph, results: LabState[], tamper: boolean): string[] {
  const found: string[] = [];
  let r = 0;
  walks.forEach((walk, w) => {
    r += 1; // the walk's reset
    let failed = false;
    walk.forEach((hop, i) => {
      const real = results[r++]!;
      if (failed) return;
      const t = graph.states.get(hop.to)!;
      const expected: Record<string, unknown> = { phase: t.phase, clock: t.clock, quiet: t.quiet, cause: t.cause, waited: t.waited, due: tamper ? !due(t) : due(t) };
      for (const [field, model] of Object.entries(expected)) {
        if (JSON.stringify(model) === JSON.stringify((real as any)[field])) continue;
        failed = true;
        found.push(`walk ${w} step ${i} (${walk.slice(0, i + 1).map((x) => x.label).join(" > ")}): ${field}: model ${JSON.stringify(model)}, module ${JSON.stringify((real as any)[field])}`);
        break;
      }
    });
  });
  return found;
}

async function deadlinesPart(out: string): Promise<number> {
  if (!existsSync(deadlinesModule)) {
    console.log(`REJECTED: deadlines: ${deadlinesModule} does not exist, so fx has no per-connection bounds to walk`);
    return 1;
  }
  const lab = buildLab(deadlinesLab, "request_deadlines", deadlinesModule, out, "configured_deadlines_lab");
  const graph = await loadGraph(out);
  if (!lab || !graph) return 2;
  const walks = walksOf(graph);
  const results = runLab(lab, walks, out, "configured_deadlines_lab");
  if (!results) return 2;
  const mismatches = mismatchesOf(walks, graph, results, false);
  const steps = walks.reduce((sum, walk) => sum + walk.length, 0);
  console.log(`deadlines: ${walks.length} walks, ${steps} steps, ${mismatches.length} mismatching walks`);
  for (const line of mismatches.slice(0, 3)) console.log(`  ${line}`);
  const walked = new Set(walks.flat().map((hop) => hop.label));
  for (const label of Object.keys(OPS)) {
    if (!walked.has(label)) {
      console.log(`deadlines: action ${label} was never walked`);
      return 1;
    }
  }
  if (mismatches.length > 0) return 1;
  if (options.selfCheck) {
    const source = readFileSync(deadlinesModule, "utf8");
    const mutants = [
      { name: "ends a wait one millisecond late", target: "silence_ms >= bound_ms", planted: "silence_ms > bound_ms" },
      { name: "times the whole response against the stall bound", target: "now_ms -| self.last_bytes_ms", planted: "now_ms -| self.wait_started_ms" },
      { name: "never gives up on a silent response", target: ".streaming => self.bounds.stall_ms", planted: ".streaming => std.math.maxInt(u32)" },
    ];
    let caught = true;
    mutants.forEach((mutant, index) => {
      if (!source.includes(mutant.target)) {
        console.log(`self-check: the target for "${mutant.name}" is gone from request_deadlines.zig`);
        caught = false;
        return;
      }
      const dir = join(out, `deadlines-mutant-${index}`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "request_deadlines.zig"), source.replace(mutant.target, mutant.planted));
      const name = `configured_deadlines_lab_mutant_${index}`;
      const bin = buildLab(deadlinesLab, "request_deadlines", join(dir, "request_deadlines.zig"), out, name);
      const mutated = bin ? runLab(bin, walks, out, name) : null;
      const rejected = mutated !== null && mismatchesOf(walks, graph, mutated, false).length > 0;
      console.log(`self-check: deadlines that ${mutant.name} ${rejected ? "rejected" : "NOT rejected"}`);
      caught &&= rejected;
    });
    const tampered = mismatchesOf(walks, graph, results, true).length > 0;
    console.log(`self-check: deadlines, tampered expectation ${tampered ? "rejected" : "NOT rejected"}`);
    if (!caught || !tampered) return 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// auth-walk: the pure command-auth planner, checked against ConfiguredAuth.tla.

type Token = { conn: string; gen: number };
type AuthOp = { op: string; r?: string; c?: string };
type AuthRequestView = { phase: string; reason: string; gen: number; refreshes: number };
type AuthConnView = { cache: number; cache_expired: boolean; runs: number; waiters: number; issued: number; valid_from: number };
type AuthView = { requests: Record<string, AuthRequestView>; conns: Record<string, AuthConnView> };
type AuthResult = AuthView & { error: string | null };
type AuthRun = { results: AuthResult[] } | { failure: string };
type AuthCase = { requests: string[]; label: string; graph: Graph; walks: Hop[][]; results: AuthResult[] };
type Mutant = { name: string; target: string; planted: string };

const AUTH_CONNS = ["c1", "c2"];
const AUTH_MAX_GEN = 2;
const AUTH_CASES = [
  { requests: ["r1", "r2"], label: "same-connection" },
  { requests: ["r1", "r3"], label: "two-connections" },
];
// Each model action, by its label, and the lab op that replays it. A helper
// that fails and a helper that times out end a run the same way.
const AUTH_ACTION_OPS: Record<string, string> = {
  Begin: "need", Replay: "replay", HelperPrints: "printed", HelperFails: "run_ended", Deadline: "run_ended",
  Accept: "accept", Reject: "reject", Revoke: "revoke", Expire: "expire", Cancel: "cancel",
};
const REJECT_PHASES = ["replay", "failed"];
const authModule = join(REPO_ROOT, "src", "core", "auth", "command_token.zig");
const authLab = join(TLA_ROOT, "drivers", "configured_provider", "lab_auth.zig");
const AUTH_MUTANTS: Mutant[] = [
  { name: "starts a second helper run while one runs", target: "if (state.running) return .wait;", planted: "if (false) return .wait;" },
  { name: "sends a token it knows has expired", target: "if (state.cached != 0 and !state.cached_expired) return .{ .send = state.cached };", planted: "if (state.cached != 0) return .{ .send = state.cached };" },
  { name: "refused keeps the refused token", target: "if (sent != 0 and state.cached == sent) {", planted: "if (sent != 0 and state.cached == sent and false) {" },
  { name: "keeps a helper nobody waits on", target: "if (state.waiters == 0 and state.running) {", planted: "if (false) {" },
];

const connOf = (r: string): string => (r === "r3" ? "c2" : "c1");
const requestState = (t: Model, r: string): string => JSON.stringify([t.phase[r], t.refreshes[r], t.used[r], t.reason[r]]);

async function loadAuthGraph(out: string, requests: string[], label: string): Promise<Graph | null> {
  const dir = join(out, `auth-graph-${label}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), ["INIT Init", "NEXT Next", "CONSTANTS", `    Requests = ${set(requests)}`,
    `    MaxGen = ${AUTH_MAX_GEN}`, "    Design = \"b\"", "    Bug = \"none\"", "    Nonideal = TRUE", "CHECK_DEADLOCK FALSE", ""].join("\n"));
  const run = await runTlc(dir, "ConfiguredAuth", "Driver.cfg", ["ConfiguredAuth.tla"], tlaDir, ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) {
    console.log(`TLC failed on ConfiguredAuth.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
    return null;
  }
  const graph = parseDotGraph(join(dir, "graph.dot"));
  if (!graph) {
    console.log(`auth-walk ${label}: the graph has no initial state`);
    return null;
  }
  console.log(`auth-walk ${label}: graph of ${graph.states.size} states, ${run.durationMs} ms`);
  return graph;
}

// The lab ops for the request rows that changed from `from` to `to`.
function requestSteps(from: Model, to: Model, requests: string[]): AuthOp[] {
  const steps: AuthOp[] = [];
  for (const r of requests) {
    if (from.phase[r] === "idle" && to.phase[r] !== "idle") steps.push({ op: "need", r });
    if (from.phase[r] === "replay" && (to.phase[r] === "sending" || to.phase[r] === "waiting")) steps.push({ op: "replay", r });
    if (from.phase[r] === "sending" && to.phase[r] === "done") steps.push({ op: "accept", r });
    if (from.phase[r] === "sending" && REJECT_PHASES.includes(to.phase[r]) && requestState(from, r) !== requestState(to, r)) {
      steps.push({ op: "reject", r });
    }
    if (to.phase[r] === "cancelled" && from.phase[r] !== "cancelled") steps.push({ op: "cancel", r });
  }
  return steps;
}

// A waiter on connection c that failed in this step: only a run ending does that.
function failedWaiterOn(from: Model, to: Model, requests: string[], c: string): boolean {
  return requests.some((r) => from.phase[r] === "waiting" && to.phase[r] === "failed" && connOf(r) === c);
}

// The lab ops for the connection rows that changed. HelperPrints and Cancel
// also lower a run count, so a run ends only when no token was printed and a
// waiter failed.
function connSteps(from: Model, to: Model, requests: string[]): AuthOp[] {
  const steps: AuthOp[] = [];
  const fresh: Token[] = to.expired.filter((token: Token) =>
    !from.expired.some((old: Token) => JSON.stringify(old) === JSON.stringify(token)));
  for (const c of AUTH_CONNS) {
    if (to.issued[c] > from.issued[c]) steps.push({ op: "printed", c });
    if (to.runs[c] < from.runs[c] && to.issued[c] === from.issued[c] && failedWaiterOn(from, to, requests, c)) {
      steps.push({ op: "run_ended", c });
    }
    if (to.valid_from[c] !== from.valid_from[c]) steps.push({ op: "revoke", c });
    if (fresh.some((token) => token.conn === c)) steps.push({ op: "expire", c });
  }
  return steps;
}

// The one lab op that takes `from` to `to`, when the states differ by exactly
// one step and that step is the one the label names. Otherwise null.
function authOp(from: Model, to: Model, label: string, requests: string[]): AuthOp | null {
  const found = [...requestSteps(from, to, requests), ...connSteps(from, to, requests)];
  if (found.length !== 1 || found[0]!.op !== AUTH_ACTION_OPS[label]) return null;
  return found[0]!;
}

// What the model says the planner must show after reaching state `t`.
function authExpected(t: Model, requests: string[]): AuthView {
  const requestViews: Record<string, AuthRequestView> = {};
  for (const r of requests) {
    requestViews[r] = { phase: t.phase[r], reason: t.reason[r], gen: t.used[r].gen, refreshes: t.refreshes[r] };
  }
  const connViews: Record<string, AuthConnView> = {};
  for (const c of AUTH_CONNS) {
    const cache: Token = t.cache[c];
    connViews[c] = {
      cache: cache.gen,
      cache_expired: cache.gen > 0 && t.expired.some((token: Token) => token.conn === cache.conn && token.gen === cache.gen),
      runs: t.runs[c],
      waiters: requests.filter((r) => t.phase[r] === "waiting" && connOf(r) === c).length,
      issued: t.issued[c],
      valid_from: t.valid_from[c],
    };
  }
  return { requests: requestViews, conns: connViews };
}

function runAuthLab(bin: string, walks: Hop[][], graph: Graph, requests: string[], out: string, name: string): AuthRun {
  const lines: string[] = [];
  for (const [w, walk] of walks.entries()) {
    lines.push(JSON.stringify({ op: "walk" }));
    for (const [i, hop] of walk.entries()) {
      const op = authOp(graph.states.get(hop.from)!, graph.states.get(hop.to)!, hop.label, requests);
      if (!op) return { failure: `auth-walk: walk ${w} step ${i} (${hop.label}) has no lab op for the model's step` };
      lines.push(JSON.stringify(op));
    }
  }
  const opsPath = join(out, `${name}.ops.jsonl`);
  const resultsPath = join(out, `${name}.results.jsonl`);
  writeFileSync(opsPath, `${lines.join("\n")}\n`);
  const run = Bun.spawnSync([bin, opsPath, resultsPath], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) {
    return { failure: `${name} exited ${run.exitCode}:\n${new TextDecoder().decode(run.stderr).slice(0, 2000)}` };
  }
  const results = readFileSync(resultsPath, "utf8").trim().split("\n").map((line) => JSON.parse(line) as AuthResult);
  if (results.length !== lines.length) return { failure: `${name} wrote ${results.length} results for ${lines.length} ops` };
  return { results };
}

// Every field the model states, paired with the value the module reported.
function authPairs(expected: AuthView, real: AuthResult): Array<[string, unknown, unknown]> {
  const pairs: Array<[string, unknown, unknown]> = [];
  for (const [r, view] of Object.entries(expected.requests)) {
    for (const [field, model] of Object.entries(view)) {
      pairs.push([`requests.${r}.${field}`, model, (real.requests[r] as Record<string, unknown>)[field]]);
    }
  }
  for (const [c, view] of Object.entries(expected.conns)) {
    for (const [field, model] of Object.entries(view)) {
      pairs.push([`conns.${c}.${field}`, model, (real.conns[c] as Record<string, unknown>)[field]]);
    }
  }
  pairs.push(["error", null, real.error]);
  return pairs;
}

function firstAuthMismatch(t: Model, real: AuthResult, requests: string[], tamper: boolean): string | null {
  const expected = authExpected(t, requests);
  if (tamper) expected.conns.c1!.runs = expected.conns.c1!.runs === 0 ? 1 : 0;
  for (const [field, model, got] of authPairs(expected, real)) {
    if (model !== got) return `${field}: model ${JSON.stringify(model)}, module ${JSON.stringify(got)}`;
  }
  return null;
}

// The first mismatch of each walk. The reset result of each walk is skipped.
function authMismatches(walks: Hop[][], graph: Graph, results: AuthResult[], requests: string[], tamper: boolean): string[] {
  const found: string[] = [];
  let r = 0;
  walks.forEach((walk, w) => {
    r += 1;
    let reported = false;
    walk.forEach((hop, i) => {
      const real = results[r++]!;
      if (reported) return;
      const mismatch = firstAuthMismatch(graph.states.get(hop.to)!, real, requests, tamper);
      if (!mismatch) return;
      reported = true;
      found.push(`walk ${w} step ${i} (${walk.slice(0, i + 1).map((x) => x.label).join(" > ")}): ${mismatch}`);
    });
  });
  return found;
}

function authMutantRejected(out: string, source: string, mutant: Mutant, index: number, first: AuthCase): boolean {
  const dir = join(out, `auth-mutant-${index}`);
  mkdirSync(dir, { recursive: true });
  const copy = join(dir, "command_token.zig");
  writeFileSync(copy, source.replace(mutant.target, mutant.planted));
  const name = `configured_auth_lab_mutant_${index}`;
  const bin = buildLab(authLab, "command_token", copy, out, name);
  if (!bin) return false;
  const run = runAuthLab(bin, first.walks, first.graph, first.requests, out, name);
  if ("failure" in run) {
    console.log(run.failure);
    return false;
  }
  return authMismatches(first.walks, first.graph, run.results, first.requests, false).length > 0;
}

function authSelfCheck(out: string, first: AuthCase): number {
  const tampered = authMismatches(first.walks, first.graph, first.results, first.requests, true).length > 0;
  console.log(`self-check: auth-walk, tampered expectation ${tampered ? "rejected" : "NOT rejected"}`);
  const source = readFileSync(authModule, "utf8");
  let caught = tampered;
  for (const [index, mutant] of AUTH_MUTANTS.entries()) {
    if (!source.includes(mutant.target)) {
      console.log(`self-check: the target for "${mutant.name}" is gone from command_token.zig`);
      caught = false;
      continue;
    }
    const rejected = authMutantRejected(out, source, mutant, index, first);
    console.log(`self-check: auth-walk that ${mutant.name} ${rejected ? "rejected" : "NOT rejected"}`);
    caught &&= rejected;
  }
  return caught ? 0 : 1;
}

async function authWalkPart(out: string): Promise<number> {
  if (!existsSync(authModule)) {
    console.log(`REJECTED: auth-walk: ${authModule} does not exist`);
    return 1;
  }
  const lab = buildLab(authLab, "command_token", authModule, out, "configured_auth_lab");
  if (!lab) return 2;
  const cases: AuthCase[] = [];
  let mismatching = false;
  for (const { requests, label } of AUTH_CASES) {
    const graph = await loadAuthGraph(out, requests, label);
    if (!graph) return 2;
    const walks = walksOf(graph);
    const run = runAuthLab(lab, walks, graph, requests, out, `configured_auth_lab-${label}`);
    if ("failure" in run) {
      console.log(run.failure);
      return 2;
    }
    const mismatches = authMismatches(walks, graph, run.results, requests, false);
    const steps = walks.reduce((sum, walk) => sum + walk.length, 0);
    console.log(`auth-walk ${label}: ${walks.length} walks, ${steps} steps, ${mismatches.length} mismatching walks`);
    for (const line of mismatches.slice(0, 3)) console.log(`  ${line}`);
    mismatching ||= mismatches.length > 0;
    cases.push({ requests, label, graph, walks, results: run.results });
  }
  const walked = new Set(cases.flatMap((c) => c.walks.flat().map((hop) => hop.label)));
  for (const label of Object.keys(AUTH_ACTION_OPS)) {
    if (!walked.has(label)) {
      console.log(`auth-walk: action ${label} was never walked`);
      return 1;
    }
  }
  if (mismatching) return 1;
  if (options.selfCheck) return authSelfCheck(out, cases[0]!);
  return 0;
}

// ---------------------------------------------------------------------------
// auth: end-to-end runs of `fx ask` with a command-auth helper, checked
// against ConfiguredAuth.tla through ConfiguredAuthTrace.tla.

type AuthHelperStep =
  | { kind: "token"; expires_at_offset_s?: number }
  | { kind: "fail"; exit_code?: number; stderr?: string }
  | { kind: "garbage" }
  | { kind: "hang"; delay_ms: number };

type AuthScenario = {
  id: string;
  valid_from: number;
  steps: AuthHelperStep[];
  near_expiry?: boolean;
  timeout_ms?: number;
  expect_exit: number;
  expect_error?: string;
  expect_auth_http_status?: number;
  expect_helper_runs?: number;
  expect_model_requests?: number;
};

type AuthLogEvent =
  | { kind: "helper_start"; run: number }
  | { kind: "helper_printed"; run: number; gen: number }
  | { kind: "helper_failed"; run: number }
  | { kind: "model_request"; r: "r1" | "r2"; gen: number; accepted: boolean };

type AuthObs = { act: string; r: string; c: string; gen: number; reason: string };

type AuthRunResult = {
  scenario: AuthScenario;
  log: AuthLogEvent[];
  observations: AuthObs[];
  exit: number;
  error: string | null;
  authHttpStatus: number | null;
  tail: string;
  verdict: Verdict;
  tlcDir: string;
};

const AUTH_SCENARIOS: AuthScenario[] = [
  { id: "fresh", valid_from: 1, steps: [{ kind: "token" }], expect_exit: 0, expect_helper_runs: 1, expect_model_requests: 2 },
  { id: "revoked", valid_from: 2, steps: [{ kind: "token" }, { kind: "token" }], expect_exit: 0, expect_helper_runs: 2, expect_model_requests: 3 },
  { id: "refused_twice", valid_from: 3, steps: [{ kind: "token" }, { kind: "token" }], expect_exit: 1, expect_auth_http_status: 401, expect_helper_runs: 2, expect_model_requests: 2 },
  { id: "helper_exits_nonzero", valid_from: 1, steps: [{ kind: "fail", exit_code: 3, stderr: "no session" }], expect_exit: 1, expect_error: "ConfiguredCommandAuthFailed", expect_helper_runs: 1, expect_model_requests: 0 },
  { id: "helper_garbage", valid_from: 1, steps: [{ kind: "garbage" }], expect_exit: 1, expect_error: "ConfiguredCommandAuthFailed", expect_helper_runs: 1, expect_model_requests: 0 },
  { id: "near_expiry", valid_from: 1, steps: [{ kind: "token", expires_at_offset_s: 10 }, { kind: "token" }], near_expiry: true, expect_exit: 0, expect_helper_runs: 2, expect_model_requests: 2 },
  { id: "helper_hangs", valid_from: 1, steps: [{ kind: "hang", delay_ms: 60_000 }], timeout_ms: 45_000, expect_exit: 1, expect_error: "ConfiguredCommandAuthFailed", expect_helper_runs: 1, expect_model_requests: 0 },
];

function obsValue(obs: AuthObs): string {
  return `[act |-> ${str(obs.act)}, r |-> ${str(obs.r)}, c |-> ${str(obs.c)}, gen |-> ${obs.gen}, reason |-> ${str(obs.reason)}]`;
}

function authTraceConstants(bug: string): string[] {
  return ['Requests = {"r1", "r2"}', "MaxGen = 3", 'Design = "b"', `Bug = ${str(bug)}`, "Nonideal = TRUE"];
}

function buildAuthObservations(
  scenario: AuthScenario,
  log: AuthLogEvent[],
  fxResult: { exit: number; error: string | null; authHttpStatus: number | null },
): AuthObs[] {
  const obs: AuthObs[] = [];
  const phase: Record<"r1" | "r2", "idle" | "waiting" | "sending" | "replay" | "done" | "failed"> = { r1: "idle", r2: "idle" };
  const refreshes: Record<"r1" | "r2", number> = { r1: 0, r2: 0 };
  let pendingHelper = false;
  let hasCache = false;
  let cacheExpired = false;
  let lastRequest: "r1" | "r2" = "r1";

  const nextRequest = (): "r1" | "r2" => (phase.r1 === "idle" || phase.r1 === "replay" ? "r1" : "r2");

  for (const event of log) {
    if (event.kind === "helper_start") {
      const r = nextRequest();
      if (phase[r] === "idle") {
        if (scenario.near_expiry && hasCache && !cacheExpired && r === "r2") {
          obs.push({ act: "Expire", r: "-", c: "c1", gen: 0, reason: "-" });
          cacheExpired = true;
        }
        obs.push({ act: "Begin", r, c: "-", gen: 0, reason: "-" });
      } else {
        obs.push({ act: "Replay", r, c: "-", gen: 0, reason: "-" });
      }
      phase[r] = "waiting";
      pendingHelper = true;
      lastRequest = r;
    } else if (event.kind === "helper_printed") {
      obs.push({ act: "HelperPrints", r: "-", c: "c1", gen: 0, reason: "-" });
      pendingHelper = false;
      hasCache = true;
      cacheExpired = false;
      for (const rk of ["r1", "r2"] as const) {
        if (phase[rk] === "waiting") phase[rk] = "sending";
      }
      if (event.gen < scenario.valid_from) {
        obs.push({ act: "Revoke", r: "-", c: "c1", gen: 0, reason: "-" });
      }
    } else if (event.kind === "helper_failed") {
      obs.push({ act: "HelperFails", r: "-", c: "c1", gen: 0, reason: "-" });
      pendingHelper = false;
      for (const rk of ["r1", "r2"] as const) {
        if (phase[rk] === "waiting") phase[rk] = "failed";
      }
    } else if (event.kind === "model_request") {
      const r = event.r;
      lastRequest = r;
      if (phase[r] === "idle") {
        obs.push({ act: "Begin", r, c: "-", gen: 0, reason: "-" });
        phase[r] = "sending";
      } else if (phase[r] === "replay") {
        obs.push({ act: "Replay", r, c: "-", gen: 0, reason: "-" });
        phase[r] = "sending";
      }
      obs.push({ act: "Sent", r, c: "-", gen: event.gen, reason: "-" });
      if (event.accepted) {
        obs.push({ act: "Accept", r, c: "-", gen: 0, reason: "-" });
        phase[r] = "done";
        obs.push({ act: "Ended", r, c: "-", gen: 0, reason: "none" });
      } else {
        obs.push({ act: "Reject", r, c: "-", gen: 0, reason: "-" });
        hasCache = false;
        if (refreshes[r] === 0) {
          refreshes[r] = 1;
          phase[r] = "replay";
        } else {
          phase[r] = "failed";
        }
      }
    }
  }

  if (pendingHelper && fxResult.error === "ConfiguredCommandAuthFailed") {
    obs.push({ act: "Deadline", r: "-", c: "c1", gen: 0, reason: "-" });
    pendingHelper = false;
    phase[lastRequest] = "failed";
  }

  if (phase[lastRequest] !== "done") {
    const reason = fxResult.error === "ConfiguredCommandAuthFailed" ? "helper"
      : fxResult.authHttpStatus === 401 ? "rejected"
      : "unknown";
    obs.push({ act: "Ended", r: lastRequest, c: "-", gen: 0, reason });
  }
  return obs;
}

async function runAuth(fixtures: any, scenario: AuthScenario, out: string): Promise<AuthRunResult> {
  const fakeHelperPath = join(REPO_ROOT, "tests/tla/drivers/configured_provider/fake-helper.ts");
  const log: AuthLogEvent[] = [];
  let activeRequest: "r1" | "r2" = "r1";
  let unexpectedAuth = false;

  const f = fixtures.createConfiguredProviderFixture(
    (body: any) => {
      const req = f.requests.at(-1)!;
      const match = /^Bearer tok-(\d+)$/.exec(req.authorization ?? "");
      if (!match) {
        unexpectedAuth = true;
        return new Response("missing or unexpected bearer token", { status: 401 });
      }
      const gen = Number(match[1]);
      const r = activeRequest;
      const accepted = gen >= scenario.valid_from;
      log.push({ kind: "model_request", r, gen, accepted });
      if (!accepted) {
        return Response.json({ error: { message: "unauthorized" } }, { status: 401 });
      }
      if (r === "r1") {
        activeRequest = "r2";
        return fixtures.toolCompletion(body.model, "read_file", { path: "note.txt" }, "call-1");
      }
      return fixtures.completion(body.model, "DONE");
    },
    {
      "/helper": (body: any) => {
        if (body.event === "start") log.push({ kind: "helper_start", run: body.run });
        else if (body.event === "printed") log.push({ kind: "helper_printed", run: body.run, gen: body.gen });
        else if (body.event === "failed") log.push({ kind: "helper_failed", run: body.run });
        return Response.json({ ok: true });
      },
    },
  );

  const runDir = mkdtempSync(join(out, `auth-run-${scenario.id}-`));
  try {
    writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
    const baseUrl = f.settings.providers.local.base_url as string;
    const helperUrl = `${new URL(baseUrl).origin}/helper`;
    writeFileSync(join(runDir, "scenario.json"), JSON.stringify({ server_url: helperUrl, steps: scenario.steps }));

    f.settings.providers.local = {
      protocol: "openai-chat-completions",
      base_url: baseUrl,
      auth: { type: "command", command: [process.execPath, fakeHelperPath, runDir] },
      model_metadata: { "local-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
    };
    f.save();

    const child = Bun.spawn([binary, "ask", "--json", "--no-save", "Read note.txt"], {
      cwd: f.workspace,
      env: testEnvironment({ HOME: f.home, FX_SOUND: "0", NO_COLOR: "1" }),
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), scenario.timeout_ms ?? 30_000);
    const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);

    let error: string | null = null;
    let authHttpStatus: number | null = null;
    try {
      const parsed = JSON.parse(stdout.trim());
      error = parsed.error ?? null;
      authHttpStatus = parsed.auth_failure?.http_status ?? null;
    } catch {
      error = "unreadable_output";
    }

    const observations = buildAuthObservations(scenario, log, { exit, error, authHttpStatus });
    writeJson(join(out, `auth-${scenario.id}.json`), {
      scenario: scenario.id,
      raw_log: log,
      observations,
      fx: { exit, error, auth_http_status: authHttpStatus, tail: `${stdout}\n${stderr}`.slice(-300) },
    });

    const helperStarts = log.filter((e) => e.kind === "helper_start").length;
    const modelRequests = log.filter((e) => e.kind === "model_request").length;
    const expectedOk =
      !unexpectedAuth &&
      exit === scenario.expect_exit &&
      (scenario.expect_error === undefined || error === scenario.expect_error) &&
      (scenario.expect_auth_http_status === undefined || authHttpStatus === scenario.expect_auth_http_status) &&
      (scenario.expect_helper_runs === undefined || helperStarts === scenario.expect_helper_runs) &&
      (scenario.expect_model_requests === undefined || modelRequests === scenario.expect_model_requests);

    const trace = await runTrace("ConfiguredAuth", observations.map(obsValue).join(", "), authTraceConstants("none"), out, `auth-${scenario.id}`);
    return {
      scenario,
      log,
      observations,
      exit,
      error,
      authHttpStatus,
      tail: `${stdout}\n${stderr}`.slice(-300),
      verdict: expectedOk ? trace.verdict : "REJECTED",
      tlcDir: trace.dir,
    };
  } finally {
    f.close();
  }
}

async function authTraceSelfCheck(out: string, runs: AuthRunResult[]): Promise<number> {
  for (const run of runs) {
    const today = await runTrace("ConfiguredAuth", run.observations.map(obsValue).join(", "), authTraceConstants("today"), out, `auth-today-${run.scenario.id}`);
    console.log(`self-check, auth ${run.scenario.id} against Bug = "today": ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }

  const revoked = runs.find((r) => r.scenario.id === "revoked")!;
  const replayAt = revoked.observations.findIndex((o) => o.act === "Replay");
  const tamperedResend: AuthObs[] = [
    ...revoked.observations.slice(0, replayAt + 1),
    { act: "Sent", r: "r1", c: "-", gen: 1, reason: "-" },
  ];
  const resendVerdict = await runTrace("ConfiguredAuth", tamperedResend.map(obsValue).join(", "), authTraceConstants("none"), out, "auth-tamper-resend");
  console.log(`self-check, auth replay sends refused generation again: ${resendVerdict.verdict} (must be REJECTED)`);
  if (resendVerdict.verdict !== "REJECTED") return resendVerdict.verdict === "TOOL_ERROR" ? 2 : 1;

  const tamperedSecondRun: AuthObs[] = [
    { act: "Begin", r: "r1", c: "-", gen: 0, reason: "-" },
    { act: "Begin", r: "r2", c: "-", gen: 0, reason: "-" },
    { act: "HelperPrints", r: "-", c: "c1", gen: 0, reason: "-" },
    { act: "HelperPrints", r: "-", c: "c1", gen: 0, reason: "-" },
  ];
  const secondRunVerdict = await runTrace("ConfiguredAuth", tamperedSecondRun.map(obsValue).join(", "), authTraceConstants("none"), out, "auth-tamper-second-run");
  console.log(`self-check, auth helper runs a second time while one runs: ${secondRunVerdict.verdict} (must be REJECTED)`);
  if (secondRunVerdict.verdict !== "REJECTED") return secondRunVerdict.verdict === "TOOL_ERROR" ? 2 : 1;
  return 0;
}

async function authPart(out: string): Promise<number> {
  const fixtures = await targetModule("fixtures/chat-completions.ts");
  const fast = AUTH_SCENARIOS.filter((s) => s.id !== "helper_hangs");
  const slow = AUTH_SCENARIOS.filter((s) => s.id === "helper_hangs");
  const runs = [
    ...(await pool(fast.length, Math.min(options.jobs, fast.length), (i) => runAuth(fixtures, fast[i]!, out))),
    ...(await pool(slow.length, 1, (i) => runAuth(fixtures, slow[i]!, out))),
  ];
  for (const run of runs) {
    console.log(`auth ${run.scenario.id}: ${run.verdict} (TLC work ${run.tlcDir})`);
    if (run.verdict === "TOOL_ERROR") return 2;
    if (run.verdict === "REJECTED") {
      const mismatch = await firstMismatch(run.observations, async (prefix) =>
        (await runTrace("ConfiguredAuth", prefix.map(obsValue).join(", "), authTraceConstants("none"), out, `auth-mismatch-${run.scenario.id}`)).verdict);
      console.log(`first observation the model cannot produce (${run.scenario.id}): ${JSON.stringify(mismatch)}`);
      console.log(`evidence (${run.scenario.id}): exit=${run.exit} error=${run.error} auth_http_status=${run.authHttpStatus} log=${JSON.stringify(run.log)} tail=${JSON.stringify(run.tail)}`);
      return 1;
    }
  }
  if (options.selfCheck) return authTraceSelfCheck(out, runs);
  return 0;
}

async function main(): Promise<number> {
  if (options.parts.some((part) => ["request", "catalog", "resume", "auth"].includes(part)) && !existsSync(binary)) {
    console.log(`TOOL_ERROR: missing ${binary}; run zig build first`);
    return 2;
  }
  const out = outDir("configured_provider");
  const run: Record<string, (out: string) => Promise<number>> = {
    request: requestPart, catalog: catalogPart, resume: resumePart, deadlines: deadlinesPart, "auth-walk": authWalkPart, auth: authPart,
  };
  let worst = 0;
  for (const part of options.parts) worst = Math.max(worst, await run[part]!(out));
  console.log(`${worst === 0 ? "ACCEPTED" : worst === 1 ? "REJECTED" : "TOOL_ERROR"}; output in ${out}`);
  return worst;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
