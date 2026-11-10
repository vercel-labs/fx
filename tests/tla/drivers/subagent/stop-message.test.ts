// Runs the built fx along tests/tla/subagent/StopMessage.tla. The driver
// plays main and every subagent: it writes main's steps from a walk, holds
// every subagent turn until the walk finishes it, holds the start of every
// turn through FX_TEST_SUBAGENT_START_HELD and the end of every stopped or
// closed work through FX_TEST_SUBAGENT_END_HELD until the walk lets it go,
// and has TLC check that what fx answered is a behavior of the model
// (StopMessageTrace.tla). The driver acts for a subagent only after main's
// step has run and every answer is in, so each walk is one ordered sequence
// of observations. The one exception is a message to a turn that is still
// starting: fx holds main's call until the turn begins, so the driver lets
// the start go once fx says the message waits for it.
//
//   bun test ./tests/tla/drivers/subagent/stop-message.test.ts
//   FX_TLA_STOP_RANDOM=20 FX_TLA_STOP_SEED=7   adds 20 random walks
//   FX_TLA_STOP_STRESS=40                       adds walks that stop and message 40 subagents in one step, and that message 40 starting ones
//   FX_TLA_REPEAT=3                             runs each walk 3 times
//   FX_BIN=<binary>                             drives another build
import { expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, repetitions, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, tlcToolchain, writeJson } from "../lib/tlc";

const MAIN_MARK = "SMW_MAIN";
const TOKEN = /SMW-(s\d+)-(\d+)/g;

type Op = "send" | "stop" | "close";
type Msg = [string, number];
type Call = { op: Op; sub: string; msg: Msg | null; id: string };
type Planned = { op: Op; sub: string };
type Action = { main: Planned[] } | { finish: string } | { end: string } | { begin: string };
// holdStarts keeps a new turn's start held until a message reaches it, a
// begin action, or the end of the walk; otherwise each start is let go as
// soon as main's step has answered.
type Walk = { name: string; subs: string[]; actions: Action[]; holdStarts?: boolean };
type Obs = {
  op: string;
  sub: string;
  msg: Msg | null;
  answer: string;
  count: number;
  calls: Array<{ op: Op; sub: string; msg: Msg | null }>;
  msgs: Msg[];
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Result = {
  observations: Obs[];
  error: string | null;
  exit: number | null;
  stderr: string;
  seconds: number;
  maxRss: number | null;
  accounted: string | null;
  steps: number;
  stops: number;
};

const send = (sub: string): Planned => ({ op: "send", sub });
const stop = (sub: string): Planned => ({ op: "stop", sub });
const close = (sub: string): Planned => ({ op: "close", sub });
const main = (...calls: Planned[]): Action => ({ main: calls });
const finish = (sub: string): Action => ({ finish: sub });
const end = (sub: string): Action => ({ end: sub });
const begin = (sub: string): Action => ({ begin: sub });

// The named edge cases.
const WALKS: Walk[] = [
  { name: "stop-then-message", subs: ["s1"], actions: [main(send("s1")), main(stop("s1")), main(send("s1")), end("s1"), finish("s1")] },
  { name: "stop-and-message-one-step", subs: ["s1"], actions: [main(send("s1")), main(stop("s1"), send("s1")), end("s1"), finish("s1")] },
  { name: "message-then-stop-one-step", subs: ["s1"], actions: [main(send("s1")), main(send("s1"), stop("s1")), end("s1")] },
  { name: "unread-then-stop", subs: ["s1"], actions: [main(send("s1")), main(send("s1")), main(stop("s1")), end("s1")] },
  {
    name: "two-subagents-one-step",
    subs: ["s1", "s2"],
    actions: [main(send("s1"), send("s2")), main(stop("s1"), stop("s2")), main(send("s1"), send("s2")), end("s1"), end("s2"), finish("s1"), finish("s2")],
  },
  { name: "stop-idle-then-message", subs: ["s1"], actions: [main(send("s1")), finish("s1"), main(stop("s1")), main(send("s1")), finish("s1")] },
  { name: "two-messages-after-stop", subs: ["s1"], actions: [main(send("s1")), main(stop("s1")), main(send("s1"), send("s1")), end("s1"), finish("s1")] },
  { name: "read-then-stop", subs: ["s1"], actions: [main(send("s1")), main(send("s1")), finish("s1"), main(stop("s1")), end("s1")] },
  { name: "second-stop-drops-waiting", subs: ["s1"], actions: [main(send("s1")), main(stop("s1")), main(send("s1")), main(stop("s1")), end("s1")] },
  { name: "close-working-then-message", subs: ["s1"], actions: [main(send("s1")), main(close("s1")), main(send("s1")), end("s1"), main(send("s1")), finish("s1")] },
  // The start gap: main's message reaches a turn before it begins.
  { name: "message-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(send("s1")), finish("s1")] },
  { name: "two-messages-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(send("s1"), send("s1")), finish("s1")] },
  { name: "two-subagents-starting", subs: ["s1", "s2"], holdStarts: true, actions: [main(send("s1"), send("s2")), main(send("s1"), send("s2")), finish("s1"), finish("s2")] },
  { name: "begin-then-message", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), begin("s1"), main(send("s1")), finish("s1")] },
  { name: "stop-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(stop("s1")), end("s1"), main(send("s1")), finish("s1")] },
  { name: "close-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(close("s1")), end("s1")] },
  { name: "stop-and-message-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(stop("s1"), send("s1")), end("s1"), finish("s1")] },
  { name: "message-then-stop-while-starting", subs: ["s1"], holdStarts: true, actions: [main(send("s1")), main(send("s1"), stop("s1")), end("s1")] },
];

function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

// A random walk over two subagents. The driver skips an action fx gives it
// no way to take (a finish without a held turn, an end without a held end).
function randomWalk(seed: number): Walk {
  const next = rng(seed);
  const subs = ["s1", "s2"];
  const pick = <T>(items: T[]) => items[Math.floor(next() * items.length)]!;
  const actions: Action[] = [main(send("s1"), send("s2"))];
  const holdStarts = next() < 0.5;
  for (let n = 0; n < 10; n += 1) {
    const roll = next();
    if (holdStarts && next() < 0.15) {
      actions.push(begin(pick(subs)));
      continue;
    }
    if (roll < 0.55) {
      const first: Planned = { op: next() < 0.6 ? "send" : next() < 0.9 ? "stop" : "close", sub: pick(subs) };
      const second: Planned = { op: next() < 0.6 ? "send" : "stop", sub: next() < 0.6 ? first.sub : pick(subs) };
      // Two messages to one subagent in a step can both reach its first
      // request when it was idle, which the model doesn't describe.
      if (next() < 0.5 || (first.op === "send" && second.op === "send" && first.sub === second.sub)) actions.push(main(first));
      else actions.push(main(first, second));
    } else if (roll < 0.8) actions.push(end(pick(subs)));
    else actions.push(finish(pick(subs)));
  }
  return { name: `random-${seed}`, subs, actions, holdStarts };
}

function stressWalk(count: number): Walk {
  const subs = Array.from({ length: count }, (_, i) => `s${i + 1}`);
  return {
    name: `stress-${count}`,
    subs,
    actions: [main(...subs.map(send)), main(...subs.flatMap((s) => [stop(s), send(s)])), ...subs.map(end), ...subs.map(finish)],
  };
}

// Every subagent is started and held, then messaged while it starts.
function stressStartWalk(count: number): Walk {
  const subs = Array.from({ length: count }, (_, i) => `s${i + 1}`);
  return { name: `stress-start-${count}`, subs, holdStarts: true, actions: [main(...subs.map(send)), main(...subs.map(send)), ...subs.map(finish)] };
}

const token = (msg: Msg) => `SMW-${msg[0]}-${msg[1]}`;
const parseToken = (text: string): Msg => {
  const match = /SMW-(s\d+)-(\d+)/.exec(text)!;
  return [match[1]!, Number(match[2])];
};

function allStrings(value: unknown, out: string[] = []): string[] {
  if (typeof value === "string") out.push(value);
  else if (Array.isArray(value)) for (const item of value) allStrings(item, out);
  else if (value && typeof value === "object") for (const item of Object.values(value)) allStrings(item, out);
  return out;
}

// The text of tool result `id` in a request body, or "" when it has none.
function toolResultText(body: string, id: string): string {
  let found = "";
  const walk = (value: any) => {
    if (found) return;
    if (Array.isArray(value)) value.forEach(walk);
    else if (value && typeof value === "object") {
      if (value.type === "tool-result" && value.toolCallId === id) found = allStrings(value.output).join("");
      else Object.values(value).forEach(walk);
    }
  };
  walk(JSON.parse(body));
  return found;
}

function sendAnswer(text: string): string {
  if (text.includes("works on it now")) return "started";
  if (text.includes("Sent into the subagent's running turn")) return "joined";
  if (text.includes("so the message waits and starts its next turn")) return "waits";
  if (text.includes("\"ok\":false")) return "refused";
  return `other: ${text.slice(0, 160)}`;
}

function dropCount(text: string): number {
  const many = /the (\d+) messages waiting for it were dropped/i.exec(text);
  if (many) return Number(many[1]);
  return /the message waiting for it was dropped/i.test(text) ? 1 : 0;
}

async function poll<T>(probe: () => T | undefined | false, ms: number): Promise<T | undefined> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = probe();
    if (value !== undefined && value !== false) return value as T;
    if (Date.now() > deadline) return undefined;
    await Bun.sleep(10);
  }
}

async function runWalk(walk: Walk, dir: string): Promise<Result> {
  const helpers = await targetHelpers();
  const fakeModel: string = helpers.FAKE_GATEWAY_MODEL;
  const sse = helpers.fakeGatewaySse;
  const final = (text: string) => sse([{ type: "text-delta", id: "t", delta: text }, { type: "finish", finishReason: { unified: "stop", raw: "stop" } }]);
  const tools = (calls: Call[]) => sse([
    ...calls.map((call) => ({
      type: "tool-call",
      toolCallId: call.id,
      toolName: "subagent",
      input: { request: call.op === "send" ? { action: "message", agent: call.sub, message: token(call.msg!) } : { action: call.op, agent: call.sub } },
    })),
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);

  const observations: Obs[] = [];
  const held = new Map<string, (response: Response) => void>();
  const arrivals = new Map<string, string[][]>();
  const waiters = new Map<string, Array<(tokens: string[]) => void>>();
  const seen = new Map<string, Set<string>>();
  const unread = new Map<string, Set<string>>();
  const waiting = new Map<string, Set<string>>();
  const ending = new Set<string>();
  const closing = new Set<string>();
  const running = new Set<string>();
  // Subagents whose current turn is held at its start, and those whose turn
  // began but whose first model request the driver has not looked at.
  const starting = new Set<string>();
  const firstPending = new Set<string>();
  // The messages that joined each subagent's turns, in the order fx took them.
  const joinedOrder = new Map<string, string[]>();
  // Messages that started a turn: the turn has them from its start, and a
  // stop can end it before it ever asks the model.
  const startTokens = new Set<string>();
  const nextMsg = new Map<string, number>();
  const readTokens = new Set<string>();
  for (const s of walk.subs) {
    seen.set(s, new Set());
    unread.set(s, new Set());
    waiting.set(s, new Set());
    nextMsg.set(s, 0);
  }
  let pending: Call[] | null = null;
  let actionIndex = 0;
  let steps = 0;
  let stops = 0;
  let sentCount = 0;
  let refusedCount = 0;
  let droppedCount = 0;
  let done = false;
  let error: string | null = null;

  const root = mkdtempSync(join(dir, `${walk.name}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const heldMarker = join(root, "end-held");
  const release = join(root, "end-release");
  const released = new Set<number>();
  const startMarker = join(root, "start-held");
  const startRelease = join(root, "start-release");
  const startReleased = new Set<number>();
  // Set while main's step runs; a background release stops once it is false.
  let stepRunning = false;
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");

  const arrive = (sub: string, tokens: string[]) => {
    const queue = waiters.get(sub);
    if (queue && queue.length > 0) queue.shift()!(tokens);
    else arrivals.set(sub, [...(arrivals.get(sub) ?? []), tokens]);
  };
  // The next request of `sub` within `ms`, or null: a turn a stop ended
  // may never have asked the model.
  const arrivalWithin = (sub: string, ms: number) => new Promise<string[] | null>((resolve) => {
    const queued = arrivals.get(sub);
    if (queued && queued.length > 0) {
      resolve(queued.shift()!);
      return;
    }
    const waiter = (tokens: string[]) => {
      clearTimeout(timer);
      resolve(tokens);
    };
    const timer = setTimeout(() => {
      waiters.set(sub, (waiters.get(sub) ?? []).filter((w) => w !== waiter));
      resolve(null);
    }, ms);
    waiters.set(sub, [...(waiters.get(sub) ?? []), waiter]);
  });
  const nextArrival = (sub: string, ms = 15_000) => new Promise<string[]>((resolve, reject) => {
    const queued = arrivals.get(sub);
    if (queued && queued.length > 0) {
      resolve(queued.shift()!);
      return;
    }
    const timer = setTimeout(() => reject(new Error(`${walk.name}: ${sub} sent no model request within ${ms} ms`)), ms);
    waiters.set(sub, [...(waiters.get(sub) ?? []), (tokens) => {
      clearTimeout(timer);
      resolve(tokens);
    }]);
  });
  // The next request of `sub` that brings messages it has not read. A
  // turn has its start message from the start, so a start message in a
  // later request, such as the task of a turn stopped before it asked the
  // model, is not a read.
  const nextRead = async (sub: string): Promise<string[]> => {
    for (;;) {
      const tokens = (await nextArrival(sub)).filter((t) => !startTokens.has(t));
      if (tokens.length > 0) {
        for (const t of tokens) readTokens.add(t);
        return tokens;
      }
    }
  };
  const logs = (): string[] => {
    const v2 = join(home, ".fx", "sessions", "v2");
    if (!existsSync(v2)) return [];
    return readdirSync(v2).map((id) => join(v2, id, "log.jsonl")).filter(existsSync).map((log) => readFileSync(log, "utf8"));
  };
  const records = () => logs().flatMap((text) => text.split("\n").filter(Boolean).map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return {};
    }
  }));
  const childIds = (sub: string) => new Set(records().filter((r) => r.kind === "child_spawned" && r.data?.agent === sub).map((r) => r.child as string));
  const finishedCount = (sub: string) => {
    const ids = childIds(sub);
    return records().filter((r) => r.kind === "child_finished" && ids.has(r.child)).length;
  };
  // How many reports of `sub`'s works fx has queued for main. The end of a
  // finished work queues it before the work is idle, so a stop sent before
  // that still finds the work running and says it stopped it.
  const reportsQueued = (sub: string) => {
    const log = join(root, "trace.log");
    if (!existsSync(log)) return 0;
    const ids = childIds(sub);
    return [...readFileSync(log, "utf8").matchAll(/event=report_queued to=main from=(\S+)/g)].filter((m) => ids.has(m[1]!)).length;
  };
  // The first held end of `sub` the walk has not released.
  const heldEnd = (sub: string): number | undefined => {
    const ids = childIds(sub);
    const held: number[] = [];
    for (const name of readdirSync(root)) {
      const match = /^end-held\.(\d+)$/.exec(name);
      if (!match || released.has(Number(match[1]))) continue;
      const child = /child=(\S+)/.exec(readFileSync(join(root, name), "utf8"))?.[1];
      if (child && ids.has(child)) held.push(Number(match[1]));
    }
    return held.sort((a, b) => a - b)[0];
  };
  // The first held start of `sub` the walk has not released.
  const heldStart = (sub: string): number | undefined => {
    const ids = childIds(sub);
    const held: number[] = [];
    for (const name of readdirSync(root)) {
      const match = /^start-held\.(\d+)$/.exec(name);
      if (!match || startReleased.has(Number(match[1]))) continue;
      const child = /child=(\S+)/.exec(readFileSync(join(root, name), "utf8"))?.[1];
      if (child && ids.has(child)) held.push(Number(match[1]));
    }
    return held.sort((a, b) => a - b)[0];
  };
  // How many times fx said a message to `sub` waits for its turn to begin.
  const waitsStart = (sub: string) => {
    const log = join(root, "trace.log");
    if (!existsSync(log)) return 0;
    const ids = childIds(sub);
    return [...readFileSync(log, "utf8").matchAll(/event=message_waits_start child=(\S+)/g)].filter((m) => ids.has(m[1]!)).length;
  };
  const releaseStart = async (sub: string) => {
    const n = await poll(() => heldStart(sub), 15_000);
    if (n === undefined) throw new Error(`${walk.name}: ${sub}'s turn never reached its start`);
    startReleased.add(n);
    writeFileSync(`${startRelease}.${n}`, "");
    starting.delete(sub);
  };
  const row = (o: Partial<Obs> & { op: string }): Obs => ({
    sub: "none", msg: null, answer: "none", count: 0, calls: [], msgs: [], ...o,
  });
  const push = (o: Partial<Obs> & { op: string }) => observations.push(row(o));
  // A first request takes every message that joined its turn before it was
  // sent, which can be in the middle of main's step: its read goes right
  // after the last message it took, before a later stop of the same step.
  const pushRead = (sub: string, tokens: string[]) => {
    const taken = new Set(tokens.map((t) => JSON.stringify(parseToken(t))));
    let at = -1;
    observations.forEach((o, i) => {
      if (o.op === "send" && o.sub === sub && o.answer === "joined" && taken.has(JSON.stringify(o.msg))) at = i;
    });
    const read = row({ op: "read", sub, msgs: tokens.map(parseToken) });
    if (at === -1) observations.push(read);
    else observations.splice(at + 1, 0, read);
  };

  // The starting turn of `sub` begins: the driver lets its start go.
  const beginAction = async (sub: string) => {
    if (!starting.has(sub)) return;
    await releaseStart(sub);
    running.add(sub);
    firstPending.add(sub);
    push({ op: "begin", sub });
  };
  // The joined messages of `sub` that a turn took into a step
  // (`feedback_applied` in fx's trace), matched to the joins in order: calls
  // to one subagent run in order.
  const appliedTokens = (sub: string): string[] => {
    const log = join(root, "trace.log");
    if (!existsSync(log)) return [];
    const text = readFileSync(log, "utf8");
    const ids = childIds(sub);
    const ops = [...text.matchAll(/event=message child=(\S+) work_id=\S+ delivery=joined receipt=\S+ operation=(\S+)/g)]
      .filter((m) => ids.has(m[1]!)).map((m) => m[2]!);
    const applied = new Set([...text.matchAll(/event=feedback_applied operation=(\S+)/g)].map((m) => m[1]!));
    return (joinedOrder.get(sub) ?? []).filter((_, i) => ops[i] !== undefined && applied.has(ops[i]!));
  };
  // A turn that began asks the model first; a message that joined it before
  // that request is read by it. A turn a stop of the same step ended may
  // have asked before the stop, or never; its step can also have taken a
  // message just before the stop ended it, with no request sent.
  const readFirst = async (sub: string) => {
    if (!firstPending.delete(sub)) return;
    const arrival = running.has(sub) ? await nextArrival(sub) : await arrivalWithin(sub, 1_000);
    const fresh = (arrival ?? []).filter((t) => !startTokens.has(t));
    if (!running.has(sub)) {
      // Such a message is in the subagent's history from now on, so a later
      // request that carries it brings nothing new.
      for (const t of appliedTokens(sub)) {
        if (readTokens.has(t) || fresh.includes(t)) continue;
        fresh.push(t);
        seen.get(sub)!.add(t);
      }
    }
    if (fresh.length === 0) return;
    for (const t of fresh) {
      readTokens.add(t);
      unread.get(sub)!.delete(t);
    }
    pushRead(sub, fresh);
  };
  // The stopped or closed work of `sub` ends; the messages waiting for it
  // start its next turn, which starts held like any other.
  const endAction = async (sub: string) => {
    if (!ending.has(sub)) return;
    const before = finishedCount(sub);
    const n = await poll(() => heldEnd(sub), 15_000);
    if (n === undefined) throw new Error(`${walk.name}: ${sub}'s stopped work never reached its end`);
    released.add(n);
    writeFileSync(`${release}.${n}`, "");
    if ((await poll(() => finishedCount(sub) > before, 15_000)) === undefined) throw new Error(`${walk.name}: ${sub}'s stopped work never finished`);
    const msgs = closing.has(sub) ? [] : [...waiting.get(sub)!];
    ending.delete(sub);
    closing.delete(sub);
    waiting.get(sub)!.clear();
    push({ op: "end", sub, msgs: msgs.map(parseToken) });
    if (msgs.length === 0) return;
    starting.add(sub);
    await releaseStart(sub);
    running.add(sub);
    push({ op: "begin", sub });
    const tokens = await nextArrival(sub);
    for (const t of msgs) {
      if (!tokens.includes(t)) throw new Error(`${walk.name}: ${sub}'s next turn did not take ${t}`);
      readTokens.add(t);
    }
  };
  // The running turn of `sub` answers: it reads what joined it, or ends.
  const finishAction = async (sub: string) => {
    if (starting.has(sub)) {
      await beginAction(sub);
      await readFirst(sub);
    }
    if (!running.has(sub) || ending.has(sub)) return;
    const resolve = await poll(() => held.get(sub), 15_000);
    if (!resolve) throw new Error(`${walk.name}: ${sub}'s running turn sent no model request`);
    const before = finishedCount(sub);
    const reportsBefore = reportsQueued(sub);
    held.delete(sub);
    resolve(final(`WALKDONE ${sub}`));
    if (unread.get(sub)!.size > 0) {
      const tokens = await nextRead(sub);
      unread.get(sub)!.clear();
      push({ op: "read", sub, msgs: tokens.map(parseToken) });
      return;
    }
    if ((await poll(() => finishedCount(sub) > before, 15_000)) === undefined) throw new Error(`${walk.name}: ${sub}'s turn never ended`);
    if ((await poll(() => reportsQueued(sub) > reportsBefore, 15_000)) === undefined) throw new Error(`${walk.name}: ${sub}'s finished work queued no report`);
    // The work publishes its end just after queuing the report.
    await Bun.sleep(200);
    running.delete(sub);
    push({ op: "finish", sub });
  };
  const takeAnswers = async (body: string, calls: Call[]) => {
    stepRunning = false;
    const startedNow: string[] = [];
    for (const call of calls) {
      const text = toolResultText(body, call.id);
      const s = call.sub;
      if (call.op === "send") {
        const answer = sendAnswer(text);
        push({ op: "send", sub: s, msg: call.msg, answer });
        const t = token(call.msg!);
        if (answer === "started") {
          startTokens.add(t);
          starting.add(s);
          startedNow.push(s);
        } else if (answer === "joined") {
          unread.get(s)!.add(t);
          joinedOrder.set(s, [...(joinedOrder.get(s) ?? []), t]);
        }
        else if (answer === "waits") waiting.get(s)!.add(t);
        else if (answer === "refused") refusedCount += 1;
      } else {
        const count = dropCount(text);
        droppedCount += count;
        const answer = text.includes("child_unavailable")
          ? "unavailable"
          : call.op === "close"
            ? (text.includes("Closed ") ? "closed" : `other: ${text.slice(0, 160)}`)
            : text.includes("its turn ended") ? "stopped" : text.includes("was not working") ? "idle" : `other: ${text.slice(0, 160)}`;
        push({ op: call.op, sub: s, answer, count });
        const endedTurn = call.op === "close" ? text.includes("ending its turn") : answer === "stopped";
        if (endedTurn) {
          ending.add(s);
          if (call.op === "close") closing.add(s);
          held.delete(s);
          running.delete(s);
          // A stopped turn that never began: its start goes, with no begin.
          if (starting.has(s)) await releaseStart(s);
        }
        unread.get(s)!.clear();
        waiting.get(s)!.clear();
      }
    }
    // A turn the step started begins now unless the walk holds starts. A
    // turn that began during the step, or begins now, then reads what joined
    // it before its first request.
    for (const s of startedNow) if (!walk.holdStarts) await beginAction(s);
    for (const s of walk.subs) if (!walk.holdStarts && starting.has(s)) await beginAction(s);
    for (const s of walk.subs) await readFirst(s);
  };
  const settle = async () => {
    for (const s of walk.subs) {
      for (let guard = 0; guard < 20; guard += 1) {
        if (ending.has(s)) await endAction(s);
        else if (starting.has(s) || running.has(s)) await finishAction(s);
        else break;
      }
    }
  };
  const releaseAll = () => {
    writeFileSync(release, "");
    writeFileSync(startRelease, "");
    for (const [s, resolve] of held) {
      held.delete(s);
      resolve(final(`WALKDONE ${s}`));
    }
  };

  const mainStep = async (body: string): Promise<Response> => {
    if (done) return final("REPORTS_SEEN");
    try {
      if (pending) {
        await takeAnswers(body, pending);
        pending = null;
      }
      while (actionIndex < walk.actions.length) {
        const action = walk.actions[actionIndex]!;
        actionIndex += 1;
        if ("main" in action) {
          steps += 1;
          const calls: Call[] = action.main.map((planned, k) => {
            let msg: Msg | null = null;
            if (planned.op === "send") {
              const n = nextMsg.get(planned.sub)! + 1;
              nextMsg.set(planned.sub, n);
              msg = [planned.sub, n];
              sentCount += 1;
            } else stops += 1;
            return { op: planned.op, sub: planned.sub, msg, id: `smw-${steps}-${k + 1}` };
          });
          push({ op: "step", calls: calls.map(({ op, sub, msg }) => ({ op, sub, msg })) });
          pending = calls;
          stepRunning = true;
          // fx holds a message to a starting turn until the turn begins:
          // once it says so, the driver lets the start go.
          for (const s of new Set(calls.filter((c) => c.op === "send" && starting.has(c.sub)).map((c) => c.sub))) {
            const before = waitsStart(s);
            void (async () => {
              await poll(() => !stepRunning || waitsStart(s) > before, 20_000);
              if (stepRunning && starting.has(s)) await beginAction(s);
            })().catch((caught) => { error ??= String(caught); });
          }
          return tools(calls);
        }
        if ("finish" in action) await finishAction(action.finish);
        else if ("begin" in action) {
          await beginAction(action.begin);
          await readFirst(action.begin);
        } else await endAction(action.end);
      }
      await settle();
    } catch (caught) {
      error = String(caught);
      console.error(error);
    }
    done = true;
    releaseAll();
    return final("WALK_DONE");
  };

  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    if (body.includes(MAIN_MARK)) return await mainStep(body);
    const tokens = [...new Set([...body.matchAll(TOKEN)].map((match) => match[0]))];
    if (tokens.length === 0) return final("UNKNOWN_REQUEST");
    const sub = parseToken(tokens[0]!)[0];
    const known = seen.get(sub) ?? new Set<string>();
    const fresh = tokens.filter((t) => !known.has(t));
    for (const t of fresh) known.add(t);
    if (done) return final(`WALKDONE ${sub}`);
    return await new Promise<Response>((resolve) => {
      held.set(sub, resolve);
      arrive(sub, fresh);
    });
  }, { models: [{ id: fakeModel, type: "language", tags: ["tool-use"] }] });

  const started = performance.now();
  const child = Bun.spawn([binary, "ask", "--json", "--full-access", `${MAIN_MARK} run the walk`], {
    cwd: workspace,
    env: testEnvironment({
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-stop-message-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: fakeModel,
      FX_MAX_AGENT_STEPS: "0",
      FX_TRACE_LOG: join(root, "trace.log"),
      FX_TRACE_SCOPES: "mailbox,subagent",
      FX_TEST_SUBAGENT_END_HELD: heldMarker,
      FX_TEST_SUBAGENT_END_RELEASE: release,
      FX_TEST_SUBAGENT_START_HELD: startMarker,
      FX_TEST_SUBAGENT_START_RELEASE: startRelease,
    }),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), 240_000);
  const [, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  releaseAll();
  gateway.stop();
  // Every message main sent was read, refused, or counted in a drop.
  const readCount = new Set([...readTokens, ...startTokens]).size;
  const accounted = sentCount === readCount + refusedCount + droppedCount
    ? null
    : `sent ${sentCount}, read ${readCount}, refused ${refusedCount}, counted as dropped ${droppedCount}`;
  return {
    observations,
    error,
    exit,
    stderr: stderr.slice(-2000),
    seconds: Number(((performance.now() - started) / 1000).toFixed(2)),
    maxRss: child.resourceUsage()?.maxRSS ?? null,
    accounted,
    steps,
    stops,
  };
}

const str = (value: string) => JSON.stringify(value);
const tlaMsg = (msg: Msg | null) => msg ? `<<${str(msg[0])}, ${msg[1]}>>` : `<<"none", 0>>`;

function observedModule(observations: Obs[]): string {
  const rows = observations.map((o) => {
    const calls = `<<${o.calls.map((c) => `[op |-> ${str(c.op)}, sub |-> ${str(c.sub)}, msg |-> ${tlaMsg(c.msg)}]`).join(", ")}>>`;
    const msgs = `{${o.msgs.map(tlaMsg).join(", ")}}`;
    return `[op |-> ${str(o.op)}, sub |-> ${str(o.sub)}, msg |-> ${tlaMsg(o.msg)}, answer |-> ${str(o.answer)}, count |-> ${o.count}, calls |-> ${calls}, msgs |-> ${msgs}]`;
  });
  return ["---- MODULE StopMessageObserved ----", "EXTENDS Sequences", `Observed == <<${rows.join(",\n  ")}>>`, "====", ""].join("\n");
}

async function checkTrace(observations: Obs[], subs: string[], dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  for (const file of ["StopMessage.tla", "StopMessageTrace.tla"]) copyFileSync(join(TLA_ROOT, "subagent", file), join(dir, file));
  writeFileSync(join(dir, "StopMessageObserved.tla"), observedModule(observations));
  const steps = observations.filter((o) => o.op === "step");
  const msgsPer = Math.max(1, ...observations.flatMap((o) => o.calls.filter((c) => c.msg).map((c) => c.msg![1])));
  const stops = steps.flatMap((o) => o.calls).filter((c) => c.op !== "send").length;
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Subs = {${subs.map(str).join(", ")}}`,
    `  MsgsPer = ${msgsPer}`,
    `  MaxSteps = ${Math.max(1, steps.length)}`,
    `  MaxStops = ${stops}`,
    `  Bug = "none"`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const tlc = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "StopMessageTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(tlc.stdout).text(), new Response(tlc.stderr).text(), tlc.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return "ACCEPTED";
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return "REJECTED";
  console.error(`TLC tool error in ${dir} (exit ${code})`);
  return "TOOL_ERROR";
}

const recorded = new Map<string, Result>();

async function runAndCheck(walk: Walk, repeat: number) {
  const dir = join(artifacts, "stop-message", `${walk.name}-${repeat}`);
  mkdirSync(dir, { recursive: true });
  const result = await runWalk(walk, dir);
  const verdict = result.observations.length > 0 ? await checkTrace(result.observations, walk.subs, join(dir, "tlc")) : "TOOL_ERROR";
  writeJson(join(dir, "walk.json"), { walk, verdict, ...result });
  recorded.set(walk.name, result);
  if (verdict !== "ACCEPTED" || result.error || result.accounted) {
    console.error(`${walk.name}: ${verdict} ${result.error ?? ""} ${result.accounted ?? ""} (${dir})`);
  }
  expect(result.error).toBeNull();
  expect(result.exit).toBe(0);
  expect(result.stderr).not.toContain("panic");
  expect(result.accounted).toBeNull();
  expect(verdict).toBe("ACCEPTED");
}

const random = Number(process.env.FX_TLA_STOP_RANDOM ?? "0");
const seed = Number(process.env.FX_TLA_STOP_SEED ?? "1");
const stress = Number(process.env.FX_TLA_STOP_STRESS ?? "0");
const walks = [
  ...WALKS,
  ...Array.from({ length: random }, (_, i) => randomWalk(seed + i)),
  ...(stress > 0 ? [stressWalk(stress), stressStartWalk(stress)] : []),
];

for (const walk of walks) {
  for (let repeat = 1; repeat <= repetitions; repeat += 1) {
    test(`${walk.name} walk ${repeat} is a behavior of StopMessage`, async () => {
      await runAndCheck(walk, repeat);
    }, 300_000);
  }
}

// The trace check rejects a walk that fx would show if one of the fixes were
// missing, so an accepted walk means something.
test("the trace check rejects planted changes to a walk", async () => {
  const dir = join(artifacts, "stop-message", "planted");
  const base = (name: string) => {
    const result = recorded.get(name);
    if (!result) throw new Error(`${name} has not run`);
    return result.observations.map((o) => ({ ...o, calls: [...o.calls], msgs: [...o.msgs] }));
  };
  const subs = ["s1"];
  expect(await checkTrace(base("stop-then-message"), subs, join(dir, "kept"))).toBe("ACCEPTED");
  const planted: Record<string, Obs[]> = {};
  // A message after the stop refused, as fx did before.
  planted.refused = base("stop-then-message").map((o) => o.op === "send" && o.answer === "waits" ? { ...o, answer: "refused" } : o);
  // In one step, the message joined the turn before the stop ended it.
  planted["joined-before-stop"] = base("stop-and-message-one-step").map((o) =>
    o.op === "send" && o.answer === "waits" ? { ...o, answer: "joined" } : o.op === "stop" ? { ...o, count: 1 } : o);
  // The stop left the unread message out of its count.
  planted.uncounted = base("message-then-stop-one-step").map((o) => o.op === "stop" ? { ...o, count: 0 } : o);
  // The stopped turn's end dropped the waiting message.
  planted["lost-at-end"] = base("stop-then-message").map((o) => o.op === "end" ? { ...o, msgs: [] } : o);
  // A message to a starting turn waited for the next one, as fx did before.
  planted["start-next-turn"] = base("message-while-starting").map((o) =>
    o.op === "send" && o.answer === "joined" ? { ...o, answer: "waits" } : o);
  // The message joined the turn before the turn began.
  const early = base("message-while-starting");
  const at = early.findIndex((o) => o.op === "begin");
  planted["joined-before-begin"] = [...early.slice(0, at), early[at + 1]!, early[at]!, ...early.slice(at + 2)];
  for (const [name, observations] of Object.entries(planted)) {
    expect(`${name}: ${await checkTrace(observations, subs, join(dir, name))}`).toBe(`${name}: REJECTED`);
  }
}, 300_000);
