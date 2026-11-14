// Runs the built fx ask along tests/tla/subagent/MainMail.tla. The driver
// plays main and every subagent: it answers main's requests from a walk and
// holds each subagent's model request until the walk finishes it. fx writes
// a worker trace line for every change to main's queue, under the worker's
// lock, so the trace orders them as the queue saw them; the driver turns
// those lines into observations, and TLC checks that the run is a behavior
// of the model and keeps its rules (MainMailTrace.tla).
//
//   bun test ./tests/tla/drivers/subagent/main-mail.test.ts
//   FX_TLA_MAIL_RANDOM=20 FX_TLA_MAIL_SEED=7   adds 20 random walks
//   FX_TLA_MAIL_STRESS=64                      adds a walk with 64 subagents whose reports join one turn, then
//                                              a turn that lists them all; it logs the list's size and build time
//   FX_TLA_REPEAT=3                            runs each walk 3 times
//   FX_BIN=<binary>                            drives another build
import { expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, repetitions, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, tlcToolchain, writeJson } from "../lib/tlc";

const MAIN_MARK = "MMW_MAIN";
const TOKEN = /MMW-(s\d+)-(\d+)/g;

type MainOp = { send: string } | { wait: true } | { status: true };
// main: answer main's next request with these calls. final: answer it with
// text, which ends the turn unless mail joined it. finish: let a held
// subagent turn end, as a reply or, with fail, as an HTTP 401. closed: wait
// until main's running turn has finished, answering main with text meanwhile.
type Action = { main: MainOp[] } | { final: true } | { finish: string; fail?: boolean } | { closed: true };
type Walk = { name: string; subs: string[]; actions: Action[] };
type Obs = { op: string; m: string; joined: boolean; count: number; said: string };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Result = {
  observations: Obs[];
  error: string | null;
  exit: number | null;
  stderr: string;
  seconds: number;
  maxRss: number | null;
  team: string[];
  lists: string[];
};

const send = (sub: string): MainOp => ({ send: sub });
const wait = (): MainOp => ({ wait: true });
const status = (): MainOp => ({ status: true });
const main = (...ops: MainOp[]): Action => ({ main: ops });
const final: Action = { final: true };
const finish = (sub: string): Action => ({ finish: sub });
const fail = (sub: string): Action => ({ finish: sub, fail: true });
const closed: Action = { closed: true };

// The named edge cases.
const WALKS: Walk[] = [
  // A report that arrives while main's step runs joins the turn at its next boundary.
  { name: "join-at-next-step", subs: ["s1"], actions: [main(send("s1")), finish("s1"), main(status()), final] },
  // A report that arrives while main waits joins right after wait's answer.
  { name: "join-in-wait", subs: ["s1"], actions: [main(send("s1")), main(wait()), finish("s1"), final] },
  // Two reports that arrive in one step both join it, in order.
  { name: "two-join-one-step", subs: ["s1", "s2"], actions: [main(send("s1"), send("s2")), finish("s1"), finish("s2"), main(status()), final] },
  // A report that arrives after the turn closed starts the next turn, once.
  { name: "after-close-next-turn", subs: ["s1"], actions: [main(send("s1")), final, closed, finish("s1"), final] },
  // A report that arrives in the turn another report started joins it.
  {
    name: "join-the-report-turn",
    subs: ["s1", "s2"],
    actions: [main(send("s1"), send("s2")), final, closed, finish("s1"), main(wait()), finish("s2"), final],
  },
  // A subagent given more work reports again, and that report joins too.
  { name: "second-work", subs: ["s1"], actions: [main(send("s1")), finish("s1"), main(send("s1")), finish("s1"), main(status()), final] },
  // A failed subagent's report joins the turn like any other.
  { name: "failed-report-joins", subs: ["s1"], actions: [main(send("s1")), fail("s1"), main(status()), final] },
  // A wait with nothing working returns at once and leaves the queue alone.
  { name: "wait-with-nothing", subs: ["s1"], actions: [main(send("s1")), finish("s1"), main(status()), main(wait()), final] },
];

function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

// A random walk over three subagents. After a final answer or a wait that
// can block, the walk lets a subagent finish before main acts again, so fx
// always has something to bring main.
function randomWalk(seed: number): Walk {
  const next = rng(seed);
  const subs = ["s1", "s2", "s3"];
  const working = new Set<string>();
  const actions: Action[] = [main(send("s1"))];
  working.add("s1");
  let mustFinish = false;
  for (let n = 0; n < 12; n += 1) {
    const roll = next();
    const busy = [...working];
    if (busy.length > 0 && (mustFinish || roll < 0.35)) {
      const sub = busy[Math.floor(next() * busy.length)]!;
      working.delete(sub);
      actions.push(next() < 0.15 ? fail(sub) : finish(sub));
      mustFinish = false;
      continue;
    }
    if (mustFinish) break;
    if (roll < 0.6) {
      const idle = subs.filter((s) => !working.has(s));
      if (idle.length === 0) continue;
      const sub = idle[Math.floor(next() * idle.length)]!;
      working.add(sub);
      actions.push(main(send(sub)));
    } else if (roll < 0.72 && working.size > 0) {
      actions.push(main(wait()));
      mustFinish = true;
    } else if (roll < 0.85) actions.push(main(status()));
    else if (working.size > 0) {
      actions.push(final);
      mustFinish = true;
    }
  }
  for (const sub of working) actions.push(finish(sub));
  actions.push(final);
  return { name: `random-${seed}`, subs, actions };
}

// `count` subagents report into one turn; one more reports after it closed,
// so the next turn starts with every one of them in main's list.
function stressWalk(count: number): Walk {
  const subs = Array.from({ length: count }, (_, i) => `s${i + 1}`);
  const last = `s${count + 1}`;
  return {
    name: `stress-${count}`,
    subs: [...subs, last],
    actions: [main(...subs.map(send), send(last)), ...subs.map(finish), main(status()), final, closed, finish(last), final],
  };
}

const token = (sub: string, n: number) => `MMW-${sub}-${n}`;

async function poll<T>(probe: () => T | undefined | false, ms: number): Promise<T | undefined> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = probe();
    if (value !== undefined && value !== false) return value as T;
    if (Date.now() > deadline) return undefined;
    await Bun.sleep(10);
  }
}

// The worker lines of fx's trace, as observations.
function observe(trace: string): Obs[] {
  const observations: Obs[] = [];
  const row = (o: Partial<Obs> & { op: string }): Obs => ({ m: "none", joined: false, count: 0, said: "none", ...o });
  let posts = 0;
  let begun = false;
  let closedTurn = false;
  // Each subagent's turn runs on a worker of its own; main's is the one
  // whose turn begins first.
  let mainWorker: string | null = null;
  for (const line of trace.split("\n")) {
    const event = /\[worker\] event=(\w+)(.*)$/.exec(line);
    if (!event) continue;
    const [, name, rest] = event as unknown as [string, string, string];
    const worker = / worker=([0-9a-f]+)/.exec(rest)?.[1];
    if (!worker) continue;
    if (mainWorker === null && name === "processing_begun") mainWorker = worker;
    if (worker !== mainWorker) continue;
    if (name === "processing_begun") {
      if (begun) throw new Error("a second turn began outside the take of its mail");
      begun = true;
      closedTurn = false;
      observations.push(row({ op: "user" }));
    } else if (name === "queued_prompt_taken" && rest.includes("marked=true")) {
      closedTurn = false;
      observations.push(row({ op: "next" }));
    } else if (name === "mail_posted") {
      posts += 1;
      observations.push(row({ op: "post", m: `m${posts}`, joined: rest.includes("delivery=joined") }));
    } else if (name === "steering_taken") {
      const count = Number(/count=(\d+)/.exec(rest)?.[1] ?? "0");
      if (count > 0) observations.push(row({ op: "take", count }));
      else if (rest.includes("closed=true") && !closedTurn) {
        closedTurn = true;
        observations.push(row({ op: "close" }));
      }
    } else if (name === "processing_finished") {
      if (!closedTurn) observations.push(row({ op: "abort" }));
      observations.push(row({ op: "finish" }));
    } else if (name === "mail_joins_checked") {
      observations.push(row({ op: "wait", said: rest.includes("joins=true") ? "follows" : "next" }));
    }
  }
  return observations;
}

async function runWalk(walk: Walk, dir: string): Promise<Result> {
  const helpers = await targetHelpers();
  const fakeModel: string = helpers.FAKE_GATEWAY_MODEL;
  const sse = helpers.fakeGatewaySse;
  const text = (value: string) => sse([{ type: "text-delta", id: "t", delta: value }, { type: "finish", finishReason: { unified: "stop", raw: "stop" } }]);
  let callCount = 0;
  const calls = (ops: MainOp[], works: Map<string, number>) => sse([
    ...ops.map((op) => {
      callCount += 1;
      const id = `mmw-${callCount}`;
      if ("send" in op) {
        const n = (works.get(op.send) ?? 0) + 1;
        works.set(op.send, n);
        return { type: "tool-call", toolCallId: id, toolName: "subagent", input: { request: { action: "message", agent: op.send, message: `Do task ${token(op.send, n)} and reply.` } } };
      }
      return { type: "tool-call", toolCallId: id, toolName: "subagent", input: { request: { action: "wait" in op ? "wait" : "status" } } };
    }),
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);

  const root = mkdtempSync(join(dir, `${walk.name}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");

  const works = new Map<string, number>();
  const held = new Map<string, (response: Response) => void>();
  const mainWaiting: Array<{ body: string; resolve: (response: Response) => void }> = [];
  const lists: string[] = [];
  let done = false;
  let error: string | null = null;
  let exited = false;

  const trace = () => (existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "");
  // Main's worker lines only: a subagent's turn runs on its own worker.
  const mainCount = (name: string, also = "") => {
    const lines = trace().split("\n");
    const first = lines.find((line) => line.includes("[worker] event=processing_begun"));
    const worker = first ? / worker=([0-9a-f]+)/.exec(first)?.[1] : undefined;
    if (!worker) return 0;
    return lines.filter((line) => line.includes(`[worker] event=${name} `) && line.includes(` worker=${worker} `) && line.includes(also)).length;
  };
  const nextMain = async () => {
    const taken = await poll(() => mainWaiting.shift() ?? (exited ? null : undefined), 20_000);
    if (taken === undefined) throw new Error(`${walk.name}: main sent no request within 20 s`);
    return taken;
  };
  const answerAll = () => {
    for (const waiting of mainWaiting.splice(0)) waiting.resolve(text("MMW_SEEN"));
  };
  const releaseAll = () => {
    for (const [sub, resolve] of held) {
      held.delete(sub);
      resolve(text(`MMW-DONE ${sub}`));
    }
    answerAll();
  };

  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    if (body.includes(MAIN_MARK)) {
      // The runtime context main had for this request, for the stress walk.
      const list = /Runtime context: your subagents\.[^"]*/.exec(body)?.[0];
      if (list) lists.push(list);
      if (done) return text("MMW_SEEN");
      return await new Promise<Response>((resolve) => mainWaiting.push({ body, resolve }));
    }
    const tokens = [...body.matchAll(TOKEN)];
    const newest = tokens.sort((a, b) => Number(a[2]) - Number(b[2])).at(-1);
    if (!newest || done) return text("MMW-DONE");
    const sub = newest[1]!;
    return await new Promise<Response>((resolve) => held.set(sub, resolve));
  }, { models: [{ id: fakeModel, type: "language", tags: ["tool-use"] }] });

  const started = performance.now();
  const child = Bun.spawn([binary, "ask", "--json", "--full-access", `${MAIN_MARK} run the walk`], {
    cwd: workspace,
    env: testEnvironment({
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-main-mail-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: fakeModel,
      FX_MAX_AGENT_STEPS: "0",
      FX_SOUND: "0",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: "worker,mailbox,subagent",
    }),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  void child.exited.then(() => { exited = true; });

  const walkDone = (async () => {
    for (const action of walk.actions) {
      if ("main" in action) {
        const request = await nextMain();
        if (request === null) throw new Error(`${walk.name}: fx ended before main's step`);
        request.resolve(calls(action.main, works));
      } else if ("final" in action) {
        const request = await nextMain();
        if (request === null) throw new Error(`${walk.name}: fx ended before main's answer`);
        request.resolve(text("MMW_TURN_DONE"));
      } else if ("closed" in action) {
        // A turn ends once every turn that began has finished; main gets
        // text meanwhile, as mail that joined keeps its turn going.
        const ended = await poll(() => {
          answerAll();
          const begun = mainCount("processing_begun") + mainCount("queued_prompt_taken", "marked=true");
          return begun > 0 && mainCount("processing_finished") >= begun;
        }, 20_000);
        if (ended === undefined) throw new Error(`${walk.name}: main's turn never finished`);
      } else {
        const sub = action.finish;
        const before = mainCount("mail_posted");
        const resolve = await poll(() => held.get(sub), 20_000);
        if (resolve === undefined) throw new Error(`${walk.name}: ${sub} has no turn to finish`);
        held.delete(sub);
        resolve(action.fail
          ? new Response(JSON.stringify({ error: { message: "Fixture access rejected" } }), { status: 401, headers: { "content-type": "application/json" } })
          : text(`MMW-DONE ${sub}`));
        if ((await poll(() => mainCount("mail_posted") > before, 20_000)) === undefined) {
          throw new Error(`${walk.name}: ${sub}'s report never reached main`);
        }
      }
    }
  })().catch((caught) => { error = String(caught); });
  await walkDone;
  done = true;
  releaseAll();
  const timer = setTimeout(() => child.kill(9), 120_000);
  const [, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  releaseAll();
  gateway.stop();
  const log = trace();
  const team = [...log.matchAll(/event=team_note [^\n]*/g)].map((m) => m[0]);
  let observations: Obs[] = [];
  try {
    observations = observe(log);
  } catch (caught) {
    error ??= String(caught);
  }
  return {
    observations,
    error,
    exit,
    stderr: stderr.slice(-2000),
    seconds: Number(((performance.now() - started) / 1000).toFixed(2)),
    maxRss: child.resourceUsage()?.maxRSS ?? null,
    team,
    lists,
  };
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Obs[]): string {
  const rows = observations.map((o) =>
    `[op |-> ${str(o.op)}, m |-> ${str(o.m)}, joined |-> ${o.joined ? "TRUE" : "FALSE"}, count |-> ${o.count}, said |-> ${str(o.said)}]`);
  return ["---- MODULE MainMailObserved ----", "EXTENDS Sequences", `Observed == <<${rows.join(",\n  ")}>>`, "====", ""].join("\n");
}

async function checkTrace(observations: Obs[], dir: string): Promise<{ verdict: Verdict; violated: string | null }> {
  mkdirSync(dir, { recursive: true });
  for (const file of ["MainMail.tla", "MainMailTrace.tla"]) copyFileSync(join(TLA_ROOT, "subagent", file), join(dir, file));
  writeFileSync(join(dir, "MainMailObserved.tla"), observedModule(observations));
  const posts = observations.filter((o) => o.op === "post").length;
  const turns = observations.filter((o) => o.op === "user" || o.op === "next").length;
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Mail = {${(posts > 0 ? Array.from({ length: posts }, (_, i) => `m${i + 1}`) : ["m1"]).map(str).join(", ")}}`,
    `  MaxTurns = ${Math.max(1, turns)}`,
    "  Joins = TRUE",
    `  Bug = "none"`,
    "INVARIANTS",
    "  NotAllMatched",
    "  JoinsOpenTurn",
    "  EachOnce",
    "  NoneLost",
    "  InOrder",
    "  WaitHonest",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const tlc = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "MainMailTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(tlc.stdout).text(), new Response(tlc.stderr).text(), tlc.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  const violated = /Error: Invariant (\w+) is violated/.exec(log)?.[1] ?? null;
  if (code === 12 && violated === "NotAllMatched") return { verdict: "ACCEPTED", violated: null };
  if (code === 12 && violated) return { verdict: "REJECTED", violated };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", violated: null };
  console.error(`TLC tool error in ${dir} (exit ${code})`);
  return { verdict: "TOOL_ERROR", violated: null };
}

const recorded = new Map<string, Result>();

async function runAndCheck(walk: Walk, repeat: number): Promise<Result> {
  const dir = join(artifacts, "main-mail", `${walk.name}-${repeat}`);
  mkdirSync(dir, { recursive: true });
  const result = await runWalk(walk, dir);
  const { verdict, violated } = result.observations.length > 0
    ? await checkTrace(result.observations, join(dir, "tlc"))
    : { verdict: "TOOL_ERROR" as Verdict, violated: null };
  writeJson(join(dir, "walk.json"), { walk, verdict, violated, ...result });
  recorded.set(walk.name, result);
  if (verdict !== "ACCEPTED" || result.error) {
    console.error(`${walk.name}: ${verdict} ${violated ?? ""} ${result.error ?? ""} (${dir})`);
  }
  expect(result.error).toBeNull();
  expect(result.exit).toBe(0);
  expect(result.stderr).not.toContain("panic");
  // No walk fails or cancels a turn, so every turn must close at its final
  // boundary; one that ends without a close line is fx skipping that take,
  // which the model would excuse as an early end.
  expect(result.observations.filter((o) => o.op === "abort")).toHaveLength(0);
  expect(verdict).toBe("ACCEPTED");
  return result;
}

const random = Number(process.env.FX_TLA_MAIL_RANDOM ?? "0");
const seed = Number(process.env.FX_TLA_MAIL_SEED ?? "1");
const stress = Number(process.env.FX_TLA_MAIL_STRESS ?? "0");
const walks = [...WALKS, ...Array.from({ length: random }, (_, i) => randomWalk(seed + i))];

for (const walk of walks) {
  for (let repeat = 1; repeat <= repetitions; repeat += 1) {
    test(`${walk.name} walk ${repeat} is a behavior of MainMail`, async () => {
      await runAndCheck(walk, repeat);
    }, 300_000);
  }
}

if (stress > 0) {
  test(`stress-${stress} walk is a behavior of MainMail, and main's list stays within its cap`, async () => {
    const result = await runAndCheck(stressWalk(stress), 1);
    // The turn the last report started lists them all, the first 20 by name.
    const list = result.lists.find((text) => text.includes("more; status lists every one."));
    expect(list).toBeDefined();
    expect(list).toContain(`- and ${stress + 1 - 20} more; status lists every one.`);
    const built = result.team.filter((line) => /listed=20 /.test(line));
    expect(built.length).toBeGreaterThan(0);
    // Its size and build time, for the run's record.
    console.log(`team note with ${stress + 1} subagents: ${built.join(" | ")}`);
  }, 600_000);
}

// The trace check rejects a run that fx would show if the delivery were
// wrong, so an accepted run means something.
test("the trace check rejects planted changes to a run", async () => {
  const dir = join(artifacts, "main-mail", "planted");
  const base = (name: string) => {
    const result = recorded.get(name);
    if (!result) throw new Error(`${name} has not run`);
    return result.observations.map((o) => ({ ...o }));
  };
  expect((await checkTrace(base("join-in-wait"), join(dir, "kept"))).verdict).toBe("ACCEPTED");
  const planted: Record<string, Obs[]> = {};
  // The report waited instead of joining the open turn, as fx ask did before.
  planted.waited = base("join-at-next-step").map((o) => (o.op === "post" ? { ...o, joined: false } : o));
  // wait said the report starts the next turn, though it joined this one.
  planted["wait-says-next"] = base("join-in-wait").map((o) => (o.op === "wait" ? { ...o, said: "next" } : o));
  // The turn closed with the joined report unread.
  planted["closed-unread"] = base("join-at-next-step").filter((o) => o.op !== "take");
  // A report that waited was read twice: in its own turn and again.
  const twice = base("after-close-next-turn");
  const at = twice.findIndex((o) => o.op === "next");
  planted["read-twice"] = [...twice.slice(0, at + 1), { op: "take", m: "none", joined: false, count: 1, said: "none" }, ...twice.slice(at + 1)];
  for (const [name, observations] of Object.entries(planted)) {
    const { verdict } = await checkTrace(observations, join(dir, name));
    expect(`${name}: ${verdict}`).toBe(`${name}: REJECTED`);
  }
}, 300_000);
