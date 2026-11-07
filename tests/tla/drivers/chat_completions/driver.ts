// Runs the built fx binary along tests/tla/chat_completions/ChatStream.tla and
// has TLC check every reply it observes (ChatStreamTrace.tla).
//
// Each run is one `fx ask` on a configured openai-chat-completions connection
// whose local fake server streams one reply made of ChatStream's events: body
// chunks, a finished choice, usage trailers, and an end ([DONE], a clean
// close, or a close inside an unterminated last event). A chunk's model may be
// absent, empty, or one of two names, and its delta may carry an empty or a
// populated legacy function_call. A chunk's usage is the model's count n:
// {prompt_tokens: 12, completion_tokens: n, total_tokens: 12 + n}. Where the
// model drops a count, on a chunk with a choice whose n is below the largest
// count so far, the wire may instead be Cloudflare's per-chunk delta, with
// prompt_tokens 0 and a completion count that may even rise. The driver runs a
// named list of edge cases, then --random seeded replies. Wire details the
// model treats as the same, such as an omitted or null finish_reason, the
// shape of an empty function_call, and the shape of a dropped count, are drawn
// from the seed too.
//
// For each run it records the events sent, whether fx completed the reply
// (exit 0) or failed it, the error fx named, and the completion tokens fx
// reported. When fx completes a reply with a tool call it runs the tool and
// asks again; the server answers that with plain text and no usage. TLC
// replays every run through the model's own actions, and a completed reply
// must report the count the model kept. --self-check also replays them
// through the model of fx before the change (Bug = "today"), which must
// reject them. --bug NAME checks them against another of the model's Bug
// values instead of the design; on fx just before the usage change, use
// --bug old_usage.
//
// Every fx process runs under `env -i` with each variable written out: a
// temporary HOME and FX_HOME, FX_DISABLE_KEYCHAIN=1, FX_SOUND=0, a fake key,
// and Gateway URLs that point back at the local server. A request to any path
// but the connection's chat URL is a harness failure.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/chat_completions/driver.ts
//   bun tests/tla/drivers/chat_completions/driver.ts --self-check
//   bun tests/tla/drivers/chat_completions/driver.ts --random 300 --seed 7 --jobs 8
//   FX_BIN=/path/to/other/fx bun tests/tla/drivers/chat_completions/driver.ts --bug today
//
// Exit codes: 0 every reply accepted (and the self-check rejected), 1 a reply
// the model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary } from "../lib/context";
import { TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Choice = "none" | "empty" | "content" | "call" | "stop" | "tools";
type Model = "absent" | "empty" | "a" | "b";
type LegacyCall = "none" | "empty" | "full";
// `usage` is the model's count, 0 for a chunk without usage.
type Chunk = { kind: "chunk"; choice: Choice; model: Model; fc: LegacyCall; usage: number };
type End = { kind: "done" | "eof" | "cut" };
type Event = Chunk | End;
type Outcome = "completed" | "failed" | "unknown";
type Observation = {
  id: string;
  events: Event[];
  outcome: Outcome;
  error: string;
  usage: number;
  evidence: { exit: number; requests: number; paths: string[]; final_output: string; reported: unknown; tail: string; seed: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tlaDir = join(TLA_ROOT, "chat_completions");
const MODEL = "local-model";
const NAMES: Record<Model, string | null> = { absent: null, empty: "", a: "served-model-a", b: "served-model-b" };
const PROMPT_TOKENS = 12;
const BUGS = ["none", "today", "old_usage", "old_model", "old_function_call", "old_eof", "old_reason",
  "old_progress", "old_finish", "eof_any_phase", "skip_models", "accept_call", "late_content", "no_usage",
  "skip_tools", "lax_final", "skip_progress"];

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function textOption(name: string, fallback: string): string {
  const at = process.argv.indexOf(name);
  return at < 0 ? fallback : String(process.argv[at + 1] ?? "");
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  random: option("--random", 150),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
  bug: textOption("--bug", "none"),
};
if (!BUGS.includes(options.bug)) throw new Error(`--bug takes one of ${BUGS.join(", ")}`);

// mulberry32: a small seeded generator, so a failing reply replays.
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

function pick<T>(next: () => number, weighted: Array<[T, number]>): T {
  const total = weighted.reduce((sum, [, weight]) => sum + weight, 0);
  let roll = next() * total;
  for (const [value, weight] of weighted) {
    roll -= weight;
    if (roll < 0) return value;
  }
  return weighted.at(-1)![0];
}

const c = (choice: Choice, model: Model = "absent", fc: LegacyCall = "none", usage = 0): Chunk =>
  ({ kind: "chunk", choice, model, fc, usage });
// A chunk with no model or function_call that reports usage count n.
const u = (choice: Choice, n: number): Chunk => c(choice, "absent", "none", n);
const done: End = { kind: "done" };
const eof: End = { kind: "eof" };
const cut: End = { kind: "cut" };

// Every reply opens with text, so a completed one always has an answer.
const opening = c("content");

// The edge cases the examiner reports name, one reply each.
const EDGES: Event[][] = [
  [c("content", "empty"), c("stop", "empty"), c("none", "empty", "none", 1), done],
  [c("content", "empty"), c("content", "a"), c("stop", "empty"), c("none", "empty", "none", 1), done],
  [c("content", "a"), c("stop", "b"), done],
  [c("content", "a"), c("stop", "a", "empty", 1), done],
  [c("empty", "absent", "empty"), c("stop"), done],
  [c("stop", "absent", "full"), done],
  [c("call", "absent", "full"), c("tools"), done],
  [c("stop"), c("stop", "absent", "empty", 1), done],
  [c("stop"), c("empty", "absent", "full", 1), done],
  [c("stop"), eof],
  [c("stop"), u("none", 1), eof],
  [c("stop"), cut],
  [c("stop"), u("none", 1), cut],
  [eof],
  [cut],
  [done],
  [c("stop"), u("empty", 1), done],
  [c("stop"), u("empty", 1), eof],
  [c("stop"), c("empty"), done],
  [c("stop"), u("content", 1), done],
  [c("stop"), u("tools", 1), done],
  [c("call"), c("tools"), eof],
  [c("call"), c("tools"), u("empty", 1), eof],
  [c("call"), eof],
  [c("call"), cut],
  [c("call"), c("stop"), done],
  [c("tools"), done],
  [u("none", 1), c("stop"), done],
  [c("content", "empty"), c("stop", "empty", "empty"), c("empty", "empty", "none", 1), eof],
  // Usage. Per-chunk counts that fall, one on the finish chunk too, before a
  // cumulative trailer of either shape (PR #1203).
  [u("content", 2), u("empty", 1), u("stop", 1), u("none", 2), done],
  [u("content", 2), u("empty", 1), u("stop", 1), u("stop", 2), done],
  // The examiner's delta_usage reply: a finish chunk without usage.
  [u("content", 2), u("content", 1), c("stop"), u("none", 2), done],
  // No trailer: fx records the largest count it kept.
  [u("content", 2), u("content", 1), u("stop", 1), done],
  [u("content", 2), u("content", 1), u("stop", 1), eof],
  [u("content", 1), u("content", 2), c("stop"), eof],
  // An equal count is kept; the trailer may match it.
  [u("content", 1), u("content", 1), c("stop"), u("none", 1), done],
  // A finish chunk's count is provisional, so a larger trailer replaces it.
  [u("stop", 1), u("none", 2), done],
  // Final counts stay strict: below a provisional count, or unlike the first.
  [u("content", 2), c("stop"), u("none", 1), done],
  [u("content", 2), u("stop", 1), u("empty", 1), done],
  [c("stop"), u("none", 2), u("none", 1), done],
  [c("stop"), u("none", 1), u("none", 2), done],
  [c("stop"), u("none", 1), u("stop", 2), eof],
  // A dropped count with a tool call, and cuts right after a dropped count.
  [u("call", 2), u("tools", 1), u("none", 2), done],
  [u("content", 2), u("content", 1), cut],
  [u("content", 2), u("call", 1), eof],
  [u("content", 2), u("stop", 1), u("none", 2), cut],
];

function randomReply(next: () => number): Event[] {
  const model = (): Model => pick(next, [["absent", 4], ["empty", 3], ["a", 2.5], ["b", 0.5]]);
  const fc = (): LegacyCall => pick(next, [["none", 7], ["empty", 2.5], ["full", 0.5]]);
  const usage = () => pick(next, [[0, 6], [1, 2], [2, 2]]);
  const final = () => pick(next, [[0, 2], [1, 4], [2, 4]]);
  const events: Event[] = [];
  const body = Math.floor(next() * 3);
  for (let n = 0; n < body; n++) {
    events.push(c(pick(next, [["content", 5], ["empty", 2], ["call", 2], ["none", 1]]), model(), fc(), usage()));
  }
  if (next() < 0.9) {
    events.push(c(pick(next, [["stop", 7], ["tools", 3]]), model(), fc(), usage()));
    const trailers = Math.floor(next() * 3);
    for (let n = 0; n < trailers; n++) {
      events.push(c(pick(next, [["none", 4], ["empty", 3], ["stop", 1.5], ["tools", 0.5], ["content", 0.5], ["call", 0.5]]),
        model(), fc(), final()));
    }
  }
  events.push(pick(next, [[done, 4], [eof, 4], [cut, 2]]));
  return events;
}

function replies(): Event[][] {
  const next = generator(options.seed);
  const all = EDGES.map((events) => [opening, ...events]);
  for (let n = 0; n < options.random; n++) all.push([opening, ...randomReply(next)]);
  return all;
}

// The wire form of one reply. `next` draws the details the model ignores.
function wire(events: Event[], next: () => number): string {
  let sawCall = false;
  // The largest count on a chunk with a choice so far, and whether the
  // finished choice has gone out: after it every chunk is a trailer.
  let kept = 0;
  let finished = false;
  const usageFor = (event: Chunk) => {
    const n = event.usage;
    const provisional = !finished && event.choice !== "none";
    if (provisional && n < kept && next() < 0.5) {
      // Cloudflare's per-chunk delta: no prompt tokens, and a completion
      // count that may rise while the prompt count falls.
      const completion = pick(next, [[n, 1], [kept + 1, 1]]);
      return { prompt_tokens: 0, completion_tokens: completion, total_tokens: completion };
    }
    if (provisional) kept = Math.max(kept, n);
    return { prompt_tokens: PROMPT_TOKENS, completion_tokens: n, total_tokens: PROMPT_TOKENS + n };
  };
  const frames: string[] = [];
  events.forEach((event, index) => {
    if (event.kind === "done") return frames.push("data: [DONE]\n\n");
    if (event.kind === "eof") return;
    if (event.kind === "cut") {
      // A finish event the close interrupts: the reader must drop it.
      return frames.push(`data: ${JSON.stringify({ id: "chat-tla", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}`);
    }
    const chunk: Record<string, unknown> = { id: "chat-tla", object: "chat.completion.chunk" };
    const name = NAMES[event.model];
    if (name !== null) chunk.model = name;
    if (event.choice === "none") {
      chunk.choices = [];
    } else {
      const delta: Record<string, unknown> = {};
      if (event.choice === "content") delta.content = index === 0 ? "streamed reply" : ` part ${index}`;
      if (event.choice === "call") {
        delta.tool_calls = [sawCall
          ? { index: 0, function: { arguments: "" } }
          : { index: 0, id: "call-tla", type: "function", function: { name: "read_file", arguments: JSON.stringify({ path: "note.txt" }) } }];
        sawCall = true;
      }
      if (event.fc === "empty") delta.function_call = pick(next, [[{ name: "", arguments: "" }, 2], [{}, 1], [{ name: null, arguments: null }, 1]]);
      if (event.fc === "full") delta.function_call = { name: "read_file", arguments: "{}" };
      const choice: Record<string, unknown> = { index: 0, delta };
      if (event.choice === "stop") choice.finish_reason = "stop";
      else if (event.choice === "tools") choice.finish_reason = "tool_calls";
      else if (next() < 0.5) choice.finish_reason = null;
      chunk.choices = [choice];
    }
    if (event.usage > 0) chunk.usage = usageFor(event);
    if (event.choice === "stop" || event.choice === "tools") finished = true;
    frames.push(`data: ${JSON.stringify(chunk)}\n\n`);
  });
  return frames.join("");
}

function plainReply(): string {
  const chunks = [
    { id: "chat-after", model: MODEL, choices: [{ index: 0, delta: { role: "assistant", content: "after the tool" }, finish_reason: null }] },
    { id: "chat-after", model: MODEL, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ];
  return chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
}

async function runReply(id: string, events: Event[], seed: number, scratch: string): Promise<Observation> {
  const body = wire(events, generator(seed));
  const paths: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      paths.push(path);
      if (request.method === "POST") await request.text();
      if (path !== "/v1/chat/completions") return new Response("unexpected endpoint", { status: 500 });
      const text = paths.filter((seen) => seen === "/v1/chat/completions").length === 1 ? body : plainReply();
      return new Response(text, { headers: { "content-type": "text/event-stream" } });
    },
  });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const workspace = join(root, "workspace");
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(workspace, "note.txt"), "fixture\n");
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({
    provider: "local",
    auto_upgrade: false,
    permission_mode: "ask",
    providers: {
      local: {
        protocol: "openai-chat-completions",
        base_url: `http://127.0.0.1:${server.port}/v1`,
        auth: { type: "none" },
        model_metadata: { [MODEL]: { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
      },
    },
    models: { local: MODEL },
  }), { mode: 0o600 });
  const unexpected = `http://127.0.0.1:${server.port}/unexpected-gateway`;
  try {
    const child = Bun.spawn([
      "/usr/bin/env", "-i",
      `PATH=${process.env.PATH ?? "/usr/bin:/bin"}`,
      `HOME=${home}`,
      `FX_HOME=${fxHome}`,
      `TMPDIR=${root}`,
      "FX_DISABLE_KEYCHAIN=1",
      "FX_SOUND=0",
      "FX_AUTO_UPGRADE=0",
      "FX_E2E_DISABLE_DOTENV=1",
      "NO_COLOR=1",
      `FX_GATEWAY_CHAT_URL=${unexpected}`,
      `FX_GATEWAY_BASE_URL=${unexpected}`,
      "AI_GATEWAY_API_KEY=fake-chat-stream-driver-key",
      binary, "ask", "--json", "--no-save", "say hello",
    ], { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill(9), 30_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    let parsed: { final_output?: unknown; error?: unknown; usage?: { output_tokens?: unknown } } = {};
    try {
      parsed = JSON.parse(stdout.trim());
    } catch {
      parsed = {};
    }
    const chats = paths.filter((path) => path === "/v1/chat/completions").length;
    let outcome: Outcome = "unknown";
    let error = "none";
    // fx adds every step's usage and prints null for a count no step reported.
    const reported = parsed.usage?.output_tokens;
    const usage = typeof reported === "number" ? reported : 0;
    if (exit === 0 && typeof parsed.final_output === "string" && (reported === null || typeof reported === "number")) {
      outcome = "completed";
    } else if (exit === 1 && typeof parsed.error === "string" && chats === 1) {
      outcome = "failed";
      error = parsed.error;
    }
    return {
      id,
      events,
      outcome,
      error,
      usage,
      evidence: {
        exit,
        requests: chats,
        paths,
        final_output: String(parsed.final_output ?? ""),
        reported: parsed.usage ?? null,
        tail: `${stdout}\n${stderr}`.slice(-400),
        seed,
      },
    };
  } finally {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const tlaEvent = (event: Event) => event.kind === "chunk"
  ? `[kind |-> "chunk", choice |-> ${str(event.choice)}, model |-> ${str(event.model)}, fc |-> ${str(event.fc)}, usage |-> ${event.usage}]`
  : `[kind |-> ${str(event.kind)}, choice |-> "none", model |-> "absent", fc |-> "none", usage |-> 0]`;

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[events |-> <<${o.events.map(tlaEvent).join(", ")}>>, outcome |-> ${str(o.outcome)}, error |-> ${str(o.error)}, usage |-> ${o.usage}]`;
  return [
    "------------------------- MODULE ChatStreamObserved -------------------------",
    "(* Generated by tests/tla/drivers/chat_completions/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["ChatStream.tla", "ChatStreamTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "ChatStreamObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "ChatStreamTrace.tla"], {
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
async function firstMismatch(observations: Observation[], bug: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const out = outDir("chat_completions");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const cases = replies();
  const observations: Observation[] = new Array(cases.length);
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < cases.length) {
      const index = next++;
      observations[index] = await runReply(`reply${index}`, cases[index]!, options.seed * 100_003 + index, scratch);
    }
  });
  await Promise.all(workers);
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) {
    const key = o.outcome === "failed" ? `failed ${o.error}` : o.outcome;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  console.log(`${observations.length} replies through ${binary} in ${seconds}s, outcomes ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const stray = observations.find((o) => o.evidence.requests === 0 || o.evidence.paths.some((path) => path !== "/v1/chat/completions"));
  if (stray) {
    console.log(`TOOL_ERROR: ${stray.id} reached paths ${JSON.stringify(stray.evidence.paths)}: ${JSON.stringify(stray.evidence)}`);
    return 2;
  }
  const unknown = observations.find((o) => o.outcome === "unknown");
  if (unknown) {
    console.log(`REJECTED: ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  const checked = await runTrace(observations, options.bug, out);
  console.log(`model with Bug = ${str(options.bug)}: ${checked.verdict} (TLC work ${checked.dir})`);
  if (checked.verdict === "TOOL_ERROR") return 2;
  if (checked.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, options.bug, out);
    console.log(`first reply the model cannot produce: ${JSON.stringify(mismatch)}`);
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
