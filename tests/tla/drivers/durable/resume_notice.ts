// Runs real libfx along tests/tla/durable/Resumption.tla and has TLC check
// every scenario it observes (ResumptionTrace.tla).
//
// A scenario is a session of one or more turns. Each turn asks the model for a
// number of lookups, one tool call per response, then an answer. Each life of
// a turn is one libfx process (resume_notice_run.mjs, on the built native
// addon or fx-core.wasm) on a journal kept in a file: the first life starts
// the turn, and every later one resumes it. A life ends in one of these:
//
//   kill@j   SIGKILL while its request j is in flight, once the store is quiet
//   fence@j  the store refuses every append after request j, as when another
//            worker took the session over
//   hang     its first append never lands, then SIGKILL
//   yield    a deadline long past, so the turn stops at its first chance
//   tail     the turn ends, and the store loses its end record
//   drop@j   (with any of the above) request j's connection drops, and the
//            core asks again
//
// or the turn ends. For each request the local fake gateway records what it
// carried of the open turn, in order: each tool step, and each "Resuming from
// unexpected session interruption." notice. From what the process did, the
// driver writes the scenario as Resumption.tla actions, and TLC replays every
// scenario through the model's own actions. --self-check also replays them
// through the notice rule fx had before (#1584, Rule = "each") and the one
// #1615 proposed (Rule = "moved"), which must each reject them. --direct
// checks the same rules on the requests themselves instead of with TLC, for
// long fuzz and stress runs.
//
// Usage (from the repository root, after zig build libfx-napi -Dnapi-surface=core
// and, for --backend wasm, zig build fx-core-wasm -Dwasm-surface=core):
//   bun tests/tla/drivers/durable/resume_notice.ts [--backend native|wasm] [--self-check] [--only <pattern>]
//   bun tests/tla/drivers/durable/resume_notice.ts --fuzz 60 --seed 7 [--direct]
//   bun tests/tla/drivers/durable/resume_notice.ts --no-named --stress 100 [--direct]
//   bun tests/tla/drivers/durable/resume_notice.ts --replay <out>/rejected.json
//
// Every process it starts gets a clean environment (FX_SOUND=0,
// FX_DISABLE_KEYCHAIN=1, a temporary HOME and FX_HOME, a fake key) and reaches
// only the fake gateway. Exit codes: 0 every scenario accepted (and the
// self-check rejected), 1 a scenario the model cannot produce, 2 a toolchain,
// build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { targetHelpers, testEnvironment } from "../lib/context";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Interrupt =
  | { kind: "kill"; at: number }
  | { kind: "fence"; at: number }
  | { kind: "hang" }
  | { kind: "tail" };
type Life = { yield?: boolean; drop?: number; interrupt?: Interrupt };
type TurnPlan = { steps: number; lives: Life[] };
type Scenario = { name: string; turns: TurnPlan[] };
type Act = { a: string; run: string[] };
type Request = { content: string[]; afterCall: boolean; response: string };
type Observation = { name: string; acts: Act[]; requests: number; lives: number; seconds: number; lastNotices: number };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const NOTICE = "Resuming from unexpected session interruption.";
const MODEL = "journal/model";
const TURN = /^turn (\d+) needs (\d+) lookups$/;
const tlaDir = join(TLA_ROOT, "durable");
const runner = join(import.meta.dirname, "resume_notice_run.mjs");
const lifeTimeoutMs = 60_000;
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

const argv = process.argv.slice(2);
function count(name: string, fallback: number): number {
  const at = argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}
function text(name: string, fallback: string): string {
  const at = argv.indexOf(name);
  return at < 0 ? fallback : String(argv[at + 1]);
}
const options = {
  backend: text("--backend", "native"),
  selfCheck: argv.includes("--self-check"),
  direct: argv.includes("--direct"),
  named: !argv.includes("--no-named"),
  only: new RegExp(text("--only", "")),
  fuzz: count("--fuzz", 0),
  seed: count("--seed", 1),
  stress: count("--stress", 0),
  jobs: Math.max(1, count("--jobs", 4)),
  replay: text("--replay", ""),
};
if (!["native", "wasm"].includes(options.backend)) throw new Error("--backend is native or wasm");

const kill = (at: number): Life => ({ interrupt: { kind: "kill", at } });
const fence = (at: number): Life => ({ interrupt: { kind: "fence", at } });
const hang: Life = { interrupt: { kind: "hang" } };
const tail: Life = { interrupt: { kind: "tail" } };
const ends: Life = {};

// The edge cases, by name.
const named: Scenario[] = [
  { name: "resumed twice", turns: [{ steps: 0, lives: [kill(1), kill(1), ends] }] },
  { name: "resumed three times with a step between", turns: [{ steps: 2, lives: [kill(1), kill(2), kill(2), ends] }] },
  { name: "yielded, then resumed", turns: [{ steps: 2, lives: [{ yield: true }, ends] }] },
  { name: "resumed after a crash, yielded, resumed", turns: [{ steps: 3, lives: [kill(1), { yield: true }, ends] }] },
  { name: "yielded, resumed, crashed after a step", turns: [{ steps: 3, lives: [{ yield: true }, kill(2), ends] }] },
  { name: "yielded, then resumed after two crashes", turns: [{ steps: 3, lives: [{ yield: true }, kill(2), kill(1), ends] }] },
  { name: "crashed before the resumed turn's first progress, twice", turns: [{ steps: 1, lives: [kill(1), hang, hang, ends] }] },
  { name: "crashed after the final reply was saved", turns: [{ steps: 1, lives: [kill(1), tail, ends] }] },
  { name: "a second turn gets its own notice", turns: [{ steps: 1, lives: [kill(2), kill(1), ends] }, { steps: 0, lives: [kill(1), ends] }] },
  { name: "fenced twice", turns: [{ steps: 2, lives: [kill(1), fence(2), fence(1), ends] }] },
  { name: "a dropped request asked again, then a crash", turns: [{ steps: 1, lives: [kill(1), { drop: 1, interrupt: { kind: "kill", at: 3 } }, ends] }] },
];

// mulberry32: a small seeded generator, so a failing scenario replays.
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

function fuzzed(total: number, seed: number): Scenario[] {
  const next = generator(seed);
  const pick = (n: number) => Math.floor(next() * n);
  const scenarios: Scenario[] = [];
  for (let index = 0; index < total; index++) {
    const turns: TurnPlan[] = [];
    for (let t = 0, n = 1 + pick(2); t < n; t++) {
      const steps = pick(4);
      const lives: Life[] = [];
      for (let l = 0, m = 1 + pick(4); l < m; l++) {
        const choice = pick(10);
        const at = 1 + pick(steps + 1);
        if (choice < 4) lives.push(kill(at));
        else if (choice < 6) lives.push(fence(at));
        else if (choice < 7 && l > 0) lives.push(hang);
        else if (choice < 8 && steps > 0) lives.push({ yield: true });
        else if (choice < 9) lives.push(tail);
        else if (pick(4) === 0) lives.push({ drop: 1, interrupt: { kind: "kill", at: 2 } });
        else lives.push(kill(at));
      }
      lives.push(ends);
      turns.push({ steps, lives });
    }
    scenarios.push({ name: `fuzz seed ${seed} #${index}`, turns });
  }
  return scenarios;
}

// One turn resumed `n` times, one more tool step each time.
function stressed(n: number): Scenario {
  return { name: `stress: ${n} resumes`, turns: [{ steps: n, lives: [...Array.from({ length: n }, () => kill(2)), ends] }] };
}

const textOf = (message: any): string => typeof message.content === "string"
  ? message.content
  : (message.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("");
const turnStart = (prompt: any[]) => prompt.findLastIndex((m) => m.role === "user" && TURN.test(textOf(m)));

// What a request carried of its open turn, in order.
function turnContent(prompt: any[]): string[] {
  const out: string[] = [];
  for (const message of prompt.slice(turnStart(prompt) + 1)) {
    if (message.role === "tool") out.push("step");
    else if (message.role === "user") out.push(textOf(message) === NOTICE ? "notice" : `unexpected: ${textOf(message).slice(0, 80)}`);
  }
  return out;
}

// The fake model: a lookup until the turn has the steps it asks for, then an answer.
function reply(prompt: any[]): { kind: "call" | "answer"; frames: unknown[] } {
  const [, turn, wanted] = TURN.exec(textOf(prompt[turnStart(prompt)]))!;
  const done = prompt.slice(turnStart(prompt) + 1).filter((m) => m.role === "tool").length;
  if (done < Number(wanted)) {
    return {
      kind: "call",
      frames: [
        { type: "tool-call", toolCallId: `call-${turn}-${done}`, toolName: "lookup", input: { key: `k${done}` } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ],
    };
  }
  return {
    kind: "answer",
    frames: [
      { type: "text-delta", id: "answer", delta: `turn ${turn} done` },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ],
  };
}

const storeSize = (path: string) => (existsSync(path) ? statSync(path).size : 0);
const storeEvents = (path: string): any[] => (existsSync(path)
  ? readFileSync(path, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
  : []);

// Waits until nothing has reached the store for a while: the process is held
// on its request, so everything it wrote before that request has landed.
async function quiet(path: string, ms = 200) {
  const started = Date.now();
  let last = storeSize(path);
  let since = Date.now();
  while (Date.now() - since < ms && Date.now() - started < 10_000) {
    await Bun.sleep(20);
    const size = storeSize(path);
    if (size !== last) {
      last = size;
      since = Date.now();
    }
  }
}

type LifeState = {
  plan: Life;
  requests: Request[];
  lastKind: string | null;
  child: ReturnType<typeof Bun.spawn> | null;
  killed: boolean;
  killedAt: number | null;
  fencedAt: number | null;
  storedAtFence: number;
};

class HarnessError extends Error {}

async function runScenario(helpers: any, scenario: Scenario, scratch: string): Promise<Observation> {
  const started = performance.now();
  const dir = mkdtempSync(join(scratch, "scenario-"));
  const store = join(dir, "journal.jsonl");
  const fencePath = join(dir, "fenced");
  const home = join(dir, "home");
  const fxHome = join(dir, "fx-home");
  mkdirSync(home, { recursive: true });
  mkdirSync(fxHome, { recursive: true });
  let life: LifeState | null = null;
  let handled = 0;
  const stopChild = async (state: LifeState) => {
    state.killed = true;
    state.child?.kill("SIGKILL");
    await state.child?.exited;
  };
  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    handled += 1;
    const state = life;
    if (!state || state.killed || state.fencedAt !== null) return new Response("this worker is gone", { status: 503 });
    const prompt = JSON.parse(body).prompt as any[];
    const j = state.requests.length + 1;
    const request: Request = { content: turnContent(prompt), afterCall: state.lastKind === "call", response: "" };
    state.requests.push(request);
    const interrupt = state.plan.interrupt;
    if (interrupt?.kind === "hang") {
      request.response = "ignored";
      await stopChild(state);
      return new Response("", { status: 503 });
    }
    if (interrupt?.kind === "kill" && interrupt.at === j) {
      await quiet(store);
      request.response = "killed";
      state.killedAt = j;
      await stopChild(state);
      return new Response("", { status: 503 });
    }
    if (interrupt?.kind === "fence" && interrupt.at === j) {
      await quiet(store);
      writeFileSync(fencePath, "");
      state.fencedAt = j;
      state.storedAtFence = storeEvents(store).length;
    }
    if (state.plan.drop === j) {
      request.response = "dropped";
      state.lastKind = "dropped";
      // The stream ends before the model's first event.
      return new Response(": dropped by the driver\n\n", { headers: { "content-type": "text/event-stream" } });
    }
    const { kind, frames } = reply(prompt);
    request.response = kind;
    state.lastKind = kind;
    return helpers.fakeGatewaySse(frames);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  const env = testEnvironment({
    HOME: home,
    FX_HOME: fxHome,
    AI_GATEWAY_API_KEY: "fake-resume-notice-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
  });

  const acts: Act[] = [];
  const act = (a: string, run: string[] = []) => acts.push({ a, run });
  let first = true;
  let ended = "none";
  let lives = 0;
  let requests = 0;
  let lastNotices = 0;
  const runLife = async (plan: Life, prompt: string | null) => {
    lives += 1;
    if (!first) {
      if (ended === "clean") act("CleanExit");
      act("Reopen");
    }
    first = false;
    if (prompt !== null) act("StartTurn");
    const state: LifeState = { plan, requests: [], lastKind: null, child: null, killed: false, killedAt: null, fencedAt: null, storedAtFence: 0 };
    // A fence stops the worker it was raised against, not the next one.
    rmSync(fencePath, { force: true });
    life = state;
    const child = Bun.spawn([
      process.execPath, runner, "--backend", options.backend, "--store", store, "--fence", fencePath,
      ...(prompt === null ? ["--resume"] : ["--prompt", prompt]),
      ...(plan.yield ? ["--yield"] : []),
      ...(plan.interrupt?.kind === "hang" ? ["--hang-first-append"] : []),
    ], { cwd: REPO_ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    state.child = child;
    const timer = setTimeout(() => child.kill("SIGKILL"), lifeTimeoutMs);
    let done: any = null;
    const reader = (async () => {
      const decoder = new TextDecoder();
      let buffered = "";
      for await (const chunk of child.stdout as ReadableStream<Uint8Array>) {
        buffered += decoder.decode(chunk, { stream: true });
        let newline;
        while ((newline = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, newline);
          buffered = buffered.slice(newline + 1);
          let message: any = null;
          try { message = JSON.parse(line); } catch { continue; }
          if (message.hanging) {
            // Its first append never lands; the barrier holds the turn there.
            await Bun.sleep(100);
            await stopChild(state);
          }
          if (message.done) done = message;
        }
      }
    })();
    const stderr = new Response(child.stderr as ReadableStream).text();
    await child.exited;
    await reader;
    clearTimeout(timer);
    life = null;
    requests += state.requests.length;
    const counted = state.requests.filter((r) => r.response !== "ignored").at(-1);
    if (counted) lastNotices = counted.content.filter((entry) => entry === "notice").length;
    if (done && done.outside > 0) throw new HarnessError(`a life reached ${done.outside} hosts other than the fake gateway`);

    if (plan.interrupt?.kind === "hang") {
      if (!state.killed) throw new HarnessError(`a hung life ended on its own: ${JSON.stringify(done)} ${(await stderr).slice(-300)}`);
      act("Crash");
      ended = "crash";
      return;
    }
    const kept = state.killedAt ?? state.fencedAt ?? state.requests.length;
    for (const request of state.requests.slice(0, kept)) {
      if (request.afterCall) act("ToolStep");
      act("Request", request.content);
    }
    if (state.killed) {
      if (state.killedAt === null) throw new HarnessError(`a life did not finish in ${lifeTimeoutMs} ms: ${(await stderr).slice(-300)}`);
      act("Crash");
      ended = "crash";
      return;
    }
    if (!done) throw new HarnessError(`a life printed no result: ${(await stderr).slice(-300)}`);
    if (state.fencedAt !== null) {
      if (storeEvents(store).length !== state.storedAtFence) throw new HarnessError("the store took an append after it fenced the worker");
      act("Crash");
      ended = "crash";
      return;
    }
    if (done.stop === "yielded") {
      if (state.requests.at(-1)?.response === "call") act("ToolStep");
      act("Yield");
      ended = "yield";
      return;
    }
    if (done.stop !== "end_turn") throw new HarnessError(`a life ended ${JSON.stringify(done)}: ${(await stderr).slice(-300)}`);
    if (state.requests.length > 0) act("FinishReply");
    if (plan.interrupt?.kind === "tail") {
      // The process died after the reply was saved, before the turn's end.
      const events = storeEvents(store);
      if (events.at(-1)?.type !== "turn_committed" || events.at(-2)?.type !== "turn_progress") {
        throw new HarnessError(`the turn did not end with its reply's progress and its end: ${events.slice(-2).map((e) => e.type)}`);
      }
      writeFileSync(store, events.slice(0, -1).map((event) => `${JSON.stringify(event)}\n`).join(""));
      act("Crash");
      ended = "crash";
      return;
    }
    act("SendEnd");
    act("EndLands");
    act("ResolveResult");
    ended = "clean";
  };

  try {
    for (const [t, turn] of scenario.turns.entries()) {
      for (const [l, plan] of turn.lives.entries()) {
        await runLife(plan, l === 0 ? `turn ${t + 1} needs ${turn.steps} lookups` : null);
        if (ended === "clean") break;
      }
      // A turn whose planned lives all stopped it is ended before the next starts.
      for (let attempt = 0; ended !== "clean"; attempt++) {
        if (attempt === 3) throw new HarnessError(`turn ${t + 1} of "${scenario.name}" did not end after three more resumes`);
        await runLife(ends, null);
      }
    }
    if (gateway.requestCount() !== handled) throw new HarnessError(`the gateway counted ${gateway.requestCount()} requests, the driver ${handled}`);
    if (handled === 0) throw new HarnessError("no request reached the gateway");
  } finally {
    gateway.stop();
  }
  return { name: scenario.name, acts, requests, lives, seconds: Number(((performance.now() - started) / 1000).toFixed(2)), lastNotices };
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.map(str).join(", ")}>>`;

function observedModule(observations: Observation[]): string {
  const scenario = (o: Observation) => `<< ${o.acts.map((a) => `[a |-> ${str(a.a)}, run |-> ${seq(a.run)}]`).join(", ")} >>`;
  return [
    "------------------------- MODULE ResumptionObserved -------------------------",
    "(* Generated by tests/tla/drivers/durable/resume_notice.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(scenario).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function check(observations: Observation[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string; states: number | null }> {
  const dir = mkdtempSync(join(parent, `trace-${rule}-`));
  const most = (name: string) => Math.max(0, ...observations.map((o) => o.acts.filter((a) => a.a === name).length));
  const bound = Math.max(2, most("Crash"), most("Yield"), most("ToolStep"), most("StartTurn")) + 1;
  writeFileSync(join(dir, "ResumptionObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  MaxCrashes = ${bound}`,
    `  MaxTurns = ${bound}`,
    `  MaxSteps = ${bound}`,
    `  MaxYields = ${bound}`,
    `  Rule = ${str(rule)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "ResumptionTrace.tla", "trace.cfg", ["Resumption.tla", "ResumptionTrace.tla"], tlaDir);
  if (run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir, states: run.distinctStates };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir, states: run.distinctStates };
  return { verdict: "TOOL_ERROR", dir, states: run.distinctStates };
}

// --direct checks the rules on the requests themselves, without TLC: within a
// turn each request extends the one before it, carries one notice at most,
// and carries one exactly when a resume after an interruption came before it.
// A resume after a yield, or after a crash that came before anything landed
// after the yield, is not one. Returns what broke, or null.
function directCheck(o: Observation): string | null {
  let last: string[] = [];
  let interrupted = false;
  let yielded = false;
  let stopped = "";
  for (const [index, { a, run }] of o.acts.entries()) {
    if (a === "StartTurn") {
      last = [];
      interrupted = false;
      yielded = false;
    } else if (a === "Yield") {
      yielded = true;
      stopped = a;
    } else if (a === "Crash") {
      stopped = a;
    } else if (a === "Reopen") {
      if (stopped === "Crash" && !yielded) interrupted = true;
    } else if (a === "ToolStep" || a === "FinishReply") {
      yielded = false;
    } else if (a === "Request") {
      const notices = run.filter((entry) => entry === "notice").length;
      const where = `act ${index + 1}, Request${seq(run)}`;
      if (notices > 1) return `${where} carries ${notices} notices`;
      if (interrupted !== (notices === 1)) return `${where} ${interrupted ? "lacks the notice after an interruption" : "carries a notice no interruption explains"}`;
      if (run.length < last.length || last.some((entry, at) => run[at] !== entry)) return `${where} does not extend the request before it, ${seq(last)}`;
      last = run;
      yielded = false;
    }
  }
  return null;
}

async function pool<T, R>(items: T[], jobs: number, work: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(jobs, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]!, index);
    }
  }));
  return results;
}

async function main(): Promise<number> {
  for (const artifact of ["zig-out/lib/libfx.node", ...(options.backend === "wasm" ? ["zig-out/bin/fx-core.wasm"] : [])]) {
    if (!existsSync(join(REPO_ROOT, artifact))) {
      console.log(`TOOL_ERROR: missing ${artifact}; build it first`);
      return 2;
    }
  }
  const helpers = await targetHelpers();
  const out = outDir("resume_notice");
  const scratch = join(out, "scenarios");
  mkdirSync(scratch, { recursive: true });
  const scenarios: Scenario[] = options.replay
    ? JSON.parse(readFileSync(options.replay, "utf8"))
    : [
      ...(options.named ? named.filter((scenario) => options.only.test(scenario.name)) : []),
      ...fuzzed(options.fuzz, options.seed),
      ...(options.stress > 0 ? [stressed(options.stress)] : []),
    ];
  if (scenarios.length === 0) {
    console.log("TOOL_ERROR: no scenarios to run");
    return 2;
  }
  writeJson(join(out, "scenarios.json"), scenarios);
  console.log(`${scenarios.length} scenarios on the ${options.backend} backend${options.fuzz ? `, fuzz seed ${options.seed}` : ""}; output ${out}`);
  const started = performance.now();
  let observations: Observation[];
  try {
    observations = await pool(scenarios, options.jobs, (scenario) => runScenario(helpers, scenario, scratch).catch((error) => {
      if (error instanceof HarnessError) throw new HarnessError(`${scenario.name}: ${error.message}`);
      throw error;
    }));
  } catch (error) {
    console.log(`TOOL_ERROR: ${error instanceof HarnessError ? error.message : (error as Error)?.stack ?? error}`);
    return 2;
  }
  writeJson(join(out, "observed.json"), observations);
  for (const o of observations) {
    console.log(`  ${o.name}: ${o.lives} lives, ${o.requests} requests, last request carried ${o.lastNotices} notice(s), ${o.seconds}s`);
  }
  const total = observations.reduce((sum, o) => sum + o.requests, 0);
  console.log(`${observations.length} scenarios, ${total} model requests, in ${((performance.now() - started) / 1000).toFixed(1)}s`);

  if (options.direct) {
    const broken = observations.map((o) => ({ o, why: directCheck(o) })).filter((entry) => entry.why !== null);
    writeJson(join(out, "rejected.json"), scenarios.filter((_, index) => directCheck(observations[index]!) !== null));
    for (const { o, why } of broken) console.log(`  broken: ${o.name}: ${why}`);
    if (broken.length > 0) {
      console.log(`REJECTED: ${broken.length} scenario(s) broke a rule; replay with --replay ${join(out, "rejected.json")}`);
      return 1;
    }
    console.log("ACCEPTED (direct)");
    return 0;
  }
  const design = await check(observations, "once", out);
  console.log(`model (Rule = "once"): ${design.verdict}, ${design.states} distinct states (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const verdicts = await pool(observations, options.jobs, async (o) => (await check([o], "once", out)).verdict);
    const rejected = observations.filter((_, index) => verdicts[index] === "REJECTED");
    writeJson(join(out, "rejected.json"), scenarios.filter((_, index) => verdicts[index] === "REJECTED"));
    for (const o of rejected) {
      console.log(`  rejected: ${o.name}: ${o.acts.map((a) => (a.a === "Request" ? `Request${seq(a.run)}` : a.a)).join(" ")}`);
    }
    console.log(`REJECTED: ${rejected.length} scenario(s); replay with --replay ${join(out, "rejected.json")}`);
    return 1;
  }
  if (options.selfCheck) {
    for (const rule of ["each", "moved"]) {
      const before = await check(observations, rule, out);
      console.log(`self-check, Rule = "${rule}": ${before.verdict} (must be REJECTED)`);
      if (before.verdict !== "REJECTED") return before.verdict === "TOOL_ERROR" ? 2 : 1;
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
